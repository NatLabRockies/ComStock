# 2026R1 all-measure run: measure failure progress log

Plan and findings: [PLAN.md](PLAN.md). Newest entry first.

## Resume here

1. The owner pushed and started `sdr_2026r1_measure_fixes_500_2` (2026-10-04) with everything up to the
   g-function fix (commit `24ceb77f`). Uncommitted since (suggested message at the end of the 2026-10-04
   late-night entry): the Package_3 hot water flow autosizing in the heat-pump boiler measure, the outdoor
   air fix in five measures, the energy recovery bypass control and wheel sizing in four measures, and the
   analysis files (`erv_bypass/`, `hr_vs_nohr_*`, `failure_summary_*`, rerun scripts and tables). Earlier uncommitted items: hydronic GSHP `:756`/`:848` fixes, ideal air loads naming, data-center skips in DOAS
   minisplits and advanced RTU controls, the g-function column fix in packaged and console GSHP, docs, rerun tables and scripts (`rerun_compare.py`,
   `rerun_applicability_tally.md`, `parse_osw.py`, `tally.py`, `compare_r3.py`, `extract_osw_rerun.sh`,
   `r3_applicability_by_system.csv`, `rerun_baseline_chars.csv`), the yml / sample / id-map copies.
2. Plan steps 1-11 are done. Open for owners: GSHP condenser-loop runaways (hydronic 24, console 2,
   packaged 8 in the rerun), Package_3 fan-coil heating-coil UA sizing (heat-pump boiler measure),
   GHEDesigner errors registered as NA (15 datapoints), the marginal unoccupied-AHU case 8613,
   console GSHP on mixed PTAC + unitary buildings. Parked: baseline 2537/7223, the 5552 WSHP loop.
3. If the owner wants a confirmation run after the hydronic and naming fixes: the same 500 sample
   yml with the new commit (hydronic 31 offices and ideal air loads 4 warehouses are the cases).
4. Pulled models and logs: `C:/tmp/mf2026r1`, `C:/tmp/mf2026r1_rerun` (local); `/scratch/ccaradon/mf2026r1*`
   and `/home/ccaradon/mf2026r1_rerun` (Kestrel, incl. `apply_upgrade_messages.tsv`); direct-run
   outputs `C:/tmp/typ_runs`; runner `C:/tmp/adhoc_typical.rb`; variants `C:/tmp/make_variant.rb`.

## Status by upgrade

| id | measure | class | diagnosis | S3 evidence | fix | tested | rerun |
|---|---|---|---|---|---|---|---|
| 14 | upgrade_hvac_doas_hp_minisplits | A | done; data-center skip added (uncommitted) | confirmed :339 (1,896 Fail) | `ad147d38` | prototype PSZ model, pulled PSZ-AC 1 and 195: Success; 6252 NA | rerun: Fail only on the parked baselines |
| 22 | upgrade_advanced_rtu_control | A | done; data-center skip added (uncommitted) | confirmed :391 (4,145 Fail) | `ad147d38` (fan curve now applied) | suite 3/3; pulled 1 and 195 Success, 6252 NA | rerun: Fail only on the parked baselines |
| 26 | upgrade_hvac_pump | A | done (was wrongly "all invalid") | confirmed :144 (2,512 Fail) | `ad147d38` | suite 11/11 | |
| 27 | upgrade_hvac_enable_ideal_air_loads | A | done | confirmed :86 (8,632 Fail) | `ad147d38` | suite 5/5 (EPW substituted) | |
| 29 | upgrade_hvac_packaged_gshp | A + D | done; g-function column fixed (uncommitted): all 56 g values were 0 | confirmed :956 (5,407), :866 (51), :874 (32), :941 (2) | `ad147d38` (port, fan curve, NA guard for mixed systems) | direct runs: PSZ-HP and PVAV Success with GHEDesigner; pulled mixed-system models 112 and 345 NA via the guard | |
| 31 | upgrade_hvac_chiller | A | done (was wrongly "all invalid") | confirmed :159 (1,161 Fail) | `ad147d38` | suite 3/3 | |
| 43 | upgrade_light_led | C | done | confirmed (8,632 Fail) | `ad147d38` (gem data lookup) | suite 8/8; pulled typical model 1: Success, 2,248 to 1,315 W | |
| 47 | upgrade_add_pvwatts (+ utility_bills) | D | done; PySAM needs Kestrel | 601 battery JSON, 16 PySAM | `ad147d38` (JSON spelling); PySAM open | | |
| 48, 54 | upgrade_env_exterior_wall_insulation | D | done; the simulation-side one is the baseline WSHP loop (Eric) | 3 nil construction, 1 simulation-side | `ad147d38` (guard) | pulled 195 model: Success, 12 tbd walls left unchanged | |
| 55, 56, 57 | Packages 2-4 (light_led) | C | done | confirmed | via 43 | | |
| 59, 63 | Package_6, Package_10 (gshp x3), missed by the summary | A + D | done | 5,577 and 5,572 Fail | via 29, 28; simulation-side open | | |
| 64 | Package_11 (gshp x3 + envelope + light_led) | A + C + D | done | 8,040 Fail | via 29, 28, 43, 48 | | |
| 28 | upgrade_hvac_hydronic_gshp | D | :443 fixed; rerun exposed :756 (nil chw_loop) and :848 (coils inside CRAH / fan coil units), both fixed uncommitted; 24 condenser-loop runaways remain (owner) | 69 + 32 | String guard, chw_loop reuse, CRAC skips, coil-loop guards | suite 7/7; pulled 1544, 1585, 2419, 1062 all Success | 7 of 61 targeted fixed; 31 at :756 now pass locally |
| 12, 13 | upgrade_hvac_vrf_hr_doas | sim | done: CRAC loops of data-center zones replaced by VRF terminals | 11 + 11 | CRAC / data-center skip (uncommitted) | pulled 3145 model Success, 6 CRAC loops kept; annual EnergyPlus run completes with 0 severe | |
| 30 | upgrade_hvac_console_gshp | sim | done: the measure's condenser loop runs away (too hot or too cold); g-function column fixed (uncommitted): all 56 g values were 0 | 4 | owner | | |
| 23 | upgrade_unoccupied_oa_controls | sim | done: numerical divergence at the first unoccupied night; optimum start + night cycle lead | 2 | owner | | |

