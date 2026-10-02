# 2026R1 all-measure run: upgrade failure assessment and fix plan

Status log and resume pointer: [PROGRESS.md](PROGRESS.md). Written 2026-10-02, updated the same
day with the S3 evidence. Per-upgrade S3 tables: [s3_failure_summary.md](s3_failure_summary.md)
(the eleven reported upgrades, full tracebacks) and [s3_all_upgrades_scan.md](s3_all_upgrades_scan.md)
(all 65 upgrades: Success / Invalid / Fail counts and failure signatures).

## 1. Context

| Item | Value |
|---|---|
| Run | `sdr_2026r1_all_measure_10k`: 8,634 buildings, 65 upgrades = the 2025R3 upgrade block (same names, options, order) |
| Simulated on | `comstock_eric.worktrees/spacetype_refactor` = `origin/spacetype_refactor` (the "Standards"/ComStock-Typical branch) |
| Postprocessed on | `ccaradon/calibration-qaqc` |
| Raw results | `s3://eulp/euss_com/0_production_runs_2026R1/tests/sdr_2026r1_all_measure_10k/sdr_2026r1_all_measure_10k/` (resbldg account 402490792549). Prefixes: `baseline/`, `buildstock_csv/`, `metadata_and_annual_results_aggregates/`, `timeseries/`, `upgrades/upgrade=N/results_upNN.parquet`. No simulation-output tars: OSMs, run logs and eplusout.err files are on Kestrel only (down on 2026-10-02) |
| Gem on the run branch | `comstock-typical` pinned at `12f0b21a19be92c6a2c309358e8fef9c39b58162` (ComStock-Typical `fix_failures`, one commit behind its tip `bc3da23`) |
| Gem on 2025R3 | `openstudio-standards = 0.8.3` (tag `2025-3`) |
| Gem on `main` today | `openstudio-standards = 0.8.6` (0.8.5 since `4edfe42c`, 2026-02-26) |
| This work | branch `ccaradon/spacetype_refactor_measure_failures`, created from `origin/spacetype_refactor` @ `0e4c8084` with no upstream (never tracks main) |

Upgrade id to measure mapping comes from the verified 2025R3 crosswalk
(`temp_plan/upgrade_id_reconciliation/` on `ccaradon/measure-release-comparison`, commit `eb63c3e0`),
which also holds a reduced copy of the 2026R1 yml (`upgrade_blocks/2026r1_all_measure_10k_test.yml`).
Upgrade ids are 1-based yml positions. None of the failing upgrades carries an `apply_logic`;
applicability is decided inside each measure.

Status semantics: "Fail" = a measure raised or returned false, or the simulation failed.
"Invalid" = the measure (or ApplyUpgrade) registered Not Applicable. `resources/meta_measure.rb:247`
rescues every exception into `registerError` plus a false return, so an Invalid never hides a crash.
That rescue logs only `e.backtrace`, not `e.message`, which is why the parquet `step_failures`
column shows file:line but never the exception text (see section 5).

## 2. Findings per upgrade (S3 counts, 8,634 buildings each)

