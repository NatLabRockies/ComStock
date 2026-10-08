# upgrade_hvac_add_heat_pump_rtu — working notes

**Measure:** `resources/measures/upgrade_hvac_add_heat_pump_rtu/measure.rb`
**This branch:** `jkim/dual_fuel_rtus_notes`, branched from `origin/ccaradon/dual_fuel_rtus` at `b3e9b751`
**Compared against:** `origin/main` (merge base `f25ac375`; `measure.rb` hasn't changed on main since)

This branch picks up the latest work on the measure from `dual_fuel_rtus` and is the starting
point for what comes next. This file is my running log: what changed, what's planned, what's still
open, and how to run it. Newest entries go at the bottom of each section. It lives here rather than
in the measure folder so the measure folder doesn't grow.

The sections run from context to action: what we're modeling (1), the code this branch inherited
(2), what I've added on this branch (3), the plan to get all four scenarios into one run (4), how to
run it (5), and what's still undecided (6).

**Contents**
1. Scope: the four scenarios
2. Starting point: what `dual_fuel_rtus` changed
3. Changes on this branch
4. Plan: all four scenarios in one run
5. How to run ComStock on Kestrel
6. Open questions
7. Thoughts and brainstorming
8. Change log

**Terms used below**
- **HP RTU:** a rooftop unit with a heat pump. Its compressor heats and cools through a **DX coil**.
- **Dual fuel RTU:** a heat pump RTU with a **gas** backup coil.
- **Backup (supplemental) coil:** the second heating coil that helps when the heat pump can't keep up.
- **Compressor lockout temperature:** the outdoor temperature below which the heat pump stops and
  only the backup coil heats.
- **Gas heating control:** how the gas coil and the heat pump share the heating in a dual fuel RTU.
  **Simultaneous:** the heat pump and the gas coil heat at the same time; the gas coil adds heat when
  the heat pump can't keep up. **Sequential:** the gas coil heats alone and the heat pump compressor
  is off.
- **Challenge spec:** the minimum performance requirement of the Cold Climate Heat Pump Challenge
  (CCHPC), since renamed the **Commercial Building HVAC Technology Challenge**. This file keeps the
  CCHPC name because the measure and option names use it. The spec is what the `cchpc_2027_spec`
  category models (scenario 2). It is a floor, not a typical product: the lab-tested units that
  passed the Challenge perform better than it.
- **Challenge "typical" unit:** the middle-performing unit among the actual lab-tested Challenge
  units (scenario 3). Decided on 2026-10-07: "typical" means **one** real unit chosen from the
  middle of the pack, not an average of all the data points. Parveen is choosing the unit.
- **Max / boost:** the Challenge let manufacturers submit a fifth speed above the normal top speed.
  The spec JSON calls it "boost" (heating stage 4 of 4) and gives it a heating capacity above 100%
  of rated. How the four stages work is in 4.3.
- **Options lookup:** `resources/options_lookup.tsv`. Each row ties an option name in a yml to a
  set of measure arguments. `national/housing_characteristics/options_lookup.tsv` is an identical copy.
- **10K run / full run:** a ComStock run on a 10,000-building sample, or on the full sample.
- **#446:** closed PR [#446](https://github.com/NatLabRockies/ComStock/pull/446) (`jk/duelfuelrtu`),
  an earlier dual fuel RTU attempt built on EMS. Several things on this branch are adapted from it.

---

## 1. Scope: the four scenarios

All four scenarios use the same measure. They should differ only in arguments and performance
data, not in code paths, so every scenario goes through the same workflow. Update these tables as
things get confirmed. **TBC** means not confirmed yet; the TBC items are collected in section 6.

### 1.1 Configuration

| Scenario | Options lookup option | Performance category | Compressor lockout | Backup heat | Oversizing | Heating sizing temp | Gas heating control |
|---|---|---|---|---|---|---|---|
| 1. Dual fuel RTU, standard performance | `dual_fuel_std_perf_lockout_30F` | Standard (`two_speed_standard_eff`) | 30 F | Gas | Oversizing not considered | N/A if no oversizing | Simultaneous |
| 2. Cold Climate Heat Pump Challenge (CCHPC): challenge spec dual fuel RTU | `dual_fuel_cchpc_spec_lockout_neg10F` (added 2026-10-08, see 3.3; the existing `cchpc_2027_spec` option uses electric backup) | Challenge spec (`cchpc_2027_spec`) | -10 F | Gas | Oversizing not considered | N/A if no oversizing | Simultaneous |
| 3. CCHPC: typical dual fuel RTU | **None yet.** Needs a new performance category first | **TBC:** Challenge "typical" unit (new curve from one middle-performing lab-tested unit; Parveen is choosing it, see 4.3) | -10 F | Gas | Oversizing not considered | N/A if no oversizing | Simultaneous |
| 4. IMPACT: dual fuel | **None yet.** Needs control strategy support first | **TBC** | **TBC** | Gas | **TBC** | **TBC** | Simultaneous and sequential |

### 1.2 Status

| Scenario | Measure doc | 10K run | Full run |
|---|---|---|---|
| 1. Dual fuel RTU, standard performance | Created | Done | Not started |
| 2. CCHPC: challenge spec dual fuel RTU | Not started | Not started | Not started |
| 3. CCHPC: typical dual fuel RTU | Not started | Not started | Not started |
| 4. IMPACT: dual fuel | Not started | Not started | Not started |

What each scenario still needs in code, options, and tests is in 4.1.

---

## 2. Starting point: what `dual_fuel_rtus` changed

Compared with `main`, the `ccaradon/dual_fuel_rtus` branch changed only `measure.rb` (+192 / -28
lines). This section was written from reading the code, before any tests were run. The questions
it raised are in section 6.

### 2.1 Two compressor lockout temperatures instead of one
- Removed `hp_min_comp_lockout_temp_f` (default 0 F).
- Added `hp_min_comp_lockout_temp_elec_backup_f` (default 0 F) and
  `hp_min_comp_lockout_temp_gas_backup_f` (default 25 F).
- The measure picks one at run time: the electric one if the building heats with electricity
  (`prim_ht_fuel_type == 'electric'`) or the backup is electric (`electric_resistance_backup`);
  otherwise the gas one. The chosen value goes into the old variable name, so the rest of the code
  didn't change.
- **Breaking change:** anything that still passes `hp_min_comp_lockout_temp_f` (workflows, inputs,
  tests) has to be updated.

### 2.2 The gas backup coil keeps the building's original fuel
- Before the old equipment is removed, the measure reads the fuel of the existing `CoilHeatingGas`
  (on its own or inside an `AirLoopHVACUnitarySystem`).
- The new backup coil uses that fuel, so fuel oil and propane buildings are no longer quietly
  switched to natural gas. If the fuel can't be found, it warns and uses the OpenStudio default.
- Coil name changed from `"<loop> gas backup coil"` to `"<loop> <fuel> backup coil"`.

### 2.3 Supply fan data now comes from the scenario JSON
- New helper `assign_fan_data(fan_data_json, std)` reads a `fan_data` entry (`fan_type`,
  `fan_power_coefficients`, `impeller_efficiency`) from the scenario's performance JSON.
- If the entry is missing or incomplete, it warns and falls back to a two-speed fan curve
  `[0.005131596, -0.061344439, 0.870911024, 0.221907644, -0.036605825]` and the baseline impeller
  efficiency from `std.fan_baseline_impeller_efficiency`.
- Before: every scenario used the Daikin Rebel variable-speed fan curve, and scenarios other than
  high efficiency got a fixed fan efficiency of 0.63.
- Fan renamed from `"<loop> VFD Fan"` to `"<loop> Supply Fan"`. Its pressure rise is now set when
  it's created.

### 2.4 Fan motor efficiency is now calculated
- Brake horsepower = `fan_static_pressure × design_airflow / (impeller_eff × 745.7)`.
- Motor size = brake horsepower × 1.1, rounded the same way openstudio-standards rounds baseline fans.
- Motor efficiency comes from `std.fan_standard_minimum_motor_efficiency_and_size`. Total fan
  efficiency = impeller efficiency × motor efficiency.
- This replaces the hard-coded `fan_mot_eff` and the `fan_change_motor_efficiency` call.

### 2.5 Fan minimum airflow
- Before: the larger of 0.40 and `min_airflow_ratio`.
- Now: the largest of (lowest stage airflow ÷ design airflow), `specified_min_flow_fraction`, and
  `current_min_oa_flow_ratio`, capped at 1.0.
- `specified_min_flow_fraction` is read before `adjust_cfm_per_ton_per_limits` changes the stage
  airflows, so that adjustment can't make the fan look like it turns down further than it does.
- With `debug_verbose` on, the measure logs a new `fan summary` line.

### 2.6 Expected effects (not yet measured)
- The lockout now depends on the backup fuel; gas-backup buildings lock out at 25 F by default.
- Fuel oil and propane buildings keep their fuel for backup.
- Two-speed scenarios will probably use more fan energy than before, since they no longer get the
  variable-speed fan curve.

---

## 3. Changes on this branch

Two things have been added so far, both adapted from #446 and both without its EMS code: a dual
fuel backup choice with options lookup rows (3.1), and a reporting output for IMPACT (3.2). Why we
left the EMS behind is explained in 3.2. A review of every existing option against scenarios 1 and
2, and the scenario 2 row it led to, is in 3.3.

### 3.1 Dual fuel backup choice and options

**New measure choice: `backup_ht_fuel_scheme=dual_fuel_gas_furnace_backup`.** It models a **dual
fuel RTU**: backup heat is always natural gas, whatever fuel the building used before. It reuses
#446's name but has no EMS.
- **Backup coil:** always a natural gas `CoilHeatingGas`. Buildings that heated with fuel oil,
  propane, or electricity all get natural gas backup.
- **Lockout:** always uses `hp_min_comp_lockout_temp_gas_backup_f` (2.1), so the electric backup
  lockout is never used.
- **Other choices are unchanged:**
  - `match_original_primary_heating_fuel`: electric-heated buildings still get electric backup, and
    buildings that burned a fuel keep that fuel (2.2).
  - `electric_resistance_backup`: unchanged.
- **Test:** `test_dual_fuel_backup_is_natural_gas` covers fuel oil, propane (the 7A gas model with
  its fuel relabeled), and an electric coil model.
- **Watch out:** this gives gas backup to electric-heated buildings that may not have a gas line
  today. Revisit whether they should be excluded.

**Options lookup rows.** Four options use this choice and differ only in compressor lockout
temperature. They're in both copies of the options lookup, right after
`orig_fuel_backup_std_perf_gas_lockout_0F`. Scenario 1 uses the 30 F row (1.1).

| Option | `backup_ht_fuel_scheme` | Electric backup lockout | Gas backup lockout | `hprtu_scenario` |
|---|---|---|---|---|
| `dual_fuel_std_perf_lockout_30F` | `dual_fuel_gas_furnace_backup` | 0 F (not used) | 30 F | `two_speed_standard_eff` |
| `dual_fuel_std_perf_lockout_17F` | `dual_fuel_gas_furnace_backup` | 0 F (not used) | 17 F | `two_speed_standard_eff` |
| `dual_fuel_std_perf_lockout_0F` | `dual_fuel_gas_furnace_backup` | 0 F (not used) | 0 F | `two_speed_standard_eff` |
| `dual_fuel_std_perf_lockout_neg10F` | `dual_fuel_gas_furnace_backup` | 0 F (not used) | -10 F | `two_speed_standard_eff` |

All other arguments match #446: no oversizing, `htg_sizing_option=0F`, and no heat recovery, DCV,
economizer, roof, or window changes.

**What changed from #446, and why:**
- **Lockout arguments.** #446's single `hp_min_comp_lockout_temp_f` is now the gas backup lockout
  (2.1).
- **Performance category.** `carrier_48qe_dualfuel` is replaced by `two_speed_standard_eff` until we
  decide whether we want the Carrier category (section 6).
- **Option names.** #446 had two sets, `dual_fuel_hybrid_heating_*` and `std_orig_backup_lockout_*`.
  With the same performance category, they'd differ only in backup scheme, so we kept one set and
  named it `dual_fuel_std_perf_lockout_*` to show both the dual fuel intent and the performance
  category.
- **No EMS two-stage gas coil.** The backup is the measure's existing single-stage gas coil (3.2).

### 3.3 Options lookup review for scenarios 1 and 2 (2026-10-08)

I went through all 41 `hvac_add_heat_pump_rtu` rows (40 before the new row below) to see which
match scenarios 1 and 2 (1.1). Scenarios 3 and 4 are left out until their definitions are settled.

**What every row has in common:** `htg_sizing_option=0F`, `clg_oversizing_estimate=1`,
`htg_to_clg_hp_ratio=1`, `dcv=false`, `econ=false`, `debug_verbose=false`, and `setback_value=2`
(which only matters when `modify_setbacks=true`). So matching comes down to the other arguments:

| Argument | What scenarios 1 and 2 need |
|---|---|
| `backup_ht_fuel_scheme` | `dual_fuel_gas_furnace_backup` (always natural gas backup, always the gas lockout; 3.1) |
| `hp_min_comp_lockout_temp_gas_backup_f` | 30 (scenario 1) / -10 (scenario 2) |
| `hprtu_scenario` | `two_speed_standard_eff` (scenario 1) / `cchpc_2027_spec` (scenario 2) |
| `performance_oversizing_factor` | 0 ("oversizing not considered") |
| `hr`, `roof`, `window`, `sizing_run`, `modify_setbacks` | all `false` |

`htg_sizing_option` is "N/A" in 1.1, and that holds in the code: with an oversizing factor of 0 the
heat pump's rated heating capacity can't go above the upsized cooling capacity, so the sizing
temperature doesn't change the capacity. (It can still change which sizing branch is taken, and so
the design heating airflow. Every row uses `0F` anyway.)

