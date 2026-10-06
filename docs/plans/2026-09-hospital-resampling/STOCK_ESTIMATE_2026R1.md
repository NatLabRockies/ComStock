# Hospital resampling — apportionment stock estimate (2026R1) plan and progress

**Branch:** `hospital_resampling`, beside `PLAN.md` (the hospital v2 TSVs and buildstocks); this is
the follow-on: the 2026R1 stock estimate and re-apportioning the new sample to it. Moved here on
2026-10-06 from the untracked `postprocessing/HOSPITAL_RESAMPLING_2026R1_PLAN.md`. **The dashboard
code changes described in §7 are NOT here** — they live on `ccaradon/calibration-qaqc`, which is
the only branch carrying `comstockpostproc/results_dashboard/`.

**Status (2026-09-21):** **DONE and validated.** 2026R1 created, applied to the new sample only,
both affected dashboards rebuilt. Hospital state coverage went 48 -> 51 states. Remaining: the
tract-list question in §5 and the S3 upload in §6 step 2.

---

## 1. The problem

`str_100k_fixes_ts_new_sample` was sampled against a **new stock estimate** (the hospital v2
TSV set) but every dashboard built so far apportioned it against **2025R3**. Apportionment
matches each ComStock model to real buildings in the truth stock by tract, so pointing it at
the wrong stock mis-weights the run.

The other two runs are unaffected — they were drawn against 2025R3 and were apportioned to it.

## 2. Evidence — which run belongs to which estimate

Hospital tracts present in each estimate, against the tracts each buildstock actually sampled:

| run | hospital models | distinct hospital tracts | tracts **absent from 2025R3** |
|---|---:|---:|---:|
| `str_100k_fixes_ts_new_sample` | 2,508 | 1,624 | **1,261 (78%)** |
| `str_100k_fixes_ts` | 2,172 | 1,081 | **0** |
| `baseline_10k` | 2,172 | 1,081 | **0** |

**1,955 of new_sample's 2,508 hospital models (78%, 1.89% of all 103,608 models) sit in tracts
that do not exist in the 2025R3 estimate at all.** `str_100k_fixes_ts` and `baseline_10k` share
a byte-identical `buildstock.csv` (md5 `a50fc2a9…`), which is why both are clean.

## 3. How the two estimates differ

Same 12 columns. Nationally near-identical — it is a **reallocation into hospitals**, not a
larger stock:

| | 2025R3 | hospital v2 | ratio |
|---|---:|---:|---:|
| hospital count | 3,224 | 5,952 | **1.85×** |
| **hospital floor area** | 0.838 B ft² | 2.100 B ft² | **2.51×** |
| secondary_school | 60,277 | 56,809 | 0.94 |
| primary_school | 55,150 | 52,361 | 0.95 |
| all other types | — | — | 0.99–1.00 |
| **national total sqft** | 100.17 B ft² | 100.79 B ft² | 1.006 |
| national building count | 4,699,979 | 4,685,550 | 0.997 |

## 4. File inventory

`Apportion` needs exactly **two** version-specific files, `{version}_building_estimate.parquet`
and `{version}_tract_list.csv`. Everything else it reads is a fixed, version-independent name.

| file | status |
|---|---|
| `2026-09-16_12-13_building_estimate.parquet` | **Have.** In `truth_data/v01/` and in the zip. Byte sizes differ (46,170,613 vs 46,599,989) but **content is identical** — same 4,685,550 rows, same 5,952 hospitals, same 2.100 B ft². Compression only. |
| `2026-09-16_12-13_tract_list.csv` | **Present but it is a COPY of `2025R3_tract_list.csv`** — md5 `b83f02df…` on both. See §5. |
| `hvac_system_size_bin_v1.tsv` | Have (shared) |
| `sampling_regions_v1.json` | Have (shared) |
| `cec_cz_by_tract_2010_lkup.json` / `_2020_` | Have (shared) |
| `hvac_system_type_v4.tsv` | Have (shared) |
| `heating_fuel_v2.tsv` | Have (shared) |

**S3 has no 2026 files.** `s3://eulp/truth_data/v01/StockE/` tops out at 2025R3 (plus 2023R2,
2024R2, 2025R1). The local zip is the only source, and the only copy — **it is not backed up
anywhere.** Upload before relying on it.

