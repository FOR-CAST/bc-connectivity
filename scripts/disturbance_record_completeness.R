## Measure the temporal completeness of the CEF Forest Disturbance record.
##
## Supports the window rationale in docs/cariboo-historical-window.html: the reconstruction
## back-casts stand age from DSTRB_HIST, so the series can only reach as far back as the event
## record does. This measures how far back that is, per disturbance agent.
##
## One-off; not part of the targets pipeline. Run from the project root, under the R version
## renv.lock pins (4.5.3) so renv resolves the right library:
##   /opt/R/4.5.3/bin/Rscript scripts/disturbance_record_completeness.R

library(ggplot2)

## ---- configuration -------------------------------------------------------------------------

gdb <- file.path("Data", "raw", "BC_CEF_Forest_Disturbance_2024.gdb")
layer <- "BC_CEF_ForestDisturbance_2024"
out_dir <- file.path("Outputs", "record-completeness")

## Years to report. 1990-2010 brackets the FIDS-to-Province survey handover (post-1995), the
## documented 1996-1999 inconsistency, and the 1999-2015 mountain pine beetle epidemic.
years <- 1990:2010

## RAM control. OGR returns the geometry column even when the query does not select it: measured
## at 242 MB per 200k features against 2 MB for the attributes alone. Reading all 23.4M features
## in one call would hold ~28 GB. So read in chunks, tally each, and discard before the next --
## peak memory is one chunk regardless of layer size.
chunk_size <- 200000L

## Features to scan. NULL scans the whole layer (~7 min) and carries no sampling caveat. Set an
## integer for a quick pass, but note OGR applies LIMIT in file order, so a partial scan follows
## storage order and may be spatially clustered rather than random.
n_max <- NULL

## Agents present in MRSRD_A / DSTRB_HIST, in plotting order.
agents <- c(CUT = "Harvest", BRN = "Fire", IBM = "Mtn pine beetle", IBS = "Spruce beetle")

## Validated categorical hues (OKLab dE >= 15 for every pair, light and dark). Keyed by the
## DISPLAY label, because the scales below map by name: an unnamed vector is matched positionally
## against whichever levels a layer happens to contain, and the zeros layer has no Harvest rows,
## which silently shifted every zero-marker one hue.
agent_colours <- c(
  Harvest = "#2a78d6",
  Fire = "#eb6834",
  `Mtn pine beetle` = "#1baf7a",
  `Spruce beetle` = "#4a3aa7"
)

## Permanent id for BC Wildfire Fire Perimeters - Historical. bcdata warns that record names are
## not stable, so use the id.
fire_perimeters_id <- "22c7cb44-1463-48f7-8e47-88857f207702"

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

## ---- inputs --------------------------------------------------------------------------------

## The CEF Forest Disturbance layer is a Custom Product: not on the BC Data Catalogue, not
## available through bcdata, and not redistributable. Available on request from the data steward.
## Place it in Data/raw/; see the 'Data access' section of README.md.
if (!file.exists(gdb)) {
  stop(
    "Required input `",
    basename(gdb),
    "` not found at:\n  ",
    gdb,
    "\n\n",
    "This is a BC Cumulative Effects Framework Custom Product. It is not publicly distributed ",
    "and cannot be downloaded automatically.\n\n",
    "Available on request: contact Travis Heckford <Travis.Heckford@gov.bc.ca>, describing your ",
    "intended use.\nSee the 'Data access' section of README.md.\n\n",
    "(Project team members may already have it staged; see scripts/internal/.)"
  )
}

## ---- parse DSTRB_HIST ------------------------------------------------------------------------

## DSTRB_HIST is a comma-separated multi-event history, each event encoded
## YEAR_AGENT_SEVERITY_SOURCE, e.g. "2004_CUT_N_VRI,2003_BRN_M_FSG,1991_BRN_L_FSG".
## About 27% of polygons carry more than one event.
tally_events <- function(hist) {
  events <- unlist(strsplit(hist[!is.na(hist)], ",", fixed = TRUE), use.names = FALSE)
  if (length(events) == 0L) {
    return(NULL)
  }

  fields <- strsplit(events, "_", fixed = TRUE)
  year <- suppressWarnings(as.integer(vapply(fields, `[`, character(1), 1L)))
  agent <- vapply(fields, `[`, character(1), 2L)

  keep <- !is.na(year) & agent %in% names(agents)
  if (!any(keep)) {
    return(NULL)
  }

  as.data.frame(table(year = year[keep], agent = agent[keep]), stringsAsFactors = FALSE)
}

