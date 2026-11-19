library(altarr)

## A sparse store: only some chunks are written; the rest are absent and
## read as 'fill'. The fetch function refuses to be asked for an absent
## chunk, so any test that passes proves absent chunks are never fetched.
make_sparse <- function(d, cs, keep, fill = NA, type = "double") {
  nch <- (d + cs - 1L) %/% cs
  grid <- as.matrix(expand.grid(lapply(nch, function(n) seq_len(n) - 1L)))
  stride <- cumprod(c(1, nch[-length(nch)]))
  cid <- as.vector(grid %*% stride)
  present <- cid %in% keep
  base <- seq_len(prod(d)) + 0.25
  ref <- array(switch(type, double = base, integer = as.integer(base),
                      logical = (as.integer(base) %% 3L) == 0L), d)
  fillv <- switch(type, double = as.double(fill), integer = as.integer(fill),
                  logical = as.logical(fill))
  ## absent chunks in the reference hold the fill value
  for (r in which(!present)) {
    st <- grid[r, ] * cs + 1L
    en <- pmin(st + cs - 1L, d)
    idx <- lapply(seq_along(d), function(k) st[k]:en[k])
    ref <- do.call(`[<-`, c(list(ref), idx, list(value = fillv)))
  }
  gen <- function(chunks) {
    lapply(seq_len(nrow(chunks)), function(r) {
      id <- sum(chunks[r, ] * stride)
      if (!id %in% keep) stop("fetch asked for absent chunk ", id)
      st <- chunks[r, ] * cs + 1L
      en <- pmin(st + cs - 1L, d)
      idx <- lapply(seq_along(d), function(k) st[k]:en[k])
      as.vector(do.call(`[`, c(list(ref), idx, list(drop = FALSE))))
    })
  }
  list(ref = ref, x = altarr(d, cs, gen, type = type, present = present,
                             fill = fill))
}

check <- function(a, b, what) {
  if (!identical(a, b)) {
    stop("mismatch: ", what, "\n", paste(capture.output(str(a)), collapse = "\n"),
         "\n vs \n", paste(capture.output(str(b)), collapse = "\n"))
  }
}
near <- function(a, b, what) {
  if (!isTRUE(all.equal(a, b))) stop("mismatch: ", what, ": ", a, " vs ", b)
}

d <- c(9L, 7L, 5L); cs <- c(4L, 3L, 2L)   # grid 3 x 3 x 3 = 27 chunks
keep <- c(0, 4, 13, 26)

for (fill in list(0, NA, -1.5)) {
  s <- make_sparse(d, cs, keep, fill = fill)
  x <- s$x; ref <- s$ref
  check(altarr_stats(x)[["chunks_present"]], 4, "chunks_present")
  check(as.vector(altarr_present(x)), (seq_len(27) - 1) %in% keep,
        "present as given")
  ## whole-array reductions: only the stored chunks are fetched
  altarr_reset(x)
  for (narm in c(FALSE, TRUE)) {
    near(sum(x, na.rm = narm), sum(ref, na.rm = narm), paste("sum", fill, narm))
    check(min(x, na.rm = narm), min(ref, na.rm = narm), paste("min", fill, narm))
    check(max(x, na.rm = narm), max(ref, na.rm = narm), paste("max", fill, narm))
  }
  check(altarr_stats(x)[["chunks_fetched"]], 24, "6 reductions x 4 chunks")
  ## an absent region costs no fetch at all
  altarr_reset(x)
  check(x[cbind(9, 7, 1)], ref[cbind(9, 7, 1)], "matrix index in absent chunk")
  check(x[5:8, 1:3, 1:2], ref[5:8, 1:3, 1:2], "Elt path, absent chunk")
  check(altarr_extract(x, 5:8, 1:3, 1:2), ref[5:8, 1:3, 1:2], "hyperslab absent")
  check(altarr_stats(x)[["fetch_calls"]], 0, "absent reads fetch nothing")
  ## mixed regions
  check(x[c(1, 50, 200, 315)], ref[c(1, 50, 200, 315)], "linear index")
  check(altarr_extract(x, , 2:7, c(1, 5)), ref[, 2:7, c(1, 5)], "hyperslab mixed")
  check(x[2:9, 3, ], ref[2:9, 3, ], "Elt mixed")
  near(mean(x, na.rm = TRUE), mean(ref, na.rm = TRUE), "mean (region)")
  ## serialization keeps the index and fill
  y <- unserialize(serialize(x, NULL))
  check(as.vector(altarr_present(y)), as.vector(altarr_present(x)), "saved index")
  check(altarr_fill(y), as.double(fill), "saved fill")
  near(sum(y, na.rm = TRUE), sum(ref, na.rm = TRUE), "saved sum")
  ## materialize
  check(x + 0, ref + 0, "materialized")
}

