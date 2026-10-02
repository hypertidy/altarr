/*
 * altarr: a lazily-read, chunked real array as an ALTREP vector.
 *
 * The object is a plain double vector with a 'dim' attribute and no class.
 * Values live in chunks that are obtained on demand from a user-supplied
 * fetch function, so the "remote" can be anything: object storage, a Zarr
 * store, GDAL, or a generator in tests.
 *
 * What each base R entry point does with it (R >= 3.5, checked on 4.3):
 *
 *   x[i]            linear      -> ExtractSubset -> Extract_subset method
 *   x[cbind(i,j,k)] matrix-idx  -> mat2indsub -> ExtractSubset -> Extract_subset
 *   x[i, j, k]      rectangular -> ArraySubset/MatrixSubset -> Elt, per element
 *   x * 2, print(x) etc         -> Dataptr (materialize, guarded by an option)
 *
 * Extract_subset sees the whole index set at once, so it can plan: find the
 * unique chunks touched and fetch them in ONE call. The Elt path cannot plan;
 * it fetches chunks one at a time, as the subsetting loop happens to hit them.
 *
 * C_altarr_hyperslab() is what ArraySubset could do if it handed its already
 * normalized per-dimension subscripts ('subs') to an ALTREP method: plan the
 * cartesian product of touched chunks, fetch once, assemble.
 *
 * Fetch contract (R function):
 *   fetch(chunks) where 'chunks' is an integer matrix, one row per chunk,
 *   one column per dimension, 0-based chunk coordinates. It returns a list
 *   of numeric vectors, one per row, each the chunk's values in column-major
 *   order, clipped to the array edge (edge chunks are NOT padded).
 */

#include <string.h>
#include <stdlib.h>
#include <limits.h>
#include <float.h>
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Altrep.h>
#include <R_ext/Rdynload.h>

static R_altrep_class_t altarr_class;

/* data1: shared spec (shared by duplicates, so the cache is shared too) */
enum { S_DIM, S_CHUNK, S_FETCH, S_NCHUNK, S_CACHE, S_STATS, S_TICK, S_STATE,
       S_LEN };
/* S_TICK: per chunk, the clock value when it was last used (for LRU)
   S_STATE: c(clock, bytes currently cached, end of the last region read) */
/* counters */
enum { ST_ELT, ST_FETCH_CALLS, ST_CHUNKS_FETCHED, ST_EXTRACT,
       ST_HYPERSLAB, ST_MATERIALIZE, ST_REDUCE, ST_EVICT, ST_REGION, ST_LEN };
static const char *stat_names[ST_LEN] = {
    "elt", "fetch_calls", "chunks_fetched", "extract_subset",
    "hyperslab", "materialize", "reduce", "evictions", "region"
};
/* data2: the materialized vector, or R_NilValue */

#define SPEC(x) R_altrep_data1(x)

static inline void bump(SEXP spec, int k, double by)
{
    REAL(VECTOR_ELT(spec, S_STATS))[k] += by;
}

static R_xlen_t spec_length(SEXP spec)
{
    SEXP dim = VECTOR_ELT(spec, S_DIM);
    R_xlen_t n = 1;
    for (int d = 0; d < LENGTH(dim); d++) n *= INTEGER(dim)[d];
    return n;
}

/* chunk grid linear id (column-major over the chunk grid) of element li */
static R_xlen_t chunk_of(SEXP spec, R_xlen_t li)
{
    const int *dim = INTEGER(VECTOR_ELT(spec, S_DIM));
    const int *cs = INTEGER(VECTOR_ELT(spec, S_CHUNK));
    const int *nch = INTEGER(VECTOR_ELT(spec, S_NCHUNK));
    int k = LENGTH(VECTOR_ELT(spec, S_DIM));
    R_xlen_t cid = 0, cstride = 1;
    for (int d = 0; d < k; d++) {
        R_xlen_t idx = li % dim[d];
        li /= dim[d];
        cid += (idx / cs[d]) * cstride;
        cstride *= nch[d];
    }
    return cid;
}

/* number of values a chunk holds, clipped at the array edge */
static R_xlen_t chunk_size(SEXP spec, R_xlen_t cid)
{
    const int *dim = INTEGER(VECTOR_ELT(spec, S_DIM));
    const int *cs = INTEGER(VECTOR_ELT(spec, S_CHUNK));
    const int *nch = INTEGER(VECTOR_ELT(spec, S_NCHUNK));
    int k = LENGTH(VECTOR_ELT(spec, S_DIM));
    R_xlen_t n = 1;
    for (int d = 0; d < k; d++) {
        R_xlen_t cc = cid % nch[d];
        cid /= nch[d];
        R_xlen_t start = cc * cs[d];
        R_xlen_t ext = dim[d] - start;
        if (ext > cs[d]) ext = cs[d];
        n *= ext;
    }
    return n;
}

/* Call the R fetch function ONCE for chunks 'need[0..m)' and return a list
   of validated double vectors, one per chunk (caller protects). Nothing is
   cached here, so a reduction can stream through bounded memory. */
static SEXP fetch_raw(SEXP spec, const R_xlen_t *need, R_xlen_t m)
{
    if (m > INT_MAX) error("altarr: too many chunks in one request");
    int k = LENGTH(VECTOR_ELT(spec, S_DIM));
    const int *nch = INTEGER(VECTOR_ELT(spec, S_NCHUNK));
    SEXP mat = PROTECT(allocMatrix(INTSXP, (int) m, k));
    int *pm = INTEGER(mat);
    for (R_xlen_t j = 0; j < m; j++) {
        R_xlen_t rem = need[j];
        for (int d = 0; d < k; d++) {
            pm[j + d * m] = (int) (rem % nch[d]);
            rem /= nch[d];
        }
    }
    SEXP call = PROTECT(lang2(VECTOR_ELT(spec, S_FETCH), mat));
    SEXP res = PROTECT(eval(call, R_GlobalEnv));
    if (TYPEOF(res) != VECSXP || XLENGTH(res) != m)
        error("altarr: fetch() must return a list with one element per "
              "requested chunk (%lld requested)", (long long) m);
    SEXP out = PROTECT(allocVector(VECSXP, m));
    for (R_xlen_t j = 0; j < m; j++) {
        SEXP v = VECTOR_ELT(res, j);
        if (TYPEOF(v) != REALSXP) {
            if (!isNumeric(v) && !isLogical(v))
                error("altarr: fetch() returned a non-numeric chunk");
            v = coerceVector(v, REALSXP);
        }
        PROTECT(v);
        R_xlen_t want = chunk_size(spec, need[j]);
        if (XLENGTH(v) != want)
            error("altarr: chunk %lld has length %lld, expected %lld "
                  "(edge chunks must be clipped, not padded)",
                  (long long) need[j], (long long) XLENGTH(v),
                  (long long) want);
        SET_VECTOR_ELT(out, j, v);
        UNPROTECT(1);
    }
    bump(spec, ST_FETCH_CALLS, 1);
    bump(spec, ST_CHUNKS_FETCHED, (double) m);
    UNPROTECT(4);
    return out;
}

