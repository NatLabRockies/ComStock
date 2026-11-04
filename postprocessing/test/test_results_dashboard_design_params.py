# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Design-parameter rules for the results dashboard. No Athena.

Pins the rules the owner set for this tab: no placeholder is averaged as a
value, notes carry no measured percentages, every metric says what it means
when nothing qualifies, and the per-type spread is carried where the table
shows it.
"""

import re

import pandas as pd

from comstockpostproc.results_dashboard import design_params as dp

PCT = re.compile(r"\d+(\.\d+)?\s*%")


def _cols(m):
    return dp._cols_in(m.expr) | dp._cols_in(m.guard) | dp._cols_in(m.weight)


def test_notes_carry_no_measured_percentages_and_docstring_neither():
    for m in dp.METRICS:
        assert not PCT.search(m.note), (m.key, m.note)
        assert not PCT.search(m.absent_note), (m.key, m.absent_note)
    # "100%" in prose about a definition (a CV fan's minimum flow) is a rule, not
    # a measurement; the regex above would flag it, so the notes avoid even that
    # spelling. The module docstring used to quote 68%, 26%, 34%, 72.6%.
    assert not PCT.search(dp.__doc__)


def test_every_metric_has_a_guard_and_the_partial_ones_say_what_absence_means():
    keys = {m.key for m in dp.METRICS}
    # the placeholder-dominated overall pump efficiency is gone, the separable ones exist
    assert "pump_eff" not in keys
    assert {"pump_eff_swh", "pump_eff_hvac_c", "pump_eff_hvac_v", "pump_w_ft2"} <= keys
    # both fan populations are covered
    assert {"fan_wcfm", "zfan_wcfm", "zfan_sp", "zfan_eff"} <= keys
    # a metric whose guard excludes whole building types explains the empty cell
    for k in ("fan_wcfm", "zfan_wcfm", "vav_flow", "clg_sp", "clg_setup", "oa_frac",
              "hw_ft2", "pump_eff_swh", "pump_w_ft2"):
        m = next(m for m in dp.METRICS if m.key == k)
        assert m.absent_note, k


def test_sql_resolves_the_subquery_tokens_against_the_run_table():
    sql = dp.build_params_sql("db.run_md", dp.METRICS, dim=None, base_where="upgrade = 0")
    assert dp.TABLE_TOKEN not in sql and dp.WHERE_TOKEN not in sql
    # the air-loop fan floor is taken from the run's own single-loop buildings
    assert ('(SELECT MIN("out.params.air_system_fan_total_efficiency") FROM db.run_md'
            ' WHERE upgrade = 0 AND "out.params.num_air_loops" = 1') in sql


def test_available_drops_only_the_metrics_whose_columns_are_missing():
    have = set().union(*(_cols(m) for m in dp.METRICS))
    assert {m.key for m in dp.available(have)} == {m.key for m in dp.METRICS}
    without = have - {"out.params.zone_hvac_fan_static_pressure..inwc"}
    keys = {m.key for m in dp.available(without)}
    assert not {"zfan_wcfm", "zfan_sp", "zfan_eff"} & keys
    assert "fan_wcfm" in keys and "pump_w_ft2" in keys


def test_cooling_guards_exclude_the_blend_and_keep_a_flat_schedule():
    clg = next(m for m in dp.METRICS if m.key == "clg_sp")
    setup = next(m for m in dp.METRICS if m.key == "clg_setup")
    assert f"< {dp.COOLING_OFF_C}" in clg.guard
    # a setup of 0 is a result: nothing in the guard asks for max > min
    assert ">" not in setup.guard.replace("> 0", "").replace(">=", "")


def test_rows_keep_the_spread_on_per_type_national_rows_only():
    m = dp.METRICS[0]
    df = pd.DataFrame([{
        "btype": "Hospital", "category": "1990s",
        f"{m.key}__wmean": 1.0, f"{m.key}__p50": 1.0, f"{m.key}__p10": 0.5,
        f"{m.key}__p90": 2.0, f"{m.key}__n": 3, f"{m.key}__wcov": 1.0, f"{m.key}__wall": 2.0,
    }])
    nat = dp.rows_from_result(df, [m], "run", "none", None, by_bt=True)[0]
    assert nat["p10"] == 0.5 and nat["p90"] == 2.0
    assert nat["btype"] == "Hospital" and nat["category"] == "All"
    assert nat["coverage_pct"] == 50.0
    cross = dp.rows_from_result(df, [m], "run", "vintage", "in.vintage", by_bt=True)[0]
    assert "p10" not in cross and cross["category"] == "1990s"
    pooled = dp.rows_from_result(df, [m], "run", "vintage", "in.vintage", by_bt=False)[0]
    assert pooled["p10"] == 0.5 and pooled["btype"] == "All"
