# 2026R1 all-measure run: measure failure progress log

Plan and findings: [PLAN.md](PLAN.md). Newest entry first.

## Resume here

1. Start step 2 of the work breakdown in PLAN.md section 3: port the seven class A call sites,
   one commit per measure (doas_hp_minisplits, advanced_rtu_control, enable_ideal_air_loads,
   packaged_gshp, hvac_pump, hvac_chiller). Keep `std` where instance methods still exist.
2. Get the fan-curve decision (parity vs `'Single Zone VAV'`) from the Advanced RTU Controls
   and packaged GSHP owners before touching those two call sites.
3. Step 4: rewrite `upgrade_light_led` to delegate to
   `OpenstudioStandards::InteriorLighting.create_typical_interior_lighting` (option A).
4. Step 5: code-side guards for hydronic_gshp:443 and wall_insulation:215, plus the
   `RetailStripmall` row in the battery JSON.
5. When Kestrel is back: the **Kestrel** items in PLAN.md section 2 (class D table) and section 4.
   Start with one failing packaged-GSHP datapoint from upgrade 29 (zone_data nil zones).
6. To refresh the S3 tables after a rerun, with a live resbldg SSO session:
   `C:/Users/ccaradon/AppData/Local/anaconda3/envs/comstockpostproc2/python.exe temp_plan/measure_failures_2026r1/s3_failure_summary.py --out temp_plan/measure_failures_2026r1`
   and `... s3_all_upgrades_scan.py` (optionally with a comma-separated id list; a subset run
   does not rewrite the md). Both scripts take the run prefix from a constant at the top.

## Status by upgrade

| id | measure | class | diagnosis | S3 evidence | fix | tested | rerun |
|---|---|---|---|---|---|---|---|
| 14 | upgrade_hvac_doas_hp_minisplits | A | done | confirmed :339 (1,896 Fail) | | | |
| 22 | upgrade_advanced_rtu_control | A | done | confirmed :391 (4,145 Fail) | | | |
| 26 | upgrade_hvac_pump | A | done (was wrongly "all invalid") | confirmed :144 (2,512 Fail) | | | |
| 27 | upgrade_hvac_enable_ideal_air_loads | A | done | confirmed :86 (8,632 Fail) | | | |
| 29 | upgrade_hvac_packaged_gshp | A + D | done; D needs Kestrel | confirmed :956 (5,407), :866 (51), :874 (32), :941 (2) | | | |
| 31 | upgrade_hvac_chiller | A | done (was wrongly "all invalid") | confirmed :159 (1,161 Fail) | | | |
| 43 | upgrade_light_led | C | done | confirmed (8,632 Fail) | | | |
| 47 | upgrade_add_pvwatts (+ utility_bills) | D | done; PySAM needs Kestrel | 601 battery JSON, 16 PySAM | | | |
| 55 | Package_2 (light_led) | C | done | confirmed | | | |
| 56 | Package_3 (light_led) | C | done | confirmed | | | |
| 57 | Package_4 (light_led) | C | done | confirmed | | | |
| 59 | Package_6 (gshp x3), missed by the summary | A + D | done; D needs Kestrel | 5,577 Fail | | | |
| 63 | Package_10 (gshp x3 + envelope), missed by the summary | A + D | done; D needs Kestrel | 5,572 Fail | | | |
| 64 | Package_11 (gshp x3 + envelope + light_led) | A + C + D | done; D needs Kestrel | 8,040 Fail | | | |
| 12, 13, 23, 28, 30, 48 | small simulation-side or class D counts | D | needs Kestrel | see all-upgrades scan | | | |

## Log

### 2026-10-02, afternoon (SSO refreshed)

- Ran `s3_failure_summary.py` and `s3_all_upgrades_scan.py` against the run prefix. The run has
  8,634 buildings (not 10k) and 65 upgrades; baseline has 2 failures (2537, 7223).
- Backtraces confirm every class A line number. The parquet never holds the exception message
  because `meta_measure.rb:248` logs only the backtrace (side item, PLAN.md section 5).
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
