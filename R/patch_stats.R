# Patch area statistics -----------------------------------------------------------------------

## Patch statistics are computed on the *dissolved seral layer* (arcpy step 5a), where a patch is a
## contiguous area of a single seral stage.
##
## They used to be computed on the final resultant instead. That layer is an overlay: its polygons
## are the fragments produced by splitting the seral layer at every interior-forest boundary, not
## patches.
##
## A minimum patch size is applied because the dissolved seral layer is itself full of slivers --
## artifacts of the source polygon boundaries rather than landscape structure. Measured on the
## Quesnel NRD: of 283,151 patches, 63% are smaller than a single 30 m pixel and 1,088 have exactly
## zero area, yet all of those together account for 1,427 ha out of 2,704,355 -- 0.05% of the
## landscape. Without a floor the median patch size describes the slivers, not the forest.
##
## 1 ha matches the threshold the CEF Biodiversity Protocol uses for residual patches (§3.2.2), and
## the one arcpy `Eliminate` applies at steps 2c/2g. Note that this is a *reporting* filter: it
## changes the statistics only, never the layers the connectivity analysis is built from. The
## excluded count and area are reported alongside so nothing is hidden.
calc_patch_stats <- function(patch_size, min_area = units::set_units(1, "ha")) {
  min_m2 <- as.numeric(units::set_units(min_area, "m^2", mode = "standard"))

  v <- tidyterra::as_spatvector(patch_size) |> dplyr::filter(!is.na(Seral))

  data.frame(
    Seral = tidyterra::pull(v, Seral),
    Area = spatialutils::expanse_planar(v, "m")
  ) |>
    dplyr::group_by(Seral) |>
    dplyr::summarise(
      N = sum(Area >= min_m2),
      Area_Min = min(Area[Area >= min_m2]),
      Area_Mean = mean(Area[Area >= min_m2]),
      Area_Median = stats::median(Area[Area >= min_m2]),
      Area_Max = max(Area[Area >= min_m2]),
      Area_Total = sum(Area[Area >= min_m2]),
      N_Excluded = sum(Area < min_m2),
      Area_Excluded = sum(Area[Area < min_m2]),
      .groups = "drop"
    ) |>
    dplyr::mutate(Min_Patch_Area = min_m2, .after = "Seral")
}

save_patch_stats <- function(stats_df) {
  dst <- file.path(get_path("outputs"), "Quesnel_TSA_seral_patch_stats.csv")

  utils::write.csv(x = stats_df, file = dst, row.names = FALSE)

  return(dst)
}

# Interpatch assessment (moving window size) --------------------------------------------------

calc_matold <- function(for_dist) {
  ## combine mature and old geometries to reduce the number of features
  tidyterra::as_spatvector(for_dist) |>
    dplyr::filter(Seral %in% c("Mature", "Old")) |>
    dplyr::mutate(patch = "matold") |>
    dplyr::select(patch) |>
    dissolve_by("patch") |>
    dplyr::mutate(id = dplyr::row_number())
}

## Split `n` features into `n_chunks` contiguous index ranges.
##
## This deliberately returns *indices*, not a list of pre-split layers. The previous version split
## the layer itself, so every branch had to retrieve the whole list of chunks (the entire layer,
## once per chunk) on top of the layer it was already given -- ~350 GB of resident memory across
## 255 workers.
make_chunks <- function(n, n_chunks = 64L) {
  data.frame(chunk = seq_len(n_chunks_for(n, n_chunks))) |>
    dplyr::group_by(chunk) |>
    targets::tar_group()
}

## Asking for more chunks than there are features would leave empty chunks behind, so the count is
## clamped -- in one place, since `make_chunks()` and `chunk_rows()` have to agree on it.
n_chunks_for <- function(n, n_chunks) {
  stopifnot(length(n) == 1, length(n_chunks) == 1, n > 0, n_chunks > 0)

  max(1L, min(as.integer(n_chunks), as.integer(n)))
}

## Rows belonging to one chunk: contiguous, near-equal blocks.
##
## NOTE: `cut(seq_len(n), breaks = k)` cannot express `k = 1` ("invalid number of intervals"), which
## made a single-chunk run -- the natural thing to do for a small layer, or when debugging -- fail.
chunk_rows <- function(n, n_chunks, chunk) {
  k <- n_chunks_for(n, n_chunks)
  breaks <- floor(seq(0, n, length.out = k + 1L))

  if (breaks[[chunk]] >= breaks[[chunk + 1L]]) {
    return(integer(0))
  }

  seq.int(breaks[[chunk]] + 1L, breaks[[chunk + 1L]])
}

