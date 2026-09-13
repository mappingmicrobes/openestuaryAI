#!/usr/bin/env Rscript

# V3: discharge-response salinity/plume emulator.
#
# Goal:
#   Train a model that can be driven by user-specified discharge scenarios
#   without requiring the user to run MIKE 21. This version focuses on spatial
#   salinity and freshwater-plume response, not temperature.
#
# User-facing idea:
#   scenario_year + discharge_m3s -> predicted salinity map + plume metrics

suppressPackageStartupMessages({
  required <- c("data.table", "dplyr", "ggplot2", "readr", "stringr", "tibble")
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

library(data.table)
library(dplyr)
library(ggplot2)
library(readr)
library(stringr)
library(tibble)

project_dir <- getwd()
xyz_dir <- "G:/Shared drives/Thrash Lab Shared/David_Banuelas_Projects/Banuelas_Coastal_MAGs/Data/Gulf_Files/ard_delta.xyz"
discharge_path <- file.path(project_dir, "MorganCity_07381600_hourly_Q_stage.csv")
output_dir <- file.path(project_dir, "Estuary-Emulator", "outputs")
model_dir <- file.path(project_dir, "Estuary-Emulator", "models")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(model_dir, recursive = TRUE, showWarnings = FALSE)

# December is excluded until the corrected MIKE boundary/model run is available.
training_years <- c(2025, 2050)
training_months <- c(9, 10, 11)
exclude_months <- c(12)

sea_level_rise_by_year <- c("2025" = 0.0, "2050" = 0.4)
discharge_reference_year <- 2025

# Keep V3 manageable. Increase after the first successful run.
max_rows_per_file <- 300000
max_train_rows <- 2000000
n_threads <- min(12, max(1, parallel::detectCores(logical = TRUE) - 2))

# From the lag analysis, 12-18 hours looked physically plausible.
lag_hours <- c(6, 12, 18, 24, 48, 72)
smooth_window_hours <- 25

fresh_thresholds_psu <- c(0.5, 1, 2, 5, 10)

# Scenario predictions to export after training.
# Users can edit this table later or replace it with a CSV.
prediction_scenarios <- tibble(
  scenario_name = c(
    "baseline_low_Q",
    "baseline_median_Q",
    "baseline_high_Q",
    "slr04_low_Q",
    "slr04_median_Q",
    "slr04_high_Q"
  ),
  scenario_year = c(2025, 2025, 2025, 2050, 2050, 2050),
  sea_level_rise_m = c(0.0, 0.0, 0.0, 0.4, 0.4, 0.4),
  discharge_quantile = c(0.1, 0.5, 0.9, 0.1, 0.5, 0.9)
)

message("V3 plume emulator")
message("Training years: ", paste(training_years, collapse = ", "))
message("Training months: ", paste(training_months, collapse = ", "))
message("Excluded months: ", paste(exclude_months, collapse = ", "))

if (!dir.exists(xyz_dir)) {
  stop("XYZ directory does not exist or is not mounted: ", xyz_dir, call. = FALSE)
}
if (!file.exists(discharge_path)) {
  stop("Discharge file not found: ", discharge_path, call. = FALSE)
}
if (!requireNamespace("ranger", quietly = TRUE)) {
  stop("Install ranger for V3: install.packages('ranger')", call. = FALSE)
}

to_discharge_reference_time <- function(time, reference_year) {
  parts <- as.POSIXlt(time, tz = "UTC")
  as.POSIXct(
    sprintf(
      "%04d-%02d-%02d %02d:%02d:%02d",
      reference_year,
      parts$mon + 1,
      parts$mday,
      parts$hour,
      parts$min,
      floor(parts$sec)
    ),
    tz = "UTC"
  )
}

read_raw_xyz <- function(path) {
  dat <- fread(
    path,
    sep = " ",
    quote = "\"",
    header = TRUE,
    data.table = FALSE,
    showProgress = TRUE,
    nThread = n_threads
  )

  if (ncol(dat) == 1) {
    dat <- fread(
      path,
      sep = " ",
      quote = "\"",
      header = FALSE,
      skip = 1,
      col.names = c("Time", "X", "Y", "Z", "zeta_m", "salinity_PSU", "temperature_C"),
      data.table = FALSE,
      showProgress = TRUE,
      nThread = n_threads
    )
  }

  names(dat) <- names(dat) |>
    str_trim() |>
    str_replace_all("[^A-Za-z0-9_]+", "_")

  required_columns <- c("Time", "X", "Y", "Z", "salinity_PSU")
  missing_columns <- setdiff(required_columns, names(dat))
  if (length(missing_columns) > 0) {
    stop(
      "Missing expected raw columns in ",
      basename(path),
      ": ",
      paste(missing_columns, collapse = ", "),
      call. = FALSE
    )
  }

  dat |>
    mutate(Time = as.POSIXct(Time, format = "%Y-%m-%d %H:%M:%S", tz = "UTC"))
}

read_discharge_features <- function(path) {
  discharge <- fread(path, showProgress = FALSE) |>
    mutate(
      datetime_utc = as.POSIXct(
        datetime_utc,
        format = "%Y-%m-%dT%H:%M:%OSZ",
        tz = "UTC"
      )
    ) |>
    arrange(datetime_utc)

  required_columns <- c("datetime_utc", "Q_m3s", "Stage_m")
  missing_columns <- setdiff(required_columns, names(discharge))
  if (length(missing_columns) > 0) {
    stop(
      "Discharge file missing expected columns: ",
      paste(missing_columns, collapse = ", "),
      call. = FALSE
    )
  }

  timestep_hours <- median(as.numeric(diff(discharge$datetime_utc), units = "hours"), na.rm = TRUE)
  if (!is.finite(timestep_hours) || timestep_hours <= 0) {
    stop("Could not infer discharge timestep.", call. = FALSE)
  }

  discharge_dt <- as.data.table(discharge)
  setorder(discharge_dt, datetime_utc)

  for (lag_hour in lag_hours) {
    lag_rows <- round(lag_hour / timestep_hours)
    discharge_dt[, paste0("Q_m3s_lag_", lag_hour, "h") := shift(Q_m3s, n = lag_rows, type = "lag")]
  }

  smooth_rows <- max(1, round(smooth_window_hours / timestep_hours))
  discharge_dt[, Q_m3s_smooth_25h := frollmean(Q_m3s, n = smooth_rows, align = "right", na.rm = TRUE)]

  for (lag_hour in lag_hours) {
    lag_rows <- round(lag_hour / timestep_hours)
    discharge_dt[
      ,
      paste0("Q_m3s_smooth_25h_lag_", lag_hour, "h") :=
        shift(Q_m3s_smooth_25h, n = lag_rows, type = "lag")
    ]
  }

  as_tibble(discharge_dt)
}

find_raw_file <- function(year, month) {
  scenario_suffix <- ifelse(year == 2050, "50", "25")
  pattern <- paste0("ard_delta_", scenario_suffix, sprintf("%02d", month), "\\.xyz$")
  candidates <- list.files(
    xyz_dir,
    pattern = pattern,
    recursive = TRUE,
    full.names = TRUE,
    ignore.case = TRUE
  )

  if (length(candidates) == 0) {
    stop("Could not find raw XYZ matching pattern: ", pattern, call. = FALSE)
  }

  candidates[1]
}

join_discharge <- function(raw, discharge) {
  raw_dt <- as.data.table(raw)
  discharge_dt <- as.data.table(discharge)
  setkey(discharge_dt, datetime_utc)

  joined <- discharge_dt[
    raw_dt,
    on = .(datetime_utc = forcing_time),
    roll = "nearest"
  ] |>
    as_tibble()

  if (!"forcing_time" %in% names(joined) && "forcing_time_original" %in% names(joined)) {
    joined <- joined |>
      mutate(forcing_time = forcing_time_original)
  }

  joined
}

discharge <- read_discharge_features(discharge_path)

training_plan <- expand.grid(
  scenario_year = training_years,
  month = setdiff(training_months, exclude_months)
) |>
  as_tibble() |>
  arrange(scenario_year, month)

training_parts <- list()
node_template <- NULL

for (i in seq_len(nrow(training_plan))) {
  scenario_year <- training_plan$scenario_year[i]
  month <- training_plan$month[i]
  raw_path <- find_raw_file(scenario_year, month)

  message("")
  message("Reading training file: ", basename(raw_path))

  raw <- read_raw_xyz(raw_path) |>
    filter(as.POSIXlt(Time, tz = "UTC")$mon + 1 == month) |>
    mutate(
      forcing_time = to_discharge_reference_time(Time, discharge_reference_year),
      forcing_time_original = forcing_time,
      scenario_year = scenario_year,
      sea_level_rise_m = unname(sea_level_rise_by_year[as.character(scenario_year)])
    )

  if (is.null(node_template)) {
    node_template <- raw |>
      distinct(X, Y, Z)
  }

  joined <- join_discharge(raw, discharge)

  set.seed(1000 + scenario_year + month)
  if (nrow(joined) > max_rows_per_file) {
    joined <- joined |>
      slice_sample(n = max_rows_per_file)
  }

  training_parts[[length(training_parts) + 1]] <- joined
  rm(raw, joined)
  invisible(gc())
}

training_data <- bind_rows(training_parts)

discharge_predictors <- c(
  paste0("Q_m3s_lag_", lag_hours, "h"),
  paste0("Q_m3s_smooth_25h_lag_", lag_hours, "h")
)

predictor_columns <- c("X", "Y", "Z", "sea_level_rise_m", discharge_predictors)
predictor_columns <- predictor_columns[predictor_columns %in% names(training_data)]
target_column <- "salinity_PSU"

training_data <- training_data |>
  filter(!is.na(.data[[target_column]])) |>
  filter(if_all(all_of(predictor_columns), ~ !is.na(.x)))

set.seed(42)
train_index <- sample(c(TRUE, FALSE), nrow(training_data), replace = TRUE, prob = c(0.8, 0.2))
train <- training_data[train_index, ]
test <- training_data[!train_index, ]

if (nrow(train) > max_train_rows) {
  train_model <- train |>
    slice_sample(n = max_train_rows)
} else {
  train_model <- train
}

message("")
message("Training rows used: ", format(nrow(train_model), big.mark = ","))
message("Test rows: ", format(nrow(test), big.mark = ","))
message("Predictors: ", paste(predictor_columns, collapse = ", "))

formula_text <- paste(target_column, "~", paste(predictor_columns, collapse = " + "))
model <- ranger::ranger( #Started @ 10:40am-10:46am, 31 GB RAM, CPU 38%
  formula = as.formula(formula_text),
  data = train_model,
  num.trees = 400,
  mtry = min(5, length(predictor_columns)),
  min.node.size = 20,
  seed = 42,
  importance = "impurity",
  num.threads = n_threads
)

prediction <- predict(model, data = test)$predictions #10:46am - 10:37am
truth <- test[[target_column]]
error <- prediction - truth

validation_predictions <- test |>
  transmute(
    Time,
    forcing_time,
    X,
    Y,
    Z,
    scenario_year,
    sea_level_rise_m,
    truth_salinity_PSU = truth,
    predicted_salinity_PSU = prediction,
    error_salinity_PSU = error
  )

metrics <- tibble(
  model_version = "v3_discharge_plume",
  n_training_files = nrow(training_plan),
  n_train = nrow(train_model),
  n_test = nrow(test),
  n_predictors = length(predictor_columns),
  predictors = paste(predictor_columns, collapse = " + "),
  mae = mean(abs(error), na.rm = TRUE),
  rmse = sqrt(mean(error^2, na.rm = TRUE)),
  bias = mean(error, na.rm = TRUE),
  r2 = 1 - sum(error^2, na.rm = TRUE) / sum((truth - mean(truth, na.rm = TRUE))^2, na.rm = TRUE)
)

message("")
message("V3 validation metrics:")
print(metrics)

q_values <- quantile(discharge$Q_m3s, probs = prediction_scenarios$discharge_quantile, na.rm = TRUE)
prediction_scenarios$Q_m3s <- as.numeric(q_values)

make_scenario_table <- function(scenario_row) {
  template <- node_template |>
    mutate(
      scenario_name = scenario_row$scenario_name,
      scenario_year = scenario_row$scenario_year,
      sea_level_rise_m = scenario_row$sea_level_rise_m,
      Q_m3s = scenario_row$Q_m3s
    )

  for (col in discharge_predictors) {
    template[[col]] <- scenario_row$Q_m3s
  }

  template
}

scenario_tables <- bind_rows(lapply(seq_len(nrow(prediction_scenarios)), function(i) {
  make_scenario_table(prediction_scenarios[i, ])
}))

scenario_tables$predicted_salinity_PSU <- predict(model, data = scenario_tables)$predictions

plume_metrics <- bind_rows(lapply(fresh_thresholds_psu, function(threshold) {
  scenario_tables |>
    group_by(scenario_name, scenario_year, sea_level_rise_m, Q_m3s) |>
    summarise(
      threshold_psu = threshold,
      fraction_nodes_fresher = mean(predicted_salinity_PSU <= threshold, na.rm = TRUE),
      nodes_fresher = sum(predicted_salinity_PSU <= threshold, na.rm = TRUE),
      total_nodes = n(),
      .groups = "drop"
    )
}))

metrics_path <- file.path(output_dir, "v3_discharge_plume_metrics.csv")
validation_predictions_path <- file.path(output_dir, "v3_discharge_plume_validation_predictions.csv")
scenario_predictions_path <- file.path(output_dir, "v3_discharge_plume_scenario_predictions.csv")
plume_metrics_path <- file.path(output_dir, "v3_discharge_plume_area_metrics.csv")
scenario_inputs_path <- file.path(output_dir, "v3_discharge_plume_scenario_inputs.csv")
model_path <- file.path(model_dir, "v3_discharge_plume_model.rds")

write_csv(metrics, metrics_path)
write_csv(validation_predictions, validation_predictions_path)
write_csv(prediction_scenarios, scenario_inputs_path)
write_csv(scenario_tables, scenario_predictions_path)
write_csv(plume_metrics, plume_metrics_path)
saveRDS(
  list(
    model = model,
    model_version = "v3_discharge_plume",
    formula = formula_text,
    predictors = predictor_columns,
    discharge_predictors = discharge_predictors,
    sea_level_rise_by_year = sea_level_rise_by_year,
    discharge_reference_year = discharge_reference_year,
    lag_hours = lag_hours,
    smooth_window_hours = smooth_window_hours,
    fresh_thresholds_psu = fresh_thresholds_psu,
    node_template = node_template,
    metrics = metrics
  ),
  model_path
)

plot_scenario <- prediction_scenarios$scenario_name[nrow(prediction_scenarios)]
plot_table <- scenario_tables |>
  filter(scenario_name == plot_scenario)

plot <- ggplot(plot_table, aes(X, Y, color = predicted_salinity_PSU)) +
  geom_point(size = 0.25) +
  coord_equal() +
  scale_color_viridis_c(option = "C", limits = c(0, 35)) +
  labs(
    title = paste0("V3 predicted salinity: ", plot_scenario),
    x = "X",
    y = "Y",
    color = "PSU"
  ) +
  theme_minimal(base_size = 11) +
  theme(
    panel.grid = element_blank(),
    plot.title = element_text(face = "bold")
  )

plot_path <- file.path(output_dir, "v3_discharge_plume_example_prediction.png")
print(plot)
ggsave(plot_path, plot, width = 6, height = 5, dpi = 250)

message("")
message("Wrote:")
message(metrics_path)
message(validation_predictions_path)
message(scenario_inputs_path)
message(scenario_predictions_path)
message(plume_metrics_path)
message(model_path)
message(plot_path)
