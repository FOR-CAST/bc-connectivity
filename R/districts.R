# District registry ---------------------------------------------------------------------------

## The pipeline is run once per Natural Resource District, as a pair of `targets` projects
## (prep + omniscape). Everything district-specific lives here so the factories in `R/factories.R`
## stay generic and cannot drift between districts.
##
## District names are the values of `DSTRCT_NM` in the BCGW `ADM_NR_DISTRICTS_SP` layer, verified
## against the downloaded shapefile rather than assumed.

#' Districts this pipeline can be run for
#'
#' @returns named list of district specifications
#'
#' @export
districts <- function() {
  list(
    quesnel = list(
      key = "quesnel",
      district_name = "Quesnel Natural Resource District",
      label = "Quesnel",
      ## 90 m, like every other district. Quesnel is the reference landscape for the
      ## resolution-equivalence study, which is the only thing the 30 m series ever existed for,
      ## and that study is written and settled (`reports/resolution-equivalence.qmd`).
      ## `study_agg_factors` keeps the pair on record so re-enabling the comparison does not
      ## require reconstructing which resolutions it compared.
      agg_factors = 3,
      study_agg_factors = c(1, 3),
      ## Quesnel is where the radii were measured, and `reference_distances()` records what they
      ## came out at -- so every district, Quesnel included, now reads them from there rather than
      ## recomputing. Measuring them again costs 97.8 h over 2.33 billion pairs to reproduce
      ## numbers already written down. `BC_CONN_INTERPATCH_DISTANCES=1` measures them anyway,
      ## which is what a change to patch construction would need; see [reference_distances()].
      interpatch_distances = FALSE
    ),
    chilcotin = list(
      key = "chilcotin",
      district_name = "Cariboo-Chilcotin Natural Resource District",
      label = "Cariboo-Chilcotin",
      agg_factors = 3,
      interpatch_distances = FALSE
    ),
    hundred_mile = list(
      key = "hundred_mile",
      district_name = "100 Mile House Natural Resource District",
      label = "100 Mile House",
      agg_factors = 3,
      interpatch_distances = FALSE
    )
  )
}

#' Specification for one district
#'
#' @param key character district key, one of `names(districts())`
#'
#' @returns list with `key`, `district_name` and `label`
#'
#' @export
district_spec <- function(key) {
  key <- match.arg(tolower(key), names(districts()))

  districts()[[key]]
}

#' The district the active `targets` project is for
#'
#' Project names are `_targets_dataprep_<district>` and `_targets_omniscape_<district>` (see
#' `_targets.yaml`), so the district is read from the active project rather than passed separately
#' -- one source of truth, and no way for a project to run against the wrong district's data.
#' Stripping a fixed prefix rather than a suffix keeps district keys containing underscores
#' (`hundred_mile`) unambiguous.
#'
#' @param project character active project name; defaults to `TAR_PROJECT`
#'
#' @returns list, as [district_spec()]
#'
#' @export
active_district <- function(project = Sys.getenv("TAR_PROJECT", "main")) {
  key <- sub("^_targets_(dataprep|omniscape)_", "", project)

  if (!key %in% names(districts())) {
    stop(
      "cannot determine the district from TAR_PROJECT=\"",
      project,
      "\".\nExpected `_targets_dataprep_<district>` or `_targets_omniscape_<district>`, ",
      "with district one of: ",
      paste(names(districts()), collapse = ", ")
    )
  }

  district_spec(key)
}

#' Is the resolution-equivalence study enabled?
#'
#' The 30 m series exists only to support the 30 m against 90 m comparison, and it is the most
#' expensive thing this pipeline can be asked to do. The 30 m regional Omniscape configuration
#' (radius 1429, block size 143) took **196.7 h -- 8.2 days -- at 64 threads**, finishing
#' 2026-09-12; the same configuration at 90 m (radius 477, block size 49) took 11 h 07 m at 16
#' threads and peaked at 33.2 GB. The comparison has been made and written up
#' (`reports/resolution-equivalence.qmd`), so the series is off unless it is asked for.
#'
#' Kept as a gate rather than deleted because the question can reopen -- a district unlike Quesnel,
#' or a change to the category cut-offs, would need the comparison redone rather than cited.
#'
#' @param flag character; defaults to `BC_CONN_RESOLUTION_STUDY`. `"1"`, `"true"` or `"yes"`,
#'   case-insensitive, enables it; anything else, including unset, does not.
#'
#' @returns `TRUE` if a district's `study_agg_factors` should be built instead of its production
#'   resolutions
#'
#' @export
resolution_study_enabled <- function(flag = Sys.getenv("BC_CONN_RESOLUTION_STUDY", "")) {
  tolower(trimws(flag)) %in% c("1", "true", "yes")
}

