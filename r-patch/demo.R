## x[i, j, k] on a lazy array: stock R versus R with the proposed ALTREP
## Extract_array_subset method. Run with both builds and compare.
##
## The fetch function simulates a store: 50 ms per call (a round trip),
## values computed from position, so no data needs to exist.
library(altarr)
cat(R.version.string, "\n")
cat("array-subset hook in this R:", altarr:::has_array_subset(), "\n\n")

d <- c(1000L, 800L, 60L)        # 48 million doubles, never all in memory
cs <- c(100L, 100L, 10L)        # 10 x 8 x 6 = 480 chunks
make_fetch <- function(d, cs, latency) {
  force(d); force(cs); force(latency)
  function(chunks) {
    Sys.sleep(latency)          # one round trip per call
    lapply(seq_len(nrow(chunks)), function(r) {
      st <- chunks[r, ] * cs; n <- pmin(cs, d - st)
      i <- st[1] + seq_len(n[1]) - 1
      j <- st[2] + seq_len(n[2]) - 1
      k <- st[3] + seq_len(n[3]) - 1
      as.vector(outer(outer(i, j * d[1], "+"), k * d[1] * d[2], "+"))
    })
  }
}
x <- altarr(d, cs, make_fetch(d, cs, latency = 0.05))

run <- function(label, expr) {
  altarr_reset(x)
  t <- system.time(v <- expr)[["elapsed"]]
  s <- altarr_stats(x)
  cat(sprintf("%-26s %7.2f s  fetch calls %3d  chunks %3d  elt %9.0f  array_subset %d\n",
              label, t, s[["fetch_calls"]], s[["chunks_fetched"]], s[["elt"]],
              s[["array_subset"]]))
  invisible(v)
}

a <- run("x[1:250, 1:250, 1:15]", x[1:250, 1:250, 1:15])            # 3x3x2 chunks
b <- run("x[seq(1,1000,50), , 30]", x[seq(1, 1000, 50), , 30])      # a strided slice
p <- run("x[500, 400, ]", x[500, 400, ])                             # a pixel's series
e <- run("altarr_extract (same)", altarr_extract(x, 500, 400, ))
stopifnot(identical(p, e), a[250, 250, 15] == 249 + 249 * 1000 + 14 * 800000)
