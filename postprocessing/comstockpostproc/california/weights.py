# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The California weight table: each model's weight by electric utility and CEC zone.

    path = save_california_weights(comstock)        # after the bills step of a driver
    path = california_weights_path('my_run')        # an earlier pass's file, or None

Utility (`in.electric_utility_eia_code`) and CEC climate zone are TRACT attributes. The
county and national aggregates the dashboard reads drop both, and counties straddle
utilities and zones, so the comparison needs the tract grain. The run's own
allocated-weights cache has it:

    output/ComStock <run>/cached_allocated_weights_plus_bills/upgrade=<N>/in.state=CA/*.parquet
    -> output/ComStock <run>/california_weights/california_weights_upgrade<N>.parquet

one row per (upgrade, bldg_id, in.electric_utility_eia_code, in.cec_climate_zone) with
the weight summed over the building's California tracts there, plus building type,
floor area, annual peak demand (the size proxy) and completion status. A few hundred
thousand rows; seconds to build. It stays LOCAL: no S3 export, no Athena table. The
dashboard passes the weights inline into its timeseries queries
(results_dashboard.calmac_shapes).

`weight` here is the weight the run's metadata tables carry (scaled to CBECS floor
area), so a California total read through this table agrees with one read through
the run's aggregates.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

import polars as pl

logger = logging.getLogger(__name__)

SUBDIR = "california_weights"
CEC_COL = "in.cec_climate_zone"
UTIL_COL = "in.electric_utility_eia_code"
PEAK_COL = "out.electricity.total.peak_demand..kw"
BLDG_TYPE_COL = "in.comstock_building_type"
SQFT_COL = "in.sqft..ft2"
SOURCE_CZ_COL = "in.ashrae_or_cec_climate_zone"
COLUMNS = ["upgrade", "bldg_id", UTIL_COL, CEC_COL, "weight", SQFT_COL, BLDG_TYPE_COL,
           PEAK_COL, "completed_status"]


def file_name(upgrade_id: int = 0) -> str:
    return f"california_weights_upgrade{int(upgrade_id)}.parquet"


def combine(alloc_ca: pl.LazyFrame, sim: pl.LazyFrame, upgrade_id: int = 0) -> pl.DataFrame:
    """The table from its two inputs (separated from the ComStock object for tests).

    alloc_ca  the California rows of the allocated weights: bldg_id, weight,
              in.electric_utility_eia_code, in.ashrae_or_cec_climate_zone
    sim       that upgrade's simulation outputs: bldg_id, in.comstock_building_type,
              in.sqft..ft2, out.electricity.total.peak_demand..kw, completed_status
    """
    a = alloc_ca.select(
        pl.col("bldg_id").cast(pl.Int64),
        pl.col("weight").cast(pl.Float64),
        pl.col(UTIL_COL).cast(pl.Int64),
        pl.col(SOURCE_CZ_COL).cast(pl.String).alias(CEC_COL),
    ).collect()
    total_in = float(a["weight"].sum())
    g = a.group_by(["bldg_id", UTIL_COL, CEC_COL]).agg(pl.col("weight").sum())
    if abs(float(g["weight"].sum()) - total_in) > 1e-6 * max(1.0, total_in):
        raise AssertionError("California weight changed while grouping by building, utility "
                             "and zone; the grouping lost or duplicated rows")
    s = sim.select(
        pl.col("bldg_id").cast(pl.Int64),
        pl.col(BLDG_TYPE_COL).cast(pl.String),
        pl.col(SQFT_COL).cast(pl.Float64),
        pl.col(PEAK_COL).cast(pl.Float64),
        pl.col("completed_status").cast(pl.String),
    ).collect().unique("bldg_id")
    out = g.join(s, on="bldg_id", how="left")
    no_sim = out.filter(pl.col("completed_status").is_null())
    if no_sim.height:
        logger.warning("california weights: %d rows (%.1f weighted buildings) have no simulation "
                       "output for their bldg_id; dropped", no_sim.height,
                       float(no_sim["weight"].sum()))
    failed = out.filter(pl.col("completed_status").is_not_null()
                        & (pl.col("completed_status") != "Success"))
    if failed.height:
        logger.warning("california weights: %d rows of models not completed successfully; dropped",
                       failed.height)
    out = out.filter(pl.col("completed_status") == "Success")
    no_util = out.filter(pl.col(UTIL_COL).is_null())
    if no_util.height:
        logger.info("california weights: %.1f weighted buildings sit in tracts with no electric "
                    "utility; they stay in the table and match no utility",
                    float(no_util["weight"].sum()))
    return (out.with_columns(pl.lit(int(upgrade_id)).cast(pl.Int64).alias("upgrade"))
            .select(COLUMNS).sort(["bldg_id", UTIL_COL, CEC_COL]))


def _bills_dir(comstock, upgrade_id: int) -> str:
    return f'{comstock.output_dir["fs_path"]}/cached_allocated_weights_plus_bills/upgrade={upgrade_id}'


def build_california_weights(comstock, upgrade_id: int = 0) -> pl.DataFrame:
    """The table for one ComStock object, from its bills cache and simulation outputs.
    Needs create_allocated_weights_plus_util_bills_for_upgrade(upgrade_id) first."""
    fs, so = comstock.output_dir["fs"], comstock.output_dir.get("storage_options")
    ca_dir = f"{_bills_dir(comstock, upgrade_id)}/in.state=CA"
    files = [f for f in fs.glob(f"{ca_dir}/*.parquet")]
    if type(fs).__name__ == "S3FileSystem":
        files = [f"s3://{f}" for f in files]
    if not files:
        raise FileNotFoundError(
            f"no California allocated weights in {ca_dir}: run "
            f"create_allocated_weights_plus_util_bills_for_upgrade({upgrade_id}) first")
    alloc = pl.scan_parquet(files, storage_options=so, hive_partitioning=False)
    sim = comstock.data.filter(pl.col(comstock.UPGRADE_ID) == upgrade_id)
    return combine(alloc, sim, upgrade_id)


def _newest_mtime(paths) -> float:
    return max((os.path.getmtime(p) for p in paths), default=0.0)


def save_california_weights(comstock, upgrade_id: int = 0, force: bool = False) -> Path:
    """Write output/ComStock <run>/california_weights/california_weights_upgrade<N>.parquet
    and return its path. Reused when it is newer than the bills cache it derives from
    (which REUSE_CACHES=False deletes, so a rebuilt cache forces a rebuild here)."""
    fs = comstock.output_dir["fs"]
    local = type(fs).__name__ != "S3FileSystem"
    out_dir = f'{comstock.output_dir["fs_path"]}/{SUBDIR}'
    path = f"{out_dir}/{file_name(upgrade_id)}"
    if local and not force and os.path.exists(path):
        src = [os.path.join(dp, f) for dp, _, fs_ in os.walk(_bills_dir(comstock, upgrade_id))
               for f in fs_]
        if src and os.path.getmtime(path) >= _newest_mtime(src):
            logger.info("california weights: reusing %s (newer than its bills cache)", path)
            return Path(path)
        logger.info("california weights: %s is older than its bills cache; rebuilding", path)
    df = build_california_weights(comstock, upgrade_id)
    fs.mkdirs(out_dir, exist_ok=True)
    with fs.open(path, "wb") as f:
        df.write_parquet(f)
    by_util = (df.group_by(UTIL_COL).agg(pl.col("weight").sum(), pl.col("bldg_id").n_unique())
               .sort("weight", descending=True).head(3))
    logger.info("california weights: %d rows, %d models -> %s; largest utilities %s",
                df.height, df["bldg_id"].n_unique(), path,
                {int(r[UTIL_COL]) if r[UTIL_COL] is not None else None:
                 (round(r["weight"]), r["bldg_id"]) for r in by_util.iter_rows(named=True)})
    return Path(path) if local else Path(f"s3://{path}")


def california_weights_path(run_version: str, upgrade_id: int = 0,
                            output_root: str | os.PathLike | None = None) -> Path | None:
    """output/ComStock <run_version>/california_weights/<file>, or None when absent --
    for an 'athena' run whose caches happen to be on this machine."""
    root = Path(output_root) if output_root else Path(__file__).resolve().parents[2] / "output"
    p = root / f"ComStock {run_version}" / SUBDIR / file_name(upgrade_id)
    return p if p.exists() else None
