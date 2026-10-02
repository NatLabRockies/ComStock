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
| `compare_runs_mixed.py.template`, `compare_runs_mixed_dbtest.py` | any mix in one RUNS list: `process` (postprocessed here, per-entry stock estimate), `athena` (already crawled), `release`; added 2026-09-28, exercised end to end on plugfix (process) vs new_sample and baseline_10k (athena) |

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
| `1f93d77f` | name multi-run comparisons honestly, within Windows MAX_PATH -- **reverted 2026-09-28**: the class is back to main's version and the multi-run templates pass `name=COMPARISON_NAME` instead |
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

### 5a. Housekeeping the repo owner should drive

- [ ] PR title and description — draft in `pr_463_description.md`
- [ ] File the weight-inflation issue — draft in `issue_weight_inflation.md`
- [ ] Re-request Copilot review after the follow-up commits
- [ ] Delete `~/.cache/comstock_results_dashboard/` once, to clear pre-workgroup-fix cached
      results (see gotcha 2)
- [ ] Decide whether the untracked investigation scripts belong on this branch or elsewhere:
      `compare_fan_*_dbtest.py`, `compute_fan_fix_btype.py`, `build_fanfix_btype_json.py`,
      `plot_fan_fix_*.py`. They are analysis, not dashboard code.

### 5b. Work plan — placeholders, coverage, axes, local-only checks (opened 2026-09-30)

**Owner's rules, which every item below serves.**
1. No placeholders shown as data: no default, sentinel, dummy or "not computed" value may be
   displayed, averaged or counted as a modelled property; no hard-coded statistic in a note.
2. Coverage wherever the data has it: if the exported tables carry a value for a building, the
   panel uses it and "applies to" says so.
3. Averages are fine as long as they correctly represent the average and accurately show
   change. Do not drop a population to make a number look better; do fix an average that mixes
   in a value that is not the quantity being averaged.
4. Axes: tick increments on clean values (1, 2, 5 x 10^k; never 7s or 2.5s); the top and the
   bottom of every axis are labelled ticks, so the last label is never at 75% of the height.
5. No template others run, and no driver being run or tested, may depend on a file that only
   this machine has.

**How each item was checked.** `[V]` re-derived by hand in this session from the raw
`results_up00.parquet` of `str_100k_new_sample_plugfix_fanfix` (103,605 successful models) or
from the cited code lines. `[A]` confirmed by two independent readers (auditor, then a skeptic
told to refute it) in workflow `wf_1708b547-785` (journal.jsonl holds the full evidence) but not
re-run by hand. `[?]` one reader only; verify before acting. Nothing below has been applied.

#### D. Dashboard only — fix in `results_dashboard/`, re-render from the existing Athena tables (this PR)

**Status 2026-09-30 evening.** D1–D9 are coded (design_params.py, dashboard.js, assessment.py,
annual.py, heating_fuel.py; 31 tests pass, `test_results_dashboard_design_params.py` pins the rules:
no percentages in notes, absent_note on partial metrics, tokens resolved, spread kept per type).
Verified in the browser on a CSV-only re-render of the fanfix dashboard: axes end on labelled 1-2-5
ticks, "none qualify" / cause tooltips, every-metric table shows absent not 0.00, Coverage-tab
sentences derived from the data. **Still needed:** re-run the fanfix assessment (Athena; SSO had
expired) so the new design-param metrics (unitary fans, separable pumps, share cooled, EFLH from
metered energy, cooling-blend guard, per-type spread, absent_note text) and the complete heating-
fuel partition appear; then read the Fans & pumps and Ventilation groups against the raw-parquet
numbers in this plan. M1-M7 unchanged (measure).

**Status 2026-10-01 morning.** The design-parameter re-assessment ran (9 min, Athena accepted
the scalar subqueries; the new tab verified in the browser: unitary fans 66% of floor area
stock-wide, 45.1% -> 52.4% efficiency across the fan fix; warehouse cooling rows say why they
are empty; separable pump rows). Step 2 (D10-D18, D20) is coded: site_energy.cbecs_fuels on
both sides with a jackknife interval (derived metrics now get intervals), the all-fuel site
total blanked against CBECS; waterfall pairs lighting as interior+exterior and names the
ComStock-only end uses; summary carries other-fuel savings; savings distributions count
undefined/zero values; gas-free floor-area panels (per type and across types); AMI thin-hour
rule (>=95% of hours backed, thin hours dropped, missing != thin); thin EUI cells drawn
faded/dashed; zone 7 merged after the audit; completion table shows in-aggregate / not-
apportioned counts; the measure timeseries reads the CRAWLED table (kBtu x 0.29307) and
refuses a create_views view's fossil fuels, so gas is right without waiting for X1, plus an
other-fuels panel. D19 has only the note (the fix is export-side).
Verified on the regenerated fanfix dashboard (2026-10-01 08:46 build): headline site energy on
CBECS fuels +49.6% (was +53.3% on all fuels), waterfall names the ComStock-only end uses and the
disaggregation residual, summary reconciles (614.9 = 141.7 + 421.2 + 52.1), distribution label
"n=14,858 · 21,679 undefined · 492 zero" in red, completion 93,889 in aggregate / 9,716 not
apportioned, AMI thin-hour rule keeps cherryland small_hotel + FSR (0.1% hours dropped), zone 7 one
bin, gas timeseries from the crawled table (MN winter weekday gas 2.0 GW thermal vs 1.1 GW
electric; the view would have given 23 GW). One more re-run carries the other-fuel columns into
the measures_ts CSVs (they were dropped by a hard-coded column list in assess_measure_timeseries).

