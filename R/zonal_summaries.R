# Zonal summaries of Omniscape output -----------------------------------------------------------

## Summarise normalized cumulative current within (and outside) each set of biodiversity features,
## and for every Landscape Unit x BEC zone combination.
##
## Takes the Omniscape output paths from the pipeline rather than globbing `Outputs/` for a
## hard-coded run-name pattern, and takes its layers as arguments rather than re-reading them with
## `tar_read()` -- both of which silently tied this function to one particular set of runs.
zonal_summaries <- function(
  omniscape_outputs,
  Quesnel_TSA,
  LCC,
  LU,
  BEC,
  moose_wetlands,
  MDWR,
  OGMA,
  parks,
  wetlands,
  WHA
) {
  if (length(omniscape_outputs) == 0L) {
    return(character(0))
  }

  current_maps <- grep("normalized_cum_currmap[.]tif$", omniscape_outputs, value = TRUE)

  if (length(current_maps) == 0L) {
    return(character(0))
  }

  studyArea <- tidyterra::as_spatvector(Quesnel_TSA) |>
    terra::project(terra::crs(LCC))

  clip <- function(x) {
    tidyterra::as_spatvector(x) |> terra::project(terra::crs(LCC)) |> terra::crop(studyArea)
  }

  summary_polys <- list(
    bec_lu = terra::intersect(clip(BEC), clip(LU)),
    hvmw = clip(moose_wetlands),
    mdwr = clip(MDWR),
    ogma = clip(OGMA),
    parks = clip(parks),
    wetlands = clip(wetlands),
    wha = clip(WHA)
  )

  purrr::map_chr(current_maps, function(tif) {
    run_dir <- dirname(tif)
    run_name <- basename(run_dir)

    norm_curr <- terra::rast(tif) |> terra::crop(studyArea, mask = TRUE)

    zonal_by_polys <- purrr::map(names(summary_polys), function(p) {
      if (p == "bec_lu") {
        ## LU x BEC summaries: summarize each combination rather than in/out
        u <- summary_polys[[p]] |>
          tidyterra::select(LANDSCAPE_UNIT_NAME, ZONE) |>
          terra::aggregate(by = c("LANDSCAPE_UNIT_NAME", "ZONE"))

        terra::zonal(norm_curr, u, fun = "mean", na.rm = TRUE) |>
          stats::setNames("mean_norm_cum_curr") |>
          dplyr::mutate(
            zone = glue::glue("LU_{u$LANDSCAPE_UNIT_NAME}_{u$ZONE}"),
            .before = "mean_norm_cum_curr"
          )
      } else {
        u <- terra::aggregate(summary_polys[[p]]) ## e.g., all parks areas
        d <- terra::erase(studyArea, u) ## e.g., all non-parks areas

        dplyr::bind_rows(
          terra::zonal(norm_curr, u, fun = "mean", na.rm = TRUE) |>
            stats::setNames("mean_norm_cum_curr") |>
            dplyr::mutate(zone = p, .before = "mean_norm_cum_curr"),
          terra::zonal(norm_curr, d, fun = "mean", na.rm = TRUE) |>
            stats::setNames("mean_norm_cum_curr") |>
            dplyr::mutate(zone = glue::glue("non-{p}"), .before = "mean_norm_cum_curr")
        )
      }
    }) |>
      dplyr::bind_rows() |>
      dplyr::mutate(run = run_name, .before = "zone")

    dst <- file.path(run_dir, "zonal_by_polys.csv")
    utils::write.csv(zonal_by_polys, file = dst, row.names = FALSE)

    gc(verbose = FALSE)

    dst
  })
}
