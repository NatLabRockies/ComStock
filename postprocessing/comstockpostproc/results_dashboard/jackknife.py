# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""CBECS jackknife replicate-weight confidence intervals.

Port of the variance math in ComStock's comstockpostproc/rse_utils_mixin.py
(EIA CBECS 2018 Technical Documentation, "Use of Replicate Weights"):

    Var(theta) = kappa * sum_r (theta_r - theta)^2,   kappa = (R-1)/R

Vectorized over many value columns at once: for each group we compute the
full-sample weighted total and the R replicate totals per metric.
"""

from __future__ import annotations

import re

import numpy as np
import pandas as pd

REP_RE = re.compile(r"^Unknown Eligibility and Nonresponse Adjusted Replicate Weight (\d+)$")


def replicate_cols(df: pd.DataFrame) -> list[str]:
    cols = [c for c in df.columns if REP_RE.match(c)]
    if not cols:
        raise ValueError("No CBECS replicate weight columns found.")
    cols.sort(key=lambda c: int(REP_RE.match(c).group(1)))
    return cols


def grouped_totals_with_ci(
    df: pd.DataFrame,
    value_cols: list[str],
    by: str,
    weight_col: str = "weight",
) -> pd.DataFrame:
    """Weighted totals of each value column per group, with jackknife 95% CIs.

    Returns tidy rows: [by, metric, estimate, se, rse_pct, ci95_low, ci95_high].
    NaN values contribute zero to totals (CBECS NaN = not surveyed); a group
    where a metric is entirely NaN yields estimate NaN.
    """
    reps = replicate_cols(df)
    kappa = (len(reps) - 1) / len(reps)
    rows = []
    for key, g in df.groupby(by, dropna=False, observed=True):
        w = pd.to_numeric(g[weight_col], errors="coerce").to_numpy(float)
        rep_w = g[reps].apply(pd.to_numeric, errors="coerce").to_numpy(float)  # n x R
        vals = g[value_cols].apply(pd.to_numeric, errors="coerce").to_numpy(float)  # n x m
        all_nan = np.isnan(vals).all(axis=0)
        x = np.nan_to_num(vals, nan=0.0)
        theta = x.T @ np.nan_to_num(w)                     # m
        rep_theta = x.T @ np.nan_to_num(rep_w)             # m x R
        var = kappa * ((rep_theta - theta[:, None]) ** 2).sum(axis=1)
        se = np.sqrt(var)
        for i, m in enumerate(value_cols):
            est = np.nan if all_nan[i] else float(theta[i])
            s = np.nan if all_nan[i] else float(se[i])
            rows.append({
                by: key,
                "metric_col": m,
                "estimate": est,
                "se": s,
                "rse_pct": (100.0 * s / est) if est else np.nan,
                "ci95_low": max(est - 1.96 * s, 0.0) if est == est else np.nan,
                "ci95_high": est + 1.96 * s if est == est else np.nan,
            })
    return pd.DataFrame(rows)
