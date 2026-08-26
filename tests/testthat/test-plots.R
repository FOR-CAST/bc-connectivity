## The seral map is a visual check that the patch-construction fixes took, so rasterising it for
## display must not change what it shows. These cases are laid out on the display grid exactly, so
## the class areas have closed-form answers.

skip_if_not_installed("terra")
skip_if_not_installed("ggplot2")

band <- function(xmin, xmax) {
  sf::st_polygon(list(rbind(
    c(xmin, 0),
    c(xmax, 0),
    c(xmax, 1000),
    c(xmin, 1000),
    c(xmin, 0)
  )))
}

## three vertical bands across [0, 1000] x [0, 1000], on 100 m boundaries
seral_bands <- function() {
  sf::st_sf(
    Seral = c("Old", "Mature", "Mid"),
    geom = sf::st_sfc(band(0, 300), band(300, 600), band(600, 1000), crs = CRS_FIXTURE)
  )
}

test_that("rasterising for display preserves class areas exactly", {
  r <- seral_display_raster(seral_bands(), res = 100)

  ## each 100 m cell is exactly 1 ha, and the bands are 3, 3 and 4 cells wide by 10 cells tall
  counts <- table(terra::values(r, dataframe = TRUE)[[1]])

  expect_equal(as.integer(counts[["Old"]]), 30L)
  expect_equal(as.integer(counts[["Mature"]]), 30L)
  expect_equal(as.integer(counts[["Mid"]]), 40L)
})

test_that("unclassified stands survive rasterising as their own class", {
  ## `Seral` is NA for unclassified stands, and a rasterised NA is indistinguishable from a cell no
  ## polygon covers -- which silently dropped the unclassified panel from the figure.
  v <- seral_bands()
  v$Seral[v$Seral == "Mid"] <- NA ## the 400 m band, 40 cells

  r <- seral_display_raster(v, res = 100)
  counts <- table(terra::values(r, dataframe = TRUE)[[1]])

  expect_equal(as.integer(counts[[SERAL_UNCLASSIFIED]]), 40L)
  expect_false(SERAL_UNCLASSIFIED %in% v$Seral)
})

test_that("no seral class is dropped by rasterising", {
  v <- seral_bands()
  r <- seral_display_raster(v, res = 100)

  expect_setequal(as.character(terra::levels(r)[[1]][[2]]), sort(unique(v$Seral)))
})

test_that("the seral map is written to the directory it is given", {
  dir <- withr::local_tempdir()
  sa <- sf::st_sf(geom = sf::st_sfc(band(0, 1000), crs = CRS_FIXTURE))

  out <- plot_forest_disturbance_seral(seral_bands(), sa, "seral.png", outdir = dir)

  expect_equal(out, file.path(dir, "seral.png"))
  expect_true(file.exists(out))
  expect_gt(file.size(out), 0)
})
