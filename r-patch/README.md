# The proposed R patch: an ALTREP array-subset method

`0001-ALTREP-Extract_array_subset.patch` adds one optional ALTREP method to
R, `Extract_array_subset`. When R evaluates `x[i, j, ...]` on an ALTREP
array, `MatrixSubset()` and `ArraySubset()` in `src/main/subset.c` first
offer the method the subscripts they have already normalized (one 1-based
integer vector per dimension, `NA` allowed). A class backed by chunked or
remote storage can then plan one read instead of answering one element at a
time. If the method returns `NULL`, or the class has none, R extracts
element by element exactly as before.

The patch is against R-devel svn r90638 (2026-10-03), git mirror commit
`d75f6a2224865f9ac0bee065de99af817a3a65e6` of
<https://github.com/wch/r-source>. It touches 6 files and adds about 100
lines.

## What R keeps doing

* It normalizes subscripts with `int_arraySubscript()`: negative, logical,
  character and missing subscripts all arrive as positive integers.
* It checks bounds, so the method only ever sees in-range indices or `NA`.
* It sets `dim`, `dimnames` and `drop` on the result.
* It validates the method's result (type, length, no attributes), and
  duplicates the result if the method returns a referenced object.

## What the method is

```c
/* R_ext/Altrep.h */
typedef SEXP (*R_altvec_Extract_array_subset_method_t)(SEXP x, SEXP subs,
                                                       SEXP dim, SEXP call);
void R_set_altvec_Extract_array_subset_method(R_altrep_class_t cls,
                         R_altvec_Extract_array_subset_method_t fun);
#define R_ALTREP_HAS_EXTRACT_ARRAY_SUBSET 1
```

`dim` is passed explicitly because R's wrapper objects (made by
`dimnames<-` and friends) hold the attributes, not the wrapped object.
Wrappers forward the method to the wrapped object. A class can decline
when `dim` is not what it expects, for example after `dim(x) <- ...`, and
R's element loop gives the right answer.

## Compatibility

* **No ABI change for packages.** R allocates each class's method table
  (`allocVector(RAWSXP, sizeof(...))` in `altrep.c`), and packages only
  call setters. Adding a method does not move anything a package can see.
* **No behaviour change for existing classes.** The default method returns
  `NULL`. This covers base R's compact sequences, deferred strings, wrappers
  around non-ALTREP objects, and every package class that does not set the
  method.
* **Packages opt in at compile time** with
  `#ifdef R_ALTREP_HAS_EXTRACT_ARRAY_SUBSET`, so one package source works on
  any R.

## Checked

* `make check` on the patched R-devel passes. The internet and Latin-1
  locale tests fail without network or that locale, as R expects. See
  the `r-hook` workflow for a clean run.
* altarr's test suite passes on stock R and on patched R-devel. On patched
  R it adds tests for rectangles, `drop`, `NA`, negative, logical and
  character subscripts, zero extents, out-of-bounds errors, dimnames,
  matrices (the `MatrixSubset` path), reshaped arrays (method declines)
  and materialized arrays (method declines). Every result is compared with
  base R using `identical()`.
* The hook passes under `gctorture(TRUE)`.

## What it buys

`demo.R` uses a simulated store with 50 ms per round trip and a 1000 x 800
x 60 array in 100 x 100 x 10 chunks:

| `x[...]`                  | stock R 4.3.3                    | patched R-devel |
|---------------------------|----------------------------------|-----------------|
| `[1:250, 1:250, 1:15]`    | 1.19 s, 18 calls, 937,500 elt    | 0.10 s, 1 call  |
| `[seq(1, 1000, 50), , 30]`| 4.23 s, 80 calls, 16,000 elt     | 0.19 s, 1 call  |
| `[500, 400, ]`            | 0.31 s, 6 calls, 60 elt          | 0.06 s, 1 call  |

The chunks fetched are the same in both columns. The difference is round
trips, which on object storage is most of the time.

## Build it yourself

```sh
git clone https://github.com/wch/r-source.git r-devel
cd r-devel
git checkout d75f6a2224865f9ac0bee065de99af817a3a65e6   # or try current trunk
git am /path/to/altarr/r-patch/0001-ALTREP-Extract_array_subset.patch
# the git mirror has no svn metadata; the build needs a revision stamp
printf 'Revision: 90638\nLast Changed Date: 2026-10-03\n' > SVNINFO
mkdir ../r-build && cd ../r-build
../r-devel/configure --without-recommended-packages --disable-java --without-x
make -j4
bin/R CMD INSTALL /path/to/altarr           # altarr:::has_array_subset() is TRUE
bin/Rscript /path/to/altarr/r-patch/demo.R
```

Build dependencies on Debian/Ubuntu: `build-essential gfortran
libreadline-dev libx11-dev libpcre2-dev liblzma-dev libbz2-dev zlib1g-dev
libicu-dev libcurl4-openssl-dev`.