/* ---- the chunk cache: LRU with a byte budget --------------------------- */

/* Each request (Elt, Extract_subset, the hyperslab) asks get_chunks() for
   the chunks it needs and assembles from the list it gets back. The cache is
   only a place to keep chunks for later requests: it holds at most
   getOption("altarr.cache_bytes") bytes (default 256 MiB), evicting the
   least recently used chunks first. Because a request holds its own
   references, eviction can never take a chunk away from a request that is
   still using it. The budget is per array (per shared recipe: a copy and its
   original share one cache). */

#define CLOCK(spec) (REAL(VECTOR_ELT(spec, S_STATE))[0])
#define BYTES(spec) (REAL(VECTOR_ELT(spec, S_STATE))[1])

static double cache_budget(void)
{
    double b = asReal(GetOption1(install("altarr.cache_bytes")));
    if (ISNAN(b) || b < 0) b = 268435456.0;   /* 256 MiB */
    return b;
}

static void cache_put(SEXP spec, R_xlen_t cid, SEXP v)
{
    SEXP cache = VECTOR_ELT(spec, S_CACHE);
    if (VECTOR_ELT(cache, cid) != R_NilValue) return;
    SET_VECTOR_ELT(cache, cid, v);
    REAL(VECTOR_ELT(spec, S_TICK))[cid] = CLOCK(spec);
    BYTES(spec) += (double) XLENGTH(v) * sizeof(double);
}

static void cache_drop(SEXP spec, R_xlen_t cid)
{
    SEXP cache = VECTOR_ELT(spec, S_CACHE);
    SEXP v = VECTOR_ELT(cache, cid);
    if (v == R_NilValue) return;
    BYTES(spec) -= (double) XLENGTH(v) * sizeof(double);
    SET_VECTOR_ELT(cache, cid, R_NilValue);
}

typedef struct { double tick; R_xlen_t cid; } lru_entry;

static int lru_cmp(const void *a, const void *b)
{
    double ta = ((const lru_entry *) a)->tick, tb = ((const lru_entry *) b)->tick;
    return (ta > tb) - (ta < tb);
}

/* evict least recently used chunks until the cache fits its budget */
static void cache_trim(SEXP spec)
{
    double budget = cache_budget();
    if (BYTES(spec) <= budget) return;
    SEXP cache = VECTOR_ELT(spec, S_CACHE);
    const double *tick = REAL(VECTOR_ELT(spec, S_TICK));
    R_xlen_t nc = XLENGTH(cache), ncached = 0;
    for (R_xlen_t c = 0; c < nc; c++)
        if (VECTOR_ELT(cache, c) != R_NilValue) ncached++;
    lru_entry *e = (lru_entry *) R_alloc(ncached > 0 ? ncached : 1, sizeof(lru_entry));
    R_xlen_t j = 0;
    for (R_xlen_t c = 0; c < nc; c++)
        if (VECTOR_ELT(cache, c) != R_NilValue) { e[j].tick = tick[c]; e[j].cid = c; j++; }
    qsort(e, (size_t) ncached, sizeof(lru_entry), lru_cmp);
    for (j = 0; j < ncached && BYTES(spec) > budget; j++) {
        cache_drop(spec, e[j].cid);
        bump(spec, ST_EVICT, 1);
    }
    if (BYTES(spec) < 0.5) BYTES(spec) = 0;   /* keep float drift tidy */
}

static void cache_clear(SEXP spec)
{
    SEXP cache = VECTOR_ELT(spec, S_CACHE);
    for (R_xlen_t c = 0; c < XLENGTH(cache); c++)
        SET_VECTOR_ELT(cache, c, R_NilValue);
    SEXP tick = VECTOR_ELT(spec, S_TICK);
    memset(REAL(tick), 0, XLENGTH(tick) * sizeof(double));
    BYTES(spec) = 0;
}

/* The chunks cids[0..n) (unique), as a list aligned with cids. Cached ones
   are marked as just used; missing ones are fetched in ONE call and offered
   to the cache, which is then trimmed to its budget. Caller protects. */
static SEXP get_chunks(SEXP spec, const R_xlen_t *cids, R_xlen_t n)
{
    SEXP cache = VECTOR_ELT(spec, S_CACHE);
    double *tick = REAL(VECTOR_ELT(spec, S_TICK));
    double now = (CLOCK(spec) += 1);
    SEXP out = PROTECT(allocVector(VECSXP, n));
    R_xlen_t *need = (R_xlen_t *) R_alloc(n > 0 ? n : 1, sizeof(R_xlen_t));
    R_xlen_t *where = (R_xlen_t *) R_alloc(n > 0 ? n : 1, sizeof(R_xlen_t));
    R_xlen_t m = 0;
    for (R_xlen_t i = 0; i < n; i++) {
        SEXP c = VECTOR_ELT(cache, cids[i]);
        if (c != R_NilValue) {
            SET_VECTOR_ELT(out, i, c);
            tick[cids[i]] = now;
        } else {
            need[m] = cids[i];
            where[m] = i;
            m++;
        }
    }
    if (m > 0) {
        SEXP got = PROTECT(fetch_raw(spec, need, m));
        for (R_xlen_t j = 0; j < m; j++) {
            SET_VECTOR_ELT(out, where[j], VECTOR_ELT(got, j));
            cache_put(spec, need[j], VECTOR_ELT(got, j));
        }
        UNPROTECT(1);
        cache_trim(spec);
    }
    UNPROTECT(1);
    return out;
}