**Scenario 1: exact match.** `dual_fuel_std_perf_lockout_30F` matches every argument. The rows
closest to it:

| Option | Differs in | Effect |
|---|---|---|
| `orig_fuel_backup_std_perf_gas_lockout_30F` | `backup_ht_fuel_scheme=match_original_primary_heating_fuel` | Electric-heated buildings get electric backup with the *electric* lockout (0 F), and fuel oil or propane buildings keep their fuel. Not a true dual fuel run. This is probably what the earlier 10K used (4.2) |
| `dual_fuel_std_perf_lockout_{17F,0F,neg10F}` | Gas lockout only | Lockout sensitivity variants |
| #446 `dual_fuel_hybrid_heating_30F` (not in this lookup) | `hprtu_scenario=carrier_48qe_dualfuel`, single `hp_min_comp_lockout_temp_f` | The 2025 R4 yml's option (5.1). Won't run on this branch |

So the scenario 1 rerun should keep `dual_fuel_std_perf_lockout_30F`. If the earlier 10K used
`orig_fuel_backup_std_perf_gas_lockout_30F`, expect differences only in buildings that heat with
electricity, fuel oil, or propane.

**Scenario 2: no existing match, so I added one.** The two closest rows each differ in one argument:

| Option | Differs in |
|---|---|
| `cchpc_2027_spec` | `backup_ht_fuel_scheme=electric_resistance_backup` (and an unused gas lockout of -10) |
| `dual_fuel_std_perf_lockout_neg10F` | `hprtu_scenario=two_speed_standard_eff` |

