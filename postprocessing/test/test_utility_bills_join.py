# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
#!/usr/bin/env python
# -*- coding: utf-8 -*-

import os

import fsspec
import polars as pl
import pytest
from polars.testing import assert_frame_equal

from comstockpostproc import utility_bills_join as ubj
from comstockpostproc.comstock import ComStock
from comstockpostproc.naming_mixin import NamingMixin as N

VALS = N.UTIL_ELEC_BILL_VALS
MEASURE_RESOURCES = os.path.join(os.path.dirname(__file__), '..', '..', 'measures', 'utility_bills', 'resources')


def block(key, mean, state=None):
    """One '<key>:<values>[:<state>]' block in the measure's field order, every ..usd field = mean."""
    vals = []
    for c in VALS:
        if c == N.UTIL_ELEC_BILL_NUM_BILLS:
            vals.append('3')
        elif 'label' in c:
            vals.append(f'rate_{key}')
        else:
            vals.append(str(mean))
    return f'{key}:' + ':'.join(vals) + (f':{state}' if state else '')


def bills_string(*blocks):
    return '|' + '|'.join(blocks) + '|'


def state_string(**by_state):
    return '|' + '|'.join(f'{st}:{v}' for st, v in by_state.items()) + '|'


# The measure's lists for two regions: R1 spans ID then WA, and utility 100 serves tracts in both;
# R2 is WY only
BILL_STATES = pl.DataFrame(
    [('R1', 'ID', 0, 100), ('R1', 'ID', 0, 200), ('R1', 'WA', 1, 100), ('R2', 'WY', 0, 300)],
    schema=ubj.BILL_STATES_SCHEMA, orient='row')

# Building 1 is in R1, so the measure writes utility 100 twice, ID's bill (with ID's escalation)
# before WA's. Building 2 is in R2.
SIM_OUTS = pl.DataFrame({
    N.BLDG_ID: [1, 2],
    N.FLR_AREA: [1000.0, 2000.0],
    N.SAMPLING_REGION: ['R1', 'R2'],
    N.UTIL_BILL_ELEC_RESULTS: [
        bills_string(block('100', 1000), block('200', 1500), block('100', 1100)),
        bills_string(block('300', 2000)),
    ],
    N.UTIL_BILL_STATE_ELEC_RESULTS: [state_string(ID=900, WA=950), state_string(WY=1900)],
    N.UTIL_BILL_STATE_GAS_RESULTS: [state_string(ID=10, WA=11), state_string(WY=20)],
    N.UTIL_BILL_STATE_PROPANE_RESULTS: [state_string(ID=0, WA=0), state_string(WY=0)],
    N.UTIL_BILL_STATE_FUEL_OIL_RESULTS: [state_string(ID=0, WA=0), state_string(WY=0)],
}).with_columns(pl.col(N.UTIL_BILL_ELEC_RESULTS).cast(pl.Categorical))

# The same results from a measure version that records each block's state
SIM_OUTS_WITH_STATES = SIM_OUTS.with_columns(pl.Series(N.UTIL_BILL_ELEC_RESULTS, [
    bills_string(block('100', 1000, 'ID'), block('200', 1500, 'ID'), block('100', 1100, 'WA')),
    bills_string(block('300', 2000, 'WY')),
]).cast(pl.Categorical))

# 10 allocated rows; tracts T1/T3 (ID) and T2 (WA) are served by utility 100, T6 (WA) by none
TRACT_TO_UTIL = pl.DataFrame({
    N.TRACT_ID: ['T1', 'T2', 'T3', 'T4', 'T5', 'T6'],
    N.UTIL_BILL_EIA_ID: [100, 100, 100, 200, 300, None],
})
DRAW = pl.DataFrame({
    N.BLDG_ID: [1, 1, 1, 1, 1, 1, 2, 2, 2, 2],
    N.TRACT_ID: ['T1', 'T2', 'T3', 'T1', 'T4', 'T6', 'T5', 'T5', 'T5', 'T5'],
    N.STATE_ABBRV: ['ID', 'WA', 'ID', 'ID', 'ID', 'WA', 'WY', 'WY', 'WY', 'WY'],
    N.BLDG_WEIGHT: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0],
})


