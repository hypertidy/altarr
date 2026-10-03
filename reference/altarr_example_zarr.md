# Write a small example Zarr v2 store

Writes a zlib-compressed, C-order Zarr v2 array of doubles into `dir`
and returns the path, ready for
[`altarr_zarr_v2()`](https://hypertidy.github.io/altarr/reference/altarr_zarr_v2.md).
The store is made on demand rather than shipped, because Zarr v2
metadata files (`.zarray`) are hidden files, which R packages should not
carry.

## Usage

``` r
altarr_example_zarr(
  dir = tempfile("altarr-example-", fileext = ".zarr"),
  dim = c(70L, 50L, 30L),
  chunk = c(20L, 16L, 7L)
)
```

## Arguments

- dir:

  directory to write the store into (created if needed).

- dim:

  R dimensions of the array (the Zarr shape is the reverse).

- chunk:

  R chunk shape (the Zarr chunk shape is the reverse). Edge chunks are
  padded in the store, as Zarr requires.

## Value

the store path, invisibly.

## Details

Every value is its own 0-based position in R's column-major order, so a
result can be checked by eye: in the array returned by
[`altarr_zarr_v2()`](https://hypertidy.github.io/altarr/reference/altarr_zarr_v2.md),
element `x[i, j, k]` is
`(i - 1) + dim[1] * (j - 1) + dim[1] * dim[2] * (k - 1)`, and `x[n]` is
`n - 1`.

## Examples

``` r
path <- altarr_example_zarr()
x <- altarr_zarr_v2(path)
dim(x)
#> [1] 70 50 30
x[c(1, 2, 71)]   # 0, 1, 70
#> [1]  0  1 70
```
