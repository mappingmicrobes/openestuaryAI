#!/usr/bin/env Rscript

# ArcGIS Pro geoprocessing wrapper for the Open Estuary AI V3 Atchafalaya
# salinity emulator. This keeps run_v3_scenario.R intact and reuses the saved
# RDS model object without retraining.

MODEL_DOWNLOAD_URL <- paste0(
  "https://github.com/mappingmicrobes/openestuaryAI/releases/download/",
  "v0.1-test-emulator/v3_discharge_plume_model.rds"
)

SUPPORTED_SLR <- c(
  "baseline" = 0.0,
  "baseline / 2025-style = 0.0 m" = 0.0,
  "2025" = 0.0,
  "2025-style baseline" = 0.0,
  "0.0" = 0.0,
  "0" = 0.0,
  "2050" = 0.4,
  "2050 slr = +0.4 m" = 0.4,
  "2050 - +0.4 m slr" = 0.4,
  "0.4" = 0.4,
  "+0.4" = 0.4
)

arc_message <- function(...) {
  msg <- paste0(...)
  message(msg)
  if (requireNamespace("arcgisbinding", quietly = TRUE)) {
    try(arcgisbinding::arc.progress_label(msg), silent = TRUE)
  }
}

require_packages <- function(pkgs) {
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing) > 0) {
    stop(
      "Missing required R packages: ",
      paste(missing, collapse = ", "),
      "\nInstall with: install.packages(c(",
      paste(sprintf('"%s"', missing), collapse = ", "),
      "))",
      call. = FALSE
    )
  }
}

project_root <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    return(normalizePath(dirname(sub("^--file=", "", file_arg[[1]])), winslash = "/", mustWork = TRUE))
  }
  normalizePath(getwd(), winslash = "/", mustWork = TRUE)
}

parse_logical <- function(x, default = TRUE) {
  if (is.null(x) || length(x) == 0 || is.na(x) || identical(x, "")) {
    return(default)
  }
  if (is.logical(x)) {
    return(isTRUE(x))
  }
  val <- tolower(trimws(as.character(x)))
  if (val %in% c("true", "t", "yes", "y", "1")) {
    return(TRUE)
  }
  if (val %in% c("false", "f", "no", "n", "0")) {
    return(FALSE)
  }
  stop("Cannot parse logical value: ", x, call. = FALSE)
}

get_named_or_indexed <- function(params, names, index = NULL, default = NULL) {
  if (!is.null(params)) {
    for (nm in names) {
      if (!is.null(params[[nm]]) && !identical(params[[nm]], "")) {
        return(params[[nm]])
      }
    }
    if (!is.null(index) && length(params) >= index && !is.null(params[[index]]) && !identical(params[[index]], "")) {
      return(params[[index]])
    }
  }
  default
}

slr_from_scenario <- function(sea_level_scenario = NULL, sea_level_rise_m = NULL) {
  if (!is.null(sea_level_rise_m) && !identical(sea_level_rise_m, "")) {
    return(as.numeric(sea_level_rise_m))
  }
  if (is.null(sea_level_scenario) || identical(sea_level_scenario, "")) {
    return(0.4)
  }
  key <- tolower(trimws(as.character(sea_level_scenario)))
  key <- gsub(paste(intToUtf8(c(8211, 8212)), collapse = "|"), "-", key)
  if (key %in% names(SUPPORTED_SLR)) {
    return(unname(SUPPORTED_SLR[[key]]))
  }
  numeric_value <- suppressWarnings(as.numeric(gsub("[^0-9.+-]", "", key)))
  if (!is.na(numeric_value)) {
    return(numeric_value)
  }
  stop("Unsupported sea-level scenario: ", sea_level_scenario, call. = FALSE)
}

scenario_label <- function(slr_m) {
  if (isTRUE(all.equal(slr_m, 0.0))) {
    return("Baseline / 2025-style = 0.0 m")
  }
  if (isTRUE(all.equal(slr_m, 0.4))) {
    return("2050 SLR = +0.4 m")
  }
  if (slr_m > 0.4) {
    return(paste0("Experimental extrapolation = +", slr_m, " m"))
  }
  paste0("Experimental interpolation = +", slr_m, " m")
}

scenario_year_from_slr <- function(slr_m) {
  if (isTRUE(all.equal(slr_m, 0.0))) {
    return(2025L)
  }
  if (isTRUE(all.equal(slr_m, 0.4))) {
    return(2050L)
  }
  NA_integer_
}

ensure_model <- function(model_path) {
  dir.create(dirname(model_path), recursive = TRUE, showWarnings = FALSE)
  if (file.exists(model_path)) {
    arc_message("Using local model: ", model_path)
    return(model_path)
  }

  arc_message("Model not found. Downloading V3 model...")
  old_timeout <- getOption("timeout")
  on.exit(options(timeout = old_timeout), add = TRUE)
  options(timeout = max(3600, old_timeout))

  download.file(
    url = MODEL_DOWNLOAD_URL,
    destfile = model_path,
    mode = "wb",
    method = "auto",
    quiet = FALSE
  )

  if (!file.exists(model_path)) {
    stop("Model download failed. Expected model at: ", model_path, call. = FALSE)
  }
  model_path
}

