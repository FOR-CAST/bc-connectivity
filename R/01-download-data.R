# Data feature collection for connectivity analyses

# --- Quesnel TSA Boundary Download ---

# Get the boundary and select just the district name
Quesnel_TSA_boundary <- nr_districts()
download_dir
filter(DISTRICT_NAME == "Quesnel Natural Resource District") |>
  select(DISTRICT_NAME) |>
  rename(DIST_NAME = DISTRICT_NAME)

# Write shapefile
st_write(
  Quesnel_TSA_boundary,
  file.path(download_dir, "QuesnelTSA_studyarea.shp"),
  delete_layer = TRUE
)

# --- Digital Elevation Model (DEM) Download ---

# bcmaps' cded() requires WGS8 - reproject buffer to WGS84 for compatibility
quesnel_boundary <- st_transform(Quesnel_TSA_boundary, 4326)
dem_path <- cded(aoi = Quesnel_TSA_boundary)
dem <- raster(dem_path)

# Crop and mask DEM to the buffered NRD boundary and save the raster
dem_crop <- crop(dem, quesnel_boundary)
dem_mask <- mask(dem_crop, quesnel_boundary)
writeRaster(dem_mask, file.path(download_dir, "Quesnel_TSA_DEM.tif"), overwrite = TRUE)

# --- BCData Package Feature Layer Downloads ---

# Define feature datasets that are downloadable through bcdata - define
# feature ID, select relevant columns to keep, and name the shapefile
datasets <- list(
  list(
    id = "1b30f3bd-0ad0-4128-916b-66c6dd91dea4",
    select_cols = c(
      "OGMA_TYPE",
      "LEGAL_OGMA_PROVID",
      "FEATURE_AREA_SQM",
      "FEATURE_LENGTH_M",
      "OBJECTID"
    ),
    out = file.path(download_dir, "OGMAcurrent.shp")
  ),
  list(
    id = "f7dac054-efbf-402f-ab62-6fc4b32a619e",
    select_cols = c("GNIS_NAME_1"),
    out = file.path(download_dir, "Rivers.shp")
  ),
  list(
    id = "93b413d8-1840-4770-9629-641d74bd1cc6",
    select_cols = c("WATERBODY_KEY"),
    out = file.path(download_dir, "Wetlands.shp")
  ),
  list(
    id = "cb1e3aba-d3fe-4de1-a2d4-b8b6650fb1f6",
    select_cols = c("WATERBODY_KEY", "AREA_HA"),
    out = file.path(download_dir, "Lakes.shp")
  ),
  list(
    id = "f358a53b-ffde-4830-a325-a5a03ff672c3",
    select_cols = c("BGC_LABEL", "ZONE", "SUBZONE", "VARIANT", "NATURAL_DISTURBANCE"),
    out = file.path(download_dir, "BEC.shp")
  ),
  list(
    id = "b19ff409-ef71-4476-924e-b3bcf26a0127",
    select_cols = c("COMMON_SPECIES_NAME", "TIMBER_HARVEST_CODE", "FEATURE_AREA_SQM"),
    out = file.path(download_dir, "WHAs.shp")
  ),
  list(
    id = "1130248f-f1a3-4956-8b2e-38d29d3e4af7",
    select_cols = c("PARK_CLASS", "PROTECTED_LANDS_DESIGNATION", "FEATURE_AREA_SQM"),
    out = file.path(download_dir, "BCParks.shp")
  ),
  list(
    id = "4ff93cda-9f58-4055-a372-98c22d04a9f8",
    select_cols = c("TRACK_NAME"),
    out = file.path(download_dir, "Railways.shp")
  ),
  list(
    id = "a60d7b6e-88b2-4105-95e2-aaf6cc3468cf",
    select_cols = c("TIMBER_HARVEST_OPP_CODE"),
    out = file.path(download_dir, "MDWR.shp")
  ),
  list(
    id = "c58a54e5-76b7-4921-94a7-b5998484e697",
    select_cols = c("FIRE_YEAR", "BURN_SEVERITY_RATING"),
    out = file.path(download_dir, "Burn_severity.shp")
  ),
  list(
    id = "11277e35-d8be-47e4-bb1f-c38e393179c6",
    select_cols = c("FEATURE_AREA_SQM", "LANDSCAPE_UNIT_NAME"),
    out = file.path(download_dir, "Landscape_units.shp")
  )
)

