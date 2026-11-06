# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
#!/usr/bin/env python
# -*- coding: utf-8 -*-

import math

import pytest
import logging
import polars as pl

import comstockpostproc.cbecs

def _run_cbecs_checks(cbecs, eia_sqft, eia_site_electricity_TBtu, eia_site_natural_gas_TBtu):
    """Run  published-tabulation and self-consistency checks used for CBECS implementation."""

    # Check the total square footage against published EIA tabulations
    weighted_area_col = cbecs.col_name_to_weighted(cbecs.FLR_AREA)
    total_sqft = cbecs.data.select(weighted_area_col).sum().collect().item()
    assert total_sqft == pytest.approx(eia_sqft, rel=0.01)

    # Check total energy consumption against published EIA tabulations
    elec_col = cbecs.col_name_to_weighted(cbecs.ANN_TOT_ELEC_KBTU, 'tbtu')
    site_electricity_TBtu = cbecs.data.select(elec_col).sum().collect().item()
    assert site_electricity_TBtu == pytest.approx(eia_site_electricity_TBtu, rel=0.01)

    gas_col = cbecs.col_name_to_weighted(cbecs.ANN_TOT_GAS_KBTU, 'tbtu')
    site_natural_gas_TBtu = cbecs.data.select(gas_col).sum().collect().item()
    assert site_natural_gas_TBtu == pytest.approx(eia_site_natural_gas_TBtu, rel=0.01)

    # Check for self-consistency in weighted and unweighted energy
    engy_tol = 0.00001
    columns = cbecs.data.collect_schema().names()

    # Pairs of total column and list of corresponding enduse columns
    tot_col_enduse_cols = [
        [cbecs.ANN_TOT_GAS_KBTU, cbecs.COLS_GAS_ENDUSE],  # Total natural gas vs. sum of end uses
        [cbecs.ANN_TOT_ELEC_KBTU, cbecs.COLS_ELEC_ENDUSE],  # Total electricity vs. sum of end uses
        [cbecs.ANN_TOT_ENGY_KBTU, [cbecs.ANN_TOT_ELEC_KBTU,  # Total energy vs. sum of all fuels
                                        cbecs.ANN_TOT_GAS_KBTU,
                                        cbecs.ANN_TOT_FUELOIL_KBTU,
                                        cbecs.ANN_TOT_PROPANE_KBTU,
                                        cbecs.ANN_TOT_DISTHTG_KBTU,
                                        cbecs.ANN_TOT_DISTCLG_KBTU]]
    ]

    for tot_col, enduse_cols in tot_col_enduse_cols:
        # Unweighted
        sum_tot_col = cbecs.data.select(tot_col).sum().collect().item()
        sum_enduses = sum(cbecs.data.select(col).sum().collect().item()
                          for col in enduse_cols if col in columns)
        assert sum_enduses == pytest.approx(sum_tot_col, rel=engy_tol), f'Error in unweighted {tot_col}'
        # Weighted
        wtd_tot_col = cbecs.col_name_to_weighted(tot_col, cbecs.weighted_energy_units)
        wtd_enduse_cols = [cbecs.col_name_to_weighted(c, cbecs.weighted_energy_units)
                          for c in enduse_cols if c in columns]
        sum_tot_col = cbecs.data.select(wtd_tot_col).sum().collect().item()
        sum_enduses = sum(cbecs.data.select(col).sum().collect().item()
                          for col in wtd_enduse_cols if col in columns)
        assert sum_enduses == pytest.approx(sum_tot_col, rel=engy_tol), f'Error in weighted {tot_col}'

def test_cbecs_2012(caplog):
    caplog.set_level(logging.INFO)
    cbecs = comstockpostproc.cbecs.CBECS(
        cbecs_year=2012,
        truth_data_version='v01',
        color_hex='#009E73',
        reload_from_csv=False
        )

    # Published EIA tabulations:
    # https://www.eia.gov/consumption/commercial/data/2012/bc/cfm/b7.php
    # https://www.eia.gov/consumption/commercial/data/2012/c&e/cfm/c1.php
    _run_cbecs_checks(
        cbecs,
        eia_sqft=87_093_000_000,
        eia_site_electricity_TBtu=4_241,
        eia_site_natural_gas_TBtu=2_248,
    )

    cbecs.export_to_csv_wide()


def test_cbecs_2018(caplog):
    caplog.set_level(logging.INFO)
    cbecs = comstockpostproc.cbecs.CBECS(
        cbecs_year=2018,
        truth_data_version='v01',
        color_hex='#16f0b4',
        reload_from_csv=False
        )

    # Published EIA tabulations:
    # https://www.eia.gov/consumption/commercial/data/2018/bc/html/b7.php
    # https://www.eia.gov/consumption/commercial/data/2018/ce/xls/c1.xlsx
    _run_cbecs_checks(
        cbecs,
        eia_sqft=96_423_000_000,
        eia_site_electricity_TBtu=4_081,
        eia_site_natural_gas_TBtu=2_300,
    )

    cbecs.export_to_csv_wide()
