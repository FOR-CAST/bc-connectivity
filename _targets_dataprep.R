# Created by use_targets().
# Follow the comments below to fill in this target script.
# Then follow the manual to check and run the pipeline:
#   https://books.ropensci.org/targets/walkthrough.html#inspect-the-pipeline

## set environment variable before loading packages
Sys.setenv(OMP_NUM_THREADS = 1)

# Load packages required to define the pipeline:
library(targets)
library(tarchetypes)
library(geotargets)

## use shared cache path if available;
## otherwise, defaults to `tools::R_user_dir("bcmaps", "cache"))`
if (dir.exists("/mnt/shared_cache/bcmaps")) {
  options(bcmaps.data_dir = "/mnt/shared_cache/bcmaps")
}

## NOTE: terra options are set in `.Rprofile` so that crew workers get them too --
## setting them here would only affect the session that *defines* the pipeline.

## Pin the format `tar_terra_vect()` serialises to. GeoPackage preserves both `NA` character values
## (the interior-forest flags are NA for most polygons) and feature order; FlatGeobuf round-trips
## the same features in a different order, which would silently desynchronise the row-index chunking
## the distance calculations rely on.
geotargets::geotargets_option_set(gdal_vector_driver = "GPKG")

## Set target options:
##
## Worker count is capped rather than "all cores": the heavy steps are now branched and short, and
## this machine is usually shared with other analyses. Override with `BC_CONN_WORKERS`.
n_workers <- as.integer(Sys.getenv(
  "BC_CONN_WORKERS",
  min(parallelly::availableCores(omit = 2), 64L)
))

tar_option_set(
  ## Packages that your targets need for their tasks.
  packages = c(
    "bcdata",
    "bcmaps",
    "dplyr",
    "ggplot2",
    "ggspatial",
    "purrr",
    "sf",
    "spatialutils",
    "terra",
    "tidyterra",
    "tibble",
    "units",
    "workflowtools"
  ),

  ## Optional settings
  # format = "qs",
  memory = "transient",
  garbage_collection = TRUE,

  ## Pipelines that take a long time to run may benefit from distributed computing.
  ## To use this capability in tar_make(), supply a {crew} controller
  ## as discussed at <https://books.ropensci.org/targets/crew.html>.
  controller = crew::crew_controller_local(
    workers = n_workers,
    seconds_idle = 600,
    crashes_max = 20L
  ),
  storage = "worker",
  retrieval = "worker",

  ## Debugging options (see <https://books.ropensci.org/targets/debugging.html>)
  ## NOTE: to run in interactive session for use with browser(), run pipeline with:
  ## `tar_make(callr_function = NULL, use_crew = FALSE, as_job = FALSE)`
  ## `"trim"` was renamed `"abridge"` in targets 1.5.0; the old name now fails tar_validate().
  ## Unaffected targets keep running; anything downstream of an error is skipped.
  error = "abridge",
  # workspace_on_error = TRUE

  ## Set other options as needed.
)

## Number of tiles / chunks used to parallelise the spatial overlays and distance calculations.
n_tiles <- c(8, 8) ## 64 tiles over the study area
n_chunks_nn <- 64L
n_chunks_all <- 64L

## Run the R scripts in the R/ folder with your custom functions:
tar_source()

## The vintage stamped onto every Omniscape run directory, e.g. "2026-08-26_p30_r1507_bs151".
##
## Deliberately a fixed string rather than `Sys.Date()`: a date evaluated at build time would change
## the target's value every day, invalidating it and every downstream summary for no reason. Bump it
## by hand whenever the inputs change enough that the previous runs should not be overwritten.
##
## It also matters because `run_omniscape(overwrite = TRUE)` *deletes* an existing output directory
## before running. Reusing a vintage whose runs are still wanted -- the 17 GB of results under
## `Outputs/2026-01-*/`, including the one the report used -- would destroy them.
OMNISCAPE_VINTAGE <- "2026-08-26"

## Define project targets here:

## Project-specific note ------------------------------------------------------------------------
##
## This script is shared by every district's project of this kind. It contains NO district-specific
## logic: the district comes from `TAR_PROJECT` via `active_district()`, and everything that varies
## lives in `R/districts.R`. A project script is exactly what drifts between districts, so there
## should never be a reason to edit this one per district.

dataprep_targets()
