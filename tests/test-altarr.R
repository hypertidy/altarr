library(altarr)

## a "remote" that is really an in-memory reference array, so every result
## can be checked against base R exactly
make_case <- function(d, cs, dimnames = NULL) {
  ref <- array(seq_len(prod(d)) + 0.25, d, dimnames = dimnames)
  gen <- function(chunks) {
    lapply(seq_len(nrow(chunks)), function(r) {
      st <- chunks[r, ] * cs + 1L
      en <- pmin(st + cs - 1L, d)
      idx <- lapply(seq_along(d), function(k) st[k]:en[k])
      as.vector(do.call(`[`, c(list(unname(ref)), idx, list(drop = FALSE))))
    })
  }
  list(ref = ref, x = altarr(d, cs, gen, dimnames = dimnames))
}

check <- function(a, b, what) {
  if (!identical(a, b)) {
    stop("mismatch: ", what, "\n", paste(capture.output(str(a)), collapse = "\n"),
         "\n vs \n", paste(capture.output(str(b)), collapse = "\n"))
  }
}

## ---- the object is an ordinary classless array -------------------------
cs1 <- make_case(c(7L, 5L, 4L), c(3L, 2L, 3L))
x <- cs1$x; ref <- cs1$ref
check(dim(x), dim(ref), "dim")
check(length(x), length(ref), "length")
check(is.object(x), FALSE, "no class")
check(altarr_stats(x)[["fetch_calls"]], 0, "dim/length are free")

## ---- three-dim subscripts: [i, j, k] (Elt) and altarr_extract (hyperslab) --
subs3 <- list(
  list(2:6, 2, 3:4),
  list(7, 5, 4),
  list(c(3, 1, 3), quote(expr = ), 2),
  list(-1, -(2:3), c(TRUE, FALSE)),
  list(c(1, NA, 7), 1:2, 4),
  list(integer(0), 1, 1),
  list(quote(expr = ), quote(expr = ), quote(expr = ))
)
for (s in subs3) {
  for (drop in c(TRUE, FALSE)) {
    want <- do.call(`[`, c(list(ref), s, list(drop = drop)))
    altarr_reset(x)
    check(do.call(`[`, c(list(x), s, list(drop = drop))), want, "x[i,j,k]")
    altarr_reset(x)
    check(do.call(altarr_extract, c(list(x), s, list(drop = drop))), want,
          "altarr_extract")
    st <- altarr_stats(x)
    stopifnot(st[["fetch_calls"]] <= 1, st[["elt"]] == 0)
  }
}

## ---- linear and matrix indexing go through Extract_subset ---------------
set.seed(1)
lin <- c(sample(length(ref), 30), NA, length(ref) + 5)
altarr_reset(x)
check(x[lin], ref[lin], "x[linear]")
stopifnot(altarr_stats(x)[["fetch_calls"]] == 1, altarr_stats(x)[["elt"]] == 0)
m <- cbind(sample(7, 25, TRUE), sample(5, 25, TRUE), sample(4, 25, TRUE))
altarr_reset(x)
check(x[m], ref[m], "x[cbind()]")
stopifnot(altarr_stats(x)[["fetch_calls"]] == 1, altarr_stats(x)[["extract_subset"]] == 1)
check(x[-(1:100)], ref[-(1:100)], "negative linear")
check(x[ref > 100], ref[ref > 100], "logical linear")

## ---- 2-d (MatrixSubset path) and 1-d --------------------------------------
cs2 <- make_case(c(11L, 9L), c(4L, 4L))
check(cs2$x[3:10, c(9, 1)], cs2$ref[3:10, c(9, 1)], "matrix [i,j]")
check(altarr_extract(cs2$x, 3:10, c(9, 1)), cs2$ref[3:10, c(9, 1)], "matrix hyperslab")
cs1d <- make_case(23L, 5L)
check(cs1d$x[c(2, 23, 11)], cs1d$ref[c(2, 23, 11)], "1-d")

## ---- dimnames, character subscripts, names(dimnames) ----------------------
dn <- list(lon = letters[1:6], lat = LETTERS[1:4], time = NULL)
cs3 <- make_case(c(6L, 4L, 3L), c(4L, 3L, 2L), dimnames = dn)
check(cs3$x[c("b", "f"), "C", ], cs3$ref[c("b", "f"), "C", ], "char [i,j,k]")
check(altarr_extract(cs3$x, c("b", "f"), "C", ), cs3$ref[c("b", "f"), "C", ],
      "char hyperslab")
