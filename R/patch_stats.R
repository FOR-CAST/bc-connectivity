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

## calculate distances between nearest neighbours
calc_nn_dists <- function(x) {
  nn <- sf::st_nearest_feature(x)
  nn_dists <- sf::st_distance(x, x[nn, ], by_element = TRUE)

  return(nn_dists)
}

## calculate distances between all patches
calc_all_dists <- function(x) {
  dist_mat <- sf::st_distance(x)
  dist_mat[upper.tri(x)]
}

calc_interpatch_distances <- function(for_dist, type) {
  for_dist_matold <- for_dist |>
    dplyr::filter(Seral %in% c("Mature", "Old"))

  switch(
    type,
    all = calc_all_dists(for_dist_matold),
    nn = calc_nn_dists(for_dist_matold),
    stop("invalid interpatch distance type")
  )
}

plot_hist_dists <- function(dists, type) {
  dst <- file.path(get_path("figures"), glue::glue("histogram_patch_distances_{type}.png"))

  gg <- ggplot(data.frame(dists), aes(x = dists)) +
    geom_histogram(fill = "lightgrey") +
    geom_vline(
      xintercept = c(median(dists), mean(dists)),
      colour = c("blue", "darkred"),
      linetype = 2,
      linewidth = 1.5
    ) +
    annotate(
      "text",
      x = c(median(dists), mean(dists)),
      y = Inf,
      label = c("median", "mean"),
      colour = c("blue", "darkred"),
      angle = 90,
      vjust = 1.5,
      hjust = 1.5
    ) +
    xlab("Interpatch distance") +
    ylab("Frequency") +
    ggtitle(glue::glue("Frequency distribution of {type} interpatch distances")) +
    theme_minimal()

  ggsave(filename = dst, plot = gg, width = 8, height = 6)

  return(dst)
}
