## What R does today with an ALTREP that has a dim and no class
##
## Three ways to ask base R for part of a lazy remote array, and what each
## one costs in round trips. The "remote" is a generator with a fixed
## latency per fetch call, standing in for an object-store GET (a batch of
## chunks is assumed to be fetched concurrently, so it costs one latency).
##
## Run: Rscript three-paths.R [path/to/zarr-v2-array]

library(altarr)

latency <- 0.02   # seconds per fetch call
d  <- c(lon = 1440L, lat = 720L, time = 365L)   # 378 million values, never allocated
cs <- c(60L, 60L, 10L)
value <- function(i, j, k) i + 1e4 * j + 1e8 * k   # exact in double, easy to check

remote <- function(chunks) {
  Sys.sleep(latency)
  lapply(seq_len(nrow(chunks)), function(r) {
    st <- chunks[r, ] * cs + 1L
    en <- pmin(st + cs - 1L, d)
    as.vector(outer(outer(st[1]:en[1], 1e4 * (st[2]:en[2]), "+"),
                    1e8 * (st[3]:en[3]), "+"))
  })
}

x <- altarr(d, cs, remote,
                dimnames = list(lon = NULL, lat = NULL, time = NULL))
cat(sprintf("dim %s, %.0f values, %s chunks, class: %s\n",
            paste(dim(x), collapse = " x "), prod(as.numeric(d)),
            format(altarr_stats(x)[["chunks_total"]], big.mark = ","),
            paste(class(x), collapse = "/")))

results <- list()
run <- function(label, path, expr) {
  altarr_reset(x)
  t <- system.time(val <- eval.parent(substitute(expr)))[["elapsed"]]
  st <- altarr_stats(x)
  results[[length(results) + 1L]] <<- data.frame(
    query = label, path = path, values = length(val),
    elt_calls = st[["elt"]], fetch_calls = st[["fetch_calls"]],
    chunks = st[["chunks_fetched"]], seconds = round(t, 2))
  invisible(val)
}

## 1. a rectangular region, written the natural way: x[i, j, k]
i <- 300:700; j <- 200:500; k <- 1:31
a <- run("region 401 x 301 x 31", "x[i, j, k] -> Elt", x[i, j, k])

## 2. the same region via the hyperslab path
b <- run("region 401 x 301 x 31", "altarr_extract -> hyperslab", altarr_extract(x, i, j, k))
stopifnot(identical(a, b),
          identical(a[1, 1, 1], value(300, 200, 1)),
          identical(a[401, 301, 31], value(700, 500, 31)))

## 3. scattered points, written as a loop of x[i, j, k]
set.seed(42)
n <- 2000
pts <- cbind(sample(d[1], n, TRUE), sample(d[2], n, TRUE), sample(10, n, TRUE))
p1 <- run("2000 points", "loop of x[i, j, k] -> Elt",
          vapply(seq_len(n), function(r) x[pts[r, 1], pts[r, 2], pts[r, 3]], 0))

## 4. the same points as base R matrix indexing
p2 <- run("2000 points", "x[cbind(i, j, k)] -> Extract_subset", x[pts])
stopifnot(identical(p1, p2), identical(p2, value(pts[, 1], pts[, 2], pts[, 3])))

## 5. a linear slice
run("first 100000 values", "x[1:1e5] -> Extract_subset", x[1:1e5])

res <- do.call(rbind, results)
print(res, row.names = FALSE)

cat("\nThe plan for the region is a table, one row per chunk:\n")
plan <- altarr_plan(x, i, j, k)
print(head(plan, 4), row.names = FALSE)
cat(sprintf("... %d rows\n", nrow(plan)))

cat("\nWhole-array operations would materialize 378M values; refused:\n")
cat(conditionMessage(tryCatch(x + 1, error = identity)), "\n")

f <- tempfile(fileext = ".rds")
saveRDS(x, f)
cat(sprintf("\nsaveRDS() of the lazy array: %d bytes (the recipe, not the data)\n",
            file.size(f)))
y <- readRDS(f)
stopifnot(identical(y[700, 500, 31], value(700, 500, 31)))

## A real Zarr v2 store (written by zarr-python; see inst/examples/make-zarr.py)
args <- commandArgs(trailingOnly = TRUE)
if (length(args)) {
  z <- altarr_zarr_v2(args[1])
  cat(sprintf("\nZarr v2 store %s: R dim %s, %d chunks\n", args[1],
              paste(dim(z), collapse = " x "), altarr_stats(z)[["chunks_total"]]))
  ref <- array(as.double(seq_len(prod(dim(z))) - 1L), dim(z))
  ref[1:20, 1:16, 1:7] <- -9999
  stopifnot(identical(z[61:70, 40:50, 25:30], ref[61:70, 40:50, 25:30]),
            identical(z[cbind(c(1, 70), c(1, 50), c(1, 30))], c(-9999, 104999)),
            identical(altarr_extract(z, , , ), ref))
  cat("all values identical to zarr-python's array, including the omitted\n",
      "fill-value chunk and the padded edge chunks\n")
}