check(altarr_extract(cs3$x, 2, 3, 1:2, drop = FALSE),
      cs3$ref[2, 3, 1:2, drop = FALSE], "dimnames kept, drop = FALSE")
check(cs3$x[cbind(2, 3, 1)], cs3$ref[cbind(2, 3, 1)], "matrix index with dimnames")
stopifnot(inherits(try(altarr_extract(cs3$x, "zz", 1, 1), silent = TRUE), "try-error"))
stopifnot(inherits(try(altarr_extract(cs3$x, 9, 1, 1), silent = TRUE), "try-error"))

## ---- the plan table matches what the hyperslab fetches -------------------
altarr_reset(x)
p <- altarr_plan(x, 2:6, 2, 3:4)
invisible(altarr_extract(x, 2:6, 2, 3:4))
stopifnot(nrow(p) == altarr_stats(x)[["chunks_fetched"]])

## ---- the cache: a second read of the same region fetches nothing --------
altarr_reset(x)
invisible(x[1:7, 1:5, 1])
n1 <- altarr_stats(x)[["fetch_calls"]]
invisible(x[1:7, 1:5, 1])
stopifnot(altarr_stats(x)[["fetch_calls"]] == n1)

## ---- materialization: allowed when small, refused when large ------------
small <- make_case(c(4L, 3L), c(2L, 2L))
check(small$x * 2, small$ref * 2, "arithmetic materializes")
check(sum(small$x), sum(small$ref), "sum")
big <- make_case(c(200L, 200L, 30L), c(50L, 50L, 10L))
old <- options(altarr.max_materialize = 1e5)
r <- try(big$x + 1, silent = TRUE)
stopifnot(inherits(r, "try-error"), grepl("refusing to materialize", r))
check(big$x[150, 120, 30], big$ref[150, 120, 30], "subset still fine")
options(old)

## ---- copy-on-modify keeps the original lazy and untouched ---------------
y <- small$x
y[1, 1] <- -1
check(y[1, 1], -1, "modified copy")
check(small$x[1, 1], small$ref[1, 1], "original unchanged")
check(is_altarr(small$x), TRUE, "original still altarr")

## changing attributes on a shared object makes R wrap it in its own
## 'wrapper' ALTREP class; planning must survive that
z <- cs1$x
dimnames(z) <- list(NULL, letters[1:5], NULL)
stopifnot(is_altarr(z), altarr_stats(z)[["materialized"]] == 0)
altarr_reset(z)
check(z[m], ref[m], "x[cbind()] through R's wrapper")
stopifnot(altarr_stats(z)[["extract_subset"]] == 1, altarr_stats(z)[["elt"]] == 0)

## ---- serialization stores the recipe, not the payload -------------------
f <- tempfile(fileext = ".rds")
saveRDS(cs3$x, f)
back <- readRDS(f)
stopifnot(is_altarr(back), altarr_stats(back)[["chunks_cached"]] == 0)
check(back[, , ], cs3$ref[, , ], "round trip values")
check(dimnames(back), dimnames(cs3$ref), "round trip dimnames")

## ---- a packed int16 Zarr v2 store written by hand: CF unpacking --------
zdir <- file.path(tempdir(), "packed.zarr")
dir.create(zdir, showWarnings = FALSE)
zshape <- c(9L, 5L, 7L); zchunk <- c(4L, 3L, 5L)     # C order (time, lat, lon)
rd <- rev(zshape); rcs <- rev(zchunk)                 # R order (lon, lat, time)
set.seed(9)
packed <- array(sample(18000:32000, prod(rd), TRUE), rd)
packed[2, 3, 4] <- -32767L
writeLines(sprintf('{"shape": [%s], "chunks": [%s], "dtype": "<i2", "order": "C",
 "compressor": {"id": "zlib", "level": 1}, "fill_value": 0, "filters": null,
 "zarr_format": 2}', paste(zshape, collapse = ", "), paste(zchunk, collapse = ", ")),
 file.path(zdir, ".zarray"))
