# The chunk index of a sparse array

`altarr_present()` gives which chunks of the grid the store holds, as a
logical array with one element per chunk (dimensions are the chunk
grid), or `NULL` if the array has no chunk index (every chunk stored).
`altarr_fill()` gives the value of every cell of an absent chunk.

## Usage

``` r
altarr_present(x)

altarr_fill(x)
```

## Arguments

- x:

  an altarr array

## Value

a logical array over the chunk grid, or `NULL`; for `altarr_fill()`, a
length-one vector of the array's type.

## Details

Absent chunks cost nothing: they are never fetched or cached. Indexing
writes `fill` for them, and [`sum()`](https://rdrr.io/r/base/sum.html),
[`min()`](https://rdrr.io/r/base/Extremes.html) and
[`max()`](https://rdrr.io/r/base/Extremes.html) of a double array
account for them from the index alone, without iterating cells.
[`altarr_stats()`](https://hypertidy.github.io/altarr/reference/altarr_stats.md)
reports `chunks_present` (in the index) and `chunks_absent` (absent
chunks that requests touched and answered without a fetch).

## Examples

``` r
x <- altarr_zarr_v2(altarr_example_zarr(sparse = TRUE))
p <- altarr_present(x)
dim(p)
#> [1] 4 4 5
sum(p)        # chunks stored
#> [1] 20
altarr_fill(x)
#> [1] 0
```