## Log

### 2026-10-07, afternoon (run _5 evaluated)

- Run `_500_5` (`708e4ed3`): 2 upgrade-only failures, the owner items (unoccupied AHU, 10k id 8613; wall insulation,
  10k id 5552), exactly the estimate in `failure_progress_by_upgrade.csv`; every GSHP upgrade and package at 0, GSHP
  applicability unchanged. Overall 4,815 (10k, same 500) -> 274 -> 393 -> 65 -> 44 -> 2.
- Buildings in both runs, `_3` -> `_5`: site energy -0.3 to +0.1%; pumps -14 to -15% (packaged/console, code curve);
  hydronic heating +8% / cooling -7% (phantom source heat gone); unmet heating hours -5% packaged, about -1% elsewhere;
  drilling -5% (hydronic) to +3% (packaged). `_4` -> `_5`: packaged/console pumps -26/-31% (3 gpm/ton restored).

### 2026-10-07 (run _4 evaluated, GSHP round 4)

- Run `_500_4` scored (`failure_summary_aggregated_sdr_2026r1_measure_fixes_500_4.csv`): 44 upgrade-only failures;
  hydronic fixed (12 -> 1), 12 new climate zone 1A/7 failures from laminar borefield design flow. Buildings in both
  runs: site energy +0.1 to +0.4%, unmet heating hours flat to -5%, drilling -5 to +4%.
- Pulled the 12 failures and baselines (Slurm 18943397, `C:/tmp/mf2026r1_run4`); round 4 in PLAN.md.
- Owner had switched this worktree to another branch; GitHub Desktop stashed the notes, restored 2026-10-07.
- Owner committed round 4 as `708e4ed3` (3 measure files; the push reported a GitHub internal server error but the
  ref was updated) and launched `_500_5` on the same sample. Expected: 2 upgrade-only failures (the owner items),
  range 2-14 (`failure_progress_by_upgrade.csv`).

### 2026-10-06 (run _3 evaluated, GSHP round 3)

- Run `_500_3`: upgrade-only failures 4,815 (10k) -> 274 -> 393 -> 65; 63 GSHP, 2 owner items. Unmet heating hours
  vs `_2` (buildings in both): packaged -11%, console -1%, hydronic flat, packages -2 to -3%.
- Pulled the 18 failing buildings' `up00` baselines (Slurm 18932317, `C:/tmp/mf2026r1_run3_base`).
- Round 3 changes in PLAN.md ("GSHP round 3"). A research pass (three agents) confirmed the EnergyPlus EIR heating
  sign bug (fixed upstream in 26.1), the branch-pump route to a minimum source flow, and the 90.1 and manufacturer
  minimum-flow context; measure docs 89239/89131/89132 checked for each change.
- Found the local harness used GHEDesigner 1.0, which reports soil heat capacity 1000x too large; patched locally with
  the owner's OK, after which HEAD bldg 185 reproduced the Kestrel failure.
- Owner committed round 3 as `0d58ce51` (7 measure files) and launched `_500_4` on the same sample (2026-10-06,
  afternoon). Score it with `failure_summary_from_raw.py` and `run3_results_compare.py` (add `_500_4`), and check
  GSHP applicability against `_3` (GHEDesigner errors are logged as not applicable) and hydronic runtimes.

### 2026-10-05, afternoon (GSHP round 2)

- Owner committed round 1 (`0bc41637`) and asked for the sizing and table steps. Pulled the 13 run _2 GSHP
  buildings' `up00` baselines (Slurm 18918644, `C:/tmp/mf2026r1_run2_base`) and built an end-to-end harness
  (`gshp_fix/e2e/`): each GSHP measure on the baseline, committed vs working tree, then the annual run.
- Packaged and console: tables in ratio form and assigned before the sizing run, catalog capacity ratio, catalog
  water flow (3.6 / 4.0 K loop delta T), packaged ground pump intermittent. Rated-curve warnings 0, heat pump
  return water no longer 53-66 C, cooling no longer oversized 2.5-3.8x; totals -5 % to +6 %.
- Hydronic: W vs kW heat pump count bug, catalog source flows, extended Carrier tables, then two EnergyPlus issues
  found in testing: EIR ConstantFlow phantom source heat (fixed with VariableSpeedPumping) and the doubled EIR source
  flow registration in loop sizing (worked around by setting the loop, pump and HX design flows).
- Details and the results table: `gshp_fix/README.md`, "Round 2".

### 2026-10-05 (GSHP plant fixes applied)

- Owner approved the ground temperature and glycol fixes. Applied in the three GSHP measures with a third piece the
  tests showed is needed: glycol on the ground loop alone does not help, because the condenser loop stays water and
  the fluid-to-fluid HX trips at OpenStudio's 0 C limit. Now both loops are 20% propylene glycol and the HX limit is
  -6 C. Results and scripts: `gshp_fix/` (README, `summary.csv`); runs in `C:/tmp/gshp_fix`.
- Verification: console `test_pthp` 7/7 and hydronic `test_vav_air_cooled_chiller_with_gas_boiler_reheat` 7/7 with
  the expected fluids, HX limit and Kusuda temperature in the output models; packaged: the edited measure applied directly to the PSZ-HP test model with New York weather returns Success with the same settings, and its annual run completes with no severe errors. The packaged suite's
  PVAV test still errors before the plant code (needs a sizing run, as on 2026-10-02); the PTAC and PSZ-AC cases
  are not applicable to the packaged and hydronic measures.
