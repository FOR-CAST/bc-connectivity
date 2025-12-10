DiagrammeR::grViz(
  "digraph {

graph [layout = dot, rankdir = LR]

# define the global styles of the nodes. We can override these in box if we wish
node [shape = rectangle, style = filled, fillcolor = linen]

subgraph cluster_data {
  label = 'Download data'
  bgcolor = azure

  data_prtct [label = 'Protected Area Features', shape = cylinder]
  data_water [label = 'Water Features', shape = cylinder]
  data_anthr [label = 'Anthropogenic Features', shape = cylinder]
  data_envir [label = 'Environmental Features', shape = cylinder]
  data_other [label = 'Other Features', shape = cylinder]
}

subgraph cluster_resistance {
  label = 'Connectivity scores'
  bgcolor = sandybrown

  resist_value [label = 'Assign resistance values', shape = tab]
  resist_weigh [label = 'Assign source weights', shape = tab]
}

subgraph cluster_interpatch {
  label = 'Interpatch assessment'
  bgcolor = palegreen

  patches [label = 'Define patches\n(Seral = Old)', shape = tab]
  nn_patches [label = 'Nearest neighbour distances', shape = tab]
}

subgraph cluster_rasterize {
  label = 'Create rasters'
  bgcolor = lavender

  raster_create [label = 'Rasterize polygons', shape = tab]
  raster_composite [label = 'Composite rasters', shape = tab]
}

subgraph cluster_connectivity {
  label = 'Omniscape runs'
  bgcolor = steelblue1

  omniscape [label = 'Connectivity maps', shape = tab]
}

# edge definitions with the node IDs
{data_prtct, data_water, data_anthr, data_envir, data_other} -> {resist_value, resist_weigh}
{resist_value, resist_weigh} -> raster_create
data_envir -> patches
raster_create -> raster_composite
patches -> nn_patches
{nn_patches, raster_composite} -> omniscape [style = dashed]

}"
) |>
  DiagrammeRsvg::export_svg() |>
  charToRaw() |>
  rsvg::rsvg_png("workflow.png")