#' Should a district measure its own interpatch distances?
#'
#' The chain that measures them is the expensive half of the data preparation -- 97.8 h over
#' 2.33 billion pairs on Quesnel -- and everything downstream reads just two numbers out of it,
#' which [reference_distances()] records. So no district measures them by default, and the
#' `else` branch in `dataprep_targets()` substitutes the constants.
#'
#' `BC_CONN_INTERPATCH_DISTANCES=1` measures them for whichever district is being built. On
#' Quesnel that regenerates the recorded values; on another district it produces that district's
#' own, which the pipeline does not otherwise use.
#'
#' @param district character district key, or a spec from [district_spec()]
#'
#' @returns `TRUE` if the interpatch-distance chain should be built
#'
#' @export
district_interpatch_distances <- function(district) {
  spec <- if (is.list(district)) district else district_spec(district)

  override <- Sys.getenv("BC_CONN_INTERPATCH_DISTANCES", "")

  if (nzchar(override)) {
    return(tolower(trimws(override)) %in% c("1", "true", "yes"))
  }

  isTRUE(spec$interpatch_distances)
}

#' Aggregation factors -- i.e. resolutions -- a district's rasters are built at
#'
#' The source landcover layer is 30 m, so factor 1 is 30 m and factor 3 is 90 m.
#'
#' **This is where the resolution conditional lives, and it is the only place it needs to live.**
#' Every raster target downstream branches over `agg_fact_lcc`, so what this returns decides the
#' whole graph -- the aggregated landcover, the resistance and source-weight rasters, the Omniscape
#' configurations, and the runs. No `if` is needed in any project script, which is what stops the
#' conditional drifting between districts.
#'
#' **Every district is 90 m.** Two ways to ask for something else, in precedence order:
#'
#' - `BC_CONN_AGG_FACTORS` sets the factors directly and applies to whichever district is being
#'   built, e.g. `"1 3"` for both resolutions or `"1"` for 30 m alone.
#' - `BC_CONN_RESOLUTION_STUDY=1` builds each district's `study_agg_factors`, the pair the
#'   resolution-equivalence study compared. Only Quesnel declares one; for every other district
#'   this changes nothing, so the flag can be left set across a multi-district run.
#'
#' Both are read where the pipeline is *defined* and passed in as arguments, so the factories can
#' bake their values into the `agg_fact_lcc` command with `!!`. That makes a flag part of the
#' target's identity: changing one changes the command text and invalidates the target, and so does
#' changing it back. An earlier version read the environment inside the command and carried an
#' always-cue instead, which invalidated in one direction only and made `tar_outdated()` report the
#' whole downstream raster chain -- 22 targets -- as outdated forever, destroying the completion
#' signal the rebuild drivers print.
#'
#' @param district character district key, or a spec from [district_spec()]
#' @param override value of `BC_CONN_AGG_FACTORS`; `""` for unset.
#' @param study whether the resolution study is enabled, as [resolution_study_enabled()].
#'
#' @returns numeric vector of aggregation factors
#'
#' @export
district_agg_factors <- function(
  district,
  override = Sys.getenv("BC_CONN_AGG_FACTORS", ""),
  study = resolution_study_enabled()
) {
  spec <- if (is.list(district)) district else district_spec(district)

  if (nzchar(override)) {
    return(as.numeric(strsplit(override, "[ ,]+")[[1]]))
  }

  if (isTRUE(study) && !is.null(spec$study_agg_factors)) {
    return(spec$study_agg_factors)
  }

  spec$agg_factors
}

#' Interpatch-distance quantiles the Omniscape radii are pinned to
#'
#' Measured on Quesnel and held fixed for every district. The radius is a property of the
#' connectivity question rather than of an administrative boundary, so pinning it keeps runs
#' comparable between districts and epochs -- and it removes the single most expensive step in the
#' pipeline from every district. Quesnel's interpatch distances took 97.8 h over 2.33 billion
#' pairs, and pair count grows with the SQUARE of patch count, so a district 2.4x the area would
#' be several times that again.
#'
#' **Quesnel now reads these too**, rather than re-measuring them, so no district recomputes the
#' chain by default. The values below reproduce the frozen store's to the pixel: the archive holds
#' 42856.7467339 m and 2566.8030443 m, and `write_omniscape_config()` rounds to the metre and then
#' takes `ceiling(m / pixel_size)`, giving 477 px and 29 px at 90 m from either. `test-districts.R`
#' pins that against the archive.
#'
#' **The cost of pinning is that nothing recomputes them if patch construction changes.** Until
#' 2026-09-14 Quesnel was the canary -- it re-measured, and a patch-construction change would have
#' moved the radii. Now a change of that kind moves every district's patches while the radii stay
#' put. If patch construction moves, re-measure with `BC_CONN_INTERPATCH_DISTANCES=1` on Quesnel
#' and update the table below.
#'
#' Values are from the corrected 2026-08-26 Quesnel build, NOT the published pre-2026-08-25 one --
#' the patch-construction fix moved both. Only the two quantiles the configurations actually read
#' are recorded, because `write_omniscape_config()` indexes `patch_distances[[paste0(q, "%")]]`:
#'
#' | series                     | q    | distance   | px @30 m | px @90 m |
#' | -------------------------- | ---- | ---------- | -------- | -------- |
#' | all-pairs (regional)       | 25%  | 42,857 m   | 1429     | 477      |
#' | nearest-neighbour (local)  | 100% |  2,567 m   |   86     |  29      |
#'
#' @returns named list of named numeric vectors, in metres
reference_distances <- function() {
  list(
    all_dists = c("25%" = 42857),
    nn_dists = c("100%" = 2566.803)
  )
}
