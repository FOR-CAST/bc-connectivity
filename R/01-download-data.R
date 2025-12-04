# Quesnel NRD Boundary ------------------------------------------------------------------------

## NOTE: bcmaps::nr_districts() provides a version suitable for web mapping applications,
## but that version is simplified; use the manually downloaded file for analyses
## <https://catalogue.data.gov.bc.ca/dataset/0bc73892-e41f-41d0-8d8e-828c16139337/resource/2d9d0a5c-bdf7-47e8-9038-103a93e6205a>

f_quesnel_nrd <- file.path(
  download_dir,
  "BCGW_02001F02_1764364089473_6756",
  "ADM_NR_DISTRICTS_SP",
  "ADM_NR_DST_polygon.shp"
)

if (file.exists(f_quesnel_nrd)) {
  Quesnel_TSA <- sf::st_read(f_quesnel_nrd) |>
    filter(DSTRCT_NM == "Quesnel Natural Resource District") |>
    select(DSTRCT_NM) |>
    rename(DIST_NAME = DSTRCT_NM)
} else {
  Quesnel_TSA <- bcmaps::nr_districts() |>
    filter(DISTRICT_NAME == "Quesnel Natural Resource District") |>
    select(DISTRICT_NAME) |>
    rename(DIST_NAME = DISTRICT_NAME)
}

sf::st_write(Quesnel_TSA, input_files[["study_area"]], append = FALSE)

rm(f_quesnel_nrd)

## Create a bounding box of the buffer to reduce processing time of large vector datasets
Quesnel_TSA_bbox <- sf::st_bbox(Quesnel_TSA)

# Landcover -----------------------------------------------------------------------------------

## load in the 2020 Canada Landcover Classification layer (30m) to be used as a base raster
## for rasterizing feature shapefiles
## <https://open.canada.ca/data/en/dataset/ee1580ab-a23d-4f86-a09b-79763677eb47/resource/f1ba2faa-ff10-4526-815a-c57b99eef1bb>

lcc_url <- "https://datacube-prod-data-public.s3.ca-central-1.amazonaws.com/store/land/landcover/landcover-2020-classification.tif"
lcc_tif <- file.path(download_dir, basename(lcc_url))

if (!file.exists(lcc_tif)) {
  withr::with_options(list(timeout = 300), {
    download.file(lcc_url, destfile = lcc_tif)
  })
}

## Load the land cover raster and re-project Quesnel buffer to match its projection
landcover <- terra::rast(lcc_tif)
Quesnel_TSA_LCC <- sf::st_transform(Quesnel_TSA, crs = terra::crs(landcover))

## Crop and mask to study area
landcover_quesnel <- terra::crop(landcover, Quesnel_TSA_LCC, mask = TRUE) |>
  terra::writeRaster(input_files[["LCC"]], datatype = "INT1U", overwrite = TRUE)

rm(lcc_url, lcc_tif, landcover)

# Digital Elevation Model (DEM) ---------------------------------------------------------------

local({
  dem <- bcmaps::cded_terra(
    aoi = Quesnel_TSA,
    dest_vrt = file.path(download_dir, "Quesnel_TSA_DEM.vrt")
  )
  Quesnel_TSA_DEM <- sf::st_transform(Quesnel_TSA, crs = terra::crs(dem))

  ## Crop and mask to study area
  terra::crop(dem, Quesnel_TSA_DEM, mask = TRUE) |>
    terra::writeRaster(input_files[["dem"]], overwrite = TRUE)
})

# bcdata layers -------------------------------------------------------------------------------

