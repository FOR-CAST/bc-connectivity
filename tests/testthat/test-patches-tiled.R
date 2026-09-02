## Tiling `patches_union_final`: the tiled build must agree with the serial one on the SAME input.
##
## Tiling crops the base layer, so polygons that straddle a tile seam are split: the tiled result
## has more features than the serial one. Area, footprint, and area-per-attribute-combination must
## be identical anyway, and `calc_matold()`'s dissolve must put split patches back together before
## the interpatch distances are measured -- if it does not, a patch becomes two at ~0 m apart and
## every quantile that feeds the Omniscape radii moves.

skip_if_not_installed("terra")
skip_if_not_installed("spatialutils")

## Closed-form fixture, seam at x = 500.
##
##  Old    : a U opening east -- [0, 900]^2 minus the notch [300, 900] x [300, 600].  63 ha
##           Cropping at x = 500 leaves ONE connected piece west of the seam and TWO
##           disconnected pieces east of it, which touch only through the western tile.
##           That is the case seam healing has to survive.
##  Mature : [-500, -100] x [0, 900], 100 m west of the Old patch.                    36 ha
##
##  old_interior    : [200, 700] x [650, 850], inside Old, straddling the seam.       10 ha
##  matold_interior : [-300, -200] x [100, 800] inside Mature (7 ha)
##                    + [100, 200] x [100, 200] inside Old (1 ha).                     8 ha
SEAM <- 500

tiling_fixture <- function() {
  u_shape <- sf::st_difference(box(0, 900, 0, 900), box(300, 900, 300, 600))

  list(
    patch_size = terra::vect(sf::st_sf(
      Seral = c("Old", "Mature"),
      geom = sf::st_sfc(u_shape, box(-500, -100, 0, 900), crs = CRS_FIXTURE)
    )),
    interior_old = terra::vect(sf::st_sf(
      old_interior = "old_interior",
      geom = sf::st_sfc(box(200, 700, 650, 850), crs = CRS_FIXTURE)
    )),
    interior_mature_old = terra::vect(sf::st_sf(
      matold_interior = "matold_interior",
      geom = sf::st_sfc(box(-300, -200, 100, 800), box(100, 200, 100, 200), crs = CRS_FIXTURE)
    ))
  )
}

## Three tiles partitioning the fixture: west of the seam, east of it, and one nothing reaches.
tiling_tiles <- function() {
  list(
    sf::st_sf(tile = 1L, geom = sf::st_sfc(box(-1000, SEAM, -1000, 1000), crs = CRS_FIXTURE)),
    sf::st_sf(tile = 2L, geom = sf::st_sfc(box(SEAM, 1500, -1000, 1000), crs = CRS_FIXTURE)),
    sf::st_sf(tile = 3L, geom = sf::st_sfc(box(1500, 2500, -1000, 1000), crs = CRS_FIXTURE))
  )
}

build_tiled <- function(fx, tiles = tiling_tiles()) {
  lapply(tiles, function(t) {
    patches_union_into_final_resultant(
      fx$patch_size,
      fx$interior_old,
      fx$interior_mature_old,
      t
    )
  })
}

## area in m^2 by every attribute combination present, NA rendered explicitly so it can be compared
area_by_attrs <- function(v) {
  d <- as.data.frame(v)
  d$m2 <- terra::expanse(v, unit = "m", transform = FALSE)
  d |>
    dplyr::mutate(dplyr::across(
      c("Seral", "matold_interior", "old_interior"),
      \(x) dplyr::coalesce(as.character(x), "<NA>")
    )) |>
    dplyr::group_by(.data$Seral, .data$matold_interior, .data$old_interior) |>
    dplyr::summarise(m2 = sum(.data$m2), .groups = "drop") |>
    dplyr::arrange(.data$Seral, .data$matold_interior, .data$old_interior) |>
    as.data.frame()
}

area_m2 <- function(v) {
  if (nrow(v) == 0L) 0 else sum(terra::expanse(v, unit = "m", transform = FALSE))
}

