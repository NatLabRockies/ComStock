# upgrade_hvac_add_heat_pump_rtu — working notes

**Measure:** `resources/measures/upgrade_hvac_add_heat_pump_rtu/measure.rb`
**This branch:** `jkim/dual_fuel_rtus_notes` (off `origin/ccaradon/dual_fuel_rtus` @ `b3e9b751`)
**Compared against:** `origin/main` (merge base `f25ac375`; main has no changes to measure.rb since)

**Purpose of this branch:** branched off `dual_fuel_rtus` to capture the latest changes to this
measure and to serve as the starting point for further work.

Running log of changes, thoughts and brainstorming for this measure. Newest entries go at the
bottom of each section. Kept here rather than in the measure folder to avoid growing it.

---

## 1. Baseline: what `ccaradon/dual_fuel_rtus` changes vs `main`

`measure.rb` only: +192 / -28 lines. Not verified by running the measure or tests.

### 1.1 Two compressor lockout temperatures (replaces one)
- Removed argument `hp_min_comp_lockout_temp_f` (default 0 F).
- Added `hp_min_comp_lockout_temp_elec_backup_f` (default 0 F).
- Added `hp_min_comp_lockout_temp_gas_backup_f` (default 25 F).
- In `run`, one is chosen: electric if `prim_ht_fuel_type == 'electric'` or
  `backup_ht_fuel_scheme == 'electric_resistance_backup'`, otherwise gas. The chosen value is
  assigned to the old variable name `hp_min_comp_lockout_temp_f`, so downstream code is unchanged.
- **Breaking:** anything passing `hp_min_comp_lockout_temp_f` (workflows, buildstock inputs,
  tests) must be updated.

### 1.2 Gas backup coil keeps the original fuel
- Before old equipment is deleted, read `fuelType` from the existing `CoilHeatingGas`
  (directly, or inside an `AirLoopHVACUnitarySystem`) into `orig_htg_coil_fuel_type`.
- New backup `CoilHeatingGas` gets that fuel type, so fuel oil / propane are no longer silently
  switched to natural gas. Warns and uses the OpenStudio default if the fuel can't be found.
- Coil name changes: `"<loop> gas backup coil"` -> `"<loop> <fuel> backup coil"`.

### 1.3 Supply fan data from the scenario JSON
- New helper `assign_fan_data(fan_data_json, std)` reads a `fan_data` record
  (`fan_type`, `fan_power_coefficients`, `impeller_efficiency`) from the scenario performance json.
- Fallback if missing/incomplete: warning, `two_speed` curve
  `[0.005131596, -0.061344439, 0.870911024, 0.221907644, -0.036605825]`, baseline impeller
  efficiency from `std.fan_baseline_impeller_efficiency`.
- Before: every scenario used the Daikin Rebel variable-speed curve; non-high-eff scenarios got a
  fixed total efficiency of 0.63.
- Fan renamed `"<loop> VFD Fan"` -> `"<loop> Supply Fan"`; pressure rise now set at creation.
- **Open:** confirm the `fan_data` records exist in the scenario JSONs on this branch.

### 1.4 Fan motor efficiency sized, not assumed
- bhp = `fan_static_pressure * design_airflow / (impeller_eff * 745.7)`.
- Nominal motor hp = bhp * 1.1 with the same rounding nudge as openstudio-standards baseline fans.
- Motor eff from `std.fan_standard_minimum_motor_efficiency_and_size`;
  total eff = impeller eff * motor eff.
- Replaces the `fan_mot_eff` literal and the `fan_change_motor_efficiency` call.

### 1.5 Fan minimum flow fraction
- Before: max(0.40, min_airflow_ratio).
- Now: min(1.0, max(lowest stage flow / design airflow, `specified_min_flow_fraction`,
  `current_min_oa_flow_ratio`)).
- `specified_min_flow_fraction` is captured before `adjust_cfm_per_ton_per_limits` mutates the
  stage fractions, so the cfm/ton guard cannot lower the fan's claimed turndown.
- New `fan summary` info line under `debug_verbose`.

### 1.6 Expected impact (hypothesis, not measured)
- Lockout temp now depends on backup fuel (gas-backup buildings lock out at 25 F by default).
- Fuel oil / propane buildings keep their fuel as backup.
- Two-speed scenarios likely see higher fan energy than before (no variable-speed credit).

---

## 2. Open questions

- [ ] Do all four scenario JSONs (`two_speed_standard_eff`, `two_speed_lab_data`,
      `variable_speed_high_eff`, `cchpc_2027_spec`) carry `fan_data`?
- [ ] Who else passes `hp_min_comp_lockout_temp_f`? (grep ymls, workflows, tests)
- [ ] Anything matching on the old coil/fan names (`gas backup coil`, `VFD Fan`)?
- [ ] Is 25 F the right default for the gas-backup lockout?

## 3. Change log (this branch)

- 2026-10-02: branch created; section 1 baseline written.
- 2026-10-02: created `jkim/dual_fuel_rtus_notes` off `origin/ccaradon/dual_fuel_rtus` to capture the
  latest changes to this measure and to use as the starting point for further work. Upstream tracking
  was removed so pushes don't go to the `ccaradon/` branch.

## 4. Thoughts / brainstorming

_(empty)_
