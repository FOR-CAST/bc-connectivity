# Helpers -------------------------------------------------------------------------------------

## paths
get_path <- function(type) {
  project_dir <- workflowtools::findProjectPath()

  switch(
    type,
    download = file.path(project_dir, "Data", "raw") |> fs::dir_create(),
    inputs = file.path(project_dir, "Data", "processed") |> fs::dir_create(),
    rasters = file.path(project_dir, "Data", "processed", "rasters") |> fs::dir_create(),
    omniscape = file.path(project_dir, "Omniscape") |> fs::dir_create(),
    outputs = file.path(project_dir, "Outputs") |> fs::dir_create(),
    project = fs::path(project_dir),
    figures = file.path(project_dir, "Outputs", "figures") |> fs::dir_create(),
  )
}

## save geospatial vector data to gpkg
save_gpkg <- function(obj, dst) {
  dst <- file.path(get_path("inputs"), dst)

  if (inherits(obj, "SpatVector")) {
    terra::writeVector(obj, dst, filetype = "GPKG", overwrite = TRUE)
  } else {
    sf::st_write(obj, dst, quiet = TRUE, append = FALSE)
  }

  return(dst)
}

## Create a bounding box of the study area to reduce processing time of large vector datasets
create_bbox <- function(studyArea) {
  sf::st_bbox(studyArea)
}

# Overlay helpers -----------------------------------------------------------------------------

## Polygon work in this project is done with `terra`, driven through `tidyterra`'s dplyr verbs.
##
## terra's overlay operators are GEOS-backed and vectorised in C++, and they implement arcpy's
## overlay semantics directly: `terra::union()`/`terra::intersect()` split geometries at the overlay
## boundaries and carry *both* attribute sets through, which is what the arcpy scripts this project
## ports rely on. `tidyterra` then lets the attribute manipulation read the same as the `sf` +
## `dplyr` code it replaces.
##
## Note in particular that `sf::st_join()` is NOT an overlay: it keeps whole geometries from `x`,
## duplicating a row for every `y` they touch. A stand spanning two NDT-BEC zones comes back twice
## at full extent and is then assigned two different seral stages. See
## `create_forest_disturbance_seral()`.

## combine the SpatVectors produced by a branched target back into one layer
combine_spatvectors <- function(x) {
  if (inherits(x, "SpatVector")) {
    return(x)
  }

  x <- Filter(function(e) !is.null(e) && nrow(e) > 0L, x)

  if (length(x) == 0L) {
    stop("no non-empty branches to combine")
  }

  ## `unname()` matters: `rbind` matches named list elements to its own formals
  do.call(rbind, unname(x))
}

## Regular grid of tiles covering the study area, ready for `pattern = map()`.
##
## Overlays are embarrassingly parallel over space, so tiling lets the crew workers do the work
## instead of a single main-session process. Each tile clips its inputs to the tile boundary, so the
## tiles partition the study area and nothing is double counted; polygons split at a tile seam are
## healed by the dissolve in `patches_get_input_data()`.
make_study_area_tiles <- function(studyArea, n = c(8, 8)) {
  sa <- sf::st_as_sf(tidyterra::as_spatvector(studyArea)) |> sf::st_set_agr("constant")

  grid <- sf::st_make_grid(sa, n = n) |> sf::st_as_sf()
  names(grid)[names(grid) == attr(grid, "sf_column")] <- "geom"
  grid <- sf::st_set_geometry(grid, "geom")

  grid[lengths(sf::st_intersects(grid, sa)) > 0, , drop = FALSE] |>
    dplyr::mutate(tile = dplyr::row_number()) |>
    dplyr::group_by(tile) |>
    targets::tar_group()
}

## write session and other info for reproducibility
write_reproducibility_receipt <- function(dst = "INFO.md") {
  if (file.exists(dst)) {
    unlink(dst)
  }

  workflowtools::reproducibilityReceipt(writeTo = dst)

  return(dst)
}


# Quesnel NRD Boundary ------------------------------------------------------------------------

## NOTE: bcmaps::nr_districts() provides a version suitable for web mapping applications,
## but that version is simplified; use the manually downloaded file for analyses
## <https://catalogue.data.gov.bc.ca/dataset/0bc73892-e41f-41d0-8d8e-828c16139337/resource/2d9d0a5c-bdf7-47e8-9038-103a93e6205a>

get_quesnel_NRD_boundary <- function(file, buffer = FALSE) {
  if (file.exists(file)) {
    Quesnel_TSA <- sf::st_read(file, quiet = TRUE) |>
      dplyr::filter(DSTRCT_NM == "Quesnel Natural Resource District") |>
      dplyr::select(DSTRCT_NM) |>
      dplyr::rename(DIST_NAME = DSTRCT_NM)
  } else {
    Quesnel_TSA <- bcmaps::nr_districts() |>
      dplyr::filter(DISTRICT_NAME == "Quesnel Natural Resource District") |>
      dplyr::select(DISTRICT_NAME) |>
      dplyr::rename(DIST_NAME = DISTRICT_NAME)
  }

  if (isTRUE(buffer)) {
    sf::st_buffer(Quesnel_TSA, 500 * 30) ## add 500-pixel buffer to mitigate edge-effects
  } else {
    Quesnel_TSA
  }
}

# Landcover -----------------------------------------------------------------------------------

## load in the 2020 Canada Landcover Classification layer (30m) to be used as a base raster
## for rasterizing feature shapefiles
## <https://open.canada.ca/data/en/dataset/ee1580ab-a23d-4f86-a09b-79763677eb47/resource/f1ba2faa-ff10-4526-815a-c57b99eef1bb>

get_landcover_raster <- function(studyArea) {
  dst <- file.path(get_path("rasters"), "Quesnel_TSA_LCC.tif")

  lcc_url <- "https://datacube-prod-data-public.s3.ca-central-1.amazonaws.com/store/land/landcover/landcover-2020-classification.tif"
  lcc_tif <- file.path(get_path("download"), basename(lcc_url))

  if (!file.exists(lcc_tif)) {
    withr::with_options(list(timeout = 300), {
      download.file(lcc_url, destfile = lcc_tif)
    })
  }

  ## Load the land cover raster and re-project Quesnel buffer to match its projection
  landcover <- terra::rast(lcc_tif)
  studyAreaLCC <- sf::st_transform(studyArea, crs = terra::crs(landcover))

  ## Crop and mask to study area
  terra::crop(landcover, studyAreaLCC, mask = TRUE) |>
    terra::writeRaster(dst, datatype = "INT1U", overwrite = TRUE)

  return(dst)
}

