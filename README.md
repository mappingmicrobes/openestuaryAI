# Open Estuary AI: Atchafalaya Salinity Emulator

This repository contains a test release of a discharge-driven salinity emulator
for the Atchafalaya coastal estuary. The goal is to let users run simple
freshwater-discharge and sea-level-rise scenarios without running MIKE 21 or
downloading the raw MIKE 21 training files.

The current release is a minimum viable ESIP testing workflow:

- clone or download this repository
- run one R script
- automatically download the trained emulator model
- generate salinity prediction outputs as CSV, PNG, and GeoJSON

## Quick Start In RStudio

Install packages once:

```r
install.packages(c("dplyr", "ggplot2", "readr", "tibble", "ranger", "sf"))
```

### Option A: Clone The Repository From RStudio

If Git is installed, open RStudio and run:

```r
system("git clone https://github.com/mappingmicrobes/openestuaryAI.git")
setwd("openestuaryAI")
```

Check that the scenario script is present:

```r
list.files()
```

You should see:

```text
run_v3_scenario.R
README.md
GITHUB_RELEASE_CHECKLIST.md
```

### Option B: Download ZIP Instead Of Using Git

If Git is not installed:

1. Go to the GitHub repository:

```text
https://github.com/mappingmicrobes/openestuaryAI
```

2. Click the green **Code** button.
3. Click **Download ZIP**.
4. Unzip the downloaded folder.
5. In RStudio, set the working directory to the unzipped folder:

```r
setwd("path/to/openestuaryAI")
```

## Run The Emulator

Open the scenario script if you want to review or edit the settings first:

```r
file.edit("run_v3_scenario.R")
```

From inside the repository folder, run:

```r
source("run_v3_scenario.R")
```

On the first run, the script downloads the trained model from the GitHub
pre-release. The model is about 976 MB, so the first run can take several
minutes. Later runs reuse the downloaded model and should not download it again.

## Change The Scenario

Open the scenario script in RStudio:

```r
file.edit("run_v3_scenario.R")
```

Edit these lines near the top:

```r
scenario_year <- 2050
sea_level_rise_m <- 0.4
discharge_m3s <- 5437
scenario_name <- "example_2050_high_Q"
```

Example lower-discharge scenario:

```r
scenario_year <- 2050
sea_level_rise_m <- 0.4
discharge_m3s <- 923
scenario_name <- "example_2050_low_Q"
```

Then rerun:

```r
source("run_v3_scenario.R")
```

The model will not download again if it already exists in:

```text
models/v3_discharge_plume_model.rds
```

## Outputs

Scenario outputs are written to:

```text
outputs/user_scenarios/
```

Each run writes:

- `<scenario_name>_predicted_salinity.csv`
- `<scenario_name>_plume_metrics.csv`
- `<scenario_name>_predicted_salinity.png`
- `<scenario_name>_predicted_salinity.geojson` if package `sf` is installed

The GeoJSON file is intended for quick viewing in QGIS and web maps. GeoJSON is
used because it is a single portable file. Shapefiles require multiple companion
files and are easier to break during sharing.

## Model File

The trained model is:

```text
models/v3_discharge_plume_model.rds
```

It is not stored as a normal GitHub repository file because it is about 976 MB.
The script downloads it from the GitHub pre-release:

```text
https://github.com/mappingmicrobes/openestuaryAI/releases/download/v0.1-test-emulator/v3_discharge_plume_model.rds
```

If the automatic download fails, manually download the model from the GitHub
release and place it here:

```text
models/v3_discharge_plume_model.rds
```

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

## Main Files

- `run_v3_scenario.R`: user-facing scenario runner
- `train_plume_emulator_v3.R`: training workflow for users with raw MIKE 21 data
- `diagnose_v3_outputs.R`: validation and diagnostic plotting workflow
- `explore_discharge_salinity_lag.R`: lagged discharge-response exploration
- `GITHUB_RELEASE_CHECKLIST.md`: release packaging notes

## Suggested Feedback

For ESIP testing, useful feedback includes:

- Did the repository download cleanly?
- Did the model download complete?
- Did `source("run_v3_scenario.R")` run without errors?
- Were the scenario settings easy to find and edit?
- Did the outputs open in RStudio and QGIS?
- Is the 976 MB model acceptable, or is a smaller demo model needed?
