# Create a lazily-read chunked array

Returns an ordinary double, integer or logical vector with a `dim`
attribute and no class. It is an ALTREP object: values are obtained
chunk by chunk from `fetch` only when base R asks for them.

## Usage

``` r
altarr(
  dim,
  chunk,
  fetch,
  dimnames = NULL,
  type = c("double", "integer", "logical")
)
```

## Arguments

- dim:

  integer dimensions.

- chunk:

  integer chunk shape (recycled to `length(dim)`).

- fetch:

  a function taking an integer matrix of 0-based chunk coordinates (one
  row per chunk, one column per dimension) and returning a list of
  vectors, one per row, in column-major order and clipped at the array
  edge. Chunks should be of the array's `type`; other numeric or logical
  vectors are coerced as
  [`as.double()`](https://rdrr.io/r/base/double.html),
  [`as.integer()`](https://rdrr.io/r/base/integer.html) or
  [`as.logical()`](https://rdrr.io/r/base/logical.html) would.

- dimnames:

  optional dimnames.

- type:

  the array's type: `"double"`, `"integer"` or `"logical"`.

## Value

a lazy array.

## Examples

``` r
## a 10 x 7 array in 4 x 3 chunks; each value is its own position
d <- c(10L, 7L); cs <- c(4L, 3L)
fetch <- function(chunks) {
  lapply(seq_len(nrow(chunks)), function(r) {
    start <- chunks[r, ] * cs + 1L
    end <- pmin(start + cs - 1L, d)   # clipped at the edge
    i <- start[1]:end[1]; j <- start[2]:end[2]
    as.vector(outer(i, (j - 1) * d[1], "+"))
  })
}
x <- altarr(d, cs, fetch)
x[c(1, 70)]
#> [1]  1 70
x[cbind(10, 7)]
#> [1] 70
altarr_stats(x)[c("fetch_calls", "chunks_fetched")]
#>    fetch_calls chunks_fetched 
#>              1              2 
## the same chunks as an integer array (values are coerced)
xi <- altarr(d, cs, fetch, type = "integer")
typeof(xi)
#> [1] "integer"
sum(xi)
#> [1] 2485
```
