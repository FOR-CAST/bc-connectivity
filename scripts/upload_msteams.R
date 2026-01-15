library("Microsoft365R")

outputPath <- "Outputs"
uploadPath <- "Content/Phase 3/Case Study -- Omniscape Quesnel TSA/Omniscape Outputs"

## see https://github.com/Azure/Microsoft365R?tab=readme-ov-file#teams
auth_type <- if (quickPlot::isRstudioServer()) "device_code" else NULL

## work around needing admin approval by passing 'app', per:
## <https://cran.r-project.org/web/packages/Microsoft365R/vignettes/auth.html>
app <- "04b07795-8ddb-461a-bbee-02f9e1bf7b46"

team <- get_team(
  "External: Landscape Integrity",
  tenant = "bcgov",
  auth_type = auth_type,
  app = app
)
shpt <- team$get_sharepoint_site()$list_drives()[[1]] ## Documents

# shpt$list_files(path = uploadPath)

shpt$upload_file(
  src = file.path(outputPath, "Quesnel_TSA_seral_patch_stats.csv"),
  dest = file.path(uploadPath, "Quesnel_TSA_seral_patch_stats.csv")
)

shpt$upload_folder(
  src = file.path(outputPath, "figures"),
  dest = file.path(uploadPath, "figures"),
  recursive = TRUE
)

omniscape_outputs <- fs::dir_ls(outputPath, type = "directory", regexp = "2026-01-13_.*") |>
  fs::path_rel(outputPath)

purrr::walk2(
  .x = file.path(outputPath, omniscape_outputs),
  .y = file.path(uploadPath, omniscape_outputs),
  .f = function(x, y) {
    ## create the remote directory if it doesn't exist
    if (!basename(y) %in% shpt$list_items(uploadPath)$name) {
      shpt$create_folder(path = y)
    }

    shpt$upload_folder(src = x, dest = y, recursive = TRUE)
  }
)
