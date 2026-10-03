# Walkthrough: what base R asks a lazy array for

An altarr array is an ordinary R array (a vector with a `dim` attribute
and no class) whose values live in chunks somewhere else. Base R does
not know it is lazy. This walkthrough runs ordinary R code against one
and shows, after each step, what R actually asked the array for.

For the background, and the case for a small change in base R, read the
post [What R does today with an ALTREP that has a dim and no
class](https://hypertidy.org/posts/2026-10-01_altrep-dim-no-class/). The
full contract for fetch functions is in
[`?altarr_contract`](https://hypertidy.github.io/altarr/reference/altarr_contract.md).

## The example store

[`altarr_example_zarr()`](https://hypertidy.github.io/altarr/reference/altarr_example_zarr.md)
writes a small Zarr v2 store (70 x 50 x 30, chunks 20 x 16 x 7, zlib
compressed) to a temporary directory. Every value is its own 0-based
position, so any result can be checked by eye:
`x[i, j, k] == (i-1) + 70*(j-1) + 3500*(k-1)`.

After each step, `seen()` prints the counters that moved since the
previous step:

- `elt`: single-element reads (the `x[i, j, k]` path)
- `extract_subset`: planned subset requests (`x[i]`, `x[cbind(...)]`)
- `hyperslab`:
  [`altarr_extract()`](https://hypertidy.github.io/altarr/reference/altarr_extract.md)
  calls
- `fetch_calls`: calls to the fetch function, that is, round trips to
  the store
- `chunks_fetched`: chunks those calls returned
- `materialize`: whole-array reads (printing, arithmetic, …)

``` r

library(altarr)

seen <- function(x) {
  s <- altarr_stats(x)
  keep <- c("elt", "extract_subset", "hyperslab", "fetch_calls",
            "chunks_fetched", "materialize")
  print(s[keep])
  cat(sprintf("chunks now cached: %d of %d   materialized: %s\n",
              s[["chunks_cached"]], s[["chunks_total"]],
              if (s[["materialized"]] == 1) "YES" else "no"))
  altarr_reset(x, cache = FALSE)   # zero the counters, keep the cache
  invisible(s)
}
```

## 1. Opening a store reads nothing

``` r

path <- altarr_example_zarr()
x <- altarr_zarr_v2(path)
dim(x)
#> [1] 70 50 30
length(x)
#> [1] 105000
class(x)    # "array": no class of its own
#> [1] "array"
seen(x)
#>            elt extract_subset      hyperslab    fetch_calls chunks_fetched 
#>              0              0              0              0              0 
#>    materialize 
#>              0 
#> chunks now cached: 0 of 80   materialized: no
```

## 2. One value reads one chunk

``` r

x[1]
#> [1] 0
seen(x)
#>            elt extract_subset      hyperslab    fetch_calls chunks_fetched 
#>              0              1              0              1              1 
#>    materialize 
#>              0 
#> chunks now cached: 1 of 80   materialized: no
```

## 3. The cache: reading it again is free

``` r

x[1:5]
#> [1] 0 1 2 3 4
seen(x)
#>            elt extract_subset      hyperslab    fetch_calls chunks_fetched 
#>              0              1              0              0              0 
#>    materialize 
#>              0 
#> chunks now cached: 1 of 80   materialized: no
```

## 4. Points: `x[cbind(i, j, k)]` is one planned request

Matrix indexing reaches altarr as a single request, so all the chunks it
touches go to the store in one fetch call.

``` r

pts <- cbind(c(70, 35, 1), c(50, 25, 1), c(30, 15, 30))
x[pts]
#> [1] 104999  50714 101500
seen(x)
#>            elt extract_subset      hyperslab    fetch_calls chunks_fetched 
#>              0              1              0              1              3 
#>    materialize 
#>              0 
#> chunks now cached: 4 of 80   materialized: no
```

## 5. A rectangle: `x[i, j, k]` reads element by element

Base R’s `ArraySubset` asks for each element in turn. The result is
correct and still lazy (each chunk is fetched once, then served from the
cache), but there is one round trip per chunk and no chance to plan.

``` r

altarr_reset(x)   # drop the cache too, for a fair count
r1 <- x[1:40, 1:20, 1:3]
seen(x)
#>            elt extract_subset      hyperslab    fetch_calls chunks_fetched 
#>           2400              0              0              4              4 
#>    materialize 
#>              0 
#> chunks now cached: 4 of 80   materialized: no
```

## 6. The same rectangle, planned

[`altarr_extract()`](https://hypertidy.github.io/altarr/reference/altarr_extract.md)
takes the same subscripts and plans the read. This is what a hook in R’s
`ArraySubset` would give `x[i, j, k]` for free.

``` r

altarr_reset(x)
r2 <- altarr_extract(x, 1:40, 1:20, 1:3)
identical(r1, r2)
#> [1] TRUE
seen(x)
#>            elt extract_subset      hyperslab    fetch_calls chunks_fetched 
#>              0              0              1              1              4 
#>    materialize 
#>              0 
#> chunks now cached: 4 of 80   materialized: no
altarr_plan(x, 1:40, 1:20, 1:3)
#>   d1 d2 d3 d1_start d1_n d2_start d2_n d3_start d3_n
#> 1  0  0  0        1   20        1   16        1    7
#> 2  1  0  0       21   20        1   16        1    7
#> 3  0  1  0        1   20       17   16        1    7
#> 4  1  1  0       21   20       17   16        1    7
```

## 7. Materialization: when R wants all the data

Some operations need a pointer to the whole array: printing, arithmetic,
most of [`apply()`](https://rdrr.io/r/base/apply.html). Then altarr
reads every chunk and keeps the full array. The operation triggers this,
not the size. The option `altarr.max_materialize` (default 1e6 values)
only decides whether it is allowed. This array has 105,000 values, under
the limit.

``` r

altarr_reset(x)
y2 <- x * 2
seen(x)   # batches of getOption("altarr.batch_chunks", 64)
#>            elt extract_subset      hyperslab    fetch_calls chunks_fetched 
#>              0              0              0              2             80 
#>    materialize 
#>              1 
#> chunks now cached: 0 of 80   materialized: YES
x[1:3]    # from memory now: no counters move
#> [1] 0 1 2
seen(x)
#>            elt extract_subset      hyperslab    fetch_calls chunks_fetched 
#>              0              0              0              0              0 
#>    materialize 
#>              0 
#> chunks now cached: 0 of 80   materialized: YES
```

Typing `x` at the console would do the same, because
[`print()`](https://rdrr.io/r/base/print.html) asks for the whole array.

## 8. With a lower limit, materializing is refused

``` r

x2 <- altarr_zarr_v2(path)
op <- options(altarr.max_materialize = 1e4)
try(x2 * 2)
#> Error in try(x2 * 2) : 
#>   altarr: refusing to materialize 105000 values (option altarr.max_materialize = 10000); subset first, or raise the option
x2[1:3]   # indexing still works
#> [1] 0 1 2
seen(x2)
#>            elt extract_subset      hyperslab    fetch_calls chunks_fetched 
#>              0              1              0              1              1 
#>    materialize 
#>              0 
#> chunks now cached: 1 of 80   materialized: no
options(op)
```

## 9. Copies stay lazy until changed

``` r

x3 <- altarr_zarr_v2(path)
y <- x3                  # no copy, no read
y[1, 1, 1] <- -1         # changing y materializes y only
c(y[1, 1, 1], x3[1, 1, 1])
#> [1] -1  0
seen(x3)
#>            elt extract_subset      hyperslab    fetch_calls chunks_fetched 
#>              1              0              0              3             81 
#>    materialize 
#>              1 
#> chunks now cached: 1 of 80   materialized: no
```

A copy shares its original’s recipe, counters and chunk cache, so the
counters include `y`’s materialization. Materializing fills `y`
directly, not through the shared cache, so `x3`’s cache holds only the
chunk `x3` itself read. The cache is bounded: see
`getOption("altarr.cache_bytes")` and `evictions` in
[`altarr_stats()`](https://hypertidy.github.io/altarr/reference/altarr_stats.md).

## 10. Saving stores the recipe, not the data

``` r

f <- tempfile(fileext = ".rds")
saveRDS(x3, f)
file.size(f)   # the path, shape and chunking, not 105,000 values
#> [1] 4943
x4 <- readRDS(f)
x4[pts]
#> [1] 104999  50714 101500
```

## Where to go next

- [`?altarr_contract`](https://hypertidy.github.io/altarr/reference/altarr_contract.md):
  what a fetch function must do, which base R operations are planned,
  element-wise or materializing, and the options.
- [`?altarr`](https://hypertidy.github.io/altarr/reference/altarr.md):
  build a lazy array over any store from a fetch function.
- The [hypertidy
  post](https://hypertidy.org/posts/2026-10-01_altrep-dim-no-class/):
  the proposal for base R.
