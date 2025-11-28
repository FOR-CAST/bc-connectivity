# BEC-NDT zones map for the Quesnel NRD Study Area

# Load BEC with NDT and Zone
bec_ndt <- st_read(file.path(inputs_dir, "BEC.shp")) |>
  st_make_valid() |>
  select(NATURAL_DI, ZONE) |>
  mutate(NDT_BEC = paste0(NATURAL_DI, "-", ZONE), BEC_ZONE = ZONE) # Save BEC zone separately for dissolve

# Load VRI and filter attributes
vri <- st_read(file.path(inputs_dir, "VRI_selected.shp")) |>
  st_make_valid() |>
  select(PROJ_AGE_1, SPECIES_CD)

# Spatial join to attach BEC/NDT
vri_joined <- st_join(vri, bec_ndt, left = FALSE) |>
  mutate(
    base_NDT_BEC = paste0(NATURAL_DI, "-", ZONE),
    NDT_BEC = case_when(
      base_NDT_BEC == "NDT4-IDF" & grepl("^FD", SPECIES_CD) ~ "NDT4-IDF-FD",
      base_NDT_BEC == "NDT4-IDF" & grepl("^PL", SPECIES_CD) ~ "NDT4-IDF-PL",
      TRUE ~ base_NDT_BEC
    )
  ) |>
  st_make_valid()

ndt_bec_dissolved <- vri_joined |>
  select(NDT_BEC, geometry) |>
  group_by(NDT_BEC) |>
  summarise(geometry = st_union(geometry), .groups = "drop")

# Export to shapefile for Arcmap
st_write(
  ndt_bec_dissolved,
  file.path(inputs_dir, "NDT_BEC_Dissolved_Quesnel.shp"),
  delete_layer = TRUE
)

# just the NDT map

# Load BEC layer
bec_clipped <- st_read(file.path(inputs_dir, "BEC.shp")) # Already clipped to study area

# Dissolve by NDT type
bec_ndt_dissolved <- bec_clipped |>
  group_by(NATURAL_DI) |>
  summarise(geometry = st_union(geometry), .groups = "drop")

st_write(bec_ndt_dissolved, file.path(inputs_dir, "NDT_Dissolved_Quesnel.shp"), delete_layer = TRUE)

# Deriving study area statistics to inform Methods section

# Load in Quesnel NRD Boundary (Study Area)
Quesnel_TSA <- st_read(
  file.path(inputs_dir, "QuesnelTSA_studyarea.shp")
)
st_crs(Quesnel_TSA)

# Calculate hectares for the Quesnel NRD boundary
Quesnel_TSA$area_ha <- as.numeric(st_area(Quesnel_TSA)) / 10000

# Calculate km2 for the Quesnel NRD boundary
Quesnel_TSA$area_km2 <- as.numeric(st_area(Quesnel_TSA)) / 1e6

# Calculate centroid of the Quesnel NRD
centroids <- st_centroid(Quesnel_TSA)

# Extract X and Y coordinates from centroids
coords <- st_coordinates(centroids)
Quesnel_TSA$centroid_x <- coords[, 1] # 1203022
Quesnel_TSA$centroid_y <- coords[, 2] # 888341.7

# Calculate lat/long for study area
centroids_wgs84 <- st_transform(centroids, crs = 4326)

# Transform to WGS84
coords_wgs84 <- st_coordinates(centroids_wgs84)

# Add long and lat to shapefile as new columns
Quesnel_TSA$longitude <- coords_wgs84[, 1] # -122.9703
Quesnel_TSA$latitude <- coords_wgs84[, 2] # 52.96388

# Load in DEM for Quesnel NRD

DEM <- rast(file.path(inputs_dir, "Quesnel_TSA_DEM.tif"))

# Find the min and max elevation values of the Quesnel NRD using DEM

min_elev <- global(DEM, "min", na.rm = TRUE)[1] # 421 meters
max_elev <- global(DEM, "max", na.rm = TRUE)[1] # 2694 meters

# Load in OGMAs and find count and total coverage

OGMAs <- st_read(file.path(inputs_dir, "OGMAcurrent.shp"))
st_crs(OGMAs)

# Find OGMA count within the Quesnel NRD

n_OGMAs <- nrow(OGMAs) # 2330 OGMA polygons

# Find OGMA coverage in hecatares and km2
OGMAs <- OGMAs |> mutate(area_m2 = st_area(geometry))

total_area_m2 <- sum(OGMAs$area_m2)
total_area_ha <- as.numeric(total_area_m2) / 10^4 # 146360.98 hectares of OGMAs
total_area_km2 <- as.numeric(total_area_m2) / 10^6 # 1463.61 km2 of OGMAs
