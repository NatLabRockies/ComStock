# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Clock handling, station assignment, and the 2025 -> 2018 weather normalization.

Polars throughout: every per-row rule is an expression (`*_expr` functions), and the
only loops are over GROUPS -- one least-squares fit per profile and season, which
needs its own design matrix -- never over rows.

CLOCKS. The granular profiles are published in local CLOCK time, daylight saving
included (PG&E 2018 has 23 rows on 2018-03-11; SDG&E 2025 zero-fills the hour that
does not exist on 2025-03-09). ComStock's crawled timeseries, every EPW, and every
other leg of the dashboard are in local STANDARD time. Everything here converts to
Pacific standard time (PST) and never the other way.

Converting clock time to PST has a consequence that is easy to get backwards: the
spring-forward date comes out COMPLETE (its missing clock hour 02:00 is simply the
hour PST 02:00 that clock 03:00 maps to), while the fall-back date ends up with one
PST hour MISSING (01:00) and the hour before it carrying the clock hour that was
recorded twice and merged (`merged_hour`). That merged reading is excluded from the
comparison metrics.

NORMALIZATION (SDG&E only, plan §5). SDG&E profiles exist for 2025; ComStock runs
on 2018 weather. Per profile and season a model is fitted to the 2025 series and
evaluated on the 2018 calendar with 2018 weather at the same station:

  electricity, hourly  Time-of-Week-and-Temperature (the form the SDG&E methodology
                       document uses, without its comparison-group terms): 168
                       hour-of-week indicators (from CLOCK time, which is what
                       occupancy follows) plus piecewise-linear temperature
                       components with the CalTRACK bin edges.
  natural gas, daily   day-of-week indicators plus a heating-degree term with a
                       change point chosen from 50-70 F.

