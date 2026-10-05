# upgrade_hvac_add_heat_pump_rtu — working notes

**Measure:** `resources/measures/upgrade_hvac_add_heat_pump_rtu/measure.rb`
**This branch:** `jkim/dual_fuel_rtus_notes` (off `origin/ccaradon/dual_fuel_rtus` @ `b3e9b751`)
**Compared against:** `origin/main` (merge base `f25ac375`; main has no changes to measure.rb since)

**Purpose of this branch:** branched off `dual_fuel_rtus` to capture the latest changes to this
measure and to serve as the starting point for further work.

Running log of changes, thoughts and brainstorming for this measure. Newest entries go at the
bottom of each section. Kept here rather than in the measure folder to avoid growing it.

## 1. Scope: measure scenarios

All four scenarios use the same measure (`resources/measures/upgrade_hvac_add_heat_pump_rtu`).
Their configurations differ, but changes are made consistently so all four go through the same
measure workflow; scenario differences should come from arguments and performance data only.
Update this table as items are confirmed.

Items marked **TBC** are not confirmed yet. The options lookup column names the row in
`resources/options_lookup.tsv` (same in `national/housing_characteristics/options_lookup.tsv`) that
runs each scenario.

### 1.1 Configuration

| Measure scenario | Options lookup option | Performance category | Compressor lockout temp | Backup heating source | Oversizing factor | Heating sizing temp | Gas heating control strategy |
|---|---|---|---|---|---|---|---|
| Dual Fuel RTU with standard performance | `dual_fuel_std_perf_lockout_30F` | Standard performance (`two_speed_standard_eff`) | 30 F | Gas | **TBC:** no oversizing considered | N/A if no oversizing | Simultaneous |
| Cold Climate Heat Pump Challenge: challenge specification dual fuel RTU | **None yet.** Proposed: `dual_fuel_cchpc_spec_lockout_neg10F`. Existing `cchpc_2027_spec` uses electric backup | Challenge specification performance (`cchpc_2027_spec`) | -10 F | Gas | **TBC:** no oversizing considered | N/A if no oversizing | Simultaneous |
| Cold Climate Heat Pump Challenge: typical dual fuel RTU **or** HP RTU | **None yet.** Needs a new performance category first | **TBC:** typical market performance (new performance curve) | -10 F | **TBC** | **TBC:** no oversizing considered | N/A if no oversizing | Simultaneous |
| IMPACT: Dual Fuel | **None yet.** Needs control strategy support first | **TBC** | **TBC** | Gas | **TBC** | **TBC** | Simultaneous and sequential |

### 1.2 Status

| Measure scenario | Measure doc | 10K run | Full run |
|---|---|---|---|
| Dual Fuel RTU with standard performance | Created | Done | Not started |
| CCHPC: challenge specification dual fuel RTU | Not started | Not started | Not started |
| CCHPC: typical dual fuel RTU or HP RTU | Created | Not started | Not started |
| IMPACT: Dual Fuel | Not started | Not started | Not started |

### 1.3 To confirm

- [ ] Oversizing: confirm "no oversizing" for the standard and both CCHPC scenarios.
- [ ] CCHPC typical: performance curve for typical market equipment (new curve needed).
- [ ] CCHPC typical: backup heating source (and whether this is dual fuel or HP RTU).
- [ ] IMPACT: performance category, compressor lockout temp, oversizing factor, heating sizing temp.
- [ ] Gas heating control: how the measure will support both simultaneous and sequential (IMPACT).
      See 1.4.
- [ ] Performance category for the `dual_fuel_std_perf_lockout_*` options: they use
      `two_speed_standard_eff` for now. #446 also added a `carrier_48qe_dualfuel` category that we
      haven't confirmed we want. See 1.5.

### 1.4 Reporting needed for scenario 4 (IMPACT: Dual Fuel)

IMPACT compares two gas heating control strategies for a dual fuel RTU:
1. **Simultaneous:** DX heating and the gas coil run together.
2. **Sequential:** gas coil only, with the DX compressor locked out.

