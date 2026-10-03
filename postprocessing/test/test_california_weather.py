# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Clocks, station assignment and the SDG&E 2025 -> 2018 weather normalization. No I/O."""

import datetime as dt

import numpy as np
import polars as pl
import pytest

from comstockpostproc.california import weather as W

SEASONS = {"Summer": [6, 7, 8, 9], "Winter": [11, 12, 1, 2], "Shoulder": [3, 4, 5, 10]}


def _hours(year):
    return pl.datetime_range(dt.datetime(year, 1, 1), dt.datetime(year, 12, 31, 23), "1h",
                             time_unit="us", eager=True)


def test_dst_bounds_follow_the_us_rules():
    s, e = W.dst_bounds_clock(2018)
    assert (str(s), str(e)) == ("2018-03-11 02:00:00", "2018-11-04 02:00:00")
    s, e = W.dst_bounds_clock(2025)
    assert (str(s), str(e)) == ("2025-03-09 02:00:00", "2025-11-02 02:00:00")


def test_clock_and_pst_round_trip_outside_the_ambiguous_hour():
    pst = _hours(2018)
    clock = W.pst_to_clock(pst)
    back = W.clock_to_pst(clock)
    ambiguous = clock == dt.datetime(2018, 11, 4, 1)          # occurs twice on the clock
    assert (back.filter(~ambiguous) == pst.filter(~ambiguous)).all()
    shift_h = (clock - pst).dt.total_hours()
    assert shift_h.is_in([0, 1]).all()
    assert shift_h.sum() == 5711                               # daylight hours in 2018


def test_dst_artefact_expressions():
    c = pl.Series("c", [dt.datetime(2025, 3, 9, 2), dt.datetime(2025, 11, 2, 1),
                        dt.datetime(2025, 7, 1, 2)]).cast(pl.Datetime("us"))
    out = pl.select(non=W.nonexistent_hour_expr(pl.lit(c)), merged=W.merged_hour_expr(pl.lit(c)))
    assert out["non"].to_list() == [True, False, False]
    assert out["merged"].to_list() == [False, True, False]


def _stations():
    return pl.DataFrame({"wmo": ["722900", "722907", "745056"], "name": ["IAP", "Gillespie", "Ramona"],
                         "lat": [32.734, 32.826, 33.038], "lon": [-117.183, -116.973, -116.916],
                         "ctz": [7, 10, 10]})


def test_nearest_station():
    st = _stations()
    assert W.nearest_station(32.73, -117.18, st)["wmo"] == "722900"     # Lindbergh Field -> CTZ 7
    assert W.nearest_station(32.83, -116.97, st)["ctz"] == 10           # Gillespie -> CTZ 10
    assert W.nearest_station(33.05, -116.90, st)["name"] == "Ramona"
    d = W.nearest_station(32.734, -117.183, st)["distance_km"]
    assert d == pytest.approx(0.0, abs=1e-9)


def test_assign_and_rank_keep_point_order():
    pts = pl.DataFrame({"gp": ["b", "a"], "latitude": [33.05, 32.73], "longitude": [-116.90, -117.18]})
    a = W.assign_stations(pts, _stations())
    assert a["gp"].to_list() == ["b", "a"]
    assert a["wmo"].to_list() == ["745056", "722900"] and a["station_ctz"].to_list() == [10, 7]
    k = W.nearest_stations(pts, _stations(), k=2)
    assert k["gp"].to_list() == ["b", "b", "a", "a"] and k["rank"].to_list() == [1, 2, 1, 2]


def test_station_year_consistency_excludes_the_outlier():
    m = pl.DataFrame({"wmo": list("abcde"), "mean_2018_c": [18.1, 18.0, 17.2, 19.1, 16.7],
                      "mean_2025_c": [17.2, 17.6, 16.5, 16.5, 16.0]})
    out = W.station_year_consistency(m)
    assert out.filter(pl.col("excluded"))["wmo"].to_list() == ["d"]   # +2.6 C vs a median of +0.7 C
    reason = out.filter(pl.col("wmo") == "d")["reason"][0]
    assert reason.startswith("2018-minus-2025 mean temperature +2.6 C against a median of +0.7 C")
    assert out.filter(pl.col("wmo") == "a")["reason"][0] == ""


