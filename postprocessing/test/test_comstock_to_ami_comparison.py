# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

#!/usr/bin/env python
# -*- coding: utf-8 -*-

import pytest
import logging

import comstockpostproc.comstock
import comstockpostproc.ami
import comstockpostproc.comstock_to_ami_comparison
import comstockpostproc.cbecs


@pytest.mark.skip(reason=(
    "Obsolete: written for the weighting pipeline that 615499514 (2025-08-04) replaced. It passes "
    "reload_from_csv to ComStock and calls add_national_scaling_weights and ComStock.export_to_csv_wide, "
    "all removed, and its S3 run (eulp comstock_core/ami_comparison) no longer exists. It checked that "
    "the ComStock-to-AMI comparison (used by compare_comstock_to_ami) runs and makes its plots."))
def test_ami_plot_generation(caplog):
    caplog.set_level(logging.INFO)
    # ComStock
    comstock = comstockpostproc.comstock.ComStock(
        s3_base_dir='eulp/comstock_core',
        comstock_run_name='ami_comparison',
        comstock_run_version='ami_comparison',
        comstock_year=2018,
        truth_data_version='v01',
        buildstock_csv_name='buildstock.csv',
        acceptable_failure_percentage=0.9,
        drop_failed_runs=True,
        color_hex='#0072B2',
        skip_missing_columns=True,
        athena_table_name='ami_comparison',
        reload_from_csv=False,
        include_upgrades=False
        )

    # CBECS
    cbecs = comstockpostproc.cbecs.CBECS(
        cbecs_year = 2018,
        truth_data_version='v01',
        color_hex='#009E73',
        reload_from_csv=False
        )

    # Scale ComStock run to CBECS 2018 AND remove non-ComStock buildings from CBECS
    # This is how weights in the models are set to represent national energy consumption
    comstock.add_national_scaling_weights(cbecs, remove_non_comstock_bldg_types_from_cbecs=True)

    # Export CBECS and ComStock data to wide and long formats for Tableau and to skip processing later
    cbecs.export_to_csv_wide()  # May comment this out after run once
    comstock.export_to_csv_wide()  # May comment this out after run once

    # AMI
    ami = comstockpostproc.ami.AMI(
        truth_data_version='v01',
        reload_from_csv=False
        )
    comstock.download_timeseries_data_for_ami_comparison(ami, reload_from_csv=False, save_individual_regions=False)

    # comparison
    comparison = comstockpostproc.comstock_to_ami_comparison.ComStockToAMIComparison(comstock, ami, make_comparison_plots=True)
    comparison.export_plot_data_to_csv_wide()
