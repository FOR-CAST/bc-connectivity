DiagrammeR::grViz(
  "digraph {
    graph [layout = dot, rankdir = TB]

    # define the global styles of the nodes
    node [shape = septagon, style = filled, fillcolor = linen]

    subgraph cluster_get_input_data {
      label = 'get_input_data'
      bgcolor = azure

      r1_seral_managed [label = 'r1_seral_managed']
      seral_managed [label = 'seral_managed']
      seral [label = 'seral']
    }
      
    subgraph cluster_create_old_and_old_mature {
      label = 'create_old_and_old_mature'
      bgcolor = azure
      
      x1_mature_old_from_seral [label = 'x1_mature_old_from_seral']
      x2_dissolved_interior_category [label = 'x2_dissolved_interior_category']
      x3_matold_eliminated_lessthan_1ha [label = 'x3_matold_eliminated_lessthan_1ha']
      r1_mature_old_1ha_eliminated [label = 'r1_mature_old_1ha_eliminated']

      x1_old_from_seral [label = 'x1_old_from_seral']
      x2_dissolved_interior_category_old [label = 'x2_dissolved_interior_category_old']
      x3_old_eliminated_lessthan_1ha [label = 'x3_old_eliminated_lessthan_1ha']
      r1_old_1ha_eliminated [label = 'r1_old_1ha_eliminated']
    }
    
     subgraph cluster_create_buffers_to_delete {
      label = 'create_buffers_to_delete'
      bgcolor = azure

      x1_200m_to_buffer [label = 'x1_200m_to_buffer']
      x1_100m_to_buffer [label = 'x1_100m_to_buffer']
      x1_50m_to_buffer [label = 'x1_50m_to_buffer']
      x1_25m_to_buffer [label = 'x1_25m_to_buffer']

      x2_200m_to_buffer_dis [label = 'x2_200m_to_buffer_dis']
      x2_100m_to_buffer_dis [label = 'x2_100m_to_buffer_dis']
      x2_50m_to_buffer_dis [label = 'x2_50m_to_buffer_dis']
      x2_25m_to_buffer_dis [label = 'x2_25m_to_buffer_dis']

      x3_200m_to_erase [label = 'x3_200m_to_erase']
      x3_100m_to_erase [label = 'x3_100m_to_erase']
      x3_50m_to_erase [label = 'x3_50m_to_erase']
      x3_25m_to_erase [label = 'x3_25m_to_erase']
    }

    subgraph cluster_create_interior_forest {
      label = 'create_interior_forest'
      bgcolor = azure

      x1_old_200_erased [label = 'x1_old_200_erased']
      x2_old_100_erased [label = 'x2_old_100_erased']
      x4_old_50_erased [label = 'x4_old_50_erased']
      x5_old_25_erased [label = 'x5_old_25_erased']
      r1_old_interior [label = 'r1_old_interior']

      x1_matold_200_erased [label = 'x1_matold_200_erased']
      x2_matold_100_erased [label = 'x2_matold_100_erased']
      x4_matold_50_erased [label = 'x4_matold_50_erased']
      x5_matold_25_erased [label = 'x5_matold_25_erased']
      r1_matold_interior [label = 'r1_matold_interior']
    }
    
    subgraph cluster_create_patch_size_data {
      label = 'create_patch_size_data'
      bgcolor = azure

      x1_dissolved_on_seral_stage [label = 'x1_dissolved_on_seral_stage']
    }
    
    subgraph cluster_union_into_final_resultant {
      label = 'union_into_final_resultant'
      bgcolor = azure

      r1_patch [label = 'r1_patch']
      r1_final_resultant_union [label = 'r1_final_resultant_union']
    }
    
    # edge definitions with the node IDs
    r1_seral_managed -> seral_managed -> seral
    seral -> {x1_mature_old_from_seral, x1_old_from_seral}
    x1_mature_old_from_seral -> x2_dissolved_interior_category -> x3_matold_eliminated_lessthan_1ha -> r1_mature_old_1ha_eliminated
    x1_old_from_seral -> x2_dissolved_interior_category_old -> x3_old_eliminated_lessthan_1ha -> r1_old_1ha_eliminated
    
    seral -> {x1_200m_to_buffer, x1_100m_to_buffer, x1_50m_to_buffer, x1_25m_to_buffer}
    x1_200m_to_buffer -> x2_200m_to_buffer_dis -> x3_200m_to_erase
    x1_100m_to_buffer -> x2_100m_to_buffer_dis -> x3_100m_to_erase
    x1_50m_to_buffer -> x2_50m_to_buffer_dis -> x3_50m_to_erase
    x1_25m_to_buffer -> x2_25m_to_buffer_dis -> x3_25m_to_erase
    
    {r1_old_1ha_eliminated, x3_200m_to_erase} -> x1_old_200_erased
    {x1_old_200_erased, x3_100m_to_erase} -> x2_old_100_erased
    {x2_old_100_erased, x3_50m_to_erase} -> x4_old_50_erased
    {x4_old_50_erased, x3_25m_to_erase} -> x5_old_25_erased
    x5_old_25_erased -> r1_old_interior

    {r1_mature_old_1ha_eliminated, x3_200m_to_erase} -> x1_matold_200_erased
    {x1_matold_200_erased, x3_100m_to_erase} -> x2_matold_100_erased
    {x2_matold_100_erased, x3_50m_to_erase} -> x4_matold_50_erased
    {x4_matold_50_erased, x3_25m_to_erase} -> x5_matold_25_erased
    x5_matold_25_erased -> r1_matold_interior

    seral -> x1_dissolved_on_seral_stage

    {r1_matold_interior, r1_old_interior, x1_dissolved_on_seral_stage} -> r1_patch
    {r1_patch, seral_managed} -> r1_final_resultant_union
    }"
) |>
  DiagrammeRsvg::export_svg() |>
  charToRaw() |>
  rsvg::rsvg_png("workflow_patches.png")
