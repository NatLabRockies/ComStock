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
| This work | branch `ccaradon/spacetype_refactor_measure_failures`, created from `origin/spacetype_refactor` @ `0e4c8084` with no upstream (never tracks main). The owner commits, pushes, and approves and runs any buildstockbatch yml; the only Kestrel jobs run by me are Slurm extraction jobs |

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
Applied provisionally as (2) in `ad147d38`; a comment at both call sites gives the parity alternative (delete the call). The owners of Advanced RTU Controls and the packaged GSHP should confirm. In favour of (2): the stock PSZ-HP prototype test model's variable-volume fans already carry these coefficients (17 of 17), so the upgrade now matches what the baseline builders set.

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

Fix applied (commit `ad147d38`, option B below): the measure now reads `lighting_space_type` and
looks the row up in the gem's `lighting_space_types.json`, found from the loaded gem's own file
path, converting the lux target to footcandles so the existing LPD math is unchanged; prototype
models keep the CSV path; space types with no lighting data (`na`) are skipped with a warning
instead of failing the building. The measure's `lighting_technology.csv` is byte-for-byte the
gem's `lighting_technology.json`, so it was kept. Option B was chosen over A because it edits the
existing lights definitions in place (schedules, multipliers and fractions untouched), which is
what the measure always did; A would recreate the `Lights` objects.

Fix options considered:

- **Option A: delegate to the gem.** Keep the measure's argument, its
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

| where | count | cause from code | action | status |
|---|---|---|---|---|
| `upgrade_hvac_packaged_gshp` measure.rb:866 and :874 `air_loop_hvac.setAvailabilitySchedule(zone_data["<zone> schedule"])` | 51 + 32 in 29; 35 + 26 in 59; 35 + 24 in 63; 35 + 25 in 64 | `zone_data` is only filled for zones on the PVAV / PSZ loops the measure inventories (measure.rb:567-568, :691). Single-zone loops skipped as DOAS, residential, no-outdoor-air or evaporative, and zones on PTAC/PTHP/WSHP equipment, are never added to `zones_to_skip`, so a building that mixes them with one PSZ-classified loop passes the "no applicable loops" check and crashes on those zones. The S3 characteristics confirm the mix: :866 is DOAS + WSHP (21) and residential furnace (10) buildings, :874 is PTHP (12) and PTAC (11) buildings, all of which were not-applicable in 2025R3 because prototype models had one system type per building | guard before the zone loop: not applicable with the zone list when any conditioned zone has no inventory entry (the measure replaces the whole system and removes the plant loops, so it cannot leave those zones in place). Verified on a PSZ-HP prototype model with one zone moved to a PTAC: NA in 1 s. The guard runs after the inventory has already stripped the PSZ loop components; harmless since Invalid datapoints are not simulated, but a pre-inventory version of the check would be cleaner (follow-up). **Kestrel** later if the owners want to replace those extra loops instead of NA | applied `ad147d38` |
| `upgrade_hvac_packaged_gshp` measure.rb:941 `zone_data[thermal_zone.name.to_s]['pressure_rise']` | 2 in 29, 1 in 59, 2 in 63, 2 in 64 | a PSZ-classified loop that is not a unitary system gets a schedule entry (:691) but no data hash (:739 is inside the unitary branch) | covered by the same guard (it requires both keys) | applied `ad147d38` |
| `upgrade_hvac_hydronic_gshp` measure.rb:443 `unit.supplyAirFlowRateMethodDuringHeatingOperation.get` | 69 in 28, 59, 63, 64 (large offices 40, medium offices 14, outpatient 8, large hotels 7; chiller + boiler systems) | the getter returns a plain String in OpenStudio 3.7+ (`'None'` when unset), so `.get` raises on every model with a unitary system (the typical CRAC and DOAS units); the first guard in `ad147d38` assumed an optional and raised too | accept both shapes (`respond_to?(:is_initialized)`); verified on the pulled 1062 model | applied, revised (uncommitted) |
| `upgrade_env_exterior_wall_insulation` measure.rb:215 `surface.setConstruction(nil)` | 3 in 48, 54, 64 (buildings 195, 755, 884: warehouses built 2016-2017 in CEC9/10/13) | the measure maps only constructions it decides to insulate (skips metal building, already at target, thin insulation, no standards type), then assigns the map's value to every exterior wall; a model with two wall constructions where one was skipped gets nil | leave such walls unchanged with an info message | applied `ad147d38` |
| `upgrade_hvac_console_gshp` "Sizing run failed" | 2 in 30, 1 in 59 and 63 (buildings 2692, 7749: large hotels, PTAC with electric coil, 1A and 6A) | sizing run inside the measure | **Kestrel**: sizing-run eplusout.err | open |
| `upgrade_add_pvwatts` "Battery storage parameters not found for building type 'RetailStripmall'" | 601 in 47 (every strip mall) | `resources/deer_t24_2022.battery_storage_system.json` spells it `RetailStripMall`; `model_find_object` matches exactly; `main`'s workflow also passes `RetailStripmall`, so this is probably pre-existing (R3's published rows cannot show it because failed datapoints are dropped) | `RetailStripmall` row added with the `RetailStripMall` values | applied `ad147d38` |
| `utility_bills` reporting measure, "Error running PySAM ... elec_rates/6452/5a5e50dd5457a3e16be429d4.json" | 16 in 47 (buildings 148, 313, 354, 630, 1837, 2234, 2342, 2406, 2431, 2619, 4047, 4094, ...) | `ElectricityPurchased:Facility` is 0.0 in all 8,760 hours for these PV + battery warehouses (a genuine no-purchase year, pulled datapoint 47/148). The failure is not in PySAM: `calc_elec_bill.py` divides the annual cost by the total kWh for an average rate, raising `ZeroDivisionError` inside a bare `except` that prints only "PySAM error", and the measure fails the whole datapoint. Reproduced with NREL-PySAM 4.2.0 (venv `C:/tmp/pysam42`); with the division guarded PySAM bills the zero profile as the fixed charges alone ($7,267 = 12 x $605.62 on that rate), energy and demand charges 0 | guard the division and report the exception text (`measures/utility_bills/resources/calc_elec_bill.py`), so a no-purchase year bills its fixed charges as the owner intended; for the utility-bills owner to review | applied (uncommitted) |
| Fail with no measure error (simulation-side) | 11 each in 12 and 13 (VRF), 2 in 23, 32 in 28, 2 in 30, 1 in 48, 36 in 59, 30 in 63 | EnergyPlus fatal errors; `step_failures` is null | **Kestrel**: eplusout.err; see the cluster notes below | open |