writeLines('{"scale_factor": 0.01, "add_offset": 0.0, "_FillValue": -32767}',
           file.path(zdir, ".zattrs"))
nch <- ceiling(rd / rcs)
for (a in seq_len(nch[1]) - 1L) for (b in seq_len(nch[2]) - 1L) for (cc in seq_len(nch[3]) - 1L) {
  full <- array(0L, rcs)                              # Zarr pads edge chunks
  st <- c(a, b, cc) * rcs + 1L; en <- pmin(st + rcs - 1L, rd)
  blk <- packed[st[1]:en[1], st[2]:en[2], st[3]:en[3], drop = FALSE]
  full[seq_len(dim(blk)[1]), seq_len(dim(blk)[2]), seq_len(dim(blk)[3])] <- blk
  con <- memCompress(writeBin(as.vector(full), raw(), size = 2L, endian = "little"), "gzip")
  writeBin(con, file.path(zdir, paste(cc, b, a, sep = ".")))
}
want <- packed * 0.01; want[packed == -32767L] <- NA
zx <- altarr_zarr_v2(zdir)
check(dim(zx), rd, "packed dims reversed")
check(altarr_extract(zx, , , ), want, "CF unpacking")
check(zx[cbind(c(2, 7), c(3, 5), c(4, 9))], want[cbind(c(2, 7), c(3, 5), c(4, 9))], "packed points")
check(altarr_zarr_v2(zdir, unpack = FALSE)[2, 3, 4], -32767L, "unpack = FALSE: raw integers")

## ---- a virtual array larger than R's maximum vector length is refused ---
r <- try(altarr(c(2e9, 2e9, 2e3), c(1e5, 1e5, 1e3), function(chunks) list()),
         silent = TRUE)
stopifnot(inherits(r, "try-error"), grepl("maximum vector length", r))
## just under the limit is fine, and shape costs nothing
big_ok <- altarr(c(1e9, 1e6, 4), c(1e5, 1e5, 4), function(chunks) list())  # 4e15 values
stopifnot(length(dim(big_ok)) == 3L, altarr_stats(big_ok)[["fetch_calls"]] == 0)

## ---- whole-array reductions: planned batches, bounded memory -------------
rd <- c(40L, 30L, 6L); rcs <- c(10L, 10L, 2L)        # 4 x 3 x 3 = 36 chunks
set.seed(5)
rref <- array(rnorm(prod(rd)), rd)
rref[3, 4, 2] <- NA; rref[39, 1, 6] <- NaN
rgen <- function(ch) lapply(seq_len(nrow(ch)), function(r) {
  st <- ch[r, ] * rcs + 1L; en <- pmin(st + rcs - 1L, rd)
  as.vector(rref[st[1]:en[1], st[2]:en[2], st[3]:en[3], drop = FALSE])
})
rx <- altarr(rd, rcs, rgen)
old <- options(altarr.max_materialize = 100, altarr.batch_chunks = 10)
for (f in c("sum", "min", "max")) for (nr in c(FALSE, TRUE)) {
  altarr_reset(rx)
  got <- do.call(f, list(rx, na.rm = nr)); want <- do.call(f, list(rref, na.rm = nr))
  if (is.na(want)) {
    stopifnot(identical(is.na(got), TRUE), identical(is.nan(got), is.nan(want)))
  } else {
    stopifnot(isTRUE(all.equal(got, want, tolerance = 1e-12)))
  }
  st <- altarr_stats(rx)
  stopifnot(st[["elt"]] == 0, st[["reduce"]] == 1, st[["fetch_calls"]] == 4,
            st[["chunks_fetched"]] == 36, st[["chunks_cached"]] == 0,
            st[["materialized"]] == 0)
}
## cached chunks are reused, not refetched
altarr_reset(rx); invisible(rx[1:10, 1:10, 1:2])
invisible(max(rx, na.rm = TRUE))
stopifnot(altarr_stats(rx)[["chunks_fetched"]] == 36)
## all-NA with na.rm = TRUE warns and returns Inf, as base R does
nax <- altarr(c(4L, 4L), c(2L, 2L), function(ch) lapply(seq_len(nrow(ch)), function(r) rep(NA_real_, 4)))
w <- tryCatch(min(nax, na.rm = TRUE), warning = function(w) conditionMessage(w))
stopifnot(grepl("no non-missing arguments to min", w))
stopifnot(identical(suppressWarnings(max(nax, na.rm = TRUE)), -Inf))
## R's wrapper does not forward Sum/Min/Max: still correct, via elements
ry <- rx; dimnames(ry) <- list(NULL, NULL, letters[1:6])
altarr_reset(rx)
stopifnot(isTRUE(all.equal(sum(ry, na.rm = TRUE), sum(rref, na.rm = TRUE))),
          altarr_stats(ry)[["reduce"]] == 0)