- [x] **D1 Fans: cover unitary, packaged and zone-equipment fans.** `[V]` The panel reads only
      `out.params.air_system_fan_*`, which the reporting measure fills for loop-level fans only.
      Fans inside `AirLoopHVACUnitarySystem` (PSZ/RTU, residential furnace) and zone equipment
      (PTAC/PTHP, fan coils, WSHP) are recorded under `out.params.zone_hvac_fan_static_pressure..inwc`,
      `out.params.zone_hvac_fan_total_efficiency` (`measure.rb:1230-1371`; exported, column
      definitions :682-684). 36.5% of models have air-system fan data, 72.4% zone-HVAC, 8.9% both,
      0% neither. Retail 0.9%/99.1%, grocery/QSR/small hotel 0/100%, small office 20/80%. Add rows
      "Unitary / zone-equipment fan power (W/cfm), static pressure, total efficiency" with guard
      `zsp > 0 AND zeff > 0`, weight `W * sqft`. Never add the zone min-flow column (1.0 for all
      75,033 zone fans: on/off and CV fans have no turndown). This is what makes the fan fix
      visible: zone-fan efficiency changed in 27,486 models (PSZ-AC gas coil median 0.37 -> 0.55).
- [x] **D2 Air-loop fan rows: rename, guard the diluted models, split min-flow.** `[V]` Rename
      the existing rows "Air-loop (AHU) fan ...". Dilution (see M1): 1,309 of 37,807 air-system
      models report a static pressure below 2.49 in. w.c., the smallest value any single-loop
      model has (single-loop values are exactly 2.5, 4.0, 4.09, 4.46, 5.58, 6.32); none is
      single-loop, all also have zone fans; medium office 860 (median 0.21 in.), outpatient 344
      (0.02 in.). Their values are real fans averaged with unitary loops counted at 0 Pa. Interim
      guard for fan_sp/fan_eff/fan_minflow/fan_wcfm: `sp >= 2.49 AND eff >= 0.50` (excludes no
      single-loop model). It cannot correct partial dilution; only M1 can. "Fan minimum flow
      fraction" -> "VAV fan minimum flow fraction" with guard `minflow < 0.999 AND vav > -900`:
      1.0 on a CV fan is a real property, but blending it with VAV turndowns produces a number
      that is neither (LargeHotel reads 99.6% because 98% of its air-loop fans are CV).
- [x] **D3 Pumps: remove "Pump motor efficiency"; replace with separable metrics.** `[V]`
      43,493 models (42.0%) report exactly 1.0, and all 43,493 use 0 pump kWh: they carry only the
      zero-head placeholder circulation pump openstudio-standards puts on a service-hot-water loop
      that has no real pump. Grocery 100%, strip mall 98.5%, small office 88.9%, secondary school
      45%. The rated-flow weighting also pulls real pumps toward 100% where a placeholder shares
      the building (FSR +4.2 pp). The note's reason ("autosized pumps have 0 rated power") is
      false for these runs (all hardsized). Replace with: SWH circulator efficiency (models with
      SWH const-speed pumps only: 29,161, mean 58%); HVAC constant-speed (5,580, 90%); HVAC
      variable-speed on models without a placeholder (3,917, 87%); rated pump power density
      `(pump_total_constant_speed_pump_power_w..w + pump_total_variable_speed_pump_power_w..w)/sqft`
      for all ~30k HVAC-pump models. Column names lower-case as Athena has them. No percentages
      in notes. Full split until M3 lands.
- [x] **D4 Cooling setpoint: stop averaging the cooling-off value as a setpoint.** `[V]` The
      measure averages the schedule minimum over every zone with a cooling thermostat schedule,
      weighted by floor area (`measure.rb:1555-1614`). Warehouse zones that are not cooled still
      carry a schedule whose value is ~52 C (126 F, implied from the export), so every warehouse
      exports 42.8-43.8 C (fraction cooled 0.30-0.34) and the panel shows "109 F" for Warehouse
      and 77.2 F for the stock, against ~73 F over the buildings whose value is a setpoint. Per
      rule 3 the average must represent the setpoints that exist and move only when they move;
      this one also moves if the cooled fraction moves. Fix so it does: M5 in the measure. Until
      then: guard `c_min < 35` on clg_sp and `c_min < 35 AND c_max < 35` on clg_setup (35 C is
      above any real setpoint and below any blend), report in "applies to" the share of COOLED
      floor area covered, and show `out.params.building_fraction_cooled` beside the row so the
      Warehouse cell says "34% of floor area cooled; exported setpoint is a blend" instead of a
      number. Delete the `< 45` sentinel rule and its comment (design_params.py:205-219).
