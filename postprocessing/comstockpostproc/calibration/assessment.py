# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Calibration/QAQC assessment: ComStock runs vs CBECS, AMI, and each other.

Writes metric CSVs plus one self-contained `dashboard.html`. FULLY
DETERMINISTIC -- Athena queries, pandas, and a hand-written JS bundle. No model
is involved at any point.

    calib = cspp.CalibrationAssessment(comstock, cbecs=cbecs, ami=ami)
    calib.run()

Every metric table carries a `run` column, so run-vs-reference and run-vs-run
differences are read off the same tables. The AMI and measure-timeseries legs
need county-split weights and therefore only cover runs that publish a
by-state-and-county metadata table.

WHAT IT NEEDS, AND WHAT HAPPENS WHEN IT IS ABSENT. The assessment reads
PUBLISHED Athena aggregate tables -- the ones `create_sightglass_tables` creates
via Glue. That step is not part of a default postprocessing run, so the tables
often do not exist, and this is an optional step that must never take a run
down. Every prerequisite is therefore probed, and a missing one skips its leg
with a stated reason: no reachable metadata table skips the whole assessment;
no CBECS skips the annual, distribution and heating-fuel legs; no AMI truth data
skips the AMI leg; no upgrades skips the measure legs. The dashboard renders an
honest "not computed" state for whatever was skipped rather than implying zero.
"""

from __future__ import annotations

import datetime
import json
import logging
from pathlib import Path
from types import SimpleNamespace

import pandas as pd

from . import (ami_shapes, annual, athena, cbecs_ref, dashboard, design_params,
               distributions, heating_fuel, measures)
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
        f"# Calibration assessment — {primary.label}",
        "",
        f"Generated {datetime.date.today().isoformat()} by comstock-calibration v{__version__}.",
        "",
        "Runs compared: " + "; ".join(f"**{r.label}** (`{r.key}`)" for r in runs) + ".",
        "",
        "ComStock side is queried from the Athena metadata tables. The published weight is the "
        "StockE apportionment weight, NOT rescaled to CBECS, so floor area runs a few percent "
        "above CBECS across every segment and energy comparisons inherit that basis. CBECS side "
        "is comstockpostproc's `CBECS wide.csv` restricted to ComStock building types, with "
        "jackknife 95% confidence intervals computed from its 151 replicate weights.",
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

    cbecs_df = cbecs_ref.load_cbecs_wide(refs["cbecs_2018_wide"])

    comps, fuel_mixes, audits, cs_buildings, pair_comps = {}, {}, {}, {}, {}
    for r in runs:
        logger.info("run %s: annual from %s", r.key, r.md_table)
        gcols = annual.available_group_cols(r.md_table, no_cache=args.no_cache)
        (out / "queries" / f"annual_{r.key}.sql").write_text(
            annual.build_annual_sql(r.md_table, gcols), encoding="utf-8")
        fine = annual.fetch_comstock_annual(r.md_table, no_cache=args.no_cache)
        logger.info("  %d fine-grained rows", len(fine))
        audits.update({f"{r.key}.{k}": v for k, v in annual.check_categories(fine, r.key).items()})

        for dim, spec in DIMENSIONS.items():
            if dim not in fine.columns or fine[dim].isna().all():
                logger.info("  %s: dimension %s unavailable for this run", r.key, dim)
                continue
            cs_agg = annual.roll_up(fine, dim)
            if spec["cbecs"]:
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
            if dim not in fine.columns or fine[dim].isna().all():
                continue
            cs_pair = annual.roll_up_pair(fine, dim)
            cb_pair = cbecs_ref.aggregate_cbecs_pair(cbecs_df, dim)
            pc = annual.build_pair_comparison(cs_pair, cb_pair, dim)
            pc.insert(0, "run", r.key)
            pair_comps.setdefault(dim, []).append(pc)

        if not args.skip_distributions:
            (out / "queries" / f"distributions_{r.key}.sql").write_text(
                distributions.build_dist_sql(r.md_table, athena.table_columns(r.md_table)),
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

    ami_metrics, coverage = None, {}
    if not args.skip_ami:
        if not primary.has_timeseries:
            logger.warning("run %s has no county metadata table; skipping AMI leg", primary.key)
            coverage["ami_skipped_reason"] = (
                f"{primary.key} publishes no by-state-and-county metadata table, which the "
                "county-split weights for the AMI comparison require")
        else:
            regions = (list(ami_shapes.REGIONS) if args.region == "all"
                       else [r.strip() for r in args.region.split(",")])
            # Every run with county-weighted timeseries gets the AMI leg, so the
            # dashboard can overlay the comparison run's total on the primary's
            # stack. Shape metrics and the agreement matrix stay primary-only —
            # one set of headline numbers, per the keep-it-simple direction.
            ts_runs = [r for r in runs if r.has_timeseries]
            ami_runs_skipped = {r.key: "no by-state-and-county metadata table"
                                for r in runs if not r.has_timeseries}
            metrics_by_region, region_coverage = {}, {}
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
            coverage = region_coverage.get("pepco", next(iter(region_coverage.values()), {}))
            coverage = dict(coverage)
            coverage["regions"] = region_coverage
            coverage["ami_regions_compared"] = sorted(metrics_by_region)
            coverage["ami_runs_compared"] = [r.key for r in ts_runs]
            if ami_runs_skipped:
                coverage["ami_runs_skipped"] = ami_runs_skipped
            ami_metrics = metrics_by_region.get("pepco")

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
        for st in [s.strip() for s in args.measure_states.split(",") if s.strip()]:
            if not primary.has_timeseries:
                logger.warning("no county table; skipping measure timeseries")
                break
            prof = measures.assess_measure_timeseries(
                primary.ts_table, primary.md_county_table, st, measure_ids,
                no_cache=args.no_cache)
            prof.to_csv(out / "metrics" / f"measures_ts_{st}.csv", index=False)
            if len(measure_ids) <= measures.MASK_MEASURE_CAP:
                masked = measures.assess_measure_timeseries_masked(
                    primary.ts_table, primary.md_county_table, st, measure_ids,
                    no_cache=args.no_cache)
                measures.check_ts_masks(masked, prof, measure_ids)
                masked.to_csv(out / "metrics" / f"measures_ts_mask_{st}.csv", index=False)
        coverage["measures"] = {"upgrades": measure_ids,
                                "states": args.measure_states.split(",")}

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
        "references": refs,
        "region": args.region,
        "tool_version": __version__,
        "created": datetime.datetime.now().isoformat(timespec="seconds"),
    }, indent=2), encoding="utf-8")

    write_findings(out, runs, primary, comps, fuel_mixes, quantiles, ami_metrics, coverage)
    logger.info("assessment written to %s", out)


class CalibrationAssessment:
    """Calibration/QAQC assessment for one or more ComStock runs.

    Deterministic: Athena SQL, pandas, and a hand-written JS bundle. No model.

        calib = cspp.CalibrationAssessment(
            comstock,                      # the run under review
            cbecs=cbecs, ami=ami,          # references the driver already built
            comparison_runs=[r2],          # optional, Athena-tables-only
        )
        calib.run()

    RUN IT AFTER `create_sightglass_tables`. The assessment reads the published
    aggregate tables that step's Glue crawlers create, so it cannot run before
    them. It probes for them and skips with a stated reason if they are absent,
    which is why `enabled=True` is a safe default even though most
    postprocessing runs never create Athena tables at all.
    """

    def __init__(self, comstock, cbecs=None, ami=None, comparison_runs=(),
                 enabled: bool = True, database: str = "enduse",
                 output_dir=None, region: str = "all",
                 measure_states: str = "CO", include_measures=None,
                 skip_distributions: bool = False,
                 skip_design_params: bool = False,
                 skip_heating_fuel: bool = False,
                 no_cache: bool = False, run_now: bool = True):
        """
        Args:
            comstock: the ComStock run under review. Supplies the run name the
                Athena table names are derived from, and the upgrade list.
            cbecs: a cspp.CBECS. Without it the annual, distribution and
                heating-fuel legs skip.
            ami: a cspp.AMI. Without it the AMI leg skips.
            comparison_runs: AthenaRunRef values for releases to compare
                against. These need no local results and no apportionment.
            enabled: master toggle. Default True; a missing metadata table
                skips the step rather than raising, so on is safe.
            database: Athena database holding the run's crawled tables. Note
                `create_sightglass_tables` writes to 'vizstock' by default while
                other postproc code reads 'enduse', so set this deliberately.
            include_measures: None derives the upgrade list from the run's own
                data. Pass a list of upgrade ids to restrict it, or [] to skip
                the measure legs. Do NOT rely on ComStock.include_upgrades --
                it only gates downloads, and `upgrade_ids_to_skip` compares a
                regex string against an int list so it never fires.
            run_now: False builds the object without running, for inspection.
        """
        self.comstock = comstock
        self.cbecs = cbecs
        self.ami = ami
        self.comparison_runs = list(comparison_runs)
        self.enabled = enabled
        self.database = database
        self.region = region
        self.measure_states = measure_states
        self.include_measures = include_measures
        self.skip_distributions = skip_distributions
        self.skip_design_params = skip_design_params
        self.skip_heating_fuel = skip_heating_fuel
        self.no_cache = no_cache
        self.skipped_reason = None

        self.primary = AthenaRunRef.from_comstock(comstock, database=database)
        self.output_dir = Path(output_dir) if output_dir else self._default_output_dir()

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

    # One parent for every assessment, so `output/` gains exactly ONE entry no
    # matter how many runs are assessed. A single run already scatters several
    # top-level folders ("ComStock <run>", "CBECS 2018 vs ComStock <run> - ...")
    # and adding a third made it hard to see which output belonged to which run.
    OUTPUT_PARENT = "Calibration QAQC Dashboard"

    def _default_output_dir(self) -> Path:
        """`output/Calibration QAQC Dashboard/<run>/`.

        Nested under one parent rather than sitting beside the comparison
        folders. Named for the run under review, so re-assessing that run
        replaces its own results instead of accumulating near-duplicates --
        which is what the comparison folders do and what made them confusing.
        The runs it was compared against are recorded in the dashboard title and
        the Coverage tab, where they belong.
        """
        root = Path(__file__).resolve().parents[2] / "output"
        return root / self.OUTPUT_PARENT / self.comstock.comstock_run_name

    def _upgrade_ids(self) -> list:
        """Upgrades to assess, derived from the run's own data.

        `ComStock.include_upgrades` only gates DOWNLOADS, and
        `upgrade_ids_to_skip` compares the regex's string against an int list so
        the skip silently never fires. The data is the only reliable source.
        """
        if self.include_measures is not None:
            return [str(u) for u in self.include_measures]
        ids = getattr(self.comstock, "upgrade_ids_to_process", None) or []
        # Upgrade 0 is the baseline, not a measure.
        return [str(u) for u in ids if str(u) not in ("0", "00")]

    def run(self) -> "CalibrationAssessment":
        """Run the assessment, or skip with a reason. Never raises on absence."""
        if not self.enabled:
            self.skipped_reason = "disabled by the caller (enabled=False)"
            logger.info("calibration assessment skipped: %s", self.skipped_reason)
            return self

        # Every query resolves bare table names against this database, and the
        # reflected table only has to exist for the client to construct.
        athena.configure(database=self.database, reflect_table=self.primary.md_table)

        if not athena.table_exists(self.primary.md_table):
            self.skipped_reason = (
                f"Athena table {self.database}.{self.primary.md_table} is not reachable. "
                "The assessment reads the aggregate tables created by "
                "create_sightglass_tables; run that first, or pass an AthenaRunRef "
                "for a published release.")
            logger.warning("calibration assessment skipped: %s", self.skipped_reason)
            return self

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
            skip_ami=ami_csv is None,
            measures=",".join(measure_ids),
            measure_states=self.measure_states,
            skip_distributions=self.skip_distributions or cbecs_csv is None,
            skip_design_params=self.skip_design_params,
            skip_heating_fuel=self.skip_heating_fuel or cbecs_csv is None,
            no_cache=self.no_cache,
        )
        logger.info("calibration assessment: %d run(s), %d measure(s) -> %s",
                    len(args.runs), len(measure_ids), self.output_dir)
        _assess(args)

        # Build the page in the same call. In the standalone tool this was a
        # SECOND command (`python -m ...dashboard --assessment <dir>`), which is
        # why a first port of run() wrote every metric CSV and no dashboard at
        # all. One entry point, or the deliverable silently goes missing.
        page = dashboard.build(self.output_dir, self.dashboard_path)
        logger.info("dashboard: %s (%.0f KB)", page, page.stat().st_size / 1024)
        return self

    @property
    def dashboard_path(self) -> Path:
        return self.output_dir / "dashboard.html"