### Smaller clusters, resolved with the Kestrel datapoints (2026-10-03)

One datapoint per cluster was pulled from the run tarballs (PROGRESS.md log of 2026-10-03; local
copy under `C:/tmp/mf2026r1/<upNN>/<bldgNNNNNNN>/run/data_point/`, with `in.osm` the final model
and `eplusout.err` the EnergyPlus log). What the files show:

| cluster | datapoints read | cause | action | status |
|---|---|---|---|---|
| VRF with DOAS (12, 13): 11 large offices each | 12/3145, 12/3701 | The typical large offices give their data-center zones (datacenter/high ite at 1,078 W/m2 of IT load, up to 192 kW in one zone) dedicated single-zone CRAC air loops. The VRF measure treats a CRAC like any single-zone loop with outdoor air, removes it and puts a VRF terminal plus DOAS on the zone; EnergyPlus diverges (surface temperatures of -11,673 C in `ZONE DATACENTER/HIGH ITE B`). The DOE prototypes never had such zones. | VRF measure: skip any loop named CRAC/CRAH or serving a zone where the fork's `OpenstudioStandards::HVAC.thermal_zone_data_center?` is true (zones of skipped loops keep their system). Verified on the pulled 3145 model: Success, 51 zones on VRF instead of 57, all six CRAC loops kept; the upgraded model completes an annual EnergyPlus run locally with 0 severe errors | applied (uncommitted) |
| Hydronic GSHP `:443` (69 buildings) | 28/1062 | `AirLoopHVACUnitarySystem#supplyAirFlowRateMethodDuringHeatingOperation` returns a plain String in OpenStudio 3.7+ (`'None'` when unset), so the measure's `.get` raised on every model with a unitary system (the typical models' CRAC and DOAS units). My first guard (`is_initialized`) failed the same way on the typical model. | accept both API shapes; verified on the pulled 1062 model: Success with GHEDesigner, boilers replaced. Owner question: the `flowmethod == ''` branch never fires on 3.10 because the unset value is `'None'` | applied (uncommitted) |
| Hydronic GSHP simulation-side (32: schools, hospitals) | 28/2419, 28/2552 | `Plant temperatures are getting far too cold` on the measure's own `CONDENSER LOOP` (the ground loop it builds); 2552 also logs an unbalanced VAV air loop in the measure's annual GHE loads run | measure owner: condenser-loop control or capacity on chiller + boiler schools; nothing gem-related. The packaged GSHP shows the same loop running cold as a recurring warning (24 million warnings in the annual run of the upgraded 6252 model), so one fix likely serves all three GSHP measures | **owner** |
| Console GSHP (30): 2 sizing-run, 2 simulation-side | 30/1046, 30/2692, 30/7749 | the same `CONDENSER LOOP` runaway (too hot in 1046 and 2692, too cold in 7749), inside the measure's annual GHE loads run for the two "sizing run failed" cases | measure owner, same note as hydronic | **owner** |
| Wall insulation simulation-side (1) | 48/5552 | `Plant temperatures are getting far too hot` on the baseline `HEAT PUMP LOOP` (the typical DOAS + water-source heat pump loop with tower and boiler) after the envelope change; the baseline itself simulated | fork owner: the WSHP condenser loop control is fragile to load changes; not a wall-insulation defect | **Eric** |
| Unoccupied AHU control (23): 2 CEC4 offices | 23/4084, 23/8613 | numerical divergence at the first unoccupied night (`DualSetPointWithDeadBand`, setpoints reported as 1e+150 and 2e-307, top-story corridor/office zones, 01/08 00:00). Both models carry the fork's optimum-start managers (12 and 8) and the measure's night fan-cycling tripled the night-cycle managers (6 to 18 in 4084). | local reproduction with the run's `G0600850.epw`: completes the full year with 0 severe errors (same EnergyPlus 25.1.0-1c11a3d85f build as the run, 4 min), and so does the production `in.idf` itself run straight through the local EnergyPlus; the production and local IDFs differ only in meter and output-variable objects; the same model with the fork's optimum-start managers removed: also completes with 0 severe errors, so the hypothesis cannot be tested locally; the divergence is a marginal numerical instability (2 of 3,811 applicable buildings) that shows on the Linux build and not on Windows with identical inputs | **owner, low priority**: not reproducible locally; if it recurs in the rerun, try tighter convergence settings or more timesteps on those two models |
| Baseline failure 2537 (small hotel, PTHP) | 00/2537 | the fork's create-typical sizing run: `SizeUnitarySystem: ZoneHVAC:PackagedTerminalHeatPump = ZONE RESTROOM B ... Unable to determine fan air flow rate`; a ground-floor restroom with zero design load. ComStock-Typical `01d805a` fixed the same symptom for residential AC loops (DesignDayWithLimit) but not for PTHP/PTAC zone equipment | **Eric**: extend the zero-load floor to packaged terminal zone equipment | parked: may be fixed in a newer ComStock-Typical (owner, 2026-10-03) |
| Baseline failure 7223 (2,000 ft2 primary school) | 00/7223 | the fork's custom-geometry stage fails its own floor-area check after bar slicing (classroom 1,260 vs 1,316 ft2, corridor 367 vs 383, restroom 137 vs 65); also `Space type properties lookup failed ... building_type=>nil` warnings | **Eric**: area tolerance or slicing for very small buildings | parked: may be fixed in a newer ComStock-Typical (owner, 2026-10-03) |
| Packaged GSHP `:866/:874/:941` | 29/112, 29/345, 29/6252 and their baselines | confirmed mixed systems: 112 is DOAS + WSHP with a separate single-zone unit for an extreme-load zone, 345 is PTHP with one such unit, 6252 is a large office whose CRAC loops are single-zone but not unitary (no `zone_data` hash) | data-center zones are now determined up front (fork helper `thermal_zone_data_center?`, loop name CRAC/CRAH as fallback), added to `zones_to_skip`, their zone equipment kept and their loop left out of the inventory, so the measure proceeds with the building's PSZ/PVAV loops; the not-applicable guard stays for zones on systems the measure does not replace (DOAS + WSHP, PTAC/PTHP with a stray unit). Verified on the pulled models: 112 and 345 still NA, 6252: Success (49 min, mostly the measure's annual ground-loop simulation): 3 PVAVs replaced with packaged GSHPs serving 54 zones, GHEDesigner ran, all 6 CRAC loops kept | applied (uncommitted) |
| LED on typical models | 00/1 | - | verified on the pulled model 1: Success, 2,248 W to 1,315 W for gen5 (1.12 to 0.66 W/ft2) | verified |
| Wall insulation `:215` | 00/195 | the typical models carry one derated `... c tbd` construction per wall (thermal bridging), so a warehouse has a dozen wall constructions; twelve were skipped as needing under 0.5 in and the old code assigned nil to them | the guard; verified on the pulled 195 model: Success, 864 ft2 insulated, twelve walls left unchanged | verified |

