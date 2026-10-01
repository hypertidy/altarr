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
#include <limits.h>
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Altrep.h>
#include <R_ext/Rdynload.h>

static R_altrep_class_t altarr_class;

/* data1: shared spec (shared by duplicates, so the cache is shared too) */
enum { S_DIM, S_CHUNK, S_FETCH, S_NCHUNK, S_CACHE, S_STATS, S_LEN };
/* counters */
enum { ST_ELT, ST_FETCH_CALLS, ST_CHUNKS_FETCHED, ST_EXTRACT,
       ST_HYPERSLAB, ST_MATERIALIZE, ST_LEN };
static const char *stat_names[ST_LEN] = {
    "elt", "fetch_calls", "chunks_fetched", "extract_subset",
    "hyperslab", "materialize"
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

/* Fetch the not-yet-cached chunks among 'cids' (assumed unique) in ONE call
   to the R fetch function. */
static void fetch_chunks(SEXP spec, const R_xlen_t *cids, R_xlen_t n)
{
    SEXP cache = VECTOR_ELT(spec, S_CACHE);
    R_xlen_t *need = (R_xlen_t *) R_alloc(n > 0 ? n : 1, sizeof(R_xlen_t));
    R_xlen_t m = 0;
    for (R_xlen_t i = 0; i < n; i++)
        if (VECTOR_ELT(cache, cids[i]) == R_NilValue) need[m++] = cids[i];
    if (m == 0) return;
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
        SET_VECTOR_ELT(cache, need[j], v);
        UNPROTECT(1);
    }
    bump(spec, ST_FETCH_CALLS, 1);
    bump(spec, ST_CHUNKS_FETCHED, (double) m);
    UNPROTECT(3);
}

/* value of element li (0-based); fetches its chunk alone if not cached */
static double value_at(SEXP spec, R_xlen_t li)
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
    SEXP cache = VECTOR_ELT(spec, S_CACHE);
    SEXP ch = VECTOR_ELT(cache, cid);
    if (ch == R_NilValue) {
        fetch_chunks(spec, &cid, 1);
        ch = VECTOR_ELT(cache, cid);
    }
    return REAL(ch)[off];
}

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
        R_xlen_t nc = XLENGTH(VECTOR_ELT(spec, S_CACHE));
        R_xlen_t *cids = (R_xlen_t *) R_alloc(nc, sizeof(R_xlen_t));
        for (R_xlen_t i = 0; i < nc; i++) cids[i] = i;
        fetch_chunks(spec, cids, nc);
        d2 = PROTECT(allocVector(REALSXP, n));
        double *p = REAL(d2);
        for (R_xlen_t i = 0; i < n; i++) p[i] = value_at(spec, i);
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
    char *seen = R_alloc(nc, 1);
    memset(seen, 0, nc);
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
            if (!seen[cid]) { seen[cid] = 1; cids[m++] = cid; }
        }
    }
    /* one planned fetch for everything not cached */
    fetch_chunks(spec, cids, m);

    /* pass 2: assemble */
    SEXP res = PROTECT(allocVector(REALSXP, n));
    double *pr = REAL(res);
    for (R_xlen_t i = 0; i < n; i++)
        pr[i] = li[i] >= 0 ? value_at(spec, li[i]) : NA_REAL;
    UNPROTECT(1);
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
   y <- x). The wrapper's data1 is the wrapped object, so look through. */
static SEXP find_altarr(SEXP x)
{
    for (int depth = 0; depth < 8 && x != R_NilValue && ALTREP(x); depth++) {
        if (R_altrep_inherits(x, altarr_class)) return x;
        x = R_altrep_data1(x);
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
    SEXP out = PROTECT(allocVector(REALSXP, ST_LEN + 3));
    SEXP nm = PROTECT(allocVector(STRSXP, ST_LEN + 3));
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
    if (asLogical(drop_cache) == TRUE) {
        SEXP cache = VECTOR_ELT(spec, S_CACHE);
        for (R_xlen_t i = 0; i < XLENGTH(cache); i++)
            SET_VECTOR_ELT(cache, i, R_NilValue);
    }
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
        nuniq[d] = 0;
        for (int j = 0; j < len[d]; j++) {
            int v = ix[d][j];
            if (v == NA_INTEGER) continue;
            if (v < 1 || v > dim[d]) error("altarr: subscript out of bounds");
            int cc = (v - 1) / cs[d];
            if (!seen[cc]) { seen[cc] = 1; uniq[d][nuniq[d]++] = cc; }
        }
    }
    bump(spec, ST_HYPERSLAB, 1);

    /* plan: cartesian product of touched chunks, fetched in one call */
    R_xlen_t np = 1;
    for (int d = 0; d < k; d++) np *= nuniq[d];
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
        fetch_chunks(spec, cids, np);
    }

    /* assemble in result column-major order */
    SEXP res = PROTECT(allocVector(REALSXP, n));
    double *pr = REAL(res);
    if (n > 0) {
        int *ctr = (int *) R_alloc(k, sizeof(int));
        memset(ctr, 0, k * sizeof(int));
        SEXP cache = VECTOR_ELT(spec, S_CACHE);
        for (R_xlen_t i = 0; i < n; i++) {
            R_xlen_t cid = 0, cstride = 1, off = 0, ostride = 1;
            int na = 0;
            for (int d = 0; d < k; d++) {
                int v = ix[d][ctr[d]];
                if (v == NA_INTEGER) { na = 1; break; }
                R_xlen_t idx = v - 1, cc = idx / cs[d];
                R_xlen_t start = cc * cs[d], ext = dim[d] - start;
                if (ext > cs[d]) ext = cs[d];
                cid += cc * cstride;
                cstride *= nch[d];
                off += (idx - start) * ostride;
                ostride *= ext;
            }
            pr[i] = na ? NA_REAL : REAL(VECTOR_ELT(cache, cid))[off];
            for (int d = 0; d < k; d++) {
                if (++ctr[d] < len[d]) break;
                ctr[d] = 0;
            }
        }
    }
    SEXP rdim = PROTECT(allocVector(INTSXP, k));
    for (int d = 0; d < k; d++) INTEGER(rdim)[d] = len[d];
    setAttrib(res, R_DimSymbol, rdim);
    UNPROTECT(2);
    return res;
}

static const R_CallMethodDef CallEntries[] = {
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

    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
}
