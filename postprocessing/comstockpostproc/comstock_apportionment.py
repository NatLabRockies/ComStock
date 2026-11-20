# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The apportionment truth data: every building in the stock estimate, bootstrapped, with
a heating fuel and an HVAC system type drawn for it.

The file reads top to bottom in four parts:

  1. BUSINESS RULES   every modelling decision, as named data: the lookups, the seeds, what
                      to do with a faulty probability table, which buckets are sampled.
                      Changing what the truth data IS means changing something here.
  2. MECHANICS        rule-free building blocks: repeat rows, draw an option from a
                      probability table.
  3. STEPS            one pure function per step, frame in -> frame out, each applying
                      rules from part 1 with mechanics from part 2.
  4. Apportion        files, S3 and the cache; runs the steps in order. Holds no rules.

Output (Apportion.data, a polars DataFrame, cached as cached_ComStock_apportionment.parquet):
the estimate's columns, then cen_div, county_id, heating_fuel, census_region, system_type,
hvac_and_fueltype -- bootstrap_coefficient rows per building, copies adjacent.

RANDOMNESS. The draws use numpy's GLOBAL generator, seeded here (see the seeds below). That
is kept on purpose: it makes the truth data reproducible, and ComStock.create_allocated_weights
draws its models with np.random.choice from the same stream when both happen in one process.
"""

import datetime
import json
import logging
import os
from dataclasses import dataclass

import boto3
import botocore
import numpy as np
import polars as pl
import s3fs

from comstockpostproc.naming_mixin import NamingMixin
from comstockpostproc.units_mixin import UnitsMixin
from comstockpostproc.s3_utilities_mixin import S3UtilitiesMixin

logger = logging.getLogger(__name__)


# =====================================================================================
# 1. BUSINESS RULES
# =====================================================================================

BUILDING_TYPE_NAME_MAPPER = {
    'full_service_restaurant': 'FullServiceRestaurant',
    'small_office': 'SmallOffice',
    'warehouse': 'Warehouse',
    'strip_mall': 'RetailStripmall',
    'small_hotel': 'SmallHotel',
    'retail': 'RetailStandalone',
    'quick_service_restaurant': 'QuickServiceRestaurant',
    'outpatient': 'Outpatient',
    'medium_office': 'MediumOffice',
    'large_office': 'LargeOffice',
    'large_hotel': 'LargeHotel',
    'hospital': 'Hospital',
    'primary_school': 'PrimarySchool',
    'secondary_school': 'SecondarySchool',
    'grocery': 'Grocery'
}
"""snake_case building types (stock estimate, probability tables, sampling input) to the
UpperCamelCase ones the simulation results use. A type missing from here is an error."""

CEN_DIV_LKUP = {
    'G090': 'New England', 'G230': 'New England', 'G250': 'New England', 'G330': 'New England',
    'G440': 'New England', 'G500': 'New England', 'G340': 'Middle Atlantic', 'G360': 'Middle Atlantic',
    'G420': 'Middle Atlantic', 'G180': 'East North Central', 'G170': 'East North Central',
    'G260': 'East North Central', 'G390': 'East North Central', 'G550': 'East North Central',
    'G190': 'West North Central', 'G200': 'West North Central', 'G270': 'West North Central',
    'G290': 'West North Central', 'G310': 'West North Central', 'G380': 'West North Central',
    'G460': 'West North Central', 'G100': 'South Atlantic', 'G110': 'South Atlantic', 'G120': 'South Atlantic',
    'G130': 'South Atlantic', 'G240': 'South Atlantic', 'G370': 'South Atlantic', 'G450': 'South Atlantic',
    'G510': 'South Atlantic', 'G540': 'South Atlantic', 'G010': 'East South Central', 'G210': 'East South Central',
    'G280': 'East South Central', 'G470': 'East South Central', 'G050': 'West South Central',
    'G220': 'West South Central', 'G400': 'West South Central', 'G480': 'West South Central', 'G040': 'Mountain',
    'G080': 'Mountain', 'G160': 'Mountain', 'G350': 'Mountain', 'G300': 'Mountain', 'G490': 'Mountain',
    'G320': 'Mountain', 'G560': 'Mountain', 'G020': 'Pacific', 'G060': 'Pacific', 'G150': 'Pacific',
    'G410': 'Pacific', 'G530': 'Pacific'
}
"""State gisjoin code to census division. (Called 'region' elsewhere in ComStock, a mixup
from EULP days.) A state missing from here gets no division, so no HVAC system."""

CENSUS_DIVISION_ALIASES = {'Mid-Atlantic': 'Middle Atlantic'}
"""Spellings in the HVAC system type table that differ from CEN_DIV_LKUP."""

# ---- sampling regions (only for an estimate that arrives without them) ----------------
CALIFORNIA = 'G060'
CEC_CZ_TO_SAMPLING_REGION = {
    'CEC1': 100, 'CEC2': 100, 'CEC3': 101, 'CEC4': 102, 'CEC5': 102, 'CEC6': 103, 'CEC7': 103, 'CEC8': 104,
    'CEC9': 105, 'CEC10': 106, 'CEC11': 107, 'CEC12': 107, 'CEC13': 108, 'CEC14': 109, 'CEC15': 109, 'CEC16': 110
}
"""Outside California a county's sampling region comes from sampling_regions_v1.json. In
California it comes from the tract's CEC climate zone -- looked up in the 2010 tract table,
then the 2020 one -- which also replaces the building's climate zone."""

