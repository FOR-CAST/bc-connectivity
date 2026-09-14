## Connectivity categories, after Cameron et al. (2022) --------------------------------------------
##
## Omniscape produces continuous surfaces. What gets read, presented and planned from is a
## categorical map: each location sorted by how the current flow it carries compares with the flow
## the same place could carry with nothing in the way. That ratio is `normalized_cum_currmap.tif`.
##
## The cut-offs below are Cameron et al. (2022), who took them unchanged from McRae et al. (2016)
## after testing 54 alternatives against a different landscape. They are NOT tuned to this study
## area, and they should not be quietly re-tuned to it: the value of using a published scheme is
## that the categories mean the same thing here as they do elsewhere.
##
## The framework goes on to split low-flow Diffuse and Impeded land into Impeded, Limited and
## Permeable using a human modification index. That needs a layer this pipeline does not yet build,
## so only the four categories the Omniscape outputs determine on their own are produced here.

## Category names, in increasing order of flow relative to what the landscape could carry.
CONNECTIVITY_CATEGORIES <- c("Impeded", "Diffuse", "Intensified", "Channelized")

## Fixed palette, so every map of every district and run is comparable at a glance. Diffuse is the
## near-neutral case and is deliberately the palest; Channelized is the one people look for.
CONNECTIVITY_COLOURS <- c(
  Impeded = "#B2182B",
  Diffuse = "#F7F7F7",
  Intensified = "#92C5DE",
  Channelized = "#2166AC"
)

#' Classify a normalized current surface into connectivity categories
#'
#' Cut-offs follow Cameron et al. (2022): Impeded at or below 0.7, Diffuse above 0.7 and below
#' 1.3, Intensified from 1.3 to 1.7 inclusive, Channelized above 1.7.
#'
#' @param x `SpatRaster` of normalized current, or a path to one.
#'
#' @returns categorical `SpatRaster` with the levels of `CONNECTIVITY_CATEGORIES`.
#'
#' @export
classify_connectivity <- function(x) {
  if (is.character(x)) {
    x <- terra::rast(x)
  }

  ## `terra::classify()` intervals are right-closed, which matches three of the four boundaries.
  ## The exception is 1.3: Cameron et al. place it in Intensified, and a right-closed break would
  ## put it in Diffuse. It is a single exact value in continuous data, so nothing measurable turns
  ## on it, but the map should say what the paper says.
  ## fmt: skip
  rcl <- matrix(
    c(
      -Inf, 0.7, 1,
       0.7, 1.3, 2,
       1.3, 1.7, 3,
       1.7, Inf, 4
    ),
    ncol = 3, byrow = TRUE
  )
  out <- terra::classify(x, rcl, include.lowest = TRUE, right = TRUE)
  out[x == 1.3] <- 3

  levels(out) <- data.frame(
    id = seq_along(CONNECTIVITY_CATEGORIES),
    category = CONNECTIVITY_CATEGORIES
  )
  names(out) <- "category"
  out
}

#' Path to a district's study area boundary
#'
#' The UNBUFFERED boundary, which is the reporting area. Quesnel keeps the filename it was given
#' before the pipeline became multi-district; every other district uses the factory's name.
#'
#' @param district district spec or key.
#'
#' @returns path to the boundary GeoPackage.
#'
#' @export
district_study_area <- function(district) {
  spec <- if (is.list(district)) district else district_spec(district)
  dir <- district_path("inputs", spec)
  cand <- c(
    file.path(dir, "studyarea.gpkg"),
    file.path(dir, "Quesnel_TSA_studyarea.gpkg")
  )
  hit <- cand[file.exists(cand)]
  if (!length(hit)) {
    stop("no study area boundary for district '", spec$key, "' in ", dir, call. = FALSE)
  }
  hit[[1]]
}

#' Categorical connectivity rasters for completed Omniscape runs
#'
#' One GeoTIFF per run, clipped to the district.
#'
#' @param run_dirs character vector of completed Omniscape run directories.
#' @param study_area `SpatVector` district boundary, or a path to one.
#' @param dest_dir directory to write into.
#'
#' @returns paths to the written GeoTIFFs, or `character(0)` if no runs were made.
#'
#' @export
connectivity_category_rasters <- function(run_dirs, study_area, dest_dir) {
  ## No branching over these targets, so an empty vector has to be handled here rather than by
  ## `targets`: with `BC_CONN_OMNISCAPE` unset -- the usual `tar_make()` -- no runs exist.
  if (!length(run_dirs)) {
    return(character(0))
  }
  fs::dir_create(dest_dir)
  vapply(
    run_dirs,
    function(d) {
      src <- file.path(d, "normalized_cum_currmap.tif")
      if (!file.exists(src)) {
        stop("no normalized_cum_currmap.tif in ", d, call. = FALSE)
      }
      k <- clip_to_study_area(classify_connectivity(src), study_area)
      dst <- file.path(dest_dir, paste0(basename(d), "_categories.tif"))
      terra::writeRaster(k, dst, overwrite = TRUE, datatype = "INT1U")
      dst
    },
    character(1),
    USE.NAMES = FALSE
  )
}