Also seen: every datapoint's run.log carries eight "Could not find options for a parameter" lines from
ApplyUpgrade; they are expected for upgrade parameters and not errors. Baseline 6252 ran with a
non-fatal `CheckAirLoopFlowBalance` severe on its PVAV loop.

### Rerun findings (2026-10-04, `rerun_all_upgrades_scan.md`, `rerun_compare.md`)

| item | cause | action | status |
|---|---|---|---|
| hydronic GSHP measure.rb:756 (31 offices with chillers) | `chw_loop` only assigned when the measure created a chilled-water loop; the unitary-system conversion also assumed PSZ units | reuse the existing loop, skip CRAC units, guard the coil assumptions; the next line (848) then failed on chilled-water coils inside CRAH and fan-coil units, now skipped | applied (uncommitted); the two pulled offices (1544, 1585) and the regressions (2419, 1062) all run |
| ideal air loads, 4 warehouses, "duplicate node names" | `<zone> Ideal Loads Air System` exceeds EnergyPlus's 100-character name limit for typical warehouse zone names, so the node names built from it collide | rename objects `Ideal Loads <n> <zone>[0,55]`, index first | applied (uncommitted); pulled warehouse 1652 simulates |
| packaged GSHP, 8 simulation-side | condenser-loop runaway, same as hydronic and console | owner (condenser loop) | **owner** |
| Package_3, 7 DOAS fan-coil buildings, "Autosizing of heating coil UA failed" | envelope upgrades plus the heat-pump boiler's 140 F setpoint leave corridor fan-coil heating coils with no design load | owner of the heat-pump boiler measure: minimum coil capacity or keep the setpoint on fan-coil systems | **owner** |
| applicability shifts vs R3 (DOAS minisplits 14% vs 51%, advanced RTU 42% vs 66%, pumps 29% vs 11%, ...) | not a shift: the R3 reference values were county-replicated row fractions of the published table. By distinct building the published R3 sample and the 10k run agree within 3 points on every measure (minisplits 19% vs 22%, advanced RTU 46% vs 48%, pumps 27% vs 29%) and have the same HVAC mix; per system type and floor-area bin the typical and prototype models give the same applicability | none; `rerun_applicability_tally.md` | done |