## all chunks absent: sum is fill * n with no fetch
s <- make_sparse(d, cs, keep = numeric(0), fill = 2)
check(sum(s$x), 2 * prod(d), "all absent sum")
check(altarr_stats(s$x)[["fetch_calls"]], 0, "all absent: no fetch")
s <- make_sparse(d, cs, keep = numeric(0), fill = NA)
check(sum(s$x, na.rm = TRUE), 0, "all absent NA fill")
check(suppressWarnings(max(s$x, na.rm = TRUE)), -Inf, "all absent NA max")

## integer and logical arrays (reduced by base R over regions)
for (type in c("integer", "logical")) {
  s <- make_sparse(d, cs, keep, fill = if (type == "logical") FALSE else 0L,
                   type = type)
  check(typeof(s$x), type, paste("type", type))
  check(sum(s$x), sum(s$ref), paste("sum", type))
  check(s$x[3:9, 2:6, 2], s$ref[3:9, 2:6, 2], paste("Elt", type))
  check(altarr_extract(s$x, 1:9, 7, ), s$ref[1:9, 7, ], paste("hyperslab", type))
  check(which(s$x[1:100] == 1L) > 0, which(s$ref[1:100] == 1L) > 0, type)
}

## present as a matrix of 0-based chunk coordinates
s <- make_sparse(d, cs, keep)
nch <- (d + cs - 1L) %/% cs
g <- as.matrix(expand.grid(lapply(nch, function(n) seq_len(n) - 1L)))
xm <- altarr(d, cs, function(chunks) stop("not used"),
             present = g[keep + 1, , drop = FALSE], fill = 0)
check(altarr_present(xm), altarr_present(s$x), "matrix present")
stopifnot(inherits(try(altarr(d, cs, identity, present = c(TRUE, FALSE)),
                       silent = TRUE), "try-error"))
stopifnot(inherits(try(altarr(d, cs, identity, present = rep(NA, 27)),
                       silent = TRUE), "try-error"))

## views stay lazy and sparse
s <- make_sparse(d, cs, keep, fill = 0)
x <- s$x; ref <- s$ref
v <- altarr_view(x, 2:9, c(1, 3, 6, 7), 2:5)
stopifnot(is_altarr(v))
check(dim(v), c(8L, 4L, 4L), "view dim")
near(sum(v), sum(ref[2:9, c(1, 3, 6, 7), 2:5]), "view sum")
check(v[, , ], ref[2:9, c(1, 3, 6, 7), 2:5], "view values")
check(altarr_extract(v, 1:3, 2, ), ref[2:4, 3, 2:5], "view of view region")
pv <- altarr_present(v)
stopifnot(sum(pv) < length(pv))
## a view chunk that draws only on absent chunks is absent
vv <- altarr_view(x, 5:8, 1:3, 1:2)
check(sum(altarr_present(vv)), 0L, "fully absent view")
check(sum(vv), 0, "fully absent view sum")

## the Zarr reader takes its index from one listing of the store
z <- altarr_zarr_v2(altarr_example_zarr(sparse = TRUE))
dense <- altarr_zarr_v2(altarr_example_zarr())
check(sum(altarr_present(z)), 20L, "sparse zarr present")
check(altarr_fill(z), 0, "sparse zarr fill")
altarr_reset(z)
s1 <- sum(z)
check(altarr_stats(z)[["chunks_fetched"]], 20, "zarr sum reads 20 of 80")
ok <- as.vector(altarr_present(z))
## stored chunks hold the dense store's values
check(z[1:20, 1:16, 1:7], dense[1:20, 1:16, 1:7], "stored chunk values")
check(z[21:40, 1:16, 1:7], array(0, c(20, 16, 7)), "absent chunk values")
check(sum(altarr_present(dense)), 80L, "dense zarr all present")

cat("all sparse tests passed\n")
