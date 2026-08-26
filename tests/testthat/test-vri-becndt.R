## `create_vri_becndt()` is a VRI x NDT-BEC overlay with the leading-group layer unioned on.
## `terra::union()` also brings in the parts of the leading-group layer the VRI does not cover, and
## those must not survive.

skip_if_not_installed("terra")
skip_if_not_installed("spatialutils")

box <- function(xmin, xmax, ymin, ymax) {
  sf::st_polygon(list(rbind(
    c(xmin, ymin),
    c(xmax, ymin),
    c(xmax, ymax),
    c(xmin, ymax),
    c(xmin, ymin)
  )))
}

vri_fixture <- function() {
  list(
    ## VRI and BEC both cover [0, 100] x [0, 100]
    VRI = sf::st_sf(
      PROJ_AGE_1 = 150L,
      SPECIES_CD_1 = "SX",
      geom = sf::st_sfc(box(0, 100, 0, 100), crs = CRS_FIXTURE)
    ),
    BECNDT = sf::st_sf(
      NDT_BEC = "NDT3-SBS",
      BEC_ZONE = "SBS",
      geom = sf::st_sfc(box(0, 100, 0, 100), crs = CRS_FIXTURE)
    ),
    ## leading group covers only the left half, but the layer also extends to [100, 200] --
    ## sharing the x = 100 boundary with the VRI without overlapping it at all
    LGC = sf::st_sf(
      LEADING_GRP = c("FirGroup", "PineGroup"),
      geom = sf::st_sfc(box(0, 50, 0, 100), box(100, 200, 0, 100), crs = CRS_FIXTURE)
    )
  )
}

test_that("leading-group area outside the VRI is dropped, even where it touches", {
  fx <- vri_fixture()
  out <- create_vri_becndt(fx$VRI, fx$BECNDT, fx$LGC)

  ## exactly the VRI footprint: the [100, 200] block merely touches and must not survive
  expect_equal(area_ha(out), 100 * 100 / 1e4, tolerance = 1e-6)
  expect_false(any(is.na(terra::values(out)$NDT_BEC)))
  expect_false("PineGroup" %in% terra::values(out)$LEADING_GRP)
})

test_that("the VRI is split where the leading group covers only part of it", {
  fx <- vri_fixture()
  out <- create_vri_becndt(fx$VRI, fx$BECNDT, fx$LGC)
  d <- as.data.frame(out)
  d$ha <- terra::expanse(out, unit = "ha", transform = FALSE)

  expect_equal(nrow(out), 2L)
  expect_equal(sum(d$ha[!is.na(d$LEADING_GRP)]), 50 * 100 / 1e4, tolerance = 1e-6)
  expect_equal(sum(d$ha[is.na(d$LEADING_GRP)]), 50 * 100 / 1e4, tolerance = 1e-6)
})

test_that("NDT4 and leading group rewrite NDT_BEC", {
  fx <- vri_fixture()
  fx$BECNDT$NDT_BEC <- "NDT4-IDF"
  out <- create_vri_becndt(fx$VRI, fx$BECNDT, fx$LGC)
  d <- as.data.frame(out)

  ## FirGroup where the leading group covers it; the NDT4 fallback elsewhere
  expect_setequal(d$NDT_BEC, "NDT4-IDF-FD")
})

test_that("VRI outside the BEC coverage is dropped", {
  fx <- vri_fixture()
  ## BEC now covers only the left half
  fx$BECNDT <- sf::st_sf(
    NDT_BEC = "NDT3-SBS",
    BEC_ZONE = "SBS",
    geom = sf::st_sfc(box(0, 50, 0, 100), crs = CRS_FIXTURE)
  )

  out <- create_vri_becndt(fx$VRI, fx$BECNDT, fx$LGC)

  expect_equal(area_ha(out), 50 * 100 / 1e4, tolerance = 1e-6)
})
