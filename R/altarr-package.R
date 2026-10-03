## Package-level roxygen tags. useDynLib loads the compiled code and
## registers the C_ routines that the R functions call; without it roxygen
## writes a NAMESPACE that never loads src/, and every .Call() fails with
## "object 'C_...' not found".
#' @useDynLib altarr, .registration = TRUE
#' @noRd
NULL
