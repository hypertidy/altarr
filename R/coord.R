#' Lazy numeric coordinates for dimnames
#'
#' A regular coordinate (an offset and a step) as a character vector that
#' never builds its strings unless asked. It is an ALTREP vector holding
#' only \code{offset}, \code{step} and \code{n}; element \code{i} is the
#' label for \code{offset + step * (i - 1)}, formatted with \code{"\%.15g"}.
#'
#' Use it as dimnames on any array, lazy or not. Base R's \code{[} subsets
#' dimnames with the same machinery it uses for data, and a regular slice of
#' a lazy coordinate (constant stride, no \code{NA}) is again a lazy
#' coordinate, so \code{a[i, j, k]} carries coordinates along without
#' formatting any labels. Irregular subsets fall back to ordinary strings.
#' Label matching (\code{a["100.5", , ]}), printing, \code{aperm()} and
#' serialization all work as for ordinary dimnames.
#'
#' \code{as_altarr_coord()} makes a lazy coordinate from numeric values when
#' they are regularly spaced (within \code{tol} of a constant step), and
#' ordinary labels otherwise. \code{altarr_coord_values()} returns the
#' numeric coordinates, exactly from offset and step when lazy, otherwise
#' by \code{as.numeric()} on the labels.
#'
#' @param offset the first coordinate value.
#' @param step the spacing between consecutive coordinates.
#' @param n the number of coordinates.
#' @param values numeric coordinate values.
#' @param tol relative tolerance for regular spacing.
#' @param x a coordinate vector (lazy or ordinary character).
#' @return \code{altarr_coord()} and \code{as_altarr_coord()} return a
#'   character vector; \code{altarr_coord_values()} returns a numeric vector.
#' @examples
#' lon <- altarr_coord(100, 0.25, 720)
#' a <- array(0, c(720, 2), dimnames = list(lon = lon, NULL))
#' b <- a[seq(5, 400, by = 5), ]
#' head(rownames(b))
#' altarr_coord_values(rownames(b))[1:3]
#' @export
altarr_coord <- function(offset, step, n) {
  .Call(C_coord_new, as.double(offset), as.double(step), as.double(n))
}

#' @rdname altarr_coord
#' @export
as_altarr_coord <- function(values, tol = 1e-9) {
  values <- as.double(values)
  n <- length(values)
  if (n < 2L || anyNA(values)) return(as.character(values))
  step <- (values[n] - values[1L]) / (n - 1L)
  fitted <- values[1L] + step * (seq_len(n) - 1L)
  scale <- max(abs(values), abs(step), 1)
  if (step != 0 && all(abs(values - fitted) <= tol * scale)) {
    return(altarr_coord(values[1L], step, n))
  }
  as.character(values)
}

#' @rdname altarr_coord
#' @export
altarr_coord_values <- function(x) {
  info <- .Call(C_coord_info, x)
  if (!is.null(info) && !isTRUE(attr(info, "materialized"))) {
    return(info[["offset"]] + info[["step"]] * (seq_len(info[["n"]]) - 1))
  }
  as.numeric(x)
}
