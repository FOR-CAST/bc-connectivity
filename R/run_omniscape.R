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

## Peak memory and wall-clock time for an Omniscape run.
##
## `targets` records neither: its metadata has `seconds` (wall clock) and `bytes` (the size of the
## *stored object*), but nothing about memory. `crew`'s `crew_options_metrics()` instruments the R
## worker process, whereas Omniscape runs in a Julia subprocess, so the worker's RSS is not
## Omniscape's. Hence this wrapper.
##
## GNU `time -v` reports the child's peak RSS ("high water mark") after it exits, which polling
## /proc can miss entirely if the peak falls between samples.
gnu_time <- function() {
  candidates <- c("/usr/bin/time", "/bin/time")
  hit <- candidates[file.exists(candidates)]

  if (length(hit) == 0L) NULL else hit[[1]]
}

## parse the fields we want out of `time -v` output
parse_gnu_time <- function(path) {
  if (!file.exists(path)) {
    return(list(peak_rss_gb = NA_real_, wall_seconds = NA_real_, cpu_pct = NA_real_))
  }

  lines <- readLines(path, warn = FALSE)

  grab <- function(pattern) {
    hit <- grep(pattern, lines, value = TRUE)
    if (length(hit) == 0L) NA_character_ else sub("^[^:]*:\\s*", "", hit[[1]]) |> trimws()
  }

  ## "Elapsed (wall clock) time" is h:mm:ss or m:ss
  elapsed <- grab("Elapsed \\(wall clock\\) time")
  seconds <- if (is.na(elapsed)) {
    NA_real_
  } else {
    parts <- as.numeric(strsplit(elapsed, ":", fixed = TRUE)[[1]])
    sum(parts * 60^rev(seq_along(parts) - 1))
  }

  list(
    peak_rss_gb = suppressWarnings(as.numeric(grab("Maximum resident set size"))) / 1024^2,
    wall_seconds = seconds,
    cpu_pct = suppressWarnings(as.numeric(sub("%$", "", grab("Percent of CPU this job got"))))
  )
}

