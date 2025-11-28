DiagrammeR::grViz(
  "digraph {

graph [layout = dot, rankdir = LR]

# define the global styles of the nodes. We can override these in box if we wish
node [shape = rectangle, style = filled, fillcolor = linen]

subgraph cluster_data {
  label = 'Data preparation'
  bgcolor = azure

  data_prtct [label = 'Protected Area Features', shape = cylinder]
  data_water [label = 'Water Features', shape = cylinder]
  data_anthr [label = 'Anthropogenic Features', shape = cylinder]
  data_envir [label = 'Environmental Features', shape = cylinder]
  data_other [label = 'Other Features', shape = cylinder]
}

subgraph cluster_resistance {
  label = 'Landscape resistance scores'
  bgcolor = lightsalmon

  resist_value [label = 'Assign values', shape = tab]
  resist_weigh [label = 'Assign weights', shape = tab]
}

subgraph cluster_moving_window {
  label = 'Moving window size'
  bgcolor = sandybrown

  nn_ogma [label = 'Nearest Neighbour OGMAs', shape = tab]
  nn_parks [label = 'Nearest Neighbour OGMAs + Parks', shape = tab]
  nn_wha [label = 'Nearest Neighbour OGMAs + Parks + WHAs', shape = tab]
}

subgraph cluster_rasterize {
  label = 'Rasterize'
  bgcolor = lavender

  raster_create [label = 'Rasterize polygons', shape = tab]
  raster_composite [label = 'Composite rasters', shape = tab]
}

subgraph cluster_connectivity {
  label = 'Omniscape runs'
  bgcolor = sandybrown

  omniscape [label = 'Connectivity maps', shape = tab]
}

# edge definitions with the node IDs
{data_prtct, data_water, data_anthr, data_envir, data_other} -> raster_create
{data_prtct, data_water, data_anthr, data_envir, data_other} -> {nn_ogma, nn_parks, nn_wha}
raster_create -> {resist_value, resist_weigh}
{resist_value, resist_weigh} -> raster_composite
{nn_ogma, nn_parks, nn_wha} -> omniscape [style = dashed]
raster_composite -> omniscape

}"
) |>
  DiagrammeRsvg::export_svg() |>
  charToRaw() |>
  rsvg::rsvg_png("workflow.png")