# Loop and download feature layers
for (d in datasets) {
  data <- bcdc_query_geodata(d$id) |>
    collect() |> # collect data layer
    st_intersection(Quesnel_TSA_boundary) |> # clip data to study area
    select(any_of(d$select_cols)) # select data fields to keep
  names(data) <- make.unique(substr(names(data), 1, 10)) # shorten field names to 10 characters (required for shapefiles)
  st_write(data, d$out, delete_layer = TRUE) # save layer as a shapefile
}

# The High Value Moose Wetlands layer has been handled separately because a
# specific filter has to be applied to the data
Moose_wetlands <- bcdc_query_geodata("2c02040c-d7c5-4960-8d04-dea01d6d3e9f") |>
  collect() |>
  st_intersection(Quesnel_TSA_boundary) |>
  filter(
    STRGC_LAND_RSRCE_PLAN_NAME == "Cariboo Chilcotin Land Use Plan",
    LEGAL_FEAT_OBJECTIVE == "High Value Wetlands for Moose"
  ) |>
  select(STRGC_LAND_RSRCE_PLAN_NAME, LEGAL_FEAT_OBJECTIVE)
names(Moose_wetlands) <- make.unique(substr(names(Moose_wetlands), 1, 10))
st_write(Moose_wetlands, file.path(inputs_dir, "Moose_wetlands.shp"), delete_layer = TRUE)

# --- Stream Order for the Cariboo Download ---

# The stream order layer for the Cariboo has been handled seperately because it
# was a slow download due to high amount of line features
streamsorder <- st_read(
  file.path(
    download_dir,
    "Stream Network",
    "BCGW_02001F02_1750206024731_7672",
    "FWA_STREAM_NETWORKS_SP",
    "FWSTRMNTWR_line.shp"
  )
) ## TODO: need download code for this
streamsorder <- streamsorder |>
  st_intersection(Quesnel_TSA_boundary)
st_write(streamsorder, file.path(inputs_dir, "streamsorder.shp"), delete_layer = TRUE)

# --- Consolidated Roads for the Cariboo Download ---

# The consolidated roads for the Cariboo layer  has been handled seperately
# because it was not downloadable through the bcdata package
from <- "//spatialfiles.bcgov/work/srm/wml/Workarea/!Cariboo_Data_Warehouse/physical_infrastructure/Cariboo_Consolidated_Roads.gdb"
to <- file.path(download_dir, "Cariboo_Consolidated_Roads.gdb")
dir.create(to)
file.copy(
  list.files(from, full.names = TRUE),
  file.path(to, basename(list.files(from))),
  overwrite = TRUE
)
roads <- st_read(file.path(download_dir, "Cariboo_Consolidated_Roads.gdb"))
roads_clipped <- st_intersection(roads, Quesnel_TSA_boundary)
Roads_filtered <- roads_clipped |>
  select(TRANSPORT_LINE_TYPE_CODE, TRANSPORT_LINE_TENURE_TYPE_CODE)
names(Roads_filtered)[names(Roads_filtered) == "TRANSPORT_LINE_TYPE_CODE"] <- "LINE_TYPE"
names(Roads_filtered)[names(Roads_filtered) == "TRANSPORT_LINE_TENURE_TYPE_CODE"] <- "LINE_TENUR"
st_write(Roads_filtered, file.path(inputs_dir, "Consolidated_roads.shp"), delete_layer = TRUE)


# --- Vegetation Resource Inventory (VRI) Download ---

# the VRI data has been downloaded and clipped directly from the BC data
# catalogue due to large file size and long processing time (over 5 GB)
bbox <- st_bbox(Quesnel_TSA_boundary) # Create a bounding box of the buffer to reduce processing time
vri_subset <- st_read(
  dsn = file.path(
    download_dir,
    "VRI_Age/VEG_COMP_LYR_R1_POLY_2023.gdb/VEG_COMP_LYR_R1_POLY_2023.gdb"
  ),
  layer = "VEG_COMP_LYR_R1_POLY",
  wkt_filter = st_as_text(st_as_sfc(bbox))
) ## TODO: need download code for this

