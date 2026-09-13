#!/usr/bin/env Rscript

# Run a user-defined scenario with the trained V3 discharge-plume emulator.
#
# This script is intended for users who do NOT have the raw MIKE 21 XYZ
# training files. It loads the trained model RDS, builds a prediction table from
# the saved node template, and writes CSV/GeoJSON/PNG outputs.

suppressPackageStartupMessages({
  required <- c("dplyr", "ggplot2", "readr", "tibble")
  missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
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
})

library(dplyr)
library(ggplot2)
library(readr)
library(tibble)

# ---------------------------------------------------------------------------
# User settings
# ---------------------------------------------------------------------------

# Use 2025 for present-day/no-SLR and 2050 for +0.4 m SLR.
scenario_year <- 2050

# Current V3 training supports these SLR anchors best:
#   2025: 0.0 m
#   2050: 0.4 m
sea_level_rise_m <- 0.4

# Morgan City discharge scenario in cubic meters per second.
# Examples from the training discharge record:
#   low    ~=  923
#   median ~= 2512
#   high   ~= 5437
discharge_m3s <- 5437

scenario_name <- "example_2050_high_Q"

# If TRUE, clamp predicted salinity to the physically expected 0-35 PSU range.
clamp_salinity <- TRUE

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

project_dir <- getwd()

# This lets the script work in either layout:
#   openestuaryAI/run_v3_scenario.R
# or:
#   openestuaryAI/Estuary-Emulator/run_v3_scenario.R
if (file.exists(file.path(project_dir, "run_v3_scenario.R"))) {
  emulator_dir <- project_dir
} else if (dir.exists(file.path(project_dir, "Estuary-Emulator"))) {
  emulator_dir <- file.path(project_dir, "Estuary-Emulator")
} else {
  emulator_dir <- project_dir
}

model_path <- file.path(emulator_dir, "models", "v3_discharge_plume_model.rds")
output_dir <- file.path(emulator_dir, "outputs", "user_scenarios")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(model_path), recursive = TRUE, showWarnings = FALSE)

prediction_csv_path <- file.path(output_dir, paste0(scenario_name, "_predicted_salinity.csv"))
plume_csv_path <- file.path(output_dir, paste0(scenario_name, "_plume_metrics.csv"))
figure_path <- file.path(output_dir, paste0(scenario_name, "_predicted_salinity.png"))
geojson_path <- file.path(output_dir, paste0(scenario_name, "_predicted_salinity.geojson"))

model_download_url <- paste0(
  "https://github.com/mappingmicrobes/openestuaryAI/releases/download/",
  "v0.1-test-emulator/v3_discharge_plume_model.rds"
)

if (!file.exists(model_path)) {
  message("Model file not found:")
  message(model_path)
  message("")
  message("Downloading trained V3 model from:")
  message(model_download_url)
  message("This is a large file and may take several minutes.")

  download_result <- tryCatch(
    {
      download.file(
        url = model_download_url,
        destfile = model_path,
        mode = "wb",
        quiet = FALSE
      )
      TRUE
    },
    error = function(e) {
      message("Model download failed: ", conditionMessage(e))
      FALSE
    }
  )

  if (!download_result || !file.exists(model_path)) {
    stop(
      "Could not download the model file.\n",
      "Download it manually from the GitHub Release and place it here:\n",
      model_path,
      call. = FALSE
    )
  }
}

if (!requireNamespace("ranger", quietly = TRUE)) {
  stop("Missing package 'ranger'. Install with: install.packages('ranger')", call. = FALSE)
}

model_object <- readRDS(model_path)
model <- model_object$model
node_template <- as_tibble(model_object$node_template)
predictor_columns <- model_object$predictors
discharge_predictors <- model_object$discharge_predictors
fresh_thresholds_psu <- model_object$fresh_thresholds_psu

required_object_fields <- c("model", "node_template", "predictors", "discharge_predictors")
missing_fields <- required_object_fields[!vapply(required_object_fields, function(x) !is.null(model_object[[x]]), logical(1))]
if (length(missing_fields) > 0) {
  stop("Model RDS is missing expected fields: ", paste(missing_fields, collapse = ", "), call. = FALSE)
}

prediction_table <- node_template |>
  mutate(
    scenario_name = scenario_name,
    scenario_year = scenario_year,
    sea_level_rise_m = sea_level_rise_m,
    Q_m3s = discharge_m3s
  )

# V3 was trained with lagged and 25-hour-smoothed discharge predictors.
# For a steady scenario, use the same discharge value for every lagged input.
for (col in discharge_predictors) {
  prediction_table[[col]] <- discharge_m3s
}

missing_predictors <- setdiff(predictor_columns, names(prediction_table))
if (length(missing_predictors) > 0) {
  stop(
    "Scenario table is missing predictors required by the model: ",
    paste(missing_predictors, collapse = ", "),
    call. = FALSE
  )
}

prediction_table$predicted_salinity_PSU <- predict(
  model,
  data = prediction_table[, predictor_columns, drop = FALSE]
)$predictions

if (clamp_salinity) {
  prediction_table <- prediction_table |>
    mutate(predicted_salinity_PSU = pmin(pmax(predicted_salinity_PSU, 0), 35))
}

plume_metrics <- bind_rows(lapply(fresh_thresholds_psu, function(threshold) {
  prediction_table |>
    summarise(
      scenario_name = scenario_name,
      scenario_year = scenario_year,
      sea_level_rise_m = sea_level_rise_m,
      Q_m3s = discharge_m3s,
      threshold_psu = threshold,
      fraction_nodes_fresher = mean(predicted_salinity_PSU <= threshold, na.rm = TRUE),
      nodes_fresher = sum(predicted_salinity_PSU <= threshold, na.rm = TRUE),
      total_nodes = n()
    )
}))

prediction_plot <- ggplot(prediction_table, aes(X, Y, color = predicted_salinity_PSU)) +
  geom_point(size = 0.24) +
  coord_equal() +
  scale_color_viridis_c(option = "C", limits = c(0, 35)) +
  labs(
    title = paste0("V3 Predicted Salinity: ", scenario_name),
    subtitle = paste0(
      "Scenario year: ", scenario_year,
      "; SLR: ", sea_level_rise_m, " m",
      "; Q: ", round(discharge_m3s, 1), " m3/s"
    ),
    x = "X",
    y = "Y",
    color = "PSU"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid = element_blank(),
    plot.title = element_text(face = "bold")
  )

write_csv(prediction_table, prediction_csv_path)
write_csv(plume_metrics, plume_csv_path)
print(prediction_plot)
ggsave(figure_path, prediction_plot, width = 7, height = 5.8, dpi = 300)

if (requireNamespace("sf", quietly = TRUE)) {
  prediction_sf <- sf::st_as_sf(
    prediction_table,
    coords = c("X", "Y"),
    crs = 32615,
    remove = FALSE
  ) |>
    sf::st_transform(4326)

  sf::st_write(prediction_sf, geojson_path, driver = "GeoJSON", delete_dsn = TRUE, quiet = TRUE)
} else {
  message("Package 'sf' is not installed, so GeoJSON export was skipped.")
  message("Install with: install.packages('sf')")
}

message("")
message("Scenario complete.")
message("Wrote:")
message(prediction_csv_path)
message(plume_csv_path)
message(figure_path)
if (file.exists(geojson_path)) {
  message(geojson_path)
}
