# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The apportionment truth data: same output as the pandas implementation, and the
places where it deliberately is not. No S3, no boto3, no cache.

Three kinds of test:

  SAME OUTPUT   comstock_apportionment.Apportion against the frozen pandas reference
                (apportionment_legacy_reference.LegacyApportion) on synthetic truth data
                written to a temp folder: frames compared exactly -- columns, dtypes,
                row order, values -- and the numpy random stream left where the old code
                left it (the allocation draw in comstock.py reads on from there).
  ERROR FIXES   behaviour that differs from the reference on purpose. Each test states
                the defect, shows the reference has it, and pins the resolution.
  INTENT        properties the output must have whatever the implementation: only
                options with a non-zero probability are drawn, floor area is conserved.

The synthetic tables are small (thousands of rows) but carry the features of the real
ones that matter: California tracts resolved through the 2010 then the 2020 CEC lookup,
the 'Mid-Atlantic' spelling, an extra fuel the draw never produces, probabilities of
exactly zero in first and last position, and -- on request -- duplicated and missing
keys in the HVAC table, as hvac_system_type_v4.tsv has.

To also check the full 2026R1 estimate against the production cache on disk (about a
minute; needs truth_data/v01 and output/Stock Estimation 2026R1), set
COMSTOCK_APPORTIONMENT_REAL_DATA=1.
"""

import inspect
import json
import logging
import os
import re
import sys
from datetime import datetime

import numpy as np
import pandas as pd
import polars as pl
import pytest
from polars.testing import assert_frame_equal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from apportionment_legacy_reference import LegacyApportion  # noqa: E402
from comstockpostproc import comstock_apportionment as ca  # noqa: E402

BUILDING_TYPES = list(LegacyApportion.BUILDING_TYPE_NAME_MAPPER)
FUELS = ['DistrictHeating', 'Electricity', 'FuelOil', 'NaturalGas', 'Propane']
SYSTEMS = [
    'DOAS with fan coil chiller with boiler', 'PSZ-AC with electric coil', 'PSZ-AC with gas coil', 'PSZ-HP',
    'PTAC with gas boiler', 'PVAV with gas boiler reheat', 'Residential AC with residential forced air furnace',
    'VAV chiller with gas boiler reheat',
]
# The HVAC table spells the Middle Atlantic division 'Mid-Atlantic'.
TABLE_REGIONS = ['New England', 'Mid-Atlantic', 'East North Central', 'West North Central', 'South Atlantic',
                 'East South Central', 'West South Central', 'Mountain', 'Pacific']
STATES = ['G060', 'G080', 'G360', 'G480', 'G250']  # Pacific (CA), Mountain, Middle Atlantic, WSC, New England
CA = 'G060'
STEPS = ['load_data', 'infer_tracts', 'add_sampling_regions', 'add_sqft_bins',
         'normalize_building_type_values', 'upsample_hvac_system_fuel_types']
FILE_NAMES = dict(
    data_file_name='TEST_building_estimate.parquet',
    hvac_size_bins_name='hvac_system_size_bin_v1.tsv',
    tract_list_name='TEST_tract_list.csv',
    sampling_regions_name='sampling_regions_v1.json',
    ca_cz_tract_2010_name='cec_cz_by_tract_2010_lkup.json',
    ca_cz_tract_2020_name='cec_cz_by_tract_2020_lkup.json',
    hvac_system_type_name='hvac_system_type_v4.tsv',
    space_heating_fuel_type_name='heating_fuel_v2.tsv',
)
CEC_TO_REGION = {'CEC1': 100, 'CEC2': 100, 'CEC3': 101, 'CEC4': 102, 'CEC5': 102, 'CEC6': 103, 'CEC7': 103,
                 'CEC8': 104, 'CEC9': 105, 'CEC10': 106, 'CEC11': 107, 'CEC12': 107, 'CEC13': 108, 'CEC14': 109,
                 'CEC15': 109, 'CEC16': 110}


# ---- synthetic truth data ---------------------------------------------------------

def _probabilities(rng, n_rows, n_options):
    """Rows of probabilities summing to 1 (to rounding), about 45% of entries exactly 0."""
    p = rng.dirichlet(np.ones(n_options), size=n_rows)
    p[rng.random(p.shape) < 0.45] = 0.0
    for i in np.flatnonzero(p.sum(axis=1) == 0):
        p[i, rng.integers(n_options)] = 1.0
    p = np.round(p / p.sum(axis=1, keepdims=True), 6)
    rows = np.arange(n_rows)
    biggest = p.argmax(axis=1)
    p[rows, biggest] = np.round(p[rows, biggest] + (1.0 - p.sum(axis=1)), 6)
    assert (p >= 0).all()
    return p


def write_truth_data(path, n=3000, seed=0, with_sampling_region=True, hvac_duplicates=False,
                     hvac_missing=False, missing_tracts=False, unknown_building_type=False,
                     unmapped_ca_tract=False, with_size_bin=True):
    """Write a synthetic truth-data folder and return what a test needs to reason about it."""
    rng = np.random.default_rng(seed)
    path = str(path)
    os.makedirs(path, exist_ok=True)

    # Geography: 3 counties per state, 4 tracts per county, one more tract only in the tract list.
    counties = {s: [f'{s}{c:03d}0' for c in (10, 30, 50)] for s in STATES}
    all_counties = [c for cs in counties.values() for c in cs]
    tracts = {c: [f'{c}{t:06d}' for t in (100, 200, 300, 400)] for c in all_counties}
    tract_list = pl.DataFrame([(c, t) for c in all_counties for t in tracts[c] + [f'{c}000900']],
                              schema=['county', 'tract'], orient='row')
    region_lkup = {c: i for i, c in enumerate(all_counties)}  # CA counties are in the file too; CEC rules win
    ca_tracts = [t for c in counties[CA] for t in tracts[c]]
    cec = {t: f'CEC{(i % 16) + 1}' for i, t in enumerate(ca_tracts)}
    cec_2010 = {t: z for i, (t, z) in enumerate(cec.items()) if i % 2 == 0}
    cec_2020 = {t: z for i, (t, z) in enumerate(cec.items()) if i % 2 == 1}
    cec_2020[ca_tracts[0]] = 'CEC16'  # in both lookups with different answers: 2010 must win
    ashrae = {c: z for c, z in zip(all_counties, ['3B', '3C', '4B', '5B', '6B', '7', '4A', '5A', '6A', '2A', '3A',
                                                  '2B', '5A', '6A', '4A'])}

    # The building estimate, one row per building.
    county = rng.choice(all_counties, n)
    tract = np.array([tracts[c][i] for c, i in zip(county, rng.integers(0, 4, n))])
    state = np.array([c[:4] for c in county])
    cz = np.array([cec[t] if s == CA else ashrae[c] for t, s, c in zip(tract, state, county)])
    est = pl.DataFrame({
        'tract': tract, 'county': county, 'state': state, 'cz': cz,
        'sqft': np.round(rng.lognormal(9, 1, n)), 'yb': rng.integers(1900, 2020, n).astype(float),
        'ns': rng.integers(1, 6, n).astype(float), 'count': np.ones(n, dtype=np.int64),
        'building_type': rng.choice(BUILDING_TYPES, n),
        'size_bin': rng.choice([0, 1, 2], n, p=[0.7, 0.25, 0.05]).astype(np.int64),
        'tract_assignment_type': pl.Series(
            [[None, 'county and building type', 'weighted within county', 'random within county'][i]
             for i in rng.choice(4, n, p=[0.9, 0.06, 0.03, 0.01])], dtype=pl.String),
    })
    region = [CEC_TO_REGION[z] if s == CA else region_lkup[c] for z, s, c in zip(cz, state, county)]
    est = est.with_columns(pl.Series('sampling_region', region, dtype=pl.Int64))
    if not with_sampling_region:
        # An estimate that has not been through the sampling-region step: CA rows carry no CEC zone yet.
        est = est.drop('sampling_region').with_columns(
            pl.when(pl.col('state') == CA).then(pl.lit('3B')).otherwise(pl.col('cz')).alias('cz'))
    if not with_size_bin:
        est = est.drop('size_bin')
    if unknown_building_type:
        est = est.with_columns(pl.when(pl.int_range(pl.len()) < 3).then(pl.lit('bowling_alley'))
                               .otherwise(pl.col('building_type')).alias('building_type'))
    if unmapped_ca_tract:
        bad = f'{counties[CA][0]}777700'
        est = est.with_columns(pl.when((pl.col('state') == CA) & (pl.int_range(pl.len()).over('state') < 2))
                               .then(pl.lit(bad)).otherwise(pl.col('tract')).alias('tract'))
    info = {'counties': counties, 'tracts': tracts}
    if missing_tracts:
        c1, c2, c3 = counties['G080']
        lone = counties['G480'][0]
        est = est.with_columns(
            # level 1: this building type still has located buildings in this county
            pl.when((pl.col('county') == c1) & (pl.col('building_type') == 'warehouse')
                    & (pl.int_range(pl.len()).over('county', 'building_type') % 2 == 0)).then(None)
            # level 2: no located building of this type in this county, others are
            .when((pl.col('county') == c2) & (pl.col('building_type') == 'hospital')).then(None)
            # level 3: nothing in this county is located; half carry the 999999 placeholder
            .when((pl.col('county') == c3) & (pl.int_range(pl.len()).over('county') % 2 == 0)).then(None)
            .when(pl.col('county') == c3).then(pl.col('county') + '999999')
            .otherwise(pl.col('tract')).alias('tract'))
        info.update(level1=(c1, 'warehouse'), level2=(c2, 'hospital'), level3=c3, lone_county=lone)
    est.write_parquet(os.path.join(path, FILE_NAMES['data_file_name']))

    # Heating fuel by building type and county.
    keys = [(b, c) for b in BUILDING_TYPES for c in all_counties]
    p = _probabilities(rng, len(keys), len(FUELS))
    fuel = pd.DataFrame(keys, columns=['Dependency=building_type', 'Dependency=county_id'])
    for j, f in enumerate(FUELS):
        fuel[f'Option={f}'] = p[:, j]
    fuel.to_csv(os.path.join(path, FILE_NAMES['space_heating_fuel_type_name']), sep='\t', index=False)

    # HVAC system by building type, size bin, heating fuel and census division. 'NaturalGasOil' rows
    # exist in the real table and are never matched: the fuel draw cannot produce that fuel.
    keys = [(b, s, f, r) for b in BUILDING_TYPES for s in (0, 1, 2) for f in FUELS + ['NaturalGasOil']
            for r in TABLE_REGIONS]
    p = _probabilities(rng, len(keys), len(SYSTEMS))
    hvac = pd.DataFrame(keys, columns=['Dependency=building_type', 'Dependency=size_bin',
                                       'Dependency=heating_fuel', 'Dependency=census_region'])
    for j, s in enumerate(SYSTEMS):
        hvac[f'Option={s}'] = p[:, j]
    bt, sb, hf, rg = (hvac[f'Dependency={k}'] for k in ('building_type', 'size_bin', 'heating_fuel', 'census_region'))
    if hvac_missing:
        gone = ((bt == 'large_hotel') & (sb == 0) & (hf == 'DistrictHeating')) | \
               ((bt == 'small_office') & (sb == 0) & (hf == 'Electricity') & rg.isin(['Pacific', 'Mountain']))
        hvac = hvac.loc[~gone].reset_index(drop=True)
        bt, sb, hf, rg = (hvac[f'Dependency={k}'] for k in ('building_type', 'size_bin', 'heating_fuel',
                                                            'census_region'))
    if hvac_duplicates:
        # As in hvac_system_type_v4.tsv: a second block of propane rows appended to the file, some
        # identical to the first copy and some with different probabilities.
        same = hvac.loc[(bt == 'full_service_restaurant') & (sb == 0) & (hf == 'Propane')].copy()
        differ = hvac.loc[(bt == 'retail') & (sb == 0) & (hf == 'Propane')].copy()
        q = _probabilities(rng, len(differ), len(SYSTEMS))
        for j, s in enumerate(SYSTEMS):
            differ[f'Option={s}'] = q[:, j]
        hvac = pd.concat([hvac, same, differ], ignore_index=True)
    hvac.to_csv(os.path.join(path, FILE_NAMES['hvac_system_type_name']), sep='\t', index=False)

    tract_list.write_csv(os.path.join(path, FILE_NAMES['tract_list_name']))
    pd.DataFrame({'Dependency=building_type': BUILDING_TYPES, 'Option=0': 1.0}).to_csv(
        os.path.join(path, FILE_NAMES['hvac_size_bins_name']), sep='\t', index=False)
    for name, lkup in [('sampling_regions_name', region_lkup), ('ca_cz_tract_2010_name', cec_2010),
                       ('ca_cz_tract_2020_name', cec_2020)]:
        with open(os.path.join(path, FILE_NAMES[name]), 'w') as f:
            json.dump(lkup, f)
    info.update(path=path, estimate=est, hvac=hvac, fuel=fuel, cec=cec, cec_2010=cec_2010)
    return info


# ---- driving the two implementations ----------------------------------------------

def _configured(cls, truth_dir, bootstrap=3, **settings):
    """An object of either class pointed at a truth-data folder, without its __init__ (no S3)."""
    obj = cls.__new__(cls)
    obj.truth_data_dir = str(truth_dir)
    obj.bootstrap_coefficient = bootstrap
    for attr, name in FILE_NAMES.items():
        setattr(obj, attr, name)
    for attr, value in settings.items():
        setattr(obj, attr, value)
    return obj


def _run(cls, truth_dir, bootstrap=3, steps=STEPS, **settings):
    obj = _configured(cls, truth_dir, bootstrap, **settings)
    for step in steps:
        getattr(obj, step)()
    return obj


def run_legacy(truth_dir, **kw):
    return _run(LegacyApportion, truth_dir, **kw)


def run_new(truth_dir, **kw):
    return _run(ca.Apportion, truth_dir, **kw)


def frame(obj):
    """obj.data as polars, whichever library the implementation holds it in."""
    data = obj.data
    return data if isinstance(data, pl.DataFrame) else pl.from_pandas(data.reset_index(drop=True))


def _refactored(name):
    """An attribute the polars refactor adds to the module; skip on the pandas implementation."""
    if not hasattr(ca, name):
        pytest.skip(f'comstock_apportionment.{name} is introduced by the polars refactor')
    return getattr(ca, name)


def _same(new, legacy):
    assert_frame_equal(frame(new), frame(legacy), check_exact=True)


@pytest.fixture
def no_breakpoint(monkeypatch):
    """The pandas infer_tracts stops in the debugger; let it run on."""
    monkeypatch.setattr(sys, 'breakpointhook', lambda *a, **k: None)


# ---- SAME OUTPUT ------------------------------------------------------------------

def test_pipeline_matches_legacy(tmp_path):
    """Well-formed tables: the whole truth-data frame is identical, cell for cell."""
    info = write_truth_data(tmp_path)
    legacy, new = run_legacy(tmp_path), run_new(tmp_path)
    _same(new, legacy)
    assert frame(new).height == 3 * info['estimate'].height
    assert frame(new).columns == [
        'tract', 'county', 'state', 'cz', 'sqft', 'yb', 'ns', 'count', 'building_type', 'size_bin',
        'tract_assignment_type', 'sampling_region', 'cen_div', 'county_id', 'heating_fuel', 'census_region',
        'system_type', 'hvac_and_fueltype']


@pytest.mark.parametrize('bootstrap', [1, 2, 5])
def test_pipeline_matches_legacy_for_any_bootstrap_coefficient(tmp_path, bootstrap):
    info = write_truth_data(tmp_path, n=1200, seed=bootstrap)
    legacy, new = run_legacy(tmp_path, bootstrap=bootstrap), run_new(tmp_path, bootstrap=bootstrap)
    _same(new, legacy)
    assert frame(new).height == bootstrap * info['estimate'].height


def test_pipeline_matches_legacy_on_a_table_with_duplicate_and_missing_keys(tmp_path):
    """The default settings keep the pandas behaviour on a table shaped like
    hvac_system_type_v4.tsv -- duplicated keys repeat buildings, unmatched buildings
    vanish -- so a cache rebuilt by the refactored code is the cache there was before.
    (That behaviour is wrong; see the ERROR FIXES tests for the settings that correct it.)"""
    info = write_truth_data(tmp_path, hvac_duplicates=True, hvac_missing=True)
    legacy, new = run_legacy(tmp_path), run_new(tmp_path)
    _same(new, legacy)
    assert frame(new).height != 3 * info['estimate'].height  # the fixture does exercise both defects


def test_numpy_random_stream_is_left_where_legacy_left_it(tmp_path):
    """Building the truth data seeds numpy's GLOBAL generator and draws from it. The allocation
    draw in comstock.py (np.random.choice) reads on from wherever that leaves the stream when both
    happen in one process, so the refactor must consume exactly the same numbers."""
    write_truth_data(tmp_path, hvac_duplicates=True, hvac_missing=True)
    run_legacy(tmp_path)
    after_legacy = np.random.rand(5)
    run_new(tmp_path)
    after_new = np.random.rand(5)
    assert np.array_equal(after_new, after_legacy)


def test_sampling_regions_are_derived_as_legacy_when_the_estimate_lacks_them(tmp_path):
    """An estimate without a sampling_region column: county lookup everywhere, and in California
    the tract's CEC climate zone (2010 lookup first, then 2020) overwrites cz and sets the region."""
    info = write_truth_data(tmp_path, with_sampling_region=False)
    legacy, new = run_legacy(tmp_path), run_new(tmp_path)
    _same(new, legacy)
    out = frame(new)
    cal = out.filter(pl.col('state') == CA)
    assert cal.height > 0
    assert cal.select((pl.col('cz') == pl.col('tract').replace_strict(info['cec'])).all()).item()
    assert cal.select((pl.col('sampling_region') == pl.col('cz').replace_strict(CEC_TO_REGION)).all()).item()
    first = next(iter(info['cec_2010']))  # the tract that is in both lookups
    assert set(cal.filter(pl.col('tract') == first)['cz']) == {info['cec_2010'][first]}
    assert out.filter(pl.col('state') != CA).select((pl.col('sampling_region') < 100).all()).item()


