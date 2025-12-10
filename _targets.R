# Created by use_targets().
# Follow the comments below to fill in this target script.
# Then follow the manual to check and run the pipeline:
#   https://books.ropensci.org/targets/walkthrough.html#inspect-the-pipeline

# Load packages required to define the pipeline:
library(targets)
library(tarchetypes)
library(geotargets)

## use shared cache path if available;
## otherwise, defaults to `tools::R_user_dir("bcmaps", "cache"))`
if (dir.exists("/mnt/shared_cache/bcmaps")) {
  options(bcmaps.data_dir = "/mnt/shared_cache/bcmaps")
}

terra::terraOptions(memfrac = 0.0) ## perform raster operations on disk

## Set target options:
tar_option_set(
  ## Packages that your targets need for their tasks.
  packages = c(
    "bcdata",
    "bcmaps",
    "dplyr",
    "ggplot2",
    "ggspatial",
    "sf",
    "spatialEco",
    "terra",
    "tibble",
    "workflowtools"
  ),

  # format = "qs", # Optionally set the default storage format. qs is fast.

  ## Pipelines that take a long time to run may benefit from
  ## optional distributed computing. To use this capability
  ## in tar_make(), supply a {crew} controller
  ## as discussed at https://books.ropensci.org/targets/crew.html.
  ## Choose a controller that suits your needs. For example, the following
  ## sets a controller that scales up to a maximum of two workers
  ## which run as local R processes. Each worker launches when there is work
  ## to do and exits if 60 seconds pass with no tasks to run.

  controller = crew::crew_controller_local(workers = 8, seconds_idle = 60),
  storage = "worker",
  retrieval = "worker"

  ## Set other options as needed.
)

## Run the R scripts in the R/ folder with your custom functions:
tar_source()

