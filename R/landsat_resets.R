## Stand-replacing disturbance CEF does not record, from Landsat (plan section D.4).
##
## CEF's Forest Disturbance layer has no fire severity before 2015 anywhere inside Quesnel, 100 Mile
## House or Cariboo-Chilcotin: its 1985-2014 product (FSG) stops at the district edges. A stand that
## burned in that period therefore keeps its pre-fire `SIFA`. Measured against CanLaD, that is 19 kha
## in Quesnel, 5 kha in 100 Mile House and 117 kha in Cariboo-Chilcotin; severe insect mortality CEF
## does not record adds 14, 4 and 23 kha.
##
## Two national 30 m products fill the gap:
##
## * CanLaBS v2 -- dNBR for every NBAC-burned pixel, 1985-2024, with NBAC's fire year. A fire is
##   stand-replacing at dNBR >= 270: the threshold that reproduces CEF's moderate + high severity
##   area (the `BRN_M`/`BRN_H` of `cef_reset_rule()`) on the 2015-2024 fires both record, at 85-87%
##   pixel agreement in all three districts, and 89-90% against CEF's 1985-2014 severities in the
##   buffers where those exist. Salvage-logged pixels are stand-replacing whatever their dNBR.
## * CanLaD v1.1 -- annual disturbance class, 1985-2024. Where CanLaBS has no dNBR (Landsat gaps,
##   6.9% of NBAC pixels nationally; or the earlier fire of a reburn, since CanLaBS keeps one value
##   per pixel), a CanLaD fire detection counts as stand-replacing. High-severity defoliation
##   (class 8) counts as insect mortality: in these districts that is overwhelmingly mountain pine
##   beetle, but CanLaD does not name the agent, so it is recorded as `INS`, not CEF's `IBM`.
##
## The events become polygons (`landsat_reset_polygons()`), are overlaid onto the CEF layer per tile,
## and are merged into each piece's history by `apply_landsat_resets()`, which defers to CEF wherever
## CEF records the same event. Everything downstream reads `SIFA`, `MRSRD_*` and `DSTRB_HIST` as
## before.

## The stand-replacing events `apply_landsat_resets()` adds: fire (`BRN_R`, severity not classed) and
## insect mortality (`INS_H`). Both always reset; they are only ever recorded when they do.
landsat_reset_rule <- function() {
  c("BRN_R", "INS_H")
}

## Every reset combination the back-cast honours: CEF's own, plus the Landsat events.
stand_reset_rule <- function() {
  c(cef_reset_rule(), landsat_reset_rule())
}

## The CanLaD and CanLaBS rasters out of what `prefetch_shared_inputs()` fetched, as one character
## vector in `LANDSAT_DISTURBANCE` order, so a `format = "file"` target tracks them all.
landsat_disturbance_files <- function(shared_inputs) {
  unname(vapply(
    names(landsat_input_sources()),
    function(which) shared_input_path(shared_inputs, which),
    character(1)
  ))
}

## Collapse repeated detections into events: the years of one pixel that fall within `gap` years
## of the previous one are a single event, dated by its first year. CanLaD flags defoliation year
## after year through an outbreak, and a fire can show in two consecutive years; neither is a
## second stand replacement. `cell` and `year` are parallel vectors.
first_of_runs <- function(cell, year, gap) {
  o <- order(cell, year)
  cell <- cell[o]
  year <- year[o]
  new_run <- c(TRUE, cell[-1] != cell[-length(cell)] | diff(year) > gap)[seq_along(cell)]
  data.frame(cell = cell[new_run], year = year[new_run])
}