# Clip VRI after loading and save result
vri_clipped <- st_intersection(vri_subset, Quesnel_TSA_boundary)
vri_selected <- vri_clipped |>
  select(PROJ_AGE_1, SPECIES_CD_1)
names(vri_selected) <- make.unique(substr(names(vri_selected), 1, 10))
st_write(vri_selected, file.path(inputs_dir, "VRI.shp"))

# --- Human Disturbance Download ---

# The human disturbance layer has been downloaded and clipped directly from the
# BCdata catalogue due to large file size and long processing time
Human_disturbance_subset <- st_read(
  dsn = file.path(
    download_dir,
    "Human_disturbance/New folder/BC_CEF_Human_Disturbance_2023/BC_CEF_Human_Disturbance_2023/BC_CEF_Human_Disturbance_2023.gdb"
  ),
  layer = "BC_CEF_Human_Disturb_BTM_2023",
  wkt_filter = st_as_text(st_as_sfc(bbox))
) ## TODO: need download code for this
Human_disturbance_subset <- st_cast(Human_disturbance_subset, "MULTIPOLYGON", warn = FALSE)
Human_disturbance_valid <- st_make_valid(Human_disturbance_subset) # fix invalid topologies error
Human_disturbance_clipped <- st_intersection(Human_disturbance_valid, Quesnel_TSA_boundary)
Human_diturbance_selected <- Human_disturbance_clipped |>
  select(CEF_DISTURB_GROUP, CEF_DISTURB_SUB_GROUP, CEF_HUMAN_DISTURB_FLAG)
names(Human_diturbance_selected)[
  names(Human_diturbance_selected) == "CEF_DISTURB_GROUP"
] <- "Dstrb_Grp"
names(Human_diturbance_selected)[
  names(Human_diturbance_selected) == "CEF_DISTURB_SUB_GROUP"
] <- "Dstrb_Subg"
names(Human_diturbance_selected) <- make.unique(
  substr(names(Human_diturbance_selected), 1, 10),
  sep = "_"
)
st_write(
  Human_diturbance_selected,
  file.path(inputs_dir, "Human_disturbance.shp"),
  delete_layer = TRUE
)

# --- Forest Disturbance Download ---

# Forest disturbance data has been downloaded manually as it is not available
# through the bcdata package (CEF Custom Product)
ForestDisturbance_Quesnel <- st_read(
  dsn = file.path(download_dir, "BC_CEF_Forest_Disturbance_2024.gdb"),
  layer = "BC_CEF_ForestDisturbance_2024",
  wkt_filter = st_as_text(st_as_sfc(bbox))
)
st_write(
  ForestDisturbance_Quesnel,
  file.path(inputs_dir, "Forest_Disturbance.shp"),
  delete_layer = TRUE
)

# --- Canada Land Cover Raster Download ---

# load in the Canada land cover layer (30-m, 2020) to be used as a base raster
# for rasterizing feature shapefiles

# Load the land cover raster and re-project Quesnel buffer to match its projection
landcover <- raster(file.path(download_dir, "landcover-2020-classification.tif")) ## TODO need download code
Quesnel_TSA_LC <- st_transform(Quesnel_TSA_boundary, crs = crs(landcover))
Quesnel_TSA_LC <- as(Quesnel_TSA_LC, "Spatial")

# Crop and mask before reprojection
landcover_clipped_raw <- crop(landcover, Quesnel_TSA_LC)
landcover_clipped_raw <- mask(landcover_clipped_raw, Quesnel_TSA_LC)

# Reproject to BC Albers to match the other data layers and save result
landcover_bc <- projectRaster(
  landcover_clipped_raw,
  crs = CRS("+init=EPSG:3005"),
  method = "ngb"
) ## TODO: avoid reprojecting the raster -- reproject the vector data instead!!!
writeRaster(landcover_bc, file.path(inputs_dir, "BC_landcover.tif"), overwrite = TRUE)
