"""CBECS reference loader.

Consumes `output/CBECS 2018/CBECS wide.csv` as produced by comstockpostproc's
CBECS class (already decoded, renamed to ComStock column names, and carrying the
151 jackknife replicate weights). Restricted to ComStock building types,
mirroring remove_non_comstock_bldg_types_from_cbecs=True in the published
comparisons.

Dimension caveats verified against the file and cbecs.py:
  - census division and vintage are ComStock-normalized and safe to group on
  - there is NO ASHRAE/IECC climate zone: CBECS public-use microdata suppresses
    sub-regional geography, so census division is its finest geography
  - in.hvac_system_type is ~37% null (partial external crosswalk), so it is not
    offered as a comparison dimension
"""

from __future__ import annotations

import logging

import numpy as np
import pandas as pd

from .jackknife import grouped_totals_with_ci
from .metrics_def import (
    ALL_KWH_METRICS,
    BLDG_TYPE_COL,
    COMSTOCK_BLDG_TYPES,
    DIMENSIONS,
    GAS_TOTAL_COL,
    SIZE_BIN_EDGES,
    SIZE_BIN_LABELS,
    SQFT_COL,
)

logger = logging.getLogger(__name__)


def load_cbecs_wide(path: str) -> pd.DataFrame:
    # Header names contain embedded commas inside quotes, so this must go through
    # a real CSV parser rather than a naive split.
    df = pd.read_csv(path, low_memory=False)
    n_all = len(df)
    df = df[df[BLDG_TYPE_COL].isin(COMSTOCK_BLDG_TYPES)].copy()
    # Same derived floor-area bins as the ComStock side, from the same edges.
    df["size_bin"] = pd.cut(
        pd.to_numeric(df[SQFT_COL], errors="coerce"),
        bins=SIZE_BIN_EDGES, labels=SIZE_BIN_LABELS, right=True, include_lowest=True
    ).astype(object)
    logger.info("CBECS wide: %d records, %d in ComStock building types", n_all, len(df))
    return df


def aggregate_cbecs(df: pd.DataFrame, dim: str) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Weighted totals + jackknife CIs for one dimension, plus an 'All' row.

    Returns (totals, diagnostics):
      totals: [category, metric, cbecs_value, cbecs_se, cbecs_rse_pct,
               cbecs_ci95_low, cbecs_ci95_high]   (kWh; sqft in ft2)
      diagnostics: [category, sqft_weighted, sqft_zero_gas_weighted, zero_gas_share]
    """
    spec = DIMENSIONS[dim]
    if not spec["cbecs"]:
        raise ValueError(f"CBECS has no {dim} column; this dimension is ComStock-only")
    col = spec["col"]
    if col not in df.columns:
        raise KeyError(f"CBECS wide.csv has no column {col!r}")

    metric_cols = {k: c for k, (c, _) in ALL_KWH_METRICS.items() if c in df.columns}
    missing = [k for k, (c, _) in ALL_KWH_METRICS.items() if c not in df.columns]
    if missing:
        logger.info("CBECS wide lacks columns for: %s", ", ".join(missing))
    value_cols = [SQFT_COL] + list(metric_cols.values())

    frames = []
    for scope_df, by in [(df, col), (df.assign(_all="All"), "_all")]:
        res = grouped_totals_with_ci(scope_df, value_cols, by=by, weight_col="weight")
        frames.append(res.rename(columns={by: "category"}))
    res = pd.concat(frames, ignore_index=True)

    col_to_key = {c: k for k, c in metric_cols.items()}
    col_to_key[SQFT_COL] = "sqft"
    res["metric"] = res["metric_col"].map(col_to_key)
    totals = res[["category", "metric", "estimate", "se", "rse_pct", "ci95_low", "ci95_high"]].rename(
        columns={"estimate": "cbecs_value", "se": "cbecs_se", "rse_pct": "cbecs_rse_pct",
                 "ci95_low": "cbecs_ci95_low", "ci95_high": "cbecs_ci95_high"}
    )

    w = pd.to_numeric(df["weight"], errors="coerce").fillna(0.0)
    sqft = pd.to_numeric(df[SQFT_COL], errors="coerce").fillna(0.0)
    gas = pd.to_numeric(df.get(GAS_TOTAL_COL), errors="coerce").fillna(0.0)
    diag = pd.DataFrame({
        "category": df[col].values,
        "sqft_weighted": (w * sqft).values,
        "sqft_zero_gas_weighted": np.where(gas.values == 0.0, (w * sqft).values, 0.0),
    })
    diag = pd.concat([diag, diag.assign(category="All")]).groupby("category", as_index=False).sum()
    diag["zero_gas_share"] = diag["sqft_zero_gas_weighted"] / diag["sqft_weighted"]
    return totals, diag


PAIR_METRIC_KEYS = ["electricity.total", "natural_gas.total", "site_energy.total"]


def aggregate_cbecs_pair(df: pd.DataFrame, dim: str) -> pd.DataFrame:
    """Weighted totals + jackknife CIs per (building type x dim category).

    Cells get small (a few CBECS records each), so the intervals are wide — that
    is honest, and the whiskers carry it. Returns [building_type, category,
    metric, cbecs_value, cbecs_ci95_low, cbecs_ci95_high] in kWh / ft2.
    """
    col = DIMENSIONS[dim]["col"]
    metric_cols = {k: ALL_KWH_METRICS[k][0] for k in PAIR_METRIC_KEYS
                   if ALL_KWH_METRICS[k][0] in df.columns}
    value_cols = [SQFT_COL] + list(metric_cols.values())
    sub = df[df[col].notna()].copy()
    sub["_pair"] = sub[BLDG_TYPE_COL].astype(str) + "||" + sub[col].astype(str)
    res = grouped_totals_with_ci(sub, value_cols, by="_pair", weight_col="weight")
    parts = res["_pair"].str.split("||", regex=False, expand=True)
    res["building_type"], res["category"] = parts[0], parts[1]
    col_to_key = {c: k for k, c in metric_cols.items()}
    col_to_key[SQFT_COL] = "sqft"
    res["metric"] = res["metric_col"].map(col_to_key)
    return res[["building_type", "category", "metric", "estimate", "ci95_low", "ci95_high"]].rename(
        columns={"estimate": "cbecs_value", "ci95_low": "cbecs_ci95_low",
                 "ci95_high": "cbecs_ci95_high"})


def observed_categories(df: pd.DataFrame, dim: str) -> set:
    spec = DIMENSIONS[dim]
    if not spec["cbecs"] or spec["col"] not in df.columns:
        return set()
    return {v for v in df[spec["col"]].dropna().unique()}