local({
  list(
    ## planning area boundaries
    LU = list(
      id = "11277e35-d8be-47e4-bb1f-c38e393179c6",
      select_cols = c("FEATURE_AREA_SQM", "LANDSCAPE_UNIT_NAME"),
      out = input_files[["LU"]]
    ),

    ## environmental features
    BEC = list(
      id = "f358a53b-ffde-4830-a325-a5a03ff672c3",
      select_cols = c("BGC_LABEL", "ZONE", "SUBZONE", "VARIANT", "NATURAL_DISTURBANCE"),
      out = input_files[["BEC"]]
    ),

    ## biodiversity features
    OGMA = list(
      id = "1b30f3bd-0ad0-4128-916b-66c6dd91dea4",
      select_cols = c(
        "OGMA_TYPE",
        "LEGAL_OGMA_PROVID",
        "FEATURE_AREA_SQM",
        "FEATURE_LENGTH_M",
        "OBJECTID"
      ),
      out = input_files[["OGMA"]]
    ),
    parks = list(
      id = "1130248f-f1a3-4956-8b2e-38d29d3e4af7",
      select_cols = c("PARK_CLASS", "PROTECTED_LANDS_DESIGNATION", "FEATURE_AREA_SQM"),
      out = input_files[["parks"]]
    ),

    MDWR = list(
      id = "a60d7b6e-88b2-4105-95e2-aaf6cc3468cf",
      select_cols = c("TIMBER_HARVEST_OPP_CODE"),
      out = input_files[["MDWR"]]
    ),
    WHA = list(
      id = "b19ff409-ef71-4476-924e-b3bcf26a0127",
      select_cols = c("COMMON_SPECIES_NAME", "TIMBER_HARVEST_CODE", "FEATURE_AREA_SQM"),
      out = input_files[["WHA"]]
    ),

    ## freshwater atlas layers
    lakes = list(
      id = "cb1e3aba-d3fe-4de1-a2d4-b8b6650fb1f6",
      select_cols = c("WATERBODY_KEY", "AREA_HA"),
      out = input_files[["lakes"]]
    ),
    rivers = list(
      id = "f7dac054-efbf-402f-ab62-6fc4b32a619e",
      select_cols = c("GNIS_NAME_1"),
      out = input_files[["rivers"]]
    ),
    wetlands = list(
      id = "93b413d8-1840-4770-9629-641d74bd1cc6",
      select_cols = c("WATERBODY_KEY"),
      out = input_files[["wetlands"]]
    ),
    streams = list(
      id = "92344413-8035-4c08-b996-65a9b3f62fca",
      select_cols = "STREAM_ORDER",
      out = input_files[["streams"]]
    ),

    ## anthropogenic disturbance features
    railways = list(
      id = "4ff93cda-9f58-4055-a372-98c22d04a9f8",
      select_cols = c("TRACK_NAME"),
      out = input_files[["railways"]]
    )
  ) |>
    purrr::walk(
      .f = function(d) {
        bcdata::bcdc_query_geodata(d$id) |>
          dplyr::filter(INTERSECTS(Quesnel_TSA)) |>
          dplyr::select(any_of(d$select_cols)) |>
          dplyr::collect() |>
          sf::st_transform(terra::crs(landcover_quesnel)) |>
          sf::st_write(d$out, append = FALSE)
      }
    )
})

## Vegetation Resource Inventory (VRI 2024) needs to be handled separately
## due to limits/issues querying and downloading the data using `bcdata`
## (has 191708 records and requires 20 paginated requests to complete);
## !! use 2024 VRI to match that of the CEF Forest Disturbance Layer
local({
  bcdata::bcdc_query_geodata("2ebb35d8-c82f-4a17-9c96-612ac3532d55") |>
    dplyr::filter(INTERSECTS(Quesnel_TSA)) |> ## intersection works, but not select?
    dplyr::collect() |>
    dplyr::select(PROJ_AGE_1, SPECIES_CD_1) |> ## select after collecting
    sf::st_transform(terra::crs(landcover_quesnel)) |>
    sf::st_write(input_files[["VRI"]], append = FALSE)
})

## High Value Moose Wetlands layer has been handled separately because a
## specific filter has to be applied to the data
local({
  bcdata::bcdc_query_geodata("2c02040c-d7c5-4960-8d04-dea01d6d3e9f") |>
    dplyr::filter(
      STRGC_LAND_RSRCE_PLAN_NAME == "Cariboo Chilcotin Land Use Plan",
      LEGAL_FEAT_OBJECTIVE == "High Value Wetlands for Moose"
    ) |>
    dplyr::select(STRGC_LAND_RSRCE_PLAN_NAME, LEGAL_FEAT_OBJECTIVE) |>
    dplyr::filter(INTERSECTS(Quesnel_TSA)) |>
    dplyr::collect() |>
    sf::st_transform(terra::crs(landcover_quesnel)) |>
    sf::st_write(input_files[["moose_wetlands"]], append = FALSE)
})

