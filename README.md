# Atchafalaya Estuary Emulator
# Open Estuary AI: Atchafalaya Salinity Emulator

This folder contains the first minimum viable emulator pipeline for the ESIP
Open Estuary AI project.
This repository contains a test release of a discharge-driven salinity emulator
for the Atchafalaya coastal estuary. The goal is to let users run simple
freshwater-discharge and sea-level-rise scenarios without running MIKE 21 or
downloading the raw MIKE 21 training files.

The initial target is intentionally narrow:
The current release is a minimum viable ESIP testing workflow:

Predict a withheld Atchafalaya MIKE 21 salinity field and generate truth,
prediction, and error maps.
- clone or download this repository
- run one R script
- automatically download the trained emulator model
- generate salinity prediction outputs as CSV, PNG, and GeoJSON

## Expected inputs
## Quick Start In RStudio

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
Install packages once:

## Commands
```r
install.packages(c("dplyr", "ggplot2", "readr", "tibble", "ranger", "sf"))
```

Inspect files:
Download the repository with Git:

```powershell
python .\atchafalaya_emulator.py inspect --data-dir .\data
```r
system("git clone https://github.com/mappingmicrobes/openestuaryAI.git")
setwd("openestuaryAI")
```

Train a baseline salinity emulator:
Or download the repository ZIP from GitHub, unzip it, and set the working
directory to the unzipped folder:

```powershell
python .\atchafalaya_emulator.py train `
  --data-dir .\data `
  --target salinity `
  --model-out .\models\atchafalaya_salinity_baseline.joblib `
  --fig-out .\outputs\salinity_truth_prediction_error.png
```r
setwd("path/to/openestuaryAI")
```

Train the RStudio monthly discharge-aware baseline:
Run the emulator:

```r
source("Estuary-Emulator/train_monthly_salinity_emulator.R")
source("run_v3_scenario.R")
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
On the first run, the script downloads the trained model from the GitHub
pre-release. The model is about 976 MB, so the first run can take several
minutes. Later runs reuse the downloaded model and should not download it again.

## Baseline model
## Change The Scenario

The first model is a conservative scikit-learn baseline. It is meant to prove
the end-to-end data path before moving to a U-Net, Fourier Neural Operator, or
other spatial neural emulator.
Open the scenario script:

The baseline uses available numeric predictors except the target variable. If a
timestep-like column exists, it uses the latest 20 percent of timesteps as the
test holdout. Otherwise, it falls back to a deterministic row-order split and
clearly reports that limitation.
```r
file.edit("run_v3_scenario.R")
```

For the R monthly model, `ranger` is used when installed. The scripts now cap
parallel work at 12 threads by default so RStudio and Windows stay responsive on
a 32-logical-processor workstation. Lower `max_train_rows` or `n_threads` near
the top of a script if RStudio becomes sluggish.
Edit these lines near the top:

The R script also trains and compares four model variants:
```r
scenario_year <- 2050
sea_level_rise_m <- 0.4
discharge_m3s <- 5437
scenario_name <- "example_2050_high_Q"
```

- `spatial_only`: coordinates, elevation/depth, month
- `spatial_slr`: spatial predictors plus explicit sea-level-rise scenario
- `spatial_slr_zeta_temp`: adds water level and temperature
- `full_discharge_aware`: adds Morgan City discharge, lagged discharge, and
  rolling antecedent discharge
Example lower-discharge scenario:

The comparison is saved to `outputs/monthly_salinity_model_comparison.csv`, and
the best variant by RMSE is used for the prediction/error maps.
```r
scenario_year <- 2050
sea_level_rise_m <- 0.4
discharge_m3s <- 923
scenario_name <- "example_2050_low_Q"
```

## V3 Discharge-Plume Emulator
Then rerun:

`train_plume_emulator_v3.R` is a separate experiment focused on user-controlled
discharge scenarios. It avoids temperature and model zeta as required user
inputs and trains salinity/plume response from:
```r
source("run_v3_scenario.R")
```

- node location: `X`, `Y`, `Z`
- sea-level-rise scenario: `sea_level_rise_m`
- lagged Morgan City discharge
- 25-hour-smoothed lagged Morgan City discharge
## Outputs

Run:
Scenario outputs are written to:

```r
source("Estuary-Emulator/train_plume_emulator_v3.R")
```text
outputs/user_scenarios/
```

The script exports predicted salinity maps for example low/median/high
discharge scenarios under 2025 baseline and 2050 +0.4 m sea-level-rise
conditions. It also writes freshwater-plume summaries at 0.5, 1, 2, 5, and 10
PSU thresholds.
Each run writes:

## Run A V3 Scenario Without Training Data
- `<scenario_name>_predicted_salinity.csv`
- `<scenario_name>_plume_metrics.csv`
- `<scenario_name>_predicted_salinity.png`
- `<scenario_name>_predicted_salinity.geojson` if package `sf` is installed

