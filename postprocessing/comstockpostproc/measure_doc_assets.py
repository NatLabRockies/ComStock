# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""
Measure documentation assets: the numbers and figures a measure document cites.

Opt in with ``ComStockMeasureComparison(..., export_measure_doc_assets=True)``, or, for a run
that has already been postprocessed, run

    python -m comstockpostproc.measure_doc_assets "postprocessing/output/ComStock <run>" --upgrade 2

Either way each upgrade gets ``measure_runs/upNN_<name>/doc_assets/``:

    manifest.json                     what was made, from which data, by which code
    tables/annual_totals.csv          stock and applicable-only totals, baseline vs upgrade
    tables/applicability.csv          models, buildings and floor area the measure applies to
    tables/savings_by_group.csv       annual_totals by building type, census division, climate
                                      zone, HVAC system type and vintage
    tables/savings_distributions.csv  the statistics behind the savings-distribution figures
    figures/<name>.png                the standard comparison figures, sized for a document

Everything is computed from the weighted plotting data the comparison figures are drawn from,
so a table and the figure beside it cannot disagree. Values are unrounded: rounding and layout
belong to the document, not the pipeline.

Contract, schema "comstock-measure-doc-assets/1". The measure documentation tooling reads these
names; change them only together with the schema version.

annual_totals.csv, savings_by_group.csv
    [group_by, group,] population, quantity, fuel, end_use, variant, units, baseline, upgrade,
    savings, percent_savings, column, derived

    population       "stock" (every row) or "applicable" (every row, baseline included, of the
                     buildings whose upgrade row has applicability = true, so that baseline vs
                     upgrade compares the same buildings)
    quantity         site_energy | utility_bill | ghg_emissions | floor_area | building_count
    fuel, end_use    tokens from the column name (site_energy/total is all fuels together)
    variant          electricity rate for bills (mean, min, max, state_average), grid scenario
                     for electricity emissions; blank otherwise
    savings          baseline - upgrade, so a saving is positive
    percent_savings  savings / baseline * 100; blank when the baseline is 0
    column           the plotting-data column summed
    derived          blank, or how a total missing from the plotting data was rebuilt. Plotting
                     caches carry every fuel's total and the total bill; one written before
                     they did does not, and for it a fuel total is the sum of its end uses and
                     the total bill the mean electricity bill plus the other fuels' bills

    savings_by_group.csv leaves out rows whose baseline and upgrade are both 0.

applicability.csv
    metric, value, units, definition

savings_distributions.csv
    figure, category, label, column, units, n, mean, q1, median, q3, iqr, lower_fence,
    upper_fence, n_below_fence, n_above_fence, min, max, filter

    One row per box in a savings-distribution figure: unweighted, upgrade rows only, with the
    filters the figure applies (stated in `filter`). Quartiles are linearly interpolated;
    fences are 1.5 x IQR beyond the quartiles. `n` is the figure's n.

manifest.json
    schema, generated, generator {package, version, module, git {commit, branch, dirty}},
    run {...}, upgrade {id, name, baseline_id, measure_dir}, inputs [{path, bytes, sha256}],
    data {...}, checks [{name, ok, detail}], files [{path, kind, bytes, sha256, description,
    ...}], notes [...]

    Figure entries add section, source, original_name, width_px, height_px, dpi, width_in and
    height_in. Figures are PNG, 6.5 in wide (at most 7.5 in tall) at 300 dpi, with the dpi
    recorded in the file so a document inserts them at that size.
