# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Units in the timeseries views ComStock.create_views writes. No Athena.

A crawled run's timeseries table stores electricity in kWh and the other fuels in
kBtu (some exports in therms or MBtu); its view renames each column to the
published spelling and converts it to kWh. The arithmetic is run here on an
in-memory SQLite table through the same SELECT list create_views uses.
"""

import pytest
import sqlalchemy as sa

from comstockpostproc.comstock import ComStock

KBTU, THERM, MBTU = 0.2930710701722222, 29.307107017222222, 293.0710701722222


def _view_row(values: dict) -> dict:
    meta = sa.MetaData()
    tbl = sa.Table("run_timeseries", meta, *[sa.Column(k, sa.Float) for k in values])
    eng = sa.create_engine("sqlite://")
    meta.create_all(eng)
    with eng.begin() as conn:
        conn.execute(tbl.insert().values(**values))
        row = conn.execute(sa.select(*ComStock.timeseries_view_columns(list(tbl.columns)))).mappings().one()
    return dict(row)


def test_each_fuel_unit_is_converted_to_kwh_by_multiplying():
    row = _view_row({
        "total_site_electricity_kwh": 100.0,
        "total_site_gas_kbtu": 1000.0,
        "propane_heating_kbtu": 10.0,
        "fueloil_water_systems_therm": 2.0,
        "total_site_districtheating_mbtu": 1.0,
    })
    assert row["out.electricity.total.energy_consumption"] == pytest.approx(100.0)
    assert row["out.natural_gas.total.energy_consumption"] == pytest.approx(1000.0 * KBTU)
    assert row["out.propane.heating.energy_consumption"] == pytest.approx(10.0 * KBTU)
    assert row["out.fuel_oil.water_systems.energy_consumption"] == pytest.approx(2.0 * THERM)
    assert row["out.district_heating.total.energy_consumption"] == pytest.approx(1.0 * MBTU)


def test_non_energy_columns_pass_through_unchanged():
    row = _view_row({"building_id": 7.0, "total_site_water_gal": 3.0})
    assert row == {"building_id": 7.0, "total_site_water_gal": 3.0}
