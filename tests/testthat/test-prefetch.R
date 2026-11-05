## `Data/raw` is one shared directory that concurrent district runs on different hosts all write
## into, so the cases that matter are the ones where two callers arrive at once. The defect being
## guarded against is silent: a second writer used to truncate the first's file, and a truncated
## raster reads without error.

test_that("a lock is held by exactly one caller", {
  d <- file.path(withr::local_tempdir(), "lock")

  expect_true(shared_lock_acquire(d))
  expect_true(dir.exists(d))
  ## a second caller with no patience gets an error naming the holder, not the lock
  expect_error(shared_lock_acquire(d, timeout = 0), "timed out")
  expect_error(shared_lock_acquire(d, timeout = 0), Sys.info()[["nodename"]])
})

test_that("a lock is reacquirable once released", {
  d <- file.path(withr::local_tempdir(), "lock")

  shared_lock_acquire(d)
  unlink(d, recursive = TRUE)

  expect_true(shared_lock_acquire(d, timeout = 0))
})

test_that("an abandoned lock is broken rather than waited on forever", {
  d <- file.path(withr::local_tempdir(), "lock")
  dir.create(d)
  Sys.setFileTime(d, Sys.time() - 10000)

  expect_warning(shared_lock_acquire(d, timeout = 0, stale_after = 100), "abandoned")
  expect_true(dir.exists(d))
})

test_that("a lock with no holder file still reports rather than erroring", {
  d <- file.path(withr::local_tempdir(), "lock")
  dir.create(d)

  expect_error(shared_lock_acquire(d, timeout = 0), "unknown")
})

test_that("a download lands atomically and leaves no partial file behind", {
  src <- withr::local_tempfile()
  writeLines("payload", src)
  dest_dir <- withr::local_tempdir()
  dst <- file.path(dest_dir, "fetched.txt")

  expect_identical(download_atomic(paste0("file://", normalizePath(src)), dst), dst)
  expect_identical(readLines(dst), "payload")
  expect_length(list.files(dest_dir, pattern = "[.]part-"), 0L)
})

test_that("a download that has already happened is not repeated", {
  dest_dir <- withr::local_tempdir()
  dst <- file.path(dest_dir, "fetched.txt")
  writeLines("original", dst)

  ## an unreachable URL, so a second fetch would fail rather than silently succeed
  expect_identical(download_atomic("file:///nonexistent/source", dst), dst)
  expect_identical(readLines(dst), "original")
})

test_that("a failed download leaves nothing for the next run to mistake for a complete file", {
  dest_dir <- withr::local_tempdir()
  dst <- file.path(dest_dir, "fetched.txt")

  expect_error(suppressWarnings(download_atomic("file:///nonexistent/source", dst)))
  expect_false(file.exists(dst))
  expect_length(list.files(dest_dir, all.files = TRUE, pattern = "[.]part-"), 0L)
})

test_that("shared inputs are selected by name, not by position", {
  paths <- c(
    "/somewhere/BC_CEF_Human_Disturbance_2023.zip",
    "/elsewhere/landcover-2020-classification.tif"
  )

  expect_identical(
    shared_input_path(paths, "landcover"),
    "/elsewhere/landcover-2020-classification.tif"
  )
  expect_error(shared_input_path(paths[1], "landcover"), "not among the fetched inputs")
})

test_that("prefetch fetches once and is a no-op thereafter", {
  src <- withr::local_tempfile()
  writeLines("payload", src)
  sources <- list(demo = list(url = paste0("file://", normalizePath(src)), file = "demo.txt"))
  dest_dir <- withr::local_tempdir()

  first <- prefetch_shared_inputs(dest_dir, sources = sources)
  expect_identical(basename(first), "demo.txt")
  ## the lock is released, so a second call proceeds rather than blocking
  expect_identical(prefetch_shared_inputs(dest_dir, sources = sources), first)
  expect_false(dir.exists(file.path(dest_dir, ".prefetch.lock")))
})

test_that("a download into a versioned subdirectory creates it", {
  src <- withr::local_tempfile()
  writeLines("payload", src)
  dst <- file.path(withr::local_tempdir(), "CanLaD", "v1", "fetched.txt")

  expect_identical(download_atomic(paste0("file://", normalizePath(src)), dst), dst)
  expect_identical(readLines(dst), "payload")
})

test_that("a shared input in a subdirectory is selected by its file name", {
  paths <- file.path("/raw", "CanLaBS", "v2_20260121", "NBAC_MRB_1972to2024_reproj.tif")

  expect_identical(shared_input_path(paths, "canlabs_nbac"), paths)
})

test_that("every CanLaD year and CanLaBS layer is a shared input", {
  src <- landsat_input_sources()

  expect_length(src, 43L)
  expect_true(all(c("canlad_1985", "canlad_2024", "canlabs_dnbr") %in% names(SHARED_INPUT_SOURCES)))
  expect_identical(
    src$canlad_2003$file,
    file.path("CanLaD", "v1.1_20260508", "canlad_annual_2003_v1_1_20260508.tif")
  )
  expect_match(src$canlad_2003$url, "/canlad_annual_2003_v1_1_20260508[.]tif$")
})

test_that("an interrupted transfer resumes from the bytes already fetched", {
  src <- withr::local_tempfile()
  writeBin(as.raw(0:255), src)
  part <- withr::local_tempfile()
  ## the first 100 bytes, as a dropped transfer would have left them
  writeBin(as.raw(0:99), part)

  fetch_append(paste0("file://", normalizePath(src)), part)

  expect_identical(readBin(part, "raw", 1000), as.raw(0:255))
})

test_that("a fetch the validator rejects is discarded and fetched again", {
  src <- withr::local_tempfile()
  writeLines("payload", src)
  url <- paste0("file://", normalizePath(src))
  dest_dir <- withr::local_tempdir()

  calls <- 0
  flaky <- function(path) {
    calls <<- calls + 1
    calls > 1
  }
  dst <- file.path(dest_dir, "fetched.txt")
  expect_identical(download_atomic(url, dst, validate = flaky), dst)
  expect_equal(calls, 2)

  never <- file.path(dest_dir, "never.txt")
  expect_error(download_atomic(url, never, validate = function(p) FALSE), "corrupt after 3")
  expect_false(file.exists(never))
  expect_length(list.files(dest_dir, all.files = TRUE, pattern = "[.]part-"), 0L)
})

test_that("a raster with a corrupted tile does not read whole", {
  f <- withr::local_tempfile(fileext = ".tif")
  r <- terra::rast(nrows = 512, ncols = 512, vals = seq_len(512 * 512) %% 251, crs = "local")
  terra::writeRaster(r, f, datatype = "INT2U", gdal = c("COMPRESS=DEFLATE", "TILED=YES"))
  expect_true(raster_reads_whole(f))

  ## overwrite a stretch in the middle, as a resume from the wrong offset did
  bytes <- readBin(f, "raw", file.size(f))
  mid <- length(bytes) %/% 2
  bytes[mid + 0:4095] <- bytes[100 + 0:4095]
  writeBin(bytes, f)
  expect_false(raster_reads_whole(f))
})