"""
import argparse
import csv
import datetime as dt
import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import polars as pl

from comstockpostproc.__version__ import __version__
from comstockpostproc.lazyframeplotter import LazyFramePlotter
from comstockpostproc.naming_mixin import NamingMixin
from comstockpostproc.plotting_mixin import PlottingMixin
from comstockpostproc.units_mixin import UnitsMixin

logger = logging.getLogger(__name__)

SCHEMA = 'comstock-measure-doc-assets/1'
DOC_ASSETS_DIR = 'doc_assets'
POPULATIONS = ('stock', 'applicable')

UPGRADE_ID = NamingMixin.UPGRADE_ID
UPGRADE_NAME = NamingMixin.UPGRADE_NAME
BLDG_ID = NamingMixin.BLDG_ID
WEIGHT = NamingMixin.BLDG_WEIGHT
APPLICABILITY = 'applicability'
FLOOR_AREA = 'calc.weighted.sqft..ft2'
GROUP_COLUMNS = (NamingMixin.BLDG_TYPE, NamingMixin.CEN_DIV, NamingMixin.CZ_ASHRAE,
                 NamingMixin.HVAC_SYS, NamingMixin.VINTAGE)

TOTALS_FIELDS = ['population', 'quantity', 'fuel', 'end_use', 'variant', 'units', 'baseline',
                 'upgrade', 'savings', 'percent_savings', 'column', 'derived']
GROUP_FIELDS = ['group_by', 'group'] + TOTALS_FIELDS
APPLICABILITY_FIELDS = ['metric', 'value', 'units', 'definition']
DISTRIBUTION_FIELDS = ['figure', 'category', 'label', 'column', 'units', 'n', 'mean', 'q1',
                       'median', 'q3', 'iqr', 'lower_fence', 'upper_fence', 'n_below_fence',
                       'n_above_fence', 'min', 'max', 'filter']

_ENERGY_RE = re.compile(r'^calc\.weighted\.(?P<fuel>[a-z_]+)\.(?P<end_use>[a-z_]+)\.energy_consumption\.\.(?P<units>\w+)$')
_BILL_RE = re.compile(r'^calc\.weighted\.utility_bills\.(?P<fuel>[a-z_]+?)_bill_(?P<variant>[a-z_]+)\.\.(?P<units>\w+)$')
_GHG_RE = re.compile(r'^calc\.weighted\.emissions\.(?P<fuel>[a-z_]+)(?:\.(?P<variant>\w+))?\.\.(?P<units>\w+)$')

_FUEL_ORDER = ['site_energy', 'electricity', 'natural_gas', 'fuel_oil', 'propane',
               'district_heating', 'district_cooling']
_ROLLUPS = ['total', 'net', 'purchased']
_NOT_END_USES = set(_ROLLUPS) | {'pv'}  # pv is generation, which the totals leave out
_BILL_PARTS = ('electricity_bill_mean', 'natural_gas_bill_state_average',
               'fuel_oil_bill_state_average', 'propane_bill_state_average')

# The standard comparison figures a measure document uses, in document order:
# (name in doc_assets/figures, plot method, file the method writes, section, description)
FIGURES = (
    ('ann_energy_by_enduse_and_fuel_stock', 'plot_energy_by_enduse_and_fuel_type',
     'ann_energy_by_enduse_and_fuel_stock.png', '5.2',
     'Annual site energy by end use and fuel, baseline vs upgrade, whole stock'),
    ('ann_energy_by_enduse_and_fuel_applicable_only', 'plot_energy_by_enduse_and_fuel_type',
     'ann_energy_by_enduse_and_fuel_applicable_only.png', '5.2',
     'Annual site energy by end use and fuel, baseline vs upgrade, applicable buildings only'),
    ('annual_utility_bills_by_fuel', 'plot_utility_bills_by_fuel_type',
     'Annual Utility Bills by Fuel.png', '5.3',
     'Annual utility bills by fuel, baseline vs upgrade, for three electricity rates'),
    ('percent_site_energy_savings_by_end_use', 'plot_measure_savings_distributions_enduse_and_fuel',
     'savings_distributions/percent_site_energy_savings_by_end_use.png', '5.4',
     'Distribution of percent site energy savings by end use and fuel'),
    ('percent_site_energy_savings_by_fuel', 'plot_measure_savings_distributions_enduse_and_fuel',
     'savings_distributions/percent_site_energy_savings_by_fuel.png', '5.4',
     'Distribution of percent site energy savings by fuel'),
    ('percent_site_energy_savings_by_building_type', 'plot_measure_savings_distributions_by_building_type',
     'savings_distributions/percent_site_energy_savings_by_building_type.png', '5.4',
     'Distribution of percent site energy savings by building type'),
    ('percent_site_energy_savings_by_climate_zone', 'plot_measure_savings_distributions_by_climate_zone',
     'savings_distributions/percent_site_energy_savings_by_climate_zone.png', '5.4',
     'Distribution of percent site energy savings by ASHRAE climate zone'),
    ('percent_site_energy_savings_by_hvac_system', 'plot_measure_savings_distributions_by_hvac_system_type',
     'savings_distributions/percent_site_energy_savings_by_hvac_system.png', '5.4',
     'Distribution of percent site energy savings by HVAC system type'),
    ('site_eui_savings_by_end_use', 'plot_measure_savings_distributions_enduse_and_fuel',
     'savings_distributions/site_eui_savings_by_end_use.png', '5.4',
     'Distribution of site EUI savings by end use and fuel'),
    ('site_eui_savings_by_fuel', 'plot_measure_savings_distributions_enduse_and_fuel',
     'savings_distributions/site_eui_savings_by_fuel.png', '5.4',
     'Distribution of site EUI savings by fuel'),
    ('site_eui_savings_by_building_type', 'plot_measure_savings_distributions_by_building_type',
     'savings_distributions/site_eui_savings_by_building_type.png', '5.4',
     'Distribution of site EUI savings by building type'),
    ('site_eui_savings_by_climate_zone', 'plot_measure_savings_distributions_by_climate_zone',
     'savings_distributions/site_eui_savings_by_climate_zone.png', '5.4',
     'Distribution of site EUI savings by ASHRAE climate zone'),
    ('site_eui_savings_by_hvac_system', 'plot_measure_savings_distributions_by_hvac_system_type',
     'savings_distributions/site_eui_savings_by_hvac_system.png', '5.4',
     'Distribution of site EUI savings by HVAC system type'),
    ('natural_gas_by_census_division_name', 'plot_floor_area_and_energy_totals',
     'natural_gas_by_census_division_name.png', 'A',
     'Annual natural gas consumption, baseline vs upgrade, by census division'),
    ('natural_gas_by_comstock_building_type', 'plot_floor_area_and_energy_totals',
     'natural_gas_by_comstock_building_type.png', 'A',
     'Annual natural gas consumption, baseline vs upgrade, by building type'),
    ('electricity_by_comstock_building_type', 'plot_floor_area_and_energy_totals',
     'electricity_by_comstock_building_type.png', 'A',
     'Annual electricity consumption, baseline vs upgrade, by building type'),
    ('electricity_by_census_division_name', 'plot_floor_area_and_energy_totals',
     'electricity_by_census_division_name.png', 'A',
     'Annual electricity consumption, baseline vs upgrade, by census division'),
    ('site_energy_by_comstock_building_type', 'plot_floor_area_and_energy_totals',
     'site_energy_by_comstock_building_type.png', 'A',
     'Annual site energy consumption, baseline vs upgrade, by building type'),
    ('site_energy_by_census_division_name', 'plot_floor_area_and_energy_totals',
     'site_energy_by_census_division_name.png', 'A',
     'Annual site energy consumption, baseline vs upgrade, by census division'),
    ('ghg_emissions', 'plot_emissions_by_fuel_type', 'ghg_emissions_*.png', 'GHG',
     'Annual greenhouse gas emissions by fuel, for three electricity grid scenarios'),
)

NOTES = []  # standing remarks for the manifest; figures that fail to draw are added per run

FIGURE_WIDTH_IN = 6.5
FIGURE_MAX_HEIGHT_IN = 7.5
FIGURE_DPI = 300


class DocAssetsPlotter(NamingMixin, UnitsMixin, PlottingMixin):
    """Enough of ComStockMeasureComparison to draw its figures outside the pipeline."""

    def __init__(self):
        self.image_type = 'png'
        self.lazyframe_plotter = LazyFramePlotter()


def measure_dir_name(upgrade_id, upgrade_name):
    """The measure_runs folder name ComStockMeasureComparison uses for an upgrade."""
    return ('up' + str(upgrade_id).zfill(2) + '_' + str(upgrade_name))[:20]


# ---------------------------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------------------------

def _rank(order, value):
    return (order.index(value), value) if value in order else (len(order), value)


def _spec(column, quantity, fuel='', end_use='', variant='', units='', parts=None):
    return {'column': column, 'quantity': quantity, 'fuel': fuel, 'end_use': end_use,
            'variant': variant or '', 'units': units, 'parts': parts}


def column_specs(names):
    """The quantities annual_totals sums, read from the column names, in a fixed order."""
    names = list(names)
    present = set(names)
    specs = []

    energy = {}
    for c in names:
        m = _ENERGY_RE.match(c)
        if m:
            energy.setdefault(m['fuel'], {})[m['end_use']] = (c, m['units'])
    for fuel in sorted(energy, key=lambda f: _rank(_FUEL_ORDER, f)):
        uses = energy[fuel]
        for end_use in sorted(uses, key=lambda u: _rank(_ROLLUPS, u)):
            column, units = uses[end_use]
            specs.append(_spec(column, 'site_energy', fuel, end_use, units=units))
        if 'total' not in uses and fuel != 'site_energy':
            parts = [uses[u][0] for u in sorted(uses) if u not in _NOT_END_USES]
            if parts:
                units = uses[sorted(uses)[0]][1]
                specs.append(_spec(f'calc.weighted.{fuel}.total.energy_consumption..{units}',
                                   'site_energy', fuel, 'total', units=units, parts=parts))

    bills = []
    for c in names:
        m = _BILL_RE.match(c)
        if m and not m['variant'].startswith('savings'):
            bills.append(_spec(c, 'utility_bill', m['fuel'], variant=m['variant'], units=m['units']))
    total_bill = 'calc.weighted.utility_bills.total_bill_mean..billion_usd'
    parts = [f'calc.weighted.utility_bills.{p}..billion_usd' for p in _BILL_PARTS]
    parts = [p for p in parts if p in present]
    if total_bill not in present and parts and parts[0].endswith('electricity_bill_mean..billion_usd'):
        bills.append(_spec(total_bill, 'utility_bill', 'total', variant='mean', units='billion_usd', parts=parts))
    specs += sorted(bills, key=lambda s: (_rank(_FUEL_ORDER + ['total'], s['fuel']), s['variant']))

    ghg = []
    for c in names:
        m = _GHG_RE.match(c)
        if m and m['fuel'] != 'savings':
            ghg.append(_spec(c, 'ghg_emissions', m['fuel'], variant=m['variant'], units=m['units']))
    specs += sorted(ghg, key=lambda s: (_rank(_FUEL_ORDER, s['fuel']), s['variant']))

    if FLOOR_AREA in present:
        specs.append(_spec(FLOOR_AREA, 'floor_area', units='ft2'))
    if WEIGHT in present:
        specs.append(_spec(WEIGHT, 'building_count', units='buildings'))
    return specs


def _expr(spec):
    if spec['parts']:
        return pl.sum_horizontal([pl.col(p) for p in spec['parts']])
    return pl.col(spec['column'])


def prepare(lf, upgrade_id, baseline_id):
    """Keep the baseline and upgrade rows and mark each row's side and population."""
    is_upgrade = pl.col(UPGRADE_ID) == upgrade_id
    applicable_ids = (lf.filter(is_upgrade & pl.col(APPLICABILITY).fill_null(False))
                      .select(BLDG_ID).unique().collect().to_series())
    return (lf.filter(pl.col(UPGRADE_ID).is_in([baseline_id, upgrade_id]))
            .with_columns(pl.when(is_upgrade).then(pl.lit('upgrade')).otherwise(pl.lit('baseline')).alias('_side'),
                          pl.col(BLDG_ID).is_in(applicable_ids.implode()).alias('_applicable')))


