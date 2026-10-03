# 2026R1 all-measure run: measure failure progress log

Plan and findings: [PLAN.md](PLAN.md). Newest entry first.

## Resume here

1. Uncommitted in the worktree (owner commits): economizer, energy recovery and unoccupied OA
   controls (CRAC skips), `upgrade_hvac_vrf_hr_doas/measure.rb` (CRAC /
   data-center loop skip), `upgrade_hvac_hydronic_gshp/measure.rb` (String-safe flow-method
   guard), `upgrade_hvac_packaged_gshp/measure.rb` (data-center zones kept on their CRAC, measure
   proceeds), `measures/utility_bills/resources/calc_elec_bill.py` (zero-purchase guard, exception
   text), PLAN.md and PROGRESS.md. Suggested commit message at the end of the 2026-10-03 log.
2. Small-sample rerun: the upgrade subset is in `rerun_upgrades_subset.yml` (20 upgrades, 2026R1 names and options, with the suggested settings in its header); the owner drops it into their run yml, approves and submits it (PLAN.md step 8). Not submitted by me.
3. Then the applicability tally (step 10) and the CRAC exclusion audit (step 11).
4. Owner items still open: GSHP condenser-loop runaways (hydronic, console), unoccupied AHU
   (see the 2026-10-03 entry for the reproduction result). Baseline failures 2537 and 7223 and the
   5552 WSHP loop are parked (newer ComStock-Typical may fix them).
5. Pulled models and logs: `C:/tmp/mf2026r1` (local), `/scratch/ccaradon/mf2026r1` and
   `/home/ccaradon/mf2026r1/mf2026r1_extract.tar.gz` on Kestrel. Direct-run outputs in
   `C:/tmp/typ_runs/<case>/out.osm`; runner `C:/tmp/adhoc_typical.rb`; variants `C:/tmp/make_variant.rb`.

## Status by upgrade

| id | measure | class | diagnosis | S3 evidence | fix | tested | rerun |
|---|---|---|---|---|---|---|---|
| 14 | upgrade_hvac_doas_hp_minisplits | A | done | confirmed :339 (1,896 Fail) | `ad147d38` | direct run on a prototype PSZ model: Success | |
| 22 | upgrade_advanced_rtu_control | A | done | confirmed :391 (4,145 Fail) | `ad147d38` (fan curve now applied) | suite 3/3 | |
| 26 | upgrade_hvac_pump | A | done (was wrongly "all invalid") | confirmed :144 (2,512 Fail) | `ad147d38` | suite 11/11 | |
| 27 | upgrade_hvac_enable_ideal_air_loads | A | done | confirmed :86 (8,632 Fail) | `ad147d38` | suite 5/5 (EPW substituted) | |
| 29 | upgrade_hvac_packaged_gshp | A + D | done | confirmed :956 (5,407), :866 (51), :874 (32), :941 (2) | `ad147d38` (port, fan curve, NA guard for mixed systems) | direct runs: PSZ-HP and PVAV Success with GHEDesigner; pulled mixed-system models 112 and 345 NA via the guard | |
| 31 | upgrade_hvac_chiller | A | done (was wrongly "all invalid") | confirmed :159 (1,161 Fail) | `ad147d38` | suite 3/3 | |
| 43 | upgrade_light_led | C | done | confirmed (8,632 Fail) | `ad147d38` (gem data lookup) | suite 8/8; pulled typical model 1: Success, 2,248 to 1,315 W | |
| 47 | upgrade_add_pvwatts (+ utility_bills) | D | done; PySAM needs Kestrel | 601 battery JSON, 16 PySAM | `ad147d38` (JSON spelling); PySAM open | | |
| 48, 54 | upgrade_env_exterior_wall_insulation | D | done; the simulation-side one is the baseline WSHP loop (Eric) | 3 nil construction, 1 simulation-side | `ad147d38` (guard) | pulled 195 model: Success, 12 tbd walls left unchanged | |
| 55, 56, 57 | Packages 2-4 (light_led) | C | done | confirmed | via 43 | | |
| 59, 63 | Package_6, Package_10 (gshp x3), missed by the summary | A + D | done | 5,577 and 5,572 Fail | via 29, 28; simulation-side open | | |
| 64 | Package_11 (gshp x3 + envelope + light_led) | A + C + D | done | 8,040 Fail | via 29, 28, 43, 48 | | |
| 28 | upgrade_hvac_hydronic_gshp | D | done: :443 is the String return type; 32 simulation-side are the measure's condenser loop (owner) | 69 + 32 | guard revised (uncommitted) | suite 7/7; pulled 1062 model Success with GHEDesigner | |
| 12, 13 | upgrade_hvac_vrf_hr_doas | sim | done: CRAC loops of data-center zones replaced by VRF terminals | 11 + 11 | CRAC / data-center skip (uncommitted) | pulled 3145 model Success, 6 CRAC loops kept; annual EnergyPlus run completes with 0 severe | |
| 30 | upgrade_hvac_console_gshp | sim | done: the measure's condenser loop runs away (too hot or too cold) | 4 | owner | | |
| 23 | upgrade_unoccupied_oa_controls | sim | done: numerical divergence at the first unoccupied night; optimum start + night cycle lead | 2 | owner | | |

