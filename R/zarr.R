#' A lazy array over a local Zarr v2 store
#'
#' A deliberately small reader, to show that a real chunked, compressed
#' store fits behind the fetch contract in a few lines. Handles Zarr v2
#' arrays with dtype `<f8`, `<f4`, `<i4`, `<i2` or `|u1`, compressor `null`
#' or `zlib`, order `C` or `F`, and missing chunk files (read as
#' `fill_value`). Zarr's padded edge chunks are clipped.
#'
#' With `unpack = TRUE`, CF packing attributes found in `.zattrs` are
#' applied inside the fetch: values equal to `_FillValue` or
#' `missing_value` become `NA`, then `scale_factor` and `add_offset` are
#' applied. The Zarr `fill_value` itself is not treated as missing.
#'
#' A C-order Zarr array of shape `(s1, ..., sn)` is returned with R `dim`
#' `c(sn, ..., s1)`: C-order bytes are already column-major for the
#' reversed shape, so no transposition is ever done.
#'
#' @param path directory of the Zarr v2 array (containing `.zarray`)
#' @param unpack apply CF `scale_factor`, `add_offset`, `_FillValue` and
#'   `missing_value` from `.zattrs`?
#' @return a lazy array, see [altarr()]
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
  fill <- num_field(meta, "fill_value")

  scale <- 1; offset <- 0; nodata <- numeric(0)
  if (unpack && nzchar(attrs)) {
    s <- num_field(attrs, "scale_factor"); if (!is.na(s)) scale <- s
    o <- num_field(attrs, "add_offset"); if (!is.na(o)) offset <- o
    nodata <- stats::na.omit(c(num_field(attrs, "_FillValue"),
                               num_field(attrs, "missing_value")))
  }
  decode <- function(v) {
    v <- as.double(v)
    if (length(nodata)) v[v %in% nodata] <- NA_real_
    if (scale != 1 || offset != 0) v <- v * scale + offset
    v
  }

  ty <- switch(dtype,
    "<f8" = list(what = "double", size = 8L),
    "<f4" = list(what = "double", size = 4L),
    "<i4" = list(what = "integer", size = 4L),
    "<i2" = list(what = "integer", size = 2L),
    "|u1" = list(what = "integer", size = 1L, signed = FALSE),
    stop("unsupported dtype ", dtype))
  if (!comp %in% c("none", "zlib")) stop("unsupported compressor ", comp)

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
  altarr(d, cs, fetch)
}
