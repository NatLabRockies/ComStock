# Integration result branch comparison

Run `python test/plot_integration_branch_comparison.py` from the repository
root. The configuration is in `test/integration_branch_comparison.yml`; it
reads the integration CSV results and writes category-specific interactive
HTML scatterplots and a comparison CSV to the configured output directory.
The YAML config selects the metrics in each file: total site energy, fuels,
and end uses. In each plot, rows are metrics, columns are building types, and
point colors represent upgrades. Points pair results by upgrade name, building
ID, and state. Each subplot compares base values on the x-axis with feature
values on the y-axis, with equality and +/-10% lines.
This assumes building IDs refer to the same sampled buildings on both branches.
Unmatched rows are reported in the CSV and workflow log.

Until base-branch results are available, the base series is mocked by applying
seeded noise to each feature-branch result. To use real local base results later,
set `base_results_dir` in the YAML file. The script does not fetch branches or
download results.

The integration workflow runs the plot after preparing published results and
uploads the HTML and CSV as the `integration-branch-comparison` artifact. It
currently runs on `ci-testing` pushes or manual dispatch, not pull requests.
Once pull-request runs and base results are available, enable the commented
base-branch checkout and configuration steps in `.github/workflows/config.yml`.
They set `base_results_dir` for pull requests only; push and manual runs
continue using mocked results.
