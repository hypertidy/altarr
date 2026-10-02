#' Write a small example Zarr v2 store
#'
#' Writes a zlib-compressed, C-order Zarr v2 array of doubles into `dir`
#' and returns the path, ready for [altarr_zarr_v2()]. The store is made on
#' demand rather than shipped, because Zarr v2 metadata files (`.zarray`)
#' are hidden files, which R packages should not carry.
#'
#' Every value is its own 0-based position in R's column-major order, so a
#' result can be checked by eye: in the array returned by
#' `altarr_zarr_v2()`, element `x[i, j, k]` is
#' `(i - 1) + dim[1] * (j - 1) + dim[1] * dim[2] * (k - 1)`, and `x[n]` is
#' `n - 1`.
#'
#' @param dir directory to write the store into (created if needed).
#' @param dim R dimensions of the array (the Zarr shape is the reverse).
#' @param chunk R chunk shape (the Zarr chunk shape is the reverse). Edge
#'   chunks are padded in the store, as Zarr requires.
#' @return the store path, invisibly.
#' @examples
#' path <- altarr_example_zarr()
#' x <- altarr_zarr_v2(path)
#' dim(x)
#' x[c(1, 2, 71)]   # 0, 1, 70
#' @export
altarr_example_zarr <- function(dir = tempfile("altarr-example-", fileext = ".zarr"),
                                dim = c(70L, 50L, 30L),
                                chunk = c(20L, 16L, 7L)) {
  dim <- as.integer(dim)
  chunk <- rep_len(as.integer(chunk), length(dim))
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  json_int <- function(v) paste0("[", paste(v, collapse = ", "), "]")
  writeLines(c(
    "{",
    sprintf('  "shape": %s,', json_int(rev(dim))),
    sprintf('  "chunks": %s,', json_int(rev(chunk))),
    '  "dtype": "<f8",',
    '  "fill_value": -9999.0,',
    '  "order": "C",',
    '  "filters": null,',
    '  "dimension_separator": ".",',
    '  "compressor": {"id": "zlib", "level": 1},',
    '  "zarr_format": 2',
    "}"), file.path(dir, ".zarray"))
  writeLines("{}", file.path(dir, ".zattrs"))

  stride <- cumprod(c(1, dim[-length(dim)]))
  nch <- ceiling(dim / chunk)
  grid <- as.matrix(expand.grid(lapply(nch, function(n) seq_len(n) - 1L)))
  for (r in seq_len(nrow(grid))) {
    cc <- grid[r, ]
    st <- cc * chunk + 1L
    ## padded full-size chunk: every cell's global 1-based coordinates;
    ## cells past the array edge hold the fill value
    g <- sweep(arrayInd(seq_len(prod(chunk)), chunk), 2, st - 1L, "+")
    inside <- rowSums(sweep(g, 2, dim, ">")) == 0
    pos <- as.vector((g - 1) %*% stride)
    vals <- ifelse(inside, pos, -9999)
    raw <- memCompress(writeBin(as.double(vals), raw(), size = 8L, endian = "little"),
                       "gzip")
    writeBin(raw, file.path(dir, paste(rev(cc), collapse = ".")))
  }
  invisible(dir)
}