run_emulator <- function(
  sea_level_rise_m = 0.4,
  discharge_m3s = 5437,
  scenario_name = "example_2050_high_Q",
  clamp_salinity = TRUE,
  root_dir = project_root()
) {
  require_packages(c("ranger"))

  model_path <- file.path(root_dir, "models", "v3_discharge_plume_model.rds")
  ensure_model(model_path)

  arc_message("Loading V3 model object...")
  model_object <- readRDS(model_path)
  required_fields <- c("model", "node_template", "predictors", "discharge_predictors")
  missing_fields <- required_fields[!vapply(required_fields, function(x) !is.null(model_object[[x]]), logical(1))]
  if (length(missing_fields) > 0) {
    stop("Model RDS is missing expected fields: ", paste(missing_fields, collapse = ", "), call. = FALSE)
  }

  prediction_table <- as.data.frame(model_object$node_template)
  prediction_table$scenario_name <- scenario_name
  prediction_table$scenario_year <- scenario_year_from_slr(sea_level_rise_m)
  prediction_table$sea_level_scenario <- scenario_label(sea_level_rise_m)
  prediction_table$sea_level_rise_m <- sea_level_rise_m
  prediction_table$Q_m3s <- discharge_m3s

  for (col in model_object$discharge_predictors) {
    prediction_table[[col]] <- discharge_m3s
  }

  missing_predictors <- setdiff(model_object$predictors, names(prediction_table))
  if (length(missing_predictors) > 0) {
    stop(
      "Scenario table is missing predictors required by the model: ",
      paste(missing_predictors, collapse = ", "),
      call. = FALSE
    )
  }

  arc_message("Predicting salinity...")
  prediction_table$predicted_salinity_PSU <- predict(
    model_object$model,
    data = prediction_table[, model_object$predictors, drop = FALSE]
  )$predictions

  if (parse_logical(clamp_salinity, default = TRUE)) {
    prediction_table$predicted_salinity_PSU <- pmin(pmax(prediction_table$predicted_salinity_PSU, 0), 35)
  }

  thresholds <- model_object$fresh_thresholds_psu
  if (is.null(thresholds) || length(thresholds) == 0) {
    thresholds <- c(0.5, 2, 5)
  }

  plume_metrics <- do.call(rbind, lapply(thresholds, function(threshold) {
    data.frame(
      scenario_name = scenario_name,
      scenario_year = scenario_year_from_slr(sea_level_rise_m),
      sea_level_scenario = scenario_label(sea_level_rise_m),
      sea_level_rise_m = sea_level_rise_m,
      Q_m3s = discharge_m3s,
      threshold_psu = threshold,
      fraction_nodes_fresher = mean(prediction_table$predicted_salinity_PSU <= threshold, na.rm = TRUE),
      nodes_fresher = sum(prediction_table$predicted_salinity_PSU <= threshold, na.rm = TRUE),
      total_nodes = nrow(prediction_table)
    )
  }))

  list(predictions = prediction_table, plume_metrics = plume_metrics)
}

write_outputs <- function(result, output_feature_class, plume_metrics_table = NULL, output_csv = NULL) {
  require_packages(c("arcgisbinding", "sf"))

  suppressPackageStartupMessages(library(arcgisbinding))
  arc.check_product()

  if (is.null(output_feature_class) || identical(output_feature_class, "")) {
    stop("An output feature class path is required.", call. = FALSE)
  }

  arc_message("Building ArcGIS point feature class...")
  prediction_sf <- sf::st_as_sf(
    result$predictions,
    coords = c("X", "Y"),
    crs = 32615,
    remove = FALSE
  )

  arc_message("Writing output feature class: ", output_feature_class)
  arcgisbinding::arc.write(output_feature_class, prediction_sf)

  if (!is.null(plume_metrics_table) && !identical(plume_metrics_table, "")) {
    arc_message("Writing plume metrics table: ", plume_metrics_table)
    arcgisbinding::arc.write(plume_metrics_table, result$plume_metrics)
  }

  if (!is.null(output_csv) && !identical(output_csv, "")) {
    arc_message("Writing prediction CSV: ", output_csv)
    utils::write.csv(result$predictions, output_csv, row.names = FALSE)
  }
}

