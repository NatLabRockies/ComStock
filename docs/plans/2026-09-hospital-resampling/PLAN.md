# Hospital v2 resampling — plan and progress

**Last updated 2026-09-19, during the run.** This is the living document for this task. It mirrors the
layout of `stock-estimation/docs/plans/2026-09-cbecs-fuel-hvac-rebuild/`, which is a separate and
deliberately untouched piece of work — see "Relationship to the CBECS rebuild" below.

---

## 0. In one paragraph

A new set of ten TSVs built from a hospital v2 stock estimate (`hospital_v2_tsvs_2026-09-16.zip`) ships
as `sampling/tsvs/tsvs-v35.zip`, and three buildstocks are being generated from it: a ~10k, a ~100k, and
a 100-row sample that is a random subset of the ~10k. The bucket definition file is being regenerated
first, because the shipped one encodes the *old* stock estimate's allocation and would otherwise pin the
sample to the pre-hospital-v2 building mix. Two real defects were found and fixed on the way: a
retired-FIPS tract remap that crashes `join_geospatial.py`, and a schema incompatibility between the new
estimate and production apportionment.

---

## 1. Where everything is

| what | where |
|---|---|
| branch | ComStock `hospital_resampling`, branched from `main` at `f25ac375` |
| source TSVs | `C:\Users\ccaradon\Downloads\hospital_v2_tsvs_2026-09-16.zip` (11 entries: 10 TSV/JSON + 1 parquet) |
| shipped TSV set | `sampling/tsvs/tsvs-v35.zip` — committed, `c2e29bed` |
| stock estimate | `postprocessing/truth_data/v01/2026-09-16_12-13_building_estimate.parquet` — gitignored, staged locally |
| tract list | `postprocessing/truth_data/v01/2026-09-16_12-13_tract_list.csv` — a copy of `2025R3_tract_list.csv` |
| bucket files | `sampling/sample_input_20260919-*_{N,12N}.csv` — being generated |
| buildstocks | `sampling/output-buildstocks/{intermediate,final}/` — **gitignored**, on disk only |
| scratch scripts | session scratchpad: `run_apportion.py`, `build_v34.py`, `rezip_v35.py`, `make_100_subset.py`, `test_fips_patch.py` |

**Environment.** conda env `comstockpostproc2` (py 3.12.12, pandas 2.3.3) for apportionment;
`comstock-sampling` for the sampler and the geospatial join. The `comstockpostproc` env is broken —
`ImportError: DLL load failed while importing _ctypes` — do not use it. AWS resbldg SSO is live under
profile `nlr-aws-resbldg-resbldg-user`, though no S3 download turned out to be needed.

---

## 2. Status

| # | step | state |
|---|---|---|
| 1 | Build `tsvs-v35.zip` = v33 + the ten hospital_v2 files | **done**, verified by hash |
| 2 | Fix the retired-FIPS tract remap in `join_geospatial.py` | **done**, tested |
| 3 | Stage the stock estimate and tract list as `2026-09-16_12-13_*` | **done** |
| 4 | Regenerate the bucket definition files | **done** — 8,634 buckets. `sample_input_20260919-1409_8634.csv` and `_103608.csv` (8,634 × 12). The two 2025-09-16 files are untouched. |
| 5 | Sample the ~10k: `tsv_sampling.py v35 2018 8634 1 hardsize -p sample_input_20260919-1409_8634.csv` | **done** — 8,634 rows, 97 cols, 1.7 min |
| 6 | Sample the ~100k: `tsv_sampling.py v35 2018 103608 12 hardsize -p sample_input_20260919-1409_103608.csv` | **running** (sequential — the sampler saturates every core) |
| 7 | `join_geospatial.py` on both | **10k done**, 119 cols, 1 tract resampled, no nulls; 100k pending step 6 |
| 8 | Cut the 100-row subset of the ~10k, with provenance | **done** — seed 20260919 |
| 9 | Commit bucket files; report | bucket files committed in `23e2c737`; buildstocks are gitignored |

### Outputs so far

All under `sampling/output-buildstocks/`, **gitignored — on disk only**:

| file | rows | cols |
|---|---:|---:|
| `buildstock_20260919-1409_v35_2018_ccaradon_8634_hardsize.csv` (intermediate) | 8,634 | 97 |
| `buildstock_20260919-1409_v35_2018_ccaradon_8634_hardsize.csv` (final) | 8,634 | 119 |
| `buildstock_20260919-1409_v35_2018_ccaradon_100_hardsize.csv` (both) | 100 | 97 / 119 |
| `..._100_hardsize.provenance.csv` (both) | 100 | 2 |

Checks that passed on the ~10k: `baseline_hvac_sizing` is uniformly `hardsize`, `year_of_simulation`
uniformly `2018`, 15 building types, 209 hospitals, no blank tracts, `Building` contiguous 1..N after the
join, no blank geospatial values, and no retired FIPS left in the `tract` column. The join reported
"Resampling 1 tracts", and one row fell in a remapped county — so section 4.1's fix was exercised on live
data and held.

The 100 is verified row-for-row identical to its parents in the ~10k, not an independent draw. Provenance
is 1-based in `final` and 0-based in `intermediate`, matching each file's own `Building` convention.

**Expected duration.** The 2026-09-06 set ran 22:04 → 03:25 for its 114,360-row sample, so budget
roughly five hours for the ~100k. The ~10k is much quicker. `generate_sampling_input` warns
"~15 minutes per 1,000 buckets" for buckets it has to add beyond the 99%-coverage set.

---

## 3. The pipeline, and the parameters chosen

```
hospital_v2 TSVs ──┐
                   ├─→ tsvs-v35.zip ──→ tsv_sampling.py ──→ join_geospatial.py ──→ buildstock
building_estimate ─┴─→ Apportion ──→ sample_input_*.csv ──┘                              │
                                                                          random 100 ────┘
```

| parameter | value | why |
|---|---|---|
| `tsv_version` | `v35` | v34 is taken; see section 5 |
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

* `v34` is taken, so this set is **`v35`** — but v35 is based on **v33**, so numerically it is above v34
  while containing none of v34's changes. If the two lineages ever need to combine, that is a deliberate
  merge someone has to perform; it will not happen by version ordering.
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
| **H4** | Is `v35`-based-on-`v33` the numbering you want? | The alternative is rebasing this set on the CBECS v34, which the instruction rules out for now. |

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
