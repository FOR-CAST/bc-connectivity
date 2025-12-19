DiagrammeR::grViz(
  "digraph {
    graph [layout = dot, rankdir = LR]

    # define the global styles of the nodes
    node [style = filled, fillcolor = linen]

    subgraph cluster_forest_disturbance {
      label = 'Forest Disturbance'
      bgcolor = olivedrab3

      VRI [label = 'VRI', shape = cylinder, fillcolor = goldenrod1]
      insect [label = 'insect', shape = cylinder, fillcolor = linen]
      fire [label = 'fire', shape = cylinder, fillcolor = linen]
      cut [label = 'cut', shape = cylinder, fillcolor = linen]
      for_dist [label = 'Forest\nDisturbance', shape = cylinder, fillcolor = goldenrod1]
    }
      
    subgraph cluster_forest_age {
      label = 'Forest Age'
      bgcolor = lavender
      
      hum_dist [label = 'Human\nDisturbance', shape = cylinder, style = dashed, fillcolor = linen]
      HFLB [label = 'Historically\nForested\nLand Base', shape = cylinder, style = dashed, fillcolor = linen]
      HFLB_age [label = 'HFLB Age', shape = cds, style = dashed, fillcolor = cadetblue2]
      SIFA [label = 'SIFA', shape = cds, fillcolor = cadetblue2]
    }
    
     subgraph cluster_seral_stage {
      label = 'Seral Stage'
      bgcolor = azure

      NDT [label = 'NDT', shape = cylinder, fillcolor = linen]
      BEC [label = 'BEC', shape = cylinder, fillcolor = linen]
      seral_tbl [label = 'Seral\nLookup\nTable', shape = tab, fillcolor = linen]
      seral_ply [label = 'Seral\nLookup\nTable\nPolygons', shape = cylinder, fillcolor = linen]
      seral [label = 'SERAL_STAGE', shape = cds, fillcolor = cadetblue2]
    }

    subgraph cluster_legend {
      label = 'Legend'

      data_primary [label = 'Primary\nspatial\ndataset', shape = cylinder, fillcolor = goldenrod1]
      data_support_ply [label = 'Supporting\nspatial\ndataset', shape = cylinder, fillcolor = linen]
      data_support_tbl [label = 'Supporting\ndataset', shape = tab, fillcolor = linen]
      data_fields [label = 'Data field', shape = cds, fillcolor = cadetblue2]
    }

    # edge definitions with the node IDs
    data_support_ply -> data_support_tbl [style = invis]
    data_support_ply -> seral [constraint = false, style = invis]
    VRI -> for_dist
    for_dist -> SIFA -> seral
    for_dist -> HFLB_age -> seral [constraint = false, style = dashed]
    {insect, fire, cut} -> for_dist
    {hum_dist, HFLB} -> HFLB_age [style = dashed]
    {NDT, BEC, seral_tbl, seral_ply} -> seral
    cut -> NDT [constraint = false, style = invis]

    }"
) |>
  DiagrammeRsvg::export_svg() |>
  charToRaw() |>
  rsvg::rsvg_png("workflow_seral.png")