def test_sampling_regions_in_the_estimate_are_left_alone(tmp_path):
    info = write_truth_data(tmp_path)
    new = _run(ca.Apportion, tmp_path, steps=STEPS[:3])
    assert_frame_equal(frame(new), info['estimate'])


def test_california_tract_without_a_cec_zone_is_an_error(tmp_path):
    write_truth_data(tmp_path, with_sampling_region=False, unmapped_ca_tract=True)
    with pytest.raises(RuntimeError, match='CEC Climate Zone'):
        run_legacy(tmp_path)
    with pytest.raises(RuntimeError, match='CEC Climate Zone'):
        run_new(tmp_path)


def test_unknown_building_type_is_an_error(tmp_path):
    write_truth_data(tmp_path, unknown_building_type=True)
    with pytest.raises(RuntimeError, match='building type'):
        run_legacy(tmp_path)
    with pytest.raises(RuntimeError, match='building type'):
        run_new(tmp_path)


def test_estimate_without_size_bins_is_an_error(tmp_path):
    write_truth_data(tmp_path, with_size_bin=False)
    with pytest.raises(NotImplementedError):
        run_legacy(tmp_path)
    with pytest.raises(NotImplementedError):
        run_new(tmp_path)


def test_apportionment_groups_match_the_pandas_construction(tmp_path):
    """The group ids comstock.py numbers the truth data and the sample by: same groups, same ids."""
    apportionment_groups = _refactored('apportionment_groups')
    write_truth_data(tmp_path, n=1500)
    legacy, new = run_legacy(tmp_path), run_new(tmp_path)
    attrs = ['sampling_region', 'building_type', 'size_bin', 'hvac_and_fueltype']
    expected = legacy.data.copy(deep=True).loc[:, attrs].drop_duplicates(keep='first').sort_values(
        by=attrs).reset_index(drop=True).reset_index(names='appo_group_id')  # as comstock.py had it
    assert_frame_equal(apportionment_groups(new.data, 'appo_group_id'), pl.from_pandas(expected))