## Consolidated Roads for the Cariboo layer has been handled separately
## (No Web Feature Service resource available for this data set; different CRS);
## <https://catalogue.data.gov.bc.ca/dataset/cariboo-consolidated-roads>
local({
  suppressWarnings({
    bcdata::bcdc_get_data("ef431656-44d2-4a16-9e0e-a14d934bb281") |>
      dplyr::select(TRANSPORT_LINE_TYPE_CODE, TRANSPORT_LINE_TENURE_TYPE_CODE) |>
      sf::st_transform(terra::crs(landcover_quesnel)) |>
      sf::st_intersection(Quesnel_TSA_LCC) |>
      sf::st_write(input_files[["roads"]], append = FALSE)
  })
})

# Human Disturbance ---------------------------------------------------------------------------

## The Cumulative Effects Framework Human Disturbance layer has been downloaded directly from the
## BCdata catalogue due to large file size and long processing time
## <https://catalogue.data.gov.bc.ca/dataset/bc-cumulative-effects-framework-human-disturbance-current>
## TODO: currently not used for connectivity analyses
local({
  cef_hd_url <- "https://coms.api.gov.bc.ca/api/v1/object/ecea4b04-055a-49d1-8910-60d726d2d1bf"
  cef_hd_zip <- file.path(download_dir, "BC_CEF_Human_Disturbance_2023.zip")
  cef_hd_gdb <- file.path(
    download_dir,
    "BC_CEF_Human_Disturbance_2023",
    "BC_CEF_Human_Disturbance_2023.gdb"
  )

  if (!file.exists(cef_hd_zip)) {
    withr::with_options(list(timeout = 300), {
      download.file(cef_hd_url, destfile = cef_hd_zip)
    })
  }

  if (!file.exists(cef_hd_gdb)) {
    archive::archive_extract(cef_hd_zip, dir = download_dir)
  }

  landcover <- terra::rast(input_files[["landcover"]])

  suppressWarnings({
    sf::st_read(
      dsn = cef_hd_gdb,
      layer = "BC_CEF_Human_Disturb_BTM_2023",
      wkt_filter = sf::st_as_text(sf::st_as_sfc(Quesnel_TSA_bbox))
    ) |>
      sf::st_cast("MULTIPOLYGON", warn = FALSE) |>
      sf::st_make_valid() |>
      sf::st_intersection(Quesnel_TSA) |>
      dplyr::select(CEF_DISTURB_GROUP, CEF_DISTURB_SUB_GROUP, CEF_HUMAN_DISTURB_FLAG) |>
      sf::st_transform(terra::crs(landcover)) |>
      sf::st_write(input_files[["human_disturbance"]], append = FALSE)
  })
})

# Forest Disturbance --------------------------------------------------------------------------

## Forest disturbance data has been downloaded manually as it is not available
## through the bcdata package (CEF Custom Product)

local({
  for_dist_gdb <- file.path(download_dir, "BC_CEF_Forest_Disturbance_2024.gdb")
  if (!file.exists(for_dist_gdb)) {
    stop(glue::glue("please manually download {basename(for_dist_gdb)} from Teams."))
  }

  landcover <- terra::rast(input_files[["landcover"]])

  suppressWarnings({
    sf::st_read(
      dsn = for_dist_gdb,
      layer = "BC_CEF_ForestDisturbance_2024",
      wkt_filter = sf::st_as_text(sf::st_as_sfc(Quesnel_TSA_bbox))
    ) |>
      sf::st_make_valid() |>
      ## fid will be recreated to be unique etc. during save
      dplyr::mutate(fid = NULL) |>
      sf::st_transform(terra::crs(landcover)) |>
      sf::st_write(input_files[["forest_disturbance"]], append = FALSE)
  })
})

# cleanup -------------------------------------------------------------------------------------

gc()
terra::tmpFiles(remove = TRUE)