def parse(sim_outs=SIM_OUTS, bill_states=BILL_STATES, keep_cols=()):
    return ubj.electricity_bills_by_utility(
        sim_outs.lazy(), N.BLDG_ID, N.UTIL_BILL_ELEC_RESULTS, N.UTIL_BILL_EIA_ID, VALS,
        N.SAMPLING_REGION, N.UTIL_BILL_STATE_ELEC_RESULTS, keep_cols=keep_cols, bill_states=bill_states).collect()


def test_each_block_gets_its_state_from_the_measure_order():
    bills = parse().sort(N.BLDG_ID, N.UTIL_BILL_EIA_ID, ubj.BILL_STATE)
    assert bills.select(N.BLDG_ID, N.UTIL_BILL_EIA_ID, ubj.BILL_STATE, N.UTIL_BILL_ELEC).rows() == [
        (1, 100, 'ID', 1000), (1, 100, 'WA', 1100), (1, 200, 'ID', 1500), (2, 300, 'WY', 2000)]
    assert bills.schema[N.UTIL_BILL_ELEC] == pl.Int64
    assert bills.schema[N.UTIL_BILL_EIA_ID] == pl.Int64


def test_state_field_gives_the_same_bills_as_the_measure_order():
    from_order = parse()
    from_field = parse(SIM_OUTS_WITH_STATES, bill_states=BILL_STATES.head(0))
    keys = [N.BLDG_ID, N.UTIL_BILL_EIA_ID, ubj.BILL_STATE]
    assert_frame_equal(from_order.sort(keys), from_field.sort(keys))


def old_join(sim_outs, draw):
    """The bills-by-utility join as it was on main 3c103063 (comstock.py:2450-2500)."""
    res, eia = N.UTIL_BILL_ELEC_RESULTS, N.UTIL_BILL_EIA_ID
    bills = sim_outs.select([N.BLDG_ID, res, N.FLR_AREA]).with_columns(pl.col(res).cast(pl.String))
    bills = bills.with_columns(pl.col(res).str.strip_chars_start('|').str.strip_chars_end('|').str.split('|')).explode(res)
    bills = bills.with_columns(pl.col(res).str.split(':').alias('tsc'))
    new_cols = [eia] + VALS
    bills = bills.with_columns(pl.col('tsc').list.to_struct('max_width', new_cols)).unnest('tsc')
    bills = bills.with_columns([pl.when(pl.col(c) == '').then(None).otherwise(pl.col(c)).alias(c) for c in new_cols])
    bills = bills.with_columns([pl.col(c).cast(pl.Int64) for c in [c for c in VALS if '..usd' in c] + [eia]])
    return draw.join(bills, on=[N.BLDG_ID, eia], how='left')


def test_matches_old_join_keeping_each_rows_own_state():
    draw = DRAW.with_row_index('row').join(TRACT_TO_UTIL, on=N.TRACT_ID, how='left')
    old = old_join(SIM_OUTS, draw)
    bills = parse(keep_cols=[N.FLR_AREA]).lazy()
    bills, keys = ubj.bills_join_keys(bills, N.BLDG_ID, N.UTIL_BILL_EIA_ID, N.STATE_ABBRV)
    new = draw.join(bills.collect(), on=keys, how='left')

    # Same columns, in the same order, with the same dtypes, except the parsed block string, which
    # the old join carried on every row and the new one drops
    res = N.UTIL_BILL_ELEC_RESULTS
    assert res in old.columns and res not in new.columns
    old = old.drop(res)
    assert new.schema == old.schema
    # The old join copied building 1's four utility-100 rows (utility 100 is in its string twice)
    assert old.height == DRAW.height + 4
    assert new.height == DRAW.height
    # Every new row is the old copy built from its own state's block: ID's 1000 in ID, WA's 1100 in WA
    other_state = (pl.col(N.UTIL_BILL_EIA_ID) == 100) & (
        ((pl.col(N.STATE_ABBRV) == 'ID') & (pl.col(N.UTIL_BILL_ELEC) == 1100))
        | ((pl.col(N.STATE_ABBRV) == 'WA') & (pl.col(N.UTIL_BILL_ELEC) == 1000))).fill_null(False)
    assert_frame_equal(new.sort('row'), old.filter(~other_state).sort('row'))
    assert new.filter(pl.col('row') == 1)[N.UTIL_BILL_ELEC].item() == 1100


