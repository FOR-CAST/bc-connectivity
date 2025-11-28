# Script: this script initiates the start of the analysis by pulling together data sets from the BC Data Catalogue; we check data structure to inform treatment for resistance ranking; we check to confirm data have a consistent projection, geographic datum and units.

# Load packages

library(sf)
install.packages("remotes")
remotes::install_github("bcgov/bcmaps")
library(bcmaps)
library(bcdata)

# Set working directory
setwd("Csfsetwd(C:/Users/theckfor/OneDrive - Government of BC/Documents - External_ Landscape Integrity/Content/Phase 3/Case Study-- Omniscape QUesnel TSA/")

# All spatial data should have the projection: "EPSG:3005" or Projected CRS: NAD83 / BC Albers; and units should be meters

# Grab Quesnel TSA/NRD as our study area
Quesnel_NRD <- nr_districts() %>% filter(DISTRICT_NAME == "Quesnel Natural Resource District")
str(Quesnel_NRD) # Feature Length and Area in M and square M and "EPSG:3005"
# Write data 
st_write(Quesnel_NRD, "/Data/BC Catalogue Data/Quesnel_NRD.shp")

# Grab OGMA's
OGMA <- bcdc_query_geodata("1b30f3bd-0ad0-4128-916b-66c6dd91dea4") %>% collect() %>% st_intersection(Quesnel_NRD) %>% collect()
str(OGMA) # Feature length and Area in M 
st_crs(OGMA) # ID["EPSG",3005]]

# Grab  BC Parks, Ecological Reserves and Protected Areas
PA <- bcdc_query_geodata("1130248f-f1a3-4956-8b2e-38d29d3e4af7") %>% collect() %>% st_intersection(Quesnel_NRD) %>% collect()
str(PA) # Feature length and Area in M 
st_crs(PA) #ID["EPSG",3005]]

# Grab Conservation Lands
ConsLANDS <- bcdc_query_geodata("68327529-c0d5-4fcb-b84e-f8d98a7f8612")  %>% collect() %>% st_intersection(Quesnel_NRD) %>% collect()
# Only 1 polygon returned, seeing more on the website map: https://www2.gov.bc.ca/gov/content/environment/plants-animals-ecosystems/wildlife/wildlife-habitats/conservation-lands/find-conservation-lands
str(ConsLANDS) # Feature length and Area in M 
st_crs(ConsLANDS) # ID["EPSG",3005]]







plot(st_geometry(Quesnel_NRD))
plot(st_geometry(ConsLANDS), add=T)






### Code below is for NN Analysis

OGMA <- st_read("Input Data/OGMAcurrent.shp")

plot(OGMA)

B <- st_distance(OGMA)
View(B)
avg_distances <- rowMeans(B)

c <- mean(avg_distances)

d <- c/1000
hist(B)

H <- diag(B)
View(H)

u <- upper.tri(B)
View(u)
