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

write_omniscape_config <- function(res, srcwt, run_name, nn_distances) {
  ## use relative paths when writing config and script files
  res <- fs::path_rel(res, get_path("project"))
  srcwt <- fs::path_rel(srcwt, get_path("project"))

  omni_path <- fs::dir_create(get_path("omniscape"), run_name)
  omni_path_rel <- fs::path_rel(omni_path, get_path("project"))

  output_dir <- fs::path(get_path("outputs"), run_name) ## don't create the dir, Omniscape neds to do it!
  output_path_rel <- fs::path_rel(output_dir, get_path("project"))

  config_file <- file.path(omni_path_rel, glue::glue("config.ini"))
  julia_script <- file.path(omni_path_rel, glue::glue("script.jl"))

  use_block_size <- function(radius, frac) {
    x <- round(radius * frac, digits = 0)
    ifelse(x %% 2 == 0, x + 1, x) ## must be odd
  }

  ## TODO: test, discuss, confirm
  radius <- round(quantile(units::drop_units(nn_distances), seq(0, 1, 0.05))[["90%"]], digits = 0)
  block_size <- use_block_size(radius, frac = 0.5) ## TODO: test with block_size = 1; frac = 0.5; frac = 0.1;

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
    parallel_batch_size = 10,
    pixel_size = 30, ## TODO: could be passed from the input data
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
      glue::glue("resistance_file = {res}"),
      glue::glue("source_file = {srcwt}"),
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
}

run_omniscape <- function(omniscape_files, julia_threads) {
  stopifnot(all(file.exists(omniscape_files)))

  run_name <- sub("^config_(.*)[.]ini$", "\\1", basename(config_file))
  omni_path <- file.path(get_path("omniscape"), run_name)

  config_file <- fs::path_rel(omniscape_files[1], omni_path)
  julia_script <- fs::path_rel(omniscape_files[2], omni_path)

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