| id | yml name | measure dir | Success / Invalid / Fail | failure signature (count) | class | reached the crash | R3 applicable |
|---|---|---|---|---|---|---|---|
| 14 | DOAS_HP_Minisplits | `upgrade_hvac_doas_hp_minisplits` | 0 / 6,736 / 1,898 | measure.rb:339 (1,896) | A | 22% | 51% |
| 22 | Advanced_RTU_Controls | `upgrade_advanced_rtu_control` | 0 / 4,487 / 4,147 | measure.rb:391 (4,145) | A | 48% | 66% |
| 26 | Pmp ("VFD Pumps", OEDI `hvac_0029`) | `upgrade_hvac_pump` | 0 / 6,120 / 2,514 | measure.rb:144 in `pump_specifications` (2,512) | A | 29% | 11% |
| 27 | Ideal_Thermal_Loads | `upgrade_hvac_enable_ideal_air_loads` | 0 / 0 / 8,634 | measure.rb:86 (8,632) | A | 100% | 100% |
| 29 | Packaged_GHP | `upgrade_hvac_packaged_gshp` | 0 / 3,140 / 5,494 | measure.rb:956 (5,407); :866 (51); :874 (32); :941 (2) | A + D | 64% | 73% |
| 31 | Chiller_Replacement | `upgrade_hvac_chiller` | 0 / 7,471 / 1,163 | measure.rb:159 in `pump_specifications` (1,161) | A | 13% (a) | 0.7% |
| 43 | LED_Lighting | `upgrade_light_led` | 0 / 0 / 8,634 | `Space type '<name>' does not have a prototype_lighting_space_type property assigned` (8,632) | C | 100% | 65% |
| 55 | Package_2 | `upgrade_light_led` + HP boiler + HP RTU | 0 / 0 / 8,634 | same lighting error (8,632) | C | 100% | 86% |
| 56 | Package_3 | envelope x3 + `upgrade_light_led` + HP boiler + HP RTU | 0 / 0 / 8,634 | same lighting error (8,632) | C | 100% | 100% |
| 57 | Package_4 | `upgrade_light_led` + HP boiler + HP RTU (standard performance) | 0 / 0 / 8,634 | same lighting error (8,632) | C | 100% | 86% |
| 59 | Package_6 (not in the original summary) | hydronic / packaged / console GSHP, no envelope, no lighting | 2,314 / 743 / 5,577 | packaged_gshp:956 (5,407); hydronic_gshp:443 (69); packaged_gshp:866 (35); :874 (26); simulation-side (36) | A + D | 65% | 98% |
| 63 | Package_10 (not in the original summary) | the three GSHPs with envelope, no lighting | 2,332 / 730 / 5,572 | packaged_gshp:956 (5,406); hydronic_gshp:443 (69); packaged_gshp:866 (35); :874 (24); simulation-side (30) | A + D | 65% | 99% |
| 64 | Package_11 | the three GSHPs with envelope and lighting | 0 / 594 / 8,040 | packaged_gshp:956 (5,405); lighting error via `call_lighting` (2,499); hydronic_gshp:443 (69); packaged_gshp:866 (35); :874 (25); wall_insulation:215 (3); :941 (2) | A + C + D | 93% | 98% |

Every upgrade also carries the two baseline failures (buildings 2537 and 7223, section 4).
"Reached the crash" is Fail at the class A or C line divided by 8,634; (a) for 31 the crash sits
in the pump loop that runs before the chiller count, so 13% is "buildings with a pump on a hydronic
loop", not chiller applicability. The original summary's "all invalid" for 26 and 31 was wrong:
both fail on every building that has an eligible pump and are Invalid on the rest, like 14, 22 and 29.
The shifts between "reached the crash" and the R3 applicability column (14: 51% to 22%, 22: 66% to
48%, 26: 11% to 29%) are applicability changes on the typical models to re-check after the port.

### Class A: openstudio-standards 0.8.5 removed `Standard` instance helpers (not a fork problem)

openstudio-standards moved its HVAC component helpers from `Standard` instance methods to
`OpenstudioStandards::HVAC` module functions. The instance methods still exist at upstream
`v0.8.4` and are gone at `v0.8.5` (checked with `git grep` in the local openstudio-standards
checkout). 2025R3 ran on 0.8.3. `main` moved to 0.8.5 on 2026-02-26 and to 0.8.6 in March,
so these six measures have been broken on `main` since February; the ComStock-Typical fork
(an openstudio-standards 0.8.6-era fork) just inherits the removal. The fork ships every
replacement module function. The S3 backtraces confirm all seven call sites exactly.

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
and the packaged GSHP results relative to R3. Options: (1) parity, delete the call and leave a
comment; (2) intended behavior, pass `'Single Zone VAV'` and record it in the measure changelog.
Needs the measure owners' call; recommendation is (2), it is what the code meant to do.

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
is never set, so `upgrade_light_led` errors on its first space type (S3: the first space type
is `office` for 1,641 buildings, `retail` 1,211, `corridor` 897, and so on).

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
the workflow; leave it. Fixing `upgrade_light_led` fixes 43, 55, 56, 57 and the lighting part of 64
(`upgrade_hvac_packaged_gshp/resources/call_other_measures.rb:171` loads
`../../upgrade_light_led/measure.rb`; hydronic and console use the same step).