The zip also contains the sampling TSVs (`county_id.tsv` 574 MB, `state_id.tsv`,
`climate_zone.tsv`, `building_type.tsv`, `size_bin.tsv`, `sampling_region.tsv`,
`building_area.tsv`, `tract.json`, `year_built.json`, `number_stories.json`). Those drive
buildstock **sampling**, not postprocessing apportionment — they are not needed to fix this,
but they are what makes the estimate reproducible.

## 5. The one real gap: the tract list

`2026-09-16_12-13_tract_list.csv` is byte-identical to the 2025R3 one. Measured against the new
estimate:

- estimate tracts: 91,228 — covered by the tract list: 91,058 — **missing: 170**
- of those missing, **156 are hospital tracts** (of 5,233 hospital tracts in the estimate)

**Severity: low, and MEASURED not assumed.** It was suspected of blocking the DE/RI/VT fix. It
does not: RI and VT have *all* their hospital tracts in the list and DE misses only 2 of 13, and
the 156 missing tracts are spread across many states (LA 26, CA 13, PA 10) rather than
concentrated in the ones that were broken. `tract_list` is the county → allowable-tracts lookup
used by `_assign_tracts` only for records whose tract is null, so records that already carry a
tract are unaffected. The real remaining objection is that the file is *mislabelled* as a v2
artifact when it is a byte-identical copy of the R3 one.

**Decide before adopting:** either regenerate a true v2 tract list from the same source that
produced the estimate, or confirm deliberately that the R3 list is intended and rename it so it
is not mistaken for a v2 file.

## 6. Plan — steps 1, 3, 4 and 5 done; step 2 outstanding

1. **Promote to a named version.** Copy, do not move, so the dated original stays as provenance:
   - `truth_data/v01/2026R1_building_estimate.parquet` ← the dated parquet
   - `truth_data/v01/2026R1_tract_list.csv` ← resolve §5 first
2. **Upload both to `s3://eulp/truth_data/v01/StockE/`** so the run is reproducible off one
   laptop. **NOT DONE — the local copy is still the only one.**
3. **Point ONLY the new run at it.** In the driver, a second `Apportion` instance:
   - `str_100k_fixes_ts_new_sample` → `stock_estimation_version='2026R1'`
   - `str_100k_fixes_ts`, `baseline_10k` → `'2025R3'` (unchanged)
   `create_allocated_weights(stock_estimate, …)` takes the estimate per run, so this needs no
   library change — just two `Apportion` objects instead of one.
4. **Re-run** `compare_str_100k_new_sample_vs_original.py` and
   `compare_three_runs_hospital_resampling.py`. Both need `reload_from_cache=False` for
   new_sample, since its cached weights are the wrong ones. Athena tables are unaffected and
   will be reused.
5. **Validate against §8 before adopting 2026R1 anywhere else.**

## 7. Concerns to weigh before adopting

**a. A dashboard that mixes two truth stocks.** Once new_sample uses 2026R1 and the others use
2025R3, hospital differences between them are partly the stock estimate (2.5× floor area) and
partly the sample. That may be exactly the intended comparison — the total effect of hospital
v2 — but it is no longer a clean sample-only A/B, and the dashboard does not say so anywhere.
State it in the run notes.

**b. CBECS rescaling hides the error rather than surfacing it.**
`create_allocated_weights_scaled_to_cbecs` forces floor area to CBECS by building type, so a
mis-apportioned run still lands on the right national floor area. The damage shows up as
distorted *within-type* weighting and as the scaling-factor warnings already in the logs
(Outpatient high, PrimarySchool high, LargeOffice low). Do not read "areas match" as "weights
are fine".

**c. RESOLVED — but note what it cost.** The first published numbers for new_sample were
produced under the wrong truth stock. Two further rebuilds *also* published stale numbers
because of the caching traps in §10, and each looked successful. The dashboards are now
correct; the lesson is that "it re-ran without error" was three times not evidence that it
re-ran with the right data.

**d. Single copy of the estimate.** Until step 2, one local zip is the only artifact.

**e. `str_100k_fixes_ts` is NOT a hospital-v2 run** despite the name and branch. It shares its
buildstock with `baseline_10k`. Anyone assuming otherwise will use the wrong estimate for it.