tool_exec <- function(in_params, out_params) {
  require_packages(c("arcgisbinding"))
  suppressPackageStartupMessages(library(arcgisbinding))

  arc_message("Checking ArcGIS product...")
  arc.check_product()

  sea_level_scenario <- get_named_or_indexed(
    in_params,
    c("sea_level_scenario", "Sea-level scenario", "Sea_level_scenario"),
    index = 1,
    default = "2050 SLR = +0.4 m"
  )
  sea_level_rise_m <- get_named_or_indexed(
    in_params,
    c("sea_level_rise_m", "Sea-level rise (m)", "SLR_m"),
    default = NULL
  )
  discharge_m3s <- as.numeric(get_named_or_indexed(
    in_params,
    c("discharge_m3s", "Morgan City discharge (m3/s)", "Q_m3s"),
    index = 2,
    default = 5437
  ))
  scenario_name <- as.character(get_named_or_indexed(
    in_params,
    c("scenario_name", "Scenario name"),
    index = 3,
    default = "example_2050_high_Q"
  ))
  clamp_salinity <- parse_logical(get_named_or_indexed(
    in_params,
    c("clamp_salinity", "Clamp salinity"),
    index = 4,
    default = TRUE
  ))

  output_feature_class <- get_named_or_indexed(
    out_params,
    c("output_feature_class", "Output feature class", "Output"),
    index = 1,
    default = NULL
  )
  plume_metrics_table <- get_named_or_indexed(
    out_params,
    c("plume_metrics_table", "Plume metrics table"),
    index = 2,
    default = NULL
  )
  output_csv <- get_named_or_indexed(
    out_params,
    c("output_csv", "CSV"),
    index = 3,
    default = NULL
  )

  slr_m <- slr_from_scenario(sea_level_scenario, sea_level_rise_m)
  if (!isTRUE(all.equal(slr_m, 0.0)) && !isTRUE(all.equal(slr_m, 0.4))) {
    arc_message("Warning: SLR value ", slr_m, " m is outside the two best-supported V3 anchors.")
  }

  result <- run_emulator(
    sea_level_rise_m = slr_m,
    discharge_m3s = discharge_m3s,
    scenario_name = scenario_name,
    clamp_salinity = clamp_salinity
  )

  write_outputs(result, output_feature_class, plume_metrics_table, output_csv)

  out_params[[1]] <- output_feature_class
  if (!is.null(plume_metrics_table) && !identical(plume_metrics_table, "")) {
    out_params[[2]] <- plume_metrics_table
  }
  if (!is.null(output_csv) && !identical(output_csv, "")) {
    out_params[[3]] <- output_csv
  }
  arc_message("Open Estuary AI ArcGIS scenario complete.")
  out_params
}

parse_cli_args <- function(args) {
  parsed <- list()
  i <- 1
  while (i <= length(args)) {
    key <- args[[i]]
    if (startsWith(key, "--")) {
      name <- sub("^--", "", key)
      next_value <- if (i < length(args) && !startsWith(args[[i + 1]], "--")) args[[i + 1]] else TRUE
      parsed[[name]] <- next_value
      if (!isTRUE(next_value)) {
        i <- i + 1
      }
    }
    i <- i + 1
  }
  parsed
}

if (identical(environment(), globalenv()) && !interactive()) {
  args <- commandArgs(trailingOnly = TRUE)
  cli <- parse_cli_args(args)

  if (isTRUE(cli[["check-only"]])) {
    require_packages(c("arcgisbinding"))
    suppressPackageStartupMessages(library(arcgisbinding))
    arc_message("Checking ArcGIS product...")
    print(arc.check_product())
    quit(status = 0)
  }

  if (length(args) > 0) {
    output_fc <- cli[["output-feature-class"]]
    output_csv <- cli[["output-csv"]]
    if (is.null(output_fc) && is.null(output_csv)) {
      stop("CLI runs require --output-feature-class or --output-csv unless --check-only is used.", call. = FALSE)
    }

    slr_m <- slr_from_scenario(cli[["sea-level-scenario"]], cli[["sea-level-rise-m"]])
    result <- run_emulator(
      sea_level_rise_m = slr_m,
      discharge_m3s = as.numeric(if (!is.null(cli[["discharge-m3s"]])) cli[["discharge-m3s"]] else 5437),
      scenario_name = as.character(if (!is.null(cli[["scenario-name"]])) cli[["scenario-name"]] else "example_2050_high_Q"),
      clamp_salinity = parse_logical(cli[["clamp-salinity"]], default = TRUE)
    )
    if (!is.null(output_fc)) {
      write_outputs(
        result,
        output_feature_class = output_fc,
        plume_metrics_table = cli[["plume-metrics-table"]],
        output_csv = output_csv
      )
    } else {
      arc_message("Writing prediction CSV: ", output_csv)
      utils::write.csv(result$predictions, output_csv, row.names = FALSE)

      plume_metrics_table <- cli[["plume-metrics-table"]]
      if (!is.null(plume_metrics_table)) {
        arc_message("Writing plume metrics CSV: ", plume_metrics_table)
        utils::write.csv(result$plume_metrics, plume_metrics_table, row.names = FALSE)
      }
    }
    arc_message("CLI scenario complete.")
  }
}