def _sums(prepared, specs, by=()):
    """{(population, group values, side): {column: sum}}"""
    exprs = [_expr(s).cast(pl.Float64).sum().alias(s['column']) for s in specs]
    out = {}
    for population in POPULATIONS:
        frame = prepared if population == 'stock' else prepared.filter(pl.col('_applicable'))
        for row in frame.group_by(['_side', *by]).agg(exprs).collect().iter_rows(named=True):
            out[(population, tuple(row[b] for b in by), row['_side'])] = row
    return out


def _percent(baseline, upgrade):
    return None if baseline == 0 else (baseline - upgrade) / baseline * 100.0


def _rows(specs, sums, population, group=()):
    base = sums.get((population, group, 'baseline'), {})
    upg = sums.get((population, group, 'upgrade'), {})
    rows = []
    for s in specs:
        b = base.get(s['column']) or 0.0
        u = upg.get(s['column']) or 0.0
        rows.append({'population': population, 'quantity': s['quantity'], 'fuel': s['fuel'],
                     'end_use': s['end_use'], 'variant': s['variant'], 'units': s['units'],
                     'baseline': b, 'upgrade': u, 'savings': b - u, 'percent_savings': _percent(b, u),
                     'column': s['column'],
                     'derived': ('sum of ' + ' + '.join(s['parts'])) if s['parts'] else ''})
    return rows


