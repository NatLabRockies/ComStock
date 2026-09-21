# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""AMI shape comparison for one region.

ComStock side: Athena timeseries joined to the by-state-and-county metadata
table (county-split weights — same basis as comstockpostproc's AMI weight
view). AMI truth side: `output/AMI v01/AMI long.csv` as produced by the
existing cspp.AMI class (3x-median filtered, bldg_count-trimmed, with 80%
t-interval sample_uncertainty) — leveraging the established methods rather
than reprocessing raw meter files.

Comparison basis mirrors comstockpostproc: season x weekday/weekend mean
24-hour kWh/sqft profiles, each dataset on its own calendar year.
"""

from __future__ import annotations

import logging

import numpy as np
import pandas as pd

from . import athena
from .timeseries import (enduse_sums, hour_trunc, join_on, time_expr,
                         state_filter, total_sum, ts_dialect)
from .metrics_def import (
    BLDG_TYPE_COL,
    BLDG_TYPE_TO_SNAKE,
    ENDUSE_STACK_ORDER,
    SQFT_COL,
    TS_ENDUSE_COL,
)

logger = logging.getLogger(__name__)

# Region definitions ported verbatim from comstockpostproc/ami.py ami_region_map
# (counties, years, and the climate-specific season month lists). "states" adds
# the ts_by_state partition filter each county set falls in.
REGIONS = {
    "fort_collins": {
        "counties": ["G0800690"], "states": ["CO"], "year": 2016,
        "seasons": {"Summer": [6, 7, 8], "Shoulder": [5, 9, 10], "Winter": [1, 2, 3, 4, 11, 12]},
    },
    "seattle": {
        "counties": ["G5300330"], "states": ["WA"], "year": 2019,
        "seasons": {"Summer": [], "Shoulder": [4, 5, 6, 7, 8, 9], "Winter": [1, 2, 3, 10, 11, 12]},
    },
    "pge": {
        "counties": ["G4100510"], "states": ["OR"], "year": 2019,
        "seasons": {"Summer": [8], "Shoulder": [4, 5, 6, 7, 9, 10], "Winter": [1, 2, 3, 11, 12]},
    },
    "maine": {
        "counties": ["G2300050"], "states": ["ME"], "year": 2018,
        "seasons": {"Summer": [7, 8], "Shoulder": [5, 6, 9], "Winter": [1, 2, 3, 4, 10, 11, 12]},
    },
    "veic": {
        "counties": ["G5000010", "G5000030", "G5000070", "G5000170",
                     "G5000210", "G5000230", "G5000250", "G5000270"],
        "states": ["VT"], "year": 2018,
        "seasons": {"Summer": [7, 8], "Shoulder": [5, 6, 9], "Winter": [1, 2, 3, 4, 10, 11, 12]},
    },
    "cherryland": {
        "counties": ["G2600190", "G2600550", "G2600790", "G2600890", "G2601010", "G2601650"],
        "states": ["MI"], "year": 2019,
        "seasons": {"Summer": [7], "Shoulder": [6, 8, 9], "Winter": [1, 2, 3, 4, 5, 10, 11, 12]},
    },
    "pepco": {
        "counties": ["G1100010", "G2400330"], "states": ["DC", "MD"], "year": 2019,
        "seasons": {"Summer": [6, 7, 8, 9], "Shoulder": [4, 5, 10], "Winter": [1, 2, 3, 11, 12]},
    },
    "epb": {
        "counties": ["G4700650"], "states": ["TN"], "year": 2019,
        "seasons": {"Summer": [5, 6, 7, 8, 9], "Shoulder": [4, 10], "Winter": [1, 2, 3, 11, 12]},
    },
    "tallahassee": {
        "counties": ["G1200730"], "states": ["FL"], "year": 2019,
        "seasons": {"Summer": [5, 6, 7, 8, 9, 10], "Shoulder": [2, 3, 4, 11, 12], "Winter": [1]},
    },
    "horry": {
        "counties": ["G4500510"], "states": ["SC"], "year": 2019,
        "seasons": {"Summer": [5, 6, 7, 8, 9, 10], "Shoulder": [3, 4], "Winter": [1, 2, 11, 12]},
    },
}

MIN_BLDG_COUNT = 3  # mirrors comstock_to_ami_comparison.py skip guard

# The COMSTOCK-side equivalent, which did not exist. MIN_BLDG_COUNT guards only
# the metered side, so a cell backed by ONE sampled model rendered as a
# confident 24-hour profile beside a well-metered truth curve. Only about 2% of
# models are SIMULATED in the AMI counties, but apportionment spreads each model
# across the counties it represents, so the count that matters is models
# carrying WEIGHT there: roughly 70-240 per (region x building type) cell on a
# national ~100k run, 20-440 on a 10k run -- and the thinnest cells still fall
# below this. Cells below this are still drawn (hiding them would misreport
# coverage) but are flagged, so a reader can tell a shape from a coincidence.
MIN_COMSTOCK_MODELS = 10


# Timeseries column addressing lives in .timeseries, shared with the measure
# leg, so a crawled run cannot work on one tab and error on the other.
# Re-exported here because callers and tests reach for ami_shapes.ts_dialect.


def build_sqft_sql(md_county_table: str, region: dict) -> str:
    counties = ", ".join(f"'{c}'" for c in region["counties"])
    states = ", ".join(f"'{s}'" for s in region["states"])
    return (
        f'SELECT "{BLDG_TYPE_COL}" AS building_type,\n'
        f'    SUM(weight) AS bldg_count_weighted,\n'
        # The number of SAMPLED MODELS behind the cell, which is what decides
        # whether its shape means anything. bldg_count_weighted is the stock it
        # represents -- a single model carrying a large weight looks reassuring
        # there while being one building's simulated shape.
        #
        # DISTINCT is load-bearing. This table holds one row per (bldg_id,
        # county), because apportionment spreads each model across the counties
        # it represents, so a plain COUNT(*) counts apportionment rows and
        # inflates any MULTI-county region by roughly its county count --
        # measured at 2.05x for cherryland's six counties and 1.00x for
        # single-county epb. Inflating this number defeats the guard: it makes
        # thin cells look adequately sampled, which is worse than not
        # reporting it.
        f'    COUNT(DISTINCT bldg_id) AS comstock_model_count,\n'
        f'    SUM(weight * "{SQFT_COL}") AS sqft_weighted\n'
        f"FROM {md_county_table}\n"
        f"WHERE state IN ({states}) AND CAST(upgrade AS varchar) = '0'\n"
        f"    AND completed_status = 'Success'\n"
        f'    AND "in.nhgis_county_gisjoin" IN ({counties})\n'
        f'GROUP BY "{BLDG_TYPE_COL}" ORDER BY 1'
    )


def build_ts_sql(ts_table: str, md_county_table: str, region: dict,
                 dialect: dict | None = None) -> str:
    """Weighted hourly end-use SQL, addressed through `dialect`.

    `dialect` comes from ts_dialect(); the default is the published schema, so
    dumping the SQL for inspection without an Athena round-trip still works.
    """
    counties = ", ".join(f"'{c}'" for c in region["counties"])
    states = ", ".join(f"'{s}'" for s in region["states"])
    # Every column reference goes through .timeseries so this leg and the
    # measure leg address a crawled run identically.
    ts_state = state_filter(dialect, region["states"])
    # "" on a crawled table, which has no state column. Kept as a whole line so
    # an empty value cannot leave a dangling AND.
    ts_state_line = f"  AND {ts_state}\n" if ts_state else ""
    return (
        "SELECT\n"
        f'    m."{BLDG_TYPE_COL}" AS building_type,\n'
        f"    {hour_trunc(dialect)} AS hour_ts,\n"
        f"    {total_sum(dialect, 'electricity', 'kwh_weighted')},\n"
        f"{enduse_sums(dialect)}\n"
        f"FROM {ts_table} t\n"
        f"JOIN {md_county_table} m\n"
        f"  ON {join_on(dialect)}\n"
        "    AND CAST(t.upgrade AS varchar) = CAST(m.upgrade AS varchar)\n"
        f"WHERE m.state IN ({states})\n"
        f"{ts_state_line}"
        # upgrade is bigint on 2025 R3 tables and varchar on 2024 R2 — comparing
        # as varchar works on both.
        "  AND CAST(t.upgrade AS varchar) = '0' AND CAST(m.upgrade AS varchar) = '0'\n"
        "  AND m.completed_status = 'Success'\n"
        f'  AND m."in.nhgis_county_gisjoin" IN ({counties})\n'
        "GROUP BY 1, 2"
    )


def build_membership_sql(ts_table: str, md_county_table: str, region: dict,
                         dialect: dict | None = None) -> str:
    """Do the region's metadata buildings all HAVE timeseries rows?

    The two halves of kWh/ft2 come from different queries: the numerator sums
    energy over buildings that appear in BOTH tables (it joins them), while the
    denominator sums floor area over the metadata table alone. If some region
    buildings have no timeseries rows -- which happens when a run writes
    timeseries for a subset of its models -- the denominator covers more
    buildings than the numerator and kWh/ft2 is biased LOW.

    Measured as zero on the run this was written against: pepco had 3,171
    metadata buildings and 3,171 with timeseries, identical weighted area. So
    this reports rather than corrects: a real gap is a property of the run, and
    silently reweighting one side would hide it.

    One day of the timeseries is enough -- a building either has a profile or it
    does not -- and scanning a year to establish set membership is not worth it.
    """
    from .timeseries import PUBLISHED
    d = dialect or PUBLISHED
    counties = ", ".join(f"'{c}'" for c in region["counties"])
    states = ", ".join(f"'{s}'" for s in region["states"])
    # Same dialect handling as the profile query: epoch-nanosecond timestamps
    # are converted and the upgrade literal is typed to the column, so an older
    # published table cannot make this probe fail and hide the coverage gap.
    ts_where = [f"upgrade = {athena.upgrade_literal(0, d.get('up_type'))}",
                f"{time_expr(d, 't')} < from_iso8601_timestamp('2018-01-02T00:00:00')"]
    if d["state"]:
        ts_where.append(f't."{d["state"]}" IN ({states})')
    return (
        "SELECT COUNT(DISTINCT m.bldg_id) AS md_bldgs,\n"
        "    COUNT(DISTINCT CASE WHEN t.b IS NOT NULL THEN m.bldg_id END) AS ts_bldgs,\n"
        f'    SUM(m.weight * m."{SQFT_COL}") AS sqft_all,\n'
        "    SUM(CASE WHEN t.b IS NOT NULL THEN m.weight * "
        f'm."{SQFT_COL}" END) AS sqft_with_ts\n'
        f"FROM {md_county_table} m\n"
        f'LEFT JOIN (SELECT DISTINCT t."{d["bldg"]}" AS b FROM {ts_table} t\n'
        f"           WHERE {' AND '.join(ts_where)}) t ON t.b = m.bldg_id\n"
        f"WHERE m.state IN ({states}) AND CAST(m.upgrade AS varchar) = '0'\n"
        "  AND m.completed_status = 'Success'\n"
        f'  AND m."in.nhgis_county_gisjoin" IN ({counties})'
    )


def check_membership(ts_table: str, md_county_table: str, region_name: str,
                     dialect: dict | None = None, no_cache: bool = False) -> dict:
    """{} when the two sides cover the same buildings, else the measured gap."""
    try:
        df = athena.query(
            build_membership_sql(ts_table, md_county_table, REGIONS[region_name], dialect),
            no_cache=no_cache, label=f"{region_name} membership")
    except Exception as exc:                                      # noqa: BLE001
        logger.warning("membership check for %s could not run (%s); timeseries "
                       "coverage of this region is unverified", region_name, exc)
        return {}
    if df.empty:
        return {}
    r = df.iloc[0]
    md, ts = float(r["md_bldgs"] or 0), float(r["ts_bldgs"] or 0)
    a_all, a_ts = float(r["sqft_all"] or 0), float(r["sqft_with_ts"] or 0)
    if not md or not a_all or abs(a_all - a_ts) <= a_all * 1e-6:
        return {}
    return {
        "md_bldgs": int(md), "ts_bldgs": int(ts),
        "area_covered_pct": round(100.0 * a_ts / a_all, 2),
        "note": (f"{int(md - ts)} of {int(md)} buildings in this region have no "
                 f"timeseries rows, so the kWh/ft2 denominator covers "
                 f"{100.0 * a_all / a_ts:.2f}x the floor area the numerator does "
                 f"— kWh/ft2 is biased LOW by "
                 f"{100.0 * (1 - a_ts / a_all):.1f}%."),
    }


def fetch_comstock_profiles(ts_table: str, md_county_table: str, region_name: str,
                            no_cache: bool = False) -> pd.DataFrame:
    """Weighted hourly kWh/sqft by AMI building type for the region (long df)."""
    region = REGIONS[region_name]
    dialect = ts_dialect(ts_table, no_cache=no_cache)
    # The numerator joins the two tables; the denominator reads the metadata
    # alone. Measure whether they cover the same buildings, and say so if not.
    gap = check_membership(ts_table, md_county_table, region_name, dialect,
                           no_cache=no_cache)
    if gap:
        logger.warning("%s: %s", region_name, gap["note"])
    sqft = athena.query(build_sqft_sql(md_county_table, region), no_cache=no_cache,
                        label=f"{region_name} sqft")
    ts = athena.query(build_ts_sql(ts_table, md_county_table, region, dialect),
                      no_cache=no_cache, label=f"{region_name} timeseries")
    ts = ts.merge(sqft[["building_type", "sqft_weighted", "comstock_model_count"]],
                  on="building_type", how="left")
    ts["kwh_per_sf"] = ts["kwh_weighted"] / ts["sqft_weighted"]
    for e in ENDUSE_STACK_ORDER:
        if e in ts.columns:
            ts[f"eu_{e}"] = ts[e] / ts["sqft_weighted"]
    ts["building_type"] = ts["building_type"].map(BLDG_TYPE_TO_SNAKE)
    ts = ts.dropna(subset=["building_type"])  # Grocery has no AMI counterpart
    ts["hour_ts"] = pd.to_datetime(ts["hour_ts"])
    # Carried on the frame rather than logged only, so compare_region can put it
    # in coverage and the page can show it. attrs survives the merges above.
    ts.attrs["membership_gap"] = gap
    ts.attrs["tz"] = dialect.get("tz", "local")   # 'est' = converted to local by state
    return ts


def load_ami_truth(ami_long_csv: str, region_name: str) -> pd.DataFrame:
    df = pd.read_csv(ami_long_csv, parse_dates=["timestamp"])
    df = df[df["region_name"] == region_name].copy()
    return df


def _daytype_norm(v: np.ndarray) -> np.ndarray:
    """Divide a 24-hour mean profile by its own day sum, so it sums to 1.

    This is the 'Daytype' normalization used by
    plot_day_type_comparison_stacked_by_enduse: a single scalar divisor, which
    removes the level (and with it any floor-area denominator error) while
    leaving a stacked end-use breakdown intact — every end use stays visible and
    the layers still sum to the normalized total.
    """
    s = float(np.nansum(v))
    if not np.isfinite(s) or s == 0:
        return np.zeros_like(v)
    return v / s


def _season_daytype(ts: pd.Series, seasons: dict) -> tuple[pd.Series, pd.Series]:
    month_to_season = {m: s for s, months in seasons.items() for m in months}
    season = ts.dt.month.map(month_to_season)
    daytype = np.where(ts.dt.dayofweek < 5, "Weekday", "Weekend")
    return season, pd.Series(daytype, index=ts.index)


def _mean_profiles(df: pd.DataFrame, ts_col: str, val_cols, seasons: dict) -> pd.DataFrame:
    if isinstance(val_cols, str):
        val_cols = [val_cols]
    season, daytype = _season_daytype(df[ts_col], seasons)
    out = df.assign(season=season, day_type=daytype, hour=df[ts_col].dt.hour)
    out = out.dropna(subset=["season"])
    return out.groupby(["building_type", "season", "day_type", "hour"], as_index=False)[val_cols].mean()


def build_ldc(cs: pd.DataFrame, ami: pd.DataFrame, both: set) -> pd.DataFrame:
    """Load duration curves per building type, mirroring plot_load_duration_curve.

    Both series are sorted descending over the full year independently; the AMI
    band is ± the maximum sample uncertainty over the year (upstream applies one
    scalar). The monotonic curve is sampled — every one of the top 24 hours,
    then ~120 evenly spaced ranks — which is visually identical to all 8760
    points and keeps nine regions embeddable.
    """
    rows = []
    for bt in sorted(both):
        c = np.sort(pd.to_numeric(
            cs.loc[cs["building_type"] == bt, "kwh_per_sf"], errors="coerce").dropna().to_numpy())[::-1]
        a_sub = ami[ami["building_type"] == bt]
        a = np.sort(pd.to_numeric(
            a_sub["kwh_per_sf"], errors="coerce").dropna().to_numpy())[::-1]
        if len(c) < 100 or len(a) < 100:
            continue
        unc = float(pd.to_numeric(a_sub.get("sample_uncertainty"), errors="coerce").max())
        if not np.isfinite(unc):
            # No measured uncertainty for this type/region. The old fallback
            # substituted 0.1 silently, and the dashboard then drew that band
            # labelled "the AMI 80% confidence interval" -- a made-up number
            # presented as a measured one. Emit NaN so no band is drawn instead.
            unc = float("nan")
        n = min(len(c), len(a))
        ranks = np.unique(np.concatenate(
            [np.arange(1, min(25, n + 1)), np.linspace(25, n, 120).astype(int)]))
        ranks = ranks[(ranks >= 1) & (ranks <= n)]
        for r in ranks:
            rows.append({
                "building_type": bt, "hours": int(r),
                "comstock_kwh_per_sf": float(c[r - 1]),
                "ami_kwh_per_sf": float(a[r - 1]),
                "ami_unc": unc,
            })
    return pd.DataFrame(rows)


def cross_region_agreement(metrics_by_region: dict[str, pd.DataFrame]) -> pd.DataFrame:
    """One row per (building_type, region): mean shape metrics across day types.

    Reading across a row of regions separates systematic shape errors (same sign
    everywhere -> the model) from regional ones (one region -> weather or local
    stock idiosyncrasy). Overnight delta is ComStock minus AMI share of the day
    in hours 0-5, in percentage points.
    """
    rows = []
    for region, met in metrics_by_region.items():
        if met is None or met.empty:
            continue
        g = met.groupby("building_type")
        for bt, sub in g:
            rows.append({
                "building_type": bt, "region": region,
                "shape_rmse_pts": float(sub["daytype_shape_rmse_pts"].mean()),
                "overnight_delta_pp": 100.0 * float(
                    (sub["overnight_share_comstock"] - sub["overnight_share_ami"]).mean()),
                "n_daytypes": int(len(sub)),
            })
    df = pd.DataFrame(rows)
    if df.empty:
        return df
    # systematic = same overnight sign in >= 2/3 of covered regions, with at
    # least three regions covering the type
    def _flag(sub: pd.DataFrame) -> str:
        n = len(sub)
        if n < 3:
            return "insufficient regions"
        pos = int((sub["overnight_delta_pp"] > 0).sum())
        frac = max(pos, n - pos) / n
        return "systematic" if frac >= 2 / 3 else "mixed"
    flags = (df.groupby("building_type").apply(_flag, include_groups=False)
             .rename("consistency").reset_index())
    return df.merge(flags, on="building_type", how="left")


def annual_totals(cs: pd.DataFrame, ami: pd.DataFrame) -> pd.DataFrame:
    """Annual kWh/ft2 per building type for each dataset.

    These are the divisors for the 'Annual' normalization (annual sum = 1) used
    by plot_day_type_comparison_stacked_by_enduse, which divides the whole frame
    — end uses included — by one scalar per dataset.
    """
    c = cs.groupby("building_type", as_index=False)["kwh_per_sf"].sum().rename(
        columns={"kwh_per_sf": "comstock_annual_kwh_per_sf"})
    a = ami.groupby("building_type", as_index=False)["kwh_per_sf"].sum().rename(
        columns={"kwh_per_sf": "ami_annual_kwh_per_sf"})
    return c.merge(a, on="building_type", how="outer")


def compare_region(cs: pd.DataFrame, ami: pd.DataFrame, region_name: str
                   ) -> tuple[pd.DataFrame, pd.DataFrame, dict, pd.DataFrame]:
    """Returns (profiles long, shape metrics, coverage, load-duration curve)."""
    seasons = REGIONS[region_name]["seasons"]

    counts = ami.groupby("building_type")["bldg_count"].agg(["min", "mean", "count"])
    thin = counts[counts["min"] < MIN_BLDG_COUNT].index.tolist()
    ami_types = set(counts.index) - set(thin) - {"total"}
    cs_types = set(cs["building_type"].unique())
    both = sorted(ami_types & cs_types)
    # ComStock-side model counts per compared type, so thin cells are visible
    # rather than implied. Reported, not dropped: removing them would understate
    # which types the run actually covers.
    cs_counts, cs_thin = {}, []
    if "comstock_model_count" in cs.columns:
        per_type = (cs.groupby("building_type")["comstock_model_count"]
                    .max().dropna().astype(int))
        cs_counts = {bt: int(n) for bt, n in per_type.items() if bt in both}
        cs_thin = sorted(bt for bt, n in cs_counts.items() if n < MIN_COMSTOCK_MODELS)

    coverage = {
        "region": region_name,
        "compared_types": both,
        "ami_missing_types": sorted(cs_types - ami_types - {"total"}),
        "comstock_missing_types": sorted(ami_types - cs_types),
        "ami_thin_sample_types_skipped": thin,
        # Metered building count per compared type, the AMI-side counterpart to
        # comstock_model_counts. bldg_count varies hour to hour as meters drop in
        # and out, so the MINIMUM is reported: it is the count every hour of the
        # comparison is backed by, which is the honest figure to put beside a
        # profile. The mean would overstate the thinnest hours.
        "ami_meter_counts": {bt: int(counts.loc[bt, "min"])
                             for bt in both if bt in counts.index},
        "comstock_model_counts": cs_counts,
        "comstock_thin_sample_types": cs_thin,
        "comstock_min_models_threshold": MIN_COMSTOCK_MODELS,
    }
    # Measured zero on the run this was built against, so it is normally absent.
    # When present, kWh/ft2 levels for this region are biased and the shape
    # metrics (day-sum normalized) are not.
    if cs.attrs.get("membership_gap"):
        coverage["timeseries_membership_gap"] = cs.attrs["membership_gap"]
    coverage["timeseries_clock"] = cs.attrs.get("tz", "local")

    eu_cols = [f"eu_{e}" for e in ENDUSE_STACK_ORDER if f"eu_{e}" in cs.columns]
    cs_prof = _mean_profiles(cs[cs["building_type"].isin(both)], "hour_ts",
                             ["kwh_per_sf"] + eu_cols, seasons)
    cs_prof = cs_prof.rename(columns={"kwh_per_sf": "comstock_kwh_per_sf"})
    ami_prof = _mean_profiles(ami[ami["building_type"].isin(both)], "timestamp",
                              ["kwh_per_sf", "sample_uncertainty"], seasons)
    ami_prof = ami_prof.rename(columns={"kwh_per_sf": "ami_kwh_per_sf",
                                        "sample_uncertainty": "ami_sample_uncertainty"})
    unc = ami[ami["building_type"].isin(both)].copy()
    unc_season, unc_daytype = _season_daytype(unc["timestamp"], seasons)
    unc = unc.assign(season=unc_season, day_type=unc_daytype).dropna(subset=["season"])
    unc = unc.groupby(["building_type", "season", "day_type"], as_index=False)["sample_uncertainty"].mean()

    prof = cs_prof.merge(ami_prof, on=["building_type", "season", "day_type", "hour"], how="inner")
    prof["rel_err"] = (prof["comstock_kwh_per_sf"] - prof["ami_kwh_per_sf"]) / prof["ami_kwh_per_sf"]

    rows = []
    for (bt, season, dt), g in prof.groupby(["building_type", "season", "day_type"]):
        g = g.sort_values("hour")
        a, c = g["ami_kwh_per_sf"].to_numpy(), g["comstock_kwh_per_sf"].to_numpy()
        if len(g) < 24 or a.mean() == 0:
            continue
        night = g["hour"] < 6
        an, cn = _daytype_norm(a), _daytype_norm(c)
        rows.append({
            "building_type": bt, "season": season, "day_type": dt,
            "nmbe_pct": 100.0 * (c.mean() - a.mean()) / a.mean(),
            "cvrmse_pct": 100.0 * np.sqrt(np.mean((c - a) ** 2)) / a.mean(),
            # Shape-only: both profiles day-sum normalized first (the postprocessing
            # 'Daytype' convention), so they are independent of the kWh/sqft level and
            # of any error in the AMI floor-area denominator. Expressed as points of
            # the day's energy, so 1.0 = one percent of the day misallocated per hour.
            "daytype_shape_rmse_pts": 100.0 * float(np.sqrt(np.mean((cn - an) ** 2))),
            # CV(RMSE) computed on the day-sum-normalized profiles: the Guideline 14
            # statistic with the level divided out, so it is not distorted by the
            # AMI floor-area denominator the way the raw CV(RMSE) is.
            "daytype_cvrmse_pct": 100.0 * float(np.sqrt(np.mean((cn - an) ** 2)) / an.mean())
            if an.mean() else np.nan,
            "shape_corr": float(np.corrcoef(a, c)[0, 1]) if a.std() and c.std() else np.nan,
            # Share of the day's energy falling in hours 0-5. Invariant to any scalar
            # normalization, so it reads the same in every view.
            "overnight_share_comstock": float(cn[night.to_numpy()].sum()),
            "overnight_share_ami": float(an[night.to_numpy()].sum()),
            "overnight_ratio_comstock": c[night.to_numpy()].mean() / c.mean(),
            "overnight_ratio_ami": a[night.to_numpy()].mean() / a.mean(),
            "overnight_rel_err_pct": 100.0 * (c[night.to_numpy()].mean() - a[night.to_numpy()].mean())
                                      / a[night.to_numpy()].mean(),
            # Normalized trough/peak depth: 0 = trough as deep as the daily minimum.
            "norm_overnight_comstock": float(cn[night.to_numpy()].mean()),
            "norm_overnight_ami": float(an[night.to_numpy()].mean()),
            "peak_hour_comstock": int(g.loc[g["comstock_kwh_per_sf"].idxmax(), "hour"]),
            "peak_hour_ami": int(g.loc[g["ami_kwh_per_sf"].idxmax(), "hour"]),
            "peak_rel_err_pct": 100.0 * (c.max() - a.max()) / a.max(),
        })
    if not rows:
        # A region can have no usable day-type panels at all (e.g. every profile
        # fails the >=24h / non-zero guards). Empty frames with the right columns
        # keep downstream merges and the multi-region loop happy.
        logger.warning("region %s: no comparable day-type panels", region_name)
        return (pd.DataFrame(columns=["building_type"]),
                pd.DataFrame(columns=["building_type", "season", "day_type"]),
                coverage, pd.DataFrame())
    metrics = pd.DataFrame(rows).merge(unc, on=["building_type", "season", "day_type"], how="left")
    metrics = metrics.rename(columns={"sample_uncertainty": "ami_mean_sample_uncertainty_80ci"})
    totals = annual_totals(cs[cs["building_type"].isin(both)], ami[ami["building_type"].isin(both)])
    prof = prof.merge(totals, on="building_type", how="left")
    ldc = build_ldc(cs, ami, both)
    return prof, metrics, coverage, ldc
