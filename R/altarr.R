#' Create a lazily-read chunked array
#'
#' Returns an ordinary double, integer or logical vector with a `dim`
#' attribute and no class. It is an ALTREP object: values are obtained chunk
#' by chunk from `fetch` only when base R asks for them.
#'
#' @param dim integer dimensions.
#' @param chunk integer chunk shape (recycled to `length(dim)`).
#' @param fetch a function taking an integer matrix of 0-based chunk
#'   coordinates (one row per chunk, one column per dimension) and returning
#'   a list of vectors, one per row, in column-major order and clipped at the
#'   array edge. Chunks should be of the array's `type`; other numeric or
#'   logical vectors are coerced as `as.double()`, `as.integer()` or
#'   `as.logical()` would.
#' @param dimnames optional dimnames.
#' @param type the array's type: `"double"`, `"integer"` or `"logical"`.
#' @param store_axes optional, for an array whose chunk grid is its store's
#'   own chunk grid: the R dimension of each stored axis, in the store's
#'   order. That is `rev(seq_along(dim))` for a C-order store (such as Zarr)
#'   whose shape the array reverses, and `seq_along(dim)` when the store and
#'   R agree. [altarr_plan()] then names each chunk by its key in the store,
#'   `dim_0 ..`, as byterefs and zaro do. Leave it `NULL` when the grid is
#'   not the store's (a window, a view, a rechunking): the plan then has no
#'   keys. It changes nothing about fetching: `fetch` is always given chunk
#'   coordinates in R's dimension order.
#' @return a lazy array.
#' @examples
#' ## a 10 x 7 array in 4 x 3 chunks; each value is its own position
#' d <- c(10L, 7L); cs <- c(4L, 3L)
#' fetch <- function(chunks) {
#'   lapply(seq_len(nrow(chunks)), function(r) {
#'     start <- chunks[r, ] * cs + 1L
#'     end <- pmin(start + cs - 1L, d)   # clipped at the edge
#'     i <- start[1]:end[1]; j <- start[2]:end[2]
#'     as.vector(outer(i, (j - 1) * d[1], "+"))
#'   })
#' }
#' x <- altarr(d, cs, fetch)
#' x[c(1, 70)]
#' x[cbind(10, 7)]
#' altarr_stats(x)[c("fetch_calls", "chunks_fetched")]
#' ## the same chunks as an integer array (values are coerced)
#' xi <- altarr(d, cs, fetch, type = "integer")
#' typeof(xi)
#' sum(xi)
#' ## a store that keeps the axes in the other order (C order) declares it,
#' ## and the plan carries the store's chunk keys
#' xs <- altarr(d, cs, fetch, store_axes = 2:1)
#' altarr_plan(xs, 9:10, 1:4)
#' @export
altarr <- function(dim, chunk, fetch, dimnames = NULL,
                   type = c("double", "integer", "logical"),
                   store_axes = NULL) {
  type <- match.arg(type)
  dim <- as.integer(dim)
  chunk <- rep_len(as.integer(chunk), length(dim))
  fetch <- match.fun(fetch)
  if (!is.null(store_axes)) {
    if (!is.numeric(store_axes) || anyNA(store_axes) ||
        !setequal(store_axes, seq_along(dim)) ||
        length(store_axes) != length(dim)) {
      stop("'store_axes' must be a permutation of 1:", length(dim),
           " (the R dimension of each stored axis, in store order)",
           call. = FALSE)
    }
    store_axes <- as.integer(store_axes)
  }
  x <- .Call(C_altarr_new, dim, chunk, fetch, type, store_axes)
  if (!is.null(dimnames)) dimnames(x) <- dimnames
  x
}

#' Is this a (still lazy-capable) altarr array?
#' @param x object
#' @return `TRUE` if `x` is an altarr array, or R's wrapper around one.
#' @examples
#' x <- altarr_zarr_v2(altarr_example_zarr())
#' is_altarr(x)
#' is_altarr(x[1:3])   # a subset is an ordinary vector
#' is_altarr(array(1:4, c(2, 2)))
#' @export
is_altarr <- function(x) .Call(C_altarr_is, x)

#' Counters and cache state for an altarr array
#'
#' `elt` counts per-element reads (the `x[i, j, k]` path), `extract_subset`
#' counts planned subset calls (`x[i]`, `x[cbind(...)]`), `hyperslab` counts
#' [altarr_extract()] calls, `fetch_calls` counts calls to the fetch function
#' (round trips) and `chunks_fetched` the chunks they returned. `reduce`
#' counts whole-array `sum()`, `min()` and `max()` calls, which stream the
#' chunk grid in batches of `getOption("altarr.batch_chunks", 64)` chunks
#' (one fetch call per batch) without caching what they read.
#' `region` counts contiguous-run reads from functions R iterates by region
#' (`mean()`, `prod()`, `anyNA()`, and reductions on R's wrapper class).
#' `evictions` counts chunks dropped from the cache to keep it within
#' its budget. Also reported: `cache_bytes` (bytes currently cached) and
#' `cache_budget` (`getOption("altarr.cache_bytes")`, default 256 MiB).
#' The cache is least recently used first, and shared by an array and
#' its copies.
#' @param x an altarr array
#' @return a named numeric vector of counters and cache state.
#' @examples
#' x <- altarr_zarr_v2(altarr_example_zarr())
#' x[1:5]
#' x[1:5]   # the second read comes from the cache
#' altarr_stats(x)[c("extract_subset", "fetch_calls", "chunks_cached")]
#' altarr_reset(x)
#' altarr_stats(x)[c("fetch_calls", "chunks_cached")]
#' @export
altarr_stats <- function(x) .Call(C_altarr_info, x)

