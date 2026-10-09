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
The scenario 4 row shows the values proposed from the precursor study (4.4) until the team confirms
them.

### 1.1 Configuration

| Scenario | Options lookup option | Performance category | Compressor lockout | Backup heat | Oversizing | Heating sizing temp | Gas heating control |
|---|---|---|---|---|---|---|---|
| 1. Dual fuel RTU, standard performance | `dual_fuel_std_perf_lockout_30F` | Standard (`two_speed_standard_eff`) | 30 F | Gas | Oversizing not considered | N/A if no oversizing | Simultaneous |
| 2. Cold Climate Heat Pump Challenge (CCHPC): challenge spec dual fuel RTU | `dual_fuel_cchpc_spec_lockout_neg10F` (added 2026-10-08, see 3.3; the existing `cchpc_2027_spec` option uses electric backup) | Challenge spec (`cchpc_2027_spec`) | -10 F | Gas | Oversizing not considered | N/A if no oversizing | Simultaneous |
| 3. CCHPC: typical dual fuel RTU | **None yet.** Needs a new performance category first | **TBC:** Challenge "typical" unit (new curve from one middle-performing lab-tested unit; Parveen is choosing it, see 4.3) | -10 F | Gas | Oversizing not considered | N/A if no oversizing | Simultaneous |
| 4. IMPACT: dual fuel | **TBC.** Proposed (from the precursor study, 4.4): `dual_fuel_std_perf_lockout_{30F,17F,0F,neg10F}`, the existing rows from 3.1. Sequential rows only if sequential is simulated | **TBC.** Proposed: Standard (`two_speed_standard_eff`), as in the precursor study | **TBC.** Proposed: sweep of 30, 17, 0, -10 F | Gas | **TBC.** Proposed: Oversizing not considered (the precursor and #446 default) | **TBC.** N/A if no oversizing | Simultaneous (simulated) and sequential (**TBC:** proposed as post-processed from the 3.2 output, as in the precursor study; see 4.4) |

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
- All four scenario JSONs have a `fan_data` entry, so the fallback doesn't trigger today.
  `cchpc_2027_spec` and `variable_speed_high_eff` use the 90.1 Appendix G single-zone VAV curve;
  the two two-speed scenarios use the two-speed curve above.
- Only `fan_power_coefficients` and `impeller_efficiency` change the model. `fan_type` is only
  printed in the debug log, and the `*_howto` / `*_notes` fields are documentation.
  `fan_power_function_ff` (only in the CCHPC JSON) isn't read by the measure.
- The impeller efficiency is 0.65 in every scenario, so total efficiency (impeller x 90.1 motor,
  looked up at bhp x 1.1) is 0.556-0.605 for all of them. The variable-speed fan advantage comes
  only from the curve and the lower minimum flow.
- The minimum flow fraction is not in `fan_data`. The measure sets it to the highest of the lowest
  stage airflow (after the cfm/ton adjustment), the lowest stage flow fraction in the JSON's staging
  data (0.40 for CCHPC, 0.59 for two-speed), and the minimum outdoor air ratio. It limits only the
  power curve; EnergyPlus can still move less air.
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
2, and the scenario 2 row it led to, is in 3.3. The measure and its test file were then cleaned up
without changing what the measure does (3.4).

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

- [x] Add fast apply-only tests for the scenario 1 and 2 rows, reading the arguments from the
      options lookup (4.5). Done: `test_dual_fuel_std_perf_lockout_30F_option` (scenario 1) and
      `test_dual_fuel_cchpc_spec_lockout_neg10F_option` (scenario 2) share the helper
      `verify_dual_fuel_options_lookup_row`. It reads the row from `resources/options_lookup.tsv`
      (via `options_lookup_args_for`), fails if any of its arguments isn't a measure argument,
      applies it to `380_small_office_psz_gas_coil_7A.osm`, and checks every RTU for:
      - a natural gas backup coil;
      - the row's gas backup compressor lockout (30 F / -10 F);
      - the heating coil type and stage count: single speed for `two_speed_standard_eff`, four
        stages for `cchpc_2027_spec`;
      - heating capacity curves from the row's category: `h_cap_T` for scenario 1, and `h_cap_low`,
        `h_cap_medium`, `h_cap_high`, `h_cap_boost` for scenario 2.

      Both passed on 2026-10-08 with OpenStudio 3.10.0 (105 and 123 assertions, about 20 s each).
      A scenario 3 or 4 test needs only a new two-line test calling the same helper.

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

### 3.4 Code cleanup of the measure and its tests (2026-10-09)

Commit `465c8341`. `measure.rb` went from 2804 to about 2040 lines and `tests/measure_test.rb` from
2963 to about 1555, with no change to what the measure does. The goal was readability, consistent
comments, and no duplicated code, before adding the scenario 3 and 4 work on top.

**What changed in `measure.rb`:**
- The eleven per-scenario `case` blocks that loaded performance curves (about 200 lines) are now one
  table, `SCENARIO_CURVE_NAMES`, listing each scenario's curve names by stage, plus a small
  `stage_curves` builder. `SCENARIO_PERFORMANCE_JSON` maps each scenario to its JSON file. Adding a
  scenario means adding one entry to each table. Curve creation order and names are unchanged.
- Repeated blocks became helpers: `set_curve_limits`, `crankcase_heater_power_w`,
  `get_supply_fan_properties`, `get_original_coil_capacities`, `get_original_heating_coil_fuel_type`,
  `get_min_oa_flow_m3_per_s`, `get_design_supply_air_flow_m3_per_s`, and `modify_heating_setbacks`
  (the 130-line setback block that was inline in the air loop loop).
- `assign_staging_data` returns a hash instead of a 17-element array, so the caller reads named
  fields instead of positional ones.
- Lists that were rebuilt inside loops are now class constants: name-match lists for applicability
  (`HP_NAME_WORDS`, `DATA_CENTER_NAME_WORDS`, ...), `SPACE_TYPES_NO_SETBACK`, `HTG_SIZING_OPTIONS_F`,
  the ERV exclusion lists, and the rated COP regressions.
- Removed duplicated setter calls (compressor lockout and fuel type set twice on the multispeed
  coils, one heating curve set twice per stage), duplicate entries in exclusion lists, the unused
  `_adv` COP regressions, the unused fan efficiency locals, commented-out code, and unused method
  parameters. The `%w[...]` arrays became bracket arrays because the repo's rubocop style asks for it.
- Comments are lowercase sentences and the section banners use one style. Argument names,
  descriptions, defaults, and choice order are byte-identical (the regenerated `measure.xml` changed
  only its checksums).

**What changed in `tests/measure_test.rb`:**
- Four helpers (`calc_cfm_per_ton_*`, `verify_cfm_per_ton`) were defined twice; the second
  definitions, which Ruby was already using, are kept.
- The argument-population loop that was copied into about twenty tests is one helper,
  `build_argument_map(arguments, overrides)`. The roof/window value check, lookup table check,
  cfm/ton checks, NA check, ERV check, sizing comparison, and setback checks are shared helpers.
- Removed the 65-line commented-out example test and two unused path helpers. The 31 test names and
  their output directories are unchanged, so nothing downstream moves.

**Two edits that do change behaviour, both in paths that previously raised an exception:**
- The setback code's warning referenced an undefined variable `zone`; it now uses `thermal_zone`.
- A supply fan whose availability schedule is a `ScheduleRuleset` was cast with the
  `ScheduleConstant` getter, which raises; it now uses the `ScheduleRuleset` getter.

**Bugs found and deliberately left alone**, each marked with a `TODO` comment in the code so they
can be fixed as separate, reviewable changes:
- `reference_heating_cfm_per_ton` is read from the **cooling** key of the staging data. All four
  JSONs define a separate heating value (411 or 420 vs 365 or 404 cfm/ton), so fixing this changes
  the adjusted heating COP for scenarios whose JSON leaves `final_rated_heating_cop` as `false`.
- The window upgrade's initial and final conditions are written into the **roof** variables, so the
  window conditions never reach the reported condition strings.
- The night cycling check is `night_cyc_sched_vals.include?([0, 0.0])`, which tests for an array
  element and is never true. The "high OA fraction with night cycling" exclusion therefore never
  removes an air loop.
- `test_confirm_heating_setback_change_opt_start` calls `possible_opt_start`, which has never been
  defined in the repo (added in `424e904f`). The call sits behind `i > 3`, and the heating setpoint
  day profiles in `Retail_PSZ-AC_updated_39_opt_start.osm` have 1, 3, or 4 values, so it is never
  reached: the test passes, but its optimum-start filtering is dead code and the test checks the
  same thing as the square wave test.
- `test_380_full_service_restaurant_psz_gas_coil_single_erv_3A` and its `_na` twin have identical
  bodies; neither toggles `hr`.

**How it was verified.** Nine output models from the committed code and the cleaned code were
compared with object handles replaced by type and name and timestamps masked: all identical. The
nine cover `two_speed_standard_eff`, `cchpc_2027_spec`, and `variable_speed_high_eff`; the sizing
run path (`test_sizing_model_in_alaska`, both runs); the setback path; and all three backup fuel
paths. All 31 tests were then run on the cleaned code in parallel (4.5) and pass.
Rubocop offenses went from 196 to 36; the remaining 36 are test method names with capitals, `eval` of
JSON strings, and size metrics on `run`.

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
| 1 | Dual fuel RTU, standard performance | None (the dual fuel backup choice is done, 3.1) | `dual_fuel_std_perf_lockout_30F` | `test_dual_fuel_std_perf_lockout_30F_option` (apply-only, reads the options lookup row; 3.3), plus `test_dual_fuel_backup_is_natural_gas` | Options reviewed (3.3): `dual_fuel_std_perf_lockout_30F` is an exact match; keep it for the rerun. Still to confirm which option the earlier 10K used (4.2). Simulation on hold until the space type refactor is stable |
| 2 | CCHPC challenge spec dual fuel RTU | None expected | `dual_fuel_cchpc_spec_lockout_neg10F` (`dual_fuel_gas_furnace_backup`, gas lockout -10 F, `cchpc_2027_spec`), added 2026-10-08 | `test_dual_fuel_cchpc_spec_lockout_neg10F_option` (apply-only, reads the options lookup row; 3.3), plus the existing fan/JSON tests | Done: no existing row matched, so `dual_fuel_cchpc_spec_lockout_neg10F` was added (3.3). No measure changes needed (confirmed). Apply-only test added and passing (3.3). 10K run on hold until the space type refactor is stable |
| 3 | CCHPC typical dual fuel RTU | **A new performance category:** a performance map JSON (with `fan_data`), a new `hprtu_scenario` choice, and matching branches wherever the code switches on scenario | A new row once the category exists. Gas backup | The JSON format and `fan_data` tests should cover the new JSON (check that they loop over every scenario). One apply-only test for the new choice | Blocked: waiting on the latest data from Parveen. Once received, compare it with the existing curves (4.3), then add the options row |
| 4 | IMPACT dual fuel | **None if sequential is post-processed** as in the precursor study (4.4, option a). Otherwise sequential control (4.4) and the TBC items in section 6 | **Proposed (from the precursor study, 4.4):** the four existing `dual_fuel_std_perf_lockout_{30F,17F,0F,neg10F}` rows (3.1), simultaneous control. Sequential rows only if we simulate it (4.4, option b) | One apply-only test per strategy if sequential gets an argument. One simulation check of the new output (3.2) | Confirm the proposed scope with the team (4.4): a lockout sweep (30, 17, 0, -10 F) with standard performance and simultaneous control; sequential derived from the new output (3.2); utility rate sensitivity and building filters in post-processing. Then confirm IMPACT's parameters and choose how to do sequential |

**All simulations are on hold** until the space type refactor (happening in parallel) reaches a
working, stable version, possibly next week. In the meantime, prep work can go ahead for scenarios 1
and 2. The options review and the scenario 2 row are done (3.3); confirming which option the earlier
scenario 1 10K used is still open. Scenario 3 is waiting on
Parveen's latest data. Scenario 4 has a proposed scope taken from the precursor study (4.4); it
still needs a team meeting to confirm it.

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

### 4.4 Scenario 4: scope and sequential control (open)

**What the precursor study did.** The deck `260410_dual_fuel_RTU_analysis_results_shared_version_1.pdf`
(Kim, Ringold, CaraDonna; April 2026, not in the repo) is the precursor of scenario 4. Its results
most likely came from the 2025 R4 full run in 5.1: that run had one `dual_fuel_hybrid_heating_*`
upgrade per lockout on `carrier_48qe_dualfuel`, and the deck has the same four lockouts and a
Carrier 48QE catalog comparison. **To confirm.** The scenario space the deck covered:

| Dimension | What was varied | How |
|---|---|---|
| System configuration | Dual fuel RTU (DX coil + gas furnace), with a standard HP RTU (DX coil + electric resistance) as the reference | Simulated (slide 3) |
| Compressor lockout | 30, 17, 0, -10 F | Simulated: one upgrade per lockout |
| Gas heating control | Simultaneous vs sequential | **Simultaneous simulated; sequential post-processed.** The heat pump heat delivered while the gas coil was on (what 3.2 now reports) was moved to gas at 0.8 thermal efficiency and taken out of electricity at the heat pump COP (slide 11). This is option (a) below |
| Performance data | Carrier 48QE catalog vs the standard performance curves vs lab measurements | Validation only (slide 6). All three agreed for a two-speed unit, so the deck concluded that the choice should be about rated efficiency or unit class (e.g., variable speed), not manufacturer |
| Utility rates, generic | Electricity energy 0.02 and 0.26 $/kWh; electricity demand 0.7 and 34 $/kW; gas 0.6 and 1.9 $/therm | Post-processing: 2 x 2 x 2 = 8 high/low combinations (slides 13-14) |
| Utility rates, by state | GA 0.12 $/kWh, 0 $/kW, 1.27 $/therm; TX 0.06, 10.88, 1.21; ME 0.10, 15.79, 1.21; MN 0.08, 16.49, 1.02 | Post-processing (slides 15-16) |
| Building filter | Standalone retail in GA, TX, ME, MN with PSZ-AC baselines (electric or gas coil); 6,800 / 6,656 / 820 / 3,497 models | Post-processing filter on the full run (slide 8) |
| Outputs | Electricity and gas intensity (kWh/sqft), peak demand, and the total bill split into electric energy, electric demand, and gas ($/sqft) | |

Headline results (slide 18): 30 F to -10 F lockout gave +34% electricity intensity and +27% peak
demand; simultaneous to sequential gave -11% electricity and +52% gas; lockout matters more as the
electricity/gas price gap grows; electricity energy rates dominate the bill; a 0 F lockout was
cheapest, by a small margin, in MN and ME, with a plateau in GA and TX.

**Proposed scope for scenario 4, as a starting point (to confirm with the team):**
- Keep the four-lockout sweep (30, 17, 0, -10 F) with simultaneous control. The rows already exist:
  `dual_fuel_std_perf_lockout_{30F,17F,0F,neg10F}` (3.1). Standard performance replaces the
  precursor's Carrier category, which the deck's validation slide supports.
- Derive sequential from the new output (3.2) as before, unless IMPACT needs it simulated.
- Rate sensitivity and the state and building type filters stay in post-processing, so they add no
  options rows.
- Still open: whether to repeat the sweep with the Challenge categories (scenarios 2 and 3), which
  would multiply the rows, and whether IMPACT wants all building types or the retail filter.

**Modeling sequential.** Today the measure only models simultaneous operation (3.2). Options for
sequential, all avoiding EMS:
- **(a) Estimate it afterwards.** Run simultaneous only, and treat the new output (3.2) as the heat
  that would move from the heat pump to gas. No measure change and only one run, but it's an
  estimate: it ignores how the equipment would actually behave under sequential control. **This is
  what the precursor study did** (slide 11: gas at 0.8 thermal efficiency, electricity at the heat
  pump COP).
- **(b) Use a built-in switchover.** Set the compressor lockout and the unitary system's maximum
  outdoor temperature for the supplemental heater to the same value. Below it, only gas heats;
  above it, only the heat pump. No EMS, but above the switchover there's no gas help when the heat
  pump falls short, so check unmet hours.
- **(c) EMS control,** as in #446. Ruled out for now (3.2).

Decide once IMPACT's definition of "sequential" is confirmed. If we pick (b), add an argument such as
`gas_heating_control_strategy` (`simultaneous` / `sequential`) and test both values.

### 4.5 Unit tests

**Where things stand** (`tests/measure_test.rb`, 29 tests before 2026-10-08, 31 now):
- **The slow ones:** 4 tests call `verify_hp_rtu`, which hard-sizes the model with a sizing run
  before and after the measure (`test_380_Small_Office_PSZ_Gas_2A`,
  `test_380_small_office_psz_gas_coil_7A`, `test_small_office_psz_not_hard_sized`,
  `test_380_retail_psz_gas_6B`; the two lockout tests used to as well, until 2026-10-09). 2 more
  run full annual simulations (`test_380_small_office_psz_gas_coil_7A_upsizing_adv` and `_std`).
- **Example:** `test_elec_backup_lockout_7A` spent over 20 minutes in one sizing run because the
  HVAC loops didn't converge on the cooling design day ("Maximum iterations (20) exceeded").
- **Fast ones exist too:** apply-only tests such as `test_backup_coil_matches_original_fuel` (26 s)
  and `test_dual_fuel_backup_is_natural_gas` (19 s) take under a minute.

**Test changes made on 2026-10-09**, all on this branch (commits `465c8341` and `97c6b03c`), and
how each worked out:

| Change | Tests affected | Result |
|---|---|---|
| Removed the first of two definitions of `calc_cfm_per_ton_singlespdcoil_heating`, `calc_cfm_per_ton_multispdcoil_heating`, `calc_cfm_per_ton_multispdcoil_cooling`, `verify_cfm_per_ton` (Ruby was already using the second) | restaurant cfm/ton tests, the two `upsizing_*` tests | same checks, no behavior change |
| Shared helpers: `build_argument_map`, `assert_envelope_measures_applied`, `verify_lookup_table_value`, `assert_cfm_per_ton_within_limits`, `run_hp_rtu_test`, `assert_measure_not_applicable`, `assert_existing_ervs_unchanged`, `run_sizing_comparison`, `apply_with_setback`, `heating_setpoint_profiles`, `assert_setback_deltas_within` | all 31 | same assertions; file went from 2963 to about 1560 lines |
| Removed the 65-line commented-out example test and two unused path helpers | none | |
| `verify_hp_rtu` dropped its unused `model` parameter and unused locals | the 4 hard-size tests (6 at the time) | same assertions |
| `test_gas_backup_lockout_7A`, `test_elec_backup_lockout_7A`: apply-only through the new `verify_backup_heat_and_lockout` instead of `verify_hp_rtu` | 2 | 55 min to 10 s each; backup coil type and lockout still checked on every RTU; stage and airflow checks remain in the 7A hard-size test |
| `test_dual_fuel_backup_is_natural_gas` uses the same helper with `expected_backup_fuel_type: 'NaturalGas'` | 1 | same assertions |
| `test_380_full_service_restaurant_psz_gas_coil_single_erv_3A_na`: `hr=true` on the excluded restaurant type, plus a check for the not-applicable warning | 1 | was an exact copy of the `hr=false` test; now a distinct check, passes |
| `test_confirm_heating_setback_change_opt_start`: removed the unreachable `possible_opt_start` call; added a direct check that each ramp step below the new minimum is raised to it and the occupied setpoint is unchanged | 1 | was a repeat of the square wave check; now verifies the ramp branch, passes |
| `test_fan_scenarios_are_differentiated`: compares fans pair by pair, matched by name, instead of `.first` of each scenario's unordered fan list | 1 | was flaky (see below); passes on all 18 pairs |
| Test names and output directories | none changed | |

**A flaky test found by the second full run.** `test_fan_scenarios_are_differentiated` passed in the
first full run and failed in the second, on identical measure code, with "the scenarios should
share an impeller efficiency; two-speed 0.55575 vs variable-speed 0.56225". The 7A model has 18
air loops (two stories), and in *both* scenarios 15 fans get motor efficiency 0.855 and the 3 main
zone fans get 0.865, because brake horsepower lands in a different 90.1 bin for the larger zones.
The test compared `two_speed.first` with `var_speed.first`, and the order of
`getAirLoopHVACUnitarySystems` is not stable, so it sometimes paired a 0.855 fan with a 0.865 one.
The original test had the same `.first` comparison. It now pairs fans by name (both scenarios name
them after the same air loops) and checks every pair.

**Running the whole file in parallel locally.** A temporary bash script (kept outside the repo)
launches nine `openstudio execute_ruby_script tests/measure_test.rb -v -n "/^(names)$/"` processes
with `MSYS_NO_PATHCONV=1`, waits, and collects the `-v` per-test times. The groups: one per
hard-size test (2A, 7A, not hard sized, retail 6B), one each for the two lockout tests (now fast,
could be merged), the two annual simulations together, the three restaurant cfm/ton tests
together, and the remaining 20 fast tests together. Nine processes fit in 32 GB with room to spare.
- **Measured 2026-10-05:** four tests (argument names, the two `*_lockout_7A` tests, and the backup
  fuel test) took 46 minutes together, almost all of it the two lockout tests' sizing runs.
- **Measured 2026-10-09, full run** (OpenStudio 3.10.0, all 31 tests, commit `465c8341`, run as
  nine parallel processes with a temporary script; 20 logical cores, 32 GB). All pass. Wall time
  57 minutes; the sum of test times is 259 minutes, so a serial run would take about 4.5 hours
  (more than the earlier estimate). Startup per process is about 25 s. Per test:

  | Test | Time | Where it goes |
  |---|---|---|
  | `test_380_small_office_psz_gas_coil_7A` | 56.0 min | sizing run after the measure: 53 min (before: 2 min) |
  | `test_elec_backup_lockout_7A` | 55.8 min | same model, same 53 min sizing run |
  | `test_gas_backup_lockout_7A` | 53.1 min | same model, same 50 min sizing run |
  | `test_380_retail_psz_gas_6B` | 32.4 min | sizing run after the measure: 30 min (before: 1.7 min) |
  | `test_380_small_office_psz_gas_coil_7A_upsizing_adv` | 24.4 min | annual EnergyPlus run: 23 min |
  | `test_380_small_office_psz_gas_coil_7A_upsizing_std` | 24.0 min | annual EnergyPlus run: 23 min |
  | `test_380_Small_Office_PSZ_Gas_2A` | 4.4 min | sizing run after the measure: 3 min (before: 0.6 min) |
  | `test_backup_coil_matches_original_fuel` | 80 s | three measure applications |
  | `test_small_office_psz_not_hard_sized` | 46 s | sizing runs of 3 s and 7 s |
  | `test_fan_scenarios_are_differentiated`, `test_dual_fuel_backup_is_natural_gas` | 40 s each | two or three applications |
  | `test_sizing_model_in_alaska`, `test_sizing_model_in_hawaii` | 37 to 39 s | two applications with the measure's own sizing run (2 s each) |
  | restaurant tests (5), setback tests (2), fan tests (2) | 17 to 32 s each | one application |
  | NA tests (3), options lookup tests (2) | 3 to 7 s each | |
  | argument, JSON format, fan data tests (4) | under 0.1 s | |

- **Measured 2026-10-09, second full run** (commit `97c6b03c`, after the test revisions below, same
  nine-process script). 31 tests, 3562 assertions, 30 passed, **1 failed**: `test_fan_scenarios_are_differentiated`,
  which turned out to be flaky (fixed the same day, see "A flaky test" below; it passes on its own
  after the fix). Wall time 36 minutes, summed test time 100 minutes (down from 57 and 259). The
  two lockout tests went from 55 minutes to 24 s each. The slow tests also ran faster than in the
  first run because fewer heavy processes competed for CPU: 7A hard-size 35 min (was 56), retail
  6B 22 min (was 32), the annual simulations 17 and 13 min (were 24 each). So per-test times depend
  on what else is running; the ranking is stable.
- **Measured 2026-10-09, third full run** (commit `13e26c1e`, after the fan test fix). 31 tests,
  3651 assertions, **all pass**. Wall time 31 minutes, summed test time 84 minutes. Slowest: 7A
  hard-size 31 min, retail 6B 18 min, the annual simulations 14 and 13 min, 2A hard-size 2.4 min;
  the other 26 tests take 7 minutes together.

  **Where the time goes.** The sizing run that `mimic_hardsize_model` does *after* the measure is
  25 to 50 times slower than the one before it, on every model (7A: 2 min to 53 min; retail 6B: 1.7
  to 30 min; 2A: 0.6 to 3 min). Its `eplusout.err` has 48 to 76 "SimHVAC: Maximum iterations (20)
  exceeded for all HVAC loops" warnings on the cooling design day; the pre-measure run has none. The
  measure's own sizing run (`SR1`, on the not-hard-sized model before the equipment is replaced)
  takes 2 to 10 s. So the slow part is simulating the *new* HP RTU, which also explains the 23
  minute annual runs for a small office. The three 7A hard-size tests repeat the identical 53 minute
  sizing run three times.

**How the tests are parallelized today.** They aren't, within this file. The Rakefile
(`unit_tests:upgrade_measure_tests`) runs each file in `test/upgrade_measure_tests.txt` in its own
process, with as many processes as the agent has cores, and Jenkins calls that through the
`cbci_shared_libs` pipeline (not in this repo, so the agent's core count isn't visible here). The 31
tests in `measure_test.rb` run one after another in one process, so this file is likely the longest
single item in the upgrade group. Locally, the same split can be made by hand with name filters in
separate terminals; the leading `/` of a regex filter needs `MSYS_NO_PATHCONV=1` in Git Bash or
the first alternative silently never matches.

**Proposed:**
- [x] **Time every test.** Per-test times recorded above (2026-10-09).
- [ ] **Split the file so CI runs it in parallel.** Move the shared helpers (now all in one place
  after 3.4) into `tests/hprtu_test_helper.rb` and split the tests into files by cost, each with
  its own class name, e.g. fast tests, two hard-size files of three tests, the five restaurant
  tests, and the two annual simulations. List each file in `test/upgrade_measure_tests.txt`; the
  Rakefile then schedules them as separate processes with no CI change. Expected: about 30 minutes
  instead of 1.5 to 2 hours, on an agent with spare cores. One precedent in the repo
  (`create_typical_building_from_model` has two test files).
- [ ] **Split the tests in two:**
  - *Fast:* argument, JSON, and apply-only checks. Run on every change.
  - *Slow:* sizing and simulation checks. Run before a 10K run or a PR.
  - Make the split explicit, e.g. a name prefix or an environment variable that skips slow tests.
- [x] **Drop duplicate slow tests** (2026-10-09). `test_gas_backup_lockout_7A` and
  `test_elec_backup_lockout_7A` repeated the 53 minute post-measure sizing run that
  `test_380_small_office_psz_gas_coil_7A` already does on the same model. They are now apply-only
  through a new helper, `verify_backup_heat_and_lockout`, which checks the backup coil type, its
  fuel when asked, and the compressor lockout on every new RTU; `test_dual_fuel_backup_is_natural_gas`
  uses the same helper. Each lockout test now takes about 10 s instead of 55 minutes, and the
  4-stage and airflow checks stay covered by the 7A hard-size test. Both pass.
- [ ] **Find out why the sizing run of the HP RTU model doesn't converge.** Not just 7A: every
  post-measure sizing run on 2026-10-09 (2A, 7A, retail 6B, the two lockout tests) hit the
  iteration limit on the cooling design day, and none of the pre-measure runs did. It may be the
  model, or the fan changes in 2.3–2.5. If it's the fan changes, real runs are affected too. Run one
  post-measure sizing run with `Output:Diagnostics,DisplayExtraWarnings` to see which loop and
  component.
- [x] **Fix `test_confirm_heating_setback_change_opt_start`** (2026-10-09). Its call to
  `possible_opt_start` (never defined in the repo) was unreachable because the test model's day
  profiles have at most 4 values (3.4), so the test only repeated the square wave check. The dead
  filter is removed and the test now checks the measure's ramp branch directly: the model's Sunday
  profile (59 F until 03:00, 64.8 F until 04:15, 67 F until 23:15, 59 F) must become 65, 65, 67, 65 F
  with a 2 F setback, i.e. every step below the new minimum is raised to it and the occupied
  setpoint is untouched. Ramp profiles are found in the input model (more than two unique values)
  and paired with the modified day schedules by name. Passes.
- [x] **Decide what the `_na` ERV test should check** (2026-10-09). It was a copy of
  `test_380_full_service_restaurant_psz_gas_coil_single_erv_3A` (3.4). It now sets `hr=true` on the
  full service restaurant model (a building type excluded from energy recovery) and asserts that the
  three existing ERVs are untouched and that the measure registered its "not applicable for energy
  recovery" warning. Passes in 10 s.
- [ ] **One fast test per scenario** that applies its options lookup arguments and checks that they
  show up in the model (backup coil fuel, lockout, performance curves, fan, control strategy).
  Ideally the test reads the arguments straight from the options lookup row, so the two can't drift
  apart. Scenarios 1 and 2 have one each (3.3); scenarios 3 and 4 can call the same helper,
  `verify_dual_fuel_options_lookup_row`.
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
      A proposed scope from the precursor study is in 4.4: standard performance, a 30/17/0/-10 F
      lockout sweep, and the #446 defaults (no oversizing, `htg_sizing_option=0F`, 3.1).
- [ ] Scenario 4: how the measure will support both simultaneous and sequential gas heating (4.4),
      and whether that needs a new argument.
- [ ] Performance category for the `dual_fuel_std_perf_lockout_*` options. They use
      `two_speed_standard_eff` for now. #446 also added a `carrier_48qe_dualfuel` category; we haven't
      decided whether we want it (3.1). The precursor deck (4.4) found the Carrier 48QE catalog, the
      standard performance curves, and lab data agree for a two-speed unit, which argues for staying
      with `two_speed_standard_eff`.

**Questions about the inherited code** (section 2):
- [x] Do all four scenario JSONs (`two_speed_standard_eff`, `two_speed_lab_data`,
      `variable_speed_high_eff`, `cchpc_2027_spec`) include `fan_data`? (2.3) Yes, all four do
      (checked 2026-10-08).
- [ ] What else still passes `hp_min_comp_lockout_temp_f`? (Search ymls, workflows, and tests.) (2.1)
- [ ] Does anything look for the old coil or fan names (`gas backup coil`, `VFD Fan`)? (2.2, 2.3)
- [ ] Is 25 F the right default lockout for gas backup? (2.1)

**Bugs found during the cleanup** (3.4), each marked `TODO` in the code and left as-is so the fix is
its own reviewable change:
- [ ] `reference_heating_cfm_per_ton` reads the cooling key. Fixing it changes the adjusted heating
      COP; confirm the intent with Chris and measure the effect on a 10K run before changing it.
- [ ] Window upgrade conditions overwrite the roof conditions in the reported condition strings.
- [ ] The night cycling check `include?([0, 0.0])` is never true, so the high OA fraction exclusion
      never fires. Decide whether that exclusion is still wanted (its comment calls it temporary,
      pending an EnergyPlus fix) before fixing or deleting it.

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
- 2026-10-08: Added `test_dual_fuel_cchpc_spec_lockout_neg10F_option`, an apply-only test for the
  scenario 2 row that reads its arguments from the options lookup. It passes (OpenStudio 3.10.0).
  Regenerated the measure's `measure.xml` for the test file checksum. Updated 3.3, 4.1, and 4.5.
- 2026-10-08: Added `test_dual_fuel_std_perf_lockout_30F_option` for the scenario 1 row and moved
  the shared steps of both option tests into `verify_dual_fuel_options_lookup_row`, which now also
  checks the heating coil type and stage count. Both pass. Regenerated `measure.xml`. Updated 3.3,
  4.1, and 4.5.
- 2026-10-09: Extracted the scenario space of the precursor dual fuel RTU study (April 2026 deck)
  into 4.4: four lockouts simulated, sequential derived by post-processing (option a), Carrier vs
  standard vs lab validation, generic and state utility rate sweeps, and the retail filter in GA, TX,
  ME, MN. Used it to propose a starting scope for scenario 4 in 4.1 (to confirm with the team) and
  added notes to the two related open items in section 6. Renamed 4.4 to "scope and sequential
  control".
- 2026-10-09: Filled the scenario 4 row in 1.1 with the proposed values from the precursor study
  (options rows, standard performance, lockout sweep, no oversizing, sequential post-processed),
  each still marked TBC.
- 2026-10-09: Expanded 2.3 with how `fan_data` is applied (which fields matter, the 0.65 impeller
  in every scenario, and where the minimum flow fraction comes from). Fixed the stale
  `fan_efficiency_range_for_this_scenario` text in all four scenario JSONs, which still described
  the earlier 0.70 variable-speed impeller. Text only; no model change. Regenerated `measure.xml`.
- 2026-10-09: Cleaned up `measure.rb` and `tests/measure_test.rb` with no functional change
  (commit `465c8341`, new 3.4): curve loading driven by a per-scenario name table, repeated blocks
  extracted into helpers, duplicated test helpers and dead code removed, comments made consistent.
  Verified by comparing nine before/after output models (all identical) and running 16 tests.
  Recorded the bugs found but left alone in 3.4 and section 6, and the test timings and the
  parallelization situation (per-file in the Rakefile, none within the file) in 4.5, with a proposal
  to split the file so CI runs it in parallel. Regenerated `measure.xml`.
- 2026-10-09: Ran all 31 tests on the cleaned code as nine parallel processes (temporary script,
  not in the repo): all pass, 57 minutes wall, 259 minutes summed. Recorded per-test times in 4.5
  and the finding that the post-measure sizing run is 25 to 50 times slower than the pre-measure
  one on every model, with iteration-limit warnings on the cooling design day. Corrected 3.4: the
  opt-start setback test passes because its undefined helper is behind an unreachable guard.
- 2026-10-09: Test revisions (4.5): the two lockout tests are apply-only via the new
  `verify_backup_heat_and_lockout` helper (55 min to 10 s each), and the `_na` ERV test now
  requests energy recovery on the excluded restaurant building type and checks the warning. The
  opt-start setback test drops its unreachable `possible_opt_start` filter and asserts the ramp
  branch directly (intermediate step raised to the new minimum, occupied setpoint untouched).
- 2026-10-09: Second full parallel run (on `97c6b03c`) exposed `test_fan_scenarios_are_differentiated`
  as flaky: it compared the first fan of each scenario from an unordered list, and the motor
  efficiency bin differs by air loop. Fixed to compare fans paired by name (4.5). Added a
  consolidated table of the day's test changes and the parallel grouping to 4.5.
- 2026-10-09: Third full parallel run on `13e26c1e`: 31 tests, 3651 assertions, 0 failures, 31
  minutes wall (4.5).
