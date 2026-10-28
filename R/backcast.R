## Back-cast stand age to a historical epoch (plan §D, task D2).
##
## The current condition classifies CEF's `SIFA` -- stand age as of the layer's 2024 compilation --
## into seral stages. An epoch is built the same way from an *epoch* `SIFA`, so everything from
## `create_forest_disturbance_seral()` onwards runs unchanged; only the age going in differs.
##
## Per polygon, with `shift = data_year - epoch`:
##
## | case | age at the epoch | `age_source` |
## |---|---|---|
## | no stand-replacing disturbance on record | `SIFA - shift` | `undisturbed` |
## | the most recent stand-replacing disturbance (`MRSRD_Y`) is at or before the epoch | `SIFA - shift`, floored at 0 | `reset_by_epoch` |
## | `MRSRD_Y` is after the epoch, and an earlier reset in `DSTRB_HIST` is at or before it | `epoch - year` of the latest such reset | `earlier_reset` |
## | `MRSRD_Y` is after the epoch, and VRI still holds the pre-disturbance age (more than `vri_update_tolerance` over the years since it) | `PROJ_AGE_1 - shift` | `vri_pre_disturbance` |
## | otherwise: the age before the disturbance is not recorded | `lost_age` | `lost` |
##
## `replaced_year` records, for `lost` rows, the year the unrecorded stand was replaced, which is
## what `impute_lost_age()` needs.
##
## `MRSRD_Y` is CEF's own reset decision, and it is taken as authoritative for the latest reset: an
## event after it was judged by CEF not to replace the stand (e.g. `2011_IBM_V` on a stand cut in
## 2007), so at any epoch from 2007 on that stand dates from 2007. `reset_rule` is applied only when
## `MRSRD_Y` is after the epoch, to events at or before it -- which are necessarily before `MRSRD_Y`,
## where CEF has recorded no judgement. An undisturbed stand younger than `shift` initiated after the epoch without a
## recorded cause, and is `lost` too.
##
## Taking `SIFA - shift` rather than `epoch - MRSRD_Y` keeps the 2024 state identical to the
## current condition: where VRI was updated for a harvest, `SIFA` is the VRI age, which allows for
## regeneration delay and so can be less than `2024 - MRSRD_Y`.
backcast_age <- function(
  x,
  epoch,
  data_year = 2024,
  reset_rule = cef_reset_rule(),
  vri_update_tolerance = 10,
  lost_age = NA_real_
) {
  stopifnot(
    length(epoch) == 1L,
    epoch <= data_year,
    length(lost_age) %in% c(1L, nrow(x))
  )

  shift <- data_year - epoch
  sifa <- x$SIFA
  mrsrd <- x$MRSRD_Y
  has_reset <- !is.na(mrsrd) & mrsrd > 0

  age <- rep(NA_real_, nrow(x))
  src <- rep(NA_character_, nrow(x))
  lost_age <- rep_len(as.numeric(lost_age), nrow(x))

  ## no reset on record, or the reset predates the epoch: shift the current age back
  undisturbed <- !has_reset & !is.na(sifa)
  age[undisturbed] <- sifa[undisturbed] - shift
  src[undisturbed] <- "undisturbed"

  by_epoch <- has_reset & mrsrd <= epoch & !is.na(sifa)
  age[by_epoch] <- pmax(sifa[by_epoch] - shift, 0)
  src[by_epoch] <- "reset_by_epoch"

  ## reset after the epoch: the age at the epoch is the age of the stand that reset replaced
  after <- which(has_reset & mrsrd > epoch & !is.na(sifa))
  if (length(after) > 0L) {
    earlier <- latest_reset(x$DSTRB_HIST[after], epoch = epoch, reset_rule = reset_rule)
    hit <- !is.na(earlier)
    age[after[hit]] <- epoch - earlier[hit]
    src[after[hit]] <- "earlier_reset"

    ## VRI is often not updated for fire or beetle, so its age is still the pre-disturbance one.
    ## Where it *was* updated, its age is the regenerating stand's, which can exceed the years since
    ## disturbance by the planting-stock age: measured on Cariboo-Chilcotin harvest, the updated
    ## population peaks at 2 years *under* and tails off by ~6 over, then falls to a flat ~1,000 ha
    ## per year of genuine pre-harvest ages. An age within `vri_update_tolerance` of the years since
    ## disturbance is therefore read as updated, not kept.
    rest <- after[!hit]
    pre <- x$PROJ_AGE_1[rest]
    kept <- !is.na(pre) &
      pre > data_year - mrsrd[rest] + vri_update_tolerance &
      pre - shift >= 0
    age[rest[kept]] <- pre[kept] - shift
    src[rest[kept]] <- "vri_pre_disturbance"
  }

  lost <- (is.na(src) & has_reset & !is.na(sifa)) | (undisturbed & age < 0)
  age[lost] <- lost_age[lost]
  src[lost] <- "lost"

  ## the year the unrecorded stand was replaced: the reset, or for an undisturbed stand younger
  ## than `shift`, its initiation
  replaced <- rep(NA_real_, nrow(x))
  replaced[lost] <- dplyr::if_else(has_reset[lost], mrsrd[lost], data_year - sifa[lost])

  x$SIFA <- age
  x$age_source <- src
  x$replaced_year <- replaced
  x
}

