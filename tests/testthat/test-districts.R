## Which resolutions a district is built at decides the whole raster graph, and the two ways to
## change it are environment variables rather than arguments -- so the cases worth pinning are the
## default (every district 90 m) and each override, including the precedence between them.

withr::with_envvar(
  c(BC_CONN_AGG_FACTORS = NA, BC_CONN_RESOLUTION_STUDY = NA),
  {
    test_that("every district is 90 m by default", {
      for (key in names(districts())) {
        expect_identical(district_agg_factors(key), 3, info = key)
      }
    })
  }
)

test_that("the resolution-study gate restores Quesnel's 30 m series", {
  withr::with_envvar(c(BC_CONN_RESOLUTION_STUDY = "1"), {
    expect_identical(district_agg_factors("quesnel"), c(1, 3))
    ## no other district declares `study_agg_factors`, so the flag is safe to leave set
    expect_identical(district_agg_factors("chilcotin"), 3)
  })
})

test_that("the gate reads only affirmative values", {
  expect_true(resolution_study_enabled("1"))
  expect_true(resolution_study_enabled("TRUE"))
  expect_true(resolution_study_enabled(" yes "))
  expect_false(resolution_study_enabled(""))
  expect_false(resolution_study_enabled("0"))
  expect_false(resolution_study_enabled("false"))
})

test_that("BC_CONN_AGG_FACTORS wins over the gate", {
  withr::with_envvar(c(BC_CONN_AGG_FACTORS = "1", BC_CONN_RESOLUTION_STUDY = "1"), {
    expect_identical(district_agg_factors("quesnel"), 1)
  })
})