# ---- tracts (only for an estimate with buildings that have none) ----------------------
MISSING_TRACT_SUFFIX = '999999'
"""A tract that is null, or ends with this placeholder, is missing and gets inferred."""
TRACT_FROM_COUNTY_AND_BUILDING_TYPE = 'county and building type'
TRACT_WEIGHTED_WITHIN_COUNTY = 'weighted within county'
TRACT_RANDOM_WITHIN_COUNTY = 'random within county'
"""tract_assignment_type of an inferred tract, in the order the three sources are tried:
where located buildings of the same type are in the county, else where any located
buildings are, else any tract the census lists for the county. (The vocabulary is the one
the stock estimate itself uses; a building that came with its tract keeps what it had.)"""
TRACT_DRAW_SEED = 12345

# ---- heating fuel and HVAC system type ------------------------------------------------
FUEL_AND_HVAC_DRAW_SEED = 54321
"""Seeds the fuel draw; the HVAC draw continues the same stream."""

HEATING_FUEL_TABLE_KEYS = {'building_type': 'building_type', 'county': 'county_id'}
HVAC_SYSTEM_TABLE_KEYS = {'building_type': 'building_type', 'size_bin': 'size_bin',
                          'heating_fuel': 'heating_fuel', 'cen_div': 'census_region'}
"""truth-data column -> the probability table's Dependency= column it is matched on. Fuel is
drawn first, by building type and county; the system is drawn second and depends on it."""

DUPLICATE_TABLE_KEYS = 'duplicate'
"""What to do when a probability table lists a key (one combination of its Dependency=
columns) on more than one row. hvac_system_type_v4.tsv does: 52 propane keys, 43 of them
with two different sets of probabilities.

  'duplicate'   every building on such a key enters the truth data once PER TABLE ROW, each
                copy with its own system draw, so its floor area is counted more than once.
                This is what the pandas implementation did and what every cache built before
                2026-11 contains; it is the default only so that a rebuilt cache does not
                change. For 2026R1: 174,795 extra rows, +5.7% full service restaurant floor
                area, +4.2% small hotel, +1.6% standalone retail, +1.5% quick service
                restaurant, +1.2% grocery.
  'keep_first'  use the first row of each duplicated key.
  'keep_last'   use the last row (in v4 the second copies are a block appended to the file).
  'error'       refuse the table.
"""

UNMATCHED_BUILDINGS = 'drop'
"""What to do with a building whose key has no row in a probability table. For 2026R1, 35
(building type, size bin, fuel) combinations the fuel table can draw are absent from
hvac_system_type_v4.tsv -- most of them DistrictHeating in the smallest size bin.

  'drop'   the building leaves the truth data, and its floor area with it. This is what the
           pandas implementation did, silently; it is now logged. For 2026R1: 124,160 rows,
           1.35% of the stock's floor area -- 10.4% of hospital, 10.1% of grocery, 4.8% of
           large hotel, 3.3% of secondary school.
  'error'  refuse to build the truth data until the tables agree.
"""

PROBABILITY_SUM_TOLERANCE = 1e-6
"""A probability table row must sum to 1 within this, with no negative entry."""

# ---- sampling input --------------------------------------------------------------------
SAMPLING_COMBINATION = ['sampling_region', 'building_type', 'size_bin', 'heating_fuel']
SAMPLING_BUCKET = SAMPLING_COMBINATION + ['system_type']
SAMPLING_BUCKET_COVERAGE = 0.99
"""A bucket is a combination plus an HVAC system type. Sampled are: the most populous
buckets, taken in order while they cover less than this share of the truth data; and, for
every combination that leaves out entirely, its single most common system type."""
SAMPLING_BUCKETS_NOT_SAMPLED = [
    # (sampling_region, building_type, size_bin): California combinations that fail to simulate
    (103, 'hospital', 0),
    (109, 'hospital', 0),
    (110, 'large_hotel', 1),
]


# =====================================================================================
# 2. MECHANICS
# =====================================================================================

_TABLE_ROW, _SOURCE_ROW, _UNIFORM, _LOWER, _ORDER, _CUM = (
    '__table_row', '__source_row', '__uniform', '__lower', '__order', '__cumulative_share')


def seeded_global_uniforms(seed):
    """A function n -> n uniform numbers in [0, 1) from numpy's GLOBAL generator, which is
    seeded with `seed` the first time it is called and read on from there afterwards."""
    seeded = []

    def draw(n):
        if not seeded:
            np.random.seed(seed)
            seeded.append(True)
        return np.random.rand(n)
    return draw


def repeat_rows(df: pl.DataFrame, n: int) -> pl.DataFrame:
    """Every row n times, copies adjacent: row 0 n times, then row 1 n times, ..."""
    return df.select(pl.all().gather(pl.int_range(pl.len(), dtype=pl.UInt32).repeat_by(n).explode()))


