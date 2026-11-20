# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

import gzip
from pathlib import Path
from unittest.mock import MagicMock

import fsspec
import polars as pl
import pytest

from comstockpostproc import buildstockbatch
from comstockpostproc.comstock import ComStock


@pytest.mark.parametrize('upgrades', [[], [{'upgrade_name': 'test'}]])
def test_publishes_weighted_results_after_staging_inputs(tmp_path, monkeypatch, upgrades):
    results = tmp_path / 'results'
    sample = tmp_path / 'sample.csv'
    sample.write_text('Building\n1\n')
    for upgrade_id in range(len(upgrades) + 1):
        source_dir = results / 'parquet' / ('baseline' if upgrade_id == 0 else f'upgrades/upgrade={upgrade_id}')
        source_dir.mkdir(parents=True)
        (source_dir / f'results_up{upgrade_id:02d}.parquet').write_bytes(b'input parquet')

    cs = MagicMock()
    cs.truth_data_dir = str(tmp_path)
    cs.tract_to_util_map_file_name = 'tract_to_elec_util_v2.csv'
    cs.STATE_ABBRV = 'state'
    cs.CZ_ASHRAE = 'climate_zone'
    cs.create_weighted_aggregate_output.return_value = pl.DataFrame({
        'building_id': [1], 'state': ['CO'], 'climate_zone': ['5B'], 'weighted_energy': [42.0],
    }).lazy()

    def create_comstock(**kwargs):
        staged = tmp_path / 'sample.csv'
        data_dir = Path(kwargs['data_dir'])
        assert kwargs['upgrade_names'] == {i: upgrade['upgrade_name'] for i, upgrade in enumerate(upgrades, 1)}
        assert (data_dir / 'buildstock.csv').read_text() == staged.read_text()
        assert sorted(p.name for p in data_dir.glob('*.parquet')) == [
            f'results_up{i:02d}.parquet' for i in range(len(upgrades) + 1)
        ]
        return cs

    monkeypatch.setattr(buildstockbatch, 'ComStock', create_comstock)
    monkeypatch.setattr(buildstockbatch, 'Apportion', MagicMock())
    monkeypatch.setattr(buildstockbatch, 'CBECS', MagicMock())
    cfg = {'upgrades': upgrades, 'postprocessing': {'comstock': {
        'stock_estimation_version': '2026R1', 'truth_data_version': 'v01', 'comstock_year': 2018,
    }}}
    buildstockbatch.publish_results(fsspec.filesystem('file'), str(results), str(sample), cfg)

    cs.download_truth_data_file.assert_called_once_with('truth_data/v01/tract_to_elec_util_v2.csv')
    assert cs.create_allocated_weights_plus_util_bills_for_upgrade.call_count == len(upgrades) + 1
    for call in cs.create_weighted_aggregate_output.call_args_list:
        assert call.kwargs['geographic_aggregation_levels'] == ['state', 'climate_zone']
        assert call.kwargs['column_downselection'] == 'full'
    for upgrade_id in range(len(upgrades) + 1):
        name = f'results_up{upgrade_id:02d}'
        with gzip.open(results / 'results_csvs_pub' / f'{name}.csv.gz', 'rb') as stream:
            assert pl.read_csv(stream.read()).to_dicts() == [
                {'building_id': 1, 'state': 'CO', 'climate_zone': '5B', 'weighted_energy': 42.0}
            ]
        assert pl.read_parquet(results / 'parquet' / 'pub_annual' / f'upgrade={upgrade_id}' / f'{name}.parquet').shape == (1, 4)


def test_rejects_missing_settings_and_skipped_baseline(tmp_path):
    fs = fsspec.filesystem('file')
    with pytest.raises(ValueError, match='requires postprocessing.comstock'):
        buildstockbatch.publish_results(fs, str(tmp_path), 'sample.csv', {})
    with pytest.raises(ValueError, match='requires baseline'):
        buildstockbatch.publish_results(fs, str(tmp_path), 'sample.csv', {
            'baseline': {'skip_sims': True}, 'postprocessing': {'comstock': {}},
        })


def test_missing_raw_parquet_raises(tmp_path):
    sample = tmp_path / 'sample.csv'
    sample.write_text('Building\n1\n')
    with pytest.raises(FileNotFoundError):
        buildstockbatch.publish_results(fsspec.filesystem('file'), str(tmp_path), str(sample), {
            'postprocessing': {'comstock': {}},
        })


