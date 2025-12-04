# Create additional joined polygons -----------------------------------------------------------

## NDT-BEC with additional BEC zone (for subsequent dissolve)
## !! ensure it matches the formatting in the Biodiversity Guidebook
bec_ndt <- sf::st_read(input_files[["BEC"]], quiet = TRUE) |>
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

## VRI spatial join with NDT-BEC;
## this join is slow, so don't rerun every time
vri <- sf::st_read(input_files[["VRI"]], quiet = TRUE)

f_vri_joint <- c(input_files[["VRI_BECNDT"]], input_files[["NDT_BEC"]], input_files[["NDT"]])

if (need_rebuild || !all(file.exists(f_vri_joint))) {
  vri_joined <- sf::st_join(vri, bec_ndt, left = FALSE) |>
    sf::st_make_valid() |>
    ## remove_slivers() |> ## TODO
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

  ndt_dissolved <- sf::st_read(input_files[["BEC"]], quiet = TRUE) |>
    dplyr::group_by(NATURAL_DISTURBANCE) |>
    dplyr::summarise(geom = sf::st_union(geom), .groups = "drop") |>
    sf::st_write(input_files[["NDT"]], append = FALSE)
} else {
  vri_joined <- sf::st_read(input_files[["VRI_BECNDT"]], quiet = TRUE)
  ndt_bec_dissolved <- sf::st_read(input_files[["NDT_BEC"]], quiet = TRUE)
  ndt_dissolved <- sf::st_read(input_files[["NDT"]], quiet = TRUE)
}

## Forest Disturbance spatial join with VRI-NDT-BEC;
## this join is slow, so don't rerun every time
if (need_rebuild || !file.exists(input_files[["forest_disturbance_joined"]])) {
  for_dist_joined <- sf::st_read(input_files[["forest_disturbance"]], quiet = TRUE) |>
    dplyr::select(SIFA) |>
    sf::st_join(vri_joined, left = FALSE) |>
    sf::st_make_valid() |>
    sf::st_write(input_files[["forest_disturbance_joined"]], append = FALSE)
} else {
  for_dist_joined <- sf::st_read(input_files[["forest_disturbance_joined"]], quiet = TRUE)
}

## Define NDT-BEC-specific seral stages according to the Biodiversity Guidebook
seral_stages <- tibble::tribble(
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

seral_stages_long <- seral_stages |>
  tidyr::pivot_longer(
    cols = Early:Old,
    names_to = "Seral",
    values_to = "Age_Min"
  ) |>
  dplyr::group_by(NDT_BEC) |>
  dplyr::arrange(match(Seral, c("Early", "Mid", "Mature", "Old")), .by_group = TRUE) |>
  dplyr::mutate(
    Age_Max = dplyr::lead(Age_Min, default = max(for_dist_joined$SIFA, na.rm = TRUE) + 1)
  ) |>
  dplyr::relocate(Seral, .after = Age_Max)

## assign seral stage classifications based on seral stage table;
## this join is slow, so don't rerun every time
if (need_rebuild || !file.exists(input_files[["forest_disturbance_seral"]])) {
  for_dist_seral <- for_dist_joined |>
    dplyr::left_join(
      seral_stages_long,
      by = dplyr::join_by(NDT_BEC, dplyr::between(SIFA, Age_Min, Age_Max, bounds = "[)"))
    ) |>
    sf::st_make_valid() |>
    dplyr::mutate(Age_Min = NULL, Age_Max = NULL) |>
    sf::st_write(input_files[["forest_disturbance_seral"]], append = FALSE)
} else {
  for_dist_seral <- sf::st_read(input_files[["forest_disturbance_seral"]], quiet = TRUE)
}

# Patch area statistics -----------------------------------------------------------------------

for_dist_seral_summary <- for_dist_seral |>
  ## TODO: filter(Area < min_area) |> ## b/c of slivers
  dplyr::mutate(Area = sf::st_area(geom), .before = "geom") |>
  dplyr::filter(!is.na(Seral)) |>
  dplyr::group_by(NDT_BEC, Seral) |>
  dplyr::summarise(
    Age_Min = min(SIFA),
    Age_Mean = mean(SIFA),
    Age_Median = median(SIFA),
    Age_Max = max(SIFA),

    Area_Min = min(Area),
    Area_Mean = mean(Area),
    Area_Median = median(Area),
    Area_Max = max(Area),

    .groups = "keep"
  ) |>
  sf::st_drop_geometry()

write.csv(
  x = for_dist_seral_summary,
  file = file.path(output_dir, "Quesnel_TSA_seral_patch_stats.csv"),
  row.names = FALSE
)

# Interpatch assessment (moving window size) --------------------------------------------------

## extract old forest patches and dissolve the polygons
for_dist_old <- for_dist_seral |>
  dplyr::filter(Seral == "Old") |>
  sf::st_collection_extract("POLYGON") |>
  spatialEco::sf_dissolve("Seral") |>
  sf::st_cast("POLYGON")

## plot for visual inspection
gg_for_dist_old <- ggplot(for_dist_old) +
  geom_sf() +
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
  ggtitle("Quesnel NRD Old Patches")

ggsave(file.path(figure_dir, "Quesnel_TSA_for_dist_old.png"), gg_for_dist_old)

## calculate nearest neighbour distances
f_nn_dists <- file.path(inputs_dir, "nearest_neighbour_distances_old_patches.rds")
if (!file.exists(f_nn_dists)) {
  ## very slow...31167 polygons
  nn <- sf::st_nearest_feature(for_dist_old)
  sf::st_distance(for_dist_old, for_dist_old[nn], by_element = TRUE)
  saveRDS(nn_dists, f_nn_dists)
  rm(nn)
} else {
  nn_dists <- readRDS(f_nn_dists)
}

median(nn_dists) ## XXXXX [m]
mean(nn_dists) ## YYYYY [m]

## stick to base plot; ggplot is super slow
hist_nn_dists <- hist(dists, plot = FALSE)
png(file.path(figure_dir, "histogram_old_patch_nn_distances.png"), width = 800, height = 600)
plot(hist_nn_dists)
dev.off()

## calculate all interpatch distances
f_dist_mat <- file.path(inputs_dir, "distance_matrix_old_patches.rds")
if (!file.exists(f_dist_mat)) {
  ## very slow...31167 polygons
  dist_mat <- sf::st_distance(for_dist_old)
  saveRDS(dist_mat, f_dist_mat)
} else {
  dist_mat <- readRDS(f_dist_mat)
}

up <- upper.tri(dist_mat)
dists <- dist_mat[up]

median(dists) ## 54948.62 [m]
mean(dists) ## 67630.84 [m]

## stick to base plot; ggplot is super slow
hist_dists <- hist(dists, plot = FALSE)
png(file.path(figure_dir, "histogram_old_patch_distances.png"), width = 800, height = 600)
plot(hist_dists)
dev.off()
