## A run stopped before its first write leaves an empty output directory. The guard that refuses
## to delete anything that does not look like Omniscape output used to refuse that too, which
## stopped both epoch pipelines on 2026-11-03.

test_that("an empty output directory is cleared", {
  dir <- file.path(withr::local_tempdir(), "run")
  dir.create(dir)

  clear_omniscape_output_dir(dir)
  expect_false(dir.exists(dir))
})

test_that("a previous run's output is cleared", {
  dir <- file.path(withr::local_tempdir(), "run")
  dir.create(dir)
  file.create(file.path(dir, "cum_currmap.tif"))

  clear_omniscape_output_dir(dir)
  expect_false(dir.exists(dir))
})

test_that("a directory holding something else is left alone", {
  dir <- file.path(withr::local_tempdir(), "run")
  dir.create(dir)
  file.create(file.path(dir, "notes.txt"))

  expect_error(clear_omniscape_output_dir(dir), "does not look like Omniscape output")
  expect_true(file.exists(file.path(dir, "notes.txt")))
})

test_that("hidden files count as contents", {
  dir <- file.path(withr::local_tempdir(), "run")
  dir.create(dir)
  file.create(file.path(dir, ".keep"))

  expect_error(clear_omniscape_output_dir(dir), "does not look like Omniscape output")
  expect_true(dir.exists(dir))
})

test_that("overwrite = FALSE refuses even an empty directory", {
  dir <- file.path(withr::local_tempdir(), "run")
  dir.create(dir)

  expect_error(clear_omniscape_output_dir(dir, overwrite = FALSE), "overwrite = FALSE")
  expect_true(dir.exists(dir))
})
