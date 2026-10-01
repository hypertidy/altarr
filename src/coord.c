/*
 * Lazy coordinates: an ALTREP character vector holding only
 * (offset, step, n). Element i is the label for offset + step * i,
 * formatted on demand with "%.15g". A regular slice of it (constant
 * stride, no NA) is again a lazy coordinate, so base R's `[` on an array
 * carries numeric coordinates along without ever building the strings.
 *
 * Dimnames must be character, and `[` subsets dimnames with the same
 * ExtractSubset() it uses for data, which offers ALTREP Extract_subset
 * first. That is the whole trick.
 */

#include <math.h>
#include <stdio.h>
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Altrep.h>
#include <R_ext/Rdynload.h>

static R_altrep_class_t coord_class;

/* data1: REALSXP c(offset, step); length lives in data1 too: c(offset, step, n)
   data2: materialized STRSXP or R_NilValue */
enum { C_OFFSET, C_STEP, C_N, C_LEN };

static inline double coord_get(SEXP x, int k)
{
    return REAL(R_altrep_data1(x))[k];
}

static SEXP coord_label(double v)
{
    char buf[64];
    if (v == 0) v = 0; /* no "-0" */
    snprintf(buf, sizeof(buf), "%.15g", v);
    return mkChar(buf);
}

static SEXP make_coord(double offset, double step, R_xlen_t n)
{
    SEXP st = PROTECT(allocVector(REALSXP, C_LEN));
    REAL(st)[C_OFFSET] = offset;
    REAL(st)[C_STEP] = step;
    REAL(st)[C_N] = (double) n;
    SEXP x = R_new_altrep(coord_class, st, R_NilValue);
    UNPROTECT(1);
    return x;
}

static R_xlen_t coord_Length(SEXP x)
{
    return (R_xlen_t) coord_get(x, C_N);
}

static SEXP coord_Elt(SEXP x, R_xlen_t i)
{
    SEXP d2 = R_altrep_data2(x);
    if (d2 != R_NilValue) return STRING_ELT(d2, i);
    return coord_label(coord_get(x, C_OFFSET) + coord_get(x, C_STEP) * (double) i);
}

static SEXP coord_materialize(SEXP x)
{
    SEXP d2 = R_altrep_data2(x);
    if (d2 == R_NilValue) {
        R_xlen_t n = coord_Length(x);
        double o = coord_get(x, C_OFFSET), s = coord_get(x, C_STEP);
        d2 = PROTECT(allocVector(STRSXP, n));
        for (R_xlen_t i = 0; i < n; i++)
            SET_STRING_ELT(d2, i, coord_label(o + s * (double) i));
        R_set_altrep_data2(x, d2);
        UNPROTECT(1);
    }
    return d2;
}

static void coord_Set_elt(SEXP x, R_xlen_t i, SEXP v)
{
    SET_STRING_ELT(coord_materialize(x), i, v);
}

static void *coord_Dataptr(SEXP x, Rboolean writable)
{
    return (void *) STRING_PTR_RO(coord_materialize(x));
}

static const void *coord_Dataptr_or_null(SEXP x)
{
    SEXP d2 = R_altrep_data2(x);
    return d2 == R_NilValue ? NULL : (const void *) STRING_PTR_RO(d2);
}

/* A regular slice (constant stride, all in range, no NA) stays lazy.
   Anything else returns NULL, and R falls back to Elt for just those. */
static SEXP coord_Extract_subset(SEXP x, SEXP indx, SEXP call)
{
    if (R_altrep_data2(x) != R_NilValue) return NULL;
    R_xlen_t m = XLENGTH(indx), n = coord_Length(x);
    if (m < 1) return NULL;
    double first = 0, prev = 0, stride = 0;
    for (R_xlen_t i = 0; i < m; i++) {
        double v;
        if (TYPEOF(indx) == INTSXP) {
            int iv = INTEGER(indx)[i];
            if (iv == NA_INTEGER) return NULL;
            v = iv;
        } else if (TYPEOF(indx) == REALSXP) {
            v = REAL(indx)[i];
            if (!R_FINITE(v)) return NULL;
            v = floor(v);
        } else return NULL;
        if (v < 1 || v > (double) n) return NULL;
        if (i == 0) first = v;
        else if (i == 1) stride = v - prev;
        else if (v - prev != stride) return NULL;
        prev = v;
    }
    double o = coord_get(x, C_OFFSET), s = coord_get(x, C_STEP);
    return make_coord(o + s * (first - 1), s * stride, m);
}

