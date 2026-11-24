import importlib.util
from pathlib import Path

import pandas as pd
import pytest
import yaml


SCRIPT = Path(__file__).with_name('plot_integration_branch_comparison.py')
SPEC = importlib.util.spec_from_file_location('plot_integration_branch_comparison', SCRIPT)
PLOTTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLOTTER)

METRICS = [{'plot': 'total', 'label': 'Energy', 'column': 'energy', 'units': 'TBtu'}]
MATCH_COLUMNS = ['bldg_id', 'in.state']
BUILDING_TYPE = 'in.comstock_building_type'


def write_results(directory, rows):
    directory.mkdir()
    pd.DataFrame(rows, columns=['in.upgrade_name', *MATCH_COLUMNS, BUILDING_TYPE, 'energy']).to_csv(
        directory / 'results_up00.csv', index=False,
    )


def load(directory):
    return PLOTTER.load_results(directory, METRICS, MATCH_COLUMNS, BUILDING_TYPE)


def test_mock_base_results_adds_reproducible_per_record_noise(tmp_path):
    write_results(tmp_path / 'feature', [
        ['Baseline', 1, 'CO', 'Office', 100.0],
        ['Baseline', 1, 'WY', 'Office', 100.0],
    ])
    feature = load(tmp_path / 'feature')
    first = PLOTTER.mock_base_results(feature, METRICS, 0.05, 12)
    second = PLOTTER.mock_base_results(feature, METRICS, 0.05, 12)

    pd.testing.assert_frame_equal(first, second)
    assert first['energy'].tolist() != feature['energy'].tolist()
    assert first.loc[0, 'energy'] != first.loc[1, 'energy']


def test_comparison_matches_building_and_state_and_reports_unmatched(tmp_path, capsys):
    write_results(tmp_path / 'feature', [
        ['Baseline', 1, 'CO', 'Office', 10.0],
        ['Baseline', 1, 'WY', 'Office', 20.0],
        ['Baseline', 2, 'CO', 'Office', 30.0],
    ])
    write_results(tmp_path / 'base', [
        ['Baseline', 1, 'WY', 'Office', 22.0],
        ['Baseline', 1, 'CO', 'Office', 11.0],
        ['Baseline', 3, 'CO', 'Office', 40.0],
    ])
    comparison = PLOTTER.compare_results(load(tmp_path / 'feature'), load(tmp_path / 'base'),
                                         METRICS, MATCH_COLUMNS, BUILDING_TYPE, False)
    matched = comparison[comparison['match_status'] == 'both'].set_index('in.state')
    assert matched.loc['CO', 'base_value'] == 11.0
    assert matched.loc['WY', 'base_value'] == 22.0
    assert set(comparison['match_status']) == {'both', 'left_only', 'right_only'}
    assert 'feature only: 1, base only: 1' in capsys.readouterr().out

    figure = PLOTTER.make_figure(comparison, METRICS, 'Total', MATCH_COLUMNS, 'Feature', 'Base', False)
    markers = [trace for trace in figure.data if trace.mode == 'markers']
    assert len(markers) == 1
    assert list(markers[0].x) == [11.0, 22.0]
    assert list(markers[0].y) == [10.0, 20.0]
    assert {trace.name for trace in figure.data if trace.mode == 'lines'} == {'Equal', '-10%', '+10%'}


