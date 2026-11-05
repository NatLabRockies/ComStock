# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""One folder per run: its comparisons and dashboard go inside it; a comparison of several runs needs a name."""

import os
from pathlib import Path

import pytest

from comstockpostproc.output_folders import OUTPUT_ROOT, comparison_folder, run_folder
from comstockpostproc.results_dashboard.assessment import ResultsDashboard


class LocalFileSystem:  # stands in for fsspec's; run_folder only looks at the class name
    pass


class S3FileSystem:  # same class name as s3fs's
    pass


def run(version, fs_path=None, fs=None):
    r = type('Run', (), {})()
    r.comstock_run_version = version
    r.output_dir = {'fs': fs or LocalFileSystem(), 'fs_path': fs_path or os.path.join(OUTPUT_ROOT, f'ComStock {version}')}
    return r


def test_a_run_writes_to_its_own_folder():
    assert run_folder(run('r1')) == os.path.join(OUTPUT_ROOT, 'ComStock r1')
    # exports on S3: figures and the dashboard still go to the local run folder
    assert run_folder(run('r1', fs_path='bucket/prefix/r1', fs=S3FileSystem())) == os.path.join(OUTPUT_ROOT, 'ComStock r1')


def test_a_comparison_of_one_run_goes_in_the_run_folder():
    assert comparison_folder([run('r1')], None, 'cbecs_comparison') == os.path.join(OUTPUT_ROOT, 'ComStock r1',
                                                                                    'cbecs_comparison')


def test_a_named_comparison_gets_its_own_folder():
    assert comparison_folder([run('r1'), run('r2')], 'my comparison', 'cbecs_comparison') == os.path.join(
        OUTPUT_ROOT, 'my comparison')


def test_an_unnamed_comparison_of_several_runs_is_refused():
    with pytest.raises(ValueError, match='needs name='):
        comparison_folder([run('r1'), run('r2')], None, 'cbecs_comparison')


def dashboard_for(primary, comparison_dir):
    d = ResultsDashboard.__new__(ResultsDashboard)
    d.comstock = primary
    d.comparison = None if comparison_dir is None else type('Comparison', (), {'output_dir': comparison_dir})()
    return d


@pytest.mark.parametrize('subfolder', ['measure_runs', 'cbecs_comparison', 'ami_comparison'])
def test_the_dashboard_of_one_run_is_in_the_run_folder(subfolder):
    r1 = run('r1')
    out = dashboard_for(r1, os.path.join(run_folder(r1), subfolder))._default_output_dir()
    assert out == Path(run_folder(r1)).resolve() / 'results_dashboard'


def test_the_dashboard_of_a_named_comparison_is_in_its_folder():
    out = dashboard_for(run('r1'), os.path.join(OUTPUT_ROOT, 'my comparison'))._default_output_dir()
    assert out == Path(OUTPUT_ROOT, 'my comparison').resolve() / 'results_dashboard'


def test_the_dashboard_without_a_comparison_is_in_the_run_folder():
    r1 = run('r1')
    assert Path(dashboard_for(r1, None)._default_output_dir()).resolve() == Path(run_folder(r1)).resolve() / 'results_dashboard'
