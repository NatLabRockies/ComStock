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
from scipy import sparse

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

    Returns tidy rows: [by, metric, estimate, se, rse_pct, ci95_low, ci95_high],
    group-major in the groupby's sorted order.

    CBECS leaves consumption BLANK for a building that does not use the fuel or
    end use, so a blank in a published column counts as zero, and a group with
    no users totals zero with zero variance. Measured on CBECS 2018 wide: every
    blank natural-gas total falls on "Natural gas used = No" (1,102 of 1,102),
    every blank electricity total on "Electricity used = No" (42 of 42). A column
    CBECS does not publish at all -- blank in EVERY record of the frame, e.g.
    propane -- is NaN in every group, never zero. "Published" is decided over
    the whole frame rather than per group: deciding it per group turned a group
    with no users of a fuel into "no value" instead of 0.

    Every column is converted to numbers once, and the group sums are one sparse
    product (groups x records) per metric. Converting inside a per-group loop cost
    about a minute per dashboard build.
    """
    reps = replicate_cols(df)
    kappa = (len(reps) - 1) / len(reps)
    num = lambda cols: df[cols].apply(pd.to_numeric, errors="coerce").to_numpy(float)
    vals = num(value_cols)                                  # n x m
    published = ~np.isnan(vals).all(axis=0)
    x = np.nan_to_num(vals, nan=0.0)                        # blank = not used = 0
    w = np.nan_to_num(pd.to_numeric(df[weight_col], errors="coerce").to_numpy(float))
    rep_w = np.nan_to_num(num(reps))                        # n x R

    gb = df.groupby(by, dropna=False, observed=True)
    codes = gb.ngroup().to_numpy()
    keys = gb.size().index                                  # ngroup numbering order
    k, m = len(keys), len(value_cols)
    G = sparse.csr_matrix((np.ones(len(df)), (codes, np.arange(len(df)))), shape=(k, len(df)))
    theta = np.asarray(G @ (x * w[:, None]))                # k x m
    se = np.empty((k, m))
    for i in range(m):
        rep_theta = np.asarray(G @ (x[:, [i]] * rep_w))     # k x R
        se[:, i] = np.sqrt(kappa * ((rep_theta - theta[:, [i]]) ** 2).sum(axis=1))

    est = np.where(published[None, :], theta, np.nan)
    s = np.where(published[None, :], se, np.nan)
    # A zero total means no surveyed record in the group uses it, so every
    # replicate is zero too and the SE is 0 by construction, not by precision.
    # Report no interval: a [0, 0] "CI" made any ComStock value a significant
    # gap on the strength of as little as one building.
    s = np.where(est == 0.0, np.nan, s)
    has_ci = ~np.isnan(est) & ~np.isnan(s)
    with np.errstate(divide="ignore", invalid="ignore"):
        rse = np.where(has_ci & (est != 0), 100.0 * s / est, np.nan)
    lo = np.where(has_ci, np.maximum(est - 1.96 * s, 0.0), np.nan)
    hi = np.where(has_ci, est + 1.96 * s, np.nan)
    return pd.DataFrame({
        by: keys.repeat(m).tolist(),
        "metric_col": value_cols * k,
        "estimate": est.ravel(),
        "se": s.ravel(),
        "rse_pct": rse.ravel(),
        "ci95_low": lo.ravel(),
        "ci95_high": hi.ravel(),
    })
