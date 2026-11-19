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
  type = c("double", "integer", "logical"),
  store_axes = NULL,
  present = NULL,
  fill = NA
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

- store_axes:

  optional, for an array whose chunk grid is its store's own chunk grid:
  the R dimension of each stored axis, in the store's order. That is
  `rev(seq_along(dim))` for a C-order store (such as Zarr) whose shape
  the array reverses, and `seq_along(dim)` when the store and R agree.
  [`altarr_plan()`](https://hypertidy.github.io/altarr/reference/altarr_plan.md)
  then names each chunk by its key in the store, `dim_0 ..`, as byterefs
  and zaro do. Leave it `NULL` when the grid is not the store's (a
  window, a view, a rechunking): the plan then has no keys. It changes
  nothing about fetching: `fetch` is always given chunk coordinates in
  R's dimension order.

- present:

  optional chunk index: which chunks the store holds. Either a logical
  vector (or array) with one element per chunk of the grid, in
  column-major order over the grid (`TRUE` = stored), or an integer
  matrix of 0-based chunk coordinates of the stored chunks, one row per
  chunk, in R's dimension order (the same form `fetch` receives). Chunks
  not stored are never passed to `fetch`: every value in them is `fill`,
  as Zarr reads an unwritten chunk as its `fill_value`. `NULL` (the
  default) means every chunk is stored.

- fill:

  the value of every cell of an absent chunk, coerced to `type`.
  Defaults to `NA`. Used only with `present`.

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
## a store that keeps the axes in the other order (C order) declares it,
## and the plan carries the store's chunk keys
xs <- altarr(d, cs, fetch, store_axes = 2:1)
altarr_plan(xs, 9:10, 1:4)
#>   dim_0 dim_1 d1 d2 d1_start d1_n d2_start d2_n
#> 1     0     2  2  0        9    2        1    3
#> 2     1     2  2  1        9    2        4    3
## a sparse store: only two of the 12 chunks were ever written; the
## rest read as 0 and are never fetched
xp <- altarr(d, cs, fetch, present = rbind(c(0L, 0L), c(2L, 2L)), fill = 0)
sum(xp)                                  # only the two stored chunks
#> [1] 289
altarr_stats(xp)[c("chunks_fetched", "chunks_absent", "chunks_present")]
#> chunks_fetched  chunks_absent chunks_present 
#>              2              7              2 
```
