# BEC-NDT zones map for the Quesnel NRD Study Area

library(sf)
library(dplyr)
library(tibble)

setwd("H:/Phase3/DownloadedData")

# Load BEC with NDT and Zone
bec_ndt <- st_read("BEC.shp") %>%
  st_make_valid() %>%
  select(NATURAL_DI, ZONE) %>%
  mutate(NDT_BEC = paste0(NATURAL_DI, "-", ZONE),
         BEC_ZONE = ZONE)  # Save BEC zone separately for dissolve

# Load VRI and filter attributes
vri <- st_read("VRI_selected.shp") %>%
  st_make_valid() %>%
  select(PROJ_AGE_1, SPECIES_CD)

# Spatial join to attach BEC/NDT
vri_joined <- st_join(vri, bec_ndt, left = FALSE) %>%
  mutate(
    base_NDT_BEC = paste0(NATURAL_DI, "-", ZONE),
    NDT_BEC = case_when(
      base_NDT_BEC == "NDT4-IDF" & grepl("^FD", SPECIES_CD) ~ "NDT4-IDF-FD",
      base_NDT_BEC == "NDT4-IDF" & grepl("^PL", SPECIES_CD) ~ "NDT4-IDF-PL",
      TRUE ~ base_NDT_BEC
    )
  ) %>%
  st_make_valid()

ndt_bec_dissolved <- vri_joined %>%
  select(NDT_BEC, geometry) %>%
  group_by(NDT_BEC) %>%
  summarise(geometry = st_union(geometry), .groups = "drop")

# Export to shapefile for Arcmap
st_write(ndt_bec_dissolved, "NDT_BEC_Dissolved_Quesnel.shp", delete_layer = TRUE)

# just the NDT map

library(sf)
library(dplyr)
library(ggplot2)

# Load BEC layer
bec_clipped <- st_read("BEC.shp")  # Already clipped to study area

# Dissolve by NDT type
bec_ndt_dissolved <- bec_clipped %>%
  group_by(NATURAL_DI) %>%
  summarise(geometry = st_union(geometry), .groups = "drop")

st_write(bec_ndt_dissolved, "NDT_Dissolved_Quesnel.shp", delete_layer = TRUE)
