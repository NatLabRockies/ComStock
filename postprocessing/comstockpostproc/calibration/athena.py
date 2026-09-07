# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Athena adapter for the calibration assessment.

Runs SQL against ComStock Athena tables -- published SDR/OEDI releases in
`buildstock_sdr`, or run tables crawled into another database -- and returns
DataFrames. Results are cached to parquet so a repeat assessment is nearly free.

WHY THIS WRAPS BuildStockQuery. The assessment emits its own hand-written SQL
(design_params.build_params_sql, heating_fuel, annual, measures, ...), so it
needs an "execute arbitrary SQL, hand me a DataFrame" primitive.
`BuildStockQuery.execute(query)` is exactly that, and the package already
depends on buildstock_query, so this routes through it rather than introducing a
second Athena client. Verified equivalent before switching: the same grouped,
weighted query returned identical values and identical model counts through this
shim and through pyathena.

ONE CLIENT PER DATABASE, NOT PER TABLE. BuildStockQuery's constructor is eager
-- it reflects `table_name` and indexes its columns -- but `execute()` simply
runs the SQL it is given. So the reflected table does not have to be the one the
SQL reads; it only has to EXIST, so construction succeeds. What actually matters
is `db_name`, because the assessment's SQL uses bare unqualified table names and
only resolves against the right database. Hence `configure()` once per
assessment, and every query site stays as it was. The tuple `table_name` form is
what allows reflecting a metadata aggregate table instead of a
`<run>_baseline`/`<run>_timeseries` pair; the precedent is gap/comprofile.py.

TWO THINGS THAT LOOK LIKE THEY SHOULD BE SIMPLER AND ARE NOT.

1. The cache key includes the CONNECTION, not just the SQL. Keying on SQL text
   alone is how the wrong-workgroup bug survived for months: every repeat query
   was a cache hit, so the first genuinely new query was the first to reach
   Athena at all, and it failed long after the run looked healthy. A cached
   result is only valid for the database and workgroup that produced it.

2. Column introspection stays on `information_schema` rather than
   `BuildStockQuery.get_cols`. Callers string-match the RAW Athena `data_type`
   -- ami_shapes and measures test `.startswith("bigint")` / `("varchar")` to
   decide how to cast -- and get_cols returns SQLAlchemy types whose names are
   upper case. That substitution would not raise; it would silently stop
   matching and change how columns are cast.