- Found the source of the remaining cold-climate failure: OpenStudio's 11 K plant sizing default sizes the heat
  pump water flows at a third of the catalog's. Tested 5.6 K on three models; not applied (owner).
- Found that every packaged and console heat pump has heating capacity 0.263 x cooling (catalog 0.74), with water
  flows sized from the heating side; cooling-mode return water reaches 78 C and all unmet hours are heating hours.
  Condenser loop maxima without a flow filter are stale node values (loop idle about half the hours).
- Item 2 assessed with links (PLAN.md, "GSHP plant fixes applied and item 2 assessed").

### 2026-10-05 (run _2 evaluated)

- Run `_2` landed (S3 `.../tests/sdr_2026r1_measure_fixes_500_2/`, Kestrel commit `24ceb77f`). Failure summary
  `failure_summary_aggregated_sdr_2026r1_measure_fixes_500_2.csv`; comparison and GSHP root causes in PLAN.md
  ("Run sdr_2026r1_measure_fixes_500_2"). Pulled 13 GSHP datapoints (Slurm 18917407, `C:/tmp/mf2026r1_run2`);
  local EnergyPlus experiments in `C:/tmp/gshp_debug_10` and `C:/tmp/gshp_gtest` (`ratio_axes.py`,
  `make_fix_variants.py`).
- Verified: zeroed g-function completes, real g-function fails (same IDF); ground temperature model is the
  OpenStudio default everywhere; glycol is lost when the GHX is added; heat pump tables clamp. Ground
  temperature fix alone rescues the Texas warehouse; the 5A strip mall still fails with all three.
- No measure code changed for the GSHP findings at this point (fixes followed the same day, entry above).

### 2026-10-04, late night (energy recovery bypass)

- Owner: no climate limit exists in the measure (only restaurants are excluded); asked for bypass if it can
  be shown to work and to match real units, with plots. The divide-by-60 is in ComStock's measures (since
  the 2023 Release 2 public commit, copied into newer measures), not in comstock-typical, which converts
  air changes with 3600.
- Implemented `add_erv_bypass_control` (EMS, one program per wheel) in the heat pump RTU, Energy_Recovery,
  advanced RTU and VRF DOAS measures, plus wheel nominal flow sized to the design outdoor air in the first
  three. Tested with nine annual runs of the pulled retail 1 (Detroit 5A, Los Angeles 3B, Honolulu 1A x no
  recovery / recovery without bypass / with bypass) and the three other measures in Los Angeles; results,
  figures and assumptions in `erv_bypass/README.md`. Energy recovery now saves HVAC energy in all three
  climates (Los Angeles: -91 kWh without bypass, +114 kWh with); recovered energy within 1.3%.
- Economizer check (owner question): all four wheels keep Economizer Lockout on, so economizer air above the
  minimum passes the stopped wheel; at the HVAC system timestep (Detroit, `econ=true`) the wheel never ran above
  98% of its rated flow while outdoor air reached 4.5x it. Details in `erv_bypass/README.md`.
- Run `_2` contains none of today's later fixes; the next round should retest HPRTU+ER, Energy_Recovery,
  Package_5, advanced RTU with energy recovery and both VRF upgrades, plus Package_3.
- Suggested commit message for everything uncommitted:
  `Model energy recovery bypass, fix ERV fan power inputs, autosize terminal hot water flows`
  body: EMS bypass control for the wheel in four measures (EnergyPlus charged its fan power whenever outdoor
  air flowed); wheel sized to the design outdoor air; design outdoor air from the standards helper instead
  of a hand sum (ACH / 60, Maximum method ignored); heat-pump boiler measure autosizes fan coil, unit heater,
  induction and CV/PIU reheat hot water flows (Package_3); rerun scoring, failure summaries, heat recovery
  and applicability analyses, bypass test figures.

### 2026-10-04, night (Package_3 fix, heat recovery check)

- Owner started run `_2` with the pushed code, then asked for the Package_3 boiler fix and a check that
  the heat-recovery variant beats the one without.
- Package_3: the real cause was the fan coils' hard-sized Maximum Hot Water Flow Rate (baseline run at
  180 F); EnergyPlus derives the coil's design load from that flow times the loop delta T, which the
  post-envelope heating airflow cannot absorb at 140 F. The heat-pump boiler measure now autosizes the
  hot water flow of fan coils, unit heaters, induction units and CV / PIU / VAV heat-and-cool reheat
  terminals with hot water coils (it already did VAV reheat). Verified on the two pulled failures and by
  rebuilding Package_3 on 48's baseline with the fixed measure (`C:/tmp/typ_runs/pkg3_chain`). The
  delta T change tried earlier is not needed and was not applied.
- Heat recovery: HPRTU+ER (upgrade 3) did not beat HPRTU (upgrade 1) in the 10k run, 17.4% vs 17.6%.
  Two bugs in the outdoor air estimate behind the measure's wheel fan power (ACH / 60, Maximum method
  summed) inflate it 60x in healthcare and ~2x in California; fixed in the five measures with that hand
  sum by calling the openstudio-standards helper. Third cause, not fixed (owner decision): EnergyPlus
  charges the heat exchanger's nominal power in every hour with outdoor air, bypassed or not. Details
  and numbers in PLAN.md ("Heat recovery check"). Run `_2` does not contain these fixes.
- Suggested commit message for the new uncommitted changes:
  `Autosize terminal hot water flows in the HP boiler measure; fix the design outdoor air estimate for energy recovery fan power`
  body: heat-pump boiler measure autosizes fan coil, unit heater, induction and CV/PIU reheat hot water
  flows (Package_3 UA sizing failures); five measures use thermal_zone_get_outdoor_airflow_rate instead
  of a hand sum that divided air changes by 60 and ignored the Maximum method (healthcare 60x, California
  ~2x energy recovery fan power); heat recovery comparison scripts and results.