# Digital Elevation Model (DEM) ---------------------------------------------------------------

get_dem_raster <- function(studyArea) {
  dst <- file.path(get_path("rasters"), "Quesnel_TSA_DEM.tif")

  dem <- bcmaps::cded_terra(
    aoi = studyArea,
    dest_vrt = file.path(get_path("download"), "Quesnel_TSA_DEM.vrt")
  )
  studyAreaDEM <- sf::st_transform(studyArea, crs = terra::crs(dem))

  ## Crop and mask to study area
  terra::crop(dem, studyAreaDEM, mask = TRUE) |>
    terra::writeRaster(dst, overwrite = TRUE)

  return(dst)
}

# Seral stage definitions ---------------------------------------------------------------------

## Define NDT-BEC-specific seral stages according to the Biodiversity Guidebook
seral_stages <- function() {
  tibble::tribble(
    ~NDT_BEC      , ~Early , ~Mid , ~Mature , ~Old ,
    "NDT1-ESSF"   ,      0 ,   40 ,     120 ,  250 ,
    "NDT1-ICH"    ,      0 ,   40 ,     100 ,  250 ,
    "NDT1-MH"     ,      0 ,   40 ,     120 ,  250 ,
    "NDT2-CWH"    ,      0 ,   40 ,      80 ,  250 ,
    "NDT2-ESSF"   ,      0 ,   40 ,     120 ,  250 ,
    "NDT2-ICH"    ,      0 ,   40 ,     100 ,  250 ,
    "NDT2-SBS"    ,      0 ,   40 ,     100 ,  250 ,
    "NDT3-ESSF"   ,      0 ,   40 ,     120 ,  140 ,
    "NDT3-ICH"    ,      0 ,   40 ,     100 ,  140 ,
    "NDT3-MS"     ,      0 ,   40 ,     100 ,  140 ,
    "NDT3-SBS"    ,      0 ,   40 ,     100 ,  140 ,
    "NDT3-SBPS"   ,      0 ,   40 ,     100 ,  140 ,
    "NDT4-IDF-FD" ,      0 ,   40 ,     100 ,  250 ,
    "NDT4-IDF-PL" ,      0 ,   40 ,     100 ,  140
  )
}

seral_stages_long <- function(max_age) {
  seral_stages() |>
    tidyr::pivot_longer(
      cols = Early:Old,
      names_to = "Seral",
      values_to = "Age_Min"
    ) |>
    dplyr::group_by(NDT_BEC) |>
    dplyr::arrange(match(Seral, c("Early", "Mid", "Mature", "Old")), .by_group = TRUE) |>
    dplyr::mutate(
      Age_Max = dplyr::lead(Age_Min, default = max_age + 1)
    ) |>
    dplyr::relocate(Seral, .after = Age_Max)
}

# bcdata layers -------------------------------------------------------------------------------

## The BC data catalogue's WFS endpoint is unreliable for large paginated queries -- VRI alone needs
## 34 requests, and one failure ("There was an issue sending this WFS request") aborts the whole
## download and, with `error = "abridge"`, the pipeline with it. Retry with a linear backoff.
##
## `f` is a function rather than an expression because a promise is forced only once: passing
## `expr` directly would return the same cached error on every retry.
with_retries <- function(f, tries = 5L, wait = 30) {
  for (i in seq_len(tries)) {
    result <- tryCatch(f(), error = function(e) e)

    if (!inherits(result, "error")) {
      return(result)
    }

    if (i < tries) {
      message(
        "attempt ",
        i,
        "/",
        tries,
        " failed (",
        conditionMessage(result),
        "); ",
        "retrying in ",
        wait * i,
        "s"
      )
      Sys.sleep(wait * i)
    } else {
      stop(result)
    }
  }
}

get_bcdata <- function(id, select_cols, studyArea, rasterToMatch) {
  with_retries(function() {
    bcdata::bcdc_query_geodata(id) |>
      dplyr::filter(INTERSECTS(studyArea)) |>
      dplyr::select(dplyr::any_of(select_cols)) |>
      dplyr::collect()
  }) |>
    sf::st_set_agr("constant") |>
    sf::st_crop(studyArea) |>
    sf::st_transform(terra::crs(rasterToMatch))
}

## planning area boundaries
get_landscape_units <- function(studyArea, rasterToMatch) {
  get_bcdata(
    id = "11277e35-d8be-47e4-bb1f-c38e393179c6",
    select_cols = c("FEATURE_AREA_SQM", "LANDSCAPE_UNIT_NAME"),
    studyArea = studyArea,
    rasterToMatch = rasterToMatch
  )
}

## environmental features
get_bec <- function(studyArea, rasterToMatch) {
  get_bcdata(
    id = "f358a53b-ffde-4830-a325-a5a03ff672c3",
    select_cols = c("BGC_LABEL", "ZONE", "SUBZONE", "VARIANT", "NATURAL_DISTURBANCE"),
    studyArea = studyArea,
    rasterToMatch = rasterToMatch
  )
}

## NDT-BEC with additional BEC zone (for subsequent dissolve)
## !! ensure it matches the formatting in the Biodiversity Guidebook
create_bec_ndt <- function(BEC) {
  BEC |>
    dplyr::select(NATURAL_DISTURBANCE, ZONE) |>
    dplyr::mutate(NDT_BEC = paste0(NATURAL_DISTURBANCE, "-", ZONE), BEC_ZONE = ZONE)
}

plot_bec_ndt <- function(BECNDT, studyArea) {
  dst <- file.path(get_path("figures"), "Quesnel_TSA_NDT-BEC.png")

  gg_bec_ndt <- ggplot2::ggplot(BECNDT) +
    ggplot2::geom_sf(ggplot2::aes(fill = NDT_BEC)) +
    ggplot2::geom_sf(data = studyArea, color = "black", fill = NA) +
    ggplot2::theme_bw() +
    ggspatial::annotation_north_arrow(
      location = "bl",
      which_north = "true",
      pad_x = ggplot2::unit(0.25, "in"),
      pad_y = ggplot2::unit(0.25, "in"),
      style = ggspatial::north_arrow_fancy_orienteering
    ) +
    ggplot2::xlab("Longitude") +
    ggplot2::ylab("Latitude") +
    ggplot2::ggtitle("Quesnel NRD")

  ggplot2::ggsave(dst, gg_bec_ndt, width = 16, height = 12)

  return(dst)
}