def annual_totals(prepared, specs):
    sums = _sums(prepared, specs)
    return [r for population in POPULATIONS for r in _rows(specs, sums, population)]


def savings_by_group(prepared, specs, group_columns=GROUP_COLUMNS):
    names = set(prepared.collect_schema().names())
    rows = []
    for group_by in [g for g in group_columns if g in names]:
        sums = _sums(prepared, specs, by=(group_by,))
        groups = sorted({k[1][0] for k in sums}, key=lambda g: (g is None, str(g)))
        for population in POPULATIONS:
            for g in groups:
                for r in _rows(specs, sums, population, (g,)):
                    if r['baseline'] == 0 and r['upgrade'] == 0:
                        continue
                    rows.append({'group_by': group_by, 'group': '' if g is None else g, **r})
    return rows


def applicability(prepared):
    """Models, buildings and floor area in the stock and in the applicable population."""
    applicable = pl.col('_applicable')
    r = (prepared.filter(pl.col('_side') == 'upgrade').select(
        pl.col(BLDG_ID).n_unique().alias('models'),
        pl.col(BLDG_ID).filter(applicable).n_unique().alias('models_applicable'),
        pl.col(WEIGHT).cast(pl.Float64).sum().alias('buildings'),
        pl.col(WEIGHT).cast(pl.Float64).filter(applicable).sum().alias('buildings_applicable'),
        pl.col(FLOOR_AREA).cast(pl.Float64).sum().alias('floor_area'),
        pl.col(FLOOR_AREA).cast(pl.Float64).filter(applicable).sum().alias('floor_area_applicable'),
    ).collect().row(0, named=True))

    def pct(part, whole):
        return part / whole * 100.0 if whole else None

    return [
        {'metric': 'models', 'value': r['models'], 'units': 'models',
         'definition': f'distinct {BLDG_ID} in the upgrade'},
        {'metric': 'models_applicable', 'value': r['models_applicable'], 'units': 'models',
         'definition': f'distinct {BLDG_ID} whose upgrade row has {APPLICABILITY} = true'},
        {'metric': 'buildings', 'value': r['buildings'], 'units': 'buildings',
         'definition': f'sum of {WEIGHT}: buildings the upgrade rows represent'},
        {'metric': 'buildings_applicable', 'value': r['buildings_applicable'], 'units': 'buildings',
         'definition': f'sum of {WEIGHT} over applicable buildings'},
        {'metric': 'buildings_applicable_pct', 'value': pct(r['buildings_applicable'], r['buildings']),
         'units': 'percent', 'definition': 'buildings_applicable / buildings * 100'},
        {'metric': 'floor_area', 'value': r['floor_area'], 'units': 'ft2',
         'definition': f'sum of {FLOOR_AREA} over the upgrade rows'},
        {'metric': 'floor_area_applicable', 'value': r['floor_area_applicable'], 'units': 'ft2',
         'definition': f'sum of {FLOOR_AREA} over applicable buildings'},
        {'metric': 'floor_area_applicable_pct', 'value': pct(r['floor_area_applicable'], r['floor_area']),
         'units': 'percent', 'definition': 'floor_area_applicable / floor_area * 100'},
    ]


def distribution_sets(namer, names):
    """The boxes of each savings-distribution figure: (figure, value column, group column, cap).

    Mirrors PlottingMixin.plot_measure_savings_distributions_*: by end use and by fuel cap
    percent savings at -150..100 %, by building type, climate zone and HVAC system at -100..100 %.
    """
    names = set(names)
    total = namer.ANN_TOT_ENGY_KBTU
    pct = lambda c: namer.col_name_to_percent_savings(c, 'percent')
    eui = lambda c: namer.col_name_to_savings(namer.col_name_to_eui(c))
    sets = []
    for figure, cols in (('percent_site_energy_savings_by_end_use', [pct(c) for c in namer.COLS_ENDUSE_ANN_ENGY]),
                         ('percent_site_energy_savings_by_fuel', [pct(c) for c in namer.COLS_TOT_ANN_ENGY]),
                         ('site_eui_savings_by_end_use', [eui(c) for c in namer.COLS_ENDUSE_ANN_ENGY]),
                         ('site_eui_savings_by_fuel', [eui(c) for c in namer.COLS_TOT_ANN_ENGY])):
        sets += [(figure, c, None, 150) for c in cols if c in names]
    for suffix, group in (('building_type', namer.BLDG_TYPE), ('climate_zone', namer.CZ_ASHRAE),
                          ('hvac_system', namer.HVAC_SYS)):
        if group not in names:
            continue
        for figure, col in ((f'percent_site_energy_savings_by_{suffix}', pct(total)),
                            (f'site_eui_savings_by_{suffix}', eui(total))):
            if col in names:
                sets.append((figure, col, group, 100))
    return sets


