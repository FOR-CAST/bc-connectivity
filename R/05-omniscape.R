library(JuliaCall)

julia_threads <- 64L ## estimated <8h using 8 cores; <2.5h using 64 cores (~300GB RAM).
julia_version <- "1.11.7"

## TODO: diagnose + fix failures
julia <- julia_setup(
  # installJulia = TRUE,
  rebuild = TRUE,
  version = julia_version
)

julia_install_package_if_needed("Omniscape")

## ensure Omniscape is installed
withr::with_dir(omniscape_dir, {
  system2(
    fs::path_expand("~/.juliaup/bin/julia"),
    c(
      glue::glue("+{julia_version}"),
      glue::glue("-t {julia_threads}"),
      glue::glue("-e 'import Pkg; Pkg.add(\"Omniscape\")'")
    ),
    stdout = TRUE
  )
})

# Biodiversity-focused connectivity -----------------------------------------------------------

block_size_bio <- 101
pixel_size_bio <- 30
radius_bio <- 500

config_file_bio <- file.path(omniscape_dir, "config_bio.ini")
julia_script_bio <- file.path(omniscape_dir, "script_bio.jl")
output_dir_bio <- file.path(output_dir, "bio")

## Omniscape refuses to accidentally overwrite existing directory,
## so need to preemptively cleanup
if (dir.exists(output_dir_bio)) {
  unlink(output_dir_bio, recursive = TRUE)
}

## Build ini file for Omniscape
cat(
  c(
    glue::glue("[Input files]"),
    glue::glue("resistance_file = {input_files[['resistance_fordist']]}"),
    glue::glue("source_file = {input_files[['sourcewt_fordist']]}"),
    glue::glue("[Options]"),
    glue::glue("block_size = {block_size_bio}"),
    glue::glue("radius = {radius_bio}"),
    glue::glue("buffer = 0"),
    glue::glue("source_threshold = 0"),
    glue::glue("project_name = {output_dir_bio}"),
    glue::glue("calc_flow_potential = true"),
    glue::glue("correct_artifacts = true"),
    glue::glue("source_from_resistance = false"),
    glue::glue("r_cutoff = 0.0"),
    glue::glue("write_raw_currmap = true"),
    glue::glue("calc_normalized_current = true"),
    glue::glue("write_as_tif = true"),
    glue::glue("parallelize = true")
  ),
  sep = "\n",
  file = config_file_bio
)

## create Julia script to run Omniscape
cat(
  c(
    glue::glue("using Omniscape"),
    glue::glue("run_omniscape('{config_file_bio}')")
  ),
  sep = "\n",
  file = julia_script_bio
)

## launch Julia
withr::with_dir(omniscape_dir, {
  system2(
    fs::path_expand("~/.juliaup/bin/julia"),
    c(
      glue::glue("+{julia_version}"),
      glue::glue("-t {julia_threads}"),
      glue::glue("{julia_script_bio}")
    ),
    # env = c(JULIA_NUM_THREADS = julia_threads),
    stdout = TRUE
  )
})

# All-layer connectivity ----------------------------------------------------------------------

block_size_all <- 101
pixel_size_all <- 30
radius_all <- 500

config_file_all <- file.path(omniscape_dir, "config_all.ini")
output_dir_all <- file.path(output_dir, "all") |> fs::dir_create()

## Build ini file for Omniscape
cat(
  c(
    glue::glue("[Input files]"),
    glue::glue("resistance_file = {input_files[['resistance_composite_all']]}"),
    glue::glue("source_file = {input_files[['sourcewt_composite_all']]}"),
    glue::glue("[Options]"),
    glue::glue("block_size = {block_size_all}"),
    glue::glue("radius = {radius_all}"),
    glue::glue("buffer = 0"),
    glue::glue("source_threshold = 0"),
    glue::glue("project_name = {output_dir_all}"),
    glue::glue("calc_flow_potential = true"),
    glue::glue("correct_artifacts = true"),
    glue::glue("source_from_resistance = false"),
    glue::glue("r_cutoff = 0.0"),
    glue::glue("write_raw_currmap = true"),
    glue::glue("calc_normalized_current = true"),
    glue::glue("write_as_tif = true"),
    glue::glue("parallelize = true")
  ),
  sep = "\n",
  file = config_file_all
)

## create Julia script to run Omniscape
cat(
  c(
    glue::glue("using Omniscape"),
    glue::glue("run_omniscape(\"{config_file_bio}\")")
  ),
  sep = "\n",
  file = julia_script_bio
)

## launch Julia
withr::with_dir(omniscape_dir, {
  system2(
    "julia",
    glue::glue("+{julia_version} script.jl"),
    env = c(JULIA_NUM_THREADS = julia_threads)
  )
})