## Stand-replacing agent and severity combinations, as CEF applies them in `MRSRD_*`: every harvest,
## fire at moderate or high severity, beetle at very severe. Read off the layer (plan §D.0); an
## entry without a severity matches every severity of that agent.
cef_reset_rule <- function() {
  c("CUT", "BRN_M", "BRN_H", "IBM_V")
}

## Split `DSTRB_HIST` into one row per event. Events are comma-separated `YEAR_AGENT_SEVERITY_SOURCE`
## tokens, e.g. `2011_IBM_V_VRI,2007_CUT_N_VRI`; `id` is the position in `x`. Some beetle events are
## undated (`NA_IBM_V_VRI`, 285 in Cariboo-Chilcotin); they parse with `year = NA` and so can never
## be placed before an epoch.
parse_disturbance_history <- function(x) {
  tokens <- strsplit(dplyr::coalesce(x, ""), ",", fixed = TRUE)
  id <- rep(seq_along(tokens), lengths(tokens))
  tokens <- trimws(unlist(tokens, use.names = FALSE))

  m <- regmatches(tokens, regexec("^([0-9]{4}|NA)_([A-Z]+)_([A-Z]+)_(.+)$", tokens))
  ok <- lengths(m) == 5L
  if (any(!ok & nzchar(tokens))) {
    warning(
      sum(!ok & nzchar(tokens)),
      " DSTRB_HIST event(s) not of the form YEAR_AGENT_SEVERITY_SOURCE; ignored",
      call. = FALSE
    )
  }
  m <- do.call(rbind, m[ok])
  if (is.null(m)) {
    m <- matrix(character(0), ncol = 5L)
  }

  data.frame(
    id = id[ok],
    year = suppressWarnings(as.integer(m[, 2])),
    agent = m[, 3],
    severity = m[, 4],
    source = m[, 5]
  )
}

## The year of the latest event matching `reset_rule` at or before `epoch`; NA where there is none.
latest_reset <- function(history, epoch, reset_rule) {
  ev <- parse_disturbance_history(history)
  is_reset <- ev$agent %in% reset_rule | paste(ev$agent, ev$severity, sep = "_") %in% reset_rule
  ev <- ev[is_reset & !is.na(ev$year) & ev$year <= epoch, , drop = FALSE]

  out <- rep(NA_integer_, length(history))
  if (nrow(ev) > 0L) {
    latest <- tapply(ev$year, ev$id, max)
    out[as.integer(names(latest))] <- as.integer(latest)
  }
  out
}

