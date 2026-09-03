# Multi-district target factories -------------------------------------------------------------

## The pipeline runs once per Natural Resource District, as a pair of `targets` projects: a `prep`
## project ending at the resistance and source-weight rasters, and an `omniscape` project that
## consumes them. `_targets.yaml` names the projects; `TAR_PROJECT` selects one.
##
## The factories exist so there is exactly one definition of each target across all districts.
## Everything that varies by district lives in `R/districts.R` and reaches the targets through the
## `district` target below -- nothing is parameterised by editing a project script, because a
## project script is what drifts.
##
## Why the split (see docs/cariboo-extension-plan.md B2'.1): separate stores firewall by *process*
## rather than by declared capacity, and they contain invalidation -- an unrelated edit upstream
## cannot mark an hours-long Omniscape run stale.

#' District-aware project paths
#'
#' The per-district equivalent of `get_path()`. `Data/raw` is **shared** across districts;
#' `Data/processed` and `Outputs` are per-district and independent.
#'
#' `get_path()` is deliberately not modified to take a district: `targets` hashes function bodies,
#' and every existing target depends on `get_path()`, so changing it would invalidate the entire
#' stored Quesnel pipeline.
#'
#' @param type one of "download", "inputs", "rasters", "omniscape", "outputs", "project", "figures"
#' @param district district key or spec, as [district_spec()]
#'
#' @returns character path, created if it does not exist
#'
#' @export
district_path <- function(type, district) {
  spec <- if (is.list(district)) district else district_spec(district)
  project_dir <- workflowtools::findProjectPath()
  key <- spec$key

  switch(
    type,
    ## shared across districts -- raw provincial layers are district-independent
    download = file.path(project_dir, "Data", "raw") |> fs::dir_create(),
    project = fs::path(project_dir),
    ## per-district
    inputs = file.path(project_dir, "Data", "processed", key) |> fs::dir_create(),
    rasters = file.path(project_dir, "Data", "processed", "rasters", key) |> fs::dir_create(),
    omniscape = file.path(project_dir, "Omniscape", key) |> fs::dir_create(),
    outputs = file.path(project_dir, "Outputs", key) |> fs::dir_create(),
    figures = file.path(project_dir, "Outputs", key, "figures") |> fs::dir_create()
  )
}

#' Targets for one district's data-preparation project
#'
#' @returns list of targets
#'
#' @export
## Route a writer's `dst` into the district's own directory.
##
## The writers in `R/data_prep.R` and `R/rasters.R` resolve their own destination as
## `file.path(get_path(<type>), dst)`, and the raster ones append the resolution to `dst` BEFORE
## prepending that directory. A relative subpath therefore survives both steps and lands
## per-district, without editing any writer -- `targets` hashes function bodies, so editing one
## would invalidate the legacy Quesnel store (100.2 GB, 280.1 h).
##
## Returns the relative subpath, having created the directory the writer will then write into;
## `save_gpkg()` and `terra::writeRaster()` do not create missing parents.
district_dst <- function(district, dst, type = c("inputs", "rasters")) {
  type <- match.arg(type)
  district_path(type, district) ## side effect: creates the directory
  file.path(district$key, dst)
}

## District-aware variants of the writers that hardcode their own filename, and so offer no `dst`
## to route with `district_dst()`. They are added here, rather than edited in place in
## `R/data_prep.R` / `R/patch_stats.R`, so those files keep a zero diff: `targets` hashes function
## bodies, and the legacy Quesnel store depends on the originals.

