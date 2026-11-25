# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The decision behind prepare_athena_tables, without AWS.

`plan` is handed the table names Glue listed and says what to export, whether
to crawl, and whether to create views. These pin that logic so a driver's
"reuse what exists" behaviour cannot silently regress into re-exporting ~3,100
county files per upgrade, or into skipping a view something reads.
"""

import os
import types

from comstockpostproc import athena_tables as at

RUN = "myrun"
NATIONAL = f"{RUN}_md_agg_national_by_state_parquet"
COUNTY = f"{RUN}_md_agg_by_state_and_county_parquet"
TS = f"{RUN}_timeseries"


def test_nothing_missing_means_nothing_to_do():
    names = {NATIONAL, COUNTY, TS, NATIONAL.replace("_parquet", "_vu"),
             COUNTY.replace("_parquet", "_vu"), f"{TS}_vu"}
    p = at.plan(names, RUN, "enduse", county=True, views=True)
    assert p.nothing_to_do
    assert "already has every table" in p.describe()


def test_empty_run_exports_national_only_unless_county_wanted():
    p = at.plan(set(), RUN, "enduse")
    assert p.export == [at.NATIONAL_EXPORT] and p.crawl and not p.views
    # County only joins the export when the timeseries table it serves exists.
    p = at.plan({TS}, RUN, "enduse", county=True)
    assert p.export == [at.NATIONAL_EXPORT, at.COUNTY_EXPORT]
    p = at.plan(set(), RUN, "enduse", county=True)
    assert p.export == [at.NATIONAL_EXPORT] and p.county_skipped


def test_county_is_not_re_exported_when_present():
    p = at.plan({NATIONAL, COUNTY}, RUN, "enduse", county=True)
    assert p.nothing_to_do


class _Stub:
    """A ComStock stand-in: a local draw file, and a local folder playing the S3 prefix."""

    def __init__(self, tmp_path, allocation_id):
        import polars as pl
        from fsspec.implementations.local import LocalFileSystem
        from comstockpostproc import allocation as al
        self.comstock_run_name = RUN
        self.allocation_id = allocation_id
        self.output_dir = {"fs": LocalFileSystem(), "fs_path": str(tmp_path / "local")}
        self.remote = str(tmp_path / "remote")
        for d in (self.output_dir["fs_path"], self.remote):
            os.makedirs(d, exist_ok=True)
        self.allocation_path = f"{self.output_dir['fs_path']}/{al.FILE_NAME}"
        prov = al.new_provenance(drawn_for=RUN, drawn_for_version=RUN, estimate_version="2026R1",
                                 bootstrap_coefficient=3, sample_hash="s" * 64, sample_rows=1,
                                 n_models_drawn=1, n_models_available=1, n_rows=1)
        prov.allocation_id = allocation_id
        al.write_allocation(pl.DataFrame({"bldg_id": [1], "weight": [1.0]}), self.allocation_path, prov)

    def setup_fsspec_filesystem(self, s3_dir, aws_profile_name=None):
        from fsspec.implementations.local import LocalFileSystem
        return {"fs": LocalFileSystem(), "fs_path": self.remote}


def test_export_record_decides_staleness_and_publishes_the_draw(tmp_path):
    from comstockpostproc import allocation as al
    c = _Stub(tmp_path, "a" * 32)
    # no record beside the export: the tables cannot be the current draw
    assert "no record of their stock allocation" in at._stale_allocation_reason(c, "s3://x/r/r")
    assert at._remote_allocation_id(c, "s3://x/r/r") is None
    # after an export the record and the draw file sit beside it, and nothing is stale
    assert at._record_allocation(c, "s3://x/r/r") == "a" * 32
    assert at._remote_allocation_id(c, "s3://x/r/r") == "a" * 32
    assert at._stale_allocation_reason(c, "s3://x/r/r") == ""
    published = f"{c.remote}/{al.FILE_NAME}"
    assert al.read_provenance(published).allocation_id == "a" * 32
    assert al.published_draw_url("eulp/euss_com/", RUN) == f"s3://eulp/euss_com/{RUN}/{RUN}/{al.FILE_NAME}"
    # the run moves to another draw: the record names the old one
    c.allocation_id = "b" * 32
    assert "exported from stock allocation aaaaaaaa; the run now uses bbbbbbbb" in \
        at._stale_allocation_reason(c, "s3://x/r/r")
    # a legacy draw (no id) compares nothing
    c.allocation_id = None
    assert at._stale_allocation_reason(c, "s3://x/r/r") == ""


def _recorded(tmp_path, recorded_id, current_id):
    """A run whose export records `recorded_id` beside its tables (None: no record), with the
    draw file there too, postprocessed now with `current_id`."""
    c = _Stub(tmp_path, recorded_id or "0" * 32)
    if recorded_id:
        at._record_allocation(c, "s3://x/r/r")
    c.allocation_id = current_id
    c.s3_base_dir = "bucket/prefix"
    return c


def test_new_weights_on_existing_tables_stop_before_anything_is_written(tmp_path, monkeypatch):
    import pytest
    monkeypatch.setattr(at, "existing_tables", lambda run, db: {NATIONAL, TS})
    c = _recorded(tmp_path, "a" * 32, "b" * 32)
    with pytest.raises(at.TablesWeightsMismatch) as e:
        at.check_tables_weights(c, "enduse")
    msg = str(e.value)
    assert "built with stock allocation aaaaaaaa, and this pass uses bbbbbbbb" in msg
    assert f"set REBUILD_ATHENA_TABLES = True: that removes all of {RUN}'s tables, every upgrade" in msg
    assert f"set WEIGHTS to s3://bucket/prefix/{RUN}/{RUN}/cached_ComStock_alloc_wts.parquet" in msg
    # the message names the settings of the driver that asks
    with pytest.raises(at.TablesWeightsMismatch, match="rebuild=True on its RUNS entry .*set weights= on its"):
        at.check_tables_weights(c, "enduse", rebuild_setting=f"rebuild=True on its RUNS entry ({RUN})",
                                weights_setting="weights= on its RUNS entry")


def test_tables_without_a_record_stop_too_and_only_a_rebuild_is_offered(tmp_path, monkeypatch):
    import pytest
    monkeypatch.setattr(at, "existing_tables", lambda run, db: {NATIONAL})
    c = _recorded(tmp_path, None, "b" * 32)
    with pytest.raises(at.TablesWeightsMismatch) as e:
        at.check_tables_weights(c, "enduse")
    assert "carry no record of the weights they were built with" in str(e.value)
    assert "set WEIGHTS" not in str(e.value)


def test_the_weights_check_passes_when_nothing_conflicts(tmp_path, monkeypatch):
    monkeypatch.setattr(at, "existing_tables", lambda run, db: {NATIONAL, TS})
    c = _recorded(tmp_path, "a" * 32, "a" * 32)
    at.check_tables_weights(c, "enduse")                    # the tables carry this pass's weights
    c.allocation_id = "b" * 32
    at.check_tables_weights(c, "enduse", rebuild=True)      # a rebuild replaces them, all of them
    c.allocation_id = None
    at.check_tables_weights(c, "enduse")                    # a legacy draw: nothing to compare
    c.allocation_id = "b" * 32
    # no tables of its own (another run sharing the prefix does not count), or Glue unreadable
    for listed in (set(), {TS, f"{RUN}_v2_md_agg_national_by_state_parquet"}, None):
        monkeypatch.setattr(at, "existing_tables", lambda run, db, listed=listed: listed)
        at.check_tables_weights(c, "enduse")


def test_views_alone_are_created_without_an_export():
    # Tables crawled, views never made: the cheap step only.
    p = at.plan({NATIONAL, TS}, RUN, "enduse", views=True)
    assert p.export == [] and not p.crawl and p.views
    assert p.describe() == f"{RUN} in enduse: create views"


def test_new_export_always_gets_views_when_views_are_wanted():
    p = at.plan({NATIONAL, NATIONAL.replace("_parquet", "_vu"), TS}, RUN, "enduse",
                county=True, views=True)
    assert p.export == [at.COUNTY_EXPORT] and p.views


def test_missing_timeseries_table_is_reported_not_repaired():
    p = at.plan({NATIONAL, NATIONAL.replace("_parquet", "_vu")}, RUN, "enduse", views=True)
    assert p.nothing_to_do                      # nothing here can create it
    assert p.timeseries_missing
    assert f"{TS} is absent" in p.describe()


def test_unlistable_glue_plans_everything():
    # The plan says "everything"; prepare_athena_tables declines to act on it
    # unless rebuild=True (see test below).
    p = at.plan(None, RUN, "enduse", county=True, views=True)
    assert p.unknown and p.export == [at.NATIONAL_EXPORT, at.COUNTY_EXPORT]
    assert p.crawl and p.views
    assert "could not list" in p.describe()


def test_another_run_sharing_the_prefix_does_not_satisfy_this_one():
    other = {f"{RUN}_v2_md_agg_national_by_state_parquet"}
    p = at.plan(other, RUN, "enduse")
    assert p.export == [at.NATIONAL_EXPORT]


def test_a_run_named_county_is_matched_by_exact_name_not_substring():
    run = "county_10k"
    names = {f"{run}_md_agg_national_by_state_parquet",
             f"{run}_md_agg_by_state_and_county_parquet"}
    p = at.plan(names, run, "enduse", county=True)
    assert p.nothing_to_do


def test_a_puma_aggregate_does_not_force_views_every_run():
    # create_views names PUMA views per census region, never <table>_vu, and
    # nothing here reads them -- so their absence must not mean "create views".
    names = {NATIONAL, NATIONAL.replace("_parquet", "_vu"),
             f"{RUN}_md_agg_by_state_and_puma_parquet"}
    p = at.plan(names, RUN, "enduse", views=True)
    assert not p.views and p.nothing_to_do


def test_county_view_is_only_required_when_county_is_wanted():
    names = {NATIONAL, COUNTY, NATIONAL.replace("_parquet", "_vu"), TS, f"{TS}_vu"}
    assert at.plan(names, RUN, "enduse", county=False, views=True).nothing_to_do
    assert at.plan(names, RUN, "enduse", county=True, views=True).views


def _stub(**kw):
    base = dict(comstock_run_name=RUN, s3_base_dir="bucket/prefix", include_upgrades=True,
                upgrade_ids_to_process=[0, 1, 2], timeseries_locations_to_plot={})
    base.update(kw)
    return types.SimpleNamespace(**base)


def test_prepare_does_not_export_blind_when_glue_cannot_be_listed(monkeypatch):
    monkeypatch.setattr(at, "existing_tables", lambda run, db: None)
    stub = _stub()
    stub.export_metadata_and_annual_results_for_upgrade = lambda **kw: (_ for _ in ()).throw(
        AssertionError("must not export"))
    assert at.prepare_athena_tables(stub, "enduse") is False


def test_prepare_returns_true_and_touches_nothing_when_complete(monkeypatch):
    monkeypatch.setattr(at, "existing_tables", lambda run, db: {NATIONAL})
    # the national table holds every upgrade the run loaded
    monkeypatch.setattr(at, "_upgrades_in_table", lambda table, db, reflect: {0, 1, 2})
    stub = _stub()
    stub.export_metadata_and_annual_results_for_upgrade = lambda **kw: (_ for _ in ()).throw(
        AssertionError("must not export"))
    assert at.prepare_athena_tables(stub, "enduse") is True


def test_baseline_only_driver_exports_the_baseline_alone():
    # ComStock fills upgrade_ids_to_process from every results file on disk,
    # even when the driver said include_upgrades=False.
    assert at._run_upgrade_ids(_stub(include_upgrades=False)) == [0]
    assert at._run_upgrade_ids(_stub()) == [0, 1, 2]


def test_upgrade_ids_restricts_county_but_never_national(monkeypatch):
    monkeypatch.setattr(at, "_forget_cached_queries", lambda run: None)   # keep off ~/.cache
    monkeypatch.setattr(at, "existing_tables", lambda run, db: set())
    stub = _stub()
    stub.STATE_ABBRV, stub.CZ_ASHRAE, stub.COUNTY_ID = "s", "cz", "c"
    stub.setup_fsspec_filesystem = lambda *a, **k: "out"
    calls = []
    stub.export_metadata_and_annual_results_for_upgrade = (
        lambda upgrade_id, geo_exports, output_dir: calls.append(
            (upgrade_id, tuple(g["geo_top_dir"] for g in geo_exports))))
    stub.create_sightglass_tables = lambda **kw: None
    stub.fix_timeseries_tables = lambda *a: None       # ami=True also builds views
    stub.create_views = lambda *a: None
    # After the crawl the tables are "there".
    listed = iter([{TS}, {NATIONAL, COUNTY, TS}])
    monkeypatch.setattr(at, "existing_tables", lambda run, db: next(listed))
    assert at.prepare_athena_tables(stub, "enduse", ami=True, upgrade_ids=[0]) is True
    assert calls == [(0, (at.NATIONAL_EXPORT, at.COUNTY_EXPORT)),
                     (1, (at.NATIONAL_EXPORT,)),
                     (2, (at.NATIONAL_EXPORT,))]


def test_prepare_reports_a_crawl_that_built_nothing(monkeypatch):
    monkeypatch.setattr(at, "_forget_cached_queries", lambda run: None)   # keep off ~/.cache
    listed = iter([set(), set()])
    monkeypatch.setattr(at, "existing_tables", lambda run, db: next(listed))
    stub = _stub(include_upgrades=False)
    stub.STATE_ABBRV, stub.CZ_ASHRAE, stub.COUNTY_ID = "s", "cz", "c"
    stub.setup_fsspec_filesystem = lambda *a, **k: "out"
    stub.export_metadata_and_annual_results_for_upgrade = lambda **kw: None
    stub.create_sightglass_tables = lambda **kw: None
    assert at.prepare_athena_tables(stub, "enduse") is False


def test_county_export_is_skipped_when_the_timeseries_table_is_absent():
    # The county aggregate only serves legs that also need <run>_timeseries,
    # which nothing here creates -- so no ~3,100-file export for legs that skip.
    p = at.plan({NATIONAL}, RUN, "enduse", county=True, views=True)
    assert p.export == [] and p.county_skipped and p.timeseries_missing
    assert "county export is skipped" in p.describe()
    p = at.plan({NATIONAL, TS}, RUN, "enduse", county=True, views=True)
    assert p.export == [at.COUNTY_EXPORT] and not p.county_skipped


def test_timeseries_absence_is_only_noted_when_something_wants_it():
    p = at.plan({NATIONAL, NATIONAL.replace("_parquet", "_vu")}, RUN, "enduse")
    assert p.timeseries_missing and "absent" not in p.describe()


def _exporting(monkeypatch, listed, **kw):
    """A run whose S3 exports are recorded, with Glue answering from `listed` in turn."""
    monkeypatch.setattr(at, "_forget_cached_queries", lambda run: None)   # keep off ~/.cache
    answers = iter(listed)
    monkeypatch.setattr(at, "existing_tables", lambda run, db: next(answers))
    stub = _stub(**kw)
    stub.STATE_ABBRV, stub.CZ_ASHRAE, stub.COUNTY_ID = "s", "cz", "c"
    stub.setup_fsspec_filesystem = lambda *a, **k: "out"
    stub.calls = []
    stub.export_metadata_and_annual_results_for_upgrade = (
        lambda upgrade_id, geo_exports, output_dir: stub.calls.append(
            (upgrade_id, tuple(g["geo_top_dir"] for g in geo_exports))))
    stub.create_sightglass_tables = lambda **kw: None
    stub.fix_timeseries_tables = lambda *a: None
    stub.create_views = lambda *a: None
    stub.determine_state_or_county_timeseries_table = (
        lambda i: "county" if str(i).startswith("G") else "state")
    return stub


def _no_athena(monkeypatch):
    def refuse(*a):
        raise AssertionError("Athena must not be asked")
    monkeypatch.setattr(at, "_upgrades_in_table", refuse)


def test_the_ami_tab_gets_county_tables_for_the_baseline_alone(monkeypatch):
    # The AMI comparison and AMI tab read upgrade 0 of the county table; nothing
    # needs the ~3,100 county files of every measure.
    stub = _exporting(monkeypatch, [{TS}, {NATIONAL, COUNTY, TS}])
    assert at.prepare_athena_tables(stub, "enduse", ami=True) is True
    assert stub.calls == [(0, (at.NATIONAL_EXPORT, at.COUNTY_EXPORT)),
                          (1, (at.NATIONAL_EXPORT,)), (2, (at.NATIONAL_EXPORT,))]


def test_a_county_timeseries_location_gets_county_tables_for_every_upgrade(monkeypatch):
    stub = _exporting(monkeypatch, [{TS}, {NATIONAL, COUNTY, TS}],
                      timeseries_locations_to_plot={"MN": "Minnesota", ("G2500250",): "Boston"})
    assert at.prepare_athena_tables(stub, "enduse", timeseries=True) is True
    assert stub.calls == [(u, (at.NATIONAL_EXPORT, at.COUNTY_EXPORT)) for u in (0, 1, 2)]
    # state locations read the national table only
    stub = _exporting(monkeypatch, [{TS}, {NATIONAL, TS}],
                      timeseries_locations_to_plot={"MN": "Minnesota"})
    assert at.prepare_athena_tables(stub, "enduse", timeseries=True) is True
    assert stub.calls == [(u, (at.NATIONAL_EXPORT,)) for u in (0, 1, 2)]


def test_extra_exports_add_levels_for_every_upgrade(monkeypatch):
    stub = _exporting(monkeypatch, [{TS}, {NATIONAL, COUNTY, TS}])
    assert at.prepare_athena_tables(stub, "enduse", extra_exports=["by_state_and_county"]) is True
    assert stub.calls == [(u, (at.NATIONAL_EXPORT, at.COUNTY_EXPORT)) for u in (0, 1, 2)]
    # 'auto' and the national level add nothing
    for extra in ("auto", ["national_by_state"], []):
        stub = _exporting(monkeypatch, [{TS}, {NATIONAL, TS}])
        assert at.prepare_athena_tables(stub, "enduse", extra_exports=extra) is True
        assert stub.calls == [(u, (at.NATIONAL_EXPORT,)) for u in (0, 1, 2)]


def test_a_mistyped_extra_export_raises_before_any_work(monkeypatch):
    import pytest
    monkeypatch.setattr(at, "existing_tables", lambda run, db: (_ for _ in ()).throw(
        AssertionError("must not list Glue")))
    with pytest.raises(ValueError, match="by_county"):
        at.prepare_athena_tables(_stub(), "enduse", extra_exports=["by_county"])


def test_tables_lacking_upgrades_get_only_those_added(monkeypatch):
    # The county table was exported for the AMI tab (the baseline) and the national one
    # before upgrade 2 existed; a county location now needs every upgrade from both.
    names = {NATIONAL, COUNTY, TS, NATIONAL.replace("_parquet", "_vu"),
             COUNTY.replace("_parquet", "_vu"), f"{TS}_vu"}
    stub = _exporting(monkeypatch, [names, names],
                      timeseries_locations_to_plot={"G2500250": "Boston"})
    held = {NATIONAL: {0, 1}, COUNTY: {0}}
    monkeypatch.setattr(at, "_upgrades_in_table", lambda table, db, reflect: held[table])
    assert at.prepare_athena_tables(stub, "enduse", timeseries=True, ami=True) is True
    assert stub.calls == [(1, (at.COUNTY_EXPORT,)), (2, (at.NATIONAL_EXPORT, at.COUNTY_EXPORT))]


def test_a_complete_table_is_not_re_exported_and_the_baseline_is_not_asked_about(monkeypatch):
    names = {NATIONAL, COUNTY, TS, NATIONAL.replace("_parquet", "_vu"),
             COUNTY.replace("_parquet", "_vu"), f"{TS}_vu"}
    stub = _exporting(monkeypatch, [names])
    asked = []
    monkeypatch.setattr(at, "_upgrades_in_table",
                        lambda table, db, reflect: asked.append(table) or {0, 1, 2})
    assert at.prepare_athena_tables(stub, "enduse", ami=True) is True
    assert stub.calls == [] and asked == [NATIONAL]        # county is wanted for upgrade 0 only
    # a baseline-only run asks nothing
    stub = _exporting(monkeypatch, [names], include_upgrades=False)
    _no_athena(monkeypatch)
    assert at.prepare_athena_tables(stub, "enduse", ami=True) is True and stub.calls == []


def test_prepare_never_adds_to_or_replaces_part_of_tables_built_with_other_weights(monkeypatch):
    # Re-exporting the upgrades this pass loaded would leave the rest of the table on the
    # old weights; extending it would add files on the new ones. Either mixes two sets.
    import pytest
    monkeypatch.setattr(at, "_stale_allocation_reason",
                        lambda c, s3: "exported from stock allocation aaaaaaaa; the run now uses bbbbbbbb")
    for replace_stale in (True, False):                     # the old switch changes nothing
        stub = _exporting(monkeypatch, [{NATIONAL, COUNTY, TS}],
                          timeseries_locations_to_plot={"G2500250": "Boston"})
        _no_athena(monkeypatch)
        with pytest.raises(at.TablesWeightsMismatch, match="REBUILD_ATHENA_TABLES = True"):
            at.prepare_athena_tables(stub, "enduse", timeseries=True, replace_stale=replace_stale)
        assert stub.calls == []


def test_a_run_without_tables_is_exported_even_without_a_record(monkeypatch):
    monkeypatch.setattr(at, "_stale_allocation_reason",
                        lambda c, s3: "exported with no record of their stock allocation; the run now uses bbbbbbbb")
    stub = _exporting(monkeypatch, [{TS}, {NATIONAL, TS}])
    assert at.prepare_athena_tables(stub, "enduse") is True
    assert stub.calls == [(u, (at.NATIONAL_EXPORT,)) for u in (0, 1, 2)]


def test_rebuild_removes_all_of_the_runs_tables_before_exporting(tmp_path, monkeypatch):
    import boto3
    from comstockpostproc import allocation as al
    monkeypatch.setattr(at, "_forget_cached_queries", lambda run: None)   # keep off ~/.cache
    c = _Stub(tmp_path, "b" * 32)                           # this pass's weights
    remote = c.remote                                       # plays s3://<base>/<run>/<run>
    al.write_marker(remote, "a" * 32, name=al.EXPORT_MARKER_NAME)        # the old record ...
    with open(f"{remote}/{al.FILE_NAME}", "wb") as f:                     # ... and old draw file
        f.write(b"old draw")
    for rel in ("metadata_and_annual_results_aggregates/national_by_state/full/parquet/upgrade=5/x.parquet",
                "metadata_and_annual_results_aggregates/by_state_and_county/full/parquet/upgrade=0/y.parquet",
                "baseline/results_up00.parquet"):
        os.makedirs(os.path.dirname(f"{remote}/{rel}"), exist_ok=True)
        with open(f"{remote}/{rel}", "wb") as f:
            f.write(b"x")
    c.s3_base_dir, c.include_upgrades, c.upgrade_ids_to_process = "bucket/prefix", True, [0, 1]
    c.timeseries_locations_to_plot = {}
    c.STATE_ABBRV, c.CZ_ASHRAE, c.COUNTY_ID = "s", "cz", "c"
    exported = []

    def export(upgrade_id, geo_exports, output_dir):
        assert not os.path.exists(f"{remote}/metadata_and_annual_results_aggregates")
        exported.append(upgrade_id)
    c.export_metadata_and_annual_results_for_upgrade = export
    c.create_sightglass_tables = lambda **kw: None
    c.fix_timeseries_tables = lambda *a: None
    c.create_views = lambda *a: None
    old = {NATIONAL, COUNTY, NATIONAL.replace("_parquet", "_vu"), COUNTY.replace("_parquet", "_vu"),
           f"{RUN}_md_agg_by_state_and_puma_parquet", TS, f"{TS}_vu", f"{RUN}_baseline", f"{RUN}_upgrades"}
    listed = iter([old, {NATIONAL, TS, f"{TS}_vu"}])        # before the removal, after the crawl
    monkeypatch.setattr(at, "existing_tables", lambda run, db: next(listed))
    deleted = []

    class Glue:
        def delete_table(self, DatabaseName, Name):
            deleted.append(Name)
    monkeypatch.setattr(boto3, "client", lambda *a, **k: Glue())
    assert at.prepare_athena_tables(c, "enduse", timeseries=True, rebuild=True) is True
    # every aggregate table and view went, every level and upgrade; buildstockbatch's stayed
    assert sorted(deleted) == sorted(n for n in old if n.startswith(f"{RUN}_md_agg_"))
    assert os.path.exists(f"{remote}/baseline/results_up00.parquet")
    assert exported == [0, 1]
    # the new record and draw file name this pass's weights
    assert al.read_marker(remote, name=al.EXPORT_MARKER_NAME) == "b" * 32
    assert al.read_provenance(f"{remote}/{al.FILE_NAME}").allocation_id == "b" * 32


def test_an_extension_is_described_in_the_log():
    p = at.plan({NATIONAL, TS}, RUN, "enduse")
    p.extend, p.crawl = {at.NATIONAL_EXPORT: [3, 4]}, True
    assert not p.nothing_to_do
    assert p.describe() == f"{RUN} in enduse: add upgrades 3, 4 to national_by_state, crawl"


def test_a_partitioned_table_is_asked_about_one_partition(monkeypatch):
    # The county table is ~3,100 files per upgrade; one county answers for it.
    import boto3

    class Glue:
        def get_table(self, DatabaseName, Name):
            keys = [{"Name": "state"}, {"Name": "county"}] if Name == COUNTY else []
            return {"Table": {"PartitionKeys": keys}}

        def get_partitions(self, DatabaseName, TableName, MaxResults):
            return {"Partitions": [{"Values": ["AL", "G0100330"]}]}

    monkeypatch.setattr(boto3, "client", lambda *a, **k: Glue())
    assert at._one_partition(COUNTY, "enduse") == " WHERE \"state\" = 'AL' AND \"county\" = 'G0100330'"
    assert at._one_partition(NATIONAL, "enduse") == ""


def test_upgrades_in_table_reuses_its_connection_and_falls_back_to_the_whole_table(monkeypatch):
    import pandas as pd
    from comstockpostproc.results_dashboard import athena
    state, sql = [None, None], []

    def configure(database=None, reflect_table=None):
        state[:] = [database, reflect_table]
        sql.append("connect")
    answers = iter([pd.DataFrame({"upgrade": ["0", "1", "2"]}),   # national, whole table
                    pd.DataFrame({"upgrade": []}),                # one county partition: empty
                    pd.DataFrame({"upgrade": ["0"]})])            # county, whole table
    monkeypatch.setattr(athena, "configure", configure)
    monkeypatch.setattr(athena, "configured", lambda: tuple(state))
    monkeypatch.setattr(athena, "query", lambda q, **kw: sql.append(q) or next(answers))
    monkeypatch.setattr(at, "_one_partition", lambda table, db: " WHERE x" if table == COUNTY else "")
    assert at._upgrades_in_table(NATIONAL, "enduse", NATIONAL) == {0, 1, 2}
    assert at._upgrades_in_table(COUNTY, "enduse", NATIONAL) == {0}
    assert sql == ["connect", f"SELECT DISTINCT upgrade FROM {NATIONAL}",
                   f"SELECT DISTINCT upgrade FROM {COUNTY} WHERE x", f"SELECT DISTINCT upgrade FROM {COUNTY}"]
