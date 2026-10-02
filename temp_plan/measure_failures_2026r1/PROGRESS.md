# 2026R1 all-measure run: measure failure progress log

Plan and findings: [PLAN.md](PLAN.md). Newest entry first.

## Resume here

1. Local unit tests of the ported measures: bundle at `C:/tmp/csgems` (see PLAN.md step 6); run
   each test file with `BUNDLE_GEMFILE=C:/tmp/csgems/Gemfile bundle _2.4.10_ exec ruby <file>` from
   the worktree root and record pass/fail below. Test models are prototype-built, so they exercise
   the class A ports and the LED measure's CSV path, not the typical-model path.
2. When Kestrel is back, pull the datapoints listed in PLAN.md step 7 (one per cluster) and the two
   baseline failures; then run the fixed measures on a few typical-model OSMs (LED, packaged GSHP
   guard, hydronic guard, wall insulation guard).
3. Get the fan-curve confirmation (PLAN.md class A) from the Advanced RTU Controls and packaged
   GSHP owners; flip by deleting the call if they want 2025R3 parity.
4. Rerun the affected upgrades on a small Kestrel sample (PLAN.md step 8), then refresh the S3 tables:
   `C:/Users/ccaradon/AppData/Local/anaconda3/envs/comstockpostproc2/python.exe temp_plan/measure_failures_2026r1/s3_failure_summary.py --out temp_plan/measure_failures_2026r1`
   and `... s3_all_upgrades_scan.py` (optionally a comma-separated id list; a subset run does not
   rewrite the md), `... s3_failed_building_characteristics.py <ids>` for the building join. All
   three take the run prefix from a constant at the top and need a live resbldg SSO session.

## Status by upgrade

| id | measure | class | diagnosis | S3 evidence | fix | tested | rerun |
|---|---|---|---|---|---|---|---|
| 14 | upgrade_hvac_doas_hp_minisplits | A | done | confirmed :339 (1,896 Fail) | `ad147d38` | direct run on a prototype PSZ model: Success | |
| 22 | upgrade_advanced_rtu_control | A | done | confirmed :391 (4,145 Fail) | `ad147d38` (fan curve now applied) | suite 3/3 | |
| 26 | upgrade_hvac_pump | A | done (was wrongly "all invalid") | confirmed :144 (2,512 Fail) | `ad147d38` | suite 11/11 | |
| 27 | upgrade_hvac_enable_ideal_air_loads | A | done | confirmed :86 (8,632 Fail) | `ad147d38` | suite 5/5 (EPW substituted) | |
| 29 | upgrade_hvac_packaged_gshp | A + D | done | confirmed :956 (5,407), :866 (51), :874 (32), :941 (2) | `ad147d38` (port, fan curve, NA guard for mixed systems) | | |
| 31 | upgrade_hvac_chiller | A | done (was wrongly "all invalid") | confirmed :159 (1,161 Fail) | `ad147d38` | suite 3/3 | |
| 43 | upgrade_light_led | C | done | confirmed (8,632 Fail) | `ad147d38` (gem data lookup) | suite 8/8 (prototype path) | |
| 47 | upgrade_add_pvwatts (+ utility_bills) | D | done; PySAM needs Kestrel | 601 battery JSON, 16 PySAM | `ad147d38` (JSON spelling); PySAM open | | |
| 48, 54 | upgrade_env_exterior_wall_insulation | D | done | 3 nil construction, 1 simulation-side | `ad147d38` (guard); 1 Kestrel | direct two-construction run: Success | |
| 55, 56, 57 | Packages 2-4 (light_led) | C | done | confirmed | via 43 | | |
| 59, 63 | Package_6, Package_10 (gshp x3), missed by the summary | A + D | done | 5,577 and 5,572 Fail | via 29, 28; simulation-side open | | |
| 64 | Package_11 (gshp x3 + envelope + light_led) | A + C + D | done | 8,040 Fail | via 29, 28, 43, 48 | | |
| 28 | upgrade_hvac_hydronic_gshp | D | done for :443; 32 simulation-side need Kestrel | 69 + 32 | `ad147d38` (guard) | suite 7/7 with GHEDesigner | |
| 12, 13 | upgrade_hvac_vrf_hr_doas | sim | 11 large offices, same in both variants | 11 + 11 | Kestrel | | |
| 30 | upgrade_hvac_console_gshp | sim | 2 sizing run, 2 simulation-side | 4 | Kestrel | | |
| 23 | upgrade_unoccupied_oa_controls | sim | 2 CEC4 offices | 2 | Kestrel | | |

## Log

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
    (GHEDesigner succeeded in all three tests that reach it). Packaged: running after the 2026-10-02
    reboot interrupted the first attempt; result to follow.
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