def test_empty_results_string_is_dropped():
    sim_outs = SIM_OUTS.with_columns(pl.col(N.UTIL_BILL_ELEC_RESULTS).cast(pl.String))
    sim_outs = pl.concat([sim_outs, sim_outs.head(1).with_columns(
        pl.lit(3).cast(sim_outs.schema[N.BLDG_ID]).alias(N.BLDG_ID),
        pl.lit('').alias(N.UTIL_BILL_ELEC_RESULTS))])
    assert 3 not in parse(sim_outs)[N.BLDG_ID].to_list()


def with_results(*results, sim_outs=SIM_OUTS):
    return sim_outs.with_columns(pl.Series(N.UTIL_BILL_ELEC_RESULTS, list(results)).cast(pl.Categorical))


def test_mixed_formats_raise():
    sim_outs = with_results(bills_string(block('100', 1000, 'ID')), bills_string(block('300', 2000)))
    with pytest.raises(ValueError, match='mix blocks with and without their state'):
        parse(sim_outs)


def test_a_state_field_that_is_not_a_state_raises():
    sim_outs = with_results(bills_string(block('100', 1000, 'Idaho')), bills_string(block('300', 2000, 'WY')))
    with pytest.raises(ValueError, match='other than a state abbreviation'):
        parse(sim_outs)


def test_states_in_another_order_raise():
    sim_outs = SIM_OUTS.with_columns(pl.Series(N.UTIL_BILL_STATE_ELEC_RESULTS,
                                               [state_string(WA=950, ID=900), state_string(WY=1900)]))
    with pytest.raises(ValueError, match='list their states in another order'):
        parse(sim_outs)


def test_unknown_region_raises():
    with pytest.raises(ValueError, match='list their states in another order'):
        parse(SIM_OUTS.with_columns(pl.Series(N.SAMPLING_REGION, ['R9', 'R2'])))


def test_blocks_that_do_not_match_the_utilitys_states_raise():
    # Utility 100 serves ID and WA tracts in R1, so it must have two blocks
    sim_outs = with_results(bills_string(block('100', 1000), block('200', 1500)), bills_string(block('300', 2000)))
    with pytest.raises(ValueError, match='do not match the states their utility serves'):
        parse(sim_outs)


def test_row_without_its_states_bill_raises_only_for_order_based_states():
    bills, keys = ubj.bills_join_keys(parse().lazy(), N.BLDG_ID, N.UTIL_BILL_EIA_ID, N.STATE_ABBRV)
    alloc = DRAW.join(TRACT_TO_UTIL, on=N.TRACT_ID, how='left').lazy()
    ubj.check_rows_find_their_state(alloc, bills, keys, ubj.STATE_FROM_MEASURE_ORDER)
    # A WA row of utility 200, which the measure billed for ID only
    stray = pl.LazyFrame({N.BLDG_ID: [1], N.STATE_ABBRV: ['WA'], N.UTIL_BILL_EIA_ID: [200]})
    with_stray = pl.concat([alloc.select(keys), stray.select(keys)])
    # states from the measure's order: every utility was billed under the same tariffs in every state,
    # so a missing state means the tract maps disagree
    with pytest.raises(ValueError, match='have no electricity bill'):
        ubj.check_rows_find_their_state(with_stray, bills, keys, ubj.STATE_FROM_MEASURE_ORDER)
    # states recorded by the measure: each state has its own tariffs, so the row simply had none that
    # applied and takes the state average
    ubj.check_rows_find_their_state(with_stray, bills, keys, ubj.STATE_FROM_BILL_RESULTS)


