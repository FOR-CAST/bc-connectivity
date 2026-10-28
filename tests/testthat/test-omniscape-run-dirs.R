## `run_omniscape()` returns five FILES per run, not a run directory, and the consumers that work
## per run were written against directories. The mismatch is invisible until a run actually exists:
## every one of these targets returns early on an empty vector, and with `BC_CONN_OMNISCAPE` unset
## that is the usual path, so the pipeline reported them as built for as long as nothing had run.

## the shape `run_omniscape()` actually returns, for a two-configuration district
omniscape_outputs <- function(root = "Outputs") {
  runs <- c("2026-08-26_hundred_mile_p90_r29_bs3", "2026-08-26_hundred_mile_p90_r477_bs49")
  files <- c(
    "cum_currmap.tif",
    "flow_potential.tif",
    "normalized_cum_currmap.tif",
    "omniscape_run.log",
    "omniscape_metrics.csv"
  )
  as.vector(outer(runs, files, function(r, f) file.path(root, r, f)))
}

test_that("one run directory comes back per run, not one per output file", {
  dirs <- omniscape_run_dirs(omniscape_outputs())

  expect_length(dirs, 2L)
  expect_identical(
    basename(dirs),
    c(
      "2026-08-26_hundred_mile_p90_r29_bs3",
      "2026-08-26_hundred_mile_p90_r477_bs49"
    )
  )
})

## The defect this pins: handed the file vector, the consumers appended the raster name to a path
## that already ended in one, giving `.../cum_currmap.tif/normalized_cum_currmap.tif`.
test_that("the selected directory holds the raster the consumers go on to read", {
  dirs <- omniscape_run_dirs(omniscape_outputs())

  expect_true(all(
    file.path(dirs, "normalized_cum_currmap.tif") %in% omniscape_outputs()
  ))
})

test_that("directories pass through, so a finished run can be pointed at by path", {
  dir <- withr::local_tempdir()

  expect_identical(omniscape_run_dirs(dir), dir)
})

test_that("a run that wrote no normalized current map contributes no directory", {
  ## `calc_normalized_current` is off by default in Omniscape, and the category rasters are a
  ## reclassification of exactly that layer -- so its absence means there is nothing to do, not a
  ## directory to visit and fail in.
  partial <- c("Outputs/run_a/cum_currmap.tif", "Outputs/run_a/omniscape_run.log")

  expect_identical(omniscape_run_dirs(partial), character(0))
})

test_that("no runs gives no directories, whichever empty shape targets hands over", {
  expect_identical(omniscape_run_dirs(character(0)), character(0))
  expect_identical(omniscape_run_dirs(list()), character(0))
  expect_identical(omniscape_run_dirs(NULL), character(0))
})

## `omniscape_run` is a branched `format = "file"` target, so its value can arrive as a list of
## per-branch character vectors rather than one flat vector.
test_that("branch output arriving as a list is flattened, not treated as one element", {
  flat <- omniscape_run_dirs(omniscape_outputs())
  nested <- omniscape_run_dirs(split(omniscape_outputs(), rep(1:2, each = 5)))

  expect_identical(sort(nested), sort(flat))
})
