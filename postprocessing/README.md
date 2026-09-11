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

### Comparing one or more ComStock runs to each other and CBECS

1. Copy the `compare_runs.py.template` file to `compare_runs.py`
2. Edit `compare_runs.py` to point to the ComStock runs you want to plot
3. Open an Anaconda prompt, activate the environment, and run the file:
    ```
    $ conda activate comstockpostproc
    $ python compare_runs.py
    ```
4. Look in the `/output` directory for results

### Comparing upgrades in a single ComStock run

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
`compare_comstock_to_cbecs.py` or `compare_comstock_to_ami.py` -- each of which
carries these settings near the top (`compare_runs.py` has no local
metadata export and omits `EXPORT_LOCAL_METADATA`):

```python
# ---- Settings ---------------------------------------------------------------
# Details in README, "Results dashboard".
ATHENA_DATABASE        = 'enduse'  # database the run's tables are crawled into and read from. Keep 'enduse':
                                   # the timeseries plots and the AMI comparison hard-code it
EXPORT_LOCAL_METADATA  = False     # local copies of the metadata aggregates (Tableau); nothing here reads them
REBUILD_ATHENA_TABLES  = False     # False: reuse S3 exports + Athena tables that exist, build only what is missing
                                   # True:  export and crawl again (what is up there is stale)
MAKE_RESULTS_DASHBOARD = True      # write <comparison folder>/results_dashboard/dashboard.html
INCLUDE_AMI            = False     # metered load-shape tab; needs the county export (~3,100 files per upgrade)
                                   # and the run's <run>_timeseries table (from buildstockbatch's crawl)
COMPARE_TO_RELEASES    = []        # published releases to compare against, e.g.
#   [dict(key='r3_2025', label='2025 R3', md_table='comstock_amy2018_r3_2025_md_agg_national_parquet',
#         database='buildstock_sdr', color='#E69F00')]
```

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

Open `dashboard.html` in the `results_dashboard/` subfolder of the comparison's
own output folder: `output/CBECS 2018 vs ComStock <version> - Baseline/` for
`compare_comstock_to_cbecs.py` (`compare_runs.py` appends ` +1 more`, keeping the
shortest names when the path would get long), `output/ComStock
<version>/measure_runs/` for `compare_upgrades.py`, and `output/ComStock <version>
vs AMI v01/` for `compare_comstock_to_ami.py`. The log line `results dashboard:
...` states the exact path. Without a comparison object it is `output/ComStock
<version>/results_dashboard/`; it never creates a top-level folder of its own.
Metric CSVs, `findings.md` and the exact SQL are in that same subfolder.

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
   resolution -- the expensive one, one file per state-county pair, per upgrade
   -- and crawls it. Without it the AMI leg skips and says so, and the cause is
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
