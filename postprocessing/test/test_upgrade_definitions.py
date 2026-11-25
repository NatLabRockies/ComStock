# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The upgrade definitions resource: publication name -> measure id and plot alias. No data, no S3."""

import logging
import os

import polars as pl

from comstockpostproc.comstock import COLUMN_DEFINITION_FILE_NAME, RESOURCE_DIR, UPGRADE_DEFINITION_FILE_NAME, ComStock

DEFS = pl.read_csv(os.path.join(RESOURCE_DIR, UPGRADE_DEFINITION_FILE_NAME), infer_schema_length=0)


def test_every_upgrade_has_one_name_measure_id_and_alias():
    for col in ('upgrade_name', 'measure_id', 'plot_alias'):
        assert DEFS[col].null_count() == 0, col
        assert DEFS[col].n_unique() == DEFS.height, f'duplicate {col}'
    assert DEFS['measure_id'].str.contains(r'^(baseline|[a-z]+_\d{4})$').all()
    assert DEFS.filter(pl.col('upgrade_name') == ComStock.BASE_NAME)['measure_id'].to_list() == ['baseline']


def test_the_measure_id_column_is_exported():
    col_defs = pl.read_csv(os.path.join(RESOURCE_DIR, COLUMN_DEFINITION_FILE_NAME), infer_schema_length=0)
    row = col_defs.filter(pl.col('new_col_name') == ComStock.UPGRADE_MEASURE_ID)
    assert row.height == 1
    assert row['location'][0] == 'calculated'
    assert row['full_metadata'][0] == 'TRUE' and row['basic_metadata'][0] == 'TRUE'


def comstock_with(names):
    obj = ComStock.__new__(ComStock)
    obj.data = pl.LazyFrame({obj.UPGRADE_ID: list(range(len(names))), obj.UPGRADE_NAME: names})
    return obj


def test_measure_ids_follow_the_publication_name_and_missing_ones_warn(caplog):
    obj = comstock_with(['Baseline', 'Package 3, Package 1 + Package 2', 'A name nobody listed'])
    with caplog.at_level(logging.WARNING, logger='comstockpostproc.comstock'):
        obj.add_upgrade_measure_id_column()
    assert obj.data.collect()[obj.UPGRADE_MEASURE_ID].to_list() == ['baseline', 'pkg_0003', None]
    assert 'A name nobody listed' in caplog.text


def test_plot_aliases_leave_the_data_alone():
    obj = comstock_with(['Baseline', 'Package 3, Package 1 + Package 2'])
    plotted = obj.apply_upgrade_aliases(obj.data).collect()[obj.UPGRADE_NAME].to_list()
    assert plotted == ['Baseline', 'Package_3']
    assert obj.data.collect()[obj.UPGRADE_NAME].to_list() == ['Baseline', 'Package 3, Package 1 + Package 2']


def test_upgrades_without_a_plot_alias_are_listed_at_load(caplog):
    obj = comstock_with(['Baseline', 'Package 3, Package 1 + Package 2', 'A name nobody listed'])
    with caplog.at_level(logging.WARNING, logger='comstockpostproc.comstock'):
        obj.check_upgrade_aliases()
    assert "no plot_alias for 1 upgrade(s)" in caplog.text
    assert "['2: A name nobody listed']" in caplog.text


def test_every_listed_upgrade_with_an_alias_loads_quietly(caplog):
    obj = comstock_with(['Baseline', 'Wall Insulation', 'Roof Insulation'])
    with caplog.at_level(logging.WARNING, logger='comstockpostproc.comstock'):
        obj.add_upgrade_measure_id_column()
        obj.check_upgrade_aliases()
    assert caplog.text == ''
    assert obj.data.collect()[obj.UPGRADE_MEASURE_ID].to_list() == ['baseline', 'env_0001', 'env_0002']


def test_two_upgrades_with_one_name_warn(caplog):
    obj = comstock_with(['Baseline', 'Wall Insulation', 'Wall Insulation'])
    with caplog.at_level(logging.WARNING, logger='comstockpostproc.comstock'):
        obj.add_upgrade_measure_id_column()
    assert "'Wall Insulation': [1, 2]" in caplog.text


