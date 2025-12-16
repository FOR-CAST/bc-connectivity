# Patch area statistics -----------------------------------------------------------------------

calc_patch_stats <- function(for_dist_seral) {
  for_dist_seral_summary <- for_dist_seral |>
    ## reset geometry col name to ensure it's consistent
    sf::st_set_geometry("geom") |>
    dplyr::filter(!is.na(Seral)) |>
    dplyr::group_by(Seral) |>
    dplyr::mutate(Area = sf::st_area(geom, .before = "geom")) |>
    dplyr::summarise(
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

## calculate nearest neighbour distances
calc_nn_dists <- function(for_dist_old) {
  nn <- sf::st_nearest_feature(for_dist_old)
  nn_dists <- sf::st_distance(for_dist_old, for_dist_old[nn, ], by_element = TRUE)

  return(nn_dists)
}

## calculate all interpatch distances
calc_all_dists <- function(for_dist_old) {
  dist_mat <- sf::st_distance(for_dist_old)
  dist_mat[upper.tri(dist_mat)]
}

plot_hist_dists <- function(dists, dst) {
  dst <- file.path(get_path("figures"), dst)

  md <- median(dists) ## 54948.62 [m]
  mn <- mean(dists) ## 67630.84 [m]

  ## stick to base plot; ggplot is super slow
  hist_dists <- hist(dists, plot = FALSE)

  png(dst, width = 800, height = 600)
  plot(
    hist_dists,
    main = "Frequency distribution of interpatch distances",
    xlab = "Interpatch distance (m)"
  )
  abline(v = md, col = "blue", lty = 2)
  abline(v = mn, col = "black", lty = 2)
  dev.off()

  return(dst)
}
