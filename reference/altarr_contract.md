# The fetch contract, and what altarr does with it

What a `fetch` function and the store behind it must guarantee, what
altarr does on its side, and what base R does with a lazy array.

## The fetch function

- It is called as `fetch(chunks)`, where `chunks` is an integer matrix
  with one row per chunk and one column per dimension, holding 0-based
  chunk coordinates. Rows may arrive in any order.

- It returns a list with one vector per row, in row order. Each vector
  holds that chunk's values in column-major (R) order, clipped at the
  array edge: an edge chunk is shorter, never padded.

- Each vector should be of the array's type (`"double"`, `"integer"` or
  `"logical"`); other numeric or logical vectors are coerced as
  [`as.double()`](https://rdrr.io/r/base/double.html),
  [`as.integer()`](https://rdrr.io/r/base/integer.html) or
  [`as.logical()`](https://rdrr.io/r/base/logical.html) would.

- One call is one round trip. altarr asks for as many chunks per call as
  it can plan, so a fetch that reads its chunks concurrently (object
  storage, GDAL) gets the full benefit.

- It runs on R's main thread. Retries, timeouts and concurrency belong
  inside it, and any code it runs on other threads must not call the R
  API.

- An error in `fetch` is an R error raised from wherever the read
  happened: inside `[`, [`sum()`](https://rdrr.io/r/base/sum.html),
  [`mean()`](https://rdrr.io/r/base/mean.html) and so on.

## Sources must be pinned

R assumes a vector's values never change. altarr re-fetches chunks after
they are evicted from the cache, and a saved recipe re-reads its source
when loaded later. So the source behind `fetch` must be immutable: a
snapshot (an Icechunk snapshot id, a versioned object), a fixed set of
chunk references (kerchunk, blocklist), or content-addressed chunks. A
mutable store can silently return different values for the same element
within one session.

## Saving arrays (recipes)

[`saveRDS()`](https://rdrr.io/r/base/readRDS.html) writes the recipe
(dim, chunk shape, type and the fetch function), never the values. The
fetch function travels with its environment, which brings two traps:

- A fetch defined at top level refers to global variables, and the
  global environment is saved as a reference, not its contents. The
  recipe loads, but reading fails in a new session with "object not
  found".

- A fetch built inside a function carries that function's environment.
  Arguments are promises until used, so an unforced argument still
  points back at the caller's variable.

Build fetch functions in a small factory that
[`force()`](https://rdrr.io/r/base/force.html)s what it needs: a path or
URL and a few parameters, not data. See the example.

## What base R does with a lazy array

Measured on R 4.3 with materialization refused, so every attempt shows:

- Planned (one fetch call per batch of chunks)::

  `x[i]` (including logical and negative subscripts),
  `x[cbind(i, j, k)]`,
  [`altarr_extract()`](https://hypertidy.github.io/altarr/reference/altarr_extract.md),
  [`sum()`](https://rdrr.io/r/base/sum.html),
  [`min()`](https://rdrr.io/r/base/Extremes.html),
  [`max()`](https://rdrr.io/r/base/Extremes.html),
  [`mean()`](https://rdrr.io/r/base/mean.html),
  [`prod()`](https://rdrr.io/r/base/prod.html),
  [`anyNA()`](https://rdrr.io/r/base/NA.html) (which stops at the first
  `NA`), [`which()`](https://rdrr.io/r/base/which.html) on logical
  arrays, and [`str()`](https://rdrr.io/r/utils/str.html).

- Element by element (correct, lazy, one chunk per round trip)::

  `x[i, j, k]` (until R offers an array-subset hook), `x[[i]]`,
  [`head()`](https://rdrr.io/r/utils/head.html) on an array, and
  [`is.na()`](https://rdrr.io/r/base/NA.html), so also the
  [`is.na()`](https://rdrr.io/r/base/NA.html) pass in
  `mean(na.rm = TRUE)`,
  [`summary()`](https://rdrr.io/r/base/summary.html) and
  [`quantile()`](https://rdrr.io/r/stats/quantile.html).

- Materializes the whole array::

  printing, arithmetic and comparison (`x + 1`, `x > 0`), maths
  functions, [`range()`](https://rdrr.io/r/base/range.html),
  [`c()`](https://rdrr.io/r/base/c.html),
  [`aperm()`](https://rdrr.io/r/base/aperm.html),
  [`apply()`](https://rdrr.io/r/base/apply.html),
  [`colSums()`](https://rdrr.io/r/base/colSums.html) and relatives, and
  assignment (`x[1] <- v`). Refused above
  `getOption("altarr.max_materialize")` values.

- Reads nothing::

  [`dim()`](https://rdrr.io/r/base/dim.html),
  [`length()`](https://rdrr.io/r/base/length.html), `dimnames<-`,
  [`identical()`](https://rdrr.io/r/base/identical.html),
  [`saveRDS()`](https://rdrr.io/r/base/readRDS.html), copying
  (`y <- x`), and [`as.vector()`](https://rdrr.io/r/base/vector.html),
  which stays lazy.

## Options

- `altarr.cache_bytes`:

  chunk cache budget per array, in bytes (default 256 MiB). Least
  recently used chunks are evicted first; a copy shares its original's
  cache.

- `altarr.batch_chunks`:

  chunks per fetch call for whole-array passes: reductions, scans and
  materialization (default 64).

- `altarr.max_materialize`:

  the most values a whole-array operation may materialize (default 1e6).
  It decides only whether materializing is allowed; the operation
  triggers it, not the size.

## Known limits

- Lazy reads, not lazy computation: arithmetic materializes.

- `x[i, j, k]` reads element by element until R's `ArraySubset` offers
  its subscripts to ALTREP;
  [`altarr_extract()`](https://hypertidy.github.io/altarr/reference/altarr_extract.md)
  shows what that would give.

- Dimension names must be character, as for any R array.

## Examples

``` r
## a fetch factory: the recipe carries a path and parameters, not data
make_fetch <- function(path, dim, chunk) {
  force(path); force(dim); force(chunk)
  function(chunks) {
    lapply(seq_len(nrow(chunks)), function(r) {
      start <- chunks[r, ] * chunk + 1L
      n <- pmin(chunk, dim - start + 1L)  # clipped at the edge
      rep(nchar(path), prod(n))           # stand-in for reading 'path'
    })
  }
}
d <- c(40L, 30L); cs <- c(16L, 16L)
x <- altarr(d, cs, make_fetch("s3://bucket/array.zarr", d, cs))
x[cbind(c(1, 40), c(1, 30))]
#> [1] 22 22
f <- tempfile(fileext = ".rds")
saveRDS(x, f)
file.size(f)   # a few hundred bytes
#> [1] 117031
```
