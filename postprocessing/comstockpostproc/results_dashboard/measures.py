# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Measure (upgrade) assessment, downstream of the published metadata tables.

QAQC-first: where do savings occur (end use x fuel, bills, emissions), and do
the per-building percent-savings distributions look physical. Comparisons follow
the Mode-2 population rule from the data-queries skill: a measure's baseline is
the baseline rows of the buildings present in that measure's upgrade partition
(non-applicable buildings are absent from upgrade partitions), so baseline and
measure always describe the same buildings.

All `calc.weighted.*` columns are already weight-multiplied per row, so national
totals are plain SUMs. `upgrade` is compared in the column's own type, probed
per table (see `up_in`): a CAST on a partition column can stop Athena pruning
partitions. Measured on the 2025 R3 tables the win was nil — the national
metadata table is not partitioned at all, and the timeseries table (partitioned
on upgrade, state) ran the same either way — but the typed comparison is kept
so a future partitioned table cannot silently full-scan.
"""

from __future__ import annotations

import logging
import re

import numpy as np
import pandas as pd

from . import athena
from .distributions import kde_json, outlier_json, weighted_quantile
from .metrics_def import BLDG_TYPE_COL, ENDUSE_STACK_ORDER, SQFT_COL, TS_ENDUSE_COL
from .timeseries import (bldg_col, enduse_sums, hour_trunc, join_on,
                         state_filter, total_sum, ts_dialect)

logger = logging.getLogger(__name__)

FUELS = ["electricity", "natural_gas"]
# Fuel order within an end-use group in the fuel x end-use stacked figure,
# matching the measure-pack chart (electricity first, districts, then fossil).
FUELS_ALL = ["electricity", "district_cooling", "district_heating",
             "natural_gas", "fuel_oil", "propane"]

# Emissions and bill detail keyed for the GHG (three electricity factors) and
# utility-bill (three electricity rates) figures.
EMISSIONS_DETAIL = {
    "egrid": "calc.weighted.emissions.electricity.egrid_2021_subregion..co2e_mmt",
    "lrmer_high": "calc.weighted.emissions.electricity.lrmer_high_re_cost_15_2023_start..co2e_mmt",
    "lrmer_low": "calc.weighted.emissions.electricity.lrmer_low_re_cost_15_2023_start..co2e_mmt",
    "natural_gas": "calc.weighted.emissions.natural_gas..co2e_mmt",
    "fuel_oil": "calc.weighted.emissions.fuel_oil..co2e_mmt",
    "propane": "calc.weighted.emissions.propane..co2e_mmt",
    "district_heating": "calc.weighted.emissions.district_heating..co2e_mmt",
    "district_cooling": "calc.weighted.emissions.district_cooling..co2e_mmt",
}
BILL_DETAIL = {
    "elec_max": "calc.weighted.utility_bills.electricity_bill_max..billion_usd",
    "elec_mean": "calc.weighted.utility_bills.electricity_bill_mean..billion_usd",
    "elec_min": "calc.weighted.utility_bills.electricity_bill_min..billion_usd",
    "natural_gas": "calc.weighted.utility_bills.natural_gas_bill_state_average..billion_usd",
    "fuel_oil": "calc.weighted.utility_bills.fuel_oil_bill_state_average..billion_usd",
    "propane": "calc.weighted.utility_bills.propane_bill_state_average..billion_usd",
    "total_mean": "calc.weighted.utility_bills.total_bill_mean..billion_usd",
}
# Candidate end uses per fuel; the actual set is intersected with the table.
EU_CANDIDATES = ENDUSE_STACK_ORDER + ["exterior_equipment"]

BILL_MEAN_COL = "calc.weighted.utility_bills.total_bill_mean..billion_usd"
BILL_SAVINGS_COL = "calc.weighted.utility_bills.total_bill_savings_mean..billion_usd"

# Savings-distribution conventions mirror
# plot_measure_savings_distributions_enduse_and_fuel: UNWEIGHTED, zeros and
# nulls dropped per category, percent values trimmed at +/-150%, n reported.
# Unlike upstream, the trimmed and negative shares are also REPORTED — those
# tails are exactly what QAQC wants to see, not hide.
PCT_TRIM = 150.0
KWH_PER_FT2_TO_KBTU = 3.412141633


def _up_lit(up_type: str, u: str) -> str:
    """A single upgrade literal, typed to the column it is compared against."""
    return f"'{u}'" if str(up_type).startswith("varchar") else str(int(u))


# The county identifier on the by-state-and-county aggregate. The national
# aggregate has no equivalent -- its in.as_simulated_nhgis_county_gisjoin is the
# county a model was SIMULATED in, not the apportioned one, so it cannot stand
# in for county attribution.
COUNTY_COL = "in.nhgis_county_gisjoin"


def classify_location(value) -> str:
    """'state' or 'county' for one location id.

    Same convention as ComStock.determine_state_or_county_timeseries_table: a
    two-letter alphabetic id is a state, a G-prefixed id is a county gisjoin.
    Reused rather than reinvented so a driver's geography means the same thing
    to the plots and to this dashboard.
    """
    s = str(value).strip()
    if len(s) == 2 and s.isalpha():
        return "state"
    if s.upper().startswith("G") and len(s) > 2:
        return "county"
    return "unknown"


def parse_locations(value) -> list[dict]:
    """`timeseries_locations_to_plot` (or a string/list) -> location specs.

    Each spec is {kind, values, label}. A tuple key becomes ONE location with
    several ids, which is what the driver means by it -- ('MA','NH',...):
    'New England' is one profile, not five.

    Mixed kinds inside a single location are rejected rather than guessed: a
    profile is either state-attributed or county-attributed, and combining the
    two would double count any county inside one of the named states.
    """
    if not value:
        return []
    if isinstance(value, str):
        items = [(v.strip(), v.strip()) for v in value.split(",") if v.strip()]
    elif isinstance(value, dict):
        items = list(value.items())
    else:
        items = [(v, v) for v in value]

    out = []
    for key, label in items:
        ids = [str(v).strip() for v in
               (key if isinstance(key, (tuple, list)) else [key]) if str(v).strip()]
        if not ids:
            continue
        kinds = {classify_location(i) for i in ids}
        name = str(label) if not isinstance(label, (tuple, list)) else "+".join(map(str, label))
        if len(kinds) > 1:
            logger.warning("location %r mixes %s ids; skipping it -- a profile must be "
                           "attributed one way or the other", name, "/".join(sorted(kinds)))
            continue
        kind = kinds.pop()
        if kind == "unknown":
            logger.warning("location %r: cannot tell whether %s is a state or a county "
                           "gisjoin; skipping", name, ids[0])
            continue
        out.append({"kind": kind, "values": ids, "label": name})
    return out


def location_col(loc: dict, md_state: str) -> str:
    """The metadata column a location is filtered on."""
    return md_state if loc["kind"] == "state" else COUNTY_COL


def location_pred(loc: dict, md_state: str, alias: str = "") -> str:
    """`<col> IN (...)` for one location, optionally qualified by a table alias."""
    a = f"{alias}." if alias else ""
    vals = ", ".join(f"'{v}'" for v in loc["values"])
    return f'{a}"{location_col(loc, md_state)}" IN ({vals})'


def location_slug(loc: dict) -> str:
    """A filesystem- and column-safe name for one location."""
    return re.sub(r"[^A-Za-z0-9]+", "_", loc["label"]).strip("_") or "location"


def up_in(col: str, upgrades, up_type: str) -> str:
    """`col IN (...)` with literals in the column's own type.

    Wrapping a partition column in CAST() stops Athena from pruning partitions,
    so every filter is emitted in the column's native type and the CAST is kept
    only where the value is an output label. `upgrade` is bigint on the 2025 R3
    and 2024 R2 tables but the type is probed per table, never assumed.
    """
    return f"{col} IN ({', '.join(_up_lit(up_type, u) for u in upgrades)})"


def up_eq(col: str, u: str, up_type: str) -> str:
    return f"{col} = {_up_lit(up_type, u)}"


def _pct_col(fuel: str, eu: str) -> str:
    return f"calc.percent_savings.{fuel}.{eu}.energy_consumption..percent"


def _eui_sav_col(fuel: str, eu: str) -> str:
    return f"out.{fuel}.{eu}.energy_savings_intensity..kwh_per_ft2"


def _ann_col(fuel: str, eu: str) -> str:
    return f"out.{fuel}.{eu}.energy_consumption..kwh"


def _sav_col(fuel: str, eu: str) -> str:
    return f"calc.weighted.savings.{fuel}.{eu}.energy_consumption..tbtu"


def fuel_enduses(have: set[str], fuels=None) -> dict[str, list[str]]:
    return {f: [e for e in EU_CANDIDATES + ["total"] if _ann_col(f, e) in have]
            for f in (fuels or FUELS)}


DIST_DIMS = {
    "building_type": "in.comstock_building_type",
    "climate_zone": "in.as_simulated_ashrae_iecc_climate_zone_2006",
    "hvac_system": "in.hvac_system_type",
}
SITE_PCT = "calc.percent_savings.site_energy.total.energy_consumption..percent"
SITE_EUI = "out.site_energy.total.energy_savings_intensity..kwh_per_ft2"
BILL_PCT_TOTAL = "calc.percent_savings.utility_bills.total_bill_mean_intensity..percent"
BILL_USD_TOTAL = "out.utility_bills.total_bill_savings_mean_intensity..usd_per_ft2"
BILL_FUEL_PCT = {
    "electricity": "calc.percent_savings.utility_bills.electricity_bill_mean_intensity..percent",
    "natural gas": "calc.percent_savings.utility_bills.natural_gas_bill_state_average_intensity..percent",
    "fuel oil": "calc.percent_savings.utility_bills.fuel_oil_bill_state_average_intensity..percent",
    "propane": "calc.percent_savings.utility_bills.propane_bill_state_average_intensity..percent",
    "total": BILL_PCT_TOTAL,
}
BILL_FUEL_USD = {
    "electricity": "out.utility_bills.electricity_bill_savings_mean_intensity..usd_per_ft2",
    "natural gas": "out.utility_bills.natural_gas_bill_savings_state_average_intensity..usd_per_ft2",
    "fuel oil": "out.utility_bills.fuel_oil_bill_savings_state_average_intensity..usd_per_ft2",
    "propane": "out.utility_bills.propane_bill_savings_state_average_intensity..usd_per_ft2",
    "total": BILL_USD_TOTAL,
}


def dist_columns(have: set[str]) -> list[dict]:
    """Per-category columns (grouped by which column, not by a dimension)."""
    cats = []
    for f in FUELS_ALL:
        for e in EU_CANDIDATES:
            for kind, col in (("eui_site", _eui_sav_col(f, e)), ("pct_site", _pct_col(f, e))):
                if col in have:
                    cats.append({"kind": kind, "group": "end_use",
                                 "label": f"{f} {e}".replace("_", " "), "col": col})
    for f in FUELS_ALL + ["site_energy"]:
        for kind, col in (("eui_site", _eui_sav_col(f, "total")), ("pct_site", _pct_col(f, "total"))):
            if col in have:
                cats.append({"kind": kind, "group": "fuel",
                             "label": f.replace("_", " "), "col": col})
    for label, col in BILL_FUEL_PCT.items():
        if col in have:
            cats.append({"kind": "pct_bill", "group": "fuel", "label": label, "col": col})
    for label, col in BILL_FUEL_USD.items():
        if col in have:
            cats.append({"kind": "usd_bill", "group": "fuel", "label": label, "col": col})
    return cats


# The by-dimension figures use the site/total column split by a building
# attribute (building type, climate zone, HVAC system).
DIM_KIND_COLS = {
    "pct_site": SITE_PCT, "eui_site": SITE_EUI,
    "pct_bill": BILL_PCT_TOTAL, "usd_bill": BILL_USD_TOTAL,
}


def build_pair_sql(md_table: str, upgrade: str, have: set[str],
                   up_type: str = "varchar") -> str:
    """Baseline-applicable vs measure aggregates in one query (Mode 2)."""
    # bare `state` is a partition column on by-state tables only; the national
    # table carries `in.state`.
    st = "state" if "state" in have else "in.state"
    # No extra columns beyond _agg_sums: the pair, whole-stock, and bitmask
    # queries must stay column-identical, because the dashboard reads whichever
    # of them is available through one code path. The total mean bill is
    # already carried as bill|total_mean.
    body = ",\n".join(_agg_sums(have, "t"))
    # The applicable set, at the aggregate's OWN grain. This used to select
    # (bldg_id, state) with no DISTINCT and join on those two columns, over a
    # table whose grain is (bldg_id, state, climate zone) -- so every baseline
    # row matched every sibling climate-zone row of the same building, and a
    # baseline row absent from the measure partition still matched through a
    # sibling. On dual_fuel_rtus_10k_02 that turned a 5,847-row baseline into
    # 7,019 rows and overstated baseline weight by 8.5%, which understated every
    # percentage saving computed against it.
    # A semi-join on bldg_id, NOT a key join. Applicability is a per-building
    # property and all of a building's geography rows share its
    # completed_status, so this selects every baseline row of the applicable
    # buildings -- at whatever grain the table has, carrying their full weight.
    #
    # Joining on a geography key instead would need to know the grain, and the
    # grain follows the export: (bldg_id, state, climate zone) for a
    # national_by_state aggregate, (bldg_id, county) for a county one, bldg_id
    # alone for a true national one. Any hardcoded key is wrong for one of them.
    # This also makes the pair query agree with the mask leg by construction:
    # both aggregate all rows of the same building set.
    return (
        "WITH app AS (\n"
        f"  SELECT DISTINCT bldg_id FROM {md_table}\n"
        f"  WHERE {up_eq('upgrade', upgrade, up_type)} AND completed_status = 'Success'\n"
        ")\n"
        "SELECT scenario,\n" + body + "\nFROM (\n"
        f"  SELECT 'baseline' AS scenario, b.* FROM {md_table} b\n"
        f"  JOIN app ON b.bldg_id = app.bldg_id\n"
        f"  WHERE {up_eq('b.upgrade', '0', up_type)} AND b.completed_status = 'Success'\n"
        "  UNION ALL\n"
        f"  SELECT 'measure' AS scenario, m.* FROM {md_table} m\n"
        f"  WHERE {up_eq('m.upgrade', upgrade, up_type)} AND m.completed_status = 'Success'\n"
        ") t\nGROUP BY scenario"
    )


def _agg_sums(have: set[str], alias: str = "") -> list[str]:
    """The aggregate column list shared by every scenario-level query, so the
    pair, whole-stock, and bitmask queries stay column-identical."""
    a = f"{alias}." if alias else ""
    fe = fuel_enduses(have, FUELS_ALL)
    # n counts ROWS; n_models counts models. On an apportioned aggregate a
    # model appears once per geography, so COUNT(*) reported as a model count
    # overstates it by the mean multiplicity (1.74x on baseline_10k's national
    # aggregate, 15.6x on its county one). Both are kept: the pair, stock and
    # bitmask queries must stay column-identical, and `n` is what the mask
    # cross-check compares.
    sums = [f"    SUM({a}weight) AS w", "    COUNT(*) AS n",
            f"    COUNT(DISTINCT {a}bldg_id) AS n_models",
            f'    SUM({a}weight * {a}"{SQFT_COL}") AS sqft']
    for f, eus in fe.items():
        for e in eus:
            sums.append(f'    SUM({a}weight * {a}"{_ann_col(f, e)}") AS "e|{f}|{e}"')
    for k, c in EMISSIONS_DETAIL.items():
        if c in have:
            sums.append(f'    SUM({a}"{c}") AS "em|{k}"')
    for k, c in BILL_DETAIL.items():
        if c in have:
            sums.append(f'    SUM({a}"{c}") AS "bill|{k}"')
    return sums


def build_stock_sql(md_table: str, have: set[str], up_type: str = "varchar") -> str:
    """Whole-stock baseline with the same columns as the pair query, so the
    total-stock view of a measure = stock + (measure - applicable baseline)."""
    return ("SELECT 'stock_baseline' AS scenario,\n" + ",\n".join(_agg_sums(have))
            + f"\nFROM {md_table}\n"
            f"WHERE {up_eq('upgrade', '0', up_type)} AND completed_status = 'Success'")


# Hard limit on the bitmask leg, and it is structural rather than a cost
# guess: the dashboard composes masks with JavaScript bitwise operators, which
# are 32-bit, so `1 << i` is undefined past 31 bits. 30 leaves headroom.
#
# This USED to be 8, justified as "the mask space is 2^M". That reasoning
# confused the theoretical space with the cost. What a query actually returns is
# the number of DISTINCT masks PRESENT, bounded by buildings and small in
# practice, because a building is applicable to only a handful of measures.
# Measured on an 11-measure run: 5 distinct masks out of 2,048 theoretical, over
# 3,245 buildings. The old cap refused a nearly free leg -- and refusing it
# removed the union and intersection bases from both measure tabs and left the
# timeseries comparison view drawing no charts at all.
MASK_MEASURE_CAP = 30

# Row budget for the TIMESERIES mask variant, which multiplies the mask count by
# 3 seasons x 2 day types x 24 hours x the scenarios. The annual variant returns
# one row per (mask, scenario) and needs no budget.
MASK_TS_ROW_BUDGET = 400_000


def count_distinct_masks(md_table: str, upgrades: list[str], up_type: str = "varchar",
                         no_cache: bool = False) -> int:
    """How many applicability masks the data actually contains.

    One cheap aggregate, so the decision to run the mask leg is made on the real
    cost rather than on 2^M. Returns -1 when it cannot be determined, which the
    caller treats as "do not risk it".
    """
    bits = " +\n      ".join(
        f"MAX(CASE WHEN up = {_up_lit(up_type, u)} THEN {1 << i} ELSE 0 END)"
        for i, u in enumerate(upgrades))
    sql = (
        "WITH app AS (\n"
        f"  SELECT DISTINCT bldg_id, upgrade AS up FROM {md_table}\n"
        f"  WHERE {up_in('upgrade', upgrades, up_type)}"
        " AND completed_status = 'Success'\n"
        "), msk AS (\n"
        f"  SELECT bldg_id, {bits} AS mask FROM app GROUP BY bldg_id\n"
        ")\n"
        "SELECT COUNT(DISTINCT mask) AS n FROM msk"
    )
    try:
        df = athena.query(sql, no_cache=no_cache, label="distinct applicability masks")
        return int(df["n"].iloc[0]) if not df.empty else -1
    except Exception as exc:                                      # noqa: BLE001
        logger.info("could not count applicability masks: %s", exc)
        return -1


def mask_leg_ok(md_table: str, upgrades: list[str], up_type: str = "varchar",
                for_timeseries: bool = False, no_cache: bool = False) -> tuple[bool, str]:
    """Whether to run the mask leg, and why not when the answer is no."""
    if len(upgrades) > MASK_MEASURE_CAP:
        return False, (f"{len(upgrades)} measures exceeds {MASK_MEASURE_CAP}, the limit "
                       "imposed by 32-bit JavaScript bitwise operators in the dashboard")
    n = count_distinct_masks(md_table, upgrades, up_type, no_cache=no_cache)
    if n < 0:
        return False, "could not count the applicability masks to size the query"
    if for_timeseries:
        rows = n * 3 * 2 * 24 * (len(upgrades) + 1)
        if rows > MASK_TS_ROW_BUDGET:
            return False, (f"{n} distinct masks would make roughly {rows:,} hourly rows, "
                           f"over the {MASK_TS_ROW_BUDGET:,} budget")
    logger.info("applicability-mask leg: %d distinct masks over %d measures", n, len(upgrades))
    return True, ""


def build_mask_sql(md_table: str, upgrades: list[str], have: set[str],
                   up_type: str = "varchar") -> str:
    """Every scenario aggregated by applicability BITMASK.

    Applicability is membership of an upgrade partition (non-applicable
    buildings are absent), so one bit per measure describes which measures
    touch a building. Aggregating each scenario by that mask makes every
    population basis exact for ANY user-selected subset S, computed downstream
    with no further queries:

        entire stock     all masks (mask 0 = applicable to none)
        union(S)         masks u where u & S != 0
        intersection(S)  masks u where S is a subset of u
        own(m)           masks u where m is in u

    and a measure's bar over population P is
        sum(measure_m[u] for u in P if m in u) + sum(baseline[u] for u in P if m not in u),
    since a measure cannot change a building outside its own applicable set.
    `own(m)` reproduces the pair query's applicable-only aggregates and
    `entire stock` reproduces stock + (measure - applicable baseline), so both
    are cross-checkable against the existing metrics.
    """
    bits = "\n".join(
        f"      MAX(CASE WHEN up = '{u}' THEN {1 << i} ELSE 0 END)"
        + ("" if i == len(upgrades) - 1 else " +")
        for i, u in enumerate(upgrades))
    return (
        "WITH app AS (\n"
        # DISTINCT guards against any table that carries a building more than
        # once per upgrade; on the national table it is a no-op.
        "  SELECT DISTINCT bldg_id, CAST(upgrade AS varchar) AS up\n"
        f"  FROM {md_table}\n"
        f"  WHERE {up_in('upgrade', upgrades, up_type)} AND completed_status = 'Success'\n"
        "),\n"
        "msk AS (\n"
        "  SELECT bldg_id,\n" + bits + " AS mask\n"
        "  FROM app GROUP BY bldg_id\n"
        ")\n"
        "SELECT t.scenario, COALESCE(msk.mask, 0) AS mask,\n"
        + ",\n".join(_agg_sums(have, "t")) + "\nFROM (\n"
        f"  SELECT 'baseline' AS scenario, b.* FROM {md_table} b\n"
        f"  WHERE {up_eq('b.upgrade', '0', up_type)} AND b.completed_status = 'Success'\n"
        "  UNION ALL\n"
        f"  SELECT CAST(m.upgrade AS varchar) AS scenario, m.* FROM {md_table} m\n"
        f"  WHERE {up_in('m.upgrade', upgrades, up_type)} AND m.completed_status = 'Success'\n"
        ") t\n"
        # t is a subquery over the METADATA table here, not a timeseries
        # table, so the identifier is always bldg_id: the
        # building_id/bldg_id split belongs to the timeseries producers.
        "LEFT JOIN msk ON t.bldg_id = msk.bldg_id\n"
        # positional, so a real column named `mask` on t cannot shadow the alias
        "GROUP BY 1, 2"
    )


# The by-category Scenario Comparison figures: four metrics x four groupings,
# whole-stock totals, matching plot_floor_area_and_energy_totals. The mask is
# carried so these honor the same four population bases as everything else.
CAT_DIMS = {
    "building_type": "in.comstock_building_type",
    "census_division": "in.census_division_name",
    "vintage": "in.vintage",
}
CAT_METRICS = {
    "sqft": "calc.weighted.sqft..ft2",
    "site_energy": "calc.weighted.site_energy.total.energy_consumption..tbtu",
    "electricity": "calc.weighted.electricity.total.energy_consumption..tbtu",
    "natural_gas": "calc.weighted.natural_gas.total.energy_consumption..tbtu",
}


def build_category_sql(md_table: str, upgrades: list[str], have: set[str], dim: str,
                       up_type: str = "varchar") -> str:
    """Per-(scenario, mask, category) totals for the by-category figures."""
    dcol = CAT_DIMS[dim]
    bits = "\n".join(
        f"      MAX(CASE WHEN up = '{u}' THEN {1 << i} ELSE 0 END)"
        + ("" if i == len(upgrades) - 1 else " +")
        for i, u in enumerate(upgrades))
    sums = ["    SUM(t.weight) AS w", "    COUNT(*) AS n"]
    for k, c in CAT_METRICS.items():
        if c in have:
            sums.append(f'    SUM(t."{c}") AS "m|{k}"')
    return (
        "WITH app AS (\n"
        "  SELECT DISTINCT bldg_id, CAST(upgrade AS varchar) AS up\n"
        f"  FROM {md_table}\n"
        f"  WHERE {up_in('upgrade', upgrades, up_type)} AND completed_status = 'Success'\n"
        "),\n"
        "msk AS (\n"
        "  SELECT bldg_id,\n" + bits + " AS mask\n"
        "  FROM app GROUP BY bldg_id\n"
        ")\n"
        "SELECT t.scenario, COALESCE(msk.mask, 0) AS mask,\n"
        f'    t."{dcol}" AS category,\n' + ",\n".join(sums) + "\nFROM (\n"
        f"  SELECT 'baseline' AS scenario, b.* FROM {md_table} b\n"
        f"  WHERE {up_eq('b.upgrade', '0', up_type)} AND b.completed_status = 'Success'\n"
        "  UNION ALL\n"
        f"  SELECT CAST(m.upgrade AS varchar) AS scenario, m.* FROM {md_table} m\n"
        f"  WHERE {up_in('m.upgrade', upgrades, up_type)} AND m.completed_status = 'Success'\n"
        ") t\n"
        # t is a subquery over the METADATA table here, not a timeseries
        # table, so the identifier is always bldg_id: the
        # building_id/bldg_id split belongs to the timeseries producers.
        "LEFT JOIN msk ON t.bldg_id = msk.bldg_id\n"
        "GROUP BY 1, 2, 3"
    )


def build_savings_sql(md_table: str, upgrade: str, have: set[str],
                     up_type: str = "varchar") -> str:
    """Direct weighted savings by end use x fuel, plus name/bills, one row."""
    fe = fuel_enduses(have)
    sums = ['    SUM(weight) AS w', '    COUNT(*) AS n',
            '    arbitrary("in.upgrade_name") AS upgrade_name']
    for f, eus in fe.items():
        for e in eus:
            c = _sav_col(f, e)
            if c in have:
                sums.append(f'    SUM("{c}") AS "s|{f}|{e}"')
    site = "calc.weighted.savings.site_energy.total.energy_consumption..tbtu"
    if site in have:
        sums.append(f'    SUM("{site}") AS "s|site_energy|total"')
    if BILL_SAVINGS_COL in have:
        sums.append(f'    SUM("{BILL_SAVINGS_COL}") AS bill_savings_busd')
    return (
        "SELECT\n" + ",\n".join(sums) + f"\nFROM {md_table}\n"
        f"WHERE {up_eq('upgrade', upgrade, up_type)} AND completed_status = 'Success'"
    )


def build_dist_sql(md_table: str, upgrade: str, have: set[str],
                   up_type: str = "varchar") -> str:
    cats = dist_columns(have)
    # bldg_id so the caller can collapse a model's per-geography rows. The
    # distribution stats here are UNWEIGHTED -- quantiles, KDE, outliers, one
    # point per model -- so leaving a model in once per geography row silently
    # weights it by its geographic spread.
    cols = ['    bldg_id']
    cols += [f'    "{c["col"]}" AS "{c["kind"]}|{c["group"]}|{c["label"]}"' for c in cats]
    for kind, c in DIM_KIND_COLS.items():
        if c in have:
            cols.append(f'    "{c}" AS "T|{kind}"')
    for dim, c in DIST_DIMS.items():
        if c in have:
            cols.append(f'    "{c}" AS "D|{dim}"')
    return (
        "SELECT\n" + ",\n".join(cols) + f"\nFROM {md_table}\n"
        f"WHERE {up_eq('upgrade', upgrade, up_type)} AND completed_status = 'Success'"
    )


# Season months for the measure timeseries: the same national convention as
# plot_measure_timeseries_season_average_by_state (map_to_season in
# plotting_mixin: 6-8 summer, 3-5 and 9-11 shoulder, else winter), so the
# dashboard's seasonal profiles match the measure postprocessing plots. Not
# region-tuned like the AMI legs; stated on the chart.
MEASURE_SEASONS = {"Summer": [6, 7, 8], "Winter": [12, 1, 2], "Shoulder": [3, 4, 5, 9, 10, 11]}


def _ts_state_line(dialect, loc):
    """The timeseries-side state predicate as a WHOLE line, or "" when there is
    nothing to prune on.

    Empty for a COUNTY location: the timeseries table is partitioned by state,
    not county, and which states a county set falls in is not known here. The
    metadata side selects the rows either way, so this only ever prunes.

    A whole line so an absent predicate cannot leave a dangling AND. Only
    the timeseries side is conditional -- the metadata side always carries
    the real state filter, which is what actually selects the rows.
    """
    if loc.get("kind") != "state":
        return ""
    f = state_filter(dialect, loc["values"])
    return f"  AND {f}\n" if f else ""


def build_ts_sql(ts_table: str, md_table: str, loc: dict,
                 upgrades: list[str], dialect: dict | None = None,
                 up_type: str = "varchar", md_state: str = "state") -> str:
    # With both sides typed the join compares the raw partition columns; a CAST
    # on either side would block pruning on the timeseries table too.
    up_join = ("CAST(t.upgrade AS varchar) = CAST(m.upgrade AS varchar)"
               if str(up_type).startswith("varchar") else "t.upgrade = m.upgrade")
    enduses = enduse_sums(dialect)
    return (
        "SELECT\n"
        "    CAST(t.upgrade AS varchar) AS upgrade,\n"
        f"    {hour_trunc(dialect)} AS hour_ts,\n"
        f"    {total_sum(dialect, 'electricity', 'elec_kwh')},\n"
        f"    {total_sum(dialect, 'natural_gas', 'gas_kwh')},\n"
        f"{enduses}\n"
        f"FROM {ts_table} t\n"
        f"JOIN {md_table} m\n"
        f"  ON {join_on(dialect, md_state=md_state)}\n"
        f"    AND {up_join}\n"
        f"WHERE {location_pred(loc, md_state, 'm')}\n"
        f"{_ts_state_line(dialect, loc)}"
        f"  AND {up_in('t.upgrade', ['0'] + list(upgrades), up_type)}\n"
        "  AND m.completed_status = 'Success'\n"
        "GROUP BY 1, 2"
    )


def build_ts_mask_sql(ts_table: str, md_table: str, loc: dict,
                      upgrades: list[str], dialect: dict | None = None,
                      up_type: str = "varchar", md_state: str = "state") -> str:
    """Hourly profiles for every scenario, split by applicability BITMASK.

    The hourly twin of build_mask_sql: with the population decomposed by mask,
    every basis (entire stock, own applicability, union, intersection) is an
    exact sum over masks downstream, for any selected subset — the timeseries
    no longer has to fall back to the two bases a per-measure baseline can
    express. Profiles are weighted kWh, so MW = kWh / 1000 for hourly means.
    """
    up_join = ("CAST(t.upgrade AS varchar) = CAST(m.upgrade AS varchar)"
               if str(up_type).startswith("varchar") else "t.upgrade = m.upgrade")
    bits = "\n".join(
        f"      MAX(CASE WHEN up = '{u}' THEN {1 << i} ELSE 0 END)"
        + ("" if i == len(upgrades) - 1 else " +")
        for i, u in enumerate(upgrades))
    enduses = enduse_sums(dialect)
    return (
        "WITH app AS (\n"
        # DISTINCT first: the county table carries one row per building PER
        # COUNTY, and without it the mask CTE and the join both fan out.
        "  SELECT DISTINCT bldg_id, CAST(upgrade AS varchar) AS up\n"
        f"  FROM {md_table}\n"
        f"  WHERE {location_pred(loc, md_state)}"
        f" AND {up_in('upgrade', upgrades, up_type)}\n"
        "    AND completed_status = 'Success'\n"
        "),\n"
        "msk AS (\n"
        "  SELECT bldg_id,\n" + bits + " AS mask\n"
        "  FROM app GROUP BY bldg_id\n"
        ")\n"
        "SELECT\n"
        "    CAST(t.upgrade AS varchar) AS upgrade,\n"
        "    COALESCE(msk.mask, 0) AS mask,\n"
        f"    {hour_trunc(dialect)} AS hour_ts,\n"
        f"    {total_sum(dialect, 'electricity', 'elec_kwh')},\n"
        f"    {total_sum(dialect, 'natural_gas', 'gas_kwh')},\n"
        f"{enduses}\n"
        f"FROM {ts_table} t\n"
        f"JOIN {md_table} m\n"
        f"  ON {join_on(dialect, md_state=md_state)}\n"
        f"    AND {up_join}\n"
        f"LEFT JOIN msk ON {bldg_col(dialect)} = msk.bldg_id\n"
        f"WHERE {location_pred(loc, md_state, 'm')}\n"
        f"{_ts_state_line(dialect, loc)}"
        f"  AND {up_in('t.upgrade', ['0'] + list(upgrades), up_type)}\n"
        "  AND m.completed_status = 'Success'\n"
        "GROUP BY 1, 2, 3"
    )


def build_ts_base_sql(ts_table: str, md_table: str, loc: dict,
                      upgrade: str, dialect: dict | None = None,
                      up_type: str = "varchar", md_state: str = "state") -> str:
    """Baseline profile restricted to ONE measure's applicable buildings.

    Without this, a measure's line (normalized over its applicable floor area)
    against the whole-stock stack mixes savings with population composition —
    for a 60%-applicable measure the difference can be mostly which buildings,
    not what the measure did. Savings reads as the gap between a measure's own
    solid (this baseline) and dashed (measure) lines.
    """
    up_join = ("CAST(t.upgrade AS varchar) = CAST(m.upgrade AS varchar)"
               if str(up_type).startswith("varchar") else "t.upgrade = m.upgrade")
    # End uses are carried here as well as on the measure rows so the dashboard
    # can re-base a measure's profile onto the whole stock
    # (stock + measure - applicable baseline) end use by end use.
    enduses = enduse_sums(dialect)
    return (
        "WITH app AS (\n"
        # DISTINCT is load-bearing: the county table carries one row per
        # building PER COUNTY (apportionment), so without it the join fans out
        # k-fold and inflates the baseline.
        f'  SELECT DISTINCT bldg_id, "{location_col(loc, md_state)}" AS loc'
        f" FROM {md_table}\n"
        f"  WHERE {location_pred(loc, md_state)}"
        f" AND {up_eq('upgrade', upgrade, up_type)}\n"
        "    AND completed_status = 'Success'\n"
        ")\n"
        "SELECT\n"
        f"    'base_{upgrade}' AS upgrade,\n"
        f"    {hour_trunc(dialect)} AS hour_ts,\n"
        f"    {total_sum(dialect, 'electricity', 'elec_kwh')},\n"
        f"    {total_sum(dialect, 'natural_gas', 'gas_kwh')},\n"
        f"{enduses}\n"
        f"FROM {ts_table} t\n"
        f"JOIN {md_table} m\n"
        f"  ON {join_on(dialect, md_state=md_state)}\n"
        f"    AND {up_join}\n"
        f"JOIN app ON {join_on(dialect, md='app', md_state='loc')}\n"
        f"WHERE {location_pred(loc, md_state, 'm')}\n"
        f"{_ts_state_line(dialect, loc)}"
        f"  AND {up_eq('t.upgrade', '0', up_type)} AND {up_eq('m.upgrade', '0', up_type)}\n"
        "  AND m.completed_status = 'Success'\n"
        "GROUP BY 1, 2"
    )


def build_ts_base_sqft_sql(md_table: str, loc: dict, upgrade: str,
                           up_type: str = "varchar",
                           md_state: str = "state") -> str:
    return (
        f'SELECT SUM(b.weight * b."{SQFT_COL}") AS sqft_weighted\n'
        f"FROM {md_table} b\n"
        f'JOIN (SELECT DISTINCT bldg_id, "{location_col(loc, md_state)}" AS loc'
        f" FROM {md_table}\n"
        f"      WHERE {location_pred(loc, md_state)}"
        f" AND {up_eq('upgrade', upgrade, up_type)}\n"
        "        AND completed_status = 'Success') app\n"
        # app already aliases the metadata state column to `state`, so only the
        # b side needs adapting: `state` on a county aggregate, `in.state` on a
        # national one.
        f'  ON b.bldg_id = app.bldg_id'
        f' AND b."{location_col(loc, md_state)}" = app.loc\n'
        f"WHERE {location_pred(loc, md_state, 'b')}"
        f" AND {up_eq('b.upgrade', '0', up_type)}\n"
        "  AND b.completed_status = 'Success'"
    )


def build_ts_sqft_sql(md_table: str, loc: dict, upgrades: list[str],
                      up_type: str = "varchar",
                      md_state: str = "state") -> str:
    return (
        "SELECT CAST(upgrade AS varchar) AS upgrade,\n"
        f'    SUM(weight * "{SQFT_COL}") AS sqft_weighted\n'
        f"FROM {md_table}\n"
        f"WHERE {location_pred(loc, md_state)} AND "
        f"{up_in('upgrade', ['0'] + list(upgrades), up_type)}\n"
        "  AND completed_status = 'Success'\n"
        "GROUP BY 1"
    )


def _melt_prefixed(row: pd.Series, prefix: str) -> pd.DataFrame:
    out = []
    for k, v in row.items():
        if isinstance(k, str) and k.startswith(prefix + "|"):
            _p, fuel, eu = k.split("|")
            out.append({"fuel": fuel, "end_use": eu, "value": v})
    return pd.DataFrame(out)


def available_upgrades(md_table: str, no_cache: bool = False) -> list[str]:
    """Upgrade ids that actually exist in this table, as strings.

    An older release does not necessarily carry every measure the current one
    does — a measure may not have existed yet, or may have been renamed or
    dropped. Asking the table rather than assuming lets the cross-release
    comparison cover the measures the two releases share and say so for the rest,
    instead of failing or silently reporting zeros.
    """
    df = athena.query(
        f"SELECT DISTINCT upgrade FROM {md_table} WHERE completed_status = 'Success'",
        no_cache=no_cache, label=f"available upgrades on {md_table}")
    out = []
    for v in df["upgrade"].tolist():
        if v is None:
            continue
        try:
            out.append(str(int(float(v))))
        except (TypeError, ValueError):
            out.append(str(v))
    return sorted(set(out), key=lambda x: (len(x), x))


def assess_measures(md_table: str, upgrades: list[str], no_cache: bool = False):
    """Returns (summary, enduse_pairs, enduse_savings, dists, scenarios).

    `categories` carries the same scenario x mask decomposition split by
    building type, census division, and vintage, for the by-category Scenario
    Comparison figures.

    `scenarios` carries one row per upgrade x {baseline, measure} plus a
    single `__stock__` whole-stock baseline row, each with the full e|fuel|eu,
    em|key, and bill|key aggregate columns — the input to the fuel x end-use,
    GHG, and utility-bill stacked figures (applicable and total-stock views).
    """
    have = athena.table_columns(md_table)
    up_type = str(athena.table_column_types(md_table).get("upgrade", "varchar"))
    kwh_to_tbtu = 3412.141633 / 1e12
    summaries, pairs, savings_rows, dist_rows, scen_rows = [], [], [], [], []
    stock = athena.query(build_stock_sql(md_table, have, up_type), no_cache=no_cache,
                         label="whole-stock baseline aggregates")
    srow = stock.iloc[0].to_dict()
    srow.update({"upgrade": "__stock__", "upgrade_name": "Whole stock"})
    scen_rows.append(srow)

    base_stock = athena.query(
        f"SELECT SUM(weight) AS w FROM {md_table} "
        f"WHERE {up_eq('upgrade', '0', up_type)} AND completed_status = 'Success'",
        no_cache=no_cache, label="baseline stock weight")
    stock_w = float(base_stock["w"].iloc[0])

    for up in upgrades:
        sav = athena.query(build_savings_sql(md_table, up, have, up_type),
                           no_cache=no_cache, label=f"measure {up} savings")
        pair = athena.query(build_pair_sql(md_table, up, have, up_type),
                            no_cache=no_cache, label=f"measure {up} pair")
        s = sav.iloc[0]
        name = str(s["upgrade_name"])

        m = _melt_prefixed(s, "s").rename(columns={"value": "savings_tbtu"})
        m.insert(0, "upgrade", up)
        m.insert(1, "upgrade_name", name)
        savings_rows.append(m)

        for _, r in pair.iterrows():
            e = _melt_prefixed(r, "e")
            e["tbtu"] = e["value"] * kwh_to_tbtu
            e = e.drop(columns="value")
            e.insert(0, "upgrade", up)
            e.insert(1, "upgrade_name", name)
            e.insert(2, "scenario", r["scenario"])
            pairs.append(e)

        for _, r in pair.iterrows():
            rr = r.to_dict()
            rr.update({"upgrade": up, "upgrade_name": name})
            scen_rows.append(rr)
        pb = pair.set_index("scenario")
        # Total emissions on the eGRID basis: egrid electricity + fuels. The
        # LRMER electricity variants are alternatives, not additive.
        em_cols = [c for c in pair.columns if c.startswith("em|") and c != "em|lrmer_high"
                   and c != "em|lrmer_low"]
        em_base = float(pb.loc["baseline", em_cols].sum()) if em_cols else np.nan
        em_meas = float(pb.loc["measure", em_cols].sum()) if em_cols else np.nan
        bill_base = float(pb.loc["baseline"].get("bill|total_mean", np.nan))
        bill_meas = float(pb.loc["measure"].get("bill|total_mean", np.nan))
        w_app = float(pb.loc["measure", "w"])
        site_sav = float(s.get("s|site_energy|total", np.nan))
        bill_sav_busd = float(s.get("bill_savings_busd", np.nan))
        summaries.append({
            "upgrade": up, "upgrade_name": name,
            # Models, not apportionment rows -- see _agg_sums.
            "n_models": int(pb.loc["measure", "n_models"]
                            if "n_models" in pb.columns
                            else pb.loc["measure", "n"]),
            "weighted_bldgs": w_app,
            "pct_of_stock": 100.0 * w_app / stock_w,
            "site_savings_tbtu": site_sav,
            "elec_savings_tbtu": float(s.get("s|electricity|total", np.nan)),
            "gas_savings_tbtu": float(s.get("s|natural_gas|total", np.nan)),
            "bill_total_savings_musd": bill_sav_busd * 1e3,
            "bill_avg_savings_usd_per_bldg": bill_sav_busd * 1e9 / w_app if w_app else np.nan,
            "bill_pct_savings": 100.0 * (bill_base - bill_meas) / bill_base
            if bill_base else np.nan,
            "emissions_savings_co2e_mmt": em_base - em_meas,
            "emissions_pct_savings": 100.0 * (em_base - em_meas) / em_base
            if em_base else np.nan,
        })

        dist = athena.query(build_dist_sql(md_table, up, have, up_type),
                            no_cache=no_cache, label=f"measure {up} savings dist")

        def _stat(v, kind, group, label):
            v = pd.to_numeric(v, errors="coerce").to_numpy(float)
            v = v[np.isfinite(v)]
            n_nonzero = int((v != 0).sum())
            v = v[v != 0]
            if not len(v):
                return
            neg = float((v < 0).sum() / len(v) * 100)
            trimmed = 0.0
            if kind.startswith("pct"):
                trimmed = float((np.abs(v) > PCT_TRIM).sum() / len(v) * 100)
                v = v[np.abs(v) <= PCT_TRIM]
                if not len(v):
                    return
            elif kind == "eui_site":
                v = v * KWH_PER_FT2_TO_KBTU
            qs = np.percentile(v, [0, 5, 25, 50, 75, 95, 100])
            dist_rows.append({
                "upgrade": up, "upgrade_name": name, "kind": kind, "group": group,
                "category": label,
                "vmin": qs[0], "p05": qs[1], "p25": qs[2], "p50": qs[3],
                "p75": qs[4], "p95": qs[5], "vmax": qs[6],
                "mean": float(v.mean()),
                "share_negative_pct": neg, "share_trimmed_pct": trimmed,
                "n_models": n_nonzero,
                # Density for the violin outline, and the far-tail points drawn
                # as outliers. Both must be computed HERE, from the raw
                # per-model values: seven quantiles cannot be turned back into a
                # distribution shape, and a violin drawn from them would be an
                # invention rather than a measurement.
                "kde": kde_json(v),          # unweighted: one row per model
                "outliers": outlier_json(v, qs[2], qs[4]),
            })

        # One row per model. The distribution columns are model-level
        # (percent savings and intensities are identical across a model's
        # geography rows), so dropping the duplicates is a de-replication, not
        # an aggregation choice.
        if "bldg_id" in dist.columns:
            before = len(dist)
            dist = dist.drop_duplicates(subset="bldg_id")
            if len(dist) != before:
                logger.info("distributions: %d apportionment rows -> %d models",
                            before, len(dist))
        for col in dist.columns:
            if col in ("bldg_id",) or col.startswith("T|") or col.startswith("D|"):
                continue
            kind, group, label = col.split("|")
            _stat(dist[col], kind, group, label)
        # by-dimension figures: the site/total metric split by building attribute
        for dim in DIST_DIMS:
            dcol = f"D|{dim}"
            if dcol not in dist.columns:
                continue
            for kind in DIM_KIND_COLS:
                tcol = f"T|{kind}"
                if tcol not in dist.columns:
                    continue
                for cat, g in dist.groupby(dcol, dropna=True):
                    _stat(g[tcol], kind, dim, str(cat))
    summary = pd.DataFrame(summaries)
    enduse_pairs = pd.concat(pairs, ignore_index=True) if pairs else pd.DataFrame()
    enduse_savings = pd.concat(savings_rows, ignore_index=True) if savings_rows else pd.DataFrame()
    dists = pd.DataFrame(dist_rows)
    scenarios = pd.DataFrame(scen_rows)

    mask_ok, mask_why = mask_leg_ok(md_table, upgrades, up_type, no_cache=no_cache)
    cats = []
    if mask_ok:
        for dim in CAT_DIMS:
            if CAT_DIMS[dim] not in have:
                logger.warning("skipping the %s by-category leg: column absent", dim)
                continue
            c = athena.query(build_category_sql(md_table, upgrades, have, dim, up_type),
                             no_cache=no_cache, label=f"scenario totals by {dim}")
            c.insert(0, "dimension", dim)
            cats.append(c)
    categories = pd.concat(cats, ignore_index=True) if cats else pd.DataFrame()
    if not categories.empty:
        categories.insert(1, "bit_order", ",".join(upgrades))

    masks = pd.DataFrame()
    if mask_ok:
        masks = athena.query(build_mask_sql(md_table, upgrades, have, up_type),
                             no_cache=no_cache, label="scenario aggregates by applicability mask")
        masks.insert(1, "bit_order", ",".join(upgrades))
        _check_masks(masks, scenarios, upgrades)
    else:
        logger.warning("skipping the applicability-mask leg: %s; union and intersection "
                       "bases will be unavailable (entire stock and own applicability "
                       "are not affected)", mask_why)
    return summary, enduse_pairs, enduse_savings, dists, scenarios, masks, categories


def _check_masks(masks: pd.DataFrame, scenarios: pd.DataFrame, upgrades: list[str]) -> None:
    """Cross-check the bitmask leg against the pair/stock aggregates.

    own(m) summed over the masks containing m must reproduce that measure's
    applicable-only aggregates, and the baseline over all masks must reproduce
    the whole-stock baseline. A mismatch means the applicability bits and the
    upgrade partitions disagree, which would silently corrupt every basis.
    """
    cols = ["w", "n"]
    for i, up in enumerate(upgrades):
        bit = 1 << i
        # Both sides of the pair must reproduce. The baseline check is the
        # load-bearing one: the mask query builds its baseline leg with a bare
        # WHERE upgrade='0', while the pair query joins baseline to the
        # applicable set, so a building present in a measure partition but
        # missing from the baseline partition would silently understate every
        # baseline bar.
        for scen, mask_scen in (("measure", up), ("baseline", "baseline")):
            got = masks[(masks["scenario"] == mask_scen)
                        & ((masks["mask"] & bit) > 0)][cols].sum()
            want = scenarios[(scenarios["upgrade"].astype(str) == str(up))
                             & (scenarios["scenario"] == scen)]
            if want.empty:
                logger.warning("no %s row for upgrade %s: mask cross-check skipped", scen, up)
                continue
            want = want[cols].iloc[0]
            for c in cols:
                rel = float(abs(got[c] - want[c]) / (abs(want[c]) or 1))
                if rel > 1e-6:
                    # Neither leg is named as the culprit: which one is wrong
                    # depends on the mismatch. The mask leg aggregates a
                    # per-building applicability mask (many-to-one, cannot
                    # duplicate); the pair query semi-joins at the aggregate's
                    # grain. A disagreement means those two disagree about the
                    # applicable set -- worth investigating, not attributing.
                    logger.warning("mask and pair legs disagree for upgrade %s "
                                   "(%s, %s): mask %.1f vs pair %.1f (%.3f%%)",
                                   up, scen, c, got[c], want[c], rel * 100)
    stock = scenarios[scenarios["scenario"] == "stock_baseline"]
    if not stock.empty:
        got = float(masks[masks["scenario"] == "baseline"]["w"].sum())
        want = float(stock["w"].iloc[0])
        if abs(got - want) / (want or 1) > 1e-6:
            logger.warning("mask baseline (%.1f) != whole-stock baseline (%.1f)", got, want)


def _md_state_col(md_table: str, no_cache: bool = False) -> str:
    """The metadata table's state column: bare `state`, or `in.state`.

    Bare `state` is a partition column on the by-state-and-county aggregate; the
    national aggregate carries `in.state` instead. measures.py already adapts
    this way for the annual queries (see build_applicability_sql); the
    timeseries builders used to hardcode `m.state`, which is what tied them to
    the county table.
    """
    try:
        have = athena.table_columns(md_table, no_cache=no_cache)
    except Exception:                                             # noqa: BLE001
        return "state"
    return "state" if "state" in have else "in.state"


def assess_measure_timeseries_masked(ts_table: str, md_table: str, loc: dict,
                                     upgrades: list[str],
                                     no_cache: bool = False) -> pd.DataFrame:
    """Seasonal-average profiles per (scenario, applicability mask).

    Downstream this collapses to any population basis for any selected subset.
    Values stay in weighted kWh (MW = kWh / 1000 for an hourly mean).
    """
    tt = athena.table_column_types(ts_table)
    dialect = ts_dialect(ts_table, no_cache=no_cache)
    up_type = str(tt.get("upgrade", "varchar"))
    md_state = _md_state_col(md_table, no_cache=no_cache)
    ts = athena.query(
        build_ts_mask_sql(ts_table, md_table, loc, upgrades, dialect, up_type,
                          md_state=md_state),
        no_cache=no_cache, label=f"measure ts by mask {loc['label']}")
    ts["hour_ts"] = pd.to_datetime(ts["hour_ts"])
    month = ts["hour_ts"].dt.month
    season = pd.Series(np.nan, index=ts.index, dtype=object)
    for s_name, months in MEASURE_SEASONS.items():
        season[month.isin(months)] = s_name
    ts = ts.assign(season=season,
                   day_type=np.where(ts["hour_ts"].dt.weekday >= 5, "Weekend", "Weekday"),
                   hour=ts["hour_ts"].dt.hour)
    val_cols = (["elec_kwh", "gas_kwh"]
                + [e for e in ENDUSE_STACK_ORDER if e in ts.columns])
    prof = (ts.groupby(["upgrade", "mask", "season", "day_type", "hour"], as_index=False)
            [val_cols].mean())
    return prof.rename(columns={e: f"raw_{e}" for e in ENDUSE_STACK_ORDER if e in prof.columns})


def check_ts_masks(masked: pd.DataFrame, prof: pd.DataFrame, upgrades: list[str]) -> None:
    """own(m) from the masked profiles must reproduce the per-measure legs.

    Same invariant as _check_masks, on the hourly side: summing the masks that
    contain a measure's bit must give that measure's profile, and summing the
    baseline over those masks must give its applicable-baseline profile.
    """
    for i, up in enumerate(upgrades):
        bit = 1 << i
        for mask_scen, ref_up in ((up, up), ("0", f"base_{up}")):
            got = (masked[(masked["upgrade"].astype(str) == mask_scen)
                          & ((masked["mask"] & bit) > 0)]
                   .groupby(["season", "day_type", "hour"])["elec_kwh"].sum())
            want = (prof[prof["upgrade"].astype(str) == ref_up]
                    .set_index(["season", "day_type", "hour"])["elec_kwh"])
            if want.empty or got.empty:
                logger.warning("ts mask cross-check skipped for %s / %s", up, ref_up)
                continue
            j = got.align(want, join="inner")
            rel = float((j[0] - j[1]).abs().max() / (j[1].abs().max() or 1))
            if rel > 1e-6:
                logger.warning("ts mask leg disagrees with %s: max relative error %.4f%%",
                               ref_up, rel * 100)


def assess_measure_timeseries(ts_table: str, md_table: str, loc: dict,
                              upgrades: list[str], no_cache: bool = False) -> pd.DataFrame:
    tt = athena.table_column_types(ts_table)
    dialect = ts_dialect(ts_table, no_cache=no_cache)
    up_type = str(tt.get("upgrade", "varchar"))
    md_state = _md_state_col(md_table, no_cache=no_cache)
    sqft = athena.query(build_ts_sqft_sql(md_table, loc, upgrades, up_type,
                                              md_state=md_state),
                        no_cache=no_cache, label=f"measure ts sqft {loc['label']}")
    ts = athena.query(build_ts_sql(ts_table, md_table, loc, upgrades,
                                   dialect, up_type, md_state=md_state),
                      no_cache=no_cache, label=f"measure ts {loc['label']}")
    parts = [ts.merge(sqft, on="upgrade", how="left")]
    for up in upgrades:
        b = athena.query(build_ts_base_sql(ts_table, md_table, loc, up,
                                           dialect, up_type,
                                           md_state=md_state),
                         no_cache=no_cache, label=f"measure ts base {up} {loc['label']}")
        bs = athena.query(build_ts_base_sqft_sql(md_table, loc, up, up_type,
                                                   md_state=md_state),
                          no_cache=no_cache, label=f"measure ts base sqft {up} {loc['label']}")
        b["sqft_weighted"] = float(bs["sqft_weighted"].iloc[0])
        parts.append(b)
    ts = pd.concat(parts, ignore_index=True)
    ts["hour_ts"] = pd.to_datetime(ts["hour_ts"])
    ts["elec_kwh_per_sf"] = ts["elec_kwh"] / ts["sqft_weighted"]
    ts["gas_kwh_per_sf"] = ts["gas_kwh"] / ts["sqft_weighted"]
    for e in ENDUSE_STACK_ORDER:
        if e in ts.columns:
            ts[f"eu_{e}"] = ts[e] / ts["sqft_weighted"]

    # Raw weighted-kWh end-use columns survive under raw_ names so profiles can
    # be drawn in MW like the upstream measure timeseries plots (MW = kWh/1000
    # for hourly means).
    ts = ts.rename(columns={e: f"raw_{e}" for e in ENDUSE_STACK_ORDER if e in ts.columns})
    month = ts["hour_ts"].dt.month
    season = pd.Series(np.nan, index=ts.index, dtype=object)
    for s_name, months in MEASURE_SEASONS.items():
        season[month.isin(months)] = s_name
    daytype = np.where(ts["hour_ts"].dt.weekday >= 5, "Weekend", "Weekday")
    ts = ts.assign(season=season, day_type=daytype, hour=ts["hour_ts"].dt.hour)
    val_cols = (["elec_kwh_per_sf", "gas_kwh_per_sf", "elec_kwh", "gas_kwh"]
                + [f"eu_{e}" for e in ENDUSE_STACK_ORDER if f"eu_{e}" in ts.columns]
                + [f"raw_{e}" for e in ENDUSE_STACK_ORDER if f"raw_{e}" in ts.columns])
    prof = (ts.groupby(["upgrade", "season", "day_type", "hour"], as_index=False)[val_cols]
            .mean())
    return prof
