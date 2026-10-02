# 2026R1 all-measure run: upgrade failure assessment and fix plan

Status log and resume pointer: [PROGRESS.md](PROGRESS.md). Written 2026-10-02.

## 1. Context

| Item | Value |
|---|---|
| Run | `sdr_2026r1_all_measure_10k` (10k buildings, 65 upgrades = the 2025R3 upgrade block, same names/options/order) |
| Simulated on | `comstock_eric.worktrees/spacetype_refactor` = `origin/spacetype_refactor` (the "Standards"/ComStock-Typical branch) |
| Postprocessed on | `ccaradon/calibration-qaqc` |
| Raw results | `s3://eulp/euss_com/0_production_runs_2026R1/tests/sdr_2026r1_all_measure_10k/sdr_2026r1_all_measure_10k/` (resbldg account 402490792549) |
| Gem on the run branch | `comstock-typical` pinned at `12f0b21a19be92c6a2c309358e8fef9c39b58162` (ComStock-Typical `fix_failures`, one commit behind its tip `bc3da23`) |
| Gem on 2025R3 | `openstudio-standards = 0.8.3` (tag `2025-3`) |
| Gem on `main` today | `openstudio-standards = 0.8.6` (0.8.5 since `4edfe42c`, 2026-02-26) |
| This work | branch `ccaradon/spacetype_refactor_measure_failures`, created from `origin/spacetype_refactor` @ `0e4c8084` with no upstream (never tracks main) |

Upgrade id to measure mapping comes from the verified 2025R3 crosswalk
(`temp_plan/upgrade_id_reconciliation/` on `ccaradon/measure-release-comparison`, commit `eb63c3e0`),
which also holds a reduced copy of the 2026R1 yml (`upgrade_blocks/2026r1_all_measure_10k_test.yml`).
Upgrade ids are 1-based yml positions. None of the failing upgrades carries an `apply_logic`;
applicability is decided inside each measure.

## 2. Findings per upgrade

"Fail" = measure raised or returned false. "Invalid" = the measure (or ApplyUpgrade) registered
Not Applicable; `resources/meta_measure.rb:247` rescues every exception into `registerError` and a
false return, so an Invalid can never hide a crash.

| id | yml name | measure dir | observed | root cause | class | R3 applicability |
|---|---|---|---|---|---|---|
| 14 | DOAS_HP_Minisplits | `upgrade_hvac_doas_hp_minisplits` | fail or invalid | `std.create_coil_cooling_dx_single_speed` (measure.rb:339), then `std.create_coil_heating_electric` (:345) and `std.create_fan_constant_volume` (:350) no longer exist on `Standard` | A | 212/416 |
| 22 | Advanced_RTU_Controls | `upgrade_advanced_rtu_control` | fail or invalid | `standard.fan_variable_volume_set_control_type(fan, 'Single Zone VAV Fan ')` at measure.rb:391. The `FanVariableVolume.new` / `setFanPowerMinimumFlowRateInputMethod` lines quoted in the failure summary are the six lines above the failing call, not the failure itself | A | 274/416 |
| 26 | Pmp | `upgrade_hvac_pump` ("VFD Pumps", OEDI `hvac_0029`) | all invalid | Measure registered NA (`no eligible pumps are found`) on every building. Latent: `std.pump_brake_horsepower` (measure.rb:144) is also gone, and it runs before the NA check, so any building with an eligible pump would have failed instead. Zero fails across 10k buildings means no `PumpConstantSpeed`/`PumpVariableSpeed` sat on a loop with a boiler, chiller, tower, district object or temperature source. Needs the S3 data and a baseline OSM to explain | B (+A latent) | 46/416 |
| 27 | Ideal_Thermal_Loads | `upgrade_hvac_enable_ideal_air_loads` | all fail | `std.remove_hvac(model)` at measure.rb:86 | A | 416/416 |
| 29 | Packaged_GHP | `upgrade_hvac_packaged_gshp` | fail or invalid | `std.fan_variable_volume_set_control_type(fan, 'Single Zone VAV Fan ')` at measure.rb:956 | A | 303/416 |
| 31 | Chiller_Replacement | `upgrade_hvac_chiller` | all invalid | Measure registered NA (`no chillers are found`) on every building; `chiller_specifications` runs on `model.getChillerElectricEIRs` before any `std` call, so no building in the sample had a `ChillerElectricEIR`. Latent: `std.pump_brake_horsepower` (measure.rb:159) | B (+A latent) | 3/416 |
| 43 | LED_Lighting | `upgrade_light_led` | all fail | `Space type 'X' does not have a prototype_lighting_space_type property assigned` (measure.rb:238). The property was set by `prototype_space_type_assignment` (measure.rb:121), which the branch's baseline workflow no longer runs. The check runs on every space type before the "already LED" check, so every building fails, applicable or not | C | 269/416 |
| 55 | Package_2 | `upgrade_light_led` + HP boiler + HP RTU | all fail | same as 43 | C | 358/416 |
| 56 | Package_3 | envelope x3 + `upgrade_light_led` + HP boiler + HP RTU | all fail | same as 43 | C | 416/416 |
| 57 | Package_4 | `upgrade_light_led` + HP boiler + HP RTU (standard performance) | all fail | same as 43 | C | 358/416 |
| 64 | Package_11 | hydronic / packaged / console GSHP with envelope + lighting | all fail | packaged: A (fan control type, as 29). All three: C, because `lighting=true` loads `../../upgrade_light_led/measure.rb` (`upgrade_hvac_packaged_gshp/resources/call_other_measures.rb:171`; hydronic and console use the same step) | A + C | 407/416 |