### 2026-10-04, afternoon (failure summaries from the raw parquet)

- Owner asked for `failure_summary_aggregated.csv` of the two runs. Neither run has a comstockpostproc
  output on this PC, the Kestrel clones or S3 (the 10k run's S3 aggregates were written on 2026-10-01/02
  from elsewhere; the rerun was never postprocessed). `failure_summary_from_raw.py` writes the same table
  (same columns and status logic as `ComStock`, minus its 1% failure-rate stop) from the raw parquet:
  `failure_summary_aggregated_sdr_2026r1_all_measure_10k.csv`, `failure_summary_aggregated_sdr_2026r1_measure_fixes_500.csv`.
- Postprocessing note: `ComStock(...)` raises when any upgrade fails more than `acceptable_failure_percentage`
  (default 0.01); the failure-enriched 500 sample exceeds it (hydronic 11%, packages 6/10/11 13-14%).

### 2026-10-04, evening (owner items assessed, g-function bug)

- Owner asked for a summary and hypotheses on the three open items and whether the applicability
  differences exist in the 10k run. Evidence and hypotheses are in PLAN.md ("Owner items: evidence
  and hypotheses"); applicability: no shift (the R3 reference values were county-replicated rows;
  `rerun_applicability_tally.md` section 5).
- New bug: `upgrade_hvac_packaged_gshp` and `upgrade_hvac_console_gshp` read GHEDesigner's
  g-function column by the hard-coded name `H:79.59`; GHEDesigner names it after the borehole
  length, so every g value was 0.0 (local packaged run on 6252: 0 of 56 nonzero; hydronic correct).
  Fixed (uncommitted) by taking the first `H:` header that is not `_bhw`. Retest: unit check on a fresh GHEDesigner output (hotel 1046, header `H:98.72`): the new lookup reads 57 of 57 nonzero g values, the old key reads nil (0.0). Console retest on 1046 stopped earlier at a local-only GHEDesigner quirk (NaN in `SimulationSummary.json`, which Ruby's JSON rejects; the three production summaries at hand have no NaN and no such failure appears in the 10,000 rerun datapoints). Packaged end-to-end retest on 6252: Success in 32 min, 3 PVAVs replaced, the 6 CRAC loops unchanged, and the ground heat exchanger now holds 56 of 56 nonzero g values (the same building before the fix: 0 of 56).
- Package_3 UA failure verified: the pulled 48 `in.idf` fails in sizing as-is and completes once the
  hot water loop's `Sizing:Plant` delta T is 5.6 K instead of 11.1 K (sizing-only EnergyPlus 25.1
  runs in `C:/tmp/typ_runs/pkg3_48`, `control` vs `dt556`). Fix belongs in the heat-pump boiler measure.
- Suggested commit message for everything uncommitted:
  `Fix GSHP g-function reads and hydronic loop guards, bound ideal air loads names, skip data centers in minisplits and advanced RTU; rerun analysis`
  body: packaged and console GSHP read the GHEDesigner g-function column by name (was 'H:79.59',
  so all g values were 0); hydronic GSHP reuses the existing chilled water loop, skips CRAC units and
  guards the coil conversions; ideal air loads names indexed; minisplits and advanced RTU skip
  data-center loops; rerun scoring, not-applicable tally and the R3 comparison (no applicability shift).

### 2026-10-04, later (applicability tally, CRAC audit)

- Step 10 done. Pulled every `out.osw` from the rerun tarballs (Slurm 18904795, 2 min, 10,500 files),
  parsed the ApplyUpgrade step (`parse_osw.py` -> `apply_upgrade_messages.tsv`, 10,000 datapoints,
  kept in `/home/ccaradon/mf2026r1_rerun`), tallied each measure's own not-applicable message
  (`tally.py`) and compared applicability by `hvac_system_type` and floor-area bin with the published
  2025 R3 metadata via Athena (`compare_r3.py`). Write-up: `rerun_applicability_tally.md`.
  Result: no shift. The R3 reference percentages were county-replicated row fractions of the
  published table (7.7M rows, 91,464 distinct buildings); by distinct building R3 and the 10k run
  have the same HVAC mix and agree within 3 points on every measure (minisplits 19% vs 22%, advanced
  RTU 46% vs 48%, pumps 27% vs 29%), the 500 sample within sampling noise. Per system type and size
  bin the typical and prototype models
  agree. Second-order: VRF zoning tests, minisplits partial applicability at 20-50k sf (35% R3, 7-16%
  now), GHEDesigner errors registered as NA (9 hydronic, 5 console, 1 packaged), console GSHP NA on
  mixed PTAC/residential + unitary buildings.
- Step 11 done. The fork's CRAC loops are OA system + DX coil + humidifier + constant-volume fan with no
  unitary system, so advanced RTU controls never selected them and minisplits skipped them by the
  'datacenter' name only; both measures now skip CRAC/CRAH loops and data-center zones (fork helper,
  which also covers computer/server room names). Regression: minisplits and advanced RTU Success on
  pulled PSZ-AC 1 (retail) and 195 (warehouse), NA unchanged on 6252/3145. Console GSHP left alone
  (see PLAN.md step 11).
- Hydronic GSHP: 1544 Success (28 min, 111 heat pump water heaters), 1585, 2419, 1062 Success with
  the `:756` and `:848` fixes (details in the entry below).
- Suggested commit message for everything uncommitted:
  `Fix hydronic GSHP loop reuse and coil guards, bound ideal air loads names, skip data centers in minisplits and advanced RTU; applicability tally vs R3`
  body: hydronic GSHP reuses the existing chilled water loop, skips CRAC units and guards the unitary
  and chilled-water coil conversions (31 offices); ideal air loads names are indexed so EnergyPlus
  node names stay unique (4 warehouses); DOAS minisplits and advanced RTU controls skip data-center
  CRAC/CRAH loops; rerun scoring and the applicability analysis (all shifts vs R3 are sample mix).