@dataclass
class ProbabilityTable:
    """A ResStock-style TSV in memory: one row per key, one probability per option.

    frame holds the key columns (the file's Dependency= columns) and the option columns (its
    Option= columns, in file order), with the prefixes removed."""
    name: str
    keys: list
    options: list
    frame: pl.DataFrame

    @classmethod
    def from_tsv_frame(cls, name, raw: pl.DataFrame, recode=None):
        """From the frame as read from the file. recode: {key column: expression that rewrites it}."""
        keys = [c.replace('Dependency=', '') for c in raw.columns if 'Dependency=' in c]
        options = [c.replace('Option=', '') for c in raw.columns if 'Option=' in c]
        frame = raw.rename({c: c.replace('Dependency=', '').replace('Option=', '') for c in raw.columns})
        frame = frame.with_columns(pl.col(options).cast(pl.Float64))
        if recode:
            frame = frame.with_columns([expr.alias(col) for col, expr in recode.items()])
        return cls(name=name, keys=keys, options=options, frame=frame)

    def check_probabilities(self):
        """Raise unless every row is a probability distribution."""
        p = self.frame.select(self.options)
        if p.select(pl.sum_horizontal(pl.all().null_count())).item() or p.select(pl.min_horizontal(pl.all().min())).item() < 0:
            raise ValueError(f'{self.name} table has missing or negative probabilities.')
        off = self.frame.filter((pl.sum_horizontal(self.options) - 1).abs() > PROBABILITY_SUM_TOLERANCE)
        if off.height:
            raise ValueError(f'{self.name} table: {off.height} rows do not sum to 1, the first is '
                             f'{off.select(self.keys).row(0, named=True)}.')

    def option_intervals(self, rows: pl.DataFrame, into: str) -> pl.DataFrame:
        """The inverse CDF as a table: one row per (table row, option with probability > 0),
        with the lower edge of the option's slice of [0, 1) -- the sum of the probabilities
        of the options before it, in file order. A uniform number u belongs to the last
        option whose lower edge is <= u."""
        p = rows.select(self.options).to_numpy()
        lower = np.hstack([np.zeros((p.shape[0], 1)), np.cumsum(p, axis=1)[:, :-1]])
        row, option = np.nonzero(p > 0)
        return pl.DataFrame({
            _TABLE_ROW: rows.get_column(_TABLE_ROW).to_numpy()[row],
            _LOWER: lower[row, option],
            into: np.array(self.options, dtype=object)[option],
        }, schema={_TABLE_ROW: pl.UInt32, _LOWER: pl.Float64, into: pl.String})


def _describe(frame: pl.DataFrame, limit=10) -> str:
    """Rows of a small frame as 'a=1, b=x; a=2, b=y; ...' for a log line."""
    rows = ['(' + ', '.join(f'{k}={v}' for k, v in r.items()) + ')' for r in frame.head(limit).iter_rows(named=True)]
    return '; '.join(rows) + (f'; ... {frame.height - limit} more' if frame.height > limit else '')


