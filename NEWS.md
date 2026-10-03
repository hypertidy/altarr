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
