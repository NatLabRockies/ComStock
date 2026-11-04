# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Like-for-like comparisons and honest counts in the results dashboard. No Athena.

Pins: the CBECS-comparable site total exists on both sides and carries an
interval; ComStock's all-fuel site total is not compared against CBECS; derived
metrics are not double-added; zone 7 is one bin after the audit; the crawled
timeseries table's kBtu fuels are converted and a create_views view's fossil
fuels are refused; dropped savings values are counted, not just dropped.
"""

import numpy as np
import pandas as pd

from comstockpostproc.results_dashboard import annual, cbecs_ref, measures, timeseries as ts
from comstockpostproc.results_dashboard.metrics_def import ALL_KWH_METRICS, DERIVED, KWH


def _cbecs(n=6):
    cols = {c for k, (c, _) in ALL_KWH_METRICS.items()}
    df = pd.DataFrame({c: np.linspace(1, 2, n) for c in cols})
    df["in.sqft..ft2"] = 1000.0
    df["in.comstock_building_type"] = ["Hospital", "Hospital", "Hospital",
                                       "Warehouse", "Warehouse", "Warehouse"]
    df["weight"] = 1.0
    # replicate weights under the column names the jackknife looks for
    reps = {f"Unknown Eligibility and Nonresponse Adjusted Replicate Weight {r}": 1.0 + (r % 3) * 0.1
            for r in range(1, 152)}
    return pd.concat([df, pd.DataFrame(reps, index=df.index)], axis=1)


def test_cbecs_derived_metrics_get_an_interval_and_the_site_sum_is_the_four_fuels():
    df = _cbecs()
    totals, _diag = cbecs_ref.aggregate_cbecs(df, "building_type")
    nat = totals[totals["category"] == "All"].set_index("metric")
    assert "site_energy.cbecs_fuels" in nat.index
    four = sum(float(df[ALL_KWH_METRICS[k][0]].sum()) for k in DERIVED["site_energy.cbecs_fuels"][0])
    assert abs(nat.loc["site_energy.cbecs_fuels", "cbecs_value"] - four) < 1e-6
    for k in ("site_energy.cbecs_fuels", "all_fuel.heating", "electricity.lighting_combined"):
        assert np.isfinite(nat.loc[k, "cbecs_ci95_low"]), k


def test_comparison_blanks_cbecs_for_the_all_fuel_site_total_and_adds_derived_once():
    cs = pd.DataFrame({"category": ["All"], "sqft": [1.0],
                       **{k: [10.0] for k in ALL_KWH_METRICS}})
    cb = pd.DataFrame({"category": ["All"] * 3,
                       "metric": ["site_energy.total", "electricity.total", "site_energy.cbecs_fuels"],
                       "cbecs_value": [40.0, 10.0, 38.0], "cbecs_se": [1.0] * 3,
                       "cbecs_rse_pct": [1.0] * 3, "cbecs_ci95_low": [1.0] * 3, "cbecs_ci95_high": [2.0] * 3})
    comp = annual.build_comparison(cs, cb, "building_type").set_index("metric")
    assert np.isnan(comp.loc["site_energy.total", "cbecs_value"])        # ComStock only
    assert (comp.index == "site_energy.cbecs_fuels").sum() == 1            # not re-added
    assert abs(comp.loc["site_energy.cbecs_fuels", "cbecs_value"] - 38.0 * (3412.141633 / 1e12)) < 1e-18


def test_zone_seven_is_one_bin_after_the_merge():
    fine = pd.DataFrame({
        "building_type": ["Hospital"] * 3, "census_division": ["Mountain"] * 3,
        "vintage": ["1990s"] * 3, "climate_zone": ["7", "7A", "7B"], "size_bin": ["1k-5k"] * 3,
        "bldg_count_weighted": [1.0, 2.0, 3.0], "sqft": [10.0, 20.0, 30.0],
        "sqft_zero_gas": [0.0, 1.0, 1.0], "electricity.total": [1.0, 1.0, 1.0],
    })
    merged = annual.merge_climate_zones(fine)
    assert merged["climate_zone"].tolist() == ["7"]
    assert merged["sqft"].iloc[0] == 60.0 and merged["bldg_count_weighted"].iloc[0] == 6.0
    audit = annual.check_categories(fine, "run")
    assert set(audit["run.climate_zone"]["unexpected_values"]) == {"7A", "7B"}


def test_crawled_fuel_totals_are_converted_and_view_fuels_are_refused(monkeypatch):
    crawled = {"building_id": "bigint", "time": "timestamp", "upgrade": "bigint",
               "total_site_electricity_kwh": "double", "total_site_gas_kbtu": "double",
               "electricity_fans_kwh": "double"}
    view = {"building_id": "bigint", "time": "timestamp", "upgrade": "bigint",
            "out.electricity.total.energy_consumption": "double",
            "out.natural_gas.total.energy_consumption": "double",
            "out.electricity.fans.energy_consumption": "double"}
    monkeypatch.setattr(ts.athena, "table_column_types", lambda t, no_cache=False: crawled if t == "run_timeseries" else view)
    d = ts.ts_dialect("run_timeseries")
    assert d["kind"] == "crawled" and d["totals"]["natural_gas"] == "total_site_gas_kbtu"
    assert abs(d["total_factors"]["natural_gas"] - 0.2930710701722222) < 1e-12
    assert "* 0.2930710701722222)" in ts.total_sum(d, "natural_gas", "gas_kwh")
    assert ts.total_sum(d, "propane", "p") == "CAST(NULL AS double) AS p"
    v = ts.ts_dialect("run_timeseries_vu")
    assert v["kind"] == "mixed" and "natural_gas" not in v["totals"] and "electricity" in v["totals"]


def test_savings_distribution_counts_undefined_and_zero_values():
    dist = pd.DataFrame({
        "bldg_id": [1, 2, 3, 4, 5],
        "pct_site|end_use|electricity heating": [np.inf, -np.inf, 0.0, 10.0, -5.0],
    })
    rows = measures.savings_distribution_rows(dist, "1", "m")
    r = rows[0]
    assert r["n_models"] == 2 and r["n_undefined"] == 2 and r["n_zero"] == 1


def test_measure_summary_other_fuels_sum_only_what_is_present():
    s = pd.Series({"s|propane|total": 1.5, "s|fuel_oil|total": 2.0})
    assert measures._nansum(s, ["s|propane|total", "s|fuel_oil|total", "s|district_heating|total"]) == 3.5
    assert np.isnan(measures._nansum(s, ["s|district_cooling|total"]))