## biodiversity features
get_ogma <- function(studyArea, rasterToMatch) {
  get_bcdata(
    id = "1b30f3bd-0ad0-4128-916b-66c6dd91dea4",
    select_cols = c(
      "OGMA_TYPE",
      "LEGAL_OGMA_PROVID",
      "FEATURE_AREA_SQM",
      "FEATURE_LENGTH_M",
      "OBJECTID"
    ),
    studyArea = studyArea,
    rasterToMatch = rasterToMatch
  ) |>
    dplyr::mutate(Resistance = 1, SourceWt = 1)
}

get_parks <- function(studyArea, rasterToMatch) {
  get_bcdata(
    id = "1130248f-f1a3-4956-8b2e-38d29d3e4af7",
    select_cols = c("PARK_CLASS", "PROTECTED_LANDS_DESIGNATION", "FEATURE_AREA_SQM"),
    studyArea = studyArea,
    rasterToMatch = rasterToMatch
  ) |>
    dplyr::mutate(Resistance = 1, SourceWt = 1)
}

get_mdwr <- function(studyArea, rasterToMatch) {
  get_bcdata(
    id = "a60d7b6e-88b2-4105-95e2-aaf6cc3468cf",
    select_cols = c("TIMBER_HARVEST_OPP_CODE"),
    studyArea = studyArea,
    rasterToMatch = rasterToMatch
  )
}

get_wha <- function(studyArea, rasterToMatch) {
  get_bcdata(
    id = "b19ff409-ef71-4476-924e-b3bcf26a0127",
    select_cols = c("COMMON_SPECIES_NAME", "TIMBER_HARVEST_CODE", "FEATURE_AREA_SQM"),
    studyArea = studyArea,
    rasterToMatch = rasterToMatch
  )
}

get_wui <- function(studyArea, rasterToMatch) {
  get_bcdata(
    id = "5eff9b25-d43a-4b4d-8ee3-ffe11b43d693",
    select_cols = c(""),
    studyArea = studyArea,
    rasterToMatch = rasterToMatch
  )
}

## High Value Moose Wetlands layer has been handled differently
## due to limits/issues querying and downloading the data using `bcdata`
get_moose_wetlands <- function(studyArea, rasterToMatch) {
  with_retries(function() {
    bcdata::bcdc_query_geodata("2c02040c-d7c5-4960-8d04-dea01d6d3e9f") |>
      dplyr::filter(
        STRGC_LAND_RSRCE_PLAN_NAME == "Cariboo Chilcotin Land Use Plan",
        LEGAL_FEAT_OBJECTIVE == "High Value Wetlands for Moose"
      ) |>
      dplyr::select(STRGC_LAND_RSRCE_PLAN_NAME, LEGAL_FEAT_OBJECTIVE) |>
      dplyr::filter(INTERSECTS(studyArea)) |>
      dplyr::collect()
  }) |>
    sf::st_set_agr("constant") |>
    sf::st_crop(studyArea) |>
    sf::st_transform(terra::crs(rasterToMatch))
}

create_secondary <- function(WHA, MDWR, moose_wetlands) {
  ## Assign resistance and source weight values directly
  wha_vals <- WHA |> dplyr::mutate(Resistance = 250, SourceWt = 0.75)

  mdwr_vals <- MDWR |> dplyr::mutate(Resistance = 250, SourceWt = 0.75)

  moose_wet_vals <- moose_wetlands |> dplyr::mutate(Resistance = 250, SourceWt = 0.75)

  ## Combine all layers together for easy handling for composite raster creation
  dplyr::bind_rows(wha_vals, mdwr_vals, moose_wet_vals)
}

## freshwater atlas layers
get_lakes <- function(studyArea, rasterToMatch) {
  get_bcdata(
    id = "cb1e3aba-d3fe-4de1-a2d4-b8b6650fb1f6",
    select_cols = c("WATERBODY_KEY", "AREA_HA"),
    studyArea = studyArea,
    rasterToMatch = rasterToMatch
  ) |>
    dplyr::mutate(Resistance = 1000, SourceWt = 0)
}

get_rivers <- function(studyArea, rasterToMatch) {
  get_bcdata(
    id = "f7dac054-efbf-402f-ab62-6fc4b32a619e",
    select_cols = c("GNIS_NAME_1"),
    studyArea = studyArea,
    rasterToMatch = rasterToMatch
  ) |>
    dplyr::mutate(Resistance = 1000, SourceWt = 0)
}

get_wetlands <- function(studyArea, rasterToMatch) {
  get_bcdata(
    id = "93b413d8-1840-4770-9629-641d74bd1cc6",
    select_cols = c("WATERBODY_KEY"),
    studyArea = studyArea,
    rasterToMatch = rasterToMatch
  ) |>
    dplyr::mutate(Resistance = 250, SourceWt = 0.75)
}

get_streams <- function(studyArea, rasterToMatch) {
  ## Streams are given different resistances and source weights based on stream order;
  ## buffering has been exaggerated for higher order streams so they will be present
  ## in the 30m resolution composite raster
  streams <- get_bcdata(
    id = "92344413-8035-4c08-b996-65a9b3f62fca",
    select_cols = "STREAM_ORDER",
    studyArea = studyArea,
    rasterToMatch = rasterToMatch
  ) |>
    ## 1 too small of a width to impact forest canopy
    dplyr::filter(STREAM_ORDER != 1) |>
    dplyr::mutate(
      buffer_dist = dplyr::case_when(
        STREAM_ORDER %in% c(2, 3, 4, 5, 6) ~ 15,
        STREAM_ORDER == 7 ~ 75,
        STREAM_ORDER == 8 ~ 130,
        STREAM_ORDER == 9 ~ 300,
        TRUE ~ NA_real_
      ),
      Resistance = dplyr::case_when(
        STREAM_ORDER %in% c(5, 6, 7, 8, 9) ~ 1000,
        STREAM_ORDER == 4 ~ 750,
        STREAM_ORDER == 3 ~ 500,
        STREAM_ORDER == 2 ~ 250,
        TRUE ~ NA_real_
      ),
      SourceWt = 0
    ) |>
    dplyr::filter(!is.na(buffer_dist))

  ## Apply buffer by buffer_dist values
  sf::st_buffer(streams, dist = streams$buffer_dist)
}

