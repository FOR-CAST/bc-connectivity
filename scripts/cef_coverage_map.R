## Where CEF records fire severity, and where CanLaBS/CanLaD fill in what it does not.
##
## Supports the "Disturbance the CEF record misses" section of reports/methods.qmd, which draws the
## map from what this writes. For one district, on the CanLaD/CanLaBS 30 m grid over its buffered
## extent:
##
##   * cef_extent -- the CEF layer has a polygon here
##   * fsg       -- CEF records fire severity from its 1985-2014 product (FSG) on the polygon
##   * fsh_fsy   -- CEF records fire severity from its 2015-2024 products (FSH, FSY)
##   * fire_ls   -- a Landsat fire reset is added: CEF does not record that fire
##   * insect_ls -- a Landsat insect-mortality reset is added
##   * age_lowered    -- the merged resets lower the present stand age
##   * age_lowered_10 -- ... by more than 10 years, enough to move a stand between seral stages
##
## The added resets are decided by the pipeline's own rules -- `landsat_reset_cells()` for the
## pixel events, `apply_landsat_resets()` for what CEF already records -- without the 1 ha sieve,
## which does not show at map scale. Each layer is written as the share of each 300 m cell, on a
## grid aligned across districts so the three can be mosaicked without resampling, together with
## the area of each inside the unbuffered district.
##
## One-off; not part of the targets pipeline. Run from the project root on a compute node:
##   Rscript-4.5.3 scripts/cef_coverage_map.R <district_key>
##   Rscript-4.5.3 scripts/cef_coverage_map.R province
## Cariboo-Chilcotin needs about 60 GB.

targets::tar_source()

d <- commandArgs(TRUE)[1]
out_dir <- file.path("Outputs", "cef-coverage")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

## `province`: the 1985-2014 fire-severity product (FSG) across the whole CEF layer, as the share of
## each 1 km cell, with the province's outline -- the context that shows it stopping at the Cariboo
## districts rather than being sparse everywhere. Read straight from the geodatabase, in its own
## BC Albers projection; about 10 minutes.
if (identical(d, "province")) {
  gdb <- file.path(get_path("download"), "BC_CEF_Forest_Disturbance_2024.gdb")
  fsg <- terra::vect(
    gdb,
    query = "SELECT DSTRB_HIST FROM BC_CEF_ForestDisturbance_2024 WHERE DSTRB_HIST LIKE '%FSG%'"
  )
  bc <- terra::vect(bcmaps::bc_bound()) |> terra::project(terra::crs(fsg))
  r100 <- terra::rast(bc, resolution = 100)
  cover <- terra::rasterize(fsg, r100, field = 1, background = 0) |>
    terra::aggregate(fact = 10, fun = "mean")
  names(cover) <- "fsg"
  terra::writeRaster(
    cover,
    file.path(out_dir, "province_fsg.tif"),
    overwrite = TRUE,
    datatype = "FLT4S"
  )
  terra::writeVector(bc, file.path(out_dir, "province_boundary.gpkg"), overwrite = TRUE)
  quit(save = "no")
}
fact <- 10L ## 30 m -> 300 m

files <- file.path(
  get_path("download"),
  vapply(landsat_input_sources(), `[[`, "", "file")
)
pick <- function(f) files[match(f, basename(files))]
lbs <- LANDSAT_DISTURBANCE$canlabs$files
grid <- terra::rast(pick(lbs[["canlabs_dnbr"]]))

aoi <- terra::vect(sprintf("Data/processed/%s/studyarea_buffered.gpkg", d)) |>
  terra::project(terra::crs(grid))
district <- terra::vect(sprintf("Data/processed/%s/studyarea.gpkg", d)) |>
  terra::project(terra::crs(grid))
## snap to the 300 m lattice of the national grid, so every district's aggregate lines up
step <- terra::res(grid)[1] * fact
b <- as.vector(terra::ext(aoi))
e <- terra::ext(
  floor(b[1] / step) * step,
  ceiling(b[2] / step) * step,
  floor(b[3] / step) * step,
  ceiling(b[4] / step) * step
)
grab <- function(f) terra::crop(terra::rast(f), e, snap = "out")

dnbr <- grab(pick(lbs[["canlabs_dnbr"]]))
outside <- is.na(terra::rasterize(aoi, dnbr))
events <- landsat_reset_cells(
  dnbr = dnbr,
  nbac = terra::mask(grab(pick(lbs[["canlabs_nbac"]])), outside, maskvalues = TRUE),
  salvage = grab(pick(lbs[["canlabs_salvage"]])),
  canlad = terra::mask(grab(pick(LANDSAT_DISTURBANCE$canlad$files)), outside, maskvalues = TRUE)
)
message("pixel events: ", nrow(events))