New row, in both copies of the options lookup right after `dual_fuel_std_perf_lockout_neg10F`:

| Option | `backup_ht_fuel_scheme` | Electric backup lockout | Gas backup lockout | `hprtu_scenario` |
|---|---|---|---|---|
| `dual_fuel_cchpc_spec_lockout_neg10F` | `dual_fuel_gas_furnace_backup` | 0 F (not used) | -10 F | `cchpc_2027_spec` |

It's `dual_fuel_std_perf_lockout_neg10F` with `hprtu_scenario=cchpc_2027_spec`. The electric backup
lockout is 0 F to follow the `dual_fuel_std_perf_lockout_*` rows; `cchpc_2027_spec` uses -10 F
there, but dual fuel never reads it. No measure change needed: `cchpc_2027_spec` is already a valid
`hprtu_scenario` choice, and its JSON (`performance_map_CCHP_spec_2027.json`) has `fan_data`.

- [ ] Add a fast apply-only test for this row (gas backup coil, -10 F lockout, `cchpc_2027_spec`
      curves), ideally reading the arguments from the options lookup (4.5).

### 3.2 New output for scenario 4 (IMPACT): heat pump heat during gas heating

IMPACT compares simultaneous and sequential gas heating control (see Terms). The difference between
the two is the heat the heat pump delivers *while the gas coil is also on*. Under sequential
control, gas would supply that heat instead. No existing output isolates it, so we report it
directly.

**From standard outputs, not EMS.** #446 got this number from an EMS variable tied to an
EMS-controlled two-stage gas coil. We're **not** bringing that EMS change over: in testing, the
two-stage EMS coil gave results close to the measure's existing (non-EMS) gas coil, so the added
complexity isn't worth it. The output doesn't need EMS either. The measure builds each RTU as an
`AirLoopHVACUnitarySystem` with the DX coil as the main heating coil and the gas coil as the
supplemental coil. EnergyPlus turns on the supplemental coil when the DX coil can't meet the load or
the compressor is locked out, so above the lockout the model already runs as "simultaneous."

**How `comstock_sensitivity_reports` calculates it:**
- **Which systems count.** `hybrid_heating_coil_pairs(model)` finds unitary systems that have a DX
  heating coil (single, multi, or variable speed) and a `CoilHeatingGas` or
  `CoilHeatingGasMultiStage` supplemental coil.
- **Which outputs it requests.** `Heating Coil Heating Energy` at each zone timestep, for those coils
  only, to keep output files small. The cost is output size: each RTU adds two timestep outputs to
  the SQL file, 35,040 values each at 4 timesteps per hour. That should be fine even with dozens of
  RTUs.
- **The calculation.** For each DX + gas pair, add up the DX coil's heating energy in every timestep
  where the gas coil's heating energy is above zero. Then add the pairs together:

  ```text
  total = 0
  for each unitary system with a DX heating coil + gas supplemental coil:
    dx  = that system's DX coil heating energy, one value per zone timestep (J)
    gas = that system's gas coil heating energy, one value per zone timestep (J)
    for each timestep i:
      if gas[i] > 0: total += dx[i]
  ```

- **The result** is one number per building: heat pump heat delivered while that same unit's gas
  coil was also on, summed over all dual fuel units. It's reported as
  `com_report_hvac_dx_heating_load_during_hybrid_heating_j`, which `comstock_column_definitions.csv`
  maps to `out.params.dx_heating_load_during_hybrid_heating`. This matches #446's definition (DX
  heat delivered while gas stage 1 is on).

**What the calculation assumes, for buildings with many RTUs:**
- **Each RTU is judged by its own gas coil.** If RTU A runs DX and gas together while RTU B runs DX
  alone, only A's DX heat counts. Another unit's gas coil never triggers a count.
- **The two series line up.** Both come from the same simulation at the same frequency, so `dx[i]`
  and `gas[i]` cover the same period. The code also checks that they're the same length.
- **Adding RTUs together is a plain sum.** Each value is already energy in joules, so there's no
  weighting by size or airflow. A building with 10 RTUs gets the sum of 10 separate totals.