# ---- sampling buckets --------------------------------------------------------------

def _bucket_data():
    """Truth data whose bucket counts are all different, so nothing depends on how ties sort
    (the pandas code breaks ties by numpy's unstable sort and by set iteration order).

    Count k for bucket k = 1..60; the 99% cut-off removes the smallest. Bucket 1 is alone in its
    (region, type, size bin, fuel) combination so it must come back with its only system; buckets 2
    and 3 share a combination, so that comes back once, with the commoner system (bucket 3's).
    Buckets 58-60 are the three combinations the code refuses to sample.
    """
    rows = []
    for k in range(1, 61):
        bucket = dict(sampling_region=k % 7, building_type=['Warehouse', 'SmallOffice', 'Grocery'][k % 3],
                      size_bin=k % 2, heating_fuel=FUELS[k % 5], system_type=SYSTEMS[k % 8])
        if k == 1:
            bucket.update(sampling_region=50, system_type='PSZ-HP')
        if k in (2, 3):
            bucket.update(sampling_region=51, building_type='Warehouse', size_bin=0, heating_fuel='Propane',
                          system_type='PSZ-HP' if k == 2 else 'PSZ-AC with gas coil')
        if k == 58:
            bucket.update(sampling_region=103, building_type='Hospital', size_bin=0)
        if k == 59:
            bucket.update(sampling_region=109, building_type='Hospital', size_bin=0)
        if k == 60:
            bucket.update(sampling_region=110, building_type='LargeHotel', size_bin=1)
        rows += [bucket] * k
    df = pl.DataFrame(rows).sample(fraction=1.0, shuffle=True, seed=3)
    return df.with_columns(pl.col('sampling_region').cast(pl.Int64), pl.col('size_bin').cast(pl.Int64))