/* chunk id and offset within that chunk of element li (0-based) */
static void locate(SEXP spec, R_xlen_t li, R_xlen_t *cid_out, R_xlen_t *off_out)
{
    const int *dim = INTEGER(VECTOR_ELT(spec, S_DIM));
    const int *cs = INTEGER(VECTOR_ELT(spec, S_CHUNK));
    const int *nch = INTEGER(VECTOR_ELT(spec, S_NCHUNK));
    int k = LENGTH(VECTOR_ELT(spec, S_DIM));
    R_xlen_t cid = 0, cstride = 1, off = 0, ostride = 1;
    for (int d = 0; d < k; d++) {
        R_xlen_t idx = li % dim[d];
        li /= dim[d];
        R_xlen_t cc = idx / cs[d];
        R_xlen_t start = cc * cs[d];
        R_xlen_t ext = dim[d] - start;
        if (ext > cs[d]) ext = cs[d];
        cid += cc * cstride;
        cstride *= nch[d];
        off += (idx - start) * ostride;
        ostride *= ext;
    }
    *cid_out = cid;
    *off_out = off;
}

/* value of element li (0-based); fetches its chunk alone if not cached */
static double value_at(SEXP spec, R_xlen_t li)
{
    R_xlen_t cid, off;
    locate(spec, li, &cid, &off);
    SEXP ch = VECTOR_ELT(VECTOR_ELT(spec, S_CACHE), cid);
    if (ch != R_NilValue) {
        /* advance the clock so a hit always counts as more recent than
           anything fetched before it */
        REAL(VECTOR_ELT(spec, S_TICK))[cid] = (CLOCK(spec) += 1);
        return REAL(ch)[off];
    }
    SEXP got = PROTECT(get_chunks(spec, &cid, 1));
    double v = REAL(VECTOR_ELT(got, 0))[off];
    UNPROTECT(1);
    return v;
}

/* write chunk cid's values (clipped, column-major) into a full array */
static void scatter_chunk(SEXP spec, R_xlen_t cid, const double *v, double *dest)
{
    const int *dim = INTEGER(VECTOR_ELT(spec, S_DIM));
    const int *cs = INTEGER(VECTOR_ELT(spec, S_CHUNK));
    const int *nch = INTEGER(VECTOR_ELT(spec, S_NCHUNK));
    int k = LENGTH(VECTOR_ELT(spec, S_DIM));
    R_xlen_t *start = (R_xlen_t *) R_alloc(k, sizeof(R_xlen_t));
    R_xlen_t *ext = (R_xlen_t *) R_alloc(k, sizeof(R_xlen_t));
    R_xlen_t *gstride = (R_xlen_t *) R_alloc(k, sizeof(R_xlen_t));
    R_xlen_t *ctr = (R_xlen_t *) R_alloc(k, sizeof(R_xlen_t));
    R_xlen_t rem = cid, n = 1, gs = 1;
    for (int d = 0; d < k; d++) {
        R_xlen_t cc = rem % nch[d];
        rem /= nch[d];
        start[d] = cc * cs[d];
        ext[d] = dim[d] - start[d];
        if (ext[d] > cs[d]) ext[d] = cs[d];
        gstride[d] = gs;
        gs *= dim[d];
        n *= ext[d];
        ctr[d] = 0;
    }
    for (R_xlen_t i = 0; i < n; i++) {
        R_xlen_t g = 0;
        for (int d = 0; d < k; d++) g += (start[d] + ctr[d]) * gstride[d];
        dest[g] = v[i];
        for (int d = 0; d < k; d++) {
            if (++ctr[d] < ext[d]) break;
            ctr[d] = 0;
        }
    }
}

static R_xlen_t batch_chunks(void);

/* ---- ALTREP methods ---------------------------------------------------- */

static R_xlen_t altarr_Length(SEXP x)
{
    return spec_length(SPEC(x));
}

static double altarr_Elt(SEXP x, R_xlen_t i)
{
    SEXP d2 = R_altrep_data2(x);
    if (d2 != R_NilValue) return REAL(d2)[i];
    SEXP spec = SPEC(x);
    bump(spec, ST_ELT, 1);
    return value_at(spec, i);
}

static void *altarr_Dataptr(SEXP x, Rboolean writable)
{
    SEXP d2 = R_altrep_data2(x);
    if (d2 == R_NilValue) {
        SEXP spec = SPEC(x);
        R_xlen_t n = spec_length(spec);
        double maxn = asReal(GetOption1(install("altarr.max_materialize")));
        if (ISNAN(maxn)) maxn = 1e6;
        if ((double) n > maxn)
            error("altarr: refusing to materialize %.0f values "
                  "(option altarr.max_materialize = %.0f); "
                  "subset first, or raise the option", (double) n, maxn);
        bump(spec, ST_MATERIALIZE, 1);
        /* batch by batch straight into the result: cached chunks are used,
           the rest fetched without caching (the result holds them all) */
        SEXP cache = VECTOR_ELT(spec, S_CACHE);
        R_xlen_t nc = XLENGTH(cache), bsize = batch_chunks();
        R_xlen_t *need = (R_xlen_t *) R_alloc(bsize, sizeof(R_xlen_t));
        d2 = PROTECT(allocVector(REALSXP, n));
        double *p = REAL(d2);
        for (R_xlen_t b0 = 0; b0 < nc; b0 += bsize) {
            R_xlen_t b1 = b0 + bsize < nc ? b0 + bsize : nc, m = 0;
            for (R_xlen_t c = b0; c < b1; c++)
                if (VECTOR_ELT(cache, c) == R_NilValue) need[m++] = c;
            SEXP fresh = PROTECT(m > 0 ? fetch_raw(spec, need, m) : R_NilValue);
            R_xlen_t j = 0;
            for (R_xlen_t c = b0; c < b1; c++) {
                SEXP ch = VECTOR_ELT(cache, c);
                if (ch == R_NilValue) ch = VECTOR_ELT(fresh, j++);
                scatter_chunk(spec, c, REAL_RO(ch), p);
            }
            UNPROTECT(1);
        }
        R_set_altrep_data2(x, d2);
        UNPROTECT(1);
    }
    return (void *) REAL(d2);
}

