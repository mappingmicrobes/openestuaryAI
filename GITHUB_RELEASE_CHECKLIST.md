# GitHub Release Checklist For ESIP Testing

This checklist separates the lightweight public emulator package from the large
MIKE 21 training archive.

## Upload To GitHub

Commit these files to the repository:

- `README.md`
- `run_v3_scenario.R`
- `diagnose_v3_outputs.R`
- `train_plume_emulator_v3.R`
- `explore_discharge_salinity_lag.R`
- `requirements.txt`
- `outputs/v3_discharge_plume_metrics.csv`
- `outputs/v3_discharge_plume_area_metrics.csv`
- `outputs/v3_discharge_plume_scenario_inputs.csv`
- `outputs/v3_publication_truth_vs_prediction.png`
- `outputs/v3_publication_error_histogram.png`
- `outputs/v3_publication_morgan_city_discharge.png`
- `outputs/v3_publication_prediction_elements_with_validation_points.png`

## Large Model Artifact

The trained emulator is:

- `models/v3_discharge_plume_model.rds`

This file is about 976 MB, so it is too large for a normal GitHub commit.
Use one of these options:

- Git LFS, if the project repository supports it.
- A GitHub Release asset.
- Zenodo, HydroShare, OSF, or another public data repository, then link it in
  the README.

ESIP users need this file to run `run_v3_scenario.R` without retraining.

## Do Not Upload Raw Training Files

Do not commit:

- raw MIKE 21 `.xyz` exports
- `.dfsu`, `.dfs1`, `.dxfm`, or other model binary files
- local OneDrive or Google Drive paths
- temporary RStudio files
- huge validation/debug CSVs unless intentionally released

Users only need the trained `.rds` model and the scenario script to make
predictions.

## GeoJSON Vs Shapefile

For public testing, GeoJSON is easier than shapefiles because it is one file and
loads directly in QGIS, ArcGIS Online, Leaflet, and most web maps.

Shapefiles are still fine for local scientific workflows, but a shapefile is
really a bundle of files (`.shp`, `.shx`, `.dbf`, `.prj`, sometimes `.cpg`).
If any companion file is missing, the layer can break or lose projection
information.

The new `run_v3_scenario.R` writes:

- scenario predictions as CSV
- plume threshold metrics as CSV
- a PNG map
- a GeoJSON point layer if package `sf` is installed

## Minimal ESIP Test Workflow

1. Download or clone the repository.
2. Place `v3_discharge_plume_model.rds` in `Estuary-Emulator/models/`.
3. In RStudio, install packages:

```r
install.packages(c("dplyr", "ggplot2", "readr", "tibble", "ranger", "sf"))
```

4. Edit the top of `run_v3_scenario.R`:

```r
scenario_year <- 2050
sea_level_rise_m <- 0.4
discharge_m3s <- 5437
scenario_name <- "example_2050_high_Q"
```

5. Run:

```r
source("Estuary-Emulator/run_v3_scenario.R")
```

6. Open the outputs in:

- RStudio plot viewer
- QGIS using the GeoJSON
- spreadsheet/GIS software using the CSV

## Current Model Limits To State Clearly

- V3 is trained on September-November 2025 and 2050 MIKE 21 outputs.
- December is excluded until the corrected boundary/model run is available.
- The 2050 scenario currently represents +0.4 m sea-level rise.
- The model is safest at `sea_level_rise_m = 0.0` and `0.4`.
- Intermediate SLR values are interpolation.
- Larger SLR values are extrapolation and should be labeled experimental.
- A steady discharge scenario sets all lagged discharge predictors to the same
  user-provided discharge value.