static SEXP coord_Duplicate(SEXP x, Rboolean deep)
{
    if (R_altrep_data2(x) != R_NilValue) return NULL;
    return make_coord(coord_get(x, C_OFFSET), coord_get(x, C_STEP),
                      coord_Length(x));
}

static int coord_No_NA(SEXP x)
{
    return R_altrep_data2(x) == R_NilValue;
}

static SEXP coord_Serialized_state(SEXP x)
{
    if (R_altrep_data2(x) != R_NilValue) return NULL; /* write plain strings */
    return R_altrep_data1(x);
}

static SEXP coord_Unserialize(SEXP class, SEXP state)
{
    return make_coord(REAL(state)[C_OFFSET], REAL(state)[C_STEP],
                      (R_xlen_t) REAL(state)[C_N]);
}

static Rboolean coord_Inspect(SEXP x, int pre, int deep, int pvec,
                              void (*inspect_subtree)(SEXP, int, int, int))
{
    Rprintf(" altarr coord offset=%.15g step=%.15g n=%.0f %s\n",
            coord_get(x, C_OFFSET), coord_get(x, C_STEP), coord_get(x, C_N),
            R_altrep_data2(x) == R_NilValue ? "lazy" : "materialized");
    return TRUE;
}

/* ---- entry points ------------------------------------------------------ */

SEXP C_coord_new(SEXP offset, SEXP step, SEXP n)
{
    double nn = asReal(n), o = asReal(offset), s = asReal(step);
    if (!R_FINITE(o) || !R_FINITE(s) || !R_FINITE(nn) || nn < 0)
        error("altarr: coordinate offset, step and n must be finite, n >= 0");
    if (nn > R_XLEN_T_MAX) error("altarr: too many coordinates");
    return make_coord(o, s, (R_xlen_t) nn);
}

/* c(offset, step, n) for a lazy coordinate, else NULL */
SEXP C_coord_info(SEXP x)
{
    if (!ALTREP(x) || !R_altrep_inherits(x, coord_class)) return R_NilValue;
    SEXP out = PROTECT(allocVector(REALSXP, 3));
    REAL(out)[0] = coord_get(x, C_OFFSET);
    REAL(out)[1] = coord_get(x, C_STEP);
    REAL(out)[2] = coord_get(x, C_N);
    SEXP nm = PROTECT(allocVector(STRSXP, 3));
    SET_STRING_ELT(nm, 0, mkChar("offset"));
    SET_STRING_ELT(nm, 1, mkChar("step"));
    SET_STRING_ELT(nm, 2, mkChar("n"));
    setAttrib(out, R_NamesSymbol, nm);
    SEXP mat = PROTECT(ScalarLogical(R_altrep_data2(x) != R_NilValue));
    setAttrib(out, install("materialized"), mat);
    UNPROTECT(3);
    return out;
}

void altarr_init_coord(DllInfo *dll)
{
    coord_class = R_make_altstring_class("altarr_coord", "altarr", dll);
    R_set_altrep_Length_method(coord_class, coord_Length);
    R_set_altrep_Inspect_method(coord_class, coord_Inspect);
    R_set_altrep_Duplicate_method(coord_class, coord_Duplicate);
    R_set_altrep_Serialized_state_method(coord_class, coord_Serialized_state);
    R_set_altrep_Unserialize_method(coord_class, coord_Unserialize);
    R_set_altvec_Dataptr_method(coord_class, coord_Dataptr);
    R_set_altvec_Dataptr_or_null_method(coord_class, coord_Dataptr_or_null);
    R_set_altvec_Extract_subset_method(coord_class, coord_Extract_subset);
    R_set_altstring_Elt_method(coord_class, coord_Elt);
    R_set_altstring_Set_elt_method(coord_class, coord_Set_elt);
    R_set_altstring_No_NA_method(coord_class, coord_No_NA);
}
