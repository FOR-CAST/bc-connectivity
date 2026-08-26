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
    command = get_quesnel_NRD_boundary(NRD_shapefile, buffer = FALSE)
  ),
  tar_target(
    name = Quesnel_TSA_gpkg,
    command = save_gpkg(Quesnel_TSA, dst = "Quesnel_TSA_studyarea.gpkg"),
    format = "file"
  ),
  tar_target(
    name = Quesnel_TSA_buffered,
    command = get_quesnel_NRD_boundary(NRD_shapefile, buffer = TRUE)
  ),
  tar_target(
    name = Quesnel_TSA_buffered_gpkg,
    command = save_gpkg(Quesnel_TSA_buffered, dst = "Quesnel_TSA_studyarea_buffered.gpkg"),
    format = "file"
  ),
  tar_target(
    name = Quesnel_TSA_buffered_LCC,
    command = sf::st_transform(Quesnel_TSA_buffered, crs = terra::crs(LCC))
  ),

  ## LCC used as rasterToMatch
  tar_target(
    name = LCC_tif,
    command = get_landcover_raster(Quesnel_TSA_buffered),
    format = "file"
  ),
  tar_target(
    name = agg_fact_lcc,
    command = c(1, 3) ## keep a version at 30m and aggregate another to 90m
  ),
  tar_terra_rast(
    name = LCC,
    command = terra::rast(LCC_tif)
  ),
  tar_terra_rast(
    name = LCC_agg,
    command = terra::aggregate(LCC, fact = agg_fact_lcc),
    pattern = map(agg_fact_lcc)
  ),

  ## DEM
  tar_target(
    name = DEM_tif,
    command = get_dem_raster(Quesnel_TSA_buffered),
    format = "file"
  ),
  tar_terra_rast(
    name = DEM,
    command = terra::rast(DEM_tif)
  ),

  ## planning boundaries
  tar_target(
    name = LU,
    command = get_landscape_units(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = LU_gpkg,
    command = save_gpkg(LU, "landscape_units.gpkg"),
    format = "file"
  ),

  ## ecological features
  tar_target(
    name = BEC,
    command = get_bec(Quesnel_TSA_buffered, LCC)
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
    command = plot_bec_ndt(BECNDT, Quesnel_TSA),
    format = "file"
  ),

  tar_target(
    name = leading_group_cariboo,
    command = get_leading_group_cariboo(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = leading_group_cariboo_gpkg,
    command = save_gpkg(leading_group_cariboo, "leading_group_cariboo.gpkg"),
    format = "file"
  ),

  tar_target(
    name = VRI,
    command = get_vri(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = VRI_gpkg,
    command = save_gpkg(VRI, "VRI.gpkg"),
    format = "file"
  ),
  tar_terra_vect(
    name = VRI_BECNDT,
    command = create_vri_becndt(VRI, BECNDT, leading_group_cariboo)
  ),
  tar_target(
    name = VRI_BECNDT_gpkg,
    command = save_gpkg(VRI_BECNDT, "VRI_BECNDT.gpkg"),
    format = "file"
  ),

  tar_target(
    name = forest_disturbance,
    command = get_forest_disturbance(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = forest_disturbance_gpkg,
    command = save_gpkg(forest_disturbance, "forest_disturbance.gpkg"),
    format = "file"
  ),
  ## Seral stage assignment is an overlay, and overlays are embarrassingly parallel over space:
  ## tile the study area and let the crew workers do it. Each branch reads only the features
  ## overlapping its tile straight from the GeoPackages, so no worker ever holds the 4 M-polygon
  ## forest disturbance layer.
  tar_target(
    name = study_area_tiles,
    command = make_study_area_tiles(Quesnel_TSA_buffered_LCC, n = n_tiles),
    iteration = "group"
  ),
  tar_target(
    name = sifa_max,
    command = max_stand_age(forest_disturbance_gpkg)
  ),
  tar_terra_vect(
    name = forest_disturbance_seral_tiles,
    command = create_forest_disturbance_seral(
      forest_disturbance_gpkg,
      VRI_BECNDT_gpkg,
      study_area_tiles,
      sifa_max
    ),
    pattern = map(study_area_tiles),
    iteration = "list"
  ),
  tar_terra_vect(
    name = forest_disturbance_seral,
    command = combine_spatvectors(forest_disturbance_seral_tiles)
  ),
  tar_target(
    name = forest_disturbance_seral_png,
    command = plot_forest_disturbance_seral(
      forest_disturbance_seral,
      Quesnel_TSA,
      "Quesnel_TSA_for_dist_seral.png"
    ),
    format = "file"
  ),
  tar_target(
    name = forest_disturbance_seral_gpkg,
    command = save_gpkg(forest_disturbance_seral, "forest_disturbance_seral.gpkg"),
    format = "file"
  ),

  ## Patch construction (README appendix, arcpy steps 1-6) ---------------------------------------
  tar_terra_vect(
    name = patches_input_data,
    command = patches_get_input_data(forest_disturbance_seral)
  ),

  tar_terra_vect(
    name = patches_mature_old,
    command = patches_create_old_mature(patches_input_data, c("Mature", "Old"))
  ),
  tar_terra_vect(
    name = patches_old,
    command = patches_create_old_mature(patches_input_data, "Old")
  ),

  ## Edge-influence buffers, one per neighbouring seral stage
  ## (Early <20 yr -> 200 m, Early >=20 yr -> 101 m, Mid -> 52 m, Mature -> 25 m).
  tar_terra_vect(
    name = patches_buffer_200,
    command = patches_create_buffers_to_delete(patches_input_data, buffer_size = 200)
  ),
  tar_terra_vect(
    name = patches_buffer_100,
    command = patches_create_buffers_to_delete(patches_input_data, buffer_size = 100)
  ),
  tar_terra_vect(
    name = patches_buffer_50,
    command = patches_create_buffers_to_delete(patches_input_data, buffer_size = 50)
  ),
  tar_terra_vect(
    name = patches_buffer_25,
    command = patches_create_buffers_to_delete(patches_input_data, buffer_size = 25)
  ),

  ## The four sequential erases collapse to one erase against the union of the buffers that apply.
  ## The 25 m (Mature) buffer applies only to the old-only target -- see
  ## `patches_create_erase_mask()`.
  tar_terra_vect(
    name = patches_erase_mask_old,
    command = patches_create_erase_mask(
      patches_buffer_200,
      patches_buffer_100,
      patches_buffer_50,
      patches_buffer_25,
      "Old"
    )
  ),
  tar_terra_vect(
    name = patches_erase_mask_mature_old,
    command = patches_create_erase_mask(
      patches_buffer_200,
      patches_buffer_100,
      patches_buffer_50,
      patches_buffer_25,
      "Mature"
    )
  ),

  tar_terra_vect(
    name = patches_interior_forest_old,
    command = patches_create_interior_forest(patches_old, patches_erase_mask_old, "Old")
  ),
  tar_terra_vect(
    name = patches_interior_forest_mature_old,
    command = patches_create_interior_forest(
      patches_mature_old,
      patches_erase_mask_mature_old,
      "Mature"
    )
  ),

  tar_terra_vect(
    name = patches_patch_size,
    command = patches_create_patch_size_data(patches_input_data)
  ),

  ## arcpy step 6a: Union of the seral layer with both interior-forest layers. Every polygon keeps
  ## its own seral stage and gains `old_interior` / `matold_interior` flags -- interior forest is an
  ## attribute, not a relabelling.
  tar_terra_vect(
    name = patches_union_final,
    command = patches_union_into_final_resultant(
      patches_patch_size,
      patches_interior_forest_old,
      patches_interior_forest_mature_old
    )
  ),

  tar_terra_vect(
    name = forest_patches_final,
    command = define_forest_seral_patch_conn_vals(patches_union_final)
  ),
  tar_target(
    name = forest_patches_final_gpkg,
    command = save_gpkg(forest_patches_final, "forest_patches_final.gpkg"),
    format = "file"
  ),
  tar_target(
    name = forest_patches_final_png,
    command = plot_forest_disturbance_seral(
      forest_patches_final,
      Quesnel_TSA,
      "Quesnel_TSA_for_dist_seral_patches.png"
    ),
    format = "file"
  ),

  ## biodiversity features
  tar_target(
    name = MDWR,
    command = get_mdwr(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = MDWR_gpkg,
    command = save_gpkg(MDWR, "MDWR.gpkg"),
    format = "file"
  ),
  tar_target(
    name = moose_wetlands,
    command = get_moose_wetlands(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = moose_wetlands_gpkg,
    command = save_gpkg(moose_wetlands, "moose_wetlands.gpkg"),
    format = "file"
  ),
  tar_target(
    name = OGMA,
    command = get_ogma(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = OGMA_gpkg,
    command = save_gpkg(OGMA, "OGMA_current.gpkg"),
    format = "file"
  ),
  tar_target(
    name = parks,
    command = get_parks(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = parks_gpkg,
    command = save_gpkg(parks, "parks.gpkg"),
    format = "file"
  ),
  tar_target(
    name = wetlands,
    command = get_wetlands(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = wetlands_gpkg,
    command = save_gpkg(wetlands, "wetlands.gpkg"),
    format = "file"
  ),
  tar_target(
    name = WHA,
    command = get_wha(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = WHA_gpkg,
    command = save_gpkg(WHA, "WHA.gpkg"),
    format = "file"
  ),
  tar_target(
    name = WUI,
    command = get_wui(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = WUI_gpkg,
    command = save_gpkg(WUI, "WUI.gpkg"),
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
    command = get_lakes(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = lakes_gpkg,
    command = save_gpkg(lakes, "lakes.gpkg"),
    format = "file"
  ),
  tar_target(
    name = rivers,
    command = get_rivers(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = rivers_gpkg,
    command = save_gpkg(rivers, "rivers.gpkg"),
    format = "file"
  ),
  tar_target(
    name = streams,
    command = get_streams(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = streams_gpkg,
    command = save_gpkg(streams, "stream_order.gpkg"),
    format = "file"
  ),

  ## anthropogenic disturbance features
  tar_target(
    name = railways,
    command = get_railways(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = railways_gpkg,
    command = save_gpkg(railways, "railways.gpkg"),
    format = "file"
  ),
  tar_target(
    name = roads,
    command = get_roads(Quesnel_TSA_buffered_LCC, LCC), ## NOTE: different studyArea CRS needed
  ),
  tar_target(
    name = roads_gpkg,
    command = save_gpkg(roads, "roads.gpkg"),
    format = "file"
  ),
  tar_target(
    name = roads_railways,
    command = create_roads_railways(roads, railways)
  ),
  tar_target(
    name = roads_railways_gpkg,
    command = save_gpkg(roads_railways, "roads_railways.gpkg"),
    format = "file"
  ),
  tar_target(
    name = human_disturbance,
    command = get_human_disturbance(Quesnel_TSA_buffered, LCC)
  ),
  tar_target(
    name = human_disturbance_gpkg,
    command = save_gpkg(human_disturbance, "human_disturbance.gpkg"),
    format = "file"
  ),

  ## patch statistics / summaries
  ##
  ## Computed on the dissolved seral layer (arcpy step 5a), where a "patch" is a contiguous area of
  ## one seral stage -- not on the final resultant, whose polygons are overlay fragments.
  tar_target(
    name = patch_summary,
    command = calc_patch_stats(patches_patch_size)
  ),
  tar_target(
    name = patch_summary_csv,
    command = save_patch_stats(patch_summary),
    format = "file"
  ),

  ## interpatch assesments ------------------------------------------------------------------------
  tar_terra_vect(
    name = patches_matold,
    command = calc_matold(forest_patches_final)
  ),

  ## Chunks are index ranges, not pre-split copies of the layer: every branch needs the whole layer
  ## to find neighbours anyway, and shipping a list of 255 pre-split chunks alongside it is what
  ## drove the ~350 GB of resident memory this step used to need.
  tar_target(
    name = forest_patches_chunks_nn_dists,
    command = make_chunks(terra::nrow(patches_matold), n_chunks = n_chunks_nn),
    iteration = "group"
  ),
  tar_target(
    name = nn_interpatch_distances_chunks,
    command = calc_nn_dists(
      patches_matold,
      forest_patches_chunks_nn_dists,
      n_chunks = n_chunks_nn
    ),
    pattern = map(forest_patches_chunks_nn_dists),
    iteration = "list"
  ),
  tar_target(
    name = nn_interpatch_distances_combined,
    command = calc_nn_dists_combine(nn_interpatch_distances_chunks)
  ),
  tar_target(
    name = quantiles_nn_dists,
    command = quantile(nn_interpatch_distances_combined, seq(0, 1, 0.01))
  ),
  tar_target(
    name = nn_interpatch_distances_png,
    command = plot_hist_dists(nn_interpatch_distances_combined, "nn"),
    format = "file"
  ),

  ## all pairwise distances: one branch per chunk pair, written straight to a parquet dataset
  tar_target(
    name = all_interpatch_distances_grid,
    command = calc_all_dists_grid(n_chunks_all),
    iteration = "group",
    deployment = "main" ## trivial to compute
  ),
  tar_target(
    name = all_interpatch_distances_parquet,
    command = calc_all_dists(
      patches_matold,
      all_interpatch_distances_grid,
      n_chunks = n_chunks_all
    ),
    pattern = map(all_interpatch_distances_grid),
    format = "file"
  ),
  tar_target(
    name = quantiles_all_dists,
    command = calc_all_dists_quantiles(all_interpatch_distances_parquet)
  ),

  ## create resistance and sourcewt rasters
  tar_target(
    name = resistance_forest,
    command = create_resistance_raster(
      polys = forest_patches_final,
      rasterToMatch = LCC_agg,
      dst = "resistance_forest.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),
  tar_target(
    name = sourcewt_forest,
    command = create_sourcewt_raster(
      polys = forest_patches_final,
      rasterToMatch = LCC_agg,
      dst = "sourcewt_forest.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),

  tar_target(
    name = resistance_roads_railways,
    command = create_resistance_raster(
      polys = roads_railways,
      rasterToMatch = LCC_agg,
      dst = "resistance_roads.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),
  tar_target(
    name = sourcewt_roads_railways,
    command = create_sourcewt_raster(
      polys = roads_railways,
      rasterToMatch = LCC_agg,
      dst = "sourcewt_roads_railways.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),

  tar_target(
    name = resistance_ogma,
    command = create_resistance_raster(
      polys = OGMA,
      rasterToMatch = LCC_agg,
      dst = "resistance_OGMA.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),
  tar_target(
    name = sourcewt_ogma,
    command = create_sourcewt_raster(
      polys = OGMA,
      rasterToMatch = LCC_agg,
      dst = "sourcewt_OGMA.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),

  tar_target(
    name = resistance_parks,
    command = create_resistance_raster(
      polys = parks,
      rasterToMatch = LCC_agg,
      dst = "resistance_parks.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),
  tar_target(
    name = sourcewt_parks,
    command = create_sourcewt_raster(
      polys = parks,
      rasterToMatch = LCC_agg,
      dst = "sourcewt_parks.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),

  tar_target(
    name = resistance_secondary,
    command = create_resistance_raster(
      polys = secondary,
      rasterToMatch = LCC_agg,
      dst = "resistance_secondary.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),
  tar_target(
    name = sourcewt_secondary,
    command = create_sourcewt_raster(
      polys = secondary,
      rasterToMatch = LCC_agg,
      dst = "sourcewt_secondary.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),

  tar_target(
    name = resistance_lakes,
    command = create_resistance_raster(
      polys = lakes,
      rasterToMatch = LCC_agg,
      dst = "resistance_lakes.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),
  tar_target(
    name = sourcewt_lakes,
    command = create_sourcewt_raster(
      polys = lakes,
      rasterToMatch = LCC_agg,
      dst = "sourcewt_lakes.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),

  tar_target(
    name = resistance_rivers,
    command = create_resistance_raster(
      polys = rivers,
      rasterToMatch = LCC_agg,
      dst = "resistance_rivers.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),
  tar_target(
    name = sourcewt_rivers,
    command = create_sourcewt_raster(
      polys = rivers,
      rasterToMatch = LCC_agg,
      dst = "sourcewt_rivers.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),

  tar_target(
    name = resistance_streams,
    command = create_resistance_raster(
      polys = streams,
      rasterToMatch = LCC_agg,
      dst = "resistance_streams.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),
  tar_target(
    name = sourcewt_streams,
    command = create_sourcewt_raster(
      polys = streams,
      rasterToMatch = LCC_agg,
      dst = "sourcewt_streams.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),

  tar_target(
    name = resistance_wetlands,
    command = create_resistance_raster(
      polys = wetlands,
      rasterToMatch = LCC_agg,
      dst = "resistance_wetlands.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),
  tar_target(
    name = sourcewt_wetlands,
    command = create_sourcewt_raster(
      polys = wetlands,
      rasterToMatch = LCC_agg,
      dst = "sourcewt_wetlands.tif"
    ),
    format = "file",
    pattern = map(LCC_agg),
    iteration = "list"
  ),

  # composite rasters
  tar_target(
    name = resistance_composite,
    command = create_composite_resistance_raster(
      forest = resistance_forest,
      roads = resistance_roads_railways,
      streams = resistance_streams,
      rivers = resistance_rivers,
      lakes = resistance_lakes,
      wetlands = resistance_wetlands,
      dst = "resistance_composite.tif"
    ),
    format = "file",
    pattern = map(
      forest = resistance_forest,
      roads = resistance_roads_railways,
      streams = resistance_streams,
      rivers = resistance_rivers,
      lakes = resistance_lakes,
      wetlands = resistance_wetlands
    ),
    iteration = "list"
  ),
  tar_target(
    name = sourcewt_composite,
    command = create_composite_sourcewt_raster(
      forest = sourcewt_forest,
      roads = sourcewt_roads_railways,
      streams = sourcewt_streams,
      rivers = sourcewt_rivers,
      lakes = sourcewt_lakes,
      wetlands = sourcewt_wetlands,
      dst = "sourcewt_composite.tif"
    ),
    format = "file",
    pattern = map(
      forest = sourcewt_forest,
      roads = sourcewt_roads_railways,
      streams = sourcewt_streams,
      rivers = sourcewt_rivers,
      lakes = sourcewt_lakes,
      wetlands = sourcewt_wetlands
    ),
    iteration = "list"
  ),

  ## Omniscape --------------------------------------------------------------------------------
  ##
  ## Runs are now launched from R (see `run_omniscape()` / `julia_env()`), so the whole analysis is
  ## one `tar_make()`. They are still expensive -- hours to days each -- so which configurations
  ## actually run is controlled by `omniscape_runs` below rather than by launching everything.
  tar_target(
    name = omniscape_config_alldist,
    command = write_omniscape_config(
      res = resistance_composite,
      srcwt = sourcewt_composite,
      patch_distances = quantiles_all_dists,
      q = 25, ## ~45 km
      run_name = "2026-01-23",
      ## untiled by default; `BC_CONN_OMNISCAPE_BENCH="2x3"` also writes tiled variants for
      ## benchmarking. See write_omniscape_config() on why tile overlap limits their usefulness.
      ntiles = omniscape_tiles()
    ),
    format = "file",
    pattern = map(resistance_composite, sourcewt_composite),
    iteration = "list"
  ),

  tar_target(
    name = omniscape_config_nndist,
    command = write_omniscape_config(
      res = resistance_composite,
      srcwt = sourcewt_composite,
      patch_distances = quantiles_nn_dists,
      q = 100, ## could reasonably use e.g., 90, 95, 99, 100
      run_name = "2026-01-23",
      ntiles = omniscape_tiles()
    ),
    format = "file",
    pattern = map(resistance_composite, sourcewt_composite),
    iteration = "list"
  ),

  ## Which launch scripts to actually run, and with how many Julia threads.
  ##
  ## `BC_CONN_OMNISCAPE` selects the configurations: "none" (default -- write configs only),
  ## "nn", "alldist", or "all". Leaving it unset means a full `tar_make()` prepares every input and
  ## stops short of committing the machine to a multi-day Omniscape run.
  tar_target(
    name = omniscape_scripts_to_run,
    command = select_omniscape_runs(
      omniscape_config_nndist,
      omniscape_config_alldist,
      which = Sys.getenv("BC_CONN_OMNISCAPE", "none")
    ),
    deployment = "main",
    cue = tar_cue(mode = "always") ## the env var is not a target dependency
  ),
  ## Runs are executed sequentially rather than branched: each one already saturates the machine
  ## (64 Julia threads, 100-650 GB), so running two at once would only thrash.
  tar_target(
    name = omniscape_run,
    command = run_omniscape_all(
      omniscape_scripts_to_run,
      julia_threads = as.integer(Sys.getenv("BC_CONN_JULIA_THREADS", 64L))
    ),
    format = "file",
    deployment = "main" ## long-running; keep it off the crew workers
  ),

  ## Measured resource use for every run made, for the README table
  tar_target(
    name = omniscape_benchmarks_csv,
    command = omniscape_benchmark_table(omniscape_run),
    format = "file"
  ),

  tar_target(
    name = omniscape_summary,
    command = zonal_summaries(
      omniscape_run,
      Quesnel_TSA,
      LCC,
      LU,
      BEC,
      moose_wetlands,
      MDWR,
      OGMA,
      parks,
      wetlands,
      WHA
    ),
    format = "file"
  ),

  ## render README
  tar_render(
    name = readme,
    path = "README.Rmd"
  ),

  ## write reproducibility receipt
  tar_target(
    name = reproducibility_receipt,
    command = write_reproducibility_receipt("INFO.md"),
    format = "file"
  )
  ## TODO: add julia and omniscape info?
)
