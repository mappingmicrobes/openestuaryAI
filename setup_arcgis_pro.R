#!/usr/bin/env Rscript

# One-step installer for the Open Estuary AI ArcGIS Pro toolbox.
#
# By default, files are installed in an openestuaryAI folder beneath the
# current working directory. To choose another location before running:
# Sys.setenv(OPENESTUARYAI_DIR = "C:/path/to/openestuaryAI")

REPOSITORY_RAW_URL <- "https://raw.githubusercontent.com/mappingmicrobes/openestuaryAI/main"
MODEL_URL <- paste0(
  "https://github.com/mappingmicrobes/openestuaryAI/releases/download/",
  "v0.1-test-emulator/v3_discharge_plume_model.rds"
)
MODEL_MINIMUM_BYTES <- 900 * 1024^2

requested_dir <- Sys.getenv("OPENESTUARYAI_DIR", unset = "")
if (nzchar(requested_dir)) {
  install_dir <- requested_dir
} else if (tolower(basename(getwd())) == "openestuaryai") {
  install_dir <- getwd()
} else {
  install_dir <- file.path(getwd(), "openestuaryAI")
}

dir.create(install_dir, recursive = TRUE, showWarnings = FALSE)
install_dir <- normalizePath(install_dir, winslash = "/", mustWork = TRUE)
setwd(install_dir)

message("Open Estuary AI - ArcGIS Pro setup")
message("====================================")
message("Installing into:")
message(install_dir)
message("")

old_timeout <- getOption("timeout")
options(timeout = max(3600, old_timeout))
on.exit(options(timeout = old_timeout), add = TRUE)

repos <- getOption("repos")
if (is.null(repos) || !"CRAN" %in% names(repos) || identical(unname(repos[["CRAN"]]), "@CRAN@")) {
  options(repos = c(CRAN = "https://cloud.r-project.org"))
}

download_project_file <- function(filename) {
  url <- paste0(REPOSITORY_RAW_URL, "/", filename)
  destination <- file.path(install_dir, filename)
  message("Downloading ", filename, "...")
  download.file(url, destination, mode = "wb", quiet = FALSE)
  if (!file.exists(destination) || file.info(destination)$size == 0) {
    stop("Download did not create a valid file: ", destination, call. = FALSE)
  }
  destination
}

project_files <- c(
  "OpenEstuaryAI.pyt",
  "run_v3_scenario_arcgis.R",
  "check_esri_connection.R",
  "run_v3_scenario.R",
  "README.md"
)

for (filename in project_files) {
  download_project_file(filename)
}

required_packages <- c("ranger")
recommended_packages <- c("dplyr", "ggplot2", "readr", "tibble", "sf")
packages <- c(required_packages, recommended_packages)
missing_packages <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]

if (length(missing_packages) > 0) {
  message("")
  message("Installing R packages: ", paste(missing_packages, collapse = ", "))
  install.packages(missing_packages)
}

still_missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
if ("ranger" %in% still_missing) {
  stop("Required package 'ranger' could not be installed.", call. = FALSE)
}
if (length(setdiff(still_missing, "ranger")) > 0) {
  warning(
    "Some recommended packages were not installed: ",
    paste(setdiff(still_missing, "ranger"), collapse = ", "),
    call. = FALSE
  )
}

if (!requireNamespace("arcgisbinding", quietly = TRUE)) {
  message("")
  message("Installing the optional R-ArcGIS Bridge package...")
  bridge_installed <- tryCatch(
    {
      install.packages(
        "arcgisbinding",
        repos = "https://r.esri.com",
        type = "win.binary"
      )
      requireNamespace("arcgisbinding", quietly = TRUE)
    },
    error = function(e) {
      message("Optional Bridge installation did not complete: ", conditionMessage(e))
      FALSE
    }
  )
  if (!bridge_installed) {
    message("Continuing: OpenEstuaryAI.pyt does not require arcgisbinding.")
  }
}

model_dir <- file.path(install_dir, "models")
model_path <- file.path(model_dir, "v3_discharge_plume_model.rds")
model_part_path <- paste0(model_path, ".part")
dir.create(model_dir, recursive = TRUE, showWarnings = FALSE)

model_is_complete <- file.exists(model_path) &&
  !is.na(file.info(model_path)$size) &&
  file.info(model_path)$size >= MODEL_MINIMUM_BYTES

if (!model_is_complete) {
  message("")
  message("Downloading the trained V3 model (approximately 976 MB).")
  message("This may take several minutes...")
  if (file.exists(model_part_path)) {
    unlink(model_part_path)
  }

  model_downloaded <- tryCatch(
    {
      download.file(MODEL_URL, model_part_path, mode = "wb", quiet = FALSE)
      file.exists(model_part_path) &&
        !is.na(file.info(model_part_path)$size) &&
        file.info(model_part_path)$size >= MODEL_MINIMUM_BYTES
    },
    error = function(e) {
      message("Model download failed: ", conditionMessage(e))
      FALSE
    }
  )

  if (!model_downloaded) {
    if (file.exists(model_part_path)) {
      unlink(model_part_path)
    }
    stop(
      "The model download was incomplete. Run setup_arcgis_pro.R again, ",
      "or download the release asset manually from:\n", MODEL_URL,
      call. = FALSE
    )
  }

  if (file.exists(model_path)) {
    unlink(model_path)
  }
  if (!file.rename(model_part_path, model_path)) {
    stop("Could not move the completed model into: ", model_path, call. = FALSE)
  }
} else {
  message("")
  message("Using the existing trained model:")
  message(model_path)
}

message("")
message("Running ArcGIS Pro and optional Bridge checks...")
source(file.path(install_dir, "check_esri_connection.R"), local = new.env(parent = globalenv()))

toolbox_path <- normalizePath(
  file.path(install_dir, "OpenEstuaryAI.pyt"),
  winslash = "/",
  mustWork = TRUE
)

message("")
message("SETUP COMPLETE")
message("==============")
message("In ArcGIS Pro:")
message("1. Open the Catalog pane.")
message("2. Right-click Toolboxes and choose Add Toolbox.")
message("3. Select this file:")
message(toolbox_path)
message("4. Open Open Estuary AI > Atchafalaya Salinity Emulator.")
message("5. Select a sea-level scenario, enter discharge, choose an output, and run.")