def _sampling_inputs(obj, out_dir, n_samples):
    """{rows: frame} for the csv files generate_sampling_input writes."""
    os.makedirs(out_dir, exist_ok=True)
    if isinstance(obj, LegacyApportion):
        obj.sampling_output_dir = str(out_dir)
        obj.generate_sampling_input(n_samples=n_samples)
    elif 'output_dir' in inspect.signature(obj.generate_sampling_input).parameters:
        obj.generate_sampling_input(n_samples=n_samples, output_dir=str(out_dir))
    else:
        pytest.skip('the pandas generate_sampling_input can only write into <repo>/sampling')
    files = sorted(os.listdir(out_dir))
    assert len(files) == len(n_samples)
    return {int(f.rsplit('_', 1)[1][:-4]): pl.read_csv(os.path.join(out_dir, f)) for f in files}


def test_sampling_input_matches_legacy(tmp_path):
    data = _bucket_data()
    legacy = LegacyApportion.__new__(LegacyApportion)
    legacy.data = data.to_pandas()
    new = ca.Apportion.__new__(ca.Apportion)
    new.data = data
    old_files = _sampling_inputs(legacy, tmp_path / 'legacy', [1, 4])
    new_files = _sampling_inputs(new, tmp_path / 'new', [1, 4])
    assert sorted(new_files) == sorted(old_files)
    buckets = ['sampling_region', 'building_type', 'size_bin', 'heating_fuel', 'hvac_system_type']
    for rows, got in new_files.items():
        want = old_files[rows]
        assert got.columns == want.columns == ['Building'] + buckets
        assert got['Building'].to_list() == list(range(rows))
        # Same buckets, each the same number of times. Row order is compared loosely: the pandas
        # code appends the added buckets in set-iteration order, which changes from run to run.
        assert_frame_equal(got.drop('Building').sort(buckets), want.drop('Building').sort(buckets))
    one = new_files[min(new_files)].drop('Building')
    as_tuples = set(one.iter_rows())
    assert (50, 'small_office', 1, 'Electricity', 'PSZ-HP') in as_tuples            # bucket 1, brought back
    assert (51, 'warehouse', 0, 'Propane', 'PSZ-AC with gas coil') in as_tuples     # buckets 2+3, commoner system
    assert (51, 'warehouse', 0, 'Propane', 'PSZ-HP') not in as_tuples
    assert not ({(103, 'hospital', 0), (109, 'hospital', 0), (110, 'large_hotel', 1)}
                & {(r, b, s) for r, b, s, _, _ in as_tuples})                        # never sampled
    four = new_files[max(new_files)].drop('Building')
    assert four.height == 4 * one.height
    assert_frame_equal(four.gather_every(4), one)  # each bucket's copies are consecutive, in bucket order