## Log

### 2026-10-03, evening (comments trimmed, local-only testing)

- Owner: keep inline comments to one or two lines; document the state; continue with testing that
  needs no Kestrel run (Kestrel storage is full; the owner is deleting old runs under eusscom).
- Trimmed every comment block I added (advanced RTU, packaged GSHP, VRF, hydronic, wall insulation,
  LED) to two lines; all files compile under the OS 3.10.0 CLI.
- `origin/spacetype_refactor` gained one commit since the branch was cut (`5e9895f1`, FSR kitchen
  SWH override in create_custom_building_from_spec); no overlap with these changes, same
  comstock-typical ref. Merging it is the owner's call.
- Batch of measure runs on the pulled typical models (`C:/tmp/typ_runs/batch2`), all with the ported
  code: DOAS minisplits Success on 1, 195, 345 (one applicable loop each); advanced RTU controls
  (add_econo=true, add_dcv=true as in the run) Success on 1 and 195, NA on the PVAV office 6252;
  pump Success on 2419 (3 pumps updated) and 1062; chiller Success on 2419 (water-cooled chiller
  found), NA on 3145; LED gen5 Success on 2419 and 6252.
- CRAC audit on 3145 (six CRAC loops, summarised before and after each measure): DCV and heat pump
  RTU leave them alone (DCV reports the six as ineligible space types; HP RTU finds no applicable
  loops). Economizer added a DifferentialDryBulb economizer to all six (the fork already decides CRAC
  economizers by climate zone); energy recovery added an ERV to all six; unoccupied OA controls put
  all six on an occupancy availability schedule with a night-cycle manager. Building 4084, one of
  the two unoccupied-AHU divergences, has six CRAC loops and data-center zones (8613 has none), so
  a night-cycled data center is the likely trigger there.
