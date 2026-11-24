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


def plotting_run(version):
    """A run whose plotting table (cached_plotting_by_upgrade) must not be built: building it fails the test."""
    import polars as pl
    r = run(version)
    r.data = pl.LazyFrame({'upgrade': [0]})
    r.plotting_data = None
    r.dataset_name = f'ComStock {version}'
    r.upgrade_ids_for_comparison = {}
    r.comstock_run_name = version
    r.athena_table_name = None
    r.s3_base_dir = 'bucket/prefix'
    r.include_upgrades = True

    def no_plotting_table():
        raise AssertionError('the plotting table was built with comparison plots off')
    r.create_plotting_lazyframe = no_plotting_table
    return r


def test_without_figures_the_measure_comparison_builds_nothing_and_keeps_its_folder():
    from comstockpostproc.comstock_measure_comparison import ComStockMeasureComparison
    r1 = plotting_run('r1')
    # timeseries figures are drawn with the comparison figures only, so this is no work either
    comp = ComStockMeasureComparison(r1, timeseries_locations_to_plot={'MN': 'Minnesota'},
                                     make_comparison_plots=False, make_timeseries_plots=True)
    assert comp.output_dir == os.path.join(run_folder(r1), 'measure_runs')
    out = dashboard_for(r1, comp.output_dir)._default_output_dir()
    assert out == Path(run_folder(r1)).resolve() / 'results_dashboard'


def test_without_figures_the_cbecs_comparison_builds_nothing_and_keeps_its_folder():
    from comstockpostproc.comstock_to_cbecs_comparison import ComStockToCBECSComparison
    r1, r2 = plotting_run('r1'), plotting_run('r2')
    cbecs = object()   # not read either
    one = ComStockToCBECSComparison(comstock_list=[r1], cbecs_list=[cbecs], make_comparison_plots=False)
    assert one.output_dir == os.path.join(run_folder(r1), 'cbecs_comparison')
    named = ComStockToCBECSComparison(comstock_list=[r1, r2], cbecs_list=[cbecs], name='my comparison',
                                      make_comparison_plots=False)
    assert named.output_dir == os.path.join(OUTPUT_ROOT, 'my comparison')
    with pytest.raises(ValueError, match='needs name='):
        ComStockToCBECSComparison(comstock_list=[r1, r2], cbecs_list=[cbecs], make_comparison_plots=False)
