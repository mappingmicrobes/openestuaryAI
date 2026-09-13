# Atchafalaya Estuary Emulator

This folder contains the first minimum viable emulator pipeline for the ESIP
Open Estuary AI project.

The initial target is intentionally narrow:

Predict a withheld Atchafalaya MIKE 21 salinity field and generate truth,
prediction, and error maps.

## Expected inputs

Place representative MIKE 21 XYZ exports in `data/`.

The script does not assume the final XYZ structure yet. It first inspects files
and reports:

- delimiter
- columns
- file size
- row count
- likely coordinate columns
- likely salinity, temperature, and water-level columns
- likely timestep columns

## Commands

Inspect files:

```powershell
python .\atchafalaya_emulator.py inspect --data-dir .\data
```

Train a baseline salinity emulator:

```powershell
python .\atchafalaya_emulator.py train `
  --data-dir .\data `
  --target salinity `
  --model-out .\models\atchafalaya_salinity_baseline.joblib `
  --fig-out .\outputs\salinity_truth_prediction_error.png
```

Train the RStudio monthly discharge-aware baseline:

```r
source("Estuary-Emulator/train_monthly_salinity_emulator.R")
```

This R script uses monthly by-node CSV summaries plus Morgan City discharge
features from `MorganCity_07381600_hourly_Q_stage.csv`. It includes same-period,
lagged, and rolling antecedent discharge predictors because upstream discharge
can influence estuary salinity after a delay. December is currently excluded
because the December 2050 MIKE 21 run used the wrong boundary assignment. The
preferred holdout is November 2050, but the script will automatically choose the
latest available month with
salinity/discharge overlap if that month is not present. The script assumes the
same discharge hydrograph was used for both the 2025 and 2050 MIKE 21 scenarios,
so 2025 monthly discharge features are joined to both scenario years by month.
This keeps discharge as hydrologic forcing while zeta/sea level carries the
scenario difference.

## Baseline model

The first model is a conservative scikit-learn baseline. It is meant to prove
the end-to-end data path before moving to a U-Net, Fourier Neural Operator, or
other spatial neural emulator.

The baseline uses available numeric predictors except the target variable. If a
timestep-like column exists, it uses the latest 20 percent of timesteps as the
test holdout. Otherwise, it falls back to a deterministic row-order split and
clearly reports that limitation.

For the R monthly model, `ranger` is used when installed. The scripts now cap
parallel work at 12 threads by default so RStudio and Windows stay responsive on
a 32-logical-processor workstation. Lower `max_train_rows` or `n_threads` near
the top of a script if RStudio becomes sluggish.

The R script also trains and compares four model variants:

- `spatial_only`: coordinates, elevation/depth, month
- `spatial_slr`: spatial predictors plus explicit sea-level-rise scenario
- `spatial_slr_zeta_temp`: adds water level and temperature
- `full_discharge_aware`: adds Morgan City discharge, lagged discharge, and
  rolling antecedent discharge

The comparison is saved to `outputs/monthly_salinity_model_comparison.csv`, and
the best variant by RMSE is used for the prediction/error maps.

## V3 Discharge-Plume Emulator

`train_plume_emulator_v3.R` is a separate experiment focused on user-controlled
discharge scenarios. It avoids temperature and model zeta as required user
inputs and trains salinity/plume response from:

- node location: `X`, `Y`, `Z`
- sea-level-rise scenario: `sea_level_rise_m`
- lagged Morgan City discharge
- 25-hour-smoothed lagged Morgan City discharge

Run:

```r
source("Estuary-Emulator/train_plume_emulator_v3.R")
```

The script exports predicted salinity maps for example low/median/high
discharge scenarios under 2025 baseline and 2050 +0.4 m sea-level-rise
conditions. It also writes freshwater-plume summaries at 0.5, 1, 2, 5, and 10
PSU thresholds.

## Run A V3 Scenario Without Training Data

Most users should start here. `run_v3_scenario.R` uses the trained model object
in `models/v3_discharge_plume_model.rds` and does not require the raw MIKE 21
XYZ training files.

Install R packages:

```r
install.packages(c("dplyr", "ggplot2", "readr", "tibble", "ranger", "sf"))
```

Edit the user settings near the top of `run_v3_scenario.R`:

```r
scenario_year <- 2050
sea_level_rise_m <- 0.4
discharge_m3s <- 5437
scenario_name <- "example_2050_high_Q"
```

Run:

```r
source("Estuary-Emulator/run_v3_scenario.R")
```

The script writes:

- `outputs/user_scenarios/<scenario>_predicted_salinity.csv`
- `outputs/user_scenarios/<scenario>_plume_metrics.csv`
- `outputs/user_scenarios/<scenario>_predicted_salinity.png`
- `outputs/user_scenarios/<scenario>_predicted_salinity.geojson` if `sf` is installed

GeoJSON is the preferred public exchange format for QGIS/web-map testing
because it is a single file. Shapefiles are fine for local workflows but require
multiple companion files (`.shp`, `.shx`, `.dbf`, `.prj`, and sometimes `.cpg`).

The trained model file is large. GitHub blocks ordinary repository files larger
than 100 MiB, and `v3_discharge_plume_model.rds` is about 976 MiB. Put the model
in Git LFS or attach it to a GitHub Release, then link it from the release notes
or README.

## Next decisions after data inspection

- Confirm coordinate reference system.
- Confirm node vs element organization.
- Confirm whether each file is a timestep or contains many timesteps.
- Confirm how discharge and tide/sea-level forcing join to each timestep.
- Add bathymetry/elevation if it is separate from the XYZ exports.
- Replace or augment the tabular baseline with a spatial emulator.