static const void *altarr_Dataptr_or_null(SEXP x)
{
    SEXP d2 = R_altrep_data2(x);
    return d2 == R_NilValue ? NULL : (const void *) REAL(d2);
}

/* Index semantics match EXTRACT_SUBSET_LOOP in src/main/subset.c:
   1-based, out of range or NA gives NA. */
static SEXP altarr_Extract_subset(SEXP x, SEXP indx, SEXP call)
{
    if (R_altrep_data2(x) != R_NilValue) return NULL;
    if (TYPEOF(indx) != INTSXP && TYPEOF(indx) != REALSXP) return NULL;
    SEXP spec = SPEC(x);
    R_xlen_t n = XLENGTH(indx), nx = spec_length(spec);
    bump(spec, ST_EXTRACT, 1);

    /* pass 1: linear 0-based positions (-1 for NA) and unique chunks */
    R_xlen_t *li = (R_xlen_t *) R_alloc(n > 0 ? n : 1, sizeof(R_xlen_t));
    R_xlen_t nc = XLENGTH(VECTOR_ELT(spec, S_CACHE));
    R_xlen_t *pos = (R_xlen_t *) R_alloc(nc, sizeof(R_xlen_t));
    for (R_xlen_t c = 0; c < nc; c++) pos[c] = -1;
    R_xlen_t *cids = (R_xlen_t *) R_alloc(n > 0 ? n : 1, sizeof(R_xlen_t));
    R_xlen_t m = 0;
    for (R_xlen_t i = 0; i < n; i++) {
        R_xlen_t ii = -1;
        if (TYPEOF(indx) == INTSXP) {
            int v = INTEGER(indx)[i];
            if (0 < v && v <= nx) ii = v - 1;
        } else {
            double dv = REAL(indx)[i];
            if (R_FINITE(dv) && dv >= 1 && (R_xlen_t) (dv - 1) < nx)
                ii = (R_xlen_t) (dv - 1);
        }
        li[i] = ii;
        if (ii >= 0) {
            R_xlen_t cid = chunk_of(spec, ii);
            if (pos[cid] < 0) { pos[cid] = m; cids[m++] = cid; }
        }
    }
    /* one planned fetch for everything not cached */
    SEXP got = PROTECT(get_chunks(spec, cids, m));

    /* pass 2: assemble from this request's own chunks */
    SEXP res = PROTECT(allocVector(REALSXP, n));
    double *pr = REAL(res);
    for (R_xlen_t i = 0; i < n; i++) {
        if (li[i] < 0) { pr[i] = NA_REAL; continue; }
        R_xlen_t cid, off;
        locate(spec, li[i], &cid, &off);
        pr[i] = REAL(VECTOR_ELT(got, pos[cid]))[off];
    }
    UNPROTECT(2);
    return res;
}

static SEXP altarr_Duplicate(SEXP x, Rboolean deep)
{
    /* materialized: let R copy the data the ordinary way */
    if (R_altrep_data2(x) != R_NilValue) return NULL;
    /* lazy: a new wrapper over the same (immutable) recipe and cache;
       R copies the attributes */
    return R_new_altrep(altarr_class, SPEC(x), R_NilValue);
}

/* serialize the recipe, never the payload */
static SEXP altarr_Serialized_state(SEXP x)
{
    SEXP spec = SPEC(x);
    SEXP st = PROTECT(allocVector(VECSXP, 3));
    SET_VECTOR_ELT(st, 0, VECTOR_ELT(spec, S_DIM));
    SET_VECTOR_ELT(st, 1, VECTOR_ELT(spec, S_CHUNK));
    SET_VECTOR_ELT(st, 2, VECTOR_ELT(spec, S_FETCH));
    UNPROTECT(1);
    return st;
}

static SEXP make_spec(SEXP dim, SEXP chunk, SEXP fetch);

static SEXP altarr_Unserialize(SEXP class, SEXP state)
{
    SEXP spec = PROTECT(make_spec(VECTOR_ELT(state, 0),
                                  VECTOR_ELT(state, 1),
                                  VECTOR_ELT(state, 2)));
    SEXP x = R_new_altrep(altarr_class, spec, R_NilValue);
    UNPROTECT(1);
    return x;
}

static Rboolean altarr_Inspect(SEXP x, int pre, int deep, int pvec,
                             void (*inspect_subtree)(SEXP, int, int, int))
{
    SEXP spec = SPEC(x);
    SEXP dim = VECTOR_ELT(spec, S_DIM), cs = VECTOR_ELT(spec, S_CHUNK);
    Rprintf(" altarr dim [");
    for (int d = 0; d < LENGTH(dim); d++)
        Rprintf("%s%d", d ? "," : "", INTEGER(dim)[d]);
    Rprintf("] chunk [");
    for (int d = 0; d < LENGTH(cs); d++)
        Rprintf("%s%d", d ? "," : "", INTEGER(cs)[d]);
    Rprintf("] %s\n", R_altrep_data2(x) == R_NilValue ? "lazy" : "materialized");
    return TRUE;
}

/* ---- whole-array reductions ------------------------------------------- */

/* sum(), min() and max() with a single ALTREP argument go to these methods
   (do_summary in src/main/summary.c). They walk the chunk grid in batches
   of getOption("altarr.batch_chunks", 64) chunks: one fetch call per batch,
   using cached chunks where present and NOT caching the rest, so memory is
   bounded by the batch. The arithmetic mirrors base R's rsum/rmin/rmax:
   long double accumulation for sum; for min/max any NA trumps NaN. Chunks
   are visited in chunk order, so a sum can differ from base R's linear-order
   sum in the last bits. */

enum { RED_SUM, RED_MIN, RED_MAX };

static R_xlen_t batch_chunks(void)
{
    double b = asReal(GetOption1(install("altarr.batch_chunks")));
    if (ISNAN(b) || b < 1) b = 64;
    if (b > 1e6) b = 1e6;
    return (R_xlen_t) b;
}