def test_sampling_input_covers_every_combination_in_the_truth_data(tmp_path):
    """On tie-ridden data, where the two implementations may legitimately pick different buckets:
    every (region, type, size bin, fuel) combination in the truth data is sampled, once per system
    chosen for it, and the file is the same from one run to the next."""
    write_truth_data(tmp_path / 'truth', n=2000)
    new = run_new(tmp_path / 'truth')
    first = _sampling_inputs(new, tmp_path / 'a', [1])
    again = _sampling_inputs(new, tmp_path / 'b', [1])
    (rows, got), = first.items()
    assert_frame_equal(got, again[rows])
    combo = ['sampling_region', 'building_type', 'size_bin', 'heating_fuel']
    back = {v: k for k, v in LegacyApportion.BUILDING_TYPE_NAME_MAPPER.items()}
    needed = frame(new).select(combo).unique().with_columns(pl.col('building_type').replace_strict(back))
    never = pl.DataFrame([(103, 'hospital', 0), (109, 'hospital', 0), (110, 'large_hotel', 1)], orient='row',
                         schema={'sampling_region': pl.Int64, 'building_type': pl.String, 'size_bin': pl.Int64})
    assert needed.join(never, on=never.columns, how='semi').height > 0  # the fixture has some to leave out
    needed = needed.join(never, on=never.columns, how='anti')
    assert got.select(combo).unique().sort(combo).equals(needed.sort(combo))
    assert got.drop('Building').is_duplicated().sum() == 0


def test_sampling_input_file_is_stamped_with_minutes():
    """ERROR FIX. The pandas code stamps the file '%Y%m%d-%H%m' -- hour then MONTH -- so two files
    written in the same hour share a name and the second overwrites the first."""
    name = _refactored('sampling_input_file_name')
    assert name(datetime(2026, 11, 17, 14, 5), 8634) == 'sample_input_20261117-1405_8634.csv'


# ---- INTENT ------------------------------------------------------------------------

def _legacy_choice(p, u):
    """What the pandas code draws for probabilities p (rows x options) and uniforms u: the last
    option whose preceding probabilities sum to no more than u."""
    choice = np.zeros(len(u), dtype=int)
    for j in range(1, p.shape[1]):
        choice[u >= p[:, :j].sum(axis=1)] = j
    return choice


