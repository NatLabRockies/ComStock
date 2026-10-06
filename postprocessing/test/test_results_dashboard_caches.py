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


def test_the_drivers_allocation_plan_replaces_the_recompute_row(tmp_path):
    out = str(tmp_path)
    _touch(os.path.join(out, "ComStock r1", "cached_ComStock_alloc_wts.parquet"))
    rows = {(r["scope"], r["cache"]): r for r in exports.report_caches(
        ["r1", "r2"], [], output_dir=out,
        allocations={"r1": "REUSE own draw", "r2": "SHARE r1's draw (same sample and estimate)"})}
    assert rows[("r1", "stock allocation")]["action"] == "REUSE"
    assert rows[("r1", "stock allocation")]["newest"] is not None
    assert rows[("r2", "stock allocation")]["action"] == "SHARE"
    assert rows[("r2", "stock allocation")]["detail"] == "r1's draw (same sample and estimate)"
    assert ("r1", "allocated weights") not in rows
    # without a plan the old row stands
    rows = {(r["scope"], r["cache"]): r for r in exports.report_caches(["r1"], [], output_dir=out)}
    assert rows[("r1", "allocated weights")]["action"] == "RECOMPUTE"


def test_bills_rows_predict_the_rebuild_the_draw_will_cause(tmp_path):
    import polars as pl
    from comstockpostproc import allocation as al
    out = str(tmp_path)
    base = os.path.join(out, "ComStock r1")
    for u in (0, 3):
        _touch(os.path.join(base, "cached_allocated_weights_plus_bills", f"upgrade={u}", "p.parquet"))
    prov = al.new_provenance(drawn_for="r1", drawn_for_version="r1", estimate_version="2026R1",
                             bootstrap_coefficient=3, sample_hash="s" * 64, sample_rows=1,
                             n_models_drawn=1, n_models_available=1, n_rows=1)
    al.write_allocation(pl.DataFrame({"bldg_id": [1], "weight": [1.0]}),
                        os.path.join(base, "cached_ComStock_alloc_wts.parquet"), prov)
    # upgrade 0 built from this draw, upgrade 3 from before markers existed
    al.write_marker(os.path.join(base, "cached_allocated_weights_plus_bills", "upgrade=0"), prov.allocation_id)

    def bills(decision):
        rows = {(r["scope"], r["cache"]): r for r in exports.report_caches(
            ["r1"], [], output_dir=out, allocations={"r1": decision} if decision else None)}
        return rows[("r1", "bills")]

    b = bills("REUSE own draw")
    assert b["action"] == "REBUILD" and "upgrades 3 were built from another draw" in b["caveat"]
    b = bills("DRAW (no draw on disk)")
    assert b["action"] == "REBUILD" and "upgrades 0, 3" in b["caveat"]
    b = bills("SHARE r2's draw")
    assert b["action"] == "CHECK" and "unless built from the draw this run adopts" in b["caveat"]
    # every folder current: a plain reuse
    al.write_marker(os.path.join(base, "cached_allocated_weights_plus_bills", "upgrade=3"), prov.allocation_id)
    assert bills("REUSE own draw")["action"] == "REUSE"
    # reuse=False still wins
    rows = {(r["scope"], r["cache"]): r for r in exports.report_caches(
        ["r1"], [], output_dir=out, reuse=False, allocations={"r1": "REUSE own draw"})}
    assert rows[("r1", "bills")]["action"] == "REBUILD"
