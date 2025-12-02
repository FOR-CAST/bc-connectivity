input_files <- append(
  input_files,
  list(
    ## forest disturbance
    resistance_fordist = file.path(inputs_raster_dir, "resistance_forest_disturbance.tif"),
    sourcewt_fordist = file.path(inputs_raster_dir, "sourcewt_forest_disturbance.tif"),

    ## consolidated roads and railways
    resistance_roads = file.path(inputs_raster_dir, "resistance_roads_.tif"),
    sourcewt_roads = file.path(inputs_raster_dir, "sourcewt_roads.tif"),

    ## consolidated WHA, MDWR, moose wetlands, and wetlands (secondary protected areas)
    resistance_secondary = file.path(inputs_raster_dir, "resistance_secondary.tif"),
    sourcewt_secondary = file.path(inputs_raster_dir, "sourcewt_secondary.tif"),

    ## OGMA
    resistance_OGMA = file.path(inputs_raster_dir, "resistance_OGMA.tif"),
    sourcewt_OGMA = file.path(inputs_raster_dir, "sourcewt_OGMA.tif"),

    ## parks and ecological reserves
    resistance_parks = file.path(inputs_raster_dir, "resistance_parks.tif"),
    sourcewt_parks = file.path(inputs_raster_dir, "sourcewt_parks.tif"),

    ## water features (lakes, rivers, streams)
    resistance_lakes = file.path(inputs_raster_dir, "resistance_lakes.tif"),
    sourcewt_lakes = file.path(inputs_raster_dir, "sourcewt_lakes.tif"),

    resistance_rivers = file.path(inputs_raster_dir, "resistance_rivers.tif"),
    sourcewt_rivers = file.path(inputs_raster_dir, "sourcewt_rivers.tif"),

    resistance_streams = file.path(inputs_raster_dir, "resistance_streams.tif"),
    sourcewt_streams = file.path(inputs_raster_dir, "sourcewt_streams.tif")
  )
)

# prepare composite resistance and source weight rasters --------------------------------------

terra::terraOptions(memfrac = 0.0) ## perform raster operations on disk

base_raster <- terra::rast(input_files[["LCC"]])

## Create Forest Age Layer --------------------------------------------------------------------

