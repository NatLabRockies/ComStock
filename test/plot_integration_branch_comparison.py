#!/usr/bin/env python3
"""Compare published integration results by building and upgrade."""

import argparse
import math
from pathlib import Path

import numpy as np
import pandas as pd
import plotly.graph_objects as go
import yaml
from plotly.colors import qualitative
from plotly.subplots import make_subplots


def load_results(results_dir, metrics, match_columns, building_type_column):
    results_dir = Path(results_dir)
    result_files = sorted(results_dir.glob('results_up*.csv'))
    if not result_files:
        raise FileNotFoundError(f'No results_up*.csv files found in {results_dir}')

    required = list(dict.fromkeys([
        'in.upgrade_name', *match_columns, building_type_column,
        *(metric['column'] for metric in metrics),
    ]))
    frames = []
    upgrade_names = set()
    for result_file in result_files:
        available = pd.read_csv(result_file, nrows=0).columns
        missing = sorted(set(required) - set(available))
        if missing:
            raise ValueError(f'{result_file} is missing required columns: {missing}')
        frame = pd.read_csv(result_file, usecols=required, dtype={col: 'string' for col in match_columns})
        if frame[['in.upgrade_name', *match_columns, building_type_column]].isna().any().any():
            raise ValueError(f'{result_file} contains missing identifiers or building types')
        names = frame['in.upgrade_name'].unique()
        if len(names) != 1:
            raise ValueError(f'{result_file} must contain exactly one upgrade name; found {names.tolist()}')
        if names[0] in upgrade_names:
            raise ValueError(f'Duplicate upgrade name {names[0]!r} in {results_dir}')
        upgrade_names.add(names[0])
        if frame.duplicated(match_columns).any():
            raise ValueError(f'{result_file} contains duplicate match keys: {match_columns}')
        for metric in metrics:
            column = metric['column']
            frame[column] = pd.to_numeric(frame[column], errors='raise')
            if frame[column].isna().any() or not np.isfinite(frame[column].to_numpy()).all():
                raise ValueError(f'{result_file} contains missing or non-finite values in {column}')
        frames.append(frame)
    return pd.concat(frames, ignore_index=True)


def mock_base_results(feature, metrics, noise_fraction, seed):
    if not math.isfinite(noise_fraction) or noise_fraction < 0:
        raise ValueError('mock_base_noise_fraction must be a finite non-negative number')
    rng = np.random.default_rng(seed)
    base = feature.copy()
    for column in dict.fromkeys(metric['column'] for metric in metrics):
        base[column] = feature[column] * (1 + rng.normal(0, noise_fraction, len(feature)))
    return base


def compare_results(feature, base, metrics, match_columns, building_type_column, base_is_mocked):
    keys = ['in.upgrade_name', *match_columns]
    paired = feature.merge(base, on=keys, how='outer', suffixes=('_feature', '_base'),
                           indicator=True, validate='one_to_one')
    unmatched = paired['_merge'].value_counts()
    if not (paired['_merge'] == 'both').any():
        raise ValueError('No matching building and upgrade results between branches')
    if (paired['_merge'] != 'both').any():
        print(f"Warning: unmatched results (feature only: {unmatched.get('left_only', 0)}, "
              f"base only: {unmatched.get('right_only', 0)}); see comparison CSV.")

    frames = []
    for metric in metrics:
        column = metric['column']
        comparison = paired[keys].copy()
        comparison['feature_building_type'] = paired[f'{building_type_column}_feature']
        comparison['base_building_type'] = paired[f'{building_type_column}_base']
        comparison['plot'] = metric['plot']
        comparison['metric'] = metric['label']
        comparison['feature_value'] = paired[f'{column}_feature']
        comparison['base_value'] = paired[f'{column}_base']
        comparison['match_status'] = paired['_merge'].astype(str)
        comparison['base_is_mocked'] = base_is_mocked
        frames.append(comparison)
    return pd.concat(frames, ignore_index=True)


