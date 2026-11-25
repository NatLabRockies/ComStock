#!/bin/bash
# Finds, checks or builds the shared Python environment for ComStock postprocessing on Kestrel.
#
#   bash postprocessing/hpc/setup_kestrel_env.sh             check this checkout's env; build it if missing
#   bash postprocessing/hpc/setup_kestrel_env.sh --check     only check it (exit code 3 if it does not exist)
#   bash postprocessing/hpc/setup_kestrel_env.sh --rebuild   delete and rebuild it (only its owner can)
#   bash postprocessing/hpc/setup_kestrel_env.sh --env DIR   use DIR instead of the shared location
#
# The env is <CSPP_ENVS_DIR>/<env-name>. CSPP_ENVS_DIR defaults to /kfs2/projects/eusscom/envs, and
# env-name is the env-name line of postprocessing/constraints.txt. The env holds the packages setup.py
# requires (with the dev extra) at the versions in constraints.txt, plus Chrome for Kaleido's figure
# export. It does not install comstockpostproc: a driver run from a checkout's postprocessing/ folder
# imports that checkout's code, so one env serves every checkout whose setup.py and constraints.txt
# it satisfies. A finished env is read-only for the group, so it does not drift; a change to
# constraints.txt comes with a new env-name, and so with a new env.
#
# Run it on a login node: pip and the Chrome download need the internet. A build takes a few minutes.
set -eo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

REBUILD=0
CHECK_ONLY=0
while [ $# -gt 0 ]; do
    case $1 in
        --env) CSPP_ENV=$(readlink -m "$2"); export CSPP_ENV; shift 2 ;;
        --check) CHECK_ONLY=1; shift ;;
        --rebuild) REBUILD=1; shift ;;
        -h|--help) cspp_usage "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done
if [ "$CHECK_ONLY" = 1 ] && [ "$REBUILD" = 1 ]; then
    echo "--check and --rebuild exclude each other" >&2
    exit 2
fi
# An existing env: check it against this checkout.
if [ -e "$CSPP_ENV" ] && [ "$REBUILD" = 0 ]; then
    OWNER=$(stat -c %U "$CSPP_ENV")
    echo "The env for this checkout is $CSPP_ENV"
    if [ ! -f "$CSPP_ENV/$CSPP_ENV_RECORD" ]; then
        echo "ERROR: it has no $CSPP_ENV_RECORD: its build is still running, or it did not finish. In the" \
             "second case, its owner ($OWNER) can run this script with --rebuild." >&2
        exit 1
    fi
    cspp_activate_env
    if python "$CSPP_HPC_DIR/check_env.py"; then
        echo "Use it: module load python/$(cspp_python_version) && source $CSPP_ENV/bin/activate"
        exit 0
    fi
    echo "This env does not match the checkout. If setup.py or constraints.txt changed, give constraints.txt" \
         "a new env-name and run this script again to build a new env. If the env itself is broken," \
         "its owner ($OWNER) can run this script with --rebuild." >&2
    exit 1
fi
if [ "$CHECK_ONLY" = 1 ]; then
    echo "There is no env at $CSPP_ENV yet. To build it, run this script without --check."
    exit 3
fi

# Build it.
[ -z "$SLURM_JOB_ID" ] || echo "note: this is a Slurm job; the build needs the internet, which login nodes have"
if [ -e "$CSPP_ENV" ]; then
    if [ ! -f "$CSPP_ENV/pyvenv.cfg" ]; then
        echo "ERROR: $CSPP_ENV is not a Python venv; not deleting it" >&2
        exit 1
    fi
    if [ ! -O "$CSPP_ENV" ]; then
        echo "ERROR: $CSPP_ENV belongs to $(stat -c %U "$CSPP_ENV"); only that user can rebuild it" >&2
        exit 1
    fi
    echo "Deleting $CSPP_ENV to rebuild it (jobs still using it will fail)"
    chmod -R u+w "$CSPP_ENV"
    rm -rf "$CSPP_ENV"