## Per-pixel stand-replacing events on the CanLaD/CanLaBS grid.
##
## `canlad` has one layer per year in `years`; `dnbr`, `nbac` and `salvage` are CanLaBS's three
## single layers, on the same grid. Returns one row per event: `cell`, `year`, `agent` (`BRN` or
## `INS`).
##
## Fire, for a pixel NBAC dates to year `Y`:
##   * dNBR >= `dnbr_threshold`, or salvage-logged -> a fire in `Y`;
##   * no dNBR -> a fire in `Y` if CanLaD detects fire within one year of it;
##   * dNBR below the threshold -> no fire in `Y`.
## A CanLaD fire more than a year from `Y` -- or on a pixel NBAC never burned -- is another fire,
## counted as stand-replacing: CanLaBS has no severity for it.
landsat_reset_cells <- function(
  dnbr,
  nbac,
  salvage,
  canlad,
  years = 1985:2024,
  dnbr_threshold = 270,
  insect_gap = 2
) {
  stopifnot(
    terra::nlyr(canlad) == length(years),
    terra::compareGeom(dnbr, nbac),
    terra::compareGeom(dnbr, salvage),
    terra::compareGeom(dnbr, canlad)
  )

  ## CanLaD fire (1) and high-severity defoliation (8), one row per detection
  det <- do.call(
    rbind,
    lapply(seq_along(years), function(i) {
      v <- terra::values(canlad[[i]], mat = FALSE)
      cell <- which(v %in% c(1L, 8L))
      data.frame(cell = cell, year = rep(years[i], length(cell)), class = v[cell])
    })
  )
  is_fire <- det$class == 1L
  lad_fire <- first_of_runs(det$cell[is_fire], det$year[is_fire], gap = 1L)
  insect <- first_of_runs(det$cell[!is_fire], det$year[!is_fire], gap = insect_gap)

  fy <- terra::values(nbac, mat = FALSE)
  burned <- which(!is.na(fy) & fy >= min(years) & fy <= max(years))
  nb <- data.frame(
    cell = burned,
    year = fy[burned],
    dnbr = terra::values(dnbr, mat = FALSE)[burned],
    salvage = terra::values(salvage, mat = FALSE)[burned] %in% 1L
  )

  ## CanLaD fires within a year of the NBAC fire are that fire; the rest are other fires
  m <- merge(lad_fire, nb[, c("cell", "year")], by = "cell", suffixes = c("", "_nbac"))
  same <- abs(m$year - m$year_nbac) <= 1L
  nb$lad_near <- nb$cell %in% m$cell[same]
  other <- lad_fire[!paste(lad_fire$cell, lad_fire$year) %in% paste(m$cell, m$year)[same], ]

  replaced <- nb$salvage | ifelse(is.na(nb$dnbr), nb$lad_near, nb$dnbr >= dnbr_threshold)
  fire <- rbind(nb[replaced, c("cell", "year")], other)

  out <- rbind(
    data.frame(fire, agent = rep("BRN", nrow(fire))),
    data.frame(insect, agent = rep("INS", nrow(insect)))
  )
  out <- out[!duplicated(out), ]
  out <- out[order(out$cell, out$year, out$agent), ]
  rownames(out) <- NULL
  out
}

## Turn per-pixel events into polygons carrying a `RESET_HIST` of `YEAR_AGENT_SEVERITY_LS` tokens.
##
## Each (year, agent) layer is sieved on its own before the layers are combined: clumps smaller than
## `min_cells` (8-connected) are dropped and holes that small are filled, so a single misclassified
## pixel neither starts nor stops a disturbance. Sieving the combined layer instead would merge a
## pixel's whole history into its neighbour's, inventing events at the edge of every overlap.
landsat_reset_polygons <- function(events, template, min_cells = 11L) {
  template <- terra::rast(template, nlyrs = 1)
  key <- paste(events$year, events$agent)

  kept <- lapply(split(events$cell, key), function(cells) {
    rc <- terra::rowColFromCell(template, cells)
    ## sieve only the window holding this layer, padded so a clump at its edge sees its neighbours
    r0 <- max(1L, min(rc[, 1]) - 2L)
    r1 <- min(nrow(template), max(rc[, 1]) + 2L)
    c0 <- max(1L, min(rc[, 2]) - 2L)
    c1 <- min(ncol(template), max(rc[, 2]) + 2L)
    win <- terra::rast(
      nrows = r1 - r0 + 1L,
      ncols = c1 - c0 + 1L,
      ext = terra::ext(template, cells = terra::cellFromRowCol(template, c(r0, r1), c(c0, c1))),
      crs = terra::crs(template),
      vals = 0L
    )
    win[terra::cellFromRowCol(win, rc[, 1] - r0 + 1L, rc[, 2] - c0 + 1L)] <- 1L
    win <- terra::sieve(win, threshold = min_cells, directions = 8)
    on <- which(terra::values(win, mat = FALSE) == 1L)
    rcw <- terra::rowColFromCell(win, on)
    terra::cellFromRowCol(template, rcw[, 1] + r0 - 1L, rcw[, 2] + c0 - 1L)
  })

  sev <- c(BRN = "R", INS = "H")
  parts <- strsplit(names(kept), " ", fixed = TRUE)
  ev <- data.frame(
    cell = unlist(kept, use.names = FALSE),
    year = rep(as.integer(vapply(parts, `[[`, "", 1)), lengths(kept)),
    agent = rep(vapply(parts, `[[`, "", 2), lengths(kept))
  )
  ev$token <- sprintf("%d_%s_%s_LS", ev$year, ev$agent, sev[ev$agent])

  ## one history per pixel, most recent event first as in CEF's `DSTRB_HIST`
  ev <- ev[order(ev$cell, -ev$year, ev$token), ]
  hist <- tapply(ev$token, ev$cell, paste, collapse = ",")
  codes <- factor(hist)
  r <- terra::rast(template, vals = NA_integer_)
  if (length(hist) > 0L) {
    r[as.integer(names(hist))] <- as.integer(codes)
  }

  v <- terra::as.polygons(r, dissolve = TRUE, values = TRUE, na.rm = TRUE)
  names(v) <- "code"
  v <- terra::disagg(v)
  v$RESET_HIST <- levels(codes)[v$code]
  v[, "RESET_HIST"]
}