## Vegetation Resource Inventory (VRI 2024) needs to be handled differently
## due to limits/issues querying and downloading the data using `bcdata`
## (has 320917 records and requires 33 paginated requests to complete);
## !! use 2024 VRI to match that of the CEF Forest Disturbance Layer
get_vri <- function(studyArea, rasterToMatch) {
  with_retries(function() {
    bcdata::bcdc_query_geodata("2ebb35d8-c82f-4a17-9c96-612ac3532d55") |>
      dplyr::filter(INTERSECTS(studyArea)) |>
      dplyr::select(PROJ_AGE_1, SPECIES_CD_1) |>
      dplyr::collect()
  }) |>
    sf::st_set_agr("constant") |>
    sf::st_crop(studyArea) |>
    sf::st_transform(terra::crs(rasterToMatch))
}

## Leading Group for the Cariboo Region
## <https://catalogue.data.gov.bc.ca/dataset/leading-group-for-the-cariboo-region>
##
## IDF - Fir Group: includes all forest polygons in NDT 4 (IDF and BG biogeoclimatic zones)
## that meet any of the following criteria:
## a) Douglas-fir (Fd or Fdi) leading or ponderosa pine leading;
## b) Lodgepole pine leading, and Douglas-fir (Fd or Fdi) or
##    ponderosa pine greater than 15% in any inventory layer;
## c) Trembling aspen leading, and Douglas-fir (Fd or Fdi) or
##    ponderosa pine greater than 15% in any inventory layer,
##    and spruce, red-cedar, cottonwood and birch less than 6% in any inventory layer;
## d) No species information in inventory data (usually NSR stands),
##    and inventory type group for pre-harvest stand or the current
##    stand = 1, 2, 3, 4, 5, 6, 7, 8, 29, or 32.
##    These inventory type groups correspond to the following species compositions:
##    F, FC, FCy, FH, FS, FPl, Fpy, FL, FDEcid, PlF and Py.
##    If inventory type group=0 and pre-harvest inventory type is not available,
##    classify the polygon as Pine Group.
##
## IDF-Pl Group: includes all forest polygons in NDT 4 (IDF and BG biogeoclimatic zones)
## that do not meet the above definition for IDF-Fir Group.
get_leading_group_cariboo <- function(studyArea, rasterToMatch) {
  with_retries(function() bcdata::bcdc_get_data("0ec65e81-cbd5-4b10-90b8-3ec779fc9c0f")) |>
    dplyr::select(LEADING_GRP) |>
    sf::st_set_agr("constant") |>
    sf::st_crop(studyArea) |>
    sf::st_transform(terra::crs(rasterToMatch))
}

## VRI overlaid with NDT-BEC and the Cariboo leading group.
##
## An overlay, not a join: VRI polygons are split at the NDT-BEC boundaries so each piece carries
## exactly one NDT-BEC (and therefore one set of seral-stage age thresholds). The leading-group
## layer does not cover the whole study area, so it is unioned rather than intersected -- the
## overlay equivalent of a left join.
create_vri_becndt <- function(VRI, BECNDT, LGC, tile = NULL) {
  ## Clip to the tile, guarding the empty case: `terra::crop()` drops attribute columns when the
  ## result is empty, whereas `[` keeps them.
  clip <- function(x) {
    v <- tidyterra::as_spatvector(x)

    if (is.null(tile)) {
      return(v)
    }

    aoi <- tidyterra::as_spatvector(tile)

    if (!any(terra::is.related(v, aoi, "intersects"))) {
      return(v[integer(0), ])
    }

    terra::crop(v, aoi) |> spatialutils::repair_geoms()
  }

  vri <- clip(VRI)
  bec <- clip(BECNDT) |> dplyr::select(NDT_BEC, BEC_ZONE)
  lgc <- clip(LGC) |> dplyr::select(LEADING_GRP)

  ## inner: drop VRI outside the BEC coverage, as the previous `left = FALSE` join did
  if (nrow(vri) == 0L || nrow(bec) == 0L) {
    return(spatialutils::drop_values(vri[integer(0), ]))
  }

  v <- spatialutils::intersect_relate(vri, bec) |> spatialutils::repair_geoms()

  if (nrow(v) == 0L) {
    return(v)
  }

  ## left: keep everything from `v`, tagging leading group where it is available.
  ##
  ## `terra::union()` also brings in the parts of `lgc` that `v` does not cover; those come back
  ## with every `v` attribute `NA`. Filtering on `NDT_BEC` drops exactly those and nothing else --
  ## `create_bec_ndt()` builds it with `paste0()`, so it is never genuinely missing in the
  ## BEC-derived parts.
  ##
  ## An `is.related(v, vri, "intersects")` filter is NOT equivalent: touching counts as
  ## intersecting, so it keeps any leading-group-only polygon that merely shares a boundary with the
  ## VRI coverage. Those polygons then pick up a fabricated `NDT_BEC` from the `case_when()` below
  ## (via `LEADING_GRP`), which makes them look like real, classified forest.
  if (nrow(lgc) > 0L) {
    v <- terra::union(v, lgc) |>
      spatialutils::repair_geoms() |>
      dplyr::filter(!is.na(NDT_BEC))
  } else {
    v$LEADING_GRP <- NA_character_
  }

  v |>
    dplyr::mutate(
      NDT_BEC = dplyr::case_when(
        LEADING_GRP == "FirGroup" ~ "NDT4-IDF-FD",
        LEADING_GRP == "PineGroup" ~ "NDT4-IDF-PL",
        grepl("^NDT4", NDT_BEC) ~ "NDT4-IDF-FD",
        .default = NDT_BEC
      )
    )
}

## anthropogenic disturbance features
get_railways <- function(studyArea, rasterToMatch) {
  get_bcdata(
    id = "4ff93cda-9f58-4055-a372-98c22d04a9f8",
    select_cols = c("TRACK_NAME"),
    studyArea = studyArea,
    rasterToMatch = rasterToMatch
  )
}