test_that("the fixture really splits a patch into pieces that do not touch", {
  ## Pins the fixture's whole point. Without this, a later simplification could turn the seam case
  ## into two halves that trivially abut, and the healing test would stop testing anything.
  fx <- tiling_fixture()
  old <- fx$patch_size[fx$patch_size$Seral == "Old", ]
  east <- terra::crop(old, terra::vect(tiling_tiles()[[2]]))

  expect_equal(nrow(terra::disagg(east)), 2L)
  expect_equal(area_m2(east), 2 * 400 * 300, tolerance = 1e-9)
})

test_that("tiling the final resultant preserves area, footprint, and every attribute combination", {
  fx <- tiling_fixture()

  serial <- patches_union_into_final_resultant(
    fx$patch_size,
    fx$interior_old,
    fx$interior_mature_old
  )
  tiled <- combine_spatvectors(build_tiled(fx))

  ## the closed-form answer, so this still fails informatively if BOTH paths are wrong together
  expected <- data.frame(
    Seral = c("Mature", "Mature", "Old", "Old", "Old"),
    matold_interior = c("<NA>", "matold_interior", "<NA>", "<NA>", "matold_interior"),
    old_interior = c("<NA>", "<NA>", "<NA>", "old_interior", "<NA>"),
    m2 = c(290000, 70000, 520000, 100000, 10000)
  )
  expect_equal(area_by_attrs(serial), expected, tolerance = 1e-9)
  expect_equal(area_by_attrs(tiled), expected, tolerance = 1e-9)

  ## and tiled against serial directly, which is the contract that actually matters
  expect_equal(area_m2(tiled), area_m2(serial), tolerance = 1e-9)
  expect_equal(area_by_attrs(tiled), area_by_attrs(serial), tolerance = 1e-9)

  ## no area invented, none lost, and none counted twice at the seam
  expect_equal(area_m2(tiled), area_m2(terra::aggregate(tiled)), tolerance = 1e-9)
  expect_equal(
    area_m2(terra::aggregate(tiled)),
    area_m2(terra::aggregate(serial)),
    tolerance = 1e-9
  )

  ## feature count is NOT preserved -- the seam splits polygons -- which is why every assertion
  ## above is about area rather than rows
  expect_gt(nrow(tiled), nrow(serial))
})

test_that("every tile presents the same attribute columns in the same order", {
  ## `rbind()` on SpatVectors matches by name and NA-fills a column a branch is missing, so a
  ## branch that silently drops `old_interior` yields a layer with no interior forest over that
  ## tile and no error anywhere. Check the column sets themselves, not just the combined result.
  fx <- tiling_fixture()
  serial <- patches_union_into_final_resultant(
    fx$patch_size,
    fx$interior_old,
    fx$interior_mature_old
  )
  want <- c("Seral", "matold_interior", "old_interior")

  expect_equal(names(serial), want)
  for (branch in build_tiled(fx)) {
    expect_equal(names(branch), want)
  }
  expect_equal(names(combine_spatvectors(build_tiled(fx))), want)
})

test_that("a tile the base does not reach returns an empty layer that still carries the columns", {
  ## `terra::crop()` returns zero rows AND zero columns when nothing overlaps, so an unguarded
  ## crop hands `rbind()` a column-less branch. Six of the 49 real tiles hold no base features.
  fx <- tiling_fixture()
  empty <- patches_union_into_final_resultant(
    fx$patch_size,
    fx$interior_old,
    fx$interior_mature_old,
    tiling_tiles()[[3]]
  )

  expect_equal(nrow(empty), 0L)
  expect_equal(names(empty), c("Seral", "matold_interior", "old_interior"))
})

test_that("a tile with base but no interior forest keeps both flag columns, all NA", {
  ## Interior forest covers a small fraction of the study area, so most tiles miss at least one of
  ## the two layers. `overlay_left_join()` must tolerate an empty `y`.
  fx <- tiling_fixture()
  ## the east tile holds part of the Old patch and part of `old_interior`, but no `matold_interior`
  east <- patches_union_into_final_resultant(
    fx$patch_size,
    fx$interior_old,
    fx$interior_mature_old,
    tiling_tiles()[[2]]
  )

  expect_equal(names(east), c("Seral", "matold_interior", "old_interior"))
  expect_equal(sum(!is.na(east$matold_interior)), 0L)
  expect_equal(area_m2(east), 2 * 400 * 300, tolerance = 1e-9)

  ## `old_interior` reaches [500, 700] x [650, 850] of this tile
  d <- as.data.frame(east)
  d$m2 <- terra::expanse(east, unit = "m", transform = FALSE)
  expect_equal(sum(d$m2[!is.na(d$old_interior)]), 200 * 200, tolerance = 1e-9)
})

