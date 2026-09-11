# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Athena adapter for the results dashboard.

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
   Rebuilding a table is the other way a cached result goes stale, so every
   entry keeps its SQL in a `.sql` sidecar and `invalidate_cache(run)` drops
   the entries that read a run once prepare_athena_tables has exported or
   crawled it again.

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
    "RESULTS_DASHBOARD_CACHE_DIR", Path.home() / ".cache" / "comstock_results_dashboard"))

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
            "results_dashboard.athena.configure(database=..., reflect_table=...) must be "
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
    # An EMPTY result is deliberately NOT cached. Every existence probe below is
    # an information_schema query, and there "no rows" means "no such table
    # YET", not "no such table". Caching that makes a table created later --
    # e.g. by create_sightglass_tables earlier in the SAME postprocessing run --
    # permanently invisible, so the assessment skips a run whose tables are
    # sitting right there. Absence is the one answer that must not be cached.
    if not df.empty:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        df.to_parquet(path)
        # The SQL beside the result, so invalidate_cache can find every entry
        # that read a given run's tables after those tables are rebuilt.
        path.with_suffix(".sql").write_text(sql, encoding="utf-8")
    return df


def invalidate_cache(needle: str) -> int:
    """Drop every cached result whose SQL mentions `needle` -- a run's table
    prefix, after prepare_athena_tables has re-exported or re-crawled it.

    The cache is keyed on SQL text, so a rebuilt table would otherwise keep
    answering from the results of its previous incarnation, silently. Entries
    written before the `.sql` sidecar existed cannot be matched and are left
    alone; `no_cache=True` (or deleting CACHE_DIR) covers those.
    """
    if not CACHE_DIR.exists():
        return 0
    needle, n = needle.lower(), 0
    for sidecar in CACHE_DIR.glob("*.sql"):
        try:
            if needle not in sidecar.read_text(encoding="utf-8").lower():
                continue
            for p in (sidecar.with_suffix(".parquet"), sidecar):
                if p.exists():
                    p.unlink()
            n += 1
        except OSError as exc:
            logger.info("cache: could not drop %s (%s)", sidecar.name, exc)
    if n:
        logger.info("cache: dropped %d cached result(s) that read %s", n, needle)
    return n


def glue_table_names(database: str | None = None, prefix: str = "") -> list[str]:
    """Tables in a database, listed through GLUE rather than Athena SQL.

    WHY NOT information_schema. Every SQL path here goes through
    BuildStockQuery, whose constructor EAGERLY reflects the table it is given --
    so building a client requires a table that already exists, which is the very
    thing table discovery is trying to establish. That is a deadlock, and it is
    not hypothetical: `from_comstock` guesses the published-release name
    `<run>_md_agg_national_parquet`, a crawled run actually gets
    `<run>_md_agg_national_by_state_parquet`, and the guess being wrong meant the
    client could not be constructed, so discovery could not run, so the
    assessment skipped a run whose tables were sitting right there.

    Glue answers "what tables exist" with no reflection and no bootstrap.
    """
    import boto3

    db = database or _cfg()["database"]
    glue = boto3.client("glue", region_name="us-west-2")
    kw = {"DatabaseName": db}
    if prefix:
        kw["Expression"] = f"{prefix}*"
    names, resp = [], glue.get_tables(**kw)
    names += [t["Name"] for t in resp["TableList"]]
    while "NextToken" in resp:
        resp = glue.get_tables(NextToken=resp["NextToken"], **kw)
        names += [t["Name"] for t in resp["TableList"]]
    return sorted(names)


def _split(table: str, database: str | None) -> tuple[str, str]:
    """Resolve a possibly-qualified table into (bare name, database to look in).

    A `db.table` reference must be PROBED in its own database:
    `information_schema` matches `table_name` against the bare name, so passing
    the qualified string through would look for a table literally called
    "buildstock_sdr.foo" and find nothing. Splitting here rather than at each
    call site keeps the dozen probe callers -- annual, distributions,
    design_params, measures, timeseries -- working unchanged whether the run
    they are describing is local or cross-database.
    """
    if "." in table:
        db, _, bare = table.partition(".")
        return bare, db
    return table, (database or _cfg()["database"])