local({
  forest_disturb <- sf::st_read(input_files[["forest_disturbance"]]) |>
    dplyr::select(SIFA) ## simple inferred forest age (SIFA)

  ## Load BEC feature layer containing BEC zones and Natural Disturbance Types;
  ## ensure it matches the formatting in the Biodiversity Guidebook
  bec_ndt <- sf::st_read(input_files[["BEC"]]) |>
    dplyr::select(NATURAL_DISTURBANCE, ZONE) |>
    dplyr::mutate(NDT_BEC = paste0(NATURAL_DISTURBANCE, "-", ZONE))

  ## Load VRI for dominant species information to distinguish 4-IDF-Fd from 4-IDF-Pl,
  ## which aligns with the Biodiversity Guidebook
  vri <- sf::st_read(input_files[["VRI"]]) |>
    dplyr::select(SPECIES_CD_1)

  ## Join forest disturbance with VRI, then join with NDT-BEC to capture SIFA,
  ## BEC Zone, NDT, and dominant species in one feature layer
  disturb_vri <- sf::st_join(forest_disturb, vri, left = FALSE)
  disturb_full <- sf::st_join(disturb_vri, bec_ndt, left = FALSE) ## very slow...

  ## Refine NDT-BEC column to assign labels for NDT4-IDF-FD and NDT4-IDF-PL based on
  ## dominant species in NDT4-IDF according to the Biodiversity Guidebook
  disturb_full <- disturb_full |>
    mutate(
      base_NDT_BEC = paste0(NATURAL_DISTURBANCE, "-", ZONE),
      NDT_BEC = dplyr::case_when(
        base_NDT_BEC == "NDT4-IDF" & grepl("^FD", SPECIES_CD_1) ~ "NDT4-IDF-FD",
        base_NDT_BEC == "NDT4-IDF" & grepl("^PL", SPECIES_CD_1) ~ "NDT4-IDF-PL",
        TRUE ~ base_NDT_BEC
      )
    )

  ## Define NDT-BEC-specific age class thresholds according to the Biodiversity
  ## Guidebook seral stage definitions table
  thresholds <- tibble::tribble(
    ~NDT_BEC      , ~Early , ~Mid , ~Mature , ~Old ,
    "NDT1-ESSF"   ,      0 ,   40 ,     120 ,  250 ,
    "NDT1-ICH"    ,      0 ,   40 ,     100 ,  250 ,
    "NDT2-ESSF"   ,      0 ,   40 ,     120 ,  250 ,
    "NDT2-ICH"    ,      0 ,   40 ,     100 ,  250 ,
    "NDT2-SBS"    ,      0 ,   40 ,     100 ,  250 ,
    "NDT3-MS"     ,      0 ,   40 ,     100 ,  140 ,
    "NDT3-ICH"    ,      0 ,   40 ,     100 ,  140 ,
    "NDT3-SBS"    ,      0 ,   40 ,     100 ,  140 ,
    "NDT3-SBPS"   ,      0 ,   40 ,     100 ,  140 ,
    "NDT4-IDF-FD" ,      0 ,   40 ,     100 ,  250 ,
    "NDT4-IDF-PL" ,      0 ,   40 ,     100 ,  140
  )

  ## Apply resistance and source weight values to forest age class thresholds
  disturb_classified <- disturb_full |>
    dplyr::left_join(thresholds, by = "NDT_BEC") |>
    dplyr::mutate(
      SIFA = as.numeric(SIFA),
      Resistance = dplyr::case_when(
        is.na(SIFA) ~ 1000,
        SIFA < Mid ~ 750,
        SIFA < Mature ~ 500,
        SIFA < Old ~ 250,
        TRUE ~ 1
      ),
      SourceWt = dplyr::case_when(
        is.na(SIFA) ~ 0,
        SIFA < Mid ~ 0.25,
        SIFA < Mature ~ 0.5,
        SIFA < Old ~ 0.75,
        TRUE ~ 1
      ),
      AgeClass = dplyr::case_when(
        is.na(SIFA) ~ "Non-forested",
        SIFA < Mid ~ "Early",
        SIFA < Mature ~ "Mid",
        SIFA < Old ~ "Mature",
        TRUE ~ "Old"
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
  # table(roads$LINE_TYPE)

  ## Filter out roads that do not exist or are being planned
  roads <- roads |>
    dplyr::filter(!LINE_TYPE %in% c("PRP", "X"))
  # table(roads$LINE_TYPE)

  ## Filter out higher use ftaFSR roads from other resource roads and assign
  ## them a higher resistance and lower source weight
  roads_res_high <- roads |>
    dplyr::filter(LINE_TYPE == "RES", LINE_TENUR == "ftaFSR") |>
    dplyr::mutate(Resistance = 750, Buffer = 50, SourceWt = 0)

  roads_res_low <- roads |>
    dplyr::filter(LINE_TYPE == "RES", LINE_TENUR != "ftaFSR") |>
    dplyr::mutate(Resistance = 500, Buffer = 25, SourceWt = 0.5)

  ## Assign other roads "high", "medium", and "low" use resistances and source
  ## weight values; create Resistance, SourceWt, and Buffer Columns for the layers
  road_lookup <- data.frame(
    LINE_TYPE = c("HWY", "AC", "LOC", "REC", "DRV", "TRL", "TRS", "OTH", "UNK"),
    Resistance = c(1000, 1000, 750, 750, 750, 500, 500, 500, 500),
    Buffer = c(250, 250, 50, 50, 50, 25, 25, 25, 25),
    SourceWt = c(0, 0, 0, 0, 0, 0.5, 0.5, 0.5, 0.5)
  )

  roads_other <- roads |>
    dplyr::filter(LINE_TYPE %in% road_lookup$LINE_TYPE) |>
    dplyr::left_join(road_lookup, by = "LINE_TYPE")

  ## Load in railways from a separate file and assign it a resistance and sourcewt
  railways <- sf::st_read(input_files[["railways"]]) |>
    mutate(Resistance = 750, Buffer = 50, SourceWt = 0)

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

## WHA, MDWR, Moose Wetlands, and Wetland Layers ----------------------------------------------

local({
  ## Assign resistance and source weight values directly
  wha_vals <- sf::st_read(input_files[["WHA"]]) |>
    dplyr::mutate(Resistance = 250, SourceWt = 0.75)

  mdwr_vals <- sf::st_read(input_files[["MDWR"]]) |>
    dplyr::mutate(Resistance = 250, SourceWt = 0.75)

  moose_wet_vals <- sf::st_read(input_files[["moose_wetlands"]]) |>
    dplyr::mutate(Resistance = 250, SourceWt = 0.75)

  wetlands_vals <- sf::st_read(input_files[["wetlands"]]) |>
    dplyr::mutate(Resistance = 250, SourceWt = 0.75)

  ## Combine all layers together for easy handling for composite raster creation
  combined_features <- dplyr::bind_rows(wha_vals, mdwr_vals, moose_wet_vals, wetlands_vals)

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