def assign_from_probability_table(df: pl.DataFrame, table: ProbabilityTable, on: dict, uniforms, into: str,
                                  duplicate_keys='duplicate', unmatched='drop', weight=None):
    """Draw one option of `table` for every row of df.

    df         the rows to draw for, order kept
    on         {df column: table key column} to match a row to its probabilities
    uniforms   function n -> n uniform numbers in [0, 1); called once, with the number of
               rows drawn for, and used in row order
    into       name of the new column holding the drawn option
    duplicate_keys, unmatched
               see DUPLICATE_TABLE_KEYS and UNMATCHED_BUILDINGS
    weight     a df column (floor area) to total in the log and the report

    Returns (df with the new column, report). The report counts what the table's faults did:
    duplicate_keys, conflicting_duplicate_keys, repeated_rows, unmatched_rows and, with a
    weight, repeated_<weight> and unmatched_<weight>.
    """
    table.check_probabilities()
    report = {'rows_in': df.height, 'duplicate_keys': 0, 'conflicting_duplicate_keys': 0,
              'repeated_rows': 0, 'unmatched_rows': 0}
    if weight:
        report.update({f'repeated_{weight}': 0.0, f'unmatched_{weight}': 0.0})
        total_weight = max(float(df.get_column(weight).sum()), 1e-300)
    rows = table.frame.with_row_index(_TABLE_ROW)

    # ---- the table's own faults: a key on more than one row
    is_dup = pl.struct(table.keys).is_duplicated()
    dup = rows.filter(is_dup)
    if dup.height:
        report['duplicate_keys'] = dup.select(table.keys).unique().height
        report['conflicting_duplicate_keys'] = (
            dup.unique(subset=table.keys + table.options).group_by(table.keys).len().filter(pl.col('len') > 1).height)
        what = (f'{table.name} table: {report["duplicate_keys"]} keys are on more than one row (duplicate keys), '
                f'{report["conflicting_duplicate_keys"]} of them with different probabilities, e.g. '
                f'{_describe(dup.select(table.keys).unique(maintain_order=True), 3)}')
        if duplicate_keys == 'error':
            raise ValueError(what + '.')
        if duplicate_keys in ('keep_first', 'keep_last'):
            rows = rows.unique(subset=table.keys, keep=duplicate_keys[5:], maintain_order=True)
            logger.warning(f'{what}. Using the {duplicate_keys[5:]} row of each [duplicate_table_keys={duplicate_keys!r}].')

    # ---- match every row of df to its table row(s)
    left, right = list(on), [f'__key_{i}' for i in range(len(on))]
    lookup = rows.select([pl.col(t).cast(df.schema[d]).alias(r) for (d, t), r in zip(on.items(), right)]
                         + [pl.col(_TABLE_ROW)])
    matched = df.with_row_index(_SOURCE_ROW).join(lookup, left_on=left, right_on=right, how='left',
                                                  maintain_order='left')
    if dup.height and duplicate_keys == 'duplicate':
        matched = matched.sort(_SOURCE_ROW, _TABLE_ROW)  # a row's copies adjacent, in table order
        again = matched.filter(pl.col(_SOURCE_ROW).is_first_distinct().not_())
        report['repeated_rows'] = again.height
        cost = ''
        if weight:
            report[f'repeated_{weight}'] = float(again.get_column(weight).sum())
            cost = f' ({report[f"repeated_{weight}"] / total_weight:.2%} of {weight})'
        logger.warning(f'{what}. Every building on such a key is in the truth data once per table row, so '
                       f'{again.height:,} rows{cost} are counted more than once '
                       f"[duplicate_table_keys='duplicate'; see DUPLICATE_TABLE_KEYS].")

    # ---- rows the table has no probabilities for
    lost = matched.filter(pl.col(_TABLE_ROW).is_null())
    if lost.height:
        report['unmatched_rows'] = lost.height
        share = f'pct_of_{weight}' if weight else 'rows'
        by_key = lost.group_by(left).agg(
            [pl.len().alias('rows')] + ([(pl.col(weight).sum() / total_weight * 100).round(3).alias(share)] if weight else []))
        by_key = by_key.sort([share] + left, descending=[True] + [False] * len(left))
        cost = ''
        if weight:
            report[f'unmatched_{weight}'] = float(lost.get_column(weight).sum())
            cost = f' ({report[f"unmatched_{weight}"] / total_weight:.2%} of {weight})'
        what = (f'{table.name} table has no row for {lost.height:,} of {df.height:,} rows{cost}, in '
                f'{by_key.height} key combinations, largest first: {_describe(by_key)}')
        if unmatched == 'error':
            raise ValueError(what + '.')
        logger.warning(f"{what}. They are DROPPED from the truth data [unmatched_buildings='drop'; "
                       'see UNMATCHED_BUILDINGS].')
        matched = matched.filter(pl.col(_TABLE_ROW).is_not_null())

    # ---- the draw: one uniform number per row, placed on its table row's inverse CDF
    intervals = table.option_intervals(rows, into).sort(_LOWER)
    drawn = (
        matched.select(_TABLE_ROW)
        .with_columns(pl.Series(_UNIFORM, uniforms(matched.height), dtype=pl.Float64))
        .with_row_index(_ORDER)
        .sort(_UNIFORM)
        .join_asof(intervals, left_on=_UNIFORM, right_on=_LOWER, by=_TABLE_ROW, strategy='backward',
                   check_sortedness=False)
        .sort(_ORDER)
    )
    if drawn.get_column(into).null_count():
        raise RuntimeError(f'{table.name} table: no option could be drawn for some rows.')
    report['rows_out'] = matched.height
    return matched.with_columns(drawn.get_column(into)).drop(_SOURCE_ROW, _TABLE_ROW), report


# =====================================================================================
# 3. STEPS
# =====================================================================================

def _tract_shares(buildings: pl.DataFrame, by: list) -> pl.DataFrame:
    """Within each `by` group, the cumulative share of rows in each tract (tracts in order)."""
    return (
        buildings.group_by(by + ['tract']).len().sort(by + ['tract'])
        .with_columns((pl.col('len').cum_sum().over(by) / pl.col('len').sum().over(by)).alias(_CUM))
        .select(by + ['tract', _CUM])
    )


def infer_missing_tracts(df: pl.DataFrame, tract_list: pl.DataFrame, uniforms=None) -> pl.DataFrame:
    """Give every building without a tract one in its own county; see the TRACT_ rules.

    tract_list: every census tract, columns county and tract. Buildings that have a tract and
    the row order are left as they are; an inferred tract is recorded in tract_assignment_type.
    """
    missing = pl.col('tract').is_null() | pl.col('tract').str.ends_with(MISSING_TRACT_SUFFIX)
    n_missing = df.select(missing.sum()).item()
    if n_missing == 0:
        return df
    logger.warning(f'{n_missing:,} of {df.height:,} buildings in the stock estimate have no tract; inferring one.')
    if 'tract_assignment_type' not in df.columns:
        df = df.with_columns(pl.lit(None, dtype=pl.String).alias('tract_assignment_type'))
    columns = df.columns
    df = df.with_row_index(_ORDER)
    located = df.filter(~missing)
    uniforms = uniforms or seeded_global_uniforms(TRACT_DRAW_SEED)
    lost = df.filter(missing).with_columns(pl.Series(_UNIFORM, uniforms(n_missing), dtype=pl.Float64)).sort(_UNIFORM)

    sources = [
        (TRACT_FROM_COUNTY_AND_BUILDING_TYPE, ['building_type', 'county'], located),
        (TRACT_WEIGHTED_WITHIN_COUNTY, ['county'], located),
        (TRACT_RANDOM_WITHIN_COUNTY, ['county'], tract_list.select('county', 'tract').unique()),
    ]
    candidates = []
    for i, (label, by, source) in enumerate(sources):
        shares = _tract_shares(source, by).rename({'tract': f'__tract_{i}'}).sort(_CUM)
        # the first tract whose cumulative share reaches the building's uniform number
        lost = lost.join_asof(shares, left_on=_UNIFORM, right_on=_CUM, by=by, strategy='forward',
                              check_sortedness=False).drop(_CUM)
        candidates.append((label, f'__tract_{i}'))
    label_of = pl.when(False).then(None)
    for label, col in candidates:
        label_of = label_of.when(pl.col(col).is_not_null()).then(pl.lit(label))
    lost = lost.with_columns(
        pl.coalesce([col for _, col in candidates]).alias('tract'),
        label_of.alias('tract_assignment_type'),
    )
    stuck = lost.filter(pl.col('tract').is_null())
    if stuck.height:
        raise RuntimeError(f'{stuck.height:,} buildings have no tract and none could be inferred: their counties '
                           f'are not in the tract list: {sorted(stuck.get_column("county").unique().to_list())}')
    for label, _ in candidates:
        n = lost.filter(pl.col('tract_assignment_type') == label).height
        logger.info(f'  {n:,} tracts inferred as: {label}')
    return pl.concat([located, lost.select(located.columns)]).sort(_ORDER).select(columns)


