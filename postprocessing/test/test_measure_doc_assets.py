# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Tests for comstockpostproc.measure_doc_assets, on small synthetic plotting data.

Three buildings, baseline (0) and one upgrade (1):
  bldg 1  applicable, split across two climate zones (two rows per upgrade)
  bldg 2  applicable
  bldg 3  not applicable
"""
import csv
import importlib.util
import json
import shutil
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import polars as pl
import pytest
from fsspec.implementations.local import LocalFileSystem

import comstockpostproc.measure_doc_assets as mda
from comstockpostproc.lazyframeplotter import LazyFramePlotter

E = 'calc.weighted.{}.{}.energy_consumption..tbtu'
PCT_SITE = 'calc.percent_savings.site_energy.total.energy_consumption..percent'
PCT_ELEC_HEAT = 'calc.percent_savings.electricity.heating.energy_consumption..percent'
EUI_SITE = 'out.site_energy.total.energy_savings_intensity..kwh_per_ft2'


def _frame():
    rows = []
    #               bldg, cz,   btype,         weight, sqft, applicable
    buildings = [(1, '4A', 'SmallOffice', 10.0, 1000.0, True),
                 (1, '5A', 'SmallOffice', 30.0, 3000.0, True),
                 (2, '4A', 'Warehouse', 20.0, 4000.0, True),
                 (3, '3A', 'SmallOffice', 40.0, 2000.0, False)]
    elec_heat = [1.0, 3.0, 2.0, 4.0]
    for upgrade, name in ((0, 'Baseline'), (1, 'Test Measure')):
        for i, (bldg, cz, btype, weight, sqft, appl) in enumerate(buildings):
            up = upgrade == 1 and appl
            eh = elec_heat[i] * (1.5 if up else 1.0)
            gh = 0.0 if up else 2.0
            fo = 0.0 if up else (0.5 if bldg == 1 else 0.0)
            row = {
                'upgrade': upgrade, 'in.upgrade_name': name, 'bldg_id': bldg,
                'applicability': appl if upgrade == 1 else True,
                'weight': weight, 'calc.weighted.sqft..ft2': sqft,
                'in.comstock_building_type': btype, 'in.census_division_name': 'Mountain',
                'in.ashrae_iecc_climate_zone_2006': cz, 'in.hvac_system_type': 'PSZ-AC', 'in.vintage': '1980 to 1989',
                E.format('electricity', 'heating'): eh,
                E.format('electricity', 'cooling'): 1.0,
                E.format('electricity', 'total'): eh + 1.0,
                E.format('natural_gas', 'heating'): gh,
                E.format('natural_gas', 'total'): gh,
                E.format('fuel_oil', 'heating'): fo,
                E.format('fuel_oil', 'water_systems'): 0.1,
                E.format('site_energy', 'total'): eh + 1.0 + gh + fo + 0.1,
                'calc.weighted.utility_bills.electricity_bill_mean..billion_usd': 2.0 * (eh + 1.0),
                'calc.weighted.utility_bills.natural_gas_bill_state_average..billion_usd': gh,
                'calc.weighted.emissions.electricity.egrid_2021_subregion..co2e_mmt': 0.5 * (eh + 1.0),
                'calc.weighted.emissions.natural_gas..co2e_mmt': 0.2 * gh,
                PCT_SITE: ([20.0, 20.0, 150.0, 0.0][i] if upgrade == 1 else 0.0),
                PCT_ELEC_HEAT: ([-50.0, -50.0, -120.0, 0.0][i] if upgrade == 1 else 0.0),
                EUI_SITE: ([2.0, 2.0, 1.0, 0.0][i] if upgrade == 1 else 0.0),
            }
            rows.append(row)
    return pl.DataFrame(rows).lazy()


def _prepared():
    return mda.prepare(_frame(), 1, 0)


def _find(rows, **match):
    hits = [r for r in rows if all(r[k] == v for k, v in match.items())]
    assert len(hits) == 1, (match, hits)
    return hits[0]


def test_column_specs_derive_what_the_plotting_data_lacks():
    specs = mda.column_specs(_frame().collect_schema().names())
    by_col = {s['column']: s for s in specs}
    fo_total = by_col[E.format('fuel_oil', 'total')]
    assert fo_total['parts'] == [E.format('fuel_oil', 'heating'), E.format('fuel_oil', 'water_systems')]
    bill_total = by_col['calc.weighted.utility_bills.total_bill_mean..billion_usd']
    assert bill_total['quantity'] == 'utility_bill' and bill_total['fuel'] == 'total' and bill_total['variant'] == 'mean'
    assert len(bill_total['parts']) == 2
    ghg = by_col['calc.weighted.emissions.electricity.egrid_2021_subregion..co2e_mmt']
    assert (ghg['fuel'], ghg['variant']) == ('electricity', 'egrid_2021_subregion')
    assert specs[0]['column'] == E.format('site_energy', 'total')  # all fuels first
    assert [s['quantity'] for s in specs][-2:] == ['floor_area', 'building_count']


def test_annual_totals_compare_the_same_buildings():
    prepared = _prepared()
    rows = mda.annual_totals(prepared, mda.column_specs(prepared.collect_schema().names()))
    heat = dict(quantity='site_energy', fuel='electricity', end_use='heating')
    stock = _find(rows, population='stock', **heat)
    assert stock['baseline'] == pytest.approx(10.0)            # 1 + 3 + 2 + 4
    assert stock['upgrade'] == pytest.approx(13.0)             # 1.5 + 4.5 + 3 + 4
    assert stock['savings'] == pytest.approx(-3.0)
    assert stock['percent_savings'] == pytest.approx(-30.0)
    applicable = _find(rows, population='applicable', **heat)   # bldg 3 left out on both sides
    assert applicable['baseline'] == pytest.approx(6.0)
    assert applicable['upgrade'] == pytest.approx(9.0)
    fo = _find(rows, population='stock', quantity='site_energy', fuel='fuel_oil', end_use='total')
    assert fo['baseline'] == pytest.approx(1.4) and fo['upgrade'] == pytest.approx(0.4)
    assert fo['derived'].startswith('sum of ')
    gas = _find(rows, population='applicable', quantity='site_energy', fuel='natural_gas', end_use='total')
    assert gas['percent_savings'] == pytest.approx(100.0)
    cooling = _find(rows, population='stock', quantity='site_energy', fuel='electricity', end_use='cooling')
    assert cooling['savings'] == 0.0 and cooling['percent_savings'] == 0.0
    bill = _find(rows, population='stock', quantity='utility_bill', fuel='total', variant='mean')
    assert bill['baseline'] == pytest.approx(2.0 * 14.0 + 8.0)
    area = _find(rows, population='applicable', quantity='floor_area')
    assert area['baseline'] == area['upgrade'] == pytest.approx(8000.0)


def test_applicability():
    a = {r['metric']: r['value'] for r in mda.applicability(_prepared())}
    assert a['models'] == 3 and a['models_applicable'] == 2
    assert a['buildings'] == pytest.approx(100.0) and a['buildings_applicable_pct'] == pytest.approx(60.0)
    assert a['floor_area'] == pytest.approx(10000.0) and a['floor_area_applicable_pct'] == pytest.approx(80.0)


def test_savings_by_group():
    prepared = _prepared()
    rows = mda.savings_by_group(prepared, mda.column_specs(prepared.collect_schema().names()))
    office = _find(rows, group_by='in.comstock_building_type', group='SmallOffice', population='stock',
                   quantity='site_energy', fuel='electricity', end_use='heating')
    assert office['baseline'] == pytest.approx(8.0)            # bldg 1 (both rows) + bldg 3
    cz4a = _find(rows, group_by='in.ashrae_iecc_climate_zone_2006', group='4A', population='applicable',
                 quantity='site_energy', fuel='electricity', end_use='heating')
    assert cz4a['baseline'] == pytest.approx(3.0)              # bldg 1's 4A row + bldg 2
    assert not [r for r in rows if r['baseline'] == 0 and r['upgrade'] == 0]


def test_savings_distributions_apply_the_figures_filters():
    rows = mda.savings_distributions(_prepared(), mda.DocAssetsPlotter())
    office = _find(rows, figure='percent_site_energy_savings_by_building_type', category='SmallOffice')
    assert office['n'] == 2 and office['median'] == pytest.approx(20.0)   # bldg 3's 0 dropped
    warehouse = _find(rows, figure='percent_site_energy_savings_by_building_type', category='Warehouse')
    assert warehouse['n'] == 0                                            # 150 % is outside -100..100
    heat = _find(rows, figure='percent_site_energy_savings_by_end_use', column=PCT_ELEC_HEAT)
    assert heat['n'] == 3 and heat['median'] == pytest.approx(-50.0)      # -120 is inside -150..100
    assert heat['label'] == 'Electricity Heating'
    q1, q3 = np.percentile([-50.0, -50.0, -120.0], [25, 75])
    assert heat['q1'] == pytest.approx(q1) and heat['upper_fence'] == pytest.approx(q3 + 1.5 * (q3 - q1))
    eui = _find(rows, figure='site_eui_savings_by_building_type', category='SmallOffice')
    assert eui['units'] == 'kwh_per_ft2' and eui['n'] == 2


def _read_csv(path):
    with open(path, newline='', encoding='utf-8') as f:
        return list(csv.DictReader(f))


def test_export_writes_the_contract(tmp_path):
    out = mda.export(_frame(), 1, 0, 'Test Measure', tmp_path / 'up01_Test Measure', figures=False,
                     run={'dataset_name': 'ComStock synthetic', 'run_dir': str(tmp_path)})
    assert out == tmp_path / 'up01_Test Measure' / 'doc_assets'
    assert not (tmp_path / 'up01_Test Measure' / 'doc_assets.partial').exists()
    m = json.loads((out / 'manifest.json').read_text(encoding='utf-8'))
    assert m['schema'] == mda.SCHEMA
    assert m['upgrade'] == {'id': 1, 'name': 'Test Measure', 'baseline_id': 0, 'measure_dir': 'up01_Test Measure'}
    assert m['generator']['package'] == 'comstockpostproc'
    assert m['data']['models'] == 3 and m['data']['rows'] == {'baseline': 4, 'upgrade': 4}
    assert all(c['ok'] for c in m['checks']), m['checks']
    paths = [f['path'] for f in m['files']]
    assert paths == ['tables/annual_totals.csv', 'tables/applicability.csv',
                     'tables/savings_by_group.csv', 'tables/savings_distributions.csv']
    for f in m['files']:
        assert mda.sha256_file(out / f['path']) == f['sha256']
    fields = {'annual_totals': mda.TOTALS_FIELDS, 'applicability': mda.APPLICABILITY_FIELDS,
              'savings_by_group': mda.GROUP_FIELDS, 'savings_distributions': mda.DISTRIBUTION_FIELDS}
    for name, expected in fields.items():
        with open(out / 'tables' / f'{name}.csv', newline='', encoding='utf-8') as fh:
            assert next(csv.reader(fh)) == expected
    totals = _read_csv(out / 'tables' / 'annual_totals.csv')
    heat = [r for r in totals if r['population'] == 'stock' and r['end_use'] == 'heating' and r['fuel'] == 'electricity']
    assert float(heat[0]['baseline']) == 10.0
    pv_free = [r for r in totals if r['percent_savings'] == '']
    assert all(float(r['baseline']) == 0 for r in pv_free)  # blank only where the baseline is 0


def test_export_replaces_and_never_leaves_partial_or_stale(tmp_path, monkeypatch):
    measure_dir = tmp_path / 'up01_x'
    mda.export(_frame(), 1, 0, 'Test Measure', measure_dir, figures=False)
    (measure_dir / 'doc_assets' / 'stale.txt').write_text('old')
    mda.export(_frame(), 1, 0, 'Test Measure', measure_dir, figures=False)
    assert not (measure_dir / 'doc_assets' / 'stale.txt').exists()

    def boom(*a, **k):
        raise RuntimeError('boom')
    monkeypatch.setattr(mda, 'savings_by_group', boom)
    with pytest.raises(RuntimeError):
        mda.export(_frame(), 1, 0, 'Test Measure', measure_dir, figures=False)
    assert not (measure_dir / 'doc_assets').exists()
    assert not (measure_dir / 'doc_assets.partial').exists()


def test_normalize_figure(tmp_path):
    from PIL import Image
    big = tmp_path / 'big.png'
    Image.new('RGBA', (4000, 2000), (255, 0, 0, 128)).save(big)
    info = mda.normalize_figure(big, tmp_path / 'big_out.png')
    assert (info['width_px'], info['height_px'], info['dpi'], info['width_in']) == (1950, 975, 300, 6.5)
    with Image.open(tmp_path / 'big_out.png') as im:
        assert im.mode == 'RGB' and round(im.info['dpi'][0]) == 300
    small = tmp_path / 'small.png'
    Image.new('RGB', (1000, 500), 'white').save(small)
    info = mda.normalize_figure(small, tmp_path / 'small_out.png')
    assert info['width_px'] == 1000 and info['width_in'] == pytest.approx(6.5, abs=0.01)
    tall = tmp_path / 'tall.png'
    Image.new('RGB', (2000, 4000), 'white').save(tall)
    info = mda.normalize_figure(tall, tmp_path / 'tall_out.png')
    assert info['height_in'] == pytest.approx(7.5, abs=0.01) and info['width_px'] < 1950


def test_measure_dir_name_matches_the_comparison():
    assert mda.measure_dir_name(2, 'std_perf_g30f') == 'up02_std_perf_g30f'
    assert mda.measure_dir_name(12, 'a_very_long_upgrade_name') == 'up12_a_very_long_upg'


def test_comparison_writes_doc_assets_when_asked(monkeypatch, tmp_path):
    import comstockpostproc.comstock_measure_comparison as cmc

    dataset = 'ComStock pytest_doc_assets'
    out_root = Path(cmc.__file__).resolve().parent.parent / 'output' / dataset
    calls = []
    real_export = mda.export

    def export_tables_only(*args, **kwargs):
        calls.append(kwargs)
        kwargs['figures'] = False
        return real_export(*args, **kwargs)

    monkeypatch.setattr(mda, 'export', export_tables_only)
    lf = _frame()
    fake = SimpleNamespace(data=lf, plotting_data=lf, include_upgrades=True, upgrade_ids_for_comparison={},
                           dataset_name=dataset, comstock_run_name='pytest', athena_table_name=None,
                           s3_base_dir=None, output_dir={'fs': LocalFileSystem(), 'fs_path': str(tmp_path)})
    try:
        cmc.ComStockMeasureComparison(fake, timeseries_locations_to_plot={}, make_comparison_plots=False,
                                      make_timeseries_plots=False, export_measure_doc_assets=True)
        assert len(calls) == 1 and calls[0]['plotter'] is not None
        manifest = json.loads((out_root / 'measure_runs' / 'up01_Test Measure' / 'doc_assets' / 'manifest.json')
                              .read_text(encoding='utf-8'))
        assert manifest['run']['dataset_name'] == dataset and manifest['run']['run_dir'] == str(tmp_path.resolve())
        calls.clear()
        cmc.ComStockMeasureComparison(fake, timeseries_locations_to_plot={}, make_comparison_plots=False,
                                      make_timeseries_plots=False)
        assert calls == []  # off by default
    finally:
        shutil.rmtree(out_root, ignore_errors=True)


def _plot_frame():
    """Every column the annual energy and utility bill figures read."""
    L = LazyFramePlotter()
    rng = np.random.default_rng(0)
    numeric = [c for c in dict.fromkeys(L.WTD_COLUMNS_ANN_ENDUSE + L.WTD_COLUMNS_ANN_PV + L.WTD_COLUMNS_SUMMARIZE
                                        + L.WTD_UTILITY_COLUMNS) if c.startswith('calc.')]
    rows = []
    for upgrade, name in ((0, 'Baseline'), (1, 'Test Measure')):
        for bldg in range(1, 7):
            row = {'upgrade': upgrade, 'in.upgrade_name': name, 'bldg_id': bldg, 'applicability': bldg % 2 == 0 or upgrade == 0,
                   'weight': 10.0, 'in.census_division_name': 'Mountain', 'in.comstock_building_type': 'SmallOffice',
                   'in.vintage': '1980 to 1989'}
            row.update({c: float(rng.uniform(1, 5)) * (0.8 if upgrade else 1.0) for c in numeric})
            rows.append(row)
    return pl.DataFrame(rows).lazy()


@pytest.mark.skipif(importlib.util.find_spec('kaleido') is None, reason='plotly image export needs kaleido')
def test_render_figures_at_document_size(tmp_path):
    names = ['ann_energy_by_enduse_and_fuel_stock', 'annual_utility_bills_by_fuel']
    entries, problems = mda.render_figures(mda.DocAssetsPlotter(), _plot_frame(), 'Test Measure', tmp_path, names=names)
    assert problems == []
    assert [e['path'] for e in entries] == [f'figures/{n}.png' for n in names]
    for e in entries:
        assert (tmp_path / Path(e['path']).name).is_file()
        assert e['width_px'] == 1950 and e['dpi'] == 300 and e['height_in'] <= 7.5
