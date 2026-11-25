# Settings and helpers shared by the scripts in postprocessing/hpc. The scripts source this file; it is
# not run on its own. Each CSPP_* setting can be set in the environment instead.

CSPP_HPC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CSPP_PP_DIR=$(dirname "$CSPP_HPC_DIR")          # this checkout's postprocessing/ folder
CSPP_CONSTRAINTS=$CSPP_PP_DIR/constraints.txt
CSPP_ENV_RECORD=comstockpostproc_env.txt         # written into an env when its build finishes

# The env: CSPP_ENVS_DIR/<the env-name line of constraints.txt>, unless CSPP_ENV names another one.
CSPP_ENVS_DIR=${CSPP_ENVS_DIR:-/kfs2/projects/eusscom/envs}
cspp_env_name() {
    sed -n 's/^#[[:space:]]*env-name:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$CSPP_CONSTRAINTS" | awk 'NR == 1'
}
if [ -z "$CSPP_ENV" ]; then
    if [ -z "$(cspp_env_name)" ]; then
        echo "ERROR: $CSPP_CONSTRAINTS has no '# env-name: <name>' line" >&2
        return 1
    fi
    CSPP_ENV=$CSPP_ENVS_DIR/$(cspp_env_name)
fi
export CSPP_ENV

# The exact Python version setup.py requires (python_requires="==3.12.12" gives 3.12.12).
cspp_python_version() {
    sed -n "s/.*python_requires[[:space:]]*=[[:space:]]*['\"]==\([0-9][0-9.]*\)['\"].*/\1/p" \
        "$CSPP_PP_DIR/setup.py" | awk 'NR == 1'
}

cspp_load_python() {
    local version
    version=$(cspp_python_version)
    if [ -z "$version" ]; then
        echo "ERROR: $CSPP_PP_DIR/setup.py has no exact python_requires (\"==X.Y.Z\")" >&2
        return 1
    fi
    if ! module load "python/$version" > /dev/null 2>&1; then
        echo "ERROR: 'module load python/$version' failed; 'module avail python' lists the versions here" >&2
        return 1
    fi
}

cspp_activate_env() {
    cspp_load_python || return 1
    if [ ! -f "$CSPP_ENV/bin/activate" ]; then
        echo "ERROR: there is no env at $CSPP_ENV. Build it with: bash $CSPP_HPC_DIR/setup_kestrel_env.sh" >&2
        return 1
    fi
    source "$CSPP_ENV/bin/activate"
}

# Reads the env's compiled libraries and bytecode once, several files at a time, before the first import.
# When /kfs2 is slow, an import reads them one small piece at a time: on 2026-11-19 importing
# comstockpostproc took 28 minutes, and reading the same files this way took 8. CSPP_PREWARM=0 skips it.
cspp_prewarm_env() {
    [ "${CSPP_PREWARM:-1}" = 0 ] && return 0
    local start=$SECONDS
    find "$CSPP_ENV" -type f -name '*.so*' -size +200k -print0 2> /dev/null \
        | xargs -0 -r -P 8 -n 4 cat > /dev/null 2>&1 || true
    find "$CSPP_ENV" "$CSPP_PP_DIR/comstockpostproc" -type f -name '*.pyc' -print0 2> /dev/null \
        | xargs -0 -r -P 16 -n 64 cat > /dev/null 2>&1 || true
    echo "read the env's libraries and bytecode ahead of the import in $((SECONDS - start)) s (CSPP_PREWARM=0 skips this)"
}

# Prints the comment block at the top of a script (its usage).
cspp_usage() {
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"
}