### 2026-10-04 (rerun landed)

- `sdr_2026r1_measure_fixes_500` finished and uploaded (baseline + 20 upgrades, 500 buildings each).
  Tables: `rerun_all_upgrades_scan.md` (per-upgrade status) and `rerun_compare.md` (targeted
  buildings scored against their original failure, applicability on the 325 random buildings).
- Fixed, failing only on the two parked baseline buildings: VRF (both variants), DOAS minisplits,
  advanced RTU controls, pump, chiller, LED, PV with battery (PySAM), Package_2, Package_4. The
  unoccupied-AHU building with CRAC loops (4084) now runs; 8613 still diverges (the marginal case).
  Wall insulation: the three nil-construction buildings run; 5552 (WSHP loop, parked) still fails.
  LED applicability on the random buildings is 65%, the R3 value.
- Applicability on the 325 random buildings, first real numbers for the typical models (R3 in
  brackets): DOAS minisplits 14% (51), advanced RTU 42% (66), VRF 44% (63), pumps 29% (11), ideal
  air loads 100% (100), hydronic GSHP 11% (0.7), packaged GSHP 57% (73), console GSHP 19% (25),
  chiller 16% (0.7), LED 65% (65), PV with battery 100% (100), wall insulation 98% (99.5),
  Package_2/4 84% (86), Package_3 99% (100), Package_6/10/11 86-87% (98-99). The tally of
  not-applicable messages (step 10) explains these.
- New crash exposed by the line-443 fix: hydronic GSHP measure.rb:756
  `chw_loop.addDemandBranchForComponent` on nil (31 buildings, all large and medium offices with
  chillers): the measure only assigned `chw_loop` when it created a chilled-water loop, and its
  unitary-system conversion assumed PSZ-style units. Fixed (uncommitted): reuse the existing
  'Chilled Water Loop', skip CRAC/data-center units, guard the coil assumptions; regression on
  pulled 2419 and 1062 and a test on pulled 1544 (rerun id 47) pending.
- New simulation-side failures (buildings that never simulated before, so not regressions): ideal
  air loads 4 (warehouses on PVAV/PSZ), packaged GSHP 8 (PSZ/PVAV retail, grocery, strip mall,
  warehouse, office), Package_3 7 (all DOAS fan coil chiller + boiler; Package_2 without the
  envelope upgrades has none). Known: hydronic 24 and console 2 condenser-loop runaways, console
  sizing run 1. Pulled two datapoints of each new cluster from the rerun's tarballs (Slurm job
  18904771, local copy `C:/tmp/mf2026r1_rerun`, triage in `C:/tmp/kestrel_jobs/triage_rerun.txt`):
  - ideal air loads: `ZoneHVAC:IdealLoadsAirSystem ... duplicate node names found`. The gem names
    the object `<zone> Ideal Loads Air System`; the typical warehouse zone names push that past
    EnergyPlus's 100-character limit, and the node names built from it truncate to the same string.
    Fixed (uncommitted): the measure renames each object `Ideal Loads <n> <zone name>[0,55]`, index
    first so uniqueness survives truncation (a first attempt with the index at the end still
    collided). Test on the pulled warehouse 1652 (rerun id 49): measure Success (30 ideal loads objects, longest name 81 characters) and the annual EnergyPlus run completes with 0 severe errors, where the production run failed before simulation.
  - packaged GSHP: `Plant temperatures are getting far too cold` on the measure's condenser loop,
    the same runaway as hydronic and console; now fatal for 8 of 228 applicable (owner item).
  - Package_3: `Autosizing of heating coil UA failed for Coil:Heating:Water "... FCU HEATING COIL"`
    on corridor fan-coil coils: the envelope upgrades plus the heat-pump boiler's lower hot water
    setpoint (140 F, autosized coils) leave almost no design heating load, and EnergyPlus cannot
    size the UA. Owner item for the heat-pump boiler measure (a minimum coil capacity or keeping
    the setpoint for fan-coil systems); Package_2 without the envelope upgrades has none.
  - 8613 diverges exactly as before (marginal case); 48/1585's baseline sizing run logs non-fatal
    CRAH controller severes.
- Hydronic `:756` fix: regression on pulled 2419 (Success, 22 heat pump water heaters) and 1062
  (Success); test on the pulled offices 1544 and 1585 (rerun ids 47, 48): after the chw_loop fix both stopped at measure.rb:848, where a hot-water coil is added behind every CoilCoolingWater in the model, including the coils inside the fork's data-center CRAH units and fan-coil units; that loop now skips coils inside zone equipment or coil systems, coils on CRAC/CRAH or data-center loops, and coils without a node outlet. With both fixes: 1544 Success (28 min, 111 heat pump water heaters), 1585 Success (3 min); regressions on 2419 and 1062 unchanged.

### 2026-10-03, night (rerun submitted)

- Owner committed all fixes as `a5822969` and pushed; checked the branch out at
  `/kfs2/projects/eusscom/repos/comstock_chris_2/ComStock`.
- Rerun yml, 500-building precomputed sample (175 targeted + 325 random, renumbered) and id map
  placed next to the original yml in `ymls/sdr_fy26/0_production_runs_2026R1/all_measure_10k/`.
  A line-ending cleanup run through the PowerShell-to-ssh path had stripped a trailing "r" from
  lines (`vrf_hr` became `vrf_h`, caught by buildstockbatch validation); the files were re-uploaded
  byte for byte and verified by checksum. Submitted by the owner; sampling was running at 17:00.
- Wrote `rerun_compare.py` for the post-run scoring.

### 2026-10-03, evening (comments trimmed, local-only testing)

- Owner: keep inline comments to one or two lines; document the state; continue with testing that
  needs no Kestrel run (Kestrel storage is full; the owner is deleting old runs under eusscom).
- Trimmed every comment block I added (advanced RTU, packaged GSHP, VRF, hydronic, wall insulation,
  LED) to two lines; all files compile under the OS 3.10.0 CLI.
