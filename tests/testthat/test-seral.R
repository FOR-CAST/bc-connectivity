## Seral stage assignment must be an OVERLAY, not a spatial join: a stand spanning two NDT-BEC
## zones has to be split at the zone boundary and each piece classified on its own thresholds.

skip_if_not_installed("terra")
skip_if_not_installed("spatialutils")

## NDT3-SBS: Mature 100, Old 140  |  NDT2-SBS: Mature 100, Old 250
## A stand aged 200 is therefore Old in NDT3-SBS and Mature in NDT2-SBS.
seral_overlay_fixture <- function(dir) {
  band <- function(xmin, xmax) {
    sf::st_polygon(list(rbind(
      c(xmin, 0),
      c(xmax, 0),
      c(xmax, 1000),
      c(xmin, 1000),
      c(xmin, 0)
    )))
  }

  vri <- sf::st_sf(
    NDT_BEC = c("NDT3-SBS", "NDT2-SBS"),
    geom = sf::st_sfc(band(0, 1000), band(1000, 2000), crs = CRS_FIXTURE)
  )

  ## one stand, spanning both zones
  fd <- sf::st_sf(
    SIFA = 200,
    geom = sf::st_sfc(band(0, 2000), crs = CRS_FIXTURE)
  )

  fd_gpkg <- file.path(dir, "fd.gpkg")
  vri_gpkg <- file.path(dir, "vri.gpkg")
  sf::st_write(fd, fd_gpkg, quiet = TRUE, append = FALSE)
  sf::st_write(vri, vri_gpkg, quiet = TRUE, append = FALSE)

  tile <- sf::st_sf(
    tile = 1L,
    geom = sf::st_sfc(band(-100, 2100), crs = CRS_FIXTURE)
  )

  list(fd = fd_gpkg, vri = vri_gpkg, tile = tile)
}

test_that("a stand spanning two NDT-BEC zones is split, not duplicated", {
  fx <- seral_overlay_fixture(withr::local_tempdir())
  out <- create_forest_disturbance_seral(fx$fd, fx$vri, fx$tile, max_age = 400)

  ## split into exactly two pieces, one per zone -- st_join() would have returned two *full-extent*
  ## copies of the stand instead, doubling the area
  expect_equal(nrow(out), 2L)
  expect_equal(area_ha(out), 2000 * 1000 / 1e4, tolerance = 1e-6)

  d <- as.data.frame(out)
  expect_equal(d$Seral[d$NDT_BEC == "NDT3-SBS"], "Old")
  expect_equal(d$Seral[d$NDT_BEC == "NDT2-SBS"], "Mature")
})

test_that("stands younger than 20 years are flagged", {
  dir <- withr::local_tempdir()
  fx <- seral_overlay_fixture(dir)

  young <- sf::st_read(fx$fd, quiet = TRUE)
  young$SIFA <- 10
  sf::st_write(young, fx$fd, quiet = TRUE, append = FALSE, delete_dsn = TRUE)

  out <- create_forest_disturbance_seral(fx$fd, fx$vri, fx$tile, max_age = 400)
  d <- as.data.frame(out)

  expect_setequal(d$Seral, "Early")
  expect_setequal(d$early_less_20yrs, "under_20")
})

test_that("a tile with no overlapping features returns an empty layer", {
  fx <- seral_overlay_fixture(withr::local_tempdir())
  far <- sf::st_sf(
    tile = 1L,
    geom = sf::st_sfc(
      sf::st_polygon(list(rbind(
        c(1e6, 1e6),
        c(1e6 + 100, 1e6),
        c(1e6 + 100, 1e6 + 100),
        c(1e6, 1e6 + 100),
        c(1e6, 1e6)
      ))),
      crs = CRS_FIXTURE
    )
  )

  expect_equal(nrow(create_forest_disturbance_seral(fx$fd, fx$vri, far, max_age = 400)), 0L)
})
