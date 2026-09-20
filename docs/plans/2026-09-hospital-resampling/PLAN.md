# Hospital v2 resampling — plan and progress

**Last updated 2026-09-19, during the run.** This is the living document for this task. It mirrors the
layout of `stock-estimation/docs/plans/2026-09-cbecs-fuel-hvac-rebuild/`, which is a separate and
deliberately untouched piece of work — see "Relationship to the CBECS rebuild" below.

---

## 0. In one paragraph

A new set of ten TSVs built from a hospital v2 stock estimate (`hospital_v2_tsvs_2026-09-16.zip`) ships
as `sampling/tsvs/tsvs-v34.zip`, and three buildstocks were generated from it: **8,634**, **103,608** and
**100** rows, the last a verified subset of the first. The bucket definition file was regenerated first,
because the shipped one encodes the *old* stock estimate's allocation and would otherwise have pinned the
sample to the pre-hospital-v2 building mix — though it turned out to move the bucket count only from
8,602 to 8,634. Two real defects were found and fixed on the way: a retired-FIPS tract remap that crashes
`join_geospatial.py`, and a schema incompatibility between the new estimate and production apportionment.
Two further defects were found in inherited production code and deliberately left alone (section 4.3).
**All steps are complete.** The remaining open items are H2 and H4 in section 6.

---

## 1. Where everything is

| what | where |
|---|---|
| branch | ComStock `hospital_resampling`, branched from `main` at `f25ac375` |
| source TSVs | `C:\Users\ccaradon\Downloads\hospital_v2_tsvs_2026-09-16.zip` (11 entries: 10 TSV/JSON + 1 parquet) |
| shipped TSV set | `sampling/tsvs/tsvs-v34.zip` — committed, `c2e29bed` |
| stock estimate | `postprocessing/truth_data/v01/2026-09-16_12-13_building_estimate.parquet` — gitignored, staged locally |
| tract list | `postprocessing/truth_data/v01/2026-09-16_12-13_tract_list.csv` — a copy of `2025R3_tract_list.csv` |
| bucket files | `sampling/sample_input_20260919-*_{N,12N}.csv` — being generated |
| buildstocks | `sampling/output-buildstocks/{intermediate,final}/` — **gitignored**, on disk only |
| scratch scripts | session scratchpad: `run_apportion.py`, `build_v34.py`, `rezip_v35.py`, `rename_to_v34.py`, `make_100_subset.py`, `test_fips_patch.py` |

**Environment.** conda env `comstockpostproc2` (py 3.12.12, pandas 2.3.3) for apportionment;
`comstock-sampling` for the sampler and the geospatial join. The `comstockpostproc` env is broken —
`ImportError: DLL load failed while importing _ctypes` — do not use it. AWS resbldg SSO is live under
profile `nlr-aws-resbldg-resbldg-user`, though no S3 download turned out to be needed.

---

## 2. Status

| # | step | state |
|---|---|---|
| 1 | Build `tsvs-v34.zip` = v33 + the ten hospital_v2 files | **done**, verified by hash |
| 2 | Fix the retired-FIPS tract remap in `join_geospatial.py` | **done**, tested |
| 3 | Stage the stock estimate and tract list as `2026-09-16_12-13_*` | **done** |
| 4 | Regenerate the bucket definition files | **done** — 8,634 buckets. `sample_input_20260919-1409_8634.csv` and `_103608.csv` (8,634 × 12). The two 2025-09-16 files are untouched. |
| 5 | Sample the ~10k: `tsv_sampling.py v34 2018 8634 1 hardsize -p sample_input_20260919-1409_8634.csv` | **done** — 8,634 rows, 97 cols, 1.7 min |
| 6 | Sample the ~100k: `tsv_sampling.py v34 2018 103608 12 hardsize -p sample_input_20260919-1409_103608.csv` | **done** — 103,608 rows, ~3 h, no lookup-reduction warnings |
| 7 | `join_geospatial.py` on both | **done** — 119 cols each; 1 tract resampled on the ~10k, 9 on the ~100k |
| 8 | Cut the 100-row subset of the ~10k, with provenance | **done** — seed 20260919 |
| 9 | Commit bucket files; report | bucket files committed in `23e2c737`; buildstocks are gitignored |

**All steps complete.**

### Outputs

All under `sampling/output-buildstocks/`, **gitignored — on disk only**:

