\name{altarr_zarr_v2}
\alias{altarr_zarr_v2}
\title{A lazy array over a local Zarr v2 store}
\description{
A deliberately small reader showing that a real chunked, compressed store
fits behind the fetch contract. Handles dtype \code{<f8}, \code{<f4},
\code{<i4}, \code{<i2} or \code{|u1}, compressor \code{null} or \code{zlib},
order \code{C} or \code{F}, and missing chunk files (read as
\code{fill_value}). Zarr's padded edge chunks are clipped. With
\code{unpack = TRUE}, CF attributes in \code{.zattrs} are applied inside the
fetch: values equal to \code{_FillValue} or \code{missing_value} become
\code{NA}, then \code{scale_factor} and \code{add_offset} are applied. The
Zarr \code{fill_value} itself is not treated as missing. A C-order array
of shape \code{(s1, ..., sn)} gets R \code{dim} \code{c(sn, ..., s1)}, so no
transposition is ever done.
}
\usage{
altarr_zarr_v2(path, unpack = TRUE)
}
\arguments{
\item{path}{directory of the Zarr v2 array (containing \code{.zarray}).}
\item{unpack}{apply CF packing attributes from \code{.zattrs}?}
}
\value{a lazy array, see \code{\link{altarr}}.}
