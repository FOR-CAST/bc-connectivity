## `write_omniscape_config()` used to write every district's configs to the repository-level
## `Omniscape/<run>/`, ignoring the district, so Cariboo-Chilcotin's and 100 Mile's landed flat beside
## `Omniscape/quesnel/`. Quesnel's were only under `quesnel/` because they had been moved by hand,
## which left their `script.jl` pointing at the old flat path.

test_that("configs and scripts are written under config_dir, and the script points there", {
  ## the writer writes relative to the project root, which `get_path()` takes from the working
  ## directory here -- so work inside the temporary directory, never in the repository
  tmp <- withr::local_tempdir()
  withr::local_dir(tmp)
  r <- terra::rast(nrows = 20, ncols = 20, xmin = 0, xmax = 1800, ymin = 0, ymax = 1800, vals = 1)
  terra::crs(r) <- "EPSG:3979"
  res <- file.path(tmp, "res.tif")
  src <- file.path(tmp, "src.tif")
  terra::writeRaster(r, res)
  terra::writeRaster(r, src)
  config_dir <- file.path(tmp, "Omniscape", "chilcotin")

  out <- write_omniscape_config(
    res = res,
    srcwt = src,
    patch_distances = c(`100%` = 900),
    q = 100,
    run_name = "test",
    ntiles = c(1, 1),
    outputs_dir = file.path(tmp, "Outputs"),
    config_dir = config_dir
  )

  ## 900 m at 90 m pixels is a 10 px radius, and a 1 px block
  run_dir <- file.path(config_dir, "test_p90_r10_bs1")
  expect_true(file.exists(file.path(run_dir, "config.ini")))
  expect_true(file.exists(file.path(run_dir, "script.jl")))

  script <- readLines(file.path(run_dir, "script.jl"))
  expect_match(script[2], "Omniscape/chilcotin/test_p90_r10_bs1/config.ini", fixed = TRUE)
})
