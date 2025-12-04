terra::terraOptions(memfrac = 0.0) ## perform raster operations on disk

base_raster <- terra::rast(input_files[["LCC"]])

# prepare resistance and source weight rasters ------------------------------------------------

## Create Forest Age Layer --------------------------------------------------------------------

local({
  forest_disturb <- sf::st_read(input_files[["forest_disturbance_seral"]], quiet = TRUE)

  ## Apply resistance and source weight values to forest age class thresholds
  disturb_classified <- forest_disturb |>
    dplyr::mutate(
      Resistance = dplyr::case_when(
        is.na(Seral) ~ 1000,
        Seral == "Early" ~ 750,
        Seral == "Mid" ~ 500,
        Seral == "Mature" ~ 250,
        Seral == "Old" ~ 1,
        .default = 1000
      ),
      SourceWt = dplyr::case_when(
        is.na(Seral) ~ 0,
        Seral == "Early" ~ 0.25,
        Seral == "Mid" ~ 0.5,
        Seral == "Mature" ~ 0.75,
        Seral == "Old" ~ 1,
        .default = 0
      )
    )

  ## Rasterize to disk
  terra::rasterize(
    disturb_classified,
    base_raster,
    field = "Resistance",
    filename = input_files[["resistance_fordist"]],
    overwrite = TRUE
  )

  terra::rasterize(
    disturb_classified,
    base_raster,
    field = "SourceWt",
    filename = input_files[["sourcewt_fordist"]],
    overwrite = TRUE
  )
})

## Consolidated Roads & Railways --------------------------------------------------------------

local({
  roads <- sf::st_read(input_files[["roads"]])
  # table(roads$TRANSPORT_LINE_TYPE_CODE)

  ## Filter out roads that do not exist or are being planned
  roads <- roads |>
    dplyr::filter(!TRANSPORT_LINE_TYPE_CODE %in% c("PRP", "X"))
  # table(roads$TRANSPORT_LINE_TYPE_CODE)

  ## Filter out higher use ftaFSR roads from other resource roads and assign
  ## them a higher resistance and lower source weight
  roads_res_high <- roads |>
    dplyr::filter(TRANSPORT_LINE_TYPE_CODE == "RES", TRANSPORT_LINE_TENURE_TYPE_CODE == "ftaFSR") |>
    dplyr::mutate(Resistance = 750, Buffer = 50, SourceWt = 0)

  roads_res_low <- roads |>
    dplyr::filter(
      TRANSPORT_LINE_TYPE_CODE == "RES",
      TRANSPORT_LINE_TENURE_TYPE_CODE != "ftaFSR"
    ) |>
    dplyr::mutate(Resistance = 500, Buffer = 25, SourceWt = 0.5)

  ## Assign other roads "high", "medium", and "low" use resistances and source
  ## weight values; create Resistance, SourceWt, and Buffer Columns for the layers
  road_lookup <- data.frame(
    TRANSPORT_LINE_TYPE_CODE = c("HWY", "AC", "LOC", "REC", "DRV", "TRL", "TRS", "OTH", "UNK"),
    Resistance = c(1000, 1000, 750, 750, 750, 500, 500, 500, 500),
    Buffer = c(250, 250, 50, 50, 50, 25, 25, 25, 25),
    SourceWt = c(0, 0, 0, 0, 0, 0.5, 0.5, 0.5, 0.5)
  )

  roads_other <- roads |>
    dplyr::filter(TRANSPORT_LINE_TYPE_CODE %in% road_lookup$TRANSPORT_LINE_TYPE_CODE) |>
    dplyr::left_join(road_lookup, by = "TRANSPORT_LINE_TYPE_CODE")

  ## Load in railways from a separate file and assign it a resistance and sourcewt
  railways <- sf::st_read(input_files[["railways"]]) |>
    dplyr::mutate(Resistance = 750, Buffer = 50, SourceWt = 0)

  ## Combine and buffer all of the roads together; buffer the roads based on their
  ## assigned buffer value
  roads_all <- dplyr::bind_rows(roads_res_high, roads_res_low, roads_other, railways)
  roads_buffered <- roads_all |>
    dplyr::rowwise() |>
    dplyr::mutate(geometry = sf::st_buffer(geom, dist = Buffer)) |>
    dplyr::ungroup() |>
    sf::st_as_sf()

  ## Rasterize resistance and source weights to file
  terra::rasterize(
    roads_buffered,
    base_raster,
    field = "Resistance",
    filename = input_files[["resistance_roads"]],
    overwrite = TRUE
  )

  terra::rasterize(
    roads_buffered,
    base_raster,
    field = "SourceWt",
    filename = input_files[["sourcewt_roads"]],
    overwrite = TRUE
  )
})

## WHA, MDWR, Moose Wetlands ------------------------------------------------------------------

local({
  ## Assign resistance and source weight values directly
  wha_vals <- sf::st_read(input_files[["WHA"]]) |>
    dplyr::mutate(Resistance = 250, SourceWt = 0.75)

  mdwr_vals <- sf::st_read(input_files[["MDWR"]]) |>
    dplyr::mutate(Resistance = 250, SourceWt = 0.75)

  moose_wet_vals <- sf::st_read(input_files[["moose_wetlands"]]) |>
    dplyr::mutate(Resistance = 250, SourceWt = 0.75)

  ## Combine all layers together for easy handling for composite raster creation
  combined_features <- dplyr::bind_rows(wha_vals, mdwr_vals, moose_wet_vals)

  ## Rasterize and save outputs
  terra::rasterize(
    combined_features,
    base_raster,
    field = "Resistance",
    filename = input_files[["resistance_secondary"]],
    overwrite = TRUE
  )

  terra::rasterize(
    combined_features,
    base_raster,
    field = "SourceWt",
    filename = input_files[["sourcewt_secondary"]],
    overwrite = TRUE
  )
})

