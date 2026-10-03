# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The California weight table for a PUBLISHED release, built from its Athena tables.

    path = save_release_california_weights(dict(kind='release', key='r3_2025',
               database='buildstock_sdr',
               md_table='comstock_amy2018_r3_2025_md_agg_national_parquet'))

A run postprocessed here gets its California weight table from its own
allocated-weights cache (weights.save_california_weights). A published release has no
such cache, but it publishes the NON-AGGREGATE metadata (`metadata_and_annual_results/`
on OEDI): every instance of each building after reallocation, one row per building and
tract with its partial weight. That table carries the tract, and usually the electric
utility and CEC zone too, so the same table can be built from it:

    one row per (upgrade, bldg_id, in.electric_utility_eia_code, in.cec_climate_zone)

written to the same place a processed run's goes -- output/ComStock <key>/
california_weights/california_weights_upgrade0.parquet -- so the dashboard leg treats
a release exactly like any other run (and california_weights_path(key) finds it).

What is discovered rather than assumed, because the published schema is not the
postprocessing one:
  * the tract-level table: one of the release's tables in its database that is not an
    aggregate (`_agg_`) or a view (`_vu`) and has `in.nhgis_tract_gisjoin`; the run entry
    can name it (`md_tract_table`) instead;
  * the column spellings for floor area, peak demand, state and upgrade, from Glue.
Utility and CEC zone are read from the table when present. Rows where they are missing,
or where the zone reads 'NotApplicable' (746 California tracts in the spatial lookup do),
keep their tract, and the gap is filled locally from the same tract lookups ComStock's
apportionment uses (truth_data/<v>/cec_cz_by_tract_{2010,2020}_lkup.json and
tract_to_elec_util_v2.csv). Everything else is aggregated in Athena, so the download is
the ~50,000-row table itself rather than every building-tract row.

Kept out of results_dashboard (the california package imports nothing from it): the one
query here goes straight through BuildStockQuery, with the same workgroup and
server-side-reuse setting the dashboard's own adapter uses.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

import polars as pl

from ..athena_config import ATHENA_WORKGROUP
from . import weights as W

logger = logging.getLogger(__name__)

TRACT_COL = "in.nhgis_tract_gisjoin"
CANDIDATES = {
    "sqft": ["in.sqft..ft2", "in.sqft"],
    "peak": ["out.electricity.total.peak_demand..kw", "out.electricity.total.peak_demand"],
    "btype": ["in.comstock_building_type"],
    "util": ["in.electric_utility_eia_code"],
    "cec": ["in.cec_climate_zone", "in.ashrae_or_cec_climate_zone"],
    "state": ["state", "in.state"],
    "status": ["completed_status"],
}
TRUTH_DIR = Path(__file__).resolve().parents[2] / "truth_data" / "v01"


# ---------------------------------------------------------------------------
# discovery (Glue)
# ---------------------------------------------------------------------------

def glue_columns(database: str, table: str) -> dict[str, str]:
    """{column: Glue type}, partition keys included."""
    import boto3
    t = boto3.client("glue", region_name="us-west-2").get_table(DatabaseName=database, Name=table)["Table"]
    cols = t["StorageDescriptor"]["Columns"] + t.get("PartitionKeys", [])
    return {c["Name"]: c.get("Type", "") for c in cols}


def glue_tables(database: str, prefix: str) -> list[str]:
    import boto3
    glue = boto3.client("glue", region_name="us-west-2")
    kw, names = {"DatabaseName": database, "Expression": f"{prefix}*"}, []
    resp = glue.get_tables(**kw)
    names += [t["Name"] for t in resp["TableList"]]
    while "NextToken" in resp:
        resp = glue.get_tables(NextToken=resp["NextToken"], **kw)
        names += [t["Name"] for t in resp["TableList"]]
    return sorted(names)


def find_tract_table(stem: str, database: str, list_tables=glue_tables,
                     columns_of=glue_columns) -> str:
    """The release's tract-level metadata table: not an aggregate, not a view, and
    carrying the tract column. Parquet tables and by-state-and-county names first."""
    cands = [t for t in list_tables(database, stem)
             if t.startswith(f"{stem}_") and "_agg_" not in t and not t.endswith("_vu")
             and "_ts_" not in t and "timeseries" not in t]
    cands.sort(key=lambda t: (not t.endswith("parquet"), "by_state_and_county" not in t, len(t)))
    for t in cands:
        try:
            if TRACT_COL in columns_of(database, t):
                return t
        except Exception as exc:                                  # noqa: BLE001
            logger.info("release weights: cannot read the columns of %s.%s (%s)", database, t, exc)
    raise LookupError(
        f"no tract-level metadata table for {stem} in {database}: looked at {cands or 'nothing'} "
        f"for one with {TRACT_COL}. Name it in the run entry as md_tract_table='<table>'.")


