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

## Interpatch distances ------------------------------------------------------------------------

test_that("no district measures its own interpatch distances by default", {
  withr::with_envvar(c(BC_CONN_INTERPATCH_DISTANCES = NA), {
    for (key in names(districts())) {
      expect_false(district_interpatch_distances(key), info = key)
    }
  })
})

test_that("BC_CONN_INTERPATCH_DISTANCES turns the chain back on", {
  withr::with_envvar(c(BC_CONN_INTERPATCH_DISTANCES = "1"), {
    expect_true(district_interpatch_distances("quesnel"))
    expect_true(district_interpatch_distances("chilcotin"))
  })
  withr::with_envvar(c(BC_CONN_INTERPATCH_DISTANCES = "0"), {
    expect_false(district_interpatch_distances("quesnel"))
  })
})

## The radii are constants now, so nothing in the pipeline would notice them drifting from what
## Quesnel actually measured -- this is that check. What has to agree is the radius in PIXELS,
## since that is what `write_omniscape_config()` derives and all Omniscape sees.
test_that("the recorded radii still reproduce the frozen archive's", {
  ## `workflowtools::findProjectPath()` returns the working directory here rather than walking up
  ## to the real root, so navigate from the test file instead.
  store <- normalizePath(test_path("..", "..", "_targets"), mustWork = FALSE)
  skip_if_not(dir.exists(store), "frozen Quesnel archive not available")

  as_px <- function(m, pixel_size = 90) {
    if (inherits(m, "units")) {
      m <- units::drop_units(m)
    }
    ceiling(round(as.numeric(m), 0) / pixel_size)
  }

  expect_identical(
    as_px(reference_distances()$all_dists[["25%"]]),
    as_px(targets::tar_read(quantiles_all_dists, store = store)[["25%"]])
  )
  expect_identical(
    as_px(reference_distances()$nn_dists[["100%"]]),
    as_px(targets::tar_read(quantiles_nn_dists, store = store)[["100%"]])
  )
})

## The flags are arguments rather than an environment read inside the command, so the factories can
## bake their values in with `!!` and make them part of the target's identity. Passing them
## explicitly has to win over the environment, or that interpolation would be a lie.
test_that("the resolution flags can be passed explicitly, overriding the environment", {
  withr::with_envvar(c(BC_CONN_AGG_FACTORS = "1", BC_CONN_RESOLUTION_STUDY = "1"), {
    expect_identical(district_agg_factors("quesnel", override = "", study = FALSE), 3)
    expect_identical(district_agg_factors("quesnel", override = "", study = TRUE), c(1, 3))
    expect_identical(district_agg_factors("quesnel", override = "3", study = TRUE), 3)
  })
})

test_that("the flags still default to the environment when not passed", {
  withr::with_envvar(c(BC_CONN_AGG_FACTORS = NA, BC_CONN_RESOLUTION_STUDY = "1"), {
    expect_identical(district_agg_factors("quesnel"), c(1, 3))
  })
})
