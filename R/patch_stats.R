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

calc_matold <- function(for_dist) {
  ## combine mature and old geometries to reduce number of features (163k ==> 70k)
  matold <- sf::st_make_valid(for_dist) |>
    dplyr::filter(Seral %in% c("Mature", "Old")) |>
    dplyr::mutate(patch = "matold") |>
    dplyr::group_by(patch) |>
    dplyr::summarise() |>
    dplyr::ungroup() |>
    sf::st_cast("POLYGON", warn = FALSE) |>
    dplyr::mutate(id = dplyr::row_number(), .before = "patch")
}

## calculate distances between nearest neighbours (in parallel) -----------------------------------

make_chunks <- function(x, n_chunks = 64L) {
  n_chunks <- as.integer(n_chunks)

  stopifnot(length(n_chunks) == 1, n_chunks > 0)

  n <- nrow(x)

  chunk_id <- cut(seq_len(n), breaks = n_chunks, labels = FALSE)

  split(x, chunk_id)
}

calc_nn_dists <- function(matold, chunk) {
  ## chunk comes in as a length-1 list
  chunk <- chunk[[1]] |> sf::st_make_valid()
  purrr::map(
    .x = seq_len(nrow(chunk)),
    .f = function(chunk_row) {
      poly <- chunk[chunk_row, ]
      matold_exclude_self <- matold[-poly$id, ]
      nn <- sf::st_nearest_feature(poly, matold_exclude_self)
      nn_dists <- sf::st_distance(poly, matold_exclude_self[nn, ], by_element = TRUE)

      return(nn_dists)
    }
  ) |>
    do.call(c, args = _) ## do.call preserves units
}

calc_nn_dists_combine <- function(dists_list) {
  do.call(c, dists_list) ## do.call preserves units
}

## calculate distances between all patches (in parallel) ------------------------------------------

calc_all_dists_grid <- function(n_chunks) {
  ## only need to calculate distances for the upper triangle of the full matrix
  idx <- expand.grid(i = seq_len(n_chunks), j = seq_len(n_chunks))
  idx <- idx[idx$i <= idx$j, , drop = FALSE]
}

calc_all_dists <- function(chunks, combo_row) {
  chunk_i <- chunks[[combo_row$i]]
  chunk_j <- chunks[[combo_row$j]]

  dist_mat <- sf::st_distance(chunk_i, chunk_j)

  if (combo_row$i == combo_row$j) {
    dist_mat <- dist_mat[upper.tri(dist_mat)]
  }

  return(c(dist_mat)) ## convert from matrix to vector
}

## too large to combine everything in memory; write to arrow dataset
calc_all_dists_combine <- function(dists_list) {
  ds_dir <- file.path(get_path("inputs"), "all-distances") |> fs::dir_create()
  arrow::write_parquet(
    x = data.frame(distance = dists_list),
    sink = file.path(ds_dir, paste0("chunk_", targets::tar_name(), ".parquet"))
  )

  targets::tar_name()
}

calc_all_dists_quantiles <- function(target_names) {
  ds <- file.path(get_path("inputs"), "all-distances") |> arrow::open_dataset()

  ## NOTE: adding more quantile calculations ramps up memory use;
  ## computing q00, q25, 250, q75 and q100 uses ~250 GB RAM
  ds |>
    arrow::to_duckdb() |>
    dplyr::summarise(
      `0%` = quantile(distance, 0.00),
      # `5%` = quantile(distance, 0.05),
      # `10%` = quantile(distance, 0.10),
      # `15%` = quantile(distance, 0.15),
      # `20%` = quantile(distance, 0.20),
      `25%` = quantile(distance, 0.25),
      # `30%` = quantile(distance, 0.30),
      # `35%` = quantile(distance, 0.35),
      # `40%` = quantile(distance, 0.40),
      # `45%` = quantile(distance, 0.45),
      `50%` = quantile(distance, 0.50),
      # `55%` = quantile(distance, 0.55),
      # `60%` = quantile(distance, 0.60),
      # `65%` = quantile(distance, 0.65),
      # `70%` = quantile(distance, 0.70),
      `75%` = quantile(distance, 0.75),
      # `80%` = quantile(distance, 0.80),
      # `85%` = quantile(distance, 0.85),
      # `90%` = quantile(distance, 0.90),
      # `95%` = quantile(distance, 0.95),
      `100%` = quantile(distance, 1.0)
    ) |>
    dplyr::collect()
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