| file | rows | cols |
|---|---:|---:|
| `buildstock_20260919-1409_v34_2018_ccaradon_8634_hardsize.csv` (intermediate / final) | 8,634 | 97 / 119 |
| `buildstock_20260919-1409_v34_2018_ccaradon_103608_hardsize.csv` (intermediate / final) | 103,608 | 97 / 119 |
| `buildstock_20260919-1409_v34_2018_ccaradon_100_hardsize.csv` (intermediate / final) | 100 | 97 / 119 |
| `..._100_hardsize.provenance.csv` (intermediate / final) | 100 | 2 |

### Verification

Both buildstocks: `baseline_hvac_sizing` uniformly `hardsize`, `year_of_simulation` uniformly `2018`, 15
building types, no blank tracts, `Building` contiguous 1..N after the join, no blank geospatial values,
and no retired FIPS left in the `tract` column. Hospitals are 209/8,634 and 2,508/103,608 — 2.42% in both.

**Section 4.1's fix was exercised on live data**, not only on the synthetic test: 1 row of the ~10k and 7
rows of the ~100k fell in remapped counties, and the joins reported 1 and 9 resampled tracts. The ~100k is
the case the CBECS branch warned about — at 12 samples per bucket a bad tract recurs many times — and it
completed with no assertion failure.

The 100 is verified row-for-row identical to its parents in the ~10k, not an independent draw. Provenance
is 1-based in `final` and 0-based in `intermediate`, matching each file's own `Building` convention.

**Distribution agreement between the two independent runs.** `building_type`, `size_bin`, `heating_fuel`
and `hvac_system_type` are identical to 0.00 pp — but that is *by construction*, not evidence of
convergence: those columns come straight from the bucket file, and the 103,608 rows are 12 copies of each
of the 8,634 buckets. The meaningful comparison is the attributes the sampler actually draws:

| attribute | categories | max abs diff | sum abs diff |
|---|---:|---:|---:|
| `climate_zone` | 30 | 0.08 pp | 0.41 pp |
| `state_name` | 51 | 0.22 pp | 2.47 pp |
| `year_built` | 211 | 0.33 pp | 9.66 pp |
| `wall_construction_type` | 4 | 0.43 pp | 0.86 pp |
| `building_area` | 17 | 0.44 pp | 3.03 pp |
| `number_stories` | 16 | 0.52 pp | 2.41 pp |
| `weekday_start_time` | 36 | 0.56 pp | 5.95 pp |

Census division shares agree within 0.22 pp. This is the right check given the sampler is not
reproducible run to run — compare distributions, never diff two outputs.

**Expected duration.** The 2026-09-06 set ran 22:04 → 03:25 for its 114,360-row sample, so budget
roughly five hours for the ~100k. The ~10k is much quicker. `generate_sampling_input` warns
"~15 minutes per 1,000 buckets" for buckets it has to add beyond the 99%-coverage set.

---

## 3. The pipeline, and the parameters chosen

```
hospital_v2 TSVs ──┐
                   ├─→ tsvs-v34.zip ──→ tsv_sampling.py ──→ join_geospatial.py ──→ buildstock
building_estimate ─┴─→ Apportion ──→ sample_input_*.csv ──┘                              │
                                                                          random 100 ────┘
```

| parameter | value | why |
|---|---|---|
| `tsv_version` | `v34` | reuses the CBECS number by instruction; see section 5 |
| `sim_year` | `2018` | matches the 2026-09-06 set and `national.yml`'s 2018 weather |
| `hvac_sizing` | `hardsize` | matches the 2026-09-06 set and `samples/bsb-integration-test.csv` |
| `n_buckets` | 1 for the ~10k, 12 for the ~100k | samples per bucket; `n_samples % n_buckets` must be 0 |
| fuel / HVAC TSVs | `heating_fuel_v2.tsv`, `hvac_system_type_v4.tsv` | production pins; see section 5 |

`n_samples` must equal the bucket file's row count exactly — `_process_precomputed_buildstock_sample`
raises otherwise.

**The sampler is not reproducible run to run.** Unseeded `random.random()` offset plus a
`.sample(frac=1)` shuffle, even on the Sobol path (this repeats D40 of the CBECS plan). So the 100 cannot
be an independent run; it must be cut from the finished ~10k. Do not diff two sampler outputs and expect
equality — compare distributions.

---

## 4. Defects found and fixed

### 4.1 `join_geospatial.py` — retired FIPS crash the new TSVs would have triggered

