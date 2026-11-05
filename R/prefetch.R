## Shared inputs, fetched once ------------------------------------------------------------------
##
## `Data/raw` is district-blind by design: the provincial layers underneath every district are the
## same bytes, and on this setup that directory is one NFS export shared by every machine. That is
## what makes it possible to run the three districts concurrently on three hosts -- and it is also
## the one place where those runs can collide.
##
## The collision is not hypothetical. Every call site used to be guarded by `!file.exists()` and
## then download straight to the final path, so two pipelines starting within the same minute both
## see the file missing, both download, and both write the same destination. The loser does not
## fail; it produces a truncated raster that reads without error.
##
## Nothing here is new data. It is the same fetch the `get_*` functions did inline, moved to one
## target that runs before them, made idempotent, and made safe to run from several hosts at once.

## CanLaD and CanLaBS, the national 30 m Landsat disturbance products behind `R/landsat_resets.R`.
## Each release goes in its own versioned subdirectory, so a new one lands beside the old rather
## than over it. `files` are relative to that directory and named for what `write_landsat_resets()`
## reads them as.
LANDSAT_DISTURBANCE <- list(
  canlad = list(
    url = paste0(
      "https://ftp.maps.canada.ca/pub/nrcan_rncan/Forests_Foret/",
      "canlad_including_insect_defoliation/v1.1/TS_FinalFilter_20260508"
    ),
    dir = file.path("CanLaD", "v1.1_20260508"),
    files = stats::setNames(
      sprintf("canlad_annual_%d_v1_1_20260508.tif", 1985:2024),
      paste0("canlad_", 1985:2024)
    )
  ),
  canlabs = list(
    url = paste0(
      "https://ftp.maps.canada.ca/pub/nrcan_rncan/Forest-fires_Incendie-de-foret/",
      "CanLaBS_v2-Burned_Severity-Severite_des_feux"
    ),
    dir = file.path("CanLaBS", "v2_20260121"),
    files = c(
      canlabs_dnbr = "CanLaBS_1985_2024_v20260121.tif",
      canlabs_nbac = "NBAC_MRB_1972to2024_reproj.tif",
      canlabs_salvage = "CanLaBS_salvageMask_1985_2024_v20260121.tif"
    )
  )
)

## `LANDSAT_DISTURBANCE` as `SHARED_INPUT_SOURCES` entries.
landsat_input_sources <- function() {
  src <- lapply(LANDSAT_DISTURBANCE, function(p) {
    Map(function(f) list(url = paste(p$url, f, sep = "/"), file = file.path(p$dir, f)), p$files)
  })
  stats::setNames(
    unlist(src, recursive = FALSE),
    unlist(lapply(LANDSAT_DISTURBANCE, \(p) names(p$files)))
  )
}

## The province-wide layers this pipeline fetches for itself. The CEF Forest Disturbance geodatabase
## is deliberately absent: it is a Custom Product that is not publicly distributed, so it has to be
## put in place by hand and `get_forest_disturbance()` says so when it is missing.
SHARED_INPUT_SOURCES <- c(
  list(
    landcover = list(
      url = paste0(
        "https://datacube-prod-data-public.s3.ca-central-1.amazonaws.com",
        "/store/land/landcover/landcover-2020-classification.tif"
      ),
      file = "landcover-2020-classification.tif"
    ),
    cef_human_disturbance = list(
      url = "https://coms.api.gov.bc.ca/api/v1/object/ecea4b04-055a-49d1-8910-60d726d2d1bf",
      file = "BC_CEF_Human_Disturbance_2023.zip"
    )
  ),
  landsat_input_sources()
)

## Who holds a lock, for an error message. A lock directory with no holder file is not an error
## worth raising from inside the path that is already reporting a different one.
lock_holder <- function(lock_dir) {
  f <- file.path(lock_dir, "holder")

  if (!file.exists(f)) {
    return("unknown")
  }

  paste(readLines(f, warn = FALSE), collapse = " ")
}