## Build the district's reset polygons from the national rasters and write them as a GeoPackage.
##
## Works on CanLaD's own grid and projects only the finished polygons: resampling a categorical
## 30 m raster to the project CRS would move pixels, and with them the edges of every disturbance.
write_landsat_resets <- function(
  files,
  study_area,
  crs,
  dst,
  years = 1985:2024,
  dnbr_threshold = 270,
  min_ha = 1
) {
  pick <- function(f) files[match(f, basename(files))]
  lbs <- LANDSAT_DISTURBANCE$canlabs$files
  dnbr <- terra::rast(pick(lbs[["canlabs_dnbr"]]))

  aoi <- terra::vect(study_area) |> terra::project(terra::crs(dnbr))
  grab <- function(f) terra::crop(terra::rast(f), aoi, snap = "out")
  dnbr <- grab(pick(lbs[["canlabs_dnbr"]]))
  outside <- is.na(terra::rasterize(aoi, dnbr))
  canlad <- grab(pick(LANDSAT_DISTURBANCE$canlad$files[match(years, 1985:2024)]))

  events <- landsat_reset_cells(
    dnbr = dnbr,
    nbac = terra::mask(grab(pick(lbs[["canlabs_nbac"]])), outside, maskvalues = TRUE),
    salvage = grab(pick(lbs[["canlabs_salvage"]])),
    canlad = terra::mask(canlad, outside, maskvalues = TRUE),
    years = years,
    dnbr_threshold = dnbr_threshold
  )

  min_cells <- round(min_ha * 1e4 / prod(terra::res(dnbr)))
  v <- landsat_reset_polygons(events, dnbr, min_cells = min_cells) |>
    terra::project(terra::crs(crs))

  save_gpkg(v, dst)
}

## Read the reset polygons overlapping `aoi`, overlay them onto `fd`, and merge them into its
## history. `fd` must carry `SIFA`, `DSTRB_HIST`, `MRSRD_Y` and `MRSRD_A`. With no reset layer, `fd`
## is returned unchanged.
add_landsat_resets <- function(fd, resets_gpkg, aoi, ...) {
  if (is.null(resets_gpkg) || nrow(fd) == 0L) {
    return(fd)
  }

  resets <- spatialutils::read_vector_aoi(resets_gpkg, aoi, fields = "RESET_HIST")
  ## guard before cropping: an empty crop also loses its attribute columns
  if (nrow(resets) > 0L) {
    resets <- terra::crop(resets, aoi)
  }
  if (nrow(resets) == 0L) {
    return(fd)
  }

  v <- spatialutils::overlay_left_join(fd, resets) |> spatialutils::repair_geoms()
  x <- apply_landsat_resets(terra::as.data.frame(v), ...)
  for (col in c("SIFA", "DSTRB_HIST", "MRSRD_Y", "MRSRD_A")) {
    v[[col]] <- x[[col]]
  }
  v[, setdiff(names(v), "RESET_HIST")]
}