get_landcover_raster_district <- function(studyArea, district) {
  dst <- file.path(district_path("rasters", district), paste0(district$key, "_LCC.tif"))

  ## the source layer is province-wide and district-independent, so it stays in the shared cache
  lcc_url <- "https://datacube-prod-data-public.s3.ca-central-1.amazonaws.com/store/land/landcover/landcover-2020-classification.tif"
  lcc_tif <- file.path(district_path("download", district), basename(lcc_url))

  if (!file.exists(lcc_tif)) {
    withr::with_options(list(timeout = 300), {
      download.file(lcc_url, destfile = lcc_tif)
    })
  }

  landcover <- terra::rast(lcc_tif)
  studyAreaLCC <- sf::st_transform(studyArea, crs = terra::crs(landcover))

  terra::crop(landcover, studyAreaLCC, mask = TRUE) |>
    terra::writeRaster(dst, datatype = "INT1U", overwrite = TRUE)

  return(dst)
}

get_dem_raster_district <- function(studyArea, district) {
  dst <- file.path(district_path("rasters", district), paste0(district$key, "_DEM.tif"))

  ## the VRT indexes the CDED tiles covering THIS district's AOI, so it is district-specific even
  ## though it lives in the shared download directory
  dem <- bcmaps::cded_terra(
    aoi = studyArea,
    dest_vrt = file.path(district_path("download", district), paste0(district$key, "_DEM.vrt"))
  )
  studyAreaDEM <- sf::st_transform(studyArea, crs = terra::crs(dem))

  terra::crop(dem, studyAreaDEM, mask = TRUE) |>
    terra::writeRaster(dst, overwrite = TRUE)

  return(dst)
}

save_patch_stats_district <- function(stats_df, district) {
  dst <- file.path(district_path("outputs", district), "seral_patch_stats.csv")

  utils::write.csv(x = stats_df, file = dst, row.names = FALSE)

  return(dst)
}

plot_hist_dists_district <- function(dists, type, district) {
  dst <- file.path(
    district_path("figures", district),
    glue::glue("histogram_patch_distances_{type}.png")
  )

  gg <- ggplot2::ggplot(data.frame(dists), ggplot2::aes(x = dists)) +
    ggplot2::geom_histogram(fill = "lightgrey") +
    ggplot2::geom_vline(
      xintercept = c(stats::median(dists), mean(dists)),
      colour = c("blue", "darkred"),
      linetype = 2,
      linewidth = 1.5
    ) +
    ggplot2::annotate(
      "text",
      x = c(stats::median(dists), mean(dists)),
      y = Inf,
      label = c("median", "mean"),
      colour = c("blue", "darkred"),
      angle = 90,
      vjust = 1.5,
      hjust = 1.5
    ) +
    ggplot2::xlab("Interpatch distance") +
    ggplot2::ylab("Frequency") +
    ggplot2::ggtitle(glue::glue("Frequency distribution of {type} interpatch distances")) +
    ggplot2::theme_minimal()

  ggplot2::ggsave(filename = dst, plot = gg, width = 8, height = 6)

  return(dst)
}

