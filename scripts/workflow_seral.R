DiagrammeR::grViz(
  "digraph {
    graph [layout = dot, rankdir = TB]

    # define the global styles of the nodes
    node [style = filled, fillcolor = linen]

    subgraph cluster_workflow {
      label = 'Seral Stage Workflow'
      bgcolor = azure

      VRI [label = 'VRI', shape = cylinder, fillcolor = goldenrod1]
      insect [label = 'insect', shape = cylinder, fillcolor = linen]
      fire [label = 'fire', shape = cylinder, fillcolor = linen]
      cut [label = 'cut', shape = cylinder, fillcolor = linen]
      for_dist [label = 'Forest\nDisturbance', shape = cylinder, fillcolor = goldenrod1]
      hum_dist [label = 'Human\nDisturbance', shape = cylinder, fillcolor = linen]
      HFLB [label = 'Historically\nForested\nLand Base', shape = cylinder, fillcolor = linen]
      HFLB_age [label = 'HFLB Age', shape = cds, fillcolor = cadetblue2]
      NDT [label = 'Natural\nDisturbance\nType', shape = cylinder, fillcolor = linen]
      BEC [label = 'BEC', shape = cylinder, fillcolor = linen]
      seral_tbl [label = 'Seral\nLookup\nTable', shape = tab, fillcolor = linen]
      seral_ply [label = 'Seral\nLookup\nTable\nPolygons', shape = cylinder, fillcolor = linen]
      seral [label = 'Seral Stage', shape = cds, fillcolor = cadetblue2]
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
    data_support_ply -> VRI [style = invis]
    {VRI -> for_dist -> HFLB_age -> seral}
    {rank=same insect, fire, cut} -> for_dist
    {rank=same hum_dist, HFLB} -> HFLB_age
    {rank=same NDT, BEC, seral_tbl, seral_ply} -> seral

    }"
) |>
  DiagrammeRsvg::export_svg() |>
  charToRaw() |>
  rsvg::rsvg_png("workflow_seral.png")