def _stats(values):
    a = np.asarray(values, dtype=float)
    out = {'n': int(a.size)}
    if a.size == 0:
        return out
    q1, median, q3 = np.percentile(a, [25, 50, 75])
    iqr = q3 - q1
    lo, hi = q1 - 1.5 * iqr, q3 + 1.5 * iqr
    out.update({'mean': float(a.mean()), 'q1': float(q1), 'median': float(median), 'q3': float(q3),
                'iqr': float(iqr), 'lower_fence': float(lo), 'upper_fence': float(hi),
                'n_below_fence': int((a < lo).sum()), 'n_above_fence': int((a > hi).sum()),
                'min': float(a.min()), 'max': float(a.max())})
    return out


def savings_distributions(prepared, namer):
    """The statistics behind each box of the savings-distribution figures."""
    upg = prepared.filter(pl.col('_side') == 'upgrade')
    sets = distribution_sets(namer, upg.collect_schema().names())
    if not sets:
        return []
    needed = sorted({c for _, c, _, _ in sets} | {g for _, _, g, _ in sets if g})
    df = upg.select(needed).collect()
    rows = []
    for figure, col, group, cap in sets:
        is_pct = 'percent_savings' in col
        units = 'percent' if is_pct else namer.units_from_col_name(col)
        values = df[col].cast(pl.Float64)
        keep = values.is_not_nan() & values.is_not_null() & (values != 0)
        if is_pct:
            keep = keep & (values >= -cap) & (values <= min(cap, 100))
            rule = f'upgrade rows; percent savings outside -{cap}..{min(cap, 100)} %, zero and missing values dropped'
        else:
            rule = 'upgrade rows; zero and missing values dropped'
        if group is None:
            boxes = [(col, namer.col_name_to_nice_saving_name(col).strip(), keep)]
        else:
            cats = sorted({str(v) for v in df[group].to_list() if v is not None})
            boxes = [(c, c, keep & (df[group].cast(pl.String) == c)) for c in cats]
        for category, label, mask in boxes:
            stats = _stats(values.filter(mask).to_numpy())
            rows.append({'figure': figure, 'category': category, 'label': label, 'column': col,
                         'units': units, **stats, 'filter': rule})
    return rows


# ---------------------------------------------------------------------------------------------
# Figures
# ---------------------------------------------------------------------------------------------

def _plot_columns(plotter, method):
    """The columns ComStockMeasureComparison.make_plots hands each plot method."""
    L = plotter.lazyframe_plotter
    p = plotter
    return {
        'plot_energy_by_enduse_and_fuel_type': L.BASE_COLUMNS + L.WTD_COLUMNS_ANN_ENDUSE + L.WTD_COLUMNS_ANN_PV + L.WTD_COLUMNS_SUMMARIZE,
        'plot_emissions_by_fuel_type': L.BASE_COLUMNS + L.WTD_GHG_COLUMNS,
        'plot_utility_bills_by_fuel_type': L.BASE_COLUMNS + L.WTD_UTILITY_COLUMNS,
        'plot_floor_area_and_energy_totals': L.BASE_COLUMNS + L.WTD_COLUMNS_SUMMARIZE,
        'plot_measure_savings_distributions_enduse_and_fuel': L.BASE_COLUMNS + L.SAVINGS_DISTRI_ENDUSE_COLUMNS + [p.UPGRADE_ID],
        'plot_measure_savings_distributions_by_building_type': L.BASE_COLUMNS + L.SAVINGS_DISTRI_BUILDINTYPE + [p.BLDG_TYPE, p.UPGRADE_ID],
        'plot_measure_savings_distributions_by_climate_zone': L.BASE_COLUMNS + L.SAVINGS_DISTRI_BUILDINTYPE + [p.CZ_ASHRAE, p.UPGRADE_ID],
        'plot_measure_savings_distributions_by_hvac_system_type': L.BASE_COLUMNS + L.SAVINGS_DISTRI_BUILDINTYPE + [p.HVAC_SYS, p.UPGRADE_ID],
    }[method]


_GROUPED_PLOTS = {'plot_energy_by_enduse_and_fuel_type', 'plot_emissions_by_fuel_type',
                  'plot_utility_bills_by_fuel_type', 'plot_floor_area_and_energy_totals'}