dataprep_targets <- function() {
  ## resolved when the project script is sourced, so it can shape the GRAPH (which targets
  ## exist), not just values -- the `district` target below carries the same spec to commands
  spec <- active_district()

  list(
    ## The single source of district truth: read from the active project name, so a project cannot
    ## be run against the wrong district's data.
    tar_target(district, active_district(), deployment = "main"),

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
      name = study_area,
      command = get_NRD_boundary(NRD_shapefile, district$district_name, buffer = FALSE)
    ),
    tar_target(
      name = study_area_gpkg,
      command = save_gpkg(study_area, district_dst(district, "studyarea.gpkg")),
      format = "file"
    ),
    tar_target(
      name = study_area_buffered,
      command = get_NRD_boundary(NRD_shapefile, district$district_name, buffer = TRUE)
    ),
    tar_target(
      name = study_area_buffered_gpkg,
      command = save_gpkg(study_area_buffered, district_dst(district, "studyarea_buffered.gpkg")),
      format = "file"
    ),
    tar_target(
      name = study_area_buffered_LCC,
      command = sf::st_transform(study_area_buffered, crs = terra::crs(LCC))
    ),

    ## LCC used as rasterToMatch
    tar_target(
      name = LCC_tif,
      command = get_landcover_raster_district(study_area_buffered, district),
      format = "file"
    ),
    tar_target(
      name = agg_fact_lcc,
      command = district_agg_factors(district)
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
      command = get_dem_raster_district(study_area_buffered, district),
      format = "file"
    ),
    tar_terra_rast(
      name = DEM,
      command = terra::rast(DEM_tif)
    ),

    ## planning boundaries
    tar_target(
      name = LU,
      command = get_landscape_units(study_area_buffered, LCC)
    ),
    tar_target(
      name = LU_gpkg,
      command = save_gpkg(LU, district_dst(district, "landscape_units.gpkg")),
      format = "file"
    ),

    ## ecological features
    tar_target(
      name = BEC,
      command = get_bec(study_area_buffered, LCC)
    ),
    tar_target(
      name = BEC_gpkg,
      command = save_gpkg(BEC, district_dst(district, "BEC.gpkg")),
      format = "file"
    ),
    tar_target(
      name = BECNDT,
      command = create_bec_ndt(BEC)
    ),
    tar_target(
      name = BECNDT_gpkg,
      command = save_gpkg(BECNDT, district_dst(district, "BECNDT.gpkg")),
      format = "file"
    ),
    tar_target(
      name = BECNDT_png,
      command = plot_bec_ndt(BECNDT, study_area),
      format = "file"
    ),

    tar_target(
      name = leading_group_cariboo,
      command = get_leading_group_cariboo(study_area_buffered, LCC)
    ),
    tar_target(
      name = leading_group_cariboo_gpkg,
      command = save_gpkg(
        leading_group_cariboo,
        district_dst(district, "leading_group_cariboo.gpkg")
      ),
      format = "file"
    ),

    tar_target(
      name = VRI,
      command = get_vri(study_area_buffered, LCC)
    ),
    tar_target(
      name = VRI_gpkg,
      command = save_gpkg(VRI, district_dst(district, "VRI.gpkg")),
      format = "file"
    ),
    ## The VRI x NDT-BEC overlay is tiled for the same reason the seral overlay is: measured at
    ## ~0.005 s per VRI polygon, and superlinear at full scale -- a single untiled call ran for 50
    ## minutes without finishing, against ~28 minutes of CPU when split across the study area.
    ## Tiles come from the same grid as the seral step, so their seams line up.
    tar_terra_vect(
      name = VRI_BECNDT_tiles,
      command = create_vri_becndt(VRI, BECNDT, leading_group_cariboo, study_area_tiles),
      ## NOTE: no `iteration =` -- `tar_terra_vect()` has no such argument, and swallows it via `...`
      ## only to fail at store time with "unused argument". Its branches already read back as a list.
      pattern = map(study_area_tiles)
    ),
    ## `deployment = "main"`: these two targets only concatenate the branches above, but they failed
    ## on a crew worker with "Error storing output: C stack usage 13972132161860 is too close to the
    ## limit" -- a nonsense figure. R's C stack detection is unreliable in the worker (`Cstack_info()`
    ## reports a normal 8 MB stack in a plain session), and writing several hundred thousand polygons
    ## recurses deeply enough to trip it. The identical combine and write succeed on main in ~5 s.
    ## Running here also avoids shipping the combined layer back from a worker.
    tar_terra_vect(
      name = VRI_BECNDT,
      command = combine_spatvectors(VRI_BECNDT_tiles),
      deployment = "main"
    ),
    tar_target(
      name = VRI_BECNDT_gpkg,
      command = save_gpkg(VRI_BECNDT, district_dst(district, "VRI_BECNDT.gpkg")),
      format = "file"
    ),

    tar_target(
      name = forest_disturbance,
      command = get_forest_disturbance(study_area_buffered, LCC)
    ),
    tar_target(
      name = forest_disturbance_gpkg,
      command = save_gpkg(forest_disturbance, district_dst(district, "forest_disturbance.gpkg")),
      format = "file"
    ),
    ## Seral stage assignment is an overlay, and overlays are embarrassingly parallel over space:
    ## tile the study area and let the crew workers do it. Each branch reads only the features
    ## overlapping its tile straight from the GeoPackages, so no worker ever holds the 4 M-polygon
    ## forest disturbance layer.
    tar_target(
      name = study_area_tiles,
      command = make_study_area_tiles(study_area_buffered_LCC, n = n_tiles),
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
      pattern = map(study_area_tiles) ## no `iteration =`; see VRI_BECNDT_tiles above
    ),
    tar_terra_vect(
      name = forest_disturbance_seral,
      command = combine_spatvectors(forest_disturbance_seral_tiles),
      deployment = "main" ## see VRI_BECNDT above
    ),
    tar_target(
      name = forest_disturbance_seral_png,
      command = plot_forest_disturbance_seral(
        forest_disturbance_seral,
        study_area,
        "study_area_for_dist_seral.png"
      ),
      format = "file"
    ),
    tar_target(
      name = forest_disturbance_seral_gpkg,
      command = save_gpkg(
        forest_disturbance_seral,
        district_dst(district, "forest_disturbance_seral.gpkg")
      ),
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
    ## The tiled resultant reads its base layer through GDAL rather than out of the store: a worker
    ## then materialises only the polygons inside its own tile, instead of deserialising all 255,879
    ## of them to keep a few thousand.
    tar_target(
      name = patches_patch_size_gpkg,
      command = save_gpkg(patches_patch_size, district_dst(district, "patches_patch_size.gpkg")),
      format = "file"
    ),

    ## arcpy step 6a: Union of the seral layer with both interior-forest layers. Every polygon keeps
    ## its own seral stage and gains `old_interior` / `matold_interior` flags -- interior forest is an
    ## attribute, not a relabelling.
    ## Tiled: this ran 5h 51m 58s in a single process on 2026-08-31, and the overlay is embarrassingly
    ## parallel over space.
    ##
    ## The tiles are `study_area_tiles` -- the *same* grid the seral layer was built on, which matters
    ## for more than consistency. That layer already carries vertices lying bit-exactly on these seam
    ## coordinates, so re-cutting here intersects at existing vertices, GEOS invents no new ones, and
    ## the halves of a split polygon abut exactly. A different or finer grid would cut at fresh
    ## coordinates and forfeit that.
    ##
    ## Cropping splits polygons at the seams, so the resultant has a few percent more features than
    ## the untiled build. Area, footprint and every attribute combination are unchanged, and
    ## `calc_matold()` dissolves and explodes before the interpatch distances are measured, which puts
    ## split patches back together -- verified on real geometry across a seam: identical feature count
    ## after `calc_matold()`, and identical nearest-neighbour quantiles.
    tar_terra_vect(
      name = patches_union_final_tiles,
      command = patches_union_into_final_resultant(
        patches_patch_size_gpkg,
        patches_interior_forest_old,
        patches_interior_forest_mature_old,
        study_area_tiles
      ),
      ## NOTE: no `iteration =` -- see `VRI_BECNDT_tiles` above
      pattern = map(study_area_tiles)
    ),
    tar_terra_vect(
      name = patches_union_final,
      command = combine_spatvectors(patches_union_final_tiles),
      deployment = "main"
    ),

    tar_terra_vect(
      name = forest_patches_final,
      command = define_forest_seral_patch_conn_vals(patches_union_final)
    ),
    tar_target(
      name = forest_patches_final_gpkg,
      command = save_gpkg(
        forest_patches_final,
        district_dst(district, "forest_patches_final.gpkg")
      ),
      format = "file"
    ),
    tar_target(
      name = forest_patches_final_png,
      command = plot_forest_disturbance_seral(
        forest_patches_final,
        study_area,
        "study_area_for_dist_seral_patches.png"
      ),
      format = "file"
    ),

    ## biodiversity features
    tar_target(
      name = MDWR,
      command = get_mdwr(study_area_buffered, LCC)
    ),
    tar_target(
      name = MDWR_gpkg,
      command = save_gpkg(MDWR, district_dst(district, "MDWR.gpkg")),
      format = "file"
    ),
    tar_target(
      name = moose_wetlands,
      command = get_moose_wetlands(study_area_buffered, LCC)
    ),
    tar_target(
      name = moose_wetlands_gpkg,
      command = save_gpkg(moose_wetlands, district_dst(district, "moose_wetlands.gpkg")),
      format = "file"
    ),
    tar_target(
      name = OGMA,
      command = get_ogma(study_area_buffered, LCC)
    ),
    tar_target(
      name = OGMA_gpkg,
      command = save_gpkg(OGMA, district_dst(district, "OGMA_current.gpkg")),
      format = "file"
    ),
    tar_target(
      name = parks,
      command = get_parks(study_area_buffered, LCC)
    ),
    tar_target(
      name = parks_gpkg,
      command = save_gpkg(parks, district_dst(district, "parks.gpkg")),
      format = "file"
    ),
    tar_target(
      name = wetlands,
      command = get_wetlands(study_area_buffered, LCC)
    ),
    tar_target(
      name = wetlands_gpkg,
      command = save_gpkg(wetlands, district_dst(district, "wetlands.gpkg")),
      format = "file"
    ),
    tar_target(
      name = WHA,
      command = get_wha(study_area_buffered, LCC)
    ),
    tar_target(
      name = WHA_gpkg,
      command = save_gpkg(WHA, district_dst(district, "WHA.gpkg")),
      format = "file"
    ),
    tar_target(
      name = WUI,
      command = get_wui(study_area_buffered, LCC)
    ),
    tar_target(
      name = WUI_gpkg,
      command = save_gpkg(WUI, district_dst(district, "WUI.gpkg")),
      format = "file"
    ),
    tar_target(
      name = secondary,
      command = create_secondary(WHA, MDWR, moose_wetlands)
    ),
    tar_target(
      name = secondary_gpkg,
      command = save_gpkg(secondary, district_dst(district, "secondary.gpkg")),
      format = "file"
    ),

    ## water features
    tar_target(
      name = lakes,
      command = get_lakes(study_area_buffered, LCC)
    ),
    tar_target(
      name = lakes_gpkg,
      command = save_gpkg(lakes, district_dst(district, "lakes.gpkg")),
      format = "file"
    ),
    tar_target(
      name = rivers,
      command = get_rivers(study_area_buffered, LCC)
    ),
    tar_target(
      name = rivers_gpkg,
      command = save_gpkg(rivers, district_dst(district, "rivers.gpkg")),
      format = "file"
    ),
    tar_target(
      name = streams,
      command = get_streams(study_area_buffered, LCC)
    ),
    tar_target(
      name = streams_gpkg,
      command = save_gpkg(streams, district_dst(district, "stream_order.gpkg")),
      format = "file"
    ),

    ## anthropogenic disturbance features
    tar_target(
      name = railways,
      command = get_railways(study_area_buffered, LCC)
    ),
    tar_target(
      name = railways_gpkg,
      command = save_gpkg(railways, district_dst(district, "railways.gpkg")),
      format = "file"
    ),
    tar_target(
      name = roads,
      command = get_roads(study_area_buffered_LCC, LCC), ## NOTE: different studyArea CRS needed
    ),
    tar_target(
      name = roads_gpkg,
      command = save_gpkg(roads, district_dst(district, "roads.gpkg")),
      format = "file"
    ),
    tar_target(
      name = roads_railways,
      command = create_roads_railways(roads, railways)
    ),
    tar_target(
      name = roads_railways_gpkg,
      command = save_gpkg(roads_railways, district_dst(district, "roads_railways.gpkg")),
      format = "file"
    ),
    tar_target(
      name = human_disturbance,
      command = get_human_disturbance(study_area_buffered, LCC)
    ),
    tar_target(
      name = human_disturbance_gpkg,
      command = save_gpkg(human_disturbance, district_dst(district, "human_disturbance.gpkg")),
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
      command = save_patch_stats_district(patch_summary, district),
      format = "file"
    ),

    ## Interpatch distances ------------------------------------------------------------------------
    ##
    ## Only the reference district measures these. Everything downstream reads two numbers out of
    ## them -- the 25% all-pairs quantile and the 100% nearest-neighbour one -- and those are pinned
    ## across districts (see `reference_distances()`), so for every other district the whole chain is
    ## replaced by the constants it would have produced.
    ##
    ## This is the expensive half of the pipeline: 97.8 h over 2.33 billion pairs on Quesnel, and
    ## pair count grows with the square of patch count. The seam is unchanged either way -- the two
    ## CSVs are written the same, so the Omniscape project cannot tell the difference.
    if (isTRUE(spec$interpatch_distances)) {
      list(
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
          command = plot_hist_dists_district(nn_interpatch_distances_combined, "nn", district),
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
            n_chunks = n_chunks_all,
            ds_dir = file.path(district_path("inputs", district), "all-distances")
          ),
          pattern = map(all_interpatch_distances_grid),
          format = "file"
        ),
        tar_target(
          name = quantiles_all_dists,
          command = calc_all_dists_quantiles(all_interpatch_distances_parquet)
        )
      )
    } else {
      list(
        tar_target(name = quantiles_nn_dists, command = reference_distances()$nn_dists),
        tar_target(name = quantiles_all_dists, command = reference_distances()$all_dists)
      )
    },

    ## create resistance and sourcewt rasters
    tar_target(
      name = resistance_forest,
      command = create_resistance_raster(
        polys = forest_patches_final,
        rasterToMatch = LCC_agg,
        dst = district_dst(district, "resistance_forest.tif", type = "rasters")
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
        dst = district_dst(district, "sourcewt_forest.tif", type = "rasters")
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
        dst = district_dst(district, "resistance_roads.tif", type = "rasters")
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
        dst = district_dst(district, "sourcewt_roads_railways.tif", type = "rasters")
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
        dst = district_dst(district, "resistance_OGMA.tif", type = "rasters")
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
        dst = district_dst(district, "sourcewt_OGMA.tif", type = "rasters")
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
        dst = district_dst(district, "resistance_parks.tif", type = "rasters")
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
        dst = district_dst(district, "sourcewt_parks.tif", type = "rasters")
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
        dst = district_dst(district, "resistance_secondary.tif", type = "rasters")
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
        dst = district_dst(district, "sourcewt_secondary.tif", type = "rasters")
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
        dst = district_dst(district, "resistance_lakes.tif", type = "rasters")
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
        dst = district_dst(district, "sourcewt_lakes.tif", type = "rasters")
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
        dst = district_dst(district, "resistance_rivers.tif", type = "rasters")
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
        dst = district_dst(district, "sourcewt_rivers.tif", type = "rasters")
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
        dst = district_dst(district, "resistance_streams.tif", type = "rasters")
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
        dst = district_dst(district, "sourcewt_streams.tif", type = "rasters")
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
        dst = district_dst(district, "resistance_wetlands.tif", type = "rasters")
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
        dst = district_dst(district, "sourcewt_wetlands.tif", type = "rasters")
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
        dst = district_dst(district, "resistance_composite.tif", type = "rasters")
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
        dst = district_dst(district, "sourcewt_composite.tif", type = "rasters")
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
    ## Seam to the omniscape project ------------------------------------------------------------
    ##
    ## Written as files so the omniscape project gets hash-based invalidation on them, rather than
    ## reading across stores. The resistance/source-weight rasters are already `format = "file"`.
    tar_target(
      name = quantiles_nn_dists_csv,
      command = save_csv(
        quantiles_nn_dists,
        file.path(district_path("inputs", district), "quantiles_nn_dists.csv")
      ),
      format = "file"
    ),
    tar_target(
      name = quantiles_all_dists_csv,
      command = save_csv(
        quantiles_all_dists,
        file.path(district_path("inputs", district), "quantiles_all_dists.csv")
      ),
      format = "file"
    )
  )
}

