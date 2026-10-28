## The omniscape project reads the layers the prep project published, rather than recomputing them
## or keeping a second copy. `district_input_layer()` is the reading half of `district_dst()`, so
## the two have to name the same file.
##
## Everything here that can run without built data does, because the suite has to pass in a clone
## with no `Data/` -- which is what CI has.

test_that("a published layer is returned by path", {
  dir <- withr::local_tempdir()
  file.create(file.path(dir, "BEC.gpkg"))

  expect_identical(
    district_input_layer("hundred_mile", "BEC.gpkg", dir = dir),
    file.path(dir, "BEC.gpkg")
  )
})

## A `format = "file"` target on a path that does not exist fails inside `targets` with a message
## naming neither the district nor the layer, a long way from "dataprep has not been built".
test_that("a layer that has not been built names itself and its district", {
  dir <- withr::local_tempdir()

  expect_error(
    district_input_layer("hundred_mile", "BEC.gpkg", dir = dir),
    "no BEC\\.gpkg for district 'hundred_mile'"
  )
})

test_that("a district key is accepted as well as a spec", {
  dir <- withr::local_tempdir()
  file.create(file.path(dir, "BEC.gpkg"))

  expect_identical(
    district_input_layer("hundred_mile", "BEC.gpkg", dir = dir),
    district_input_layer(district_spec("hundred_mile"), "BEC.gpkg", dir = dir)
  )
})

test_that("an unknown type is rejected rather than silently resolved", {
  expect_error(district_input_layer("hundred_mile", "BEC.gpkg", type = "outputs"))
})

## The seam itself: both halves must name the same file. Needs the layer to have been built, so it
## skips where it has not been -- the same way the frozen-archive test does.
test_that("the path is the one district_dst() writes to", {
  spec <- district_spec("hundred_mile")
  written <- file.path(district_path("inputs", spec), basename(district_dst(spec, "BEC.gpkg")))

  skip_if_not(file.exists(written), "dataprep layers not built")

  expect_identical(district_input_layer(spec, "BEC.gpkg"), written)
})

test_that("rasters are routed to the rasters directory, not inputs", {
  spec <- district_spec("hundred_mile")
  written <- file.path(district_path("rasters", spec), paste0(spec$key, "_LCC.tif"))

  skip_if_not(file.exists(written), "dataprep rasters not built")

  expect_identical(
    district_input_layer(spec, paste0(spec$key, "_LCC.tif"), "rasters"),
    written
  )
})
