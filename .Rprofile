source("renv/activate.R")

## Settings below are deliberately in .Rprofile rather than _targets.R: `crew` workers start their
## own R sessions, which load this file, but do NOT source `_targets.R`. Anything set only there
## applies to the session that *defines* the pipeline and silently does not reach the workers.

## keep the linear-algebra / GDAL thread pools to one thread per process -- the pipeline gets its
## parallelism from crew workers, and oversubscribing threads on top of that is what made the
## spatial steps deadlock
Sys.setenv(OMP_NUM_THREADS = 1)

## perform raster operations on disk rather than in memory
if (requireNamespace("terra", quietly = TRUE)) {
  terra::terraOptions(memfrac = 0.1, progress = 0)
}

## NOTE: this file deliberately attaches NOTHING.
##
## `.Rprofile` runs *before* R attaches the default packages, so anything attached here lands BELOW
## `stats` on the search path -- and `library()` on an already-attached package is a no-op, so a
## later `library(dplyr)` cannot lift it back up. The result is that a bare `filter()` resolves to
## `stats::filter()` in every session that loads this file, which fails with an unrelated-looking
## error ("'list' object cannot be coerced to type 'double'").
##
## This used to attach dplyr, sf, and targets "to make targets happy when map". Dynamic branching
## over `sf`/`SpatVector` objects has since been verified to work without it (sf 1.0.23,
## targets 1.11.4), and `crew` workers get their packages from `tar_option_set(packages = )`
## regardless. Everything in `R/` uses qualified calls (`dplyr::filter()`), so nothing needs an
## attached package.
##
## A bare `library()` here would also break a fresh clone: the project library is empty until
## `renv::restore()` runs, and a failed attach at startup takes `renv::restore()` down with it.