- **One unreadable RTU doesn't block the rest.** If either series is missing, that system is skipped
  with a warning, not an error, and the total covers only the units that could be read. A warning
  therefore means the total is partial.

**Caveats:**
- **Timestep resolution.** We use the zone timestep, not hourly values. With hourly values, an hour
  with a few minutes of gas would count all of that hour's DX heat. There's still a small version
  of this error: if the gas coil runs for only part of a zone timestep, that timestep's full DX heat
  counts. The EMS approach in #446 worked at a finer timestep and didn't have this error.
- **Below the lockout,** the DX coil delivers nothing, so those timesteps add zero. That's correct:
  heat only shifts from DX to gas under sequential control when it's above the lockout.
- **`measure.xml` checksum** for `comstock_sensitivity_reports` hasn't been updated yet. Regenerate it
  with the measure updater.
- **Not yet checked in a full simulation.** The helper has only been tried on a small test model.

- [ ] Run a dual fuel model end to end and compare the value against the DX and gas coil totals.

This output only *measures* the difference between the two control strategies. How the measure
will *model* sequential control is still open (4.4).

---

## 4. Plan: all four scenarios in one run

**Goal:** one ComStock run with one upgrade per scenario in the yml (scenario 4 may need two, one
per control strategy). Every upgrade uses this measure; they differ only in their options lookup
arguments.

**Approach:** get each scenario working and tested on its own, then combine them. A scenario is
ready to combine when it has:
1. an options lookup row,
2. passing unit tests for whatever makes it different, and
3. a clean 10K run.

### 4.1 Where each scenario stands

| # | Scenario | Measure changes needed | Options lookup | Tests | Next step |
|---|---|---|---|---|---|
| 1 | Dual fuel RTU, standard performance | None (the dual fuel backup choice is done, 3.1) | `dual_fuel_std_perf_lockout_30F` | `test_dual_fuel_backup_is_natural_gas` | Options reviewed (3.3): `dual_fuel_std_perf_lockout_30F` is an exact match; keep it for the rerun. Still to confirm which option the earlier 10K used (4.2). Simulation on hold until the space type refactor is stable |
| 2 | CCHPC challenge spec dual fuel RTU | None expected | `dual_fuel_cchpc_spec_lockout_neg10F` (`dual_fuel_gas_furnace_backup`, gas lockout -10 F, `cchpc_2027_spec`), added 2026-10-08 | Existing fan/JSON tests plus the dual fuel test. Add a `cchpc_2027_spec` case if it's cheap | Done: no existing row matched, so `dual_fuel_cchpc_spec_lockout_neg10F` was added (3.3). No measure changes needed (confirmed). Next: an apply-only test for the row. 10K run on hold until the space type refactor is stable |
| 3 | CCHPC typical dual fuel RTU | **A new performance category:** a performance map JSON (with `fan_data`), a new `hprtu_scenario` choice, and matching branches wherever the code switches on scenario | A new row once the category exists. Gas backup | The JSON format and `fan_data` tests should cover the new JSON (check that they loop over every scenario). One apply-only test for the new choice | Blocked: waiting on the latest data from Parveen. Once received, compare it with the existing curves (4.3), then add the options row |
| 4 | IMPACT dual fuel | **Sequential control** (4.4) and the TBC items in section 6 | Two rows (simultaneous and sequential) once the arguments exist | One apply-only test per strategy. One simulation check of the new output (3.2) | Meet with the team to confirm the simulation scope (may mean many options lookup rows; TBD). Then confirm IMPACT's parameters and choose how to do sequential |

**All simulations are on hold** until the space type refactor (happening in parallel) reaches a
working, stable version, possibly next week. In the meantime, prep work can go ahead for scenarios 1
and 2. The options review and the scenario 2 row are done (3.3); confirming which option the earlier
scenario 1 10K used is still open. Scenario 3 is waiting on
Parveen's latest data, and scenario 4 is waiting on a team meeting to confirm its scope.

### 4.2 Steps

1. **Match each scenario to an option.** Keep the options column in 1.1 up to date. The scenario 2
   row is added (3.3). Find out which option the scenario 1 10K used. It ran before
   `dual_fuel_gas_furnace_backup` existed, so it was probably
   `orig_fuel_backup_std_perf_gas_lockout_30F` (`match_original_primary_heating_fuel`). That option
   gives electric backup to electric-heated buildings and keeps fuel oil or propane, so it isn't a
   true dual fuel run.
2. **Run scenarios 1 and 2 separately** (10K each). Check that backup coils are natural gas, that the
   lockout is applied, and that the new output (3.2) is above zero and reasonable.
3. **Scenario 3:** add the performance category and its tests, add the options row, then a 10K run.
4. **Scenario 4:** add sequential control (4.4) and its tests, add the two options rows, then a 10K
   run for each.
5. **Rework the unit tests** (4.5). This can happen alongside steps 2–4, but finish it before
   writing the scenario 3 and 4 tests so those follow the new layout.
6. **Combine:** one yml with every upgrade, a 10K check run, then the full run (section 5).

### 4.3 Scenario 3: performance data plan and references (from the meeting on 2026-10-06)

**Experimental data.** Parveen has lab-tested data on many actual Challenge dual fuel RTU units.
Scenario 3 uses the "typical" unit from that set (see below). We compare it against the existing
curves in
`resources/measures/upgrade_hvac_add_heat_pump_rtu/resources/performance_maps_hprtu_lab_data.json`.
(That file is the `two_speed_lab_data` category.)

| Case | What we do |
|---|---|
| The existing curves match the experimental points well | Use Parveen's data to validate the existing curves. Show that they're already well structured. No new curves |
| They don't match well | Build new curves from Parveen's data points (see below) |

**If we build new curves:**
- The experimental data has **no indoor temperature variation**. We'd quantify the indoor
  temperature effect on capacity ratio and EIR from existing curves, probably the lab data curves in
  the JSON above.
- The indoor temperature effect would be a consistent % change on capacity ratio and EIR.

**Other data:**
- **Fan:** Parveen also has fan data. Next step: look at what it contains.
- **Defrost:** no defrost data, so we keep the existing defrost data.

**What "typical" means (clarified 2026-10-07/08).** The Challenge spec (scenario 2, already
modeled) is the Challenge's *minimum* requirement, so the tested units perform better than it, not
worse. Scenario 3's "typical" unit is the middle-performing one among the actual lab-tested units.
We discussed two ways to define "middle": an average of all the data points, or one unit that sits
in the middle on one or several metrics. **Decision: one unit.** Parveen is working out which unit
and on which metrics.