- [x] **D5 Keep real zeros where zero is a modelled outcome.** `[A]` Cooling setup depth drops
      flat schedules (`c_max - c_min > 0.5`): 16,811 non-warehouse models were sampled with
      `hvac_tst_clg_delta_f = 0`, so 0 is the value; the shown mean is 19% high (5.79 vs 4.85 F)
      and not comparable with the heating setback beside it. Occupant density drops 717 zero-
      occupant warehouses (a modelled 0). Keep both zeros; keep `> 0` only for per-person and
      EFLH ratios and say so in the note.
- [x] **D6 Lighting EFLH: compute from metered energy.** `[V]` For the 12,157 models with zone
      multipliers, metered interior lighting kWh / (LPD x sqft x EFLH) has median 2.02 (p10 1.30,
      p90 6.17; large office 2.82, hospital 2.07, large hotel 1.84); for the 91,448 models without
      multipliers it is exactly 1.000. The measure takes EFLH = LightingSummary consumption /
      total power (`measure.rb:882`) and the two carry the multiplier inconsistently; LPD is
      unaffected (identical between groups). Define light_eflh as
      `electricity.interior_lighting kWh * 1000 / (LPD * sqft)`, weighted by connected load as
      now. Drop light_implied, or relabel it "Interior lighting intensity (simulated)" and delete
      the "design-implied, NOT simulated" note. M6 for the measure.
- [x] **D7 Weighting that misstates the average.** `[A]` Plug-load density is weighted by
      building count (1.51 W/ft2) although equipment-served area is within 5% of floor area for
      98% of models; weight by floor area (0.91 W/ft2) and delete the "cannot be multiplied by
      floor area" note. Window-to-wall ratio is weighted by NET wall area (10.3%); weight by gross
      wall (wall + window: 13.0%, which equals aggregate window / aggregate gross wall). Outdoor-
      air fraction: guard `num_air_loops > 0 AND oaf IS NOT NULL` (residential-furnace loops
      with no OA intake are a real 0; PTAC/PTHP have no air loop and their zone OA is not
      recorded, see M4); rename "Air-loop outdoor air fraction"; note that DOAS loops read ~100%.
