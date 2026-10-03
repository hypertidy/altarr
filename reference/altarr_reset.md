# Reset counters, and optionally drop the chunk cache

Reset counters, and optionally drop the chunk cache

## Usage

``` r
altarr_reset(x, cache = TRUE)
```

## Arguments

- x:

  an altarr array

- cache:

  drop cached chunks too?

## Value

`x`, invisibly.

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
