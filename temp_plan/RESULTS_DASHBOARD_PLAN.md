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

## 8. PR #463 review follow-up (2026-09-27)

Reviewer requests (mpraprost), the open Copilot thread, and two additions asked for on
2026-09-27. Status as of this edit; each item names the file it lives in.

| # | item | root cause / decision | status |
|---|---|---|---|
| 1 | Timeseries tabs "having issues" (compare_upgrades) | `timeseries.check_no_duplicate_hours` counted rows per (building, hour) across ALL upgrade partitions, so any run with measures read as duplicated (5.13 rows/hour with eleven measures, 1.00 inside each partition) and both timeseries tabs were declined. Probe now restricted to `upgrade = 0` via `duplicate_hours_sql`; two unit tests. | done; verified end to end: `compare_upgrades_dbtest_5measures.py` (2026-09-27, EXIT=0) wrote Arizona, Minnesota and Ohio measure profiles and the tab renders them |
| 2 | Axis values look random | every axis split the data maximum into four equal parts. `niceStep`/`niceTicks` place gridlines on a 1-2-5 step; scale unchanged, only labels move. Applied to `yAxis` and the six hand-rolled tick loops. | done, verified in browser |
| 3 | Violins tiny with long tails | `boxPlot` scaled to the last outlier. New `opts.scale`: "whiskers" (default, axis just past the highest p95, outliers beyond counted in the figure corner) or "full"; Distributions tab toggle "Axis to p95 / Full range", persisted in the hash as `distScale`. | done, verified in browser |
| 4 | Baseline (and CBECS) in measure plots | No change. Upgrade 0 already drives every baseline-vs-CBECS tab; the measure figures already pair baseline against measure (end-use pairs, multi-measure bars, release table). Reply on the PR pointing at the Annual tab's closer/further arrows for run-vs-run. | reply pending |
| 5 | Copilot: cache key ignores table version | Local cache was already invalidated on export/crawl; the real hole was Athena's server-side result reuse (7-day, `buildstock_query` default), which served the re-exported new_sample tables stale on 09-21. `athena_query_reuse=False` in `results_dashboard/athena.py`. The clients in `comstock.py` and `gap/` still default to reuse. | done (uncommitted until this batch) |
| 6 | Remove "Percent difference vs CBECS by building type and metric" and "Share of floor area with no natural gas" | Both panels removed from the JS (`fuelMixPanel` deleted, `sec-gasmix` jump link dropped). The SQL still computes `sqft_zero_gas`; nothing reads it now. | done |
| 7 | Model failures per run, total and % | New leg `results_dashboard/failures.py` reads buildstockbatch's `<run>_baseline` / `<run>_upgrades` (the aggregates hold only successes, `drop_failed_runs`). `metrics/failures.csv`; "Model completion by run" panel on the Overview after the verdict strip. `Invalid` is shown as not-applicable, not failure, and the failed share is over applicable models. A published release has neither table, so the leg falls back to its aggregate, which records Fail/Invalid on measure rows but only successes on the baseline (stated in the panel). Rows are limited to the baseline plus the measures the dashboard compares; the CSV keeps all. | done; four-run dashboard shows plugfix 3/103,608, new_sample 26, fixes_ts 26, baseline_10k 2,685/103,224 (2.6%) |
| 8 | Custom-building-spec alias shim (`comstock.py`) | required by every ComStock Typical run; was uncommitted since 09-21 | committed in this batch |

### Copilot review 2 (2026-09-28): 12 open threads

