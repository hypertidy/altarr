# A lazy subset that stays lazy (and sparse)

`altarr_view(x, i, j, k)` is `x[i, j, k, drop = FALSE]` as a new lazy
array: nothing is read when it is made. Its chunks have the same shape
as `x`'s, laid over the subset, and each is read with one
[`altarr_extract()`](https://hypertidy.github.io/altarr/reference/altarr_extract.md)
of `x`. If `x` has a chunk index (`present`), the view gets one too: a
view chunk is absent when every chunk of `x` it draws from is absent, so
a subset of a sparse array is still sparse, and
[`sum()`](https://rdrr.io/r/base/sum.html) of it is still answered from
the index for the empty parts.

## Usage

``` r
altarr_view(x, ...)
```

## Arguments

- x:

  an altarr array

- ...:

  one subscript per dimension (missing means all)

## Value

a lazy array (an altarr), with `dim` the lengths of the subscripts.
Dimnames are kept.

## Details

This is what an `ArraySubset` ALTREP method could return instead of a
dense result: a method that receives `x[i, j, k]`'s normalized
subscripts can hand back any vector, including another lazy one.

## Examples

``` r
x <- altarr_zarr_v2(altarr_example_zarr(sparse = TRUE))
v <- altarr_view(x, 1:50, , 1:10)
is_altarr(v)
#> [1] TRUE
sum(altarr_present(v)); length(altarr_present(v))
#> [1] 6
#> [1] 24
all.equal(sum(v, na.rm = TRUE), sum(x[1:50, , 1:10], na.rm = TRUE))
#> [1] TRUE
```