def test_draw_is_the_inverse_cdf_at_the_boundaries():
    """Hand-checked: a uniform equal to a cumulative boundary belongs to the option above it, and
    an option with zero probability is never drawn -- first, middle or last."""
    ProbabilityTable = _refactored('ProbabilityTable')
    table = ProbabilityTable(name='t', keys=['k'], options=['a', 'b', 'c', 'd'], frame=pl.DataFrame(
        {'k': ['x', 'y'], 'a': [0.0, 0.25], 'b': [0.5, 0.25], 'c': [0.0, 0.5], 'd': [0.5, 0.0]}))
    df = pl.DataFrame({'id': range(10), 'k': ['x'] * 5 + ['y'] * 5})
    u = np.array([0.0, 0.4999, 0.5, 0.9999, 0.7, 0.0, 0.25, 0.4999, 0.5, 0.999999])
    out, report = ca.assign_from_probability_table(df, table, on={'k': 'k'}, uniforms=lambda n: u[:n], into='pick')
    assert out['id'].to_list() == list(range(10))
    assert out['pick'].to_list() == ['b', 'b', 'd', 'd', 'd', 'a', 'b', 'b', 'c', 'c']
    assert report['unmatched_rows'] == 0 and report['duplicate_keys'] == 0


def test_draw_matches_the_pandas_rule_on_random_tables():
    ProbabilityTable = _refactored('ProbabilityTable')
    rng = np.random.default_rng(11)
    options = [f'o{j}' for j in range(12)]
    p = _probabilities(rng, 40, len(options))
    table = ProbabilityTable(name='t', keys=['k'], options=options, frame=pl.DataFrame(
        {'k': np.arange(40)} | {o: p[:, j] for j, o in enumerate(options)}))
    rows = rng.integers(0, 40, 20000)
    u = rng.random(20000)
    u[:40] = p.cumsum(axis=1)[np.arange(40), rng.integers(0, 12, 40)].clip(0, 0.999999)  # sit on boundaries
    out, _ = ca.assign_from_probability_table(pl.DataFrame({'k': rows}), table, on={'k': 'k'},
                                              uniforms=lambda n: u, into='pick')
    want = np.array(options)[_legacy_choice(p[rows], u)]
    assert out['pick'].to_list() == want.tolist()
    assert (p[rows, [options.index(o) for o in out['pick']]] > 0).all()


def test_only_options_with_a_probability_are_drawn_and_floor_area_is_conserved(tmp_path):
    info = write_truth_data(tmp_path, n=4000)
    out = frame(run_new(tmp_path))
    back = {v: k for k, v in LegacyApportion.BUILDING_TYPE_NAME_MAPPER.items()}
    out = out.with_columns(pl.col('building_type').replace_strict(back).alias('bt'))
    fuel = pl.from_pandas(info['fuel']).unpivot(index=['Dependency=building_type', 'Dependency=county_id'],
                                                variable_name='heating_fuel', value_name='p').with_columns(
        pl.col('heating_fuel').str.replace('Option=', '', literal=True))
    p_fuel = out.join(fuel, left_on=['bt', 'county', 'heating_fuel'],
                      right_on=['Dependency=building_type', 'Dependency=county_id', 'heating_fuel'], how='left')['p']
    assert p_fuel.null_count() == 0 and p_fuel.min() > 0
    keys = [f'Dependency={k}' for k in ('building_type', 'size_bin', 'heating_fuel', 'census_region')]
    hvac = pl.from_pandas(info['hvac']).unpivot(index=keys, variable_name='system_type', value_name='p').with_columns(
        pl.col('system_type').str.replace('Option=', '', literal=True),
        pl.col('Dependency=census_region').replace('Mid-Atlantic', 'Middle Atlantic'))
    p_sys = out.join(hvac, left_on=['bt', 'size_bin', 'heating_fuel', 'cen_div', 'system_type'],
                     right_on=keys + ['system_type'], how='left')['p']
    assert p_sys.null_count() == 0 and p_sys.min() > 0
    assert out['sqft'].sum() == pytest.approx(3 * info['estimate']['sqft'].sum(), rel=1e-12)
    assert out.select((pl.col('hvac_and_fueltype') == pl.col('system_type') + '_' + pl.col('heating_fuel')).all()).item()
    assert set(out.filter(pl.col('state') == 'G360')['cen_div']) == {'Middle Atlantic'}


# ---- ERROR FIXES -------------------------------------------------------------------
#
# 1. Duplicated keys in the HVAC table. hvac_system_type_v4.tsv lists 52 keys twice (all
#    propane). The pandas merge returns a building once per matching table row, so each of
#    those buildings is in the truth data twice and its floor area is counted twice.
# 2. Keys missing from the HVAC table. The merge is an inner join, so a building whose
#    (type, size bin, drawn fuel, division) has no row in the table disappears.
# 3. Tract inference stops in the debugger and then fails; it cannot have run.

def _table_rows(hvac, keep):
    """The HVAC table with one row per key, keeping the first or last copy."""
    keys = [c for c in hvac.columns if c.startswith('Dependency=')]
    return hvac.drop_duplicates(subset=keys, keep=keep)


def test_legacy_counts_buildings_on_duplicated_keys_twice(tmp_path):
    """The defect, on the reference: more rows than buildings x bootstrap, and every extra row is
    a second copy of a building whose key is duplicated in the table."""
    info = write_truth_data(tmp_path, hvac_duplicates=True)
    out = frame(run_legacy(tmp_path))
    extra = out.height - 3 * info['estimate'].height
    assert extra > 0
    on_dup_keys = out.filter((pl.col('heating_fuel') == 'Propane') & (pl.col('size_bin') == 0)
                             & pl.col('building_type').is_in(['FullServiceRestaurant', 'RetailStandalone']))
    assert on_dup_keys.height == 2 * extra
    assert out['sqft'].sum() > 3 * info['estimate']['sqft'].sum()


