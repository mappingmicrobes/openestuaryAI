#!/usr/bin/env Rscript

# Explore lagged relationships between Morgan City discharge and MIKE 21 salinity.
# This is diagnostic only. It does not replace the monthly emulator.

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
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

n_threads <- min(12, max(1, parallel::detectCores(logical = TRUE) - 2))

# Start with a valid month. December is excluded until the corrected MIKE run is ready.
target_scenario_year <- 2050
target_month <- 11
discharge_reference_year <- 2025

# Raw XYZ files can include ramp/spinup days. This keeps only the analysis month.
analysis_month_only <- TRUE

# Salinity thresholds used to describe the freshwater plume.
fresh_thresholds_psu <- c(0.5, 1, 2, 5, 10)

# Test discharge travel-time/memory lags from same-time to two weeks.
lag_hours <- seq(0, 14 * 24, by = 6)
smooth_window_hours <- 25

# Optional region brackets. These let us track plume response in broad water
# zones rather than averaging the entire model domain.
regions <- tibble(
  region = c("entire_domain", "upper_estuary", "central_bay", "nearshore_gulf"),
  xmin = c(-Inf, 650000, 620000, -Inf),
  xmax = c( Inf,  Inf, 670000, 650000),
  ymin = c(-Inf, 3250000, 3235000, -Inf),
  ymax = c( Inf,  Inf, 3270000, 3245000)
)

message("Lag analysis target: ", target_scenario_year, "-", sprintf("%02d", target_month))
message("Raw XYZ folder: ", xyz_dir)

