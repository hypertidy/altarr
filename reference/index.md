# Package index

## Lazy arrays

- [`altarr()`](https://hypertidy.github.io/altarr/reference/altarr.md) :
  Create a lazily-read chunked array
- [`is_altarr()`](https://hypertidy.github.io/altarr/reference/is_altarr.md)
  : Is this a (still lazy-capable) altarr array?

## Planned reads

- [`altarr_extract()`](https://hypertidy.github.io/altarr/reference/altarr_extract.md)
  : Rectangular (hyperslab) extraction with one planned fetch
- [`altarr_plan()`](https://hypertidy.github.io/altarr/reference/altarr_plan.md)
  : The chunk plan for a subscript, as a data frame

## Inspecting

- [`altarr_stats()`](https://hypertidy.github.io/altarr/reference/altarr_stats.md)
  : Counters and cache state for an altarr array
- [`altarr_reset()`](https://hypertidy.github.io/altarr/reference/altarr_reset.md)
  : Reset counters, and optionally drop the chunk cache

## The contract

- [`altarr_contract`](https://hypertidy.github.io/altarr/reference/altarr_contract.md)
  [`altarr-contract`](https://hypertidy.github.io/altarr/reference/altarr_contract.md)
  : The fetch contract, and what altarr does with it

## Example and demonstration reader

- [`altarr_example_zarr()`](https://hypertidy.github.io/altarr/reference/altarr_example_zarr.md)
  : Write a small example Zarr v2 store
- [`altarr_zarr_v2()`](https://hypertidy.github.io/altarr/reference/altarr_zarr_v2.md)
  : A lazy array over a local Zarr v2 store