The observed pattern matches the R3 applicability column: 14/22/29 are "fail or invalid" because
the crash only happens on applicable buildings; 27 is "all fail" because it applies everywhere;
43/55/56/57/64 are "all fail" because the lighting error fires before the applicability check.
26 and 31 are the only true anomalies (11% and 0.7% applicable in R3, 0% here).

### Class A: openstudio-standards 0.8.5 removed `Standard` instance helpers (not a fork problem)

openstudio-standards moved its HVAC component helpers from `Standard` instance methods to
`OpenstudioStandards::HVAC` module functions. The instance methods still exist at upstream
`v0.8.4` and are gone at `v0.8.5` (checked with `git grep` in the local openstudio-standards
checkout). 2025R3 ran on 0.8.3. `main` moved to 0.8.5 on 2026-02-26 and to 0.8.6 in March,
so these six measures have been broken on `main` since February; the ComStock-Typical fork
(an openstudio-standards 0.8.6-era fork) just inherits the removal. The fork does ship every
replacement module function.

Audit (every `std.` / `standard.` / `standard_new_motor.` call in `resources/measures/upgrade_*`
checked against `def` names in the fork's `lib/`; the only `Standard.build` variable names in
upgrade measures are those three):

| call (old, on `Standard`) | measures | replacement in fork | notes |
|---|---|---|---|
| `create_coil_cooling_dx_single_speed(model, air_loop_node:, name:, type: 'PSZ-AC')` | doas_hp_minisplits:339 | `OpenstudioStandards::HVAC.create_coil_cooling_dx_single_speed(model, air_loop_node:, name:, schedule:, type:, cop:)` (`hvac/components/coil_cooling_dx_single_speed.rb:17`) | same keywords; `'PSZ-AC'` is a supported `type` |
| `create_coil_heating_electric(model, air_loop_node:, name:)` | doas_hp_minisplits:345 | `OpenstudioStandards::HVAC.create_coil_heating_electric(model, air_loop_node:, name:, schedule:, nominal_capacity:, efficiency:)` (`coil_heating_electric.rb:16`) | same keywords |
| `create_fan_constant_volume(model, fan_name:, pressure_rise:)` | doas_hp_minisplits:350 | `OpenstudioStandards::HVAC.create_fan_constant_volume(model, fan_name:, fan_efficiency:, pressure_rise:, motor_efficiency:, motor_in_airstream_fraction:, end_use_subcategory:)` (`fan.rb:45`) | same keywords |
| `remove_hvac(model)` | enable_ideal_air_loads:86 | `OpenstudioStandards::HVAC.remove_hvac(model)` (`hvac/helpers.rb:107`) | same semantics: keeps SWH loops and zone exhaust fans |
| `fan_variable_volume_set_control_type(fan, 'Single Zone VAV Fan ')` | advanced_rtu_control:391, packaged_gshp:956 | `OpenstudioStandards::HVAC.fan_variable_volume_set_control_type(fan, control_type: 'Single Zone VAV')` (`fan.rb:277`) | keyword arg now; see the behavior decision below |
| `pump_brake_horsepower(pump)` | hvac_pump:144, hvac_chiller:159 | `OpenstudioStandards::HVAC.pump_get_brake_horsepower(pump)` (`hvac/components/pump.rb:72`) | same formula (0.78 impeller efficiency) |