static SEXP reduce_lazy(SEXP x, int op, Rboolean narm)
{
    if (R_altrep_data2(x) != R_NilValue) return NULL;   /* R has the data */
    SEXP spec = SPEC(x);
    SEXP cache = VECTOR_ELT(spec, S_CACHE);
    R_xlen_t nc = XLENGTH(cache), bsize = batch_chunks();
    R_xlen_t *need = (R_xlen_t *) R_alloc(bsize, sizeof(R_xlen_t));
    long double sum = 0;   /* R's internal LDOUBLE */
    double best = 0;
    Rboolean updated = FALSE;
    bump(spec, ST_REDUCE, 1);

    for (R_xlen_t b0 = 0; b0 < nc; b0 += bsize) {
        R_xlen_t b1 = b0 + bsize < nc ? b0 + bsize : nc, m = 0;
        for (R_xlen_t c = b0; c < b1; c++)
            if (VECTOR_ELT(cache, c) == R_NilValue) need[m++] = c;
        SEXP fresh = PROTECT(m > 0 ? fetch_raw(spec, need, m) : R_NilValue);
        R_xlen_t j = 0;
        for (R_xlen_t c = b0; c < b1; c++) {
            SEXP ch = VECTOR_ELT(cache, c);
            if (ch == R_NilValue) ch = VECTOR_ELT(fresh, j++);
            const double *v = REAL_RO(ch);
            R_xlen_t n = XLENGTH(ch);
            if (op == RED_SUM) {
                for (R_xlen_t i = 0; i < n; i++)
                    if (!narm || !ISNAN(v[i])) { updated = TRUE; sum += v[i]; }
            } else {
                for (R_xlen_t i = 0; i < n; i++) {
                    if (ISNAN(v[i])) {
                        if (!narm) {
                            if (!ISNA(best)) best = v[i];  /* NA trumps NaN */
                            updated = TRUE;
                        }
                    } else if (!updated ||
                               (op == RED_MIN ? v[i] < best : v[i] > best)) {
                        best = v[i];   /* never true once best is NA/NaN */
                        updated = TRUE;
                    }
                }
            }
        }
        UNPROTECT(1);
    }

    if (op == RED_SUM) {
        double r = sum > DBL_MAX ? R_PosInf :
                   sum < -DBL_MAX ? R_NegInf : (double) sum;
        return ScalarReal(r);
    }
    if (!updated) {   /* every value NA and na.rm = TRUE: as base R */
        warning(op == RED_MIN ?
                "no non-missing arguments to min; returning Inf" :
                "no non-missing arguments to max; returning -Inf");
        return ScalarReal(op == RED_MIN ? R_PosInf : R_NegInf);
    }
    return ScalarReal(best);
}

static SEXP altarr_Sum(SEXP x, Rboolean narm) { return reduce_lazy(x, RED_SUM, narm); }
static SEXP altarr_Min(SEXP x, Rboolean narm) { return reduce_lazy(x, RED_MIN, narm); }
static SEXP altarr_Max(SEXP x, Rboolean narm) { return reduce_lazy(x, RED_MAX, narm); }

/* ---- region reads: mean(), prod(), anyNA(), ... ------------------------ */

/* Functions that iterate by region (ITERATE_BY_REGION in R's sources: mean,
   prod, anyNA, and sum/min/max on R's wrapper class) ask for contiguous
   runs of elements, typically 512 at a time, from the start of the array to
   the end. A region read takes exactly the chunks its run touches, through
   get_chunks(), so eviction stays safe.

   A scan is detected when a region starts at 0 or exactly where the last
   one ended. Then, on a cache miss, the whole chunk "layer" the scan has
   entered is prefetched in batches of altarr.batch_chunks: all chunks that
   share the last dimension's chunk coordinate, which in column-major order
   is one contiguous block of the array. That happens only if the layer fits
   the cache budget; otherwise each region fetches just what it touches. For
   a 1-d array the "layer" is the next batch of chunks along the array.
   Isolated region requests (not part of a scan) never prefetch. */

static void prefetch_scan(SEXP spec, const R_xlen_t *u, R_xlen_t nu)
{
    SEXP cache = VECTOR_ELT(spec, S_CACHE);
    const int *cs = INTEGER(VECTOR_ELT(spec, S_CHUNK));
    const int *nch = INTEGER(VECTOR_ELT(spec, S_NCHUNK));
    int k = LENGTH(VECTOR_ELT(spec, S_DIM));
    R_xlen_t nc = XLENGTH(cache), bsize = batch_chunks();
    double chunk_bytes = sizeof(double);
    for (int d = 0; d < k; d++) chunk_bytes *= cs[d];
    R_xlen_t layer = 1;
    for (int d = 0; d < k - 1; d++) layer *= nch[d];
    R_xlen_t span = k == 1 ? bsize : layer;   /* chunks to prefetch at once */
    if ((double) span * chunk_bytes > cache_budget()) return;
    R_xlen_t *need = (R_xlen_t *) R_alloc(bsize, sizeof(R_xlen_t));
    R_xlen_t done_lo = -1, done_hi = -1;     /* last window prefetched */
    for (R_xlen_t j = 0; j < nu; j++) {
        if (VECTOR_ELT(cache, u[j]) != R_NilValue) continue;
        if (u[j] >= done_lo && u[j] < done_hi) continue;
        R_xlen_t lo = k == 1 ? u[j] : (u[j] / layer) * layer;
        R_xlen_t hi = lo + span < nc ? lo + span : nc;
        for (R_xlen_t b0 = lo; b0 < hi; b0 += bsize) {
            R_xlen_t b1 = b0 + bsize < hi ? b0 + bsize : hi, m = 0;
            for (R_xlen_t c = b0; c < b1; c++)
                if (VECTOR_ELT(cache, c) == R_NilValue) need[m++] = c;
            if (m > 0) get_chunks(spec, need, m);   /* result unused: now cached */
        }
        done_lo = lo;
        done_hi = hi;
    }
}