`manual_fips_update` rewrote `county_id` for retired FIPS but left `tract`, which becomes the `gisjoin`.
The new `county_id.tsv` adds three counties; two of them, `G4601130` (Shannon SD → Oglala Lakota) and
`G5105150` (Bedford City VA → Bedford County), hold exactly one tract each and neither tract is in
`spatial_tract_lookup_table_publish_v10.csv`. By the time the resample runs, `county_id` has already been
rewritten, so the same-county pool is empty and `random.sample` raises `ValueError`.

Remapping `tract` alongside `county_id` lands both directly in the lookup — `G4601020940500` and
`G5100190050100` both exist there — so they never reach the resample path. The third new county,
`G0202610`, is already in the lookup and needs nothing.

**Also fixed, and pre-existing:** the resample pool is now restricted to tracts that are in the lookup.
A replacement could previously be unjoinable itself, tripping the `assert` at the end of the join *after*
the work was done. `G2901490` is missing 8 of its 11 tracts, so it was roughly a coin flip per affected
building. The CBECS branch hit this same class of bug independently and fixed it almost identically;
their note says it bit a 114,360-row buildstock with 13 such tracts and did not bite at one sample per
bucket. Committed in `c2e29bed`.

> This fix was lost once already, when the ComStock checkout was switched to `main` and the uncommitted
> edit to a tracked file went with it. It is committed now.

### 4.2 Apportionment rejects the hospital v2 estimate's schema

`upsample_hvac_system_fuel_types` asserts no column contains NaN, exempting exactly one:

```python
non_nan_cols = df.columns != 'tract_assignment_type'
assert(0 == df.loc[df.loc[:, non_nan_cols].isna().any(axis=1), non_nan_cols].shape[0])
```

The hospital v2 parquet carries a new 13th column, `hospital_subtype`, null for 4,679,598 of 4,685,550
rows (99.87% — every non-hospital building). 2025R3 has 12 columns and nulls only in the exempted one, so
the assertion fires on the first row regardless of data quality.

Fixed by staging the truth-data parquet with `hospital_subtype` dropped; its schema then matches 2025R3
exactly. Apportionment never reads that column — buckets key on sampling region, building type, size bin,
heating fuel and system type. No ComStock code was changed. The full 13-column original is intact in the
Downloads zip.

**This is not obviously the right long-term answer** — see section 6.

A first guess that proved wrong, recorded so nobody re-runs it: this is *not* a missing-county failure.
Both merges are inner joins, so a missing key drops rows rather than producing NaN.

### 4.3 Two inherited apportionment defects — found, deliberately NOT fixed here

The apportioned frame came out at **14,107,285** rows where bootstrap × estimate is
4,685,550 × 3 = **14,056,650**. More rows than the bootstrap should produce, which is worth decomposing
because it is not noise:

| | rows |
|---|---:|
| expected, 3 × estimate | 14,056,650 |
| added by duplicated TSV keys | +76,444 |
| dropped by the production inner merge | −25,809 |
| **actual** | **14,107,285** |

* **`hvac_system_type_v4.tsv` has 52 duplicated dependency keys.** 152,888 building-rows carry one of
  them and are therefore counted twice, e.g.
  `full_service_restaurant / size_bin 0 / Propane / East North Central`. `heating_fuel_v2.tsv` is clean.
  This is precisely what the CBECS branch's `validate_tsv` raises on, and `hvac_system_type_v5.tsv` has
  **zero** duplicated keys.
* **The production merge is an inner join**, so 25,809 rows whose key has no truth data are silently
  dropped. This is the same class of defect as CBECS plan D46, and the branch's `probability_merge.py`
  replaces it with a validated left join plus fallback.

Both are pre-existing production behaviour, not caused by the hospital v2 estimate: the shipped
`sample_input_20250916-1309_*` files carry the same properties. They are left alone because this task is
explicitly kept off the CBECS rebuild. **Flagging them because the bucket file produced here inherits
both** — roughly 0.5% of rows double-counted and 0.2% dropped.

---

## 5. Relationship to the CBECS fuel/HVAC rebuild — deliberately separate

`stock-estimation/docs/plans/2026-09-cbecs-fuel-hvac-rebuild/` covers a different, in-progress piece of
work: rebuilt heating-fuel and HVAC-system-type distributions shipped as `hvac_system_type_v5.tsv` and
`heating_fuel_v3.tsv`, committed to ComStock branch `ccaradon/cbecs-tsv-v34-apportionment-validation`
(pushed to origin) as **`tsvs-v34.zip`**, with its own bucket files
`sample_input_20260906-1809_{9530,114360}.csv`.

