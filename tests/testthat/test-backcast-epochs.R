## The epoch seral layer: the history overlay, back-cast and classified per epoch.

skip_if_not_installed("terra")
skip_if_not_installed("spatialutils")

## Two NDT-BEC zones as horizontal bands, three stands as vertical strips crossing both:
##
##   NDT3-SBS (y 0-1000):    Mid 40, Mature 100, Old 140
##   NDT2-SBS (y 1000-2000): Mid 40, Mature 100, Old 250
##
##   x 0-1000     never disturbed, SIFA 200
##   x 1000-2000  beetle-killed 2011; VRI kept the pre-attack age, 112
##   x 2000-3000  cut 2015; VRI updated, so the pre-harvest age is lost
epoch_overlay_fixture <- function(dir) {
  rect <- function(xmin, xmax, ymin, ymax) {
    sf::st_polygon(list(rbind(
      c(xmin, ymin),
      c(xmax, ymin),
      c(xmax, ymax),
      c(xmin, ymax),
      c(xmin, ymin)
    )))
  }

  vri <- sf::st_sf(
    NDT_BEC = c("NDT3-SBS", "NDT2-SBS"),
    geom = sf::st_sfc(rect(0, 3000, 0, 1000), rect(0, 3000, 1000, 2000), crs = CRS_FIXTURE)
  )
  fd <- sf::st_sf(
    SIFA = c(200, 13, 9),
    PROJ_AGE_1 = c(200L, 112L, 9L),
    DSTRB_HIST = c(NA, "2011_IBM_V_VRI", "2015_CUT_N_VRI"),
    MRSRD_Y = c(NA, 2011, 2015),
    MRSRD_A = c(NA, "IBM", "CUT"),
    geom = sf::st_sfc(
      rect(0, 1000, 0, 2000),
      rect(1000, 2000, 0, 2000),
      rect(2000, 3000, 0, 2000),
      crs = CRS_FIXTURE
    )
  )

  fd_gpkg <- file.path(dir, "fd.gpkg")
  vri_gpkg <- file.path(dir, "vri.gpkg")
  sf::st_write(fd, fd_gpkg, quiet = TRUE, append = FALSE)
  sf::st_write(vri, vri_gpkg, quiet = TRUE, append = FALSE)

  tile <- sf::st_sf(tile = 1L, geom = sf::st_sfc(rect(-100, 3100, -100, 2100), crs = CRS_FIXTURE))

  list(fd = fd_gpkg, vri = vri_gpkg, tile = tile)
}

## every lost age falls back to this single donor, 150 at harvest
one_donor <- data.frame(NDT_BEC = "NDT3-SBS", agent = "CUT", age = 150, weight = 1)

seral_table <- function(v) {
  d <- terra::as.data.frame(v)
  d <- d[order(d$NDT_BEC, -d$SIFA), c("NDT_BEC", "SIFA", "Seral")]
  rownames(d) <- NULL
  d
}

test_that("the history overlay splits each stand at the zone boundary and carries planar area", {
  fx <- epoch_overlay_fixture(withr::local_tempdir())
  h <- create_forest_disturbance_history(fx$fd, fx$vri, fx$tile)

  expect_equal(nrow(h), 6L)
  expect_equal(sum(h$ha), 3000 * 2000 / 1e4, tolerance = 1e-9)
  expect_true(all(c("DSTRB_HIST", "MRSRD_Y", "PROJ_AGE_1", "NDT_BEC") %in% names(h)))
})

test_that("at 2024 the epoch layer is the current condition", {
  fx <- epoch_overlay_fixture(withr::local_tempdir())
  current <- create_forest_disturbance_seral(fx$fd, fx$vri, fx$tile, max_age = 400)
  h <- create_forest_disturbance_history(fx$fd, fx$vri, fx$tile)
  epoch <- create_forest_disturbance_seral_epoch(h, 2024, one_donor, 400, fx$tile)

  expect_equal(seral_table(epoch), seral_table(current))
})

test_that("at 2010 each stand takes its closed-form age and seral stage", {
  fx <- epoch_overlay_fixture(withr::local_tempdir())
  h <- create_forest_disturbance_history(fx$fd, fx$vri, fx$tile)
  out <- create_forest_disturbance_seral_epoch(h, 2010, one_donor, 400, fx$tile)
  d <- terra::as.data.frame(out)

  ## undisturbed: 200 - 14 = 186, Old in NDT3-SBS (>= 140) and Mature in NDT2-SBS (< 250)
  ## beetle: VRI's 112 - 14 = 98, Mid in both (Mature starts at 100)
  ## cut: lost, filled from the donor: 150 - (2015 - 2010) = 145, Old / Mature as the first
  expected <- data.frame(
    NDT_BEC = rep(c("NDT2-SBS", "NDT3-SBS"), each = 3),
    SIFA = c(186, 145, 98, 186, 145, 98),
    Seral = c("Mature", "Mature", "Mid", "Old", "Old", "Mid")
  )
  expect_equal(seral_table(out), expected)
  expect_setequal(d$age_source, c("undisturbed", "vri_pre_disturbance", "imputed"))
})

test_that("an epoch age past the current maximum still gets a seral stage", {
  ## VRI's pre-attack age can exceed every current SIFA, which the oldest class is closed at
  fx <- epoch_overlay_fixture(withr::local_tempdir())
  h <- create_forest_disturbance_history(fx$fd, fx$vri, fx$tile)
  out <- create_forest_disturbance_seral_epoch(h, 2010, one_donor, max_age = 50, fx$tile)

  expect_false(anyNA(terra::as.data.frame(out)$Seral))
})

test_that("BC_CONN_EPOCHS selects the epochs", {
  expect_equal(historical_epochs(""), integer(0))
  expect_equal(historical_epochs("all"), c(2005L, 2010L, 2015L, 2020L))
  expect_equal(historical_epochs(" 2010, 2005,2010 "), c(2005L, 2010L))
  expect_error(historical_epochs("2025"), "before 2024")
  expect_error(historical_epochs("soon"), "before 2024")
})
