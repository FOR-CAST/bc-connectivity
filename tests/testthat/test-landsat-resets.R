## Landsat resets: CanLaD/CanLaBS events CEF does not record, merged into CEF's history. Data year
## 2024 throughout, so a reset in year y leaves a stand 2024 - y years old.

resets_fixture <- function() {
  tibble::tribble(
    ~case                          , ~DSTRB_HIST      , ~MRSRD_Y , ~MRSRD_A , ~SIFA , ~RESET_HIST                   ,
    "unrecorded fire"              , NA               , NA       , NA       ,   120 , "2003_BRN_R_LS"               ,
    "CEF has the fire"             , "2003_BRN_L_FSG" , NA       , NA       ,   120 , "2004_BRN_R_LS"               ,
    "VRI already younger"          , NA               , NA       , NA       ,    10 , "2003_BRN_R_LS"               ,
    "CEF reset is later"           , "2015_CUT_N_VRI" ,     2015 , "CUT"    ,     8 , "2003_BRN_R_LS"               ,
    "insect, old stand"            , NA               , NA       , NA       ,   110 , "2008_INS_H_LS"               ,
    "insect, plantation"           , "2000_CUT_N_VRI" ,     2000 , "CUT"    ,    24 , "2008_INS_H_LS"               ,
    "insect after unrecorded fire" , NA               , NA       , NA       ,   120 , "2008_INS_H_LS,1995_BRN_R_LS" ,
    "insect CEF already has"       , "2007_IBM_V_VRI" ,     2007 , "IBM"    ,    17 , "2008_INS_H_LS"               ,
    "after the data year"          , NA               , NA       , NA       ,   100 , "2025_BRN_R_LS"               ,
    "insect, age unknown"          , "2015_CUT_N_VRI" ,     2015 , "CUT"    ,     8 , "2008_INS_H_LS"               ,
    "no Landsat event"             , "2015_CUT_N_VRI" ,     2015 , "CUT"    ,     8 , NA
  )
}

test_that("each case merges to its closed-form history, MRSRD and age", {
  out <- apply_landsat_resets(resets_fixture())

  expect_equal(out$SIFA, c(21, 120, 10, 8, 16, 24, 29, 17, 100, 8, 8))
  expect_equal(out$MRSRD_Y, c(2003, NA, 2003, 2015, 2008, 2000, 1995, 2007, NA, 2015, 2015))
  expect_equal(
    out$MRSRD_A,
    c("BRN", NA, "BRN", "CUT", "INS", "CUT", "BRN", "IBM", NA, "CUT", "CUT")
  )
  expect_equal(
    out$DSTRB_HIST,
    c(
      "2003_BRN_R_LS",
      "2003_BRN_L_FSG", ## CEF's own severity decides
      "2003_BRN_R_LS",
      "2015_CUT_N_VRI,2003_BRN_R_LS", ## kept for the back-cast, but not the latest reset
      "2008_INS_H_LS",
      "2000_CUT_N_VRI", ## an 8-year-old plantation is not beetle-killed
      "1995_BRN_R_LS", ## 13 years after the fire: too young for the insect event
      "2007_IBM_V_VRI",
      NA,
      "2015_CUT_N_VRI,2008_INS_H_LS",
      "2015_CUT_N_VRI"
    )
  )
  expect_false("RESET_HIST" %in% names(out))
})

test_that("no RESET_HIST column leaves the layer untouched", {
  x <- dplyr::select(resets_fixture(), -RESET_HIST)
  expect_identical(apply_landsat_resets(x), x)
})