## Distance from each patch in `chunk` to the nearest *other* patch in `matold`.
##
## `spatialutils::nn_distance()` runs one indexed candidate query per round over an escalating
## search radius, then computes exact distances for the candidates only. `exclude = idx` tells it
## which row of `matold` each patch in this chunk *is*, so a patch does not find itself at distance
## 0 -- that is what lets a chunk be measured against the whole layer, and therefore what lets the
## chunks run in parallel.
##
## The previous implementation called `sf::st_nearest_feature()` once per patch against `matold`
## minus that patch, rebuilding the GEOS index over ~70,000 polygons ~70,000 times: 1.72 s per
## patch, and 227,672 s of CPU for the layer.
calc_nn_dists <- function(matold, chunk, n_chunks) {
  v <- tidyterra::as_spatvector(matold)
  idx <- chunk_rows(nrow(v), n_chunks, chunk$chunk[[1]])

  d <- spatialutils::nn_distance(v[idx, ], v, exclude = idx)

  if (anyNA(d)) {
    stop(sum(is.na(d)), " patches have no neighbour anywhere in the layer")
  }

  units::set_units(d, "m")
}

calc_nn_dists_combine <- function(dists_list) {
  do.call(c, dists_list) ## do.call preserves units
}

## calculate distances between all patches (in parallel) ------------------------------------------

calc_all_dists_grid <- function(n_chunks) {
  ## only need to calculate distances for the upper triangle of the full matrix
  idx <- expand.grid(i = seq_len(n_chunks), j = seq_len(n_chunks))
  idx <- idx[idx$i <= idx$j, , drop = FALSE]

  idx |> dplyr::mutate(pair = dplyr::row_number()) |> dplyr::group_by(pair) |> targets::tar_group()
}

## Distances between every pair of patches, one chunk-pair at a time, written straight to parquet.
##
## The distances used to be returned as a target *and* then written to parquet by a second target,
## which stored ~20 GB of intermediates in `_targets/objects` and re-read all of it to write the
## dataset. Writing here and returning the file path makes the parquet dataset the target itself.
calc_all_dists <- function(matold, combo_row, n_chunks, ds_dir = NULL) {
  v <- tidyterra::as_spatvector(matold)

  i <- combo_row$i[[1]]
  j <- combo_row$j[[1]]

  rows_i <- chunk_rows(nrow(v), n_chunks, i)
  rows_j <- chunk_rows(nrow(v), n_chunks, j)

  dists <- if (length(rows_i) == 0L || length(rows_j) == 0L) {
    numeric(0)
  } else {
    dist_mat <- terra::distance(v[rows_i, ], v[rows_j, ])

    if (i == j) dist_mat[upper.tri(dist_mat)] else c(dist_mat)
  }

  ## Named for the chunk pair, not `targets::tar_name()`: the branch name changes whenever the
  ## branch is re-hashed, which orphans the previous run's parquet files in the dataset directory.
  if (is.null(ds_dir)) {
    ds_dir <- file.path(get_path("inputs"), "all-distances")
  }
  fs::dir_create(ds_dir)
  dst <- file.path(ds_dir, sprintf("chunk_%04d_%04d.parquet", i, j))

  arrow::write_parquet(x = data.frame(distance = as.numeric(dists)), sink = dst)

  return(dst)
}

## Quantiles over the whole distance dataset.
##
## Reads exactly the files the pipeline produced rather than globbing the directory: a directory
## glob silently folds in parquet files left behind by an earlier run with different chunking.
calc_all_dists_quantiles <- function(dist_files) {
  ds <- arrow::open_dataset(dist_files)

  ## NOTE: adding more quantile calculations ramps up memory use;
  ## computing q00, q25, 250, q75 and q100 uses ~250 GB RAM
  ds |>
    arrow::to_duckdb() |>
    dplyr::summarise(
      `0%` = quantile(distance, 0.00),
      `25%` = quantile(distance, 0.25),
      `50%` = quantile(distance, 0.50),
      `75%` = quantile(distance, 0.75),
      `100%` = quantile(distance, 1.0)
    ) |>
    dplyr::collect()
}

## plotting ---------------------------------------------------------------------------------------

plot_hist_dists <- function(dists, type) {
  dst <- file.path(get_path("figures"), glue::glue("histogram_patch_distances_{type}.png"))

  gg <- ggplot2::ggplot(data.frame(dists), ggplot2::aes(x = dists)) +
    ggplot2::geom_histogram(fill = "lightgrey") +
    ggplot2::geom_vline(
      xintercept = c(stats::median(dists), mean(dists)),
      colour = c("blue", "darkred"),
      linetype = 2,
      linewidth = 1.5
    ) +
    ggplot2::annotate(
      "text",
      x = c(stats::median(dists), mean(dists)),
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
