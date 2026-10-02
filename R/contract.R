#' The fetch contract, and what altarr does with it
#'
#' What a `fetch` function and the store behind it must guarantee, what
#' altarr does on its side, and what base R does with a lazy array.
#'
#' @section The fetch function:
#' \itemize{
#'   \item It is called as `fetch(chunks)`, where `chunks` is an integer
#'     matrix with one row per chunk and one column per dimension, holding
#'     0-based chunk coordinates. Rows may arrive in any order.
#'   \item It returns a list with one vector per row, in row order. Each
#'     vector holds that chunk's values in column-major (R) order, clipped at
#'     the array edge: an edge chunk is shorter, never padded.
#'   \item Each vector should be of the array's type (`"double"`,
#'     `"integer"` or `"logical"`); other numeric or logical vectors are
#'     coerced as `as.double()`, `as.integer()` or `as.logical()` would.
#'   \item One call is one round trip. altarr asks for as many chunks per
#'     call as it can plan, so a fetch that reads its chunks concurrently
#'     (object storage, GDAL) gets the full benefit.
#'   \item It runs on R's main thread. Retries, timeouts and concurrency
#'     belong inside it, and any code it runs on other threads must not call
#'     the R API.
#'   \item An error in `fetch` is an R error raised from wherever the read
#'     happened: inside `[`, `sum()`, `mean()` and so on.
#' }
#'
#' @section Sources must be pinned:
#' R assumes a vector's values never change. altarr re-fetches chunks after
#' they are evicted from the cache, and a saved recipe re-reads its source
#' when loaded later. So the source behind `fetch` must be immutable: a
#' snapshot (an Icechunk snapshot id, a versioned object), a fixed set of
#' chunk references (kerchunk, blocklist), or content-addressed chunks. A
#' mutable store can silently return different values for the same element
#' within one session.
#'
#' @section Saving arrays (recipes):
#' `saveRDS()` writes the recipe (dim, chunk shape, type and the fetch
#' function), never the values. The fetch function travels with its
#' environment, which brings two traps:
#' \itemize{
#'   \item A fetch defined at top level refers to global variables, and the
#'     global environment is saved as a reference, not its contents. The
#'     recipe loads, but reading fails in a new session with "object not
#'     found".
#'   \item A fetch built inside a function carries that function's
#'     environment. Arguments are promises until used, so an unforced
#'     argument still points back at the caller's variable.
#' }
#' Build fetch functions in a small factory that `force()`s what it needs:
#' a path or URL and a few parameters, not data. See the example.
#'
#' @section What base R does with a lazy array:
#' Measured on R 4.3 with materialization refused, so every attempt shows:
#' \describe{
#'   \item{Planned (one fetch call per batch of chunks):}{`x[i]` (including
#'     logical and negative subscripts), `x[cbind(i, j, k)]`,
#'     [altarr_extract()], `sum()`, `min()`, `max()`, `mean()`, `prod()`,
#'     `anyNA()` (which stops at the first `NA`), `which()` on logical
#'     arrays, and `str()`.}
#'   \item{Element by element (correct, lazy, one chunk per round trip):}{
#'     `x[i, j, k]` (until R offers an array-subset hook), `x[[i]]`,
#'     `head()` on an array, and `is.na()`, so also the `is.na()` pass in
#'     `mean(na.rm = TRUE)`, `summary()` and `quantile()`.}
#'   \item{Materializes the whole array:}{printing, arithmetic and
#'     comparison (`x + 1`, `x > 0`), maths functions, `range()`, `c()`,
#'     `aperm()`, `apply()`, `colSums()` and relatives, and assignment
#'     (`x[1] <- v`). Refused above `getOption("altarr.max_materialize")`
#'     values.}
#'   \item{Reads nothing:}{`dim()`, `length()`, `dimnames<-`, `identical()`,
#'     `saveRDS()`, copying (`y <- x`), and `as.vector()`, which stays
#'     lazy.}
#' }
#'
#' @section Options:
#' \describe{
#'   \item{`altarr.cache_bytes`}{chunk cache budget per array, in bytes
#'     (default 256 MiB). Least recently used chunks are evicted first; a
#'     copy shares its original's cache.}
#'   \item{`altarr.batch_chunks`}{chunks per fetch call for whole-array
#'     passes: reductions, scans and materialization (default 64).}
#'   \item{`altarr.max_materialize`}{the most values a whole-array
#'     operation may materialize (default 1e6). It decides only whether
#'     materializing is allowed; the operation triggers it, not the size.}
#' }
#'
#' @section Known limits:
#' \itemize{
#'   \item Lazy reads, not lazy computation: arithmetic materializes.
#'   \item `x[i, j, k]` reads element by element until R's `ArraySubset`
#'     offers its subscripts to ALTREP; [altarr_extract()] shows what that
#'     would give.
#'   \item Dimension names must be character, as for any R array.
#' }
#'
#' @name altarr_contract
#' @aliases altarr-contract
#' @examples
#' ## a fetch factory: the recipe carries a path and parameters, not data
#' make_fetch <- function(path, dim, chunk) {
#'   force(path); force(dim); force(chunk)
#'   function(chunks) {
#'     lapply(seq_len(nrow(chunks)), function(r) {
#'       start <- chunks[r, ] * chunk + 1L
#'       n <- pmin(chunk, dim - start + 1L)  # clipped at the edge
#'       rep(nchar(path), prod(n))           # stand-in for reading 'path'
#'     })
#'   }
#' }
#' d <- c(40L, 30L); cs <- c(16L, 16L)
#' x <- altarr(d, cs, make_fetch("s3://bucket/array.zarr", d, cs))
#' x[cbind(c(1, 40), c(1, 30))]
#' f <- tempfile(fileext = ".rds")
#' saveRDS(x, f)
#' file.size(f)   # a few hundred bytes
NULL