def normalize_figure(src, dst, width_in=FIGURE_WIDTH_IN, max_height_in=FIGURE_MAX_HEIGHT_IN, dpi=FIGURE_DPI):
    """Write src as an RGB PNG sized for a document page, with its dpi recorded in the file.

    Large renders are scaled down to width_in at dpi (and to max_height_in if taller); a render
    narrower than that keeps its pixels and gets the dpi that makes it width_in wide.
    """
    from PIL import Image

    with Image.open(src) as im:
        im.load()
        if im.mode in ('RGBA', 'LA', 'P'):
            rgba = im.convert('RGBA')
            flat = Image.new('RGB', rgba.size, 'white')
            flat.paste(rgba, mask=rgba.getchannel('A'))
            im = flat
        else:
            im = im.convert('RGB')
        w, h = im.size
        scale = min(1.0, width_in * dpi / w, max_height_in * dpi / h)
        if scale < 1.0:
            im = im.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
        w, h = im.size
        eff_dpi = dpi if scale < 1.0 else min(dpi, w / width_in)
        im.save(dst, format='PNG', dpi=(eff_dpi, eff_dpi), optimize=True)
    return {'width_px': w, 'height_px': h, 'dpi': round(eff_dpi, 2),
            'width_in': round(w / eff_dpi, 3), 'height_in': round(h / eff_dpi, 3)}


def render_figures(plotter, lf, upgrade_name, out_dir, names=None):
    """Draw the FIGURES with the comparison's own plot methods and size them for a document.

    Returns (manifest entries, problems). A figure that fails to draw is reported, not raised:
    the tables are the core of the assets and should not be lost to one plot.
    """
    import matplotlib
    import matplotlib.pyplot as plt

    wanted = [f for f in FIGURES if names is None or f[0] in names]
    color_map = {'Baseline': plotter.COLOR_COMSTOCK_BEFORE, upgrade_name: plotter.COLOR_COMSTOCK_AFTER}
    entries, problems = [], []
    old_type = plotter.image_type
    plotter.image_type = 'png'
    try:
        with tempfile.TemporaryDirectory(prefix='doc_assets_') as staging, \
                matplotlib.rc_context({'savefig.dpi': FIGURE_DPI}):
            staging = Path(staging)
            for method in dict.fromkeys(f[1] for f in wanted):
                kwargs = {'output_dir': str(staging)}
                if method in _GROUPED_PLOTS:
                    kwargs.update(column_for_grouping=plotter.UPGRADE_NAME, color_map=color_map)
                try:
                    LazyFramePlotter.plot_with_lazy(plot_method=getattr(plotter, method), lazy_frame=lf.clone(),
                                                    columns=_plot_columns(plotter, method))(**kwargs)
                except Exception as e:  # noqa: BLE001 - reported in the manifest
                    logger.exception(f'doc_assets: {method} failed')
                    problems.append(f'{method}: {type(e).__name__}: {e}')
                finally:
                    plt.close('all')
            for name, method, source, section, description in wanted:
                found = sorted(staging.glob(source))
                if not found:
                    if not any(p.startswith(method + ':') for p in problems):
                        problems.append(f'{name}: {method} did not write {source}')
                    continue
                path = Path(out_dir) / f'{name}.png'
                info = normalize_figure(found[0], path)
                entries.append({'path': f'figures/{name}.png', 'kind': 'figure', 'section': section,
                                'description': description, 'source': f'PlottingMixin.{method}',
                                'original_name': found[0].relative_to(staging).as_posix(), **info})
    finally:
        plotter.image_type = old_type
    return entries, problems


# ---------------------------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------------------------

def _cell(v):
    if v is None:
        return ''
    if isinstance(v, float):
        return '' if np.isnan(v) else repr(v)
    return v


def _write_csv(path, fields, rows):
    with open(path, 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f, lineterminator='\n')
        w.writerow(fields)
        for r in rows:
            w.writerow([_cell(r.get(k)) for k in fields])


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def _git_info():
    here = Path(__file__).resolve().parent

    def git(*args):
        r = subprocess.run(['git', '-C', str(here), *args], capture_output=True, text=True, timeout=20)
        return r.stdout.strip() if r.returncode == 0 else None

    try:
        commit = git('rev-parse', 'HEAD')
        if not commit:
            return None
        status = git('status', '--porcelain', '--untracked-files=no')
        return {'commit': commit, 'branch': git('rev-parse', '--abbrev-ref', 'HEAD'),
                'dirty': bool(status) if status is not None else None}
    except (OSError, subprocess.SubprocessError):
        return None


def _checks(totals):
    """Consistency of the totals with each other, recorded rather than enforced."""
    stock = {(r['quantity'], r['fuel'], r['end_use'], r['variant']): r for r in totals if r['population'] == 'stock'}
    checks = []

    def rel(a, b):
        return abs(a - b) / max(abs(a), abs(b)) if max(abs(a), abs(b)) else 0.0

    area = stock.get(('floor_area', '', '', ''))
    if area:
        d = rel(area['baseline'], area['upgrade'])
        # the upgrade's allocated weights differ from the baseline's in the 7th digit or so
        checks.append({'name': 'floor area unchanged by the upgrade', 'ok': d < 1e-5, 'detail': f'relative difference {d:.1e}'})
    site = stock.get(('site_energy', 'site_energy', 'total', ''))
    fuels = [r for k, r in stock.items() if k[0] == 'site_energy' and k[2] == 'total' and k[1] != 'site_energy']
    if site and fuels:
        for side in ('baseline', 'upgrade'):
            d = rel(site[side], sum(r[side] for r in fuels))
            checks.append({'name': f'site energy total = sum of fuel totals ({side})', 'ok': d < 1e-4,
                           'detail': f'relative difference {d:.1e} over {len(fuels)} fuels'})
    for fuel in sorted({k[1] for k in stock if k[0] == 'site_energy' and k[1] != 'site_energy'},
                       key=lambda f: _rank(_FUEL_ORDER, f)):
        tot = stock.get(('site_energy', fuel, 'total', ''))
        uses = [r for k, r in stock.items() if k[0] == 'site_energy' and k[1] == fuel and k[2] not in _NOT_END_USES]
        if tot and uses and not tot['derived']:
            d = rel(tot['baseline'], sum(r['baseline'] for r in uses))
            checks.append({'name': f'{fuel} total = sum of its end uses (baseline)', 'ok': d < 1e-4,
                           'detail': f'relative difference {d:.1e} over {len(uses)} end uses'})
    return checks


