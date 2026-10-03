# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The California leg of the results dashboard: segmentation, inline weights, SQL,
pooled truth and the comparison metrics. No Athena."""

import numpy as np
import pandas as pd
import pytest

from comstockpostproc.california import segments as SEG
from comstockpostproc.results_dashboard import calmac_shapes as CS
from comstockpostproc.results_dashboard import timeseries as ts

# What ts_dialect returns for a buildstockbatch-crawled <run>_timeseries table.
CRAWLED = {**ts.PUBLISHED, "bldg": "building_id", "time": "time", "state": "",
           "kind": "crawled", "tz": "local", "up_type": "bigint",
           "enduses": {e: f"electricity_{e}_kwh" for e in ts.ENDUSE_STACK_ORDER},
           "totals": {"electricity": "total_site_electricity_kwh",
                      "natural_gas": "total_site_gas_kbtu"},
           "total_factors": {"electricity": 1.0, "natural_gas": ts.KBTU_TO_KWH}}
CFG = SEG.resolve_config()


def _weights():
    return pd.DataFrame({
        "bldg_id": [1, 2, 3, 4, 5, 5],
        CS.UTIL_COL: [SEG.PGE, SEG.PGE, SEG.PGE, SEG.SDGE, SEG.PGE, SEG.PGE],
        CS.CEC_COL: ["CEC3", "CEC3", "CEC9", "CEC7", "CEC12", "CEC3"],
        "weight": [10.0, 5.0, 7.0, 4.0, 2.0, 1.0],
        CS.SQFT_COL: [5000.0, 50000.0, 5000.0, 5000.0, 20000.0, 20000.0],
        CS.BLDG_TYPE_COL: ["SmallOffice", "LargeOffice", "SmallOffice", "SmallOffice",
                           "Warehouse", "Warehouse"],
        CS.PEAK_COL: [20.0, 600.0, 20.0, 15.0, 100.0, 100.0],
    })


def test_classify_groups_zones_industries_and_sizes():
    c = CS.classify(_weights(), CFG).set_index(["bldg_id", CS.CEC_COL])
    assert c.loc[(1, "CEC3"), ["cz_group", "industry", "size"]].tolist() == ["C", "Office", "S"]
    assert c.loc[(2, "CEC3"), "size"] == "M"                       # >= 75 kW for PG&E
    assert c.loc[(3, "CEC9"), "cz_group"] == SEG.OTHER_ZONE        # PG&E CEC9: not a group
    assert c.loc[(4, "CEC7"), ["cz_group", "size"]].tolist() == ["C", "S"]   # SDG&E: S below 20 kW
    pooled = CS.classify(_weights(), SEG.resolve_config({"size_rule": "none"}))
    assert set(pooled["size"]) == {SEG.POOLED}


def test_segment_weights_pools_sizes_and_industries():
    sw = CS.segment_weights(CS.classify(_weights(), CFG)).set_index(
        ["utility_id", "cz_group", "industry", "size"])
    assert sw.loc[(SEG.PGE, "C", "Office", "S"), "weight_sum"] == 10.0
    assert sw.loc[(SEG.PGE, "C", "Office", SEG.POOLED), "weight_sum"] == 15.0
    # the 'other' zone weight (model 3) is excluded from every compared segment
    assert sw.loc[(SEG.PGE, "C", SEG.ALL_MAPPED, SEG.POOLED), "weight_sum"] == 16.0
    assert sw.loc[(SEG.PGE, "C", SEG.ALL_MAPPED, SEG.POOLED), "model_count"] == 3
    zs = CS.zone_summary(CS.classify(_weights(), CFG))
    assert zs.loc[zs[CS.CEC_COL] == "CEC9", "cz_group"].iloc[0] == SEG.OTHER_ZONE


def test_values_ctes_chunk_between_buildings_and_use_double_literals():
    rows, codes = CS.segment_codes(CS.classify(_weights(), CFG))
    assert set(rows["bldg_id"]) == {1, 2, 4, 5}                   # model 3 sits outside the groups
    one = CS.values_ctes(rows)
    assert len(one) == 1 and one[0].startswith("WITH w (building_id, seg, weight) AS (VALUES")
    assert "10e0" in one[0] and "0.5" not in one[0]               # DOUBLE, never DECIMAL
    big = pd.DataFrame({"bldg_id": np.repeat(np.arange(4000), 2), "seg": np.tile([0, 1], 4000),
                        "weight": 1.234567})
    chunks = CS.values_ctes(big, max_bytes=40_000)
    assert len(chunks) > 1 and all(len(c) < 40_000 for c in chunks)
    seen = [set(int(x.split(",")[0].strip("(")) for x in c.split("\n")[1:]) for c in chunks]
    assert all(not (a & b) for i, a in enumerate(seen) for b in seen[i + 1:])   # no building split
    assert sum(c.count("),(") + c.count("),\n(") + 1 for c in chunks) == len(big)


def test_hourly_sql_on_crawled_and_published_tables():
    cte = "WITH w (building_id, seg, weight) AS (VALUES (1,0,1e0))"
    crawled = CS.build_hourly_sql("run_timeseries", cte, CRAWLED)
    assert 'JOIN w ON t."building_id" = w.building_id' in crawled
    assert "SUM(t.\"total_site_electricity_kwh\" * w.weight) AS kwh_weighted" in crawled
    assert "total_site_gas_kbtu" in crawled and "0.2930710701722222" in crawled   # kBtu -> kWh
    assert "t.upgrade = 0" in crawled and "'CA'" not in crawled
    assert "date_trunc('hour', date_add('minute', -15, t.\"time\"))" in crawled
    pub = CS.build_hourly_sql("rel_ts_by_state", cte, ts.PUBLISHED)
    assert 't."state" = \'CA\'' in pub                             # the California copy
    assert "date_add('hour', CASE" in pub                          # EST -> local
    mem = CS.build_membership_sql("run_timeseries", cte, CRAWLED)
    assert "LEFT JOIN (SELECT DISTINCT t.\"building_id\" AS b" in mem


def _truth_frame():
    idx = pd.date_range("2018-01-01", "2018-12-31 23:00", freq="h")
    rows = []
    for gp, scale in (("Office_S_C", 1.0), ("Office_M_C", 3.0), ("Wareho_A_C", 2.0)):
        rows.append(pd.DataFrame({"gp": gp, "timestamp": idx, "value": scale, "basis": "raw",
                                  "premise_count": 200, "merged_hour": False}))
    return pd.concat(rows, ignore_index=True)


def _segw(office_s=30.0, office_m=10.0, wareho=60.0):
    return pd.DataFrame([
        (SEG.PGE, "C", "Office", "S", office_s), (SEG.PGE, "C", "Office", "M", office_m),
        (SEG.PGE, "C", "Office", SEG.POOLED, office_s + office_m),
        (SEG.PGE, "C", "Wareho", SEG.POOLED, wareho),
    ], columns=["utility_id", "cz_group", "industry", "size", "weight_sum"])


def test_pooled_truth_is_composition_weighted():
    truth, desc = CS.truth_segments(_truth_frame(), SEG.PGE, "electricity", CFG, _segw())
    pooled = truth[("Office", "C", SEG.POOLED)]["value"]
    assert np.allclose(pooled, 0.75 * 1.0 + 0.25 * 3.0)          # 30:10 ComStock weights
    allm = truth[(SEG.ALL_MAPPED, "C", SEG.POOLED)]["value"]
    assert np.allclose(allm, 0.4 * 1.5 + 0.6 * 2.0)               # Office 40, Warehouse 60
    d = desc.set_index(["industry", "size"])
    assert d.loc[("Office", "S"), "size_comparable"] == False      # noqa: E712 -- multi-tenant
    eq = CS.truth_segments(_truth_frame(), SEG.PGE, "electricity",
                           SEG.resolve_config({"pool_weights": "equal"}), _segw())[0]
    assert np.allclose(eq[("Office", "C", SEG.POOLED)]["value"], 2.0)


def test_empty_comstock_cell_weighs_zero_not_equal():
    truth, _ = CS.truth_segments(_truth_frame(), SEG.PGE, "electricity", CFG, _segw(office_s=np.nan))
    assert np.allclose(truth[("Office", "C", SEG.POOLED)]["value"], 3.0)


def test_mixed_bases_fall_back_to_raw_for_every_component():
    t = _truth_frame()
    norm = t[t["gp"] == "Office_S_C"].assign(basis="normalized_2018")
    t = pd.concat([t, norm], ignore_index=True)
    _, desc = CS.truth_segments(t, SEG.SDGE, "electricity",
                                SEG.resolve_config({"size_rule": {"kind": "peak_kw",
                                                    "thresholds_kw": {SEG.SDGE: 20.0},
                                                    "labels": {SEG.SDGE: ["S", "M"]}}}),
                                _segw().assign(utility_id=SEG.SDGE))
    d = desc.set_index(["industry", "size"])
    assert d.loc[("Office", "S"), "basis"] == "normalized_2018"
    assert d.loc[("Office", SEG.POOLED), "basis"] == "raw"         # one component lacks it


def test_compare_electricity_identical_shapes_score_zero():
    idx = pd.date_range("2018-01-01", "2018-12-31 23:00", freq="h")
    shape = 1.0 + (idx.hour.isin(range(8, 18))).astype(float)
    hourly = pd.DataFrame({"utility_id": SEG.PGE, "cz_group": "C", "industry": "Wareho",
                           "size": SEG.POOLED, "hour_ts": idx, "kwh_weighted": 60.0 * shape * 7,
                           "gas_kwh_weighted": 0.0, "eu_interior_lighting": 60.0 * shape * 7})
    segw = pd.DataFrame([(SEG.PGE, "C", "Wareho", SEG.POOLED, 60.0, 12, 1.2e6)],
                        columns=["utility_id", "cz_group", "industry", "size", "weight_sum",
                                 "model_count", "sqft_weighted"])
    truth = {("Wareho", "C", SEG.POOLED): pd.DataFrame({"timestamp": idx, "value": shape})}
    desc = pd.DataFrame([{"industry": "Wareho", "cz_group": "C", "size": SEG.POOLED,
                          "components": "Wareho_A_C", "pool_weights": "", "basis": "raw",
                          "premises": 200, "size_comparable": True}])
    prof, met, summ, ldc, mon = CS.compare_electricity(hourly, segw, truth, desc, SEG.PGE, CFG, "r")
    assert len(met) == 6 and np.allclose(met["daytype_shape_rmse_pts"], 0)
    assert (met["peak_hour_comstock"] == met["peak_hour_calmac"]).all()
    assert summ["comstock_annual_per_bldg"].iloc[0] == pytest.approx(7 * shape.sum())
    assert summ["monthly_share_rmse_pts"].iloc[0] == pytest.approx(0, abs=1e-9)
    assert not ldc.empty and np.allclose(ldc["comstock_rel"], ldc["calmac_rel"])
    ag = CS.cross_segment_agreement(met.assign(utility_id=SEG.PGE))
    assert ag["consistency"].iloc[0] == "insufficient groups"
