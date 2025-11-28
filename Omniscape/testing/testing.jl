using Pkg; Pkg.add(["Omniscape", "Rasters", "Plots"])
using Omniscape, Rasters, Plots

url_base = "https://raw.githubusercontent.com/Circuitscape/datasets/main/"
# Download the NLCD tile used to create the resistance surface and load it
download(string(url_base, "data/nlcd_2016_frederick_md.tif"),
         "nlcd_2016_frederick_md.tif")

# Plot the landcover data
values = [11, 21, 22, 23, 24, 31, 41, 42, 43, 52, 71, 81, 82, 90, 95]
palette = ["#476BA0", "#DDC9C9", "#D89382", "#ED0000", "#AA0000",
           "#b2b2b2", "#68AA63", "#1C6330", "#B5C98E", "#CCBA7C",
           "#E2E2C1", "#DBD83D", "#AA7028", "#BAD8EA", "#70A3BA"]

plot(Raster("nlcd_2016_frederick_md.tif"),
     title = "Land Cover Type", xlabel = "Easting", ylabel = "Northing",
     seriescolor = cgrad(palette, (values .- 12) ./ 84, categorical = true),
     size = (700, 640))

land_cover, wkt, transform = Omniscape.read_raster("nlcd_2016_frederick_md.tif", Float64)

# Create the reclassification table used to translate land cover into resistance
reclass_table = [
    11	100; # Water
    21	500; # Developed, open space
    22	1000; # Developed, low intensity
    23	missing; # Developed, medium intensity
    24	missing; # Developed, high intensity
    31	100; # Barren land
    41	1; # Deciduous forest
    42	1; # Evergreen forest
    43	1; # Mixed forest
    52	20; # Shrub/scrub
    71	30; # Grassland/herbaceous
    81	200; # Pasture/hay
    82	300; # Cultivated crops
    90	20; # Woody wetlands
    95	30; # Emergent herbaceous wetlands
]

# Specify the configuration options
proj_name = "md_nlcd_omniscape_output"
config = Dict{String, String}(
    "radius" => "100",
    "block_size" => "21",
    "project_name" => proj_name,
    "source_from_resistance" => "true",
    "r_cutoff" => "1", # Only forest pixels should be sources
    "reclassify_resistance" => "true",
    "calc_normalized_current" => "true",
    "calc_flow_potential" => "true"
)

if isdir(proj_name)
    rm(proj_name, recursive = true)
end

currmap, flow_pot, norm_current = run_omniscape(config,
                                                land_cover,
                                                reclass_table = reclass_table,
                                                wkt = wkt,
                                                geotransform = transform,
                                                write_outputs = true)

current = Raster("md_nlcd_omniscape_output/cum_currmap.tif")
plot(current,
     title = "Cumulative Current Flow", xlabel = "Easting", ylabel = "Northing",
     seriescolor = cgrad(:inferno, [0, 0.005, 0.03, 0.06, 0.09, 0.14]),
     size = (600, 550))

fp = Raster("md_nlcd_omniscape_output/flow_potential.tif")
plot(fp,
     title = "Flow Potential", xlabel = "Easting", ylabel = "Northing",
     seriescolor = cgrad(:inferno, [0, 0.005, 0.03, 0.06, 0.09, 0.14]),
     size = (700, 640))

normalized_current = Raster("md_nlcd_omniscape_output/normalized_cum_currmap.tif")
plot(normalized_current,
     title = "Normalized Current Flow", xlabel = "Easting", ylabel = "Northing",
     seriescolor = cgrad(:inferno, [0, 0.005, 0.03, 0.06, 0.09, 0.14]),
     size = (700, 640))