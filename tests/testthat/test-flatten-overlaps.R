## flatten_overlaps(): CEF overlaps itself as delivered, so each overlap must go to exactly one
## stand. Unit squares on a metre grid, so every area is a closed-form count of square metres.

square <- function(x0, y0, size) {
  sf::st_polygon(list(rbind(
    c(x0, y0),
    c(x0 + size, y0),
    c(x0 + size, y0 + size),
    c(x0, y0 + size),
    c(x0, y0)
  )))
}

stands <- function(geoms, SIFA) {
  sf::st_sf(id = seq_along(geoms), SIFA = SIFA, geometry = sf::st_sfc(geoms, crs = 3979))
}

areas <- function(x) stats::setNames(as.numeric(sf::st_area(x)), x$id)

test_that("a partial overlap goes to the younger stand", {
  x <- stands(list(square(0, 0, 10), square(5, 0, 10)), SIFA = c(100, 10))
  out <- flatten_overlaps(x, "SIFA")

  expect_equal(areas(out), c(`1` = 50, `2` = 100))
})

test_that("a younger stand nested in an older one cuts a hole in it", {
  x <- stands(list(square(0, 0, 10), square(2, 2, 2)), SIFA = c(200, 20))
  out <- flatten_overlaps(x, "SIFA")

  expect_equal(areas(out), c(`1` = 96, `2` = 4))
})

test_that("a nested duplicate with the same age is dropped, not kept twice", {
  x <- stands(list(square(0, 0, 10), square(2, 2, 2)), SIFA = c(50, 50))
  out <- flatten_overlaps(x, "SIFA")

  expect_equal(areas(out), c(`1` = 100))
})

test_that("ties go to the earlier row", {
  x <- stands(list(square(2, 2, 2), square(0, 0, 10)), SIFA = c(50, 50))
  out <- flatten_overlaps(x, "SIFA")

  expect_equal(areas(out), c(`1` = 4, `2` = 96))
})

test_that("a missing age ranks last", {
  x <- stands(list(square(0, 0, 10), square(5, 0, 10)), SIFA = c(NA, 300))
  out <- flatten_overlaps(x, "SIFA")

  expect_equal(areas(out), c(`1` = 50, `2` = 100))
})

test_that("three stacked stands partition their union", {
  ## along x: A (oldest) 0-10, B 5-15, C (youngest) 8-18; C keeps 8-18, B 5-8, A 0-5
  x <- stands(
    list(square(0, 0, 10), square(5, 0, 10), square(8, 0, 10)),
    SIFA = c(150, 60, 5)
  )
  out <- flatten_overlaps(x, "SIFA")

  expect_equal(areas(out), c(`1` = 50, `2` = 30, `3` = 100))
  expect_equal(sum(areas(out)), as.numeric(sf::st_area(sf::st_union(x))))
})

rect <- function(x0, y0, x1, y1) {
  sf::st_polygon(list(rbind(c(x0, y0), c(x1, y0), c(x1, y1), c(x0, y1), c(x0, y0))))
}

test_that("a sliver left by the cut goes to the neighbour with the longest border", {
  ## A (old) 0-10 is cut by B (young) 0.5-10.5, leaving a 0.5 x 10 strip (5 m2). The strip shares
  ## 10 m with B and 1 m with C, so it goes to B. D is small but was never cut, so it stays.
  x <- stands(
    list(rect(0, 0, 10, 10), rect(0.5, 0, 10.5, 10), rect(-10, 0, 0, 1), rect(20, 20, 22, 22)),
    SIFA = c(100, 10, 50, 5)
  )
  out <- flatten_overlaps(x, "SIFA", min_area = 10)

  expect_equal(areas(out), c(`2` = 105, `3` = 10, `4` = 4))
  expect_named(out, names(x))
})

test_that("a cut piece at or above min_area keeps its own stand", {
  x <- stands(list(rect(0, 0, 10, 10), rect(5, 0, 15, 10)), SIFA = c(100, 10))
  out <- flatten_overlaps(x, "SIFA", min_area = 10)

  expect_equal(areas(out), c(`1` = 50, `2` = 100))
})

test_that("only the small pieces of a cut stand are merged", {
  ## B splits A into a 0-4 piece (40 m2, kept) and a 9.5-10 strip (5 m2, merged into B)
  x <- stands(list(rect(0, 0, 10, 10), rect(4, 0, 9.5, 10)), SIFA = c(100, 10))
  out <- flatten_overlaps(x, "SIFA", min_area = 10)

  expect_equal(areas(out), c(`1` = 40, `2` = 60))
})

test_that("stands that only share an edge are left alone", {
  x <- stands(list(square(0, 0, 10), square(10, 0, 10)), SIFA = c(100, 10))
  out <- flatten_overlaps(x, "SIFA")

  expect_identical(out, x)
})
