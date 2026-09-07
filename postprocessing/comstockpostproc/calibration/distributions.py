"""Weighted EUI distributions: box-plot quantiles and histograms by building type.

Both datasets are weighted samples, so every statistic here is weight-aware — an
unweighted quantile from a weighted stock model describes the sample, not the
stock. Two weighting bases are produced because they answer different questions:

  count : each building counts once, weighted by its stock weight.
          "What does a typical building look like?"
  area  : each building counts by its weighted floor area.
          "Where does the floor area (and so the energy) sit?"

The upstream package mixes these — its EUI boxplots are count-weighted (by row
replication) while its histograms are area-weighted — so the two are kept
explicit and switchable here rather than silently chosen.

Natural-gas asymmetry: CBECS leaves gas EUI null for non-gas buildings (it is
never exactly zero there), while ComStock records 0.0. Comparing as-is would pit
"CBECS gas users only" against "ComStock including every zero" and make CBECS
look systematically higher. Nulls are therefore filled with zero so both sides
describe all buildings; the share of zero-gas floor area is reported separately
in the fuel-mix table.

EUI is reported in kBtu/ft2-yr (the conventional unit); the stored columns are
kWh/ft2.
"""

from __future__ import annotations

import json
import logging
import math

import numpy as np
import pandas as pd

from . import athena
from .metrics_def import (
    BLDG_TYPE_COL,
    CEN_DIV_COL,
    SIZE_BIN_EDGES,
    SIZE_BIN_LABELS,
    SQFT_COL,
    VINTAGE_COL,
)

logger = logging.getLogger(__name__)

KWH_PER_FT2_TO_KBTU_PER_FT2 = 3.412141633

EUI_METRICS = {
    "site_energy": "out.site_energy.total.energy_consumption_intensity..kwh_per_ft2",
    "electricity": "out.electricity.total.energy_consumption_intensity..kwh_per_ft2",
    "natural_gas": "out.natural_gas.total.energy_consumption_intensity..kwh_per_ft2",
}
# Metrics where a null on the CBECS side means "this building has no such fuel"
# rather than "not surveyed".
FILL_NULL_AS_ZERO = {"natural_gas"}

# Dimensions the distributions are cut by. All four exist on both sides; the
# floor-area bins come from metrics_def so the annual and distribution views use
# identical edges.
DIST_DIMENSIONS = {
    "building_type": {"label": "Building type", "col": "building_type"},
    "census_division": {"label": "Census division", "col": "census_division"},
    "vintage": {"label": "Vintage", "col": "vintage"},
    "size_bin": {"label": "Floor area bin", "col": "size_bin"},
}

QUANTILES = [0.05, 0.25, 0.50, 0.75, 0.95]
N_BINS = 40
# Histograms are clipped at this weighted percentile so a few extreme buildings
# cannot compress the informative part of the axis (the upstream histograms run
# min-to-max and are flattened by single outliers). The clip and the mass beyond
# it are both reported.
HIST_CLIP_Q = 0.99
BASES = ("count", "area")


def build_dist_sql(md_table: str, have: set[str] | None = None) -> str:
    present = {k: c for k, c in EUI_METRICS.items() if have is None or c in have}
    cols = ",\n".join(f'    "{c}" AS {k}' for k, c in present.items())
    dims = ",\n".join(
        f'    "{c}" AS {a}' for a, c in
        [("census_division", CEN_DIV_COL), ("vintage", VINTAGE_COL)]
        if have is None or c in have
    )
    return (
        f'SELECT\n    "{BLDG_TYPE_COL}" AS building_type,\n{dims},\n'
        f'    weight,\n    "{SQFT_COL}" AS sqft,\n{cols}\n'
        f"FROM {md_table}\n"
        f"WHERE upgrade = 0 AND completed_status = 'Success'"
    )


def fetch_comstock_buildings(md_table: str, no_cache: bool = False) -> pd.DataFrame:
    """Building-level EUI + weight + area (one row per model)."""
    have = athena.table_columns(md_table, no_cache=no_cache)
    return athena.query(build_dist_sql(md_table, have), no_cache=no_cache,
                        label=f"building-level EUI ({md_table})")


def weighted_quantile(values: np.ndarray, weights: np.ndarray, qs: list[float]) -> list[float]:
    ok = np.isfinite(values) & np.isfinite(weights) & (weights > 0)
    v, w = values[ok], weights[ok]
    if v.size == 0 or w.sum() == 0:
        return [float("nan")] * len(qs)
    order = np.argsort(v)
    v, w = v[order], w[order]
    cw = np.cumsum(w)
    cdf = (cw - 0.5 * w) / w.sum()   # midpoint convention
    return [float(np.interp(q, cdf, v)) for q in qs]


KDE_GRID = 48          # samples across the range; enough for a smooth outline
KDE_MAX_OUTLIERS = 40  # per category, so a large category cannot bloat the payload