def _rebuilt_note(specs):
    """Say so in the manifest when an older plotting cache made the export rebuild totals."""
    rebuilt = [f"{s['fuel']} total" if s['quantity'] == 'site_energy' else 'total bill' for s in specs if s['parts']]
    if not rebuilt:
        return []
    return [f'this plotting cache has no column for: {", ".join(rebuilt)}. {"Each was" if len(rebuilt) > 1 else "It was"} '
            'rebuilt from its parts (see the derived column of the tables); postprocess the run again to use '
            'the exported totals.']


def _jsonable(v):
    if isinstance(v, (str, int, float, bool)) or v is None:
        return v
    if isinstance(v, dict):
        return {str(k): _jsonable(x) for k, x in v.items()}
    if isinstance(v, (list, tuple, set)):
        return [_jsonable(x) for x in v]
    return str(v)


def run_info_from_comstock(comstock_object):
    """The run settings worth recording, from a ComStock object."""
    keys = ('dataset_name', 'comstock_run_name', 'comstock_run_version', 's3_base_dir', 'athena_table_name',
            'year', 'truth_data_version', 'buildstock_file_name', 'include_upgrades', 'upgrade_ids_to_skip',
            'upgrade_ids_to_process', 'rename_upgrades', 'weighted_energy_units', 'weighted_ghg_units',
            'weighted_utility_units')
    info = {k: _jsonable(getattr(comstock_object, k)) for k in keys if hasattr(comstock_object, k)}
    out = getattr(comstock_object, 'output_dir', None)
    if isinstance(out, dict) and out.get('fs_path') and out.get('fs') is not None:
        protocol = out['fs'].protocol
        protocol = protocol if isinstance(protocol, str) else protocol[0]
        if protocol in ('file', 'local'):  # S3 outputs have no local run folder to point at
            info['run_dir'] = str(Path(out['fs_path']).resolve())
    return info


def plotting_cache_files(run_dir, upgrade_ids):
    """The cached plotting parquet files ComStock.create_plotting_lazyframe wrote for these upgrades."""
    root = Path(run_dir) / 'cached_plotting_by_upgrade'
    ids = [int(u) if str(u).isdigit() else u for u in upgrade_ids]  # '00' in some runs, 0 in the cache
    return sorted(p for u in ids for p in root.glob(f'upgrade={u}/*.parquet'))


def export(lf, upgrade_id, baseline_id, upgrade_name, measure_dir, plotter=None, run=None,
           inputs=(), figures=True):
    """Write measure_dir/doc_assets/ for one upgrade and return its path.

    lf holds the plotting rows of the baseline and the upgrade (more rows are ignored). The
    folder is built beside the old one and swapped in only when complete; if anything fails,
    neither a partial folder nor a stale one from an earlier run is left behind.
    """
    measure_dir = Path(measure_dir)
    final = measure_dir / DOC_ASSETS_DIR
    partial = measure_dir / (DOC_ASSETS_DIR + '.partial')
    _check_path_length(partial, figures)
    shutil.rmtree(partial, ignore_errors=True)
    try:
        (partial / 'tables').mkdir(parents=True)
        plotter = plotter or DocAssetsPlotter()
        prepared = prepare(lf, upgrade_id, baseline_id)
        specs = column_specs(prepared.collect_schema().names())

        totals = annual_totals(prepared, specs)
        appl = applicability(prepared)
        tables = [
            ('tables/annual_totals.csv', TOTALS_FIELDS, totals,
             'Stock and applicable-only annual totals, baseline vs upgrade: site energy by fuel and '
             'end use, utility bills, emissions, floor area, buildings'),
            ('tables/applicability.csv', APPLICABILITY_FIELDS, appl,
             'Models, buildings and floor area in the stock and the applicable population'),
            ('tables/savings_by_group.csv', GROUP_FIELDS, savings_by_group(prepared, specs),
             'annual_totals by building type, census division, climate zone, HVAC system type and vintage'),
            ('tables/savings_distributions.csv', DISTRIBUTION_FIELDS, savings_distributions(prepared, plotter),
             'Statistics behind each box of the savings-distribution figures'),
        ]
        files = []
        for rel_path, fields, rows, description in tables:
            _write_csv(partial / rel_path, fields, rows)
            files.append({'path': rel_path, 'kind': 'table', 'rows': len(rows), 'description': description})

        problems = []
        if figures:
            (partial / 'figures').mkdir()
            entries, problems = render_figures(plotter, lf.filter(pl.col(UPGRADE_ID).is_in([baseline_id, upgrade_id])),
                                               upgrade_name, partial / 'figures')
            files += entries
        for f in files:
            p = partial / f['path']
            f['bytes'] = p.stat().st_size
            f['sha256'] = sha256_file(p)

        rows_by_side = dict(prepared.group_by('_side').agg(pl.len()).collect().iter_rows())
        manifest = {
            'schema': SCHEMA,
            'generated': dt.datetime.now().astimezone().replace(microsecond=0).isoformat(),
            'generator': {'package': 'comstockpostproc', 'version': __version__,
                          'module': 'comstockpostproc.measure_doc_assets', 'git': _git_info()},
            'run': _jsonable(run or {}),
            'upgrade': {'id': _jsonable(upgrade_id), 'name': str(upgrade_name),
                        'baseline_id': _jsonable(baseline_id), 'measure_dir': measure_dir.name},
            'inputs': [{'path': _rel(p, (run or {}).get('run_dir')), 'bytes': Path(p).stat().st_size,
                        'sha256': sha256_file(p)} for p in inputs],
            'data': {'rows': {k: int(rows_by_side.get(k, 0)) for k in ('baseline', 'upgrade')},
                     **{r['metric']: r['value'] for r in appl if r['metric'] in ('models', 'models_applicable')}},
            'checks': _checks(totals),
            'files': files,
            'notes': NOTES + _rebuilt_note(specs) + [f'figure not made: {p}' for p in problems],
        }
        (partial / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        if final.exists():
            shutil.rmtree(final, ignore_errors=True)
            logger.error(f'doc_assets: removed {final}, which no longer matches this run')
        raise
    if final.exists():
        shutil.rmtree(final)
    partial.rename(final)
    logger.info(f'doc_assets: wrote {final} ({len(files)} files)')
    return final


def _check_path_length(folder, figures=True):
    """Fail up front, and say why, rather than midway with a bare FileNotFoundError."""
    if os.name != 'nt':
        return
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r'SYSTEM\CurrentControlSet\Control\FileSystem') as k:
            if winreg.QueryValueEx(k, 'LongPathsEnabled')[0]:
                return
    except OSError:
        pass
    longest = max([f'figures/{f[0]}.png' for f in FIGURES if figures] + ['tables/savings_distributions.csv'], key=len)
    n = len(str(Path(folder) / longest))
    if n > 259:
        raise OSError(f'doc_assets would write paths of {n} characters, over the Windows limit of 260, '
                      f'under {folder}. Use a shorter output folder.')


