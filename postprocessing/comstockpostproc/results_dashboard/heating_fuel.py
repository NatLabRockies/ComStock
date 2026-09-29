# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Main heating fuel prevalence: ComStock vs CBECS 2018, by census division.

WHY THIS IS ITS OWN MODULE. Heating fuel is the one design input where the two
sides describe the stock with different vocabularies, and every mismatch is easy
to paper over:

  * CBECS records main heating fuel as SEVEN INDEPENDENT yes/no flags, one per
    fuel, so in principle a building can report several. In the ComStock-restricted
    `CBECS wide.csv` it behaves as a single choice -- of 3,891 heated records 3,886
    flag exactly one fuel, none flag two, five flag none -- so a partition
    comparison is legitimate. That is a property of THIS file, re-verified on every
    run by `_check_single_choice` rather than assumed: if a future CBECS vintage
    reports several fuels for one building, that building's floor area is split
    equally among them (so the shares still sum to 100%) and the check counts and
    warns about every such record instead of hiding them.
  * CBECS splits district heat into STEAM and HOT WATER; ComStock has a single
    `DistrictHeating`. The two CBECS categories are summed to match it.
  * CBECS has a WOOD category that ComStock cannot represent. It is kept as its
    own fuel rather than folded into "other", so a gap that exists stays visible.
  * DENOMINATORS DIFFER, and this is the trap. CBECS reports ~7.8% of floor area as
    having no main heating at all; ComStock assigns a heating fuel to every model
    and so has no unheated stock to report. Shares are therefore taken over HEATED
    floor area, the closest like-for-like, and the excluded unheated share travels
    with the frame so the dashboard can state what was dropped instead of quietly
    dropping it.

