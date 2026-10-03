#' A lazy array over a local Zarr v2 store
#'
#' A deliberately small reader, to show that a real chunked, compressed
#' store fits behind the fetch contract in a few lines. Handles Zarr v2
#' arrays with dtype `<f8`, `<f4`, `<i4`, `<i2`, `|i1`, `<u2`, `|u1` or
#' `|b1`, compressor `null` or `zlib`, order `C` or `F`, and missing chunk
#' files (read as `fill_value`). Zarr's padded edge chunks are clipped.
#'
#' This is a demonstration, not a Zarr implementation: no Zarr v3, no
#' remote stores, no other codecs. For real stores, use a full Zarr reader
#' and hand its chunk reads to [altarr()] as the fetch function.
#'
#' The array's type follows the dtype: floats give a double array, integers
#' an integer array, `|b1` a logical array. With `unpack = TRUE`, CF
#' packing attributes found in `.zattrs` are applied inside the fetch:
#' values equal to `_FillValue` or `missing_value` become `NA`, and if
#' `scale_factor` or `add_offset` is present the array is double, holding
#' the unpacked values. The Zarr `fill_value` itself is not treated as
#' missing.
#'
#' A C-order Zarr array of shape `(s1, ..., sn)` is returned with R `dim`
#' `c(sn, ..., s1)`: C-order bytes are already column-major for the
#' reversed shape, so no transposition is ever done.
#'
#' @param path directory of the Zarr v2 array (containing `.zarray`)
#' @param unpack apply CF `scale_factor`, `add_offset`, `_FillValue` and
#'   `missing_value` from `.zattrs`?
#' @return a lazy array, see [altarr()]
#' @examples
#' path <- altarr_example_zarr()
#' x <- altarr_zarr_v2(path)
#' dim(x)   # the Zarr shape, reversed
#' x[cbind(70, 50, 30)]
#' str(x)
#' @export
altarr_zarr_v2 <- function(path, unpack = TRUE) {
  slurp <- function(f) {
    if (!file.exists(f)) return("")
    paste(readLines(f, warn = FALSE), collapse = "")
  }
  meta <- slurp(file.path(path, ".zarray"))
  attrs <- slurp(file.path(path, ".zattrs"))
  num_array <- function(key) {
    m <- regmatches(meta, regexpr(sprintf('"%s"\\s*:\\s*\\[[^]]*\\]', key), meta))
    as.numeric(strsplit(gsub(".*\\[|\\]|\\s", "", m), ",")[[1]])
  }
  str_field <- function(key) {
    m <- regmatches(meta, regexpr(sprintf('"%s"\\s*:\\s*"[^"]*"', key), meta))
    if (!length(m)) return(NA_character_)
    sub('.*"\\s*:\\s*"([^"]*)"', "\\1", m)
  }
  ## a scalar number (or a one-element array) for 'key' in a JSON string
  num_field <- function(json, key) {
    m <- regmatches(json, regexpr(sprintf('"%s"\\s*:\\s*\\[?\\s*[^],}]*', key), json))
    if (!length(m)) return(NA_real_)
    suppressWarnings(as.numeric(gsub('.*:\\s*\\[?\\s*|"', "", m)))
  }
  shape <- num_array("shape")
  zchunk <- num_array("chunks")
  dtype <- str_field("dtype")
  order <- str_field("order")
  sep <- str_field("dimension_separator")
  if (is.na(sep)) sep <- "."
  comp <- if (grepl('"compressor"\\s*:\\s*null', meta)) "none" else str_field("id")

  ty <- switch(dtype,
    "<f8" = list(what = "double", size = 8L, kind = "double"),
    "<f4" = list(what = "double", size = 4L, kind = "double"),
    "<i4" = list(what = "integer", size = 4L, kind = "integer"),
    "<i2" = list(what = "integer", size = 2L, kind = "integer"),
    "|i1" = list(what = "integer", size = 1L, kind = "integer"),
    "<u2" = list(what = "integer", size = 2L, kind = "integer", signed = FALSE),
    "|u1" = list(what = "integer", size = 1L, kind = "integer", signed = FALSE),
    "|b1" = list(what = "integer", size = 1L, kind = "logical", signed = FALSE),
    stop("unsupported dtype ", dtype))
  if (!comp %in% c("none", "zlib")) stop("unsupported compressor ", comp)

  ## Zarr fill_value: a number, true/false for booleans, or null
  fill <- if (ty$kind == "logical") {
    if (grepl('"fill_value"\\s*:\\s*true', meta)) 1 else
    if (grepl('"fill_value"\\s*:\\s*false', meta)) 0 else NA_real_
  } else num_field(meta, "fill_value")

  scale <- 1; offset <- 0; nodata <- numeric(0)
  if (unpack && nzchar(attrs)) {
    s <- num_field(attrs, "scale_factor"); if (!is.na(s)) scale <- s
    o <- num_field(attrs, "add_offset"); if (!is.na(o)) offset <- o
    nodata <- stats::na.omit(c(num_field(attrs, "_FillValue"),
                               num_field(attrs, "missing_value")))
  }
  ## the array's type: unpacking with scale/offset gives doubles
  out_type <- if (ty$kind == "integer" && (scale != 1 || offset != 0)) "double" else ty$kind
  decode <- function(v) {
    if (length(nodata)) v[v %in% nodata] <- NA
    switch(out_type,
      double = {
        v <- as.double(v)
        if (scale != 1 || offset != 0) v <- v * scale + offset
        v
      },
      integer = as.integer(v),
      logical = as.logical(v))
  }

  ## R dims: reversed for C order
  rev_c <- identical(order, "C")
  d <- as.integer(if (rev_c) rev(shape) else shape)
  cs <- as.integer(if (rev_c) rev(zchunk) else zchunk)
  full <- prod(cs)

  fetch <- function(chunks) {
    lapply(seq_len(nrow(chunks)), function(r) {
      cc <- chunks[r, ]
      key <- paste(if (rev_c) rev(cc) else cc, collapse = sep)
      st <- cc * cs + 1L
      ext <- pmin(cs, d - st + 1L)
      f <- file.path(path, key)
      if (!file.exists(f)) return(decode(rep(fill, prod(ext))))
      raw <- readBin(f, "raw", file.size(f))
      if (comp == "zlib") raw <- memDecompress(raw, type = "gzip")
      v <- readBin(raw, ty$what, n = full, size = ty$size,
                   signed = !isFALSE(ty$signed), endian = "little")
      if (any(ext != cs)) {
        ## Zarr pads edge chunks to full size; clip in R's dim order
        a <- array(v, cs)
        idx <- lapply(ext, seq_len)
        v <- do.call(`[`, c(list(a), idx, list(drop = FALSE)))
      }
      decode(v)
    })
  }
  altarr(d, cs, fetch, type = out_type)
}