def test_figure_groups_metrics_and_building_types_and_colors_upgrades():
    rows = []
    for metric in ['Energy', 'Heating']:
        for building_type in ['Office', 'Retail']:
            for upgrade in ['Baseline', 'Upgrade']:
                rows.append({
                    'in.upgrade_name': upgrade, 'bldg_id': '1', 'in.state': 'CO',
                    'feature_building_type': building_type, 'metric': metric,
                    'base_value': 1.0, 'feature_value': 2.0, 'match_status': 'both',
                })
    metrics = [METRICS[0], {'plot': 'total', 'label': 'Heating', 'column': 'heating', 'units': 'TBtu'}]
    figure = PLOTTER.make_figure(pd.DataFrame(rows), metrics, 'Total', MATCH_COLUMNS, 'Feature', 'Base', False)
    markers = [trace for trace in figure.data if trace.mode == 'markers']
    assert [(trace.name, trace.xaxis) for trace in markers] == [
        ('Baseline', 'x'), ('Upgrade', 'x'), ('Baseline', 'x2'), ('Upgrade', 'x2'),
        ('Baseline', 'x3'), ('Upgrade', 'x3'), ('Baseline', 'x4'), ('Upgrade', 'x4'),
    ]
    assert markers[0].marker.color == markers[2].marker.color == markers[4].marker.color
    assert markers[0].marker.color != markers[1].marker.color
    assert [annotation.text for annotation in figure.layout.annotations] == [
        '<b>Energy</b> - Office', '<b>Energy</b> - Retail',
        '<b>Heating</b> - Office', '<b>Heating</b> - Retail',
    ]
    for number in range(1, 5):
        suffix = '' if number == 1 else str(number)
        x_axis = figure.layout[f'xaxis{suffix}']
        y_axis = figure.layout[f'yaxis{suffix}']
        assert y_axis.scaleanchor == f'x{suffix}'
        assert y_axis.scaleratio == 1
        assert x_axis.constrain == y_axis.constrain == 'domain'
        assert x_axis.range == y_axis.range


def test_load_rejects_duplicate_keys_and_missing_metric(tmp_path):
    write_results(tmp_path / 'duplicate', [
        ['Baseline', 1, 'CO', 'Office', 10.0],
        ['Baseline', 1, 'CO', 'Office', 20.0],
    ])
    with pytest.raises(ValueError, match='duplicate match keys'):
        load(tmp_path / 'duplicate')

    with pytest.raises(ValueError, match='missing required columns'):
        PLOTTER.load_results(tmp_path / 'duplicate', [{'column': 'missing'}], MATCH_COLUMNS, BUILDING_TYPE)


def test_comparison_rejects_no_matching_records(tmp_path):
    write_results(tmp_path / 'feature', [['Baseline', 1, 'CO', 'Office', 10.0]])
    write_results(tmp_path / 'base', [['Baseline', 1, 'WY', 'Office', 11.0]])
    with pytest.raises(ValueError, match='No matching building and upgrade results'):
        PLOTTER.compare_results(load(tmp_path / 'feature'), load(tmp_path / 'base'),
                                METRICS, MATCH_COLUMNS, BUILDING_TYPE, False)


@pytest.mark.parametrize('use_real_base', [False, True])
def test_run_writes_scatterplot_and_comparison(tmp_path, use_real_base):
    feature_dir = tmp_path / 'feature'
    base_dir = tmp_path / 'base'
    output_dir = tmp_path / 'plots'
    write_results(feature_dir, [['Baseline', 1, 'CO', 'Office', 4.0]])
    config = {
        'feature_results_dir': str(feature_dir),
        'output_dir': str(output_dir),
        'feature_label': 'Feature',
        'base_label': 'Base',
        'match_columns': MATCH_COLUMNS,
        'building_type_column': BUILDING_TYPE,
        'mock_base_noise_fraction': 0.05,
        'mock_base_seed': 12,
        'plots': {
            'total': {'title': 'Total', 'metrics': METRICS},
            'fuels': {'title': 'Fuels', 'metrics': METRICS},
        },
    }
    if use_real_base:
        write_results(base_dir, [['Baseline', 1, 'CO', 'Office', 6.0]])
        config['base_results_dir'] = str(base_dir)
    config_path = tmp_path / 'plot.yml'
    config_path.write_text(yaml.safe_dump(config), encoding='utf-8')

    PLOTTER.run(config_path)

    for name in ['total', 'fuels']:
        html = (output_dir / f'{name}.html').read_text(encoding='utf-8')
        assert 'scatter' in html
        assert ('mocked base results' in html) is not use_real_base
    comparison = pd.read_csv(output_dir / 'branch_comparison.csv')
    assert set(comparison['plot']) == {'total', 'fuels'}
    assert bool(comparison.loc[0, 'base_is_mocked']) is not use_real_base
    assert comparison.loc[0, 'feature_value'] == 4.0
    if use_real_base:
        assert comparison.loc[0, 'base_value'] == 6.0
    else:
        assert comparison.loc[0, 'base_value'] != 4.0
