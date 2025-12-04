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
need_rebuild <- FALSE ## set to TRUE when preparing raster layers

input_files <- list(
  study_area = file.path(inputs_dir, "Quesnel_TSA_studyarea.gpkg"),

  DEM = file.path(inputs_raster_dir, "Quesnel_TSA_DEM.tif"),
  LCC = file.path(inputs_raster_dir, "Quesnel_TSA_LCC.tif"),

  BEC = file.path(inputs_dir, "BEC.gpkg"),
  BECNDT = file.path(inputs_dir, "BECNDT.gpkg"),
  LU = file.path(inputs_dir, "landscape_units.gpkg"),
  MDWR = file.path(inputs_dir, "MDWR.gpkg"),
  OGMA = file.path(inputs_dir, "OGMA_current.gpkg"),
  VRI = file.path(inputs_dir, "VRI.gpkg"),
  VRI_BECNDT = file.path(inputs_dir, "VRI_BECNDT.gpkg"),
  WHA = file.path(inputs_dir, "WHA.gpkg"),

  forest_disturbance = file.path(inputs_dir, "forest_disturbance.gpkg"),
  human_disturbance = file.path(inputs_dir, "human_disturbance.gpkg"),
  moose_wetlands = file.path(inputs_dir, "moose_wetlands.gpkg"),
  parks = file.path(inputs_dir, "parks.gpkg"),
  roads = file.path(inputs_dir, "roads.gpkg"),
  railways = file.path(inputs_dir, "railways.gpkg"),

  lakes = file.path(inputs_dir, "lakes.gpkg"),
  rivers = file.path(inputs_dir, "rivers.gpkg"),
  streams = file.path(inputs_dir, "stream_order.gpkg"),
  wetlands = file.path(inputs_dir, "wetlands.gpkg"),

  ## study area poylgons
  NDT_BEC = file.path(inputs_dir, "NDT_BEC_dissolved.gpkg"),
  NDT = file.path(inputs_dir, "NDT_dissolved.gpkg"),

  ## forest disturbance
  resistance_fordist = file.path(inputs_raster_dir, "resistance_forest_disturbance.tif"),
  sourcewt_fordist = file.path(inputs_raster_dir, "sourcewt_forest_disturbance.tif"),

  ## consolidated roads and railways
  resistance_roads = file.path(inputs_raster_dir, "resistance_roads_.tif"),
  sourcewt_roads = file.path(inputs_raster_dir, "sourcewt_roads.tif"),

  ## consolidated WHA, MDWR, moose wetlands, and wetlands (secondary protected areas)
  resistance_secondary = file.path(inputs_raster_dir, "resistance_secondary.tif"),
  sourcewt_secondary = file.path(inputs_raster_dir, "sourcewt_secondary.tif"),

  ## OGMA
  resistance_OGMA = file.path(inputs_raster_dir, "resistance_OGMA.tif"),
  sourcewt_OGMA = file.path(inputs_raster_dir, "sourcewt_OGMA.tif"),

  ## parks and ecological reserves
  resistance_parks = file.path(inputs_raster_dir, "resistance_parks.tif"),
  sourcewt_parks = file.path(inputs_raster_dir, "sourcewt_parks.tif"),

  ## water features (lakes, rivers, streams)
  resistance_lakes = file.path(inputs_raster_dir, "resistance_lakes.tif"),
  sourcewt_lakes = file.path(inputs_raster_dir, "sourcewt_lakes.tif"),

  resistance_rivers = file.path(inputs_raster_dir, "resistance_rivers.tif"),
  sourcewt_rivers = file.path(inputs_raster_dir, "sourcewt_rivers.tif"),

  resistance_streams = file.path(inputs_raster_dir, "resistance_streams.tif"),
  sourcewt_streams = file.path(inputs_raster_dir, "sourcewt_streams.tif"),

  ## composite rasters
  resistance_composite_all = file.path(inputs_raster_dir, "resistance_composite_all.tif"),
  sourcewt_composite_all = file.path(inputs_raster_dir, "sourcewt_composite_all.tif")
)

## download data
if (need_download) {
  source("R/01a-download-data.R")
}

## prepare maps and summaries of study area
source("R/02-study-area.R")

## prepare resistance rasters
if (need_rebuild) {
  source("R/03a-rasterize.R")
  source("R/03b-composite.R")
}

## nearest neighbour analysis to get moving window size
source("R/04-moving-window.R")

## setup omniscape runs
source("R/05-omniscape.R")

# record session info -------------------------------------------------------------------------

workflowtools::reproducibilityReceipt(writeTo = "INFO.md")

# cleanup -------------------------------------------------------------------------------------

terra::tmpFiles(remove = TRUE)

withr::deferred_run()