# Lost pre-disturbance ages (plan §D, task D2a) ----------------------------------------------------

## Ages at disturbance where VRI genuinely kept the pre-disturbance age: the donors for
## `impute_lost_age()`. `x` needs `NDT_BEC`, `MRSRD_A`, `MRSRD_Y`, `PROJ_AGE_1` and an area column.
## Only disturbances from `since` on are used -- the period whose lost ages are being filled.
donor_ages <- function(
  x,
  weight = "ha",
  since = 2005,
  data_year = 2024,
  vri_update_tolerance = 10
) {
  since_dist <- data_year - x$MRSRD_Y
  ok <- !is.na(x$MRSRD_Y) &
    x$MRSRD_Y >= since &
    !is.na(x$PROJ_AGE_1) &
    !is.na(x$NDT_BEC) &
    x$PROJ_AGE_1 > since_dist + vri_update_tolerance

  data.frame(
    NDT_BEC = x$NDT_BEC[ok],
    agent = x$MRSRD_A[ok],
    age = x$PROJ_AGE_1[ok] - since_dist[ok],
    weight = x[[weight]][ok]
  )
}

## Fill `lost` ages from the observed distribution of age at disturbance.
##
## A lost stand replaced in `replaced_year` is given a donor's age at disturbance, less the years
## between the epoch and the replacement, floored at 0. Donors are matched on (`NDT_BEC`, agent); a
## group with fewer than `min_donors` falls back to `NDT_BEC` alone, then to every donor.
##
## `method = "draw"` samples one donor per polygon, area-weighted, so the filled ages follow the
## donor distribution -- which is what seral-class areas depend on. `method = "quantile"` gives every
## polygon in a group the area-weighted `prob` quantile, for bounding runs (e.g. 0.1 and 0.9).
impute_lost_age <- function(
  x,
  epoch,
  donors,
  method = c("draw", "quantile"),
  prob = 0.5,
  seed = epoch,
  min_donors = 30L
) {
  method <- match.arg(method)
  lost <- which(x$age_source %in% "lost")
  if (length(lost) == 0L) {
    return(x)
  }

  key_full <- paste(donors$NDT_BEC, donors$agent)
  n_full <- table(key_full)
  n_bec <- table(donors$NDT_BEC)

  want_full <- paste(x$NDT_BEC[lost], x$MRSRD_A[lost])
  group <- dplyr::case_when(
    want_full %in% names(n_full)[n_full >= min_donors] ~ want_full,
    x$NDT_BEC[lost] %in% names(n_bec)[n_bec >= min_donors] ~ x$NDT_BEC[lost],
    .default = "<all>"
  )
  pool <- function(g) {
    if (g == "<all>") {
      return(donors)
    }
    donors[if (grepl(" ", g, fixed = TRUE)) key_full == g else donors$NDT_BEC == g, , drop = FALSE]
  }

  at_replacement <- rep(NA_real_, length(lost))
  withr::with_seed(seed, {
    for (g in sort(unique(group))) {
      i <- which(group == g)
      d <- pool(g)
      at_replacement[i] <- if (method == "draw") {
        d$age[sample.int(nrow(d), length(i), replace = TRUE, prob = d$weight)]
      } else {
        weighted_quantile(d$age, d$weight, prob)
      }
    }
  })

  x$SIFA[lost] <- pmax(at_replacement - (x$replaced_year[lost] - epoch), 0)
  x$age_source[lost] <- "imputed"
  x
}

## The smallest `v` whose cumulative weight reaches `prob` of the total.
weighted_quantile <- function(v, w, prob) {
  o <- order(v)
  v[o][which(cumsum(w[o]) >= prob * sum(w))[1]]
}

# Epoch targets (plan §D, task D4) ---------------------------------------------------------------