- `origin/spacetype_refactor` gained one commit since the branch was cut (`5e9895f1`, FSR kitchen
  SWH override in create_custom_building_from_spec); no overlap with these changes, same
  comstock-typical ref. Merging it is the owner's call.
- Batch of measure runs on the pulled typical models (`C:/tmp/typ_runs/batch2`), all with the ported
  code: DOAS minisplits Success on 1, 195, 345 (one applicable loop each); advanced RTU controls
  (add_econo=true, add_dcv=true as in the run) Success on 1 and 195, NA on the PVAV office 6252;
  pump Success on 2419 (3 pumps updated) and 1062; chiller Success on 2419 (water-cooled chiller
  found), NA on 3145; LED gen5 Success on 2419 and 6252.
- CRAC audit on 3145 (six CRAC loops, summarised before and after each measure): DCV and heat pump
  RTU leave them alone (DCV reports the six as ineligible space types; HP RTU finds no applicable
  loops). Economizer added a DifferentialDryBulb economizer to all six (the fork already decides CRAC
  economizers by climate zone); energy recovery added an ERV to all six; unoccupied OA controls put
  all six on an occupancy availability schedule with a night-cycle manager. Building 4084, one of
  the two unoccupied-AHU divergences, has six CRAC loops and data-center zones (8613 has none), so
  a night-cycled data center is the likely trigger there.
