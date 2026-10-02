#' Create a lazily-read chunked array
#'
#' Returns an ordinary double vector with a `dim` attribute and no class.
#' It is an ALTREP object: values are obtained chunk by chunk from `fetch`
#' only when base R asks for them.
#'
#' @param dim integer dimensions.
#' @param chunk integer chunk shape (recycled to `length(dim)`).
#' @param fetch a function taking an integer matrix of 0-based chunk
#'   coordinates (one row per chunk, one column per dimension) and returning
#'   a list of numeric vectors, one per row, in column-major order and
#'   clipped at the array edge.
#' @param dimnames optional dimnames.
#' @return a lazy array.
#' @export
altarr <- function(dim, chunk, fetch, dimnames = NULL) {
  dim <- as.integer(dim)
  chunk <- rep_len(as.integer(chunk), length(dim))
  fetch <- match.fun(fetch)
  x <- .Call(C_altarr_new, dim, chunk, fetch)
  if (!is.null(dimnames)) dimnames(x) <- dimnames
  x
}

#' Is this a (still lazy-capable) altarr array?
#' @param x object
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
#' @export
altarr_stats <- function(x) .Call(C_altarr_info, x)

#' Reset counters, and optionally drop the chunk cache
#' @param x an altarr array
#' @param cache drop cached chunks too?
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
#' @inheritParams altarr_extract
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
  plan
}