#' Clip a raster to the study area, reprojecting the boundary if needed
#'
#' The Omniscape rasters extend past the district because the moving window needs a buffer, and
#' that margin is not part of the result. The boundary is usually BC Albers while the rasters are
#' on the landcover grid, so it is reprojected rather than assumed to match.
#'
#' Pass the UNBUFFERED study area. The buffered one exists so the moving window has room to work;
#' it is not the reporting area, and clipping to it would put land outside the district into every
#' map and every category share.
#'
#' @param r `SpatRaster`.
#' @param study_area `SpatVector`.
#'
#' @returns `SpatRaster` cropped and masked to `study_area`.
#'
#' @export
clip_to_study_area <- function(r, study_area) {
  if (is.character(study_area)) {
    study_area <- terra::vect(study_area)
  }
  if (!terra::same.crs(study_area, r)) {
    study_area <- terra::project(study_area, terra::crs(r))
  }
  terra::mask(terra::crop(r, study_area), study_area)
}

#' Render a connectivity category map to PNG, for presentations and reports
#'
#' Sized and captioned for a slide rather than for a figure panel: large fonts, the run name in
#' the subtitle so a map cannot be separated from the run that produced it, and the category
#' shares in the legend so the picture carries its own summary.
#'
#' @param categories categorical `SpatRaster` from [classify_connectivity()], or a path to one.
#' @param dest_dir directory to write into.
#' @param run_name run identifier, used in the filename and subtitle.
#' @param title map title; defaults to the district label if given.
#' @param width,height,res passed to [grDevices::png()].
#'
#' @returns path to the written PNG.
#'
#' @export
plot_connectivity_categories <- function(
  categories,
  dest_dir,
  run_name,
  title = NULL,
  width = 2400,
  height = 1500,
  res = 200
) {
  if (is.character(categories)) {
    categories <- terra::rast(categories)
  }
  fs::dir_create(dest_dir)
  dst <- file.path(dest_dir, paste0(run_name, "_categories.png"))

  ## Share of the mapped district in each category, so the legend states the split rather than
  ## leaving the reader to estimate it from colour.
  f <- terra::freq(categories, digits = 4)
  shares <- stats::setNames(f$count / sum(f$count), as.character(f$value))
  lab <- vapply(
    CONNECTIVITY_CATEGORIES,
    function(k) {
      s <- shares[[k]]
      if (is.null(s) || is.na(s)) k else sprintf("%s (%.1f%%)", k, 100 * s)
    },
    character(1)
  )

  grDevices::png(dst, width = width, height = height, res = res)
  on.exit(grDevices::dev.off(), add = TRUE)
  op <- graphics::par(mar = c(0.5, 0.5, 3.2, 0.5))
  on.exit(graphics::par(op), add = TRUE)

  terra::plot(
    categories,
    col = CONNECTIVITY_COLOURS,
    axes = FALSE,
    legend = FALSE,
    mar = c(0.5, 0.5, 3.2, 0.5)
  )
  graphics::title(
    main = title %||% "Connectivity categories",
    sub = NULL,
    cex.main = 1.5
  )
  graphics::mtext(run_name, side = 3, line = 0.2, cex = 0.9, col = "grey30")
  graphics::legend(
    "bottomleft",
    legend = lab,
    fill = CONNECTIVITY_COLOURS,
    border = "grey40",
    bty = "n",
    cex = 1.0,
    inset = c(0.01, 0.01)
  )
  dst
}

#' Categorical maps for every completed Omniscape run in a district
#'
#' @param run_dirs character vector of completed Omniscape run directories.
#' @param study_area `SpatVector` district boundary.
#' @param dest_dir directory to write the PNGs into.
#' @param label district label used in map titles.
#'
#' @returns paths to the written PNGs.
#'
#' @export
connectivity_category_maps <- function(run_dirs, study_area, dest_dir, label = NULL) {
  if (!length(run_dirs)) {
    return(character(0))
  }
  vapply(
    run_dirs,
    function(d) {
      k <- clip_to_study_area(
        classify_connectivity(file.path(d, "normalized_cum_currmap.tif")),
        study_area = study_area
      )
      plot_connectivity_categories(
        k,
        dest_dir = dest_dir,
        run_name = basename(d),
        title = if (is.null(label)) NULL else paste(label, "- connectivity categories")
      )
    },
    character(1),
    USE.NAMES = FALSE
  )
}
