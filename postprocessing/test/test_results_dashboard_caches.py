# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The cache report the drivers print before anything expensive starts. No Athena.

Pins: a cache that exists is REUSE, one that does not is BUILD, a run-specific
one under reuse=False is REBUILD, and the CBECS / AMI files (which depend on no
run) are reused regardless; the simulation and bills rows name the upgrades
they hold.
"""

import os

from comstockpostproc.results_dashboard import exports


def _touch(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("x")


def test_report_names_each_cache_and_its_action(tmp_path):
    out = str(tmp_path)
    _touch(os.path.join(out, "ComStock r1", "cached_simulation_outputs", "a",
                        "cached_simulation_outputs_upgrade0.parquet"))
    _touch(os.path.join(out, "ComStock r1", "cached_simulation_outputs", "a",
                        "cached_simulation_outputs_upgrade3.parquet"))
    _touch(os.path.join(out, "ComStock r1", "cached_allocated_weights_plus_bills", "upgrade=0", "p.parquet"))
    _touch(os.path.join(out, "Stock Estimation 2026R1", "cached_ComStock_apportionment.parquet"))
    _touch(os.path.join(out, "CBECS 2018", "CBECS wide.csv"))

    rows = {(r["scope"], r["cache"]): r for r in
            exports.report_caches(["r1", "r2"], ["2026R1", "2025R3"], output_dir=out)}
    assert rows[("r1", "simulation outputs")]["action"] == "REUSE"
    assert rows[("r1", "simulation outputs")]["detail"] == "upgrades 0, 3"
    assert rows[("r2", "simulation outputs")]["action"] == "BUILD"
    assert rows[("r1", "bills")]["action"] == "REUSE" and rows[("r1", "bills")]["detail"] == "upgrades 0"
    assert rows[("r1", "allocated weights")]["action"] == "RECOMPUTE"
    assert rows[("2026R1", "apportionment")]["action"] == "REUSE"
    assert rows[("2025R3", "apportionment")]["action"] == "BUILD"
    assert rows[("CBECS 2018", "CBECS wide.csv")]["action"] == "REUSE"
    assert rows[("AMI v01", "AMI long.csv")]["action"] == "BUILD"
    assert rows[("r1", "simulation outputs")]["newest"] is not None

    # reuse=False rebuilds what depends on the runs and leaves the truth-data files alone
    rows = {(r["scope"], r["cache"]): r for r in
            exports.report_caches(["r1"], ["2026R1"], reuse=False, output_dir=out)}
    assert rows[("r1", "simulation outputs")]["action"] == "REBUILD"
    assert rows[("r1", "bills")]["action"] == "REBUILD"
    assert rows[("2026R1", "apportionment")]["action"] == "REBUILD"
    assert rows[("CBECS 2018", "CBECS wide.csv")]["action"] == "REUSE"
