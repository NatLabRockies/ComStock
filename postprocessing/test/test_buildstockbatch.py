# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

import gzip
from pathlib import Path
from unittest.mock import MagicMock

import fsspec
import polars as pl
import pytest

from comstockpostproc import buildstockbatch


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
