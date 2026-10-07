Pull request overview
---------------------
<!--- DESCRIBE PURPOSE OF THIS PULL REQUEST -->
 - Fixes #ISSUENUMBERHERE (IF RELEVANT)

### Pull Request Author
This pull request makes changes to (select all the apply):
 - [ ] Documentation
 - [ ] Infrastructure (includes apptainer image, buildstock batch, dependencies, continuous integration tests)
 - [ ] Sampling
 - [ ] Workflow Measures
 - [ ] Upgrade Measures
 - [ ] Reporting Measures
 - [ ] Postprocessing

This pull request is expected to (select one):
 - [ ] Change model results (sampling, simulation, or reported outputs)
 - [ ] **Not** change model results; the benefit is elsewhere. Complete the "No Result Change" section below.

Primary benefit, if no result change (select all that apply):
 - [ ] Code simplification / maintainability
 - [ ] Simulation runtime or HPC node-hours
 - [ ] Postprocessing runtime or memory
 - [ ] Data volume (file size, column count, file count, Athena/S3 cost)
 - [ ] Reliability (lower failure rate, fewer retries)
 - [ ] Developer tooling / CI

### Pull Request Author Checklist:
<!--- Base checklist. Remove list items that do no apply. -->
 - [ ] Tagged the pull request with the appropriate label (documentation, infrastructure, sampling, workflow measure, upgrade measure, reporting measure, postprocessing, no-results-change) to help categorize changes in the release notes.
 - [ ] Added or edited tests for measures that adequately cover anticipated cases
 - [ ] New or changed register values reflected in `comstock_column_definitions.csv`
 - [ ] Both `options_lookup.tsv` files updated
 - [ ] New measure tests add to to `test/reporting_measure_tests.txt`, `test/workflow_measure_tests.txt`, or `test/upgrade_measure_tests.txt`
 - [ ] Added 'See ComStock License' language to first two lines of each code file
 - [ ] Run rubocop and ensure no ADDITIONAL errors or errors in functions / files edited
 - [ ] Updated measure .xml(s)
 - [ ] Ran 10k+ test run and checked failure rate to make sure no new errors were introduced (for no-result-change PRs, paired with a baseline run on the same sample)
 - [ ] Measure documentation written or updated
<!--- Additional items for core changes. -->
 - [ ] ComStock documentation written or updated
 - [ ] Change document written and assigned to a reviewer (for no-result-change PRs, the equivalence and benefit tables below may serve as the change document)
 - [ ] Changes reflected in example `.yml` files and `README.md` files
 - [ ] All new / modified functions have docstrings

### No Result Change
<!--- Delete this section if this pull request changes results. -->

#### Result equivalence evidence
<!--- Describe the comparison: sample, size, baseline commit, tolerance. -->
| Item | Value |
|---|---|
| Baseline commit (main) | |
| Sample used (buildstock.csv / size) | |
| Comparison method | e.g. `compare_runs.py`, `pd.testing.assert_frame_equal`, OSM/IDF diff |
| Tolerance | exact / rel 1e-6 / other (justify) |

#### Benefit evidence
<!--- Measure the baseline and this branch the same way: same inputs, same hardware. -->
| Metric | main | this PR | Change | How measured |
|---|---|---|---|---|
| | | | | |

#### Author checklist: verify no result change
 - [ ] Ran the **same** sample (same buildstock.csv, weather, seed, upgrades) on the baseline commit and on this branch
 - [ ] Annual results match **per building**, not only in aggregate, for every `out.*` column (offsetting differences can hide in totals)
 - [ ] Characteristic / metadata columns (`in.*`) are identical, including sampling output if sampling code was touched
 - [ ] The same set of buildings succeeded and failed in both runs
 - [ ] Result column set is unchanged (no added, dropped, renamed, or retyped columns) and `comstock_column_definitions.csv` is unchanged
 - [ ] Timeseries spot-checked for a few buildings that exercise the changed code paths
 - [ ] For workflow measure refactors: the OSM/IDF of a few affected buildings is identical, or the diff is explained
 - [ ] For postprocessing changes: output files match in row count, columns, dtypes, and values (e.g. `assert_frame_equal`)
 - [ ] The comparison sample exercises the changed code; if the change touches rare branches (specific building types, HVAC systems, climate zones), a targeted sample was used rather than relying on a random 10k run
 - [ ] Existing tests pass **without** changes to their expected values; any test edits are listed and justified
 - [ ] Any non-exact equality is explained (floating-point ordering, precision reduction such as float64 to float32, nondeterminism) and its magnitude reported
 - [ ] OpenStudio, EnergyPlus, openstudio-standards, and Python dependency versions are unchanged, or the version change is the point of the PR

#### Author checklist: verify the benefit
 - [ ] Baseline and branch measured with the same inputs on the same hardware / node type
 - [ ] Runtime claims use repeated runs (median reported, or noted as a single run) and state whether wall-clock, per-building, or node-hours
 - [ ] Data reduction claims report before/after file size, file count, or column count, and note any precision lost
 - [ ] Simplification claims list what was removed or consolidated (duplicated logic, dead code, net LOC, rubocop offenses)
 - [ ] Checked for regressions elsewhere (e.g. faster but higher peak memory; smaller files but slower reads)
 - [ ] If file layout or format changed, downstream consumers still work (Tableau workbooks, results dashboards, OEDI schema, Athena tables)

### Pull Request Reviewer Checklist:
<!--- Base checklist. Remove list items that do no apply. -->
 - [ ] Perform a code review on GitHub
 - [ ] `.yml` and `README.md` files updated
 - [ ] Author had ensured all modified and new functions have docstrings
 - [ ] All changes have been implemented: data, methods, tests, documentation
 - [ ] Measure tests written and adequately cover anticipated cases
 - [ ] Run measure tests and ensure they pass
 - [ ] New measure tests add to to `test/reporting_measure_tests.txt`, `test/workflow_measure_tests.txt`, or `test/upgrade_measure_tests.txt`
 - [ ] Ensured code files contain License reference
 - [ ] (when CI works) Confirm no additional rubocop errors
 - [ ] Check edited measure .xml files updated
 - [ ] (when CI works) CI status: all tests pass
<!--- Additional items for core changes. -->
 - [ ] ComStock documentation adequately describes the new assumptions
 - [ ] Reviewed change documentation, results differences are reasonable (zero or within the stated tolerance for no-result-change PRs), and no new errors introduced
 - [ ] Author has addressed comments in change documentation
<!--- Additional items for no-result-change PRs. -->
 - [ ] Equivalence evidence covers the code paths actually changed (the sample includes the affected building types / systems)
 - [ ] Comparison is per building (or per row), not only aggregate
 - [ ] Tests were not loosened or rebaselined to make the PR pass
 - [ ] Benefit measurement method is sound, and reproduced where practical
 - [ ] Any tolerance or precision change is acceptable for downstream users

#### ComStock Licensing Language - Add to Beginning of Each Code File
```
# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
```
