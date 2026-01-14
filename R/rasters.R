# prepare resistance and source weight rasters ------------------------------------------------

create_resistance_raster <- function(polys, rasterToMatch, dst) {
  ## append raster resolution to filename
  dst <- sub("[.]tif$", paste0("_", terra::res(rasterToMatch)[1], ".tif"), dst)
  dst <- file.path(get_path("rasters"), dst)

  terra::rasterize(
    polys,
    rasterToMatch,
    field = "Resistance",
    fun = mean,
    na.rm = TRUE,
    filename = dst,
    overwrite = TRUE
  )

  return(dst)
}

create_sourcewt_raster <- function(polys, rasterToMatch, dst) {
  ## append raster resolution to filename
  dst <- sub("[.]tif$", paste0("_", terra::res(rasterToMatch)[1], ".tif"), dst)
  dst <- file.path(get_path("rasters"), dst)

  terra::rasterize(
    polys,
    rasterToMatch,
    field = "SourceWt",
    fun = mean,
    na.rm = TRUE,
    filename = dst,
    overwrite = TRUE
  )

  return(dst)
}

# Composite resistance raster -----------------------------------------------------------------

#' Create composite resistance and source weight rasters
#'
#' @param forest,roads,streams,lakes,wetlands raster file paths
#'
#' @return path to the composite raster
#'
#' @export
#' @rdname composite_rasters
create_composite_resistance_raster <- function(
  forest,
  roads,
  streams,
  rivers,
  lakes,
  wetlands,
  dst
) {
  ## Load resistance rasters
  resistance <- c(forest, roads, streams, rivers, lakes, wetlands) |> terra::rast()

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
    }
  )

  ## A very small number of pixels (81) show up as 0 which can cause problems with the
  ## Omniscape run, so reclassify as 1 and classify N/A as 1000
  composite_resistance[composite_resistance == 0] <- 1
  composite_resistance[is.na(composite_resistance)] <- 1000

  res <- terra::res(composite_resistance) |> unique()
  dst <- file.path(get_path("rasters"), sub("[.]tif$", glue::glue("_{res}.tif"), dst))
  terra::writeRaster(composite_resistance, dst, overwrite = TRUE)

  return(dst)
}

## Source weight composite raster -------------------------------------------------------------

#' @export
#' @rdname composite_rasters
create_composite_sourcewt_raster <- function(
  forest,
  roads,
  streams,
  rivers,
  lakes,
  wetlands,
  dst
) {
  ## Load resistance rasters
  sourcewt <- c(forest, roads, streams, rivers, lakes, wetlands) |> terra::rast()

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
    }
  )

  ## Replace NA values with 0 to avoid errors in Omniscape run
  composite_sourcewt[is.na(composite_sourcewt)] <- 0

  res <- terra::res(composite_sourcewt) |> unique()
  dst <- file.path(get_path("rasters"), sub("[.]tif$", glue::glue("_{res}.tif"), dst))
  terra::writeRaster(composite_sourcewt, dst, overwrite = TRUE)

  return(dst)
}