def resolve_columns(cols: dict[str, str]) -> dict[str, str | None]:
    """The real spelling of each column the query needs, None where absent."""
    out = {k: next((c for c in names if c in cols), None) for k, names in CANDIDATES.items()}
    missing = [k for k in ("sqft", "peak", "btype", "state") if not out[k]]
    if missing or "bldg_id" not in cols or "weight" not in cols or TRACT_COL not in cols:
        raise LookupError(f"the tract-level table lacks columns the California weights need: "
                          f"{missing + [c for c in ('bldg_id', 'weight', TRACT_COL) if c not in cols]}")
    out["upgrade_type"] = cols.get("upgrade", "")
    return out


# ---------------------------------------------------------------------------
# the query (pure)
# ---------------------------------------------------------------------------

def build_release_weights_sql(table: str, c: dict) -> str:
    """Building x utility x CEC zone weights for California, aggregated in Athena.

    The tract is kept only on rows whose utility or zone the table does not resolve,
    so the result is small and those rows can still be filled locally."""
    q = lambda col: f'"{col}"'                                      # noqa: E731
    util = f"CAST({q(c['util'])} AS bigint)" if c.get("util") else "CAST(NULL AS bigint)"
    cec = f"CAST({q(c['cec'])} AS varchar)" if c.get("cec") else "CAST(NULL AS varchar)"
    resolved = f"({util} IS NOT NULL AND {cec} LIKE 'CEC%')"
    status = f"ARBITRARY({q(c['status'])})" if c.get("status") else "'Success'"
    where = [f"{q(c['state'])} = 'CA'"]
    if c.get("upgrade_type"):
        where.append("CAST(upgrade AS varchar) IN ('0', '00')")
    if c.get("status"):
        where.append(f"{q(c['status'])} = 'Success'")
    return (
        "SELECT\n"
        "    bldg_id,\n"
        f"    {util} AS util,\n"
        f"    CASE WHEN {resolved} THEN {cec} END AS cec,\n"
        f'    CASE WHEN {resolved} THEN NULL ELSE "{TRACT_COL}" END AS tract,\n'
        "    SUM(weight) AS weight,\n"
        f"    ARBITRARY({q(c['btype'])}) AS btype,\n"
        f"    ARBITRARY(CAST({q(c['sqft'])} AS double)) AS sqft,\n"
        f"    ARBITRARY(CAST({q(c['peak'])} AS double)) AS peak,\n"
        f"    {status} AS completed_status\n"
        f"FROM {table}\n"
        f"WHERE {' AND '.join(where)}\n"
        "GROUP BY 1, 2, 3, 4"
    )


# ---------------------------------------------------------------------------
# local fill and shape (pure)
# ---------------------------------------------------------------------------

def tract_lookups(truth_dir: Path = TRUTH_DIR) -> tuple[pl.DataFrame, pl.DataFrame]:
    """(tract -> CEC zone, tract -> electric utility), from the files ComStock's
    apportionment and bills already use. 2010 tracts first, then 2020, as there."""
    cz = {}
    for name in ("cec_cz_by_tract_2020_lkup.json", "cec_cz_by_tract_2010_lkup.json"):
        p = truth_dir / name
        if p.exists():
            cz.update(json.loads(p.read_text(encoding="utf-8")))   # 2010 wins on overlap
    cz_df = pl.DataFrame({"tract": list(cz.keys()), "cec_fill": list(cz.values())},
                         schema={"tract": pl.String, "cec_fill": pl.String})
    util_path = truth_dir / "tract_to_elec_util_v2.csv"
    util_df = (pl.read_csv(util_path, schema_overrides={"in.nhgis_tract_gisjoin": pl.String})
               .select(pl.col("in.nhgis_tract_gisjoin").alias("tract"),
                       pl.col("in.electric_utility_eia_code").cast(pl.Int64).alias("util_fill"))
               if util_path.exists() else
               pl.DataFrame(schema={"tract": pl.String, "util_fill": pl.Int64}))
    return cz_df, util_df.unique("tract")