## Consolidated Roads for the Cariboo layer has been handled separately
## (No Web Feature Service resource available for this data set; different CRS);
## <https://catalogue.data.gov.bc.ca/dataset/cariboo-consolidated-roads>
get_roads <- function(studyAreaLCC, rasterToMatch) {
  with_retries(function() bcdata::bcdc_get_data("ef431656-44d2-4a16-9e0e-a14d934bb281")) |>
    dplyr::select(TRANSPORT_LINE_TYPE_CODE, TRANSPORT_LINE_TENURE_TYPE_CODE) |>
    sf::st_set_agr("constant") |>
    sf::st_transform(terra::crs(rasterToMatch)) |>
    sf::st_crop(studyAreaLCC)
}

create_roads_railways <- function(roads, railways) {
  railways <- railways |>
    ## reset geometry col name to ensure it's consistent
    sf::st_set_geometry("geom") |>
    dplyr::mutate(Resistance = 750, Buffer = 50, SourceWt = 0)

  ## Filter out roads that do not exist or are being planned
  roads <- roads |>
    ## reset geometry col name to ensure it's consistent
    sf::st_set_geometry("geom") |>
    dplyr::filter(!TRANSPORT_LINE_TYPE_CODE %in% c("PRP", "X"))

  ## Filter out higher use ftaFSR roads from other resource roads and assign
  ## them a higher resistance and lower source weight
  roads_res_high <- roads |>
    dplyr::filter(TRANSPORT_LINE_TYPE_CODE == "RES", TRANSPORT_LINE_TENURE_TYPE_CODE == "ftaFSR") |>
    dplyr::mutate(Resistance = 750, Buffer = 50, SourceWt = 0)

  roads_res_low <- roads |>
    dplyr::filter(
      TRANSPORT_LINE_TYPE_CODE == "RES",
      TRANSPORT_LINE_TENURE_TYPE_CODE != "ftaFSR"
    ) |>
    dplyr::mutate(Resistance = 500, Buffer = 25, SourceWt = 0.5)

  ## Assign other roads "high", "medium", and "low" use resistances and source
  ## weight values; create Resistance, SourceWt, and Buffer Columns for the layers
  road_lookup <- data.frame(
    TRANSPORT_LINE_TYPE_CODE = c("HWY", "AC", "LOC", "REC", "DRV", "TRL", "TRS", "OTH", "UNK"),
    Resistance = c(1000, 1000, 750, 750, 750, 500, 500, 500, 500),
    Buffer = c(250, 250, 50, 50, 50, 25, 25, 25, 25),
    SourceWt = c(0, 0, 0, 0, 0, 0.5, 0.5, 0.5, 0.5)
  )

  roads_other <- roads |>
    dplyr::filter(TRANSPORT_LINE_TYPE_CODE %in% road_lookup$TRANSPORT_LINE_TYPE_CODE) |>
    dplyr::left_join(road_lookup, by = "TRANSPORT_LINE_TYPE_CODE")

  ## Combine and buffer all of the roads together;
  ## buffer the roads based on their assigned buffer value
  dplyr::bind_rows(roads_res_high, roads_res_low, roads_other, railways) |>
    dplyr::rowwise() |>
    dplyr::mutate(geom = sf::st_buffer(geom, dist = Buffer)) |>
    dplyr::ungroup() |>
    sf::st_as_sf()
}

# Human Disturbance ---------------------------------------------------------------------------

## TODO: currently not used for connectivity analyses

## The Cumulative Effects Framework Human Disturbance layer has been downloaded directly from the
## BCdata catalogue due to large file size and long processing time
## <https://catalogue.data.gov.bc.ca/dataset/bc-cumulative-effects-framework-human-disturbance-current>
get_human_disturbance <- function(studyArea, rasterToMatch) {
  cef_hd_url <- "https://coms.api.gov.bc.ca/api/v1/object/ecea4b04-055a-49d1-8910-60d726d2d1bf"
  cef_hd_zip <- file.path(get_path("download"), "BC_CEF_Human_Disturbance_2023.zip")
  cef_hd_gdb <- file.path(
    get_path("download"),
    "BC_CEF_Human_Disturbance_2023",
    "BC_CEF_Human_Disturbance_2023.gdb"
  )

  if (!file.exists(cef_hd_zip)) {
    withr::with_options(list(timeout = 300), {
      download.file(cef_hd_url, destfile = cef_hd_zip)
    })
  }

  if (!file.exists(cef_hd_gdb)) {
    archive::archive_extract(cef_hd_zip, dir = get_path("download"))
  }

  studyArea_bbox <- create_bbox(studyArea)

  sf::st_read(
    dsn = cef_hd_gdb,
    layer = "BC_CEF_Human_Disturb_BTM_2023",
    wkt_filter = sf::st_as_text(sf::st_as_sfc(studyArea_bbox))
  ) |>
    sf::st_cast("MULTIPOLYGON", warn = FALSE) |>
    sf::st_make_valid() |>
    sf::st_set_agr("constant") |>
    sf::st_crop(studyArea) |>
    dplyr::select(CEF_DISTURB_GROUP, CEF_DISTURB_SUB_GROUP, CEF_HUMAN_DISTURB_FLAG) |>
    sf::st_transform(terra::crs(rasterToMatch))
}

# Forest Disturbance --------------------------------------------------------------------------

## Forest disturbance data must be downloaded manually as it is not available
## through the bcdata package (CEF Custom Product) and is not publicly distributed.
## See the 'Data access' section of the README for how to request it.

get_forest_disturbance <- function(studyArea, rasterToMatch) {
  for_dist_gdb <- file.path(get_path("download"), "BC_CEF_Forest_Disturbance_2024.gdb")
  if (!file.exists(for_dist_gdb)) {
    stop(glue::glue(
      "Required input `{basename(for_dist_gdb)}` not found at:\n  {for_dist_gdb}\n\n",
      "This is a BC Cumulative Effects Framework Custom Product; it is not publicly ",
      "distributed and cannot be downloaded automatically.\n",
      "To request access, contact Travis Heckford <Travis.Heckford@gov.bc.ca>.\n",
      "See the 'Data access' section of the README for details."
    ))
  }

  studyArea_bbox <- create_bbox(studyArea)

  sf::st_read(
    dsn = for_dist_gdb,
    layer = "BC_CEF_ForestDisturbance_2024",
    wkt_filter = sf::st_as_text(sf::st_as_sfc(studyArea_bbox))
  ) |>
    sf::st_make_valid() |>
    sf::st_set_agr("constant") |>
    sf::st_crop(studyArea) |>
    dplyr::mutate(fid = NULL) |> ## fid will be recreated to be unique etc. during save
    sf::st_transform(terra::crs(rasterToMatch))
}

