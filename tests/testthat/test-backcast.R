## Back-casting stand age to an epoch. Every case has a closed-form answer: data year 2024, epoch
## 2010, so `shift` = 14.

backcast_fixture <- function() {
  tibble::tribble(
    ~case                 , ~DSTRB_HIST                     , ~MRSRD_Y , ~SIFA , ~PROJ_AGE_1 ,
    "old, undisturbed"    , NA                              , NA       ,   100 ,         100 ,
    "young, unrecorded"   , NA                              , NA       ,    10 ,          10 ,
    "MRSRD_Y = 0 is none" , ""                              ,        0 ,    60 ,          60 ,
    "cut before epoch"    , "2005_CUT_N_VRI"                ,     2005 ,    19 ,          19 ,
    "regen delay"         , "2008_CUT_N_VRI"                ,     2008 ,    12 ,          12 ,
    "beetle, VRI kept"    , "2011_IBM_V_VRI"                ,     2011 ,    13 ,         112 ,
    "cut, VRI reset"      , "2015_CUT_N_VRI"                ,     2015 ,     7 ,           7 ,
    "fire on earlier cut" , "2017_BRN_H_FSH,2003_CUT_N_VRI" ,     2017 ,     7 ,           7 ,
    "earlier non-reset"   , "2017_BRN_H_FSH,2003_BRN_L_FSH" ,     2017 ,     7 ,         150 ,
    "event after MRSRD"   , "2011_IBM_V_VRI,2007_CUT_N_VRI" ,     2007 ,    17 ,         132 ,
    "no age"              , "2015_CUT_N_VRI"                ,     2015 , NA    , NA
  )
}

test_that("each case back-casts to its closed-form age and source", {
  out <- backcast_age(backcast_fixture(), epoch = 2010, lost_age = -1)

  expect_equal(
    out$SIFA,
    c(86, -1, 46, 5, 0, 98, -1, 7, 136, 3, NA)
  )
  expect_equal(
    out$age_source,
    c(
      "undisturbed",
      "lost",
      "undisturbed",
      "reset_by_epoch",
      "reset_by_epoch",
      "vri_pre_disturbance",
      "lost",
      "earlier_reset",
      "vri_pre_disturbance",
      "reset_by_epoch",
      NA
    )
  )
})

test_that("an event after CEF's most recent reset is not treated as a reset", {
  ## CEF chose the 2007 cut over the 2011 beetle attack, although `IBM_V` is in the reset rule. At
  ## 2012 the stand therefore dates from 2007 (17 - 12 = 5), not from 2011 (1).
  x <- backcast_fixture()[10, ]
  out <- backcast_age(x, epoch = 2012)

  expect_equal(out$SIFA, 5)
  expect_equal(out$age_source, "reset_by_epoch")

  ## at 2005 the stand is pre-cut, and the only recorded age for that is VRI's: 132 - 19
  out <- backcast_age(x, epoch = 2005)

  expect_equal(out$SIFA, 113)
  expect_equal(out$age_source, "vri_pre_disturbance")
})

test_that("the data year reproduces the current condition exactly", {
  x <- backcast_fixture()
  out <- backcast_age(x, epoch = 2024)

  expect_equal(out$SIFA, x$SIFA)
  expect_false(any(out$age_source == "lost", na.rm = TRUE))
})

test_that("lost ages are NA by default and can be supplied per polygon", {
  x <- backcast_fixture()
  lost <- c(2, 7)

  expect_true(all(is.na(backcast_age(x, epoch = 2010)$SIFA[lost])))

  out <- backcast_age(x, epoch = 2010, lost_age = seq_len(nrow(x)) * 10)
  expect_equal(out$SIFA[lost], c(20, 70))
})

test_that("a VRI age just over the years since harvest is a regeneration age, not a kept one", {
  ## cut 2015, VRI updated with 3 years of planting-stock age: 9 years since, VRI age 12
  x <- tibble::tibble(DSTRB_HIST = "2015_CUT_N_VRI", MRSRD_Y = 2015, SIFA = 9, PROJ_AGE_1 = 12)

  expect_equal(backcast_age(x, epoch = 2014)$age_source, "lost")

  ## without the tolerance it would be read as a 2-year-old stand at 2014: 12 - 10
  out <- backcast_age(x, epoch = 2014, vri_update_tolerance = 0)
  expect_equal(out$SIFA, 2)
  expect_equal(out$age_source, "vri_pre_disturbance")
})

test_that("the reset rule is a parameter", {
  ## counting low-severity fire as a reset makes the 2003 burn the stand's origin at 2010
  x <- backcast_fixture()[9, ]
  out <- backcast_age(x, epoch = 2010, reset_rule = c(cef_reset_rule(), "BRN_L"))

  expect_equal(out$SIFA, 7)
  expect_equal(out$age_source, "earlier_reset")
})

