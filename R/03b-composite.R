terra::terraOptions(memfrac = 0.0) ## perform raster operations on disk

n_cores <- 1L ## see `?terra::lapp` (may not be that helpful to increase this)

# All-layer composite rasters -----------------------------------------------------------------

## All-layer resistance composite -------------------------------------------------------------

## Load resistance rasters
resistance <- c(
  input_files[["resistance_fordist"]],
  input_files[["resistance_roads"]],
  input_files[["resistance_streams"]],
  input_files[["resistance_rivers"]],
  input_files[["resistance_lakes"]],
  input_files[["resistance_wetlands"]]
) |>
  terra::rast()

composite_resistance <- terra::lapp(
  x = resistance,
  fun = function(forest, roads, streams, rivers, lakes, wetlands) {
    ## roads, streams, rivers, lakes, wetlands raise landscape resistance
    raised_roads <- ifelse(!is.na(roads), pmax(forest, roads, na.rm = TRUE), forest)
    raised_streams <- ifelse(
      !is.na(streams),
      pmax(raised_roads, streams, na.rm = TRUE),
      raised_roads
    )
    raised_rivers <- ifelse(
      !is.na(rivers),
      pmax(raised_streams, rivers, na.rm = TRUE),
      raised_streams
    )
    raised_lakes <- ifelse(!is.na(lakes), pmax(raised_rivers, lakes, na.rm = TRUE), raised_rivers)
    raised_wetlands <- ifelse(
      !is.na(wetlands),
      pmax(raised_lakes, wetlands, na.rm = TRUE),
      raised_lakes
    )

    return(raised_wetlands)
  },
  cores = n_cores
)

## A very small number of pixels (81) show up as 0 which can cause problems with the
## Omniscape run, so reclassify as 1 and classify N/A as 1000
composite_resistance[composite_resistance == 0] <- 1
composite_resistance[is.na(composite_resistance)] <- 1000

terra::writeRaster(
  composite_resistance,
  input_files[["resistance_composite"]],
  overwrite = TRUE
)

## All-layer source weight composite ----------------------------------------------------------

sourcewt <- c(
  input_files[["sourcewt_fordist"]],
  input_files[["sourcewt_roads"]],
  input_files[["sourcewt_streams"]],
  input_files[["sourcewt_rivers"]],
  input_files[["sourcewt_lakes"]],
  input_files[["sourcewt_wetlands"]]
) |>
  terra::rast()

composite_sourcewt <- terra::lapp(
  x = sourcewt,
  fun = function(forest, roads, streams, rivers, lakes, wetlands) {
    ## Add in function where roads, streams, rivers, and lakes can only lower source weight
    lowered_roads <- ifelse(!is.na(roads), pmin(forest, roads, na.rm = TRUE), forest)
    lowered_streams <- ifelse(
      !is.na(streams),
      pmin(lowered_roads, streams, na.rm = TRUE),
      lowered_roads
    )
    lowered_rivers <- ifelse(
      !is.na(rivers),
      pmin(lowered_streams, rivers, na.rm = TRUE),
      lowered_streams
    )
    lowered_lakes <- ifelse(
      !is.na(lakes),
      pmin(lowered_rivers, lakes, na.rm = TRUE),
      lowered_rivers
    )
    lowered_wetlands <- ifelse(
      !is.na(wetlands),
      pmin(lowered_lakes, wetlands, na.rm = TRUE),
      lowered_lakes
    )

    return(lowered_wetlands)
  },
  cores = n_cores
)

## Replace NA values with 0 to avoid errors in Omniscape run
composite_sourcewt[is.na(composite_sourcewt)] <- 0

## write composite source weight raster for Omniscape run
terra::writeRaster(
  composite_sourcewt,
  input_files[["sourcewt_composite"]],
  overwrite = TRUE
)

# cleanup -------------------------------------------------------------------------------------

gc()
terra::tmpFiles(remove = TRUE)