To quantify the difference, we need the DX heating load delivered *while the gas coil is also on*.
That is the load that shifts from DX to gas under sequential control. Existing outputs don't
separate it out, so it has to be reported explicitly.

**Approach: report-side, no EMS.** Closed PR [#446](https://github.com/NatLabRockies/ComStock/pull/446)
(`jk/duelfuelrtu`) got this value from an EMS variable set by an EMS-controlled two-stage gas
backup coil in the HPRTU measure. We are **not** porting that EMS change. When it was tested, the
two-stage EMS gas coil gave results close to the measure's existing non-EMS gas coil, so the
extra complexity isn't justified.

Instead, `comstock_sensitivity_reports` calculates it from standard output variables:
- **Why it works without EMS:** the HPRTU measure puts the DX coil in an
  `AirLoopHVACUnitarySystem` as the heating coil and the gas coil as the supplemental coil.
  EnergyPlus fires the supplemental coil when the DX coil can't meet the load, or when the
  compressor is locked out. So the current model already runs as "simultaneous" above the lockout.
- **Which systems:** `hybrid_heating_coil_pairs(model)` finds unitary systems with a DX heating coil
  (single, multi or variable speed) and a `CoilHeatingGas` or `CoilHeatingGasMultiStage`
  supplemental coil.
- **Output requests:** `Heating Coil Heating Energy` at `Timestep` frequency, keyed to just those
  coils to keep output size down.
- **Calculation:** for each pair, sum the DX coil heating energy over the zone timesteps where the
  gas coil heating energy is above 0. The total is registered as
  `com_report_hvac_dx_heating_load_during_hybrid_heating_j`, which `comstock_column_definitions.csv`
  maps to `out.params.dx_heating_load_during_hybrid_heating`. This is the same definition as #446,
  where the EMS variable equals the DX load while gas stage 1 is on.
- **Missing data:** if either series is missing, the system is skipped with a warning (not an error).

**Models with many DX + gas coil pairs:** each pair is calculated on its own, then the results are added.

```text
total = 0
for each unitary system with a DX heating coil + gas supplemental coil:
  dx  = that system's DX coil heating energy, one value per zone timestep (J)
  gas = that system's gas coil heating energy, one value per zone timestep (J)
  for each timestep i:
    if gas[i] > 0: total += dx[i]
```

- **Pairs stay separate.** A DX coil's energy counts only when its own system's gas coil is heating.
  If RTU A runs DX with gas while RTU B runs DX alone, only A's DX energy is added. Another
  system's gas coil never triggers a count.
- **Timesteps line up within a pair.** Both series come from the same simulation at the same
  reporting frequency, so `dx[i]` and `gas[i]` cover the same period. The code also checks that
  the two series have the same length.
- **Adding across pairs is a plain sum.** Each value is already energy in J, so no capacity or
  airflow weighting is needed. A building with 10 RTUs gets the sum of 10 independent per-RTU totals.
- **A pair with missing data is skipped, and the rest still count.** The registered total then
  covers only the pairs that could be read, so a warning means the total is partial.
- **Cost grows with the number of pairs.** Each pair adds two timestep output variables to the SQL
  file. With 4 timesteps per hour, that's 35,040 values per variable. That should be fine even for
  buildings with dozens of RTUs, but it's the main cost of this approach.

The result is one building-level number: the DX heat delivered while that same unit's gas coil
was also on, summed over all dual fuel units.

**Caveats:**
- **Resolution:** we use zone timestep rather than hourly. With hourly averages, any hour with a
  few minutes of gas would count all of that hour's DX heat. A zone timestep where the gas coil
  fires during only some HVAC system sub-timesteps still counts that timestep's full DX energy.
  This error should be small. The EMS approach in #446 worked at the system timestep and had no
  such error.
- **Below the lockout,** the DX coil delivers 0, so those timesteps add nothing. That is correct:
  the DX heat that shifts to gas under sequential control only happens above the lockout.
- **The `measure.xml` checksum** for `comstock_sensitivity_reports` was not updated. Regenerate it
  with the measure updater.
- **Not yet verified** in a simulation (helper checked on a small test model only).

- [ ] Run a dual fuel model end to end and sanity-check the value against the DX and gas coil totals.
- [ ] Decide how the measure switches between simultaneous and sequential control (a new argument?).

### 1.5 Dual fuel options (adapted from #446)

These options model a **dual fuel RTU**: the backup heat is always natural gas, whatever the
building's original heating fuel. They sweep the compressor lockout temperature.

Added to both `resources/options_lookup.tsv` and `national/housing_characteristics/options_lookup.tsv`,
after `orig_fuel_backup_std_perf_gas_lockout_0F`:

| Option | `backup_ht_fuel_scheme` | elec backup lockout | gas backup lockout | `hprtu_scenario` |
|---|---|---|---|---|
| `dual_fuel_std_perf_lockout_30F` | `dual_fuel_gas_furnace_backup` | 0 F (unused) | 30 F | `two_speed_standard_eff` |
| `dual_fuel_std_perf_lockout_17F` | `dual_fuel_gas_furnace_backup` | 0 F (unused) | 17 F | `two_speed_standard_eff` |
| `dual_fuel_std_perf_lockout_0F` | `dual_fuel_gas_furnace_backup` | 0 F (unused) | 0 F | `two_speed_standard_eff` |
| `dual_fuel_std_perf_lockout_neg10F` | `dual_fuel_gas_furnace_backup` | 0 F (unused) | -10 F | `two_speed_standard_eff` |

Other arguments are the same as #446 (no oversizing, `htg_sizing_option=0F`, no hr/dcv/econ/roof/window).

**New measure choice `backup_ht_fuel_scheme=dual_fuel_gas_furnace_backup`** (reuses #446's name, no EMS):
- **Backup coil:** always a `CoilHeatingGas` with fuel `NaturalGas`. Fuel oil, propane and
  electric-heated buildings all get natural gas backup.
- **Lockout:** always `hp_min_comp_lockout_temp_gas_backup_f`, so the elec backup lockout in these
  rows is never used.
- **Existing choices unchanged:**
  - `match_original_primary_heating_fuel`: electric-heated buildings still get electric backup,
    and combustion buildings keep their original fuel (2.2).
  - `electric_resistance_backup`: unchanged.
- **Test:** `test_dual_fuel_backup_is_natural_gas` covers fuel oil, propane (the 7A gas model
  relabeled) and an electric coil model.
- **Note for electric-heated buildings:** this adds gas backup to buildings that may not have
  gas service today. Revisit whether applicability should exclude them.

**What changed from #446, and why:**
- **Lockout arguments:** #446's single `hp_min_comp_lockout_temp_f` became the gas backup lockout
  from 2.1.
- **Performance category:** `carrier_48qe_dualfuel` became `two_speed_standard_eff` until we
  decide whether we want the Carrier category.
- **Option names:** #446 had two sets, `dual_fuel_hybrid_heating_*` and `std_orig_backup_lockout_*`.
  With the same performance category, they would differ only in backup scheme. We keep one set,
  named `dual_fuel_std_perf_lockout_*` so the dual fuel intent and the performance category are
  both visible.
- **No EMS two-stage gas coil.** The backup is the measure's existing single-stage
  supplemental gas coil (see 1.4).

---

## 2. Baseline: what `ccaradon/dual_fuel_rtus` changes vs `main`

`measure.rb` only: +192 / -28 lines. Not verified by running the measure or tests.

### 2.1 Two compressor lockout temperatures (replaces one)
- Removed argument `hp_min_comp_lockout_temp_f` (default 0 F).
- Added `hp_min_comp_lockout_temp_elec_backup_f` (default 0 F).
- Added `hp_min_comp_lockout_temp_gas_backup_f` (default 25 F).
- In `run`, one is chosen: electric if `prim_ht_fuel_type == 'electric'` or
  `backup_ht_fuel_scheme == 'electric_resistance_backup'`, otherwise gas. The chosen value is
  assigned to the old variable name `hp_min_comp_lockout_temp_f`, so downstream code is unchanged.
- **Breaking:** anything passing `hp_min_comp_lockout_temp_f` (workflows, buildstock inputs,
  tests) must be updated.

### 2.2 Gas backup coil keeps the original fuel
- Before old equipment is deleted, read `fuelType` from the existing `CoilHeatingGas`
  (directly, or inside an `AirLoopHVACUnitarySystem`) into `orig_htg_coil_fuel_type`.
- New backup `CoilHeatingGas` gets that fuel type, so fuel oil / propane are no longer silently
  switched to natural gas. Warns and uses the OpenStudio default if the fuel can't be found.
- Coil name changes: `"<loop> gas backup coil"` -> `"<loop> <fuel> backup coil"`.

### 2.3 Supply fan data from the scenario JSON
- New helper `assign_fan_data(fan_data_json, std)` reads a `fan_data` record
  (`fan_type`, `fan_power_coefficients`, `impeller_efficiency`) from the scenario performance json.
- Fallback if missing/incomplete: warning, `two_speed` curve
  `[0.005131596, -0.061344439, 0.870911024, 0.221907644, -0.036605825]`, baseline impeller
  efficiency from `std.fan_baseline_impeller_efficiency`.
- Before: every scenario used the Daikin Rebel variable-speed curve; non-high-eff scenarios got a
  fixed total efficiency of 0.63.
- Fan renamed `"<loop> VFD Fan"` -> `"<loop> Supply Fan"`; pressure rise now set at creation.
- **Open:** confirm the `fan_data` records exist in the scenario JSONs on this branch.

### 2.4 Fan motor efficiency sized, not assumed
- bhp = `fan_static_pressure * design_airflow / (impeller_eff * 745.7)`.
- Nominal motor hp = bhp * 1.1 with the same rounding nudge as openstudio-standards baseline fans.
- Motor eff from `std.fan_standard_minimum_motor_efficiency_and_size`;
  total eff = impeller eff * motor eff.
- Replaces the `fan_mot_eff` literal and the `fan_change_motor_efficiency` call.

### 2.5 Fan minimum flow fraction
- Before: max(0.40, min_airflow_ratio).
- Now: min(1.0, max(lowest stage flow / design airflow, `specified_min_flow_fraction`,
  `current_min_oa_flow_ratio`)).
- `specified_min_flow_fraction` is captured before `adjust_cfm_per_ton_per_limits` mutates the
  stage fractions, so the cfm/ton guard cannot lower the fan's claimed turndown.
- New `fan summary` info line under `debug_verbose`.

### 2.6 Expected impact (hypothesis, not measured)
- Lockout temp now depends on backup fuel (gas-backup buildings lock out at 25 F by default).
- Fuel oil / propane buildings keep their fuel as backup.
- Two-speed scenarios likely see higher fan energy than before (no variable-speed credit).

## 3. Plan: all four scenarios in one ComStock run

**Goal:** a single ComStock run whose yml has one upgrade per scenario. IMPACT may need two
upgrades, one per control strategy. All upgrades use `upgrade_hvac_add_heat_pump_rtu` and differ
only by options lookup arguments.

**Approach:** get each scenario working and tested on its own first, then combine. A scenario is
ready to combine when it has (a) an options lookup row, (b) passing unit tests for what makes it
different, and (c) a clean 10K run.

### 3.1 Readiness by scenario

| # | Scenario | Measure changes needed | Options lookup | Tests | Next step |
|---|---|---|---|---|---|
| 1 | Dual Fuel RTU, standard performance | None (dual fuel backup scheme added, 1.5) | `dual_fuel_std_perf_lockout_30F` | `test_dual_fuel_backup_is_natural_gas` | Confirm which option the existing 10K used (see 3.2). Rerun the 10K with this option if it differs, then do a full run |
| 2 | CCHPC challenge spec dual fuel RTU | None expected | Add `dual_fuel_cchpc_spec_lockout_neg10F` (`dual_fuel_gas_furnace_backup`, gas lockout -10 F, `cchpc_2027_spec`) | Covered by existing fan/JSON tests plus the dual fuel test; add a `cchpc_2027_spec` case if cheap | Add the row, then a 10K run |
| 3 | CCHPC typical dual fuel or HP RTU | **New performance category:** performance map JSON (with `fan_data`), a new `hprtu_scenario` choice, and branches in the scenario `case` statements | New row once the category exists; backup scheme depends on dual fuel vs HP RTU | JSON format and `fan_data` tests should cover the new JSON (confirm they loop over all scenarios); one apply-only test for the new choice | Get the performance data; decide dual fuel vs HP RTU and the backup |
| 4 | IMPACT dual fuel | **Sequential control** (see 3.3) and the TBC items in 1.3 | Two rows (simultaneous, sequential) once the arguments exist | One apply-only test per strategy; one simulation check of `com_report_hvac_dx_heating_load_during_hybrid_heating_j` | Confirm IMPACT parameters; choose a sequential approach |

Scenarios 1 and 2 can go ahead now. Scenarios 3 and 4 are blocked on decisions (performance data,
IMPACT parameters, sequential approach) before the measure work starts.

### 3.2 Steps

1. **Map scope to options.** Keep the 1.1 "Options lookup option" column current, and add the
   scenario 2 row. Confirm which option the scenario 1 10K used: it ran before
   `dual_fuel_gas_furnace_backup` existed, so it was probably `orig_fuel_backup_std_perf_gas_lockout_30F`
   (`match_original_primary_heating_fuel`). That option gives electric backup to electric-heated
   buildings and keeps fuel oil or propane, so it isn't a pure dual fuel run.
2. **Run scenarios 1 and 2 individually** (10K each). Check that the backup coils are natural gas,
   that the lockout is applied, and that the hybrid heating DX load (1.4) is non-zero and plausible.
3. **Scenario 3:** add the performance category and its tests, add the options row, then a 10K run.
4. **Scenario 4:** implement sequential control (3.3) and its tests, add the two option rows, then
   a 10K run for each.
5. **Revisit unit tests** (3.4). This can run alongside steps 2–4, but finish it before adding the
   scenario 3 and 4 tests so the new tests follow the new structure.
6. **Combine:** one yml with all upgrades, a 10K smoke run, then the full run.

### 3.3 Sequential control for IMPACT (open)

"Sequential" means the gas coil heats alone with the DX compressor locked out. Today the measure
only models simultaneous operation: the supplemental gas coil adds heat when DX can't meet the
load. Candidates, avoiding EMS (1.4):
- **(a) Post-processing estimate.** Use the simultaneous run and treat
  `com_report_hvac_dx_heating_load_during_hybrid_heating_j` as heat that moves from DX to gas under
  sequential control. No measure change and one run. It's an estimate: it ignores how the
  equipment's behavior would change under sequential control.
- **(b) Native changeover.** Set the DX compressor lockout and the unitary system's supplemental
  heater maximum outdoor temperature to the same switchover temperature. Below it, gas only; above
  it, DX only. No EMS, but above the switchover there is no gas help when DX falls short, so check
  unmet hours.
- **(c) EMS control** as in #446. Rejected for now (1.4).

Decide after confirming IMPACT's definition of sequential. If (b), add an argument such as
`gas_heating_control_strategy` (`simultaneous` / `sequential`) and tests for both values.

### 3.4 Unit tests

**Current state** (`tests/measure_test.rb`): 29 tests.
- **Slowest:** 7 call `verify_hp_rtu`, which runs two sizing runs each (before/after). 4 more run
  full simulations.
- **Example:** in one sizing run, `test_elec_backup_lockout_7A` took over 20 minutes, because the
  HVAC loops didn't converge on the cooling design day ("Maximum iterations (20) exceeded").
- **Cheap tests do exist:** apply-only tests like `test_backup_coil_matches_original_fuel` (26 s)
  and `test_dual_fuel_backup_is_natural_gas` (19 s) finish in under a minute.
- **Measured 2026-10-05:** four tests (argument names, two `*_lockout_7A` tests and the backup
  fuel test) took 46 minutes together. Nearly all of that was the two lockout tests' sizing runs.

**Proposed:**
- [ ] **Time every test.** Run minitest `--verbose` for per-test times, and record them here.
- [ ] **Split into two tiers:**
  - *Fast:* argument, JSON and apply-only checks, run on every change.
  - *Slow:* sizing and simulation checks, run before a 10K or a PR.
  - Make the split explicit, e.g. by name prefix or an env var that skips slow tests.
- [ ] **Remove redundant slow tests.** Three `verify_hp_rtu` tests (`test_380_small_office_psz_gas_coil_7A`,
  `test_gas_backup_lockout_7A`, `test_elec_backup_lockout_7A`) do before/after sizing runs on the
  same `380_small_office_psz_gas_coil_7A.osm` and differ only in arguments. The lockout checks
  could be apply-only. Keep one sizing-run test per behavior and move the rest to apply-only.
- [ ] **Look into the non-convergence** in the 7A sizing run. It may be a model problem, or it may
  be related to the fan changes in 2.3–2.5. If it's the fan changes, it also matters for real runs.
- [ ] **One fast test per scenario** that applies the scenario's options lookup arguments and checks
  that they reach the model (backup coil fuel, lockout, performance curves, fan, control strategy).
  Ideally the arguments are read straight from the options lookup row, so the test and the
  lookup can't drift apart.
- [ ] **One simulation test** (slow tier) for the hybrid heating DX load report (1.4), on a small
  dual fuel model.

---

## 4. Open questions

- [ ] Do all four scenario JSONs (`two_speed_standard_eff`, `two_speed_lab_data`,
      `variable_speed_high_eff`, `cchpc_2027_spec`) carry `fan_data`?
- [ ] Who else passes `hp_min_comp_lockout_temp_f`? (grep ymls, workflows, tests)
- [ ] Anything matching on the old coil/fan names (`gas backup coil`, `VFD Fan`)?
- [ ] Is 25 F the right default for the gas-backup lockout?

## 5. Change log (this branch)

- 2026-10-02: branch created; section 2 baseline written (originally numbered section 1).
- 2026-10-02: created `jkim/dual_fuel_rtus_notes` off `origin/ccaradon/dual_fuel_rtus` to capture the
  latest changes to this measure and to use as the starting point for further work. Upstream tracking
  was removed so pushes don't go to the `ccaradon/` branch.
- 2026-10-05: added section 1 (scope table for the four measure scenarios); renumbered later sections.
- 2026-10-05: added 1.4. Ported the reporting side of closed PR #446 into this branch
  (`com_report_hvac_dx_heating_load_during_hybrid_heating_j` in `comstock_sensitivity_reports`,
  plus a column definition) to support the simultaneous vs sequential comparison for IMPACT.
- 2026-10-05: replaced the EMS-based calculation with a report-side one that uses zone timestep
  `Heating Coil Heating Energy` for DX + gas supplemental coil pairs, so the #446 EMS change is not
  needed. Rewrote 1.4 accordingly.
- 2026-10-05: ported `std_orig_backup_lockout_{30,17,0,neg10}F` options from #446 with the split
  lockout arguments and `two_speed_standard_eff`; skipped `dual_fuel_hybrid_heating_*`. Added 1.5.
- 2026-10-05: renamed those options to `dual_fuel_std_perf_lockout_*` and switched them to a new measure
  choice `backup_ht_fuel_scheme=dual_fuel_gas_furnace_backup` (always natural gas backup, gas
  lockout). Rewrote 1.5. Regenerated the HPRTU `measure.xml`, which also fixes checksums left stale by
  `b3e9b751`.
- 2026-10-05: added section 3 (plan for running all four scenarios) and an options lookup column in
  1.1; renumbered later sections.

## 6. Thoughts / brainstorming

_(empty)_
