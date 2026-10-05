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

Items marked **TBC** are not confirmed yet.

### 1.1 Configuration

| Measure scenario | Performance category | Compressor lockout temp | Backup heating source | Oversizing factor | Heating sizing temp | Gas heating control strategy |
|---|---|---|---|---|---|---|
| Dual Fuel RTU with standard performance | Standard performance (`two_speed_standard_eff`) | 30 F | Gas | **TBC:** no oversizing considered | N/A if no oversizing | Simultaneous |
| Cold Climate Heat Pump Challenge: challenge specification dual fuel RTU | Challenge specification performance (`cchpc_2027_spec`) | -10 F | Gas | **TBC:** no oversizing considered | N/A if no oversizing | Simultaneous |
| Cold Climate Heat Pump Challenge: typical dual fuel RTU **or** HP RTU | **TBC:** typical market performance (new performance curve) | -10 F | **TBC** | **TBC:** no oversizing considered | N/A if no oversizing | Simultaneous |
| IMPACT: Dual Fuel | **TBC** | **TBC** | Gas | **TBC** | **TBC** | Simultaneous and sequential |

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
- [ ] Performance category for the `std_orig_backup_lockout_*` options: they use
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

### 1.5 Options lookup rows ported from #446

Added to both `resources/options_lookup.tsv` and `national/housing_characteristics/options_lookup.tsv`,
after `orig_fuel_backup_std_perf_gas_lockout_0F`:

| Option | `backup_ht_fuel_scheme` | elec backup lockout | gas backup lockout | `hprtu_scenario` |
|---|---|---|---|---|
| `std_orig_backup_lockout_30F` | `match_original_primary_heating_fuel` | 0 F | 30 F | `two_speed_standard_eff` |
| `std_orig_backup_lockout_17F` | `match_original_primary_heating_fuel` | 0 F | 17 F | `two_speed_standard_eff` |
| `std_orig_backup_lockout_0F` | `match_original_primary_heating_fuel` | 0 F | 0 F | `two_speed_standard_eff` |
| `std_orig_backup_lockout_neg10F` | `match_original_primary_heating_fuel` | 0 F | -10 F | `two_speed_standard_eff` |

Other arguments are the same as #446 (no oversizing, `htg_sizing_option=0F`, no hr/dcv/econ/roof/window).

**What changed from #446, and why:**
- #446's single `hp_min_comp_lockout_temp_f` became the two arguments from 2.1. The #446 value
  goes to `hp_min_comp_lockout_temp_gas_backup_f`, and `hp_min_comp_lockout_temp_elec_backup_f`
  is set to 0 F. This matches the existing `orig_fuel_backup_std_perf_gas_lockout_*` rows, so
  only gas-backup buildings vary by option. (In #446, one lockout applied to all buildings.)
- #446's `dual_fuel_hybrid_heating_{30,17,0,neg10}F` rows were **not** ported. They need
  `backup_ht_fuel_scheme=dual_fuel_gas_furnace_backup`, which came with the #446 EMS gas coil and
  doesn't exist in our measure. They also use `hprtu_scenario=carrier_48qe_dualfuel`. Changed to
  our measure's arguments, they would be identical to `std_orig_backup_lockout_*`.

**Overlap:** `std_orig_backup_lockout_30F` and `_0F` give the same arguments as the existing
`orig_fuel_backup_std_perf_gas_lockout_30F` and `_0F`. Kept for now so the #446 lockout sweep
(30/17/0/-10 F) is in one set; consolidate later if not needed.

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

---

## 3. Open questions

- [ ] Do all four scenario JSONs (`two_speed_standard_eff`, `two_speed_lab_data`,
      `variable_speed_high_eff`, `cchpc_2027_spec`) carry `fan_data`?
- [ ] Who else passes `hp_min_comp_lockout_temp_f`? (grep ymls, workflows, tests)
- [ ] Anything matching on the old coil/fan names (`gas backup coil`, `VFD Fan`)?
- [ ] Is 25 F the right default for the gas-backup lockout?

## 4. Change log (this branch)

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

## 5. Thoughts / brainstorming

_(empty)_
