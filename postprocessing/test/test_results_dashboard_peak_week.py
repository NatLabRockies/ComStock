# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The peak week by season. No Athena.

The peak-week selection is checked on a synthetic
2018 whose answers are known by construction: where each scenario peaks, which
calendar week that falls in, and what the coincident change is.
"""

import json

import numpy as np
import pandas as pd
import pytest

from comstockpostproc.results_dashboard import dashboard, measures



# --------------------------------------------------------------- the clock

def test_fold_to_year_puts_the_wrapped_hour_on_31_december():
    # A Central building's last local hour of 2018 arrives as 2017-12-31 23:00
    # once the published EST stamps are shifted back an hour.
    raw = pd.Series(["2017-12-31 23:00", "2018-01-01 00:00", "2018-12-31 22:00"])
    out = measures.fold_to_year(raw)
    assert list(out.dt.strftime("%Y-%m-%d %H:%M")) == [
        "2018-12-31 23:00", "2018-01-01 00:00", "2018-12-31 22:00"]


def test_crawled_hours_pass_through_the_fold():
    raw = pd.Series(pd.date_range("2018-01-01", periods=48, freq="h"))
    assert measures.fold_to_year(raw).equals(raw)


# --------------------------------------------------------------- peak weeks

HOURS = pd.date_range("2018-01-01 00:00", "2018-12-31 23:00", freq="h")


def _year(base, bumps=()):
    s = pd.Series(float(base), index=HOURS)
    for t, v in bumps:
        s[pd.Timestamp(t)] = float(v)
    return s


def _hourly():
    """Stock baseline 1000, measures 4 and 5 over 400 kW of applicable baseline.

    Winter: measure 4 spikes to 1400 on Tue 2 Jan 07:00 (whole stock 2000) and
    measure 5 to 1300 on Wed 14 Feb 08:00 (whole stock 1900); the stock
    baseline's own winter high is 1100 on Fri 5 Jan 18:00.
    Summer: the baseline sets the peak, 1500 on Tue 17 Jul 15:00.
    Shoulder: the baseline again, 1200 on Wed 3 Oct 12:00.
    """
    series = {
        "0": _year(1000, [("2018-01-05 18:00", 1100), ("2018-07-17 15:00", 1500),
                          ("2018-10-03 12:00", 1200)]),
        "base_4": _year(400, [("2018-07-17 15:00", 600)]),
        "4": _year(380, [("2018-01-02 07:00", 1400), ("2018-07-17 15:00", 500)]),
        "base_5": _year(400),
        "5": _year(390, [("2018-02-14 08:00", 1300)]),
    }
    parts = []
    for up, s in series.items():
        parts.append(pd.DataFrame({"upgrade": up, "hour_ts": s.index, "elec_kwh": s.to_numpy(),
                                   "gas_kwh": 0.5 * s.to_numpy(), "heating": 0.1 * s.to_numpy(),
                                   "fans": 0.05 * s.to_numpy(), "sqft_weighted": 1e6}))
    return pd.concat(parts, ignore_index=True)


def _week(weeks, basis, anchor, season):
    w = weeks[(weeks["basis"] == basis) & (weeks["anchor"] == anchor) & (weeks["season"] == season)]
    return w["week_start"].iloc[0], w


def test_whole_stock_week_is_set_by_the_highest_hour_across_scenarios():
    weeks, _ = measures.peak_weeks(_hourly(), ["4", "5"])
    start, w = _week(weeks, "stock", "all", "Winter")
    # measure 4's whole-stock 2000 beats measure 5's 1900 and the baseline's 1100
    assert start == "2018-01-01"
    assert w["set_by"].iloc[0] == "stock:4" and w["set_at"].iloc[0] == "2018-01-02 07:00"
    assert _week(weeks, "stock", "all", "Summer")[0] == "2018-07-16"      # baseline sets it
    assert _week(weeks, "stock", "all", "Shoulder")[0] == "2018-10-01"
    # every scenario the page needs to re-base the measures is in the week
    assert set(w["upgrade"]) == {"0", "4", "base_4", "5", "base_5"}


def test_own_basis_week_follows_each_measure_and_its_applicable_baseline():
    weeks, _ = measures.peak_weeks(_hourly(), ["4", "5"])
    assert _week(weeks, "own", "4", "Winter")[0] == "2018-01-01"
    assert _week(weeks, "own", "5", "Winter")[0] == "2018-02-12"           # its own spike
    _start, w5 = _week(weeks, "own", "5", "Winter")
    assert set(w5["upgrade"]) == {"5", "base_5"}


def test_a_week_is_monday_to_sunday_with_its_hour_of_week():
    weeks, _ = measures.peak_weeks(_hourly(), ["4", "5"])
    _start, w = _week(weeks, "stock", "all", "Summer")
    base = w[w["upgrade"] == "0"]
    assert len(base) == 168
    assert base["how"].min() == 0 and base["how"].max() == 167
    assert base["hour_ts"].iloc[0] == "2018-07-16 00:00"                    # a Monday
    assert pd.Timestamp(base["hour_ts"].iloc[0]).weekday() == 0
    assert "raw_heating" in w.columns and "heating" not in w.columns


def test_week_rows_are_in_time_order_whatever_order_athena_returns():
    # a GROUP BY comes back unordered; the CSV is read by people making figures
    weeks, _ = measures.peak_weeks(_hourly().sample(frac=1.0, random_state=0), ["4", "5"])
    _start, w = _week(weeks, "stock", "all", "Summer")
    assert w[w["upgrade"] == "0"]["how"].tolist() == list(range(168))


def test_31_december_is_a_week_of_its_own():
    h = _hourly()
    late = (h["upgrade"] == "4") & (h["hour_ts"] == pd.Timestamp("2018-12-31 18:00"))
    h.loc[late, "elec_kwh"] = 5000.0
    weeks, _ = measures.peak_weeks(h, ["4", "5"])
    start, w = _week(weeks, "stock", "all", "Winter")
    assert start == "2018-12-31"
    assert len(w[w["upgrade"] == "0"]) == 24


def test_peaks_carry_peak_to_peak_and_coincident_change():
    _weeks, peaks = measures.peak_weeks(_hourly(), ["4", "5"])
    p = peaks[(peaks["basis"] == "stock") & (peaks["season"] == "Winter")
              & (peaks["metric"] == "electricity")].set_index("series")
    assert p.loc["0", "peak_mw"] == pytest.approx(1.1)
    assert p.loc["0", "peak_hour"] == "2018-01-05 18:00"
    assert p.loc["stock:4", "peak_mw"] == pytest.approx(2.0)
    assert p.loc["stock:4", "change_mw"] == pytest.approx(0.9)
    assert p.loc["stock:4", "change_pct"] == pytest.approx(100 * 0.9 / 1.1)
    # at the baseline's own peak hour measure 4 is 1100 + 380 - 400 = 1080
    assert p.loc["stock:4", "at_ref_peak_mw"] == pytest.approx(1.08)
    assert p.loc["stock:4", "coincident_change_mw"] == pytest.approx(-0.02)
    assert set(peaks["metric"]) == {"electricity", "natural_gas"}


def test_a_duplicated_hour_fails_rather_than_doubling_a_peak():
    h = _hourly()
    with pytest.raises(ValueError):
        measures.peak_weeks(pd.concat([h, h.iloc[:1]], ignore_index=True), ["4", "5"])


def test_a_measure_without_hourly_rows_is_left_out():
    h = _hourly()
    weeks, peaks = measures.peak_weeks(h[~h["upgrade"].isin(["5", "base_5"])], ["4", "5"])
    assert "5" not in set(weeks["anchor"]) and "stock:5" not in set(peaks["series"])


# ----------------------------------------------------------------- payload

def test_peak_frames_reach_the_payload_and_are_not_read_as_locations(tmp_path):
    m = tmp_path / "metrics"
    m.mkdir()
    (tmp_path / "manifest.json").write_text(json.dumps(
        {"runs": [{"key": "r3", "md_table": "rel_md"}], "primary_run": "r3"}))
    (tmp_path / "coverage.json").write_text(json.dumps({}))
    pd.DataFrame({"upgrade": ["4"], "upgrade_name": ["HP RTU"]}).to_csv(
        m / "measures_summary.csv", index=False)
    pd.DataFrame({"upgrade": ["0"], "season": ["Winter"], "day_type": ["Weekday"],
                  "hour": [0], "elec_kwh": [1.0]}).to_csv(m / "measures_ts_Minnesota.csv",
                                                           index=False)
    weeks, peaks = measures.peak_weeks(_hourly(), ["4"])
    weeks.to_csv(m / "measures_peakweek_Minnesota.csv", index=False)
    peaks.to_csv(m / "measures_peaks_Minnesota.csv", index=False)

    meas = dashboard.build_payload(tmp_path)["measures"]
    assert list(meas["ts"]) == ["Minnesota"]
    packed = meas["peakWeek"]["Minnesota"]
    assert packed["n"] == len(weeks)
    ups = packed["dict"]["upgrade"]
    assert "4" in ups and "4.0" not in ups and "base_4" in ups
    assert {r["upgrade"] for r in meas["peaks"]["Minnesota"]} >= {"4"}
    assert all(r["anchor"] in ("all", "4") for r in meas["peaks"]["Minnesota"])