def assign_sampling_regions(df: pl.DataFrame, county_regions: dict, cec_cz_2010: dict, cec_cz_2020: dict):
    """Add sampling_region to an estimate that lacks it; see CEC_CZ_TO_SAMPLING_REGION."""
    if 'sampling_region' in df.columns:
        return df
    logger.info('Assigning sampling region ids to truth data')
    in_ca = pl.col('state') == CALIFORNIA
    if 'cz' not in df.columns:
        df = df.with_columns(pl.lit(None, dtype=pl.String).alias('cz'))
    cec_cz = {**cec_cz_2020, **cec_cz_2010}  # the 2010 tract table wins where both know the tract
    df = df.with_columns(
        pl.when(in_ca).then(pl.col('tract').replace_strict(cec_cz, default=None, return_dtype=pl.String))
        .otherwise(pl.col('cz')).alias('cz'))
    unmapped = df.filter(in_ca & pl.col('cz').is_null()).get_column('tract').unique().sort().to_list()
    if unmapped:
        raise RuntimeError('Unable to determine all CEC Climate Zones for California tracts. '
                           f'Not in the 2010 or 2020 lookup: {unmapped}')
    df = df.with_columns(
        pl.when(in_ca).then(pl.col('cz').replace_strict(CEC_CZ_TO_SAMPLING_REGION, default=None, return_dtype=pl.Int64))
        .otherwise(pl.col('county').replace_strict(county_regions, default=None, return_dtype=pl.Int64))
        .alias('sampling_region'))
    unmapped = df.filter(pl.col('sampling_region').is_null()).get_column('county').unique().sort().to_list()
    if unmapped:
        raise RuntimeError(f'Sampling region calculation resulted in counties with missing regions: {unmapped}')
    return df


def _recode_building_type():
    """The building_type column from snake_case to UpperCamelCase, for the estimate and for the
    probability tables alike. A type BUILDING_TYPE_NAME_MAPPER does not have becomes null."""
    return pl.col('building_type').replace_strict(BUILDING_TYPE_NAME_MAPPER, default=None, return_dtype=pl.String)


def _unknown_building_types(before: pl.Series, after: pl.Series) -> list:
    """The building types that _recode_building_type could not name."""
    return before.filter(after.is_null()).unique().sort().to_list()


def normalize_building_types(df: pl.DataFrame) -> pl.DataFrame:
    """building_type from snake_case to UpperCamelCase; an unknown type is an error."""
    out = df.with_columns(_recode_building_type())
    unknown = _unknown_building_types(df.get_column('building_type'), out.get_column('building_type'))
    if unknown:
        logger.error(f'Building type values from the building estimate not expected by the building type mapper: {unknown}')
        raise RuntimeError(f'Unable to process the specified building type enumerations: {unknown}')
    return out


def _table_by_building_type(name, raw: pl.DataFrame, recode=None) -> ProbabilityTable:
    """A probability table keyed on building type, its building types named as the estimate's are.
    An unknown type is an error here too: a row that can match no building is a fault in the file
    (or a type missing from BUILDING_TYPE_NAME_MAPPER), not something to skip without a word."""
    table = ProbabilityTable.from_tsv_frame(name, raw, recode={'building_type': _recode_building_type(), **(recode or {})})
    unknown = _unknown_building_types(raw.get_column('Dependency=building_type'), table.frame.get_column('building_type'))
    if unknown:
        raise ValueError(f'{name} table has building type values that BUILDING_TYPE_NAME_MAPPER does not: {unknown}')
    return table


def heating_fuel_table(raw: pl.DataFrame) -> ProbabilityTable:
    """heating_fuel_v*.tsv: fuel by building type and county."""
    return _table_by_building_type('heating_fuel', raw)


def hvac_system_table(raw: pl.DataFrame) -> ProbabilityTable:
    """hvac_system_type_v*.tsv: system by building type, size bin, heating fuel and census division."""
    return _table_by_building_type('hvac_system_type', raw, recode={
        'census_region': pl.col('census_region').replace(CENSUS_DIVISION_ALIASES),
    })