## Forest disturbance overlaid with VRI-NDT-BEC, then classified into seral stages.
##
## This is an overlay (arcpy `Intersect`), not a spatial join. `sf::st_join()` -- used here until
## 2026-08-25 -- keeps the *whole* forest-disturbance geometry and emits one copy per VRI polygon it
## touches, so a stand spanning several NDT-BEC zones came back several times at full extent, each
## copy assigned a different set of seral-stage age thresholds. Measured on this study area, that
## inflated the layer from 4.02 M polygons / 4.09 Mha to 7.78 M polygons / 39.5 Mha, and left
## ~165,000 ha (6% of the landscape) belonging to two or more seral stages at once, resolved
## arbitrarily by whichever union happened to run first downstream.
create_forest_disturbance_seral <- function(for_dist_gpkg, vri_gpkg, tile, max_age) {
  aoi <- tidyterra::as_spatvector(tile)

  ## Push the spatial filter down to the GDAL read: only the features overlapping this tile are
  ## ever materialised, so a worker never holds the whole 4 M-polygon layer.
  ##
  ## `NDT_BEC` is the only VRI attribute the seral classification needs; the rest are carried
  ## because `forest_disturbance_seral.gpkg` is a deliverable in its own right and they are what
  ## make it interpretable. The source-system artifacts (`id`, `FEATURE_ID`, `OBJECTID`) are
  ## deliberately not carried, and `NATURAL_DISTURBANCE`/`ZONE` are recoverable from `NDT_BEC`.
  fd <- spatialutils::read_vector_aoi(for_dist_gpkg, aoi, fields = "SIFA")
  vri <- spatialutils::read_vector_aoi(
    vri_gpkg,
    aoi,
    fields = c("NDT_BEC", "BEC_ZONE", "SPECIES_CD_1", "PROJ_AGE_1", "LEADING_GRP")
  )

  if (nrow(fd) == 0L || nrow(vri) == 0L) {
    return(fd[integer(0)])
  }

  ## clip to the tile so tiles partition the study area rather than overlapping at their edges
  fd <- terra::crop(fd, aoi) |> spatialutils::repair_geoms()

  v <- spatialutils::intersect_relate(fd, vri) |> spatialutils::repair_geoms()

  if (nrow(v) == 0L) {
    return(v)
  }

  ## seral stage is a lookup on (NDT_BEC, SIFA); the age classes partition [0, max_age] within each
  ## NDT-BEC, so exactly one row can match -- `relationship` makes that an error rather than a
  ## silent row duplication if the table ever gains overlapping ranges.
  seral <- as.data.frame(v) |>
    dplyr::left_join(
      seral_stages_long(max_age),
      by = dplyr::join_by(NDT_BEC, dplyr::between(SIFA, Age_Min, Age_Max, bounds = "[)")),
      relationship = "many-to-one"
    )

  v |>
    dplyr::mutate(
      Seral = !!seral$Seral,
      early_less_20yrs = dplyr::if_else(SIFA < 20, "under_20", NA_character_)
    )
}

## Largest projected stand age in the layer; sets the upper bound of the oldest seral class.
##
## Asks GDAL for the aggregate rather than reading the layer: `SELECT MAX(SIFA)` returns one row and
## no geometry, so this is constant-memory over a 4 M-polygon layer. A `terra` proxy would be the
## obvious route but cannot open a layer whose geometry type is "Unknown (any)" -- which is what
## `sf::st_write()` produces for mixed POLYGON/MULTIPOLYGON, i.e. every GeoPackage this pipeline
## writes.
max_stand_age <- function(for_dist_gpkg) {
  layer <- sf::st_layers(for_dist_gpkg)$name[[1]]

  sf::st_read(
    for_dist_gpkg,
    query = glue::glue('SELECT MAX(SIFA) AS max_sifa FROM "{layer}"'),
    quiet = TRUE
  )$max_sifa
}

## per the CEF Biodiversity Protocol (§3.2.2):
##   Unique patches are formed if similarly-aged forest polygons are separated >100m,
##   such that small residual patches <1ha in size and 'peninsulas' or corridors
##   (e.g. riparian corridors) of different aged forest <100m wide within a larger
##   similarly aged forest patch are included as part of that singular patch.

## NOTE: naming conventions for patch creation functions resemble those of the BC arcpy scripts;
## see the README appendix for the step-by-step description they are ported from.
##
## The patch chain works on `terra` SpatVectors rather than `sf`. terra's overlay operators are
## GEOS-backed and vectorised in C++, and -- crucially -- `terra::union()` implements arcpy's
## `Union_analysis` semantics exactly: geometries are split at the overlay boundaries and *both*
## attribute sets are carried through, `NA` where a layer does not cover. The `sf` port this
## replaces (`st_union_analysis()`) instead kept only `x`'s attributes on every intersection and
## then dissolved on `Seral`, which silently relabelled interior old forest as `Mature`.

## Area, sliver elimination, and dissolving on attributes that contain `NA` are all places where
## the obvious `terra` call does something subtly different from what the arcpy scripts do; they
## live in `spatialutils` so the reasoning is documented and tested in one place:
##
## * `expanse_planar()` -- planar area in the layer's own projection, as `sf::st_area()` and ArcGIS
##   `Shape_Area` report it. `terra::expanse()` defaults to geodesic area, 2.69% larger in this
##   study area's Lambert projection (3,010,405 ha vs 2,931,558 ha for the seral layer), which would
##   silently move every 1 ha threshold and inflate every reported total.
## * `dissolve_by()` -- `terra::aggregate(by = )` cannot dissolve on several columns when any of
##   them contains `NA`; it returns a SpatVector whose attribute table has fewer rows than it has
##   geometries. Both `Seral` and `early_less_20yrs` have `NA` values.
## * `drop_values()` -- there is no `v[, character(0)]` for SpatVectors.
## * `nn_distance()` -- indexed nearest-neighbour search; see `calc_nn_dists()`.

## dissolve on one or more attributes, then explode back to single-part polygons
dissolve_by <- function(v, by) {
  spatialutils::dissolve_by(tidyterra::as_spatvector(v), by, explode = TRUE)
}

## step 1: dissolve the seral layer on seral stage + the <20 yr early split
patches_get_input_data <- function(for_dist_seral) {
  tidyterra::as_spatvector(for_dist_seral) |>
    spatialutils::repair_geoms() |>
    dissolve_by(c("Seral", "early_less_20yrs"))
}