test_that("disturbance histories parse into one row per event", {
  ev <- parse_disturbance_history(c("2011_IBM_V_VRI,2007_CUT_N_VRI", NA, "", "2017_BRN_M_FSG"))

  expect_equal(ev$id, c(1L, 1L, 4L))
  expect_equal(ev$year, c(2011L, 2007L, 2017L))
  expect_equal(ev$agent, c("IBM", "CUT", "BRN"))
  expect_equal(ev$severity, c("V", "N", "M"))
  expect_equal(ev$source, c("VRI", "VRI", "FSG"))
})

test_that("undated events parse with a missing year and never count as a reset", {
  ev <- parse_disturbance_history("NA_IBM_V_VRI,2003_CUT_N_VRI")
  expect_equal(ev$year, c(NA, 2003L))

  expect_equal(
    latest_reset("NA_IBM_V_VRI", epoch = 2010, reset_rule = cef_reset_rule()),
    NA_integer_
  )
})

test_that("malformed events warn and are dropped", {
  expect_warning(
    ev <- parse_disturbance_history("2011_IBM_V_VRI,garbage"),
    "1 DSTRB_HIST event"
  )
  expect_equal(nrow(ev), 1L)
})

test_that("lost rows carry the year the unrecorded stand was replaced", {
  out <- backcast_age(backcast_fixture(), epoch = 2010)

  ## the young undisturbed stand initiated in 2024 - 10; the cut stand was replaced in 2015
  expect_equal(out$replaced_year[c(2, 7)], c(2014, 2015))
  expect_true(all(is.na(out$replaced_year[-c(2, 7)])))
})

## Lost-age imputation ----------------------------------------------------------------------------

## NDT3-SBS harvest donors aged 60, 100 and 140 at harvest, the last with twice the area
imputation_donors <- function() {
  data.frame(
    NDT_BEC = "NDT3-SBS",
    agent = "CUT",
    age = c(60, 100, 140),
    weight = c(1, 1, 2)
  )
}

lost_fixture <- function(ndt_bec, agent, replaced_year) {
  tibble::tibble(
    NDT_BEC = ndt_bec,
    MRSRD_A = agent,
    SIFA = NA_real_,
    age_source = "lost",
    replaced_year = replaced_year
  )
}

test_that("weighted quantiles step at the cumulative weight", {
  d <- imputation_donors()

  expect_equal(weighted_quantile(d$age, d$weight, 0.25), 60)
  expect_equal(weighted_quantile(d$age, d$weight, 0.5), 100)
  expect_equal(weighted_quantile(d$age, d$weight, 0.51), 140)
})

test_that("a lost stand is the donor age less the years to its replacement", {
  ## cut 2015; at 2010 it was 5 years short of its age at harvest: 100 - 5
  x <- lost_fixture("NDT3-SBS", "CUT", 2015)
  out <- impute_lost_age(x, 2010, imputation_donors(), method = "quantile", min_donors = 1)

  expect_equal(out$SIFA, 95)
  expect_equal(out$age_source, "imputed")
})

test_that("ages are floored at zero", {
  x <- lost_fixture("NDT3-SBS", "CUT", 2024)
  d <- transform(imputation_donors(), age = 5)
  out <- impute_lost_age(x, 2005, d, method = "quantile", min_donors = 1)

  expect_equal(out$SIFA, 0)
})

test_that("donor groups fall back to NDT-BEC, then to every donor", {
  d <- rbind(
    imputation_donors(),
    data.frame(NDT_BEC = "NDT2-SBS", agent = "CUT", age = 300, weight = 1)
  )
  ## no NDT3-SBS fire donors: falls back to NDT3-SBS (median 100); an unseen zone uses all donors,
  ## whose weighted median is 140 (cumulative 1, 2, 4, 5 of 5)
  x <- lost_fixture(c("NDT3-SBS", "NDT1-ESSF"), c("BRN", "CUT"), 2015)
  out <- impute_lost_age(x, 2010, d, method = "quantile", min_donors = 1)

  expect_equal(out$SIFA, c(95, 135))
})

test_that("draws follow the area-weighted donor distribution, reproducibly", {
  d <- data.frame(NDT_BEC = "NDT3-SBS", agent = "CUT", age = c(60, 140), weight = c(3, 1))
  x <- lost_fixture(rep("NDT3-SBS", 4000), "CUT", 2010)

  a <- impute_lost_age(x, 2010, d, min_donors = 1)
  b <- impute_lost_age(x, 2010, d, min_donors = 1)

  expect_identical(a$SIFA, b$SIFA)
  expect_setequal(unique(a$SIFA), c(60, 140))
  expect_equal(mean(a$SIFA == 60), 0.75, tolerance = 0.03)
})

test_that("donors exclude ages within the VRI-update tolerance and before `since`", {
  x <- tibble::tibble(
    NDT_BEC = "NDT3-SBS",
    MRSRD_A = "CUT",
    MRSRD_Y = c(2015, 2015, 2000),
    PROJ_AGE_1 = c(109, 12, 150),
    ha = 1
  )
  d <- donor_ages(x)

  ## 109 - 9 = 100 at harvest; 12 is a regeneration age; the 2000 cut predates `since`
  expect_equal(d$age, 100)
})
