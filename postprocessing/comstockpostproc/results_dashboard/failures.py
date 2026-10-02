# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Model completion per run: failed simulations as a count and a share.

The metadata aggregates cannot say how many models failed. drop_failed_runs=True
removes failures before the export, so every row they hold is a success (checked
on three runs before this was written: 163,237 rows, all 'Success'). What
buildstockbatch's own crawl leaves beside them can: <run>_baseline carries every
sampled model with its completed_status, and <run>_upgrades the same per
upgrade. Published releases carry the same pair. Nothing here creates either
table; a run without them is reported as a gap, not an error.
"""

from __future__ import annotations

import logging

import pandas as pd

from . import athena

logger = logging.getLogger(__name__)

COLUMNS = ["run", "upgrade", "completed_status", "n", "total", "pct"]


def _stem(md_table: str) -> str:
    """`db.run_md_agg_national_by_state_parquet` -> `run`."""
    return md_table.split(".")[-1].split("_md_agg_")[0]


def assess_failures(runs, no_cache: bool = False) -> tuple[pd.DataFrame, dict[str, str]]:
    """One row per (run, upgrade, completed_status), with the partition total and share.

    Args:
        runs: AthenaRunRef values (md_table, database, key). The stem of the
            metadata table names the crawler's tables.
        no_cache: bypass the local query cache.

    Returns:
        (frame, notes). `notes` says, per run key, which table could not be read
        or that neither exists.
    """
    frames, notes = [], {}
    for r in runs:
        stem, db = _stem(r.md_table), (getattr(r, "database", None) or None)
        found = False
        for table, per_upgrade in ((f"{stem}_baseline", False), (f"{stem}_upgrades", True)):
            if not athena.table_exists(table, db):
                continue
            q = athena.qualify(table, db)
            sql = (f"SELECT {'upgrade, ' if per_upgrade else ''}completed_status, COUNT(*) AS n\n"
                   f"FROM {q}\nGROUP BY {'1, 2' if per_upgrade else '1'}")
            try:
                df = athena.query(sql, no_cache=no_cache, label=f"completion {table}")
            except Exception as exc:                                  # noqa: BLE001
                notes[r.key] = f"{table}: {exc}"
                continue
            if df.empty:
                continue
            if not per_upgrade:
                df.insert(0, "upgrade", 0)
            df["upgrade"] = df["upgrade"].astype(str)
            df.insert(0, "run", r.key)
            frames.append(df[["run", "upgrade", "completed_status", "n"]])
            found = True
        if not found and r.key not in notes:
            # A published release has neither table, but its aggregate keeps
            # completed_status on the upgrade rows (Fail / Invalid / Success);
            # its baseline rows are successes only, because a model that failed
            # never received a weight. Report what it can and say what it cannot.
            try:
                sql = ('SELECT upgrade, completed_status, COUNT(DISTINCT "bldg_id") AS n '
                       f"FROM {r.md_table} GROUP BY 1, 2")
                df = athena.query(sql, no_cache=no_cache, label=f"completion {stem} (aggregate)")
            except Exception as exc:                                  # noqa: BLE001
                df = pd.DataFrame()
                notes[r.key] = f"{stem}: no _baseline/_upgrades table and the aggregate could not be read ({exc})"
            if not df.empty:
                df["upgrade"] = df["upgrade"].astype(str)
                df.insert(0, "run", r.key)
                frames.append(df[["run", "upgrade", "completed_status", "n"]])
                notes[r.key] = (f"from the published aggregate ({stem}): measure rows carry "
                                "Fail/Invalid/Success, but baseline failures are not recorded "
                                "there (a model that failed never received a weight), so the "
                                "baseline row counts successes only")
            elif r.key not in notes:
                notes[r.key] = (f"no {stem}_baseline table in {db or athena._cfg()['database']}; "
                                "buildstockbatch's own crawl of the run creates it")
    if not frames:
        return pd.DataFrame(columns=COLUMNS), notes
    out = pd.concat(frames, ignore_index=True)
    out["n"] = out["n"].astype("int64")
    out["total"] = out.groupby(["run", "upgrade"])["n"].transform("sum")
    out["pct"] = out["n"] / out["total"] * 100
    return out[COLUMNS], notes
