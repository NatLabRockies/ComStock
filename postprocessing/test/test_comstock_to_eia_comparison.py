# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

#!/usr/bin/env python
# -*- coding: utf-8 -*-

import pytest

import comstockpostproc.comstock
import comstockpostproc.eia
import comstockpostproc.comstock_to_eia_comparison
import comstockpostproc.cbecs


@pytest.mark.skip(reason=(
    "Obsolete: written for the weighting pipeline that 615499514 (2025-08-04) replaced. It passes "
    "reload_from_csv to ComStock and calls add_national_scaling_weights and ComStock.export_to_csv_wide, "
    "all removed, and its S3 run (eulp euss_com/baseline_data_10k) no longer exists. It checked that the "
    "ComStock-to-EIA comparison runs and writes its plots and wide csv."))
def test_eia_plot_generation():
    # ComStock
    comstock = comstockpostproc.comstock.ComStock(
        s3_base_dir='eulp/euss_com',
        comstock_run_name='baseline_data_10k',
        comstock_run_version='baseline_data_10k',
        comstock_year=2018,
        truth_data_version='v01',
        buildstock_csv_name='buildstock.csv',
        acceptable_failure_percentage=0.9,
        drop_failed_runs=True,
        color_hex='#0072B2',
        skip_missing_columns=True,
        athena_table_name='baseline_data_10k',
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

    # EIA
    eia = comstockpostproc.eia.EIA(
        year=2018,
        truth_data_version="v01",
        reload_from_csv=False
    )

    # save cbecs csv
    cbecs.export_to_csv_wide()
    
    # Scale ComStock run to CBECS 2018 AND remove non-ComStock buildings from CBECS
    comstock.add_national_scaling_weights(cbecs, remove_non_comstock_bldg_types_from_cbecs=True)
    comstock.export_to_csv_wide()

    # Make a comparison by passing in a list of EIA and ComStock runs to compare
    eia_list = [eia]
    comstock_list = [comstock]
    comp = comstockpostproc.comstock_to_eia_comparison.ComStockToEIAComparison(eia_list, comstock_list, make_comparison_plots=True)
    comp.monthly_data
    comp.export_to_csv_wide()

    