# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Which upgrades a ComStock run uses: upgrade_ids_to_skip, and include_upgrades=False, which means
the baseline only, even when measure results from an earlier pass sit in the run's data folder. And
when its cached simulation outputs can stand in for those results (reload_from_cache='auto')."""

import os

import numpy as np

from comstockpostproc.comstock import ComStock


def _run(tmp_path, include_upgrades, skip=()):
    """A ComStock holding only what the upgrade selection reads, with results files for
    the baseline and three measures in its data folder."""
    cs = ComStock.__new__(ComStock)
    cs.data_dir = str(tmp_path)
    cs.include_upgrades = include_upgrades
    cs.upgrade_ids_to_skip = [int(u) for u in skip]
    for up in (0, 1, 2, 12):
        (tmp_path / f'results_up{up:02d}.parquet').write_bytes(b'')
    return cs


def test_with_measures_only_the_skip_list_is_left_out(tmp_path):
    used, left_out = _run(tmp_path, include_upgrades=True, skip=[2]).results_upgrade_ids()
    assert [int(u) for u in used] == [0, 1, 12]
    assert [int(u) for u in left_out] == [2]


def test_without_measures_only_the_baseline_is_used(tmp_path):
    used, left_out = _run(tmp_path, include_upgrades=False).results_upgrade_ids()
    assert [int(u) for u in used] == [0]
    assert [int(u) for u in left_out] == [1, 2, 12]


def test_skips_upgrade_takes_any_integer_type(tmp_path):
    cs = _run(tmp_path, include_upgrades=False)
    assert not cs.skips_upgrade(0) and not cs.skips_upgrade(np.int64(0))
    assert cs.skips_upgrade(1) and cs.skips_upgrade(np.int64(12)) and cs.skips_upgrade('02')
    cs.include_upgrades = True
    assert not cs.skips_upgrade(np.int64(12))


def _cached(tmp_path, upgrades, include_upgrades=True, skip=()):
    """The run above, with cached simulation outputs for `upgrades` written after its results."""
    from fsspec.implementations.local import LocalFileSystem
    (tmp_path / 'data').mkdir(parents=True)
    cs = _run(tmp_path / 'data', include_upgrades, skip)
    out = tmp_path / 'output'
    cs.output_dir = {'fs': LocalFileSystem(), 'fs_path': str(out)}
    cs.upgrade_ids_to_process, _ = cs.results_upgrade_ids()
    for up in upgrades:
        f = out / 'cached_simulation_outputs' / f'upgrade={up}' / f'cached_simulation_outputs_upgrade{up}.parquet'
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(b'')
        later = os.path.getmtime(tmp_path / 'data' / f'results_up{up:02d}.parquet') + 60
        os.utime(f, (later, later))
    return cs


def test_cached_outputs_for_every_upgrade_are_reused(tmp_path):
    reuse, why = _cached(tmp_path, [0, 1, 2, 12]).simulation_outputs_cache()
    assert reuse and why.startswith('found for every upgrade')


def test_a_cache_missing_an_upgrade_is_rebuilt(tmp_path):
    # a pass that died partway, or an upgrade taken off the skip list
    reuse, why = _cached(tmp_path, [0, 1, 12]).simulation_outputs_cache()
    assert not reuse and '[2]' in why


def test_only_the_upgrades_the_run_processes_need_a_cache(tmp_path):
    assert _cached(tmp_path, [0], include_upgrades=False).simulation_outputs_cache()[0]
    assert _cached(tmp_path / 'b', [0, 1, 12], skip=[2]).simulation_outputs_cache()[0]


def test_a_cache_older_than_replaced_results_is_rebuilt(tmp_path):
    cs = _cached(tmp_path, [0, 1, 2, 12])
    newer = os.path.getmtime(tmp_path / 'output' / 'cached_simulation_outputs' / 'upgrade=1'
                             / 'cached_simulation_outputs_upgrade1.parquet') + 60
    os.utime(tmp_path / 'data' / 'results_up01.parquet', (newer, newer))
    reuse, why = cs.simulation_outputs_cache()
    assert not reuse and 'older than the results files of upgrade(s) [1]' in why
