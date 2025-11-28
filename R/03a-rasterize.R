# Omniscape data prep from collected feature layers for composite resistance and
# source weight raster creation

## TODO: use terra::rasterize instead of fasterize

# Load in base raster (30m, BC Albers) to be used in shapefile rasterization
base_raster <- raster(file.path(inputs_dir, "BC_landcover.tif"))

# --- Forest Age Layer Rasterization ---

# Load forest disturbance polygons with simple inferred forest age (SIFA)
forest_disturb <- st_read(file.path(inputs_dir, "Forest_Disturbance.shp")) %>%
  select(SIFA)

# Load BEC feature layer containing BEC zones and Natural Disturbance Types
bec_ndt <- st_read(file.path(inputs_dir, "BEC.shp")) %>%
  select(NATURAL_DI, ZONE) %>%
  mutate(NDT_BEC = paste0(NATURAL_DI, "-", ZONE)) # matches the formatting in the Biodiversity Guidebook

# Load VRI for dominant species information to distinguish 4-IDF-Fd from 4-IDF-Pl
# which aligns with the Biodiversity Guidebook
vri <- st_read(file.path(inputs_dir, "VRI.shp")) %>%
  select(SPECIES_CD)

# Join forest disturbance with VRI, then join with NDT-BEC to capture SIFA,
# BEC Zone, NDT, and dominant species in one feature layer
disturb_vri <- st_join(forest_disturb, vri, left = FALSE)
disturb_full <- st_join(disturb_vri, bec_ndt, left = FALSE)

# Refine NDT-BEC column to assign labels for NDT4-IDF-FD and NDT4-IDF-PL based on
# dominant species in NDT4-IDF according to the Biodiversity Guidebook
disturb_full <- disturb_full %>%
  mutate(
    base_NDT_BEC = paste0(NATURAL_DI, "-", ZONE),
    NDT_BEC = case_when(
      base_NDT_BEC == "NDT4-IDF" & grepl("^FD", SPECIES_CD) ~ "NDT4-IDF-FD",
      base_NDT_BEC == "NDT4-IDF" & grepl("^PL", SPECIES_CD) ~ "NDT4-IDF-PL",
      TRUE ~ base_NDT_BEC
    )
  )