def kde_json(values: np.ndarray, weights: np.ndarray | None = None) -> str | None:
    """Weighted Gaussian KDE on a fixed grid, as JSON, for the violin outline.

    ONE implementation, used by the EUI distributions (which are weighted by
    building count or floor area) and by the measure savings distributions
    (unweighted, so they pass weights=None). Two copies of a shape calculation
    is how a figure ends up disagreeing with itself.

    It has to be computed where the raw per-building values still exist: a
    violin reconstructed from stored quantiles would be a drawing of an
    assumption, not of the data. Silverman's rule matches seaborn's default,
    which is what produces the upstream figures.

    Returns None when a KDE is not meaningful (fewer than 5 distinct values, no
    spread), in which case the dashboard shows box-and-whiskers alone.
    """
    v = np.asarray(values, dtype=float)
    w = np.ones_like(v) if weights is None else np.asarray(weights, dtype=float)
    ok = np.isfinite(v) & np.isfinite(w) & (w > 0)
    v, w = v[ok], w[ok]
    if v.size < 5 or np.unique(v).size < 5 or w.sum() <= 0:
        return None
    lo, hi = float(v.min()), float(v.max())
    if not (np.isfinite(lo) and np.isfinite(hi)) or hi <= lo:
        return None
    # weighted std and IQR, so the bandwidth describes the weighted stock
    mu = float(np.average(v, weights=w))
    var = float(np.average((v - mu) ** 2, weights=w))
    sd = math.sqrt(var) if var > 0 else 0.0
    q25, q75 = weighted_quantile(v, w, [0.25, 0.75])
    iqr = q75 - q25 if np.isfinite(q75) and np.isfinite(q25) else 0.0
    scale = min(sd, iqr / 1.34) if iqr > 0 else sd
    # effective sample size, so weighting does not fake extra resolution
    n_eff = float(w.sum() ** 2 / np.sum(w ** 2))
    if scale <= 0 or n_eff < 2:
        return None
    bw = 0.9 * scale * n_eff ** (-0.2)
    if not np.isfinite(bw) or bw <= 0:
        return None
    pad = 2.0 * bw
    grid = np.linspace(lo - pad, hi + pad, KDE_GRID)
    z = (grid[:, None] - v[None, :]) / bw
    dens = (np.exp(-0.5 * z * z) * w[None, :]).sum(axis=1) / (w.sum() * bw * math.sqrt(2 * math.pi))
    peak = float(dens.max())
    if not np.isfinite(peak) or peak <= 0:
        return None
    # normalized to a 0-1 half-width; the dashboard scales it to the row height
    return json.dumps({
        "x0": round(float(grid[0]), 6),
        "x1": round(float(grid[-1]), 6),
        "d": [round(float(x / peak), 4) for x in dens],
    }, separators=(",", ":"))


def outlier_json(values: np.ndarray, p25: float, p75: float) -> str | None:
    """Points beyond 1.5 IQR, the rule matplotlib's boxplot uses."""
    v = np.asarray(values, dtype=float)
    v = v[np.isfinite(v)]
    iqr = p75 - p25
    if not np.isfinite(iqr) or iqr <= 0 or not v.size:
        return None
    lo, hi = p25 - 1.5 * iqr, p75 + 1.5 * iqr
    out = v[(v < lo) | (v > hi)]
    if not out.size:
        return None
    if out.size > KDE_MAX_OUTLIERS:
        out = np.sort(out)
        idx = np.unique(np.linspace(0, out.size - 1, KDE_MAX_OUTLIERS).astype(int))
        out = out[idx]
    return json.dumps([round(float(x), 5) for x in out], separators=(",", ":"))


def weighted_mean(values: np.ndarray, weights: np.ndarray) -> float:
    ok = np.isfinite(values) & np.isfinite(weights) & (weights > 0)
    if not ok.any() or weights[ok].sum() == 0:
        return float("nan")
    return float(np.average(values[ok], weights=weights[ok]))


def _prepare(df: pd.DataFrame, cols: dict[str, str], is_cbecs: bool) -> pd.DataFrame:
    """Normalize one dataset to dimension columns, weights, and metrics in kBtu/ft2."""
    out = pd.DataFrame({"building_type": df[BLDG_TYPE_COL].values})
    for alias, col in [("census_division", CEN_DIV_COL), ("vintage", VINTAGE_COL)]:
        src = col if col in df.columns else alias
        out[alias] = df[src].values if src in df.columns else None
    w = pd.to_numeric(df["weight"], errors="coerce").to_numpy(float)
    sqft_src = SQFT_COL if SQFT_COL in df.columns else "sqft"
    sqft = pd.to_numeric(df[sqft_src], errors="coerce").to_numpy(float)
    out["w_count"] = w
    out["w_area"] = w * sqft
    out["size_bin"] = pd.cut(sqft, bins=SIZE_BIN_EDGES, labels=SIZE_BIN_LABELS,
                             right=True, include_lowest=True).astype(object)
    for metric, col in cols.items():
        v = pd.to_numeric(df[col], errors="coerce").to_numpy(float)
        if is_cbecs and metric in FILL_NULL_AS_ZERO:
            v = np.nan_to_num(v, nan=0.0)
        out[metric] = v * KWH_PER_FT2_TO_KBTU_PER_FT2
    return out