def test_bin_edges_merge_sparse_bins_and_components_sum_to_temperature():
    t = np.r_[np.full(100, 60.0), np.full(5, 95.0), np.full(100, 70.0)]
    edges = W.fit_bin_edges(t)
    assert 90.0 not in edges                                            # 5 points above 90 F
    comps = W.temp_components(t, edges)
    assert np.allclose(comps.sum(axis=1), t)
    X = W.towt_design(np.zeros(len(t), int), t, edges)
    assert X.shape == (len(t), 168 + len(edges) + 1)


def _wx(year, temp_c: pl.Expr):
    return _hours(year).alias("timestamp_pst").to_frame().with_columns(drybulb_c=temp_c)


def test_towt_recovers_a_planted_response_and_round_trips():
    rng = np.random.default_rng(1)
    ts = pl.col("timestamp_pst")
    temp = (15 + 10 * (2 * np.pi * ts.dt.ordinal_day() / 365).sin()
            + 4 * (2 * np.pi * ts.dt.hour() / 24).sin())
    occ = lambda c: pl.when((c.dt.weekday() <= 5) & c.dt.hour().is_between(8, 17)).then(5.0).otherwise(2.0)  # noqa: E731
    wx25 = _wx(2025, temp)
    obs = (wx25.with_columns(clock=W.pst_to_clock_expr(ts))
           .with_columns(value=occ(pl.col("clock"))
                         + 0.08 * (W.c_to_f_expr(pl.col("drybulb_c")) - 65).clip(lower_bound=0)
                         + pl.Series(rng.normal(0, 0.01, 8760)))
           .select("clock", "value"))
    # identical weather in the target year: the prediction must reproduce the planted model
    wx18 = wx25.with_columns(ts.dt.offset_by("-7y"))
    pred, stats = W.normalize_hourly(obs, wx25, wx18, 2018, SEASONS)
    assert pred.height == 8760 and pred["timestamp_pst"].is_unique().all()
    assert (stats["cvrmse_pct"] < 2).all()
    expect = (pred.join(wx18, on="timestamp_pst")
              .with_columns(clock=W.pst_to_clock_expr(ts))
              .with_columns(e=occ(pl.col("clock"))
                            + 0.08 * (W.c_to_f_expr(pl.col("drybulb_c")) - 65).clip(lower_bound=0)))
    assert (expect["value"] - expect["e"]).abs().max() < 0.1
    ok, cv = W.annual_fit_ok(stats)
    assert ok and cv < 2


def test_gas_change_point_found_and_never_negative():
    days = pl.date_range(dt.date(2025, 1, 1), dt.date(2025, 12, 31), "1d", eager=True)
    tf = 60 + 15 * np.cos(2 * np.pi * (days.dt.ordinal_day().to_numpy() - 200) / 365)
    obs = pl.DataFrame({"date": days.cast(pl.Datetime("us")),
                        "value": 2.0 + 0.5 * np.maximum(58 - tf, 0)})
    wx = (pl.DataFrame({"date": days, "tf": tf})
          .join(pl.DataFrame({"h": list(range(24))}), how="cross")
          .select((pl.col("date").cast(pl.Datetime("us")) + pl.duration(hours=pl.col("h")))
                  .alias("timestamp_pst"), ((pl.col("tf") - 32) * 5 / 9).alias("drybulb_c")))
    wx18 = wx.with_columns(pl.col("timestamp_pst").dt.offset_by("-7y"))
    pred, stats = W.normalize_daily_gas(obs, wx, wx18, 2018, SEASONS)
    win = stats.filter(pl.col("season") == "Winter").row(0, named=True)
    assert win["balance_point_f"] == pytest.approx(58, abs=1)
    assert win["heating_slope"] == pytest.approx(0.5, rel=0.05)
    assert (pred["value"] >= 0).all() and pred.height == 365
