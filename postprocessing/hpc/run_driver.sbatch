#!/bin/bash -l
#SBATCH --account=eusscom
#SBATCH --partition=standard
#SBATCH --time=12:00:00
#SBATCH --nodes=1
#SBATCH --mem=0
#SBATCH --job-name=cspp
# The Slurm job that runs one ComStock postprocessing driver. submit_driver.sh submits it after its checks
# and sets the account, partition, time, job name and log path; options given to sbatch override the
# #SBATCH defaults above. To submit it without the checks, from the checkout's postprocessing/ folder:
#
#   sbatch --account=<project> --time=<hh:mm:ss> hpc/run_driver.sbatch compare_upgrades.py
#
# The job activates the env (CSPP_ENV; by default the env named in constraints.txt), reads the env's files
# ahead of the first import (unless CSPP_PREWARM=0), checks and exports the AWS keys from ~/.aws/credentials
# (unless CSPP_NO_AWS=1), and runs the driver in the checkout's postprocessing/ folder with that folder
# first on PYTHONPATH, so it uses that checkout's comstockpostproc.
set -eo pipefail
DRIVER=$(readlink -f "${1:?usage: sbatch run_driver.sbatch <driver.py>}")
if [ ! -f "$(dirname "$DRIVER")/hpc/common.sh" ]; then
    echo "ERROR: $DRIVER is not in a checkout's postprocessing/ folder" >&2
    exit 2
fi
source "$(dirname "$DRIVER")/hpc/common.sh"

echo "job $SLURM_JOB_ID ($SLURM_JOB_NAME) on $(hostname), start $(date '+%F %T')"
echo "driver $DRIVER"
cspp_activate_env
echo "env $CSPP_ENV, $(python --version)"
cspp_prewarm_env
export PYTHONPATH="$CSPP_PP_DIR${PYTHONPATH:+:$PYTHONPATH}"
python -W ignore::SyntaxWarning -c 'import comstockpostproc as c; print("comstockpostproc from", c.__path__[0])'

if [ "${CSPP_NO_AWS:-0}" != 1 ]; then
    if ! bash "$CSPP_HPC_DIR/check_aws.sh" --quiet; then
        echo "The AWS keys cannot be used (see above), so the job stops before the driver runs." >&2
        exit 2
    fi
    source "$CSPP_HPC_DIR/aws_env.sh"
fi

cd "$CSPP_PP_DIR"
set +e
python -u "$DRIVER"
RC=$?
echo "end $(date '+%F %T'), exit code $RC"
exit $RC
