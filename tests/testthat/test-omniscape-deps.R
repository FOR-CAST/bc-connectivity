## `omniscape_run` reads the composite rasters through a config file that holds only their paths.
## Until 2026-11-03 the run depended on nothing else, so a composite rebuilt with new values at the
## same path left the config, the script and the run all looking current: the GEOS 3.15 rebuild
## changed every Cariboo-Chilcotin and 100 Mile composite and `tar_make()` skipped both baselines.

flatten_targets <- function(x) {
  if (inherits(x, "tar_target")) list(x) else do.call(c, lapply(x, flatten_targets))
}

run_deps <- function(targets_list, name) {
  tl <- flatten_targets(targets_list)
  run <- Filter(function(t) identical(t$settings$name, name), tl)
  expect_length(run, 1L)
  targets::tar_deps_raw(run[[1]]$command$expr)
}

test_that("omniscape_run depends on the composite rasters themselves", {
  withr::local_package("targets")
  withr::local_envvar(BC_CONN_OMNISCAPE = "all")

  deps <- run_deps(omniscape_run_targets(), "omniscape_run")
  expect_true(all(c("resistance_composite", "sourcewt_composite") %in% deps))
})

test_that("each epoch's omniscape_run depends on that epoch's composites", {
  withr::local_package("targets")
  withr::local_envvar(BC_CONN_OMNISCAPE = "all")

  deps <- run_deps(historical_omniscape_targets(2005L), "omniscape_run_2005")
  expect_true(all(c("resistance_composite_2005", "sourcewt_composite_2005") %in% deps))
})