static R_xlen_t altarr_Get_region(SEXP x, R_xlen_t i, R_xlen_t n, double *buf)
{
    SEXP spec = SPEC(x);
    R_xlen_t len = spec_length(spec);
    if (i < 0 || i >= len || n <= 0) return 0;
    if (n > len - i) n = len - i;
    SEXP d2 = R_altrep_data2(x);
    if (d2 != R_NilValue) {
        memcpy(buf, REAL_RO(d2) + i, (size_t) n * sizeof(double));
        return n;
    }
    bump(spec, ST_REGION, 1);
    const int *dim = INTEGER(VECTOR_ELT(spec, S_DIM));
    const int *cs = INTEGER(VECTOR_ELT(spec, S_CHUNK));
    const int *nch = INTEGER(VECTOR_ELT(spec, S_NCHUNK));
    int k = LENGTH(VECTOR_ELT(spec, S_DIM));

    /* Walk the run with an odometer over (chunk coordinate, position within
       the chunk) per dimension: no divisions per element. Each element gets
       a slot in the list of distinct chunks the run touches; neighbours
       nearly always share a chunk, so the previous slot is checked first. */
    R_xlen_t *cc = (R_xlen_t *) R_alloc(k, sizeof(R_xlen_t));
    R_xlen_t *wp = (R_xlen_t *) R_alloc(k, sizeof(R_xlen_t));
    R_xlen_t *ext = (R_xlen_t *) R_alloc(k, sizeof(R_xlen_t));
    R_xlen_t *cstride = (R_xlen_t *) R_alloc(k, sizeof(R_xlen_t));
    R_xlen_t rem = i, cst = 1;
    for (int d = 0; d < k; d++) {
        R_xlen_t idx = rem % dim[d];
        rem /= dim[d];
        cc[d] = idx / cs[d];
        wp[d] = idx - cc[d] * cs[d];
        ext[d] = dim[d] - cc[d] * cs[d];
        if (ext[d] > cs[d]) ext[d] = cs[d];
        cstride[d] = cst;
        cst *= nch[d];
    }
    R_xlen_t *u = (R_xlen_t *) R_alloc(n, sizeof(R_xlen_t));     /* distinct chunks */
    R_xlen_t *slot = (R_xlen_t *) R_alloc(n, sizeof(R_xlen_t));
    R_xlen_t *off = (R_xlen_t *) R_alloc(n, sizeof(R_xlen_t));
    R_xlen_t nu = 0, last = -1;
    for (R_xlen_t e = 0; e < n; e++) {
        R_xlen_t cid = 0, o = 0, ostride = 1;
        for (int d = 0; d < k; d++) {
            cid += cc[d] * cstride[d];
            o += wp[d] * ostride;
            ostride *= ext[d];
        }
        R_xlen_t sl = -1;
        if (last >= 0 && u[last] == cid) sl = last;
        else {
            for (R_xlen_t q = 0; q < nu; q++) if (u[q] == cid) { sl = q; break; }
            if (sl < 0) { sl = nu; u[nu++] = cid; }
        }
        slot[e] = sl;
        off[e] = o;
        last = sl;
        /* next element: increment dimension 0, carrying upward */
        for (int d = 0; d < k; d++) {
            wp[d]++;
            if (cc[d] * cs[d] + wp[d] == dim[d]) {          /* wrapped this dim */
                cc[d] = 0; wp[d] = 0;
                ext[d] = dim[d] < cs[d] ? dim[d] : cs[d];
                continue;                                   /* carry */
            }
            if (wp[d] == ext[d]) {                          /* next chunk along d */
                cc[d]++; wp[d] = 0;
                ext[d] = dim[d] - cc[d] * cs[d];
                if (ext[d] > cs[d]) ext[d] = cs[d];
            }
            break;
        }
    }

    double *st = REAL(VECTOR_ELT(spec, S_STATE));
    int scanning = (i == 0) || ((double) i == st[2]);
    st[2] = (double) (i + n);
    if (scanning) prefetch_scan(spec, u, nu);

    SEXP got = PROTECT(get_chunks(spec, u, nu));
    for (R_xlen_t e = 0; e < n; e++)
        buf[e] = REAL_RO(VECTOR_ELT(got, slot[e]))[off[e]];
    UNPROTECT(1);
    return n;
}

/* REAL_GET_REGION from R, for tests: goes through ALTREP dispatch (and
   through R's wrapper class, if x is wrapped) exactly as R's own code does */
static SEXP C_altarr_region(SEXP x, SEXP i, SEXP n)
{
    R_xlen_t ii = (R_xlen_t) asReal(i), nn = (R_xlen_t) asReal(n);
    SEXP out = PROTECT(allocVector(REALSXP, nn > 0 ? nn : 0));
    R_xlen_t got = nn > 0 ? REAL_GET_REGION(x, ii, nn, REAL(out)) : 0;
    SEXP res = PROTECT(xlengthgets(out, got));
    UNPROTECT(2);
    return res;
}

/* ---- construction ------------------------------------------------------ */

static SEXP make_spec(SEXP dim, SEXP chunk, SEXP fetch)
{
    if (TYPEOF(dim) != INTSXP || TYPEOF(chunk) != INTSXP ||
        LENGTH(dim) != LENGTH(chunk) || LENGTH(dim) < 1)
        error("altarr: 'dim' and 'chunk' must be integer vectors of equal length");
    if (!isFunction(fetch)) error("altarr: 'fetch' must be a function");
    int k = LENGTH(dim);
    SEXP nch = PROTECT(allocVector(INTSXP, k));
    double total = 1, len = 1;
    for (int d = 0; d < k; d++) {
        int dd = INTEGER(dim)[d], cc = INTEGER(chunk)[d];
        if (dd == NA_INTEGER || dd < 1 || cc == NA_INTEGER || cc < 1)
            error("altarr: dims and chunk sizes must be positive");
        INTEGER(nch)[d] = (dd + cc - 1) / cc;
        total *= INTEGER(nch)[d];
        len *= dd;
    }
    /* A virtual array is never allocated, so its size is limited only by
       R's maximum vector length (2^52 values), which Length() must respect. */
    if (len > (double) R_XLEN_T_MAX)
        error("altarr: array has %.0f values, more than R's maximum vector "
              "length (%.0f)", len, (double) R_XLEN_T_MAX);
    if (total > R_XLEN_T_MAX) error("altarr: chunk grid too large");
    SEXP spec = PROTECT(allocVector(VECSXP, S_LEN));
    SET_VECTOR_ELT(spec, S_DIM, dim);
    SET_VECTOR_ELT(spec, S_CHUNK, chunk);
    SET_VECTOR_ELT(spec, S_FETCH, fetch);
    SET_VECTOR_ELT(spec, S_NCHUNK, nch);
    SET_VECTOR_ELT(spec, S_CACHE, allocVector(VECSXP, (R_xlen_t) total));
    SEXP stats = allocVector(REALSXP, ST_LEN);
    SET_VECTOR_ELT(spec, S_STATS, stats);
    memset(REAL(stats), 0, ST_LEN * sizeof(double));
    SEXP tick = allocVector(REALSXP, (R_xlen_t) total);
    SET_VECTOR_ELT(spec, S_TICK, tick);
    memset(REAL(tick), 0, (size_t) total * sizeof(double));
    SEXP state = allocVector(REALSXP, 3);
    SET_VECTOR_ELT(spec, S_STATE, state);
    REAL(state)[0] = 0;
    REAL(state)[1] = 0;
    REAL(state)[2] = -1;
    UNPROTECT(2);
    return spec;
}

