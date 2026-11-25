# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
#!/usr/bin/env python
# -*- coding: utf-8 -*-

import os
import pytest
import logging
import polars as pl

import comstockpostproc.comstock
import comstockpostproc.eia
import comstockpostproc.comstock_to_eia_comparison

@pytest.mark.skip(reason=(
    "Obsolete: written for the weighting pipeline that 615499514 (2025-08-04) replaced. It passes "
    "reload_from_csv to ComStock and calls add_national_scaling_weights, both removed, and its S3 run "
    "(com-sdr lbl_df_geb_measures_10k_7) no longer exists. It checked that the ComStock-to-EIA "
    "comparison writes its emissions figures for electricity, fuel oil, natural gas and propane."))
def test_eia_emissions():
    comstock = comstockpostproc.comstock.ComStock(
        s3_base_dir='com-sdr',  # If run not on S3, download results_up**.parquet manually
        comstock_run_name='lbl_df_geb_measures_10k_7',  # Name of the run on S3
        comstock_run_version='lbl_df_geb_measures_10k_7',  # Use whatever you want to see in plot and folder names
        comstock_year=2018,  # Typically don't change this
        athena_table_name=None,  # Typically don't change this
        truth_data_version='v01',  # Typically don't change this
        buildstock_csv_name='buildstock.csv',
        acceptable_failure_percentage=0.9,
        drop_failed_runs=True,
        color_hex='#0072B2',
        skip_missing_columns=True,
        reload_from_csv=False,
        include_upgrades=False
        )

    # CBECS
    cbecs = comstockpostproc.cbecs.CBECS(
        cbecs_year = 2018,
        truth_data_version='v01',
        color_hex='#009E73',
        reload_from_csv=False, # True since CSV already made and want faster reload times
        )

    eia = comstockpostproc.eia.EIA(
        year=2018,
        truth_data_version='v01',
        color_hex='#009E73',
        reload_from_csv=False,
    )

    # save cbecs csv
    cbecs.export_to_csv_wide()

    # Scale ComStock run to CBECS 2018 AND remove non-ComStock buildings from CBECS
    comstock.add_national_scaling_weights(cbecs, remove_non_comstock_bldg_types_from_cbecs=True)
    comstock.data = comstock.add_weighted_area_energy_savings_columns(comstock.data)
    
    assert isinstance(comstock.data, pl.LazyFrame)
    print(f"columns in comstock is {comstock.data.schema}")

    eia_list = [eia]
    comstock_list = [comstock]
    comp = comstockpostproc.comstock_to_eia_comparison.ComStockToEIAComparison(comstock_list, eia_list, make_comparison_plots=True)

    assert os.path.exists(os.path.join(comp.output_dir, 'emissions_electricity_egrid_2021_subregion.jpg'))
    assert os.path.exists(os.path.join(comp.output_dir, 'emissions_fuel_oil.jpg'))
    assert os.path.exists(os.path.join(comp.output_dir, 'emissions_natural_gas.jpg'))
    assert os.path.exists(os.path.join(comp.output_dir, 'emissions_propane.jpg'))
