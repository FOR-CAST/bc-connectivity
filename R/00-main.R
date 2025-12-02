# packages ------------------------------------------------------------------------------------

## project/workflow management
library(workflowtools)

## data manipulation
library(dplyr)
library(tibble)

## geospatial packages
library(sf)
library(spatialEco)
library(terra)
library(raster) ## TODO: remove and use terra
library(fasterize) ## TODO: remove and use terra

## geospatial data packages
library(bcdata)
library(bcmaps)

## plotting
library(ggplot2)
library(ggspatial)

# paths ---------------------------------------------------------------------------------------

## use shared cache path if available;
## otherwise, defaults to `R_user_dir("bcmaps", "cache"))`
bcmaps_cache_dir <- "/mnt/shared_cache/bcmaps"

if (dir.exists(bcmaps_cache_dir)) {
  options(bcmaps.data_dir = bcmaps_cache_dir)
} else {
  bcmaps_cache_dir <- tools::R_user_dir("bcmaps", "cache")
}

project_dir <- workflowtools::findProjectPath()
download_dir <- file.path(project_dir, "Data", "raw") |> fs::dir_create()
inputs_dir <- file.path(project_dir, "Data", "processed") |> fs::dir_create()
inputs_raster_dir <- file.path(project_dir, "Data", "processed", "rasters") |> fs::dir_create()
omniscape_dir <- file.path(project_dir, "Omniscape") |> fs::dir_create()
output_dir <- file.path(project_dir, "Outputs") |> fs::dir_create()
figure_dir <- file.path(output_dir, "figures") |> fs::dir_create()

# data processing and analyses ----------------------------------------------------------------

need_download <- FALSE ## set to TRUE when fetching data the first time

## download data
if (need_download) {
  source("R/01a-download-data.R")
}

## prepare maps and summaries of study area
source("R/02-study-area.R")

## prepare resistance rasters
source("R/03a-rasterize.R")
source("R/03b-composite.R")

## nearest neighbour analysis to get moving window size
source("R/04-moving-window.R")

## setup omniscape runs
source("R/05-omniscape.R")

# record session info -------------------------------------------------------------------------

workflowtools::reproducibilityReceipt(writeTo = "INFO.md")

# cleanup -------------------------------------------------------------------------------------

terra::tmpFiles(remove = TRUE)

withr::deferred_run()
