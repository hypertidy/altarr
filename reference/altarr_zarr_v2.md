# A lazy array over a local Zarr v2 store

A deliberately small reader, to show that a real chunked, compressed
store fits behind the fetch contract in a few lines. Handles Zarr v2
arrays with dtype `<f8`, `<f4`, `<i4`, `<i2`, `|i1`, `<u2`, `|u1` or
`|b1`, compressor `null` or `zlib`, order `C` or `F`, and missing chunk
files (read as `fill_value`). Zarr's padded edge chunks are clipped.

This is a demonstration, not a Zarr implementation: no Zarr v3, no
remote stores, no other codecs. For real stores, use a full Zarr reader
and hand its chunk reads to
[`altarr()`](https://hypertidy.github.io/altarr/reference/altarr.md) as
the fetch function.

## Usage

``` r
altarr_zarr_v2(path, unpack = TRUE)
```

## Arguments

- path:

  directory of the Zarr v2 array (containing `.zarray`)

- unpack:

  apply CF `scale_factor`, `add_offset`, `_FillValue` and
  `missing_value` from `.zattrs`?

## Value

a lazy array, see
[`altarr()`](https://hypertidy.github.io/altarr/reference/altarr.md)

## Details

The array's type follows the dtype: floats give a double array, integers
an integer array, `|b1` a logical array. With `unpack = TRUE`, CF
packing attributes found in `.zattrs` are applied inside the fetch:
values equal to `_FillValue` or `missing_value` become `NA`, and if
`scale_factor` or `add_offset` is present the array is double, holding
the unpacked values. The Zarr `fill_value` itself is not treated as
missing.

A C-order Zarr array of shape `(s1, ..., sn)` is returned with R `dim`
`c(sn, ..., s1)`: C-order bytes are already column-major for the
reversed shape, so no transposition is ever done.

## Examples

``` r
path <- altarr_example_zarr()
x <- altarr_zarr_v2(path)
dim(x)   # the Zarr shape, reversed
#> [1] 70 50 30
x[cbind(70, 50, 30)]
#> [1] 104999
str(x)
#>  num [1:70, 1:50, 1:30] 0 1 2 3 4 5 6 7 8 9 ...
```