**Max and boost speeds.** Manufacturers could submit a fifth speed to the Challenge, above the
normal top speed. My reading, to confirm with Parveen: "max" is the normal top speed and "boost"
is that optional fifth speed. Parveen can elaborate on how the submitted products differ
physically. Per Parveen, we may still use four stages for scenario 3.

**How the model reflects speeds above rated (checked against the code on 2026-10-08).** The
Challenge RTU Technical Support Document says: "Heat pumps for the measure scenario are modeled with
4 stages of heating: low, medium, high, and boost." The measure does this in the challenge spec
category (`cchpc_2027_spec`, `performance_map_CCHP_spec_2027.json`, `staging_data`). Heating has
four stages, cooling also has four (cooling has no boost):

| Heating stage | Name | Capacity fraction (of rated) | Flow fraction | COP fraction | Capacity / efficiency curves |
|---|---|---|---|---|---|
| 1 | low | 0.713 | 0.50 | 1.019 | `h_cap_low` / `h_eir_low` |
| 2 | medium (**rated stage**) | 1.000 | 1.0 | 1.000 | `h_cap_medium` / `h_eir_medium` |
| 3 | high (the "max" speed) | 1.350 | 1.0 | 1.098 | `h_cap_high` / `h_eir_high` |
| 4 | boost | 1.389 | 1.0 | 0.722 | `h_cap_boost` / `h_eir_boost` |

- **Rated stage is 2, not the top stage.** `rated_stage_num_heating` is 2, so the rated heating
  capacity (the sized value) belongs to "medium". The other stages are fractions of it, which is how
  the measure gets capacities over 100%: high is 135% and boost is 139% of rated. (Cooling is the
  opposite: its rated stage is 4, the top stage.)
- **Each stage is its own speed in the coil.** `set_heating_coil_stages` builds one
  `CoilHeatingDXMultiSpeedStageData` per stage, using that stage's capacity, COP
  (`final_rated_heating_cop` × COP fraction), airflow, and its own capacity and EIR vs.
  temperature curves. The four curves are loaded per stage in the curve section of the measure.
  All four stages share one capacity-vs-flow curve and one EIR-vs-flow curve.
- **Boost costs efficiency.** Its COP fraction is 0.72 versus about 1.0 to 1.1 for the other three,
  so it adds only about 3% more capacity than high but at a much lower COP.
- **Flow per ton is checked per stage.** `adjust_cfm_per_ton_per_limits` can raise or lower a
  stage's airflow, and can drop a stage if its flow per ton can't be met. The checks skip the rated
  stage and higher (`stage < rated_stage_num`), so only low can be adjusted for heating; medium,
  high and boost are left as given.
- **The boost temperature limit is NOT applied.** The JSON has
  `boost_stage_num_and_max_temp_tuple` = `[4, -8.33333]` (stage 4, max outdoor temperature in C,
  about 17 F), which reads as "boost is only available at or below this temperature". The measure
  reads it in `assign_staging_data` and passes it along, but nothing uses it afterward (searched the
  whole measure folder). So boost can run at any outdoor temperature where the coil asks for the top
  speed. The other three JSONs set the tuple to `[]`. Part of the limit may be carried by the
  `h_cap_boost` / `h_eir_boost` curve ranges, but I haven't checked, and curve inputs outside the
  range are clamped rather than cut off. **Decision (2026-10-08): don't enforce the limit for now.**
  Revisit if the typical unit's data shows boost matters at warmer temperatures.
- **Open for scenario 3:** whether the new JSON keeps four stages (as Parveen suggested) or adds a
  fifth. If it keeps four, the stage layout above is the template.

**How EnergyPlus chooses the stage (checked 2026-10-08 against the EnergyPlus 25.1 Engineering
Reference, sections 15.2.13 `Coil:Heating:DX:MultiSpeed` and 16.5.6 multispeed unitary control, at
`C:\EnergyPlusV25-1-0\Documentation\EngineeringReference.pdf`).** The measure puts the coils in an
`AirLoopHVAC:UnitarySystem` with `Control Type = Load`, which uses the staging logic below.
**Stages are chosen by load, not by outdoor temperature.** Each HVAC timestep:

1. **Load.** The thermostat zone's sensible heating load is scaled up by the control zone's share
   of system airflow to get the load the unit must deliver.
2. **Top stage check.** The unit is modeled at full load at the highest stage (4, boost). If that
   can't meet the load, it runs at stage 4 with speed ratio 1 and the supplemental coil (gas or
   electric backup) makes up the rest; the setpoint may not be met.
3. **Stage 1 (low).** If stage 1's full-load capacity is enough, the unit stays at stage 1 and
   cycles on and off. Cycling ratio = load ÷ stage-1 full capacity (0 to 1). This is the only mode
   with part-load (cycling) losses through the PLF curve: the spec JSON sets
   `enable_cycling_losses_above_lowest_speed` to false, which becomes
   `Apply Part Load Fraction to Speeds Greater than 1 = No` on the coil.
4. **Step up.** Otherwise the cycling ratio is 1 and the stage number rises one at a time (2, 3, 4).
   The stage number is the lowest index whose full-load sensible capacity at the given airflow is
   greater than or equal to the load.
5. **Interpolate between n−1 and n.** Speed ratio = (load − full output at n−1) ÷ (full output at n
   − full output at n−1), 0 to 1. Capacity, airflow and power are linear blends,
   `Q = SR × Q_n + (1 − SR) × Q_(n−1)` and `Power = SR × P_n + (1 − SR) × P_(n−1)`
   (equations 15.355 and 15.359), as if the compressor spent a fraction SR of the timestep at stage
   n and the rest at n−1. The final speed ratio comes from an iterative solve, since fan heat and
   outlet conditions change with airflow.

Where the per-stage curves come in: each stage's full-load capacity is
`RatedCap_i × CapFT_i(T_indoor, T_outdoor) × CapFF_i(flow fraction)`, and likewise EIR, using that
stage's own curves (`h_cap_low` … `h_cap_boost`, `h_eir_low` … `h_eir_boost`). The curves don't
pick the stage; they set how much capacity each stage has at the current conditions, and the load
comparison in steps 2 to 5 uses that. Outdoor temperature affects staging only indirectly: colder
outdoors shrinks every stage's capacity, so a given load reaches a higher stage sooner.

What this means for the four-stage spec model:
- Boost (stage 4) runs only when the load exceeds high (stage 3)'s full-load capacity at that
  hour's conditions. In mild weather with high loads (for example morning warm-up) boost can run.
  Nothing in EnergyPlus or the measure ties it to −8.33 C, consistent with the unused tuple above.
