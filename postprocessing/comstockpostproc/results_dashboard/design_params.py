# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Design-parameter review: the modelling inputs that drive calibration choices.

What the model was TOLD to do, before arguing about what it produced. Lighting
and plug densities, ventilation, setpoints, fan and pump characteristics,
envelope, water heating, and the two comfort results that judge them.

Everything here was checked against the upstream measure that writes these
columns (`measures/comstock_sensitivity_reports/measure.rb`) and against
`comstock_column_definitions.csv`, because the column NAMES are misleading in
several places and a plausible-looking average is the failure mode:

  * `air_system_vav_avg_flow_ratio` is -999 for the 72.6% of buildings with no
    VAV loop. A naive average returns -931. Several other columns carry the same
    sentinel, so the guard is applied by rule, not case by case.
  * A zero usually means "no such system" -- 68% of buildings have no central
    air system, 26% no hot water -- and averaging those zeros in understates
    every one of those parameters. Fan power over buildings that HAVE an air
    system is 1.06 W/cfm; with the zeros folded in it reads 0.34.
  * But for unmet hours a zero is the ANSWER, not a gap: 34% of models meet
    setpoint all year. Same column shape, opposite rule.
  * Lighting power density is normalized by whole-building area, while interior
    equipment power density is normalized by the area of zones that HAVE
    equipment. They are not the same denominator, so `sqft * density` is invalid
    for plug loads and the two densities cannot be summed.
  * Setpoints are area-weighted over zones that have a thermostat, so the stock
    average has to be weighted by CONDITIONED area, not floor area.
  * Cooling setpoint max reaches 50 C: that encodes "cooling disabled when
    unoccupied", not a setback temperature.

