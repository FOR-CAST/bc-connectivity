# Launching Julia from R ----------------------------------------------------------------------

## R exports `LD_LIBRARY_PATH` pointing at its own bundled shared libraries (e.g.
## /opt/R/4.5.3/lib/R/lib, as installed by rig). Any child process inherits it, so Julia resolves
## libraries such as libcurl/libz/libgomp against R's copies instead of the ones it ships with, and
## dies with SIGSEGV as soon as a package that touches them is loaded:
##
##   processx::run(julia, c("+1.11.7", "-t", "4", "-e", "using Omniscape"))  # status -11
##   ... the same call with LD_LIBRARY_PATH removed from the child env       # status 0
##
## Dropping that one variable is what makes running Omniscape from R work; `JuliaCall` was never
## the problem. `R_HOME` and `LD_PRELOAD` are dropped for the same reason (nothing in Julia should
## be resolving against the calling R installation).

## environment for a Julia child process: the current environment minus the variables that make
## Julia load R's shared libraries
julia_env <- function(drop = c("LD_LIBRARY_PATH", "LD_PRELOAD", "R_HOME")) {
  e <- Sys.getenv()
  e <- e[!names(e) %in% drop]

  stats::setNames(as.character(e), names(e))
}

## locate the julia launcher; prefer whatever is on PATH, fall back to the juliaup shim
julia_bin <- function() {
  jl <- Sys.which("julia")

  if (!nzchar(jl)) {
    jl <- fs::path_expand("~/.juliaup/bin/julia")
  }

  if (!file.exists(jl)) {
    stop(
      "Could not find the `julia` launcher on PATH or at ~/.juliaup/bin/julia.\n",
      "Install Julia via juliaup (<https://github.com/JuliaLang/juliaup>) and ensure the ",
      "required version is available (`juliaup add 1.11.7`)."
    )
  }

  return(unname(jl))
}

## read a single option out of an Omniscape config.ini
read_omniscape_option <- function(config_file, option) {
  lines <- readLines(config_file, warn = FALSE)
  hit <- grep(paste0("^\\s*", option, "\\s*="), lines, value = TRUE)

  if (length(hit) != 1) {
    stop("expected exactly one `", option, "` entry in ", config_file, "; found ", length(hit))
  }

  sub(paste0("^\\s*", option, "\\s*=\\s*"), "", hit) |> trimws()
}