## Wetlands -----------------------------------------------------------------------------------

local({
  wetlands <- sf::st_read(input_files[["wetlands"]]) |>
    dplyr::mutate(Resistance = 250, SourceWt = 0.75)

  ## Rasterize and save outputs
  terra::rasterize(
    wetlands,
    base_raster,
    field = "Resistance",
    filename = input_files[["resistance_wetlands"]],
    overwrite = TRUE
  )

  terra::rasterize(
    wetlands,
    base_raster,
    field = "SourceWt",
    filename = input_files[["sourcewt_wetlands"]],
    overwrite = TRUE
  )
})

## OGMA ---------------------------------------------------------------------------------------

local({
  ## OGMAs are given a resistance and source weight of 1 due to their optimal
  ## biodiversity value; create a Resistance and SourceWt Column for the layers
  OGMA <- sf::st_read(input_files[["OGMA"]]) |>
    dplyr::mutate(Resistance = 1, SourceWt = 1)

  terra::rasterize(
    OGMA,
    base_raster,
    field = "Resistance",
    filename = input_files[["resistance_OGMA"]],
    overwrite = TRUE
  )

  terra::rasterize(
    OGMA,
    base_raster,
    field = "SourceWt",
    filename = input_files[["sourcewt_OGMA"]],
    overwrite = TRUE
  )
})

## BC Parks and Ecological Reserves -----------------------------------------------------------

local({
  ## BC Parks and Ecological Reserves are given a resistance and source weight of 1
  ## due to their optimal biodiversity value
  parks <- sf::st_read(input_files[["parks"]]) |>
    dplyr::mutate(Resistance = 1, SourceWt = 1)

  terra::rasterize(
    parks,
    base_raster,
    field = "Resistance",
    filename = input_files[["resistance_parks"]],
    overwrite = TRUE
  )

  terra::rasterize(
    parks,
    base_raster,
    field = "SourceWt",
    filename = input_files[["sourcewt_parks"]],
    overwrite = TRUE
  )
})

## Water features (lakes, rivers, and streams) ------------------------------------------------

local({
  ## Lakes are given a max resistance and min source weight
  lakes <- sf::st_read(input_files[["lakes"]]) |>
    dplyr::mutate(Resistance = 1000, SourceWt = 0)

  terra::rasterize(
    lakes,
    base_raster,
    field = "Resistance",
    filename = input_files[["resistance_lakes"]],
    overwrite = TRUE
  )

  terra::rasterize(
    lakes,
    base_raster,
    field = "SourceWt",
    filename = input_files[["sourcewt_lakes"]],
    overwrite = TRUE
  )

  ## Rivers are given a max resistance and min source weight
  rivers <- sf::st_read(input_files[["rivers"]]) |>
    mutate(Resistance = 1000, SourceWt = 0)

  terra::rasterize(
    rivers,
    base_raster,
    field = "Resistance",
    filename = input_files[["resistance_rivers"]],
    overwrite = TRUE
  )

  terra::rasterize(
    rivers,
    base_raster,
    field = "SourceWt",
    filename = input_files[["sourcewt_rivers"]],
    overwrite = TRUE
  )

  ## Streams are given different resistances and source weights based on stream order;
  ## buffering has been exaggerated for higher order streams so they will be present
  ## in the 30m resolution composite raster
  streams_order <- sf::st_read(input_files[["streams"]]) |>
    dplyr::filter(STREAM_ORDER != 1) ## 1 too small of a width to impact forest canopy

  streams_with_values <- streams_order |>
    dplyr::mutate(
      buffer_dist = dplyr::case_when(
        STREAM_ORDER %in% c(2, 3, 4, 5, 6) ~ 15,
        STREAM_ORDER == 7 ~ 75,
        STREAM_ORDER == 8 ~ 130,
        STREAM_ORDER == 9 ~ 300,
        TRUE ~ NA_real_
      ),
      Resistance = dplyr::case_when(
        STREAM_ORDER %in% c(5, 6, 7, 8, 9) ~ 1000,
        STREAM_ORDER == 4 ~ 750,
        STREAM_ORDER == 3 ~ 500,
        STREAM_ORDER == 2 ~ 250,
        TRUE ~ NA_real_
      ),
      SourceWt = 0
    ) |>
    dplyr::filter(!is.na(buffer_dist))

  ## Apply buffer by buffer_dist values
  buffered_streams <- sf::st_buffer(streams_with_values, dist = streams_with_values$buffer_dist)

  ## Rasterize to disk
  terra::rasterize(
    buffered_streams,
    base_raster,
    field = "Resistance",
    filename = input_files[["resistance_streams"]],
    overwrite = TRUE
  )

  terra::rasterize(
    buffered_streams,
    base_raster,
    field = "SourceWt",
    filename = input_files[["sourcewt_streams"]],
    overwrite = TRUE
  )
})

# cleanup -------------------------------------------------------------------------------------

rm(base_raster)

gc()
terra::tmpFiles(remove = TRUE)