options(old)
## ---- the example store: values are their own positions --------------------
ep <- altarr_example_zarr()
ex <- altarr_zarr_v2(ep)
check(dim(ex), c(70L, 50L, 30L), "example dims")
check(altarr_extract(ex, , , ), array(as.double(seq_len(105000) - 1), c(70L, 50L, 30L)),
      "example values")
ep2 <- altarr_example_zarr(dim = c(5L, 3L), chunk = c(2L, 2L))   # ragged 2-d
check(altarr_extract(altarr_zarr_v2(ep2), , ), array(as.double(0:14), c(5L, 3L)),
      "example 2-d ragged")

## ---- bounded cache: LRU with a byte budget --------------------------------
bd <- c(37L, 29L, 11L); bcs <- c(8L, 7L, 3L)          # 100 ragged chunks
set.seed(11)
bref <- array(rnorm(prod(bd)), bd); bref[sample(length(bref), 20)] <- NA
bgen <- function(ch) lapply(seq_len(nrow(ch)), function(r) {
  st <- ch[r, ] * bcs + 1L; en <- pmin(st + bcs - 1L, bd)
  as.vector(bref[st[1]:en[1], st[2]:en[2], st[3]:en[3], drop = FALSE])
})
chunk_bytes <- prod(bcs) * 8
old <- options(altarr.max_materialize = 1e9)
set.seed(2)
for (b in c(0, chunk_bytes / 2, chunk_bytes * 3, chunk_bytes * 20)) {
  options(altarr.cache_bytes = b)
  bx <- altarr(bd, bcs, bgen)
  for (rep in 1:15) {
    i <- sort(sample(bd[1], 12)); j <- sample(bd[2], 5); k <- sample(bd[3], 3)
    check(bx[i, j, k], bref[i, j, k], "Elt path under a budget")
    check(altarr_extract(bx, i, j, k), bref[i, j, k], "hyperslab under a budget")
    m <- cbind(sample(bd[1], 30, TRUE), sample(bd[2], 30, TRUE), sample(bd[3], 30, TRUE))
    check(bx[m], bref[m], "Extract_subset under a budget")
    stopifnot(altarr_stats(bx)[["cache_bytes"]] <= b)
  }
  by <- bx; by[1, 1, 1] <- 99                         # materialize under the budget
  check(by[-1], bref[-1], "materialize under a budget")
}
stopifnot(altarr_stats(bx)[["evictions"]] > 0)
## least recently used goes first
options(altarr.cache_bytes = 2 * chunk_bytes)
lx <- altarr(bd, bcs, bgen)
invisible(lx[1, 1, 1]); invisible(lx[9, 1, 1])        # chunks A and B
invisible(lx[2, 1, 1])                                # touch A
invisible(lx[17, 1, 1])                               # C evicts B, not A
altarr_reset(lx, cache = FALSE)
invisible(lx[3, 1, 1]); stopifnot(altarr_stats(lx)[["fetch_calls"]] == 0)
invisible(lx[10, 1, 1]); stopifnot(altarr_stats(lx)[["fetch_calls"]] == 1)
## materializing a copy no longer fills the shared cache
options(altarr.cache_bytes = 1e9)
cx3 <- altarr(bd, bcs, bgen)
invisible(cx3[1, 1, 1])
cy <- cx3; cy[1, 1, 1] <- 0
stopifnot(altarr_stats(cx3)[["chunks_cached"]] == 1)
## reset clears bytes with the chunks
altarr_reset(cx3)
stopifnot(altarr_stats(cx3)[["cache_bytes"]] == 0, altarr_stats(cx3)[["chunks_cached"]] == 0)
options(old)

