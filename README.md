# altarr

What R does today with an ALTREP that has a `dim` and no class.

`altarr` makes a lazily-read, chunked, remote array that is, as far as R is
concerned, an ordinary double, integer or logical vector with a `dim`
attribute. No class, no S4,
no methods. Chunks come from a fetch function you supply, so the store behind
it can be anything: object storage, Zarr, GDAL, a generator.

The point is to find out how far R's old and very rich array indexing can
drive *planned* reads of remote encoded chunks without patching R, and to
pin down exactly what small change to R would close the gap.

```r
library(altarr)
z <- altarr_zarr_v2("path/to/array.zarr")   # a real Zarr v2 store
dim(z)                                      # free: no data read
z[cbind(lon_i, lat_i, time_i)]              # one planned batch of chunk reads
z[100:200, 50:80, 1:12]                     # works, but chunk by chunk
altarr_extract(z, 100:200, 50:80, 1:12)     # same answer, one planned batch
```

## The three paths through base R

Reading `src/main/subset.c` (R 4.3 and current trunk have the same structure):

| you write | R calls | the ALTREP object sees | can it plan? |
|---|---|---|---|
| `x[i]` | `VectorSubset` -> `ExtractSubset` | `Extract_subset(x, indx)`, all indices at once | yes |
| `x[cbind(i, j, k)]` | `mat2indsub` -> `ExtractSubset` | `Extract_subset(x, indx)`, all indices at once | yes |
| `x[i, j, k]` | `ArraySubset` / `MatrixSubset` | `Elt(x, offset)`, one element at a time | no |
| `x + 1`, `print(x)` | anything needing `DATAPTR` | `Dataptr(x)` | must materialize |

`ArraySubset` already holds the hyperslab: after `int_arraySubscript()` it has
one normalized integer subscript vector per dimension (`subs[k]`). It just
never offers them to ALTREP, and walks `REAL_ELT()` over the result instead.

## Measured

A 1440 x 720 x 365 array (378 million values, never allocated), chunks of
60 x 60 x 10, behind a fetch function with 20 ms latency per call (a stand-in
for an object-store round trip; a batch is assumed to be fetched
concurrently). From `inst/examples/three-paths.R`:

| query | path | fetch calls | chunks | seconds |
|---|---|---:|---:|---:|
| region 401 x 301 x 31 | `x[i, j, k]` -> `Elt` | 192 | 192 | 4.38 |
| region 401 x 301 x 31 | `altarr_extract()` -> hyperslab | 1 | 192 | 0.21 |
| 2000 scattered points | loop of `x[i, j, k]` -> `Elt` | 287 | 287 | 6.01 |
| 2000 scattered points | `x[cbind(i, j, k)]` -> `Extract_subset` | 1 | 287 | 0.15 |
| first 100000 values | `x[1:1e5]` -> `Extract_subset` | 1 | 48 | 0.04 |

The same chunks either way; the difference is round trips. Point extraction
through `x[cbind(...)]` is already first-class in unpatched R. Rectangular
`x[i, j, k]` is correct and lazy, but serial.

## The hook R could add

`altarr_extract()` is an emulation of this. In `ArraySubset` (and
`MatrixSubset`), once the subscripts are normalized and bounds-checked:

```c
if (ALTREP(x)) {
    SEXP ans = ALTVEC_EXTRACT_ARRAY_SUBSET(x, s, call);  /* s: per-dim subs */
    if (ans != NULL) {
        /* attach dim and dimnames exactly as the existing code does */
    }
}
/* otherwise fall through to the element loop, as today */
```

That mirrors how `ExtractSubset` already consults `ALTVEC_EXTRACT_SUBSET`. It
is general (any lazy array package benefits: arrow, gdalraster, Zarr readers),
adds no data model, and returning `NULL` keeps today's behaviour.

## What else comes for free

- `dim()`, `length()`, `str()`: no reads.
- A chunk cache, so repeat reads cost nothing. It is bounded: least
  recently used chunks are evicted to keep it within
  `getOption("altarr.cache_bytes")` (default 256 MiB, per array; a copy
  shares its original's cache). Each request assembles from its own list of
  chunks, so eviction never takes a chunk away from a request still using
  it, and materialization fills its result directly rather than through the
  cache, so it works under any budget, including 0.
- Copy-on-modify works: `y <- x; y[1, 1, 1] <- 0` materializes `y` only.
- Changing attributes on a shared object makes R wrap it in its own
  `wrapper` ALTREP class; the wrapper forwards `Extract_subset`, so planning
  survives (tested).
- `saveRDS()` stores the recipe (dim, chunk, fetch), not the payload: 1250
  bytes for the 378M-value array. `readRDS()` in a fresh session auto-loads
  the package and returns a lazy array.
- `altarr_plan(x, i, j, k)` returns the plan as a data frame, one row per
  chunk. The plan is a table; the array is what assembling it gives.

## Whole-array reductions

`sum()`, `min()` and `max()` with a single ALTREP argument go to the
class's own `Sum`, `Min` and `Max` methods (`do_summary` in
`src/main/summary.c`). altarr implements them as planned passes over the
chunk grid: one fetch call per batch of `getOption("altarr.batch_chunks",
64)` chunks, reusing cached chunks and caching nothing new, so memory stays
bounded by the batch. Results match base R, including its `NA`/`NaN` rules
and the all-`NA` warning; sums are accumulated in long double in chunk order.

