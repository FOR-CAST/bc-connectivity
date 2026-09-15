## The thread count is the memory control on a shared host -- memory is linear in threads with a
## near-zero intercept -- so the ceiling has to hold against both ways of asking for threads.

test_that("the default ceiling is the top of the measured sweep", {
  withr::with_envvar(c(BC_CONN_JULIA_THREADS_MAX = NA), {
    expect_identical(omniscape_thread_cap(), 64L)
  })
})

test_that("the ceiling is read from the environment", {
  withr::with_envvar(c(BC_CONN_JULIA_THREADS_MAX = "16"), {
    expect_identical(omniscape_thread_cap(), 16L)
  })
})

## `expect_snapshot()` needs testthat edition 3, which this suite is not on -- there is no
## DESCRIPTION to declare it, since this is an analysis project rather than a package.
test_that("a ceiling that is not a positive integer is an error, not a silent default", {
  expect_error(omniscape_thread_cap("many"), "must be a positive integer")
  expect_error(omniscape_thread_cap("0"), "must be a positive integer")
})

test_that("the ceiling clips the per-configuration choice", {
  cfg <- withr::local_tempfile(fileext = ".ini")
  ## radius 477 is the 90 m regional configuration: compute-bound, so unclipped it asks for 64
  writeLines(c("[Options]", "radius = 477"), cfg)

  expect_identical(omniscape_threads(cfg), 64L)
  expect_identical(omniscape_threads(cfg, max_threads = 16L), 16L)
})

test_that("the ceiling does not raise a configuration that wants fewer", {
  cfg <- withr::local_tempfile(fileext = ".ini")
  ## radius 29 is the 90 m local configuration: contention-bound, measured slower at 32 than at 8
  writeLines(c("[Options]", "radius = 29"), cfg)

  expect_identical(omniscape_threads(cfg, max_threads = 48L), 8L)
})