message("scanning ", layer, if (is.null(n_max)) " (whole layer)" else paste0(" (n = ", n_max, ")"))

tallies <- list()
n_polys <- 0L
n_events <- 0L
offset <- 0L

repeat {
  lim <- if (is.null(n_max)) chunk_size else min(chunk_size, n_max - n_polys)
  if (lim <= 0L) {
    break
  }

  query <- sprintf("SELECT DSTRB_HIST FROM %s LIMIT %d OFFSET %d", layer, lim, offset)
  chunk <- sf::st_read(gdb, query = query, quiet = TRUE)
  n <- nrow(chunk)
  if (n == 0L) {
    break
  }

  ## Drop geometry immediately -- it is ~99% of the chunk's footprint and is not used here.
  hist <- sf::st_drop_geometry(chunk)$DSTRB_HIST
  rm(chunk)

  tallied <- tally_events(hist)
  rm(hist)
  if (!is.null(tallied)) {
    tallies[[length(tallies) + 1L]] <- tallied
    n_events <- n_events + sum(tallied$Freq)
  }

  n_polys <- n_polys + n
  offset <- offset + n
  gc(verbose = FALSE)

  message(
    "  ",
    format(n_polys, big.mark = ","),
    " features | ",
    format(n_events, big.mark = ","),
    " events"
  )

  if (n < lim) break
}

## ---- assemble the year x agent grid ----------------------------------------------------------

counts <- do.call(rbind, tallies)
counts$year <- as.integer(counts$year)
counts <- aggregate(Freq ~ year + agent, data = counts, FUN = sum)

## Complete the grid so absent years are zeros rather than missing rows -- the distinction between
## "no events recorded" and "no row" is the whole point of the exercise.
grid <- expand.grid(year = years, agent = names(agents), stringsAsFactors = FALSE)
counts <- merge(grid, counts, by = c("year", "agent"), all.x = TRUE)
counts$Freq[is.na(counts$Freq)] <- 0L
names(counts)[names(counts) == "Freq"] <- "events"

## ---- cross-check: were there fires in the years CEF records none? ----------------------------

## The CEF fire record is empty 1998-2001. Fire perimeters are a separate, public, annual series
## going back to 1917 -- if it shows fires in those years, the CEF gap is a gap in the RECORD
## rather than an absence of fire. Province-wide, matching the scope of the scan above.
yr_min <- min(years)
yr_max <- max(years)

## The WFS is occasionally unavailable; one transient failure produced a silently NA-filled column
## on an earlier run. Retry before giving up, mirroring with_retries() in R/data_prep.R.
with_retries <- function(f, n = 3L, wait = 5) {
  for (i in seq_len(n)) {
    out <- tryCatch(f(), error = function(e) e)
    if (!inherits(out, "error")) {
      return(out)
    }
    if (i < n) {
      message("  attempt ", i, " failed (", conditionMessage(out), "); retrying in ", wait, "s")
      Sys.sleep(wait)
    }
  }
  stop(out)
}

fire_check <- tryCatch(
  {
    message("downloading BC historical fire perimeters (province-wide, ", yr_min, "-", yr_max, ")")

    ## Unquote the bounds: bcdata translates the filter to CQL and cannot evaluate calls in place.
    perims <- with_retries(function() {
      bcdata::bcdc_query_geodata(fire_perimeters_id) |>
        dplyr::filter(FIRE_YEAR >= !!yr_min, FIRE_YEAR <= !!yr_max) |>
        dplyr::select(FIRE_YEAR) |>
        dplyr::collect()
    })

    fc <- as.data.frame(table(year = perims$FIRE_YEAR), stringsAsFactors = FALSE)
    fc$year <- as.integer(fc$year)
    names(fc)[names(fc) == "Freq"] <- "fire_perimeters"
    rm(perims)

    merge(data.frame(year = years), fc, by = "year", all.x = TRUE) |>
      transform(fire_perimeters = ifelse(is.na(fire_perimeters), 0L, fire_perimeters))
  },
  error = function(e) {
    warning("fire-perimeter cross-check skipped: ", conditionMessage(e), call. = FALSE)
    data.frame(year = years, fire_perimeters = NA_integer_)
  }
)

## ---- tables ----------------------------------------------------------------------------------

wide <- reshape(counts, idvar = "year", timevar = "agent", direction = "wide", v.names = "events")
names(wide) <- sub("^events\\.", "", names(wide))
wide <- merge(wide, fire_check, by = "year", all.x = TRUE)
wide <- wide[order(wide$year), c("year", names(agents), "fire_perimeters")]