| thread | verdict | change |
|---|---|---|
| distributions collapse assigns a straddling model's whole weight to its first census division | real, critical | `collapse_to_models` groups by (model, geography); cells count models with `nunique(bldg_id)`; `_prepare` carries `bldg_id` |
| design-params `_rn = 1` de-dupe does the same | real, critical | window partitions by (bldg_id, grouping column); pooled/by-type unchanged |
| county applicability CTE joined a county id as a state | real | CTE at the timeseries grain: (building, state) for published tables, building only for crawled; the metadata fan-out in the main join is intentional (partial weights) |
| `sqft_zero_gas` emitted without checking the gas column | real | guarded; `CAST(NULL AS double)` when absent |
| `df.get(GAS_TOTAL_COL)` -> None crashes CBECS aggregation | real | NaN share when the column is absent |
| run labels unescaped in `<title>`/subtitle and in `swatch` innerHTML | valid, low (driver-supplied) | `html.escape` in `dashboard.build`; idempotent `esc()` in JS, applied in `runLabel` (so `runShort` too) and `swatch`; swatch validates the colour |
| JS bundle read at import time | valid, low | `_js()` read at build time |
| upgrade shorthand drops runs in mixed comparisons | valid, low | shorthand only with exactly one ComStock dataset, else `_bounded_name` |
| AMI/CBECS loaders touch S3 despite a cached export | valid | `download_truth_data=False` when the export exists (new constructor flag on `AMI` and `CBECS`, default True) |
| cache key ignores table version (round 1) | answered | Athena result reuse disabled (commit `2e1e263`); local cache invalidated on export/crawl |
| committed `x.egg-info` (round 1) | answered | no longer tracked; `.gitignore` covers `*.egg-info/` |

Grain rules these fixes rest on, stated once: an apportioned aggregate has one row per
(building, state x climate zone) with a PARTIAL weight, so weighted sums may fan out across
those rows but unweighted counts and any "first row" collapse must key on the geography
too; a run with measures repeats every scenario per `upgrade`, so every query filters its
partition; a published timeseries table keeps one copy of a building per state folder, so
timeseries joins carry the state (crawled tables hold one copy and join on the building).
Tests: `test/test_results_dashboard_grain.py`.

Also verified while doing this: the four-run hospital dashboard reproduces from fresh
reuse-off queries for all four runs (`verify_run_linkage.py` in the buildstock-dev-ai skill).

### Copilot review 3 (2026-09-28): 7 open threads, 3 new

| thread | verdict | change |
|---|---|---|
| savings distributions: the model-level `drop_duplicates('bldg_id')` runs before the by-dimension loop, so a model whose rows fall in two categories of a dimension is counted in only the first | real for any geographic dimension; a no-op for today's three (building type, as-simulated climate zone, HVAC system are model attributes) | block lifted out of `assess_measures` into `measures.savings_distribution_rows`: pooled figures dedupe on the model, by-dimension figures on (model, dimension value); a log line reports how many models straddle a dimension; grain test added. Numbers unchanged for every existing dashboard. |
| failure notes and skip reasons (Athena exception text, table names) interpolated into innerHTML unescaped, in `completionPanel` and five other sites | valid, low (same trust level as the run labels) | `esc()` on notes, reasons, statuses, measure names, run labels/tables on the Coverage tab, the sources/references table, audit values, ranked-gap labels and bar tooltips; `safeColor()` validates every colour that lands in a style attribute (also used by `swatch`); `runShort` escapes its raw-key fallback; the run-toggle `data-run` attribute is escaped |
| `roll_up` / `roll_up_pair` turn an all-NULL metric into 0 (the `CAST(NULL AS double) AS sqft_zero_gas` case) | real | `sum(min_count=1)` in both, so a column the release lacks leaves the rollup as NULL and the page shows it as absent, not zero; test added |
| dashboard.py unescaped labels (carried from review 2) | fixed in `bf456be6` (`html.escape`) | reply and resolve |
| JS bundle read at import time / packaging (carried) | fixed in `bf456be6` (`_js()` at build time); `setup.py` ships `resources/*.js` via `package_data` | reply and resolve |
| cache key ignores table version (carried) | answered by `2e1e263` (Athena result reuse off; local cache invalidated on export/crawl) | reply and resolve |
| committed egg-info (carried) | not tracked on the branch; `.gitignore` covers `*.egg-info/` | reply and resolve |

Verification: `node --check` on the bundle; 21 dashboard tests pass (8 grain, 8 timeseries,
3 athena, plus 2 new); both local dashboards rebuilt from their existing metrics with the
new bundle (five-measure 17.5 MB, four-run 56.6 MB) and opened in the browser without
console errors.

PR housekeeping still open: tick the change-type and author checkboxes, add the
`postprocessing` label, reply to the two reviewer comments and the Copilot cache thread,
re-request the Copilot review. Optional: license headers on the `*.py.template` files
(absent on main too).