@pytest.mark.parametrize('keep', ['first', 'last'])
def test_duplicated_keys_can_be_resolved_to_one_row(tmp_path, keep, caplog):
    """duplicate_table_keys='keep_first' / 'keep_last': every building is in the truth data exactly
    bootstrap times, and the result is precisely what the pandas code produces from the table with
    the other copy deleted -- the fix is the table clean-up and nothing else."""
    info = write_truth_data(tmp_path, hvac_duplicates=True)
    with caplog.at_level(logging.WARNING):
        new = run_new(tmp_path, duplicate_table_keys=f'keep_{keep}')
    assert frame(new).height == 3 * info['estimate'].height
    assert frame(new)['sqft'].sum() == pytest.approx(3 * info['estimate']['sqft'].sum(), rel=1e-12)
    assert 'duplicate' in caplog.text.lower()
    _table_rows(info['hvac'], keep).to_csv(
        os.path.join(info['path'], FILE_NAMES['hvac_system_type_name']), sep='\t', index=False)
    _same(new, run_legacy(tmp_path))


def test_first_and_last_copies_differ_only_where_the_table_does(tmp_path):
    info = write_truth_data(tmp_path, hvac_duplicates=True)
    first = frame(run_new(tmp_path, duplicate_table_keys='keep_first'))
    last = frame(run_new(tmp_path, duplicate_table_keys='keep_last'))
    assert first.height == last.height == 3 * info['estimate'].height
    differs = first.filter(first['system_type'] != last['system_type'])
    assert differs.height > 0
    # Only the retail rows were given conflicting copies; the restaurant copies are identical.
    assert set(differs['building_type']) == {'RetailStandalone'}
    assert set(differs['heating_fuel']) == {'Propane'} and set(differs['size_bin']) == {0}


def test_duplicated_keys_can_be_refused(tmp_path):
    write_truth_data(tmp_path, hvac_duplicates=True)
    with pytest.raises(ValueError, match='hvac_system_type.*duplicate'):
        run_new(tmp_path, duplicate_table_keys='error')


def test_default_reports_duplicated_keys_and_what_they_cost(tmp_path, caplog):
    info = write_truth_data(tmp_path, hvac_duplicates=True)
    with caplog.at_level(logging.WARNING):
        new = run_new(tmp_path)
    report = new.table_reports['hvac_system_type']
    assert report['duplicate_keys'] == 18 and report['conflicting_duplicate_keys'] == 9  # 9 divisions x 2 types
    assert report['repeated_rows'] == frame(new).height - 3 * info['estimate'].height > 0
    assert report['repeated_sqft'] == pytest.approx(frame(new)['sqft'].sum() - 3 * info['estimate']['sqft'].sum())
    assert 'counted more than once' in caplog.text
    assert new.table_reports['heating_fuel']['duplicate_keys'] == 0


def test_legacy_drops_buildings_missing_from_the_table_without_a_word(tmp_path, caplog):
    """The defect, on the reference: fewer rows than buildings x bootstrap and nothing logged."""
    info = write_truth_data(tmp_path, hvac_missing=True)
    with caplog.at_level(logging.WARNING):
        out = frame(run_legacy(tmp_path))
    assert out.height < 3 * info['estimate'].height
    assert caplog.text == ''
    assert out.filter((pl.col('building_type') == 'LargeHotel') & (pl.col('size_bin') == 0)
                      & (pl.col('heating_fuel') == 'DistrictHeating')).height == 0


def test_default_reports_buildings_missing_from_the_table(tmp_path, caplog):
    info = write_truth_data(tmp_path, hvac_missing=True)
    with caplog.at_level(logging.WARNING):
        new = run_new(tmp_path)
    report = new.table_reports['hvac_system_type']
    assert report['unmatched_rows'] == 3 * info['estimate'].height - frame(new).height > 0
    assert report['unmatched_sqft'] == pytest.approx(3 * info['estimate']['sqft'].sum() - frame(new)['sqft'].sum())
    assert 'LargeHotel' in caplog.text and 'DistrictHeating' in caplog.text


def test_buildings_missing_from_the_table_can_be_refused(tmp_path):
    write_truth_data(tmp_path, hvac_missing=True)
    with pytest.raises(ValueError, match='hvac_system_type.*no row'):
        run_new(tmp_path, unmatched_buildings='error')


def test_unknown_settings_are_refused(tmp_path):
    write_truth_data(tmp_path, n=200)
    with pytest.raises(ValueError, match='duplicate_table_keys'):
        run_new(tmp_path, duplicate_table_keys='keep_some')
    with pytest.raises(ValueError, match='unmatched_buildings'):
        run_new(tmp_path, unmatched_buildings='ignore')


def test_legacy_tract_inference_cannot_run(tmp_path, no_breakpoint):
    """The defect, on the reference: with the debugger stop skipped, inference still fails."""
    write_truth_data(tmp_path, missing_tracts=True)
    with pytest.raises(Exception):
        _run(LegacyApportion, tmp_path, steps=STEPS[:2])


