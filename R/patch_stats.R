# Patch area statistics -----------------------------------------------------------------------

calc_patch_stats <- function(for_dist_seral) {
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
}

save_patch_stats <- function(stats_df) {
  dst <- file.path(get_path("outputs"), "Quesnel_TSA_seral_patch_stats.csv")

  write.csv(x = stats_df, file = dst, row.names = FALSE)

  return(dst)
}

# Interpatch assessment (moving window size) --------------------------------------------------

## extract old forest patches and dissolve the polygons
extract_old_patches <- function(for_dist_seral) {
  for_dist_seral |>
    dplyr::filter(Seral == "Old") |>
    sf::st_collection_extract("POLYGON") |>
    spatialEco::sf_dissolve("Seral") |>
    sf::st_cast("POLYGON")
}

## plot for visual inspection
plot_old_patches <- function(for_dist_old) {
  dst <- file.path(get_path("figures"), "Quesnel_TSA_for_dist_old.png")

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

  ggsave(dst, gg_for_dist_old)

  return(dst)
}

## calculate nearest neighbour distances; very slow...31167 polygons
calc_nn_dists <- function(for_dist_old) {
  nn <- sf::st_nearest_feature(for_dist_old)
  nn_dists <- sf::st_distance(for_dist_old, for_dist_old[nn, ], by_element = TRUE)

  ## > quantile(nn_dists, seq(0, 1, 0.05))
  ## Units: [m]
  ##          0%          5%         10%         15%         20%         25%
  ##    0.000000    0.000000    0.000000    0.000000    0.000000    0.000000
  ##         30%         35%         40%         45%         50%         55%
  ##    1.476026    3.960346    6.450645    9.272795   12.377916   17.265910
  ##         60%         65%         70%         75%         80%         85%
  ##   22.029441   29.047189   35.843593   47.102736   61.796614   83.751292
  ##         90%         95%        100%
  ##  127.926552  242.972648 5757.345139

  return(nn_dists)
}

plot_nn_dists <- function(nn_dists) {
  dst <- file.path(get_path("figures"), "histogram_old_patch_nn_distances.png")

  ## stick to base plot; ggplot is super slow
  hist_nn_dists <- hist(nn_dists, breaks = 60, plot = FALSE)

  png(dst, width = 800, height = 600)
  plot(hist_nn_dists)
  dev.off()

  return(dst)
}

## calculate all interpatch distances; very slow...31167 polygons
calc_all_dists <- function(for_dist_old) {
  sf::st_distance(for_dist_old)
}

plot_all_dists <- function(dist_mat) {
  dst <- file.path(get_path("figures"), "histogram_old_patch_all_distances.png")

  dists <- dist_mat[upper.tri(dist_mat)]

  md <- median(dists) ## 54948.62 [m]
  mn <- mean(dists) ## 67630.84 [m]

  ## stick to base plot; ggplot is super slow
  hist_dists <- hist(dists, plot = FALSE)

  png(dst, width = 800, height = 600)
  plot(hist_dists)
  abline(v = md, col = "blue", lty = 2)
  abline(v = mn, col = "black", lty = 2)
  dev.off()

  return(dst)
}