# Define NDT-BEC-specific age class thresholds according to the Biodiversity
# Guidebook seral stage definitions table
thresholds <- tribble(
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

# Apply resistance and source weight values to forest age class thresholds
disturb_classified <- disturb_full %>%
  left_join(thresholds, by = "NDT_BEC") %>%
  mutate(
    SIFA = as.numeric(SIFA),
    Resistance = case_when(
      is.na(SIFA) ~ 1000,
      SIFA < Mid ~ 750,
      SIFA < Mature ~ 500,
      SIFA < Old ~ 250,
      TRUE ~ 1
    ),
    SourceWt = case_when(
      is.na(SIFA) ~ 0,
      SIFA < Mid ~ 0.25,
      SIFA < Mature ~ 0.5,
      SIFA < Old ~ 0.75,
      TRUE ~ 1
    ),
    AgeClass = case_when(
      is.na(SIFA) ~ "Non-forested",
      SIFA < Mid ~ "Early",
      SIFA < Mature ~ "Mid",
      SIFA < Old ~ "Mature",
      TRUE ~ "Old"
    )
  )

# Rasterize and save outputs
res_raster <- fasterize(disturb_classified, base_raster, field = "Resistance")
sw_raster <- fasterize(disturb_classified, base_raster, field = "SourceWt")
writeRaster(
  res_raster,
  file.path(inputs_raster_dir, "resistance_forest_disturbance.tif"),
  overwrite = TRUE
)
writeRaster(
  sw_raster,
  file.path(inputs_raster_dir, "sourcewt_forest_disturbance.tif"),
  overwrite = TRUE
)

# --- Consolidated roads & Railways Rasterization ---

# Load consolidated Cariboo roads layer
roads <- st_read(file.path(inputs_dir, "Consolidated_roads.shp"))
table(roads$LINE_TYPE)

# Filter out unwanted road types from the consolidated roads layer
roads <- roads %>%
  filter(!LINE_TYPE %in% c("PRP", "X")) # roads that do not exist or are being planned are filtered out
table(roads$LINE_TYPE)

# Filter out higher use ftaFSR roads from other resource roads and assign
# them a higher resistance and lower source weight
roads_res_high <- roads %>%
  filter(LINE_TYPE == "RES", LINE_TENUR == "ftaFSR") %>%
  mutate(Resistance = 750, Buffer = 50, SourceWt = 0)
roads_res_low <- roads %>%
  filter(LINE_TYPE == "RES", LINE_TENUR != "ftaFSR") %>%
  mutate(Resistance = 500, Buffer = 25, SourceWt = 0.5)

# Assign other roads "high", "medium", and "low" use resistances and source
# weight values; create Resistance, SourceWt, and Buffer Columns for the layers
road_lookup <- data.frame(
  LINE_TYPE = c("HWY", "AC", "LOC", "REC", "DRV", "TRL", "TRS", "OTH", "UNK"),
  Resistance = c(1000, 1000, 750, 750, 750, 500, 500, 500, 500),
  Buffer = c(250, 250, 50, 50, 50, 25, 25, 25, 25),
  SourceWt = c(0, 0, 0, 0, 0, 0.5, 0.5, 0.5, 0.5)
)

roads_other <- roads %>%
  filter(LINE_TYPE %in% road_lookup$LINE_TYPE) %>%
  left_join(road_lookup, by = "LINE_TYPE")

# Load in railways from a separate file and assign it a resistance and sourcewt
railways <- st_read(file.path(inputs_dir, "Railways.shp")) %>%
  mutate(Resistance = 750, Buffer = 50, SourceWt = 0)

# Combine and buffer all of the roads together; buffer the roads based on their
#assigned buffer value
roads_all <- bind_rows(roads_res_high, roads_res_low, roads_other, railways)
roads_buffered <- roads_all %>%
  rowwise() %>% # apply buffering to one row at a time based on buffer column value
  mutate(geometry = st_buffer(geometry, dist = Buffer)) %>%
  ungroup() %>%
  st_as_sf()

# Rasterize resistance and source weight rasters and save outputs
roads_resistance_raster <- fasterize(roads_buffered, base_raster, field = "Resistance")
roads_sourcewt_raster <- fasterize(roads_buffered, base_raster, field = "SourceWt")
writeRaster(
  roads_resistance_raster,
  file.path(inputs_raster_dir, "resistance_consolidated_roads_.tif"),
  overwrite = TRUE
)
writeRaster(
  roads_sourcewt_raster,
  file.path(inputs_raster_dir, "sourcewt_consolidated_roads.tif"),
  overwrite = TRUE
)

# --- WHA, MDWR, Moose Wetlands, and Wetland Layers Rasterization ---

# Load in all of the protected feature polygon layers
wha <- st_read(file.path(inputs_dir, "WHAs.shp"))
mdwr <- st_read(file.path(inputs_dir, "MDWR.shp"))
moose_wet <- st_read(file.path(inputs_dir, "Moose_wetlands.shp"))
wetlands <- st_read(file.path(inputs_dir, "Wetlands.shp"))

# Assign resistance and source weight values directly
wha_vals <- wha %>%
  mutate(Resistance = 250, SourceWt = 0.75)

mdwr_vals <- mdwr %>%
  mutate(Resistance = 250, SourceWt = 0.75)

moose_wet_vals <- moose_wet %>%
  mutate(Resistance = 250, SourceWt = 0.75)

wetlands_vals <- wetlands %>%
  mutate(Resistance = 250, SourceWt = 0.75)

# Combine all layers together for easy handling for composite raster creation
combined_features <- bind_rows(wha_vals, mdwr_vals, moose_wet_vals, wetlands_vals)

# Rasterize and save outputs
r_res <- fasterize(combined_features, base_raster, field = "Resistance")
r_sw <- fasterize(combined_features, base_raster, field = "SourceWt")
writeRaster(r_res, file.path(inputs_raster_dir, "resistance_secondaryPAs.tif"), overwrite = TRUE)
writeRaster(r_sw, file.path(inputs_raster_dir, "sourcewt_secondaryPAs.tif"), overwrite = TRUE)

# --- OGMA Rasterization ---

# OGMAs are given a resistance and source weight of 1 due to their optimal
# biodiversity value; create a Resistance and SourceWt Column for the layers
OGMAs <- st_read(file.path(inputs_dir, "OGMAcurrent.shp")) %>%
  mutate(Resistance = 1, SourceWt = 1)
res_ogma <- fasterize(OGMAs, base_raster, field = "Resistance")
sw_ogma <- fasterize(OGMAs, base_raster, field = "SourceWt")
writeRaster(res_ogma, file.path(inputs_raster_dir, "resistance_OGMAs.tif"), overwrite = TRUE)
writeRaster(sw_ogma, file.path(inputs_raster_dir, "sourcewt_OGMAs.tif"), overwrite = TRUE)

# --- BC Parks/Ecological Reserves Rasterization ---

# BC Parks/Ecological Reserves are given a resistance and source weight of 1
# due to their optimal biodiversity value; create a Resistance and SourceWt
# Column for the layers
Protected <- st_read(file.path(inputs_dir, "BCParks.shp")) %>%
  mutate(Resistance = 1, SourceWt = 1)
res_prot <- fasterize(Protected, base_raster, field = "Resistance")
sw_prot <- fasterize(Protected, base_raster, field = "SourceWt")
writeRaster(res_prot, file.path(inputs_raster_dir, "resistance_BCParks.tif"), overwrite = TRUE)
writeRaster(sw_prot, file.path(inputs_raster_dir, "sourcewt_BCParks.tif"), overwrite = TRUE)

# --- Water features (rivers, lakes, and streams) Rasterization ---

# Lakes are given a max resistance and min source weight; create a Resistance
# and SourceWt Column for the layers
lakes <- st_read(file.path(inputs_dir, "Lakes.shp")) %>%
  mutate(Resistance = 1000, SourceWt = 0)
res_lakes <- fasterize(lakes, base_raster, field = "Resistance")
sw_lakes <- fasterize(lakes, base_raster, field = "SourceWt")
writeRaster(res_lakes, file.path(inputs_raster_dir, "resistance_lakes.tif"), overwrite = TRUE)
writeRaster(sw_lakes, file.path(inputs_raster_dir, "sourcewt_lakes.tif"), overwrite = TRUE)

# Rivers are given a max resistance and min source weight;  create a Resistance
# and SourceWt Column for the layers
rivers <- st_read(file.path(inputs_dir, "Rivers.shp")) %>%
  mutate(Resistance = 1000, SourceWt = 0)
res_rivers <- fasterize(rivers, base_raster, field = "Resistance")
sw_rivers <- fasterize(rivers, base_raster, field = "SourceWt")
writeRaster(res_rivers, file.path(inputs_raster_dir, "resistance_rivers.tif"), overwrite = TRUE)
writeRaster(sw_rivers, file.path(inputs_raster_dir, "sourcewt_rivers.tif"), overwrite = TRUE)

# Streams are given different resistances and source weights based on their
# stream order, buffering has been exaggerated for higher order streams so it
# will be present in the 30-m resolution composite raster
streamsorder <- st_read(file.path(inputs_dir, "streamsorder.shp"))

# Filter out stream order 1 - too small of a width to impact forest canopy
streams_filtered <- streamsorder %>% filter(STRMRDR != 1)

# Assign resistance, buffer values, and source weight
streams_with_values <- streams_filtered %>%
  mutate(
    buffer_dist = case_when(
      STRMRDR %in% c(2, 3, 4, 5, 6) ~ 15,
      STRMRDR == 7 ~ 75,
      STRMRDR == 8 ~ 130,
      STRMRDR == 9 ~ 300,
      TRUE ~ NA_real_
    ),
    Resistance = case_when(
      STRMRDR %in% c(5, 6, 7, 8, 9) ~ 1000,
      STRMRDR == 4 ~ 750,
      STRMRDR == 3 ~ 500,
      STRMRDR == 2 ~ 250,
      TRUE ~ NA_real_
    ),
    SourceWt = 0
  ) %>%
  filter(!is.na(buffer_dist))

# Apply buffer by buffer_dist values
buffered_streams <- st_buffer(streams_with_values, dist = streams_with_values$buffer_dist)

# Rasterize and save stream order resistance and source weight rasters
res_streamnetwork <- fasterize(buffered_streams, base_raster, field = "Resistance")
sw_streamnetwork <- fasterize(buffered_streams, base_raster, field = "SourceWt")
writeRaster(
  res_streamnetwork,
  file.path(inputs_raster_dir, "resistance_streamnetwork.tif"),
  overwrite = TRUE
)
writeRaster(
  sw_streamnetwork,
  file.path(inputs_raster_dir, "sourcewt_streamnetwork.tif"),
  overwrite = TRUE
)