### Class D: secondary failures that survive the class A and C fixes

Small counts, found by the full scan. Items marked **Kestrel** need the datapoint's OSM, run.log
or eplusout.err from Kestrel (down on 2026-10-02); the rest can be fixed from code.

| where | count | cause from code | action |
|---|---|---|---|
| `upgrade_hvac_packaged_gshp` measure.rb:866 and :874 `air_loop_hvac.setAvailabilitySchedule(zone_data["<zone> schedule"])` | 51 + 32 in 29; 35 + 26 in 59; 35 + 24 in 63; 35 + 25 in 64 | `zone_data` is only filled for zones on the PVAV / PSZ loops the measure inventories (measure.rb:567-568, :691, :739); a conditioned zone served by anything else has no entry, so the schedule is nil and the SWIG call raises. Candidates: the fork's new separate systems for extreme-load zones and CRAC/CRAH units (ComStock-Typical `79853e6`) | **Kestrel**: pull one failing OSM, list the zone's equipment; then either skip such zones like `zones_to_skip` or inventory their loops |
| `upgrade_hvac_packaged_gshp` measure.rb:941 `zone_data[thermal_zone.name.to_s]['pressure_rise']` | 2 in 29, 2 in 64 | same root: no `zone_data` entry for the zone (nil receiver) | same as above |
| `upgrade_hvac_hydronic_gshp` measure.rb:443 `unit.supplyAirFlowRateMethodDuringHeatingOperation.get` | 69 in 28, 59, 63, 64 | `.get` on an empty optional: some `AirLoopHVACUnitarySystem` objects in the typical models leave the heating flow method blank | guard with `is_initialized` and set `'SupplyAirFlowRate'` when blank (the code's own intent); **Kestrel** only to confirm which units |
| `upgrade_env_exterior_wall_insulation` measure.rb:215 `surface.setConstruction(nil)` | 3 in 48, 3 in 54, 3 in 64 | an exterior wall carries a construction absent from `old_to_new_construction_map`, so the map returns nil | `next` with a warning when the map has no entry; **Kestrel** to see which construction (likely a hard-assigned one the mapping loop skips) |
| `upgrade_hvac_console_gshp` "Sizing run failed" | 2 in 30 | sizing run inside the measure | **Kestrel**: sizing-run eplusout.err |
| `upgrade_add_pvwatts` "Battery storage parameters not found for building type 'RetailStripmall'" | 601 in 47 (every strip mall) | `resources/deer_t24_2022.battery_storage_system.json` spells it `RetailStripMall`; `model_find_object` matches exactly; `main`'s workflow also passes `RetailStripmall`, so this is probably pre-existing (R3's published rows cannot show it because failed datapoints are dropped) | add a `RetailStripmall` row to the JSON (or match case-insensitively); check an R3 strip mall with battery if parity matters |
| `utility_bills` reporting measure, "Error running PySAM ... elec_rates/6452/5a5e50dd5457a3e16be429d4.json" | 16 in 47 (buildings 148, 313, 354, 630, 1837, 2234, 2342, 2406, 2431, 2619, 4047, 4094, ...) | PySAM bill calculation fails on the PV + battery hourly profile with that one rate | hand to the utility-bills owner; **Kestrel** for `electricity_hourly.csv` of one datapoint |
| Fail with no measure error (simulation-side) | 11 each in 12 and 13 (VRF), 2 in 23, 32 in 28, 2 in 30, 1 in 48, 36 in 59, 30 in 63 | EnergyPlus fatal errors; `step_failures` is null | **Kestrel**: eplusout.err; not gem-related |

## 3. Work breakdown

