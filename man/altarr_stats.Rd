\name{altarr_stats}
\alias{altarr_stats}
\alias{altarr_reset}
\title{Counters and cache state for an altarr array}
\description{
\code{elt} counts per-element reads (the \code{x[i, j, k]} path),
\code{extract_subset} counts planned subset calls (\code{x[i]},
\code{x[cbind(...)]}), \code{hyperslab} counts \code{\link{altarr_extract}}
calls, \code{fetch_calls} counts calls to the fetch function (round trips)
and \code{chunks_fetched} the chunks they returned.
}
\usage{
altarr_stats(x)
altarr_reset(x, cache = TRUE)
}
\arguments{
\item{x}{an altarr array.}
\item{cache}{drop cached chunks as well as resetting counters?}
}
\value{\code{altarr_stats} returns a named numeric vector.}
