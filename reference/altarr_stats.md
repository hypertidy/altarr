# Counters and cache state for an altarr array

`elt` counts per-element reads (the `x[i, j, k]` path), `extract_subset`
counts planned subset calls (`x[i]`, `x[cbind(...)]`), `hyperslab`
counts
[`altarr_extract()`](https://hypertidy.github.io/altarr/reference/altarr_extract.md)
calls, `fetch_calls` counts calls to the fetch function (round trips)
and `chunks_fetched` the chunks they returned. `reduce` counts
whole-array [`sum()`](https://rdrr.io/r/base/sum.html),
[`min()`](https://rdrr.io/r/base/Extremes.html) and
[`max()`](https://rdrr.io/r/base/Extremes.html) calls, which stream the
chunk grid in batches of `getOption("altarr.batch_chunks", 64)` chunks
(one fetch call per batch) without caching what they read. `region`
counts contiguous-run reads from functions R iterates by region
([`mean()`](https://rdrr.io/r/base/mean.html),
[`prod()`](https://rdrr.io/r/base/prod.html),
[`anyNA()`](https://rdrr.io/r/base/NA.html), and reductions on R's
wrapper class). `evictions` counts chunks dropped from the cache to keep
it within its budget. Also reported: `cache_bytes` (bytes currently
cached) and `cache_budget` (`getOption("altarr.cache_bytes")`, default
256 MiB). The cache is least recently used first, and shared by an array
and its copies.

## Usage

``` r
altarr_stats(x)
```

## Arguments

- x:

  an altarr array

## Value

a named numeric vector of counters and cache state.

## Examples

``` r
x <- altarr_zarr_v2(altarr_example_zarr())
x[1:5]
#> [1] 0 1 2 3 4
x[1:5]   # the second read comes from the cache
#> [1] 0 1 2 3 4
altarr_stats(x)[c("extract_subset", "fetch_calls", "chunks_cached")]
#> extract_subset    fetch_calls  chunks_cached 
#>              2              1              1 
altarr_reset(x)
altarr_stats(x)[c("fetch_calls", "chunks_cached")]
#>   fetch_calls chunks_cached 
#>             0             0 
```
