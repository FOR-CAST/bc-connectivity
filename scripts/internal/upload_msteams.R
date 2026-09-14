## Work out what needs uploading to the project team's SharePoint site, and optionally upload it.
##
## NOT part of the reproducible analysis workflow -- see README.md in this directory.
##
## READ-ONLY BY DEFAULT. Uploading through this script needs a Graph token carrying
## `Files.ReadWrite.All` or `Sites.ReadWrite.All`, and the public Azure CLI client used here is
## not consented for either in the `bcgov` tenant: reads succeed, the first `upload_file()` returns
## HTTP 401. Until that changes the transfer is done by hand in the browser, and what this script
## is for is telling you exactly which files to drag.
##
## Set DRY_RUN to FALSE only once a write scope is actually granted; the preflight below will stop
## you otherwise rather than failing partway through a 197 MB file.

library("Microsoft365R")

DRY_RUN <- TRUE

targets::tar_source()

input_rasters <- get_path("rasters")
output_dir <- get_path("outputs")

TEAM <- "External: Landscape Integrity"
TENANT <- "bcgov"
REMOTE_ROOT <- "Content/Phase 3/Case Study -- Omniscape Quesnel TSA"
REMOTE_INPUTS <- file.path(REMOTE_ROOT, "Omniscape Inputs")
REMOTE_OUTPUTS <- file.path(REMOTE_ROOT, "Omniscape Outputs")

## Which Omniscape run directories to keep current on the site.
##
## Only the corrected `2026-08-26` runs. The delivered `2026-01-23` set has been moved into `_old/`
## on the site, where it stays: it is the record of what was handed over, not something to keep in
## step with the working copy. Re-add it here only to restore it alongside the corrected runs.
##
## The `2026-01-13` vintage and every directory carrying a `_t<n>` or `_<n>` suffix are
## thread-scaling benchmark reruns rather than results, so the pattern requires a name to end at
## the block size.
RUN_VINTAGES <- "2026-08-26"
RUN_PATTERN <- paste0(
  "^(",
  paste(RUN_VINTAGES, collapse = "|"),
  ")_p[0-9]+_r[0-9]+_bs[0-9]+$"
)

WRITE_SCOPES <- c("Files.ReadWrite.All", "Sites.ReadWrite.All")

# authenticate ----------------------------------------------------------------------------------

## see https://github.com/Azure/Microsoft365R?tab=readme-ov-file#teams
auth_type <- if (quickPlot::isRstudioServer()) "device_code" else NULL

## work around needing admin approval by passing 'app', per:
## <https://cran.r-project.org/web/packages/Microsoft365R/vignettes/auth.html>
app <- "04b07795-8ddb-461a-bbee-02f9e1bf7b46"

team <- get_team(TEAM, tenant = TENANT, auth_type = auth_type, app = app)
shpt <- team$get_sharepoint_site()$list_drives()[[1]] ## Documents

## Fail before transferring anything rather than after. `.default` returns whatever the tenant has
## already consented for this client, so a missing scope here cannot be fixed by asking for it.
if (!DRY_RUN) {
  granted <- strsplit(team$token$credentials$scope %||% "", " ")[[1]]
  if (!any(basename(granted) %in% WRITE_SCOPES)) {
    stop(
      "this token carries no write scope (",
      paste(WRITE_SCOPES, collapse = " or "),
      "),\n",
      "so uploads will fail with HTTP 401. Upload in the browser, or have a tenant admin\n",
      "consent one of those scopes for this client.",
      call. = FALSE
    )
  }
}

# compare local against remote ------------------------------------------------------------------

remote_index <- function(path) {
  out <- tryCatch(shpt$list_files(path = path), error = function(e) NULL)
  if (is.null(out)) {
    return(data.frame(name = character(), size = numeric(), isdir = logical()))
  }
  out[, c("name", "size", "isdir"), drop = FALSE]
}

