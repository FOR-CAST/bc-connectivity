input_files <- append(input_files, list(
  NDT_BEC = file.path(inputs_dir, "NDT_BEC_dissolved.gpkg"),
  NDT = file.path(inputs_dir, "NDT_dissolved.gpkg")
))

# BEC-NDT zones map for the Quesnel NRD Study Area --------------------------------------------

## Load BEC with NDT and Zone; save BEC zone separately for dissolve
bec_ndt <- sf::st_read(input_files[["BEC"]]) |>
  dplyr::select(NATURAL_DI, ZONE) |>
  dplyr::mutate(NDT_BEC = paste0(NATURAL_DI, "-", ZONE), BEC_ZONE = ZONE)

## Load VRI and filter attributes
vri <- sf::st_read(input_files[["VRI"]]) |>
  dplyr::select(PROJ_AGE_1, SPECIES_CD)

## Spatial join to attach BEC/NDT
vri_joined <- sf::st_join(vri, bec_ndt, left = FALSE) |>
  dplyr::mutate(
    base_NDT_BEC = paste0(NATURAL_DI, "-", ZONE),
    NDT_BEC = dplyr::case_when(
      base_NDT_BEC == "NDT4-IDF" & grepl("^FD", SPECIES_CD) ~ "NDT4-IDF-FD",
      base_NDT_BEC == "NDT4-IDF" & grepl("^PL", SPECIES_CD) ~ "NDT4-IDF-PL",
      TRUE ~ base_NDT_BEC
    )
  ) |>
  sf::st_make_valid()

ndt_bec_dissolved <- vri_joined |>
  dplyr::select(NDT_BEC, geometry) |>
  dplyr::group_by(NDT_BEC) |>
  dplyr::summarise(geometry = sf::st_union(geometry), .groups = "drop") |>
  sf::st_write(input_files[["NDT_BEC"]], append = FALSE)

# NDT zones map for the Quesnel NRD Study Area ------------------------------------------------

## Load BEC layer
ndt <- sf::st_read(file.path(inputs_dir, "BEC.gpkg")) |>
  dplyr::group_by(NATURAL_DI) |>
  dplyr::summarise(geometry = sf::st_union(geometry), .groups = "drop") |>
  sf::st_write(input_files[["NDT"]], append = FALSE)

# Study area statistics -----------------------------------------------------------------------

## Load in Quesnel NRD Boundary (Study Area)
Quesnel_TSA <- sf::st_read(input_files[["study_area"]])

sf::st_crs(Quesnel_TSA)

Quesnel_TSA <- Quesnel_TSA |>
  dplyr::mutate(area_m2 = as.numeric(sf::st_area(Quesnel_TSA)))


centroids <- sf::st_centroid(Quesnel_TSA)
centroids_lonlat <- sf::st_transform(centroids, crs = 4326)

## Extract X and Y coordinates from centroids
coords <- sf::st_coordinates(centroids)
coords_lonlat <- sf::st_coordinates(centroids_wgs84)

Quesnel_TSA <- Quesnel_TSA |>
  dplyr::mutate(
    centroid_x = coords[, 1],
    centroid_y = coords[, 2],
    longitude = coords_wgs84[, 1], ## -122.9703
    latitude = coords_wgs84[, 2] ## 52.96388
  )

## Load in DEM for Quesnel NRD

DEM <- terra::rast(input_files[["DEM"]])

## Find the min and max elevation values of the Quesnel NRD using DEM

min_elev <- terra::global(DEM, "min", na.rm = TRUE)[1] ## 421 meters
max_elev <- terra::global(DEM, "max", na.rm = TRUE)[1] ## 2694 meters

## Load in OGMAs and find count and total coverage

OGMAs <- sf::st_read(file.path(inputs_dir, "OGMAcurrent.gpkg"))

sf::st_crs(OGMAs)

## Find OGMA count within the Quesnel NRD

n_OGMAs <- nrow(OGMAs) ## 2330 OGMA polygons

## Find OGMA coverage area
OGMAs <- OGMAs |>
  dplyr::mutate(area_m2 = sf::st_area(geometry))

total_area_m2 <- sum(OGMAs$area_m2)
