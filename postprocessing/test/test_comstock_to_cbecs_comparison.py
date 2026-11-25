# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
#!/usr/bin/env python
# -*- coding: utf-8 -*-

import pytest
import glob

import comstockpostproc.comstock
import comstockpostproc.cbecs
import comstockpostproc.comstock_to_cbecs_comparison
import comstockpostproc.comstock_apportionment
import os


@pytest.mark.skip(reason=(
    "Obsolete: written for the weighting pipeline that 615499514 (2025-08-04) replaced. It passes "
    "reload_from_csv to ComStock and calls add_weights_aportioned_by_stock_estimate and "
    "add_national_scaling_weights, all removed, and its S3 run (com-sdr lbl_df_geb_measures_10k_7) no "
    "longer exists. It checked that the ComStock-to-CBECS comparison writes its figures (over 250)."))
def test_cbecs_plot_generation():
    comstock = comstockpostproc.comstock.ComStock(
        s3_base_dir='com-sdr',  # If run not on S3, download results_up**.parquet manually
        comstock_run_name='lbl_df_geb_measures_10k_7',  # Name of the run on S3
        comstock_run_version='lbl_df_geb_measures_10k_7',  # Use whatever you want to see in plot and folder names
        comstock_year=2018,  # Typically don't change this
        athena_table_name=None,  # Typically don't change this
        truth_data_version='v01',  # Typically don't change this
        buildstock_csv_name='buildstock.csv',  # Download buildstock.csv manually
        acceptable_failure_percentage=0.10,  # Can increase this when testing and high failure are OK
        drop_failed_runs=True,  # False if you want to evaluate which runs failed in raw output data
        color_hex='#0072B2',  # Color used to represent this run in plots
        skip_missing_columns=True,  # False if you want to ensure you have all data specified for export
        reload_from_csv=False, # True if CSV already made and want faster reload times
        include_upgrades=False,  # False if not looking at upgrades
        upgrade_ids_to_skip=[]  # Use ['01', '03'] etc. to exclude certain upgrades
        )

    # Scale ComStock to CBECS 2012 AND remove non-ComStock buildings from CBECS
    cbecs = comstockpostproc.cbecs.CBECS(
        cbecs_year=2012,
        truth_data_version='v01',
        color_hex='#009E73',
        reload_from_csv=False
        )
    
    # Stock Estimation for Apportionment:
    stock_estimate = comstockpostproc.comstock_apportionment.Apportion(
        stock_estimation_version='2024R2',  # Only updated when a new stock estimate is published
        truth_data_version='v01',  # Typically don't change this
        reload_from_cache=False
    )


    # Scale ComStock runs to the 'truth data' from StockE V3 estimates using bucket-based apportionment
    comstock.add_weights_aportioned_by_stock_estimate(apportionment=stock_estimate)

    comstock.add_national_scaling_weights(cbecs, remove_non_comstock_bldg_types_from_cbecs=False)


    # Compare one or more ComStock runs to one another and to CBECS
    comp = comstockpostproc.ComStockToCBECSComparison(cbecs_list=[cbecs], comstock_list=[comstock], upgrade_id=0, make_comparison_plots=True)
    # Export the comparison data to wide format for Tableau

    # Check that a smattering of plots do exist
    n_plots = len(glob.glob(f'{comp.output_dir}/**/*.jpg'))
    assert n_plots > 250, 'Expected at least 250 plots for a comparison'
