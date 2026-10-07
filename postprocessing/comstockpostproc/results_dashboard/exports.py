# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""What the assessment needs on disk and in Athena, so a driver does not guess.

The Athena side -- which aggregates to export, which tables and views must
exist, and building only what is missing -- is shared with the timeseries plots
and the AMI comparison, so it lives in `comstockpostproc.athena_tables`. Drivers
call `cspp.prepare_athena_tables(...)` once per run, and the assessment reads
what that produced. Constructing `ResultsDashboard` creates NO tables: it
probes and skips what it cannot find, reporting the cause.

What is left here are the two truth inputs the assessment reads from disk --
`AMI long.csv` (load_ami) and `CBECS wide.csv` (load_cbecs) -- each loaded from
its export if present and built otherwise.
"""

from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


def load_ami(truth_data_version: str = "v01", **kwargs):
    """A `cspp.AMI` that reads its exported CSV if present, and builds it if not.

    `reload_from_csv` is a footgun as a driver setting: True raises
    FileNotFoundError when 'AMI long.csv' is absent, False spends several minutes
    recomputing an 82 MB file that is probably already there -- and the setting
    sits far from the top of the file, so whoever hits it has no reason to know
    where to look. The answer is on disk, so read it from disk.
    """
    import os

    from ..ami import AMI

    # Mirrors how AMI.__init__ derives output_dir, rather than constructing one
    # just to ask it -- construction is what does the expensive work.
    here = os.path.dirname(os.path.abspath(__file__))
    csv = os.path.join(here, "..", "..", "output",
                       f"AMI {truth_data_version}", "AMI long.csv")
    have = os.path.exists(csv)
    logger.info("AMI: %s 'AMI long.csv'", "reloading" if have else "building")
    # A present export is sufficient on its own: with it, the constructor is
    # kept off S3 entirely (no truth-data check), so the reuse this loader
    # promises does not depend on credentials or on the raw files being here.
    return AMI(truth_data_version=truth_data_version, reload_from_csv=have,
               download_truth_data=not have, **kwargs)


def load_cbecs(cbecs_year: int = 2018, truth_data_version: str = "v01",
               color_hex: str = "#009E73", **kwargs):
    """A `cspp.CBECS` whose 'CBECS wide.csv' exists afterwards, whichever way.

    Same footgun as AMI, one step worse: `reload_from_csv=True` raises when the
    file is absent, and `reload_from_csv=False` neither reads nor WRITES it --
    only `export_to_csv_wide()` does -- so a first run that forgets the export
    gets no CBECS legs in the dashboard. Reads the file if present; otherwise
    builds the object and exports it.
    """
    import os

    from ..cbecs import CBECS

    here = os.path.dirname(os.path.abspath(__file__))
    csv = os.path.join(here, "..", "..", "output",
                       f"CBECS {cbecs_year}", "CBECS wide.csv")
    have = os.path.exists(csv)
    logger.info("CBECS: %s 'CBECS wide.csv'", "reloading" if have else "building")
    cbecs = CBECS(cbecs_year=cbecs_year, truth_data_version=truth_data_version,
                  color_hex=color_hex, reload_from_csv=have,
                  download_truth_data=not have, **kwargs)
    if not have:
        cbecs.export_to_csv_wide()
    return cbecs


def _stale_bills(upgrade_dirs, alloc_path, decision):
    """Which cached bills upgrades the library will rebuild because of the draw.

    Returns a list of upgrade ids (empty: none), or None when it cannot be told
    from the disk -- the run adopts another run's draw (SHARE / USE), whose id
    the report does not know. DRAW / REDRAW: every folder, the draw changes.
    REUSE or no decision: the folders whose marker is not the own draw's id.
    """
    import os
    import re
    from comstockpostproc import allocation
    ids = sorted({int(m.group(1)) for d in upgrade_dirs
                  for m in [re.search(r"upgrade=(\d+)", os.path.basename(d))] if m})
    action = str(decision or "").split(" ")[0]
    if action in ("DRAW", "REDRAW"):
        return ids
    if action in ("SHARE", "USE"):
        return None
    try:
        own = allocation.read_provenance(alloc_path) if os.path.exists(alloc_path) else None
    except Exception:                                             # noqa: BLE001
        own = None
    current = own.allocation_id if own else None
    stale = []
    for d in upgrade_dirs:
        m = re.search(r"upgrade=(\d+)", os.path.basename(d))
        if m and not allocation.derived_is_current(allocation.read_marker(d), current):
            stale.append(int(m.group(1)))
    return sorted(stale)


def report_caches(run_versions=(), estimate_versions=(), cbecs_year: int = 2018,
                  truth_data_version: str = "v01", reuse: bool = True,
                  output_dir: str | None = None, allocations: dict | None = None) -> list[dict]:
    """Log one line per cache a driver will touch -- what it is, whether it will be
    REUSED or BUILT, when it was written and where -- and return the rows.

    `allocations` maps a run version to what the driver decided about its stock
    allocation (a `Decision.describe()` from comstockpostproc.allocation: "REUSE own
    draw", "SHARE <run>'s draw", ...); the allocated-weights row then shows that
    decision instead of the old "recomputed on every pass".

    The drivers decide each cache from the disk (a cache that exists is reused,
    one that does not is built), so nobody has to remember what a machine holds;
    this makes that decision visible before anything expensive starts, with the
    dates that give a stale cache away. `reuse=False` is a driver's switch to
    rebuild the run-specific caches regardless -- simulation outputs, the
    apportionment, the bills -- for the case the disk cannot show: the inputs
    changed but the files still exist. CBECS and AMI depend on no run and are
    always reused; the allocated weights are recomputed by the drivers on every
    pass whatever the switch says.
    """
    import glob
    import os
    import re
    from datetime import datetime

    here = os.path.dirname(os.path.abspath(__file__))
    out = output_dir or os.path.join(here, "..", "..", "output")
    rows: list[dict] = []

    def add(scope, cache, paths, folder, run_specific=True, detail="", caveat="",
            recompute=False, action_override=None):
        found = [p for p in paths if os.path.exists(p)]
        newest = max((os.path.getmtime(p) for p in found), default=None)
        if recompute:
            action = "RECOMPUTE"
        elif not found:
            action = "BUILD"
        elif run_specific and not reuse:
            action = "REBUILD"
        elif action_override:
            action = action_override
        else:
            action = "REUSE"
        rows.append({"scope": scope, "cache": cache, "action": action,
                     "path": os.path.normpath(folder), "newest": newest,
                     "detail": detail, "caveat": caveat})

    def upgrades_in(paths, pattern):
        ids = sorted({int(m.group(1)) for p in paths
                      for m in [re.search(pattern, os.path.basename(p))] if m})
        return f"upgrades {', '.join(map(str, ids))}" if ids else ""

    for v in run_versions:
        base = os.path.join(out, f"ComStock {v}")
        sim_dir = os.path.join(base, "cached_simulation_outputs")
        sim = glob.glob(os.path.join(sim_dir, "**", "cached_simulation_outputs_upgrade*.parquet"),
                        recursive=True)
        add(v, "simulation outputs", sim, sim_dir, detail=upgrades_in(sim, r"upgrade(\d+)"))
        alloc = os.path.join(base, "cached_ComStock_alloc_wts.parquet")
        if allocations and v in allocations:
            # The driver's allocation plan (comstockpostproc.allocation.plan_allocations):
            # REUSE / DRAW / REDRAW <why> / SHARE <run>'s draw / USE <file>.
            action, _, rest = str(allocations[v]).partition(" ")
            found = [p for p in [alloc] if os.path.exists(p)]
            rows.append({"scope": v, "cache": "stock allocation", "action": action,
                         "path": os.path.normpath(alloc),
                         "newest": max((os.path.getmtime(p) for p in found), default=None),
                         "detail": rest, "caveat": ""})
        else:
            add(v, "allocated weights", [alloc], alloc, recompute=True,
                caveat="recomputed from the apportionment on every pass")
        bills_dir = os.path.join(base, "cached_allocated_weights_plus_bills")
        bills = glob.glob(os.path.join(bills_dir, "upgrade=*"))
        # The bills follow the draw: each upgrade folder carries the id of the draw it
        # was built from, and the library rebuilds a folder whose id differs from the
        # run's draw (or that has none while the draw has an id). Say so here, per
        # upgrade, instead of promising a reuse that step 4 will not honour.
        stale = _stale_bills(bills, alloc, (allocations or {}).get(v))
        if bills and stale is None:
            caveat = "rebuilt in step 4 unless built from the draw this run adopts"
        elif bills and stale:
            caveat = f"upgrades {', '.join(map(str, stale))} were built from another draw: rebuilt in step 4"
        else:
            caveat = "reuse=False deletes it"
        add(v, "bills", bills, bills_dir, detail=upgrades_in(bills, r"upgrade=(\d+)"),
            caveat=caveat, recompute=False,
            action_override=("REBUILD" if (bills and stale) else "CHECK" if (bills and stale is None) else None))
    for e in estimate_versions:
        app = os.path.join(out, f"Stock Estimation {e}", "cached_ComStock_apportionment.parquet")
        add(e, "apportionment", [app], app)
    cb = os.path.join(out, f"CBECS {cbecs_year}", "CBECS wide.csv")
    add(f"CBECS {cbecs_year}", "CBECS wide.csv", [cb], cb, run_specific=False)
    ami = os.path.join(out, f"AMI {truth_data_version}", "AMI long.csv")
    add(f"AMI {truth_data_version}", "AMI long.csv", [ami], ami, run_specific=False)

    logger.info("caches on this machine (reuse=%s); each row is what this pass will do:", reuse)
    for r in rows:
        when = (datetime.fromtimestamp(r["newest"]).strftime("%Y-%m-%d %H:%M")
                if r["newest"] else "absent")
        logger.info("  %-40s %-20s %-9s %-16s %s%s%s", r["scope"][:40], r["cache"],
                    r["action"], when, r["path"],
                    f"  [{r['detail']}]" if r["detail"] else "",
                    f"  -- {r['caveat']}" if r["caveat"] else "")
    return rows
