## Synthetic seral-stage layer used to pin down patch construction.
##
## Concentric squares, so every interior-forest area is known in closed form:
##
##   Old          [-600,  600]^2   (1200 m across)
##   Mature ring  [-800,  800]^2   minus Old
##   Mid ring     [-1000, 1000]^2  minus Mature
##   Early >=20   [-1200, 1200]^2  minus Mid
##   Early <20    [-1500, 1500]^2  minus Early >=20
##
## plus one *detached* square of unclassified (NA seral) land, far enough away that none of the
## edge-influence buffers reach it. That square is what makes the fixture sensitive to the
## `INTERIOR_CATEGORY` filter: without it, unclassified land survives the erase and is relabelled
## as interior forest.
##
## Expected interior forest, from the buffers in patches_create_buffers_to_delete()
## (Early <20 -> 200 m, Early >=20 -> 101 m, Mid -> 52 m, Mature -> 25 m):
##
##   old-only    : Old eroded by the *Mature* 25 m buffer  -> (1200 - 2*25)^2 = 1150^2 = 132.25 ha
##   mature+old  : (Old + Mature) eroded by the *Mid* 52 m buffer -> (1600 - 2*52)^2 = 1496^2
##                                                                = 223.8016 ha
##
## The 101 m and 200 m buffers stop at 899 m and 1000 m from centre, so neither reaches either core.

CRS_FIXTURE <- "EPSG:3005" ## BC Albers: projected, metres

sq <- function(half, cx = 0, cy = 0) {
  sf::st_polygon(list(rbind(
    c(cx - half, cy - half),
    c(cx + half, cy - half),
    c(cx + half, cy + half),
    c(cx - half, cy + half),
    c(cx - half, cy - half)
  )))
}

ring <- function(outer, inner) sf::st_difference(sq(outer), sq(inner))

seral_fixture <- function(na_square = TRUE) {
  geoms <- list(
    sq(600), ## Old
    ring(800, 600), ## Mature
    ring(1000, 800), ## Mid
    ring(1200, 1000), ## Early, >= 20 yr
    ring(1500, 1200) ## Early, < 20 yr
  )
  seral <- c("Old", "Mature", "Mid", "Early", "Early")
  under20 <- c(NA, NA, NA, NA, "under_20")

  if (isTRUE(na_square)) {
    ## detached, unclassified: 500 m square centred at (5000, 5000), 25 ha
    geoms <- c(geoms, list(sq(250, cx = 5000, cy = 5000)))
    seral <- c(seral, NA_character_)
    under20 <- c(under20, NA_character_)
  }

  sf::st_sf(
    Seral = seral,
    early_less_20yrs = under20,
    geom = sf::st_sfc(geoms, crs = CRS_FIXTURE)
  ) |>
    sf::st_set_agr("constant")
}

## area in hectares, as a bare numeric
area_ha <- function(x) {
  if (inherits(x, "SpatVector")) {
    sum(terra::expanse(x, unit = "ha", transform = FALSE))
  } else {
    sum(as.numeric(sf::st_area(x))) / 1e4
  }
}