Audit false positives: `upgrade_df_load_shed` only mentions `model_standards_climate_zone` in a
comment (already migrated to `OpenstudioStandards::Weather.model_get_climate_zone`);
`upgrade_light_lighting_controls` uses `std.standards_data`, an `attr_reader`.

Behavior decision for the fan curve call: in 0.8.3 the string `'Single Zone VAV Fan '` matched
no case, so the method logged a warning, left the fan power coefficients at their OpenStudio
defaults and returned false (`Standards.FanVariableVolume.rb:71-73` at v0.8.3). Passing
`'Single Zone VAV'` to the new function applies the 90.1-2016 System 11 coefficients
(a=0.0278, b=0.0266, c=-0.0871, d=1.0309, minimum 10%), which changes Advanced RTU Controls
and Packaged GHP results relative to R3. Options: (1) parity, delete the call and leave a comment;
(2) intended behavior, pass `'Single Zone VAV'` and record it in the measure changelog. Needs the
measure owners' call; recommendation is (2), it is what the code meant to do.

### Class B: pump and chiller applicability (needs S3 evidence)

Both measures decide applicability from model contents, and both are NA on all 10k buildings.
Options tables (`param|option` pairs) are identical between `main` and the branch, so this is
not an options_lookup rename. Checks, in order:

1. `temp_plan/measure_failures_2026r1/s3_failure_summary.py` once SSO is live: confirm
   `completed_status` and `apply_upgrade.applicable` for 26 and 31, print the run's
   `hvac_system_type` distribution from `buildstock.csv`.
2. If the sample does contain boiler/chiller systems: pull one baseline datapoint's OSM
   (`simulation_output` tar) for a building with a boiler system and list its plant loops,
   supply components and pump object classes. Hypotheses: the typical HVAC builders put the
   loop pumps where the measure's filter does not look (e.g. `HeaderedPumps*`, found only for
   condenser water at `Prototype.hvac_systems.rb:553-556`), or the loops carry
   component classes the filter does not list, or (for 31) chillers are not `ChillerElectricEIR`.
3. If the sample contains no such systems, the 10k test sample is the explanation and the only
   needed fix is the latent class A call.

Either way, port `pump_brake_horsepower` first; nothing else can be tested until it is.

### Class C: LED lighting measure relies on the dropped prototype workflow

The branch's baseline workflow (per `resources/options_lookup.tsv`) no longer runs
`create_bar_from_building_type_ratios`, `create_typical_building_from_model`,
`prototype_space_type_assignment`, `set_interior_lighting_technology`,
`set_interior_lighting_bpr`, `set_electric_equipment_bpr` or
`add_thermostat_setpoint_variability`; `create_custom_building_from_spec` replaces them and
drives `OpenstudioStandards::InteriorLighting.create_typical_interior_lighting` with the
sampled `lighting_generation`. The fork stamps `lighting_space_type` on each space type
(`space_type/standards_space_type.rb:65`, values like `corridor_lighting`, 95 names) and
`lighting_technology` + `lighting_system_type` on each lights definition
(`interior_lighting/create_typical_interior_lighting.rb:132-216`). `prototype_lighting_space_type`
is never set, so `upgrade_light_led` errors on its first space type.

Fix options:

