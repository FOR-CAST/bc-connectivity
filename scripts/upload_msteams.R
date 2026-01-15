library("Microsoft365R")

inputRasterPath <- "Data/processed/rasters"
outputPath <- "Outputs"

upload_path_inputs <- "Content/Phase 3/Case Study -- Omniscape Quesnel TSA/Omniscape Inputs"
upload_path_outputs <- "Content/Phase 3/Case Study -- Omniscape Quesnel TSA/Omniscape Outputs"

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

# shpt$list_files(path = upload_path_outputs)

shpt$upload_file(
  src = file.path(outputPath, "Quesnel_TSA_seral_patch_stats.csv"),
  dest = file.path(upload_path_outputs, "Quesnel_TSA_seral_patch_stats.csv")
)

shpt$upload_folder(
  src = file.path(outputPath, "figures"),
  dest = file.path(upload_path_outputs, "figures")
)

# shpt$create_folder(path = upload_path_inputs)
shpt$upload_folder(src = inputRasterPath, dest = upload_path_inputs, recursive = TRUE)

omniscape_outputs <- fs::dir_ls(outputPath, type = "directory", regexp = "2026-01-13_.*") |>
  fs::path_rel(outputPath)

purrr::walk2(
  .x = file.path(outputPath, omniscape_outputs),
  .y = file.path(upload_path_outputs, omniscape_outputs),
  .f = function(x, y) {
    ## create the remote directory if it doesn't exist
    if (!basename(y) %in% shpt$list_items(upload_path_outputs)$name) {
      shpt$create_folder(path = y)
    }

    shpt$upload_folder(src = x, dest = y)
  }
)
