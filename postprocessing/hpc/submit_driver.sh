#!/bin/bash
# Submits a postprocessing driver (a copy of one of the postprocessing/*.py.template files) as a Slurm job
# on Kestrel. First it checks on the login node that the job can run: the driver is in this checkout's
# postprocessing/ folder and parses, the env matches the checkout, and the AWS keys work. A driver whose
# KESTREL_JOB setting is filled in runs this script itself when it is started on a login node.
#
#   bash postprocessing/hpc/submit_driver.sh compare_upgrades.py
#   bash postprocessing/hpc/submit_driver.sh --time 4:00:00 --partition bigmem compare_runs_mixed.py
#   bash postprocessing/hpc/submit_driver.sh --partition shared --mem 32G --cpus 4 compare_upgrades.py
#
# Options, with their defaults:
#   --account eusscom      the HPC project the job is charged to
#   --partition standard   standard: a whole node. bigmem: more memory than a standard node has. shared: part
#                          of a node, for a small job such as a rerun from caches; it needs --mem
#   --time 12:00:00        time limit
#   --mem 0                memory; 0 is the whole node. On the shared partition give it, for example 32G
#   --cpus N               cores (default: the whole node on standard, 1 on shared)
#   --qos QOS              for example high, for projects that have it
#   --mail ADDRESS         email ADDRESS when the job ends or fails
#   --env DIR              the env (default: the one named in constraints.txt; see setup_kestrel_env.sh)
#   --job-name cspp_<driver name>
#   --no-aws               no AWS check and no keys, for a driver that needs no AWS access
#   --dry-run              check, then print the sbatch command instead of submitting it
#   -- ARGS                everything after -- goes to sbatch as it is
# The job's log is postprocessing/logs/<job name>_<job id>.out.
set -eo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ACCOUNT=eusscom
PARTITION=standard
TIME=12:00:00
MEM=0
CPUS=
QOS=
MAIL=
JOB_NAME=
USE_AWS=1
DRY_RUN=0
DRIVER=
SBATCH_EXTRA=()
while [ $# -gt 0 ]; do
    case $1 in
        --account) ACCOUNT=$2; shift 2 ;;
        --partition) PARTITION=$2; shift 2 ;;
        --time) TIME=$2; shift 2 ;;
        --mem) MEM=$2; shift 2 ;;
        --cpus) CPUS=$2; shift 2 ;;
        --qos) QOS=$2; shift 2 ;;
        --mail) MAIL=$2; shift 2 ;;
        --env) CSPP_ENV=$(readlink -m "$2"); export CSPP_ENV; shift 2 ;;
        --job-name) JOB_NAME=$2; shift 2 ;;
        --no-aws) USE_AWS=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) cspp_usage "$0"; exit 0 ;;
        --) shift; SBATCH_EXTRA=("$@"); break ;;
        -*) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
        *)
            if [ -n "$DRIVER" ]; then
                echo "one driver per job: $DRIVER and $1" >&2
                exit 2
            fi
            DRIVER=$1; shift ;;
    esac
done
if [ -z "$DRIVER" ]; then
    cspp_usage "$0"
    exit 2
fi
case $PARTITION in
    shared|sharedl)
        if [ "$MEM" = 0 ]; then
            echo "ERROR: a job on the $PARTITION partition states its memory: add --mem, for example --mem 32G" \
                 "(in KESTREL_JOB: mem='32G')" >&2
            exit 2
        fi ;;
esac

# The driver must be in this checkout's postprocessing/ folder, so that the job imports this checkout's code.
if [ -f "$DRIVER" ]; then
    DRIVER=$(readlink -f "$DRIVER")
elif [ -f "$CSPP_PP_DIR/$DRIVER" ]; then
    DRIVER=$CSPP_PP_DIR/$DRIVER
else
    echo "ERROR: there is no driver $DRIVER, here or in $CSPP_PP_DIR" >&2
    exit 2
fi
if [ "$(dirname "$DRIVER")" != "$CSPP_PP_DIR" ]; then
    echo "ERROR: $DRIVER is not in $CSPP_PP_DIR. Drivers run from the postprocessing/ folder of the" \
         "checkout whose code they use; put the driver there, or use that checkout's submit_driver.sh." >&2
    exit 2
fi
JOB_NAME=${JOB_NAME:-cspp_$(basename "$DRIVER" .py)}

echo "== checks before submitting"
cspp_activate_env
python -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$DRIVER"
python "$CSPP_HPC_DIR/check_env.py" --no-export --quiet
if [ "$USE_AWS" = 1 ]; then
    bash "$CSPP_HPC_DIR/check_aws.sh" --quiet
fi

SBATCH_ARGS=(--parsable --account="$ACCOUNT" --partition="$PARTITION" --time="$TIME" --nodes=1 --mem="$MEM"
             --job-name="$JOB_NAME" --output="$CSPP_PP_DIR/logs/%x_%j.out"
             --export="ALL,CSPP_ENV=$CSPP_ENV,CSPP_NO_AWS=$((1 - USE_AWS))")
if [ -n "$CPUS" ]; then SBATCH_ARGS+=(--cpus-per-task="$CPUS"); fi
if [ -n "$QOS" ]; then SBATCH_ARGS+=(--qos="$QOS"); fi
if [ -n "$MAIL" ]; then SBATCH_ARGS+=(--mail-type=END,FAIL --mail-user="$MAIL"); fi
SBATCH_ARGS+=("${SBATCH_EXTRA[@]}")
if [ "$MEM" = 0 ]; then MEM_TEXT="the whole node's memory"; else MEM_TEXT="memory $MEM"; fi
RESOURCES="account $ACCOUNT, partition $PARTITION, time $TIME, $MEM_TEXT${CPUS:+, $CPUS cores}${QOS:+, qos $QOS}"

if [ "$DRY_RUN" = 1 ]; then
    echo "== dry run: the checks passed; this would submit ($RESOURCES):"
    printf '%q ' sbatch "${SBATCH_ARGS[@]}" "$CSPP_HPC_DIR/run_driver.sbatch" "$DRIVER"
    echo
    exit 0
fi
mkdir -p "$CSPP_PP_DIR/logs"
JOB_ID=$(sbatch "${SBATCH_ARGS[@]}" "$CSPP_HPC_DIR/run_driver.sbatch" "$DRIVER")
JOB_ID=${JOB_ID%%;*}
LOG=$CSPP_PP_DIR/logs/${JOB_NAME}_$JOB_ID.out

echo "== submitted job $JOB_ID ($JOB_NAME)"
echo "driver   $DRIVER"
echo "job      $RESOURCES"
echo "env      $CSPP_ENV"
echo "log      $LOG"
echo "Follow it:"
echo "  squeue -j $JOB_ID              (queued or running; squeue --start -j $JOB_ID estimates the start)"
echo "  tail -f $LOG"
echo "  sacct -j $JOB_ID -o JobID,State,Elapsed,MaxRSS    (after it ends)"
echo "  scancel $JOB_ID                (to stop it)"
if [ -n "$MAIL" ]; then
    echo "An email goes to $MAIL when the job ends or fails."
fi
if [ "$USE_AWS" = 1 ]; then
    echo "The job reads the AWS keys when it starts. If it waits in the queue until they expire, it stops" \
         "at the start; then paste fresh keys and submit again."
fi
