## Regression tests for the patch-construction chain (README appendix, arcpy steps 1-6).
## Closed-form expectations come from the concentric fixture in helper-seral-fixture.R.

skip_if_not_installed("terra")
skip_if_not_installed("spatialutils")

build_patches <- function(seral_sf) {
  input <- patches_get_input_data(seral_sf)

  bufs <- lapply(c(200, 100, 50, 25), \(b) patches_create_buffers_to_delete(input, b))
  names(bufs) <- c("b200", "b100", "b50", "b25")

  mask_old <- patches_create_erase_mask(bufs$b200, bufs$b100, bufs$b50, bufs$b25, "Old")
  mask_mo <- patches_create_erase_mask(bufs$b200, bufs$b100, bufs$b50, bufs$b25, "Mature")

  list(
    input = input,
    buffers = bufs,
    old = patches_create_old_mature(input, "Old"),
    mature_old = patches_create_old_mature(input, c("Mature", "Old")),
    patch_size = patches_create_patch_size_data(input),
    interior_old = patches_create_interior_forest(
      patches_create_old_mature(input, "Old"),
      mask_old,
      "Old"
    ),
    interior_mature_old = patches_create_interior_forest(
      patches_create_old_mature(input, c("Mature", "Old")),
      mask_mo,
      "Mature"
    )
  )
}

test_that("the seral input layer dissolves without losing area or the NA class", {
  seral <- seral_fixture()
  input <- patches_get_input_data(seral)

  expect_equal(area_ha(input), area_ha(seral), tolerance = 1e-6)
  expect_setequal(input$Seral, c("Old", "Mature", "Mid", "Early", NA))
  expect_equal(sum(is.na(input$Seral)), 1L)
})

test_that("OLD / MATURE_OLD keep only their own age class", {
  p <- build_patches(seral_fixture())

  expect_setequal(p$old$INTERIOR_CATEGORY, "O")
  expect_setequal(p$mature_old$INTERIOR_CATEGORY, "MO")

  ## the 1200 m old square, and the 1600 m mature+old square
  expect_equal(area_ha(p$old), 1200^2 / 1e4, tolerance = 1e-6)
  expect_equal(area_ha(p$mature_old), 1600^2 / 1e4, tolerance = 1e-6)
})

test_that("interior forest matches the closed-form areas", {
  p <- build_patches(seral_fixture())

  ## Old eroded by the Mature 25 m buffer
  expect_equal(area_ha(p$interior_old), (1200 - 2 * 25)^2 / 1e4, tolerance = 1e-4)
  ## Mature+Old eroded by the Mid 52 m buffer -- NOT also by the 25 m Mature buffer
  expect_equal(area_ha(p$interior_mature_old), (1600 - 2 * 52)^2 / 1e4, tolerance = 1e-4)
})

test_that("mature+old interior forest is strictly larger than old-only", {
  ## the collapse fixed in 145cffb made these two numerically identical
  p <- build_patches(seral_fixture())

  expect_gt(area_ha(p$interior_mature_old), area_ha(p$interior_old))
})

test_that("unclassified land never becomes interior forest", {
  ## none of the four edge-influence buffers cover NA-seral land, so without the
  ## INTERIOR_CATEGORY filter it survives the erase and is relabelled as interior forest
  p <- build_patches(seral_fixture(na_square = TRUE))

  na_sq <- terra::vect(sf::st_sf(
    geom = sf::st_sfc(sq(250, cx = 5000, cy = 5000), crs = CRS_FIXTURE)
  ))

  expect_false(any(terra::is.related(p$interior_old, na_sq, "intersects")))
  expect_false(any(terra::is.related(p$interior_mature_old, na_sq, "intersects")))
})

test_that("the final resultant preserves Seral and flags interior forest separately", {
  p <- build_patches(seral_fixture())
  final <- patches_union_into_final_resultant(
    p$patch_size,
    p$interior_old,
    p$interior_mature_old
  ) |>
    define_forest_seral_patch_conn_vals()

  d <- as.data.frame(final)
  d$ha <- terra::expanse(final, unit = "ha", transform = FALSE)

  ## every square metre of old forest is still Old -- not relabelled Mature
  expect_equal(sum(d$ha[d$Seral == "Old"]), 1200^2 / 1e4, tolerance = 1e-4)

  ## old cores are the most permeable and the strongest sources
  old_interior <- d[d$Seral == "Old" & !is.na(d$old_interior), ]
  expect_equal(sum(old_interior$ha), (1200 - 2 * 25)^2 / 1e4, tolerance = 1e-4)
  expect_setequal(old_interior$Resistance, 1)
  expect_setequal(old_interior$SourceWt, 1)

  ## interior membership is an attribute, not a seral stage
  expect_true(all(c("old_interior", "matold_interior") %in% names(d)))
  expect_setequal(na.omit(d$old_interior), "old_interior")
})

test_that("the final resultant keeps the base layer's footprint exactly", {
  ## This pins the contract: a left join must not invent area, lose area, or count any twice.
  ##
  ## It does NOT reproduce the `terra::union()` failure that motivated the rewrite. On clean
  ## synthetic geometry `union()` is exact; the corruption only shows on real polygons. Measured on
  ## a window of 2,933 seral polygons it returned 221 ha more than its base, overlapped itself by
  ## 303 ha, and dropped 82 ha of land outright -- so the evidence for that lives in the commit
  ## message and the corrections report, not here.
  base <- sf::st_sf(
    Seral = c("Old", "Mature"),
    geom = sf::st_sfc(box(0, 100, 0, 100), box(100, 200, 0, 100), crs = CRS_FIXTURE)
  ) |>
    terra::vect()

  ## an interior-forest patch straddling the seam, so both base polygons are split
  interior <- sf::st_sf(
    old_interior = "old_interior",
    geom = sf::st_sfc(box(50, 150, 25, 75), crs = CRS_FIXTURE)
  ) |>
    terra::vect()

  out <- overlay_left_join(base, interior)
  area <- function(v) sum(terra::expanse(v, unit = "ha", transform = FALSE))

  ## no area invented, none lost, and none counted twice
  expect_equal(area(out), area(base), tolerance = 1e-9)
  expect_equal(area(out), area(terra::aggregate(out)), tolerance = 1e-9)

  ## the flag is carried where the patch reaches and NA elsewhere, and `Seral` survives intact
  d <- as.data.frame(out)
  d$ha <- terra::expanse(out, unit = "ha", transform = FALSE)
  expect_equal(sum(d$ha[!is.na(d$old_interior)]), 100 * 50 / 1e4, tolerance = 1e-9)
  expect_setequal(unique(d$Seral), c("Old", "Mature"))
})
