# Activates the shared Python environment for ComStock postprocessing on Kestrel: the one this checkout's
# constraints.txt names (setup_kestrel_env.sh builds it). Source it, from any folder:
#
#   source postprocessing/hpc/activate.sh
#
# Then work as on your own computer: copy a template, edit its settings, python compare_upgrades.py. On a
# login node, a driver whose KESTREL_JOB setting is filled in queues itself as a Slurm job (README,
# "Running on Kestrel").
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "Source this file instead of running it: source ${BASH_SOURCE[0]}" >&2
    exit 2
fi
if source "$(dirname "${BASH_SOURCE[0]}")/common.sh" && cspp_activate_env; then
    echo "Active: $CSPP_ENV ($(python --version 2>&1)). Drivers go in $CSPP_PP_DIR."
fi