- Added a CRAC/data-center skip to economizer, energy recovery (counted as an inapplicable space
  type) and unoccupied OA controls, the same test as the VRF and packaged GSHP measures (loop name
  CRAC/CRAH or the fork's `thermal_zone_data_center?`). Verification on 3145 and the non-CRAC
  school 2419: verified (`C:/tmp/typ_runs/batch3`): on 3145 the economizer measure is NA (its three PVAV loops already had economizers, the six CRACs are skipped), energy recovery adds 3 ERVs to the PVAV loops and counts the six CRACs as inapplicable, unoccupied OA controls leave the CRAC availability untouched; on the school 2419 (no CRACs) all three behave as before (ERV added, controls applied, economizer NA). Annual EnergyPlus run of the GSHP-upgraded 6252 model:
  completes the full year with 0 severe errors (31 min) but 24.4 million warnings; the most frequent one-line type is `161 CheckSimpleWAHPRatedCurvesOutputs: Coil:Cooling:WaterToAirHeatPump:EquationFit=X` (see `C:/tmp/typ_runs/pgshp_6252_sim/top_warnings.txt` and the recurring-error summary in its eplusout.err), and the recurring warning is `Plant loop falling below lower temperature limit, PlantLoop="CONDENSER LOOP"`: the same ground loop that goes fatal in the hydronic and console cases, so the condenser-loop item for the GSHP owners covers all three measures.

### 2026-10-03, afternoon (owner directions)

- Owner: skip CRAC systems and proceed rather than dropping the building; validate the
  unoccupied AHU failure; explain the PySAM failure; no buildstockbatch runs by me (yml for
  approval); baseline failures parked.
- Packaged GSHP: data-center zones are determined before the equipment pass, kept on their CRAC
  with their equipment, left out of the loop inventory and skipped in the zone loop; the NA guard
  remains for DOAS + WSHP and PTAC/PTHP buildings with a stray unit. Pulled 112 and 345: still NA.
  Pulled 6252 (large office, 6 CRAC loops): Success (49 min, mostly the measure's annual ground-loop simulation): 3 PVAVs replaced with packaged GSHPs serving 54 zones, GHEDesigner ran, all 6 CRAC loops kept. Prototype PSZ-HP regression:
  Success, 18 RTUs replaced (657 s).
- PySAM: reproduced with NREL-PySAM 4.2.0. `calc_elec_bill.py` raised `ZeroDivisionError` on the
  average-rate line for the all-zero purchase profile; the bare `except` hid it; the measure then
  failed the datapoint. Guarded the division and surfaced the exception text; the zero profile now
  bills $7,267 of fixed charges on rate 6452/5a5e50dd, the 1 kWh control is unchanged.
- Unoccupied AHU: pulled the run's `G0600850.epw`; local annual run of the post-measure 4084 model
  as-is: completes the full year with 0 severe errors (same EnergyPlus 25.1.0-1c11a3d85f build as the run, 4 min), and so does the production `in.idf` itself run straight through the local EnergyPlus; the production and local IDFs differ only in meter and output-variable objects; with the 12 optimum-start managers removed: also completes with 0 severe errors, so the hypothesis cannot be tested locally; the divergence is a marginal numerical instability (2 of 3,811 applicable buildings) that shows on the Linux build and not on Windows with identical inputs.
- Suggested commit message for all uncommitted changes:
  `Keep CRAC systems in the VRF and packaged GSHP measures, fix the hydronic flow-method guard and the zero-purchase utility bill`
  with a body naming: VRF 11 large offices per upgrade; packaged GSHP data-center zones skipped
  instead of the building; hydronic String return type (69 buildings); utility bills
  ZeroDivisionError on PV + battery buildings (16); typical-model verification runs.

### 2026-10-03, later (datapoints read, two more fixes)

- The first extraction job found nothing: the job files are 0-based with `null` for baseline. Job
  18891509 pulled all 26 datapoints (1.7 GB, bundle 259 MB) to `C:/tmp/mf2026r1`.
- Findings per cluster are in PLAN.md "Smaller clusters" (VRF: CRAC loops of data-center zones;
  hydronic `:443`: String return type; GSHP simulation-side: the measures' condenser loop;
  unoccupied AHU: divergence with optimum start + night cycle; 2537: PTHP zero-load sizing; 7223:
  floor-area check; 5552: baseline WSHP loop; PySAM 47/148: all-zero net hourly profile with PV + battery).
- Fixes applied, uncommitted: VRF measure skips CRAC/CRAH loops and loops serving data-center
  zones (fork helper `thermal_zone_data_center?`, name fallback); hydronic guard rewritten to accept
  the String return type (the `ad147d38` version raised on the typical model).
- Typical-model verification with `C:/tmp/adhoc_typical.rb` (loads the pulled `in.osm`, sets a
  local EPW, runs the measure, no simulation): LED on 1 Success; wall insulation on 195 Success;
  packaged GSHP on 112 and 345 NA with the zone list; hydronic on 1062 Success with GHEDesigner;
  VRF on 3145 Success with 51 zones on VRF and 6 CRAC loops kept; packaged GSHP on 6252 NA in 2 s
  naming its six data-center zones (the CRAC loops are single-zone but not unitary, the `:941`
  case). The VRF-upgraded 3145 model then completed a full annual EnergyPlus run locally with
  0 severe errors (1 min 48 s), where production diverged in the data-center zone.
- Suggested commit message for the uncommitted changes:
  `Skip CRAC loops in the VRF measure and accept the String flow-method API in the hydronic GSHP`
  with a body naming the 11 large offices per VRF upgrade and the 69 hydronic failures, the
  typical-model runs above, and the docs update.

### 2026-10-03 (Kestrel back: pulling the datapoints)

- Run directory on Kestrel: `/kfs2/projects/eusscom/runs/0_production_runs_2026R1/tests/sdr_2026r1_all_measure_10k`.
  The per-job assignment files `job001.json` .. `job080.json` (`batch: [[building_id, upgrade], ...]`)
  map every datapoint to its tarball `results/simulation_output/simulations_job<N>.tar.gz` (80 files,
  ~70 GB each, members `./upNN/bldgNNNNNNN/...` with `openstudio_output.log`, `run/data_point.zip`,
  `run/data_point_out.json` and the measure sizing-run folders). Copied the 80 json files to
  `C:/tmp/kestrel_jobs/` and built `targets.txt` (26 datapoints in 22 tarballs).
- Targets: VRF 12/3145 and 12/3701; unoccupied AHU 23/4084 and 23/8613; hydronic 28/2419, 28/2552
  (simulation-side) and 28/1062 (:443); packaged GSHP 29/112 (:866), 29/345 (:874), 29/6252 (:941);
  console 30/7749, 30/2692 (sizing run), 30/1046 (simulation-side); PV+battery 47/148 (PySAM);
  wall insulation 48/5552 (simulation-side) and 48/195 (:215); baseline failures 00/2537 and 00/7223;
  baseline OSMs for local reruns of the fixed measures: 00/1, 00/112, 00/345, 00/195, 00/1062,
  00/3145, 00/2419, 00/6252.
- The job files are 0-based with `null` for baseline (`[5354, 14]` is `up15`); the first Slurm job
  (18890166) used the number as the directory suffix and extracted nothing. Slurm job 18891509
  (`/home/ccaradon/mf2026r1/extract_targets.sh`, eusscom / debug, 1 node, 11 parallel tar streams,
  about 8 min per tarball) extracts those directories to `/scratch/ccaradon/mf2026r1`, unzips
  `data_point.zip`, drops sql/eso/audit files and bundles the rest as
  `/home/ccaradon/mf2026r1/mf2026r1_extract.tar.gz` for scp. Local copy goes to `C:/tmp/mf2026r1`.

### 2026-10-02, evening (changes applied)

- Owner asked for the confident changes now, an assessment of the hydronic GHP, VRF, console GHP,
  wall insulation and unoccupied AHU failures, and one branch. Deleted the empty auto-created
  `claude/2025r3-measure-failures-cc4276` (it sat at main's tip with no commits and was never
  pushed); the worktree stays on `ccaradon/spacetype_refactor_measure_failures`.
- Commit `ad147d38` (pushed): class A ports at all seven call sites; fan curve applied as
  `'Single Zone VAV'` with the parity alternative in a comment; LED measure reads
  `lighting_space_type` plus the gem's json (option B); hydronic GSHP `.get` guard; wall insulation
  nil-construction guard; packaged GSHP not-applicable guard for zones it does not inventory;
  `RetailStripmall` battery row; meta_measure logs exception class and message. Every edited Ruby
  file compiles under the OS 3.10.0 CLI.
- `s3_failed_building_characteristics.py` joined the failing ids to buildstock.csv: the packaged
  GSHP :866/:874 buildings are DOAS + WSHP, residential furnace, PTHP and PTAC buildings (mixed with
  one PSZ-type loop in the typical models, not-applicable in R3); the VRF failures are 11 large
  offices (same in both variants); the hydronic simulation-side failures are schools and hospitals
  on chiller + boiler systems; the wall insulation nil constructions are three 2016-2017 CEC
  warehouses. Details in PLAN.md "Smaller clusters".
- Local tests with the bundle at `C:/tmp/csgems` (system Ruby 3.2.2, bundler 2.4.10). Two test-suite
  quirks, unrelated to the fixes: the suites must be invoked with an ABSOLUTE test path (they
  `Dir.chdir` into their run directory and keep relative model paths), and the ideal-air-loads suite
  names two weather files that are not in `resources/tests/weather` (run with a temp copy pointing at
  the New York TMY3 file, not committed). Results on the prototype test models:
  - upgrade_hvac_pump: 11 runs, 286 assertions, pass (pump_get_brake_horsepower port).
  - upgrade_light_led: 8 runs, 23 assertions, pass (CSV path; the gem data file resolves and loads).
  - upgrade_hvac_enable_ideal_air_loads: 5 runs, 280 assertions, pass with the EPW substitution (remove_hvac port).
  - upgrade_advanced_rtu_control: 3 runs, 25 assertions, pass (fan curve port with 'Single Zone VAV').
  - upgrade_hvac_chiller: 3 runs, 120 assertions, pass with an absolute path (pump_get_brake_horsepower port, simulation test included).
  - upgrade_env_exterior_wall_insulation: its suite segfaults in its own weather-file setup on this
    machine regardless of the fix; verified instead with a direct run on 370_small_office_psz_gas_2A:
    Success on the stock model, and Success on a copy where one wall carries a cloned 'Metal Building'
    construction (the failing warehouses' situation): that wall is left unchanged with the info
    message and insulation is applied to the other 11 walls, where the old code raised.
  - upgrade_hvac_doas_hp_minisplits: its suite is stale (expects one argument, the measure has three,
    and its example model fails on an unrelated line); verified with a direct run on
    370_small_office_psz_gas_2A: Success, all 9 PSZ loops rebuilt as DOAS loops with the ported DX
    coil, electric coil and constant-volume fan creators.
  - upgrade_hvac_hydronic_gshp and upgrade_hvac_packaged_gshp: suites need a `ghedesigner` CLI;
    installed GHEDesigner 1.0 in a throwaway venv at `C:/tmp/ghe` (needs numpy<2, scipy<1.14,
    pandas<2.3), run with `PATH=/c/tmp/ghe/Scripts:$PATH`. Hydronic: 7 runs, 40 assertions, pass
    (GHEDesigner succeeded in all three tests that reach it). Packaged: the suite runs an annual
    simulation after every test and exceeded the 2 h background window twice (two applicable tests
    had passed through the measure and their simulations, no failures logged), so it was finished
    with direct runs instead: PSZ-HP_gthp Success (18 RTUs replaced, GHEDesigner ran);
    PVAV_gas_heat_electric_reheat Success after a sizing run (2 PVAVs replaced, GHEDesigner ran,
    all 30 new VAV fans carry the 'Single Zone VAV' coefficients a=0.0278); the mixed-system case
    (one zone moved from its PSZ-HP loop to a PTAC, the production situation behind :874) returns
    NA in 1 s with the guard's message naming the zone, where production crashed. Note the guard runs
    after the inventory has already removed the PSZ loop components; harmless because an Invalid
    datapoint is never simulated (the measure's own GHEDesigner NA at :1315 behaves the same), but a
    pre-inventory check would be cleaner (follow-up, PLAN.md class D). Side observation: the stock PSZ-HP prototype model's 17 VAV fans already
    carry the 'Single Zone VAV' coefficients, so applying them in the upgrade matches the baseline.
  None of the suites covers the typical-model code paths (lighting_space_type lookup, mixed-system
  NA guard, blank heating flow method); those wait for the Kestrel OSMs.

### 2026-10-02, afternoon (SSO refreshed)

- Ran `s3_failure_summary.py` and `s3_all_upgrades_scan.py` against the run prefix. The run has
  8,634 buildings (not 10k) and 65 upgrades; baseline has 2 failures (2537, 7223).
- Backtraces confirm every class A line number. The parquet never holds the exception message
  because `meta_measure.rb:248` logs only the backtrace (fixed in `ad147d38`).
- Upgrades 26 and 31 are not all-invalid: 2,514 and 1,163 buildings fail at the removed
  `pump_brake_horsepower` call, the rest are Invalid. Class B (applicability mystery) is closed.
- The full scan found two more upgrades failing the same way that were not in the summary:
  Package_6 (59) and Package_10 (63), 5,577 and 5,572 Fail each, dominated by packaged_gshp:956.
- New class D list (PLAN.md section 2): packaged_gshp zone_data nil zones (:866/:874/:941),
  hydronic_gshp:443 empty optional, wall_insulation:215 nil construction, console GSHP sizing run,
  PV battery JSON spelling (`RetailStripMall` vs `RetailStripmall`, 601 strip malls), PySAM bill
  failures (16), and simulation-side fails with no measure error (VRF 11 each, Hydronic_GHP 32,
  Package_6 36, Package_10 30, others 1-2). Kestrel is down, so the OSM/log items are marked and
  parked, per the owner.
- Applicability shifts vs R3 to re-check after the port: DOAS minisplits 51% to 22%, Advanced
  RTU 66% to 48%, pumps 11% to 29%.
- Fixed two script bugs along the way (duplicate parquet read that doubled counts; subset runs
  overwriting the full scan table).

### 2026-10-02, morning

- Branch `ccaradon/spacetype_refactor_measure_failures` created from `origin/spacetype_refactor`
  @ `0e4c8084` with `--no-track` (push target is its own name, never main).
- S3 read blocked at first: `UnauthorizedSSOTokenError` from boto3 with the default (resbldg)
  profile. Wrote `s3_failure_summary.py` to run once the session was refreshed.
- Mapped all eleven failing ids to measures with the 2025R3 crosswalk from
  `ccaradon/measure-release-comparison` (the 2026R1 yml is the R3 upgrade block). Upgrade 26
  "Pmp" is `upgrade_hvac_pump` (published "VFD Pumps").
- Root causes established from code (details in PLAN.md):
  - A: openstudio-standards 0.8.5 removed the `Standard` instance helpers
    `create_coil_cooling_dx_single_speed`, `create_coil_heating_electric`,
    `create_fan_constant_volume`, `remove_hvac`, `fan_variable_volume_set_control_type`,
    `pump_brake_horsepower`. Six upgrade measures still call them (seven call sites). Broken on
    `main` since the 2026-02-26 gem bump, not caused by the fork. Fork has the
    `OpenstudioStandards::HVAC` replacements.
  - C: `upgrade_light_led` needs `prototype_lighting_space_type`, which only the dropped
    `prototype_space_type_assignment` measure set; the fork stamps `lighting_space_type`
    instead and already contains the same lighting algorithm as a module function.
- Audited every `std.`/`standard.` call in all `upgrade_*` measures against the fork; no other
  missing instance methods beyond the six above.
- Found that `'Single Zone VAV Fan '` never matched a valid control type in 0.8.3 either
  (warning, no change), so the port is a behavior decision for 22 and 29.
