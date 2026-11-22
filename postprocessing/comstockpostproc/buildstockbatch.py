"""Publish BuildStockBatch annual results using ComStock's weighted export pipeline."""

import gzip
import os
from pathlib import Path
import shutil
import tempfile

from .cbecs import CBECS
from .comstock import ComStock
from .comstock_apportionment import Apportion


def publish_results(fs, results_dir, buildstock_csv_filename, cfg):
    if cfg.get('baseline', {}).get('skip_sims', False):
        raise ValueError('Commercial publication requires baseline simulation results.')

    stock_estimation_version = '2025R3'
    truth_data_version = 'v01'
    comstock_year = 2018
    upgrade_ids = range(len(cfg.get('upgrades', [])) + 1)
    with tempfile.TemporaryDirectory(prefix='comstock-publication-') as tmpdir:
        data_dir = Path(tmpdir) / 'data'
        output_dir = Path(tmpdir) / 'output'
        data_dir.mkdir()
        shutil.copyfile(buildstock_csv_filename, data_dir / 'buildstock.csv')
        for upgrade_id in upgrade_ids:
            filename = f'results_up{upgrade_id:02d}.parquet'
            source_dir = 'baseline' if upgrade_id == 0 else f'upgrades/upgrade={upgrade_id}'
            source = f'{results_dir}/parquet/{source_dir}/{filename}'
            with fs.open(source, 'rb') as src, (data_dir / filename).open('wb') as dst:
                shutil.copyfileobj(src, dst)

        comstock = ComStock(
            s3_base_dir=None,
            comstock_run_name='buildstockbatch',
            comstock_run_version='buildstockbatch',
            comstock_year=comstock_year,
            athena_table_name=None,
            truth_data_version=truth_data_version,
            data_dir=str(data_dir),
            output_dir=str(output_dir),
            skip_missing_columns=True,
            include_upgrades=len(cfg.get('upgrades', [])) > 0,
            upgrade_names={i: upgrade['upgrade_name'] for i, upgrade in enumerate(cfg.get('upgrades', []), 1)},
            make_comparison_plots=False,
            make_timeseries_plots=False,
        )
        utility_map = os.path.join(comstock.truth_data_dir, comstock.tract_to_util_map_file_name)
        if not os.path.exists(utility_map):
            comstock.download_truth_data_file(
                f'truth_data/{truth_data_version}/{comstock.tract_to_util_map_file_name}'
            )
        estimate = Apportion(
            stock_estimation_version=stock_estimation_version,
            truth_data_version=truth_data_version,
            output_dir=str(output_dir / 'apportionment'),
        )
        baseline = comstock.get_sim_outs_for_upgrade(0)
        comstock.create_allocated_weights(estimate, baseline)
        cbecs = CBECS(cbecs_year=2018, truth_data_version=truth_data_version)
        comstock.create_allocated_weights_scaled_to_cbecs(
            cbecs, baseline, comstock.get_allocated_weights(), remove_non_comstock_bldg_types_from_cbecs=True
        )
        for upgrade_id in upgrade_ids:
            comstock.create_allocated_weights_plus_util_bills_for_upgrade(upgrade_id)

        base_weights = comstock.get_allocated_weights_plus_util_bills_for_upgrade(0)
        csv_dir = f'{results_dir}/results_csvs_pub'
        fs.makedirs(csv_dir, exist_ok=True)
        for upgrade_id in upgrade_ids:
            weights = comstock.get_allocated_weights_plus_util_bills_for_upgrade(upgrade_id)
            outputs = comstock.get_sim_outs_for_upgrade(upgrade_id)
            result = comstock.create_weighted_aggregate_output(
                weights, outputs, base_weights,
                geographic_aggregation_levels=[comstock.STATE_ABBRV, comstock.CZ_ASHRAE],
                column_downselection='full',
            ).collect()
            filename = f'results_up{upgrade_id:02d}'
            with fs.open(f'{csv_dir}/{filename}.csv.gz', 'wb') as stream:
                with gzip.open(stream, 'wb') as compressed:
                    result.write_csv(compressed)
            parquet_dir = f'{results_dir}/parquet/pub_annual/upgrade={upgrade_id}'
            fs.makedirs(parquet_dir, exist_ok=True)
            with fs.open(f'{parquet_dir}/{filename}.parquet', 'wb') as stream:
                result.write_parquet(stream)