Each metric therefore carries its own guard, its own weighting basis, and a
COVERAGE figure -- the share of weighted floor area (or buildings) the guard
leaves behind. A design parameter reported without its coverage is not
interpretable when two thirds of the stock is excluded by definition.
"""

from __future__ import annotations

import re

import logging

import pandas as pd

from . import athena

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------- conversions
# Every factor recomputed from first principles and cross-checked against
# comstockpostproc/units_mixin.py.
M_S_TO_CFM_FT2 = 196.850393700787   # m3/(m2 s) is a velocity: m/s -> ft/min
INWC_TO_W_PER_CFM = 0.117547        # 1 inwc x 1 cfm = 0.117547 W at 100% eff
M3_TO_GAL = 264.172052358148
PPL_M2_TO_PER_1000FT2 = 92.90304    # people/m2 -> people/1000 ft2
M2_TO_FT2 = 10.7639104167097
J_TO_KBTU = 9.4781712031332e-7
SENTINEL = -900                     # anything <= this is "not applicable"

# Baseline only, and only simulations that finished. Without the upgrade filter
# a table carrying upgrades holds one row per (building, upgrade) and every
# stock total silently multiplies.
BASE_WHERE = "upgrade = 0 AND completed_status = 'Success'"

SQFT = '"in.sqft..ft2"'
W = "weight"


def q(col: str) -> str:
    return f'"{col}"'


class Metric:
    """One design parameter: its value expression, its guard, its weighting.

    `expr`    already converted to the display unit.
    `guard`   SQL predicate deciding which buildings the parameter APPLIES to.
              Defaults to "value is not null"; pass a stricter one where a zero
              means "no such system".
    `weight`  the weighting basis. A weighted mean of an intensity must weight
              by that intensity's own denominator.
    `weight_label`
              what that basis IS, in words, for the coverage cell. Stated rather
              than inferred: the old rule tested whether the floor-area column
              appeared anywhere in `weight`, which called the envelope metrics
              "buildings" (they weight by surface area) and called lighting EFLH
              "floor area" (it weights by connected lighting load) -- 9 of 29
              metrics captioned with a basis that was not theirs.
    """

    def __init__(self, key, name, group, unit, expr, weight, guard=None,
                 needs=(), note="", kind="mean", weight_label=None):
        self.key = key
        self.name = name
        self.group = group
        self.unit = unit
        self.expr = expr
        self.weight = weight
        self.guard = guard or f"{expr} IS NOT NULL"
        self.needs = tuple(needs)
        self.note = note
        self.kind = kind          # mean | distribution
        self.weight_label = weight_label or (
            "floor area" if SQFT in weight else "buildings")


def _metrics() -> list[Metric]:
    lpd = q("out.params.interior_lighting_power_density..w_per_ft2")
    eflh = q("out.params.interior_lighting_eflh..hr")
    epd = q("out.params.interior_electric_equipment_power_density..w_per_ft2")
    e_eflh = q("out.params.interior_electric_equipment_eflh..hr")
    occ = q("out.params.occupant_density_ppl_per_m_2..people_per_m2")
    occ_eflh = q("out.params.occupant_eflh..hr")
    oa = q("out.params.design_outdoor_air_flow_rate..m3_per_m2_s")
    oaf = q("out.params.average_outdoor_air_fraction")
    h_max = q("out.params.average_heating_setpoint_max..c")
    h_min = q("out.params.average_heating_setpoint_min..c")
    c_min = q("out.params.average_cooling_setpoint_min..c")
    c_max = q("out.params.average_cooling_setpoint_max..c")
    unmet_h = q("out.params.hours_heating_setpoint_not_met..hr")
    unmet_c = q("out.params.hours_cooling_setpoint_not_met..hr")
    sp = q("out.params.air_system_fan_static_pressure..inwc")
    eff = q("out.params.air_system_fan_total_efficiency")
    minflow = q("out.params.air_system_fan_power_minimum_flow_fraction")
    vav = q("out.params.air_system_vav_avg_flow_ratio")
    pump_eff = q("out.params.pump_flow_weighted_avg_motor_efficiency")
    wall_u = q("out.params.average_wall_u_value..btu_per_ft2_f_hr")
    roof_u = q("out.params.average_roof_u_value..btu_per_ft2_f_hr")
    win_u = q("out.params.average_window_u_value..btu_per_ft2_f_hr")
    shgc = q("out.params.average_window_shgc")
    wwr = q("out.params.window_to_wall_ratio")
    wall_a = q("out.params.ext_wall_area..m2")
    roof_a = q("out.params.ext_roof_area..m2")
    win_a = q("out.params.ext_window_area..m2")
    hw = q("out.params.hot_water_volume..m3")
    fr_heat = q("out.params.building_fraction_heated")
    fr_cool = q("out.params.building_fraction_cooled")
    # These two are published as VARCHAR, not numeric, so they need an explicit
    # cast; TRY_CAST rather than CAST so a non-numeric value yields NULL and is
    # excluded by the guard instead of failing the whole query.
    wk = f'TRY_CAST({q("in.weekday_operating_hours..hr")} AS double)'
    we = f'TRY_CAST({q("in.weekend_operating_hours..hr")} AS double)'

    area = f"{W} * {SQFT}"
    heated = f"{W} * {SQFT} * COALESCE({fr_heat}, 1)"
    cooled = f"{W} * {SQFT} * COALESCE({fr_cool}, 1)"

    M = []
    a = M.append

    # ---- Loads -------------------------------------------------------------
    a(Metric("lpd", "Lighting power density", "Loads", "W/ft²",
             lpd, area, f"{lpd} > 0",
             note="Normalized by whole-building floor area."))
    a(Metric("light_eflh", "Lighting EFLH", "Loads", "hr/yr",
             eflh, f"{area} * {lpd}", f"{eflh} > 0 AND {lpd} > 0",
             note="Weighted by connected lighting load, so density x EFLH "
                  "reproduces total lighting energy.",
             weight_label="connected lighting load"))
    a(Metric("light_implied", "Implied lighting use (design)", "Loads", "kWh/ft²·yr",
             f"({lpd} * {eflh} / 1000.0)", area, f"{lpd} > 0 AND {eflh} > 0",
             note="Design-implied, NOT simulated: density x EFLH. Compare "
                  "against the metered interior-lighting end use."))
    a(Metric("epd", "Plug-load power density", "Loads", "W/ft²",
             epd, W, f"{epd} > 0", kind="distribution",
             note="Per equipment-served zone area, NOT whole-building area, so "
                  "it cannot be multiplied by floor area or added to lighting "
                  "density. Shown as a per-building distribution."))
    a(Metric("epd_eflh", "Plug-load EFLH (bound)", "Loads", "hr/yr",
             e_eflh, W, f"{e_eflh} > 0", kind="distribution",
             note="Building-meter energy over zone-summed power: the two are "
                  "different populations, so read it as a bound, not an EFLH."))
    a(Metric("occ", "Occupant density", "Loads", "people/1000 ft²",
             f"({occ} * {PPL_M2_TO_PER_1000FT2})", area, f"{occ} > 0"))
    a(Metric("occ_eflh", "Occupant EFLH", "Loads", "hr/yr",
             occ_eflh, area, f"{occ_eflh} > 0"))
    a(Metric("wk_hours", "Weekday operating hours", "Loads", "hr/day",
             wk, W, f"{wk} > 0"))
    a(Metric("we_hours", "Weekend operating hours", "Loads", "hr/day",
             we, W, f"{we} > 0"))

    # ---- Ventilation and setpoints ----------------------------------------
    a(Metric("oa_flow", "Design outdoor air", "Ventilation & setpoints", "cfm/ft²",
             f"({oa} * {M_S_TO_CFM_FT2})", area, f"{oa} > 0",
             note="Per OA-SERVED floor area, not whole-building area."))
    a(Metric("oa_frac", "Average outdoor air fraction", "Ventilation & setpoints", "%",
             f"({oaf} * 100)", area, f"{oaf} > 0",
             note="Buildings with no air system are excluded, not counted as 0."))
    a(Metric("htg_sp", "Heating setpoint, occupied", "Ventilation & setpoints", "°F",
             f"({h_max} * 1.8 + 32)", heated, f"{h_max} IS NOT NULL",
             note="Weighted by heated floor area. The schedule MAX is the "
                  "occupied setpoint; the min is the setback.",
             weight_label="heated floor area"))
    a(Metric("htg_setback", "Heating setback depth", "Ventilation & setpoints", "°F",
             f"(({h_max} - {h_min}) * 1.8)", heated,
             f"{h_max} IS NOT NULL AND {h_min} IS NOT NULL",
             note="A temperature DIFFERENCE, so 1.8 with no +32 offset.",
             weight_label="heated floor area"))
    a(Metric("clg_sp", "Cooling setpoint, occupied", "Ventilation & setpoints", "°F",
             f"({c_min} * 1.8 + 32)", cooled, f"{c_min} IS NOT NULL",
             note="The schedule MIN is the occupied setpoint; the max is the "
                  "unoccupied setup, reported separately as clg_setup.",
             weight_label="cooled floor area"))
    # Cooling setup was long omitted on the belief that the schedule max is always a
    # 50 C sentinel meaning "cooling disabled unoccupied". That is not true of current
    # runs -- measured maxima sit at 25-26 C, a real setup temperature, and 64-95% of
    # cooled floor area carries one. The guard below still excludes a genuine disabled
    # sentinel so the mean stays a setup depth rather than mixing in a 25 C artifact.
    a(Metric("clg_setup", "Cooling setup depth", "Ventilation & setpoints", "°F",
             f"(({c_max} - {c_min}) * 1.8)", cooled,
             f"{c_max} IS NOT NULL AND {c_min} IS NOT NULL AND {c_max} < 45 "
             f"AND {c_max} - {c_min} > 0.5",
             note="A temperature DIFFERENCE, so 1.8 with no +32 offset. Buildings "
                  "whose cooling is disabled when unoccupied (schedule max >= 45 C) "
                  "are EXCLUDED, not counted as a large setup; so is a flat schedule "
                  "(max - min <= 0.5 C), which is no setup at all. Coverage therefore "
                  "reads as the share of cooled floor area that actually sets up.",
             weight_label="cooled floor area"))
    a(Metric("unmet_htg", "Unmet heating hours", "Comfort", "hr/yr",
             unmet_h, W, f"{unmet_h} IS NOT NULL",
             note="Zeros KEPT: a model that meets setpoint all year is the "
                  "good case. All hours, not occupied hours, so the ASHRAE "
                  "90.1 App. G 300-hour screen does not apply."))
    a(Metric("unmet_clg", "Unmet cooling hours", "Comfort", "hr/yr",
             unmet_c, W, f"{unmet_c} IS NOT NULL",
             note="Zeros KEPT, as for heating."))

    # ---- Fans and pumps ----------------------------------------------------
    a(Metric("fan_wcfm", "Air-system fan power", "Fans & pumps", "W/cfm",
             f"(({sp} * {INWC_TO_W_PER_CFM}) / NULLIF({eff}, 0))", area,
             f"{sp} > 0 AND {eff} > 0",
             note="Static pressure x 0.117547 / total efficiency. Only "
                  "buildings with a central air system; 68% have none."))
    a(Metric("fan_sp", "Air-system fan static pressure", "Fans & pumps", "in. w.c.",
             sp, area, f"{sp} > 0"))
    a(Metric("fan_eff", "Air-system fan total efficiency", "Fans & pumps", "%",
             f"({eff} * 100)", area, f"{eff} > 0"))
    a(Metric("fan_minflow", "Fan minimum flow fraction", "Fans & pumps", "%",
             f"({minflow} * 100)", area, f"{minflow} > 0"))
    a(Metric("vav_flow", "VAV average flow ratio", "Fans & pumps", "%",
             f"({vav} * 100)", area, f"{vav} > {SENTINEL} AND {vav} > 0",
             needs=("out.params.air_system_vav_avg_flow_ratio",),
             note="-999 marks 'no VAV loop' on 72.6% of buildings and is "
                  "excluded, not averaged."))
    a(Metric("pump_eff", "Pump motor efficiency", "Fans & pumps", "%",
             f"({pump_eff} * 100)", W, f"{pump_eff} > 0",
             needs=("out.params.pump_flow_weighted_avg_motor_efficiency",),
             note="Weighted by building count: rated pump power is 0 for "
                  "autosized pumps, so it cannot be used as a weight."))

    # ---- Envelope ----------------------------------------------------------
    # Each U-value is weighted by ITS OWN surface area, and guarded > 0 because
    # an uncomputable surface is written as U=0 with its full area.
    a(Metric("wall_u", "Wall U-value", "Envelope", "Btu/h·ft²·°F",
             wall_u, f"{W} * COALESCE({wall_a}, 0)", f"{wall_u} > 0",
             weight_label="exterior wall area"))
    a(Metric("roof_u", "Roof U-value", "Envelope", "Btu/h·ft²·°F",
             roof_u, f"{W} * COALESCE({roof_a}, 0)", f"{roof_u} > 0",
             weight_label="roof area"))
    a(Metric("win_u", "Window U-value", "Envelope", "Btu/h·ft²·°F",
             win_u, f"{W} * COALESCE({win_a}, 0)", f"{win_u} > 0",
             weight_label="window area"))
    a(Metric("shgc", "Window SHGC", "Envelope", "–",
             shgc, f"{W} * COALESCE({win_a}, 0)", f"{shgc} > 0",
             weight_label="window area"))
    a(Metric("wwr", "Window-to-wall ratio", "Envelope", "%",
             f"({wwr} * 100)", f"{W} * COALESCE({wall_a}, 0)", f"{wwr} > 0",
             weight_label="exterior wall area"))

    # ---- Water heating -----------------------------------------------------
    a(Metric("hw_ft2", "Hot water use", "Water heating", "gal/ft²·yr",
             f"({hw} * {M3_TO_GAL} / NULLIF({SQFT}, 0))", area, f"{hw} > 0",
             note="Hot-side draw. Buildings with no hot water (26%) excluded."))
    a(Metric("hw_person", "Hot water per person", "Water heating", "gal/person·day",
             f"({hw} * {M3_TO_GAL} / 365.0"
             f" / NULLIF({occ} * {SQFT} / {M2_TO_FT2}, 0))",
             area, f"{hw} > 0 AND {occ} > 0",
             note="Design occupant count from occupant density x floor area."))
    return M


METRICS = _metrics()
GROUPS = ["Loads", "Ventilation & setpoints", "Fans & pumps", "Envelope",
          "Water heating", "Comfort"]

# Aggregation dimensions. Everything here except climate zone exists in both
# releases, so a run comparison is possible on all of them.
DIMENSIONS = {
    "none": None,
    "building_type": "in.comstock_building_type",
    "vintage": "in.vintage",
    "census_division": "in.census_division_name",
    "state": "in.state",
    "hvac_system": "in.hvac_system_type",
    "climate_zone": "in.as_simulated_ashrae_iecc_climate_zone_2006",
}


def available(have: set[str]) -> list[Metric]:
    """Metrics whose columns this release actually publishes.

    A missing parameter is dropped, never rendered as zero or as an empty
    share: the R2 tables have no pump or VAV columns at all.
    """
    out = []
    for m in METRICS:
        cols = {c.strip('"') for c in _cols_in(m.expr) | _cols_in(m.guard)
                | _cols_in(m.weight)}
        if all(c in have for c in cols):
            out.append(m)
        else:
            logger.info("  design params: %s unavailable (missing %s)",
                        m.key, sorted(c for c in cols if c not in have))
    return out


def _cols_in(expr: str) -> set[str]:
    import re
    return set(re.findall(r'"([^"]+)"', expr or ""))


# Dimensions worth crossing with building type. State is deliberately excluded:
# 51 categories x 15 types would dominate the payload, and the state map stays
# available in the all-types view where it is actually read.
BTYPE_CROSS = ("none", "vintage", "census_division", "climate_zone", "hvac_system")
BTYPE_COL = "in.comstock_building_type"


def metric_meta(md_table: str) -> pd.DataFrame:
    """Static per-metric description, stored ONCE rather than on every row.

    Name, unit and the explanatory note came to 42% of this tab's payload when
    repeated across all value rows, which is what made crossing by building type
    unaffordable.
    """
    mets = available(athena.table_columns(md_table))
    return pd.DataFrame([{
        "metric": m.key, "name": m.name, "group": m.group, "unit": m.unit,
        "kind": m.kind, "note": m.note,
        "coverage_basis": m.weight_label,
    } for m in mets])


def _per_model_weight(expr: str) -> str:
    """A weight basis rewritten to use the per-model total weight.

    Only the bare `weight` token is replaced. The other factors in every basis
    (floor area, lighting power density, exterior areas) are model-level and
    identical across a model's geography rows, so they are left alone.
    """
    return re.sub(r"\bweight\b", "weight_model", expr)


def build_params_sql(md_table: str, metrics: list[Metric], dim: str | None,
                     by_btype: bool = False, base_where: str | None = None) -> str:
    """Weighted mean, median, p10/p90 and coverage for each metric.

    Coverage is the point of the CASE guards: it reports how much of the
    weighted stock each parameter actually applies to, so a figure computed over
    a third of the buildings cannot be mistaken for a stock-wide one.
    """
    sel = []
    for m in metrics:
        # weight -> weight_model: the per-model total from the window below.
        # Every basis is `weight` times model-level factors, so this is an exact
        # substitution, not an approximation. See the module note on grain.
        g, e, w = m.guard, m.expr, _per_model_weight(m.weight)
        sel += [
            f"  SUM(CASE WHEN {g} THEN ({w}) * ({e}) END)"
            f" / NULLIF(SUM(CASE WHEN {g} THEN ({w}) END), 0) AS {m.key}__wmean",
            f"  APPROX_PERCENTILE(CASE WHEN {g} THEN CAST({e} AS double) END, 0.5)"
            f" AS {m.key}__p50",
            f"  APPROX_PERCENTILE(CASE WHEN {g} THEN CAST({e} AS double) END, 0.1)"
            f" AS {m.key}__p10",
            f"  APPROX_PERCENTILE(CASE WHEN {g} THEN CAST({e} AS double) END, 0.9)"
            f" AS {m.key}__p90",
            # DISTINCT: on an apportioned aggregate a model appears once
            # per geography, so COUNT counted rows and reported them as a
            # model count (1.89x on the run measured).
            f"  COUNT(DISTINCT CASE WHEN {g} THEN bldg_id END) AS {m.key}__n",
            # Coverage on the metric's OWN weighting basis. Reporting it as a
            # share of building count understates an area-weighted parameter:
            # central air systems are in 8% of buildings by count but a far
            # larger share of floor area, because the big buildings have them.
            f"  SUM(CASE WHEN {g} THEN ({w}) END) AS {m.key}__wcov",
            f"  SUM({w}) AS {m.key}__wall",
        ]
    keys = []
    if by_btype:
        keys.append((q(BTYPE_COL), "btype"))
    if dim:
        keys.append((q(dim), "category"))
    grp = "".join(f"  {col} AS {alias},\n" for col, alias in keys)
    tail = ("GROUP BY " + ", ".join(c for c, _ in keys) + "\n") if keys else ""
    # One row per MODEL, carrying the model's total weight. Without this the
    # APPROX_PERCENTILEs below run over apportionment rows, so a model spread
    # across k geographies counts k times and the "unweighted across models"
    # percentiles are really weighted by geographic spread.
    #
    # SELECT * is deliberate: the metric guards and expressions are arbitrary
    # SQL over columns this function never enumerates, so they must all survive.
    per_model = (f"(SELECT *,\n"
                 f"        SUM({W}) OVER (PARTITION BY bldg_id) AS weight_model,\n"
                 f"        ROW_NUMBER() OVER (PARTITION BY bldg_id"
                 f" ORDER BY bldg_id) AS _rn\n"
                 f" FROM {md_table}\n WHERE {base_where or athena.baseline_where(md_table)}) t")
    return (f"SELECT\n{grp}"
            f"  COUNT(*) AS n_rows,\n  SUM(weight_model) AS w_total,\n"
            + ",\n".join(sel) + f"\nFROM {per_model}\nWHERE t._rn = 1\n{tail}")


def assess_design_params(md_table: str, run_key: str,
                         no_cache: bool = False) -> pd.DataFrame:
    """Long frame: one row per (run, btype, dimension, category, metric).

    `btype` is "All" for the stock-wide rows and the building type for the
    per-type cross-tab, so the pane can be filtered to one type without a
    second query path.
    """
    have = athena.table_columns(md_table)
    mets = available(have)
    if not mets:
        return pd.DataFrame()
    rows = []
    passes = [(k, c, False) for k, c in DIMENSIONS.items()]
    if BTYPE_COL in have:
        passes += [(k, DIMENSIONS[k], True) for k in BTYPE_CROSS if k in DIMENSIONS]
    for dim_key, dim_col, by_bt in passes:
        if dim_col is not None and dim_col not in have:
            logger.info("  design params: dimension %s unavailable", dim_key)
            continue
        label = (f"design params {run_key} by {dim_key}"
                 + (" x building type" if by_bt else ""))
        df = athena.query(build_params_sql(md_table, mets, dim_col, by_bt),
                          no_cache=no_cache, label=label)
        for _, r in df.iterrows():
            for m in mets:
                wcov = r.get(f"{m.key}__wcov")
                wcov = float(wcov) if wcov == wcov and wcov is not None else 0.0
                wall = r.get(f"{m.key}__wall")
                w_total = float(wall) if wall == wall and wall is not None else 0.0
                row = {
                    "run": run_key,
                    "btype": str(r["btype"]) if by_bt else "All",
                    "dimension": dim_key,
                    "category": "All" if dim_col is None else str(r["category"]),
                    "metric": m.key,
                    "wmean": r.get(f"{m.key}__wmean"),
                    "p50": r.get(f"{m.key}__p50"),
                    "n_models": int(r.get(f"{m.key}__n") or 0),
                    "coverage_pct": 100.0 * wcov / w_total if w_total else float("nan"),
                }
                # The p10-p90 spread is carried only on the stock-wide rows: on
                # the per-type cross-tab it would roughly double the payload for
                # a figure that view does not show.
                if not by_bt:
                    row["p10"] = r.get(f"{m.key}__p10")
                    row["p90"] = r.get(f"{m.key}__p90")
                rows.append(row)
    return pd.DataFrame(rows)