if (!dir.exists(xyz_dir)) {
  stop("XYZ directory does not exist or is not mounted: ", xyz_dir, call. = FALSE)
}
if (!file.exists(discharge_path)) {
  stop("Discharge file not found: ", discharge_path, call. = FALSE)
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

safe_cor <- function(x, y) {
  ok <- is.finite(x) & is.finite(y)
  if (sum(ok) < 3) {
    return(NA_real_)
  }
  if (sd(x[ok]) == 0 || sd(y[ok]) == 0) {
    return(NA_real_)
  }
  cor(x[ok], y[ok])
}

smooth_by_time <- function(dat, value_cols, group_cols, time_col = "Time", window_hours = 25) {
  smoothed <- dat |>
    arrange(across(all_of(c(group_cols, time_col)))) |>
    group_by(across(all_of(group_cols))) |>
    group_modify(function(.x, .y) {
      times <- .x[[time_col]]
      timestep_hours <- median(as.numeric(diff(times), units = "hours"), na.rm = TRUE)
      if (!is.finite(timestep_hours) || timestep_hours <= 0) {
        timestep_hours <- 1
      }
      window_rows <- max(1, round(window_hours / timestep_hours))
      for (col in value_cols) {
        .x[[paste0(col, "_smooth")]] <- data.table::frollmean(
          .x[[col]],
          n = window_rows,
          align = "right",
          na.rm = TRUE
        )
      }
      .x
    }) |>
    ungroup()

  smoothed
}

scenario_suffix <- ifelse(target_scenario_year == 2050, "50", "25")
target_pattern <- paste0("ard_delta_", scenario_suffix, sprintf("%02d", target_month), "\\.xyz$")
raw_candidates <- list.files(
  xyz_dir,
  pattern = target_pattern,
  recursive = TRUE,
  full.names = TRUE,
  ignore.case = TRUE
)

if (length(raw_candidates) == 0) {
  stop("Could not find raw XYZ matching pattern: ", target_pattern, call. = FALSE)
}

raw_path <- raw_candidates[1]
message("Using raw XYZ: ", raw_path)

raw <- read_raw_xyz(raw_path)

if (analysis_month_only) {
  raw <- raw |>
    filter(
      as.POSIXlt(Time, tz = "UTC")$mon + 1 == target_month
    )
}

raw <- raw |>
  mutate(forcing_time = to_discharge_reference_time(Time, discharge_reference_year))

message("Rows after analysis-window filter: ", format(nrow(raw), big.mark = ","))
message("Unique timesteps: ", length(unique(raw$Time)))
message("Discharge reference year for lag join: ", discharge_reference_year)

discharge <- fread(discharge_path, showProgress = FALSE) |>
  mutate(
    datetime_utc = as.POSIXct(
      datetime_utc,
      format = "%Y-%m-%dT%H:%M:%OSZ",
      tz = "UTC"
    )
  ) |>
  arrange(datetime_utc)

if (any(is.na(discharge$datetime_utc))) {
  stop("Some discharge timestamps could not be parsed.", call. = FALSE)
}

assign_region <- function(dat, region_row) {
  dat |>
    filter(
      X >= region_row$xmin,
      X <= region_row$xmax,
      Y >= region_row$ymin,
      Y <= region_row$ymax
    ) |>
    mutate(region = region_row$region)
}

region_series <- bind_rows(lapply(seq_len(nrow(regions)), function(i) {
  region_raw <- assign_region(raw, regions[i, ])

  if (nrow(region_raw) == 0) {
    return(tibble())
  }

  region_raw |>
    group_by(region, Time, forcing_time) |>
    summarise(
      mean_salinity_PSU = mean(salinity_PSU, na.rm = TRUE),
      median_salinity_PSU = median(salinity_PSU, na.rm = TRUE),
      min_salinity_PSU = min(salinity_PSU, na.rm = TRUE),
      max_salinity_PSU = max(salinity_PSU, na.rm = TRUE),
      n_nodes = n(),
      .groups = "drop"
    )
}))

plume_series <- bind_rows(lapply(seq_len(nrow(regions)), function(i) {
  region_raw <- assign_region(raw, regions[i, ])

  if (nrow(region_raw) == 0) {
    return(tibble())
  }

  bind_rows(lapply(fresh_thresholds_psu, function(threshold) {
    region_raw |>
      group_by(Time, forcing_time) |>
      summarise(
        fraction_below_threshold = mean(salinity_PSU <= threshold, na.rm = TRUE),
        nodes_below_threshold = sum(salinity_PSU <= threshold, na.rm = TRUE),
        n_nodes = n(),
        .groups = "drop"
      ) |>
      mutate(
        region = regions$region[i],
        threshold_psu = threshold
      )
  }))
}))

region_series_smoothed <- smooth_by_time(
  region_series,
  value_cols = c("mean_salinity_PSU", "median_salinity_PSU"),
  group_cols = c("region"),
  window_hours = smooth_window_hours
)

plume_series_smoothed <- smooth_by_time(
  plume_series,
  value_cols = c("fraction_below_threshold"),
  group_cols = c("region", "threshold_psu"),
  window_hours = smooth_window_hours
)

discharge_smoothed <- discharge |>
  arrange(datetime_utc)

discharge_timestep_hours <- median(
  as.numeric(diff(discharge_smoothed$datetime_utc), units = "hours"),
  na.rm = TRUE
)
discharge_window_rows <- max(1, round(smooth_window_hours / discharge_timestep_hours))
discharge_smoothed <- discharge_smoothed |>
  mutate(
    Q_m3s_smooth = data.table::frollmean(
      Q_m3s,
      n = discharge_window_rows,
      align = "right",
      na.rm = TRUE
    ),
    Stage_m_smooth = data.table::frollmean(
      Stage_m,
      n = discharge_window_rows,
      align = "right",
      na.rm = TRUE
    )
  )

nearest_discharge <- function(times, discharge_table) {
  discharge_dt <- as.data.table(discharge_table)
  query_dt <- data.table(Time = times)
  setkey(discharge_dt, datetime_utc)
  discharge_dt[query_dt, on = .(datetime_utc = Time), roll = "nearest"]
}

lagged_join <- bind_rows(lapply(lag_hours, function(lag_hour) {
  shifted <- region_series |>
    mutate(discharge_lookup_time = forcing_time - lag_hour * 3600)

  q <- nearest_discharge(shifted$discharge_lookup_time, discharge)

  shifted |>
    mutate(
      lag_hour = lag_hour,
      discharge_lookup_time = discharge_lookup_time,
      Q_m3s = q$Q_m3s,
      Stage_m = q$Stage_m
    )
}))

lag_correlations <- lagged_join |>
  group_by(region, lag_hour) |>
  summarise(
    n = n(),
    cor_Q_mean_salinity = safe_cor(Q_m3s, mean_salinity_PSU),
    cor_Q_median_salinity = safe_cor(Q_m3s, median_salinity_PSU),
    .groups = "drop"
  ) |>
  arrange(region, cor_Q_mean_salinity)

best_lag_by_region <- lag_correlations |>
  group_by(region) |>
  slice_max(order_by = abs(cor_Q_mean_salinity), n = 1, with_ties = FALSE) |>
  ungroup()

plume_lagged_join <- bind_rows(lapply(lag_hours, function(lag_hour) {
  shifted <- plume_series |>
    mutate(discharge_lookup_time = forcing_time - lag_hour * 3600)

  q <- nearest_discharge(shifted$discharge_lookup_time, discharge)

  shifted |>
    mutate(
      lag_hour = lag_hour,
      discharge_lookup_time = discharge_lookup_time,
      Q_m3s = q$Q_m3s,
      Stage_m = q$Stage_m
    )
}))

plume_lag_correlations <- plume_lagged_join |>
  group_by(region, threshold_psu, lag_hour) |>
  summarise(
    n = n(),
    cor_Q_fresh_fraction = safe_cor(Q_m3s, fraction_below_threshold),
    .groups = "drop"
  ) |>
  arrange(region, threshold_psu, desc(abs(cor_Q_fresh_fraction)))

best_plume_lag <- plume_lag_correlations |>
  group_by(region, threshold_psu) |>
  slice_max(order_by = abs(cor_Q_fresh_fraction), n = 1, with_ties = FALSE) |>
  ungroup()

lagged_join_smoothed <- bind_rows(lapply(lag_hours, function(lag_hour) {
  shifted <- region_series_smoothed |>
    mutate(discharge_lookup_time = forcing_time - lag_hour * 3600)

  q <- nearest_discharge(shifted$discharge_lookup_time, discharge_smoothed)

  shifted |>
    mutate(
      lag_hour = lag_hour,
      discharge_lookup_time = discharge_lookup_time,
      Q_m3s_smooth = q$Q_m3s_smooth,
      Stage_m_smooth = q$Stage_m_smooth
    )
}))

lag_correlations_smoothed <- lagged_join_smoothed |>
  group_by(region, lag_hour) |>
  summarise(
    n = n(),
    cor_Q_mean_salinity_smooth = safe_cor(Q_m3s_smooth, mean_salinity_PSU_smooth),
    cor_Q_median_salinity_smooth = safe_cor(Q_m3s_smooth, median_salinity_PSU_smooth),
    .groups = "drop"
  ) |>
  arrange(region, cor_Q_mean_salinity_smooth)

best_lag_by_region_smoothed <- lag_correlations_smoothed |>
  filter(!is.na(cor_Q_mean_salinity_smooth)) |>
  group_by(region) |>
  slice_max(order_by = abs(cor_Q_mean_salinity_smooth), n = 1, with_ties = FALSE) |>
  ungroup()

plume_lagged_join_smoothed <- bind_rows(lapply(lag_hours, function(lag_hour) {
  shifted <- plume_series_smoothed |>
    mutate(discharge_lookup_time = forcing_time - lag_hour * 3600)

  q <- nearest_discharge(shifted$discharge_lookup_time, discharge_smoothed)

  shifted |>
    mutate(
      lag_hour = lag_hour,
      discharge_lookup_time = discharge_lookup_time,
      Q_m3s_smooth = q$Q_m3s_smooth,
      Stage_m_smooth = q$Stage_m_smooth
    )
}))

plume_lag_correlations_smoothed <- plume_lagged_join_smoothed |>
  group_by(region, threshold_psu, lag_hour) |>
  summarise(
    n = n(),
    cor_Q_fresh_fraction_smooth = safe_cor(Q_m3s_smooth, fraction_below_threshold_smooth),
    .groups = "drop"
  ) |>
  arrange(region, threshold_psu, desc(abs(cor_Q_fresh_fraction_smooth)))

best_plume_lag_smoothed <- plume_lag_correlations_smoothed |>
  filter(!is.na(cor_Q_fresh_fraction_smooth)) |>
  group_by(region, threshold_psu) |>
  slice_max(order_by = abs(cor_Q_fresh_fraction_smooth), n = 1, with_ties = FALSE) |>
  ungroup()

region_series_path <- file.path(output_dir, "lag_region_salinity_timeseries.csv")
plume_series_path <- file.path(output_dir, "lag_plume_threshold_timeseries.csv")
lag_correlations_path <- file.path(output_dir, "lag_discharge_salinity_correlations.csv")
best_lag_path <- file.path(output_dir, "lag_best_discharge_salinity_by_region.csv")
plume_lag_path <- file.path(output_dir, "lag_discharge_plume_correlations.csv")
best_plume_lag_path <- file.path(output_dir, "lag_best_discharge_plume_by_region.csv")
lag_plot_path <- file.path(output_dir, "lag_discharge_salinity_correlation.png")
plume_lag_plot_path <- file.path(output_dir, "lag_discharge_plume_correlation.png")
lag_correlations_smoothed_path <- file.path(output_dir, "lag_discharge_salinity_correlations_smoothed_25h.csv")
best_lag_smoothed_path <- file.path(output_dir, "lag_best_discharge_salinity_by_region_smoothed_25h.csv")
plume_lag_smoothed_path <- file.path(output_dir, "lag_discharge_plume_correlations_smoothed_25h.csv")
best_plume_lag_smoothed_path <- file.path(output_dir, "lag_best_discharge_plume_by_region_smoothed_25h.csv")
lag_smoothed_plot_path <- file.path(output_dir, "lag_discharge_salinity_correlation_smoothed_25h.png")
plume_lag_smoothed_plot_path <- file.path(output_dir, "lag_discharge_plume_correlation_smoothed_25h.png")

write_csv(region_series, region_series_path)
write_csv(plume_series, plume_series_path)
write_csv(lag_correlations, lag_correlations_path)
write_csv(best_lag_by_region, best_lag_path)
write_csv(plume_lag_correlations, plume_lag_path)
write_csv(best_plume_lag, best_plume_lag_path)
write_csv(lag_correlations_smoothed, lag_correlations_smoothed_path)
write_csv(best_lag_by_region_smoothed, best_lag_smoothed_path)
write_csv(plume_lag_correlations_smoothed, plume_lag_smoothed_path)
write_csv(best_plume_lag_smoothed, best_plume_lag_smoothed_path)

lag_plot <- ggplot(lag_correlations, aes(lag_hour, cor_Q_mean_salinity, color = region)) +
  geom_hline(yintercept = 0, color = "gray70") +
  geom_line(linewidth = 0.8) +
  geom_point(size = 1.8) +
  labs(
    title = "Morgan City discharge vs regional salinity by lag",
    x = "Discharge lag before salinity response (hours)",
    y = "Correlation: Q vs mean salinity",
    color = "Region"
  ) +
  theme_minimal(base_size = 11)

plume_lag_plot <- ggplot(
  plume_lag_correlations,
  aes(lag_hour, cor_Q_fresh_fraction, color = factor(threshold_psu))
) +
  geom_hline(yintercept = 0, color = "gray70") +
  geom_line(linewidth = 0.8) +
  facet_wrap(~region) +
  labs(
    title = "Morgan City discharge vs freshwater-plume extent by lag",
    x = "Discharge lag before plume response (hours)",
    y = "Correlation: Q vs fraction below salinity threshold",
    color = "Fresh threshold (PSU)"
  ) +
  theme_minimal(base_size = 11)

lag_smoothed_plot <- ggplot(
  lag_correlations_smoothed,
  aes(lag_hour, cor_Q_mean_salinity_smooth, color = region)
) +
  geom_hline(yintercept = 0, color = "gray70") +
  geom_line(linewidth = 0.8, na.rm = TRUE) +
  geom_point(size = 1.8, na.rm = TRUE) +
  labs(
    title = paste0("25-hour smoothed discharge vs regional salinity by lag"),
    x = "Discharge lag before salinity response (hours)",
    y = "Correlation: smoothed Q vs smoothed mean salinity",
    color = "Region"
  ) +
  theme_minimal(base_size = 11)

plume_lag_smoothed_plot <- ggplot(
  plume_lag_correlations_smoothed,
  aes(lag_hour, cor_Q_fresh_fraction_smooth, color = factor(threshold_psu))
) +
  geom_hline(yintercept = 0, color = "gray70") +
  geom_line(linewidth = 0.8, na.rm = TRUE) +
  facet_wrap(~region) +
  labs(
    title = paste0("25-hour smoothed discharge vs freshwater-plume extent by lag"),
    x = "Discharge lag before plume response (hours)",
    y = "Correlation: smoothed Q vs smoothed fraction below threshold",
    color = "Fresh threshold (PSU)"
  ) +
  theme_minimal(base_size = 11)

message("")
message("Best raw discharge-salinity lags:")
print(best_lag_by_region)
message("")
message("Best raw discharge-plume lags:")
print(best_plume_lag)
message("")
message("Best 25-hour smoothed discharge-salinity lags:")
print(best_lag_by_region_smoothed)
message("")
message("Best 25-hour smoothed discharge-plume lags:")
print(best_plume_lag_smoothed)
print(lag_plot)
print(plume_lag_plot)
print(lag_smoothed_plot)
print(plume_lag_smoothed_plot)

ggsave(lag_plot_path, lag_plot, width = 8, height = 5, dpi = 250)
ggsave(plume_lag_plot_path, plume_lag_plot, width = 9, height = 6, dpi = 250)
ggsave(lag_smoothed_plot_path, lag_smoothed_plot, width = 8, height = 5, dpi = 250)
ggsave(plume_lag_smoothed_plot_path, plume_lag_smoothed_plot, width = 9, height = 6, dpi = 250)

message("")
message("Wrote:")
message(region_series_path)
message(plume_series_path)
message(lag_correlations_path)
message(best_lag_path)
message(plume_lag_path)
message(best_plume_lag_path)
message(lag_plot_path)
message(plume_lag_plot_path)
message(lag_correlations_smoothed_path)
message(best_lag_smoothed_path)
message(plume_lag_smoothed_path)
message(best_plume_lag_smoothed_path)
message(lag_smoothed_plot_path)
message(plume_lag_smoothed_plot_path)
