\name{altarr_extract}
\alias{altarr_extract}
\alias{altarr_plan}
\title{Rectangular extraction with one planned fetch, and its plan}
\description{
\code{altarr_extract(x, i, j, k)} has the semantics of \code{x[i, j, k]} but
hands the per-dimension subscripts to the ALTREP object whole: the touched
chunks are planned as a cartesian product and fetched in one call. This is
what base R's \code{ArraySubset} could do if it offered its normalized
subscripts to an ALTREP method.

\code{altarr_plan} returns that plan as a data frame, one row per chunk, with
0-based chunk coordinates and each chunk's 1-based start and extent.
}
\usage{
altarr_extract(x, ..., drop = TRUE)
altarr_plan(x, ...)
}
\arguments{
\item{x}{an altarr array.}
\item{...}{one subscript per dimension; missing means all.}
\item{drop}{as for \code{[}.}
}
\value{an array (or vector, after dropping), or a data frame.}
