# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The local California weight table: grouping, filtering, and reuse. No AWS."""

import os
import time

import fsspec
import polars as pl
import pytest

from comstockpostproc.california import weights as W


def _alloc():
    # model 1 spans two tracts in one utility x zone and a third in another zone
    return pl.LazyFrame({
        "bldg_id": [1, 1, 1, 2, 3, 4],
        "weight": [0.5, 0.25, 0.25, 2.0, 1.0, 3.0],
        W.UTIL_COL: [14328, 14328, 14328, 16609, 14328, None],
        W.SOURCE_CZ_COL: ["CEC3", "CEC3", "CEC12", "CEC7", "CEC3", "CEC3"],
    })


def _sim():
    return pl.LazyFrame({
        "bldg_id": [1, 2, 3, 4],
        W.BLDG_TYPE_COL: ["SmallOffice", "Warehouse", "Hospital", "Grocery"],
        W.SQFT_COL: [5000.0, 20000.0, 200000.0, 40000.0],
        W.PEAK_COL: [30.0, 90.0, 1500.0, 300.0],
        "completed_status": ["Success", "Success", "Fail", "Success"],
    })


def test_combine_groups_by_building_utility_and_zone():
    df = W.combine(_alloc(), _sim(), upgrade_id=0)
    assert df.columns == W.COLUMNS
    m1 = df.filter(pl.col("bldg_id") == 1).sort(W.CEC_COL)
    assert m1[W.CEC_COL].to_list() == ["CEC12", "CEC3"]
    assert m1["weight"].to_list() == [0.25, 0.75]                 # two CEC3 tracts summed
    assert 3 not in df["bldg_id"].to_list()                      # failed model dropped
    assert df.filter(pl.col("bldg_id") == 4)[W.UTIL_COL].is_null().all()   # no utility: kept
    assert df["upgrade"].unique().to_list() == [0]


class _FakeComStock:
    UPGRADE_ID = "upgrade"

    def __init__(self, root):
        self.output_dir = {"fs": fsspec.filesystem("file"), "fs_path": str(root),
                           "storage_options": None}
        self.data = _sim().with_columns(pl.lit(0).alias("upgrade"))


def _write_bills(root):
    d = root / "cached_allocated_weights_plus_bills" / "upgrade=0" / "in.state=CA"
    d.mkdir(parents=True, exist_ok=True)
    _alloc().collect().write_parquet(d / "cached_allocated_weights_plus_bills_upgrade0_CA.parquet")
    return d


def test_save_reuses_until_the_bills_cache_is_newer(tmp_path):
    cs = _FakeComStock(tmp_path)
    _write_bills(tmp_path)
    p1 = W.save_california_weights(cs)
    assert p1.exists() and pl.read_parquet(p1).height == 4
    first = os.path.getmtime(p1)
    time.sleep(1.1)
    assert W.save_california_weights(cs) == p1 and os.path.getmtime(p1) == first   # reused
    time.sleep(1.1)
    _write_bills(tmp_path)                                                         # newer source
    W.save_california_weights(cs)
    assert os.path.getmtime(p1) > first                                            # rebuilt


def test_missing_bills_cache_is_a_clear_error(tmp_path):
    with pytest.raises(FileNotFoundError, match="create_allocated_weights_plus_util_bills"):
        W.build_california_weights(_FakeComStock(tmp_path))


def test_weights_path_none_when_absent(tmp_path):
    assert W.california_weights_path("nope", output_root=tmp_path) is None
    p = tmp_path / "ComStock r" / W.SUBDIR / W.file_name(0)
    p.parent.mkdir(parents=True)
    p.write_bytes(b"x")
    assert W.california_weights_path("r", output_root=tmp_path) == p


# ---- a published release: weights from its tract-level Athena table ------------

from comstockpostproc.california import release_weights as R  # noqa: E402