fi
trap 'echo "BUILD FAILED: $CSPP_ENV is incomplete. Fix the error above, then run this script again with --rebuild." >&2' ERR

cspp_load_python
PY_VERSION=$(cspp_python_version)
echo "== $(date '+%F %T') building $CSPP_ENV with python $PY_VERSION on $(hostname)"
mkdir -p "$(dirname "$CSPP_ENV")"
python3 -m venv --upgrade-deps --prompt "$(basename "$CSPP_ENV")" "$CSPP_ENV"
source "$CSPP_ENV/bin/activate"
if [ "$(python -c 'import platform; print(platform.python_version())')" != "$PY_VERSION" ]; then
    echo "ERROR: the venv has python $(python --version), not $PY_VERSION" >&2
    exit 1
fi

echo "== packages setup.py requires, at the versions in constraints.txt"
cp "$CSPP_CONSTRAINTS" "$CSPP_ENV/constraints.txt"
python "$CSPP_HPC_DIR/check_env.py" --print-requirements > "$CSPP_ENV/requirements.txt"
python -m pip install --no-input -c "$CSPP_ENV/constraints.txt" -r "$CSPP_ENV/requirements.txt"
python -m pip check
python -m pip freeze > "$CSPP_ENV/freeze.txt"

echo "== Chrome for Kaleido"
mkdir -p "$CSPP_ENV/chrome"
plotly_get_chrome -y --path "$CSPP_ENV/chrome"
CHROME=$(find "$CSPP_ENV/chrome" -type f -name chrome -perm -u+x | head -n 1)
if [ -z "$CHROME" ]; then
    echo "ERROR: no chrome executable under $CSPP_ENV/chrome" >&2
    exit 1
fi
# Kaleido takes the user's own Chrome download first (plotly_get_chrome without --path) and BROWSER_PATH
# next, so users who never downloaded Chrome get this one, in jobs too, activated or not.
SITE_PACKAGES=$(python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
cat > "$SITE_PACKAGES/sitecustomize.py" << EOF
# Written by postprocessing/hpc/setup_kestrel_env.sh. Kaleido (plotly's figure export) uses the user's
# own Chrome download if there is one, and otherwise BROWSER_PATH: this env's Chrome, unless BROWSER_PATH
# is already set.
import os
os.environ.setdefault('BROWSER_PATH', '$CHROME')
EOF

echo "== checking the env (with no user Chrome download in reach, so the figure export uses the env's Chrome)"
NO_USER_DATA=$(mktemp -d)
XDG_DATA_HOME=$NO_USER_DATA python "$CSPP_HPC_DIR/check_env.py"
rm -rf "$NO_USER_DATA"

GIT_STATE="not a git checkout"
if git -C "$CSPP_PP_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    GIT_STATE="$(git -C "$CSPP_PP_DIR" rev-parse --abbrev-ref HEAD) at $(git -C "$CSPP_PP_DIR" rev-parse --short HEAD)"
    if [ -n "$(git -C "$CSPP_PP_DIR" status --porcelain -- setup.py constraints.txt)" ]; then
        GIT_STATE="$GIT_STATE, with uncommitted changes to setup.py or constraints.txt"
    fi
fi
cat > "$CSPP_ENV/$CSPP_ENV_RECORD" << EOF
built $(date '+%F %T') by $USER on $(hostname) from $CSPP_PP_DIR ($GIT_STATE)
python $PY_VERSION: module load python/$PY_VERSION, then source $CSPP_ENV/bin/activate
requirements.txt: what setup.py requires, with the dev extra
constraints.txt: the versions pinned for this env
freeze.txt: pip freeze after the build
chrome: $CHROME (BROWSER_PATH, set by sitecustomize.py)
EOF
chmod -R g+rX,g-w "$CSPP_ENV"
trap - ERR

echo "== $(date '+%F %T') done: $CSPP_ENV, read-only for group $(stat -c %G "$CSPP_ENV")"
echo "Use it: module load python/$PY_VERSION && source $CSPP_ENV/bin/activate"
echo "Submit a driver: bash $CSPP_HPC_DIR/submit_driver.sh <driver.py>"
