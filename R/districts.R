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
      ## 30 m AND 90 m: Quesnel is the reference landscape for the resolution-equivalence study,
      ## which is the only thing the 30 m series exists for.
      agg_factors = c(1, 3)
    ),
    chilcotin = list(
      key = "chilcotin",
      district_name = "Cariboo-Chilcotin Natural Resource District",
      label = "Cariboo-Chilcotin",
      agg_factors = 3
    ),
    hundred_mile = list(
      key = "hundred_mile",
      district_name = "100 Mile House Natural Resource District",
      label = "100 Mile House",
      agg_factors = 3
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

#' Aggregation factors -- i.e. resolutions -- a district's rasters are built at
#'
#' The source landcover layer is 30 m, so factor 1 is 30 m and factor 3 is 90 m.
#'
#' **This is where the 30 m conditional lives, and it is the only place it needs to live.** Every
#' raster target downstream branches over `agg_fact_lcc`, so dropping 30 m here removes it from the
#' entire graph -- the resistance and source-weight rasters, the Omniscape configurations, and the
#' runs. No `if` is needed in any project script, which is what stops the conditional drifting
#' between districts.
#'
#' Only Quesnel builds 30 m, and only for the resolution-equivalence study. The Quesnel historical
#' comparison and every other district are 90 m. `BC_CONN_AGG_FACTORS` overrides, e.g. `"3"` to run
#' Quesnel at 90 m only.
#'
#' @param district character district key, or a spec from [district_spec()]
#'
#' @returns numeric vector of aggregation factors
#'
#' @export
district_agg_factors <- function(district) {
  spec <- if (is.list(district)) district else district_spec(district)

  override <- Sys.getenv("BC_CONN_AGG_FACTORS", "")

  if (nzchar(override)) {
    return(as.numeric(strsplit(override, "[ ,]+")[[1]]))
  }

  spec$agg_factors
}