Most users should start here. `run_v3_scenario.R` uses the trained model object
in `models/v3_discharge_plume_model.rds` and does not require the raw MIKE 21
XYZ training files. If the model file is missing, the script attempts to
download it from the GitHub prerelease.
The GeoJSON file is intended for quick viewing in QGIS and web maps. GeoJSON is
used because it is a single portable file. Shapefiles require multiple companion
files and are easier to break during sharing.

Install R packages:
## Model File

The trained model is:

```r
install.packages(c("dplyr", "ggplot2", "readr", "tibble", "ranger", "sf"))
```text
models/v3_discharge_plume_model.rds
```

Edit the user settings near the top of `run_v3_scenario.R`:
It is not stored as a normal GitHub repository file because it is about 976 MB.
The script downloads it from the GitHub pre-release:

```r
scenario_year <- 2050
sea_level_rise_m <- 0.4
discharge_m3s <- 5437
scenario_name <- "example_2050_high_Q"
```text
https://github.com/mappingmicrobes/openestuaryAI/releases/download/v0.1-test-emulator/v3_discharge_plume_model.rds
```

Run from the repository folder:
If the automatic download fails, manually download the model from the GitHub
release and place it here:

```r
source("run_v3_scenario.R")
```text
models/v3_discharge_plume_model.rds
```

The script writes:
## What Users Do Not Need

Users do not need:

- raw MIKE 21 `.xyz` files
- `.dfsu`, `.dfs1`, or `.dxfm` files
- training data
- MIKE 21
- Python
- Git, if they use GitHub's Download ZIP button

## Current Model Scope

This is a test emulator, not a final operational forecast model.

Current training scope:

- Atchafalaya/Gulf MIKE 21 salinity outputs
- September-November 2025 and 2050 scenarios
- December excluded pending corrected boundary/model run
- 2050 scenario represents +0.4 m sea-level rise
- Morgan City discharge used as the freshwater forcing signal

Supported sea-level-rise inputs:

- `outputs/user_scenarios/<scenario>_predicted_salinity.csv`
- `outputs/user_scenarios/<scenario>_plume_metrics.csv`
- `outputs/user_scenarios/<scenario>_predicted_salinity.png`
- `outputs/user_scenarios/<scenario>_predicted_salinity.geojson` if `sf` is installed
- `sea_level_rise_m <- 0.0` for 2025-style baseline
- `sea_level_rise_m <- 0.4` for the 2050 SLR scenario

Intermediate values are interpolation. Larger values are extrapolation and
should be treated as experimental.

## Validation Summary

The current V3 random held-out validation metrics are:

- MAE: about 0.32 PSU
- RMSE: about 0.69 PSU
- R2: about 0.997

These metrics show the emulator can reproduce held-out sampled MIKE 21 rows.
Future validation should include stricter time-based tests, such as training on
September-October and testing on November.

GeoJSON is the preferred public exchange format for QGIS/web-map testing
because it is a single file. Shapefiles are fine for local workflows but require
multiple companion files (`.shp`, `.shx`, `.dbf`, `.prj`, and sometimes `.cpg`).
## Main Files

The trained model file is large. GitHub blocks ordinary repository files larger
than 100 MiB, and `v3_discharge_plume_model.rds` is about 976 MiB. Put the model
in Git LFS or attach it to a GitHub Release, then link it from the release notes
or README. The current test script expects the prerelease URL:
- `run_v3_scenario.R`: user-facing scenario runner
- `train_plume_emulator_v3.R`: training workflow for users with raw MIKE 21 data
- `diagnose_v3_outputs.R`: validation and diagnostic plotting workflow
- `explore_discharge_salinity_lag.R`: lagged discharge-response exploration
- `GITHUB_RELEASE_CHECKLIST.md`: release packaging notes

```text
https://github.com/mappingmicrobes/openestuaryAI/releases/download/v0.1-test-emulator/v3_discharge_plume_model.rds
```
## Suggested Feedback

## Next decisions after data inspection
For ESIP testing, useful feedback includes:

- Confirm coordinate reference system.
- Confirm node vs element organization.
- Confirm whether each file is a timestep or contains many timesteps.
- Confirm how discharge and tide/sea-level forcing join to each timestep.
- Add bathymetry/elevation if it is separate from the XYZ exports.
- Replace or augment the tabular baseline with a spatial emulator.
- Did the repository download cleanly?
- Did the model download complete?
- Did `source("run_v3_scenario.R")` run without errors?
- Were the scenario settings easy to find and edit?
- Did the outputs open in RStudio and QGIS?
- Is the 976 MB model acceptable, or is a smaller demo model needed?