Everything is FLOOR-AREA weighted (`weight * sqft`), matching cbecs_ref and the
rest of the tool: a fuel's prevalence is the share of square footage it heats, not
the share of buildings, because buildings differ in size by orders of magnitude
and the energy follows the area.
"""

from __future__ import annotations

import logging

import numpy as np
import pandas as pd

from . import athena

logger = logging.getLogger(__name__)

BLDG_TYPE_COL = "in.comstock_building_type"
DIV_COL = "in.census_division_name"
SQFT_COL = "in.sqft..ft2"

# Canonical fuel names, in stacking and tabulation order. Ordered by national
# prevalence so the largest segment reads first and the long tail stays adjacent.
FUEL_ORDER = ["Natural gas", "Electricity", "District heating",
              "Fuel oil", "Propane", "Wood"]

# CBECS flag column -> canonical fuel. The two district columns collapse onto one.
CBECS_FUEL_COLS = {
    "Natural gas used for main heating": "Natural gas",
    "Electricity used for main heating": "Electricity",
    "District steam used for main heating": "District heating",
    "District hot water used for main heating": "District heating",
    "Fuel oil used for main heating": "Fuel oil",
    "Propane used for main heating": "Propane",
    "Wood used for main heating": "Wood",
}
CBECS_HEATED_COL = "Energy used for main heating"

# ComStock in.heating_fuel value -> canonical fuel.
COMSTOCK_FUEL_MAP = {
    "NaturalGas": "Natural gas",
    "Electricity": "Electricity",
    "DistrictHeating": "District heating",
    "FuelOil": "Fuel oil",
    "Propane": "Propane",
    "Wood": "Wood",
}

CBECS_RUN_KEY = "cbecs_2018"

# Below this many CBECS records behind the whole cell, a division x building-type
# share is too thin to read. Set at 30 rather than 20 after finding that
# Warehouse x New England rests on exactly 20 surveyed buildings split four ways
# -- 7 gas, 6 propane, 4 electricity, 3 fuel oil -- and yields a +/-36 pp
# "regional finding" off three-building shares. A cell total is only a coarse
# guard, so THIN_FUEL_N below flags the individual share as well.
THIN_N = 30
# Below this many CBECS records for ONE fuel, that fuel's own share is noise
# regardless of how large the cell around it is.
THIN_FUEL_N = 5


def _canonical_flags(df: pd.DataFrame) -> pd.DataFrame:
    """One 0/1 column per CANONICAL fuel. District steam and district hot water
    are one fuel here, so a record flagging both counts once, not twice."""
    out = {}
    for col, canon in CBECS_FUEL_COLS.items():
        if col in df.columns:
            f = (df[col] == "Yes").astype(int)
            out[canon] = f if canon not in out else (out[canon] | f)
    return pd.DataFrame(out, index=df.index)


def _check_single_choice(df: pd.DataFrame, heated: pd.Series) -> dict:
    """Verify CBECS main heating fuel behaves as a single choice in THIS file."""
    n_fuels = _canonical_flags(df).sum(axis=1)
    h = heated.to_numpy()
    rep = {
        "heated_records": int(h.sum()),
        "exactly_one_fuel": int(((n_fuels == 1).to_numpy() & h).sum()),
        "multiple_fuels": int(((n_fuels > 1).to_numpy() & h).sum()),
        "no_fuel_flagged": int(((n_fuels == 0).to_numpy() & h).sum()),
    }
    if rep["multiple_fuels"]:
        logger.warning(
            "CBECS: %d heated records flag MORE THAN ONE main heating fuel; each "
            "one's floor area and record count are split equally among its fuels, "
            "so the shares still sum to 100%%",
            rep["multiple_fuels"])
    if rep["no_fuel_flagged"]:
        logger.info(
            "CBECS: %d heated records flag no main heating fuel; they hold heated "
            "area but no fuel and are excluded from both share numerator and "
            "denominator", rep["no_fuel_flagged"])
    return rep


def cbecs_heating_fuel(cbecs_df: pd.DataFrame) -> tuple[pd.DataFrame, dict]:
    """Floor-area-weighted main-heating-fuel shares from CBECS wide.

    Returns (long frame, provenance dict), one row per
    (btype, dimension, category, fuel).
    """
    d = cbecs_df
    missing = [c for c in list(CBECS_FUEL_COLS) + [CBECS_HEATED_COL]
               if c not in d.columns]
    if missing:
        raise KeyError(f"CBECS wide is missing heating columns: {missing[:3]}")

    w = pd.to_numeric(d["weight"], errors="coerce").fillna(0.0)
    sqft = pd.to_numeric(d[SQFT_COL], errors="coerce").fillna(0.0)
    area = (w * sqft).to_numpy()
    heated = (d[CBECS_HEATED_COL] == "Yes")

    prov = _check_single_choice(d, heated)
    tot_area = float(area.sum())
    prov["unheated_area_share_pct"] = (
        float(100.0 * area[~heated.to_numpy()].sum() / tot_area)
        if tot_area else float("nan"))

    # One row per (record, flagged canonical fuel). A record that flags k fuels
    # contributes 1/k of its FLOOR AREA to each, so the shares stay a partition
    # and no fuel wins by being listed first; the count of such records is
    # reported above. Record counts stay whole: `n` is how many surveyed
    # buildings report the fuel (the thin-fuel guard), and `rec` (1/k) lets the
    # cell's record count count each building once. A record with no fuel flagged
    # keeps one row with no fuel, which the shares leave out. None of the 3,891
    # heated records in CBECS 2018 flags more than one fuel.
    flags = _canonical_flags(d)
    k = flags.sum(axis=1).to_numpy()
    common = {"btype_col": d[BLDG_TYPE_COL].astype(object).to_numpy(),
              "division": d[DIV_COL].astype(object).to_numpy(),
              "heated": heated.to_numpy()}
    parts = []
    for canon in flags.columns:
        on = flags[canon].to_numpy() == 1
        if on.any():
            frac = 1.0 / k[on]
            parts.append(pd.DataFrame({key: v[on] for key, v in common.items()}
                                      | {"fuel": canon, "area": area[on] * frac,
                                         "n": 1.0, "rec": frac}))
    none = k == 0
    parts.append(pd.DataFrame({key: v[none] for key, v in common.items()}
                              | {"fuel": pd.NA, "area": area[none], "n": 1.0, "rec": 1.0}))
    base = pd.concat(parts, ignore_index=True)
    return _long_shares(base, run=CBECS_RUN_KEY, dataset="cbecs"), prov


def comstock_heating_fuel(md_table: str, run_key: str,
                          no_cache: bool = False) -> pd.DataFrame:
    """The same shares from a ComStock metadata table.

    Grouped in SQL rather than pulled per model: the aggregate is nine divisions
    x fifteen building types x five fuels, a few hundred rows instead of a few
    hundred thousand.
    """
    sql = f"""
SELECT "{BLDG_TYPE_COL}"          AS btype_col,
       "{DIV_COL}"                AS division,
       "in.heating_fuel"          AS fuel_raw,
       SUM(weight * "{SQFT_COL}") AS area,
       COUNT(DISTINCT bldg_id)    AS n