- Between stages 3 and 4 the model blends 135% and 139% capacity with COP fractions 1.098 and
  0.722. Because the blend is linear in time share, hours in that band pay a steep efficiency
  penalty for a small capacity gain.
- "Rated stage = 2" only affects how capacities are specified (fractions of the sized stage 2
  capacity). Staging itself works through the four absolute capacities in order.
- EnergyPlus has an alternative, `Single Mode Operation = Yes` on
  `UnitarySystemPerformance:Multispeed`, where the unit runs the highest stage that does **not**
  exceed the load, with no interpolation (section 15.2.13.5). The measure doesn't set it;
  OpenStudio's forward translator writes the performance object itself with the default `No`, so
  the interpolating mode is what runs. To double check, look for
  `UnitarySystemPerformance:Multispeed` in a translated IDF.
- The compressor lockout (the 0 F / 25 F arguments, 2.1) is the only outdoor-temperature gate. It
  switches the whole DX coil off, after which only the supplemental coil heats.

**References we can use:**

| Reference | Location | Use |
|---|---|---|
| Challenge RTU Technical Support Document (DOE review, reviewed by Sam Petty; unpublished) | `ComStock - Measures\HVAC - Dual Fuel RTU\references\Challenge RTU Technical Support Document- DOE Review.docx` | **The predecessor measure doc of scenario 2.** It models the challenge spec HP RTU with electric resistance backup and says: "The HP-RTUs all use electric resistance supplemental heat in this study, noting that the Challenge does encourage dual fuel, of which a measure is expected in an upcoming ComStock data release." Scenario 2 is that dual fuel measure. Also background to reuse for scenario 3 (CCHPC typical dual fuel RTU) |
| Commercial Building Heat Pump Technology Challenge Specification, V1 | `ComStock - Measures\HVAC - Dual Fuel RTU\references\Commercial Building Heat Pump Technology Challenge Specification_V1.pdf` | Background on the Challenge itself (what the spec requires). **Not up to date on naming:** it uses the older terms; the Challenge is now called the "Commercial Building HVAC Technology Challenge" (see Terms). Use it for context, but check current naming before citing |
| Standard performance dual fuel RTU measure doc (`dual_fuel_hp_rtu_measure_doc_v5.docx`) | `ComStock - Measures\HVAC - Dual Fuel RTU\references\` | The measure doc for scenario 1 |
| Lab tested data HPRTU measure doc | **Not received yet** | Explains how `performance_maps_hprtu_lab_data.json` was created |
| Lab tested data on many actual dual fuel RTU units | **Not received yet.** Asked whether a published version (manufacturer names removed) exists; if so I need its URL or citation | Reference to cite for scenario 3 |

- [ ] Parveen: pick the "typical" unit and say which metric(s) put it in the middle.
- [ ] Parveen: confirm whether scenario 3 uses four stages or a fifth (boost) stage.
- [ ] Compare the typical unit's points with the existing curves and decide which case applies.
- [ ] Look at Parveen's fan data.
- [ ] Get the two documents we haven't received, and a URL or citation for the lab data if one is published.

### 4.4 Scenario 4: sequential control (open)

Today the measure only models simultaneous operation (3.2). Options for sequential, all avoiding
EMS:
- **(a) Estimate it afterwards.** Run simultaneous only, and treat the new output (3.2) as the heat
  that would move from the heat pump to gas. No measure change and only one run, but it's an
  estimate: it ignores how the equipment would actually behave under sequential control.
- **(b) Use a built-in switchover.** Set the compressor lockout and the unitary system's maximum
  outdoor temperature for the supplemental heater to the same value. Below it, only gas heats;
  above it, only the heat pump. No EMS, but above the switchover there's no gas help when the heat
  pump falls short, so check unmet hours.
- **(c) EMS control,** as in #446. Ruled out for now (3.2).

Decide once IMPACT's definition of "sequential" is confirmed. If we pick (b), add an argument such as
`gas_heating_control_strategy` (`simultaneous` / `sequential`) and test both values.

### 4.5 Unit tests

**Where things stand** (`tests/measure_test.rb`, 29 tests):
- **The slow ones:** 7 tests call `verify_hp_rtu`, which does two sizing runs each (before and
  after the measure). 4 more run full simulations.
- **Example:** `test_elec_backup_lockout_7A` spent over 20 minutes in one sizing run because the
  HVAC loops didn't converge on the cooling design day ("Maximum iterations (20) exceeded").
- **Fast ones exist too:** apply-only tests such as `test_backup_coil_matches_original_fuel` (26 s)
  and `test_dual_fuel_backup_is_natural_gas` (19 s) take under a minute.
- **Measured 2026-10-05:** four tests (argument names, the two `*_lockout_7A` tests, and the backup
  fuel test) took 46 minutes together, almost all of it the two lockout tests' sizing runs.

**Proposed:**
- [ ] **Time every test.** Run minitest with `--verbose` to get per-test times, and record them here.
- [ ] **Split the tests in two:**
  - *Fast:* argument, JSON, and apply-only checks. Run on every change.
  - *Slow:* sizing and simulation checks. Run before a 10K run or a PR.
  - Make the split explicit, e.g. a name prefix or an environment variable that skips slow tests.
- [ ] **Drop duplicate slow tests.** Three `verify_hp_rtu` tests (`test_380_small_office_psz_gas_coil_7A`,
  `test_gas_backup_lockout_7A`, `test_elec_backup_lockout_7A`) do the same before/after sizing runs
  on `380_small_office_psz_gas_coil_7A.osm` and differ only in arguments. The lockout checks could
  be apply-only. Keep one sizing test per behavior and make the rest apply-only.
- [ ] **Find out why the 7A sizing run doesn't converge.** It may be the model, or the fan changes in
  2.3–2.5. If it's the fan changes, real runs are affected too.
- [ ] **One fast test per scenario** that applies its options lookup arguments and checks that they
  show up in the model (backup coil fuel, lockout, performance curves, fan, control strategy).
  Ideally the test reads the arguments straight from the options lookup row, so the two can't drift
  apart.
- [ ] **One simulation test** (slow group) for the new output (3.2), on a small dual fuel model.

---

## 5. How to run ComStock on Kestrel

Pieced together from memory and `comstock_hpc_training.md` at the repo root, which is the full
reference (yml fields, monitoring, stopping stuck jobs, reading results). My OneNote page "ComStock
workflow: executing ComStock run" (EUSS notebook) has the exact commands I used; copy anything
missing from there into this section. Fill in each `TODO` the next time I run.

**What you need:**
- **This branch,** with the measure, the options lookup, and
  `postprocessing/comstockpostproc/resources/comstock_column_definitions.csv` up to date.
- **The latest yml.** It's not in the repo (`ymls/` only has examples). The team keeps the current
  ymls on Kestrel under `/kfs2/projects/<allocation>/ymls/<project>/`; ask which one is current.
  TODO: record its path and who confirmed it. Until then, my last yml (5.1) shows the layout.

**Steps:**

1. **Push the branch.** Commit and push everything the run needs. Both copies of the options lookup
   (`resources/` and `national/housing_characteristics/`) must match; they do as of 2026-10-06.
2. **Log in:** `ssh <user>@kestrel.hpc.nrel.gov`. Use WinSCP to move files.
3. **Check out the branch in my own clone,** not the shared `comstock` one, so other people's runs
   aren't affected:
   ```
   cd /kfs2/projects/eusscom/repos
   git clone https://github.com/NatLabRockies/ComStock.git ComStock_janghyun   # first time only
   cd ComStock_janghyun
   git fetch && git checkout jkim/dual_fuel_rtus_notes && git pull
   ```
   My 2025 R4 yml pointed to `ComStock_janghyun`, so it probably already exists. Run `git status`
   first so nothing local is lost.
4. **Copy the latest yml** into my own folder (e.g. `/kfs2/projects/eusscom/ymls/<project>/`) and
   edit it:
   - `buildstock_directory:` → my clone from step 3.
   - `output_directory:` → a new folder under `/kfs2/projects/eusscom/runs/<project>/`. Change
     `postprocessing.aws.s3.prefix` to match.
   - `sampler.args.sample_file:` → the right sample (10K or full). Set
     `baseline.n_buildings_represented` to its building count.
   - `upgrades:` → one entry per scenario, each `option: <parameter>|<option name>` matching a row
     in the options lookup (e.g. `dual_fuel_std_perf_lockout_30F`; see 3.1 and 4.1).
   - `os_version` / `os_sha` → the current image in `/kfs2/shared-projects/buildstock/apptainer_images/`.
   - `kestrel.account` and `n_jobs` → set both. `n_jobs` ≈ number of simulations ÷ 5,000–6,000.
5. **Turn on buildstockbatch:**
   ```
   module load python
   source /kfs2/shared-projects/buildstock/envs/<current-bsb-env>/bin/activate
   ```
   TODO: record the environment name. The training doc's example, `bsb-2024.01.0-ry`, may be out
   of date.
6. **Submit from the yml's folder:**
   ```
   buildstock_kestrel <name>.yml                     # normal run
   buildstock_kestrel --hipri <name>.yml             # small, quick runs only
   buildstock_kestrel --postprocessonly <name>.yml   # redo postprocessing only
   ```
7. **Watch it:** `squeue -u <user>`, plus the `job.out*` and `postprocessing.out` files in the
   output folder.
8. **Check results** in `<output_directory>/results/results_csvs/`. `up00` is the baseline; the
   upgrades follow in yml order. Look at `housing_characteristics/options_lookup.tsv` in the output
   folder to confirm the run used my options lookup.

**Run log** (one line per run: date, yml path, branch @ commit, sample, upgrades, output folder, result):

- _(none yet)_

### 5.1 My last yml (2025 R4 dual fuel, full run)

Possibly out of date; kept as a template. The settings worth reusing:

| Field | Value | Note |
|---|---|---|
| `schema_version` | `'0.5'` | The repo's examples in `ymls/` say `'0.3'`. Use whatever the team's current yml has |
| `buildstock_directory` | `/kfs2/projects/eusscom/repos/ComStock_janghyun` | My clone (section 5, step 3) |
| `output_directory` | `/kfs2/projects/eusscom/runs/euss_fy25/production_runs/2025_r4/full/dual_fuel_r4_combined_103224_v0` | Use a new folder for every run |
| `weather_files_path` | `/kfs2/projects/eusscom/weather/BuildStock_2018_FIPS_HI.zip` | |
| `sample_file` | `/kfs2/projects/eusscom/samples/euss_fy25/2025_r4/buildstock_20250917-0909_v30_2018_ltaylor2_103224_hardsize.csv` | 103,224 buildings (full R4). For a 10K run, use a 10K sample and update `n_buildings_represented` |
| `kestrel.account` | `cscore` | Billed to `cscore` even though the files are under `eusscom` |
| `kestrel.n_jobs` / `minutes_per_sim` | `216` / `120` | 103,224 buildings × (baseline + 4 upgrades) ≈ 516K simulations, about 2,400 per job |
| `kestrel.postprocessing.time` | `2000` | |
| `s3.bucket` / `athena.database_name` | `com-sdr` / `enduse` | |
| `os_version` / `os_sha` | `os_3_10_0_stds_0_8_3` / `86d7e215a1` | **Probably stale.** `ymls/national.yml` on main uses `os_3_10_0_stds_0_8_6`. Check `/kfs2/shared-projects/buildstock/apptainer_images/` |
| `max_minutes_per_sim` | `480` | |
| `workflow_generator` | `commercial_default`, version `'2024.07.18'` | Reporting measures: SimulationOutputReport, comstock_sensitivity_reports, qoi_report, simulation_settings_check (`run_sim_settings_checks: true`), emissions_reporting, utility_bills, run_directory_cleanup. Timestep CSV export with `inc_output_variables: false` |

**Its upgrades won't work on this branch.** They used
`hvac_add_heat_pump_rtu|dual_fuel_hybrid_heating_{30F,17F,0F,neg10F}`, #446 options this branch
didn't bring over (3.1). The equivalents here are `dual_fuel_std_perf_lockout_{30F,17F,0F,neg10F}`.
For the four-scenario run (section 4), list one upgrade per scenario instead:

```yaml
upgrades:
  - upgrade_name: DualFuel_StdPerf_30F
    options:
      - option: hvac_add_heat_pump_rtu|dual_fuel_std_perf_lockout_30F
  - upgrade_name: DualFuel_CCHPC_spec_neg10F
    options:
      - option: hvac_add_heat_pump_rtu|dual_fuel_cchpc_spec_lockout_neg10F
  # scenarios 3 and 4: add once their options exist (4.1)
