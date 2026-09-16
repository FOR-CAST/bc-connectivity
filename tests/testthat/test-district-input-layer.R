## The omniscape project reads the layers the prep project published, rather than recomputing them
## or keeping a second copy. `district_input_layer()` is the reading half of `district_dst()`, so
## the two have to name the same file.

test_that("the path is the one district_dst() writes to", {
  spec <- district_spec("hundred_mile")

  written <- file.path(district_path("inputs", spec), basename(district_dst(spec, "BEC.gpkg")))

  expect_identical(
    district_input_layer(spec, "BEC.gpkg"),
    written
  )
})

test_that("rasters are routed to the rasters directory, not inputs", {
  spec <- district_spec("hundred_mile")

  expect_identical(
    district_input_layer(spec, paste0(spec$key, "_LCC.tif"), "rasters"),
    file.path(district_path("rasters", spec), paste0(spec$key, "_LCC.tif"))
  )
})

test_that("a district key is accepted as well as a spec", {
  expect_identical(
    district_input_layer("hundred_mile", "BEC.gpkg"),
    district_input_layer(district_spec("hundred_mile"), "BEC.gpkg")
  )
})

## A `format = "file"` target on a path that does not exist fails inside `targets` with a message
## naming neither the district nor the layer, a long way from "dataprep has not been built".
test_that("a layer that has not been built names itself and its district", {
  expect_error(
    district_input_layer("hundred_mile", "not_a_layer.gpkg"),
    "no not_a_layer\\.gpkg for district 'hundred_mile'"
  )
})
