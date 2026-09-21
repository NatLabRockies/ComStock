# ComStock results dashboard — plan and progress

**Repo/branch:** `NatLabRockies/ComStock` → `ccaradon/calibration-qaqc`
**PR:** [#463](https://github.com/NatLabRockies/ComStock/pull/463)
**Status:** feature complete, all five driver types run end to end, review follow-ups applied.
Remaining work is PR housekeeping, listed in [Open items](#open-items).

This file is the handoff document. It is written so another agent can pick the work up without
reading the PR thread.

---

## 1. What this is

A self-contained HTML dashboard that compares ComStock runs against CBECS, AMI, and each other,
built from published Athena aggregate tables. One `dashboard.html` per assessment, plus metric
CSVs beside it. Deterministic throughout: SQL, pandas, and a hand-written JS bundle — no
notebook, no plotting library in the output.

It was originally called "calibration" / "QAQC". It was renamed to **results dashboard** on
2026-09-11 because it is not only used for calibration. Anything still saying "calibration" in
older output folders is pre-rename and can be ignored.

## 2. Where the code lives

| path | role |
|---|---|
| `comstockpostproc/results_dashboard/assessment.py` | `ResultsDashboard`, the entry point; `OUTPUT_SUBDIR = "results_dashboard"` |
| `comstockpostproc/results_dashboard/athena.py` | query helper, disk cache, `.sql` sidecars, `upgrade_literal()`, `baseline_where()` |
| `comstockpostproc/results_dashboard/exports.py` | `load_ami`, `load_cbecs` |
| `comstockpostproc/results_dashboard/measures.py` | measure applicability and savings summary |
| `comstockpostproc/results_dashboard/annual.py`, `distributions.py`, `design_params.py`, `heating_fuel.py`, `timeseries.py`, `ami_shapes.py`, `cbecs_ref.py`, `jackknife.py` | the metric legs |
| `comstockpostproc/results_dashboard/dashboard.py` | HTML assembly, `_script_safe()`, `window.__DASHBOARD__` |
| `comstockpostproc/results_dashboard/resources/dashboard.js` | the whole front end |
| `comstockpostproc/athena_tables.py` | `prepare_athena_tables(...)` — export/crawl/views for every driver |
| `comstockpostproc/athena_config.py` | `ATHENA_WORKGROUP = "buildstock"`, the single source of truth |

## 3. Driver scripts — one per run type

Each is a runnable example. Measure drivers are capped at 5 measures so a test run is cheap.

| driver | run type |
|---|---|
| `compare_comstock_to_cbecs.py` | ComStock vs CBECS |
| `compare_comstock_to_cbecs_dbtest_1run_vs_release.py` | one local run vs a published release |
| `compare_comstock_to_ami.py`, `compare_comstock_to_ami_dbtest_1run.py` | ComStock vs AMI |
| `compare_runs.py`, `compare_runs_dbtest_2runs.py` | run vs run |
| `compare_upgrades.py`, `compare_upgrades_dbtest_5measures.py` | baseline + upgrades |

All five were run by the user and confirmed working (2026-09-11/12).

### Athena table handling

`prepare_athena_tables(comstock, database, timeseries=, ami=, rebuild=, upgrade_ids=,
glue_service_role=)` replaces the export/crawl/views block every driver used to carry inline.
It detects existing Glue tables and S3 objects and **skips** them by default; pass `rebuild=True`
to replace them deliberately. This removed the need to comment out code sections between runs.

Local metadata export is a top-level option on the driver, not buried in the assessment.

## 4. Progress

Commits on the branch, newest first:

| commit | what |
|---|---|
| `4bb87a3e` | Expand measure summary applicability and layout |
| `c7b9b5fa` | results dashboard — review follow-up (PR #463) |
| `6ab19b31` | Refactor calibration into results dashboard (the rename) |
| `ca11fd0f` | building-type selector filters the distributions |
| `44092735` | write output inside the run's existing output folder |
| `29fa1e06` | keep output under one parent folder |
| `207c2bfc` | driver template and README entry |
| `cce5bd7b` | assessment as a toggleable step |
| `1f93d77f` | name multi-run comparisons honestly, within Windows MAX_PATH |
| `12a41b65` | document the Athena workgroup in the README |
| `1b5d9312` | one Athena workgroup constant instead of eight literals |

### Measures annual tab (commit `4bb87a3e`)

Layout is **figures first, summary table last**. `renderMeasuresAnnual` builds `summaryPanel`
separately and appends it at all three exit paths (`dashboard.js` lines ~3617, ~3724, ~3783),
including the two early returns, so it cannot fall off in the empty-selection or
empty-intersection cases.

`measSummaryTable` has two header rows and these columns:

| group | columns |
|---|---|
| Applicable stock | floor area (`pct_of_stock_sqft`), buildings (`pct_of_stock`) |
| Savings | site, electricity, natural gas |
| End-use savings | heating (elec), heating (gas), cooling, fans |
| Bill savings | $/bldg·yr, $M/yr |
| Emissions | MMT CO₂e, % |

Every new column is guarded by `num(k)`, so a dashboard generated from an older payload omits
the column instead of rendering blanks. Verified end to end against the dual_fuel measure run.

**Why both applicability denominators:** `pct_of_stock` is weighted *buildings* and reads ~63%;
floor area is ~40%. The 2024 R2 deck quotes the floor-area number. Reporting only one caused a
real misreading, so the table now shows both.

## 5. Open items

Housekeeping the repo owner should drive:

- [ ] PR title and description — draft in `pr_463_description.md`
- [ ] File the weight-inflation issue — draft in `issue_weight_inflation.md`
- [ ] Re-request Copilot review after the follow-up commits
- [ ] Delete `~/.cache/comstock_results_dashboard/` once, to clear pre-workgroup-fix cached
      results (see gotcha 2)
- [ ] Decide whether the untracked investigation scripts belong on this branch or elsewhere:
      `compare_fan_*_dbtest.py`, `compute_fan_fix_btype.py`, `build_fanfix_btype_json.py`,
      `plot_fan_fix_*.py`. They are analysis, not dashboard code.

## 6. Gotchas that cost time before

1. **Published timeseries are EST.** Every building's `ts_by_state` timestamp is Eastern
   Standard Time; crawled `time` and AMI are local. Shift by state before comparing profiles.
   Already handled in `timeseries.py` — do not "fix" it again.
2. **The Athena cache hides failures.** Results are cached by SQL text *and connection*
   (database, workgroup, schema). The `comcore` → `buildstock` workgroup error stayed invisible
   for months behind cache hits. The connection is now part of the cache key.
3. **Weights are ~6% high** in published releases, from a duplicating utility-bill join. The
   dashboard **reads the data as is** — this is deliberate. The fix belongs in data processing,
   not here. See `issue_weight_inflation.md`.
4. **R2 and R3 schemas differ.** R2's national aggregate has no
   `in.ashrae_iecc_climate_zone_2006`; R2 lacks `total_bill_mean` and names gas differently
   (`natural_gas_bill..billion_usd` vs R3's `_state_average`). Operating-hours columns are
   varchar — `try_cast(... AS double)`.
5. **The building type column is `in.comstock_building_type`**, not `in.building_type`.
6. **Use the `comstockpostproc2` conda environment.** Everything here needs it:

   ```
   C:\Users\ccaradon\AppData\Local\anaconda3\envs\comstockpostproc2\python.exe
   ```

   The bare `py` / `python` on PATH is a separate Python 3.11 that has pandas and pyathena but
   **not** `sqlalchemy`, `polars` or `buildstock_query`. In that interpreter
   `from comstockpostproc.results_dashboard import athena` fails with a `ModuleNotFoundError`
   that looks like a code problem and is not one. Athena connection details, if ever needed
   directly: workgroup `buildstock`, region `us-west-2`, schema `buildstock_sdr`.

## 7. Related

- Fan motor-efficiency regression that this dashboard surfaced:
  `output/fan_motor_efficiency_regression_r2_to_r3.md`, and the fix plan in
  **ComStock-Typical**, branch `ccaradon/fix_psz_fan_eff_bug`.