### Owner items: evidence and hypotheses (2026-10-04)

| item | evidence | hypothesis / what to do |
|---|---|---|
| GSHP condenser-loop runaways (hydronic 24, packaged 8, console 2 in the rerun) | Every fatal is EnergyPlus's `CheckForRunawayPlantTemps` on the measure's own `CONDENSER LOOP` / `GROUND LOOP`, which fires only when the loop outlet is more than 100 K beyond the loop limit the measure sets (10 C minimum), i.e. a collapse, not a few degrees of undershoot. GHEDesigner's own 20-year simulation of the same hourly loads (`SimulationSummary.json`) says the fields it sized are fine: minimum heat pump entering temperature 5.0 C (packaged 8, 12 boreholes; hydronic 2552, 1,156 boreholes), 11-17 C (packaged 183, console 1046). The loads are heating-dominated (extraction 1.0-26x rejection). The loops are coupled by an `Ideal`, `UncontrolledOn` fluid-to-fluid heat exchanger, so both loops fall together; the water-to-air / water-to-water equation-fit coils have no low source temperature cutoff and extrapolate below the fitted range | The borefield size is not the problem; the plant model is. First step (EnergyPlus's own advice): rerun one case to the day before the fatal with node reports on both loops (temperatures, flows, HX heat transfer, heat pump source-side flow) and see whether the decline is gradual (loads above what the loads run fed GHEDesigner, e.g. because that run used a fixed-temperature source) or a step (flow or control). Robustness either way: a hybrid backup on the condenser loop (boiler at the low setpoint, fluid cooler at the high one, standard practice for imbalanced loads) bounds the loop and turns fatals into reported backup energy; a low-temperature cutoff on the heat pumps would mask it. Packaged and console must be re-judged after the g-function fix below, which changes their ground response entirely |
| Packaged and console GSHP g-functions all zero (new, fixed uncommitted) | both measures read GHEDesigner's `Gfunction.csv` with `r['H:79.59']`, a column name from one test run; GHEDesigner names the column after the borehole length (`H:118.85`), so the lookup was nil and `nil.to_f` wrote 0.0 into all 56 pairs of `GroundHeatExchanger:Vertical` (local packaged run on 6252: 0 of 56 nonzero; hydronic, patched to `r[1]`, 56 of 56). With g = 0 the borehole wall never leaves the undisturbed ground temperature: the ground loop was an infinite source/sink in every packaged and console GSHP result, 2025R3 included | fixed: pick the first `H:` header that is not `_bhw`, the column the hydronic measure already reads (`r[1]`); retest on 6252 Success with 56 of 56 nonzero g values. The container's GHEDesigner also writes an `H:<length>_bhw` column (near zero at short times, so a borehole-wall g-function), which the local GHEDesigner 1.0 does not; owners to confirm which one EnergyPlus should get, for all three GSHP measures. Owners: the published packaged and console GSHP savings are optimistic; the runaway counts for those two measures will change with a real ground response |
| Package_3, 7 DOAS fan-coil buildings | `Coil:Heating:Water ... FCU HEATING COIL`: design coil load 102 W, design coil capacity 0 W, "Inadequate water side capacity in Plant Sizing for this hot water loop: increase design loop exit temperature and/or decrease design loop delta T" (exit 60 C, delta T 11.1 K). The heat-pump boiler measure lowers the hot water `Sizing:Plant` exit temperature to 60 C but keeps the gas boiler loop's 11.1 K design delta T, so the design return water (49 C) is below what the fan-coil coils must deliver; the envelope upgrades shrink the corridor loads to ~100 W and the UA solve fails | verified locally: the pulled 48 (rerun id; original 1585) `in.idf` fails in 1.4 s as-is (sizing periods only) and completes with the hot water loop delta T set to 5.6 K, no UA error (`C:/tmp/typ_runs/pkg3_48`). Fix for the heat-pump boiler measure: set the hot water `Sizing:Plant` delta T to ~5.6 K (10 F) when it lowers the supply temperature |
| Unoccupied AHU control, 8613 | fails at 01/08 00:00 in `ZONE OFFICE A - STORY TOP` with `DualSetPointWithDeadBand: heating set-point higher than cooling set-point` and setpoints of 6e+161 / 1.5e-154: uninitialised numbers, not a thermal divergence. The zone's thermostat schedules are complete (Schedule:Year, two week rules covering the year), no EMS touches setpoints (the fork's three `DamperStuckOverride` programs act on OA fractions); the loops carry the fork's `AvailabilityManager:OptimumStart` managers (8) whose applicability schedule is now the measure's `_night_fancycle_novent_schedule`. EnergyPlus's optimum start overrides a zone's setpoints with the "occupied" setpoints it looked up when it decides a pre-start period is active; with the measure's night fan-cycling schedule the manager can set the flag without a valid lookup, which is exactly a garbage setpoint at midnight. Same IDF completes locally: uninitialised memory behaves differently per machine, which also explains why 4084 "passed" after unrelated changes | in the unoccupied measure, when the loop availability becomes the night-cycling schedule, leave optimum start on the original occupied schedule or remove the optimum-start managers from those loops; report the IDF to EnergyPlus (deterministic in the container) |

