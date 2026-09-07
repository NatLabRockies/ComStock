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


### Calibration / QAQC assessment

Compares one or more ComStock runs against CBECS, AMI, and each other, writing
metric CSVs plus one self-contained `dashboard.html`. Deterministic: Athena SQL,
pandas, and a hand-written JS bundle.

It reads the published Athena aggregate tables that `create_sightglass_tables`
creates, so it must run **after** that step. It is safe to leave enabled either
way -- if the tables are not reachable it skips with a stated reason rather than
failing the run.

1. Copy the `compare_calibration.py.template` file to `compare_calibration.py`
2. Edit `compare_calibration.py` to point at the run you are reviewing, and at
   any published releases you want to compare against
3. Open an Anaconda prompt, activate the environment, and run the file:
    ```
    $ conda activate comstockpostproc
    $ python compare_calibration.py
    ```
4. Open the dashboard at `<the run's output folder>/calibration/dashboard.html`

   The assessment writes into a `calibration/` subfolder of the folder that
   run's results already go to -- the comparison folder when a
   `ComStockToCBECSComparison` is passed, otherwise `output/ComStock <run>/`.
   It never creates a top-level folder of its own. Metric CSVs, `findings.md`
   and the exact SQL are in that same subfolder.

Notes:
 - A comparison release is referenced by its Athena tables alone (`AthenaRunRef`),
   so it needs no local simulation results and no apportionment.
 - `cbecs` and `ami` are optional. Each must have had its export run
   (`export_to_csv_wide()`), and a missing one skips only the legs that need it.
 - The upgrade list is taken from the run's own data. Do not rely on
   `include_upgrades` or `upgrade_ids_to_skip` to control it.

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
