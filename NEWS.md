# altarr (development version)

* Sparse arrays: `altarr()` takes a chunk index, `present` (a logical per
  chunk of the grid, or a matrix of the stored chunks' coordinates), and a
  `fill` value. Absent chunks are never passed to `fetch` and never cached;
  every read of them gives `fill`. `sum()`, `min()` and `max()` of a double
  array count the absent cells from the index without touching them.
  `altarr_stats()` reports `chunks_present` and `chunks_absent`. Saved
  recipes carry the index; older recipes load with every chunk present.
* `altarr_present()` and `altarr_fill()` return an array's chunk index and
  fill value.
* `altarr_view(x, i, j, k)` is `x[i, j, k, drop = FALSE]` as a new lazy
  array. A view of a sparse array is sparse: its chunk index is derived
  from its source's, so nothing is read for the empty parts.
* `altarr_zarr_v2()` lists the store once and uses the listing as the chunk
  index: unwritten chunks read as `fill_value` without being opened.
  `altarr_example_zarr(sparse = TRUE)` writes a store with only a diagonal
  band of chunks. Demo: `inst/examples/sparse.R`.

* `altarr()` takes `store_axes`, for an array whose chunk grid is its
  store's own: the R dimension of each stored axis, in store order
  (`rev(seq_along(dim))` for a C-order store whose shape the array
  reverses). `altarr_plan()` then starts each row with the chunk's key in
  the store, `dim_0 ..`, the column names of byterefs views and zaro's
  plans, so a plan joins to them; its own columns are unchanged. Without
  `store_axes` (the default) the plan has no keys, since altarr cannot know
  whether its grid is the store's. `altarr_zarr_v2()` sets it. Saved
  recipes carry it; recipes saved by earlier versions load with it unset,
  and earlier versions load new recipes and ignore it.

# altarr 0.1.1

First CRAN submission.

* The Description says what the package does now (lazy chunked arrays used
  by ndr, zaro and GDAL7) rather than describing a prototype.
* The blog post copy in `inst/blog/` stays in the repository but is no
  longer installed with the package.

* New vignette, `vignette("fetch", package = "altarr")`: writing a fetch
  function, for maintainers of Zarr, netCDF, GDAL and object-store readers.
* pkgdown site at <https://hypertidy.github.io/altarr/>, built by GitHub
  Actions.

# altarr 0.1.0

First release-shaped version: the package is usable on its own, not only
as a record of the base R proposal (tag v0.0.1).

* Bounded chunk cache: least recently used chunks are evicted to keep each
  array within `getOption("altarr.cache_bytes")` (default 256 MiB). A copy
  shares its original's cache (#5, #10).
* Planned region reads (ALTREP `Get_region`): `mean()`, `prod()`, `anyNA()`
  and reductions on R's wrapper class read whole chunk layers in batched
  fetch calls instead of one chunk per round trip (#6, #11).
* Integer and logical arrays, via `altarr(type = )`. `altarr_zarr_v2()`
  picks the type from the Zarr dtype; CF scale and offset give doubles
  (#7, #12).
* `?altarr_contract` documents the fetch contract, pinned sources, saving
  recipes safely, and a measured table of which base R operations are
  planned, element by element, or materializing (#8, #13).
* New vignette, `vignette("walkthrough", package = "altarr")`: ten steps
  showing what base R asks a lazy array for.
* Examples for every exported function; `altarr_zarr_v2()` is labelled a
  demonstration reader.
* `useDynLib` is declared in roxygen, so `document()` keeps it (#14).
* GitHub Actions R CMD check on Linux, macOS and Windows.

# altarr 0.0.1

* The state of the package for the base R `ArraySubset` hook proposal and
  the post "What R does today with an ALTREP that has a dim and no class".