def bootstrap_with_fuel_and_hvac(df: pl.DataFrame, fuel: ProbabilityTable, hvac: ProbabilityTable,
                                 bootstrap_coefficient: int, duplicate_table_keys=DUPLICATE_TABLE_KEYS,
                                 unmatched_buildings=UNMATCHED_BUILDINGS, uniforms=None):
    """Repeat every building bootstrap_coefficient times and draw a heating fuel, then an HVAC
    system type, for each copy. Returns (frame, {table name: report})."""
    uniforms = uniforms or seeded_global_uniforms(FUEL_AND_HVAC_DRAW_SEED)
    settings = dict(duplicate_keys=duplicate_table_keys, unmatched=unmatched_buildings, weight='sqft')
    reports = {}

    df = repeat_rows(df, bootstrap_coefficient)
    df = df.with_columns(pl.col('state').replace_strict(CEN_DIV_LKUP, default=None, return_dtype=pl.String).alias('cen_div'))

    # county_id and census_region repeat county and cen_div under the tables' names. Nothing
    # reads them; they are in the cache because the pandas merge left them there.
    logger.info('Sampling fuel type onto truth data')
    df = df.with_columns(pl.col('county').alias('county_id'))
    df, reports[fuel.name] = assign_from_probability_table(
        df, fuel, on=HEATING_FUEL_TABLE_KEYS, uniforms=uniforms, into='heating_fuel', **settings)

    logger.info('Sampling HVAC system type onto truth data')
    df = df.with_columns(pl.col('cen_div').alias('census_region'))
    df, reports[hvac.name] = assign_from_probability_table(
        df, hvac, on=HVAC_SYSTEM_TABLE_KEYS, uniforms=uniforms, into='system_type', **settings)

    df = df.with_columns(pl.concat_str(['system_type', 'heating_fuel'], separator='_').alias('hvac_and_fueltype'))

    # Nothing but tract_assignment_type may be empty
    nulls = df.drop('tract_assignment_type', strict=False).null_count().row(0, named=True)
    nulls = {c: n for c, n in nulls.items() if n}
    if nulls:
        raise RuntimeError(f'Unexpected missing values in the truth data, rows per column: {nulls}')
    return df, reports


def apportionment_groups(data: pl.DataFrame, id_col: str) -> pl.DataFrame:
    """Number the groups a ComStock model must share with a truth-data building to stand for
    it: (sampling region, building type, size bin, HVAC system and fuel), ids in sorted order."""
    attrs = ['sampling_region', 'building_type', 'size_bin', 'hvac_and_fueltype']
    return data.select(attrs).unique().sort(attrs).with_row_index(id_col).with_columns(pl.col(id_col).cast(pl.Int64))


def select_sampling_buckets(data: pl.DataFrame) -> pl.DataFrame:
    """The buckets to draw the ComStock sample from; see the SAMPLING_ rules. One row per
    bucket, building types in snake_case. Of two buckets the same size, the one that appears
    first in the truth data comes first (as pandas value_counts orders them), so the same
    truth data always gives the same buckets in the same order."""
    counts = (
        data.select(SAMPLING_BUCKET).with_row_index(_ORDER)
        .group_by(SAMPLING_BUCKET).agg(pl.len(), pl.col(_ORDER).min())
        .sort(['len', _ORDER], descending=[True, False])
    )
    covered = counts.filter(pl.col('len').cum_sum() < data.height * SAMPLING_BUCKET_COVERAGE)
    left_out = counts.join(covered.select(SAMPLING_COMBINATION).unique(), on=SAMPLING_COMBINATION, how='anti')
    most_common = left_out.group_by(SAMPLING_COMBINATION, maintain_order=True).first().sort(SAMPLING_COMBINATION)
    logger.info(f'Sampling {covered.height} buckets covering {SAMPLING_BUCKET_COVERAGE:.0%} of the truth data, '
                f'plus {most_common.height} for combinations they leave out')
    buckets = pl.concat([covered.select(SAMPLING_BUCKET), most_common.select(SAMPLING_BUCKET)])

    to_snake_case = {v: k for k, v in BUILDING_TYPE_NAME_MAPPER.items()}
    buckets = buckets.with_columns(pl.col('building_type').replace_strict(to_snake_case, return_dtype=pl.String))
    if buckets.is_duplicated().any():
        raise RuntimeError('Duplicates in bucket specification. Please debug.')
    not_sampled = pl.DataFrame(SAMPLING_BUCKETS_NOT_SAMPLED, orient='row',
                               schema={'sampling_region': buckets.schema['sampling_region'],
                                       'building_type': pl.String, 'size_bin': buckets.schema['size_bin']})
    return buckets.join(not_sampled, on=not_sampled.columns, how='anti', maintain_order='left')


def sampling_input_file_name(now: datetime.datetime, rows: int) -> str:
    return f'sample_input_{now.strftime("%Y%m%d-%H%M")}_{rows}.csv'


# =====================================================================================
# 4. Apportion: files, S3, cache
# =====================================================================================

def _one_of(setting, value, allowed):
    if value not in allowed:
        raise ValueError(f'{setting} must be one of {allowed}, not {value!r}')
    return value