def finish(raw: pl.DataFrame, cz_df: pl.DataFrame, util_df: pl.DataFrame,
           upgrade_id: int = 0) -> pl.DataFrame:
    """Athena's rows -> the weights.COLUMNS table: fill unresolved utility and zone
    from the tract lookups, then sum by building, utility and zone."""
    df = (raw.with_columns(pl.col("tract").cast(pl.String), pl.col("cec").cast(pl.String),
                           pl.col("util").cast(pl.Int64))
          .join(cz_df, on="tract", how="left")
          .join(util_df, on="tract", how="left")
          .with_columns(
              util=pl.coalesce("util", "util_fill"),
              cec=pl.when(pl.col("cec").str.starts_with("CEC")).then(pl.col("cec"))
                    .otherwise(pl.col("cec_fill"))))
    unresolved = df.filter(pl.col("cec").is_null())
    if not unresolved.is_empty():
        logger.warning("release weights: %.1f weighted California buildings sit in tracts with no "
                       "CEC zone in the table or the lookups; dropped", unresolved["weight"].sum())
    return (df.filter(pl.col("cec").is_not_null())
            .group_by(["bldg_id", "util", "cec"])
            .agg(pl.col("weight").sum(), pl.col("btype").first(), pl.col("sqft").first(),
                 pl.col("peak").first(), pl.col("completed_status").first())
            .select(pl.lit(int(upgrade_id)).cast(pl.Int64).alias("upgrade"),
                    pl.col("bldg_id").cast(pl.Int64),
                    pl.col("util").alias(W.UTIL_COL),
                    pl.col("cec").alias(W.CEC_COL),
                    pl.col("weight").cast(pl.Float64),
                    pl.col("sqft").alias(W.SQFT_COL),
                    pl.col("btype").cast(pl.String).alias(W.BLDG_TYPE_COL),
                    pl.col("peak").alias(W.PEAK_COL),
                    pl.col("completed_status").cast(pl.String))
            .sort(["bldg_id", W.UTIL_COL, W.CEC_COL]))


# ---------------------------------------------------------------------------
# doing it
# ---------------------------------------------------------------------------

def _athena(sql: str, database: str, reflect_table: str):
    from buildstock_query import BuildStockQuery
    client = BuildStockQuery(workgroup=ATHENA_WORKGROUP, db_name=database,
                             table_name=(reflect_table, None, None), db_schema="comstock_oedi",
                             buildstock_type="comstock", skip_reports=True,
                             athena_query_reuse=False)
    return client.execute(sql)


def save_release_california_weights(entry: dict, output_root: str | Path | None = None,
                                    force: bool = False) -> Path:
    """Build (or reuse) a release's California weight table; returns its path.

    entry: a driver RUNS entry of kind 'release' -- key, database, md_table, and
    optionally md_tract_table. Reused when present (a published release does not
    change); force=True rebuilds it."""
    key, database = entry["key"], entry.get("database", "buildstock_sdr")
    root = Path(output_root) if output_root else Path(__file__).resolve().parents[2] / "output"
    path = root / f"ComStock {key}" / W.SUBDIR / W.file_name(0)
    if path.exists() and not force:
        logger.info("release weights: reusing %s", path)
        return path
    stem = entry["md_table"].split("_md_agg_")[0]
    table = entry.get("md_tract_table") or find_tract_table(stem, database)
    cols = resolve_columns(glue_columns(database, table))
    sql = build_release_weights_sql(table, cols)
    logger.info("release weights: %s from %s.%s (utility %s, CEC zone %s in the table)", key,
                database, table, "is" if cols.get("util") else "is NOT",
                "is" if cols.get("cec") else "is NOT")
    raw = pl.from_pandas(_athena(sql, database, table))
    df = finish(raw, *tract_lookups())
    path.parent.mkdir(parents=True, exist_ok=True)
    df.write_parquet(path)
    (path.parent / "california_weights_upgrade0.sql").write_text(sql, encoding="utf-8")
    logger.info("release weights: %d rows, %d models, %.0f weighted California buildings -> %s",
                df.height, df["bldg_id"].n_unique(), df["weight"].sum(), path)
    return path
