# Is this a (still lazy-capable) altarr array?

Is this a (still lazy-capable) altarr array?

## Usage

``` r
is_altarr(x)
```

## Arguments

- x:

  object

## Value

`TRUE` if `x` is an altarr array, or R's wrapper around one.

## Examples

``` r
x <- altarr_zarr_v2(altarr_example_zarr())
is_altarr(x)
#> [1] TRUE
is_altarr(x[1:3])   # a subset is an ordinary vector
#> [1] FALSE
is_altarr(array(1:4, c(2, 2)))
#> [1] FALSE
```
