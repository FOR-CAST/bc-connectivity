zonal_summaries <- function(TODO) {
  LCC <- tar_read(LCC)

  studyArea <- tar_read(Quesnel_TSA) |>
    sf::st_transform(terra::crs(LCC)) |>
    terra::vect()

  norm_curr <- file.path("Outputs", "2026-01-13_p90_r61_bs7", "normalized_cum_currmap.tif") |>
    terra::rast() |>
    terra::crop(studyArea, mask = TRUE)

  summary_polys <- list(
    hvmw = tar_read(moose_wetlands) |> terra::vect() |> terra::crop(studyArea),
    mdwr = tar_read(MDWR) |> terra::vect() |> terra::crop(studyArea),
    ogma = tar_read(OGMA) |> terra::vect() |> terra::crop(studyArea),
    parks = tar_read(parks) |> terra::vect() |> terra::crop(studyArea),
    wetlands = tar_read(wetlands) |> terra::vect() |> terra::crop(studyArea),
    wha = tar_read(WHA) |> terra::vect() |> terra::crop(studyArea)
  )

  zonal_by_polys <- lapply(names(summary_polys), function(p) {
    u <- summary_polys[[p]] |> terra::aggregate() ## e.g., all parks areas
    d <- terra::erase(studyArea, u) ## e.g., all non-parks areas

    z <- dplyr::bind_rows(
      terra::zonal(norm_curr, u, fun = "mean", na.rm = TRUE) |>
        dplyr::mutate(zone = !!p, .before = "normalized_cum_currmap"),
      terra::zonal(norm_curr, d, fun = "mean", na.rm = TRUE) |>
        dplyr::mutate(zone = !!glue::glue("non-{p}"), .before = "normalized_cum_currmap")
    )

    return(z)
  }) |>
    dplyr::bind_rows()

  return(zonal_by_polys)
}