## step 3: edge-influence buffers, one per neighbouring seral stage.
##
## Each buffer distance belongs to a *specific* stand type -- it is the distance that stand type's
## edge influence reaches into an adjacent patch -- which is why which buffers get erased depends on
## which patch is being measured (see patches_create_erase_mask()).
patches_buffer_sizes <- function() {
  ## nominal size -> (buffer actually applied, seral stage whose edge influence it represents)
  list(
    `200` = list(dist = 200, seral = "Early", under_20 = TRUE),
    `100` = list(dist = 101, seral = "Early", under_20 = FALSE),
    `50` = list(dist = 52, seral = "Mid", under_20 = NA),
    `25` = list(dist = 25, seral = "Mature", under_20 = NA)
  )
}

patches_create_buffers_to_delete <- function(seral, buffer_size) {
  spec <- patches_buffer_sizes()[[as.character(buffer_size)]]

  if (is.null(spec)) {
    stop("`buffer_size` must be one of 200, 100, 50, or 25")
  }

  ## `Seral == spec$seral` also drops the unclassified (NA) stands, as intended
  subset <- tidyterra::as_spatvector(seral) |>
    dplyr::filter(Seral == !!spec$seral)

  if (!is.na(spec$under_20)) {
    subset <- if (isTRUE(spec$under_20)) {
      dplyr::filter(subset, !is.na(early_less_20yrs) & early_less_20yrs == "under_20")
    } else {
      dplyr::filter(subset, is.na(early_less_20yrs) | early_less_20yrs != "under_20")
    }
  }

  if (nrow(subset) == 0L) {
    return(subset)
  }

  ## dissolve, then keep only patches larger than 1 ha before buffering (arcpy step 3c)
  dissolved <- dissolve_by(dplyr::select(subset, Seral), "Seral")
  dissolved <- dissolved[spatialutils::expanse_planar(dissolved, "ha") > 1, ]

  terra::buffer(dissolved, width = spec$dist) |> spatialutils::repair_geoms()
}

## step 4: the area to erase from a given interior-forest target.
##
## Erasing four buffers one after another is the same as erasing their union (A \ B1 \ B2 = A \
## (B1 u B2)), so they are combined once here instead of being differenced four times.
##
## WHICH buffers apply depends on the target. The 25 m buffer is the edge influence of *Mature*
## stands: for the old-only target a mature stand is an adjacent younger neighbour, so it is erased;
## for the mature+old target mature stands are part of the patch itself, so erasing it would remove
## every mature stand plus a 25 m margin and leave exactly the old-only interior forest behind.
## Erasing all four from both targets is what this pipeline did until 2026-08-25, which made
## `patches_interior_forest_mature_old` numerically identical to `patches_interior_forest_old`
## (measured: both 326,081.5 ha over 13,783 polygons).
##
## This matches the arcpy scripts, which erase 200/100/50/25 m from OLD (README steps 4a-d) but
## only 200/100/50 m from MATURE_OLD (steps 4e-h).
patches_create_erase_mask <- function(
  patches_buffer_200,
  patches_buffer_100,
  patches_buffer_50,
  patches_buffer_25,
  age_class
) {
  age_class <- match.arg(age_class, c("Old", "Mature"))

  buffers <- list(patches_buffer_200, patches_buffer_100, patches_buffer_50)

  ## "Mature" here labels the mature+old target, whose patches already contain the mature stands
  ## that the 25 m buffer represents.
  if (identical(age_class, "Old")) {
    buffers <- c(buffers, list(patches_buffer_25))
  }

  ## geometry only; attributes are irrelevant to an erase
  buffers <- lapply(buffers, function(b) spatialutils::drop_values(tidyterra::as_spatvector(b)))

  do.call(rbind, buffers) |>
    terra::aggregate() |>
    spatialutils::repair_geoms()
}

## step 2: the OLD / MATURE_OLD feature classes.
##
## Slivers smaller than 1 ha that are *not* part of the target class are merged into the
## neighbouring polygon they share the longest border with (arcpy `Eliminate`, LENGTH option), then
## everything outside the target class is dropped (arcpy steps 2d and 2h).
##
## Dropping the non-target class is what this pipeline omitted until 2026-08-25. The leftover
## "other" polygons -- 2.47 Mha of dissolved Early/Mid/unclassified land for the old-only target --
## were carried into the erase, and since none of the four edge-influence buffers cover
## unclassified (NA seral) land, that land survived and was relabelled as interior forest:
## 165,527 ha of the 326,036 ha `patches_interior_forest_old` layer (50.8%) was not old forest.
patches_create_old_mature <- function(seral, age_class) {
  use_class <- switch(
    paste0(age_class, collapse = "_"),
    Mature_Old = "MO",
    Old = "O",
    stop("age_class must be one of `c('Mature', 'Old')` or `'Old'`")
  )

  ## `%in%` yields FALSE (never NA) for unclassified stands, so they fall into "other"
  p <- tidyterra::as_spatvector(seral) |>
    dplyr::mutate(INTERIOR_CATEGORY = dplyr::if_else(Seral %in% age_class, use_class, "other")) |>
    dplyr::select(INTERIOR_CATEGORY) |>
    dissolve_by("INTERIOR_CATEGORY")

  if (!any(p$INTERIOR_CATEGORY == use_class)) {
    stop("no polygons of class `", use_class, "` found; check the seral stage classification")
  }

  ## `keep` protects the target class from being treated as a sliver, so only "other" polygons
  ## below 1 ha are eliminated -- as in arcpy steps 2c/2g.
  merged <- spatialutils::eliminate_slivers(
    p,
    threshold = units::set_units(1, "ha"),
    keep = INTERIOR_CATEGORY == !!use_class,
    explode = FALSE ## `p` is already single-part
  )

  dplyr::filter(merged, INTERIOR_CATEGORY == !!use_class)
}

## step 5: patch sizes (dissolve on seral stage alone)
patches_create_patch_size_data <- function(seral) {
  ## NOTE: it's unnecessary here to further classify patches based on size
  tidyterra::as_spatvector(seral) |>
    dplyr::select(Seral) |>
    dissolve_by("Seral")
}