## Merge Landsat events (`RESET_HIST`) into CEF's record (`DSTRB_HIST`, `MRSRD_Y`, `MRSRD_A`,
## `SIFA`), one row per polygon piece.
##
## CEF wins wherever it records the event: a fire is dropped if CEF records any fire on the piece
## within a year of it (CEF's severity then decides), and insect mortality is dropped if CEF records
## a stand-replacing event in the two years before it or the year after. Insect mortality on a stand
## younger than `min_insect_age` at the time is dropped too: beetles do not kill regenerating stands,
## and CanLaD's defoliation classes pick up their spectral recovery. Events after `data_year` are
## outside the CEF layer's snapshot and are dropped.
##
## A kept event later than CEF's most recent stand-replacing disturbance becomes the new `MRSRD_Y` /
## `MRSRD_A`, and `SIFA` becomes the years since it, unless VRI already has the stand younger --
## CEF's own rule for `SIFA`.
apply_landsat_resets <- function(x, data_year = 2024L, min_insect_age = 30) {
  if (!"RESET_HIST" %in% names(x)) {
    return(x)
  }

  new <- parse_disturbance_history(x$RESET_HIST)
  new <- new[!is.na(new$year) & new$year <= data_year, , drop = FALSE]
  new$k <- seq_len(nrow(new))
  cef <- parse_disturbance_history(x$DSTRB_HIST)
  cef <- cef[!is.na(cef$year), , drop = FALSE]
  cef_reset <- cef[
    cef$agent %in%
      cef_reset_rule() |
      paste(cef$agent, cef$severity, sep = "_") %in% cef_reset_rule(),
    ,
    drop = FALSE
  ]

  ## `k` of the `ev` rows with a `ref` event on the same piece within [year + lo, year + hi]
  near <- function(ev, ref, lo, hi) {
    m <- merge(ev[, c("k", "id", "year")], data.frame(id = ref$id, ry = ref$year), by = "id")
    m$k[m$ry >= m$year + lo & m$ry <= m$year + hi]
  }
  fire <- new$agent == "BRN"
  drop <- c(
    near(new[fire, , drop = FALSE], cef[cef$agent == "BRN", , drop = FALSE], -1L, 1L),
    near(new[!fire, , drop = FALSE], cef_reset, -2L, 1L)
  )
  new <- new[!new$k %in% drop, , drop = FALSE]

  ## insect mortality needs a stand old enough to kill: its age is the years since the latest reset
  ## before the event; with no reset either side of it, `SIFA` taken back to the event year; with
  ## only later resets, the age then is not recorded, and the event is kept
  ins <- new[new$agent == "INS", , drop = FALSE]
  if (nrow(ins) > 0L) {
    resets <- rbind(cef_reset[, c("id", "year")], new[new$agent == "BRN", c("id", "year")])
    m <- merge(ins[, c("k", "id", "year")], data.frame(id = resets$id, ry = resets$year), by = "id")
    prior <- m[m$ry < m$year, , drop = FALSE]
    before <- if (nrow(prior) > 0L) tapply(prior$ry, prior$k, max) else integer(0)
    age <- x$SIFA[ins$id] - (data_year - ins$year)
    age[ins$k %in% m$k[m$ry >= m$year]] <- NA
    hit <- match(as.character(ins$k), names(before))
    age[!is.na(hit)] <- ins$year[!is.na(hit)] - before[hit[!is.na(hit)]]
    young <- ins$k[!is.na(age) & age < min_insect_age]
    new <- new[!new$k %in% young, , drop = FALSE]
  }

  x$RESET_HIST <- NULL
  if (nrow(new) == 0L) {
    return(x)
  }

  ## history: CEF's tokens, then the kept Landsat ones
  tok <- paste(new$year, new$agent, new$severity, new$source, sep = "_")
  add <- tapply(tok, new$id, paste, collapse = ",")
  i <- as.integer(names(add))
  old <- dplyr::coalesce(x$DSTRB_HIST[i], "")
  x$DSTRB_HIST[i] <- ifelse(nzchar(old), paste(old, add, sep = ","), add)

  ## the latest kept event per piece; fire before insect in the same year
  new <- new[order(new$id, -new$year, new$agent), , drop = FALSE]
  latest <- new[!duplicated(new$id), , drop = FALSE]
  mrsrd <- x$MRSRD_Y[latest$id]
  latest <- latest[is.na(mrsrd) | mrsrd <= 0 | latest$year > mrsrd, , drop = FALSE]

  x$MRSRD_Y[latest$id] <- latest$year
  x$MRSRD_A[latest$id] <- latest$agent
  x$SIFA[latest$id] <- pmin(x$SIFA[latest$id], data_year - latest$year)
  x
}
