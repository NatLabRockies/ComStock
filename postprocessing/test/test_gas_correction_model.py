# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
#!/usr/bin/env python
# -*- coding: utf-8 -*-

import pytest
import pandas as pd
import polars as pl

import comstockpostproc.comstock
import comstockpostproc.cbecs


@pytest.mark.skip(reason=(
    "Obsolete: written for the weighting pipeline that 615499514 (2025-08-04) replaced. It passes "
    "reload_from_csv to ComStock, calls add_national_scaling_weights (removed) and treats ComStock's "
    "data as an eager pandas-style frame (polars groupby). It checked that "
    "correct_comstock_gas_to_match_cbecs leaves electricity unchanged, changes total energy, and makes "
    "weighted gas end uses match CBECS by building type and census division."))
def test_gas_correction_model():
    comstock = comstockpostproc.comstock.ComStock(
        s3_base_dir='comstock-core/test',  # If run not on S3, download results_up**.parquet manually
        comstock_run_name='com_os340_stds_030_10k_test_1',  # Name of the run on S3
        comstock_run_version='com_os340_stds_030_10k_test_1',  # Use whatever you want to see in plot and folder names
        comstock_year=2018,  # Typically don't change this
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

    # Read a full ComStock from OEDI
    comstock_oedi_path = '/'.join([
          's3://oedi-data-lake',
          'nrel-pds-building-stock',
          'end-use-load-profiles-for-us-building-stock',
          '2023',
          'comstock_amy2018_release_1',
          'metadata_and_annual_results',
          'national',
          'parquet',
          'baseline_metadata_and_annual_results.parquet'])
    comstock_full_run_data = pl.read_parquet(comstock_oedi_path)

    # Add units back to energy consumption column names (not present on OEDI)
    crnms = {}  # Column renames
    for col in (comstock.COLS_TOT_ANN_ENGY + comstock.COLS_ENDUSE_ANN_ENGY):
        og_col = col.replace(f'..kwh', '')
        if og_col in comstock_full_run_data:
            crnms[og_col] = col
    comstock_full_run_data = comstock_full_run_data.rename(crnms)

    # Adds energy column added after publication
    comstock_full_run_data = comstock_full_run_data.with_columns([
        pl.lit(0.0).alias('out.district_heating.interior_equipment.energy_consumption..kwh')
    ])

    # Replace test run data with full run data from OEDI
    # This is just for testing because we aren't keeping full
    # runs on S3 RESBLDG permanently
    comstock.data = comstock_full_run_data

    # Scale ComStock to CBECS 2012 AND remove non-ComStock buildings from CBECS
    cbecs = comstockpostproc.cbecs.CBECS(
        cbecs_year=2012,
        truth_data_version='v01',
        color_hex='#009E73',
        reload_from_csv=False
        )

    comstock.add_national_scaling_weights(cbecs, remove_non_comstock_bldg_types_from_cbecs=True)

    engy_tol = 0.001

    # Get total electricity and total energy consumption before gas correction
    cstock_elec_before = comstock.data[comstock.ANN_TOT_ELEC_KBTU].sum()
    cstock_tot_before = comstock.data[comstock.ANN_TOT_ENGY_KBTU].sum()

    # Apply gas correction model
    comstock.correct_comstock_gas_to_match_cbecs(cbecs)

    # Check that electricity consumption hasn't changed
    cstock_elec_after = comstock.data[comstock.ANN_TOT_ELEC_KBTU].sum()
    assert cstock_elec_after == pytest.approx(cstock_elec_before, rel=engy_tol)

    # Check that total energy consumption HAS changed
    cstock_tot_after = comstock.data[comstock.ANN_TOT_ENGY_KBTU].sum()
    assert cstock_tot_after != pytest.approx(cstock_tot_before, rel=engy_tol)

    # Check that ComStock and CBECS natural gas end use totals match
    # by building type and census division after correction is applied
    for gas_enduse_col in comstock.COLS_GAS_ENDUSE:
        # IGNORE Natural Gas Cooling, which isn't modeled in ComStock
        if gas_enduse_col == comstock.ANN_GAS_COOL_KBTU:
            continue

        wtd_enduse_col = comstock.col_name_to_weighted(gas_enduse_col, comstock.weighted_energy_units)

        # Sum by building type and census division
        cstock_gas = comstock.data.groupby([comstock.BLDG_TYPE, comstock.CEN_DIV]).agg(pl.col(wtd_enduse_col).sum())
        cstock_gas = cstock_gas.to_pandas().set_index([comstock.BLDG_TYPE, comstock.CEN_DIV])
        cstock_gas.fillna(0.0, inplace=True)

        cbecs_gas = cbecs.data.groupby([cbecs.BLDG_TYPE, cbecs.CEN_DIV])[wtd_enduse_col].sum()

        # Merge and compare totals
        both_gas = pd.merge(cstock_gas, cbecs_gas, how='outer', left_index=True, right_index=True, suffixes=('_cstock', '_cbecs'))
        for (bldg_type, cdiv), vals in both_gas.iterrows():
            cstock_val = vals[0]
            cbecs_val = vals[1]
            assert cstock_val == pytest.approx(cbecs_val, rel=engy_tol),\
                f'{bldg_type} {cdiv} {wtd_enduse_col}: enduse ComStock = {cstock_val} but CBECS = {cbecs_val}'