#' Write Omniscape configuration file
#'
#' @param res,srcwt character specific the file path to the resistance and source weight rasters
#' @param patch_distances numeric (units) vector of interpatch distances
#' @param q percentile value from `patch_distances` to use as the Omniscape run `radius` (e.g., 90 means '90%')
#' @param run_name character specifying the base run name, to which the pixel size, radius, and block size will be appended
#' @param ntiles integer [2] specifying the number of tile rows and columns to split the rasters by
#'
#' @returns character vector specifying the file paths of the saved configuration and launch script files
#' (`config.ini` and `script.jl`, respectively)
#'
#' @export
write_omniscape_config <- function(
  res,
  srcwt,
  patch_distances,
  q = 100L,
  run_name = Sys.Date(),
  ntiles = c(2, 3)
) {
  q <- as.integer(q)

  stopifnot(q >= 1 && q <= 100)

  res_r <- terra::rast(res)
  srcwt_r <- terra::rast(srcwt)

  stopifnot(terra::compareGeom(res_r, srcwt_r, stopOnError = FALSE))

  pixel_size <- terra::res(res_r) |> unique()

  ## UNITS: Omniscape's `radius`, `block_size`, and `buffer` are all in PIXELS, not map units.
  ## From its docs: "A positive integer specifying the radius *in pixels* of the moving window",
  ## and its source uses `radius` directly in raster index arithmetic
  ## (`target.x_coord - radius - 1`, `ncols - (target.x_coord + radius)`).
  ##
  ## So an interpatch distance in metres has to be divided by the pixel size here. Everything
  ## downstream of `use_radius()` is therefore in pixels -- including the tile overlap, which is why
  ## dividing by `pixel_size` a second time there was wrong (see `use_buffer` below).
  ##
  ## Cross-check against the run names: 45,202 m / 30 m = 1507 px, / 90 m = 503 px; 1,726 m / 30 m
  ## = 58 px.
  ##
  ## NOTE: using larger radius increases computation time, even with increasing block_size
  use_radius <- function(patch_distances, pixel_size, q) {
    rad <- patch_distances[[paste0(q, "%")]] |> round(digits = 0)
    rad_px <- ceiling(rad / pixel_size) ## now in pixels, not m
    if (inherits(rad_px, "units")) {
      rad_px <- units::drop_units(rad_px)
    }

    return(rad_px)
  }
  radius <- use_radius(patch_distances, pixel_size, q) ## (in pixels)

  ## use block_size ~1/10 of radius per Phillips et. al (2021) Landscape Ecol. 36:1647-1661.
  ## Both are in pixels and the guidance is a ratio, so no unit conversion is involved.
  use_block_size <- function(radius, frac = 0.1) {
    x <- round(radius * frac, digits = 0)
    ifelse(x %% 2 == 0, x + 1, x) ## must be odd
  }
  block_size <- use_block_size(radius, frac = 0.1)

  ## append the following to the run_name:
  ## - pixel_size;
  ## - radius;
  ## - block_size;
  run_name <- glue::glue("{run_name}_p{pixel_size}_r{radius}_bs{block_size}")

  ## create tiles (or not: `ntiles = c(1, 1)` means run the whole raster in one go)
  ##
  ## Tiles must overlap by at least `2 * radius` so that every moving window is fully populated
  ## right up to the tile edge; the mosaicked result is then artifact-free
  ## (<https://github.com/Circuitscape/Omniscape.jl/issues/75>).
  ##
  ## `radius` is already in PIXELS, and `terra::makeTiles(buffer =)` is also in cells, so the
  ## overlap is simply `2 * radius`. Dividing by `pixel_size` here (as this did until 2026-08-25)
  ## made the buffer 30x too small at 30 m: r = 1507 px got 101 px of overlap instead of 3014, so
  ## current within ~1400 px of every seam was wrong and the mosaics were artifact-ridden.
  tiled <- prod(ntiles) > 1

  tile_dir <- file.path(get_path("rasters"), run_name) |> fs::dir_create()
  tile_c <- ceiling(terra::ncol(res_r) / ntiles[2])
  tile_r <- ceiling(terra::nrow(res_r) / ntiles[1])
  use_buffer <- 2 * radius

  ## A correctly-buffered tile is `tile + 2 * use_buffer` on a side, so for large radii the tiles
  ## quickly grow back to (or past) the size of the untiled raster and tiling buys nothing. Refuse
  ## to emit tiles that cannot be mosaicked correctly rather than emitting bad ones.
  if (tiled && (tile_c <= use_buffer || tile_r <= use_buffer)) {
    stop(
      glue::glue(
        "cannot tile {run_name}: a radius of {radius} px needs {use_buffer} px of tile overlap, ",
        "but the requested {ntiles[1]}x{ntiles[2]} grid gives tiles of only {tile_r}x{tile_c} px.\n",
        "Use fewer tiles (or `ntiles = c(1, 1)`, i.e. run untiled) for this radius."
      )
    )
  }

  if (tiled) {
    res_tiles <- terra::makeTiles(
      x = res_r,
      y = c(tile_r, tile_c),
      filename = file.path(
        tile_dir,
        paste0(tools::file_path_sans_ext(basename(res)), "_tile_.tif")
      ),
      buffer = use_buffer
    )
    srcwt_tiles <- terra::makeTiles(
      x = srcwt_r,
      y = c(tile_r, tile_c),
      filename = file.path(
        tile_dir,
        paste0(tools::file_path_sans_ext(basename(srcwt)), "_tile_.tif")
      ),
      buffer = use_buffer
    )
  } else {
    res_tiles <- character(0)
    srcwt_tiles <- character(0)
  }

  ## the untiled run is always written, and is always last
  res_tiles <- c(res_tiles, res)
  srcwt_tiles <- c(srcwt_tiles, srcwt)

  tile_ids <- seq_along(res_tiles)

  stopifnot(length(tile_ids) == length(res_tiles), length(tile_ids) == length(srcwt_tiles))

  ## use relative paths when writing config and script files
  res <- fs::path_rel(res, get_path("project"))
  res_tiles <- fs::path_rel(res_tiles, get_path("project"))
  srcwt <- fs::path_rel(srcwt, get_path("project"))
  srcwt_tiles <- fs::path_rel(srcwt_tiles, get_path("project"))

  ## write config files for each tile
  julia_files <- lapply(tile_ids, function(tile_id) {
    ## further append tile id to run_name
    if (tile_id == max(tile_ids)) {
      run_name_tile <- glue::glue("{run_name}")
    } else {
      run_name_tile <- glue::glue("{run_name}_t{tile_id}")
    }

    omni_path <- fs::dir_create(get_path("omniscape"), run_name)
    omni_path_rel <- fs::path_rel(omni_path, get_path("project"))

    output_dir <- fs::path(get_path("outputs"), run_name_tile) ## don't create the dir, Omniscape needs to do it!
    output_path_rel <- fs::path_rel(output_dir, get_path("project"))

    if (tile_id == max(tile_ids)) {
      config_file <- file.path(omni_path_rel, "config.ini")
      julia_script <- file.path(omni_path_rel, "script.jl")
    } else {
      config_file <- file.path(omni_path_rel, glue::glue("config_t{tile_id}.ini"))
      julia_script <- file.path(omni_path_rel, glue::glue("script_t{tile_id}.jl"))
    }

    ## see <https://docs.circuitscape.org/Omniscape.jl/stable/usage/> for full info
    ##
    ## NOTE: use of conditional connectivity options not implemented here
    args <- list(
      allow_different_projections = "false",
      block_size = block_size,
      buffer = 0,
      calc_flow_potential = "true",
      calc_normalized_current = "true",
      connect_four_neighbors_only = "false",
      correct_artifacts = "true",
      mask_nodata = "true",
      parallelize = "true",
      parallel_batch_size = 10, ## TODO: may need to tweak this
      project_name = output_path_rel,
      r_cutoff = 0.0,
      radius = radius,
      resistance_is_conductance = "false",
      solver = "cg+amg", ## use default "cg+amg"
      source_from_resistance = "false",
      source_threshold = 0,
      write_as_tif = "true",
      write_raw_currmap = "true"
    )

    ## Omniscape refuses to accidentally overwrite existing directory,
    ## so need to preemptively cleanup
    # if (dir.exists(output_dir)) {
    #   unlink(output_dir, recursive = TRUE)
    # }

    ## write ini file for Omniscape
    cat(
      c(
        glue::glue("[Input files]"),
        glue::glue("resistance_file = {res_tiles[tile_id]}"),
        glue::glue("source_file = {srcwt_tiles[tile_id]}"),
        glue::glue("[Required options]"),
        glue::glue("block_size = {args$block_size}"),
        glue::glue("project_name = {args$project_name}"),
        glue::glue("radius = {args$radius}"),
        glue::glue("[General options]"),
        glue::glue("allow_different_projections = {args$allow_different_projections}"),
        glue::glue("buffer = {args$buffer}"),
        glue::glue("calc_flow_potential = {args$calc_flow_potential}"),
        glue::glue("calc_normalized_current = {args$calc_normalized_current}"),
        glue::glue("connect_four_neighbors_only = {args$connect_four_neighbors_only}"),
        glue::glue("correct_artifacts = {args$correct_artifacts}"),
        glue::glue("r_cutoff = {args$r_cutoff}"),
        glue::glue("resistance_is_conductance = {args$resistance_is_conductance}"),
        glue::glue("source_from_resistance = {args$source_from_resistance}"),
        glue::glue("source_threshold = {args$source_threshold}"),
        glue::glue("[Processing options]"),
        glue::glue("parallelize = {args$parallelize}"),
        glue::glue("parallel_batch_size = {args$parallel_batch_size}"),
        glue::glue("[Output options]"),
        glue::glue("mask_nodata = {args$mask_nodata}"),
        glue::glue("write_as_tif = {args$write_as_tif}"), ## whether to use .tif or .asc
        glue::glue("write_raw_currmap = {args$write_raw_currmap}")
      ),
      sep = "\n",
      file = config_file
    )

    ## create Julia script to run Omniscape
    cat(
      c(
        glue::glue("using Omniscape"),
        glue::glue("run_omniscape(\"{config_file}\")")
      ),
      sep = "\n",
      file = julia_script
    )

    return(c(config_file, julia_script))
  })

  config_files <- purrr::transpose(julia_files) |> purrr::pluck(1) |> unlist()
  script_files <- purrr::transpose(julia_files) |> purrr::pluck(2) |> unlist()

  return(c(config_files, script_files, res_tiles, srcwt_tiles))
}

