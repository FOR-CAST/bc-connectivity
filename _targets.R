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
    "terra",
    "tibble",
    "units",
    "workflowtools"
  ),

  # format = "qs", ## Optionally set the default storage format. qs is fast.

  ## Pipelines that take a long time to run may benefit from distributed computing.
  ##  To use this capability in tar_make(), supply a {crew} controller
  ## as discussed at <https://books.ropensci.org/targets/crew.html>.
  controller = crew::crew_controller_local(workers = 8, seconds_idle = 600),
  storage = "worker",
  retrieval = "worker",

  ## Debugging options (see <https://books.ropensci.org/targets/debugging.html>)
  ## NOTE: to run in interactive session for use with browser(), run pipeline with:
  ## `tar_make(callr_function = NULL, use_crew = FALSE, as_job = FALSE)`
  error = "trim" ## allows targets to keep running unless affected by the error
  # workspace_on_error = TRUE

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
  tar_target(
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
  tar_target(
    name = forest_disturbance_seral,
    command = create_forest_disturbance_seral(forest_disturbance, VRI_BECNDT) |>
      dplyr::group_by(Seral) |>
      tar_group(),
    iteration = "group"
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

  ## TODO: targets branching not working with sf objects
  ## - even though sf inherits from data.frame, branching complains about it not being a data.frame;
  ## - manually split the forest seral sf object to run in parallel, since it's only 4 predetermined groups;
  ## - manually recombine all patches and add resistance and sourcewt values;
  tar_target(
    name = forest_disturbance_seral_early,
    command = subset_forest_seral_ageclass(forest_disturbance_seral, "Early")
  ),
  tar_target(
    name = forest_disturbance_seral_mid,
    command = subset_forest_seral_ageclass(forest_disturbance_seral, "Mid")
  ),
  tar_target(
    name = forest_disturbance_seral_mature,
    command = subset_forest_seral_ageclass(forest_disturbance_seral, "Mature")
  ),
  tar_target(
    name = forest_disturbance_seral_old,
    command = subset_forest_seral_ageclass(forest_disturbance_seral, "Old")
  ),

  tar_target(
    name = forest_patches_early,
    command = define_forest_seral_patches(forest_disturbance_seral_early)
  ),
  tar_target(
    name = forest_patches_mid,
    command = define_forest_seral_patches(forest_disturbance_seral_mid)
  ),
  tar_target(
    name = forest_patches_mature,
    command = define_forest_seral_patches(forest_disturbance_seral_mature)
  ),
  tar_target(
    name = forest_patches_old,
    command = define_forest_seral_patches(forest_disturbance_seral_old)
  ),

  tar_target(
    name = forest_patches_early_png,
    command = plot_forest_disturbance_seral(
      forest_patches_early,
      Quesnel_TSA,
      "Quesnel_TSA_for_dist_early_patches.png"
    ),
    format = "file"
  ),
  tar_target(
    name = forest_patches_mid_png,
    command = plot_forest_disturbance_seral(
      forest_patches_mid,
      Quesnel_TSA,
      "Quesnel_TSA_for_dist_mid_patches.png"
    ),
    format = "file"
  ),
  tar_target(
    name = forest_patches_mature_png,
    command = plot_forest_disturbance_seral(
      forest_patches_mature,
      Quesnel_TSA,
      "Quesnel_TSA_for_dist_mature_patches.png"
    ),
    format = "file"
  ),
  tar_target(
    name = forest_patches_old_png,
    command = plot_forest_disturbance_seral(
      forest_patches_old,
      Quesnel_TSA,
      "Quesnel_TSA_for_dist_old_patches.png"
    ),
    format = "file"
  ),

  tar_target(
    name = forest_patches_seral,
    command = rbind(
      forest_patches_early,
      forest_patches_mid,
      forest_patches_mature,
      forest_patches_old
    )
  ),

  tar_target(
    name = forest_patches_all,
    command = define_forest_seral_patch_conn_vals(forest_patches_seral)
  ),
  tar_target(
    name = forest_patches_all_gpkg,
    command = save_gpkg(forest_patches_all, "forest_disturbance_seral.gpkg"),
    format = "file"
  ),
  tar_target(
    name = forest_patches_all_png,
    command = plot_forest_disturbance_seral(
      forest_patches_all,
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
    command = get_roads(Quesnel_TSA_buffered_LCC, LCC), ## note differest studyArea CRS needed
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
  tar_target(
    name = patch_summary,
    command = calc_patch_stats(forest_patches_all),
  ),
  tar_target(
    name = patch_summary_csv,
    command = save_patch_stats(patch_summary),
    format = "file"
  ),

  ## interpatch assesments
  tar_target(
    name = distance_type,
    command = c("all", "nn")
  ),
  tar_target(
    name = interpatch_distances,
    command = calc_interpatch_distances(forest_patches_old, distance_type),
    pattern = map(distance_type),
    iteration = "list"
  ),
  tar_target(
    name = interpatch_distances_png,
    command = plot_hist_dists(interpatch_distances, distance_type),
    format = "file",
    pattern = map(interpatch_distances, distance_type),
    iteration = "list"
  ),

  ## create resistance and sourcewt rasters
  tar_target(
    name = resistance_forest,
    command = create_resistance_raster(
      polys = forest_patches_all,
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
      polys = forest_patches_all,
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

  ## omniscape
  tar_target(
    name = omniscape_config,
    command = write_omniscape_config(
      res = resistance_composite,
      srcwt = sourcewt_composite,
      patch_distances = interpatch_distances,
      q = 99, ## could reasonably use e.g., 95, 99, 100 percentile
      run_name = "2025-12-18"
    ),
    format = "file",
    pattern = cross(map(resistance_composite, sourcewt_composite), map(interpatch_distances)),
    iteration = "list"
  ),
  ## TODO: too many issues launching julia, running Omniscape from R;
  ## -- run manually from bash shell (but not via Rstudio terminal!)
  # tar_target(
  #   name = omniscape_run,
  #   command = run_omniscape(omniscape_config, 64L),
  #   format = "file"
  # ),

  ## write reproducibility receipt
  tar_target(
    name = reproducibility_receipt,
    command = write_reproducibility_receipt("INFO.md"),
    format = "file"
  ) ## TODO: add julia and omniscape info?
)