## Classify each local file against what is already on the site. Sizes are all SharePoint reports
## without downloading, so "same size" is the available proxy for "same file"; it is enough to tell
## a file that has never been uploaded from one that has changed.
classify <- function(local_files, remote_path) {
  rem <- remote_index(remote_path)
  nm <- basename(local_files)
  sz <- as.numeric(fs::file_info(local_files)$size)
  rsz <- rem$size[match(nm, rem$name)]
  data.frame(
    name = nm,
    status = ifelse(is.na(rsz), "NEW", ifelse(abs(sz - rsz) > 0, "REPLACE", "same")),
    local = sz,
    remote = rsz,
    stringsAsFactors = FALSE
  )
}

report <- function(title, tbl) {
  todo <- tbl[tbl$status != "same", , drop = FALSE]
  cat("\n== ", title, " -- ", nrow(todo), " of ", nrow(tbl), " need uploading\n", sep = "")
  if (nrow(todo)) {
    print(todo[order(todo$status, todo$name), ], row.names = FALSE)
  }
  invisible(todo)
}

message(glue::glue("comparing against {REMOTE_ROOT}"))

## inputs: the rasters only. `run_omniscape()` leaves a per-run tile directory under the rasters
## path, so uploading the folder recursively would send that scratch too -- which is how the empty
## `2026-08-26_*` directories in "Omniscape Inputs" got there.
input_files <- fs::dir_ls(input_rasters, type = "file")
report("Omniscape Inputs", classify(input_files, REMOTE_INPUTS))

## outputs: the statistics table, the figures, and each result run
report(
  "Omniscape Outputs (top level)",
  classify(file.path(output_dir, "Quesnel_TSA_seral_patch_stats.csv"), REMOTE_OUTPUTS)
)

report(
  "Omniscape Outputs / figures",
  classify(
    fs::dir_ls(file.path(output_dir, "figures"), type = "file"),
    file.path(REMOTE_OUTPUTS, "figures")
  )
)

runs <- sort(basename(fs::dir_ls(output_dir, type = "directory")))
runs <- runs[grepl(RUN_PATTERN, runs)]

if (length(runs) == 0L) {
  stop("no Omniscape run directories matched ", RUN_PATTERN, " under ", output_dir)
}

## A run that has been archived under `_old/` is not something to upload. Comparing it against
## its now-empty former location would otherwise list every file in it as missing.
archived <- remote_index(file.path(REMOTE_OUTPUTS, "_old"))$name

if (length(intersect(runs, archived))) {
  cat(
    "\n== archived under _old/, not listed below --",
    paste(sort(intersect(runs, archived)), collapse = ", "),
    "\n"
  )
}

for (run in setdiff(runs, archived)) {
  report(
    file.path("Omniscape Outputs", run),
    classify(fs::dir_ls(file.path(output_dir, run), type = "file"), file.path(REMOTE_OUTPUTS, run))
  )
}

# upload ----------------------------------------------------------------------------------------

if (!DRY_RUN) {
  put <- function(src, dest) {
    message(glue::glue("uploading {basename(src)}"))
    shpt$upload_file(src = src, dest = dest)
  }

  for (f in input_files) {
    put(f, file.path(REMOTE_INPUTS, basename(f)))
  }

  put(
    file.path(output_dir, "Quesnel_TSA_seral_patch_stats.csv"),
    file.path(REMOTE_OUTPUTS, "Quesnel_TSA_seral_patch_stats.csv")
  )

  shpt$upload_folder(
    src = file.path(output_dir, "figures"),
    dest = file.path(REMOTE_OUTPUTS, "figures"),
    recursive = TRUE
  )

  existing <- shpt$list_items(REMOTE_OUTPUTS)$name

  for (run in setdiff(runs, archived)) {
    dest <- file.path(REMOTE_OUTPUTS, run)
    if (!run %in% existing) {
      shpt$create_folder(path = dest)
    }
    shpt$upload_folder(src = file.path(output_dir, run), dest = dest, recursive = TRUE)
  }
}