## ---- region reads: mean(), prod(), anyNA() and R's wrapper ----------------
region <- function(x, i, n) .Call(altarr:::C_altarr_region, x, i, n)
mkr <- function(d, cs) {
  ref <- array(as.double(seq_len(prod(d))) / 7, d); ref[c(5, 17, 40)] <- NA
  gen <- function(ch) lapply(seq_len(nrow(ch)), function(r) {
    st <- ch[r, ] * cs + 1L; en <- pmin(st + cs - 1L, d)
    idx <- lapply(seq_along(d), function(k) st[k]:en[k])
    as.vector(do.call(`[`, c(list(ref), idx, list(drop = FALSE))))
  })
  list(ref = ref, x = altarr(d, cs, gen))
}
set.seed(4)
old <- options(altarr.max_materialize = 100)
for (shape in list(list(c(37L, 29L, 11L), c(8L, 7L, 3L)), list(c(23L, 17L), c(5L, 4L)),
                   list(97L, 10L))) {
  for (b in c(0, 2000, 1e9)) {
    options(altarr.cache_bytes = b)
    rc <- mkr(shape[[1]], shape[[2]]); rx <- rc$x; rv <- as.vector(rc$ref); N <- length(rv)
    for (r in 1:20) {
      i <- sample(0:(N - 1), 1); n <- sample(c(1, 7, 512, N), 1)
      check(region(rx, i, n), rv[(i + 1):min(N, i + n)], "region read")
    }
    stopifnot(length(region(rx, N, 5)) == 0)
    check(region(rx, N - 3, 100), rv[(N - 2):N], "region clipped at the end")
    altarr_reset(rx)
    ## mean(na.rm = TRUE) goes through is.na(), which reads element by element
    ## (no ALTREP hook), so only check its value; anyNA() and mean() use regions
    stopifnot(isTRUE(all.equal(mean(rx, na.rm = TRUE), mean(rv, na.rm = TRUE))))
    altarr_reset(rx)
    stopifnot(identical(anyNA(rx), TRUE), identical(mean(rx), NA_real_),
              altarr_stats(rx)[["elt"]] == 0, altarr_stats(rx)[["cache_bytes"]] <= b)
  }
}
## a full scan prefetches by layer: 4 layers of 12 chunks -> 4 fetch calls
options(altarr.cache_bytes = 1e9)
rc <- mkr(c(40L, 30L, 8L), c(10L, 10L, 2L))
rx <- rc$x
stopifnot(isTRUE(all.equal(prod(rx, na.rm = TRUE), prod(rc$ref, na.rm = TRUE))))
st <- altarr_stats(rx)
stopifnot(st[["elt"]] == 0, st[["fetch_calls"]] == 4, st[["chunks_fetched"]] == 48)
## isolated requests do not prefetch
altarr_reset(rx); invisible(region(rx, 5000, 3))
stopifnot(altarr_stats(rx)[["chunks_fetched"]] == 1)
## R's wrapper forwards region reads, so sum() on a wrapped array is planned too
rw <- rx; dimnames(rw) <- list(NULL, NULL, letters[1:8])
altarr_reset(rx)
stopifnot(isTRUE(all.equal(sum(rw, na.rm = TRUE), sum(rc$ref, na.rm = TRUE))),
          altarr_stats(rx)[["elt"]] == 0, altarr_stats(rx)[["fetch_calls"]] == 4)
options(old)

## ---- integer and logical arrays: every path, R's own reductions ----------
tregion <- function(x, i, n) .Call(altarr:::C_altarr_region, x, i, n)
tmk <- function(ref, cs, type) {
  d <- dim(ref)
  gen <- function(ch) lapply(seq_len(nrow(ch)), function(r) {
    st <- ch[r, ] * cs + 1L; en <- pmin(st + cs - 1L, d)
    idx <- lapply(seq_along(d), function(k) st[k]:en[k])
    as.vector(do.call(`[`, c(list(ref), idx, list(drop = FALSE))))
  })
  altarr(d, cs, gen, type = type)
}
td <- c(37L, 29L, 11L); tcs <- c(8L, 7L, 3L)
set.seed(7)
trefs <- list(integer = array(sample(-1000:1000, prod(td), TRUE), td),
              logical = array(sample(c(TRUE, FALSE), prod(td), TRUE), td))
