library("Microsoft365R")

downloadPath <- normalizePath("Teams")

## see https://github.com/Azure/Microsoft365R?tab=readme-ov-file#teams
auth_type <- if (quickPlot::isRstudioServer()) "device_code" else NULL

## work around needing admin approval by passing 'app', per:
## <https://cran.r-project.org/web/packages/Microsoft365R/vignettes/auth.html>
app <- "04b07795-8ddb-461a-bbee-02f9e1bf7b46"

list_teams(tenant = "bcgov", app = app)

team <- get_team(
  "External: Landscape Integrity",
  tenant = "bcgov",
  auth_type = auth_type,
  app = app
)

team$list_channels()

chan <- team$get_channel("Content")

chan_folder <- chan$get_folder()

all_dirs <- chan_folder$list_files() |> subset(isdir == TRUE)

## download all (doesn't properly handle recursive dirs)
chan_folder$download(dest = downloadPath, recursive = TRUE, parallel = TRUE)

## recursively download directories
download_dir <- function(src, dst, chan_folder, recursive = FALSE) {
  message(glue::glue("Downloading '{src}' to '{dst}' ..."))
  tryCatch(
    {
      chan_folder$get_item(path = src)$download(
        dest = dst,
        overwrite = TRUE,
        recursive = TRUE,
        parallel = TRUE
      )
    },
    error = function(e) warning(e)
  )

  if (recursive) {
    subdirs <- subset(
      chan_folder$list_files(path = src, full_names = TRUE),
      isdir == TRUE & size > 0
    )$name

    lapply(subdirs, function(subd) {
      download_dir(
        src = subd,
        dst = file.path(dst, basename(subd)),
        chan_folder = chan_folder,
        recursive = recursive
      )
    })
  }

  invisible(TRUE)
}

all_dirs <- subset(chan_folder$list_files(), isdir == TRUE)$name

lapply(all_dirs, FUN = function(d) {
  download_dir(
    src = d,
    dst = file.path(downloadPath, d),
    chan_folder = chan_folder,
    recursive = TRUE
  )
})