FROM {md_table}
WHERE {athena.baseline_where(md_table, no_cache=no_cache)}
GROUP BY 1, 2, 3
"""
    g = athena.query(sql, no_cache=no_cache, label=f"heating fuel {run_key}")
    if g.empty:
        return pd.DataFrame()

    unknown = sorted(set(g["fuel_raw"].dropna().astype(str)) - set(COMSTOCK_FUEL_MAP))
    if unknown:
        # Never bucket an unrecognised fuel into an existing one: carry it under
        # its own name so it reads as unaccounted rather than inflating gas.
        logger.warning("ComStock %s: unmapped in.heating_fuel values %s -- "
                       "carried verbatim", run_key, unknown)
    g["fuel"] = g["fuel_raw"].astype(str).map(
        lambda v: COMSTOCK_FUEL_MAP.get(v, v))
    g["heated"] = True
    return _long_shares(g[["btype_col", "division", "fuel", "area", "heated", "n"]],
                        run=run_key, dataset="comstock")


def _long_shares(base: pd.DataFrame, run: str, dataset: str) -> pd.DataFrame:
    """Collapse a record- or cell-level frame into shares at every scope.

    Four scopes, so the dashboard can answer the same question nationally and
    regionally, for the whole stock and for a single building type, with no
    second query: (btype All | one type) x (dimension none | census_division).
    """
    b = base.copy()
    if "n" not in b.columns:
        b["n"] = 1
    # Records behind a cell. The CBECS side passes `rec` because one building
    # can span several fuel rows; everywhere else a row is its own count.
    if "rec" not in b.columns:
        b["rec"] = b["n"]

    # Shares are over heated area WITH A KNOWN FUEL. Unheated area and
    # fuel-unknown area leave both the numerator and the denominator, and are
    # reported separately, so no share is diluted by a category the other side
    # cannot express.
    usable = b[b["heated"].astype(bool) & b["fuel"].notna()]
    if usable.empty:
        return pd.DataFrame()

    scopes = [("All", usable)]
    scopes += [(t, usable[usable["btype_col"] == t])
               for t in sorted(usable["btype_col"].dropna().unique())]

    out = []
    for btype_label, sub in scopes:
        if sub.empty:
            continue
        for dim, keys in (("none", []), ("census_division", ["division"])):
            grp = sub.groupby(keys + ["fuel"], dropna=True, observed=True).agg(
                area=("area", "sum"), n=("n", "sum"), rec=("rec", "sum")).reset_index()
            if grp.empty:
                continue
            cat = (grp["division"] if keys
                   else pd.Series("National", index=grp.index))
            grp = grp.assign(category=cat.astype(object))
            tot = grp.groupby("category", observed=True)["area"].transform("sum")
            grp["area_share_pct"] = np.where(tot > 0, 100.0 * grp["area"] / tot,
                                             np.nan)
            # Records behind the WHOLE cell, not just this fuel: that is what
            # decides whether the cell is too thin to trust.
            grp["cell_n"] = grp.groupby("category", observed=True)["rec"].transform("sum")
            out.append(grp.assign(dataset=dataset, run=run, btype=btype_label,
                                  dimension=dim)[
                ["dataset", "run", "btype", "dimension", "category", "fuel",
                 "area", "area_share_pct", "n", "cell_n"]])
    if not out:
        return pd.DataFrame()
    res = pd.concat(out, ignore_index=True)
    res["thin"] = (res["dataset"] == "cbecs") & (res["cell_n"] < THIN_N)
    return res


def assess_heating_fuel(cbecs_df: pd.DataFrame, runs, no_cache: bool = False
                        ) -> tuple[pd.DataFrame, dict]:
    """CBECS plus every run in one long frame, with the CBECS provenance."""
    parts = []
    cb, prov = cbecs_heating_fuel(cbecs_df)
    if not cb.empty:
        parts.append(cb)
    for r in runs:
        try:
            cs = comstock_heating_fuel(r.md_table, r.key, no_cache=no_cache)
        except Exception as exc:                              # noqa: BLE001
            logger.warning("  %s: heating fuel failed (%s); skipping", r.key, exc)
            continue
        if not cs.empty:
            parts.append(cs)
    if not parts:
        return pd.DataFrame(), prov
    return pd.concat(parts, ignore_index=True), prov
