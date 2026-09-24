# -*- coding: utf-8 -*-

"""ArcGIS Pro toolbox for the Open Estuary AI salinity emulator."""

import os
import subprocess
import tempfile

import arcpy


class Toolbox(object):
    def __init__(self):
        self.label = "Open Estuary AI"
        self.alias = "openestuaryai"
        self.tools = [AtchafalayaSalinityEmulator]


class AtchafalayaSalinityEmulator(object):
    def __init__(self):
        self.label = "Atchafalaya Salinity Emulator"
        self.description = "Run the V3 R salinity emulator and create an ArcGIS point feature class."
        self.canRunInBackground = False

    def getParameterInfo(self):
        sea_level = arcpy.Parameter(
            displayName="Sea-level scenario",
            name="sea_level_scenario",
            datatype="GPString",
            parameterType="Required",
            direction="Input",
        )
        sea_level.filter.type = "ValueList"
        sea_level.filter.list = [
            "Baseline / 2025-style = 0.0 m",
            "2050 SLR = +0.4 m",
        ]
        sea_level.value = "2050 SLR = +0.4 m"

        discharge = arcpy.Parameter(
            displayName="Morgan City discharge (m3/s)",
            name="discharge_m3s",
            datatype="GPDouble",
            parameterType="Required",
            direction="Input",
        )
        discharge.value = 5437

        scenario_name = arcpy.Parameter(
            displayName="Scenario name",
            name="scenario_name",
            datatype="GPString",
            parameterType="Required",
            direction="Input",
        )
        scenario_name.value = "example_2050_high_Q"

        clamp_salinity = arcpy.Parameter(
            displayName="Clamp salinity to 0-35 PSU",
            name="clamp_salinity",
            datatype="GPBoolean",
            parameterType="Required",
            direction="Input",
        )
        clamp_salinity.value = True

        output_fc = arcpy.Parameter(
            displayName="Output predicted salinity points",
            name="output_feature_class",
            datatype="DEFeatureClass",
            parameterType="Required",
            direction="Output",
        )

        plume_metrics = arcpy.Parameter(
            displayName="Output plume metrics CSV",
            name="plume_metrics_csv",
            datatype="DEFile",
            parameterType="Optional",
            direction="Output",
        )

        rscript = arcpy.Parameter(
            displayName="Rscript.exe path",
            name="rscript_path",
            datatype="DEFile",
            parameterType="Optional",
            direction="Input",
        )
        rscript.value = r"C:\Program Files\R\R-4.4.2\bin\Rscript.exe"

        return [sea_level, discharge, scenario_name, clamp_salinity, output_fc, plume_metrics, rscript]

    def isLicensed(self):
        return True

    def updateParameters(self, parameters):
        if not parameters[4].altered:
            workspace = arcpy.env.workspace or arcpy.env.scratchGDB
            parameters[4].value = os.path.join(workspace, "Predicted_Salinity")
        if not parameters[5].altered:
            parameters[5].value = os.path.join(
                tempfile.gettempdir(),
                "openestuaryai_plume_metrics.csv",
            )
        return

    def execute(self, parameters, messages):
        toolbox_dir = os.path.dirname(__file__)
        r_script = os.path.join(toolbox_dir, "run_v3_scenario_arcgis.R")
        rscript = parameters[6].valueAsText or r"C:\Program Files\R\R-4.4.2\bin\Rscript.exe"

        if not os.path.exists(rscript):
            raise arcpy.ExecuteError("Rscript.exe was not found: {0}".format(rscript))
        if not os.path.exists(r_script):
            raise arcpy.ExecuteError("R runner script was not found: {0}".format(r_script))

        output_fc = parameters[4].valueAsText
        plume_csv = parameters[5].valueAsText
        temp_csv = os.path.join(
            tempfile.gettempdir(),
            "openestuaryai_{0}_predicted_salinity.csv".format(os.getpid()),
        )

        cmd = [
            rscript,
            r_script,
            "--sea-level-scenario",
            parameters[0].valueAsText,
            "--discharge-m3s",
            parameters[1].valueAsText,
            "--scenario-name",
            parameters[2].valueAsText,
            "--clamp-salinity",
            str(bool(parameters[3].value)).lower(),
            "--output-csv",
            temp_csv,
        ]
        if plume_csv:
            cmd.extend(["--plume-metrics-table", plume_csv])

        arcpy.AddMessage("Running R salinity emulator...")
        process = subprocess.run(
            cmd,
            cwd=toolbox_dir,
            capture_output=True,
            text=True,
            shell=False,
        )
        if process.stdout:
            arcpy.AddMessage(process.stdout)
        if process.stderr:
            arcpy.AddMessage(process.stderr)
        if process.returncode != 0:
            raise arcpy.ExecuteError("R salinity emulator failed.")
        if not os.path.exists(temp_csv):
            raise arcpy.ExecuteError("R completed but did not create the prediction CSV.")

        arcpy.AddMessage("Creating point feature class...")
        spatial_reference = arcpy.SpatialReference(32615)
        arcpy.management.XYTableToPoint(
            temp_csv,
            output_fc,
            "X",
            "Y",
            None,
            spatial_reference,
        )

        arcpy.SetParameterAsText(4, output_fc)
        arcpy.AddMessage("Created predicted salinity points: {0}".format(output_fc))