## Which historical epochs to build, from `BC_CONN_EPOCHS`: unset or empty builds none, `"all"` builds
## 2005, 2010, 2015 and 2020, and a comma-separated list builds those. 2025 is the current condition
## (plan §D.3a) and is never an epoch. Off by default because each epoch re-runs the patch chain,
## ~16 h on Cariboo-Chilcotin.
historical_epochs <- function(flag = Sys.getenv("BC_CONN_EPOCHS", "")) {
  flag <- tolower(trimws(flag))
  if (!nzchar(flag)) {
    return(integer(0))
  }
  if (flag == "all") {
    return(c(2005L, 2010L, 2015L, 2020L))
  }

  epochs <- suppressWarnings(as.integer(trimws(strsplit(flag, ",", fixed = TRUE)[[1]])))
  if (anyNA(epochs) || any(epochs >= 2024L)) {
    stop("BC_CONN_EPOCHS must be \"all\" or years before 2024, e.g. \"2005,2010\"", call. = FALSE)
  }
  sort(unique(epochs))
}

## The forest disturbance layer overlaid with VRI-NDT-BEC, carrying the disturbance history rather
## than a seral stage: the epoch-independent half of `create_forest_disturbance_seral()`, built once
## and classified per epoch by `create_forest_disturbance_seral_epoch()`.
##
## `PROJ_AGE_1` comes from the CEF layer, which carries VRI's, so the VRI read leaves it out rather
## than producing two columns of the same name.
create_forest_disturbance_history <- function(for_dist_gpkg, vri_gpkg, tile) {
  aoi <- tidyterra::as_spatvector(tile)

  fd <- spatialutils::read_vector_aoi(
    for_dist_gpkg,
    aoi,
    fields = c("SIFA", "PROJ_AGE_1", "DSTRB_HIST", "MRSRD_Y", "MRSRD_A")
  )
  vri <- spatialutils::read_vector_aoi(
    vri_gpkg,
    aoi,
    fields = c("NDT_BEC", "BEC_ZONE", "SPECIES_CD_1", "LEADING_GRP")
  )

  if (nrow(fd) == 0L || nrow(vri) == 0L) {
    return(fd[integer(0)])
  }

  fd <- terra::crop(fd, aoi) |> spatialutils::repair_geoms()
  v <- spatialutils::intersect_relate(fd, vri) |> spatialutils::repair_geoms()

  if (nrow(v) == 0L) {
    return(v)
  }

  v$ha <- spatialutils::expanse_planar(v) / 1e4
  v
}

## One tile's seral layer at `epoch`: back-cast the age, fill the ages CEF does not record, then
## classify exactly as `create_forest_disturbance_seral()` does for the current condition.
##
## The oldest class is closed at the larger of `max_age` and the tile's oldest epoch age: a
## back-cast from VRI's pre-disturbance age can exceed the current condition's maximum `SIFA`, and
## an age past the last class's upper bound would match no class at all.
create_forest_disturbance_seral_epoch <- function(
  history,
  epoch,
  donors,
  max_age,
  tile,
  lost_method = "draw",
  lost_prob = 0.5
) {
  v <- history
  if (nrow(v) == 0L) {
    return(v)
  }

  x <- backcast_age(terra::as.data.frame(v), epoch = epoch)
  x <- impute_lost_age(
    x,
    epoch,
    donors,
    method = lost_method,
    prob = lost_prob,
    seed = epoch * 100L + tile$tile[[1]]
  )

  max_age <- max(max_age, x$SIFA, na.rm = TRUE)
  seral <- x |>
    dplyr::left_join(
      seral_stages_long(max_age),
      by = dplyr::join_by(NDT_BEC, dplyr::between(SIFA, Age_Min, Age_Max, bounds = "[)")),
      relationship = "many-to-one"
    )

  v$SIFA <- x$SIFA
  v$age_source <- x$age_source
  v |>
    dplyr::mutate(
      Seral = !!seral$Seral,
      early_less_20yrs = dplyr::if_else(SIFA < 20, "under_20", NA_character_)
    )
}
