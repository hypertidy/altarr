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
check(altarr_zarr_v2(zdir, unpack = FALSE)[2, 3, 4], -32767, "unpack = FALSE")

## ---- a virtual array larger than R's maximum vector length is refused ---
r <- try(altarr(c(2e9, 2e9, 2e3), c(1e5, 1e5, 1e3), function(chunks) list()),
         silent = TRUE)
stopifnot(inherits(r, "try-error"), grepl("maximum vector length", r))
## just under the limit is fine, and shape costs nothing
big_ok <- altarr(c(1e9, 1e6, 4), c(1e5, 1e5, 4), function(chunks) list())  # 4e15 values
stopifnot(length(dim(big_ok)) == 3L, altarr_stats(big_ok)[["fetch_calls"]] == 0)

## ---- lazy coordinates as dimnames ----------------------------------------
lazy <- function(v) {
  info <- .Call(altarr:::C_coord_info, v)
  !is.null(info) && !isTRUE(attr(info, "materialized"))
}
plain <- function(o, s, n) sprintf("%.15g", o + s * (seq_len(n) - 1))
lon <- altarr_coord(100, 0.25, 720)
lat <- altarr_coord(90, -0.25, 160)          # descending, as many grids are
check(lon[], plain(100, 0.25, 720), "coord labels")
check(lat[1:3], c("90", "89.75", "89.5"), "descending labels")
ca <- array(as.double(seq_len(720 * 160 * 2)), c(720L, 160L, 2L),
            dimnames = list(lon = lon, lat = lat, time = c("t1", "t2")))
stopifnot(lazy(dimnames(ca)$lon), lazy(dimnames(ca)$lat))
cb <- ca[101:200, seq(1, 160, by = 4), 2]
stopifnot(lazy(dimnames(cb)$lon), lazy(dimnames(cb)$lat))
check(dimnames(cb)$lat, plain(90, -1, 40), "strided slice")
cr <- ca[10:1, 1, 1]
stopifnot(lazy(names(cr)))
check(names(cr), plain(102.25, -0.25, 10), "reversed slice")
ci <- ca[c(5, 1, 9), 1, 1]
stopifnot(!lazy(names(ci)))
check(names(ci), c("101", "100", "102"), "irregular falls back")
check(ca["100.5", "89.75", 1], ca[3, 2, 1], "label matching")
stopifnot(lazy(dimnames(aperm(ca, c(2, 1, 3)))$lon))
f2 <- tempfile(fileext = ".rds"); saveRDS(ca, f2); ca2 <- readRDS(f2)
stopifnot(lazy(dimnames(ca2)$lon), identical(dimnames(ca2), dimnames(ca)))
check(altarr_coord_values(dimnames(cb)$lat), 90 - (seq_len(40) - 1), "exact values")
check(altarr_coord_values(names(ci)), c(101, 100, 102), "values from plain labels")
stopifnot(lazy(as_altarr_coord(seq(-180, 179.5, by = 0.5))),
          !lazy(as_altarr_coord(c(1, 2, 4))))
mod <- lon; mod[1] <- "first"
check(mod[1:2], c("first", "100.25"), "assignment materializes a copy")
stopifnot(lazy(lon))

## ...and on an altarr array, through both paths
cd <- dim(ca); ccs <- c(60L, 40L, 1L)
cgen <- function(ch) lapply(seq_len(nrow(ch)), function(r) {
  st <- ch[r, ] * ccs + 1L; en <- pmin(st + ccs - 1L, cd)
  as.vector(ca[st[1]:en[1], st[2]:en[2], st[3]:en[3], drop = FALSE])
})
cx <- altarr(cd, ccs, cgen, dimnames = dimnames(ca))
cy <- cx[101:200, seq(1, 160, by = 4), 2]
stopifnot(lazy(dimnames(cy)$lon), lazy(dimnames(cy)$lat))
check(cy, cb, "altarr x[i,j,k] with lazy coords")
check(altarr_extract(cx, 101:200, seq(1, 160, by = 4), 2), cb, "hyperslab with lazy coords")
stopifnot(lazy(dimnames(altarr_extract(cx, 101:200, 1:3, 1))$lon))

cat("all tests passed\n")