"""

from __future__ import annotations

import hashlib
import logging
import os
import time
from pathlib import Path

import pandas as pd

from ..athena_config import ATHENA_WORKGROUP

logger = logging.getLogger(__name__)

CACHE_DIR = Path(os.environ.get(
    "CALIB_CACHE_DIR", Path.home() / ".cache" / "comstock_calibration"))

# Published SDR/OEDI releases live here. A privately crawled run lives in
# whichever database create_sightglass_tables wrote it to.
DEFAULT_DATABASE = "buildstock_sdr"
# The column vocabulary the published tables use (bldg_id, weight, in./out.,
# timestamp). BuildStockQuery reflects a schema on construction, so it must be
# told which one to expect.
DEFAULT_DB_SCHEMA = "comstock_oedi"

_STATE: dict = {"database": None, "reflect_table": None, "client": None}


def configure(database: str | None = None, reflect_table: str | None = None) -> None:
    """Point the adapter at a database, once per assessment.

    `reflect_table` only needs to be a table that exists in that database --
    BuildStockQuery reflects it at construction. Pass the primary run's metadata
    table, which the assessment has to have anyway.
    """
    _STATE["database"] = database or os.environ.get("ATHENA_DATABASE", DEFAULT_DATABASE)
    _STATE["reflect_table"] = reflect_table
    _STATE["client"] = None            # force a reconnect on the next query


def _cfg() -> dict:
    return {
        "database": _STATE["database"] or os.environ.get("ATHENA_DATABASE", DEFAULT_DATABASE),
        "workgroup": os.environ.get("ATHENA_WORKGROUP", ATHENA_WORKGROUP),
        "db_schema": os.environ.get("ATHENA_DB_SCHEMA", DEFAULT_DB_SCHEMA),
    }


def _client():
    if _STATE["client"] is not None:
        return _STATE["client"]
    from buildstock_query import BuildStockQuery

    cfg, table = _cfg(), _STATE["reflect_table"]
    if not table:
        raise RuntimeError(
            "calibration.athena.configure(database=..., reflect_table=...) must be "
            "called before any query; reflect_table selects the schema "
            "BuildStockQuery reflects on construction.")
    logger.info("connecting to Athena: db=%s workgroup=%s (reflecting %s)",
                cfg["database"], cfg["workgroup"], table)
    _STATE["client"] = BuildStockQuery(
        workgroup=cfg["workgroup"],
        db_name=cfg["database"],
        table_name=(table, None, None),
        db_schema=cfg["db_schema"],
        buildstock_type="comstock",
        skip_reports=True,
    )
    return _STATE["client"]


def _cache_path(sql: str) -> Path:
    cfg = _cfg()
    # Connection in the key -- see note 1 in the module docstring.
    stamp = f"{cfg['database']}|{cfg['workgroup']}|{cfg['db_schema']}|{sql.strip().lower()}"
    return CACHE_DIR / f"{hashlib.md5(stamp.encode()).hexdigest()[:16]}.parquet"


def query(sql: str, no_cache: bool = False, label: str = "") -> pd.DataFrame:
    """Execute SQL, returning a DataFrame. Cached on disk by SQL + connection."""
    path = _cache_path(sql)
    if not no_cache and path.exists():
        logger.info("cache hit%s: %s", f" ({label})" if label else "", path.name)
        return pd.read_parquet(path)

    t0 = time.time()
    df = _client().execute(sql)
    if not isinstance(df, pd.DataFrame):
        # execute() returns a future when run_async is set; it is not set here,
        # so anything else means the API moved and results must not be trusted.
        raise TypeError(
            f"BuildStockQuery.execute returned {type(df).__name__}, expected DataFrame")
    logger.info("athena%s: %d rows in %.1fs",
                f" ({label})" if label else "", len(df), time.time() - t0)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    df.to_parquet(path)
    return df


def table_columns(table: str, no_cache: bool = False) -> set[str]:
    """Columns a table actually has.

    Queries are built from what exists rather than from what the data dictionary
    lists, because schemas drift between releases: 2024 R2 publishes no
    as-simulated climate zone and no fuel-oil totals.
    """
    cfg = _cfg()
    sql = ("SELECT column_name FROM information_schema.columns "
           f"WHERE table_schema = '{cfg['database']}' AND table_name = '{table}'")
    return set(query(sql, no_cache=no_cache, label=f"columns of {table}")["column_name"])


def table_column_types(table: str, no_cache: bool = False) -> dict[str, str]:
    """Column name -> RAW Athena data_type string.

    Raw on purpose: callers match the lower-case Athena spelling. See note 2 in
    the module docstring before replacing this with get_cols.
    """
    cfg = _cfg()
    sql = ("SELECT column_name, data_type FROM information_schema.columns "
           f"WHERE table_schema = '{cfg['database']}' AND table_name = '{table}'")
    df = query(sql, no_cache=no_cache, label=f"column types of {table}")
    return dict(zip(df["column_name"], df["data_type"]))


def table_exists(table: str) -> bool:
    """Whether a table is reachable; decides whether a leg runs or is skipped.

    Returns False rather than raising on ANY failure -- missing table, missing
    workgroup, expired credentials. The assessment is an optional step and must
    never take a postprocessing run down with it.
    """
    try:
        return bool(table_columns(table))
    except Exception as exc:                                  # noqa: BLE001
        logger.warning("cannot reach %s: %s", table, exc)
        return False
