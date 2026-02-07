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
calc_nn_dists <- function(for_dist) {
  matold <- for_dist |>
    dplyr::filter(Seral %in% c("Mature", "Old"))

  nn <- sf::st_nearest_feature(matold)
  nn_dists <- sf::st_distance(matold, matold[nn, ], by_element = TRUE)

  return(nn_dists)
}

## calculate distances between all patches (in parallel) ------------------------------------------

calc_all_dists_chunks <- function(for_dist, n_chunks = 64L) {
  n_chunks <- as.integer(n_chunks)

  stopifnot(length(n_chunks) == 1, n_chunks > 0)

  matold <- for_dist |>
    dplyr::filter(Seral %in% c("Mature", "Old"))

  n <- nrow(matold)

  chunk_id <- cut(
    seq_len(n),
    breaks = n_chunks,
    labels = FALSE
  )

  split(matold, chunk_id)
}

calc_all_dists_grid <- function(n_chunks) {
  ## only need to calculate distances for the upper triangle of the full matrix
  idx <- expand.grid(
    i = seq_len(n_chunks),
    j = seq_len(n_chunks)
  )
  idx[idx$i <= idx$j, , drop = FALSE]
}

calc_all_dists <- function(chunks, combo_row) {
  old_omp <- Sys.getenv("OMP_NUM_THREADS", unset = "")
  on.exit(Sys.setenv(OMP_NUM_THREADS = old_omp), add = TRUE)
  Sys.setenv(OMP_NUM_THREADS = 1)

  dist_mat <- sf::st_distance(chunks[[combo_row$i]], chunks[[combo_row$j]])

  if (combo_row$i == combo_row$j) {
    dist_mat <- dist_mat[upper.tri(dist_mat)]
  }

  return(dist_mat)
}

calc_all_dists_combine <- function(dists_list) {
  do.call(c, dists_list)
}

## plotting ---------------------------------------------------------------------------------------

plot_hist_dists <- function(dists, type) {
  dst <- file.path(get_path("figures"), glue::glue("histogram_patch_distances_{type}.png"))

  gg <- ggplot2::ggplot(data.frame(dists), aes(x = dists)) +
    ggplot2::geom_histogram(fill = "lightgrey") +
    ggplot2::geom_vline(
      xintercept = c(median(dists), mean(dists)),
      colour = c("blue", "darkred"),
      linetype = 2,
      linewidth = 1.5
    ) +
    ggplot2::annotate(
      "text",
      x = c(median(dists), mean(dists)),
      y = Inf,
      label = c("median", "mean"),
      colour = c("blue", "darkred"),
      angle = 90,
      vjust = 1.5,
      hjust = 1.5
    ) +
    ggplot2::xlab("Interpatch distance") +
    ggplot2::ylab("Frequency") +
    ggplot2::ggtitle(glue::glue("Frequency distribution of {type} interpatch distances")) +
    ggplot2::theme_minimal()

  ggplot2::ggsave(filename = dst, plot = gg, width = 8, height = 6)

  return(dst)
}
