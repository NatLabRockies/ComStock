# ComStock Postprocessing

This package automates the common postprocessing tasks that are part of running ComStock. It includes:

- Downloading ComStock results from S3
- Downloading CBECS data from S3
- Scaling ComStock results to national scale using CBECS
- Plotting comparisons of one or more ComStock runs and CBECS versions
- Exporting data to CSV for plotting using other tools

## Assumptions

1. A ComStock run exists and results have been pushed to the S3 RESBLDG account
2. You have set up credentials for accessing the S3 RESBLDG account

## AWS Access

### Athena Workgroup

Athena queries run in a named workgroup, set once in
`comstockpostproc/athena_config.py` as `ATHENA_WORKGROUP` and imported by every
query site. It currently points at `buildstock`. If your account uses a
different workgroup, change it in that one file rather than at the call sites.
The workgroup must have a query result location configured, since the client
does not supply one.

### Non-NREL Staff

To download your BuildStockBatch simulation results from S3 for postprocessing, you’ll need to configure your user account with your AWS credentials. This setup only needs to be done once.

1. [Install the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-install.html) version 2
2. [Configure the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html#cli-quick-configuration). (Don’t type the `$` in the example.)
3. You may need to [change the Athena Engine version](https://docs.aws.amazon.com/athena/latest/ug/engine-versions-changing.html) for your query workgroup to v2 or v3.

### NREL Staff

NREL now uses a refreshable Single Sign On (SSO) approach for authentication of accounts.

### If you have already configured the SSO for the resbldg AWS account:

1. Set the `AWS_DEFAULT_PROFILE` environment variable to the alias for your AWS resbldg SSO account.
    - On Windows, the command is `set AWS_DEFAULT_PROFILE=my_resbldg_account_alias`
    - On OSX, the command is `export AWS_DEFAULT_PROFILE=my_resbldg_account_alias`
2. Run the following command to activate the SSO: `aws sso login` - follow the prompts in the webpage

You're now ready to execute the commands below! In case of an AWS access error please begin by running the login command again. The SSO does time out eventually.

### To configure SSO for the resbldg account

Note: Access to the SSO requires an NREL network account. We do not currently support use of the sampler for users without an NREL account.

1. Go to the [NREL AWS SSO page](https://nrel-ace.awsapps.com/start#/) and click on the AWS Account button.
2. Click on the NREL AWS RESBLDG dropdown. If you do not see the dropdown email the [CSC team](mailto:StratusCloudHelp@nrel.gov) and ask for accesss to the resbldg account.
3. Click on an available role (typically `developer`) and then click the `Command line or programatic access` link.
4. Follow the steps listed in the `AWS IAM Identity Center credentials (Recommended)` section.
5. Remember the name you give the profile during the configuration. This is the value you will set the `AWS_DEFAULT_PROFILE` enviornment variable to.
6. Open the `credentials` file inside your home directory:
    - On Windows, this is: `C:\Users\myusername\.aws\credentials`
    - On Mac, this is: `/Users/myusername/.aws/credentials`
7. If there are any values set under the `default` profile either rename the profile (replace the word `default` with something else) or delete the section. For reference a default profile in the `credentials` file looks like the following and should be deleted:
    ```
    [default]
    aws_access_key_id = AKIAIOSFODNN7EXAMPLE
    aws_secret_access_key = wJalrX+UtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
    ```
8. Follow the steps above to set the `AWS_DEFAULT_PROFILE` and login to the resbldg account.

## Installation

Create a new conda environment with **python 3.12.12** or above (only need to do this once):
```
# Local
$ conda create -y -n comstockpostproc python=3.12.12 pip
$ conda activate comstockpostproc

# HPC Eagle (NREL Staff)
$ module load conda
$ conda create -y --prefix /projects/cscore/envs/comstockpostproc_<myname> -c conda-forge "python=3.9"
$ conda activate /projects/cscore/envs/comstockpostproc_<myname>

# HPC Kestrel (NREL Staff)
$ module load python
$ python -m venv --clear --upgrade-deps --prompt "comstockpostproc_<myname>" "/kfs2/projects/cscore/envs/comstockpostproc_<myname>"
$ source "/kfs2/projects/cscore/envs/comstockpostproc_<myname>/bin/activate"
```

Navigate to the `/postprocessing` directory of this repo:
```
$ cd /path/to/ComStock/postprocessing
```

Make sure you are using the latest version of `pip`:
```
$ pip install --upgrade pip
```

Install the libraries needed for this repository:
```
$ pip install -e .[dev]
```

If running the ComStock Gap Model, install the required libraries with:
```
$ pip install -e .[dev,gap]
```

## Usage

### Template settings

Each template starts with a settings block: the things you change from run to run. The
code below `main()` reads them and normally needs no edits. Only `compare_upgrades` and
`compare_runs_and_upgrades` load upgrades, and each has an **Upgrades** section for them. The
other templates are baseline only and have no upgrade settings. The single-run templates
(`compare_upgrades`, `compare_comstock_to_cbecs`, `compare_comstock_to_ami`) take:

| Setting | What it does |
|---|---|
| `S3_BASE_DIR`, `RUN_NAME` | Where the run was uploaded (`postprocessing.aws.s3` in its yml) and its name, which is also the prefix of its Athena tables. For a run that is not on S3, put its `results_up*.parquet` files in `comstock_data/<RUN_VERSION>/` by hand. |
| `RUN_VERSION` | Names the run's folder, `output/ComStock <RUN_VERSION>/`, and labels the run in plots. On Windows the checkout path, this name and about 150 more characters must stay under 260. |
| `ACCEPTABLE_FAILURES` | The share of failed simulations tolerated. |
| `REUSE_CACHES` | `True` reuses what earlier passes built when it still fits; `False` rebuilds it. See **Caches**. |
| `STOCK_ESTIMATE` | The stock estimate the run's sample was drawn from; `sampling/README.md` pairs each bucket file with its estimate. A wrong one mis-weights every result, and only `compare_runs_and_upgrades` checks it (`CHECK_SAMPLE_PAIRING`). |
| `WEIGHTS` | `'auto'` or a weights file. See **Weights**. |
| `ATHENA_DATABASE` | Where the run's tables are crawled and read. Keep `'enduse'`: the timeseries figures and the AMI comparison read it. |
| `REBUILD_ATHENA_TABLES` | `True` exports and crawls the run's tables again, overwriting what is on S3. `False` builds only what is missing. |
| `ATHENA_EXPORTS` | In `compare_upgrades`: `'auto'`, or levels to add. See **Exports**. |
| `LOCAL_EXPORTS` | Local copies of the metadata aggregates for other tools such as Tableau, in the run's folder: `'national_by_state'` and/or `'by_state_and_county'`. Nothing in postprocessing reads them. |
| `MAKE_RESULTS_DASHBOARD`, `INCLUDE_AMI`, `COMPARE_TO_RELEASES`, `MAKE_COMPARISON_PLOTS` | The outputs: the dashboard, its AMI tab, published releases to compare against, and the template's figures. See "Results dashboard" below. |

The **Upgrades** section of `compare_upgrades`:

| Setting | What it does |
|---|---|
| `UPGRADE_IDS_TO_SKIP` | Upgrades to leave out; every other upgrade of the run on S3 is loaded. |
| `UPGRADE_ALIASES` | Short upgrade names in figures. See "Upgrade names, plot aliases and measure IDs" below. |
| `TIMESERIES_LOCATIONS` | Load-shape locations for the dashboard's Measures tab and the measure figures: state codes or county IDs such as `'G2500250'`, a tuple key combining several. A county adds county tables for every upgrade (see **Exports**). |
| `MAKE_COMPARISON_PLOTS`, `MAKE_TIMESERIES_PLOTS`, `UPGRADE_GROUPS` | The measure figures in `measure_runs/`, their load-shape figures, and figures comparing groups of upgrades. The dashboard needs none of them. |

`compare_runs` takes one settings dict per run (`RUN_A`, `RUN_B`) with the same items, and
`weights` in place of `WEIGHTS`. `compare_runs_and_upgrades` takes its `RUNS` list, and an
Upgrades section that adds `INCLUDE_UPGRADES` and applies to the run under review (see "Any
mix of runs and upgrades" below). Use it for runs sampled against different stock estimates,
or to compare one run's upgrades with other runs.

**Weights.** The stock allocation weights say which model stands for each building in the
stock estimate, and with what weight. Bills, exports and Athena tables are built from them.
The draw is random, so two draws differ model by model; reusing one file keeps results
repeatable. `WEIGHTS` takes:

| Value | What happens |
|---|---|
| `'auto'` (default) | Use `output/ComStock <RUN_VERSION>/cached_ComStock_alloc_wts.parquet` when it was drawn for this estimate and sample (a fingerprint of `buildstock.csv`). Otherwise draw new weights and save them there. To draw again, delete that file. |
| a path or `s3://` URL | Use exactly that weights file. It is checked against the run (same estimate, bootstrap coefficient and sample; otherwise the run stops) and copied into the run's folder, where `'auto'` finds it next time. |

Every postprocessed run publishes its weights beside its exported tables, at
`s3://<s3_base_dir>/<run>/<run>/cached_ComStock_alloc_wts.parquet`. To make a run of only
your measures match a published dataset, point `WEIGHTS` at the weights that dataset was
postprocessed with. Your run must use the same `buildstock.csv` and estimate; reading from
S3 needs AWS access.

**Caches.** A pass reuses what earlier passes built, when it still fits, and builds what is
missing. Before anything expensive starts, the log lists every cache with what this pass will
do with it and when it was written.

| Cache | Where | Reused when |
|---|---|---|
| Downloaded results and `buildstock.csv` | `comstock_data/<RUN_VERSION>/` | Always: a file is downloaded only when it is absent. Delete it to download it again. |
| Processed simulation outputs | `output/ComStock <RUN_VERSION>/cached_simulation_outputs/` | There is one for every upgrade the run loads, newer than its results file. |
| Apportionment | `output/Stock Estimation <STOCK_ESTIMATE>/` | It exists. Every run on that estimate shares it. |
| Weights | `output/ComStock <RUN_VERSION>/cached_ComStock_alloc_wts.parquet` | It fits the run; `WEIGHTS` decides (above). |
| Bills | `output/ComStock <RUN_VERSION>/cached_allocated_weights_plus_bills/` | It was built from the weights this pass uses; checked per upgrade. |
| CBECS and AMI | `output/CBECS 2018/`, `output/AMI v01/` | Always: they depend on no run. |

`REUSE_CACHES = False` rebuilds the processed simulation outputs, the apportionment and the
bills, for changes the files cannot show: new postprocessing code or a changed estimate
file. It never redraws the weights. They are a random draw rather than a cache, and a new
draw changes every weighted result; to draw again, delete the weights file. Do that too when
an estimate file changed under the same name: the weights are matched to the estimate by
name, so the old draw would still fit. So a run can be
postprocessed from its results alone around existing weights: set `WEIGHTS` to the weights
file, and every cache is built (or rebuilt, with `REUSE_CACHES = False`) around it.

**Exports.** The S3 exports and Athena tables follow from the outputs you ask for, so no
template asks you to choose them. The national aggregate is exported for every upgrade the
run loads; the dashboard reads it. The county aggregate is exported for the baseline when
`INCLUDE_AMI` is on (the AMI tab and the AMI figures read upgrade 0 only), and for every
upgrade when a `TIMESERIES_LOCATIONS` entry is a county. In the two upgrade templates,
`ATHENA_EXPORTS = 'auto'` adds nothing, and a list adds levels for every upgrade, e.g.
`['by_state_and_county']` for county tables of every measure (about 3,100 files and 15
minutes per upgrade). A table that exists but lacks an upgrade this pass needs gets it
added: Athena is asked which upgrades the table holds.

### Upgrade names, plot aliases and measure IDs

`comstockpostproc/resources/comstock_upgrade_definitions.csv` has one row per upgrade:

| Column | Meaning |
|---|---|
| `upgrade_name` | The publication name: the upgrade's `upgrade_name` in the run's yml, exactly as it appears in the results. |
| `measure_id` | The measure or package ID, for example `hvac_0005` or `pkg_0003` (`baseline` for the baseline). It stays the same across releases, while upgrade numbers (positions in the yml) and sometimes names change. |
| `plot_alias` | A short name for figures and folders. |

How postprocessing uses it:

- Every run gets an `in.upgrade_measure_id` column when it loads, matched on the publication
  name, and every export carries it. To match an upgrade across releases, use this column,
  not `upgrade` or `in.upgrade_name`.
- `UPGRADE_ALIASES = True`, in the templates that load upgrades (`compare_upgrades`, and
  `compare_runs_and_upgrades` with `INCLUDE_UPGRADES`), labels figures and the measure
  comparison's `upNN_<name>` folders with the plot alias. Exported and cached files keep the
  publication name.
- An upgrade whose name is not in the file still runs: its `in.upgrade_measure_id` is empty,
  its figures keep the publication name, and a warning at load lists it. A run whose yml uses
  short names instead of the publication names gets this warning for every upgrade.

To add a measure, add a row with its publication name exactly as in the yml, its measure ID
(from the release's `measure_name_crosswalk.csv`, or the ID assigned to a new measure) and a
short alias. Never change or reuse an existing measure ID. For a release, this file is
generated with the yml from the release's upgrade table, so change names in that table, not
only here.

### Comparing one or more ComStock runs to each other and CBECS

1. Copy the `compare_runs.py.template` file to `compare_runs.py`
2. Edit `compare_runs.py` to point to the ComStock runs you want to plot
3. Open an Anaconda prompt, activate the environment, and run the file:
    ```
    $ conda activate comstockpostproc
    $ python compare_runs.py
    ```
4. Look in the `/output` directory for results

### Any mix of runs and upgrades: already in Athena, postprocessed here, on one sample or several

`compare_runs_and_upgrades.py.template` is the general form of the two-run driver, and can
add the upgrades of the run under review. Instead of one
code block per run it takes a single `RUNS` list, one entry per run, each entry saying what
kind it is: `process` (postprocessed here: download, apportion to the entry's own stock
estimate, scale to CBECS, export, crawl), `athena` (already crawled by an earlier driver:
its tables are read, nothing is recomputed) or `release` (a published OEDI release). The
run under review is the one `REVIEW_RUN` names, and every view draws CBECS first and then the
runs in `RUNS` order, top to bottom = left to right. Runs on one sample share one apportionment and a run
on another sample gets its own, so the samples may differ, and a guard checks every
`process` run's sample against its stated estimate before anything expensive starts.
With no `process` entries it is the Athena-only case below and finishes in minutes.

**One stock allocation per sample.** Apportionment draws a model at random for every
building in the stock estimate, so two draws differ model by model (two draws of one
100k sample: 0.2% of models kept their weight, the median model's weight moved 18%) and
anything averaged over models moves a little with the draw even where no model changed.
`process` runs on one sample and estimate therefore share ONE draw: the run under review's
when it is among them, else the first listed; the others copy it, and the log says so
("SHARE <run>'s draw"). The draw file, `output/ComStock <v>/cached_ComStock_alloc_wts.parquet`,
carries its provenance in the parquet metadata -- the run, estimate and sample (a fingerprint
of `buildstock.csv`) it was drawn for -- and is reused only when that matches the run; a run
whose draw changed gets its bills and its Athena tables rebuilt. The export publishes the
draw beside the run's tables (`s3://<s3_base_dir>/<run>/<run>/cached_ComStock_alloc_wts.parquet`,
with `postprocessing_allocation.json` naming it), and a `process` entry adopts that published
draw by itself when it fits, so everyone who postprocesses or plots the run gets exactly the
published weights; `weights='<path or s3://...>'` (earlier name `allocation=`, still accepted)
names another file instead. The library
checks any adopted file fits the run and reports how many models it weights. Tables whose
record names a different draw are replaced only when this machine processed the run before
or the entry says `rebuild=True`, so a teammate never overwrites a published run by accident.
`comstockpostproc/allocation.py` has the details.

Caches work as in the single-run templates (**Caches** under "Template settings"): each is
reused when it fits and built when it is missing, and the log lists them before anything
expensive starts. `REUSE_CACHES = False` rebuilds every `process` run's simulation outputs,
apportionment and bills; it never redraws a run's weights. To redraw them, delete the run's
weights file, and set `rebuild=True` on the entry when its tables were published with the old
weights, so that they are replaced and the published weights are not adopted again. The
Athena exports follow from the dashboard as described under **Exports**; `ATHENA_EXPORTS`
adds levels for every `process` run.

**Samples.** Each `process` entry names the stock estimate its sample was drawn from. Runs on
different estimates may be compared, and the log says which run sits on which, but for the
building types the estimates allocate differently a difference is the estimate and the run,
not the run alone; say so wherever the results are presented. `CHECK_SAMPLE_PAIRING` checks
every pairing first: each (building type, tract) pair in the run's `buildstock.csv` must
exist in the estimate, since apportionment matches models to buildings on that pair. A
correct pairing has zero missing pairs; a wrong one misses hundreds to thousands, and without
the check it is silent (floor areas still match CBECS while the weights within each building
type are wrong).

**Order and upgrades.** Every view draws CBECS first and then the runs in `RUNS` order. The
findings, the scorecard, the AMI end-use stack and the Measures tabs are about `REVIEW_RUN`;
the delta arrows, the "moved toward CBECS" line and the heating-fuel gap column measure it
against `DELTA_REF`. In the Upgrades settings, `INCLUDE_UPGRADES = True` postprocesses the
upgrades of `REVIEW_RUN` (a `process` run) too: the dashboard gets its Measures tabs, each
upgrade against the run's own baseline, and the measure load shapes at `TIMESERIES_LOCATIONS`.
`UPGRADE_IDS_TO_SKIP` and `UPGRADE_ALIASES` work as in `compare_upgrades`. Comparison runs
load only their baseline.

1. Copy `compare_runs_and_upgrades.py.template` to `compare_runs_and_upgrades.py`
2. Fill in `RUNS` (in the order you want them drawn), `REVIEW_RUN`, `COMPARISON_NAME` and
   `DELTA_REF` at the top, and the Upgrades settings if you want the run's upgrades
3. Run it as above; everything lands in `output/<COMPARISON_NAME>/`

### Comparing upgrades in a single ComStock run

To compare one run's upgrades with other runs as well, use `compare_runs_and_upgrades` with
`INCLUDE_UPGRADES = True` (above).

1. Copy the `compare_upgrades.py.template` file to `compare_upgrades.py`
2. Edit `compare_upgrades.py` to point to the ComStock runs you want to plot
3. Open an Anaconda prompt, activate the environment, and run the file:
    ```
    $ conda activate comstockpostproc
    $ python compare_upgrades.py
    ```
4. Look in the `/output` directory for results

### Comparing a ComStock run to AMI data

1. Copy the `compare_comstock_to_ami.py.template` file to `compare_comstock_to_ami.py`
2. Edit `compare_comstock_to_ami.py` to point to the ComStock runs you want to plot.
    Note that your run should use a buildstock.csv generated from the 10k sample file in /sampling/resources/ami_comparison.csv
3. Open an Anaconda prompt, activate the environment, and run the file:
    ```
    $ conda activate comstockpostproc
    $ python compare_comstock_to_ami.py
    ```
4. Look in the `/output` directory for results


### Results dashboard

Compares one or more ComStock runs against CBECS, AMI, and each other, writing
metric CSVs plus one self-contained `dashboard.html`. Deterministic: Athena SQL,
pandas, and a hand-written JS bundle.

**For a run you are postprocessing**, this is a step inside the driver you
already use -- `compare_runs.py`, `compare_upgrades.py`,
`compare_comstock_to_cbecs.py` or `compare_comstock_to_ami.py` -- set by the
output settings at its top: `MAKE_RESULTS_DASHBOARD`, `INCLUDE_AMI` (the AMI tab),
`COMPARE_TO_RELEASES` (published releases to compare against) and
`MAKE_COMPARISON_PLOTS`. The multi-run drivers add `COMPARISON_NAME`, the folder
under `output/` that holds the comparison and its dashboard; keep it short on
Windows. A release is given as
`dict(key='r3_2025', label='2025 R3', database='buildstock_sdr',
md_table='comstock_amy2018_r3_2025_md_agg_national_parquet', color='#E69F00')`.

Every template writes the dashboard and skips the figures by default. The dashboard reads
only the Athena tables, so with `MAKE_COMPARISON_PLOTS = False` nothing is built for the
figures either: not the per-upgrade plotting table (`cached_plotting_by_upgrade`, minutes
per upgrade), nor the AMI template's timeseries download. Set `MAKE_COMPARISON_PLOTS = True`
to get the figures as well. In `compare_upgrades.py`, `MAKE_TIMESERIES_PLOTS = True` adds the
measure timeseries figures to them, so it does nothing on its own. The dashboard's
timeseries tab needs neither setting: the Athena tables it reads are prepared either way,
and it draws the locations in `TIMESERIES_LOCATIONS`.

The dashboard reads the same Athena tables the timeseries plots and the AMI
comparison do, and every driver gets them the same way: one
`cspp.prepare_athena_tables(...)` call per run, which checks Glue first and
exports, crawls and creates views only for what is missing. Nothing has to be
commented out on a second run; set `REBUILD_ATHENA_TABLES = True` when the
tables exist but are out of date (files for upgrades no longer in the run stay
on S3 and in the table). It logs and returns `False` rather than raising, so an
S3 or Glue problem cannot cost you the comparison plots that already completed
-- and if Glue cannot be listed at all (expired credentials) it exports nothing
rather than exporting blind. On `False` the dashboard skips the affected legs
and says why; the timeseries plots and the AMI comparison cannot, so those two
drivers stop with an error naming the cause. `cspp.ResultsDashboard(...)`
then reads the tables and creates **none** of its own: it skips what it cannot
find and says why, and a query that fails once it runs is caught the same way.

Two things it relies on that are not in the drivers: `prepare_athena_tables`
runs the Glue crawler in `us-west-2` with the IAM role
`service-role/AWSGlueServiceRole-default` (its `glue_service_role=` argument if
your account names it differently), and the dashboard caches query results
under `~/.cache/comstock_results_dashboard/` (`RESULTS_DASHBOARD_CACHE_DIR` to
move it); a run's cached results are dropped whenever its tables are exported
or crawled again, so a rebuild is never answered from the old tables.

Where the outputs go. Everything about one run is in that run's folder,
`output/ComStock <version>/`: its caches, stock allocation, bills and exports, the
figures of every comparison of that run alone (`measure_runs/` from
`compare_upgrades.py`, `cbecs_comparison/` from `compare_comstock_to_cbecs.py`,
`ami_comparison/` from `compare_comstock_to_ami.py`) and its dashboard,
`results_dashboard/dashboard.html`, whichever of those drivers made it. A comparison
of several runs (`compare_runs.py`, `compare_runs_and_upgrades.py`) goes in `output/<COMPARISON_NAME>/`, the name set at the top
of the driver (keep it short on Windows), with its dashboard in `results_dashboard/`
there; a comparison of several runs without a name is refused rather than named
after the runs. Shared by every run that uses them, and so in no run's folder:
`output/Stock Estimation <version>/` (the estimate's apportionment; each run's stock
allocation is drawn from it and names it), `output/CBECS 2018/` and
`output/AMI v01/`. The downloaded results are in `comstock_data/<version>/`. The log
line `results dashboard: ...` states the exact path; metric CSVs, `findings.md` and
the exact SQL are in that `results_dashboard/` folder.

Notes:
 - **Comparing your run to a published release** is what `COMPARE_TO_RELEASES`
   in each driver is for -- "is my run better or worse than the last release?".
   A release is referenced by its Athena tables alone, so it needs no download,
   no local simulation results and no apportionment. Releases live in
   `buildstock_sdr` while your own crawled run lives in `enduse`; the assessment
   reads both in one pass by qualifying the release's table names, so no extra
   setup is needed. A release whose tables cannot be found is reported as a
   dropped run in the dashboard rather than silently omitted.
 - The four drivers above cover a run you are postprocessing. See
   *Reviewing a run that is already in Athena* below for one that is not.
 - `cbecs` and `ami` are optional, and a missing one skips only the legs that
   need it. Each reads a truth CSV: `CBECS wide.csv`, which only
   `cbecs.export_to_csv_wide()` writes (the drivers call it), and `AMI long.csv`,
   which `AMI.__init__` writes when not reloading. `cspp.load_cbecs()`
   and `cspp.load_ami()` read the file if it is present and build it if
   not, so the Athena-only driver never has to know which.
 - **The AMI leg needs the county aggregate.** It weights by county, so it
   reads the run's `_md_agg_by_state_and_county_parquet` table, which only
   exists if that resolution was exported. `INCLUDE_AMI = True` is all a driver
   has to say: `prepare_athena_tables(..., ami=True)` exports the county
   resolution for the baseline -- the expensive one, one file per state-county
   pair (about 3,100) -- and crawls it. Without it the AMI leg skips and says so, and the cause is
   the export config, not the run.
 - **The AMI leg also needs a timeseries table, and nothing here creates one.**
   `<run>_timeseries` comes from buildstockbatch's own postprocessing crawl of
   the run; the crawler here only covers the metadata prefixes, and when that
   table is absent `prepare_athena_tables` skips the county export and returns
   `False` to a driver that asked for timeseries or AMI. What
   `prepare_athena_tables` does add is the `<run>_timeseries_vu` view, which
   translates the raw `electricity_<enduse>_kwh` columns into the
   `out.electricity.<enduse>.energy_consumption` names these queries use. The
   assessment prefers that view, and adapts to the two remaining differences
   from a published `<release>_ts_by_state` -- `building_id` vs `bldg_id`,
   `time` vs `timestamp` -- and to the `state` column crawled runs do not have
   (its only role was pruning a state-partitioned published table; the region is
   selected by the county filter on the metadata side). End-use columns are the
   union over the run's own models, so a run that metered no heat recovery just
   has one fewer layer in the stack. See `ts_dialect` in `results_dashboard/timeseries.py`.
 - AMI coverage is thin on a national run. Only about 2% of models are simulated
   in the counties of the ten AMI regions. On a national ~100k run that still
   gives roughly 70-240 models per (region x building type) cell, because
   apportionment spreads each model across the counties it represents -- the
   count that matters is models carrying WEIGHT in those counties, not models
   simulated there. Cells below `MIN_COMSTOCK_MODELS` are drawn but flagged with
   their model count, and the headline AMI numbers are for one region (`pepco`,
   the best-sampled) rather than a national result. The `v01` truth data covers
   9 of the 10 regions -- `seattle` has none and is reported as skipped.
 - The measure legs cover the run's `upgrade_ids_to_process`, so
   `upgrade_ids_to_skip` restricts them the same way it restricts the driver's
   own plots. `include_upgrades=False` turns them off: `prepare_athena_tables`
   then exports the baseline alone, so there would be nothing to read.
 - **Measure timeseries: seasonal averages and peak week by season.** The
   locations come from `measure_states` (by default a ComStock run's own
   `timeseries_locations_to_plot`). Besides the season x day-type averages, the
   leg writes each season's peak week, `measures_peakweek_<loc>.csv` and
   `measures_peaks_<loc>.csv`, cut from the same hourly data on two bases: the
   whole stock (one week per season, holding the highest hour among the stock
   baseline and every measure's whole-stock series, so all measures share it)
   and each measure's own applicable buildings (the `peak_week_by_state` rule of
   the measure plots). Weeks run Monday to Sunday in local standard time. The
   full hourly year is kept as `measures_ts_hourly_<loc>.parquet` for figures
   the page does not draw. On the page, the tab's sticky "Jump to" bar links
   each panel and carries a peak-week season picker (all seasons by default;
   the seasonal-peaks table always lists all three).

### Reviewing a run that is already in Athena

A published SDR/OEDI release, or a private run crawled by an earlier
postprocessing pass. Use this when you want the dashboard WITHOUT downloading or
reprocessing the run -- `sdr_2025_r3_combined` is 32 GB of local run data, and
its aggregate tables are already published, so there is nothing to repeat.

The four drivers above cannot do this: they build `cspp.ComStock` objects, and
`ComStock.__init__` downloads and globs `results_up*.parquet` unconditionally.
The assessment itself never opens run data, so a crawled run needs none of it.

1. Copy `results_dashboard_from_athena.py.template` to `results_dashboard_from_athena.py`
2. Edit it to name the run's `md_table` and database, plus any releases to
   compare against
3. Open an Anaconda prompt, activate the environment, and run the file:
    ```
    $ conda activate comstockpostproc
    $ python results_dashboard_from_athena.py
    ```

Two things differ from the driver path: `output_dir` is required (a table
reference carries no run folder to infer one from), and `include_measures` must
be stated explicitly for the same reason. This file only READS -- if the run has
not been crawled yet, run it through one of the four drivers with
`MAKE_RESULTS_DASHBOARD = True` first; their `prepare_athena_tables` call exports
and crawls the tables.
`compare_runs_and_upgrades.py.template` with only `athena` and `release` entries does the same
job from one run list, and can take the not-yet-crawled runs as `process` entries.

### NREL Staff - Extracting simulations and summarizing EnergyPlus warnings and errors on HPC

1. First time only: install `comstockpostproc` to your `comstockpostproc_<myname>` environment on HPC (see installation instructions above)
2. Navigate to your ComStock repo checkout:
    ```
    $ cd /projects/cscore/repos/comstock_<myname>/postprocessing
    ```
3. Copy the `/postprocessing/extract_models_and_errors.py.template` file to `extract_models_and_errors.py`
4. Edit `extract_models_and_errors.py` to point to the YML for your ComStock run
    This script can do four things. Each section has 1-2 lines of code you can comment out to turn off.

    1. **Extract and summarize failed runs:**
    This reads the `run.log` files for all failed models and concatenates the `[ERROR]` messages into `/my_run/results/simulation_output/failure_summary/failure_summary.log`. This is a fast way to see if lots of models failed for the same reason.

    2. **Extract models:**
    This extracts the `.osm`, `.idf`, `.html`, and `run.log` for a set of models from the `simulations_jobXYZ.tar.gz` files so that you can look at them for debugging.
        - Make a file called `building_id_list.csv` and save to `/my_run/building_id_list.csv`.
        - Edit `building_id_list.csv` so that the first row contains the header `building_id` and each subsequent row contains the ID of a building you want to extract.
        - Optionally, you can list output variables that get added to the extracted IDF files after they are extracted.

    3. **Run extracted IDFs with EnergyPlus:**
    This simply runs the extracted IDF files, including any new output variables that were added. This can be helpful for creating timeseries outputs for confirming detailed behavior in a subset of models in a run.

    4. **Extract and summarize warnings in eplusout.err files:** This reads the `eplusout.err` files from all the successful models and summarizes the count of each warning to `/my_run/simulation_output/eplusout_errors/eplusout_summary.tsv`. This helps identify systematic issues with model inputs.

    5. **Parse and summarize runs simulations logs for profiling:** Function `parse_and_generate_profiling` reads `simulations_jobXYZ.tar.gz` files and generate a report under `/my_run/results/simulation_output/profiling_summary/aggregate_profiling.csv`.

    6. **Summarize HPC usage:** This extracts the HPC runtime and usage from `sampling`, `simulation`, and `postprocessing.out` files and writes a summary CSV file into `/my_run/results/simulation_output/hpc_runtime_summary/hpc_runtime_summary.csv`'

5. Run:
    ```
    $ salloc --time=30 --qos=high --account=cscore --nodes=1
    ```
    to start an interactive job on a [compute node](https://www.nrel.gov/hpc/eagle-interactive-jobs.html). The postprocessing can take a while to run depending on the number of models; you can increase `--time=30` as necessary. Do not run `extract_models_and_errors.py` on a login node (i.e., without starting an interactive job), you will get an email about inappropriate login node use.
6. Navigate to your ComStock repo checkout:
    ```
    $ cd /projects/cscore/repos/comstock_<myname>/postprocessing
    ```
7. Load Anaconda, activate your environment, and run the file:
    ```
    $ module load conda
    $ conda activate /projects/cscore/envs/comstockpostproc_<myname>
    $ python extract_models_and_errors.py
8. Look in `/my_run/results/simulation_output` directory for outputs, see `/failure_summary`, `/model_files`, and `/eplusout_errors` depending on what parts of the script you included.
