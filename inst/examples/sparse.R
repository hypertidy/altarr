## Sparse arrays: a Zarr store where most chunks were never written.
##
## Zarr reads an unwritten chunk as the array's fill_value. altarr_zarr_v2()
## lists the store once and hands that listing to altarr() as the chunk
## index ('present'), so absent chunks are never read, never cached, and
## sum(), min() and max() count them from the index without touching a cell.
##
## Run with: Rscript inst/examples/sparse.R
library(altarr)

path <- altarr_example_zarr(dim = c(400L, 400L, 60L), chunk = c(50L, 50L, 10L),
                            sparse = TRUE)
x <- altarr_zarr_v2(path)
p <- altarr_present(x)
cat(sprintf("array %s, chunk grid %s: %d of %d chunks stored (%.0f%%)\n",
            paste(dim(x), collapse = " x "), paste(dim(p), collapse = " x "),
            sum(p), length(p), 100 * mean(p)))

## the same store read the old way: no index, every chunk asked for and
## absent ones synthesized as fill inside fetch
no_index <- local({
  f <- x
  fetch <- function(chunks) {
    ## read the stored ones through x, synthesize the rest
    lapply(seq_len(nrow(chunks)), function(r) {
      cc <- chunks[r, ]
      st <- cc * c(50L, 50L, 10L) + 1L
      en <- pmin(st + c(50L, 50L, 10L) - 1L, dim(f))
      as.vector(altarr_extract(f, st[1]:en[1], st[2]:en[2], st[3]:en[3]))
    })
  }
  altarr(dim(x), c(50L, 50L, 10L), fetch)
})

altarr_reset(x)
t1 <- system.time(s1 <- sum(x))[["elapsed"]]
st <- altarr_stats(x)
cat(sprintf("sum() with the index:    %g  (%d chunks fetched, %d answered from the index, %.2fs)\n",
            s1, st[["chunks_fetched"]], st[["chunks_absent"]], t1))
altarr_reset(x)
t2 <- system.time(s2 <- sum(no_index))[["elapsed"]]
cat(sprintf("sum() without the index: %g  (%d chunks asked of fetch, %.2fs)\n",
            s2, altarr_stats(no_index)[["chunks_fetched"]], t2))
stopifnot(all.equal(s1, s2))

## a region that falls in empty space costs nothing
altarr_reset(x)
r <- x[101:150, 1:50, 1:10]        # chunk (2, 0, 0): never written
cat(sprintf("x[101:150, 1:50, 1:10]: all %g, fetch calls %d\n",
            unique(as.vector(r)), altarr_stats(x)[["fetch_calls"]]))

## a subset that stays lazy and sparse: altarr_view() is x[i, j, k] as a new
## altarr with its own chunk index, the shape an ArraySubset ALTREP method
## could return instead of a dense copy
v <- altarr_view(x, 1:200, 1:400, 31:60)
pv <- altarr_present(v)
cat(sprintf("view %s: %d of %d chunks stored; sum %g\n",
            paste(dim(v), collapse = " x "), sum(pv), length(pv), sum(v)))
stopifnot(all.equal(sum(v), sum(altarr_extract(x, 1:200, 1:400, 31:60))))
