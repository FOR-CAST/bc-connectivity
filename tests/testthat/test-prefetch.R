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
