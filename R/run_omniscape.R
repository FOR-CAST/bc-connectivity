## JuliaCall doesn't work with "non-standard" installation locations (i.e. used by rig)
## see <https://github.com/JuliaInterop/JuliaCall/issues/272>

# library(JuliaCall)
#
# julia_threads <- 64L
# julia_version <- "1.11.7"
#
# ## TODO: diagnose + fix failures
# julia <- julia_setup(
#   # installJulia = TRUE,
#   rebuild = TRUE,
#   version = julia_version
# )
#
# julia_install_package_if_needed("Omniscape")

## NOTE: can't run julia from R (some env vars clash); segfaults
if (FALSE) {
  julia_threads <- 4L
  julia_version <- "1.11.7"

  err <- tempfile("error_", fileext = ".log")
  out <- tempfile("output_", fileext = ".log")

  ## ensure Omniscape is installed
  system2(
    # fs::path_expand("~/.juliaup/bin/julia"),
    Sys.which("julia"),
    c(
      sprintf("+%s", julia_version),
      sprintf("-t %s", julia_threads),
      "Omniscape/install.jl"
    ),
    wait = TRUE,
    stderr = err,
    stdout = out
  )

  file.edit(err) ## Segmentation fault (core dumped)
  file.edit(out)
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

  ## NOTE: using larger radius increases computation time, even with increasing block_size
  use_radius <- function(patch_distances, pixel_size, q) {
    rad <- quantile(units::drop_units(patch_distances), seq(0, 1, 0.01))[[paste0(q, "%")]] |>
      round(digits = 0)
    ceiling(rad / pixel_size)
  }
  radius <- use_radius(patch_distances, pixel_size, q) ## (in pixels)

  ## use block_size ~1/10 of radius (in pixels) per Phillips et. al (2021) Landscape Ecol. 36:1647–1661
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

  ## create tiles
  tile_dir <- file.path(get_path("rasters"), run_name) |> fs::dir_create()
  tile_c <- ceiling(terra::ncol(res_r) / ntiles[2])
  tile_r <- ceiling(terra::nrow(res_r) / ntiles[1])
  use_buffer <- ceiling(2 * radius / pixel_size)

  stopifnot(tile_c > use_buffer, tile_r > use_buffer)

  res_tiles <- terra::makeTiles(
    x = res_r,
    y = c(tile_r, tile_c),
    filename = file.path(tile_dir, paste0(tools::file_path_sans_ext(basename(res)), "_tile_.tif")),
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

  ## also add non-tiled versions
  res_tiles <- c(res_tiles, res)
  srcwt_tiles <- c(srcwt_tiles, srcwt)

  tile_ids <- seq_len(prod(ntiles) + 1) ## add extra index at end for non-tiled version

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
    if (dir.exists(output_dir)) {
      unlink(output_dir, recursive = TRUE)
    }

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

run_omniscape <- function(omniscape_files, julia_threads) {
  stopifnot(all(file.exists(omniscape_files)))

  config_files <- grep("config", omniscape_files, value = TRUE)
  julia_scripts <- grep("script", omniscape_files, value = TRUE)

  run_name <- basename(dirname(config_files[1])) ## TODO: deal with tile ids

  output_dir <- file.path(get_path("outputs"), run_name) ## don't create the dir, Omniscape neds to do it!
  log_file <- file.path(output_dir, "omniscape_run.log")

  output_files <- file.path(
    output_dir,
    c(
      "cum_currmap.tif",
      "flow_potential.tif",
      "normalized_cum_currmap.tif",
      log_file
    )
  )

  julia_version <- "1.11.7"

  ## use tmpfile for logging since omniscape output dir won't exist yet
  ## (and omniscape won't write to the directory if it exists)
  tmp_log <- tempfile(pattern = glue::glue("omniscape_{run_name}_"), fileext = ".log")
  on.exit(file.copy(tmp_log, log_file))

  ## launch Julia
  ps2 <- processx::run(
    command = Sys.which("julia"), ## TODO: doesn't always work?
    # command = fs::path_expand("~/.juliaup/bin/julia"),
    args = paste(
      glue::glue("+{julia_version}"),
      glue::glue("-t {julia_threads}"),
      glue::glue("{julia_script}")
    ),
    error_on_status = TRUE,
    wd = get_path("project"),
    stdout = tmp_log,
    stderr = tmp_log,
  )

  return(output_files)
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
