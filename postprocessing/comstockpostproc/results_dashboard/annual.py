# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Annual comparison: ComStock (Athena metadata table) vs CBECS wide.csv.

One fine-grained query groups by building type x census division x vintage x
climate zone; weighted sums are additive, so every single-dimension view rolls
up from that one result exactly. That keeps Athena to a single scan per run.

The Athena `weight` on published SDR tables is the StockE apportionment weight
(not rescaled to CBECS), so floor area runs a few percent above CBECS across the
board. That basis is reported rather than silently corrected.
"""

from __future__ import annotations

import logging

import numpy as np
import pandas as pd

from . import athena
from .metrics_def import (
    ALL_KWH_METRICS,
    BLDG_TYPE_COL,
    CEN_DIV_COL,
    CZ_COL,
    DERIVED,
    DIMENSIONS,
    GAS_TOTAL_COL,
    KWH_TO_TBTU,
    ORDERED_CATEGORIES,
    SQFT_COL,
    VINTAGE_COL,
    size_bin_sql,
)

logger = logging.getLogger(__name__)

GROUP_COLS = {
    "building_type": BLDG_TYPE_COL,
    "census_division": CEN_DIV_COL,
    "vintage": VINTAGE_COL,
    "climate_zone": CZ_COL,
}
# Dimensions computed in SQL rather than read from a column, keyed by the columns
# they need so availability can still be checked per table.
GROUP_EXPRS = {"size_bin": (size_bin_sql(), [SQFT_COL])}


def available_group_cols(md_table: str, no_cache: bool = False) -> dict[str, str]:
    """Which dimension columns this table actually has."""
    have = athena.table_columns(md_table, no_cache=no_cache)
    present = {a: c for a, c in GROUP_COLS.items() if c in have}
    for alias in GROUP_COLS.keys() - present.keys():
        logger.info("%s: no column for dimension %s — skipping that view", md_table, alias)
    return present


def build_annual_sql(md_table: str, group_cols: dict[str, str] | None = None,
                     have: set[str] | None = None,
                     base_where: str = athena.DEFAULT_BASE_WHERE) -> str:
    group_cols = group_cols or GROUP_COLS
    metrics = {k: c for k, (c, _p) in ALL_KWH_METRICS.items() if have is None or c in have}
    sel = [f'    "{col}" AS {alias}' for alias, col in group_cols.items()]
    for alias, (expr, needs) in GROUP_EXPRS.items():
        if have is None or all(c in have for c in needs):
            sel.append(f"    {expr} AS {alias}")
    sel.append('    SUM(weight) AS "bldg_count_weighted"')
    sel.append(f'    SUM(weight * "{SQFT_COL}") AS "sqft"')
    sel.append(
        f'    SUM(CASE WHEN COALESCE("{GAS_TOTAL_COL}", 0) = 0 '
        f'THEN weight * "{SQFT_COL}" ELSE 0 END) AS "sqft_zero_gas"'
    )
    for key, col in metrics.items():
        sel.append(f'    SUM(weight * "{col}") AS "{key}"')
    n_dims = len(group_cols) + sum(
        1 for _a, (_e, needs) in GROUP_EXPRS.items() if have is None or all(c in have for c in needs)
    )
    body = ",\n".join(sel)
    group = ", ".join(str(i + 1) for i in range(n_dims))
    return (
        f"SELECT\n{body}\n"
        f"FROM {md_table}\n"
        f"WHERE {base_where}\n"
        f"GROUP BY {group}\n"
        f"ORDER BY {group}"
    )


def fetch_comstock_annual(md_table: str, no_cache: bool = False) -> pd.DataFrame:
    """Fine-grained weighted totals: one row per available dimension combination."""
    have = athena.table_columns(md_table, no_cache=no_cache)
    cols = {a: c for a, c in GROUP_COLS.items() if c in have}
    missing = [k for k, (c, _p) in ALL_KWH_METRICS.items() if c not in have]
    if missing:
        logger.info("%s: no column for metrics %s", md_table, ", ".join(missing))
    sql = build_annual_sql(md_table, cols, have, athena.baseline_where(md_table, no_cache=no_cache))
    return athena.query(sql, no_cache=no_cache, label=f"annual by {len(cols)} dimensions")


def roll_up(fine: pd.DataFrame, dim: str) -> pd.DataFrame:
    """Sum the fine-grained frame to one dimension, plus an 'All' row."""
    dim_cols = set(GROUP_COLS) | set(GROUP_EXPRS)
    value_cols = [c for c in fine.columns if c not in dim_cols]
    agg = fine.groupby(dim, as_index=False)[value_cols].sum()
    agg = agg.rename(columns={dim: "category"})
    all_row = fine[value_cols].sum().to_frame().T
    all_row.insert(0, "category", "All")
    return pd.concat([agg, all_row], ignore_index=True)


def check_categories(fine: pd.DataFrame, dataset: str) -> dict:
    """Report values outside the canonical orderings instead of dropping them.

    The upstream package passes canonical lists to seaborn's `order=`, which
    silently discards anything unlisted — so a codebook spelling drift reads as
    "this group has no buildings" rather than as an error. Surfacing it here.
    """
    out = {}
    for dim in list(GROUP_COLS) + list(GROUP_EXPRS):
        canon = ORDERED_CATEGORIES.get(dim)
        if not canon or dim not in fine.columns:
            continue
        seen = {v for v in fine[dim].dropna().unique()}
        unknown = sorted(seen - set(canon))
        missing = sorted(set(canon) - seen)
        if unknown or missing:
            out[f"{dataset}.{dim}"] = {"unexpected_values": unknown, "absent_values": missing}
    return out


def _add_derived(long_df: pd.DataFrame, value_col: str) -> pd.DataFrame:
    extra = []
    for key, (components, _prov) in DERIVED.items():
        sub = long_df[long_df["metric"].isin(components)]
        if sub.empty:
            continue
        agg = sub.groupby("category", as_index=False)[value_col].sum(min_count=1)
        agg["metric"] = key
        extra.append(agg)
    if not extra:
        return long_df
    return pd.concat([long_df, *extra], ignore_index=True)


def build_comparison(
    comstock_agg: pd.DataFrame,
    cbecs_totals: pd.DataFrame | None,
    dim: str,
) -> pd.DataFrame:
    """Tidy comparison for one dimension. cbecs_totals=None -> ComStock-only view."""
    metric_keys = ["sqft"] + list(ALL_KWH_METRICS.keys())
    cs_long = comstock_agg.melt(
        id_vars=["category"],
        value_vars=[k for k in metric_keys if k in comstock_agg.columns],
        var_name="metric", value_name="comstock_value",
    )
    cs_long = _add_derived(cs_long, "comstock_value")

    if cbecs_totals is None:
        comp = cs_long.copy()
        for c in ["cbecs_value", "cbecs_se", "cbecs_rse_pct", "cbecs_ci95_low", "cbecs_ci95_high"]:
            comp[c] = np.nan
    else:
        cb_long = _add_derived(cbecs_totals[["category", "metric", "cbecs_value"]], "cbecs_value")
        cb_ci = cbecs_totals[["category", "metric", "cbecs_se", "cbecs_rse_pct",
                              "cbecs_ci95_low", "cbecs_ci95_high"]]
        comp = cs_long.merge(cb_long.merge(cb_ci, on=["category", "metric"], how="left"),
                             on=["category", "metric"], how="outer")

    prov = {k: p for k, (_c, p) in ALL_KWH_METRICS.items()}
    prov.update({k: p for k, (_c, p) in DERIVED.items()})
    prov["sqft"] = "measured"
    comp["provenance"] = comp["metric"].map(prov)
    comp["dimension"] = dim

    energy = comp["metric"] != "sqft"
    for c in ["comstock_value", "cbecs_value", "cbecs_se", "cbecs_ci95_low", "cbecs_ci95_high"]:
        comp.loc[energy, c] = comp.loc[energy, c] * KWH_TO_TBTU

    # EUI per category, each side on its OWN floor area. This is what separates an
    # intensity error from a prevalence error: if the EUIs agree but the totals do
    # not, the discrepancy is in how much floor area the segment has, not in how
    # the buildings behave. TBtu * 1e9 / ft2 = kBtu/ft2.
    sq = comp[comp["metric"] == "sqft"].set_index("category")
    for side in ("comstock", "cbecs"):
        area = comp["category"].map(sq[f"{side}_value"])
        comp[f"{side}_eui"] = np.where(
            energy & area.notna() & (area > 0), comp[f"{side}_value"] * 1e9 / area, np.nan)
    comp["eui_pct_diff"] = 100.0 * (comp["comstock_eui"] - comp["cbecs_eui"]) / comp["cbecs_eui"]

    comp["pct_diff"] = 100.0 * (comp["comstock_value"] - comp["cbecs_value"]) / comp["cbecs_value"]
    comp["within_cbecs_ci95"] = (
        (comp["comstock_value"] >= comp["cbecs_ci95_low"])
        & (comp["comstock_value"] <= comp["cbecs_ci95_high"])
    ).astype("boolean")
    comp.loc[comp["cbecs_ci95_low"].isna() | comp["comstock_value"].isna(), "within_cbecs_ci95"] = pd.NA

    order = ORDERED_CATEGORIES.get(dim)
    if order:
        rank = {c: i for i, c in enumerate(order)}
        comp["_r"] = comp["category"].map(lambda c: rank.get(c, 998) if c != "All" else 999)
        comp = comp.sort_values(["_r", "category", "metric"]).drop(columns="_r")
    return comp.reset_index(drop=True)


# Two-dimensional rollups: every building type crossed with each of these bins.
# Restricted to the headline metrics so the tables stay light; the single-dim
# tables keep the full metric set.
PAIR_DIMS = ["vintage", "census_division", "size_bin"]
PAIR_METRICS = ["sqft", "electricity.total", "natural_gas.total", "site_energy.total"]


def roll_up_pair(fine: pd.DataFrame, dim: str) -> pd.DataFrame:
    """Sum the fine-grained frame to (building_type x dim)."""
    dim_cols = set(GROUP_COLS) | set(GROUP_EXPRS)
    value_cols = [c for c in fine.columns if c not in dim_cols]
    agg = fine.groupby(["building_type", dim], as_index=False, dropna=True)[value_cols].sum()
    return agg.rename(columns={dim: "category"})


def build_pair_comparison(cs_agg: pd.DataFrame, cbecs_pair: pd.DataFrame | None,
                          dim: str) -> pd.DataFrame:
    """Tidy comparison keyed on (building_type, category) for the headline metrics."""
    keep = [m for m in PAIR_METRICS if m in cs_agg.columns]
    cs_long = cs_agg.melt(id_vars=["building_type", "category"], value_vars=keep,
                          var_name="metric", value_name="comstock_value")
    if cbecs_pair is not None:
        comp = cs_long.merge(cbecs_pair, on=["building_type", "category", "metric"], how="outer")
    else:
        comp = cs_long.copy()
        for c in ["cbecs_value", "cbecs_ci95_low", "cbecs_ci95_high"]:
            comp[c] = np.nan
    comp["dimension"] = f"building_type_x_{dim}"

    energy = comp["metric"] != "sqft"
    for c in ["comstock_value", "cbecs_value", "cbecs_ci95_low", "cbecs_ci95_high"]:
        comp.loc[energy, c] = comp.loc[energy, c] * KWH_TO_TBTU

    # Per-cell EUI on each side's own floor area, exactly as in build_comparison.
    sq = comp[comp["metric"] == "sqft"].set_index(["building_type", "category"])
    idx = pd.MultiIndex.from_frame(comp[["building_type", "category"]])
    for side in ("comstock", "cbecs"):
        area = pd.Series(idx.map(sq[f"{side}_value"]), index=comp.index)
        comp[f"{side}_eui"] = np.where(
            energy & area.notna() & (area > 0), comp[f"{side}_value"] * 1e9 / area, np.nan)
    comp["eui_pct_diff"] = 100.0 * (comp["comstock_eui"] - comp["cbecs_eui"]) / comp["cbecs_eui"]
    comp["pct_diff"] = 100.0 * (comp["comstock_value"] - comp["cbecs_value"]) / comp["cbecs_value"]

    order = ORDERED_CATEGORIES.get(dim)
    if order:
        rank = {c: i for i, c in enumerate(order)}
        comp["_r"] = comp["category"].map(lambda c: rank.get(c, 998))
        comp = comp.sort_values(["building_type", "_r", "category", "metric"]).drop(columns="_r")
    return comp.reset_index(drop=True)


def build_fuel_mix(comstock_agg: pd.DataFrame, cbecs_diag: pd.DataFrame | None) -> pd.DataFrame:
    fm = comstock_agg[["category", "sqft", "sqft_zero_gas"]].copy()
    fm["comstock_zero_gas_share"] = fm["sqft_zero_gas"] / fm["sqft"]
    if cbecs_diag is not None:
        fm = fm.merge(
            cbecs_diag[["category", "zero_gas_share"]].rename(
                columns={"zero_gas_share": "cbecs_zero_gas_share"}),
            on="category", how="left")
    else:
        fm["cbecs_zero_gas_share"] = np.nan
    return fm