RELEASE_COLS = {"bldg_id": "bigint", "weight": "double", "upgrade": "bigint", "state": "string",
                R.TRACT_COL: "string", "in.electric_utility_eia_code": "bigint",
                "in.cec_climate_zone": "string", "in.comstock_building_type": "string",
                "in.sqft..ft2": "double", "out.electricity.total.peak_demand..kw": "double",
                "completed_status": "string"}


def test_find_tract_table_skips_aggregates_views_and_timeseries():
    tables = ["rel_md_agg_national_parquet", "rel_md_by_state_and_county_vu",
              "rel_ts_by_state", "rel_md_by_state_and_county_parquet", "rel_md_by_puma_parquet"]
    cols = {"rel_md_by_state_and_county_parquet": RELEASE_COLS,
            "rel_md_by_puma_parquet": {"bldg_id": "bigint"}}
    t = R.find_tract_table("rel", "db", list_tables=lambda db, p: tables,
                           columns_of=lambda db, t: cols.get(t, {}))
    assert t == "rel_md_by_state_and_county_parquet"
    with pytest.raises(LookupError, match="md_tract_table"):
        R.find_tract_table("rel", "db", list_tables=lambda db, p: tables, columns_of=lambda db, t: {})


def test_resolve_columns_and_sql():
    c = R.resolve_columns(RELEASE_COLS)
    assert (c["sqft"], c["state"], c["util"]) == ("in.sqft..ft2", "state", "in.electric_utility_eia_code")
    sql = R.build_release_weights_sql("rel_md_by_state_and_county_parquet", c)
    assert '"state" = \'CA\'' in sql and "CAST(upgrade AS varchar) IN ('0', '00')" in sql
    assert "GROUP BY 1, 2, 3, 4" in sql and "SUM(weight) AS weight" in sql
    # the tract survives only where the table leaves utility or zone unresolved
    assert "CASE WHEN (CAST(\"in.electric_utility_eia_code\" AS bigint) IS NOT NULL" in sql
    no_cec = R.resolve_columns({k: v for k, v in RELEASE_COLS.items() if k != "in.cec_climate_zone"})
    assert "CAST(NULL AS varchar)" in R.build_release_weights_sql("t", no_cec)
    with pytest.raises(LookupError):
        R.resolve_columns({"bldg_id": "bigint"})


def test_finish_fills_unresolved_rows_from_tract_lookups_and_regroups():
    raw = pl.DataFrame({
        "bldg_id": [1, 1, 2, 3],
        "util": [14328, None, 16609, 16609],
        "cec": ["CEC3", None, "NotApplicable", "CEC7"],
        "tract": [None, "G06A", "G06B", None],
        "weight": [1.0, 0.5, 2.0, 4.0],
        "btype": ["SmallOffice", "SmallOffice", "Warehouse", "Grocery"],
        "sqft": [5000.0, 5000.0, 20000.0, 40000.0], "peak": [30.0, 30.0, 90.0, 300.0],
        "completed_status": ["Success"] * 4})
    cz = pl.DataFrame({"tract": ["G06A", "G06B"], "cec_fill": ["CEC3", "CEC10"]})
    util = pl.DataFrame({"tract": ["G06A", "G06B"], "util_fill": [14328, 16609]})
    out = R.finish(raw, cz, util)
    assert out.columns == W.COLUMNS
    m1 = out.filter(pl.col("bldg_id") == 1)
    assert m1.height == 1 and m1["weight"][0] == 1.5          # filled row joins its twin
    m2 = out.filter(pl.col("bldg_id") == 2)
    assert m2[W.CEC_COL][0] == "CEC10"                         # NotApplicable filled from the tract


def test_release_weights_reused_when_present(tmp_path):
    p = tmp_path / "ComStock r3" / W.SUBDIR / W.file_name(0)
    p.parent.mkdir(parents=True)
    p.write_bytes(b"x")
    assert R.save_release_california_weights({"key": "r3", "md_table": "x_md_agg_national_parquet"},
                                             output_root=tmp_path) == p
