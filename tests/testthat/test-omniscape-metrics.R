## `parse_gnu_time()` reads the `time -v` report each Omniscape run is wrapped in.
##
## The wall-clock line is the awkward one: its own label contains colons
## ("Elapsed (wall clock) time (h:mm:ss or m:ss): 1:17:03"), so splitting on the first colon
## leaves label text in the value. That is what produced "NAs introduced by coercion" on every
## run, and a silent fall back to R's clock for the recorded `wall_seconds`.

gnu_time_report <- function(elapsed, rss_kb = 3250540, cpu = "591%") {
  c(
    "\tCommand being timed: \"julia --project=Omniscape -t 32 Omniscape/run/script.jl\"",
    "\tUser time (seconds): 11000.00",
    "\tSystem time (seconds): 500.00",
    paste0("\tPercent of CPU this job got: ", cpu),
    paste0("\tElapsed (wall clock) time (h:mm:ss or m:ss): ", elapsed),
    "\tAverage shared text size (kbytes): 0",
    paste0("\tMaximum resident set size (kbytes): ", rss_kb),
    "\tExit status: 0"
  )
}

write_report <- function(...) {
  path <- withr::local_tempfile(.local_envir = parent.frame())
  writeLines(gnu_time_report(...), path)
  path
}

test_that("wall clock parses in h:mm:ss, without warning", {
  expect_warning(m <- parse_gnu_time(write_report("1:17:03")), NA)
  expect_equal(m$wall_seconds, 4623)
})

test_that("wall clock parses in m:ss with fractional seconds", {
  expect_warning(m <- parse_gnu_time(write_report("31:59.50")), NA)
  expect_equal(m$wall_seconds, 1919.5)
})

test_that("peak RSS and CPU percent are read", {
  m <- parse_gnu_time(write_report("1:17:03", rss_kb = 3250540, cpu = "591%"))
  expect_equal(m$peak_rss_gb, 3250540 / 1024^2)
  expect_equal(m$cpu_pct, 591)
})

test_that("a missing report gives NAs rather than an error", {
  m <- parse_gnu_time(file.path(withr::local_tempdir(), "absent.txt"))
  expect_equal(m, list(peak_rss_gb = NA_real_, wall_seconds = NA_real_, cpu_pct = NA_real_))
})

test_that("a report without the elapsed line gives NA, not a wrong number", {
  path <- withr::local_tempfile()
  writeLines(grep("Elapsed", gnu_time_report("1:17:03"), invert = TRUE, value = TRUE), path)

  expect_warning(m <- parse_gnu_time(path), NA)
  expect_identical(m$wall_seconds, NA_real_)
})
