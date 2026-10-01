# altarr

What R does today with an ALTREP that has a `dim` and no class.

`altarr` makes a lazily-read, chunked, remote array that is, as far as R is
concerned, an ordinary double vector with a `dim` attribute. No class, no S4,
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
- A chunk cache, so repeat reads cost nothing.
- Copy-on-modify works: `y <- x; y[1, 1, 1] <- 0` materializes `y` only.
- Changing attributes on a shared object makes R wrap it in its own
  `wrapper` ALTREP class; the wrapper forwards `Extract_subset`, so planning
  survives (tested).
- `saveRDS()` stores the recipe (dim, chunk, fetch), not the payload: 1250
  bytes for the 378M-value array. `readRDS()` in a fresh session auto-loads
  the package and returns a lazy array.
- `altarr_plan(x, i, j, k)` returns the plan as a data frame, one row per
  chunk. The plan is a table; the array is what assembling it gives.

## The fetch contract

```r
fetch(chunks)
# chunks: integer matrix, one row per chunk, one column per dimension,
#         0-based chunk coordinates
# returns: list of numeric vectors, one per row, column-major, clipped at
#          the array edge (edge chunks are not padded)
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
- The cache is unbounded (one slot per chunk in the grid). It needs an LRU
  and a byte budget.
- Fetch is called on R's main thread. Concurrency belongs inside the fetch
  implementation (Rust/object_store, GDAL), never touching the R API
  off-thread.
- Coordinates are still dimnames, which must be character. Lazy coordinates
  (below) carry regular grids through `[` without that cost; irregular
  numeric coordinates are still a question for base R.

## Lazy coordinates

`altarr_coord(offset, step, n)` is an ALTREP *character* vector that holds
only three numbers and formats each label on demand. Base R's `[` subsets
dimnames through the same `ExtractSubset()` it uses for data, which offers
ALTREP `Extract_subset` first, so a regular slice of a lazy coordinate comes
back as another lazy coordinate. That works on any array, lazy or not:

```r
lon <- altarr_coord(100, 0.25, 720)
lat <- altarr_coord(90, -0.25, 160)
a <- array(0, c(720, 160), dimnames = list(lon = lon, lat = lat))
b <- a[101:200, seq(1, 160, by = 4)]   # dimnames still lazy: no strings built
altarr_coord_values(colnames(b))       # exact numbers from offset and step
a["100.5", "89.75"]                    # label matching still works
```

Tested and lazy throughout: `dimnames<-`, `[` (including strided and
reversed slices), dropping to a vector, `aperm()`, printing, and
`saveRDS()`/`readRDS()`. Irregular subsets fall back to ordinary strings.
`as_altarr_coord(values)` makes a lazy coordinate from regularly spaced
numbers. No change to R was needed.

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
- `src/coord.c`, `R/coord.R`: lazy coordinates for dimnames.
- `R/zarr.R`: `altarr_zarr_v2()`.
- `tests/test-altarr.R`: every path checked against base R with `identical()`.
- `inst/examples/three-paths.R`: the measurements above.
- `inst/blog/2026-10-01_altrep-dim-no-class/`: the blog post (Quarto `index.qmd`
  plus its figure), identical to the copy published on hypertidy.org.
