# 2026R1 all-measure run: measure failure progress log

Plan and findings: [PLAN.md](PLAN.md). Newest entry first.

## Resume here

1. Refresh the resbldg SSO session (no AWS CLI on this machine; boto3 reads `~/.aws/config`
   `[default]`), then from the worktree:
   `C:/Users/ccaradon/AppData/Local/anaconda3/envs/comstockpostproc2/python.exe temp_plan/measure_failures_2026r1/s3_failure_summary.py --out temp_plan/measure_failures_2026r1`
   and paste the per-upgrade counts and error strings into the table below.
2. Confirm the class A tracebacks are `NoMethodError` on the calls listed in PLAN.md section 2.
3. Start step 2 of the work breakdown (port the seven call sites), one commit per measure.
4. Get the fan-curve decision (parity vs `'Single Zone VAV'`) from the Advanced RTU Controls
   and Packaged GHP owners before touching those two measures.

## Status by upgrade

| id | measure | class | diagnosis | S3 evidence | fix | tested | rerun |
|---|---|---|---|---|---|---|---|
| 14 | upgrade_hvac_doas_hp_minisplits | A | done (code) | pending | | | |
| 22 | upgrade_advanced_rtu_control | A | done (code) | pending | | | |
| 26 | upgrade_hvac_pump | B + A latent | hypotheses only | pending | | | |
| 27 | upgrade_hvac_enable_ideal_air_loads | A | done (code) | pending | | | |
| 29 | upgrade_hvac_packaged_gshp | A | done (code) | pending | | | |
| 31 | upgrade_hvac_chiller | B + A latent | hypotheses only | pending | | | |
| 43 | upgrade_light_led | C | done (code) | pending | | | |
| 55 | Package_2 (light_led) | C | done (code) | pending | | | |
| 56 | Package_3 (light_led) | C | done (code) | pending | | | |
| 57 | Package_4 (light_led) | C | done (code) | pending | | | |
| 64 | Package_11 (gshp x3 + light_led) | A + C | done (code) | pending | | | |

## Log

### 2026-10-02

- Branch `ccaradon/spacetype_refactor_measure_failures` created from `origin/spacetype_refactor`
  @ `0e4c8084` with `--no-track` (push target is its own name, never main).
- S3 read blocked: `UnauthorizedSSOTokenError` from boto3 with the default (resbldg) profile.
  Wrote `s3_failure_summary.py` to run once the session is refreshed.
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
  - B: pump (26) and chiller (31) are NA on every building; options tables are unchanged, so the
    cause is model contents. Needs S3 counts plus one baseline OSM to settle.
  - C: `upgrade_light_led` needs `prototype_lighting_space_type`, which only the dropped
    `prototype_space_type_assignment` measure set; the fork stamps `lighting_space_type`
    instead and already contains the same lighting algorithm as a module function.
- Audited every `std.`/`standard.` call in all `upgrade_*` measures against the fork; no other
  missing instance methods beyond the six above.
- Found that `'Single Zone VAV Fan '` never matched a valid control type in 0.8.3 either
  (warning, no change), so the port is a behavior decision for 22 and 29.