for (ty in names(trefs)) { r <- trefs[[ty]]; r[sample(length(r), 25)] <- NA; trefs[[ty]] <- r }
old <- options(altarr.max_materialize = 1e9)
for (ty in names(trefs)) {
  tref <- trefs[[ty]]
  for (b in c(0, 2000, 1e9)) {
    options(altarr.cache_bytes = b)
    tx <- tmk(tref, tcs, ty)
    stopifnot(identical(typeof(tx), typeof(tref)))
    for (rep in 1:8) {
      i <- sort(sample(td[1], 10)); j <- sample(td[2], 4); k <- sample(td[3], 3)
      check(tx[i, j, k], tref[i, j, k], paste(ty, "Elt path"))
      check(altarr_extract(tx, i, j, k), tref[i, j, k], paste(ty, "hyperslab"))
      m <- cbind(sample(td[1], 30, TRUE), sample(td[2], 30, TRUE), sample(td[3], 30, TRUE))
      check(tx[m], tref[m], paste(ty, "Extract_subset"))
      lin <- c(sample(length(tref), 40), NA)
      check(tx[lin], tref[lin], paste(ty, "linear with NA"))
      s0 <- sample(0:(length(tref) - 1), 1); n0 <- sample(c(1, 9, 512), 1)
      check(tregion(tx, s0, n0), as.vector(tref)[(s0 + 1):min(length(tref), s0 + n0)],
            paste(ty, "region"))
    }
    for (f in c("sum", "min", "max", "mean", "prod")) for (nr in c(FALSE, TRUE)) {
      check(suppressWarnings(do.call(f, list(tx, na.rm = nr))),
            suppressWarnings(do.call(f, list(tref, na.rm = nr))), paste(ty, f))
    }
    check(anyNA(tx), anyNA(tref), paste(ty, "anyNA"))
    if (ty == "logical") check(which(tx), which(tref), "which() on a lazy logical array")
    ty2 <- tx; ty2[1, 1, 1] <- tref[2, 1, 1]               # materialize a copy
    check(ty2[-1], tref[-1], paste(ty, "materialized copy"))
    stopifnot(typeof(ty2) == typeof(tref), altarr_stats(tx)[["cache_bytes"]] <= b)
  }
  f3 <- tempfile(fileext = ".rds"); saveRDS(tmk(tref, tcs, ty), f3); tb <- readRDS(f3)
  stopifnot(is_altarr(tb), typeof(tb) == typeof(tref))
  check(tb[1:20], tref[1:20], paste(ty, "serialization keeps the type"))
}
options(old)
## integer overflow behaves exactly as base R does on this R version
big <- array(.Machine$integer.max - 5L, c(4L, 4L))
bxi <- tmk(big, c(2L, 2L), "integer")
quiet <- function(e) withCallingHandlers(e, warning = function(w) invokeRestart("muffleWarning"))
check(quiet(sum(bxi)), quiet(sum(big)), "integer overflow as base R")
## chunks of another type are coerced like as.integer() / as.logical()
cxi <- altarr(4L, 4L, function(ch) list(c(1.9, -2.5, 3, NA)), type = "integer")
check(as.vector(cxi[1:4]), as.integer(c(1.9, -2.5, 3, NA)), "coercion to integer")
cxl <- altarr(3L, 3L, function(ch) list(c(0, 2, NA)), type = "logical")
check(as.vector(cxl[1:3]), c(FALSE, TRUE, NA), "coercion to logical")
stopifnot(inherits(try(altarr(2L, 2L, function(ch) list(1:2), type = "complex"), silent = TRUE),
                   "try-error"))
## Zarr: integer dtypes give integer arrays, |b1 gives logical
zbd <- file.path(tempdir(), "bool.zarr"); dir.create(zbd, showWarnings = FALSE)
writeLines('{"shape": [3, 5], "chunks": [2, 4], "dtype": "|b1", "order": "C",
 "compressor": null, "fill_value": false, "filters": null, "zarr_format": 2}',
 file.path(zbd, ".zarray"))
bref <- matrix(c(TRUE, FALSE, TRUE, TRUE, FALSE,  FALSE, FALSE, TRUE, NA, NA,
                 TRUE, TRUE, TRUE, FALSE, TRUE), 5, 3)        # R dims c(5, 3)