def _rel(path, root):
    path = Path(path).resolve()
    if root:
        try:
            return path.relative_to(Path(root).resolve()).as_posix()
        except ValueError:
            pass
    return path.as_posix()


# ---------------------------------------------------------------------------------------------
# Command line, for runs already postprocessed
# ---------------------------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(
        prog='python -m comstockpostproc.measure_doc_assets',
        description='Write measure_runs/upNN_<name>/doc_assets/ for a postprocessed run, from the '
                    'cached plotting data its comparison figures were drawn from.')
    ap.add_argument('run_dir', help='postprocessing output folder, e.g. "postprocessing/output/ComStock my_run"')
    ap.add_argument('--upgrade', type=int, nargs='+', help='upgrade ids (default: every upgrade)')
    ap.add_argument('--baseline', type=int, default=0, help='baseline upgrade id (default 0)')
    ap.add_argument('--no-figures', action='store_true', help='tables and manifest only')
    ap.add_argument('--out', help='write <OUT>/upNN_<name>/doc_assets/ instead of into the run\'s measure_runs/')
    args = ap.parse_args(argv)

    logging.basicConfig(level='INFO', format='%(levelname)s %(message)s')
    run_dir = Path(args.run_dir).resolve()
    files = sorted((run_dir / 'cached_plotting_by_upgrade').glob('upgrade=*/*.parquet'))
    if not files:
        print(f'error: no cached plotting data under {run_dir / "cached_plotting_by_upgrade"}; '
              'run the postprocessing (compare_upgrades.py) for this run first', file=sys.stderr)
        return 2
    lf = (pl.scan_parquet([str(f) for f in files], hive_partitioning=True)
          .with_columns(pl.col(UPGRADE_NAME).cast(pl.String)))
    names = dict(lf.select(UPGRADE_ID, UPGRADE_NAME).unique().collect().iter_rows())
    if args.baseline not in names:
        print(f'error: baseline upgrade {args.baseline} is not in the cached plotting data', file=sys.stderr)
        return 2
    ids = args.upgrade or sorted(u for u in names if u != args.baseline)
    missing = [u for u in ids if u not in names]
    if missing:
        print(f'error: upgrades {missing} are not in the cached plotting data (found {sorted(names)})', file=sys.stderr)
        return 2
    dataset = lf.select(pl.col('dataset').first()).collect().item() if 'dataset' in lf.collect_schema().names() else run_dir.name
    plotter = DocAssetsPlotter()
    measure_runs = Path(args.out).resolve() if args.out else run_dir / 'measure_runs'
    for uid in ids:
        run = {'dataset_name': dataset, 'run_dir': str(run_dir),
               'source': 'cached plotting data, via python -m comstockpostproc.measure_doc_assets'}
        out = export(lf.filter(pl.col(UPGRADE_ID).is_in([args.baseline, uid])), uid, args.baseline, names[uid],
                     measure_runs / measure_dir_name(uid, names[uid]), plotter=plotter, run=run,
                     inputs=plotting_cache_files(run_dir, [args.baseline, uid]), figures=not args.no_figures)
        print(out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
