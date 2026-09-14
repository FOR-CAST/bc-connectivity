## Download the project team's shared input data from the SharePoint channel folder.
##
## NOT part of the reproducible analysis workflow -- see README.md in this directory.

library("Microsoft365R")

DEST <- normalizePath("Teams", mustWork = FALSE)

TEAM <- "External: Landscape Integrity"
TENANT <- "bcgov"
CHANNEL <- "Content"

# authenticate ----------------------------------------------------------------------------------

## see https://github.com/Azure/Microsoft365R?tab=readme-ov-file#teams
auth_type <- if (quickPlot::isRstudioServer()) "device_code" else NULL

## work around needing admin approval by passing 'app', per:
## <https://cran.r-project.org/web/packages/Microsoft365R/vignettes/auth.html>
app <- "04b07795-8ddb-461a-bbee-02f9e1bf7b46"

team <- get_team(TEAM, tenant = TENANT, auth_type = auth_type, app = app)
chan_folder <- team$get_channel(CHANNEL)$get_folder()

# download --------------------------------------------------------------------------------------

## Walk the tree one level at a time, downloading each directory's own files and then descending.
##
## `$download(recursive = TRUE)` on the channel folder does not descend reliably, which is why the
## walk exists. The earlier version of this script called BOTH: the whole tree was fetched by the
## unreliable recursive call and then fetched again, directory by directory, by the walk. Asking
## for each level non-recursively is the part that keeps every file to a single download, while
## still letting `parallel = TRUE` work within a level.
download_dir <- function(src, dst) {
  message(glue::glue("downloading {src}/ -> {dst}/"))
  fs::dir_create(dst)

  tryCatch(
    chan_folder$get_item(path = src)$download(
      dest = dst,
      overwrite = TRUE,
      recursive = FALSE,
      parallel = TRUE
    ),
    error = function(e) warning(e)
  )

  ## `size > 0` skips the empty directories the site carries, which have nothing to fetch
  subdirs <- subset(
    chan_folder$list_files(path = src, full_names = TRUE),
    isdir == TRUE & size > 0
  )$name

  lapply(subdirs, function(d) download_dir(d, file.path(dst, basename(d))))

  invisible(TRUE)
}

top_level <- subset(chan_folder$list_files(), isdir == TRUE)$name

message(glue::glue(
  "downloading {length(top_level)} top-level folder(s) into {DEST}"
))

invisible(lapply(top_level, function(d) download_dir(d, file.path(DEST, d))))