bref[4:5, 2] <- FALSE                                        # chunk 0.1 omitted: fill
for (a in 0:1) for (b in 0:1) {
  if (a == 0 && b == 1) next                                 # leave one chunk missing
  full <- matrix(FALSE, 4, 2)
  rows <- (b * 4 + 1):min(5, b * 4 + 4); cols <- (a * 2 + 1):min(3, a * 2 + 2)
  full[seq_along(rows), seq_along(cols)] <- bref[rows, cols]
  writeBin(as.raw(as.integer(full)), file.path(zbd, paste(a, b, sep = ".")))
}
zb <- altarr_zarr_v2(zbd)
stopifnot(typeof(zb) == "logical")
check(altarr_extract(zb, , ), bref, "bool Zarr store")

## ---- the documented contract (?altarr_contract) holds -----------------------
## If a future R changes how an operation reaches the array, a test here fails
## and the contract table needs updating.
kd <- c(40L, 30L, 8L); kcs <- c(10L, 10L, 2L)
set.seed(1); kref <- array(runif(prod(kd)), kd); kref[5] <- NA
kmk <- function() altarr(kd, kcs, function(ch) lapply(seq_len(nrow(ch)), function(r) {
  st <- ch[r, ] * kcs + 1L; en <- pmin(st + kcs - 1L, kd)
  as.vector(kref[st[1]:en[1], st[2]:en[2], st[3]:en[3], drop = FALSE]) }))
how <- function(e) {
  x <- kmk()
  r <- tryCatch({ eval(e, list(x = x)); "ok" }, error = function(err) conditionMessage(err))
  s <- altarr_stats(x)
  if (grepl("refusing to materialize", r)) return("materializes")
  stopifnot(r == "ok")
  if (s[["elt"]] > 0) return("element")
  if (s[["fetch_calls"]] == 0) return("none")
  "planned"
}
old <- options(altarr.max_materialize = 100)
for (e in list(quote(x[1:50]), quote(x[-(1:9000)]), quote(x[cbind(1:5, 1:5, 1:5)]),
               quote(altarr_extract(x, 1:20, 1:5, 1)), quote(sum(x, na.rm = TRUE)),
               quote(max(x, na.rm = TRUE)), quote(mean(x)), quote(prod(x)), quote(anyNA(x)))) {
  if (how(e) != "planned") stop("expected planned: ", deparse(e))
}
for (e in list(quote(x[1:20, 1:5, 1]), quote(x[[7]]), quote(is.na(x)), quote(head(x)))) {
  if (how(e) != "element") stop("expected element by element: ", deparse(e))
}
for (e in list(quote(x + 1), quote(range(x, na.rm = TRUE)), quote(c(x)), quote(aperm(x)),
               quote(capture.output(print(x))))) {
  if (how(e) != "materializes") stop("expected to materialize: ", deparse(e))
}
for (e in list(quote(dim(x)), quote(identical(x, x)), quote(as.vector(x)))) {
  if (how(e) != "none") stop("expected no reads: ", deparse(e))
}
stopifnot(is_altarr(as.vector(kmk())))
options(old)

## a factory-built fetch with forced arguments survives a fresh R session
rs <- file.path(R.home("bin"), "Rscript")
if (nzchar(Sys.getenv("_R_CHECK_PACKAGE_NAME_")) || file.exists(rs) ||
    file.exists(paste0(rs, ".exe"))) {
  ## forward slashes: a Windows path pasted into R code would turn
  ## "C:\Users" into a \U escape in the child session
  ff <- normalizePath(tempfile(fileext = ".rds"), winslash = "/", mustWork = FALSE)
  make_fetch <- function(path, d, cs) {
    force(path); force(d); force(cs)
    function(ch) lapply(seq_len(nrow(ch)), function(r) {
      st <- ch[r, ] * cs + 1L; rep(nchar(path), prod(pmin(cs, d - st + 1L)))
    })
  }
  saveRDS(altarr(c(9L, 7L), c(4L, 4L), make_fetch("abc", c(9L, 7L), c(4L, 4L))), ff)
  out <- system2(rs, c("-e", shQuote(sprintf("cat(readRDS('%s')[9, 7])", ff))),
                 stdout = TRUE, stderr = TRUE)
  if (!identical(trimws(tail(out, 1)), "3")) {
    stop("fresh session read failed:\n", paste(out, collapse = "\n"))
  }
}

cat("all tests passed\n")
