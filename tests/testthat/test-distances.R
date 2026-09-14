## Interpatch distance calculations, and the chunking they are parallelised over.

skip_if_not_installed("terra")

patch_at <- function(x0, y0, side = 100) {
  sf::st_polygon(list(rbind(
    c(x0, y0),
    c(x0 + side, y0),
    c(x0 + side, y0 + side),
    c(x0, y0 + side),
    c(x0, y0)
  )))
}

## A---200m---B, A---200m---C, and D far away (9600 m from B), so the escalating
## search radius has to widen past its first step to resolve D.
dist_fixture <- function() {
  v <- sf::st_sf(
    patch = "matold",
    geom = sf::st_sfc(
      patch_at(0, 0),
      patch_at(300, 0),
      patch_at(0, 300),
      patch_at(10000, 0),
      crs = CRS_FIXTURE
    )
  ) |>
    terra::vect()
  v$id <- seq_len(nrow(v))
  v
}

one_chunk <- data.frame(chunk = 1L)

test_that("chunk_rows partitions the rows exactly once", {
  rows <- unlist(lapply(1:7, function(k) chunk_rows(100, 7, k)))

  expect_setequal(rows, 1:100)
  expect_equal(length(rows), 100L)
})

test_that("make_chunks never asks for more chunks than there are rows", {
  expect_equal(nrow(make_chunks(3, n_chunks = 10L)), 3L)
})

test_that("nearest-neighbour distances are exact, including beyond the first search radius", {
  v <- dist_fixture()
  d <- calc_nn_dists(v, one_chunk, n_chunks = 1L)

  expect_s3_class(d, "units")
  expect_equal(as.numeric(d), c(200, 200, 200, 9600), tolerance = 1e-6)
})

test_that("touching patches are at distance zero", {
  v <- sf::st_sf(
    patch = "matold",
    geom = sf::st_sfc(patch_at(0, 0), patch_at(100, 0), crs = CRS_FIXTURE)
  ) |>
    terra::vect()
  v$id <- seq_len(nrow(v))

  expect_equal(as.numeric(calc_nn_dists(v, one_chunk, n_chunks = 1L)), c(0, 0))
})

test_that("chunked nearest-neighbour distances match the unchunked answer", {
  v <- dist_fixture()

  whole <- calc_nn_dists(v, one_chunk, n_chunks = 1L)
  chunked <- lapply(1:2, function(k) calc_nn_dists(v, data.frame(chunk = k), n_chunks = 2L)) |>
    calc_nn_dists_combine()

  expect_equal(as.numeric(chunked), as.numeric(whole))
})

test_that("the all-distances grid covers the upper triangle only", {
  g <- calc_all_dists_grid(4L)

  expect_equal(nrow(g), 10L) ## 4 * 5 / 2
  expect_true(all(g$i <= g$j))
})

test_that("all pairwise distances cover every unordered pair exactly once", {
  v <- dist_fixture()
  n_chunks <- 2L

  ds_dir <- withr::local_tempdir()
  grid <- calc_all_dists_grid(n_chunks)
  files <- vapply(
    seq_len(nrow(grid)),
    function(k) calc_all_dists(v, grid[k, ], n_chunks = n_chunks, ds_dir = ds_dir),
    character(1)
  )

  expect_equal(length(unique(files)), nrow(grid)) ## one file per chunk pair

  dists <- do.call(rbind, lapply(files, arrow::read_parquet))$distance

  ## A(0,0) B(300,0) C(0,300) D(10000,0), all 100 m squares
  expected <- c(
    200, ## A-B
    200, ## A-C
    sqrt(200^2 + 200^2), ## B-C
    9900, ## A-D
    9600, ## B-D
    sqrt(9900^2 + 200^2) ## C-D
  )
  expect_equal(length(dists), choose(nrow(v), 2)) ## 6 unordered pairs
  expect_equal(sort(dists), sort(expected), tolerance = 1e-6)
})