def load_raw_results(tmp_path, baseline, upgrade=None, upgrade_names=None):
    (tmp_path / 'buildstock.csv').write_text('Building\n' + ''.join(f'{i}\n' for i in baseline['building_id']))
    baseline.write_parquet(tmp_path / 'results_up00.parquet')
    if upgrade is not None:
        upgrade.write_parquet(tmp_path / 'results_up01.parquet')
    comstock = ComStock.__new__(ComStock)
    comstock.data_dir = str(tmp_path)
    comstock.results_file_name = 'results_up00.parquet'
    comstock.buildstock_file_name = 'buildstock.csv'
    comstock.upgrade_ids_to_skip = []
    comstock.upgrade_names = upgrade_names or {}
    comstock.output_dir = {'fs': fsspec.filesystem('file'), 'fs_path': str(tmp_path)}
    comstock.downselect_imported_columns = lambda df: df
    comstock.load_data(1 if upgrade is not None else 0)
    return comstock.data


def raw_results(statuses, applicability, names, energy):
    return pl.DataFrame({
        'building_id': list(range(1, len(statuses) + 1)),
        'completed_status': statuses,
        'simulation_output_report.total_site_energy_mbtu': energy,
        'apply_upgrade.upgrade_name': names,
        'apply_upgrade.applicable': applicability,
        'apply_upgrade.reference_scenario': [''] * len(statuses),
    })


@pytest.mark.parametrize('applicability', [[None], [False], ['False']])
def test_baseline_applicability_is_true(tmp_path, applicability):
    baseline = raw_results(['Success'], applicability, [None], [100.0])
    results = load_raw_results(tmp_path, baseline)
    assert results['apply_upgrade.applicable'].to_list() == [True]


def test_fully_inapplicable_upgrade_uses_baseline_and_configured_name(tmp_path):
    baseline = raw_results(['Success'], [None], [None], [100.0])
    upgrade = raw_results(['Invalid'], [False], [None], [None])
    results = load_raw_results(tmp_path, baseline, upgrade, {1: 'Test Upgrade'})
    result = results.filter(pl.col('upgrade') == 1).row(0, named=True)
    assert result['completed_status'] == 'Invalid'
    assert result['apply_upgrade.applicable'] is False
    assert result['apply_upgrade.upgrade_name'] == 'Test Upgrade'
    assert result['simulation_output_report.total_site_energy_mbtu'] == 100.0


def test_mixed_upgrade_preserves_success_and_fills_inapplicable_name(tmp_path):
    baseline = raw_results(['Success', 'Success'], [None, None], [None, None], [100.0, 200.0])
    upgrade = raw_results(['Success', 'Invalid'], ['True', 'False'], ['Test Upgrade', None], [80.0, None])
    results = load_raw_results(tmp_path, baseline, upgrade)
    upgrade_results = results.filter(pl.col('upgrade') == 1).sort('building_id')
    assert upgrade_results['simulation_output_report.total_site_energy_mbtu'].to_list() == [80.0, 200.0]
    assert upgrade_results['apply_upgrade.upgrade_name'].to_list() == ['Test Upgrade', 'Test Upgrade']


def test_fully_inapplicable_upgrade_without_name_reports_error(tmp_path):
    baseline = raw_results(['Success'], [None], [None], [100.0])
    upgrade = raw_results(['Invalid'], [False], [None], [None])
    with pytest.raises(ValueError, match='upgrade 1.*name'):
        load_raw_results(tmp_path, baseline, upgrade)


def test_fully_inapplicable_upgrade_uses_existing_name(tmp_path):
    baseline = raw_results(['Success'], [None], [None], [100.0])
    upgrade = raw_results(['Invalid'], [False], ['Recorded Upgrade'], [None])
    results = load_raw_results(tmp_path, baseline, upgrade)
    assert results.filter(pl.col('upgrade') == 1)['apply_upgrade.upgrade_name'].to_list() == ['Recorded Upgrade']


def test_all_failed_upgrade_still_exceeds_failure_limit(tmp_path):
    baseline = raw_results(['Success'], [None], [None], [100.0])
    upgrade = raw_results(['Fail'], [False], [None], [None])
    with pytest.raises(Exception, match='failure rate.*above the specified acceptable limit'):
        load_raw_results(tmp_path, baseline, upgrade)