class Apportion(NamingMixin, UnitsMixin, S3UtilitiesMixin):

    BUILDING_TYPE_NAME_MAPPER = BUILDING_TYPE_NAME_MAPPER
    CEN_DIV_LKUP = CEN_DIV_LKUP
    duplicate_table_keys = DUPLICATE_TABLE_KEYS
    unmatched_buildings = UNMATCHED_BUILDINGS

    def __init__(self, stock_estimation_version, truth_data_version, bootstrap_coefficient=3, reload_from_cache=False,
                 output_dir=None, aws_profile_name=None, duplicate_table_keys=None, unmatched_buildings=None):
        """
        A class to apportion the sampled data to the known set of buildings in the U.S.
        Args:

            stock_estimation_version (str): The stock estimation dataset to use for apportionment. This
            is produced through the StockE process and underlies the distributions represented in the TSVs.
            truth_data_version (str): The version/location to retrieve truth/starting data. Truth data
            may change for certain data sources over time, although unlikely for CBECS.
            bootstrap_coefficient (int): The number of samples to bootstrap for each building in the stock truth dataset estimate. This should never be less than three, however the virtues of larger numbers is not yet well understood and may never be unless we have reason to spend a fair bit of effort on this.
            reload_from_cache (bool): Read cached_ComStock_apportionment.parquet instead of building it. The
            cache is whatever the settings in force when it was written made it.
            duplicate_table_keys, unmatched_buildings (str): What to do about a faulty probability table;
            see DUPLICATE_TABLE_KEYS and UNMATCHED_BUILDINGS in this module. Default: those values.

        self.data is a polars DataFrame.
        """

        # Initialize members
        logger.info('Initializing Apportion class')
        self.stock_estimation_version = stock_estimation_version
        self.truth_data_version = truth_data_version
        self.bootstrap_coefficient = bootstrap_coefficient
        if duplicate_table_keys is not None:
            self.duplicate_table_keys = duplicate_table_keys
        if unmatched_buildings is not None:
            self.unmatched_buildings = unmatched_buildings
        self._check_settings()
        current_dir = os.path.dirname(os.path.abspath(__file__))
        self.dataset_name = f'Stock Estimation {self.stock_estimation_version}'
        self.truth_data_dir = os.path.join(current_dir, '..', 'truth_data', self.truth_data_version)
        self.resource_dir = os.path.join(current_dir, 'resources')
        self.output_dir = self.setup_fsspec_filesystem(output_dir, aws_profile_name)
        self.data_file_name = f'{self.stock_estimation_version}_building_estimate.parquet'
        self.hvac_size_bins_name = 'hvac_system_size_bin_v1.tsv'
        self.tract_list_name = f'{self.stock_estimation_version}_tract_list.csv'
        self.sampling_regions_name = 'sampling_regions_v1.json'
        self.ca_cz_tract_2010_name = 'cec_cz_by_tract_2010_lkup.json'
        self.ca_cz_tract_2020_name = 'cec_cz_by_tract_2020_lkup.json'
        self.hvac_system_type_name = 'hvac_system_type_v4.tsv'
        self.space_heating_fuel_type_name = 'heating_fuel_v2.tsv'
        self.s3_client = boto3.client('s3', config=botocore.client.Config(max_pool_connections=50))
        logger.info(f'Creating {self.dataset_name}')

        # Make directories
        for p in [self.truth_data_dir]:
            if not os.path.exists(p):
                os.makedirs(p)

        if not isinstance(self.output_dir['fs'], s3fs.S3FileSystem):
            if not os.path.exists(self.output_dir['fs_path']):
                os.makedirs(self.output_dir['fs_path'])

        # Load and transform truth data
        file_path = f'{self.output_dir["fs_path"]}/cached_ComStock_apportionment.parquet'
        if isinstance(self.output_dir['fs'], s3fs.S3FileSystem):
            file_path = f's3://{file_path}'
        if reload_from_cache:
            if not self.output_dir['fs'].exists(file_path):
                raise FileNotFoundError(
                f'Cannot find wide .csv or .parquet in {file_path} to reload data, set reload_from_cache=False.')
            logger.info(f'Reloading apportionment data from: {file_path}')
            with self.output_dir['fs'].open(file_path, 'rb') as f:
                self.data = pl.read_parquet(f)
        else:
            self.download_data()
            self.load_data()
            self.infer_tracts()
            self.add_sampling_regions()
            self.add_sqft_bins()
            self.normalize_building_type_values()
            self.upsample_hvac_system_fuel_types()
            logger.info(f'Caching apportionment data to: {file_path}')
            with self.output_dir['fs'].open(file_path, "wb") as f:
                self.data.write_parquet(f)

        logger.info('Finished processing Apportion class truth data')
        logger.debug('\nDesired Truth Data columns after adding all data')
        for c in self.data.columns:
            logger.debug(c)

    def _check_settings(self):
        _one_of('duplicate_table_keys', self.duplicate_table_keys, ('duplicate', 'keep_first', 'keep_last', 'error'))
        _one_of('unmatched_buildings', self.unmatched_buildings, ('drop', 'error'))

    # ---- files -------------------------------------------------------------------------

    def download_data(self):
        """Download all data files associated with and needed for segment apportionment."""

        logger.info('Downloading data required for Apportionment class')
        for file_name in [
            self.data_file_name,                # Expected buildings estimate from the StockE analysis
            self.hvac_size_bins_name,           # HVAC system size cutoff bins that define the estimate's size bins
            self.tract_list_name,               # All allowable tracts within a given county, many tracts per county
            self.sampling_regions_name,         # All non-CA counties to sampling regions
            self.ca_cz_tract_2010_name,         # All 2010 CA census tracts to CEC climate zones
            self.ca_cz_tract_2020_name,         # All 2020 CA census tracts to CEC climate zones
            self.hvac_system_type_name,         # P(hvac system type | heating fuel, census division, building type, size bin)
            self.space_heating_fuel_type_name,  # P(heating fuel | county, building type)
        ]:
            if not os.path.exists(os.path.join(self.truth_data_dir, file_name)):
                self.download_truth_data_file(f'truth_data/{self.truth_data_version}/StockE/{file_name}')

    def _truth_path(self, file_name):
        return os.path.join(self.truth_data_dir, file_name)

    def _read_json(self, file_name):
        with open(self._truth_path(file_name), 'r') as rfobj:
            return json.load(rfobj)

    def load_data(self):
        """Load all downloaded and / or cached data into memory for use by the segment apportionment methods."""

        logger.info('Loading data required for Apportionment class')

        # Building stock estimate from StockE: one row per building
        self.data = pl.read_parquet(self._truth_path(self.data_file_name))

        # Size bin cutoffs (not used yet, see add_sqft_bins)
        self.hvac_size_bin_df = pl.read_csv(self._truth_path(self.hvac_size_bins_name), separator='\t',
                                            infer_schema_length=None)

        # Tract list for tract inference
        self.tract_list = pl.read_csv(self._truth_path(self.tract_list_name), infer_schema_length=None)

        # Non-CA county to sampling region, and CA tract to CEC climate zone (2010 and 2020 tracts)
        self.sampling_region_lkup = self._read_json(self.sampling_regions_name)
        self.ca_cz_2010_lkup = self._read_json(self.ca_cz_tract_2010_name)
        self.ca_cz_2020_lkup = self._read_json(self.ca_cz_tract_2020_name)

        # Probabilities of hvac system type and of space heating fuel type, as in the files
        self.hvac_system_type_prob = pl.read_csv(self._truth_path(self.hvac_system_type_name), separator='\t',
                                                 infer_schema_length=None)
        self.heating_fuel_type_prob = pl.read_csv(self._truth_path(self.space_heating_fuel_type_name), separator='\t',
                                                  infer_schema_length=None)

    # ---- steps, in the order __init__ runs them -----------------------------------------

    def infer_tracts(self):
        """Give every building in self.data that has no tract one in its own county.

        Stock estimates since 2024R2 arrive with every tract set, so this normally does nothing.
        See infer_missing_tracts and the TRACT_ rules."""
        self.data = infer_missing_tracts(self.data, self.tract_list)

    def add_sampling_regions(self):
        """Add the sampling_region column if the estimate does not have it. See assign_sampling_regions."""
        self.data = assign_sampling_regions(self.data, self.sampling_region_lkup, self.ca_cz_2010_lkup,
                                            self.ca_cz_2020_lkup)

    def add_sqft_bins(self):
        """Check if size bins have been added to the file - if not error."""
        # TODO implement this using the self.hvac_size_bins_name
        if 'size_bin' in self.data.columns:
            return

        raise NotImplementedError('This does not yet exist - if it is needed someone needs to write this...')

    def normalize_building_type_values(self):
        """Change the building type names from snake_case to UpperCamelCase."""
        self.data = normalize_building_types(self.data)

    def upsample_hvac_system_fuel_types(self):
        """Bootstrap the estimate and draw a heating fuel and an HVAC system type for every copy.

        Adds cen_div, county_id, heating_fuel, census_region, system_type and hvac_and_fueltype.
        What the probability tables' faults did is logged and kept in self.table_reports.
        See bootstrap_with_fuel_and_hvac."""
        logger.info('Upsampling truth data with fuel type and HVAC system type')
        self._check_settings()
        self.data, self.table_reports = bootstrap_with_fuel_and_hvac(
            self.data,
            fuel=heating_fuel_table(self.heating_fuel_type_prob),
            hvac=hvac_system_table(self.hvac_system_type_prob),
            bootstrap_coefficient=self.bootstrap_coefficient,
            duplicate_table_keys=self.duplicate_table_keys,
            unmatched_buildings=self.unmatched_buildings,
        )

    # ---- sampling input -----------------------------------------------------------------

    def generate_sampling_input(self, n_samples=[1, 12], output_dir=None):
        """Write the sampling input csv(s) for the ComStock sampler from the truth data.

        One file per entry of n_samples, with that many rows per bucket; see
        select_sampling_buckets for which buckets. Written to output_dir, by default the
        repository's sampling folder. Returns the paths.
        """

        logger.info('Using the apportioned dataset to generate an input for sampling')
        buckets = select_sampling_buckets(self.data).rename({'system_type': 'hvac_system_type'})
        if output_dir is None:
            output_dir = os.path.join(os.path.abspath(os.path.dirname(__file__)), '..', '..', 'sampling')
        now = datetime.datetime.now()
        paths = []
        for n_sample in n_samples:
            to_write = repeat_rows(buckets, n_sample).with_row_index('Building')
            path = os.path.join(output_dir, sampling_input_file_name(now, to_write.height))
            to_write.write_csv(path)
            logger.info(f'Wrote {to_write.height:,} rows ({buckets.height:,} buckets x {n_sample}) to {path}')
            paths.append(path)
        return paths
