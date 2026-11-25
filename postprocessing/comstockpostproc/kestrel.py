# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Run a postprocessing driver on NREL's Kestrel the same way as anywhere else.

A driver (a copy of a postprocessing/*.py.template) has a KESTREL_JOB setting and ends with

    if __name__ == "__main__":
        cspp.run_or_submit(main, KESTREL_JOB)

`python <driver>.py` then runs main() where it is started: on a laptop, on a Kestrel compute node, inside a
Slurm job. On a Kestrel login node, which is for editing and submitting rather than for postprocessing, it
queues the driver as a Slurm job instead, through postprocessing/hpc/submit_driver.sh (checks first, then
sbatch); the job runs the same file on a compute node. See README, "Running on Kestrel".
"""
import logging
import os
import re
import socket
import subprocess
import sys

logger = logging.getLogger(__name__)

HPC_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'hpc')
LOGIN_NODE = re.compile(r'kl\d+$')          # Kestrel's login nodes are kl1, kl2 and kl3
SHARED_PARTITIONS = ('shared', 'sharedl')   # partitions whose nodes several jobs share: a job states its memory

# KESTREL_JOB keys and the submit_driver.sh options they become. Only account is required.
JOB_OPTIONS = {
    'account': '--account',      # the HPC project the job is charged to, e.g. 'eusscom'
    'time': '--time',            # time limit, default '12:00:00'
    'partition': '--partition',  # default 'standard' (a whole node); 'shared' for a small job, with mem
    'mem': '--mem',              # default the whole node; e.g. '32G' (required on the shared partition)
    'cpus': '--cpus',            # cores; the whole node on standard, 1 on shared unless given
    'qos': '--qos',              # e.g. 'high', for projects that have it
    'mail': '--mail',            # address emailed when the job ends or fails
    'job_name': '--job-name',    # default cspp_<driver name>
}
JOB_KEYS = tuple(JOB_OPTIONS) + ('aws', 'sbatch_args')  # aws=False: no AWS keys; sbatch_args: more sbatch options


def where():
    """'login' on a Kestrel login node, 'compute' on any other Kestrel node, None off Kestrel."""
    cluster = os.environ.get('NLR_CLUSTER') or os.environ.get('NREL_CLUSTER') or ''
    if cluster.lower() != 'kestrel':
        return None
    return 'login' if LOGIN_NODE.match(socket.gethostname().split('.')[0]) else 'compute'


def job_arguments(job):
    """(submit_driver.sh options, extra sbatch arguments) for a KESTREL_JOB value.

    job is an account name or a dict with the JOB_KEYS. Raises ValueError saying what is wrong with it.
    """
    if isinstance(job, str):
        job = {'account': job}
    if not isinstance(job, dict):
        raise ValueError("KESTREL_JOB must be None, an account name, or a dict such as dict(account='eusscom'); "
                         f"it is {job!r}")
    unknown = sorted(set(job) - set(JOB_KEYS))
    if unknown:
        raise ValueError(f"KESTREL_JOB has keys it does not know: {', '.join(unknown)}. "
                         f"It takes {', '.join(JOB_KEYS)}.")
    if not job.get('account'):
        raise ValueError("KESTREL_JOB needs the account, the HPC project the job is charged to: "
                         "dict(account='eusscom'), for example")
    if job.get('partition') in SHARED_PARTITIONS and not job.get('mem'):
        raise ValueError(f"KESTREL_JOB: on the {job['partition']} partition the job states its memory, "
                         "for example dict(..., partition='shared', mem='32G', cpus=4)")
    options = []
    for key, option in JOB_OPTIONS.items():
        if job.get(key) not in (None, ''):
            options += [option, str(job[key])]
    if job.get('aws', True) is False:
        options.append('--no-aws')
    extra = job.get('sbatch_args') or []
    if isinstance(extra, str):
        extra = extra.split()
    return options, [str(a) for a in extra]


def _stop(message, code=2):
    print(message, file=sys.stderr, flush=True)
    sys.exit(code)


def run_or_submit(main, job=None):
    """Run main() here, or, on a Kestrel login node, queue this driver as a Slurm job that runs it.

    job is the driver's KESTREL_JOB setting: None, an account name, or a dict (JOB_KEYS; README, "Running
    on Kestrel"). It matters only on a Kestrel login node:
      - with a job, the driver is checked (it parses, the environment matches the checkout, the AWS keys
        work) and submitted with postprocessing/hpc/submit_driver.sh; nothing runs here;
      - without one, this stops and says how to run it, because login nodes are not for postprocessing.
    Everywhere else, main() runs here, as it would without this function. Returns what main() returns,
    or None once the job is submitted. CSPP_RUN_ON_LOGIN_NODE=1 runs main() on a login node anyway.
    """
    place = where()
    if place != 'login':
        if job and place is None:
            logger.info('KESTREL_JOB is set, but this is not Kestrel: running here')
        return main()

    host = socket.gethostname().split('.')[0]
    driver = getattr(sys.modules.get('__main__'), '__file__', None)
    name = os.path.basename(driver) if driver else 'this driver'
    if os.environ.get('CSPP_RUN_ON_LOGIN_NODE') == '1':
        logger.warning('CSPP_RUN_ON_LOGIN_NODE=1: running %s on the login node %s', name, host)
        return main()
    if not job:
        _stop(f"{name}: {host} is a Kestrel login node, which is for editing and submitting jobs, not for "
              "postprocessing.\n"
              f"  To run it as a Slurm job, set KESTREL_JOB in {name}, for example "
              "KESTREL_JOB = dict(account='eusscom'),\n"
              "  and run it again the same way.\n"
              "  To run it interactively instead, get a compute node first, for example\n"
              "    salloc --account=<project> --partition=debug --time=1:00:00 --nodes=1\n"
              "  (README, \"Running on Kestrel\").")
    if not driver:
        _stop('run_or_submit: start the driver as a script, python <driver>.py, so it can be submitted.')
    try:
        options, extra = job_arguments(job)
    except ValueError as exc:
        _stop(f'{name}: {exc}')
    if not os.path.isfile(os.path.join(sys.prefix, 'bin', 'activate')):
        _stop(f"{name}: the job activates the environment this runs in, {sys.prefix}, and that is not a "
              "virtual environment.\n  Activate the shared one first: source postprocessing/hpc/activate.sh "
              "(README, \"Running on Kestrel\").")

    print(f'{name}: {host} is a Kestrel login node, so this queues it as a Slurm job (KESTREL_JOB) '
          'that runs it on a compute node.', flush=True)
    command = ['bash', os.path.join(HPC_DIR, 'submit_driver.sh'), *options, '--env', sys.prefix,
               os.path.abspath(driver)]
    if extra:
        command += ['--', *extra]
    code = subprocess.call(command)
    if code:
        sys.exit(code)
    return None