#' Acquire an advisory lock shared across districts and hosts
#'
#' `dir.create()` is the lock primitive rather than [filelock::lock()] for two reasons. It is
#' atomic over NFS -- a single `MKDIR` that returns `EEXIST` to everyone but the winner -- whereas
#' POSIX record locks need a working lock manager on the mount and degrade *silently* without one,
#' which is the failure mode least worth having in the thing whose whole job is preventing silent
#' corruption. And it needs no new package, so nothing has to be installed into a project library
#' that live pipelines are loading from.
#'
#' The cost is that a crashed holder leaves the directory behind and nothing else would ever clear
#' it, so the wait breaks a lock older than `stale_after` and says that it did.
#'
#' @param lock_dir directory to create as the lock.
#' @param timeout seconds to wait before giving up.
#' @param stale_after seconds after which an existing lock is treated as abandoned. Must comfortably
#'   exceed a real fetch: the largest file here is 2 GB.
#'
#' @returns invisibly `TRUE`; errors if the lock cannot be acquired.
#'
#' @export
shared_lock_acquire <- function(lock_dir, timeout = 3600, stale_after = 7200) {
  deadline <- Sys.time() + timeout

  repeat {
    if (dir.create(lock_dir, showWarnings = FALSE)) {
      ## who to blame, and when, if this is ever found abandoned
      writeLines(
        paste(Sys.info()[["nodename"]], Sys.getpid(), format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")),
        file.path(lock_dir, "holder")
      )
      return(invisible(TRUE))
    }

    age <- difftime(Sys.time(), file.info(lock_dir)$mtime, units = "secs")

    if (!is.na(age) && as.numeric(age) > stale_after) {
      warning(
        "breaking an abandoned prefetch lock ",
        round(as.numeric(age)),
        "s old, held by: ",
        lock_holder(lock_dir),
        call. = FALSE
      )
      unlink(lock_dir, recursive = TRUE)
      next
    }

    if (Sys.time() > deadline) {
      stop(
        "timed out after ",
        timeout,
        "s waiting for the prefetch lock at ",
        lock_dir,
        "; it is held by: ",
        lock_holder(lock_dir),
        call. = FALSE
      )
    }

    Sys.sleep(5)
  }
}

#' Download a file to its final path, or leave an existing one alone
#'
#' The download lands on `<dst>.part-<pid>` and is then renamed. Rename is atomic within a
#' directory, so no reader ever sees a partial file and a failed transfer leaves nothing behind for
#' the next run to mistake for a complete one. That property holds whether or not the lock does its
#' job, which is the point of having both.
#'
#' A transfer that drops after making progress is resumed from where it stopped, up to `attempts`
#' times: the federal FTP mirror serving CanLaD and CanLaBS routinely cuts off long transfers, and
#' restarting a 1.75 GB file from zero each time need never finish. A transfer that fails without
#' making progress -- a 404, an unreachable host -- is an error at once.
#'
#' @param url source URL.
#' @param dst final path; its directory is created if need be.
#' @param timeout seconds allowed for each attempt.
#' @param attempts the most transfers to try per fetch.
#' @param validate optional function of the downloaded path, `TRUE` when the file is intact. A
#'   resumed transfer from the CanLaD mirror once came back the right length with 12 KB of it taken
#'   from the wrong offset, so length alone is not evidence of a good file, and the mirror publishes
#'   no checksums. A file that fails is discarded and fetched again from the start.
#' @param fresh the most complete fetches to try when `validate` rejects them.
#'
#' @returns `dst`.
#'
#' @export
download_atomic <- function(
  url,
  dst,
  timeout = 3600,
  attempts = 30,
  validate = NULL,
  fresh = 3
) {
  if (file.exists(dst)) {
    return(dst)
  }

  fs::dir_create(dirname(dst))
  part <- paste0(dst, ".part-", Sys.getpid())
  on.exit(unlink(part), add = TRUE)

  for (k in seq_len(fresh)) {
    for (i in seq_len(attempts)) {
      have <- if (file.exists(part)) file.size(part) else 0
      done <- tryCatch(
        {
          fetch_append(url, part, timeout = timeout)
          TRUE
        },
        error = function(e) {
          progressed <- file.exists(part) && file.size(part) > have
          if (!progressed || i == attempts) {
            stop("download of ", url, " failed: ", conditionMessage(e), call. = FALSE)
          }
          FALSE
        }
      )
      if (done) {
        break
      }
    }

    if (is.null(validate) || validate(part)) {
      break
    }
    unlink(part)
    if (k == fresh) {
      stop("download of ", url, " is corrupt after ", fresh, " complete fetches", call. = FALSE)
    }
  }

  if (!file.rename(part, dst)) {
    stop("could not move the completed download into place: ", dst, call. = FALSE)
  }

  dst
}

## `TRUE` when GDAL can read every block of the raster at `path`. A corrupt compressed tile is
## only found by decoding it, so this computes the full checksum; GDAL reports a bad tile as a
## warning, not an error.
raster_reads_whole <- function(path) {
  tryCatch(
    {
      sf::gdal_utils("info", path, options = "-checksum", quiet = TRUE)
      TRUE
    },
    warning = function(w) FALSE,
    error = function(e) FALSE
  )
}

## Fetch `url` onto the end of `part`, starting from the bytes already there.
##
## Streams straight into `part` rather than going through `curl::curl_download()`, which writes to
## `<part>.curltmp` and renames only on success: a dropped transfer then leaves `part` untouched, so
## nothing could ever be resumed. A connection that delivers nothing for `stall` seconds is dropped
## rather than left to hold the attempt for its whole `timeout`.
fetch_append <- function(url, part, timeout = 3600, stall = 120) {
  have <- if (file.exists(part)) file.size(part) else 0
  con <- file(part, open = if (have > 0) "ab" else "wb")
  on.exit(close(con), add = TRUE)

  h <- curl::new_handle(
    resume_from = have,
    timeout = timeout,
    low_speed_limit = 1,
    low_speed_time = stall,
    failonerror = TRUE
  )
  curl::curl_fetch_stream(url, function(x) writeBin(x, con), handle = h)
  invisible(part)
}

#' Fetch the province-wide inputs every district shares
#'
#' Runs before anything that reads them, so the `get_*` functions find their inputs present and
#' never download inline. Safe to run concurrently from several districts and several hosts: one
#' caller fetches and the rest wait and then find the files already there.
#'
#' Also warms `bcmaps`' CDED tile cache when given an area of interest. That cache is shared and
#' `bcmaps` owns the writes into it, so it cannot be made atomic from here -- but serialising the
#' *calls* is enough, because the only racers are this project's own pipelines.
#'
#' @param dest_dir directory for the shared downloads, i.e. `district_path("download", district)`.
#' @param aoi optional `sf`/`SpatVector` area of interest whose CDED tiles should be cached.
#' @param sources list of `list(url =, file =)`; defaults to [SHARED_INPUT_SOURCES]. An argument so
#'   the fetch can be exercised against local files in tests.
#'
#' @returns paths to the fetched files, for a `format = "file"` target to track.
#'
#' @export
prefetch_shared_inputs <- function(dest_dir, aoi = NULL, sources = SHARED_INPUT_SOURCES) {
  fs::dir_create(dest_dir)

  lock_dir <- file.path(dest_dir, ".prefetch.lock")
  shared_lock_acquire(lock_dir)
  on.exit(unlink(lock_dir, recursive = TRUE), add = TRUE)

  fetched <- vapply(
    sources,
    function(src) {
      download_atomic(
        src$url,
        file.path(dest_dir, src$file),
        validate = if (grepl("[.]tif$", src$file)) raster_reads_whole
      )
    },
    character(1),
    USE.NAMES = FALSE
  )

  ## The CEF human-disturbance layer is read from the geodatabase inside the zip. Extract to a
  ## private directory and rename it into place, for the same reason the downloads do: a partial
  ## extraction left at the final path would be indistinguishable from a complete one.
  cef_dir <- file.path(dest_dir, "BC_CEF_Human_Disturbance_2023")

  if ("cef_human_disturbance" %in% names(sources) && !dir.exists(cef_dir)) {
    staging <- file.path(dest_dir, paste0(".extract-", Sys.getpid()))
    on.exit(unlink(staging, recursive = TRUE), add = TRUE)
    fs::dir_create(staging)

    archive::archive_extract(
      file.path(dest_dir, "BC_CEF_Human_Disturbance_2023.zip"),
      dir = staging
    )

    if (!file.rename(file.path(staging, basename(cef_dir)), cef_dir)) {
      stop("could not move the extracted CEF human-disturbance data into place", call. = FALSE)
    }
  }

  if (!is.null(aoi)) {
    ## the VRT is a throwaway: what is wanted is the side effect on the tile cache
    bcmaps::cded_terra(aoi = aoi, dest_vrt = tempfile(fileext = ".vrt"))
  }

  fetched
}

#' Pick one shared input out of what [prefetch_shared_inputs()] returned
#'
#' Takes the vector rather than the directory so that a target command naming it acquires a real
#' dependency on the fetch, instead of merely happening to run after it. Matching on the filename
#' rather than on position keeps that independent of the order of [SHARED_INPUT_SOURCES].
#'
#' @param paths character vector from [prefetch_shared_inputs()].
#' @param which name in [SHARED_INPUT_SOURCES].
#'
#' @returns path to the file.
#'
#' @export
shared_input_path <- function(paths, which) {
  src <- SHARED_INPUT_SOURCES[[match.arg(which, names(SHARED_INPUT_SOURCES))]]
  hit <- paths[basename(paths) == basename(src$file)]

  if (!length(hit)) {
    stop(
      "shared input `",
      src$file,
      "` is not among the fetched inputs: ",
      paste(basename(paths), collapse = ", "),
      call. = FALSE
    )
  }

  hit[[1]]
}