## Define project targets here:
list(
  ## studyArea
  tar_target(
    name = NRD_shapefile,
    command = file.path(
      get_path("download"),
      "BCGW_02001F02_1764364089473_6756",
      "ADM_NR_DISTRICTS_SP",
      "ADM_NR_DST_polygon.shp"
    ),
    format = "file"
  ),
  tar_target(
    name = Quesnel_TSA,
    command = get_quesnel_NRD_boundary(NRD_shapefile)
  ),
  tar_target(
    name = Quesnel_TSA_gpkg,
    command = save_gpkg(Quesnel_TSA, dst = "Quesnel_TSA_studyarea.gpkg"),
    format = "file"
  ),
  tar_target(
    name = Quesnel_TSA_LCC,
    command = sf::st_transform(Quesnel_TSA, crs = terra::crs(LCC))
  ),

  ## LCC used as rasterToMatch
  tar_target(
    name = LCC_tif,
    command = get_landcover_raster(Quesnel_TSA),
    format = "file"
  ),
  tar_terra_rast(
    name = LCC,
    command = terra::rast(LCC_tif)
  ),

  ## DEM
  tar_target(
    name = DEM_tif,
    command = get_dem_raster(Quesnel_TSA),
    format = "file"
  ),
  tar_terra_rast(
    name = DEM,
    command = terra::rast(DEM_tif)
  ),

  ## planning boundaries
  tar_target(
    name = LU,
    command = get_landscape_units(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = LU_gpkg,
    command = save_gpkg(LU, "landscape_units.gpkg"),
    format = "file"
  ),

  ## ecological features
  tar_target(
    name = BEC,
    command = get_bec(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = BEC_gpkg,
    command = save_gpkg(BEC, "BEC.gpkg"),
    format = "file"
  ),
  tar_target(
    name = BECNDT,
    command = create_bec_ndt(BEC)
  ),
  tar_target(
    name = BECNDT_gpkg,
    command = save_gpkg(BECNDT, "BECNDT.gpkg"),
    format = "file"
  ),
  tar_target(
    name = BECNDT_png,
    command = plot_bec_ndt(BECNDT),
    format = "file"
  ),

  tar_target(
    name = VRI,
    command = get_vri(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = VRI_gpkg,
    command = save_gpkg(VRI, "VRI.gpkg"),
    format = "file"
  ),
  tar_target(
    name = VRI_BECNDT,
    command = create_vri_becndt(VRI, BECNDT)
  ),
  tar_target(
    name = VRI_BECNDT_gpkg,
    command = save_gpkg(VRI_BECNDT, "VRI_BECNDT.gpkg"),
    format = "file"
  ),

  tar_target(
    name = forest_disturbance,
    command = get_forest_disturbance(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = forest_disturbance_gpkg,
    command = save_gpkg(forest_disturbance, "forest_disturbance.gpkg"),
    format = "file"
  ),
  tar_target(
    name = forest_disturbance_joined,
    command = create_forest_disturbance_joined(forest_disturbance, VRI_BECNDT)
  ),
  tar_target(
    name = forest_disturbance_joined_gpkg,
    command = save_gpkg(forest_disturbance_joined, "forest_disturbance_joined.gpkg"),
    format = "file"
  ),
  tar_target(
    name = forest_disturbance_seral,
    command = create_forest_disturbance_seral(forest_disturbance_joined)
  ),
  tar_target(
    name = forest_disturbance_seral_gpkg,
    command = save_gpkg(forest_disturbance_seral, "forest_disturbance_seral.gpkg"),
    format = "file"
  ),

  ## biodiversity features
  tar_target(
    name = MDWR,
    command = get_mdwr(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = MDWR_gpkg,
    command = save_gpkg(MDWR, "MDWR.gpkg"),
    format = "file"
  ),
  tar_target(
    name = moose_wetlands,
    command = get_moose_wetlands(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = moose_wetlands_gpkg,
    command = save_gpkg(moose_wetlands, "moose_wetlands.gpkg"),
    format = "file"
  ),
  tar_target(
    name = OGMA,
    command = get_ogma(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = OGMA_gpkg,
    command = save_gpkg(OGMA, "OGMA_current.gpkg"),
    format = "file"
  ),
  tar_target(
    name = parks,
    command = get_parks(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = parks_gpkg,
    command = save_gpkg(parks, "parks.gpkg"),
    format = "file"
  ),
  tar_target(
    name = wetlands,
    command = get_wetlands(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = wetlands_gpkg,
    command = save_gpkg(wetlands, "wetlands.gpkg"),
    format = "file"
  ),
  tar_target(
    name = WHA,
    command = get_wha(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = WHA_gpkg,
    command = save_gpkg(WHA, "WHA.gpkg"),
    format = "file"
  ),
  tar_target(
    name = secondary,
    command = create_secondary(WHA, MDWR, moose_wetlands)
  ),
  tar_target(
    name = secondary_gpkg,
    command = save_gpkg(secondary, "secondary.gpkg"),
    format = "file"
  ),

  ## water features
  tar_target(
    name = lakes,
    command = get_lakes(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = lakes_gpkg,
    command = save_gpkg(lakes, "lakes.gpkg"),
    format = "file"
  ),
  tar_target(
    name = rivers,
    command = get_rivers(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = rivers_gpkg,
    command = save_gpkg(rivers, "rivers.gpkg"),
    format = "file"
  ),
  tar_target(
    name = streams,
    command = get_streams(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = streams_gpkg,
    command = save_gpkg(streams, "stream_order.gpkg"),
    format = "file"
  ),

  ## anthropogenic disturbance features
  tar_target(
    name = railways,
    command = get_railways(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = railways_gpkg,
    command = save_gpkg(railways, "railways.gpkg"),
    format = "file"
  ),
  tar_target(
    name = roads,
    command = get_roads(Quesnel_TSA_LCC, LCC), ## note differest studyArea CRS needed
  ),
  tar_target(
    name = roads_gpkg,
    command = save_gpkg(roads, "roads.gpkg"),
    format = "file"
  ),
  # tar_target(
  #   name = roads_railways,
  #   command = create_roads_railways(roads, railways)
  # ),
  # tar_target(
  #   name = roads_railways_gpkg,
  #   command = save_gpkg(roads_railways, "roads_railways.gpkg"),
  #   format = "file"
  # ),
  tar_target(
    name = human_disturbance,
    command = get_human_disturbance(Quesnel_TSA, LCC)
  ),
  tar_target(
    name = human_disturbance_gpkg,
    command = save_gpkg(human_disturbance, "human_disturbance.gpkg"),
    format = "file"
  ),

  ## patch statistics / summaries
  tar_target(
    name = patch_summary,
    command = calc_patch_stats(forest_disturbance_seral),
  ),
  tar_target(
    name = patch_summary_csv,
    command = save_patch_stats(patch_summary),
    format = "file"
  ),

  ## interpatch assesments
  tar_target(
    name = old_patches,
    command = extract_old_patches(forest_disturbance_seral)
  ),
  tar_target(
    name = old_patches_png,
    command = plot_old_patches(old_patches),
    format = "file"
  ),
  tar_target(
    name = nn_dist,
    command = calc_nn_dists(old_patches)
  ),
  tar_target(
    name = nn_dist_png,
    command = plot_nn_dists(nn_dist),
    format = "file"
  ),
  tar_target(
    name = all_dist,
    command = calc_all_dists(old_patches)
  ),
  tar_target(
    name = all_dist_png,
    command = plot_all_dists(all_dist),
    format = "file"
  ),

  ## create resistance and sourcewt rasters
  tar_target(
    name = resistance_forest,
    command = create_resistance_raster(
      polys = forest_disturbance_seral,
      rasterToMatch = LCC,
      dst = "resistance_forest_disturbance.tif"
    ),
    format = "file"
  ),
  tar_target(
    name = sourcewt_forest,
    command = create_sourcewt_raster(
      polys = forest_disturbance_seral,
      rasterToMatch = LCC,
      dst = "sourcewt_forest_disturbance.tif"
    ),
    format = "file"
  ),

  # tar_target(
  #   name = resistance_roads_railways,
  #   command = create_resistance_raster(
  #     polys = roads_railways,
  #     rasterToMatch = LCC,
  #     dst = "resistance_roads.tif"
  #   ),
  #   format = "file"
  # ),
  # tar_target(
  #   name = sourcewt_roads_railways,
  #   command = create_sourcewt_raster(
  #     polys = roads_railways,
  #     rasterToMatch = LCC,
  #     dst = "sourcewt_roads.tif"
  #   ),
  #   format = "file"
  # ),

  tar_target(
    name = resistance_ogma,
    command = create_resistance_raster(
      polys = OGMA,
      rasterToMatch = LCC,
      dst = "resistance_OGMA.tif"
    ),
    format = "file"
  ),
  tar_target(
    name = sourcewt_ogma,
    command = create_sourcewt_raster(
      polys = OGMA,
      rasterToMatch = LCC,
      dst = "sourcewt_OGMA.tif"
    ),
    format = "file"
  ),

  tar_target(
    name = resistance_parks,
    command = create_resistance_raster(
      polys = parks,
      rasterToMatch = LCC,
      dst = "resistance_parks.tif"
    ),
    format = "file"
  ),
  tar_target(
    name = sourcewt_parks,
    command = create_sourcewt_raster(
      polys = parks,
      rasterToMatch = LCC,
      dst = "sourcewt_parks.tif"
    ),
    format = "file"
  ),

  tar_target(
    name = resistance_secondary,
    command = create_resistance_raster(
      polys = secondary,
      rasterToMatch = LCC,
      dst = "resistance_secondary.tif"
    ),
    format = "file"
  ),
  tar_target(
    name = sourcewt_secondary,
    command = create_sourcewt_raster(
      polys = secondary,
      rasterToMatch = LCC,
      dst = "sourcewt_secondary.tif"
    ),
    format = "file"
  ),

  tar_target(
    name = resistance_lakes,
    command = create_resistance_raster(
      polys = lakes,
      rasterToMatch = LCC,
      dst = "resistance_lakes.tif"
    ),
    format = "file"
  ),
  tar_target(
    name = sourcewt_lakes,
    command = create_sourcewt_raster(
      polys = lakes,
      rasterToMatch = LCC,
      dst = "sourcewt_lakes.tif"
    ),
    format = "file"
  ),

  tar_target(
    name = resistance_rivers,
    command = create_resistance_raster(
      polys = rivers,
      rasterToMatch = LCC,
      dst = "resistance_rivers.tif"
    ),
    format = "file"
  ),
  tar_target(
    name = sourcewt_rivers,
    command = create_sourcewt_raster(
      polys = rivers,
      rasterToMatch = LCC,
      dst = "sourcewt_rivers.tif"
    ),
    format = "file"
  ),

  tar_target(
    name = resistance_streams,
    command = create_resistance_raster(
      polys = streams,
      rasterToMatch = LCC,
      dst = "resistance_streams.tif"
    ),
    format = "file"
  ),
  tar_target(
    name = sourcewt_streams,
    command = create_sourcewt_raster(
      polys = streams,
      rasterToMatch = LCC,
      dst = "sourcewt_streams.tif"
    ),
    format = "file"
  ),

  tar_target(
    name = resistance_wetlands,
    command = create_resistance_raster(
      polys = wetlands,
      rasterToMatch = LCC,
      dst = "resistance_wetlands.tif"
    ),
    format = "file"
  ),
  tar_target(
    name = sourcewt_wetlands,
    command = create_sourcewt_raster(
      polys = wetlands,
      rasterToMatch = LCC,
      dst = "sourcewt_wetlands.tif"
    ),
    format = "file"
  ),

  ## composite rasters
  # tar_target(
  #   name = resistance_composite,
  #   command = create_composite_resistance_raster(
  #     forest = resistance_forest,
  #     roads = resistance_roads,
  #     streams = resistance_streams,
  #     rivers = resistance_rivers,
  #     lakes = resistance_lakes,
  #     wetlands = resistance_wetlands,
  #     dst = "resistance_composite.tif"
  #   ),
  #   format = "file"
  # ),
  # tar_target(
  #   name = sourcewt_composite,
  #   command = create_composite_sourcewt_raster(
  #     forest = sourcewt_forest,
  #     roads = sourcewt_roads,
  #     streams = sourcewt_streams,
  #     rivers = sourcewt_rivers,
  #     lakes = sourcewt_lakes,
  #     wetlands = sourcewt_wetlands,
  #     dst = "sourcewt_composite.tif"
  #   ),
  #   format = "file"
  # ),

  ## write reproducibility receipt
  tar_target(
    name = reproducibility_receipt,
    command = write_reproducibility_receipt("INFO.md"),
    format = "file"
  )
)