#' Run Omniscape
#'
#' Launches a single Omniscape configuration in a Julia subprocess. See `julia_env()` for why the
#' child environment has to be scrubbed; without that this segfaults, which is why Omniscape runs
#' used to be launched by hand from a shell.
#'
#' @param julia_script path to one `script.jl` written by [write_omniscape_config()]
#' @param julia_threads integer, number of Julia threads (`-t`)
#' @param julia_version character, juliaup channel to run (Omniscape does not work on Julia 1.12;
#'   see <https://github.com/Circuitscape/Omniscape.jl/issues/160>)
#' @param overwrite if `TRUE`, remove a pre-existing Omniscape output directory before running.
#'   Omniscape refuses to write into a directory that already exists, so a rerun of this target
#'   cannot otherwise proceed. Only directories that look like Omniscape output are removed.
#'
#' @returns character vector of the output files produced by the run
#'
#' @export
run_omniscape <- function(
  julia_script,
  julia_threads = 64L,
  julia_version = "1.11.7",
  overwrite = TRUE
) {
  stopifnot(length(julia_script) == 1L, file.exists(julia_script))

  ## `script.jl` <-> `config.ini`, `script_t3.jl` <-> `config_t3.ini`
  config_file <- file.path(
    dirname(julia_script),
    sub("^script(_t[0-9]+)?[.]jl$", "config\\1.ini", basename(julia_script))
  )
  stopifnot(file.exists(config_file))

  ## the output directory is whatever `project_name` says; paths in the config are relative to the
  ## project root, which is also the working directory the run is launched from
  project_dir <- get_path("project")
  output_dir <- file.path(project_dir, read_omniscape_option(config_file, "project_name"))
  run_name <- basename(output_dir)

  ## Omniscape errors out rather than overwrite an existing output directory. Deleting it
  ## pre-emptively and unconditionally is what b8949de rightly backed out, so only clear a
  ## directory that actually holds output from a previous Omniscape run of this configuration.
  if (dir.exists(output_dir)) {
    looks_like_output <- length(fs::dir_ls(output_dir, glob = "*.tif")) > 0 ||
      file.exists(file.path(output_dir, "omniscape_run.log"))

    if (!isTRUE(overwrite)) {
      stop(
        glue::glue(
          "Omniscape output directory already exists and `overwrite = FALSE`:\n  {output_dir}"
        )
      )
    }
    if (!looks_like_output) {
      stop(
        glue::glue(
          "refusing to remove {output_dir}: it exists but does not look like Omniscape output.\n",
          "Move it aside by hand, then rerun."
        )
      )
    }

    unlink(output_dir, recursive = TRUE)
  }

  ## Omniscape creates the output directory itself, so it cannot exist yet -- log to a temp file
  ## and move the log into place once the run is done.
  tmp_log <- tempfile(pattern = glue::glue("omniscape_{run_name}_"), fileext = ".log")
  log_file <- file.path(output_dir, "omniscape_run.log")
  on.exit(
    if (file.exists(tmp_log) && dir.exists(output_dir)) {
      file.copy(tmp_log, log_file, overwrite = TRUE)
    },
    add = TRUE
  )

  processx::run(
    command = julia_bin(),
    ## processx does NOT go through a shell, so each argument must be its own element; passing
    ## these space-joined (as this did until 2026-08-25) hands julia one nonsense argument.
    args = c(
      glue::glue("+{julia_version}"),
      "-t",
      as.character(julia_threads),
      fs::path_rel(julia_script, project_dir)
    ),
    env = julia_env(),
    wd = project_dir,
    error_on_status = TRUE,
    stdout = tmp_log,
    stderr = "2>&1"
  )

  output_files <- c(
    file.path(output_dir, c("cum_currmap.tif", "flow_potential.tif", "normalized_cum_currmap.tif")),
    log_file
  )

  missing <- output_files[!file.exists(output_files)]
  if (length(missing) > 0) {
    stop(
      glue::glue(
        "Omniscape run {run_name} finished but did not produce:\n  ",
        paste(missing, collapse = "\n  "),
        "\nSee {log_file}"
      )
    )
  }

  return(output_files)
}

