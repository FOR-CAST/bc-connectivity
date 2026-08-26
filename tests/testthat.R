## Standalone test suite for this analysis project (not an R package).
##
## Run with:
##   targets::tar_source(); testthat::test_dir("tests/testthat")
## or:
##   Rscript tests/testthat.R

if (!requireNamespace("testthat", quietly = TRUE)) {
  stop("the `testthat` package is required to run these tests")
}

targets::tar_source()

testthat::test_dir("tests/testthat", package = NULL, stop_on_failure = TRUE)