def test_bills_stage_fills_state_average_where_no_in_state_tariff_applied(tmp_path, monkeypatch):
    # Building 1 in R1 (ID, WA): the measure records states, and utility 100 has an applicable tariff
    # in ID only (none of its WA tariffs covered the building), so there is no WA block
    sim_outs = SIM_OUTS_WITH_STATES.with_columns(pl.Series(N.UTIL_BILL_ELEC_RESULTS, [
        bills_string(block('100', 1000, 'ID'), block('200', 1500, 'ID')),
        bills_string(block('300', 2000, 'WY')),
    ]).cast(pl.Categorical))
    cs, root = make_comstock(tmp_path, monkeypatch, sim_outs)
    out = read_stage(cs.create_allocated_weights_plus_util_bills_for_upgrade(0))
    assert out.height == DRAW.height
    # tract T2 (WA, utility 100) gets WA's state-average bill, 950; the ID rows keep utility 100's bill
    by_weight = out.filter(pl.col(N.BLDG_ID) == 1).sort(N.BLDG_WEIGHT)
    assert by_weight[N.UTIL_BILL_ELEC].to_list() == [1000, 950, 1000, 1000, 1500, 950]
    # every row carries its building's floor area, the state-average rows included, so the bill
    # intensities computed downstream are defined for them
    assert by_weight[N.FLR_AREA].to_list() == [1000.0] * 6
    assert out[N.FLR_AREA].null_count() == 0


@pytest.mark.skipif(not os.path.isdir(MEASURE_RESOURCES), reason='needs the utility_bills measure resources')
def test_bill_state_table_matches_measure():
    assert_frame_equal(ubj.build_bill_state_table(MEASURE_RESOURCES), ubj.read_bill_state_table())


def test_assert_unique_on_names_offending_key():
    lf = pl.LazyFrame({'a': [1, 1, 2], 'b': [5, 5, 6]})
    with pytest.raises(ValueError, match='1 duplicated join keys'):
        ubj.assert_unique_on(lf, ['a', 'b'], 'frame')
    ubj.assert_unique_on(pl.LazyFrame({'a': [1, 2]}), ['a'], 'frame')


def test_assert_row_count_preserved():
    ubj.assert_row_count_preserved(10, 10, 'join')
    with pytest.raises(ValueError, match='from 10 to 12'):
        ubj.assert_row_count_preserved(10, 12, 'join')


def make_comstock(tmp_path, monkeypatch, sim_outs=SIM_OUTS):
    """A ComStock with only what create_allocated_weights_plus_util_bills_for_upgrade reads."""
    cs = ComStock.__new__(ComStock)
    out_dir = tmp_path / 'output'
    truth_dir = tmp_path / 'truth'
    out_dir.mkdir()
    truth_dir.mkdir()
    TRACT_TO_UTIL.write_csv(truth_dir / 'tract_to_util.csv')
    BILL_STATES.write_csv(truth_dir / 'bill_states.csv')
    # the getter joins the PUMA of each tract from the geospatial lookup
    pl.DataFrame({'nhgis_tract_gisjoin': TRACT_TO_UTIL[N.TRACT_ID], 'nhgis_puma_gisjoin': 'P1'}).write_csv(truth_dir / 'geo.csv')
    monkeypatch.setattr(ubj, 'BILL_STATES_FILE', (truth_dir / 'bill_states.csv').as_posix())
    cs.output_dir = {'fs': fsspec.filesystem('file'), 'fs_path': out_dir.as_posix(), 'storage_options': None}
    cs.truth_data_dir = truth_dir.as_posix()
    cs.tract_to_util_map_file_name = 'tract_to_util.csv'
    cs.geospatial_lookup_file_name = 'geo.csv'
    cs.weighted_utility_units = 'billion_usd'
    cs.unweighted_weighted_map = {}
    cs.data = sim_outs.with_columns(pl.lit(0).alias(N.UPGRADE_ID)).lazy()
    cs.get_sim_outs_for_upgrade = lambda upgrade_id: cs.data
    cs.get_allocated_weights_scaled_to_cbecs_for_upgrade = lambda upgrade_id: DRAW.lazy().with_columns(
        pl.lit(upgrade_id).cast(pl.Int64).alias(N.UPGRADE_ID))
    return cs, out_dir.as_posix() + '/cached_allocated_weights_plus_bills'


def read_stage(bills_dir):
    return pl.scan_parquet(f'{bills_dir}/**/*.parquet', hive_partitioning=True).collect()


