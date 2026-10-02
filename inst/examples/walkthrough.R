## altarr walkthrough: run this one step at a time and watch the counters.
##
## Every value in the example array is its own 0-based position, so you can
## check any result by eye: x[i, j, k] == (i-1) + 70*(j-1) + 3500*(k-1).
##
## After each step, `seen()` shows what base R actually asked the object
## for since the previous step:
##   elt             single-element reads (the x[i, j, k] path)
##   extract_subset  planned subset requests (x[i], x[cbind(...)])
##   hyperslab       altarr_extract() calls
##   fetch_calls     calls to the fetch function = round trips to the store
##   chunks_fetched  chunks those calls returned
##   materialize     whole-array reads (printing, arithmetic, ...)

library(altarr)

seen <- function(x) {
  s <- altarr_stats(x)
  keep <- c("elt", "extract_subset", "hyperslab", "fetch_calls",
            "chunks_fetched", "materialize")
  print(s[keep])
  cat(sprintf("chunks now cached: %d of %d   materialized: %s\n\n",
              s[["chunks_cached"]], s[["chunks_total"]],
              if (s[["materialized"]] == 1) "YES" else "no"))
  altarr_reset(x, cache = FALSE)   # zero the counters, keep the cache
  invisible(s)
}

## ---- 1. Open a store: nothing is read ------------------------------------
path <- altarr_example_zarr()          # 70 x 50 x 30, chunks 20 x 16 x 7
x <- altarr_zarr_v2(path)
dim(x)                                 # free: from metadata
length(x)                              # free
class(x)                               # "array": no class of its own
seen(x)                                # all zero

## ---- 2. One value: one chunk ---------------------------------------------
x[1]                                   # 0
seen(x)                                # 1 extract_subset, 1 fetch, 1 chunk

## ---- 3. The cache: reading it again is free -------------------------------
x[1:5]                                 # 0 1 2 3 4, all in the cached chunk
seen(x)                                # 0 fetch calls

## ---- 4. Points: x[cbind(i, j, k)] is ONE planned request -----------------
pts <- cbind(c(70, 35, 1), c(50, 25, 1), c(30, 15, 30))
x[pts]                                 # 104999 50714 101500
seen(x)                                # 1 extract_subset, 1 fetch call, 3 chunks

## ---- 5. A rectangle: x[i, j, k] reads element by element -----------------
altarr_reset(x)                        # drop the cache too, for a fair count
r1 <- x[1:40, 1:20, 1:3]
seen(x)                                # 2400 elt calls, 4 fetch calls (one per chunk)

## ---- 6. The same rectangle, planned (what an R core hook would give) -----
altarr_reset(x)
r2 <- altarr_extract(x, 1:40, 1:20, 1:3)
identical(r1, r2)                      # TRUE
seen(x)                                # 1 hyperslab, 1 fetch call, same 4 chunks
altarr_plan(x, 1:40, 1:20, 1:3)        # those 4 chunks, as a table

## ---- 7. Materialization: when R wants ALL the data -----------------------
## Some operations need a pointer to the whole array: printing, arithmetic,
## most of apply(). Then altarr reads every chunk and keeps the full array.
## Size does not trigger this; the operation does. The option
## altarr.max_materialize (default 1e6 values) only decides whether it is
## ALLOWED. This array has 105,000 values, under the limit, so:
altarr_reset(x)
y2 <- x * 2                            # arithmetic -> materializes
seen(x)                                # materialize 1: all 80 chunks in 1 fetch call
x[1:3]                                 # from memory now: no counters move
seen(x)
## Typing `x` at the console would do the same, because print() asks for the
## whole array. That is the quiet switch: small arrays just become ordinary.

## ---- 8. The same with a lower limit: refused, but indexing still works ---
x2 <- altarr_zarr_v2(path)             # a fresh lazy array
op <- options(altarr.max_materialize = 1e4)
try(x2 * 2)                            # refused: 105000 > 10000
x2[1:3]                                # still fine
seen(x2)                               # materialized: no
options(op)

## ---- 9. Copies stay lazy until changed -----------------------------------
x3 <- altarr_zarr_v2(path)
y <- x3                                # no copy, no read
y[1, 1, 1] <- -1                       # changing y materializes y only
c(y[1, 1, 1], x3[1, 1, 1])             # -1, 0
seen(x3)                               # x3 is NOT materialized, but see below
## A copy shares its original's chunk cache. Materializing y read all 80
## chunks through that shared cache, so x3 stays lazy yet its cache is now
## full. (One reason the cache needs a size budget.)

## ---- 10. Saving stores the recipe, not the data --------------------------
f <- tempfile(fileext = ".rds")
saveRDS(x3, f)
file.size(f)                           # about 5 KB: path, shape, chunking
x4 <- readRDS(f)                       # a lazy array again, reading from `path`
x4[pts]
