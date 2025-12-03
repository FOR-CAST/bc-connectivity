terra::terraOptions(memfrac = 0.0) ## perform raster operations on disk

n_cores <- 1L ## see `?terra::lapp` (may not be that helpful to increase this)

# Composite Resistance Raster Creation --------------------------------------------------------

## Load resistance rasters
resistance <- c(
  terra::rast(input_files[["resistance_fordist"]]),
  terra::rast(input_files[["resistance_secondary"]]),
  terra::rast(input_files[["resistance_parks"]]),
  terra::rast(input_files[["resistance_OGMA"]]),
  terra::rast(input_files[["resistance_roads"]]),
  terra::rast(input_files[["resistance_streams"]]),
  terra::rast(input_files[["resistance_rivers"]]),
  terra::rast(input_files[["resistance_lakes"]])
)

## Composite resistance stacking with all created feature rasters
composite_resistance <- terra::lapp(
  x = resistance,
  fun = function(forest, secondary, parks, ogma, roads, streams, rivers, lakes) {
    ## Add in function where old forest will raise the resistance of secondary PAs
    secondary_mod <- ifelse(
      !is.na(forest) & !is.na(secondary),
      pmin(forest, secondary),
      coalesce(secondary, forest)
    )

    ## Add in function where OGMAs override all
    base_stack <- coalesce(ogma, parks, secondary_mod)

    ## Add in function where roads can only raise resistance, not lower it
    raised_roads <- ifelse(!is.na(roads), pmax(base_stack, roads, na.rm = TRUE), base_stack)
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

    return(raised_lakes)
  },
  cores = n_cores
)

# A very small number of pixels (81) show up as 0 which can cause problems with the
# omniscape run, so reclassify as 1 and classify N/A as 1000
composite_resistance[composite_resistance == 0] <- 1
composite_resistance[is.na(composite_resistance)] <- 1000

# write composite resistance raster for Omniscape run
writeRaster(
  composite_resistance,
  input_files[["resistance_composite"]],
  overwrite = TRUE
)

# Composite Source Weight Raster Creation -----------------------------------------------------

sourcewt <- c(
  terra::rast(input_files[["sourcewt_fordist"]]),
  terra::rast(input_files[["sourcewt_secondary"]]),
  terra::rast(input_files[["sourcewt_parks"]]),
  terra::rast(input_files[["sourcewt_OGMA"]]),
  terra::rast(input_files[["sourcewt_roads"]]),
  terra::rast(input_files[["sourcewt_streams"]]),
  terra::rast(input_files[["sourcewt_rivers"]]),
  terra::rast(input_files[["sourcewt_lakes"]])
)

## Composite source weight stacking with all created feature rasters (functions are
## the inverse of the resistance raster functions)
composite_sourcewt <- terra::lapp(
  x = sourcewt,
  fun = function(forest, secondary, parks, ogma, roads, streams, rivers, lakes) {
    ## Add in function where Old Forest raises source weight of secondary PAs
    secondary_mod <- ifelse(
      !is.na(forest) & !is.na(secondary),
      pmax(forest, secondary),
      coalesce(secondary, forest)
    )

    ## Add in function where OGMA overrides all
    base_stack <- coalesce(ogma, parks, secondary_mod)

    ## Add in function where roads, streams, rivers, and lakes can only lower source weight
    lowered_roads <- ifelse(!is.na(roads), pmin(base_stack, roads, na.rm = TRUE), base_stack)
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

    return(lowered_lakes)
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