On 2.4 million values in 48 chunks, without these methods, `sum(x)` already
streamed without materializing, but through 2.4 million `Elt` calls and 48
serial fetches that filled the cache. With them it is 0 `Elt` calls and 1
fetch call (3 with batches of 16), and nothing is cached.

`mean()`, `prod()` and `anyNA()` have no class hook: R iterates them by
region, asking for contiguous runs (usually 512 values) from start to end.
altarr's `Get_region` method serves those runs from the chunks they touch,
and when the runs arrive in sequence (a scan) it prefetches the whole chunk
layer the scan has entered (all chunks sharing the last dimension's chunk
coordinate, one contiguous block in column-major order), in batches, if the
layer fits the cache budget. Isolated region requests never prefetch.

On the same 2.4 million values with 20 ms latency per fetch call:

| | before | after |
|---|---:|---:|
| `mean(x)` | 1.72 s, 48 fetch calls | 0.49 s, 4 fetch calls |
| `prod(x)` | 1.31 s, 48 fetch calls | 0.15 s, 4 fetch calls |
| `anyNA(x)` | 1.27 s, 48 fetch calls | 0.16 s, 4 fetch calls |

R's internal wrapper class (made by `dimnames(y) <- ...` after `y <- x`)
forwards `Extract_subset` but not `Sum`/`Min`/`Max`. It does forward region
reads, though, and R falls back to them, so `sum()`, `min()` and `max()` on
a wrapped array are planned too. Forwarding the reduction methods would
still be a tidy small change for R core.

Still element by element: `is.na()`, which has no ALTREP hook, and so
`mean(x, na.rm = TRUE)`, which calls `x[!is.na(x)]`. The subset itself is
planned; the `is.na()` pass is not.

## Integer and logical arrays

`altarr(dim, chunk, fetch, type = "integer")` (or `"logical"`) makes an
integer or logical array. One engine serves three ALTREP classes
(`altarr_real`, `altarr_integer`, `altarr_logical`); chunks are cached in
the array's own type, so an integer array uses half the cache of a double
one. Every path above works for all three types.

Integer and logical arrays deliberately have no `Sum`/`Min`/`Max` methods
of their own. R then reduces them with its own code over `Get_region`,
which is planned, so integer overflow, `NA` handling and result types are
exactly base R's (they are base R's). `which()` on a lazy logical array is
planned the same way.

`altarr_zarr_v2()` follows the store's dtype: floats give double, integer
dtypes give integer, `|b1` gives logical. If CF `scale_factor` or
`add_offset` apply, the array is double, holding unpacked values;
`unpack = FALSE` returns the stored integers. Checked value for value
against zarr-python stores of `int16`, `uint16`, `int8` and `bool`.

Recipes saved before typed arrays existed load as double arrays.

## The fetch contract

```r
fetch(chunks)
# chunks: integer matrix, one row per chunk, one column per dimension,
#         0-based chunk coordinates
# returns: list of vectors, one per row, column-major, clipped at the
#          array edge (edge chunks are not padded), of the array's type
#          (others are coerced as as.double/as.integer/as.logical would)
```

`altarr_zarr_v2()` is an 85-line implementation of this for Zarr v2 (zlib or
uncompressed, C or F order, missing chunks read as `fill_value`, padded edge
chunks clipped, CF `scale_factor`/`add_offset`/`_FillValue` from `.zattrs` applied inside fetch). A C-order array of shape `(s1, ..., sn)` gets R `dim`
`c(sn, ..., s1)`: C-order bytes are already column-major for the reversed
shape, so nothing is ever transposed. Its output is checked value-for-value
against an array written by zarr-python (`inst/examples/make-zarr.py`).

## Limits, honestly

- Lazy *reads*, not lazy compute. Anything that needs the data pointer
  materializes, and that is refused above
  `getOption("altarr.max_materialize", 1e6)` values.
- Fetch is called on R's main thread. Concurrency belongs inside the fetch
  implementation (Rust/object_store, GDAL), never touching the R API
  off-thread.
- Coordinates are still dimnames, which must be character. That is the one
  gap ALTREP does not touch.

## Why C here

The ALTREP surface is the part that would face R core, and any change to R
itself is C, so the prototype keeps that layer in plain C with no
dependencies. The fetch side is where Rust (object_store, async-tiff,
codecs) earns its place, and it plugs in behind the fetch contract without
touching the ALTREP layer.

## Files

- `src/altarr.c`: the ALTREP class (`Length`, `Elt`, `Extract_subset`,
  `Dataptr`, `Duplicate`, `Serialized_state`, `Inspect`) and the hyperslab.
- `R/altarr.R`: constructor, `altarr_extract()`, `altarr_plan()`, counters.
- `R/zarr.R`: `altarr_zarr_v2()`.
- `tests/test-altarr.R`: every path checked against base R with `identical()`.
- `inst/examples/walkthrough.R`: a step-by-step tour to run line by line,
  printing what base R asked for at each step; uses `altarr_example_zarr()`,
  which writes a small store whose values are their own positions.
- `inst/examples/three-paths.R`: the measurements above.
- `inst/blog/2026-10-01_altrep-dim-no-class/`: the blog post (Quarto `index.qmd`
  plus its figure), identical to the copy published on hypertidy.org.
