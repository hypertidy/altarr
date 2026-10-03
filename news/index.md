# Changelog

## altarr (development version)

- New vignette,
  [`vignette("fetch", package = "altarr")`](https://hypertidy.github.io/altarr/articles/fetch.md):
  writing a fetch function, for maintainers of Zarr, netCDF, GDAL and
  object-store readers.
- pkgdown site at <https://hypertidy.github.io/altarr/>, built by GitHub
  Actions.

## altarr 0.1.0

First release-shaped version: the package is usable on its own, not only
as a record of the base R proposal (tag v0.0.1).

- Bounded chunk cache: least recently used chunks are evicted to keep
  each array within `getOption("altarr.cache_bytes")` (default 256 MiB).
  A copy shares its original’s cache
  ([\#5](https://github.com/hypertidy/altarr/issues/5),
  [\#10](https://github.com/hypertidy/altarr/issues/10)).
- Planned region reads (ALTREP `Get_region`):
  [`mean()`](https://rdrr.io/r/base/mean.html),
  [`prod()`](https://rdrr.io/r/base/prod.html),
  [`anyNA()`](https://rdrr.io/r/base/NA.html) and reductions on R’s
  wrapper class read whole chunk layers in batched fetch calls instead
  of one chunk per round trip
  ([\#6](https://github.com/hypertidy/altarr/issues/6),
  [\#11](https://github.com/hypertidy/altarr/issues/11)).
- Integer and logical arrays, via `altarr(type = )`.
  [`altarr_zarr_v2()`](https://hypertidy.github.io/altarr/reference/altarr_zarr_v2.md)
  picks the type from the Zarr dtype; CF scale and offset give doubles
  ([\#7](https://github.com/hypertidy/altarr/issues/7),
  [\#12](https://github.com/hypertidy/altarr/issues/12)).
- [`?altarr_contract`](https://hypertidy.github.io/altarr/reference/altarr_contract.md)
  documents the fetch contract, pinned sources, saving recipes safely,
  and a measured table of which base R operations are planned, element
  by element, or materializing
  ([\#8](https://github.com/hypertidy/altarr/issues/8),
  [\#13](https://github.com/hypertidy/altarr/issues/13)).
- New vignette,
  [`vignette("walkthrough", package = "altarr")`](https://hypertidy.github.io/altarr/articles/walkthrough.md):
  ten steps showing what base R asks a lazy array for.
- Examples for every exported function;
  [`altarr_zarr_v2()`](https://hypertidy.github.io/altarr/reference/altarr_zarr_v2.md)
  is labelled a demonstration reader.
- `useDynLib` is declared in roxygen, so `document()` keeps it
  ([\#14](https://github.com/hypertidy/altarr/issues/14)).
- GitHub Actions R CMD check on Linux, macOS and Windows.

## altarr 0.0.1

- The state of the package for the base R `ArraySubset` hook proposal
  and the post “What R does today with an ALTREP that has a dim and no
  class”.