Fit statistics are reported per profile and season. A profile whose year-long
CV(RMSE) exceeds MAX_CVRMSE_PCT is not normalized; the dashboard then shows its raw
2025 series and says so.
"""

from __future__ import annotations

import datetime as dt
import logging

import numpy as np
import polars as pl

logger = logging.getLogger(__name__)

TOWT_BIN_EDGES_F = [30.0, 45.0, 55.0, 65.0, 75.0, 90.0]   # CalTRACK hourly
MIN_POINTS_PER_BIN = 20
GAS_BALANCE_POINTS_F = list(range(50, 71))
MAX_CVRMSE_PCT = 25.0
MAX_STATION_DELTA_DEVIATION_C = 1.0
TIME_UNIT = "us"


# ---------------------------------------------------------------------------
# clocks
# ---------------------------------------------------------------------------

def _first_sunday_on_or_after(d: pl.Expr) -> pl.Expr:
    # dt.weekday(): Monday = 1 ... Sunday = 7
    return d + pl.duration(days=(7 - d.dt.weekday()) % 7)


def dst_start_expr(year: pl.Expr) -> pl.Expr:
    """02:00 clock time on the second Sunday of March of `year` (US rules since 2007)."""
    sunday = _first_sunday_on_or_after(pl.date(year, 3, 1)) + pl.duration(days=7)
    return sunday.cast(pl.Datetime(TIME_UNIT)) + pl.duration(hours=2)


def dst_end_expr(year: pl.Expr) -> pl.Expr:
    """02:00 daylight clock time on the first Sunday of November of `year`."""
    sunday = _first_sunday_on_or_after(pl.date(year, 11, 1))
    return sunday.cast(pl.Datetime(TIME_UNIT)) + pl.duration(hours=2)


def dst_bounds_clock(year: int) -> tuple[dt.datetime, dt.datetime]:
    """(start, end) of daylight time in `year` as naive CLOCK datetimes."""
    row = pl.select(start=dst_start_expr(pl.lit(year)), end=dst_end_expr(pl.lit(year))).row(0)
    return row[0], row[1]


def clock_to_pst_expr(clock: pl.Expr) -> pl.Expr:
    """Hour-beginning clock time -> PST. A clock time inside daylight time is one hour
    ahead of standard time. The clock hour 01:00 on the fall-back date happens twice
    and the profiles merge it into one row; it is treated as its first (daylight)
    occurrence."""
    y = clock.dt.year()
    in_dst = (clock >= dst_start_expr(y)) & (clock < dst_end_expr(y))
    return clock - pl.duration(hours=in_dst.cast(pl.Int64))


def pst_to_clock_expr(pst: pl.Expr) -> pl.Expr:
    """PST -> clock time. Daylight time runs from 02:00 PST on the start date to 01:00
    PST on the end date (02:00 daylight)."""
    y = pst.dt.year()
    in_dst = (pst >= dst_start_expr(y)) & (pst < dst_end_expr(y) - pl.duration(hours=1))
    return pst + pl.duration(hours=in_dst.cast(pl.Int64))


def nonexistent_hour_expr(clock: pl.Expr) -> pl.Expr:
    """The spring-forward clock hour that does not exist (02:00 on the start date)."""
    return clock == dst_start_expr(clock.dt.year())


def merged_hour_expr(clock: pl.Expr) -> pl.Expr:
    """The fall-back clock hour that happens twice (01:00 on the end date)."""
    return clock == dst_end_expr(clock.dt.year()) - pl.duration(hours=1)


def clock_to_pst(clock: pl.Series) -> pl.Series:
    return pl.select(clock_to_pst_expr(pl.lit(clock))).to_series().alias(clock.name)


def pst_to_clock(pst: pl.Series) -> pl.Series:
    return pl.select(pst_to_clock_expr(pl.lit(pst))).to_series().alias(pst.name)


def hour_of_week_expr(clock: pl.Expr) -> pl.Expr:
    # weekday() and hour() are Int8: widen before multiplying, or 6 x 24 overflows
    return (clock.dt.weekday().cast(pl.Int32) - 1) * 24 + clock.dt.hour().cast(pl.Int32)


def season_expr(ts: pl.Expr, seasons: dict) -> pl.Expr:
    lookup = {m: s for s, ms in seasons.items() for m in ms}
    return ts.dt.month().replace_strict(lookup, default=None, return_dtype=pl.String)


def c_to_f_expr(c: pl.Expr) -> pl.Expr:
    return c.cast(pl.Float64) * 9.0 / 5.0 + 32.0


def c_to_f(c):
    return np.asarray(c, dtype=float) * 9.0 / 5.0 + 32.0


# ---------------------------------------------------------------------------
# stations
# ---------------------------------------------------------------------------

def haversine_expr(lat1, lon1, lat2, lon2) -> pl.Expr:
    """Great-circle distance in km between column (or literal) expressions."""
    p1, p2 = lat1.radians(), lat2.radians()
    dphi, dlmb = p2 - p1, (lon2 - lon1).radians()
    a = (dphi / 2).sin() ** 2 + p1.cos() * p2.cos() * (dlmb / 2).sin() ** 2
    return 2 * 6371.0 * a.sqrt().arcsin()


def haversine_km(lat1, lon1, lat2, lon2):
    """Numeric great-circle distance (numpy arrays or scalars)."""
    p1, p2 = np.radians(lat1), np.radians(lat2)
    dphi, dlmb = p2 - p1, np.radians(np.asarray(lon2) - np.asarray(lon1))
    a = np.sin(dphi / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dlmb / 2) ** 2
    return 2 * 6371.0 * np.arcsin(np.sqrt(a))


def _with_distance(points: pl.DataFrame, stations: pl.DataFrame) -> pl.DataFrame:
    """Every point x every station with `distance_km`. `points` carries latitude and
    longitude, `stations` lat and lon."""
    return points.join(stations, how="cross").with_columns(
        distance_km=haversine_expr(pl.col("latitude"), pl.col("longitude"),
                                   pl.col("lat"), pl.col("lon")))


def nearest_station(lat: float, lon: float, stations: pl.DataFrame) -> dict:
    """The station nearest a point, as a dict with `distance_km`. `stations` needs
    wmo, name, lat, lon (and ctz, carried through)."""
    if stations.is_empty():
        raise ValueError("no stations to choose from")
    point = pl.DataFrame({"latitude": [float(lat)], "longitude": [float(lon)]})
    return (_with_distance(point, stations).sort("distance_km")
            .drop("latitude", "longitude").row(0, named=True))


def nearest_stations(points: pl.DataFrame, stations: pl.DataFrame, k: int = 1,
                     key: str = "gp") -> pl.DataFrame:
    """The `k` stations nearest each point, `rank` 1..k, points in their own order."""
    if stations.is_empty():
        raise ValueError("no stations to choose from")
    return (_with_distance(points.with_row_index("_point"), stations)
            .with_columns(rank=pl.col("distance_km").rank("ordinal").over("_point"))
            .filter(pl.col("rank") <= k)
            .sort(["_point", "rank"]).drop("_point"))


def assign_stations(centroids: pl.DataFrame, stations: pl.DataFrame) -> pl.DataFrame:
    """gp -> nearest station: gp, latitude, longitude, nearest_station, wmo,
    distance_km, station_ctz."""
    return (nearest_stations(centroids.select("gp", "latitude", "longitude"), stations)
            .select("gp", "latitude", "longitude",
                    pl.col("name").alias("nearest_station"),
                    pl.col("wmo").cast(pl.String),
                    pl.col("distance_km").round(2),
                    pl.col("ctz").cast(pl.Int64, strict=False).alias("station_ctz")))


def _signed(x: pl.Expr) -> pl.Expr:
    """'+2.6' / '-0.1': one decimal with an explicit sign."""
    return pl.when(x < 0).then(pl.lit("-")).otherwise(pl.lit("+")) + x.abs().round(1).cast(pl.String)


def station_year_consistency(means: pl.DataFrame,
                             max_dev_c: float = MAX_STATION_DELTA_DEVIATION_C) -> pl.DataFrame:
    """Reject stations whose year-to-year change disagrees with their neighbours'.

    The normalization reads the DIFFERENCE between a station's 2018 and 2025
    records, so a station whose sensor, siting or source changed between the years
    injects that change straight into every profile assigned to it. Neighbouring
    stations share their weather, so their 2018-minus-2025 mean differences should
    agree; one that departs from the candidates' median by more than `max_dev_c` is
    excluded. Measured 2026-10-02: Miramar MCAS reads +2.6 C (2018 minus 2025)
    against +0.4 to +0.9 C at the other San Diego stations -- 1 C warmer than
    Montgomery Field, 7 km away, in 2018 and 0.8 C cooler in 2025, in every month.

    means: wmo, mean_2018_c, mean_2025_c (and anything else, carried through).
    Returns it with delta_c, median_delta_c, deviation_c, excluded, reason.
    """
    delta = pl.col("mean_2018_c") - pl.col("mean_2025_c")
    out = means.with_columns(delta_c=delta).with_columns(
        median_delta_c=pl.col("delta_c").median())
    out = out.with_columns(deviation_c=pl.col("delta_c") - pl.col("median_delta_c"))
    out = out.with_columns(excluded=pl.col("deviation_c").abs() > max_dev_c)
    reason = pl.concat_str([
        pl.lit("2018-minus-2025 mean temperature "), _signed(pl.col("delta_c")),
        pl.lit(" C against a median of "), _signed(pl.col("median_delta_c")),
        pl.lit(" C across the candidate stations: the station's two years are not comparable")])
    return out.with_columns(reason=pl.when(pl.col("excluded")).then(reason).otherwise(pl.lit("")))


# ---------------------------------------------------------------------------
# electricity: time-of-week and temperature
# ---------------------------------------------------------------------------

def fit_bin_edges(temp_f: np.ndarray, edges=TOWT_BIN_EDGES_F,
                  min_points: int = MIN_POINTS_PER_BIN) -> list[float]:
    """Drop bin edges until every temperature bin holds at least `min_points`
    observations (CalTRACK's rule). Bins are merged from the sparse side."""
    t = np.asarray(temp_f, dtype=float)
    e = list(edges)
    while e:
        counts = np.bincount(np.searchsorted(e, t, side="right"), minlength=len(e) + 1)
        sparse = np.flatnonzero(counts < min_points)
        if not len(sparse):
            break
        i = int(sparse[0])
        # merge the sparse bin into its neighbour by removing the edge between them
        e.pop(min(i, len(e) - 1))
    return e


def temp_components(temp_f: np.ndarray, edges: list[float]) -> np.ndarray:
    """Piecewise-linear temperature components; they sum to the temperature, so
    each coefficient is the slope inside its bin."""
    t = np.asarray(temp_f, dtype=float)
    if not edges:
        return t[:, None]
    e = np.asarray(edges, dtype=float)
    lower = np.minimum(t, e[0])[:, None]
    middle = np.clip(t[:, None], e[:-1], e[1:]) - e[:-1]
    upper = np.maximum(t - e[-1], 0.0)[:, None]
    return np.hstack([lower, middle, upper])


def towt_design(how: np.ndarray, temp_f: np.ndarray, edges: list[float]) -> np.ndarray:
    onehot = np.zeros((len(how), 168))
    onehot[np.arange(len(how)), np.asarray(how, dtype=int)] = 1.0
    return np.hstack([onehot, temp_components(temp_f, edges)])


def _fit_stats(y, yhat) -> dict:
    y, yhat = np.asarray(y, float), np.asarray(yhat, float)
    n, mean = len(y), float(np.mean(y)) if len(y) else float("nan")
    resid = y - yhat
    rmse = float(np.sqrt(np.mean(resid ** 2))) if n else float("nan")
    ss_tot = float(np.sum((y - mean) ** 2)) if n else float("nan")
    return {"n": n,
            "cvrmse_pct": 100.0 * rmse / mean if n and mean else float("nan"),
            "nmbe_pct": 100.0 * float(np.sum(resid)) / (n * mean) if n and mean else float("nan"),
            "r2": 1.0 - float(np.sum(resid ** 2)) / ss_tot if n and ss_tot else float("nan")}


def _stats_frame(stats: list[dict]) -> pl.DataFrame:
    return pl.DataFrame(stats, infer_schema_length=None) if stats else pl.DataFrame()


def normalize_hourly(obs: pl.DataFrame, wx_fit: pl.DataFrame, wx_target: pl.DataFrame,
                     target_year: int, seasons: dict) -> tuple[pl.DataFrame, pl.DataFrame]:
    """Fit TOWT per season on `obs` and predict the full `target_year` in PST.

    obs        clock (hour-beginning clock time), value; DST artefacts already removed
    wx_fit     timestamp_pst, drybulb_c for the observed year
    wx_target  timestamp_pst, drybulb_c for the target year
    Returns (prediction: timestamp_pst, value, season; stats: season, n, cvrmse_pct,
    nmbe_pct, r2, bin_edges_f, negatives_floored -- plus an 'All' row pooling the
    seasons' residuals).
    """
    o = (obs.with_columns(timestamp_pst=clock_to_pst_expr(pl.col("clock")))
         .join(wx_fit.select("timestamp_pst", "drybulb_c"), on="timestamp_pst", how="inner")
         .with_columns(temp_f=c_to_f_expr(pl.col("drybulb_c")),
                       season=season_expr(pl.col("timestamp_pst"), seasons),
                       how=hour_of_week_expr(pl.col("clock"))))
    tgt = (wx_target.filter(pl.col("timestamp_pst").dt.year() == target_year)
           .with_columns(clock=pst_to_clock_expr(pl.col("timestamp_pst")))
           .with_columns(temp_f=c_to_f_expr(pl.col("drybulb_c")),
                         season=season_expr(pl.col("timestamp_pst"), seasons),
                         how=hour_of_week_expr(pl.col("clock"))))
    preds, stats, ys, fits = [], [], [], []
    for season in seasons:                       # one fit per season: groups, not rows
        so = o.filter(pl.col("season") == season)
        st = tgt.filter(pl.col("season") == season)
        if so.is_empty() or st.is_empty():
            continue
        y = so["value"].to_numpy()
        edges = fit_bin_edges(so["temp_f"].to_numpy())
        X = towt_design(so["how"].to_numpy(), so["temp_f"].to_numpy(), edges)
        beta, *_ = np.linalg.lstsq(X, y, rcond=None)
        fit = X @ beta
        yt = towt_design(st["how"].to_numpy(), st["temp_f"].to_numpy(), edges) @ beta
        neg = int((yt < 0).sum())
        preds.append(st.select("timestamp_pst").with_columns(
            value=pl.Series(np.maximum(yt, 0.0)), season=pl.lit(season)))
        stats.append({"season": season, **_fit_stats(y, fit),
                      "bin_edges_f": ",".join(f"{e:g}" for e in edges),
                      "negatives_floored": neg})
        ys.append(y)
        fits.append(fit)
    if ys:
        stats.append({"season": "All", **_fit_stats(np.concatenate(ys), np.concatenate(fits)),
                      "bin_edges_f": "", "negatives_floored": sum(s["negatives_floored"] for s in stats)})
    pred = (pl.concat(preds).sort("timestamp_pst") if preds else
            pl.DataFrame(schema={"timestamp_pst": pl.Datetime(TIME_UNIT), "value": pl.Float64,
                                 "season": pl.String}))
    return pred, _stats_frame(stats)


# ---------------------------------------------------------------------------
# natural gas: daily change-point model
# ---------------------------------------------------------------------------

def daily_mean_temp_f(wx: pl.DataFrame) -> pl.DataFrame:
    """date (midnight datetime), temp_f: mean of the PST hours of each calendar date."""
    return (wx.group_by(pl.col("timestamp_pst").dt.truncate("1d").alias("date"))
            .agg(temp_f=c_to_f_expr(pl.col("drybulb_c")).mean()).sort("date"))


def _gas_design(dow: np.ndarray, temp_f: np.ndarray, bp: float | None) -> np.ndarray:
    onehot = np.zeros((len(dow), 7))
    onehot[np.arange(len(dow)), np.asarray(dow, dtype=int)] = 1.0
    if bp is None:
        return onehot
    return np.hstack([onehot, np.maximum(bp - np.asarray(temp_f, float), 0.0)[:, None]])


def fit_gas_season(dow: np.ndarray, temp_f: np.ndarray, y: np.ndarray):
    """Best change-point model for one season: (balance point or None, beta, yhat).

    Non-negative least squares: a day-of-week baseload and a heating slope are both
    physically non-negative. Ordinary least squares let a steep heating slope pull
    the baseload below zero, which then predicted negative gas on warm 2018 days
    (131 days across the SDG&E profiles before this). The day-of-week-only model is
    the fallback and wins whenever a heating term does not lower the error."""
    from scipy.optimize import nnls
    X0 = _gas_design(dow, temp_f, None)
    b0, _ = nnls(X0, y)
    best = (None, b0, X0 @ b0, float(np.sum((y - X0 @ b0) ** 2)))
    for bp in GAS_BALANCE_POINTS_F:
        X = _gas_design(dow, temp_f, float(bp))
        if not np.any(X[:, -1] > 0):
            continue
        b, _ = nnls(X, y)
        sse = float(np.sum((y - X @ b) ** 2))
        if b[-1] > 0 and sse < best[3] - 1e-12:
            best = (float(bp), b, X @ b, sse)
    return best[0], best[1], best[2]


def normalize_daily_gas(obs: pl.DataFrame, wx_fit: pl.DataFrame, wx_target: pl.DataFrame,
                        target_year: int, seasons: dict) -> tuple[pl.DataFrame, pl.DataFrame]:
    """obs: date, value (daily). Returns (prediction: date, value, season; stats)."""
    def prep(df: pl.DataFrame) -> pl.DataFrame:
        return df.with_columns(season=season_expr(pl.col("date"), seasons),
                               dow=pl.col("date").dt.weekday() - 1)
    o = prep(obs.with_columns(pl.col("date").cast(pl.Datetime(TIME_UNIT)))
             .join(daily_mean_temp_f(wx_fit), on="date", how="inner"))
    t = prep(daily_mean_temp_f(wx_target).filter(pl.col("date").dt.year() == target_year))
    preds, stats, ys, fits = [], [], [], []
    for season in seasons:                       # one fit per season: groups, not rows
        so, st = o.filter(pl.col("season") == season), t.filter(pl.col("season") == season)
        if so.is_empty() or st.is_empty():
            continue
        y = so["value"].to_numpy()
        bp, beta, fit = fit_gas_season(so["dow"].to_numpy(), so["temp_f"].to_numpy(), y)
        yt = _gas_design(st["dow"].to_numpy(), st["temp_f"].to_numpy(), bp) @ beta
        neg = int((yt < 0).sum())
        preds.append(st.select("date").with_columns(
            value=pl.Series(np.maximum(yt, 0.0)), season=pl.lit(season)))
        stats.append({"season": season, **_fit_stats(y, fit),
                      "balance_point_f": bp,
                      "heating_slope": float(beta[-1]) if bp is not None else 0.0,
                      "negatives_floored": neg})
        ys.append(y)
        fits.append(fit)
    if ys:
        stats.append({"season": "All", **_fit_stats(np.concatenate(ys), np.concatenate(fits)),
                      "balance_point_f": None, "heating_slope": None,
                      "negatives_floored": sum(s["negatives_floored"] for s in stats)})
    pred = (pl.concat(preds).sort("date") if preds else
            pl.DataFrame(schema={"date": pl.Datetime(TIME_UNIT), "value": pl.Float64,
                                 "season": pl.String}))
    return pred, _stats_frame(stats)


def annual_fit_ok(stats: pl.DataFrame, max_cvrmse_pct: float = MAX_CVRMSE_PCT) -> tuple[bool, float]:
    """(passes, CV(RMSE) %) from the year-long 'All' row: the residuals of every
    season's fit pooled, so it is exact rather than recombined from the seasons."""
    if stats.is_empty():
        return False, float("nan")
    row = stats.filter(pl.col("season") == "All")
    if row.is_empty():
        return False, float("nan")
    cv = row["cvrmse_pct"][0]
    cv = float("nan") if cv is None else float(cv)
    return bool(np.isfinite(cv) and cv <= max_cvrmse_pct), cv
