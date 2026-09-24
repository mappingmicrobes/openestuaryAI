#!/usr/bin/env Rscript

# ArcGIS Pro readiness and optional R-ArcGIS Bridge diagnostic.
# Run from the repository with: source("check_esri_connection.R")

script_directory <- function() {
  frames <- rev(sys.frames())
  for (frame in frames) {
    if (!is.null(frame$ofile)) {
      return(dirname(normalizePath(frame$ofile, winslash = "/", mustWork = TRUE)))
    }
  }
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[[1]]), winslash = "/")))
  }
  normalizePath(getwd(), winslash = "/", mustWork = TRUE)
}

project_dir <- script_directory()
toolbox_path <- file.path(project_dir, "OpenEstuaryAI.pyt")
runner_path <- file.path(project_dir, "run_v3_scenario_arcgis.R")
model_path <- file.path(project_dir, "models", "v3_discharge_plume_model.rds")
rscript_path <- file.path(R.home("bin"), "Rscript.exe")

check_line <- function(ok, label, detail = NULL) {
  status <- if (isTRUE(ok)) "PASS" else "CHECK"
  message(sprintf("[%s] %s%s", status, label, if (!is.null(detail)) paste0(": ", detail) else ""))
}

message("Open Estuary AI - ArcGIS Pro readiness check")
message("================================================")
message("Repository/toolbox directory:")
message(project_dir)
message("")

check_line(.Platform$OS.type == "windows", "Windows operating system", Sys.info()[["sysname"]])
check_line(file.exists(rscript_path), "Rscript.exe", rscript_path)
check_line(file.exists(toolbox_path), "ArcGIS Python toolbox", toolbox_path)
check_line(file.exists(runner_path), "ArcGIS companion R runner", runner_path)
check_line(requireNamespace("ranger", quietly = TRUE), "Required R package 'ranger'")
check_line(requireNamespace("sf", quietly = TRUE), "Optional R package 'sf'")
check_line(file.exists(model_path), "Downloaded V3 model", model_path)

program_files <- unique(c(
  Sys.getenv("ProgramW6432", unset = ""),
  Sys.getenv("ProgramFiles", unset = "")
))
arcgis_candidates <- file.path(program_files[nzchar(program_files)], "ArcGIS", "Pro", "bin", "ArcGISPro.exe")
arcgis_pro_path <- arcgis_candidates[file.exists(arcgis_candidates)][1]
check_line(length(arcgis_pro_path) == 1 && !is.na(arcgis_pro_path), "ArcGIS Pro installation", arcgis_pro_path)

message("")
message("Optional R-ArcGIS Bridge check")
message("--------------------------------")
message("The OpenEstuaryAI.pyt workflow does not require arcgisbinding; it uses R for")
message("prediction and ArcPy for the output feature class. The checks below are included")
message("for users who also want the full Esri R-ArcGIS Bridge configured.")

bridge_installed <- requireNamespace("arcgisbinding", quietly = TRUE)
check_line(bridge_installed, "R package 'arcgisbinding'")

if (bridge_installed) {
  product <- tryCatch(
    {
      suppressPackageStartupMessages(library(arcgisbinding))
      arc.check_product()
    },
    error = function(e) e
  )

  if (inherits(product, "error")) {
    check_line(FALSE, "arc.check_product()", conditionMessage(product))
    message("Set ArcGIS Pro > Project > Options > Geoprocessing > R-ArcGIS Support to:")
    message(R.home())
  } else {
    check_line(TRUE, "arc.check_product() connected to ArcGIS Pro")
    print(product)
  }
} else {
  message("To install the optional Bridge package in this R installation, run:")
  message("install.packages('arcgisbinding', repos = 'https://r.esri.com', type = 'win.binary')")
  message("Then point ArcGIS Pro > Project > Options > Geoprocessing > R-ArcGIS Support to:")
  message(R.home())
}

message("")
message("Add the toolbox in ArcGIS Pro")
message("------------------------------")
message("1. Open the Catalog pane.")
message("2. Right-click Toolboxes and choose Add Toolbox.")
message("3. Browse to this file:")
message(toolbox_path)
message("4. Open Open Estuary AI > Atchafalaya Salinity Emulator.")
message("")
message("Keep OpenEstuaryAI.pyt and run_v3_scenario_arcgis.R together in this directory.")

