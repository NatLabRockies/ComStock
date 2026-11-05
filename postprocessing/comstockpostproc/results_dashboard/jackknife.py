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

    CBECS leaves consumption BLANK for a building that does not use the fuel or
    end use, so a blank in a published column counts as zero, and a group with
    no users totals zero with zero variance. Measured on CBECS 2018 wide: every
    blank natural-gas total falls on "Natural gas used = No" (1,102 of 1,102),
    every blank electricity total on "Electricity used = No" (42 of 42). A column
    CBECS does not publish at all -- blank in EVERY record of the frame, e.g.
    propane -- is NaN in every group, never zero. "Published" is decided over
    the whole frame rather than per group: deciding it per group turned a group
    with no users of a fuel into "no value" instead of 0.
    """
    reps = replicate_cols(df)
    kappa = (len(reps) - 1) / len(reps)
    published = df[value_cols].apply(pd.to_numeric, errors="coerce").notna().any(axis=0).to_numpy()
    rows = []
    for key, g in df.groupby(by, dropna=False, observed=True):
        w = pd.to_numeric(g[weight_col], errors="coerce").to_numpy(float)
        rep_w = g[reps].apply(pd.to_numeric, errors="coerce").to_numpy(float)  # n x R
        vals = g[value_cols].apply(pd.to_numeric, errors="coerce").to_numpy(float)  # n x m
        x = np.nan_to_num(vals, nan=0.0)                   # blank = not used = 0
        theta = x.T @ np.nan_to_num(w)                     # m
        rep_theta = x.T @ np.nan_to_num(rep_w)             # m x R
        var = kappa * ((rep_theta - theta[:, None]) ** 2).sum(axis=1)
        se = np.sqrt(var)
        for i, m in enumerate(value_cols):
            est = float(theta[i]) if published[i] else np.nan
            s = float(se[i]) if published[i] else np.nan
            # A zero total means no surveyed record in the group uses it, so every
            # replicate is zero too and the SE is 0 by construction, not by
            # precision. Report no interval: a [0, 0] "CI" made any ComStock value
            # a significant gap on the strength of as little as one building.
            if est == 0.0:
                s = np.nan
            has_ci = est == est and s == s
            rows.append({
                by: key,
                "metric_col": m,
                "estimate": est,
                "se": s,
                "rse_pct": (100.0 * s / est) if has_ci and est else np.nan,
                "ci95_low": max(est - 1.96 * s, 0.0) if has_ci else np.nan,
                "ci95_high": est + 1.96 * s if has_ci else np.nan,
            })
    return pd.DataFrame(rows)
