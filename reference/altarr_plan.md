# The chunk plan for a subscript, as a data frame

One row per chunk that `x[i, j, k]` would touch: 0-based chunk
coordinates, plus each chunk's 1-based start and its extent along every
dimension. The plan is a table; the array is what assembling it gives.

## Usage

``` r
altarr_plan(x, ...)
```

## Arguments

- x:

  an altarr array

- ...:

  one subscript per dimension (missing means all)

## Value

a data frame, one row per chunk.

## Details

When the array knows its store's axis order (`store_axes` in
[`altarr()`](https://hypertidy.github.io/altarr/reference/altarr.md),
set by
[`altarr_zarr_v2()`](https://hypertidy.github.io/altarr/reference/altarr_zarr_v2.md)),
each row starts with the chunk's key in the store: `dim_0 ..`, 0-based
chunk indexes in store order. These are the column names of a byterefs
view and of zaro's plans, so a plan joins to them on those columns, one
array at a time. The plan holds no bytes or presence: those come from
the join.

## Examples

``` r
x <- altarr_zarr_v2(altarr_example_zarr())
altarr_plan(x, 1:40, 1:20, 1:3)
#>   dim_0 dim_1 dim_2 d1 d2 d3 d1_start d1_n d2_start d2_n d3_start d3_n
#> 1     0     0     0  0  0  0        1   20        1   16        1    7
#> 2     0     0     1  1  0  0       21   20        1   16        1    7
#> 3     0     1     0  0  1  0        1   20       17   16        1    7
#> 4     0     1     1  1  1  0       21   20       17   16        1    7
altarr_plan(x, 70, , 1)   # a missing subscript means the whole dimension
#>   dim_0 dim_1 dim_2 d1 d2 d3 d1_start d1_n d2_start d2_n d3_start d3_n
#> 1     0     0     3  3  0  0       61   10        1   16        1    7
#> 2     0     1     3  3  1  0       61   10       17   16        1    7
#> 3     0     2     3  3  2  0       61   10       33   16        1    7
#> 4     0     3     3  3  3  0       61   10       49    2        1    7
```
