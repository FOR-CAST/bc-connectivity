# Composite Resistance Raster Creation for required Omniscape inputs

# --- Load in libraries ---

library(raster)
library(dplyr)

setwd("C:/Users/CWILTSE/OneDrive - Government of BC/External_ Landscape Integrity - Biodiversity Emphasis")

# Load resistance rasters
res_forest    <- raster("resistance_forest_disturbance.tif")
res_secondaryPAs   <- raster("resistance_secondaryPAs.tif")
res_BCParks <- raster("resistance_BCParks.tif")
res_ogma      <- raster("resistance_OGMAs.tif")
res_roads     <- raster("resistance_consolidated_roads_.tif")
res_streams   <- raster("resistance_streamnetwork.tif")
res_rivers    <- raster("resistance_rivers.tif")
res_lakes     <- raster("resistance_lakes.tif")

# Composite resistance stacking with all created feature rasters
composite_resistance <- overlay(
  res_forest, res_secondaryPAs, res_BCParks, res_ogma,
  res_roads, res_streams, res_rivers, res_lakes,
  fun = function(forest, secondaryPAs, bcparks, ogma, roads, streams, rivers, lakes) {
    
    # Add in function where old forest will raise the resistance of secondary PAs
    secondaryPAs_mod <- ifelse(!is.na(forest) & !is.na(secondaryPAs), pmin(forest, secondaryPAs), coalesce(secondaryPAs, forest))
    
    # Add in function where OGMAs override all
    base_stack <- coalesce(ogma, bcparks, secondaryPAs_mod)
    
    # Add in function where roads can only raise resistance, not lower it
    raised_roads   <- ifelse(!is.na(roads),   pmax(base_stack, roads,   na.rm = TRUE), base_stack)
    raised_streams <- ifelse(!is.na(streams), pmax(raised_roads, streams, na.rm = TRUE), raised_roads)
    raised_rivers  <- ifelse(!is.na(rivers),  pmax(raised_streams, rivers, na.rm = TRUE), raised_streams)
    raised_lakes   <- ifelse(!is.na(lakes),   pmax(raised_rivers, lakes,  na.rm = TRUE), raised_rivers)
    
    return(raised_lakes)
  }
)

# A very small number of pixels (81) show up as 0 which can cause problems with the
# omniscape run, so reclassify as 1 and classify N/A as 1000
composite_resistance[composite_resistance == 0] <- 1
composite_resistance[is.na(composite_resistance)] <- 1000

# write composite resistance raster for Omniscape run
writeRaster(composite_resistance, "composite_resistance_raster.tif", overwrite = TRUE)

# --- Composite Source Weight Raster Creation ---

# Load source weight rasters
sw_forest    <- raster("sourcewt_forest_disturbance.tif")
sw_secondaryPAs   <- raster("sourcewt_secondaryPAs.tif")
sw_BCParks <- raster("sourcewt_BCParks.tif")
sw_ogma      <- raster("sourcewt_OGMAs.tif")
sw_roads     <- raster("sourcewt_consolidated_roads.tif")
sw_streams   <- raster("sourcewt_streamnetwork.tif")
sw_rivers    <- raster("sourcewt_rivers.tif")
sw_lakes     <- raster("sourcewt_lakes.tif")

# Composite source weight stacking with all created feature rasters (functions are
# the inverse of the resistance raster functions)
composite_sourcewt <- overlay(
  sw_forest, sw_secondaryPAs, sw_BCParks, sw_ogma,
  sw_roads, sw_streams, sw_rivers, sw_lakes,
  fun = function(forest, secondaryPAs, bcparks, ogma, roads, streams, rivers, lakes) {
    
    # Add in function where Old Forest raises source weight of secondary PAs
    secondaryPAs_mod <- ifelse(!is.na(forest) & !is.na(secondaryPAs), pmax(forest, secondaryPAs), coalesce(secondaryPAs, forest))
    
    # Add in function where OGMA overrides all
    base_stack <- coalesce(ogma, bcparks, secondaryPAs_mod)
    
    # Add in function where roads, streams, rivers, and lakes can only lower source weight
    lowered_roads   <- ifelse(!is.na(roads),   pmin(base_stack, roads,   na.rm = TRUE), base_stack)
    lowered_streams <- ifelse(!is.na(streams), pmin(lowered_roads, streams, na.rm = TRUE), lowered_roads)
    lowered_rivers  <- ifelse(!is.na(rivers),  pmin(lowered_streams, rivers, na.rm = TRUE), lowered_streams)
    lowered_lakes   <- ifelse(!is.na(lakes),   pmin(lowered_rivers, lakes,  na.rm = TRUE), lowered_rivers)
    
    return(lowered_lakes)
  }
)

# Replace NA values with 0 to avoid errors in Omniscape run
composite_sourcewt[is.na(composite_sourcewt)] <- 0

# write composite source weight raster for Omniscape run
writeRaster(composite_sourcewt, "composite_sourcewt_raster.tif", overwrite = TRUE)
