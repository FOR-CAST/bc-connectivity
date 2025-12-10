if (FALSE) {
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
  withr::with_dir(get_path("omniscape"), {
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
}

write_omniscape_config <- function(run_name, window_size) {
  block_size <- 101
  pixel_size <- 30
  radius <- 500 ## use nearest neighbour analysis to inform moving window size

  config_file <- file.path(get_path("omniscape"), glue::glue("config_{run_name}.ini"))
  julia_script <- file.path(get_path("omniscape"), glue::glue("script_{run_name}.jl"))
  output_dir <- file.path(get_path("outputs"), run_name)

  ## Omniscape refuses to accidentally overwrite existing directory,
  ## so need to preemptively cleanup
  if (dir.exists(output_dir)) {
    unlink(output_dir, recursive = TRUE)
  }

  ## Build ini file for Omniscape
  cat(
    c(
      glue::glue("[Input files]"),
      glue::glue("resistance_file = {input_files[['resistance_fordist']]}"),
      glue::glue("source_file = {input_files[['sourcewt_fordist']]}"),
      glue::glue("[Options]"),
      glue::glue("block_size = {block_size}"),
      glue::glue("radius = {radius}"),
      glue::glue("buffer = 0"),
      glue::glue("source_threshold = 0"),
      glue::glue("project_name = {output_dir}"),
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
    file = config_file
  )

  ## create Julia script to run Omniscape
  cat(
    c(
      glue::glue("using Omniscape"),
      glue::glue("run_omniscape('{config_file}')")
    ),
    sep = "\n",
    file = julia_script
  )
}

if (FALSE) {
  ## launch Julia
  withr::with_dir(get_path("omniscape"), {
    system2(
      fs::path_expand("~/.juliaup/bin/julia"),
      c(
        glue::glue("+{julia_version}"),
        glue::glue("-t {julia_threads}"),
        glue::glue("{julia_script}")
      ),
      # env = c(JULIA_NUM_THREADS = julia_threads),
      stdout = TRUE
    )
  })
}