```

Always change `output_directory` and `s3.prefix` together. If the old ones are reused, the new
results land under the 2025 R4 production prefix.

---

## 6. Open questions

Decisions and questions that don't have an owner yet. Action items with a clear next step stay in
their own sections (the checkboxes in 3.2, 4.3, and 4.5).

**Decisions about the scenarios** (the TBC items in 1.1):
- [ ] Scenario 3: the performance curve for the Challenge "typical" unit (a new curve is needed).
      Which unit is "typical" and whether it has a fifth (boost) stage are with Parveen. Plan and
      data sources are in 4.3.
- [x] Is `boost_stage_num_and_max_temp_tuple` used anywhere after it's read from the JSON? No; the
      boost temperature limit isn't applied. Decided not to enforce it for now (4.3).
- [ ] Scenario 4: performance category, compressor lockout, oversizing, and heating sizing temp.
- [ ] Scenario 4: how the measure will support both simultaneous and sequential gas heating (4.4),
      and whether that needs a new argument.
- [ ] Performance category for the `dual_fuel_std_perf_lockout_*` options. They use
      `two_speed_standard_eff` for now. #446 also added a `carrier_48qe_dualfuel` category; we haven't
      decided whether we want it (3.1).

**Questions about the inherited code** (section 2):
- [x] Do all four scenario JSONs (`two_speed_standard_eff`, `two_speed_lab_data`,
      `variable_speed_high_eff`, `cchpc_2027_spec`) include `fan_data`? (2.3) Yes, all four do
      (checked 2026-10-08).
- [ ] What else still passes `hp_min_comp_lockout_temp_f`? (Search ymls, workflows, and tests.) (2.1)
- [ ] Does anything look for the old coil or fan names (`gas backup coil`, `VFD Fan`)? (2.2, 2.3)
- [ ] Is 25 F the right default lockout for gas backup? (2.1)

## 7. Thoughts and brainstorming

_(empty)_

## 8. Change log

Section numbers in older entries are the numbers at the time.

- 2026-10-02: Created `jkim/dual_fuel_rtus_notes` from `origin/ccaradon/dual_fuel_rtus` to pick up
  the latest measure changes and build on them. Removed upstream tracking so pushes don't go to the
  `ccaradon/` branch. Wrote the baseline notes (now section 2).
- 2026-10-05: Added the scope tables for the four scenarios (section 1) and renumbered the rest.
- 2026-10-05: Added 1.4. Brought over the reporting side of closed PR #446:
  `com_report_hvac_dx_heating_load_during_hybrid_heating_j` in `comstock_sensitivity_reports`, plus a
  column definition, for IMPACT's simultaneous vs sequential comparison.
- 2026-10-05: Replaced the EMS-based calculation with one that reads timestep
  `Heating Coil Heating Energy` for each DX + gas coil pair, so #446's EMS change isn't needed.
  Rewrote 1.4.
- 2026-10-05: Brought over the `std_orig_backup_lockout_{30,17,0,neg10}F` options from #446, using
  the split lockout arguments and `two_speed_standard_eff`. Skipped `dual_fuel_hybrid_heating_*`.
  Added 1.5.
- 2026-10-05: Renamed those options to `dual_fuel_std_perf_lockout_*` and pointed them at a new
  measure choice, `backup_ht_fuel_scheme=dual_fuel_gas_furnace_backup` (always natural gas backup,
  gas lockout). Rewrote 1.5. Regenerated the measure's `measure.xml`, which also fixed checksums left
  stale by `b3e9b751`.
- 2026-10-05: Added the four-scenario plan (section 3) and the options column in 1.1. Renumbered.
- 2026-10-06: Added the Kestrel run instructions and my last yml (then sections 7 and 7.1).
- 2026-10-06: Rewrote the whole file in plainer language. Added a contents list and a terms list.
  Moved the run instructions to section 4 (my last yml is now 4.1) and the change log to the end.
- 2026-10-07: Added 1.6 with the scenario 3 data plan (Parveen's experimental data, validate vs.
  rebuild curves, fan and defrost data) and the list of references, from the meeting on 2026-10-06.
- 2026-10-07: Scenario 3 is now "CCHPC: typical dual fuel RTU" (HP RTU dropped), with gas backup.
  Set oversizing to "Oversizing not considered" for scenarios 1-3 and removed the related open items.
- 2026-10-07: Reorganized the file so it reads from context to action. Section 1 is now only the
  scope tables; the branch's own changes (the dual fuel options, old 1.5, and the IMPACT output,
  old 1.4) moved to a new section 3 after the inherited code; the scenario 3 data plan (old 1.6) and
  sequential control (old 3.3) moved under the plan as 4.3 and 4.4; the "still to confirm" list
  (old 1.3) merged into Open questions (now section 6). Added "gas heating control" and "#446" to
  the terms list and removed the repeated definitions and EMS reasoning. No content dropped.
- 2026-10-07: Corrected 1.2: the scenario 3 (CCHPC typical dual fuel RTU) measure doc is "Not started", not "Created".
- 2026-10-08: Added what "Challenge spec" and Challenge "typical" mean, the max/boost speeds, and
  how the spec JSON already models capacities over 100%, from a colleague's answers to my questions.
  Added terms, updated the scenario 3 row in 1.1 and the data plan in 4.3, and added open items.
- 2026-10-08: References in 4.3: the Challenge RTU Technical Support Document is the predecessor
  measure doc of scenario 2 (electric backup, with a dual fuel measure expected next). Added the
  Challenge Specification V1 PDF as background, noting it uses the older naming. Noted the
  Challenge's new name, "Commercial Building HVAC Technology Challenge", in Terms.
- 2026-10-08: Checked the Technical Support Document's "4 stages of heating: low, medium, high, and
  boost" against `measure.rb`. Rewrote the stage paragraph in 4.3 with a stage table (rated stage is
  2; capacity, flow and COP fractions; curves), how stages become coil speeds, the flow-per-ton
  check, and the finding that `boost_stage_num_and_max_temp_tuple` is read but never applied.
  Decided not to enforce the boost limit for now and closed that open item in section 6.
- 2026-10-08: Added "How EnergyPlus chooses the stage" to 4.3, from the EnergyPlus 25.1 Engineering
  Reference: load-based staging (lowest stage whose full-load capacity meets the load, with linear
  interpolation between stages n−1 and n), the role of the per-stage curves, and what that means
  for boost and the compressor lockout.
- 2026-10-08: Reviewed all 40 `hvac_add_heat_pump_rtu` options against scenarios 1 and 2 (new 3.3).
  Scenario 1 matches `dual_fuel_std_perf_lockout_30F` exactly. Scenario 2 had no match, so I added
  `dual_fuel_cchpc_spec_lockout_neg10F` (dual fuel, gas lockout -10 F, `cchpc_2027_spec`) to both
  copies of the options lookup. Updated 1.1, 4.1, 4.2, and 5.1. Closed the `fan_data` open question:
  all four scenario JSONs have it.
