# Rectangular (hyperslab) extraction with one planned fetch

Same semantics as `x[i, j, k, drop = drop]`, but the per-dimension
subscripts are handed to the ALTREP object whole: the touched chunks are
planned as a cartesian product and fetched in one call. This is what
base R's ArraySubset could do if it offered its normalized subscripts to
an ALTREP method.

## Usage

``` r
altarr_extract(x, ..., drop = TRUE)
```

## Arguments

- x:

  an altarr array

- ...:

  one subscript per dimension (missing means all)

- drop:

  as for `[`

## Value

an ordinary (not lazy) array or vector.

## Examples

``` r
x <- altarr_zarr_v2(altarr_example_zarr())
r <- altarr_extract(x, 1:40, 1:20, 1:3)
dim(r)
#> [1] 40 20  3
identical(r, x[1:40, 1:20, 1:3])
#> [1] TRUE
altarr_extract(x, 1, 1:3, 1)   # dropped to a vector, as `[` would
#> [1]   0  70 140
```
