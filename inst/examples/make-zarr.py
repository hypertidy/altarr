# Write the small Zarr v2 store used by three-paths.R
# usage: python3 make-zarr.py <outdir>
import sys
import numpy as np
import zarr
from numcodecs import Zlib

out = sys.argv[1]
shape = (30, 50, 70)            # C order: (time, lat, lon)
chunks = (7, 16, 20)            # deliberately ragged at every edge
data = np.arange(np.prod(shape), dtype="<f8").reshape(shape)

z = zarr.create_array(
    store=out, shape=shape, chunks=chunks, dtype="<f8",
    zarr_format=2, compressors=Zlib(level=1),
    fill_value=-9999.0, overwrite=True,
)
z[:] = data
# leave one chunk entirely at fill so the store omits it (sparse store)
z[0:7, 0:16, 0:20] = -9999.0
print(out, z.shape, z.chunks)