def make_figure(comparison, metrics, plot_title, match_columns, feature_label, base_label, base_is_mocked):
    matched = comparison[comparison['match_status'] == 'both']
    types = sorted(matched['feature_building_type'].unique())
    upgrades = comparison['in.upgrade_name'].drop_duplicates().tolist()
    colors = {name: qualitative.Dark24[index % len(qualitative.Dark24)] for index, name in enumerate(upgrades)}
    titles = [f'<b>{metric["label"]}</b> - {building_type}' for metric in metrics for building_type in types]
    figure = make_subplots(
        rows=len(metrics), cols=len(types), subplot_titles=titles,
        vertical_spacing=0.15 / max(1, len(metrics) - 1),
        horizontal_spacing=0.08 / max(1, len(types) - 1),
    )
    shown_upgrades = set()
    shown_reference_lines = False

    for row, metric in enumerate(metrics, 1):
        for col, building_type in enumerate(types, 1):
            points = matched[(matched['feature_building_type'] == building_type)
                             & (matched['metric'] == metric['label'])]
            if not points.empty:
                minimum = min(0.0, points['base_value'].min(), points['feature_value'].min())
                maximum = max(0.0, points['base_value'].max(), points['feature_value'].max())
                span = maximum - minimum
                padding = span * 0.1 if span else 1.0
                bounds = [minimum - padding, maximum + padding]
                for factor, name, color, dash in [
                    (1.0, 'Equal', '#526577', 'solid'),
                    (0.9, '-10%', '#9AA9B8', 'dash'),
                    (1.1, '+10%', '#9AA9B8', 'dash'),
                ]:
                    figure.add_trace(go.Scatter(
                        x=bounds, y=[factor * value for value in bounds], mode='lines',
                        name=name, legendgroup=name, showlegend=not shown_reference_lines,
                        line={'color': color, 'dash': dash, 'width': 1.5},
                        legendrank=1000,
                        hoverinfo='skip',
                    ), row=row, col=col)
                shown_reference_lines = True
                figure.update_xaxes(range=bounds, row=row, col=col)
                figure.update_yaxes(range=bounds, row=row, col=col)

            for upgrade, group in points.groupby('in.upgrade_name', sort=False):
                hover = group[match_columns].astype(str).apply(
                    lambda values: ' | '.join(f'{key}: {value}' for key, value in values.items()), axis=1,
                )
                figure.add_trace(go.Scatter(
                    x=group['base_value'], y=group['feature_value'], mode='markers',
                    name=upgrade, legendgroup=upgrade, showlegend=upgrade not in shown_upgrades,
                    legendrank=100,
                    marker={'color': colors[upgrade], 'size': 11, 'opacity': 0.85,
                            'line': {'color': 'white', 'width': 0.8}},
                    text=hover,
                    hovertemplate=(f'%{{text}}<br>{base_label}: %{{x:.4g}} {metric["units"]}'
                                   f'<br>{feature_label}: %{{y:.4g}} {metric["units"]}'
                                   '<extra>%{fullData.name}</extra>'),
                ), row=row, col=col)
                shown_upgrades.add(upgrade)

            axis_number = (row - 1) * len(types) + col
            x_axis = 'x' if axis_number == 1 else f'x{axis_number}'
            figure.update_xaxes(title_text=f'{base_label} ({metric["units"]})', constrain='domain',
                                row=row, col=col)
            figure.update_yaxes(title_text=f'{feature_label} ({metric["units"]})', scaleanchor=x_axis,
                                scaleratio=1, constrain='domain', row=row, col=col)

    title = f'<b>{plot_title}</b><br><sup>{feature_label} vs. {base_label}'
    if base_is_mocked:
        title += ' | mocked base results'
    title += '</sup>'
    figure.update_annotations(font={'size': 17, 'color': '#25364A'})
    figure.update_xaxes(showline=True, linecolor='#C8D2DC', linewidth=1, ticks='outside',
                        tickcolor='#9AA9B8', ticklen=4, gridcolor='#E8EDF2', zeroline=False)
    figure.update_yaxes(showline=True, linecolor='#C8D2DC', linewidth=1, ticks='outside',
                        tickcolor='#9AA9B8', ticklen=4, gridcolor='#E8EDF2', zeroline=False)
    figure.update_layout(
        title={'text': title, 'x': 0.04, 'xanchor': 'left'},
        template='plotly_white',
        font={'family': 'Arial, sans-serif', 'size': 14, 'color': '#25364A'},
        legend={'title': {'text': 'Upgrade / reference'}, 'x': 1.02, 'y': 1, 'yanchor': 'top'},
        margin={'l': 95, 'r': 40, 't': 145, 'b': 65},
        height=610 * len(metrics) + 130, width=650 * len(types) + 310,
    )
    return figure


def run(config_path):
    config = yaml.safe_load(Path(config_path).read_text(encoding='utf-8'))
    repo_root = Path(__file__).resolve().parents[1]
    plots = config['plots']
    metrics = [{**metric, 'plot': name} for name, plot in plots.items() for metric in plot['metrics']]
    match_columns = config['match_columns']
    building_type_column = config['building_type_column']
    feature = load_results(repo_root / config['feature_results_dir'], metrics, match_columns, building_type_column)

    base_results_dir = config.get('base_results_dir')
    if base_results_dir:
        base = load_results(repo_root / base_results_dir, metrics, match_columns, building_type_column)
        base_is_mocked = False
    else:
        base = mock_base_results(feature, metrics, config['mock_base_noise_fraction'], config['mock_base_seed'])
        base_is_mocked = True

    comparison = compare_results(feature, base, metrics, match_columns, building_type_column, base_is_mocked)
    output_dir = repo_root / config['output_dir']
    output_dir.mkdir(parents=True, exist_ok=True)
    for name, plot in plots.items():
        plot_metrics = [metric for metric in metrics if metric['plot'] == name]
        figure = make_figure(comparison[comparison['plot'] == name], plot_metrics, plot['title'], match_columns,
                             config['feature_label'], config['base_label'], base_is_mocked)
        figure.write_html(output_dir / f'{name}.html')
    comparison.to_csv(output_dir / 'branch_comparison.csv', index=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--config',
        type=Path,
        default=Path(__file__).with_name('integration_branch_comparison.yml'),
        help='Path to the YAML plotting configuration',
    )
    arguments = parser.parse_args()
    run(arguments.config)