test_that("a merged Landsat fire is a reset the back-cast honours", {
  out <- apply_landsat_resets(resets_fixture())
  out$PROJ_AGE_1 <- 120

  ## 1995 fire: at 2000 the stand is 5; at 1990 it is the pre-fire stand, 120 - 34
  at_2000 <- backcast_age(out[7, ], epoch = 2000)
  expect_equal(at_2000$SIFA, 5)
  expect_equal(at_2000$age_source, "reset_by_epoch")

  at_1990 <- backcast_age(out[7, ], epoch = 1990)
  expect_equal(at_1990$SIFA, 86)
  expect_equal(at_1990$age_source, "vri_pre_disturbance")

  ## a Landsat fire before a later CEF cut: the earlier reset dates the stand at an epoch between
  at_2010 <- backcast_age(out[4, ], epoch = 2010)
  expect_equal(at_2010$SIFA, 7)
  expect_equal(at_2010$age_source, "earlier_reset")
})

## A 1 x 12 strip, one pixel per case, years 2000-2004.
landsat_fixture <- function() {
  r <- terra::rast(nrows = 1, ncols = 12, xmin = 0, xmax = 360, ymin = 0, ymax = 30, crs = "local")
  set <- function(v) terra::rast(r, vals = v)
  canlad <- matrix(0L, nrow = 12, ncol = 5) ## pixels x years
  canlad[3, 3] <- 1L ## fire 2002, next to NBAC 2001
  canlad[5, 1] <- 1L ## fire 2000, three years before NBAC 2003: a separate fire
  canlad[6, 2:3] <- 1L ## fire flagged 2001 and 2002, never in NBAC: one fire
  canlad[7, 1:3] <- 8L ## high defoliation 2000-2002: one event
  canlad[8, c(1, 5)] <- 8L ## 2000 and 2004: two events
  canlad[10, 1:5] <- 7L ## medium defoliation: never a reset
  list(
    dnbr = set(c(500, 100, NA, NA, 400, NA, NA, NA, 100, NA, NA, NA)),
    nbac = set(c(2001, 2001, 2001, 2001, 2003, NA, NA, NA, 2002, NA, NA, 1990)),
    salvage = set(c(0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0)),
    canlad = terra::rast(lapply(1:5, function(i) set(canlad[, i])))
  )
}

test_that("pixel events follow the fire and insect rules", {
  f <- landsat_fixture()
  ev <- landsat_reset_cells(f$dnbr, f$nbac, f$salvage, f$canlad, years = 2000:2004)

  expect_equal(
    ev,
    data.frame(
      cell = c(1, 3, 5, 5, 6, 7, 8, 8, 9),
      year = c(2001, 2001, 2000, 2003, 2001, 2000, 2000, 2004, 2002),
      agent = c("BRN", "BRN", "BRN", "BRN", "BRN", "INS", "INS", "INS", "BRN")
    ),
    ignore_attr = TRUE
  )
})

test_that("polygons drop sub-hectare clumps and carry each pixel's whole history", {
  r <- terra::rast(
    nrows = 12,
    ncols = 12,
    xmin = 0,
    xmax = 360,
    ymin = 0,
    ymax = 360,
    crs = "local"
  )
  rc <- function(rows, cols) {
    g <- expand.grid(row = rows, col = cols)
    terra::cellFromRowCol(r, g$row, g$col)
  }
  fire <- setdiff(rc(2:6, 2:6), rc(4, 4)) ## 5 x 5 with a one-pixel hole
  insect <- rc(2:6, 5:8) ## overlaps the fire's last two columns
  speck <- rc(11, 11) ## a lone fire pixel
  events <- data.frame(
    cell = c(fire, insect, speck),
    year = c(rep(2001L, length(fire)), rep(2008L, length(insect)), 2001L),
    agent = c(rep("BRN", length(fire)), rep("INS", length(insect)), "BRN")
  )

  v <- landsat_reset_polygons(events, r, min_cells = 11L)
  cells <- tapply(terra::expanse(v, transform = FALSE) / 900, v$RESET_HIST, sum)

  expect_equal(
    as.vector(cells[c("2001_BRN_R_LS", "2008_INS_H_LS,2001_BRN_R_LS", "2008_INS_H_LS")]),
    c(15, 10, 10)
  )
  expect_length(cells, 3L) ## the speck is gone; the hole was filled
})