- [x] **D8 Labels, notes and tags that assert what the data does not.** `[V]` where marked.
      (a) `[V]` No literal statistic in any Metric note, docstring or panel note: "68% have
      none", "72.6%", "26%", "34%" were measured once and are wrong now (design_params.py:14-30,
      205-209, 233-234, 244-245, 249-250, 274; dashboard.js:5041-5048). Derive shares at render
      time from n_models / coverage_pct or say nothing.
      (b) `[V]` `notPublished` ("this release does not carry the columns") is rendered whenever
      wmean is null (dashboard.js:4733-4736), including rows that exist with n_models = 0 (20
      per run today: grocery/QSR/small-hotel fans, warehouse hot water and cooling setup, small-
      hotel OA). Use it only when the row is missing; otherwise a cause-specific tag ("no model
      of this type has an air-loop fan", "no model has service hot water").
      (c) `[V]` Per-building-type p10/p90 are computed in every pass (design_params.py:372-377)
      and discarded for by-type rows (:463-468); the panel then prints "stock-wide only". Keep
      them (`if not by_bt or dim_key == "none"`), render them, delete `stockWideOnly` and its
      legend row (dashboard.js:4745-4748, 5311, 5047-5048).
      (d) `[V]` The per-type "every metric" table prints CBECS **0.00** for the 80 cells where
      CBECS publishes nothing (`fmt(r.cbecs_value*scale,2)` on null, dashboard.js:2030), which
      contradicts the Coverage tab's "absent, never zero". Render absent; pick the CI tag by
      cause (0 -> none surveyed, derived -> real interval, else not published).
      (e) `[A]` Weight-basis text: Coverage tab and annual.py say "not scaled to CBECS";
      findings.md says it is scaled and "should read 0%"; the export does scale
      (comstock.py:2469) and floor area lands +4.6% to +6.9% above CBECS in every type. Generate
      one sentence from the data (X5 owns the cause). AMI caveat: build from
      `coverage.ami_regions_compared` (9 regions assessed, text names one).
      (f) `[A]` The population badge on multi-measure panels sums apportionment rows and calls
      them models (163,212 vs 93,889 for the stock: +74%); sum n_models.
      (g) `[A]` Heating-fuel matrix labels a fuel ComStock does not assign to a type "cannot
      represent"; for 26 of the 61 such cells it is a sampling gap, not a structural limit. Emit
      zero-share rows for every fuel and show the numeric difference with a "ComStock assigns
      no <fuel> to this type" note.
- [x] **D9 Axes: clean increments, labelled extremes.** `[V]` `niceStep` chooses steps from
      {1, 2, 2.5, 5, 10} x 10^k and `niceTicks` deliberately leaves the SCALE at the data maximum
      (x1.1 headroom in some figures), so the top gridline "may sit below the frame"
      (dashboard.js:214-245). Example: max 455 -> axis 500.5 -> step 200 -> ticks 0, 200, 400 ->
      last label at 80% of the axis. Change: steps from {1, 2, 5} x 10^k only; axis max =
      ceil(dataMax / step) x step and, when the axis does not start at 0, axis min =
      floor(dataMin / step) x step, so both ends are labelled ticks; include CI whiskers, violins
      and negative bars in dataMax/dataMin so nothing is clipped; drop the x1.1 headroom where the
      ceiling supplies it. Call sites: `yAxis` (:239), histogram y and x (:783, :790), 24-h
      profiles (:867, `max = rawMax*1.1`), waterfall (:1182), :2221, diverging bars (:3146, :3206),
      and any figure that computes its own ticks. Check every tab after: bar heights change
      because the scale changes.
- [x] **D10 Site energy vs CBECS like-for-like.** `[V]` ComStock site energy includes propane
      and district cooling, which CBECS never counts. From this run's own table: Hospital shown
      +7.3%, without them -4.0% (district cooling is 49.3 TBtu, 10.5% of hospital site energy);
      LargeOffice +74.0% vs +63.0%; FSR +161.6% vs +151.7%; national +53.3% vs +49.6%. Define the
      CBECS-comparable site total as electricity + natural gas + fuel oil + district heating
      wherever CBECS is the reference (headline card, verdict strip, ranked gaps, EUI
      distributions); keep the full ComStock total as a ComStock-only row.
- [x] **D11 End-use waterfall: the grey bar is ComStock load, and lighting is mis-paired.**
      `[A]` CBECS electricity end uses sum exactly to its total (2,633.2 TBtu). The ComStock end
      uses in END_USES sum to 3,609.0 against 3,779.0, so the 170.0 TBtu grey bar labelled "CBECS
      does not disaggregate" is exterior lighting (105.0) + pumps (51.0) + heat recovery (6.8) +
      heat rejection (7.1). CBECS lighting (459.0) is paired with ComStock INTERIOR lighting
      (502.0, +9%); like-for-like is lighting_combined (607.0, +32%). Add the missing end uses as
      ComStock-only bars, pair CBECS lighting with lighting_combined, and split the residual into
      "ComStock end uses with no CBECS counterpart" and a true remainder.
- [x] **D12 Measure summary omits propane and fuel-oil savings.** `[V]` `measures.FUELS =
      ["electricity", "natural_gas"]` (measures.py:37) feeds the summary; site - elec - gas =
      614.94 - 141.68 - 421.21 = 52.05 TBtu for HPRTU_E_Backup (9-11% of site savings per
      measure), which the scenario rows (queried with all fuels) account for exactly: propane
      29.9 + fuel oil 22.1 + district heating. Add propane/fuel-oil/district-heating columns from
      the scenario pair; fix the note that claims the difference is something else.
- [x] **D13 Measure timeseries: gas 11.6x high; other fuels absent.** `[V]` The `_timeseries_vu`
      view divides kBtu gas by the kWh factor instead of multiplying (X1). Until X1 lands and the
      views are recreated, the tab must read the crawled `total_site_gas_kbtu` and convert
      (x0.29307) itself, or say the MW-thermal panels are wrong. Then add propane, fuel oil and
      district heating (`[A]` in MN they are 146 GWh against 219 GWh gas; in AZ 48% of fossil
      heating savings) as an "other fuels" line, after verifying the crawled column names.
- [x] **D14 Savings distributions: undefined and zero-baseline models are dropped silently.**
      `[A]` The % view drops models whose baseline is 0 (24,210 of 40,867 applicable have no
      electric heating before HPRTU), so "electricity heating" reads -60% on the typical building
      when most gain electric heating; bill % savings drop 7,090 models (19%) whose bill saving
      is 0 or non-finite (X2 fills nulls with 0). Count n_undefined and n_zero, show them beside
      n, grey the % box and point to the EUI/$ view when undefined >= 25%.
- [x] **D15 Fuel mix is computed and never shown.** `[A]` `fuel_mix_by_*.csv` are written and
      embedded (`D.fuelByDim`) and nothing renders them; distributions.py:22 points readers to a
      table that does not exist. Grocery 0.0% gas-free floor area vs CBECS 30.1%, outpatient 0.1
      vs 28.2, FSR 0.3 vs 20+. Add the panel on the Annual and Distributions tabs.
- [x] **D16 AMI: thin types relabelled "no AMI data".** `[V]` `compare_region` drops a building
      type whose MINIMUM hourly meter count is below 3 and then computes `ami_missing_types =
      cs_types - ami_types` from the already-reduced set (ami_shapes.py:415-436), so 11 region x
      type pairs with data (veic large office: 1 hour of 8,759 below 3 meters) are listed under
      "No AMI truth data". Compute missing before removing thin; keep a type when >= 95% of hours
      have >= 3 meters and drop only the thin hours; record the dropped-hour share.
- [x] **D17 Thin EUI cells drawn solid.** `[A]` distributions.py sets `thin` for n < 10 and
      promises a flag; boxPlot never reads it. 89 CBECS crossed cells have n < 10, 16 have n = 1
      and draw as a zero-height box. Grey/hatch thin boxes, append n, state the threshold;
      findings.md says "n < 60" (assessment.py:156) — use `distributions.THIN_MODELS`.
- [x] **D18 Climate zone 7 / 7A / 7B.** `[A]` Three bins for one zone (81, 260, 20 Mft2) from
      mixed codebooks in the sampled `climate_zone_ashrae_2006`; the category audit has no
      climate-zone list so it reports nothing. Merge for display with a note; add the canonical
      list to `ORDERED_CATEGORIES`; X4 for the upstream codebook.
- [ ] **D19 Run-vs-run design-parameter deltas include apportionment noise.** `[A]` Each run is
      apportioned separately (random draw per group), so identical per-model inputs show deltas
      up to 1.4% (lighting, plug, envelope). When two runs share a sample (same building_ids and
      sqft), compute the comparison run's parameters on the primary run's weights, or render the
      delta as 0 when the per-model inputs are identical.
- [x] **D20 Model counts that do not reconcile.** `[A]` Completion table: 40,870 applicable;
      Measures summary: 37,029. The 9.4% gap (27% of hospitals) is models never drawn by the
      apportionment (by design, comstock.py:3345-3350) — not an export loss — but nothing says
      so, and measure failure rates include the 3 baseline failures. Add "in weighted aggregate"
      and "not apportioned" columns; subtract baseline failures from measure rows; change "one
      vote per simulated model" to "one vote per model in the apportioned table".

- [x] **D21 Run order on the page follows the driver's list.** Owner's request 2026-10-01. The
      dashboard drew every run in manifest order but moved the run under review to the END, so
      the bar order differed from the list just written. Now: CBECS first, then the runs in
      RUNS order, top to bottom = left to right, everywhere (grouped bars, legends, tables, the
      header checkboxes). `REVIEW_RUN` names the run under review in the mixed template, so it
      can sit anywhere in the list; `measures=True` belongs on that entry. The order travels as
      `display_order` (ResultsDashboard -> manifest -> payload); an older assessment falls back
      to its manifest order. findings.md follows it too, and its run-vs-run change is now
      measured against DELTA_REF (it was against whichever run happened to be listed last).
      Verified 2026-10-01 from cache: the fanfix driver (listed fanfix, plugfix) draws CBECS,
      fanfix, plugfix; a reordered copy (`compare_fanfix_measures_dbtest_order.py`, listed
      plugfix then fanfix, REVIEW_RUN fanfix, output `fanfix order test/`) draws CBECS, plugfix,
      fanfix with fanfix still the run under review (Measures tabs, AMI stack, toggles).
#### T. Templates and drivers — local-only checks (audit `wf_c7167ba6-fb6`, 5 readers + 5 skeptics)

- [x] **T1 This PR** (done 2026-10-01; the driver copies got the same text) (templates it already touches):
  - [x] `compare_runs_mixed.py.template`, then copy into `compare_fanfix_measures.py` and
        `compare_runs_mixed*.py`: the pairing-failure hint globs local `truth_data/` (~l.424) so a
        fresh machine lists no candidates — list `s3://eulp/truth_data/v01/StockE/` instead;
        `estimate_path` docstring/error says hand-copy an estimate into the local folder — say
        upload estimate AND tract list to StockE; the docstring launch line redirects into
        `logs/`, which a fresh clone lacks.
  - [x] `compare_runs.py.template:73`: `Apportion(reload_from_cache=True)` raises on a machine
        that never apportioned 2025R3 (after both runs are processed). Detect the cache.
  - [x] `compare_comstock_to_ami.py.template:63`: `CBECS(reload_from_csv=True)` raises without
        `CBECS wide.csv`. Use `cspp.load_cbecs()`.
  - [x] `compare_comstock_to_cbecs.py.template:96`: `include_upgrades=True` but bills are built
        for upgrade 0 only; `create_plotting_lazyframe` needs bills per upgrade. Loop over the
        loaded upgrades.
- [ ] **T3 Retire the one-off drivers** (`compare_four_runs_hospital_plugfix.py`,
      `compare_three_runs_*`, `compare_str_100k_*`, the ignored `compare_runs.py` /
      `compare_upgrades.py` / ... copies): 11 of 12 hard-code `reload_*=True` for this disk. Point
      teammates at the mixed template (Eric hit both the estimate guard and the AMI CSV in the
      hospital driver on 2026-09-30).

**Cache report + REUSE_CACHES (2026-10-01, owner's request).** `cspp.report_caches()` logs one
line per cache a driver will touch (REUSE / BUILD / REBUILD / RECOMPUTE, date, path, upgrades held)
before anything expensive starts; every template calls it. The mixed template (and the driver
copies) gained `REUSE_CACHES`: True reuses what the disk holds, False rebuilds the run-specific
caches and deletes each run's bills folder (the one cache nothing refreshes). Detection stays
automatic either way -- a user-set "trust the cache" flag is what stranded Eric twice.

#### Suggested order

1. D9 axes, D8 labels, D1-D3 fans and pumps, D4-D7 setpoints/EFLH/weighting: all design-
   parameter work, one re-render to check.
2. D10-D12, D14-D20: the other panels, one re-render.
3. D13 with X1: fix the view, recreate views, re-render the measure tab.
4. T1, the cache report and D21 in this PR. Everything else is queued in 5c.

### 5c. Separate PRs — not this PR; break them off one at a time

Everything below was found during this PR but belongs elsewhere. Each line is its own PR
(or an issue for another owner); tick it when that PR merges, and keep the evidence that
follows the queue until then. Context as of 2026-10-01.

- [ ] **PR-A `create_views` unit inversion (X1).** comstock.py `create_views` divides a
      crawled run's kBtu / therm / MBtu timeseries columns by the to-kWh factor instead of
      multiplying: gas 11.6x too high, therms 858x too low, MBtu 85,891x too low; kWh columns
      are right. Introduced with the SDR 2025 R4 work (`0c14308b`, 2026-01-21). Scope, checked in
      Athena 2026-10-01: the 32 `<run>_timeseries_vu` views in `enduse` (internal crawled runs,
      including `sdr_2025_r4_103224_baseline_2`); none in `buildstock_sdr` (the published R2/R3
      `ts_by_state` views store kWh, factor 1, no division) and none in `vizstock`; OEDI files
      untouched (a view is a query-time object); metadata `_vu` views only rename and cast.
      SightGlassDataProcessing `euss_release_c3` builds its aggregates from the per-building
      parquet with weights and its view script has no arithmetic, so it is not affected by the
      code; any SightGlass instance that was loaded FROM an `enduse` timeseries view is wrong for
      fossil fuels. Fix: multiply, then recreate the 32 views. The dashboard already reads the
      crawled tables and refuses a view's fossil fuels (this PR, D13).
- [ ] **PR-B weight inflation (X4).** Exported floor area lands +4.6% to +6.9% above CBECS in
      every run assessed, after a scaling step that should leave 0%. Measured on the fanfix run:
      allocation stage 14,009,063 rows / 93,978 models; bills stage (what is exported)
      14,784,323 rows / 93,889 models: +5.5% rows for fewer models, so rows are duplicated inside
      `create_allocated_weights_plus_util_bills_for_upgrade`. NOT the tract-to-utility map (one
      row per tract, 108,660); the join of the exploded per-utility bill results is the suspect.
      First task: find the key the duplication is on (the 15 M-row group-by crashed polars in
      memory; chunk it by state). Then fix and re-export the runs in use. Gotcha 3.
- [ ] **PR-C bill percent savings filled with 0 (X2).** `fill_null(0.0)` / `fill_nan(0.0)` after
      the percent division (comstock.py:3590-3591): "not computed" reads as "0% saving", ~19% of
      applicable models per measure. Leave them null; the dashboard already counts them (D14).
- [ ] **PR-D climate-zone codebook (X3).** The sampled `climate_zone_ashrae_2006` spells zone 7
      as '7', '7A' and '7B'; normalize in the sampling TSV / sampler. The dashboard merges them
      for display (D18).
- [ ] **PR-E templates and library reliability (T2).** `create_load_components_long_csv.py.template`
      broken for everyone; extract/transfer templates point at retired Eagle paths and the
      transfer template's default destination is the published OEDI 2023 R1 prefix;
      `reload_from_*=True` raises instead of building (Apportion, CBECS, AMI, the ComStock
      simulation cache, `create_allocated_weights`, EIA); the bills cache is reused whatever
      weights were just computed (now visible in the cache report and deletable with
      REUSE_CACHES=False, but the library should refresh it); the upgrade list is a glob of the
      `results_up*.parquet` files on disk.
- [ ] **PR-F export the fan flow weights (X5)**, once the reporting measure registers them (M2).
- [ ] **Reporting measure, for its owner (M1-M6; needs new simulations).** M1 air-loop fan values
      diluted by unitary loops counted at 0 Pa; M2 register per-group fan airflow; M3 the zero-head
      placeholder SWH pump counted as a pump; M4 zone-HVAC outdoor-air fields written as 0 on a
      failed lookup; M5 setpoint averages include zones whose schedule means "off"; M6 lighting
      EFLH inconsistent with zone multipliers.
- [ ] **M7 investigation, model generation (unverified).** Hot water per ft2 is 1.6-3.6x higher
      in multiplied large buildings; verify on one multiplied model before anything changes.

Evidence for each, as found (moved here from 5b):

#### X. Export / library — `comstockpostproc`, also on `main` (separate PR)

- [ ] **X1 `create_views` divides by the to-kWh factor.** `[V]` comstock.py:4779 (main :4719):
      `(col/conv_factor)` where conv_factor is kWh per unit, so kBtu columns come out 11.64x high,
      therm 858x low, MBtu 85,891x low in every `<run>_timeseries_vu`; kWh columns are right.
      Anything reading those views inherits it (dashboard measure load shapes, SightGlass).
      Change to `col*conv_factor`, recreate the views for every run in use, then D13.
- [ ] **X2 Bill percent savings: nulls and NaNs filled with 0.** `[V]` comstock.py:3590-3591
      `fill_null(0.0)` / `fill_nan(0.0)` after the percent division, so "not computed" and "0%
      saving" are the same number (~19% of applicable models per measure). Leave them null; D14
      then counts them.
- [ ] **X3 Climate-zone codebook.** `[A]` `climate_zone_ashrae_2006` in the sampled buildstock.csv
      has '7' 1,020, '7A' 2,093, '7B' 567; normalise in the TSV/sampler or map in the export.
- [ ] **X4 Floor area lands +5.4% above `CBECS wide.csv` in every run and type.** `[V]` from the
      findings tables of every dashboard built so far (+4.6% to +6.9% by type). The scaling step
      should make it 0%; find where weight is added after `create_allocated_weights_scaled_to_cbecs`
      (see `issue_weight_inflation.md`, gotcha 3).
- [ ] **X5 Export the fan flow weights** once M2 registers them (column definitions +
      full_metadata TRUE), and the descriptions of pump columns 693/695/699 should carry the
      placeholder caveat until M3.

#### M. Reporting measure — `measures/comstock_sensitivity_reports/measure.rb` (needs new simulations)

- [ ] **M1 Air-system fan values diluted by unitary loops.** `[V]` The air-loop pass adds every
      loop's mixed-air mass flow to the denominator (:1160) but fills fan properties only when
      `air_loop_hvac.supplyFan` returns a fan (:1083-1108); a loop whose fan sits inside a unitary
      system contributes flow at 0 Pa / 0 efficiency (the code warns about this at :1067 and
      counts the flow anyway). Keep a separate fan weight incremented only when a fan was read;
      divide by it at :1176-1180; keep the total flow for the OA fraction. Add a `FanSystemModel`
      branch (OS 3.10 `supplyFan` returns it; today it falls to "type not recognized" and dilutes).
- [ ] **M2 Register per-group fan flow.** `[A]` `zone_hvac_fan_total_air_flow_m3_per_s` is a
      local (:1226, :1319) and no air-system fan flow is registered, so no combined per-building
      fan metric is possible for the 8.9% of models with both kinds. Register both.
- [ ] **M3 Placeholder SWH pumps.** `[V]` symptom (D3). Exclude pumps with rated head <= 1 Pa
      (or power < 0.0746 W) from every pump efficiency and count (:1397-1451); register the
      non-circulating SWH loop count separately; fall back to `autosizedRatedFlowRate` (:1399,
      :1414) and leave the value NULL, not 0.0, when a building has no real pump.
- [ ] **M4 Zone-HVAC outdoor-air fields are 0 in all 103,605 models.** `[A]`
      `zone_hvac_total_outdoor_air_mass_flow_rate` and `zone_hvac_average_outdoor_air_fraction`
      are exactly 0 everywhere because `sql_get_report_variable_data_double` returns 0.0 on a
      failed lookup (:50-75) and the OA node name lookup fails. Skip `registerValue` (NULL) on a
      failed lookup; fix the node name.
- [ ] **M5 Cooling (and heating) setpoint averaged over zones whose schedule is "off".** `[V]`
      :1555-1614 weights every zone with a thermostat schedule. Exclude schedule values that are
      not setpoints (cooling >= 40 C, heating <= 5 C) from the weighted sums, or weight by the
      cooled/heated zone area already computed for `building_fraction_cooled/heated` (:1499).
- [ ] **M6 Lighting EFLH inconsistent with zone multipliers.** `[V]` symptom (D6): EFLH from
      LightingSummary consumption / total power (:882) is off by ~the multiplier in multiplied
      models. Take consumption from the interior-lights meter and power with multipliers applied
      (or compute EFLH per Lights object and weight by power).
- [ ] **M7 `[?]` Hot water scales with the zone multiplier.** One reader claimed SWH demand is
      multiplied twice. Symptom check this session (exported m3 per ft2, medians, multiplied vs
      not): hospital 0.057 vs 0.016 (3.6x), large office 0.032 vs 0.019 (1.7x), large hotel 0.060
      vs 0.037 (1.6x), outpatient 0.040 vs 0.025 (1.6x), medium office 0.0187 vs 0.0182 (none).
      Consistent with a multiplier problem in most large types but not conclusive; it is model
      generation (SWH sizing), not the reporting measure. Verify on one multiplied model before
      any change. If real, it also inflates the water-heating end use on the annual and CBECS tabs.

#### T2. Templates and library reliability (PR-E)

- [ ] **T2 Separate PR:**
  - [ ] `create_load_components_long_csv.py.template`: broken for everyone (reloads a cache that
        does not exist, no bills step, `C:/path/to/...` read path).
  - [ ] `extract_models_and_errors` / `transfer_model_files_to_s3` templates: example yml paths
        (FY22 `/projects`, retired Eagle); transfer's default destination is the published OEDI
        2023 R1 prefix. Placeholders plus a guard.
  - [ ] Library: `reload_from_*=True` raises instead of building (Apportion, CBECS, AMI, ComStock
        sim cache, `create_allocated_weights`, EIA). `load_ami`/`load_cbecs` show the fix.
  - [ ] Library, silent result differences: the bills cache
        (`cached_allocated_weights_plus_bills/`) is reused whatever weights were just computed;
        the upgrade list is a glob of `results_up*.parquet` on disk.

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
| upgrade shorthand drops runs in mixed comparisons | valid, low | superseded 2026-09-28: the naming change was reverted altogether (`comstock_to_cbecs_comparison.py` matches main); `compare_runs.py.template` and `compare_runs_different_samples.py.template` pass `name=COMPARISON_NAME`, so the folder is the driver's choice |
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

Naming decision (2026-09-28): the CBECS comparison class stays exactly as on main. Its default
folder name assumes one run compared across its upgrades (more than two dataset names ->
"<two shortest> and Upgrades"), which misnames a multi-run baseline comparison, so the two
multi-run templates now pass `name=COMPARISON_NAME` and the README's settings excerpt lists
it. Whoever writes the driver names the folder; the templates say to keep it short on Windows.

Verification: `node --check` on the bundle; 19 dashboard tests pass (8 grain, of which 2 new;
8 timeseries; 3 athena); both local dashboards rebuilt from their existing metrics with the
new bundle (five-measure 17.5 MB, four-run 56.6 MB) and opened in the browser without
console errors.

### Copilot review 4 (2026-09-28): 4 open threads, 1 new

| thread | verdict | change |
|---|---|---|
| legend colours (`i.color`, `SECONDARY.color`, measure and series colours, payload end-use colours) written into style attributes without `safeColor` | valid, low (driver/payload-supplied) | `safeColor()` on every colour that reaches a style attribute, including the fullscreen/side-rail legend, the AMI legend, the measure menu and tables, the heating-fuel table and the end-use keys; it now also admits `var(--token)` and numeric `rgb/rgba`, which the page itself assigns; the labels next to those swatches are escaped |
| JS bundle at import time / packaging (round 1) | fixed in `c7b9b5fa` (package data) and `bf456be6` (lazy read) | GitHub shows it outdated; needs a reply and Resolve |
| cache key (round 1) | fixed in `2e1e263` and `athena_tables.py` (`invalidate_cache` after every export/crawl) | outdated; needs a reply and Resolve |
| committed `x.egg-info` (round 1) | removed in `c7b9b5fa`; nothing tracked, ignored by both `.gitignore`s | outdated; needs a reply and Resolve |

Why the round-1 threads keep reappearing: Copilot re-lists every thread that is still
unresolved on GitHub, and it never resolves its own. All three were fixed in code within
a day of being raised, and GitHub marks them outdated, but no reply was ever posted and
nobody clicked Resolve, so each new review summary carries them again. Posting the reply
and resolving is a manual step on the PR page.

### Copilot review 5 (2026-09-28): 8 open threads, 6 new, plus 1 previously missed

| thread | verdict | change |
|---|---|---|
| duplicate-hour probe keys on (building, hour) and omits the state, so a published `*_ts_by_state` table with one copy per state folder reads as duplicated and both timeseries legs are declined | real for published tables | key is (building, state, hour) when the dialect has a state column, (building, hour) otherwise; message reworded; `check_no_duplicate_hours` now defines `d` before its failure message (a latent NameError on that path); test added |
| AMI membership probe keeps only `bldg_id` for a published table, so a model with rows in two target states counts as covered wherever one copy exists | real for published tables | membership CTE at the timeseries grain: (building, state) and a join on both for published tables, building only for crawled; test added |
| previously missed: `queries/ami_<region>_timeseries.sql` written with the published default dialect while the executed query used the detected one | real (audit trail) | sidecar built with `ts_dial` |
| previously missed: README still described the `+N more` folder | real | README paragraph rewritten for `COMPARISON_NAME` |
| escape annual category labels in tooltips; upgrade names in the measure selector; run labels in the heating-fuel headers; Athena coverage values | valid, low | `esc()` at every remaining data-derived insertion: tooltips, verdict cards, ranked-gap row keys, AMI region and measure location options, measure selector, legend keys, badges, measure tables, heating-fuel headers, `absentTag` titles, and every Coverage-tab list from Athena |
| cache key, egg-info (round 1) | fixed long ago; unresolved on GitHub | reply and Resolve |

Why new findings keep appearing beside the old ones: Copilot's pass is not exhaustive and
reports a bounded number of findings against the code as it stands; each fix changes the
surrounding lines and the next pass reads them afresh. "Previously missed" is GitHub's own
label for a finding in code that did not change since the last review.

### Copilot review 6 (2026-09-28): 3 open threads, 1 new

One new thread: the heating-fuel tables interpolate the region name (`cat`, a census
division from the CSV or the literal "National") into innerHTML unescaped, in `hfMatrix`
and `hfSharesTable`. Valid, low; `esc()` at both sites. The other two open threads are
the round-1 cache-key and egg-info threads, still awaiting Resolve.

### Copilot review 7 (2026-09-28): 3 open threads, 1 new

One new thread: the local cache key lowercased the SQL, so two queries differing only in
the case of a string literal (`'CO'` vs `'co'`) shared a cache entry. Valid in principle,
never hit in practice (every query is generated with fixed literal case). The key now
keeps the SQL's case; test added. Consequence: every existing entry under
`~/.cache/comstock_results_dashboard` (1,059 files, 616 MB on this machine) has a new key,
so the next build of any dashboard re-runs its queries once. The other two open threads are
still the round-1 cache-key and egg-info threads, awaiting Resolve.

PR housekeeping still open: tick the change-type and author checkboxes, add the
`postprocessing` label, reply to the two reviewer comments and the Copilot cache thread,
re-request the Copilot review. Optional: license headers on the `*.py.template` files
(absent on main too).