static SEXP C_altarr_new(SEXP dim, SEXP chunk, SEXP fetch)
{
    SEXP spec = PROTECT(make_spec(dim, chunk, fetch));
    SEXP x = PROTECT(R_new_altrep(altarr_class, spec, R_NilValue));
    setAttrib(x, R_DimSymbol, duplicate(dim));
    UNPROTECT(2);
    return x;
}

/* R wraps an ALTREP object in one of its own 'wrapper' ALTREP classes when
   attributes are changed on a shared object (e.g. dimnames(y) <- ... after
   y <- x). In R's implementation (src/main/altclasses.c) the wrapper's data1
   is the wrapped vector, so we look through it. That layout is not part of
   the documented ALTREP API, so each step is checked: a wrapper has the same
   type and length as what it wraps. If a future R changes the layout, this
   returns R_NilValue and the R-level helpers report "not an altarr array"
   rather than misreading memory. Arrays themselves keep working either way;
   only the introspection helpers depend on this. */
static SEXP find_altarr(SEXP x)
{
    if (x == R_NilValue || !ALTREP(x)) return R_NilValue;
    int type = TYPEOF(x);
    R_xlen_t len = XLENGTH(x);
    for (int depth = 0; depth < 4; depth++) {
        if (R_altrep_inherits(x, altarr_class)) return x;
        SEXP inner = R_altrep_data1(x);
        if (inner == R_NilValue || !ALTREP(inner) || TYPEOF(inner) != type ||
            XLENGTH(inner) != len)
            return R_NilValue;
        x = inner;
    }
    return R_NilValue;
}

static SEXP check_altarr(SEXP x)
{
    SEXP s = find_altarr(x);
    if (s == R_NilValue)
        error("altarr: not an altarr array (it may have been copied "
              "into an ordinary vector)");
    return s;
}

static SEXP C_altarr_is(SEXP x)
{
    return ScalarLogical(find_altarr(x) != R_NilValue);
}

static SEXP C_altarr_wrapped(SEXP x)
{
    SEXP s = find_altarr(x);
    return ScalarLogical(s != R_NilValue && s != x);
}

static SEXP C_altarr_info(SEXP x)
{
    x = check_altarr(x);
    SEXP spec = SPEC(x);
    SEXP st = VECTOR_ELT(spec, S_STATS);
    SEXP cache = VECTOR_ELT(spec, S_CACHE);
    SEXP out = PROTECT(allocVector(REALSXP, ST_LEN + 5));
    SEXP nm = PROTECT(allocVector(STRSXP, ST_LEN + 5));
    for (int i = 0; i < ST_LEN; i++) {
        REAL(out)[i] = REAL(st)[i];
        SET_STRING_ELT(nm, i, mkChar(stat_names[i]));
    }
    R_xlen_t cached = 0;
    for (R_xlen_t i = 0; i < XLENGTH(cache); i++)
        if (VECTOR_ELT(cache, i) != R_NilValue) cached++;
    REAL(out)[ST_LEN] = (double) cached;
    REAL(out)[ST_LEN + 1] = (double) XLENGTH(cache);
    REAL(out)[ST_LEN + 2] = R_altrep_data2(x) != R_NilValue;
    SET_STRING_ELT(nm, ST_LEN, mkChar("chunks_cached"));
    SET_STRING_ELT(nm, ST_LEN + 1, mkChar("chunks_total"));
    SET_STRING_ELT(nm, ST_LEN + 2, mkChar("materialized"));
    REAL(out)[ST_LEN + 3] = BYTES(spec);
    REAL(out)[ST_LEN + 4] = cache_budget();
    SET_STRING_ELT(nm, ST_LEN + 3, mkChar("cache_bytes"));
    SET_STRING_ELT(nm, ST_LEN + 4, mkChar("cache_budget"));
    setAttrib(out, R_NamesSymbol, nm);
    UNPROTECT(2);
    return out;
}

static SEXP C_altarr_chunk(SEXP x)
{
    x = check_altarr(x);
    return duplicate(VECTOR_ELT(SPEC(x), S_CHUNK));
}

static SEXP C_altarr_reset(SEXP x, SEXP drop_cache)
{
    x = check_altarr(x);
    SEXP spec = SPEC(x);
    memset(REAL(VECTOR_ELT(spec, S_STATS)), 0, ST_LEN * sizeof(double));
    if (asLogical(drop_cache) == TRUE) cache_clear(spec);
    return R_NilValue;
}

/* What ArraySubset could do with its 'subs': plan, fetch once, assemble.
   'subs' is a list of 1-based integer index vectors (NA allowed), one per
   dimension, already normalized by R's own indexing rules. */