## Cap an Omniscape run's memory with a transient systemd scope (cgroup v2).
##
## A runaway run takes the whole machine down and everyone else's work with it -- these hosts are
## shared with another project's multi-hundred-GB jobs. `MemoryMax` makes the kernel kill *our* run
## instead of picking a victim. `MemorySwapMax=0` stops it thrashing the (small) swap on the way
## down, which on an anonymous-memory-heavy solver just converts a fast failure into a slow one.
##
## This only works at launch: a limit cannot be retrofitted to a running job, because moving a live
## PID into a cgroup we control needs write access to the common ancestor of the two cgroups, and
## that is root-owned (cgroup v2's delegation rule).
##
## Needs a systemd user manager with a delegated subtree that has the `memory` controller enabled;
## `systemd-run` being on PATH is not sufficient, so probe it for real. Returns NULL when
## unavailable so the run proceeds unguarded rather than failing.
systemd_scope <- function() {
  bin <- Sys.which("systemd-run")

  if (!nzchar(bin)) {
    return(NULL)
  }

  ok <- tryCatch(
    processx::run(
      unname(bin),
      c("--user", "--scope", "--quiet", "-p", "MemoryMax=1G", "true"),
      error_on_status = FALSE
    )$status ==
      0L,
    error = function(e) FALSE
  )

  if (isTRUE(ok)) unname(bin) else NULL
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
#' @param julia_threads integer, number of Julia threads (`-t`). Defaults to 32, not the host's
#'   core count: memory scales linearly with thread count (measured at ~9.3 GB/thread for the 30 m
#'   regional configuration, so 64 threads would need ~600 GB), 64 exceeds the physical core count
#'   on half these hosts, and Omniscape's scaling is configuration-dependent -- a run with many
#'   small moving windows contends on the shared current accumulator and got *slower* between 8 and
#'   32 threads. Raise it only for a configuration whose scaling has been measured.
#' @param julia_version character, juliaup channel to run (Omniscape does not work on Julia 1.12;
#'   see <https://github.com/Circuitscape/Omniscape.jl/issues/160>)
#' @param memory_max systemd `MemoryMax` for the run, e.g. `"400G"` or `"50%"`; `NULL` or `"none"`
#'   runs unguarded. See [omniscape_memory_max()]. Ignored with a warning if no systemd user manager
#'   is available.
#' @param overwrite if `TRUE`, remove a pre-existing Omniscape output directory before running.
#'   Omniscape refuses to write into a directory that already exists, so a rerun of this target
#'   cannot otherwise proceed. Only directories that look like Omniscape output are removed.
#'
#' @returns character vector of the output files produced by the run
#'
#' @export
run_omniscape <- function(
  julia_script,
  julia_threads = NULL,
  julia_version = "1.11.7",
  overwrite = TRUE,
  memory_max = omniscape_memory_max()
) {
  stopifnot(length(julia_script) == 1L, file.exists(julia_script))

  ## `script.jl` <-> `config.ini`, `script_t3.jl` <-> `config_t3.ini`
  config_file <- file.path(
    dirname(julia_script),
    sub("^script(_t[0-9]+)?[.]jl$", "config\\1.ini", basename(julia_script))
  )
  stopifnot(file.exists(config_file))

  ## `NULL` means "size it to this configuration" -- the runs differ by three orders of magnitude
  ## in window size and do not share an optimal thread count. See `omniscape_threads()`.
  if (is.null(julia_threads)) {
    julia_threads <- omniscape_threads(config_file)
  }

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

  ## processx does NOT go through a shell, so each argument must be its own element; passing these
  ## space-joined (as this did until 2026-08-25) hands julia one nonsense argument.
  julia_args <- c(
    glue::glue("+{julia_version}"),
    "-t",
    as.character(julia_threads),
    fs::path_rel(julia_script, project_dir)
  )

  ## measure peak RSS and wall clock by running under GNU `time -v`, writing to its own file so the
  ## measurements do not get tangled up in Omniscape's log
  timer <- gnu_time()
  tmp_metrics <- tempfile(pattern = glue::glue("metrics_{run_name}_"), fileext = ".txt")

  if (is.null(timer)) {
    command <- julia_bin()
    args <- julia_args
  } else {
    command <- timer
    args <- c("-v", "-o", tmp_metrics, julia_bin(), julia_args)
  }

  ## wrap the lot in a transient scope so the cgroup limit covers julia and the timer together
  scope <- if (is.null(memory_max)) NULL else systemd_scope()

  if (!is.null(memory_max) && is.null(scope)) {
    warning(
      "no usable systemd user manager, so `memory_max` cannot be enforced; ",
      "running Omniscape unguarded."
    )
  }

  if (!is.null(scope)) {
    args <- c(
      "--user",
      "--scope",
      "--quiet",
      "-p",
      paste0("MemoryMax=", memory_max),
      "-p",
      "MemorySwapMax=0",
      "--",
      command,
      args
    )
    command <- scope
  }

  started <- Sys.time()

  ## `error_on_status = FALSE` so that a cgroup kill can be reported as what it is; processx's own
  ## error message knows nothing about the memory cap
  result <- processx::run(
    command = command,
    args = args,
    env = julia_env(),
    wd = project_dir,
    error_on_status = FALSE,
    stdout = tmp_log,
    stderr = "2>&1"
  )

  if (!identical(result$status, 0L)) {
    ## processx reports a signal death as the negative signal; a shell would report 128 + signal.
    ## The cap does not always surface as SIGKILL: systemd tears the whole scope down, so a run
    ## that hits `MemoryMax` can land here as SIGTERM instead. Treat any signal death under a
    ## scope as *possibly* the cap and say so tentatively, rather than missing the common case.
    killed <- !is.null(scope) && (result$status < 0L || result$status %in% c(137L, 143L))

    hint <- if (killed) {
      glue::glue(
        " The process was killed by a signal, which is consistent with hitting ",
        "`MemoryMax={memory_max}`: raise it (or set BC_CONN_OMNISCAPE_MEMMAX), or lower ",
        "`julia_threads` -- memory scales linearly with thread count. Check the log below to rule ",
        "out an unrelated failure."
      )
    } else {
      ""
    }

    stop(glue::glue(
      "Omniscape failed with exit status {result$status}.{hint}\n  Log kept at: {tmp_log}"
    ))
  }

  metrics <- parse_gnu_time(tmp_metrics)
  config <- function(opt) read_omniscape_option(config_file, opt)

  ## Move the log into place *before* the completeness check below. `on.exit()` does not run until
  ## this function returns, so including `log_file` in that check meant it was always missing at
  ## check time and every otherwise-successful run stopped with "did not produce". The `on.exit()`
  ## copy remains, and covers the error path.
  if (file.exists(tmp_log) && dir.exists(output_dir)) {
    file.copy(tmp_log, log_file, overwrite = TRUE)
  }

  metrics_row <- data.frame(
    run_name = run_name,
    tiled = grepl("_t[0-9]+$", run_name),
    pixel_size = as.numeric(sub(".*_p([0-9]+)_.*", "\\1", run_name)),
    radius_px = as.integer(config("radius")),
    block_size_px = as.integer(config("block_size")),
    julia_threads = as.integer(julia_threads),
    wall_seconds = if (is.na(metrics$wall_seconds)) {
      as.numeric(difftime(Sys.time(), started, units = "secs"))
    } else {
      metrics$wall_seconds
    },
    peak_rss_gb = metrics$peak_rss_gb,
    cpu_pct = metrics$cpu_pct
  )

  metrics_file <- file.path(output_dir, "omniscape_metrics.csv")
  utils::write.csv(metrics_row, metrics_file, row.names = FALSE)

  ## Omniscape writes each raster only when the matching option asked for it (see the `write_*`
  ## block in `Omniscape/src/main.jl`), so demanding all three fails a run that deliberately
  ## skipped one. Defaults here match Omniscape's own (`config.jl`) for options a config omits.
  enabled <- function(opt, default) {
    value <- tryCatch(config(opt), error = function(e) default)
    isTRUE(as.logical(value))
  }

  expected_tifs <- c(
    if (enabled("write_raw_currmap", "true")) "cum_currmap.tif",
    if (enabled("calc_flow_potential", "false")) "flow_potential.tif",
    if (enabled("calc_normalized_current", "false")) "normalized_cum_currmap.tif"
  )

  output_files <- c(file.path(output_dir, expected_tifs), log_file, metrics_file)

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

#' Tiling for the Omniscape configurations
#'
#' Tiled variants exist to benchmark resource use against the untiled run, not because the analysis
#' needs them -- one set of results is used for reporting. They are therefore opt-in: set
#' `BC_CONN_OMNISCAPE_BENCH` to a `rows x cols` grid (e.g. `"2x3"`) to have them written alongside
#' the untiled configuration.
#'
#' @returns integer vector of length 2, `c(1, 1)` meaning "do not tile"
#'
#' @export
omniscape_tiles <- function(spec = Sys.getenv("BC_CONN_OMNISCAPE_BENCH", "")) {
  if (!nzchar(spec) || identical(tolower(spec), "false")) {
    return(c(1L, 1L))
  }

  parts <- suppressWarnings(as.integer(strsplit(tolower(spec), "x", fixed = TRUE)[[1]]))

  if (length(parts) != 2L || anyNA(parts) || any(parts < 1L)) {
    stop("`BC_CONN_OMNISCAPE_BENCH` must look like \"2x3\" (rows x cols); got \"", spec, "\"")
  }

  parts
}

#' Collect the measured resource use of every Omniscape run
#'
#' Reads the `omniscape_metrics.csv` each run writes and combines them into the table the README
#' reports, so those figures are measured rather than transcribed by hand.
#'
#' @param omniscape_outputs character vector of files returned by [run_omniscape_all()]
#'
#' @returns path to the combined CSV, or `character(0)` when no runs have been made
#'
#' @export
omniscape_benchmark_table <- function(omniscape_outputs) {
  metrics <- grep("omniscape_metrics[.]csv$", omniscape_outputs, value = TRUE)

  if (length(metrics) == 0L) {
    return(character(0))
  }

  combined <- lapply(metrics, utils::read.csv) |>
    dplyr::bind_rows() |>
    dplyr::arrange(.data$pixel_size, .data$radius_px, .data$tiled) |>
    dplyr::mutate(
      wall_hours = round(.data$wall_seconds / 3600, 2),
      peak_rss_gb = round(.data$peak_rss_gb, 1)
    )

  dst <- file.path(get_path("outputs"), "omniscape_benchmarks.csv")
  utils::write.csv(combined, dst, row.names = FALSE)

  return(dst)
}


#' Memory cap for an Omniscape run
#'
#' Resolves the `MemoryMax` passed to the transient systemd scope that [run_omniscape()] launches
#' Omniscape in. A percentage is resolved by systemd against physical memory, so one value travels
#' correctly across hosts of different sizes -- 50% is ~488 GB on a 976 GB machine and ~503 GB on a
#' 1 TB one, which matches the per-project budget in use here.
#'
#' @param spec character; a systemd `MemoryMax` value -- either an absolute size (`"400G"`) or a
#'   percentage of physical memory (`"50%"`). `"none"` disables the guard. Defaults to
#'   `BC_CONN_OMNISCAPE_MEMMAX` if set, otherwise `"50%"`.
#'
#' @returns character scalar suitable for `systemd-run -p MemoryMax=`, or `NULL` for no cap
#'
#' @export
omniscape_memory_max <- function(spec = Sys.getenv("BC_CONN_OMNISCAPE_MEMMAX", "")) {
  if (!nzchar(spec)) {
    spec <- "50%"
  }

  if (identical(spec, "none")) {
    return(NULL)
  }

  if (!grepl("^[0-9]+(\\.[0-9]+)?([KMGT]|%)$", spec)) {
    stop(
      "`memory_max` must be a systemd MemoryMax value such as \"400G\" or \"50%\" ",
      "(or \"none\"), not: ",
      spec
    )
  }

  spec
}

#' Julia threads appropriate to one Omniscape configuration
#'
#' Thread count is not a global setting: Omniscape's scaling depends on the size of the moving
#' window. A configuration with many *small* windows gets **slower** with more threads; one with
#' few *large* windows is compute-bound and scales.
#'
#' The mechanism is the progress meter, not the current accumulator. `cum_currmap` is allocated
#' with a trailing `n_threads` dimension (`Omniscape/src/main.jl:218-226`), so each worker writes
#' its own slice and does not contend. `ProgressMeter` however holds a single global
#' `Threads.ReentrantLock` (`ProgressMeter.jl:80`) and takes it on every `next!` once threading is
#' detected, so a configuration with very many very short solves serialises on it -- the 90 m local
#' configuration calls `next!` 854,910 times around solves lasting a few ms.
#'
#' Measured on this study area: the 90 m local configuration (radius 29, ~3.5k cells per window,
#' ~855k windows) ran in 57 min at 8 threads and was on track for ~87 min at 32 -- 4.6x the CPU
#' time for the same work, with the threads busy but stalled. The 30 m regional configuration
#' (radius 1429, ~8.2M cells per window, ~3.3k windows) has ~2400x more compute per shared write
#' and shows no such collapse.
#'
#' The upper band is measured but the *ceiling* is not. On the r = 477 configuration (912k cells
#' per window) on a 128-core host, wall clock was 1841 s at 16 threads, 922 s at 40 (2.00x) and
#' 929 s at 48 -- so 40 threads is a solid, measured working point. It does **not** establish that
#' scaling stops there. That test had only 190 targets, i.e. 4 per thread at 48, and Julia's
#' `@threads` does **not** work-steal: `threading_run` creates exactly `threadpoolsize()` tasks
#' over *contiguous static chunks* (`base/threadingconstructs.jl:148,228`), and `:dynamic` refers
#' only to task migration, not to load balancing. Omniscape shuffles targets first
#' (`randperm`, `main.jl:210`), which equalises expected chunk cost but cannot reduce the variance
#' of a 4-sample mean -- so the critical path is whichever chunk drew the expensive targets, not
#' any hardware limit. Treat 40 as "measured to work well", not as a known optimum; the ceiling is
#' unmeasured and may be higher. A curve needs ~20+ targets per thread to be meaningful.
#'
#' Memory also scales linearly with threads (~9.3 GB/thread for the 30 m regional), which is the
#' other reason not to apply one number everywhere; [omniscape_memory_max()] is the backstop.
#' At 40 threads the 30 m regional projects to ~377 GB, inside the per-project budget; 48 would be
#' ~451 GB for no gain.
#'
#' @param config_file path to an Omniscape `config.ini`
#' @param max_threads integer, the most this will return
#'
#' @returns integer number of Julia threads
#'
#' @export
omniscape_threads <- function(config_file, max_threads = 64L) {
  radius <- as.numeric(read_omniscape_option(config_file, "radius"))
  window_cells <- (2 * radius + 1)^2

  ## Anchored at both ends by measurement; the middle band is interpolated and untested. Revisit
  ## with numbers rather than intuition if a configuration lands there.
  threads <- if (window_cells < 1e4) {
    8L ## contention-bound: measured slower at 32 than at 8
  } else if (window_cells < 2e5) {
    16L ## interpolated
  } else {
    ## Compute-bound. An 8-point sweep on this study area (radius 477, block_size 75, 1323 targets,
    ## tsuga) puts 64 at the top and still improving -- solve-phase seconds:
    ##
    ##   16    24    32    40    48    64
    ## 7616  5528  5054  4345  3980  3317      (64 is 2.30x over 16, and 1.31x over 40)
    ##
    ## Do NOT pin to a NUMA node here. Pinning gained 11% at 32 threads (5054 -> 4497 s) and LOST
    ## 54% at 64 (3317 -> 5123 s): one socket's memory controllers saturate before 64 threads are
    ## fed, and the default placement spreads across both.
    ##
    ## MEMORY, not speed, is what usually picks the thread count. It is linear in threads with a
    ## near-zero intercept -- per-thread solve workspace dominates, not the accumulator -- and the
    ## per-thread constant scales with WINDOW size, so it must be re-anchored per configuration:
    ##
    ##   radius  477, block_size  75   2.32 GB/thread   (8-point sweep, 16-64 threads)
    ##   radius 1429, block_size 143   9.57 GB/thread   (191.4 GB at 20 threads, 1970 samples)
    ##
    ## Both measured on this study area. The 30 m regional at 40 threads was predicted at 383 GB
    ## from the second row and peaked at 381.8 GB, so the model holds across a 2x thread
    ## extrapolation. Size the cap from it, and set the cap AT LAUNCH -- see `systemd_scope()`.
    64L
  }

  as.integer(min(threads, max_threads))
}

#' Thread count requested for Omniscape runs
#'
#' `BC_CONN_JULIA_THREADS` forces one value for every configuration. Unset -- the default -- gives
#' `NULL`, meaning "choose per configuration" via [omniscape_threads()], which is what the branched
#' `omniscape_run` target wants: the configurations differ by three orders of magnitude in window
#' size and do not share an optimum.
#'
#' @param spec character; an integer thread count, or `""` to choose per configuration
#'
#' @returns integer, or `NULL` to derive per configuration
#'
#' @export
omniscape_thread_setting <- function(spec = Sys.getenv("BC_CONN_JULIA_THREADS", "")) {
  if (!nzchar(spec)) {
    return(NULL)
  }

  as.integer(spec)
}

#' Is any Omniscape run selected?
#'
#' `targets` cannot branch over an empty vector -- `tar_make()` fails with "cannot branch over
#' empty target" -- and `BC_CONN_OMNISCAPE` defaults to `"none"`, which selects nothing. So
#' `_targets.R` has to decide at pipeline-definition time whether `omniscape_run` is a branched
#' target at all.
#'
#' @param which as for [select_omniscape_runs()]
#'
#' @returns `TRUE` if any Omniscape configuration is selected
#'
#' @export
omniscape_any_selected <- function(which = Sys.getenv("BC_CONN_OMNISCAPE", "none")) {
  choice <- match.arg(tolower(which), c("none", "nn", "alldist", "all"))

  !identical(choice, "none")
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
## NOTE: the pipeline no longer calls this. `omniscape_run` branches over
## `omniscape_scripts_to_run` instead, so one failed run does not discard the others and a
## completed run is not repeated. Kept for running several configurations by hand.
run_omniscape_all <- function(julia_scripts, julia_threads = NULL, ...) {
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
