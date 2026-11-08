## Submission

This is a first submission.

## Test environments

* local: Ubuntu, R 4.6.1
* Docker (ghcr.io/hypertidy/gdal-r-full, Ubuntu): R 4.6.2, `R CMD check --as-cran`
  with TinyTeX and HTML Tidy
* R-universe (https://hypertidy.r-universe.dev/altarr): Windows x86_64 and
  aarch64 (R 4.5.3, 4.6.1, R-devel), macOS x86_64 and arm64 (R 4.5.3,
  4.6.1), Linux x86_64 and aarch64 (R 4.6.1, R-devel)
* win-builder: R-devel (TODO: run devtools::check_win_devel() before submitting)

## R CMD check results

0 errors | 0 warnings | 1 note

* New submission.

The local and Docker checks also note the compiler flag
`-mno-omit-leaf-frame-pointer`, which comes from the Ubuntu R build's
configuration, not from this package.

## ALTREP

The package defines ALTREP classes using only the API in `R_ext/Altrep.h`
(class constructors, method setters, `R_altrep_data1`/`R_set_altrep_data1`
and friends); `R CMD check` reports no non-API entry points.
