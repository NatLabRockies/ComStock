# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The stock allocation as a portable file. No S3, no Athena.

Pins: the sample fingerprint is a fact about the file's content, not its
layout; a draw carries its provenance and polars still reads it; a draw is
only reused for the run it fits; runs on one sample share the run under
review's draw; a derived cache built from another draw is not inherited.
"""

import os

import polars as pl
import pytest

from comstockpostproc import allocation as al

ROWS = [("1", "Hospital", "G01", "1000"), ("2", "Warehouse", "G02", "2500"),
        ("10", "Hospital", "G03", "800")]
COLS = ["Building", "building_type", "tract", "sqft"]


def _csv(path, rows, cols=COLS, newline="\n"):
    order = [COLS.index(c) for c in cols]
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(",".join(cols) + newline)
        for r in rows:
            f.write(",".join(r[i] for i in order) + newline)
    return str(path)


def _prov(**over):
    base = dict(drawn_for="runA", drawn_for_version="runA", estimate_version="2026R1",
                bootstrap_coefficient=3, sample_hash="s" * 64, sample_rows=3,
                n_models_drawn=2, n_models_available=3, n_rows=9)
    base.update(over)
    return al.new_provenance(**base)


def _draw():
    return pl.DataFrame({"bldg_id": [1, 1, 2], "in.state": ["CO", "CO", "NM"],
                         "weight": [0.5, 0.25, 2.0]})


def test_fingerprint_depends_on_content_not_layout(tmp_path):
    a, n = al.sample_fingerprint(_csv(tmp_path / "a.csv", ROWS))
    assert n == 3
    # row order, column order and line endings do not matter
    assert al.sample_fingerprint(_csv(tmp_path / "b.csv", ROWS[::-1]))[0] == a
    assert al.sample_fingerprint(_csv(tmp_path / "c.csv", ROWS, cols=COLS[::-1]))[0] == a
    assert al.sample_fingerprint(_csv(tmp_path / "d.csv", ROWS, newline="\r\n"))[0] == a
    # one changed value does
    changed = [ROWS[0], ("2", "Warehouse", "G02", "2501"), ROWS[2]]
    assert al.sample_fingerprint(_csv(tmp_path / "e.csv", changed))[0] != a
    # a model more does too
    assert al.sample_fingerprint(_csv(tmp_path / "f.csv", ROWS + [("3", "Office", "G04", "5")]))[0] != a


def test_provenance_round_trip_and_polars_reads_the_file_unchanged(tmp_path):
    path = str(tmp_path / al.FILE_NAME)
    prov = _prov()
    al.write_allocation(_draw(), path, prov)
    assert al.read_provenance(path) == prov
    assert pl.scan_parquet(path).collect().equals(_draw())      # metadata is invisible to polars
    assert al.draw_model_ids(path) == {1, 2}
    # a copy keeps the id and says where it came from
    dst = str(tmp_path / "other" / al.FILE_NAME)
    os.makedirs(os.path.dirname(dst))
    copied = al.copy_allocation(path, dst, prov)
    got = al.read_provenance(dst)
    assert got.allocation_id == prov.allocation_id and got.copied_from == path
    assert copied == got
    assert pl.scan_parquet(dst).collect().equals(_draw())
    assert "drawn for runA" in prov.describe()


def test_a_newer_provenance_field_does_not_break_an_older_reader():
    text = _prov().to_json().replace('"copied_from": ""', '"copied_from": "", "future_field": 1')
    assert al.Provenance.from_json(text).drawn_for == "runA"


def test_status_missing_unverified_stale_valid(tmp_path):
    kw = dict(estimate_version="2026R1", bootstrap_coefficient=3, sample_hash="s" * 64)
    path = str(tmp_path / al.FILE_NAME)
    assert al.status_of(path, **kw).state == "missing"
    _draw().write_parquet(path)                                # a legacy draw: no provenance
    st = al.status_of(path, **kw)
    assert st.state == "unverified" and "before draws carried provenance" in st.describe()
    al.write_allocation(_draw(), path, _prov(estimate_version="2025R3"))
    st = al.status_of(path, **kw)
    assert st.state == "stale" and "estimate 2025R3 in the draw, 2026R1 here" in st.describe()
    al.write_allocation(_draw(), path, _prov(sample_hash="t" * 64))
    st = al.status_of(path, **kw)
    assert st.state == "stale" and "a different buildstock.csv" in st.describe()
    assert al.status_of(path, **{**kw, "sample_hash": None}).reasons[0].startswith(
        "this run's buildstock.csv is not on disk")
    al.write_allocation(_draw(), path, _prov())
    st = al.status_of(path, **kw)
    assert st.state == "valid" and st.provenance.drawn_for == "runA"


def test_reconcile_counts_and_words():
    r = al.reconcile({1, 2, 3}, {2, 3, 4, 5})
    assert (r.shared, r.only_in_draw, r.only_in_run) == (2, 1, 2)
    s = r.describe()
    assert "2 models weighted" in s and "1 models the draw picked" in s and "2 models in this run" in s
    assert al.reconcile({1}, {1}).describe() == "1 models weighted"


def _run(name, estimate="2026R1", sample="s1", state="missing", allocation=None):
    return dict(run=name, estimate=estimate, sample_hash=sample, allocation=allocation,
                status=al.AllocationStatus(state, f"{name}/draw.parquet",
                                           ["old"] if state in ("stale", "unverified") else []))


def test_runs_on_one_sample_share_the_run_under_reviews_draw():
    runs = [_run("a", state="valid"), _run("review", state="valid"), _run("c", state="valid")]
    plan = al.plan_allocations(runs, review_run="review", reuse=True)
    assert [(d.run, d.action, d.source) for d in plan] == [
        ("review", "reuse", ""), ("a", "share", "review"), ("c", "share", "review")]
    # the owner comes first; REUSE_CACHES=False redraws it and the others still share
    plan = al.plan_allocations(runs, review_run="review", reuse=False)
    assert plan[0].action == "redraw" and "REUSE_CACHES=False" in plan[0].describe()
    assert {d.action for d in plan[1:]} == {"share"}


def test_review_run_elsewhere_makes_the_first_listed_the_owner():
    runs = [_run("a"), _run("b"), _run("review", sample="s2")]
    plan = {d.run: d for d in al.plan_allocations(runs, review_run="review")}
    assert plan["a"].action == "draw" and plan["b"].source == "a"
    assert plan["review"].action == "draw" and plan["review"].source == ""


def test_unverified_or_stale_own_draw_is_redrawn_with_the_reason():
    plan = al.plan_allocations([_run("a", state="unverified")], review_run="a")
    assert plan[0].action == "redraw" and "unverified" in plan[0].reason
    plan = al.plan_allocations([_run("a", state="stale")], review_run="a")
    assert plan[0].action == "redraw" and "stale" in plan[0].reason


def test_different_estimate_or_sample_or_no_fingerprint_means_no_sharing():
    runs = [_run("a"), _run("b", estimate="2025R3"), _run("c", sample="s9"), _run("d", sample=None)]
    plan = al.plan_allocations(runs, review_run="a")
    assert all(d.action == "draw" for d in plan) and len(plan) == 4


def test_an_entry_naming_a_file_makes_its_whole_group_use_it():
    runs = [_run("a"), _run("b", allocation="s3://bucket/run/cached_ComStock_alloc_wts.parquet")]
    plan = al.plan_allocations(runs, review_run="a")
    assert [(d.run, d.action) for d in plan] == [("a", "use"), ("b", "use")]
    assert all(d.source.startswith("s3://") for d in plan)
    with pytest.raises(al.AllocationError):
        al.plan_allocations([_run("a", allocation="x.parquet"), _run("b", allocation="y.parquet")],
                            review_run="a")
    # two published copies of ONE draw (same id, different files) are one draw: the run under
    # review's file is the one every member uses
    runs = [dict(_run("a", allocation="s3://x/a/a/d.parquet"), allocation_id="id1"),
            dict(_run("b", allocation="s3://x/b/b/d.parquet"), allocation_id="id1")]
    plan = al.plan_allocations(runs, review_run="b")
    assert [(d.run, d.action, d.source) for d in plan] == [
        ("a", "use", "s3://x/b/b/d.parquet"), ("b", "use", "s3://x/b/b/d.parquet")]


def test_publish_draw_copies_the_bytes_and_names_the_place(tmp_path):
    src = str(tmp_path / al.FILE_NAME)
    al.write_allocation(_draw(), src, _prov())
    remote = tmp_path / "remote"
    remote.mkdir()
    dst = al.publish_draw(src, None, str(remote), None)
    assert dst.replace("\\", "/").endswith(f"remote/{al.FILE_NAME}")
    assert open(dst, "rb").read() == open(src, "rb").read()
    assert al.read_provenance(dst).allocation_id == al.read_provenance(src).allocation_id
    assert al.published_draw_url("eulp/euss_com", "r") == f"s3://eulp/euss_com/r/r/{al.FILE_NAME}"


def test_derived_cache_follows_the_draw(tmp_path):
    assert al.derived_is_current(None, None)            # legacy draw: nothing to compare
    assert al.derived_is_current("abc", None)
    assert not al.derived_is_current(None, "abc")       # cache older than markers, draw has an id
    assert not al.derived_is_current("old", "abc")
    assert al.derived_is_current("abc", "abc")
    folder = str(tmp_path / "cached_allocated_weights_plus_bills" / "upgrade=0")
    os.makedirs(folder)
    assert al.read_marker(folder) is None
    al.write_marker(folder, "abc")
    assert al.read_marker(folder) == "abc"
    assert os.path.basename(os.listdir(folder)[0]).startswith("_")   # skipped by hive readers