## 3. Work breakdown

| step | what | depends on | status |
|---|---|---|---|
| 1 | S3 diagnosis: per-upgrade status counts, backtraces, full 65-upgrade scan, failing-building characteristics | SSO | done 2026-10-02 |
| 2 | Port the seven class A call sites; `std` kept where instance methods still exist | none | done `ad147d38` |
| 3 | Fan curve decision (parity vs `'Single Zone VAV'`) | owner input | applied provisionally as `'Single Zone VAV'` with a comment at both call sites giving the parity alternative; owners can flip it by deleting the call |
| 4 | LED measure fix (option B) | none | done `ad147d38`, untested on a typical model |
| 5 | Class D code-side guards: hydronic_gshp:443, wall_insulation:215, packaged_gshp not-applicable guard, battery JSON spelling, meta_measure exception message | none | done `ad147d38` |
| 6 | Unit tests under OS 3.10.0 with the `resources/` bundle (bundle at `C:/tmp/csgems`, bundler 2.4.10, system Ruby 3.2.2 with the `site_ruby/openstudio.rb` shim; `BUNDLE_GEMFILE=C:/tmp/csgems/Gemfile bundle _2.4.10_ exec ruby <test>`); `measure.xml` left alone (no argument changes) | 2, 4, 5 | see PROGRESS.md |
| 7 | Kestrel items: 26 datapoints pulled (PROGRESS.md 2026-10-03); causes in section 2 "Smaller clusters"; VRF CRAC skip and the hydronic String fix applied; owner items listed there (GSHP condenser loops, unoccupied AHU, WSHP loop) and Eric items (2537 PTHP zero-load, 7223 small-building areas). PySAM datapoint 47/148 pulled but not yet read | done 2026-10-03 except PySAM |
| 8 | Small-sample rerun on Kestrel of the affected upgrades (12, 13, 14, 22, 23, 26, 27, 28, 29, 30, 31, 43, 47, 48, 55, 56, 57, 59, 63, 64). The owner approves and runs the yml; I prepare it (sample of a few hundred buildings, the branch commit, `keep_run_folders` so the not-applicable messages can be tallied). Pass criteria: Fail limited to the owner items above | owner | yml, 500-building precomputed sample and id map uploaded to Kestrel `ymls/sdr_fy26/0_production_runs_2026R1/all_measure_10k/` (copies in this folder); needs the branch checked out on Kestrel as `buildstock_directory` |
| 10 | Applicability shifts vs 2025R3: tallied every measure's not-applicable message from the rerun's `out.osw` files (Kestrel job 18904795) and compared applicability by HVAC system type and floor-area bin with the published R3 metadata in Athena, by distinct building and against the 10k run. No shift: the reference percentages were county-replicated rows; R3 and the 10k run agree within 3 points, the 500 sample within sampling noise. Second-order: VRF zoning tests, GHEDesigner errors registered as NA (15 datapoints). `rerun_applicability_tally.md`, `parse_osw.py`, `tally.py`, `compare_r3.py` | 8 | done |
| 11 | CRAC / data-center exclusion audit, done. The fork's CRAC loops carry no AirLoopHVACUnitarySystem (OA system, DX coil, humidifier, constant-volume fan), so advanced RTU controls (unitary loops only) never selected them, and DOAS minisplits skipped them by the 'datacenter' name test only; both now also skip CRAC/CRAH loops and data-center zones by the fork helper (uncommitted; Success unchanged on pulled PSZ-AC 1 and 195, NA unchanged on 6252). Console GSHP: a CRAC loop does not trip its unitary test, but any air loop makes it skip the PTAC inventory, so a PTAC building with a data center would be NA (none in the 65 PTAC/PTHP/residential random buildings); owner's call. Hydronic GSHP skips CRAC units since the :756 fix | none | done |
| 9 | PR from `ccaradon/spacetype_refactor_measure_failures` into `spacetype_refactor` (not main); flag that the class A fixes, the battery JSON and the meta_measure logging are needed on `main` too | 8 | |

## 4. Baseline failures (not this branch's scope, for the fork owner)

Two of 8,634 buildings fail in `create_custom_building_from_spec` ("failed, see previous errors"),
so every upgrade inherits two Fail rows: building 2537 (small_hotel, PTHP, 1998, county G3700190,
climate zone 3A, gen2_t8_halogen) and 7223 (primary_school, PVAV with gas boiler reheat, 1955,
county G4400070, 5A, gen4_led). The error text is in the Kestrel run.log only.

## 5. Side item: log the exception message

`resources/meta_measure.rb:248` writes `"Measure Failed with Error: #{e.backtrace.join("\n")}"`.
Adding `e.class` and `e.message` in front of the backtrace would have made every class A failure
self-explanatory in the parquet (`NoMethodError: undefined method 'remove_hvac' for
#<ComStock901_2019 ...>`). Applied in `ad147d38` on this branch; needs its own PR to main as well.

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
