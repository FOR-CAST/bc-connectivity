# Omniscape analysis test based on BC_ConservationConnectivity Github script

setwd("H:/Phase3/DownloadedData")

ConnDir <- "H:/Phase3/DownloadedData" # Folder where rasters and config files are located
RunDir <- "Omniscape_Outputs" # Subfolder for outputs
OmniRadius <- 500
pixSize <- 30
BlockSize <- 101

#Build ini file for Omniscape
OS_ini <- c(
  "[Input files]",
  paste("resistance_file = ", file.path(ConnDir, "composite_resistance_omniscape1.tif")),
  paste("source_file = ", file.path(ConnDir, "composite_sourcewt_omniscape1.tif")),
  "[Options]",
  paste("block_size =", BlockSize),
  paste("radius = ", OmniRadius),
  "buffer = 0",
  "source_threshold = 0",
  paste("project_name = ", file.path(ConnDir, RunDir), sep = ''),
  "calc_flow_potential = true",
  "correct_artifacts = true",
  "source_from_resistance = false",
  "r_cutoff = 0.0",
  "write_raw_currmap = true",
  "calc_normalized_current = true",
  "write_as_tif = true",
  "parallelize = true"
)

#write ini file to disk at 'configLocation'
configLocation <- file.path(ConnDir, "config.ini")
cat(OS_ini, sep = "\n", file = configLocation)

#write to jl file - that reads ini file and launches Omniscape on top of Julia
script <- c('using Omniscape', paste('run_omniscape(', configLocation, ')', sep = '"'))

#Julia is happier if jl file is in directory that Julia is launched from
cat(script, sep = "\n", file = "script.jl")

#Set up parallel processing
Sys.setenv(JULIA_NUM_THREADS = 4)
#Launch Julia
Julia_exe <- ('julia script.jl')
system(Julia_exe)