def test_bills_stage_preserves_rows_and_weights(tmp_path, monkeypatch):
    cs, root = make_comstock(tmp_path, monkeypatch)
    out = read_stage(cs.create_allocated_weights_plus_util_bills_for_upgrade(0))

    assert out.height == DRAW.height
    assert out[N.BLDG_WEIGHT].sum() == DRAW[N.BLDG_WEIGHT].sum()
    # Each row gets its own state's bill: WA's 1100 in tract T2, the WA state average in T6
    by_weight = out.filter(pl.col(N.BLDG_ID) == 1).sort(N.BLDG_WEIGHT)
    assert by_weight[N.UTIL_BILL_ELEC].to_list() == [1000, 1100, 1000, 1000, 1500, 950]
    # tract T6 has no utility and is billed at the state average; its row still carries the floor area
    assert out[N.FLR_AREA].null_count() == 0 and out.filter(pl.col(N.BLDG_ID) == 2)[N.FLR_AREA].to_list() == [2000.0] * 4
    # the getter reads the same table back from the cache
    cached = cs.get_allocated_weights_plus_util_bills_for_upgrade(0).collect()
    assert cached.height == out.height and cached[N.BLDG_WEIGHT].sum() == out[N.BLDG_WEIGHT].sum()
    assert sorted(cached[N.UTIL_BILL_ELEC].to_list()) == sorted(out[N.UTIL_BILL_ELEC].to_list())


def test_bills_stage_is_the_same_with_and_without_the_state_field(tmp_path, monkeypatch):
    stages, infos = {}, {}
    parse = ubj.electricity_bills_by_utility

    def parse_and_keep_info(*args, **kwargs):
        bills = parse(*args, **kwargs)
        infos[kwargs['info']['bill_state_source']] = dict(kwargs['info'])
        return bills
    monkeypatch.setattr(ubj, 'electricity_bills_by_utility', parse_and_keep_info)
    for name, sim_outs in [('order', SIM_OUTS), ('field', SIM_OUTS_WITH_STATES)]:
        (tmp_path / name).mkdir()
        cs, root = make_comstock(tmp_path / name, monkeypatch, sim_outs)
        stages[name] = read_stage(cs.create_allocated_weights_plus_util_bills_for_upgrade(0))
    # the states came from the measure's order for the old format and from the bills for the new one
    assert sorted(infos) == sorted([ubj.STATE_FROM_MEASURE_ORDER, ubj.STATE_FROM_BILL_RESULTS])
    assert all(i['n_electricity_bills'] == 4 and i['n_buildings_with_bills'] == 2 for i in infos.values())
    order = [N.BLDG_ID, N.BLDG_WEIGHT]
    assert_frame_equal(stages['order'].sort(order), stages['field'].sort(order))
    assert N.UTIL_BILL_ELEC_RESULTS not in stages['field'].columns


def test_bill_result_strings_are_imported_but_the_electricity_string_is_not_exported():
    col_defs = pl.read_csv(os.path.join(os.path.dirname(ubj.__file__), 'resources', 'comstock_column_definitions.csv'))
    imported = ComStock.__new__(ComStock).imported_column_definitions(col_defs)
    rows = imported.filter(pl.col('new_col_name').is_in(N.COLS_UTIL_BILL_RESULTS))
    assert sorted(rows['new_col_name']) == sorted(N.COLS_UTIL_BILL_RESULTS)
    elec = rows.filter(pl.col('new_col_name') == N.UTIL_BILL_ELEC_RESULTS)
    assert elec['full_metadata'].to_list() == [False] and elec['basic_metadata'].to_list() == [False]
    # the rest of the import list is unchanged: the exported columns of the raw results
    exported = col_defs.filter((pl.col('full_metadata') == True) &
                               (~pl.col('location').is_in(['calculated', 'geospatial', 'cejst', 'ejscreen'])))
    assert set(imported['original_col_name']) == set(exported['original_col_name']) | {'utility_bills.electricity_utility_bill_results'}


def test_bills_stage_fails_on_fan_out(tmp_path, monkeypatch):
    cs, _ = make_comstock(tmp_path, monkeypatch)
    # A tract mapped to two utilities would duplicate rows: refuse it
    pl.concat([TRACT_TO_UTIL, TRACT_TO_UTIL.head(1)]).write_csv(f'{cs.truth_data_dir}/tract_to_util.csv')
    with pytest.raises(ValueError, match='duplicated join keys'):
        cs.create_allocated_weights_plus_util_bills_for_upgrade(0)