static SEXP C_altarr_hyperslab(SEXP x, SEXP subs)
{
    x = check_altarr(x);
    SEXP spec = SPEC(x);
    const int *dim = INTEGER(VECTOR_ELT(spec, S_DIM));
    const int *cs = INTEGER(VECTOR_ELT(spec, S_CHUNK));
    const int *nch = INTEGER(VECTOR_ELT(spec, S_NCHUNK));
    int k = LENGTH(VECTOR_ELT(spec, S_DIM));
    if (TYPEOF(subs) != VECSXP || LENGTH(subs) != k)
        error("altarr: need one index vector per dimension");

    int **ix = (int **) R_alloc(k, sizeof(int *));
    int *len = (int *) R_alloc(k, sizeof(int));
    int **uniq = (int **) R_alloc(k, sizeof(int *));
    int *nuniq = (int *) R_alloc(k, sizeof(int));
    int **upos = (int **) R_alloc(k, sizeof(int *));   /* chunk coord -> index in uniq */
    R_xlen_t n = 1;
    for (int d = 0; d < k; d++) {
        SEXP s = VECTOR_ELT(subs, d);
        if (TYPEOF(s) != INTSXP) error("altarr: indices must be integer");
        ix[d] = INTEGER(s);
        len[d] = LENGTH(s);
        n *= len[d];
        /* unique chunk coordinates touched along this dimension */
        char *seen = R_alloc(nch[d], 1);
        memset(seen, 0, nch[d]);
        uniq[d] = (int *) R_alloc(nch[d], sizeof(int));
        upos[d] = (int *) R_alloc(nch[d], sizeof(int));
        nuniq[d] = 0;
        for (int j = 0; j < len[d]; j++) {
            int v = ix[d][j];
            if (v == NA_INTEGER) continue;
            if (v < 1 || v > dim[d]) error("altarr: subscript out of bounds");
            int cc = (v - 1) / cs[d];
            if (!seen[cc]) {
                seen[cc] = 1;
                upos[d][cc] = nuniq[d];
                uniq[d][nuniq[d]++] = cc;
            }
        }
    }
    bump(spec, ST_HYPERSLAB, 1);

    /* plan: cartesian product of touched chunks, fetched in one call */
    R_xlen_t np = 1;
    R_xlen_t *pstride = (R_xlen_t *) R_alloc(k, sizeof(R_xlen_t));
    for (int d = 0; d < k; d++) { pstride[d] = np; np *= nuniq[d]; }
    SEXP got = R_NilValue;
    if (np > 0) {
        R_xlen_t *cids = (R_xlen_t *) R_alloc(np, sizeof(R_xlen_t));
        int *ctr = (int *) R_alloc(k, sizeof(int));
        memset(ctr, 0, k * sizeof(int));
        for (R_xlen_t p = 0; p < np; p++) {
            R_xlen_t cid = 0, cstride = 1;
            for (int d = 0; d < k; d++) {
                cid += (R_xlen_t) uniq[d][ctr[d]] * cstride;
                cstride *= nch[d];
            }
            cids[p] = cid;
            for (int d = 0; d < k; d++) {
                if (++ctr[d] < nuniq[d]) break;
                ctr[d] = 0;
            }
        }
        got = get_chunks(spec, cids, np);
    }
    PROTECT(got);

    /* assemble in result column-major order */
    SEXP res = PROTECT(allocVector(REALSXP, n));
    double *pr = REAL(res);
    if (n > 0) {
        int *ctr = (int *) R_alloc(k, sizeof(int));
        memset(ctr, 0, k * sizeof(int));
        for (R_xlen_t i = 0; i < n; i++) {
            R_xlen_t pidx = 0, off = 0, ostride = 1;
            int na = 0;
            for (int d = 0; d < k; d++) {
                int v = ix[d][ctr[d]];
                if (v == NA_INTEGER) { na = 1; break; }
                R_xlen_t idx = v - 1, cc = idx / cs[d];
                R_xlen_t start = cc * cs[d], ext = dim[d] - start;
                if (ext > cs[d]) ext = cs[d];
                pidx += upos[d][cc] * pstride[d];
                off += (idx - start) * ostride;
                ostride *= ext;
            }
            pr[i] = na ? NA_REAL : REAL(VECTOR_ELT(got, pidx))[off];
            for (int d = 0; d < k; d++) {
                if (++ctr[d] < len[d]) break;
                ctr[d] = 0;
            }
        }
    }
    SEXP rdim = PROTECT(allocVector(INTSXP, k));
    for (int d = 0; d < k; d++) INTEGER(rdim)[d] = len[d];
    setAttrib(res, R_DimSymbol, rdim);
    UNPROTECT(3);
    return res;
}

static const R_CallMethodDef CallEntries[] = {
    {"C_altarr_region", (DL_FUNC) &C_altarr_region, 3},
    {"C_altarr_new", (DL_FUNC) &C_altarr_new, 3},
    {"C_altarr_is", (DL_FUNC) &C_altarr_is, 1},
    {"C_altarr_info", (DL_FUNC) &C_altarr_info, 1},
    {"C_altarr_reset", (DL_FUNC) &C_altarr_reset, 2},
    {"C_altarr_chunk", (DL_FUNC) &C_altarr_chunk, 1},
    {"C_altarr_wrapped", (DL_FUNC) &C_altarr_wrapped, 1},
    {"C_altarr_hyperslab", (DL_FUNC) &C_altarr_hyperslab, 2},
    {NULL, NULL, 0}
};

void R_init_altarr(DllInfo *dll)
{
    altarr_class = R_make_altreal_class("altarr_real", "altarr", dll);
    R_set_altrep_Length_method(altarr_class, altarr_Length);
    R_set_altrep_Inspect_method(altarr_class, altarr_Inspect);
    R_set_altrep_Duplicate_method(altarr_class, altarr_Duplicate);
    R_set_altrep_Serialized_state_method(altarr_class, altarr_Serialized_state);
    R_set_altrep_Unserialize_method(altarr_class, altarr_Unserialize);
    R_set_altvec_Dataptr_method(altarr_class, altarr_Dataptr);
    R_set_altvec_Dataptr_or_null_method(altarr_class, altarr_Dataptr_or_null);
    R_set_altvec_Extract_subset_method(altarr_class, altarr_Extract_subset);
    R_set_altreal_Elt_method(altarr_class, altarr_Elt);
    R_set_altreal_Get_region_method(altarr_class, altarr_Get_region);
    R_set_altreal_Sum_method(altarr_class, altarr_Sum);
    R_set_altreal_Min_method(altarr_class, altarr_Min);
    R_set_altreal_Max_method(altarr_class, altarr_Max);

    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
}