cef <- terra::vect(sprintf("Data/processed/%s/forest_disturbance.gpkg", d))
cef <- terra::project(cef[, c("SIFA", "DSTRB_HIST", "MRSRD_Y", "MRSRD_A")], terra::crs(grid))
cef$id <- seq_len(nrow(cef))
idv <- as.integer(terra::values(terra::rasterize(cef, dnbr, field = "id"), mat = FALSE))
attrs <- terra::as.data.frame(cef)

## Landsat events per pixel, decided once per (polygon, history) pair rather than per pixel
events$id <- idv[events$cell]
events <- events[!is.na(events$id), ]
events$token <- sprintf(
  "%d_%s_%s_LS",
  events$year,
  events$agent,
  c(BRN = "R", INS = "H")[events$agent]
)
events <- events[order(events$cell, -events$year), ]
hist <- tapply(events$token, events$cell, paste, collapse = ",")
px <- data.frame(cell = as.integer(names(hist)), RESET_HIST = as.vector(hist))
px$id <- idv[px$cell]
pairs <- unique(px[, c("id", "RESET_HIST")])
x <- cbind(
  attrs[pairs$id, c("SIFA", "DSTRB_HIST", "MRSRD_Y", "MRSRD_A")],
  RESET_HIST = pairs$RESET_HIST
)
merged <- apply_landsat_resets(x)
added <- substring(merged$DSTRB_HIST, nchar(dplyr::coalesce(x$DSTRB_HIST, "")) + 1L)
pairs$fire <- grepl("_BRN_R_LS", added, fixed = TRUE)
pairs$insect <- grepl("_INS_H_LS", added, fixed = TRUE)
pairs$younger <- !is.na(merged$SIFA) & merged$SIFA < x$SIFA
## by more than the inventory-update tolerance: an age that was already the regenerating stand's
## is trimmed by a year or two, which moves no stand between seral stages
pairs$younger_10 <- pairs$younger & x$SIFA - merged$SIFA > 10
px <- merge(px, pairs, by = c("id", "RESET_HIST"))
message("pixels with an added reset: ", sum(px$fire | px$insect))

## The CEF layers are kept over the whole extent the CEF layer was clipped to -- the bounding box of
## the buffered district, so most of the 1985-2014 product lies outside the buffer itself -- and the
## Landsat ones over the buffered district, where the pipeline adds them.
no_cef <- terra::rast(dnbr, vals = is.na(idv))
layer <- function(cells, within = outside) {
  r <- terra::rast(dnbr, vals = 0L)
  r[cells] <- 1L
  terra::mask(r, within, maskvalues = TRUE)
}
flag <- function(pattern) which(grepl(pattern, attrs$DSTRB_HIST)[idv])
r <- c(
  layer(which(!is.na(idv)), within = no_cef),
  layer(flag("_FSG"), within = no_cef),
  layer(flag("_FSH|_FSY"), within = no_cef),
  layer(px$cell[px$fire]),
  layer(px$cell[px$insect]),
  layer(px$cell[px$younger]),
  layer(px$cell[px$younger_10])
)
names(r) <- c(
  "cef_extent",
  "fsg",
  "fsh_fsy",
  "fire_ls",
  "insect_ls",
  "age_lowered",
  "age_lowered_10"
)

## area inside the unbuffered district, 30 m
inside <- !is.na(terra::values(terra::rasterize(district, dnbr), mat = FALSE))
cell_ha <- prod(terra::res(dnbr)) / 1e4
ha <- vapply(
  names(r),
  function(n) sum(terra::values(r[[n]], mat = FALSE)[inside] %in% 1L) * cell_ha,
  0
)
utils::write.csv(
  data.frame(district = d, layer = names(ha), ha = round(ha)),
  file.path(out_dir, sprintf("%s_area.csv", d)),
  row.names = FALSE
)

terra::writeRaster(
  terra::aggregate(r, fact = fact, fun = "mean", na.rm = TRUE),
  file.path(out_dir, sprintf("%s.tif", d)),
  overwrite = TRUE,
  datatype = "FLT4S"
)
terra::writeVector(district, file.path(out_dir, sprintf("%s_boundary.gpkg", d)), overwrite = TRUE)
print(ha)