- **Option A (recommended): delegate to the gem.** Keep the measure's argument, its
  "already LED" applicability check (gem LED technology names all contain `LED`, so the
  existing `include?('LED')` test keeps working), and its before/after power reporting and
  `registerValue` outputs, but replace the per-space-type CSV lookup and
  `change_lighting_technology` with one call to
  `OpenstudioStandards::InteriorLighting.create_typical_interior_lighting(model, lighting_generation: lighting_generation)`.
  Same algorithm the baseline used, so a gen5 upgrade over a gen4 baseline is exactly the
  generation step. Caveats: the gem removes and recreates `Lights` objects (space-level lights
  included) and skips space types whose `lighting_space_type` is `na` with a warning; the measure
  should warn rather than error in that case. Test on a typical-built model, not the prototype
  test OSMs.
- **Option B (minimal patch):** read `lighting_space_type` instead of
  `prototype_lighting_space_type` and look rows up in the gem's
  `interior_lighting/data/lighting_space_types.json`. Field names differ
  (`lighting_space_type_target_illuminance_setpoint` in lux vs
  `total_horizontal_illuminance_lumens_per_ft2` in footcandles) so the LPD formula needs a unit
  conversion; duplicates gem logic in the measure.

`set_interior_lighting_technology` has the same error line (measure.rb:142) but is no longer in
the workflow; leave it. Fixing `upgrade_light_led` fixes 43, 55, 56, 57 and the lighting half of 64.

### Alternative for class A: a compatibility shim in the fork

ComStock-Typical could reopen `Standard` with the six old instance methods forwarding to the
module functions (one file, deprecation warnings). It would unbreak every unported measure at
once, including ones outside this run, but hides the migration. Recommendation: port the
measures explicitly (small, mechanical diffs) and decide separately whether the fork wants the
shim as a safety net.

## 3. Work breakdown

| step | what | depends on | owner / status |
|---|---|---|---|
| 1 | S3 diagnosis: run `s3_failure_summary.py`, paste the per-upgrade status and error counts into PROGRESS.md, confirm the class A tracebacks are `NoMethodError` on the calls above | resbldg SSO refresh | blocked |
| 2 | Port the seven class A call sites (one commit per measure); keep `std` for the instance methods that still exist (`fan_standard_minimum_motor_efficiency_and_size` etc.) | none | ready |
| 3 | Fan curve decision (parity vs `'Single Zone VAV'`) recorded in both measures | owner input | open |
| 4 | LED measure rewrite (option A) with a typical-built test model | 2 (shared bundle) | ready |
| 5 | Unit tests under OS 3.10.0 with the `resources/` bundle (`bundle exec rake unit_tests:upgrade_measure_tests`, or the seven test files directly); regenerate `measure.xml` only where arguments change and diff it, the 3.10 CLI drops JSON resource entries | 2, 4 | |
| 6 | Pump/chiller applicability: steps in class B; fix in the measure filter or the fork's builders, whichever the OSM shows | 1 | blocked |
| 7 | Rerun the 11 upgrades on a small sample on Kestrel; pass criteria: zero Fail, applicability fractions near the R3 column in section 2 | 2-6 | |
| 8 | PR from `ccaradon/spacetype_refactor_measure_failures` into `spacetype_refactor` (not main); flag that the class A fixes are needed on `main` too | 7 | |

## 4. Evidence trail

- `git grep -n -E "def (remove_hvac|create_coil_cooling_dx_single_speed|fan_variable_volume_set_control_type)\b" v0.8.4 -- lib` finds all three; the same at `v0.8.5` finds none (local openstudio-standards checkout).
- `git show 2025-3:resources/Gemfile` pins 0.8.3; `git log origin/main -- resources/Gemfile` shows 0.8.5 at `4edfe42c` (2026-02-26).
- Fork module functions: `git grep -n "def self\.<name>" 12f0b21a -- lib` in the ComStock-Typical checkout.
- Baseline workflow diff: measure dirs referenced by `resources/options_lookup.tsv` on `main` vs the branch (seven dropped, one added).
- Crosswalk: `reconciliation_2025_comstock_amy2018_release_3.csv` and `definition_diff_2026r1_10k_vs_2025r3.json` on `ccaradon/measure-release-comparison`.
