library(dplyr)
library(sf)
library(terra)

library(targets)

library(ggplot2)
library(ggspatial)
library(tidyterra)

LCC <- tar_read(LCC)

studyArea <- tar_read(Quesnel_TSA) |>
  sf::st_transform(terra::crs(LCC)) |>
  terra::vect()

output_dirs <- "Outputs" |>
  fs::dir_ls(type = "directory", regexp = "2026-01-13") |>
  fs::dir_info() |> ## captures file info, therefore none for empty dirs
  dplyr::pull(path) |>
  dirname() |>
  unique()

summary_polys <- list(
  bec_lu = (tar_read(BEC) |> terra::vect() |> terra::crop(studyArea)) |>
    terra::intersect(tar_read(LU) |> terra::vect() |> terra::crop(studyArea)),
  hvmw = tar_read(moose_wetlands) |> terra::vect() |> terra::crop(studyArea),
  mdwr = tar_read(MDWR) |> terra::vect() |> terra::crop(studyArea),
  ogma = tar_read(OGMA) |> terra::vect() |> terra::crop(studyArea),
  parks = tar_read(parks) |> terra::vect() |> terra::crop(studyArea),
  wetlands = tar_read(wetlands) |> terra::vect() |> terra::crop(studyArea),
  wha = tar_read(WHA) |> terra::vect() |> terra::crop(studyArea)
)

# all_summary_polys <- bind_rows(summary_polys) ## TODO: what's the tidyterra way to do this?

purrr::walk(
  .x = output_dirs,
  .f = function(x) {
    norm_curr <- file.path(x, "normalized_cum_currmap.tif") |>
      terra::rast() |>
      terra::crop(studyArea, mask = TRUE)

    zonal_by_polys <- lapply(names(summary_polys), function(p) {
      if (p == "bec_lu") {
        ## LUxBEC summaries, but don't do summaries in/out, just summarize each combo
        u <- summary_polys[[p]] |>
          tidyterra::select(LANDSCAPE_UNIT_NAME, ZONE) |>
          terra::aggregate(by = c("LANDSCAPE_UNIT_NAME", "ZONE"))

        z <- terra::zonal(norm_curr, u, fun = "mean", na.rm = TRUE) |>
          dplyr::rename(mean_norm_cum_curr = normalized_cum_currmap) |>
          dplyr::mutate(
            zone = !!glue::glue("LU_{u$LANDSCAPE_UNIT_NAME}_{u$ZONE}"),
            .before = "mean_norm_cum_curr"
          )
      } else {
        u <- summary_polys[[p]] |> terra::aggregate() ## e.g., all parks areas
        d <- terra::erase(studyArea, u) ## e.g., all non-parks areas

        z <- dplyr::bind_rows(
          terra::zonal(norm_curr, u, fun = "mean", na.rm = TRUE) |>
            dplyr::rename(mean_norm_cum_curr = normalized_cum_currmap) |>
            dplyr::mutate(zone = !!p, .before = "mean_norm_cum_curr"),
          terra::zonal(norm_curr, d, fun = "mean", na.rm = TRUE) |>
            dplyr::rename(mean_norm_cum_curr = normalized_cum_currmap) |>
            dplyr::mutate(zone = !!glue::glue("non-{p}"), .before = "mean_norm_cum_curr")
        ) |>
          dplyr::mutate(run = basename(x), .before = "zone")
      }

      return(z)
    }) |>
      dplyr::bind_rows()

    gc(verbose = FALSE)

    write.csv(zonal_by_polys, file = file.path(x, "zonal_by_polys.csv"), row.names = FALSE)
  }
)

###################################################################################################

ggplot() +
  geom_spatraster(data = norm_curr) +
  scale_fill_whitebox_c(palette = "arid") +
  # geom_spatvector(
  #   data = studyArea,
  #   col = "black",
  #   fill = NA,
  #   inherit.aes = FALSE,
  #   linewidth = 1.2
  # ) +
  geom_spatvector(
    data = summary_polys[[p]],
    # aes(col = as.factor(PARK_CLASS)),
    fill = NA,
    inherit.aes = FALSE,
    linewidth = 1.2
  )
