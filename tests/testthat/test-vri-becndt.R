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

test_that("tiling gives the same answer as not tiling", {
  fx <- vri_fixture()

  whole <- create_vri_becndt(fx$VRI, fx$BECNDT, fx$LGC)

  ## two tiles cutting the VRI in half vertically, at x = 60 -- deliberately NOT on the
  ## leading-group boundary at x = 50, so a real polygon is split at the seam
  tiles <- list(
    sf::st_sf(tile = 1L, geom = sf::st_sfc(box(-10, 60, -10, 110), crs = CRS_FIXTURE)),
    sf::st_sf(tile = 2L, geom = sf::st_sfc(box(60, 210, -10, 110), crs = CRS_FIXTURE))
  )
  tiled <- lapply(tiles, function(t) create_vri_becndt(fx$VRI, fx$BECNDT, fx$LGC, t)) |>
    combine_spatvectors()

  expect_equal(area_ha(tiled), area_ha(whole), tolerance = 1e-6)

  summarise_by_grp <- function(v) {
    d <- as.data.frame(v)
    d$ha <- terra::expanse(v, unit = "ha", transform = FALSE)
    d |>
      dplyr::mutate(LEADING_GRP = dplyr::coalesce(LEADING_GRP, "none")) |>
      dplyr::group_by(NDT_BEC, LEADING_GRP) |>
      dplyr::summarise(ha = round(sum(ha), 6), .groups = "drop") |>
      dplyr::arrange(NDT_BEC, LEADING_GRP)
  }

  expect_equal(summarise_by_grp(tiled), summarise_by_grp(whole))
})

test_that("a tile that misses the leading-group layer still works", {
  fx <- vri_fixture()
  ## the right half of the VRI, where the leading group does not reach
  tile <- sf::st_sf(tile = 1L, geom = sf::st_sfc(box(60, 90, 0, 100), crs = CRS_FIXTURE))

  out <- create_vri_becndt(fx$VRI, fx$BECNDT, fx$LGC, tile)

  expect_equal(area_ha(out), 30 * 100 / 1e4, tolerance = 1e-6)
  expect_true(all(is.na(terra::values(out)$LEADING_GRP)))
})

test_that("a tile outside every input returns an empty layer", {
  fx <- vri_fixture()
  far <- sf::st_sf(
    tile = 1L,
    geom = sf::st_sfc(box(1e6, 1e6 + 100, 1e6, 1e6 + 100), crs = CRS_FIXTURE)
  )

  expect_equal(nrow(create_vri_becndt(fx$VRI, fx$BECNDT, fx$LGC, far)), 0L)
})

test_that("the leading-group join partitions the VRI x BEC result exactly", {
  ## `terra::union()` failed both halves of this on real data: its output polygons overlapped each
  ## other by 2,444 ha and its dissolved footprint was 1,619 ha smaller than its input, so it
  ## double-counted some land and dropped other land outright.
  fx <- vri_fixture()
  out <- create_vri_becndt(fx$VRI, fx$BECNDT, fx$LGC)

  ## no duplication: the parts sum to the area they jointly cover
  expect_equal(area_ha(out), area_ha(terra::aggregate(out)), tolerance = 1e-9)

  ## no loss: that area is the whole VRI x BEC footprint
  expect_equal(area_ha(terra::aggregate(out)), 100 * 100 / 1e4, tolerance = 1e-9)

  ## and every part carries a leading group or an explicit NA, never a fabricated one
  expect_setequal(unique(terra::values(out)$LEADING_GRP), c("FirGroup", NA_character_))
})
