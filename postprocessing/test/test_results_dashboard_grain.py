# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Grain checks for the results dashboard. No Athena.

An apportioned metadata aggregate has one row per (building, geography) with a
PARTIAL weight, a run with measures has that again per upgrade, and a published
timeseries table keeps one copy of a building per state folder. These pin the
places where those grains meet: the per-model collapses, the applicability join
of the measure profiles, and the schema-drift guards around the gas column.
"""

import numpy as np
import pandas as pd

from comstockpostproc.results_dashboard import (ami_shapes, annual, distributions as dist, measures,
                                                timeseries as ts)
from comstockpostproc.results_dashboard.design_params import METRICS, build_params_sql

CRAWLED = {**ts.PUBLISHED, "bldg": "building_id", "time": "time", "state": "",
           "kind": "crawled", "tz": "local"}


def _apportioned():
    # model 1 straddles two census divisions; model 2 has two rows in ONE division
    return pd.DataFrame({
        "bldg_id": [1, 1, 2, 2],
        "building_type": ["Hospital"] * 4,
        "census_division": ["Mountain", "Pacific", "Mountain", "Mountain"],
        "vintage": ["1990s"] * 4,
        "weight": [0.6, 0.4, 0.3, 0.7],
        "sqft": [100.0] * 4,
        "site_energy": [50.0, 50.0, 80.0, 80.0],
    })


def test_collapse_keeps_each_division_share_of_a_straddling_model():
    out = dist.collapse_to_models(_apportioned())
    m1 = out[out.bldg_id == 1].set_index("census_division")["weight"]
    assert m1.to_dict() == {"Mountain": 0.6, "Pacific": 0.4}      # not 1.0 in the first division
    m2 = out[out.bldg_id == 2]
    assert len(m2) == 1 and m2["weight"].iloc[0] == 1.0             # same division rows still merge
    assert out["weight"].sum() == 2.0                               # nothing lost, nothing doubled
    assert (out["site_energy"] == out["bldg_id"].map({1: 50.0, 2: 80.0})).all()


def test_collapse_is_a_pure_deduplication_for_model_level_frames():
    df = _apportioned().drop(columns="census_division")
    out = dist.collapse_to_models(df)
    assert list(out["bldg_id"]) == [1, 2] and list(out["weight"]) == [1.0, 1.0]


def test_quantile_cell_counts_models_not_geography_rows():
    g = pd.DataFrame({"bldg_id": [1, 1, 2], "site_energy": [50.0, 50.0, 80.0],
                      "w_count": [0.6, 0.4, 1.0], "w_area": [60.0, 40.0, 100.0]})
    cell = dist._quantile_cell(g, "run", "vintage", "1990s", "site_energy", "count", "All", False)
    assert cell["n_models"] == 2
    assert cell["weighted_total"] == 2.0


def test_design_params_dedupe_partitions_by_the_grouping_column():
    sql = build_params_sql("run_md", METRICS[:1], dim="in.census_division_name",
                           base_where="upgrade = 0 AND completed_status = 'Success'")
    assert 'PARTITION BY bldg_id, "in.census_division_name")' in sql
    pooled = build_params_sql("run_md", METRICS[:1], dim=None,
                              base_where="upgrade = 0 AND completed_status = 'Success'")
    assert "PARTITION BY bldg_id)" in pooled and "PARTITION BY bldg_id," not in pooled


def test_measure_baseline_applicability_joins_at_the_timeseries_grain():
    loc = {"kind": "county", "values": ["G0800690"], "label": "Larimer"}
    published = measures.build_ts_base_sql("rel_ts_by_state", "rel_md", loc, "3",
                                           dialect=ts.PUBLISHED, up_type="bigint", md_state="in.state")
    # published: one copy per state folder -> (building, state) set and join
    assert 'SELECT DISTINCT bldg_id, "in.state" AS st' in published
    assert 't."state" = app."st"' in published
    assert '"loc"' not in published
    crawled = measures.build_ts_base_sql("run_timeseries_vu", "run_md", loc, "3",
                                         dialect=CRAWLED, up_type="bigint", md_state="in.state")
    # crawled: a single copy -> building-only set and join, never one row per county
    assert "SELECT DISTINCT bldg_id FROM run_md" in crawled
    assert "app.\"st\"" not in crawled and 'AS st' not in crawled


def test_annual_sql_survives_a_table_without_the_gas_total():
    have = {annual.SQFT_COL, annual.BLDG_TYPE_COL, "out.electricity.total.energy_consumption..kwh"}
    sql = annual.build_annual_sql("run_md", {"building_type": annual.BLDG_TYPE_COL}, have=have)
    assert 'CAST(NULL AS double) AS "sqft_zero_gas"' in sql
    assert annual.GAS_TOTAL_COL not in sql
    with_gas = annual.build_annual_sql("run_md", {"building_type": annual.BLDG_TYPE_COL},
                                       have=have | {annual.GAS_TOTAL_COL})
    assert f'COALESCE("{annual.GAS_TOTAL_COL}", 0) = 0' in with_gas


def test_savings_distribution_counts_a_straddling_model_in_each_dimension_category():
    # model 1 has two geography rows in different climate zones; model 2 has one
    dist = pd.DataFrame({
        "bldg_id": [1, 1, 2],
        "pct_site|fuel|site energy": [10.0, 10.0, 20.0],
        "T|pct_site": [10.0, 10.0, 20.0],
        "D|climate_zone": ["5A", "6A", "5A"],
    })
    rows = pd.DataFrame(measures.savings_distribution_rows(dist, "3", "Measure"))
    pooled = rows[rows.group == "fuel"].set_index("category")
    assert pooled.loc["site energy", "n_models"] == 2                      # once per model
    by_cz = rows[rows.group == "climate_zone"].set_index("category")["n_models"].to_dict()
    assert by_cz == {"5A": 2, "6A": 1}                                      # model 1 in BOTH zones


def test_roll_up_keeps_an_all_null_metric_null():
    fine = pd.DataFrame({
        "building_type": ["Hospital", "Hospital", "Office"],
        "sqft": [1.0, 2.0, 3.0],
        "sqft_zero_gas": [np.nan, np.nan, np.nan],      # column the release lacks
        "site_energy": [5.0, np.nan, 7.0],              # a real gap in one row
    })
    out = annual.roll_up(fine, "building_type").set_index("category")
    assert out["sqft_zero_gas"].isna().all()                              # never 0
    assert out.loc["All", "sqft"] == 6.0 and out.loc["Hospital", "site_energy"] == 5.0
    pair = annual.roll_up_pair(fine.assign(vintage="1990s"), "vintage")
    assert pair["sqft_zero_gas"].isna().all() and pair["sqft"].sum() == 6.0


def test_ami_membership_probe_joins_at_the_timeseries_grain():
    region = {"counties": ["G0800690"], "states": ["CO"]}
    published = ami_shapes.build_membership_sql("rel_ts_by_state", "run_md_county", region, ts.PUBLISHED)
    # published: a model is covered only where its state folder has a copy
    assert 't."bldg_id" AS b, t."state" AS s' in published
    assert "ON t.b = m.bldg_id AND t.s = m.state" in published
    crawled = ami_shapes.build_membership_sql("run_timeseries_vu", "run_md_county", region, CRAWLED)
    assert 't."building_id" AS b FROM' in crawled          # building only, no state alias
    assert '" AS s' not in crawled and "t.s = m.state" not in crawled
    assert "ON t.b = m.bldg_id\n" in crawled

