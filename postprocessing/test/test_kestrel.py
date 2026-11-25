# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Running a driver on Kestrel the same way as anywhere else (comstockpostproc.kestrel). No Slurm, no AWS.

Pins: off Kestrel, on a compute node and inside a job, run_or_submit runs main() whatever KESTREL_JOB says;
on a login node it submits the driver with KESTREL_JOB and stops without it; KESTREL_JOB is checked and
turned into submit_driver.sh options.
"""
import os
import sys

import pytest

from comstockpostproc import kestrel


@pytest.fixture
def place(monkeypatch):
    def set_place(cluster, host):
        monkeypatch.delenv('NREL_CLUSTER', raising=False)
        monkeypatch.delenv('CSPP_RUN_ON_LOGIN_NODE', raising=False)
        if cluster is None:
            monkeypatch.delenv('NLR_CLUSTER', raising=False)
        else:
            monkeypatch.setenv('NLR_CLUSTER', cluster)
        monkeypatch.setattr(kestrel.socket, 'gethostname', lambda: host)
    return set_place


def _main(calls):
    def main():
        calls.append('main')
        return 'done'
    return main


def _venv(path):
    (path / 'bin').mkdir(parents=True)
    (path / 'bin' / 'activate').write_text('')
    return str(path)


def test_where(place):
    place(None, 'kl1')
    assert kestrel.where() is None
    place('kestrel', 'kl2')
    assert kestrel.where() == 'login'
    place('kestrel', 'kl3.head.cm.kestrel.hpc.nlr.gov')
    assert kestrel.where() == 'login'
    place('kestrel', 'x1003c7s0b0n1')
    assert kestrel.where() == 'compute'
    place('Kestrel', 'kd1')  # a DAV node
    assert kestrel.where() == 'compute'
    place('other', 'kl1')
    assert kestrel.where() is None


def test_job_arguments():
    assert kestrel.job_arguments('eusscom') == (['--account', 'eusscom'], [])
    options, extra = kestrel.job_arguments(dict(account='cscore', qos='high', time='4:00:00', aws=False,
                                                sbatch_args='--constraint=lbw --exclusive'))
    assert options == ['--account', 'cscore', '--time', '4:00:00', '--qos', 'high', '--no-aws']
    assert extra == ['--constraint=lbw', '--exclusive']
    options, _ = kestrel.job_arguments(dict(account='eusscom', partition='shared', mem='32G', cpus=4,
                                            mail='someone@example.org', job_name='dash'))
    assert options == ['--account', 'eusscom', '--partition', 'shared', '--mem', '32G', '--cpus', '4',
                       '--mail', 'someone@example.org', '--job-name', 'dash']


@pytest.mark.parametrize('job, words', [
    (dict(time='1:00:00'), 'needs the account'),
    (dict(account='eusscom', acount='x'), 'acount'),
    (dict(account='eusscom', partition='shared'), 'states its memory'),
    (['eusscom'], 'must be None'),
])
def test_job_arguments_refuses(job, words):
    with pytest.raises(ValueError, match=words):
        kestrel.job_arguments(job)


@pytest.mark.parametrize('cluster, host', [(None, 'laptop'), (None, 'kl1'), ('kestrel', 'x1000c0s0b0n0')])
def test_runs_main_off_login_nodes(place, monkeypatch, cluster, host):
    place(cluster, host)
    monkeypatch.setattr(kestrel.subprocess, 'call', lambda *a, **k: pytest.fail('submitted'))
    calls = []
    assert kestrel.run_or_submit(_main(calls), dict(account='eusscom')) == 'done'
    assert kestrel.run_or_submit(_main(calls), None) == 'done'
    assert calls == ['main', 'main']


def test_login_node_without_job_stops(place, capsys):
    place('kestrel', 'kl1')
    calls = []
    with pytest.raises(SystemExit) as stop:
        kestrel.run_or_submit(_main(calls), None)
    assert stop.value.code == 2 and calls == []
    err = capsys.readouterr().err
    assert 'login node' in err and 'KESTREL_JOB' in err and 'salloc' in err


def test_login_node_runs_main_when_told(place, monkeypatch):
    place('kestrel', 'kl1')
    monkeypatch.setenv('CSPP_RUN_ON_LOGIN_NODE', '1')
    calls = []
    assert kestrel.run_or_submit(_main(calls), None) == 'done'
    assert calls == ['main']


def test_login_node_with_job_submits(place, monkeypatch, tmp_path):
    place('kestrel', 'kl2')
    driver = tmp_path / 'compare_upgrades.py'
    driver.write_text('')
    monkeypatch.setattr(sys.modules['__main__'], '__file__', str(driver), raising=False)
    prefix = _venv(tmp_path / 'env')
    monkeypatch.setattr(kestrel.sys, 'prefix', prefix)
    seen = []
    monkeypatch.setattr(kestrel.subprocess, 'call', lambda command: seen.append(command) or 0)
    calls = []
    assert kestrel.run_or_submit(_main(calls), dict(account='eusscom', sbatch_args=['--exclusive'])) is None
    assert calls == []
    (command,) = seen
    assert command == ['bash', os.path.join(kestrel.HPC_DIR, 'submit_driver.sh'), '--account', 'eusscom',
                       '--env', prefix, str(driver), '--', '--exclusive']


def test_login_node_refuses_what_cannot_be_submitted(place, monkeypatch, tmp_path, capsys):
    place('kestrel', 'kl3')
    driver = tmp_path / 'd.py'
    driver.write_text('')
    monkeypatch.setattr(sys.modules['__main__'], '__file__', str(driver), raising=False)
    # a mistyped KESTREL_JOB
    with pytest.raises(SystemExit) as stop:
        kestrel.run_or_submit(_main([]), dict(acount='eusscom'))
    assert stop.value.code == 2 and 'acount' in capsys.readouterr().err
    # a Python that is not a virtual env: the job could not activate it
    monkeypatch.setattr(kestrel.sys, 'prefix', str(tmp_path / 'not_a_venv'))
    with pytest.raises(SystemExit) as stop:
        kestrel.run_or_submit(_main([]), 'eusscom')
    assert stop.value.code == 2 and 'not a virtual environment' in capsys.readouterr().err
    # submit_driver.sh failed (a check, or sbatch): its exit code
    monkeypatch.setattr(kestrel.sys, 'prefix', _venv(tmp_path / 'venv'))
    monkeypatch.setattr(kestrel.subprocess, 'call', lambda command: 3)
    with pytest.raises(SystemExit) as stop:
        kestrel.run_or_submit(_main([]), 'eusscom')
    assert stop.value.code == 3