test_that("a tile lying entirely inside interior forest flags every row", {
  fx <- tiling_fixture()
  inside_tile <- sf::st_sf(tile = 1L, geom = sf::st_sfc(box(300, 400, 700, 800), crs = CRS_FIXTURE))
  out <- patches_union_into_final_resultant(
    fx$patch_size,
    fx$interior_old,
    fx$interior_mature_old,
    inside_tile
  )

  expect_equal(names(out), c("Seral", "matold_interior", "old_interior"))
  expect_equal(area_m2(out), 100 * 100, tolerance = 1e-9)
  expect_equal(sum(is.na(out$old_interior)), 0L)
  expect_equal(sum(!is.na(out$matold_interior)), 0L)
})

test_that("calc_matold heals the seam: same patches, same interpatch distances as serial", {
  ## This is the claim the whole change rests on. `calc_matold()` dissolves on a constant and
  ## explodes, which must put the pieces of a split patch back into one feature.
  fx <- tiling_fixture()

  serial <- patches_union_into_final_resultant(
    fx$patch_size,
    fx$interior_old,
    fx$interior_mature_old
  )
  tiled <- combine_spatvectors(build_tiled(fx))

  m_serial <- calc_matold(serial)
  m_tiled <- calc_matold(tiled)

  ## Mature and Old are 100 m apart, so exactly two patches, whichever way the layer was built
  expect_equal(nrow(m_serial), 2L)
  expect_equal(nrow(m_tiled), 2L)
  expect_equal(area_m2(m_tiled), area_m2(m_serial), tolerance = 1e-9)
  expect_equal(area_m2(m_tiled), 630000 + 360000, tolerance = 1e-9)

  ## and the distances themselves, not just the feature count: a split that healed into one
  ## feature of the wrong shape would keep the count and move the distance
  one_chunk <- data.frame(chunk = 1L)
  expect_equal(
    sort(as.numeric(calc_nn_dists(m_tiled, one_chunk, n_chunks = 1L))),
    c(100, 100),
    tolerance = 1e-9
  )
  expect_equal(
    sort(as.numeric(calc_nn_dists(m_tiled, one_chunk, n_chunks = 1L))),
    sort(as.numeric(calc_nn_dists(m_serial, one_chunk, n_chunks = 1L))),
    tolerance = 1e-9
  )
})

test_that("the seam does not change the rasters the connectivity model is built from", {
  ## Resistance and source weight come from `Seral` alone, and `terra::rasterize()` assigns by cell
  ## centre, so splitting a polygon must not move a single cell.
  fx <- tiling_fixture()
  serial <- define_forest_seral_patch_conn_vals(patches_union_into_final_resultant(
    fx$patch_size,
    fx$interior_old,
    fx$interior_mature_old
  ))
  tiled <- define_forest_seral_patch_conn_vals(combine_spatvectors(build_tiled(fx)))

  template <- terra::rast(terra::ext(-500, 900, 0, 900), resolution = 30, crs = CRS_FIXTURE)
  rasterise <- function(v, field) {
    terra::values(terra::rasterize(v, template, field = field, fun = mean, na.rm = TRUE))
  }

  expect_equal(rasterise(tiled, "Resistance"), rasterise(serial, "Resistance"))
  expect_equal(rasterise(tiled, "SourceWt"), rasterise(serial, "SourceWt"))
})

test_that("the base layer carries no attribute computed from whole-patch geometry", {
  ## Cropping splits patches, so any per-feature attribute describing the WHOLE patch -- an area, a
  ## patch-size class -- would land on a fragment that contradicts it, and nothing downstream would
  ## notice: `calc_patch_stats()` reads the untiled base, so the two could never disagree.
  ## `patches_create_patch_size_data()` deliberately carries only `Seral`; this fails the moment
  ## that changes, which is the moment tiling stops being safe.
  input <- patches_get_input_data(seral_fixture())

  expect_equal(names(patches_create_patch_size_data(input)), "Seral")
})
