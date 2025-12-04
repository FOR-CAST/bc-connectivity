# Study area statistics -----------------------------------------------------------------------

## TODO: create table of summary stats

## Load in Quesnel NRD Boundary (Study Area)
Quesnel_TSA <- sf::st_read(input_files[["study_area"]])

sf::st_crs(Quesnel_TSA)

Quesnel_TSA <- Quesnel_TSA |>
  dplyr::mutate(area_m2 = as.numeric(sf::st_area(Quesnel_TSA)))

centroids <- sf::st_centroid(Quesnel_TSA)
centroids_lonlat <- sf::st_transform(centroids, crs = 4326)

## Extract X and Y coordinates from centroids
coords <- sf::st_coordinates(centroids)
coords_lonlat <- sf::st_coordinates(centroids_lonlat)

Quesnel_TSA <- Quesnel_TSA |>
  dplyr::mutate(
    centroid_x = coords[, 1],
    centroid_y = coords[, 2],
    longitude = coords_lonlat[, 1], ## -122.9703
    latitude = coords_lonlat[, 2] ## 52.96388
  )

## Find the min and max elevation values of the Quesnel NRD using DEM
DEM <- terra::rast(input_files[["DEM"]])
min_elev <- terra::global(DEM, "min", na.rm = TRUE)[1] ## 421 meters
max_elev <- terra::global(DEM, "max", na.rm = TRUE)[1] ## 2700 meters

## Create NDT-BEC with additional BEC zone (for subsequent dissolve)
## !! ensure it matches the formatting in the Biodiversity Guidebook
bec_ndt <- sf::st_read(input_files[["BEC"]]) |>
  dplyr::select(NATURAL_DISTURBANCE, ZONE) |>
  dplyr::mutate(NDT_BEC = paste0(NATURAL_DISTURBANCE, "-", ZONE), BEC_ZONE = ZONE) |>
  sf::st_write(input_files[["BECNDT"]], append = FALSE)

gg_bec_ndt <- ggplot(bec_ndt) +
  geom_sf(aes(fill = NDT_BEC)) +
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

ggsave(file.path(figure_dir, "Quesnel_TSA_NDT-BEC.png"), gg_bec_ndt)


## VRI spatial join with NDT-BEC
vri <- sf::st_read(input_files[["VRI"]])

f_vri_joint <- c(input_files[["VRI_BECNDT"]], input_files[["NDT_BEC"]], input_files[["NDT"]])

if (need_rebuild || !all(file.exists(f_vri_joint))) {
  ## this join is slow, so don't rerun every time
  vri_joined <- sf::st_join(vri, bec_ndt, left = FALSE) |>
    sf::st_make_valid() |>
    dplyr::mutate(
      NDT_BEC = dplyr::case_when(
        NDT_BEC == "NDT4-IDF" & grepl("^FD", SPECIES_CD_1) ~ "NDT4-IDF-FD",
        NDT_BEC == "NDT4-IDF" & grepl("^PL", SPECIES_CD_1) ~ "NDT4-IDF-PL",
        TRUE ~ NDT_BEC
      )
    ) |>
    sf::st_write(input_files[["VRI_BECNDT"]], append = FALSE)

  ndt_bec_dissolved <- vri_joined |>
    dplyr::select(NDT_BEC, geom) |>
    dplyr::group_by(NDT_BEC) |>
    dplyr::summarise(geo = sf::st_union(geom), .groups = "drop") |>
    sf::st_write(input_files[["NDT_BEC"]], append = FALSE)

  ndt_dissolved <- sf::st_read(input_files[["BEC"]]) |>
    dplyr::group_by(NATURAL_DISTURBANCE_NAME) |>
    dplyr::summarise(geom = sf::st_union(geom), .groups = "drop") |>
    sf::st_write(input_files[["NDT"]], append = FALSE)
} else {
  vri_joined <- sf::st_read(input_files[["VRI_BECNDT"]])
  ndt_bec_dissolved <- sf::st_read(input_files[["NDT_BEC"]])
  ndt_dissolved <- sf::st_read(input_files[["NDT"]])
}

## TODO: make maps

# Interpatch assessment (moving window size) --------------------------------------------------

plot(OGMA)

B <- sf::st_distance(OGMA)
View(B)
avg_distances <- rowMeans(B)

c <- mean(avg_distances)

d <- c / 1000
hist(B)

H <- diag(B)
View(H)

u <- upper.tri(B)
View(u)