def _quantile_rows(prep: pd.DataFrame, dataset: str, metrics: list[str]) -> list[dict]:
    """Quantiles per (dimension, category, metric, weighting basis)."""
    rows = []
    for dim, spec in DIST_DIMENSIONS.items():
        col = spec["col"]
        if col not in prep.columns or prep[col].isna().all():
            continue
        for cat, g in prep.groupby(col, dropna=True, observed=True):
            for metric in metrics:
                v = g[metric].to_numpy(float)
                for basis in BASES:
                    w = g["w_count" if basis == "count" else "w_area"].to_numpy(float)
                    qs = weighted_quantile(v, w, QUANTILES)
                    rows.append({
                        "dataset": dataset, "dimension": dim, "category": str(cat),
                        "metric": metric, "basis": basis,
                        "p05": qs[0], "p25": qs[1], "p50": qs[2], "p75": qs[3], "p95": qs[4],
                        "mean": weighted_mean(v, w),
                        "n_models": int(np.isfinite(v).sum()),
                        "weighted_total": float(np.nansum(w[np.isfinite(v)])),
                        # violin outline + outliers, on the same weighting as the
                        # quantiles above so the shape and the box agree
                        "kde": kde_json(v, w),
                        "outliers": outlier_json(v, qs[1], qs[3]),
                    })
    return rows


def build_distributions(
    comstock_by_run: dict[str, pd.DataFrame],
    cbecs_df: pd.DataFrame,
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Quantiles and shared-bin histograms for every run plus CBECS."""
    cbecs_cols = {k: c for k, c in EUI_METRICS.items() if c in cbecs_df.columns}
    if set(EUI_METRICS) - set(cbecs_cols):
        logger.info("CBECS lacks EUI columns for: %s",
                    ", ".join(sorted(set(EUI_METRICS) - set(cbecs_cols))))

    preps = {"CBECS 2018": _prepare(cbecs_df, cbecs_cols, is_cbecs=True)}
    for run_key, df in comstock_by_run.items():
        d = df.rename(columns={"building_type": BLDG_TYPE_COL, "sqft": SQFT_COL})
        cols = {k: k for k in EUI_METRICS if k in df.columns}
        preps[run_key] = _prepare(d, cols, is_cbecs=False)

    metrics = sorted({m for p in preps.values() for m in EUI_METRICS if m in p.columns})
    qrows = []
    for ds, p in preps.items():
        qrows += _quantile_rows(p, ds, [m for m in metrics if m in p.columns])
    quantiles = pd.DataFrame(qrows)

    # Histograms stay keyed on building type: they are read one segment at a time,
    # and binning every dimension would multiply the embedded payload for little gain.
    hrows = []
    types = sorted(quantiles.loc[quantiles["dimension"] == "building_type",
                                 "category"].dropna().unique())
    for bt in types:
        for metric in metrics:
            for basis in BASES:
                wcol = "w_count" if basis == "count" else "w_area"
                series = {}
                for ds, p in preps.items():
                    if metric not in p.columns:
                        continue
                    sub = p[p["building_type"] == bt]
                    if sub.empty:
                        continue
                    v = sub[metric].to_numpy(float)
                    w = sub[wcol].to_numpy(float)
                    ok = np.isfinite(v) & np.isfinite(w) & (w > 0)
                    if ok.sum() == 0:
                        continue
                    series[ds] = (v[ok], w[ok])
                if not series:
                    continue
                hi = max(weighted_quantile(v, w, [HIST_CLIP_Q])[0] for v, w in series.values())
                if not np.isfinite(hi) or hi <= 0:
                    continue
                edges = np.linspace(0.0, hi, N_BINS + 1)
                for ds, (v, w) in series.items():
                    hist, _ = np.histogram(np.clip(v, edges[0], edges[-1]), bins=edges, weights=w)
                    total = hist.sum()
                    above = float(w[v > hi].sum())
                    for i in range(len(hist)):
                        hrows.append({
                            "dataset": ds, "building_type": bt, "metric": metric, "basis": basis,
                            "bin_left": float(edges[i]), "bin_right": float(edges[i + 1]),
                            "weighted_share": float(hist[i] / total) if total else float("nan"),
                            "clip_value": float(hi),
                            "share_above_clip": float(above / w.sum()) if w.sum() else float("nan"),
                        })
    return quantiles, pd.DataFrame(hrows)