#' Targets for one district's Omniscape project
#'
#' Consumes the prep project's outputs as `format = "file"` inputs, so this project's expensive
#' targets are invalidated only by their actual inputs changing.
#'
#' @returns list of targets
#'
#' @export
omniscape_targets <- function() {
  list(
    tar_target(district, active_district(), deployment = "main"),

    ## Inputs from the prep project, by path. `district_agg_factors()` decides how many
    ## resolutions exist, so a 90 m-only district simply has fewer branches here -- which is the
    ## whole of the 30 m conditional.
    tar_target(
      name = resistance_composite,
      command = file.path(
        district_path("rasters", district),
        paste0("resistance_composite_", 30 * district_agg_factors(district), ".tif")
      ),
      format = "file"
    ),
    tar_target(
      name = sourcewt_composite,
      command = file.path(
        district_path("rasters", district),
        paste0("sourcewt_composite_", 30 * district_agg_factors(district), ".tif")
      ),
      format = "file"
    ),
    tar_target(
      name = quantiles_nn_dists,
      command = read_csv_file(
        file.path(district_path("inputs", district), "quantiles_nn_dists.csv")
      )
    ),
    tar_target(
      name = quantiles_all_dists,
      command = read_csv_file(
        file.path(district_path("inputs", district), "quantiles_all_dists.csv")
      )
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
        run_name = OMNISCAPE_VINTAGE,
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
        run_name = OMNISCAPE_VINTAGE,
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
    ## One branch per Omniscape configuration, so a failed run does not discard the others and a
    ## completed one is not repeated -- the previous single target wrapped every run in one command,
    ## so any failure threw away days of finished work.
    ##
    ## `deployment = "main"` keeps the branches *sequential*: each run takes 32 Julia threads and
    ## 100-650 GB, so two at once only thrash. Branching buys granularity here, not parallelism.
    ## Bounded concurrency across hosts is the separate `omniscape` targets project driven by
    ## `crew.ssh` (see docs/cariboo-extension-plan.md B2'.1), deliberately *not* a controller group.
    ##
    ## Defined conditionally because `targets` fails with "cannot branch over empty target", and the
    ## default `BC_CONN_OMNISCAPE=none` selects no runs -- the usual `tar_make()` path.
    if (omniscape_any_selected()) {
      tar_target(
        name = omniscape_run,
        command = run_omniscape(
          omniscape_scripts_to_run,
          julia_threads = omniscape_thread_setting()
        ),
        format = "file",
        pattern = map(omniscape_scripts_to_run),
        deployment = "main"
      )
    } else {
      tar_target(
        name = omniscape_run,
        command = character(0),
        format = "file",
        deployment = "main"
      )
    },

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
        study_area,
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
}

## Small IO helpers for the prep -> omniscape seam. Kept here rather than in `R/data_prep.R` so
## that adding them cannot alter any hash the stored Quesnel pipeline depends on.

#' @export
save_csv <- function(x, dst) {
  ## Write the NAMES as a column. `write.csv(row.names = FALSE)` discards them, and the names are
  ## the payload here: `write_omniscape_config()` selects its radius with
  ## `patch_distances[[paste0(q, "%")]]`, so a nameless vector makes the radius unreachable.
  utils::write.csv(
    data.frame(quantile = names(x), value = as.numeric(x)),
    dst,
    row.names = FALSE
  )

  dst
}

#' @export
read_csv_file <- function(path) {
  ## `check.names = FALSE` keeps "25%" and "100%" intact; make.names() would mangle them to "X25."
  df <- utils::read.csv(path, check.names = FALSE)

  stats::setNames(df$value, df$quantile)
}