def test_blank_and_repeated_resource_entries_warn(tmp_path, monkeypatch, caplog):
    (tmp_path / UPGRADE_DEFINITION_FILE_NAME).write_text(
        'upgrade_name,measure_id,plot_alias\n'
        'Baseline,baseline,Baseline\n'
        'Wall Insulation,,Envelope\n'
        'Roof Insulation,env_0002,Envelope\n')
    monkeypatch.setattr('comstockpostproc.comstock.RESOURCE_DIR', str(tmp_path))
    obj = comstock_with(['Baseline', 'Wall Insulation', 'Roof Insulation'])
    with caplog.at_level(logging.WARNING, logger='comstockpostproc.comstock'):
        obj.upgrade_definitions()
    assert 'no measure_id on line(s) [3]' in caplog.text
    assert "the same plot_alias on more than one line: ['Envelope']" in caplog.text
    caplog.clear()
    with caplog.at_level(logging.WARNING, logger='comstockpostproc.comstock'):
        obj.upgrade_definitions()  # read once per object: no second read, no second warning
        obj.check_upgrade_aliases()
    assert "'Envelope': ['Roof Insulation', 'Wall Insulation']" in caplog.text
    assert 'no measure_id on line(s)' not in caplog.text


def comstock_with_results(tmp_path, names_by_upgrade, process=None):
    """A ComStock whose results files hold only the upgrade-name column, as check_upgrade_measure_ids reads it."""
    for up, names in names_by_upgrade.items():
        pl.DataFrame({'apply_upgrade.upgrade_name': names}, schema={'apply_upgrade.upgrade_name': pl.Utf8}).write_parquet(
            tmp_path / f'results_up{up:02d}.parquet')
    obj = ComStock.__new__(ComStock)
    obj.data_dir = str(tmp_path)
    obj.upgrade_ids_to_process = sorted(names_by_upgrade) if process is None else process
    return obj


def test_upgrades_without_a_measure_id_are_reported_before_processing(tmp_path, caplog):
    obj = comstock_with_results(tmp_path, {0: [None], 1: ['Wall Insulation', 'Wall Insulation', None],
                                           2: ['A name nobody listed']})
    with caplog.at_level(logging.WARNING, logger='comstockpostproc.comstock'):
        assert obj.check_upgrade_measure_ids() == [(2, 'A name nobody listed')]
    assert '2: A name nobody listed' in caplog.text
    assert '"A name nobody listed",<measure_id>,<plot_alias>' in caplog.text
    assert 'REBUILD_ATHENA_TABLES' in caplog.text and 'Wall Insulation' not in caplog.text
    # the end of the load adds the column and does not repeat the warning
    obj.data = pl.LazyFrame({obj.UPGRADE_ID: [0, 1, 2],
                             obj.UPGRADE_NAME: ['Baseline', 'Wall Insulation', 'A name nobody listed']})
    caplog.clear()
    with caplog.at_level(logging.WARNING, logger='comstockpostproc.comstock'):
        obj.add_upgrade_measure_id_column()
    assert caplog.text == ''
    assert obj.data.collect()[obj.UPGRADE_MEASURE_ID].to_list() == ['baseline', 'env_0001', None]


def test_a_run_whose_upgrades_all_have_measure_ids_reports_nothing(tmp_path, caplog):
    obj = comstock_with_results(tmp_path, {1: ['Wall Insulation'], 2: ['Package 3, Package 1 + Package 2']})
    with caplog.at_level(logging.WARNING, logger='comstockpostproc.comstock'):
        assert obj.check_upgrade_measure_ids() == []
    assert caplog.text == ''


def test_upgrades_the_run_leaves_out_are_not_checked(tmp_path, caplog):
    obj = comstock_with_results(tmp_path, {1: ['Wall Insulation'], 2: ['A name nobody listed']}, process=[0, 1])
    with caplog.at_level(logging.WARNING, logger='comstockpostproc.comstock'):
        assert obj.check_upgrade_measure_ids() == []
    assert caplog.text == ''