## the launch scripts written by write_omniscape_config(), in the order they should be run
omniscape_scripts <- function(omniscape_files, tiled = FALSE) {
  scripts <- grep("[.]jl$", unlist(omniscape_files), value = TRUE)

  ## `script.jl` is the untiled run; `script_t<N>.jl` are the tiles
  is_tile <- grepl("_t[0-9]+[.]jl$", basename(scripts))

  if (isTRUE(tiled)) scripts[is_tile] else scripts[!is_tile]
}

#' Choose which Omniscape configurations to run
#'
#' A full `tar_make()` should be able to prepare every input without also committing the machine to
#' a multi-day Omniscape run, so which runs execute is opt-in.
#'
#' @param nn_files,alldist_files the file vectors returned by [write_omniscape_config()]
#' @param which one of `"none"` (default), `"nn"`, `"alldist"`, or `"all"`
#'
#' @returns character vector of launch scripts to run (possibly empty)
#'
#' @export
select_omniscape_runs <- function(nn_files, alldist_files, which = "none") {
  which <- match.arg(tolower(which), c("none", "nn", "alldist", "all"))

  files <- switch(
    which,
    none = character(0),
    nn = unlist(nn_files),
    alldist = unlist(alldist_files),
    all = c(unlist(nn_files), unlist(alldist_files))
  )

  omniscape_scripts(files, tiled = FALSE)
}

#' Run several Omniscape configurations, one after another
#'
#' @inheritParams run_omniscape
#' @param julia_scripts character vector of launch scripts (may be empty)
#'
#' @returns character vector of every output file produced
#'
#' @export
run_omniscape_all <- function(julia_scripts, julia_threads = 64L, ...) {
  if (length(julia_scripts) == 0L) {
    message(
      "No Omniscape runs selected. Set BC_CONN_OMNISCAPE to 'nn', 'alldist', or 'all' to run them."
    )
    return(character(0))
  }

  purrr::map(
    julia_scripts,
    function(x) run_omniscape(x, julia_threads = julia_threads, ...)
  ) |>
    unlist()
}

#' Create raster tiles for Omniscape runs
#'
#' From discussion at <https://github.com/Circuitscape/Omniscape.jl/issues/75>:
#' split large raster inputs into subsets overlapping by at least `2 * radius` pixels,
#' then, combine the results, taking the maximum value of the inputs.
#'

#' Recombine resistance and source weight raster tiles
#'
#' @export
mosaic_raster_tiles <- function(r_list, file) {
  do.call(terra::mosaic, r_list, fun = "max", filename = file, overwrite = TRUE) ## TODO

  return(file)
}