## step 4 (cont.): interior forest = the target patches with the edge-influence mask erased.
##
## Interior-forest membership is recorded as its own column rather than by overwriting `Seral`.
## Overwriting it is what made old cores come out labelled `Mature` in the final resultant, and
## therefore modelled at Resistance 250 / SourceWt 0.75 instead of 1 / 1.0.
patches_create_interior_forest <- function(patches, erase_mask, age_class) {
  age_class <- match.arg(age_class, c("Old", "Mature"))

  flag <- switch(age_class, Old = "old_interior", Mature = "matold_interior")

  interior <- terra::erase(
    tidyterra::as_spatvector(patches),
    tidyterra::as_spatvector(erase_mask)
  ) |>
    spatialutils::repair_geoms() |>
    terra::disagg() |>
    spatialutils::drop_values()

  interior[[flag]] <- flag

  dissolve_by(interior, flag)
}

## step 6: the final resultant.
##
## arcpy `Union` of the seral layer with both interior-forest layers: geometries are split at every
## boundary and all three attribute sets travel through, so a polygon knows its seral stage *and*
## whether it is old interior and/or mature+old interior.
##
## The former three-step `st_union_analysis()` chain is gone. Besides clobbering attributes, its
## third step (`patches_union_final_3`) unioned the resultant with the seral layer dissolved on
## `Seral` -- the same layer step 2 had already unioned in -- and cost 33.5 h to change 12 polygons
## out of 162,905 and zero area.
patches_union_into_final_resultant <- function(
  patch_size,
  interior_forest_old,
  interior_forest_mature_old
) {
  base <- tidyterra::as_spatvector(patch_size) |>
    dplyr::filter(!is.na(Seral))

  terra::union(base, tidyterra::as_spatvector(interior_forest_mature_old)) |>
    spatialutils::repair_geoms() |>
    terra::union(tidyterra::as_spatvector(interior_forest_old)) |>
    spatialutils::repair_geoms()
}

define_forest_seral_patch_conn_vals <- function(for_dist_seral_agg) {
  ## add resistance and sourcewt based on aggregated patches
  tidyterra::as_spatvector(for_dist_seral_agg) |>
    dplyr::mutate(
      Resistance = dplyr::case_when(
        is.na(Seral) ~ 1000,
        Seral == "Early" ~ 750,
        Seral == "Mid" ~ 500,
        Seral == "Mature" ~ 250,
        Seral == "Old" ~ 1,
        .default = 1000
      ),
      SourceWt = dplyr::case_when(
        is.na(Seral) ~ 0,
        Seral == "Early" ~ 0.25,
        Seral == "Mid" ~ 0.5,
        Seral == "Mature" ~ 0.75,
        Seral == "Old" ~ 1,
        .default = 0
      )
    )
}

## Sentinel for unclassified stands while they pass through the raster, which has no way to
## represent "covered by a polygon, but with no seral class". Not a value `Seral` ever takes.
SERAL_UNCLASSIFIED <- "<unclassified>"

## Rasterise the seral layer for display.
##
## The layer is millions of polygons, and `geom_sf()` strokes every one of them individually:
## measured at 1h 18m for a figure whose pixels cannot resolve them anyway. At 16 in and 300 dpi
## across two facet columns, one pixel of the PNG is ~85 m on the ground, so a 100 m grid is already
## at the limit of what the image can show. `res` is in map units (metres, in this project's
## Lambert CRS).
seral_display_raster <- function(for_dist_seral, res = 100) {
  v <- tidyterra::as_spatvector(for_dist_seral)
  template <- terra::rast(terra::ext(v), resolution = res, crs = terra::crs(v))

  ## `Seral` is NA for unclassified stands, and a rasterised NA is indistinguishable from a cell no
  ## polygon covers at all -- which drops the unclassified panel the `geom_sf()` version drew (a
  ## quarter of a million hectares of it). Carry them through as an explicit level and turn it back
  ## into a real NA once the cells are in a data frame.
  v$.display <- dplyr::coalesce(as.character(v$Seral), SERAL_UNCLASSIFIED)

  terra::rasterize(v, template, field = ".display")
}

plot_forest_disturbance_seral <- function(
  for_dist_seral,
  studyArea,
  dst,
  res = 100,
  outdir = get_path("figures")
) {
  dst <- file.path(outdir, dst)

  r <- seral_display_raster(for_dist_seral, res = res)

  ## `geom_tile()` takes bare numbers, so -- unlike the `geom_sf()` layer below -- `coord_sf()`
  ## cannot reproject them: it just reads them in whatever CRS the panel ends up in. The study area
  ## is in BC Albers and the seral layer in Canada Atlas Lambert, so leaving it to `coord_sf()`
  ## silently plots the raster thousands of km from the outline. Project the outline to the
  ## raster's CRS instead, so the panel CRS and the tile coordinates are the same thing.
  sa <- tidyterra::as_spatvector(studyArea) |>
    terra::project(terra::crs(r)) |>
    sf::st_as_sf()

  d <- terra::as.data.frame(r, xy = TRUE, na.rm = TRUE)
  names(d)[3] <- "Seral"
  d$Seral <- as.character(d$Seral)
  d$Seral[d$Seral == SERAL_UNCLASSIFIED] <- NA_character_
  ## `rasterize()` returns the classes as a factor in its own level order; sort them so the facets
  ## and the legend come out in the same order as the character column they were plotted from.
  ## Unclassified stands stay NA, so they get their own facet and the grey NA fill, as before.
  d$Seral <- factor(d$Seral, levels = sort(unique(stats::na.omit(d$Seral))))

  gg_for_dist_seral <- ggplot2::ggplot(d) +
    ggplot2::geom_tile(ggplot2::aes(x = .data$x, y = .data$y, fill = .data$Seral)) +
    ggplot2::facet_wrap(ggplot2::vars(.data$Seral), ncol = 2) +
    ggplot2::geom_sf(data = sa, color = "black", fill = NA, inherit.aes = FALSE) +
    ggplot2::theme_bw() +
    ggspatial::annotation_north_arrow(
      location = "bl",
      which_north = "true",
      pad_x = ggplot2::unit(0.25, "in"),
      pad_y = ggplot2::unit(0.25, "in"),
      style = ggspatial::north_arrow_fancy_orienteering
    ) +
    ggplot2::xlab("Longitude") +
    ggplot2::ylab("Latitude") +
    ggplot2::ggtitle("Quesnel NRD Seral Stages")

  ggplot2::ggsave(dst, gg_for_dist_seral, width = 16, height = 16)

  return(dst)
}