def test_missing_tracts_are_inferred(tmp_path, caplog):
    """Buildings without a tract (null, or the 999999 placeholder) get one in their own county:
    from where buildings of their type are, else from where any buildings are, else any tract of
    the county. Buildings that had a tract are untouched and the row order is kept."""
    info = write_truth_data(tmp_path, missing_tracts=True)
    est = info['estimate']
    missing = est['tract'].is_null() | est['tract'].str.ends_with('999999')
    assert missing.sum() > 20
    with caplog.at_level(logging.WARNING):
        new = _run(ca.Apportion, tmp_path, steps=STEPS[:2])
    out = frame(new)
    assert 'tract' in caplog.text.lower()
    keep = [c for c in est.columns if c not in ('tract', 'tract_assignment_type')]
    assert_frame_equal(out.select(keep), est.select(keep))
    assert_frame_equal(out.filter(~missing), est.filter(~missing))
    got = out.filter(missing)
    assert got['tract'].null_count() == 0 and not got['tract'].str.ends_with('999999').any()
    assert got.select((pl.col('tract').str.slice(0, 8) == pl.col('county')).all()).item()

    located = est.filter(~missing)
    (c1, bt1), (c2, bt2), c3 = info['level1'], info['level2'], info['level3']
    l1 = got.filter((pl.col('county') == c1) & (pl.col('building_type') == bt1))
    assert l1.height > 0 and set(l1['tract_assignment_type']) == {'county and building type'}
    assert set(l1['tract']) <= set(located.filter((pl.col('county') == c1) & (pl.col('building_type') == bt1))['tract'])
    l2 = got.filter((pl.col('county') == c2) & (pl.col('building_type') == bt2))
    assert l2.height > 0 and set(l2['tract_assignment_type']) == {'weighted within county'}
    assert set(l2['tract']) <= set(located.filter(pl.col('county') == c2)['tract'])
    l3 = got.filter(pl.col('county') == c3)
    assert l3.height > 0 and set(l3['tract_assignment_type']) == {'random within county'}
    assert set(l3['tract']) <= set(info['tracts'][c3] + [f'{c3}000900'])
    assert len(set(l3['tract'])) > 1

    again = frame(_run(ca.Apportion, tmp_path, steps=STEPS[:2]))
    assert_frame_equal(again, out)  # seeded: the same tracts every time


def test_tract_inference_follows_the_located_buildings(tmp_path):
    """Level 2 is weighted: a tract with nine times the located buildings gets about nine times
    the unlocated ones."""
    infer_missing_tracts = _refactored('infer_missing_tracts')
    county = 'G0800100'
    a, b = county + '000100', county + '000200'
    located = pl.DataFrame({'tract': [a] * 900 + [b] * 100, 'county': county, 'building_type': 'warehouse'})
    lost = pl.DataFrame({'tract': [None] * 5000, 'county': county, 'building_type': 'hospital'},
                        schema_overrides={'tract': pl.String})
    out = infer_missing_tracts(pl.concat([located, lost]), pl.DataFrame({'county': [county] * 2, 'tract': [a, b]}))
    share = out.tail(5000)['tract'].value_counts(normalize=True).sort('tract')['proportion'].to_list()
    assert share[0] == pytest.approx(0.9, abs=0.02) and share[1] == pytest.approx(0.1, abs=0.02)


def test_a_building_that_cannot_be_given_a_tract_is_an_error(tmp_path):
    info = write_truth_data(tmp_path, missing_tracts=True)
    lone = info['lone_county']
    est = info['estimate'].with_columns(
        pl.when(pl.col('county') == lone).then(None).otherwise(pl.col('tract')).alias('tract'))
    est.write_parquet(os.path.join(info['path'], FILE_NAMES['data_file_name']))
    tract_list = pl.read_csv(os.path.join(info['path'], FILE_NAMES['tract_list_name']))
    tract_list.filter(pl.col('county') != lone).write_csv(os.path.join(info['path'], FILE_NAMES['tract_list_name']))
    with pytest.raises(RuntimeError, match=lone):
        _run(ca.Apportion, tmp_path, steps=STEPS[:2])


def test_estimate_with_every_tract_is_not_touched(tmp_path):
    info = write_truth_data(tmp_path)
    new = _run(ca.Apportion, tmp_path, steps=STEPS[:2])
    assert_frame_equal(frame(new), info['estimate'])


# ---- the real estimate (opt-in) -----------------------------------------------------

POSTPROC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REAL_TRUTH = os.path.join(POSTPROC, 'truth_data', 'v01')
REAL_CACHE = os.path.join(POSTPROC, 'output', 'Stock Estimation 2026R1', 'cached_ComStock_apportionment.parquet')


@pytest.mark.skipif(os.environ.get('COMSTOCK_APPORTIONMENT_REAL_DATA') != '1',
                    reason='set COMSTOCK_APPORTIONMENT_REAL_DATA=1 to rebuild the 2026R1 truth data')
def test_2026R1_estimate_reproduces_the_production_cache():
    """The 4.7 million building 2026R1 estimate, through the real tables, against the cache the
    pandas code wrote on 2026-11-09 (14,107,285 rows): identical with the default settings."""
    if not (os.path.exists(REAL_CACHE) and os.path.exists(os.path.join(REAL_TRUTH, '2026R1_building_estimate.parquet'))):
        pytest.skip('2026R1 truth data or its cache is not on this machine')
    obj = ca.Apportion.__new__(ca.Apportion)
    obj.truth_data_dir = REAL_TRUTH
    obj.bootstrap_coefficient = 3
    for attr, name in FILE_NAMES.items():
        setattr(obj, attr, name.replace('TEST_', '2026R1_'))
    for step in STEPS:
        getattr(obj, step)()
    cache = pl.read_parquet(REAL_CACHE)
    assert cache.height == 14_107_285, 'the cache on disk is not the one this test was written against'
    assert_frame_equal(frame(obj), cache, check_exact=True)
