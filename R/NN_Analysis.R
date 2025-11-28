library(spatialEco)
library(sf)

setwd("Csfsetwd(C:/Users/theckfor/OneDrive - Government of BC/Documents - External_ Landscape Integrity/Content/Phase 3/Case Study/Nearest Neighbour Analysis")

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
