\name{altarr}
\alias{altarr}
\alias{is_altarr}
\title{Create a lazily-read chunked array}
\description{
Returns an ordinary double vector with a \code{dim} attribute and no class.
It is an ALTREP object: values are obtained chunk by chunk from \code{fetch}
only when base R asks for them.
}
\usage{
altarr(dim, chunk, fetch, dimnames = NULL)
is_altarr(x)
}
\arguments{
\item{dim}{integer dimensions.}
\item{chunk}{integer chunk shape, recycled to \code{length(dim)}.}
\item{fetch}{a function taking an integer matrix of 0-based chunk
coordinates (one row per chunk, one column per dimension) and returning a
list of numeric vectors, one per row, in column-major order and clipped at
the array edge.}
\item{dimnames}{optional dimnames.}
\item{x}{an object.}
}
\details{
Base R routes \code{x[i]} and \code{x[cbind(i, j, k)]} to the ALTREP
\code{Extract_subset} method with the whole index set, so the touched chunks
are fetched in one call. \code{x[i, j, k]} is routed through per-element
\code{Elt} calls, so chunks are fetched one at a time; see
\code{\link{altarr_extract}} for the planned equivalent. Operations that need
the full data pointer (arithmetic, printing) materialize the array, which is
refused above \code{getOption("altarr.max_materialize", 1e6)} values.
Serialization stores the recipe (dim, chunk, fetch), never the values.
}
\value{a lazy array; \code{is_altarr} returns a logical.}
\examples{
d <- c(7L, 5L); cs <- c(3L, 2L)
ref <- array(seq_len(35) + 0.5, d)
fetch <- function(chunks) lapply(seq_len(nrow(chunks)), function(r) {
  st <- chunks[r, ] * cs + 1L; en <- pmin(st + cs - 1L, d)
  as.vector(ref[st[1]:en[1], st[2]:en[2], drop = FALSE])
})
x <- altarr(d, cs, fetch)
x[cbind(c(1, 7), c(5, 1))]
altarr_stats(x)
}
