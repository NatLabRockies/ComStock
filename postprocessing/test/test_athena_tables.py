# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The decision behind prepare_athena_tables, without AWS.

`plan` is handed the table names Glue listed and says what to export, whether
to crawl, and whether to create views. These pin that logic so a driver's
"reuse what exists" behaviour cannot silently regress into re-exporting ~3,100
county files per upgrade, or into skipping a view something reads.
"""

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
    stub = _stub()
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
