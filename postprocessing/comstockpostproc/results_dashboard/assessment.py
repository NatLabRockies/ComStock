# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Results dashboard: ComStock runs vs CBECS, AMI, and each other.

Writes metric CSVs plus one self-contained `dashboard.html`. FULLY
DETERMINISTIC -- Athena queries, pandas, and a hand-written JS bundle. No model
is involved at any point.

    dashboard = cspp.ResultsDashboard(comstock, cbecs=cbecs, ami=ami)  # runs on construction
    dashboard.skipped_reason or dashboard.dashboard_path

Every metric table carries a `run` column, so run-vs-reference and run-vs-run
differences are read off the same tables. The AMI and measure-timeseries legs
need county-split weights and therefore only cover runs that publish a
by-state-and-county metadata table.

WHAT IT NEEDS, AND WHAT HAPPENS WHEN IT IS ABSENT. The assessment reads
Athena aggregate tables -- the ones `prepare_athena_tables` exports and crawls
in the drivers, or a published release's. This is an optional step that must
never take a postprocessing run down, so every prerequisite is probed and a
missing one skips its leg with a stated reason: no reachable metadata table
skips the whole assessment; no CBECS makes the annual comparison ComStock-only
and skips the distribution and heating-fuel legs; no AMI truth data skips the
AMI leg; no upgrades skips the measure legs; and a query that fails once it
runs is caught in run(), which keeps what was written and records the error.
The dashboard renders an honest "not computed" state for whatever was skipped
rather than implying zero.
"""

from __future__ import annotations

import datetime
import json
import logging
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import pandas as pd

from . import (ami_shapes, annual, athena, cbecs_ref, dashboard, design_params,
               distributions, heating_fuel, measures, timeseries)
from .metrics_def import DIMENSIONS, ORDERED_CATEGORIES
from ._version import __version__
from .run_ref import AthenaRunRef

logger = logging.getLogger(__name__)


def _fmt(v, nd=1):
    return "n/a" if v is None or v != v else f"{v:,.{nd}f}"


def _pct(v):
    return "n/a" if v is None or v != v else f"{v:+.1f}%"


def write_findings(out: Path, runs, primary, comps, fuel_mix, quantiles,
                   ami_metrics, coverage) -> None:
    L = [
        f"# Results dashboard — {primary.label}",
        "",
        f"Generated {datetime.date.today().isoformat()} by comstock-results-dashboard v{__version__}.",
        "",
        "Runs compared: " + "; ".join(f"**{r.label}** (`{r.key}`)" for r in runs) + ".",
        "",
        "ComStock side is queried from the Athena metadata tables. Their weights are scaled per "
        "building type to CBECS floor area at postprocessing time, so the sqft rows below should "
        "read 0% -- a consistent positive gap means weight was added downstream of that scaling "
        "(the exported tables carry more weight than the scaled allocation; see "
        "create_allocated_weights_plus_util_bills_for_upgrade), and energy comparisons inherit "
        "that basis. CBECS side is comstockpostproc's `CBECS wide.csv` restricted to ComStock "
        "building types, with jackknife 95% confidence intervals computed from its 151 replicate "
        "weights.",
        "",
        "**Reading caveats.** CBECS end-use splits are EIA statistical disaggregations, not "
        "metered. A CBECS null means *not surveyed*, not zero — except natural-gas EUI, where "
        "null means the building has no gas and is filled with zero so both sides describe all "
        "buildings. CBECS carries no ASHRAE/IECC climate zone (its public-use microdata "
        "suppresses sub-regional geography), so census division is the finest geography it "
        "supports and the climate-zone view is ComStock-only. AMI is electricity-only, one "
        "region, compared against ComStock AMY2018; its floor-area denominators are uncertain, "
        "so shape (0–1) metrics are reported alongside kWh/ft² levels.",
        "",
        "## Headline, national (TBtu)",
        "",
        "| run | metric | ComStock | CBECS | CBECS 95% CI | % diff | within CI |",
        "|---|---|---|---|---|---|---|",
    ]
    for r in runs:
        c = comps.get((r.key, "building_type"))
        if c is None:
            continue
        sub = c[(c["category"] == "All") & c["metric"].isin(
            ["electricity.total", "natural_gas.total", "site_energy.total", "sqft"])]
        for _, row in sub.iterrows():
            scale = 1e-6 if row["metric"] == "sqft" else 1
            ci = (f"[{_fmt(row['cbecs_ci95_low']*scale)}, {_fmt(row['cbecs_ci95_high']*scale)}]"
                  if row["cbecs_ci95_low"] == row["cbecs_ci95_low"] else "n/a")
            L.append(f"| {r.key} | {row['metric']}{' (Mft²)' if row['metric']=='sqft' else ''} "
                     f"| {_fmt(row['comstock_value']*scale)} | {_fmt(row['cbecs_value']*scale)} "
                     f"| {ci} | {_pct(row['pct_diff'])} | {row['within_cbecs_ci95']} |")

    if len(runs) > 1:
        L += ["", "## Run vs run — where the releases differ most (electricity, by building type)",
              "", "| building type | " + " | ".join(r.key for r in runs) + " | change |",
              "|---" * (len(runs) + 2) + "|"]
        base = comps.get((runs[0].key, "building_type"))
        cats = [c for c in ORDERED_CATEGORIES["building_type"]
                if c in set(base["category"])] if base is not None else []
        rows = []
        for cat in cats:
            vals = []
            for r in runs:
                c = comps.get((r.key, "building_type"))
                v = None
                if c is not None:
                    m = c[(c["category"] == cat) & (c["metric"] == "electricity.total")]
                    v = float(m["comstock_value"].iloc[0]) if len(m) else None
                vals.append(v)
            if vals[0] and vals[-1]:
                chg = 100.0 * (vals[0] - vals[-1]) / vals[-1]
                rows.append((abs(chg), cat, vals, chg))
        for _, cat, vals, chg in sorted(rows, reverse=True):
            L.append(f"| {cat} | " + " | ".join(_fmt(v) for v in vals) + f" | {_pct(chg)} |")
        L += ["", f"Change is {runs[0].key} relative to {runs[-1].key}."]

    # The distributions leg is skipped whenever CBECS is absent, which leaves
    # `quantiles` an EMPTY frame with no columns at all -- so indexing it by
    # name raised KeyError('metric') here and took the run down after every
    # query had already succeeded. State the absence instead.
    if quantiles.empty or "metric" not in quantiles.columns:
        L += ["", "## EUI distributions", "",
              "Not assessed: the distribution leg needs a CBECS reference, and none "
              "was available for this run."]
    else:
        L += ["", "## EUI distributions — site energy median and spread (kBtu/ft²·yr, count-weighted)",
              "", "| building type | " + " | ".join(
                  f"{d} p25–p50–p75" for d in ([r.key for r in runs] + ["CBECS 2018"])) + " | CBECS n |",
              "|---" * (len(runs) + 2) + "|"]
        q = quantiles[(quantiles["metric"] == "site_energy") & (quantiles["basis"] == "count")
                      & (quantiles["dimension"] == "building_type")]
        for cat in ORDERED_CATEGORIES["building_type"]:
            cells, n = [], ""
            for ds in [r.key for r in runs] + ["CBECS 2018"]:
                s = q[(q["dataset"] == ds) & (q["category"] == cat)]
                if len(s):
                    r0 = s.iloc[0]
                    cells.append(f"{_fmt(r0['p25'],0)}–{_fmt(r0['p50'],0)}–{_fmt(r0['p75'],0)}")
                    if ds == "CBECS 2018":
                        n = str(int(r0["n_models"]))
                else:
                    cells.append("n/a")
            if any(c != "n/a" for c in cells):
                L.append(f"| {cat} | " + " | ".join(cells) + f" | {n} |")
        L += ["", "Small CBECS cells (n < 60) give unstable quartiles — read those rows with care."]

    if ami_metrics is not None and not ami_metrics.empty:
        L += ["", f"## AMI — {coverage.get('region')} ({primary.key} only)", "",
              "| building type | NMBE % (level) | shape RMSE (pts) | share of day in hours 0–5: CS vs AMI |",
              "|---|---|---|---|"]
        g = ami_metrics.groupby("building_type")[
            ["nmbe_pct", "daytype_shape_rmse_pts",
             "overnight_share_comstock", "overnight_share_ami"]].mean()
        for bt, r0 in g.iterrows():
            L.append(f"| {bt} | {_pct(r0['nmbe_pct'])} | {_fmt(r0['daytype_shape_rmse_pts'],2)} "
                     f"| {_fmt(100*r0['overnight_share_comstock'],1)}% vs "
                     f"{_fmt(100*r0['overnight_share_ami'],1)}% |")
        L += ["", "Shape metrics use the postprocessing day-sum normalization (day sum = 1), so "
                  "they are independent of the kWh/ft² level and of any error in the AMI "
                  "floor-area denominator. Level and shape can disagree: a profile can sit below "
                  "the meters in kWh/ft² while still putting a larger share of its day into the "
                  "overnight hours."]

    L += ["", "Full tables in `metrics/`; exact SQL in `queries/`; open `dashboard.html` for the "
              "interactive version."]
    (out / "findings.md").write_text("\n".join(L), encoding="utf-8")


def _assess(args) -> None:
    """The assessment itself. `args` carries the resolved options.

    Kept as a plain function taking an options object, unchanged from the
    standalone tool's orchestration, so the port did not have to touch any of
    the twenty-five option reads inside it.
    """
    runs = args.runs
    primary = runs[0]
    refs = args.refs

    out = Path(args.out)
    (out / "metrics").mkdir(parents=True, exist_ok=True)
    (out / "queries").mkdir(exist_ok=True)

    # CBECS is documented as OPTIONAL, and skip_distributions/skip_heating_fuel
    # already fold in its absence -- but this load was unconditional, so a run
    # passed cbecs=None raised KeyError here before any skip logic ran. The
    # annual leg still works without it: every CBECS comparison below already
    # has a None path, because dimensions CBECS cannot support (climate zone)
    # take it on every run.
    cbecs_df = (cbecs_ref.load_cbecs_wide(refs["cbecs_2018_wide"])
                if refs.get("cbecs_2018_wide") else None)
    if cbecs_df is None:
        logger.info("no CBECS reference: comparisons are ComStock-only")

    comps, fuel_mixes, audits, cs_buildings, pair_comps = {}, {}, {}, {}, {}
    for r in runs:
        logger.info("run %s: annual from %s", r.key, r.md_table)
        gcols = annual.available_group_cols(r.md_table, no_cache=args.no_cache)
        # The saved SQL is the one that ran: same column filter, same literal.
        (out / "queries" / f"annual_{r.key}.sql").write_text(
            annual.build_annual_sql(
                r.md_table, gcols, athena.table_columns(r.md_table, no_cache=args.no_cache),
                athena.baseline_where(r.md_table, no_cache=args.no_cache)),
            encoding="utf-8")
        fine = annual.fetch_comstock_annual(r.md_table, no_cache=args.no_cache)
        logger.info("  %d fine-grained rows", len(fine))
        audits.update({f"{r.key}.{k}": v for k, v in annual.check_categories(fine, r.key).items()})

        for dim, spec in DIMENSIONS.items():
            if dim not in fine.columns or fine[dim].isna().all():
                logger.info("  %s: dimension %s unavailable for this run", r.key, dim)
                continue
            cs_agg = annual.roll_up(fine, dim)
            if spec["cbecs"] and cbecs_df is not None:
                cb_totals, cb_diag = cbecs_ref.aggregate_cbecs(cbecs_df, dim)
                canon = set(ORDERED_CATEGORIES.get(dim, []))
                seen = cbecs_ref.observed_categories(cbecs_df, dim)
                if canon and (seen - canon):
                    audits[f"cbecs.{dim}"] = {"unexpected_values": sorted(seen - canon),
                                              "absent_values": sorted(canon - seen)}
            else:
                cb_totals, cb_diag = None, None
            c = annual.build_comparison(cs_agg, cb_totals, dim)
            c.insert(0, "run", r.key)
            fm = annual.build_fuel_mix(cs_agg, cb_diag)
            fm.insert(0, "run", r.key)
            comps[(r.key, dim)] = c
            fuel_mixes[(r.key, dim)] = fm

        for dim in annual.PAIR_DIMS:
            # Pair comparisons exist to put ComStock beside CBECS on a crossed
            # dimension, so without CBECS there is nothing to pair against.
            if cbecs_df is None:
                continue
            if dim not in fine.columns or fine[dim].isna().all():
                continue
            cs_pair = annual.roll_up_pair(fine, dim)
            cb_pair = cbecs_ref.aggregate_cbecs_pair(cbecs_df, dim)
            pc = annual.build_pair_comparison(cs_pair, cb_pair, dim)
            pc.insert(0, "run", r.key)
            pair_comps.setdefault(dim, []).append(pc)

        if not args.skip_distributions:
            (out / "queries" / f"distributions_{r.key}.sql").write_text(
                distributions.build_dist_sql(r.md_table, athena.table_columns(r.md_table),
                                             athena.baseline_where(r.md_table)),
                encoding="utf-8")
            cs_buildings[r.key] = distributions.fetch_comstock_buildings(
                r.md_table, no_cache=args.no_cache)

    for dim in DIMENSIONS:
        parts = [comps[(r.key, dim)] for r in runs if (r.key, dim) in comps]
        if parts:
            pd.concat(parts, ignore_index=True).to_csv(
                out / "metrics" / f"annual_vs_cbecs_by_{dim}.csv", index=False)
        fparts = [fuel_mixes[(r.key, dim)] for r in runs if (r.key, dim) in fuel_mixes]
        if fparts:
            pd.concat(fparts, ignore_index=True).to_csv(
                out / "metrics" / f"fuel_mix_by_{dim}.csv", index=False)

    for dim, parts in pair_comps.items():
        pd.concat(parts, ignore_index=True).to_csv(
            out / "metrics" / f"annual_vs_cbecs_by_building_type_and_{dim}.csv", index=False)

    quantiles = pd.DataFrame()
    if cs_buildings:
        logger.info("distributions: %s", ", ".join(f"{k} n={len(v):,}" for k, v in cs_buildings.items()))
        quantiles, hists = distributions.build_distributions(cs_buildings, cbecs_df)
        quantiles.to_csv(out / "metrics" / "eui_quantiles.csv", index=False)
        hists.to_csv(out / "metrics" / "eui_histograms.csv", index=False)

    # Which county/timeseries tables this run ACTUALLY has, probed once and
    # shared by the two legs that need them (AMI shapes and measure
    # timeseries). This used to sit inside the AMI branch, so the measure leg
    # could not see it -- and when no AMI object was passed it never ran at all.
    # Both legs then trusted AthenaRunRef.has_timeseries, which only asserts the
    # NAMES are set; from_comstock always sets them, so it is always True for a
    # live run and says nothing about whether the tables exist.
    stem = primary.md_table.split("_md_agg_")[0]
    # The county table's name follows the export's geo_top_dir, and the
    # timeseries table is <run>_timeseries when crawled but <run>_ts_by_state on
    # a published release, so both are discovered rather than assumed. Reject
    # the _vu view for the METADATA table (create_views renames in.sqft..ft2,
    # which build_sqft_sql selects by its original name) and PREFER it for the
    # timeseries (create_views is what translates a crawled run's
    # electricity_<enduse>_kwh columns into the published spelling).
    county_table = _discover(primary.md_county_table, stem,
                             require=("_md_agg_", "county"), reject=("_vu",))
    ts_table = (_discover(f"{stem}_timeseries_vu", stem, require=("timeseries", "_vu"))
                or _discover(primary.ts_table, stem, require=("timeseries",))
                or _discover(primary.ts_table, stem, require=("ts_by_state",)))
    # Applied INDEPENDENTLY. Coupling them meant that a run with a timeseries
    # table but no county aggregate -- the normal state of a run postprocessed
    # by compare_upgrades, which exports national only -- kept an EMPTY
    # ts_table, so the measure leg probed "" for its column types, got nothing,
    # defaulted the upgrade type to varchar and failed on a bigint column.
    if county_table:
        primary = replace(primary, md_county_table=county_table)
    if ts_table:
        primary = replace(primary, ts_table=ts_table)
    # Keep `runs` in step. It was built before this probe, and everything
    # downstream -- the AMI leg's run list, the manifest -- iterates `runs`, so
    # a stale entry there hands them the pre-discovery names: empty, for a ref
    # built from md_table alone. That produced a manifest claiming ts_table=''
    # for a run whose timeseries had just been found, and an AMI leg whose
    # every region SQL was built around a zero-length table name.
    runs = [primary if r.key == primary.key else r for r in runs]
    ts_dial = ami_shapes.ts_dialect(ts_table, no_cache=args.no_cache) if ts_table else None
    # Is the timeseries table usable at all? Shared by every leg that reads it
    # -- AMI shapes, county AND state measure profiles -- so a defect found
    # here declines all of them, not only the county-weighted ones.
    ts_usable = bool(ts_table and ts_dial and not ts_dial["missing"])
    ts_problems = []
    if not ts_table:
        ts_problems.append("a timeseries table")
    elif ts_dial and ts_dial["missing"]:
        ts_problems.append(f"a queryable timeseries table ({ts_table} is missing "
                           f"{'; '.join(ts_dial['missing'])})")
    # A duplicated (building, hour) would inflate every weighted timeseries sum
    # by the number of copies, invisibly. Better to decline the legs that read
    # it and say why than to publish a number that is wrong by an unknown
    # factor. Checked once, for state and county profiles alike.
    if ts_usable:
        dup = timeseries.check_no_duplicate_hours(
            ts_table, ts_dial, no_cache=args.no_cache)
        if dup:
            logger.warning("timeseries not usable: %s", dup)
            ts_problems.append(dup)
            ts_usable = False
    # The single condition every county-weighted leg must satisfy.
    county_ts_ok = bool(county_table and ts_usable)
    county_ts_missing = ([] if county_table else
                         ["the by-state-and-county metadata table"]) + ts_problems
    if county_ts_ok:
        logger.info("county-weighted legs: %s + %s (%s schema) -> id=%s time=%s "
                    "state=%s end uses=%d/%d", county_table, ts_table,
                    ts_dial["kind"], ts_dial["bldg"], ts_dial["time"],
                    ts_dial["state"] or "none", len(ts_dial["enduses"]),
                    len(ami_shapes.ENDUSE_STACK_ORDER))
    else:
        logger.info("county-weighted legs (AMI shapes, measure timeseries) "
                    "unavailable: %s missing", ", ".join(county_ts_missing))

    ami_metrics, coverage = None, {}
    if args.skip_ami:
        # The reason used to be recorded only for a run that HAD an AMI object
        # but no county table. With no AMI object at all the tab rendered with
        # nothing explaining itself, which is the one thing an absence must not
        # do: a reader cannot tell "not compared" from "compared and agreed".
        coverage["ami_skipped_reason"] = (
            "no AMI truth data was supplied to the assessment (set INCLUDE_AMI = True "
            "in the driver, or pass ami=cspp.load_ami())")
        logger.info("AMI leg skipped: %s", coverage["ami_skipped_reason"])
    else:
        # Uses the shared probe above; see county_ts_ok.
        ami_tables_missing = county_ts_missing
        if not county_ts_ok:
            logger.warning("run %s has no county metadata table; skipping AMI leg", primary.key)
            # Name the remedy, not just the absence. This message used to stop at
            # "requires", which reads as a property of the RUN -- and it is not:
            # it is a property of the geo_exports the driver asked for. That
            # ambiguity is why an earlier assessment reported the AMI leg as
            # unsupported for two runs that had ample models in every AMI region.
            missing = ", ".join(ami_tables_missing) or "the by-state-and-county metadata table"
            coverage["ami_skipped_reason"] = (
                f"{primary.key} is missing {missing}, which the county-split weights for the "
                "AMI comparison require. This is usually the EXPORT config, not the run: set "
                "INCLUDE_AMI = True in the driver, and its prepare_athena_tables call exports "
                "the county aggregate and crawls it as "
                f"{primary.md_table.split('_md_agg_')[0]}_md_agg_by_state_and_county_parquet")
        else:
            regions = (list(ami_shapes.REGIONS) if args.region == "all"
                       else [r.strip() for r in args.region.split(",")])
            # Every run with county-weighted timeseries gets the AMI leg, so the
            # dashboard can overlay the comparison run's total on the primary's
            # stack. Shape metrics and the agreement matrix stay primary-only —
            # one set of headline numbers, per the keep-it-simple direction.
            # Probed per run, not taken from has_timeseries. A COMPARISON run
            # has the same problem the primary had: from_comstock fills its
            # table names in unconditionally, so the name-only check is always
            # True and the first region's SQL is where you learn the table is
            # absent. The primary is already probed above; each comparison run
            # needs its own probe because it can be a different release, in a
            # different database, exported differently.
            ts_runs, ami_runs_skipped = [], {}
            for r in runs:
                if r.key == primary.key:
                    # `primary`, NOT `r`: `runs` was built before the probe
                    # above replaced the primary's county and timeseries table
                    # names with the discovered ones. Appending the stale `r`
                    # handed the AMI leg the ORIGINAL fields -- empty for a ref
                    # constructed from md_table alone -- so every region's SQL
                    # was built around a zero-length table name and failed.
                    ts_runs.append(primary)
                    continue
                # The stem must be the BARE name: by now md_table has been
                # qualified to db.table for a cross-database run, and a stem of
                # "buildstock_sdr.comstock_..." matches no table anywhere. And
                # the lookup must happen in the run's OWN database.
                r_stem = r.md_table.split(".")[-1].split("_md_agg_")[0]
                r_cty = _discover(r.md_county_table, r_stem,
                                  require=("_md_agg_", "county"), reject=("_vu",),
                                  database=r.database)
                r_ts = (_discover(f"{r_stem}_timeseries_vu", r_stem,
                                  require=("timeseries", "_vu"), database=r.database)
                        or _discover(r.ts_table, r_stem, require=("timeseries",),
                                     database=r.database)
                        or _discover(r.ts_table, r_stem, require=("ts_by_state",),
                                     database=r.database))
                if r_cty and r_ts:
                    ts_runs.append(replace(r, md_county_table=athena.qualify(r_cty, r.database),
                                           ts_table=athena.qualify(r_ts, r.database)))
                else:
                    absent = [n for n, t in (("county metadata table", r_cty),
                                             ("timeseries table", r_ts)) if not t]
                    ami_runs_skipped[r.key] = f"no {' and no '.join(absent)}"
                    logger.info("AMI leg: %s has no %s; not overlaid",
                                r.key, " and no ".join(absent))
            # Write the discovered, qualified table names back into `runs`, which
            # is what the manifest is built from. Without this the manifest
            # recorded a comparison run's PRE-discovery fields -- ts_table='' for
            # R3 in a dashboard whose every AMI region had just been queried
            # against R3's timeseries. A manifest that misreports what was read
            # is the same failure as an absence with no reason: it makes the
            # output un-auditable.
            runs = [next((t for t in ts_runs if t.key == r.key), r) for r in runs]
            metrics_by_region, region_coverage = {}, {}
            ami_clock = {}   # run key -> 'est' | 'local' (timeseries clock)
            for rg in regions:
                region = ami_shapes.REGIONS[rg]
                (out / "queries" / f"ami_{rg}_timeseries.sql").write_text(
                    ami_shapes.build_ts_sql(primary.ts_table, primary.md_county_table, region),
                    encoding="utf-8")
                (out / "queries" / f"ami_{rg}_sqft.sql").write_text(
                    ami_shapes.build_sqft_sql(primary.md_county_table, region), encoding="utf-8")
                try:
                    truth = ami_shapes.load_ami_truth(refs["ami_v01_long"], rg)
                except Exception as e:
                    logger.warning("region %s truth failed: %s", rg, e)
                    region_coverage[rg] = {"error": str(e)}
                    continue
                # A region in REGIONS with no rows in the truth CSV is not a
                # comparison — it is an absence. load_ami_truth FILTERS by
                # region, so a missing one comes back empty rather than raising:
                # v01 carries 9 of the 10 regions (no seattle), and without this
                # check seattle burned two Athena queries per run and wrote a
                # header-only metrics file while being counted as compared.
                if truth.empty:
                    logger.warning(
                        "region %s has no rows in the AMI truth data; skipping", rg)
                    region_coverage[rg] = {
                        "skipped_reason": "no rows for this region in the AMI truth "
                                          "data, so there is nothing to compare against"}
                    continue
                prof_parts, ldc_parts = [], []
                for r in ts_runs:
                    logger.info("AMI leg: %s, region %s", r.key, rg)
                    try:
                        cs_prof = ami_shapes.fetch_comstock_profiles(
                            r.ts_table, r.md_county_table, rg, no_cache=args.no_cache)
                    except Exception as e:
                        logger.warning("region %s / run %s failed: %s", rg, r.key, e)
                        if r.key == primary.key:
                            region_coverage[rg] = {"error": str(e)}
                        continue
                    ami_clock[r.key] = cs_prof.attrs.get("tz", "local")
                    prof, met, cov, ldc = ami_shapes.compare_region(cs_prof, truth, rg)
                    if not prof.empty:
                        prof.insert(0, "run", r.key)
                        prof_parts.append(prof)
                    if not ldc.empty:
                        ldc.insert(0, "run", r.key)
                        ldc_parts.append(ldc)
                    if r.key == primary.key:
                        met.to_csv(out / "metrics" / f"ami_shape_metrics_{rg}.csv", index=False)
                        metrics_by_region[rg] = met
                        region_coverage[rg] = cov
                if prof_parts:
                    pd.concat(prof_parts, ignore_index=True).to_csv(
                        out / "metrics" / f"ami_profiles_{rg}.csv", index=False)
                if ldc_parts:
                    pd.concat(ldc_parts, ignore_index=True).to_csv(
                        out / "metrics" / f"ami_ldc_{rg}.csv", index=False)
            agreement = ami_shapes.cross_region_agreement(metrics_by_region)
            if not agreement.empty:
                agreement.to_csv(out / "metrics" / "ami_cross_region_agreement.csv", index=False)
            # The headline region. It was hardcoded to pepco, which is the
            # BEST-sampled of the ten (roughly 40 models per cell against a
            # median near a dozen elsewhere), so the headline numbers read more
            # favourably than the other regions support -- while the dashboard
            # named no region at all. Keep pepco as the default, because it is
            # genuinely the most defensible single region, but say so.
            headline = "pepco" if "pepco" in metrics_by_region else next(
                iter(sorted(metrics_by_region)), None)
            coverage = dict(region_coverage.get(headline, {})) if headline else {}
            coverage["regions"] = region_coverage
            coverage["ami_regions_compared"] = sorted(metrics_by_region)
            coverage["ami_runs_compared"] = [r.key for r in ts_runs]
            coverage["ami_timeseries_clock"] = ami_clock
            coverage["ami_headline_region"] = headline
            coverage["ami_headline_region_note"] = (
                f"Headline AMI metrics are for {headline} alone, the best-sampled region. "
                "Per-region metrics are in the region panels; do not read these as a "
                "national result." if headline else "")
            if ami_runs_skipped:
                coverage["ami_runs_skipped"] = ami_runs_skipped
            ami_metrics = metrics_by_region.get(headline) if headline else None

    # Design-parameter review: the modelling inputs behind the results. Runs for
    # every release, since the columns are shared, so the pane can compare them.
    if not args.skip_design_params:
        dp = []
        for r in runs:
            logger.info("design params: %s", r.key)
            try:
                d = design_params.assess_design_params(r.md_table, r.key,
                                                       no_cache=args.no_cache)
            except Exception as exc:                     # noqa: BLE001
                logger.warning("  %s: design params failed (%s); skipping", r.key, exc)
                continue
            if not d.empty:
                dp.append(d)
        if dp:
            pd.concat(dp, ignore_index=True).to_csv(
                out / "metrics" / "design_params.csv", index=False)
            # per-metric description stored once, not repeated on every value row
            design_params.metric_meta(primary.md_table).to_csv(
                out / "metrics" / "design_params_meta.csv", index=False)
            (out / "queries" / "design_params.sql").write_text(
                design_params.build_params_sql(
                    primary.md_table,
                    design_params.available(athena.table_columns(primary.md_table)),
                    None),
                encoding="utf-8")

    # Main heating fuel vs CBECS by census division. Kept apart from the other
    # design parameters because it is the one input with a CBECS counterpart, and
    # because the two vocabularies need an explicit crosswalk (see heating_fuel).
    if not args.skip_heating_fuel:
        logger.info("heating fuel: CBECS + %d run(s)", len(runs))
        try:
            hfr, hprov = heating_fuel.assess_heating_fuel(
                cbecs_df, runs, no_cache=args.no_cache)
        except Exception as exc:                         # noqa: BLE001
            logger.warning("  heating fuel failed (%s); skipping", exc)
            hfr, hprov = pd.DataFrame(), {}
        if not hfr.empty:
            hfr.to_csv(out / "metrics" / "heating_fuel.csv", index=False)
            # The CBECS caveats travel with the data: what share of floor area was
            # excluded as unheated, and whether the single-fuel assumption held.
            (out / "metrics" / "heating_fuel_provenance.json").write_text(
                json.dumps(hprov, indent=2), encoding="utf-8")
            logger.info("  wrote %d rows; CBECS unheated area excluded: %.2f%%",
                        len(hfr), hprov.get("unheated_area_share_pct", float("nan")))

    measure_ids = [m.strip() for m in args.measures.split(",") if m.strip()]
    if measure_ids:
        logger.info("measure leg: upgrades %s on %s", measure_ids, primary.md_table)
        msum, mpairs, msav, mdist, mscen, mmask, mcats = measures.assess_measures(
            primary.md_table, measure_ids, no_cache=args.no_cache)
        for _f in (msum, mpairs, msav, mdist, mscen, mmask, mcats):
            if not _f.empty:
                _f.insert(0, "run", primary.key)

        # Cross-release measure comparison: run the same measure assessment
        # against each comparison release, restricted to the upgrades that
        # release actually carries. An older release may not have every measure
        # (not yet written, renamed, or dropped), so the ids are read from the
        # table rather than assumed; the shared ones get a second set of rows
        # tagged with that run's key, and the rest are reported as absent.
        measures_by_run = {primary.key: sorted(set(measure_ids))}
        for r in runs:
            if r.key == primary.key:
                continue
            try:
                avail = set(measures.available_upgrades(r.md_table,
                                                        no_cache=args.no_cache))
            except Exception as exc:                     # noqa: BLE001
                logger.warning("  %s: could not list upgrades (%s); "
                               "skipping its measure leg", r.key, exc)
                continue
            shared = [u for u in measure_ids if u in avail]
            missing = [u for u in measure_ids if u not in avail]
            measures_by_run[r.key] = shared
            if missing:
                logger.info("  %s: does not carry upgrades %s", r.key, missing)
            if not shared:
                logger.info("  %s: no requested measure exists here; skipping", r.key)
                continue
            logger.info("  %s: measure leg for shared upgrades %s on %s",
                        r.key, shared, r.md_table)
            try:
                p2 = measures.assess_measures(r.md_table, shared,
                                              no_cache=args.no_cache)
            except Exception as exc:                     # noqa: BLE001
                logger.warning("  %s: measure leg failed (%s); "
                               "keeping the primary run only", r.key, exc)
                continue
            s2, pa2, sa2, di2, sc2, mk2, ca2 = p2
            for _f in (s2, pa2, sa2, di2, sc2, mk2, ca2):
                if not _f.empty:
                    _f.insert(0, "run", r.key)
            msum = pd.concat([msum, s2], ignore_index=True)
            mpairs = pd.concat([mpairs, pa2], ignore_index=True)
            msav = pd.concat([msav, sa2], ignore_index=True)
            mdist = pd.concat([mdist, di2], ignore_index=True)
            mscen = pd.concat([mscen, sc2], ignore_index=True)
            if not mk2.empty:
                mmask = pd.concat([mmask, mk2], ignore_index=True)
            if not ca2.empty:
                mcats = pd.concat([mcats, ca2], ignore_index=True)
        coverage["measures_by_run"] = measures_by_run
        coverage["measures_requested"] = sorted(set(measure_ids))

        msum.to_csv(out / "metrics" / "measures_summary.csv", index=False)
        mpairs.to_csv(out / "metrics" / "measures_enduse_pairs.csv", index=False)
        msav.to_csv(out / "metrics" / "measures_enduse_savings.csv", index=False)
        mdist.to_csv(out / "metrics" / "measures_savings_dist.csv", index=False)
        mscen.to_csv(out / "metrics" / "measures_scenarios.csv", index=False)
        if not mcats.empty:
            mcats.to_csv(out / "metrics" / "measures_categories.csv", index=False)
        if not mmask.empty:
            mmask.to_csv(out / "metrics" / "measures_masks.csv", index=False)
            (out / "queries" / "measures_mask.sql").write_text(
                measures.build_mask_sql(primary.md_table, measure_ids,
                                        athena.table_columns(primary.md_table)),
                encoding="utf-8")
        (out / "queries" / "measures_pair_example.sql").write_text(
            measures.build_pair_sql(primary.md_table, measure_ids[0],
                                    athena.table_columns(primary.md_table)),
            encoding="utf-8")
        # Locations, not just states. The driver's timeseries_locations_to_plot
        # may name states, counties, or tuples of either as ONE profile, and
        # each shape is served from the table it needs -- see parse_locations.
        ts_locs = measures.parse_locations(args.measure_states)
        if not ts_locs:
            # Silently iterating nothing looked identical to a run with no
            # measures. Say which it is.
            logger.warning("no locations for the measure timeseries leg; skipping")
            coverage["measures_ts_skipped_reason"] = (
                "no locations to profile. These come from the run's "
                "timeseries_locations_to_plot -- state codes ('MN'), county "
                "gisjoins ('G2500250'), or a tuple of either as one profile. Pass "
                "measure_states=... to set them explicitly.")
        # STATE profiles do not need the county aggregate. This leg groups by
        # state, and the national_by_state aggregate already carries one row per
        # (bldg_id, state, climate zone) with PARTIAL weights, so summing weight
        # per state gives exactly the state-attributable weight. Verified equal
        # to the county table to six decimals on baseline_10k:
        #   AZ 88,132.754553   CO 95,360.590230   MN 83,594.866643, both tables.
        #
        # Requiring county here meant the leg could never run on a run
        # postprocessed the normal way -- compare_upgrades exports national only
        # -- for data it does not use. The county table is still preferred when
        # present, since it is the finer grain and costs nothing extra to read.
        ts_leg_ok = bool(ts_usable and primary.md_table)
        if not ts_leg_ok:
            # A console warning is not enough: whoever opens the dashboard is
            # not the person who watched the log. Without a coverage entry the
            # measure-timeseries panels are simply absent, which reads as "this
            # run has no load-shape story".
            logger.warning("no usable timeseries table; skipping measure timeseries")
            coverage["measures_ts_skipped_reason"] = (
                f"{primary.key} has no usable timeseries table"
                + (f" ({'; '.join(ts_problems)})" if ts_problems else "")
                + ". The measure ANNUAL figures above are unaffected. The "
                "timeseries table comes from buildstockbatch's own "
                "postprocessing crawl of the run, not from this assessment.")
            ts_locs = []
        done_locs, skipped_locs = [], {}
        for loc in ts_locs:
            # STATE locations do not need the county aggregate: the
            # national_by_state table is keyed (bldg_id, state, climate zone)
            # with PARTIAL weights, so summing per state gives exactly the
            # state-attributable weight -- verified equal to the county table to
            # six decimals (AZ 88,132.754553 / CO 95,360.590230 /
            # MN 83,594.866643 from both). COUNTY locations genuinely need the
            # county aggregate: the national one carries no
            # in.nhgis_county_gisjoin, only the as-simulated county, which is
            # not the apportioned one.
            if loc["kind"] == "county" and not county_ts_ok:
                skipped_locs[loc["label"]] = (
                    f"county profile over {len(loc['values'])} county id(s) needs the "
                    "by-state-and-county aggregate, which this run does not have. "
                    "State locations in this run are unaffected.")
                logger.warning("location %s skipped: %s", loc["label"],
                               skipped_locs[loc["label"]])
                continue
            md_for_loc = (primary.md_county_table if loc["kind"] == "county"
                          else primary.md_table)
            slug = measures.location_slug(loc)
            prof = measures.assess_measure_timeseries(
                primary.ts_table, md_for_loc, loc, measure_ids,
                no_cache=args.no_cache)
            prof.to_csv(out / "metrics" / f"measures_ts_{slug}.csv", index=False)
            # up_type must come from the table being queried: the literals
            # in the probe have to match the `upgrade` column's own type, and
            # defaulting to varchar against a bigint column made the probe fail
            # and the leg skip for a reason that was really a type mismatch.
            ts_mask_ok, ts_mask_why = measures.mask_leg_ok(
                md_for_loc, measure_ids,
                up_type=str(athena.table_column_types(md_for_loc).get("upgrade", "varchar")),
                for_timeseries=True, no_cache=args.no_cache)
            if not ts_mask_ok:
                logger.info("hourly mask leg skipped for %s: %s", loc["label"], ts_mask_why)
                coverage["measures_ts_mask_skipped_reason"] = ts_mask_why
            if ts_mask_ok:
                masked = measures.assess_measure_timeseries_masked(
                    primary.ts_table, md_for_loc, loc, measure_ids,
                    no_cache=args.no_cache)
                measures.check_ts_masks(masked, prof, measure_ids)
                masked.to_csv(out / "metrics" / f"measures_ts_mask_{slug}.csv", index=False)
            done_locs.append({"label": loc["label"], "kind": loc["kind"],
                              "ids": loc["values"], "slug": slug,
                              "table": md_for_loc})
        coverage["measures"] = {"upgrades": measure_ids, "locations": done_locs,
                                # Kept for readers and code expecting the old key.
                                "states": [d["label"] for d in done_locs]}
        if skipped_locs:
            coverage["measures_ts_locations_skipped"] = skipped_locs

    coverage["category_audit"] = audits
    coverage["dimensions"] = {d: {"label": s["label"], "cbecs_reference": s["cbecs"]}
                              for d, s in DIMENSIONS.items()}
    coverage["runs"] = [{"key": r.key, "label": r.label, "has_timeseries": r.has_timeseries}
                        for r in runs]
    if audits:
        logger.warning("category mismatches: %s", json.dumps(audits))

    base = comps.get((primary.key, "building_type"))
    headline = base[(base["category"] == "All") & base["metric"].isin(
        ["sqft", "electricity.total", "natural_gas.total", "site_energy.total"])]
    (out / "metrics.json").write_text(json.dumps({
        "primary_run": primary.key,
        "runs": [r.key for r in runs],
        "created": datetime.datetime.now().isoformat(timespec="seconds"),
        "tool_version": __version__,
        "annual_national": {
            r0["metric"]: {
                "comstock": r0["comstock_value"], "cbecs": r0["cbecs_value"],
                "pct_diff": r0["pct_diff"],
                "within_cbecs_ci95": None if pd.isna(r0["within_cbecs_ci95"])
                else bool(r0["within_cbecs_ci95"]),
            } for _, r0 in headline.iterrows()},
        "ami_region": coverage.get("region"),
    }, indent=2), encoding="utf-8")
    (out / "coverage.json").write_text(json.dumps(coverage, indent=2), encoding="utf-8")
    (out / "manifest.json").write_text(json.dumps({
        "runs": [{"key": r.key, "label": r.label, "md_table": r.md_table,
                  "md_county_table": r.md_county_table, "ts_table": r.ts_table,
                  "color": r.color} for r in runs],
        "primary_run": primary.key,
        # The run the delta annotations compare against -- the arrows, the
        # "moved toward CBECS" line and the heating-fuel gap column. With one
        # comparison run this is simply that run. With several it USED to be
        # whichever happened to be first, which is invisible to a reader; it is
        # now stated here so the dashboard can name it.
        "delta_ref": (getattr(args, "delta_ref", None)
                      or (runs[1].key if len(runs) > 1 else None)),
        # Runs the caller ASKED for that could not be reached. Recorded so the
        # manifest says what the assessment was meant to cover, not just what it
        # managed to cover -- otherwise a dropped comparison run is
        # indistinguishable from one that was never requested.
        "dropped_runs": getattr(args, "dropped_runs", {}) or {},
        "references": refs,
        "region": args.region,
        "tool_version": __version__,
        "created": datetime.datetime.now().isoformat(timespec="seconds"),
    }, indent=2), encoding="utf-8")

    write_findings(out, runs, primary, comps, fuel_mixes, quantiles, ami_metrics, coverage)
    logger.info("assessment written to %s", out)


def _discover(assumed: str, stem: str, require=(), reject=(),
              database: str | None = None) -> str:
    """A table matching `stem` and the filters, in `database` (default: the
    configured one).

    `database` matters for a comparison run living elsewhere -- a published
    release in buildstock_sdr beside a crawled run in enduse. Without it,
    discovery listed the configured database, found nothing, and reported the
    release as having no county or timeseries tables when both existed.

    Probes `assumed` first -- one cheap query, and the common case -- then falls
    back to listing the database. Prefers a `_parquet` table over a `_vu` view
    because create_views renames columns the assessment's SQL asks for by their
    original names, and prefers the shortest remaining name so a more specific
    variant does not win by accident.
    """
    # The assumed name must satisfy the same filters as a discovered one.
    # Returning it on a bare existence probe left the reject list half-applied:
    # athena.table_exists resolves VIEWS too, so an explicitly-passed _vu name
    # was accepted here and then failed inside the region SQL -- the exact
    # failure the reject list exists to prevent.
    if (assumed and all(k in assumed for k in require)
            and not any(k in assumed for k in reject)
            and athena.table_exists(assumed, database=database)):
        return assumed
    cands = [t for t in athena.table_names(database=database)
             if t.startswith(f"{stem}_")
             and all(k in t for k in require)
             and not any(k in t for k in reject)]
    if not cands:
        return ""
    cands = [t for t in cands if t.endswith("parquet")] or cands
    return sorted(cands, key=len)[0]


def _resolve_md_table(ref, database: str | None = None) -> str:
    """The run's real national aggregate table name, or "" if it has none.

    `AthenaRunRef.from_comstock` can only GUESS this name, and it guesses the
    published releases' `<run>_md_agg_national_parquet`. A privately crawled run
    is named after the `geo_top_dir` of the export that fed the crawler, so an
    export using `geo_top_dir='national_by_state'` -- what the driver templates
    use -- produces `<run>_md_agg_national_by_state_parquet` instead. Nothing
    about the run name reveals which, so requiring callers to know it just moves
    a silent skip onto them.

    Probes the assumed name first, since that is one cheap query and the common
    case, then falls back to discovery.
    """
    if athena.table_exists(ref.md_table, database=database):
        return ref.md_table

    stem = ref.md_table.split("_md_agg_")[0]
    # Fail soft, like athena.table_exists. "No tables yet" is the NORMAL state
    # of a run that has not been crawled, and this is the first Athena call the
    # assessment makes -- so an unreachable database, an expired token or a
    # missing workgroup surfaced here as a traceback that took the whole
    # postprocessing run down, which is exactly what this step promises never
    # to do. An empty list means "discovered nothing", and the caller turns
    # that into a stated skip.
    try:
        names = athena.table_names(database=database)
    except Exception as exc:                                      # noqa: BLE001
        logger.warning("cannot list tables while looking for %s: %s",
                       ref.md_table, exc)
        return ""
    cands = [t for t in names if t.startswith(f"{stem}_md_agg_")]
    if not cands:
        return ""
    # A `_parquet` suffix when there is one, but do not REQUIRE it: postproc
    # logs its expected table as `<run>_md_agg_national_by_state_national_by_state`
    # while the crawler actually produced `..._national_by_state_parquet`, so
    # the suffix is not something to depend on either way.
    cands = [t for t in cands if t.endswith("parquet")] or cands
    # Prefer a national aggregate: a county-level table has the columns the
    # queries need but many more rows per group, and would quietly change what
    # every weighted average means.
    national = [t for t in cands if "national" in t and "county" not in t]
    pick = sorted(national or cands, key=len)[0]
    logger.info("run %s: %s absent; using discovered aggregate %s",
                ref.key, ref.md_table, pick)
    return pick


class ResultsDashboard:
    """Results dashboard for one or more ComStock runs.

    Deterministic: Athena SQL, pandas, and a hand-written JS bundle. No model.

        dashboard = cspp.ResultsDashboard(
            comstock,                      # the run under review
            cbecs=cbecs, ami=ami,          # references the driver already built
            comparison_runs=[r2],          # optional, Athena-tables-only
        )                                  # runs on construction (run_now=True)

    RUN IT AFTER `prepare_athena_tables`. The assessment reads the aggregate
    tables that call exports and crawls (the drivers make it under
    MAKE_RESULTS_DASHBOARD), so it cannot run before them. It probes for them
    and skips with a stated reason if they are absent, which is why
    `enabled=True` is a safe default.
    """

    def __init__(self, comstock, cbecs=None, ami=None, comparison_runs=(),
                 comparison=None, enabled: bool = True, database: str = "enduse",
                 output_dir=None, region: str = "all", delta_ref: str | None = None,
                 measure_states=None, include_measures=None,
                 skip_distributions: bool = False,
                 skip_design_params: bool = False,
                 skip_heating_fuel: bool = False,
                 no_cache: bool = False, run_now: bool = True):
        """
        Args:
            comstock: the ComStock run under review. Supplies the run name the
                Athena table names are derived from, and the upgrade list.
            cbecs: a cspp.CBECS. Without it the annual comparison is
                ComStock-only and the distribution and heating-fuel legs skip.
            ami: a cspp.AMI. Without it the AMI leg skips.
            delta_ref: key of the comparison run the delta annotations compare
                against (arrows, "moved toward CBECS", heating-fuel gap column).
                Defaults to the first comparison run.
            comparison_runs: AthenaRunRef values for releases to compare
                against. These need no local results and no apportionment.
            comparison: the driver's comparison object, if there is one --
                ComStockToCBECSComparison, ComStockMeasureComparison or
                ComStockToAMIComparison; anything with an `output_dir`. Output
                then lands in a `results_dashboard/` subfolder of that
                comparison's own folder, so the dashboard sits with the plots
                covering the same runs instead of in a folder of its own.
            enabled: master toggle. Default True; a missing metadata table
                skips the step rather than raising, so on is safe.
            database: Athena database holding the run's crawled tables -- the
                driver's ATHENA_DATABASE, 'enduse' for every driver here.
            include_measures: None takes the upgrade list from the run
                (`upgrade_ids_to_process`, which `upgrade_ids_to_skip` does
                restrict; `include_upgrades=False` turns the measure legs off).
                Pass a list of upgrade ids to restrict it further, or [] to
                skip the measure legs.
            run_now: False builds the object without running, for inspection.
        """
        self.comstock = comstock
        self.cbecs = cbecs
        self.ami = ami
        self.comparison_runs = list(comparison_runs)
        # Which comparison run the delta annotations reference. None means the
        # first one, which is the only sensible default but is worth naming
        # rather than leaving to list order once there are several.
        self.delta_ref = delta_ref
        self.comparison = comparison
        self.enabled = enabled
        self.database = database
        self.region = region
        # Kept RAW. measures.parse_locations does the interpreting, because it
        # is the only thing that knows a tuple key is one multi-id profile and
        # that a G-prefixed id is a county.
        #
        # This used to normalize to a comma-separated string of states here
        # first, which destroyed exactly the information the location support
        # needs: {('MN','OH'): 'Upper Midwest'} arrived as "MN,OH" -- two
        # separate state profiles with the label thrown away -- and county ids
        # were dropped silently before anything could report them.
        #
        # Defaults to the run's own timeseries_locations_to_plot rather than a
        # hardcoded state: an invented default profiles a geography the user
        # never asked about, and reads as if it meant something.
        self.measure_states = (
            measure_states if measure_states is not None
            else getattr(comstock, "timeseries_locations_to_plot", None))
        self.include_measures = include_measures
        self.skip_distributions = skip_distributions
        self.skip_design_params = skip_design_params
        self.skip_heating_fuel = skip_heating_fuel
        self.no_cache = no_cache
        self.skipped_reason = None
        # Comparison runs that could not be reached, key -> why. A dropped run
        # is a coverage gap to report, not an error to swallow silently.
        self.dropped_runs: dict[str, str] = {}

        # The run under review is normally a live ComStock object, but an
        # AthenaRunRef is accepted directly. That covers reviewing a run whose
        # simulation outputs are not on this machine -- a published release, or
        # a run already crawled by an earlier postprocessing pass -- where
        # constructing a ComStock is impossible anyway, since its __init__
        # downloads and globs local results parquet. With a ref, `output_dir`
        # must be given: there is no run folder to infer one from.
        self.primary = (comstock if isinstance(comstock, AthenaRunRef)
                        else AthenaRunRef.from_comstock(comstock, database=database))
        # An undeterminable output_dir is a SKIP, not a raise. _default_output_dir
        # raises, and it is called here in __init__ -- before run() and before
        # `enabled` is consulted -- so a driver that had turned this step off, or
        # that passed a ref without output_dir, still lost its whole
        # postprocessing run to a step that is meant to be optional.
        self.output_dir = None
        try:
            self.output_dir = (Path(output_dir) if output_dir
                               else self._default_output_dir())
        except ValueError as exc:
            self.skipped_reason = str(exc)
            logger.warning("results dashboard skipped: %s", exc)
            return

        if run_now:
            self.run()

    @staticmethod
    def _truth_file(obj, file_name, label):
        """Locate a reference's exported CSV, or say why the leg will skip.

        cspp.CBECS and cspp.AMI expose `output_dir`, not a path to the file, and
        each writes a fixed name into it ('CBECS wide.csv', 'AMI long.csv' --
        both literals in those classes). Deriving it here rather than asking for
        a path keeps the driver call simple.

        Returns None on absence AND LOGS WHY. An earlier version used
        getattr(obj, "wide_csv_path", None), which silently returned None for an
        attribute that does not exist -- the leg would then skip for a reason no
        one could see. A reference that was passed but whose export is missing
        is the interesting case: it usually means export_to_csv_wide() has not
        been called yet.
        """
        if obj is None:
            logger.info("no %s object supplied; its leg will be skipped", label)
            return None
        out = getattr(obj, "output_dir", None)
        if not out:
            logger.warning("%s object has no output_dir; skipping its leg", label)
            return None
        path = Path(out) / file_name
        if not path.exists():
            logger.warning(
                "%s supplied but %s is not there -- call its export first. "
                "Skipping that leg.", label, path)
            return None
        return path

    # Subfolder created INSIDE the run's existing output folder. The assessment
    # does not create a top-level folder of its own: a run already owns
    # "ComStock <run>" and a comparison already owns
    # "CBECS 2018 vs ComStock <run> - ...", and adding a third sibling made one
    # run map to several unrelated-looking folders.
    OUTPUT_SUBDIR = "results_dashboard"

    def _default_output_dir(self) -> Path:
        """`<the folder this run's results already go to>/results_dashboard/`.

        Preferred parent is the comparison's own output folder, when one was
        passed -- the assessment then sits with the plots describing the same
        runs. Falling back to the ComStock run's folder keeps it next to that
        run's results when there is no comparison.
        """
        if self.comparison is not None:
            return Path(self.comparison.output_dir) / self.OUTPUT_SUBDIR

        # ComStock.output_dir is an fsspec mapping, not a path, and can point at
        # S3. The assessment writes with plain Path, so an S3 target has to be
        # named rather than silently written somewhere local.
        out = getattr(self.comstock, "output_dir", None)
        if isinstance(out, dict):
            fs, fs_path = out.get("fs"), out.get("fs_path")
            if fs is not None and type(fs).__name__ == "S3FileSystem":
                raise ValueError(
                    "This run's output_dir is on S3; the results dashboard "
                    "writes locally. Pass output_dir=... explicitly, or pass "
                    "comparison=<the driver's comparison object> to write beside "
                    "its plots.")
            if fs_path:
                return Path(fs_path) / self.OUTPUT_SUBDIR
        if out:
            return Path(str(out)) / self.OUTPUT_SUBDIR
        raise ValueError(
            "Cannot determine where to write: pass comparison=... or output_dir=...")

    def _upgrade_ids(self) -> list:
        """Upgrades to assess: `include_measures` if given, else the run's own
        `upgrade_ids_to_process` -- which `upgrade_ids_to_skip` does restrict.
        (Its DOWNLOAD skip at comstock.py:355 compares a regex string against
        an int list and never fires, but that only costs a download.)
        """
        if self.include_measures is not None:
            return [str(u) for u in self.include_measures]
        if not getattr(self.comstock, "include_upgrades", True):
            # A baseline-only driver: prepare_athena_tables exported upgrade 0
            # alone, so the measure legs would query partitions that are not
            # there -- even though stale results_up*.parquet files on disk can
            # still put ids into upgrade_ids_to_process.
            logger.info("include_upgrades=False: measure legs off "
                        "(pass include_measures=[ids] to force them)")
            return []
        ids = getattr(self.comstock, "upgrade_ids_to_process", None) or []
        if not ids and isinstance(self.comstock, AthenaRunRef):
            # A ref carries no upgrade list, so the measure legs disappear --
            # and unlike every other skipped leg they left NO coverage entry,
            # which reads as "this run has no measures" rather than "nobody
            # said which". Say it instead.
            logger.info(
                "no upgrade list: the run under review is an AthenaRunRef, which "
                "carries none. Pass include_measures=[ids] for the measure legs, "
                "or include_measures=[] to state that they are not wanted.")
        # Upgrade 0 is the baseline, not a measure.
        return [str(u) for u in ids if str(u) not in ("0", "00")]

    def run(self) -> "ResultsDashboard":
        """Run the assessment, or skip with a reason. Never raises on absence."""
        if not self.enabled:
            self.skipped_reason = "disabled by the caller (enabled=False)"
            logger.info("results dashboard skipped: %s", self.skipped_reason)
            return self
        if self.output_dir is None:
            # __init__ could not determine one and already recorded why; guard
            # here too so a hand-called run() cannot proceed without a target.
            logger.info("results dashboard skipped: %s", self.skipped_reason)
            return self

        # Every query resolves bare table names against this database, and the
        # reflected table only has to exist for the client to construct.
        #
        # An explicitly-set primary.database wins over the assessment default.
        # Ignoring it made the ref path quietly wrong: AthenaRunRef defaults to
        # 'buildstock_sdr' and the assessment to 'enduse', so passing a
        # published-release ref without also repeating database= resolved every
        # table in the wrong place and reported the run as never crawled.
        if (isinstance(self.comstock, AthenaRunRef) and self.primary.database
                and self.primary.database != self.database):
            logger.info("using the run's own database %s (not %s)",
                        self.primary.database, self.database)
            self.database = self.primary.database
        # Resolve the real table name FIRST, then point the client at it.
        # Configuring on the guessed name meant BuildStockQuery tried to reflect
        # a table that may not exist; construction then failed, and every
        # subsequent probe failed with it, so a run whose tables were present
        # was reported as never crawled. Discovery runs on Glue and needs no
        # client, so it can safely precede this.
        athena.configure(database=self.database, reflect_table=None)
        primary_table = _resolve_md_table(self.primary)
        if primary_table:
            athena.configure(database=self.database, reflect_table=primary_table)
        if not primary_table:
            self.skipped_reason = (
                f"No metadata aggregate table for run '{self.primary.key}' in "
                f"database {self.database} (looked for {self.primary.md_table} and "
                f"any {self.primary.md_table.split('_md_agg_')[0]}_md_agg_*parquet). "
                "The dashboard reads the aggregate tables prepare_athena_tables "
                "exports and crawls (MAKE_RESULTS_DASHBOARD = True in the driver does "
                "that; REBUILD_ATHENA_TABLES = True redoes it), or pass an "
                "AthenaRunRef for a published release.")
            logger.warning("results dashboard skipped: %s", self.skipped_reason)
            return self
        self.primary = replace(self.primary, md_table=primary_table)

        # Comparison runs are probed too. They used not to be, so an
        # unreachable one raised from inside the first leg that queried it --
        # taking down a postprocessing step whose whole contract is that it
        # skips rather than fails. Dropping the run here keeps that contract,
        # and the missing run is reported as the coverage gap it is.
        kept = []
        for ref in self.comparison_runs:
            # A comparison run in ANOTHER database used to be dropped here, on
            # the grounds that the assessment resolves one database. That was a
            # self-imposed limit: Athena resolves a qualified `db.table` from
            # any configured database -- one query can read an unqualified table
            # in `enduse` and a qualified one in `buildstock_sdr` together,
            # verified directly. And this is the comparison people most want:
            # my new run against the last published release, which lives in
            # buildstock_sdr while a crawled run lives in enduse. So resolve the
            # ref in ITS OWN database and qualify the names.
            found = _resolve_md_table(ref, database=ref.database)
            if not found:
                self.dropped_runs[ref.key] = (
                    f"no metadata aggregate table in {ref.database} "
                    f"(looked for {ref.md_table})")
                logger.warning("comparison run %s dropped: %s",
                               ref.key, self.dropped_runs[ref.key])
                continue
            if ref.database != self.database:
                logger.info("comparison run %s is in %s; its tables will be "
                            "referenced as %s.<table>",
                            ref.key, ref.database, ref.database)
            kept.append(replace(
                ref,
                md_table=athena.qualify(found, ref.database),
                md_county_table=athena.qualify(ref.md_county_table, ref.database),
                ts_table=athena.qualify(ref.ts_table, ref.database),
            ))
        self.comparison_runs = kept

        refs = {}
        cbecs_csv = self._truth_file(self.cbecs, "CBECS wide.csv", "CBECS")
        ami_csv = self._truth_file(self.ami, "AMI long.csv", "AMI")
        if cbecs_csv:
            refs["cbecs_2018_wide"] = str(cbecs_csv)
        if ami_csv:
            refs["ami_v01_long"] = str(ami_csv)

        measure_ids = self._upgrade_ids()
        args = SimpleNamespace(
            out=str(self.output_dir),
            runs=[self.primary] + self.comparison_runs,
            refs=refs,
            region=self.region,
            delta_ref=self.delta_ref,
            skip_ami=ami_csv is None,
            measures=",".join(measure_ids),
            measure_states=self.measure_states,
            skip_distributions=self.skip_distributions or cbecs_csv is None,
            skip_design_params=self.skip_design_params,
            skip_heating_fuel=self.skip_heating_fuel or cbecs_csv is None,
            no_cache=self.no_cache,
            dropped_runs=self.dropped_runs,
        )
        logger.info("results dashboard: %d run(s), %d measure(s) -> %s",
                    len(args.runs), len(measure_ids), self.output_dir)
        # Fail soft from here on. Every prerequisite above was probed, but a
        # query can still fail once it runs -- permissions, a network drop, a
        # column an older release spells differently. This is an optional step
        # inside someone's postprocessing job, so that must not take the job
        # down: keep whatever was written, say what failed, and return.
        try:
            _assess(args)
            # Build the page in the same call. In the standalone tool this was
            # a SECOND command (`python -m ...dashboard --assessment <dir>`),
            # which is why a first port of run() wrote every metric CSV and no
            # dashboard at all. One entry point, or the deliverable silently
            # goes missing.
            page = dashboard.build(self.output_dir, self.dashboard_path)
        except Exception as exc:                                  # noqa: BLE001
            self.skipped_reason = (
                f"failed while assessing ({type(exc).__name__}: {exc}); metric "
                f"files written before the failure are in {self.output_dir}")
            logger.warning("results dashboard skipped: %s", self.skipped_reason,
                           exc_info=True)
            return self
        logger.info("dashboard: %s (%.0f KB)", page, page.stat().st_size / 1024)
        return self

    @property
    def dashboard_path(self) -> Path:
        return self.output_dir / "dashboard.html"