- Added a CRAC/data-center skip to economizer, energy recovery (counted as an inapplicable space
  type) and unoccupied OA controls, the same test as the VRF and packaged GSHP measures (loop name
  CRAC/CRAH or the fork's `thermal_zone_data_center?`). Verification on 3145 and the non-CRAC
  school 2419: verified (`C:/tmp/typ_runs/batch3`): on 3145 the economizer measure is NA (its three PVAV loops already had economizers, the six CRACs are skipped), energy recovery adds 3 ERVs to the PVAV loops and counts the six CRACs as inapplicable, unoccupied OA controls leave the CRAC availability untouched; on the school 2419 (no CRACs) all three behave as before (ERV added, controls applied, economizer NA). Annual EnergyPlus run of the GSHP-upgraded 6252 model:
  completes the full year with 0 severe errors (31 min) but 24.4 million warnings; the most frequent one-line type is `161 CheckSimpleWAHPRatedCurvesOutputs: Coil:Cooling:WaterToAirHeatPump:EquationFit=X` (see `C:/tmp/typ_runs/pgshp_6252_sim/top_warnings.txt` and the recurring-error summary in its eplusout.err), and the recurring warning is `Plant loop falling below lower temperature limit, PlantLoop="CONDENSER LOOP"`: the same ground loop that goes fatal in the hydronic and console cases, so the condenser-loop item for the GSHP owners covers all three measures.

### 2026-10-03, afternoon (owner directions)

- Owner: skip CRAC systems and proceed rather than dropping the building; validate the
  unoccupied AHU failure; explain the PySAM failure; no buildstockbatch runs by me (yml for
  approval); baseline failures parked.
- Packaged GSHP: data-center zones are determined before the equipment pass, kept on their CRAC
  with their equipment, left out of the loop inventory and skipped in the zone loop; the NA guard
  remains for DOAS + WSHP and PTAC/PTHP buildings with a stray unit. Pulled 112 and 345: still NA.
  Pulled 6252 (large office, 6 CRAC loops): Success (49 min, mostly the measure's annual ground-loop simulation): 3 PVAVs replaced with packaged GSHPs serving 54 zones, GHEDesigner ran, all 6 CRAC loops kept. Prototype PSZ-HP regression:
  Success, 18 RTUs replaced (657 s).
- PySAM: reproduced with NREL-PySAM 4.2.0. `calc_elec_bill.py` raised `ZeroDivisionError` on the
  average-rate line for the all-zero purchase profile; the bare `except` hid it; the measure then
  failed the datapoint. Guarded the division and surfaced the exception text; the zero profile now
  bills $7,267 of fixed charges on rate 6452/5a5e50dd, the 1 kWh control is unchanged.
- Unoccupied AHU: pulled the run's `G0600850.epw`; local annual run of the post-measure 4084 model
  as-is: completes the full year with 0 severe errors (same EnergyPlus 25.1.0-1c11a3d85f build as the run, 4 min), and so does the production `in.idf` itself run straight through the local EnergyPlus; the production and local IDFs differ only in meter and output-variable objects; with the 12 optimum-start managers removed: also completes with 0 severe errors, so the hypothesis cannot be tested locally; the divergence is a marginal numerical instability (2 of 3,811 applicable buildings) that shows on the Linux build and not on Windows with identical inputs.
- Suggested commit message for all uncommitted changes:
  `Keep CRAC systems in the VRF and packaged GSHP measures, fix the hydronic flow-method guard and the zero-purchase utility bill`
  with a body naming: VRF 11 large offices per upgrade; packaged GSHP data-center zones skipped
  instead of the building; hydronic String return type (69 buildings); utility bills
  ZeroDivisionError on PV + battery buildings (16); typical-model verification runs.

### 2026-10-03, later (datapoints read, two more fixes)

- The first extraction job found nothing: the job files are 0-based with `null` for baseline. Job
  18891509 pulled all 26 datapoints (1.7 GB, bundle 259 MB) to `C:/tmp/mf2026r1`.
- Findings per cluster are in PLAN.md "Smaller clusters" (VRF: CRAC loops of data-center zones;
  hydronic `:443`: String return type; GSHP simulation-side: the measures' condenser loop;
  unoccupied AHU: divergence with optimum start + night cycle; 2537: PTHP zero-load sizing; 7223:
  floor-area check; 5552: baseline WSHP loop; PySAM 47/148: all-zero net hourly profile with PV + battery).
- Fixes applied, uncommitted: VRF measure skips CRAC/CRAH loops and loops serving data-center
  zones (fork helper `thermal_zone_data_center?`, name fallback); hydronic guard rewritten to accept
  the String return type (the `ad147d38` version raised on the typical model).
- Typical-model verification with `C:/tmp/adhoc_typical.rb` (loads the pulled `in.osm`, sets a
  local EPW, runs the measure, no simulation): LED on 1 Success; wall insulation on 195 Success;
  packaged GSHP on 112 and 345 NA with the zone list; hydronic on 1062 Success with GHEDesigner;
  VRF on 3145 Success with 51 zones on VRF and 6 CRAC loops kept; packaged GSHP on 6252 NA in 2 s
  naming its six data-center zones (the CRAC loops are single-zone but not unitary, the `:941`
  case). The VRF-upgraded 3145 model then completed a full annual EnergyPlus run locally with
  0 severe errors (1 min 48 s), where production diverged in the data-center zone.
- Suggested commit message for the uncommitted changes:
  `Skip CRAC loops in the VRF measure and accept the String flow-method API in the hydronic GSHP`
  with a body naming the 11 large offices per VRF upgrade and the 69 hydronic failures, the
  typical-model runs above, and the docs update.

### 2026-10-03 (Kestrel back: pulling the datapoints)

- Run directory on Kestrel: `/kfs2/projects/eusscom/runs/0_production_runs_2026R1/tests/sdr_2026r1_all_measure_10k`.
  The per-job assignment files `job001.json` .. `job080.json` (`batch: [[building_id, upgrade], ...]`)
  map every datapoint to its tarball `results/simulation_output/simulations_job<N>.tar.gz` (80 files,
  ~70 GB each, members `./upNN/bldgNNNNNNN/...` with `openstudio_output.log`, `run/data_point.zip`,
  `run/data_point_out.json` and the measure sizing-run folders). Copied the 80 json files to
  `C:/tmp/kestrel_jobs/` and built `targets.txt` (26 datapoints in 22 tarballs).
- Targets: VRF 12/3145 and 12/3701; unoccupied AHU 23/4084 and 23/8613; hydronic 28/2419, 28/2552
  (simulation-side) and 28/1062 (:443); packaged GSHP 29/112 (:866), 29/345 (:874), 29/6252 (:941);
  console 30/7749, 30/2692 (sizing run), 30/1046 (simulation-side); PV+battery 47/148 (PySAM);
  wall insulation 48/5552 (simulation-side) and 48/195 (:215); baseline failures 00/2537 and 00/7223;
  baseline OSMs for local reruns of the fixed measures: 00/1, 00/112, 00/345, 00/195, 00/1062,
  00/3145, 00/2419, 00/6252.
- The job files are 0-based with `null` for baseline (`[5354, 14]` is `up15`); the first Slurm job
  (18890166) used the number as the directory suffix and extracted nothing. Slurm job 18891509
  (`/home/ccaradon/mf2026r1/extract_targets.sh`, eusscom / debug, 1 node, 11 parallel tar streams,
  about 8 min per tarball) extracts those directories to `/scratch/ccaradon/mf2026r1`, unzips
  `data_point.zip`, drops sql/eso/audit files and bundles the rest as
  `/home/ccaradon/mf2026r1/mf2026r1_extract.tar.gz` for scp. Local copy goes to `C:/tmp/mf2026r1`.

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
    (GHEDesigner succeeded in all three tests that reach it). Packaged: the suite runs an annual
    simulation after every test and exceeded the 2 h background window twice (two applicable tests
    had passed through the measure and their simulations, no failures logged), so it was finished
    with direct runs instead: PSZ-HP_gthp Success (18 RTUs replaced, GHEDesigner ran);
    PVAV_gas_heat_electric_reheat Success after a sizing run (2 PVAVs replaced, GHEDesigner ran,
    all 30 new VAV fans carry the 'Single Zone VAV' coefficients a=0.0278); the mixed-system case
    (one zone moved from its PSZ-HP loop to a PTAC, the production situation behind :874) returns
    NA in 1 s with the guard's message naming the zone, where production crashed. Note the guard runs
    after the inventory has already removed the PSZ loop components; harmless because an Invalid
    datapoint is never simulated (the measure's own GHEDesigner NA at :1315 behaves the same), but a
    pre-inventory check would be cleaner (follow-up, PLAN.md class D). Side observation: the stock PSZ-HP prototype model's 17 VAV fans already
    carry the 'Single Zone VAV' coefficients, so applying them in the upgrade matches the baseline.
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