**This task does not use any of it, by instruction.** Consequences to keep straight:

* **This set is also named `v34`**, by instruction, and is based on **v33**. Two different
  `tsvs-v34.zip` files therefore exist: this one on `hospital_resampling`, and the CBECS one at
  `48dbc0bd` on `ccaradon/cbecs-tsv-v34-apportionment-validation`. Same name and number, different
  contents. Merging those branches is a hard binary conflict someone resolves by hand, and the
  buildstocks are told apart only by their date stamp: `20260919-1409` here, `20260906-1909` there.
* Apportionment here uses the production `v4`/`v2` pins, not the branch's `v5`/`v3`.
* The CBECS branch also carries fixes to `tsv_sampling.py` (a `validate_tsv` structural check) and to
  `join_geospatial.py` that this branch does not have, beyond the equivalent resample fix in 4.1.

From that plan, two items bear directly on what happens to these buildstocks downstream:

* **D46** — a bucket key with no truth data is *silently dropped*, not an error: `csdf.join(appo_group_df)`
  in `comstock.py` is a polars inner join. **The bucket file and the post-processing apportionment must
  match, and nothing will tell you when they do not.** Anyone post-processing these runs must use the same
  configuration used here: the `2026-09-16_12-13` estimate with `v4`/`v2`.
* **D44** — `sampling/README.md` is wrong where it says the shipped bucket files were generated for
  EUSS 2024 R2; they reproduce from 2025 R3.

---

## 6. Open questions

| | question | notes |
|---|---|---|
| ~~H1~~ | ~~Is `hospital_subtype` meant to drive anything downstream?~~ | **Closed 2026-09-19 — nothing consumes it, so dropping it costs nothing.** Verified: `git grep hospital_subtype` across ComStock returns only this document; `options_lookup.tsv` has zero references; there is no `hospital_subtype.tsv` in the TSV set. The existing subtype mechanism is `building_subtype.tsv` feeding `bldg_subtype_*` args of `create_bar_from_building_type_ratios`, and its hospital row is `NA = 1.0` with no hospital options defined at all. If subtype-aware hospitals are ever wanted, that is the path, and it needs a TSV, `options_lookup` rows, and a measure that registers the options (CBECS plan D35: `options_lookup` alone is not enough). |
| **H2** | Should the exporter stop emitting sparse columns, or should the assertion exempt them? | Adding any column with nulls breaks production apportionment on that blanket check. This will recur. |
| ~~H3~~ | ~~Does the hospital v2 allocation actually differ from September's 9,530 buckets?~~ | **Closed 2026-09-19 — 8,634 buckets.** Against the production baseline of **8,602** (`sample_input_20250916-1309_8602.csv`, same v4/v2 pins) that is **+32 buckets, +0.37%**: the hospital v2 estimate barely moves the bucket set. September's **9,530** is not the comparison — that came from the CBECS branch's v5/v3 fuel and HVAC TSVs, so the +928 there is the fuel/HVAC rebuild, not the stock estimate. Regenerating was still correct (the allocation is pinned per row and now reflects hospital v2), but the effect is small. |
| ~~H4~~ | ~~Is the numbering right?~~ | **Closed 2026-09-19 — named `v34` by instruction**, since the CBECS work is not being pursued right now. The collision with `48dbc0bd` is accepted and documented in section 5. Earlier commits in this branch's history (`c2e29bed` … `9eb8f69e`) say `v35`; that was the interim name and the history was not rewritten. |

---

## 7. How to resume if this is interrupted

1. `git -C C:/Users/ccaradon/Documents/GitHub/ComStock checkout hospital_resampling`
2. Check `sampling/sample_input_20260919-*.csv` exists. If not, re-run `run_apportion.py` from the
   scratchpad under env `comstockpostproc2`, with `PYTHONBREAKPOINT=0` set — `infer_tracts` contains an
   interactive `breakpoint()` on its non-early-return path that would hang a background run. It early-returns
   here because the estimate has no null or `999999` tracts.
3. Steps 5–8 of section 2, in order. Each sampler run writes to
   `sampling/output-buildstocks/intermediate`, then `join_geospatial.py <name>.csv` writes to `final`.
4. The 100-row cut is `make_100_subset.py <intermediate_10k.csv> 100 20260919`; it picks positions once
   and takes the same positions from both intermediate and final, so the 100 are literally rows of the
   10k, and writes a `Building,parent_Building` provenance file next to each output.