| step | what | depends on | status |
|---|---|---|---|
| 1 | S3 diagnosis: per-upgrade status counts, backtraces, full 65-upgrade scan | SSO | done 2026-10-02 |
| 2 | Port the seven class A call sites (one commit per measure); keep `std` for the instance methods that still exist (`fan_standard_minimum_motor_efficiency_and_size` etc.) | none | ready |
| 3 | Fan curve decision (parity vs `'Single Zone VAV'`) recorded in both measures | owner input | open |
| 4 | LED measure rewrite (option A) with a typical-built test model | 2 (shared bundle) | ready |
| 5 | Class D code-side guards: hydronic_gshp:443, wall_insulation:215, battery JSON spelling | none | ready |
| 6 | Unit tests under OS 3.10.0 with the `resources/` bundle (`bundle exec rake unit_tests:upgrade_measure_tests`, or the seven test files directly); regenerate `measure.xml` only where arguments change and diff it, the 3.10 CLI drops JSON resource entries | 2, 4, 5 | |
| 7 | Kestrel items: packaged_gshp zone_data zones (one OSM), console GSHP sizing run, simulation-side fails (eplusout.err), baseline failures 2537 and 7223 (run.log), PySAM datapoint | Kestrel back | blocked |
| 8 | Rerun the affected upgrades (14, 22, 26, 27, 29, 31, 43, 47, 55, 56, 57, 59, 63, 64) on a small sample on Kestrel; pass criteria: Fail limited to the Kestrel items of section 2, applicability fractions explained against the R3 column | 2-7 | blocked |
| 9 | PR from `ccaradon/spacetype_refactor_measure_failures` into `spacetype_refactor` (not main); flag that the class A fixes and the battery JSON are needed on `main` too | 8 | |

## 4. Baseline failures (not this branch's scope, for the fork owner)

Two of 8,634 buildings fail in `create_custom_building_from_spec` ("failed, see previous errors"),
so every upgrade inherits two Fail rows: building 2537 (small_hotel, PTHP, 1998, county G3700190,
climate zone 3A, gen2_t8_halogen) and 7223 (primary_school, PVAV with gas boiler reheat, 1955,
county G4400070, 5A, gen4_led). The error text is in the Kestrel run.log only.

## 5. Side item: log the exception message

`resources/meta_measure.rb:248` writes `"Measure Failed with Error: #{e.backtrace.join("\n")}"`.
Adding `e.class` and `e.message` in front of the backtrace would have made every class A failure
self-explanatory in the parquet (`NoMethodError: undefined method 'remove_hvac' for
#<ComStock901_2019 ...>`). One-line change, own PR to main.

## 6. Alternative for class A: a compatibility shim in the fork

ComStock-Typical could reopen `Standard` with the six old instance methods forwarding to the
module functions (one file, deprecation warnings). It would unbreak every unported measure at
once, including ones outside this run, but hides the migration. Recommendation: port the
measures explicitly (small, mechanical diffs) and decide separately whether the fork wants the
shim as a safety net.

## 7. Evidence trail

- `git grep -n -E "def (remove_hvac|create_coil_cooling_dx_single_speed|fan_variable_volume_set_control_type)\b" v0.8.4 -- lib` finds all three; the same at `v0.8.5` finds none (local openstudio-standards checkout).
- `git show 2025-3:resources/Gemfile` pins 0.8.3; `git log origin/main -- resources/Gemfile` shows 0.8.5 at `4edfe42c` (2026-02-26).
- Fork module functions: `git grep -n "def self\.<name>" 12f0b21a -- lib` in the ComStock-Typical checkout.
- Baseline workflow diff: measure dirs referenced by `resources/options_lookup.tsv` on `main` vs the branch (seven dropped, one added); `param|option` pairs identical.
- Crosswalk: `reconciliation_2025_comstock_amy2018_release_3.csv` and `definition_diff_2026r1_10k_vs_2025r3.json` on `ccaradon/measure-release-comparison`.
- S3: `s3_failure_summary.py` (eleven upgrades, full backtraces, buildstock `hvac_system_type` distribution) and `s3_all_upgrades_scan.py` (all 65 upgrades via ranged column reads); outputs `s3_failure_summary.md` and `s3_all_upgrades_scan.md` next to them.