## 8. Validation — done

- [x] **Hospital CBECS scaling factor 3.93 → 1.51** for new_sample. This is the headline: it is
      the correction CBECS had to apply to compensate for the wrong truth stock.
- [x] **Non-hospital types essentially unchanged** — 0.59→0.59, 0.53→0.53 and so on across the
      board. This was the key criterion, since the estimate changed hospitals 2.5× and nothing
      else by more than 6%. Mean |factor−1| fell 0.884 → 0.733, entirely from hospital.
- [x] **State coverage 48 → 51.** DE, RI and VT had *zero* hospital models before and now have
      18, 20 and 16. Hospital models 1,653 → 2,782.
- [x] Apportionment unmatched truth data did not grow (0.70% vs 0.69%).
- [x] Apportionment table itself: Hospital rows 7,870 → 15,142; DE 0→32, RI 0→42, VT 0→48,
      IL 3→548.

Written up for implementors in `output/hospital_resampling_before_after.html`, with hospital
counts, models, weighted buildings and weighted area for all 51 states.

## 9. Progress log

| date | what |
|---|---|
| 2026-09-21 | Defect found: new_sample apportioned to 2025R3, missing 78% of its hospital tracts. Estimates compared (§3), file inventory taken (§4), tract-list copy identified (§5). |
| 2026-09-21 | 2026R1 created from the dated files; existing apportionment cache reused. Per-run `Apportion` wired into both drivers. Validated per §8. Both dashboards rebuilt. |
| 2026-09-21 | **Two caching traps found the hard way — see §10.** The first two "corrected" rebuilds silently published stale 2025R3 numbers. |

## 10. Two caching traps that made this look fixed when it was not

Both produced dashboards that looked healthy, logged nothing unusual, and contained
mis-apportioned numbers. Anyone changing apportionment will hit them.

1. **`prepare_athena_tables` checks table EXISTENCE only.** It cannot tell that the weights
   behind an existing table came from a different stock estimate, so with `rebuild=False` it
   logs "already has every table it needs" and skips. Two consecutive "corrected" runs reused
   tables exported under 2025R3. Fix: `REBUILD_ATHENA_RUNS` in both drivers, scoped per run so
   an unaffected run does not pay for a needless export and crawl.

2. **`create_allocated_weights_plus_util_bills_for_upgrade` has NO reload flag.** It
   short-circuits whenever its cache directory exists, unconditionally. `create_allocated_weights`
   rebuilt correctly at 08:53 while this reused a cache from 07:18, and the export reads from
   *this* cache. Fix: the stale caches were moved aside as `*.stale_2025R3_*` under
   `output/ComStock str_100k_fixes_ts_new_sample/`. **Delete those once satisfied.**
   Consider giving this method a `reload_from_cache` parameter like its siblings.

A third, smaller one: the results-dashboard Athena helper caches query results by SQL text, so
re-running an unchanged verification query returns the OLD answer after a table is re-exported.
Pass `no_cache=True`, or vary the SQL, when checking whether a rebuild took.

## 11. Related state on other branches

`ccaradon/calibration-qaqc` carries `comstockpostproc/results_dashboard/` and these
**uncommitted** changes, which the hospital dashboards depend on:

- `comstock.py` — `alias_custom_building_spec_columns`, maps
  `create_custom_building_from_spec_*` onto the legacy measure names the column definitions
  use. **Without it no custom-building-spec run can be postprocessed at all.** Worth its own PR.
- `design_params.py` — new `clg_setup` metric (cooling setup depth) and a corrected note on
  `clg_sp`; the old note claimed the cooling schedule max is a 50 °C "disabled" sentinel, which
  is untrue of these runs (measured maxima 25–26 °C).
- `assessment.py` / `dashboard.py` / `dashboard.js` — `delta_ref`, so a multi-run dashboard
  names the run its delta arrows compare against instead of silently taking the first, and the
  header toggle says "compare: N runs".
- Drivers: `compare_str_100k_fixes_ts_vs_baseline_10k.py`,
  `compare_str_100k_new_sample_vs_original.py`, `compare_three_runs_hospital_resampling.py`.