def table_columns(table: str, no_cache: bool = False,
                  database: str | None = None) -> set[str]:
    """Columns a table actually has.

    Queries are built from what exists rather than from what the data dictionary
    lists, because schemas drift between releases: 2024 R2 publishes no
    as-simulated climate zone and no fuel-oil totals.
    """
    table, db = _split(table, database)
    sql = ("SELECT column_name FROM information_schema.columns "
           f"WHERE table_schema = '{db}' AND table_name = '{table}'")
    return set(query(sql, no_cache=no_cache, label=f"columns of {db}.{table}")["column_name"])


def table_column_types(table: str, no_cache: bool = False,
                       database: str | None = None) -> dict[str, str]:
    """Column name -> RAW Athena data_type string.

    Raw on purpose: callers match the lower-case Athena spelling. See note 2 in
    the module docstring before replacing this with get_cols.
    """
    table, db = _split(table, database)
    sql = ("SELECT column_name, data_type FROM information_schema.columns "
           f"WHERE table_schema = '{db}' AND table_name = '{table}'")
    df = query(sql, no_cache=no_cache, label=f"column types of {db}.{table}")
    return dict(zip(df["column_name"], df["data_type"]))


def table_names(no_cache: bool = False,
                database: str | None = None) -> list[str]:
    """Every table in the configured database.

    Used to DISCOVER a run's aggregate table rather than assume its name. The
    crawled table name follows the `geo_top_dir` of the export that produced it
    -- `geo_top_dir='national_by_state'` yields
    `<run>_md_agg_national_by_state_parquet`, not the published releases'
    `<run>_md_agg_national_parquet` -- so it cannot be derived from the run name
    alone. Filtering happens in Python on purpose: `_` is a single-character
    wildcard in SQL LIKE, so a run name containing one makes a LIKE pattern
    match tables belonging to other runs.
    """
    # Glue, not information_schema: this is called BEFORE any table name is
    # known, and an Athena query cannot run until one is. See glue_table_names.
    return glue_table_names(database)


def table_exists(table: str, database: str | None = None) -> bool:
    """Whether a table is reachable; decides whether a leg runs or is skipped.

    Returns False rather than raising on ANY failure -- missing table, missing
    workgroup, expired credentials. The assessment is an optional step and must
    never take a postprocessing run down with it.
    """
    # Asked through Glue rather than by querying the table, so that a table
    # which does not exist reports False instead of failing to construct a
    # client -- the two were indistinguishable before, and the second took
    # discovery down with it.
    bare, db = _split(table, database)
    try:
        return bare in set(glue_table_names(db, prefix=bare.split("_")[0]))
    except Exception as exc:                                  # noqa: BLE001
        logger.warning("cannot reach %s: %s", table, exc)
        return False


def qualify(table: str, database: str | None) -> str:
    """`database.table` when that database is not the configured one.

    Athena resolves a qualified name from any configured database -- one query
    can read an unqualified table in `enduse` and a qualified one in
    `buildstock_sdr` at the same time. So comparing your own crawled run against
    a published release needs only this, not a second assessment: qualify the
    release's tables and every existing SQL builder keeps working unchanged.

    Returns the name untouched when it is already qualified, when no database is
    given, or when it matches the configured one -- the common case, kept bare
    so the emitted SQL stays readable.
    """
    if not table or not database or "." in table:
        return table
    return table if database == _cfg()["database"] else f"{database}.{table}"


# ---------------------------------------------------------------------------
# baseline predicate, typed to the column
# ---------------------------------------------------------------------------
# Published releases and crawled runs store `upgrade` as bigint; some older
# releases expose it as varchar, and Athena does not coerce `varchar = integer`.
# `measures` probes the type for its own literals; the single-run legs share
# this one.
DEFAULT_BASE_WHERE = "upgrade = 0 AND completed_status = 'Success'"


def upgrade_literal(value, col_type: str | None) -> str:
    """`0` for an integer `upgrade` column, `'0'` for a varchar one."""
    t = str(col_type or "").lower()
    return f"'{value}'" if ("char" in t or "string" in t) else str(value)


def baseline_where(table: str, no_cache: bool = False) -> str:
    """`upgrade = 0 AND completed_status = 'Success'`, the literal typed to
    `table`'s own `upgrade` column. Falls back to the integer form when the
    column types cannot be read -- what every table seen so far uses."""
    try:
        col_type = table_column_types(table, no_cache=no_cache).get("upgrade")
    except Exception as exc:                                      # noqa: BLE001
        logger.info("cannot read column types of %s (%s); assuming integer upgrade",
                    table, exc)
        col_type = None
    return f"upgrade = {upgrade_literal(0, col_type)} AND completed_status = 'Success'"
