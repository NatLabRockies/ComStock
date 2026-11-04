# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Run order on the page follows the driver's list. No Athena.

The manifest keeps the run under review first (the lookups rely on it); the page
draws the runs in the order the driver listed them, after CBECS.
"""

from types import SimpleNamespace

from comstockpostproc.results_dashboard import assessment


def _runs(*keys):
    return [SimpleNamespace(key=k) for k in keys]


def test_driver_order_is_kept_and_the_run_under_review_is_not_moved():
    runs = _runs("review", "a", "b")                 # manifest order: review first
    assert assessment._display_order(["a", "review", "b"], runs) == ["a", "review", "b"]
    assert assessment._display_order(["b", "a", "review"], runs) == ["b", "a", "review"]


def test_no_order_falls_back_to_arrival_order():
    runs = _runs("review", "a", "b")
    assert assessment._display_order(None, runs) == ["review", "a", "b"]
    assert assessment._display_order([], runs) == ["review", "a", "b"]


def test_a_dropped_or_misnamed_run_is_left_out_and_an_unnamed_one_kept():
    runs = _runs("review", "a", "b")
    # 'gone' was dropped (missing tables); 'b' was not named: it goes at the end
    assert assessment._display_order(["a", "gone", "review"], runs) == ["a", "review", "b"]
    # a repeated key counts once
    assert assessment._display_order(["a", "a", "review", "b"], runs) == ["a", "review", "b"]