csv <- file.path(out_dir, "disturbance_record_by_year.csv")
utils::write.csv(wide, csv, row.names = FALSE)
message("wrote ", csv)

print(wide, row.names = FALSE)

## ---- figure ----------------------------------------------------------------------------------

## The headline finding, computed rather than asserted: the beetle record is not absent before the
## step, it is negligible. Derive the figures so the subtitle cannot drift from the data.
step_year <- 2003L
ibm <- counts[counts$agent == "IBM", ]
ibm_pre <- sum(ibm$events[ibm$year < step_year])
ibm_post <- sum(ibm$events[ibm$year >= step_year])

## Small multiples with independent y-scales: the comparison of interest is the SHAPE of each
## agent's record over time, not the height of one agent against another.
counts$agent <- factor(counts$agent, levels = names(agents), labels = agents)
zeros <- counts[counts$events == 0, ]

scanned <- if (is.null(n_max)) {
  paste0("All ", format(n_polys, big.mark = ","), " features scanned")
} else {
  paste0(format(n_polys, big.mark = ","), " features sampled")
}

gg <- ggplot(counts, aes(x = year, y = events, fill = agent)) +
  geom_col(width = 0.7) +
  ## Zero years get an explicit open marker so an absent record reads differently from a small one.
  geom_point(data = zeros, aes(colour = agent), shape = 21, fill = NA, size = 2.2, stroke = 0.8) +
  facet_wrap(vars(agent), ncol = 1, scales = "free_y", strip.position = "top") +
  scale_fill_manual(values = agent_colours, guide = "none") +
  scale_colour_manual(values = agent_colours, guide = "none") +
  scale_x_continuous(breaks = seq(yr_min, yr_max, by = 5), expand = expansion(c(0.02, 0.02))) +
  ## Plain thousands separators: the default switches to scientific notation on some panels and
  ## not others, so the four y-axes read in two different formats.
  scale_y_continuous(labels = scales::label_comma(), expand = expansion(c(0, 0.10))) +
  labs(
    title = "CEF disturbance record: events per year by agent",
    subtitle = paste0(
      "The beetle record is negligible before ",
      step_year,
      ": ",
      format(ibm_pre, big.mark = ","),
      " events across ",
      yr_min,
      "-",
      step_year - 1L,
      " against ",
      format(ibm_post, big.mark = ","),
      " from ",
      step_year,
      ".\n",
      scanned,
      "; ",
      format(n_events, big.mark = ","),
      " events parsed. Independent y-scales; open circles mark zero-event years."
    ),
    x = NULL,
    y = "Events recorded",
    caption = "Source: BC_CEF_ForestDisturbance_2024.gdb, DSTRB_HIST"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    panel.grid.minor = element_blank(),
    panel.grid.major.x = element_blank(),
    ## Strip labels sat on the baseline of the panel above; give the facets room.
    panel.spacing.y = unit(1.4, "lines"),
    strip.text = element_text(hjust = 0, face = "bold", margin = margin(b = 4)),
    plot.title = element_text(face = "bold"),
    plot.subtitle = element_text(lineheight = 1.25, margin = margin(b = 10)),
    plot.caption = element_text(hjust = 0, colour = "grey40", margin = margin(t = 10)),
    plot.margin = margin(12, 16, 10, 12)
  )

png <- file.path(out_dir, "disturbance_record_by_year.png")
ggsave(png, gg, width = 9, height = 8.5, dpi = 150, bg = "white")
message("wrote ", png)

## ---- what the cross-check says ----------------------------------------------------------------

gap <- wide[wide$year %in% 1998:2001, c("year", "BRN", "fire_perimeters")]
if (anyNA(gap$fire_perimeters)) {
  ## Say so in the ordinary output: a warning alone is easy to filter away, and the CSV would
  ## otherwise carry an NA column with nothing to explain it.
  message(
    "\nNOTE: the fire-perimeter cross-check did not run, so `fire_perimeters` is NA in the CSV.\n",
    "  Re-run to populate it; the CEF counts above are unaffected."
  )
} else {
  message(
    "\nCEF fire record vs public fire perimeters, 1998-2001:\n",
    paste0(
      "  ",
      gap$year,
      ": CEF ",
      gap$BRN,
      " events, ",
      gap$fire_perimeters,
      " fire perimeters mapped",
      collapse = "\n"
    ),
    "\n=> fires occurred; the CEF gap is a gap in the record, not an absence of fire."
  )
}
