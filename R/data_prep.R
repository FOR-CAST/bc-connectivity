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

  sf::st_write(obj, dst, quiet = TRUE, append = FALSE)

  return(dst)
}

## Create a bounding box of the study area to reduce processing time of large vector datasets
create_bbox <- function(studyArea) {
  sf::st_bbox(studyArea)
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
    Quesnel_TSA <- sf::st_read(file) |>
      filter(DSTRCT_NM == "Quesnel Natural Resource District") |>
      select(DSTRCT_NM) |>
      rename(DIST_NAME = DSTRCT_NM)
  } else {
    Quesnel_TSA <- bcmaps::nr_districts() |>
      filter(DISTRICT_NAME == "Quesnel Natural Resource District") |>
      select(DISTRICT_NAME) |>
      rename(DIST_NAME = DISTRICT_NAME)
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

get_bcdata <- function(id, select_cols, studyArea, rasterToMatch) {
  bcdata::bcdc_query_geodata(id) |>
    dplyr::filter(INTERSECTS(studyArea)) |>
    dplyr::select(any_of(select_cols)) |>
    dplyr::collect() |>
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

  gg_bec_ndt <- ggplot(BECNDT) +
    geom_sf(aes(fill = NDT_BEC)) +
    geom_sf(data = studyArea, color = "black", fill = NA) +
    theme_bw() +
    annotation_north_arrow(
      location = "bl",
      which_north = "true",
      pad_x = unit(0.25, "in"),
      pad_y = unit(0.25, "in"),
      style = north_arrow_fancy_orienteering
    ) +
    xlab("Longitude") +
    ylab("Latitude") +
    ggtitle("Quesnel NRD")

  ggsave(dst, gg_bec_ndt, width = 16, height = 12)

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

## High Value Moose Wetlands layer has been handled differently
## due to limits/issues querying and downloading the data using `bcdata`
get_moose_wetlands <- function(studyArea, rasterToMatch) {
  bcdata::bcdc_query_geodata("2c02040c-d7c5-4960-8d04-dea01d6d3e9f") |>
    dplyr::filter(
      STRGC_LAND_RSRCE_PLAN_NAME == "Cariboo Chilcotin Land Use Plan",
      LEGAL_FEAT_OBJECTIVE == "High Value Wetlands for Moose"
    ) |>
    dplyr::select(STRGC_LAND_RSRCE_PLAN_NAME, LEGAL_FEAT_OBJECTIVE) |>
    dplyr::filter(INTERSECTS(studyArea)) |>
    dplyr::collect() |>
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
  bcdata::bcdc_query_geodata("2ebb35d8-c82f-4a17-9c96-612ac3532d55") |>
    dplyr::filter(INTERSECTS(studyArea)) |>
    dplyr::select(PROJ_AGE_1, SPECIES_CD_1) |>
    dplyr::collect() |>
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
  bcdata::bcdc_get_data("0ec65e81-cbd5-4b10-90b8-3ec779fc9c0f") |>
    dplyr::select(LEADING_GRP) |>
    sf::st_set_agr("constant") |>
    sf::st_crop(studyArea) |>
    sf::st_transform(terra::crs(rasterToMatch))
}

## VRI spatial join with NDT-BEC; this join is slow!
create_vri_becndt <- function(VRI, BECNDT, LGC) {
  sf::st_join(VRI, BECNDT, left = FALSE) |> ## inner join; keeps obs from VRI with matching key in BECNDT
    sf::st_make_valid() |>
    sf::st_join(LGC) |> ## left join; keeps all obs from the prev joined BECNDT/VRI
    sf::st_make_valid() |>
    dplyr::mutate(
      NDT_BEC = dplyr::case_when(
        LEADING_GRP == "FirGroup" ~ "NDT4-IDF-FD",
        LEADING_GRP == "PineGroup" ~ "NDT4-IDF-PL",
        grepl("^NDT4", NDT_BEC) ~ "NDT4-IDF-FD",
        TRUE ~ NDT_BEC
      )
    ) |>
    sf::st_set_geometry("geom")
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
  bcdata::bcdc_get_data("ef431656-44d2-4a16-9e0e-a14d934bb281") |>
    dplyr::select(TRANSPORT_LINE_TYPE_CODE, TRANSPORT_LINE_TENURE_TYPE_CODE) |>
    sf::st_transform(terra::crs(rasterToMatch)) |>
    sf::st_transform(terra::crs(rasterToMatch))
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

## Forest disturbance data has been downloaded manually as it is not available
## through the bcdata package (CEF Custom Product)

get_forest_disturbance <- function(studyArea, rasterToMatch) {
  for_dist_gdb <- file.path(get_path("download"), "BC_CEF_Forest_Disturbance_2024.gdb")
  if (!file.exists(for_dist_gdb)) {
    stop(glue::glue("please manually download {basename(for_dist_gdb)} from Teams."))
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

## Forest Disturbance spatial join with VRI-NDT-BEC and
## assign seral stage classifications based on seral stage table
create_forest_disturbance_seral <- function(for_dist, vri_joined) {
  for_dist |>
    sf::st_set_geometry("geom") |>
    dplyr::select(SIFA) |>
    sf::st_join(vri_joined, left = FALSE) |> ## inner join; keeps obs from for_dist with matching key in vri_joined
    sf::st_make_valid() |>
    dplyr::left_join(
      seral_stages_long(max(for_dist$SIFA, na.rm = TRUE)),
      by = dplyr::join_by(NDT_BEC, dplyr::between(SIFA, Age_Min, Age_Max, bounds = "[)"))
    ) |>
    sf::st_make_valid() |>
    dplyr::mutate(
      Age_Min = NULL,
      Age_Max = NULL,
      early_less_20yrs = dplyr::if_else(SIFA < 20, "under_20", NA_character_)
    ) |>
    sf::st_cast("MULTIPOLYGON", warn = FALSE) |>
    sf::st_cast("POLYGON", warn = FALSE)
}

## per the CEF Biodiversity Protocol (§3.2.2):
##   Unique patches are formed if similarly-aged forest polygons are separated >100m,
##   such that small residual patches <1ha in size and 'peninsulas' or corridors
##   (e.g. riparian corridors) of different aged forest <100m wide within a larger
##   similarly aged forest patch are included as part of that singular patch.

## NOTE: naming conventions for patch creation functions resemble those of the BC arcpy scripts.

patches_get_input_data <- function(for_dist_seral) {
  for_dist_seral |>
    dplyr::group_by(Seral, early_less_20yrs) |>
    dplyr::summarise() |>
    sf::st_cast("POLYGON", warn = FALSE)
}

patches_create_buffers_to_delete <- function(seral, buffer_size) {
  use_buffer <- switch(
    as.character(buffer_size),
    "200" = 200,
    "100" = 101,
    "50" = 52,
    "25" = 25,
    stop("buffer_size must be one of 200, 100, 50, or 25")
  )

  seral_subset <- switch(
    as.character(buffer_size),
    "200" = dplyr::filter(seral, early_less_20yrs == "under_20" & Seral == "Early"),
    "100" = dplyr::filter(
      seral,
      (early_less_20yrs != "under_20" | is.na(early_less_20yrs)) & Seral == "Early"
    ),
    "50" = dplyr::filter(seral, Seral == "Mid"),
    "25" = dplyr::filter(seral, Seral == "Mature")
  )

  seral_subset |>
    dplyr::group_by(Seral) |>
    dplyr::summarise() |>
    sf::st_cast("POLYGON", warn = FALSE) |>
    dplyr::filter(sf::st_area(geom) > units::set_units(1, ha)) |>
    sf::st_buffer(use_buffer)
}

patches_create_old_mature <- function(seral, age_class) {
  use_class <- switch(
    paste0(age_class, collapse = "_"),
    Mature_Old = "MO",
    Old = "O",
    stop("age_class must be one of `c('Mature', 'Old')` or `'Old'`")
  )

  p <- seral |>
    dplyr::mutate(
      INTERIOR_CATEGORY = dplyr::if_else(Seral %in% age_class, use_class, "other")
    ) |>
    dplyr::group_by(INTERIOR_CATEGORY) |>
    dplyr::summarise() |>
    sf::st_cast("POLYGON", warn = FALSE)

  p_slivers <- p |>
    dplyr::filter(
      INTERIOR_CATEGORY != !!use_class & sf::st_area(geom) <= units::set_units(1, ha)
    )
  p_not_slivers <- p |>
    dplyr::filter(
      INTERIOR_CATEGORY == !!use_class | sf::st_area(geom) > units::set_units(1, ha)
    )

  if (nrow(p_not_slivers) < 1) {
    stop("Threshold exceeds the area of every polygon. Please select a smaller number.")
  }

  ## emulate `arcpy.Eliminate_management` using LENGTH, via `terra::combineGeom`
  v_slivers <- terra::vect(p_slivers)
  v_not_slivers <- terra::vect(p_not_slivers)

  v_merged <- terra::combineGeoms(
    v_not_slivers,
    v_slivers,
    overlap = TRUE,
    boundary = TRUE,
    distance = TRUE,
    append = TRUE,
    minover = 0.05,
    maxdist = 1, ## need some small distance to deal with possible topology errors
    dissolve = TRUE,
    erase = TRUE
  )

  p_merged <- sf::st_as_sf(v_merged) |>
    sf::st_set_geometry("geom")

  ## NOTE: it's unnecessary here to further classify patches by area

  return(p_merged)
}

patches_create_patch_size_data <- function(seral) {
  ## NOTE: it's unecessary here to further classify patches based on size
  seral |>
    dplyr::group_by(Seral) |>
    dplyr::summarise() |>
    sf::st_cast("POLYGON", warn = FALSE)
}

## st_erase modified from <https://github.com/r-spatial/sf/issues/346>
st_erase <- function(x, y) {
  x <- sf::st_set_agr(x, "constant")
  y <- sf::st_set_agr(y, "constant")

  sf::st_difference(x, sf::st_union(y)) |>
    sf::st_make_valid()
}

patches_create_interior_forest <- function(
  patches_mature_old,
  patches_buffer_200,
  patches_buffer_100,
  patches_buffer_50,
  patches_buffer_25,
  age_class
) {
  st_erase(patches_mature_old, patches_buffer_200) |>
    st_erase(patches_buffer_100) |>
    st_erase(patches_buffer_50) |>
    st_erase(patches_buffer_25) |>
    dplyr::mutate(
      INTERIOR_CATEGORY = NULL,
      # patch_type = paste(!!age_class, "interior", sep = "_"),
      Seral = !!age_class
    ) |>
    dplyr::group_by(Seral) |>
    dplyr::summarise() |>
    sf::st_cast("POLYGON", warn = FALSE)
}

## copied from FOR-CAST/spatialutils for testing with these large sf objects
st_union_analysis <- function(x, y, union_by = NULL) {
  x <- sf::st_set_geometry(x, "geometry")
  y <- sf::st_set_geometry(y, "geometry")

  i <- sf::st_intersection(x, y) |>
    sf::st_make_valid() |>
    dplyr::select(-dplyr::ends_with(".1")) ## use attribute values from x for intersections

  dx <- sf::st_difference(x, sf::st_union(y))
  dy <- sf::st_difference(y, sf::st_union(x))

  names_diff_x <- setdiff(names(x), names(y))
  names_diff_y <- setdiff(names(y), names(x))

  if (length(names_diff_y) > 0) {
    for (col_name in seq_along(names_diff_y)) {
      dx <- dplyr::mutate(dx, {{ col_name }} := NA_character_, .before = "geometry")
    }
  }

  if (length(names_diff_x) > 0) {
    for (col_name in seq_along(names_diff_x)) {
      dy <- dplyr::mutate(dy, {{ names_diff_x }} := NA_character_, .before = "geometry")
    }
  }

  u <- rbind(i, dx, dy)

  if (is.null(union_by)) {
    u <- u |> dplyr::summarise()
  } else {
    stopifnot(is.character(union_by), length(union_by) == 1)

    u <- u |> dplyr::group_by(.data[[union_by]]) |> dplyr::summarise()
  }

  return(u)
}

patches_union_into_final_resultant <- function(
  interior_forest_mature_old,
  interior_forest_old,
  patch_size,
  for_dist_seral
) {
  interior_forest_mature_old <- interior_forest_mature_old |>
    dplyr::mutate(Seral = "Mature", patch_type = NULL, .before = "geom") |>
    sf::st_set_agr("constant")
  interior_forest_old <- interior_forest_old |>
    dplyr::mutate(Seral = "Old", patch_type = NULL, .before = "geom") |>
    sf::st_set_agr("constant")
  patch_size <- patch_size |>
    sf::st_set_agr("constant")

  ## NOTE: cast multipolygon before cast polygon b/c mix of polygon/multiploygon produced
  for_dist_seral <- sf::st_make_valid(for_dist_seral) |>
    dplyr::group_by(Seral) |>
    dplyr::summarise() |> ## this union is very slow b/c 7.8 million polygons
    sf::st_cast("MULTIPOLYGON", warn = FALSE) |>
    sf::st_cast("POLYGON", warn = FALSE)

  interior_forest_mature_old |>
    st_union_analysis(interior_forest_old) |>
    sf::st_cast("MULTIPOLYGON", warn = FALSE) |>
    sf::st_cast("POLYGON", warn = FALSE) |>
    st_union_analysis(patch_size, by = "Seral") |>
    sf::st_cast("MULTIPOLYGON", warn = FALSE) |>
    sf::st_cast("POLYGON", warn = FALSE) |>
    st_union_analysis(for_dist_seral, by = "Seral") |>
    sf::st_cast("MULTIPOLYGON", warn = FALSE) |>
    sf::st_cast("POLYGON", warn = FALSE)
}

define_forest_seral_patch_conn_vals <- function(for_dist_seral_agg) {
  ## add resistance and sourcewt based on aggregated patches
  for_dist_seral_agg |>
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

plot_forest_disturbance_seral <- function(for_dist_seral, studyArea, dst) {
  dst <- file.path(get_path("figures"), dst)

  gg_for_dist_seral <- ggplot(for_dist_seral) +
    geom_sf(aes(fill = Seral)) +
    facet_wrap(vars(Seral), ncol = 2) +
    geom_sf(data = studyArea, color = "black", fill = NA) +
    theme_bw() +
    annotation_north_arrow(
      location = "bl",
      which_north = "true",
      pad_x = unit(0.25, "in"),
      pad_y = unit(0.25, "in"),
      style = north_arrow_fancy_orienteering
    ) +
    xlab("Longitude") +
    ylab("Latitude") +
    ggtitle("Quesnel NRD Seral Stages")

  ggsave(dst, gg_for_dist_seral, width = 16, height = 16)

  return(dst)
}