#' Reset counters, and optionally drop the chunk cache
#' @param x an altarr array
#' @param cache drop cached chunks too?
#' @return `x`, invisibly.
#' @examples
#' x <- altarr_zarr_v2(altarr_example_zarr())
#' x[1:5]
#' x[1:5]   # the second read comes from the cache
#' altarr_stats(x)[c("extract_subset", "fetch_calls", "chunks_cached")]
#' altarr_reset(x)
#' altarr_stats(x)[c("fetch_calls", "chunks_cached")]
#' @export
altarr_reset <- function(x, cache = TRUE) {
  invisible(.Call(C_altarr_reset, x, cache))
}

## Normalize one subscript per dimension using base R's own rules, by
## indexing a (named) sequence. Returns a list of 1-based integer vectors.
.norm_subs <- function(x, dots, env) {
  d <- dim(x)
  if (length(dots) != length(d)) stop("incorrect number of dimensions")
  dn <- dimnames(x)
  out <- vector("list", length(d))
  for (k in seq_along(d)) {
    s <- seq_len(d[k])
    if (!is.null(dn[[k]])) names(s) <- dn[[k]]
    if (identical(dots[[k]], quote(expr = ))) {
      out[[k]] <- unname(s)
    } else {
      i <- eval(dots[[k]], env)
      if (is.numeric(i) && any(i > d[k], na.rm = TRUE)) {
        stop("subscript out of bounds")
      }
      ix <- s[i]
      if (is.character(i) && anyNA(ix[!is.na(i)])) {
        stop("subscript out of bounds")
      }
      out[[k]] <- unname(as.integer(ix))
    }
  }
  out
}

#' Rectangular (hyperslab) extraction with one planned fetch
#'
#' Same semantics as `x[i, j, k, drop = drop]`, but the per-dimension
#' subscripts are handed to the ALTREP object whole: the touched chunks are
#' planned as a cartesian product and fetched in one call. This is what
#' base R's ArraySubset could do if it offered its normalized subscripts to
#' an ALTREP method.
#'
#' @param x an altarr array
#' @param ... one subscript per dimension (missing means all)
#' @param drop as for `[`
#' @return an ordinary (not lazy) array or vector.
#' @examples
#' x <- altarr_zarr_v2(altarr_example_zarr())
#' r <- altarr_extract(x, 1:40, 1:20, 1:3)
#' dim(r)
#' identical(r, x[1:40, 1:20, 1:3])
#' altarr_extract(x, 1, 1:3, 1)   # dropped to a vector, as `[` would
#' @export
altarr_extract <- function(x, ..., drop = TRUE) {
  subs <- .norm_subs(x, as.list(substitute(list(...)))[-1L], parent.frame())
  res <- .Call(C_altarr_hyperslab, x, subs)
  dn <- dimnames(x)
  if (!is.null(dn)) {
    ndn <- vector("list", length(subs))
    for (k in seq_along(subs)) {
      if (!is.null(dn[[k]])) ndn[k] <- list(dn[[k]][subs[[k]]])
    }
    names(ndn) <- names(dn)
    dimnames(res) <- ndn
  }
  if (drop) res <- drop(res)
  res
}

#' The chunk plan for a subscript, as a data frame
#'
#' One row per chunk that `x[i, j, k]` would touch: 0-based chunk
#' coordinates, plus each chunk's 1-based start and its extent along every
#' dimension. The plan is a table; the array is what assembling it gives.
#'
#' When the array knows its store's axis order (`store_axes` in [altarr()],
#' set by [altarr_zarr_v2()]), each row starts with the chunk's key in the
#' store: `dim_0 ..`, 0-based chunk indexes in store order. These are the
#' column names of a byterefs view and of zaro's plans, so a plan joins to
#' them on those columns, one array at a time. The plan holds no bytes or
#' presence: those come from the join.
#'
#' @inheritParams altarr_extract
#' @return a data frame, one row per chunk.
#' @examples
#' x <- altarr_zarr_v2(altarr_example_zarr())
#' altarr_plan(x, 1:40, 1:20, 1:3)
#' altarr_plan(x, 70, , 1)   # a missing subscript means the whole dimension
#' @export
altarr_plan <- function(x, ...) {
  subs <- .norm_subs(x, as.list(substitute(list(...)))[-1L], parent.frame())
  d <- dim(x)
  chunk <- .Call(C_altarr_chunk, x)
  nm <- names(dimnames(x))
  if (is.null(nm) || any(!nzchar(nm))) nm <- paste0("d", seq_along(d))
  cc <- Map(function(s, cs) sort(unique((stats::na.omit(s) - 1L) %/% cs)),
            subs, chunk)
  names(cc) <- nm
  plan <- expand.grid(cc, KEEP.OUT.ATTRS = FALSE)
  for (k in seq_along(d)) {
    start <- plan[[k]] * chunk[k] + 1L
    plan[[paste0(nm[k], "_start")]] <- start
    plan[[paste0(nm[k], "_n")]] <- pmin(chunk[k], d[k] - start + 1L)
  }
  axes <- .Call(C_altarr_store, x)
  if (!is.null(axes)) {
    keys <- lapply(axes, function(a) plan[[a]])
    names(keys) <- paste0("dim_", seq_along(axes) - 1L)
    plan <- cbind(as.data.frame(keys), plan)
  }
  plan
}
