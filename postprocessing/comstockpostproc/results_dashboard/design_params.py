# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Design-parameter review: the modelling inputs that drive calibration choices.

What the model was TOLD to do, before arguing about what it produced. Lighting
and plug densities, ventilation, setpoints, fan and pump characteristics,
envelope, water heating, and the two comfort results that judge them.

Everything here was checked against the upstream measure that writes these
columns (`measures/comstock_sensitivity_reports/measure.rb`) and against
`comstock_column_definitions.csv`, because the column NAMES are misleading in
several places and a plausible-looking average is the failure mode. The rules:

  * No placeholder is averaged as a value. The measure writes sentinels (-999
    for "no VAV loop"), zeros for "no such system", a perfectly efficient zero-head
    pump on hot-water loops that have no real pump, and setpoint averages that
    fold in zones whose schedule means "cooling off". Each metric's guard
    excludes exactly those, and its note says what was excluded and why.
  * A zero that IS the answer is kept: unmet hours of 0, a flat cooling
    schedule (setup of 0), a building with no occupants. Same column shape as
    a "no such system" zero, opposite rule, so it is decided per metric.
  * Coverage wherever the data has it. Fans are recorded in two places (air-
    loop fans, and the fans inside packaged/unitary and zone equipment), so
    both are shown; between them every model has a fan.
  * Each metric is weighted by its own denominator (floor area for an
    intensity, connected load for an EFLH, window area for a window U-value)
    and reports COVERAGE on that basis -- the share of the weighted stock the
    guard leaves behind -- so a figure computed over a subset of buildings
    cannot be mistaken for a stock-wide one.
  * Notes carry no measured percentages. A share quoted in prose goes stale
    with the next run; the coverage cell beside the number is always current.
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
# A thermostat schedule value this far above any occupied cooling setpoint is
# the "cooling off" value the prototypes put on uncooled zones. The reporting
# measure averages it into a building's cooling setpoint with the real zones,
# so a building average above this line is a blend, not a setpoint.
COOLING_OFF_C = 35.0

# Baseline only, and only simulations that finished. Without the upgrade filter
# a table carrying upgrades holds one row per (building, upgrade) and every
# stock total silently multiplies.
BASE_WHERE = "upgrade = 0 AND completed_status = 'Success'"

SQFT = '"in.sqft..ft2"'
W = "weight"

# Tokens a guard may use for a scalar subquery against the run's own table.
# build_params_sql fills them in; nothing else should see them.
TABLE_TOKEN = "{TABLE}"
WHERE_TOKEN = "{BASE_WHERE}"


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
    `absent_note`
              what it means when the row exists but NO model in the selection
              passes the guard. Rendered in place of the number; without it the
              page said "not published", which is a statement about the
              release's columns, not about the buildings.
    """

    def __init__(self, key, name, group, unit, expr, weight, guard=None,
                 needs=(), note="", kind="mean", weight_label=None,
                 absent_note=""):
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
        self.absent_note = absent_note


def _metrics() -> list[Metric]:
    lpd = q("out.params.interior_lighting_power_density..w_per_ft2")
    light_kwh = q("out.electricity.interior_lighting.energy_consumption..kwh")
    epd = q("out.params.interior_electric_equipment_power_density..w_per_ft2")
    e_eflh = q("out.params.interior_electric_equipment_eflh..hr")
    occ = q("out.params.occupant_density_ppl_per_m_2..people_per_m2")
    occ_eflh = q("out.params.occupant_eflh..hr")
    oa = q("out.params.design_outdoor_air_flow_rate..m3_per_m2_s")
    oaf = q("out.params.average_outdoor_air_fraction")
    nal = q("out.params.num_air_loops")
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
    zsp = q("out.params.zone_hvac_fan_static_pressure..inwc")
    zeff = q("out.params.zone_hvac_fan_total_efficiency")
    ec = q("out.params.pump_flow_weighted_avg_motor_efficiency_const_spd")
    ev = q("out.params.pump_flow_weighted_avg_motor_efficiency_var_spd")
    hc = q("out.params.pump_count_hvac_const_spd")
    hv = q("out.params.pump_count_hvac_var_spd")
    sc = q("out.params.pump_count_swh_const_spd")
    sv = q("out.params.pump_count_swh_var_spd")
    pc = q("out.params.pump_total_constant_speed_pump_power_w..w")
    pv = q("out.params.pump_total_variable_speed_pump_power_w..w")
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

    # Air-loop fan values are DILUTED in the reporting measure wherever a
    # building has an air loop whose fan it cannot read (the fan sits inside a
    # unitary system): that loop's airflow enters the flow-weighted average at
    # zero pressure and zero efficiency. Nothing exported says which buildings
    # are affected, so the rule is the data's own: a value below the lowest one
    # any SINGLE-air-loop building in the run reports cannot be an undiluted
    # fan property, because a single loop is either read whole or not at all.
    # Partial dilution above that floor passes; only the measure can fix that.
    def undiluted(col):
        return (f"{col} >= (SELECT MIN({col}) FROM {TABLE_TOKEN}"
                f" WHERE {WHERE_TOKEN} AND {nal} = 1 AND {col} > 0)")
    fan_ok = f"{sp} > 0 AND {eff} > 0 AND {undiluted(sp)} AND {undiluted(eff)}"
    FAN_NOTE = ("Fans on an air loop whose fan the reporting measure reads directly "
                "(VAV, PVAV, DOAS and similar). Fans inside packaged/unitary "
                "systems and zone equipment are in the 'Unitary / zone-equipment' "
                "rows. Where a building also has an air loop whose fan the measure "
                "cannot read, that loop's airflow enters this average at zero; a "
                "value below the lowest value any single-air-loop building in the "
                "run reports is excluded as such a blend.")
    FAN_ABSENT = ("no model of this type has an air-loop fan the reporting measure "
                  "reads directly; see the unitary / zone-equipment rows")
    ZFAN_NOTE = ("Fans inside packaged/unitary systems (PSZ, RTU, residential "
                 "furnace) and zone equipment (PTAC/PTHP, fan coils, water-source "
                 "heat pumps), weighted within a building by design airflow.")
    ZFAN_ABSENT = ("no model of this type has a packaged, unitary or zone-equipment "
                   "fan; see the air-loop rows")

    M = []
    a = M.append

    # ---- Loads -------------------------------------------------------------
    a(Metric("lpd", "Lighting power density", "Loads", "W/ft²",
             lpd, area, f"{lpd} > 0",
             note="Normalized by whole-building floor area."))
    # Metered energy over connected load, not the reporting measure's EFLH
    # column: that column divides two LightingSummary figures that carry zone
    # multipliers inconsistently, so for every multiplied model it disagrees
    # with the lighting energy the same model metered.
    a(Metric("light_eflh", "Lighting EFLH", "Loads", "hr/yr",
             f"({light_kwh} * 1000.0 / NULLIF({lpd} * {SQFT}, 0))",
             f"{area} * {lpd}", f"{lpd} > 0 AND {light_kwh} > 0",
             note="Metered interior-lighting energy over connected load (density x "
                  "floor area), so density x EFLH reproduces the metered lighting "
                  "energy. Weighted by connected lighting load.",
             weight_label="connected lighting load"))
    a(Metric("epd", "Plug-load power density", "Loads", "W/ft²",
             epd, area, f"{epd} > 0",
             note="Normalized by the floor area of zones that carry plug loads, "
                  "which the prototypes keep close to whole-building area. "
                  "Weighted by floor area."))
    a(Metric("epd_eflh", "Plug-load EFLH", "Loads", "hr/yr",
             e_eflh, f"{area} * {epd}", f"{e_eflh} > 0 AND {epd} > 0",
             note="Building-meter plug energy over connected plug load, weighted "
                  "by connected load. Where the meter includes loads outside the "
                  "zone-summed power it exceeds the hours in a year; read such a "
                  "value as an upper bound.",
             weight_label="connected plug load"))
    a(Metric("occ", "Occupant density", "Loads", "people/1000 ft²",
             f"({occ} * {PPL_M2_TO_PER_1000FT2})", area, f"{occ} IS NOT NULL",
             note="Models with no occupants are kept at zero: no occupants is a "
                  "modelled property, not a missing value."))
    a(Metric("occ_eflh", "Occupant EFLH", "Loads", "hr/yr",
             occ_eflh, area, f"{occ_eflh} > 0 AND {occ} > 0",
             note="Models with no occupants are excluded: there are no occupant "
                  "hours to average."))
    a(Metric("wk_hours", "Weekday operating hours", "Loads", "hr/day",
             wk, W, f"{wk} > 0"))
    a(Metric("we_hours", "Weekend operating hours", "Loads", "hr/day",
             we, W, f"{we} > 0"))

    # ---- Ventilation and setpoints ----------------------------------------
    a(Metric("oa_flow", "Design outdoor air", "Ventilation & setpoints", "cfm/ft²",
             f"({oa} * {M_S_TO_CFM_FT2})", area, f"{oa} > 0",
             note="Per OA-SERVED floor area, not whole-building area."))
    a(Metric("oa_frac", "Air-loop outdoor air fraction", "Ventilation & setpoints", "%",
             f"({oaf} * 100)", area, f"{nal} > 0 AND {oaf} IS NOT NULL",
             needs=("out.params.num_air_loops",),
             note="Outdoor-air share of air-loop supply flow. An air loop with no "
                  "outdoor-air intake counts as zero; a dedicated outdoor-air "
                  "system is nearly all outdoor air by design. Buildings with no "
                  "air loop (zone equipment only) are excluded: the reporting "
                  "measure does not record zone-equipment outdoor air.",
             absent_note="no model of this type has an air loop; zone-equipment "
                         "outdoor air is not recorded by the reporting measure"))
    a(Metric("htg_sp", "Heating setpoint, occupied", "Ventilation & setpoints", "°F",
             f"({h_max} * 1.8 + 32)", heated, f"{h_max} IS NOT NULL",
             note="Weighted by heated floor area. The schedule MAX is the "
                  "occupied setpoint; the min is the setback.",
             weight_label="heated floor area"))
    a(Metric("htg_setback", "Heating setback depth", "Ventilation & setpoints", "°F",
             f"(({h_max} - {h_min}) * 1.8)", heated,
             f"{h_max} IS NOT NULL AND {h_min} IS NOT NULL",
             note="A temperature DIFFERENCE, so 1.8 with no +32 offset. A flat "
                  "schedule is a setback of zero and is kept.",
             weight_label="heated floor area"))
    # The reporting measure averages the cooling schedule over EVERY zone with
    # a cooling thermostat, weighted by zone area -- including zones that are
    # not cooled, whose schedule holds a "cooling off" value far above any
    # occupied setpoint. A building whose exported average lands above that
    # line (warehouses, whose office zones are the only cooled ones) is a blend
    # of a setpoint and an off value; it is excluded, and the share-cooled row
    # below says how much of the type that is.
    real_clg = f"{c_min} IS NOT NULL AND {c_min} < {COOLING_OFF_C}"
    CLG_ABSENT = ("every model of this type exports a cooling value that averages "
                  "uncooled zones with cooled ones; see 'Share of floor area cooled'")
    a(Metric("clg_sp", "Cooling setpoint, occupied", "Ventilation & setpoints", "°F",
             f"({c_min} * 1.8 + 32)", cooled, real_clg,
             note="Weighted by cooled floor area. The schedule MIN is the occupied "
                  "setpoint; the max is the unoccupied setup, reported separately "
                  "as the setup depth. The reporting measure averages every zone "
                  "with a cooling schedule, cooled or not; a building whose "
                  "average sits above any occupied setpoint is such a blend and is "
                  "excluded rather than shown as a setpoint.",
             weight_label="cooled floor area", absent_note=CLG_ABSENT))
    a(Metric("clg_setup", "Cooling setup depth", "Ventilation & setpoints", "°F",
             f"(({c_max} - {c_min}) * 1.8)", cooled,
             f"{real_clg} AND {c_max} IS NOT NULL AND {c_max} < {COOLING_OFF_C}",
             note="A temperature DIFFERENCE (schedule max minus min), so 1.8 with "
                  "no +32 offset. A flat schedule is a setup of zero and is kept, "
                  "so this averages like the heating setback beside it. Buildings "
                  "whose exported schedule blends uncooled zones are excluded, as "
                  "for the cooling setpoint.",
             weight_label="cooled floor area", absent_note=CLG_ABSENT))
    a(Metric("fr_cooled", "Share of floor area cooled", "Ventilation & setpoints", "%",
             f"({fr_cool} * 100)", area, f"{fr_cool} IS NOT NULL",
             note="Cooled zone area over total zone area, from the model. Where "
                  "much of a type's area is uncooled, the exported cooling-setpoint "
                  "averages blend uncooled zones and are not shown as setpoints."))
    a(Metric("unmet_htg", "Unmet heating hours", "Comfort", "hr/yr",
             unmet_h, W, f"{unmet_h} IS NOT NULL",
             note="Zeros KEPT: a model that meets setpoint all year is the "
                  "good case. All hours, not occupied hours, so the ASHRAE "
                  "90.1 App. G 300-hour screen does not apply."))
    a(Metric("unmet_clg", "Unmet cooling hours", "Comfort", "hr/yr",
             unmet_c, W, f"{unmet_c} IS NOT NULL",
             note="Zeros KEPT, as for heating."))

    # ---- Fans and pumps ----------------------------------------------------
    a(Metric("fan_wcfm", "Air-loop (AHU) fan power", "Fans & pumps", "W/cfm",
             f"(({sp} * {INWC_TO_W_PER_CFM}) / NULLIF({eff}, 0))", area, fan_ok,
             note="Static pressure x 0.117547 / total efficiency. " + FAN_NOTE,
             absent_note=FAN_ABSENT))
    a(Metric("fan_sp", "Air-loop (AHU) fan static pressure", "Fans & pumps", "in. w.c.",
             sp, area, fan_ok, note=FAN_NOTE, absent_note=FAN_ABSENT))
    a(Metric("fan_eff", "Air-loop (AHU) fan total efficiency", "Fans & pumps", "%",
             f"({eff} * 100)", area, fan_ok, note=FAN_NOTE, absent_note=FAN_ABSENT))
    # 1.0 is the correct minimum flow of a constant-volume fan, but averaged with
    # VAV turndowns it produced a number that was neither; VAV fans only.
    a(Metric("fan_minflow", "VAV fan minimum flow fraction", "Fans & pumps", "%",
             f"({minflow} * 100)", area,
             f"{fan_ok} AND {minflow} > 0 AND {minflow} < 0.999 AND {vav} > {SENTINEL}",
             needs=("out.params.air_system_vav_avg_flow_ratio",),
             note="Variable-volume air-loop fans only: a constant-volume fan's "
                  "minimum flow equals its design flow by definition and is left out rather than "
                  "averaged with turndowns. " + FAN_NOTE,
             absent_note="no model of this type has a VAV fan on an air loop"))
    a(Metric("vav_flow", "VAV average flow ratio", "Fans & pumps", "%",
             f"({vav} * 100)", area, f"{vav} > {SENTINEL} AND {vav} > 0",
             needs=("out.params.air_system_vav_avg_flow_ratio",),
             note="Average operating airflow over design airflow, VAV loops only. "
                  "Buildings with no VAV loop are excluded, not averaged as zero.",
             absent_note="no model of this type has a VAV loop"))
    a(Metric("zfan_wcfm", "Unitary / zone-equipment fan power", "Fans & pumps", "W/cfm",
             f"(({zsp} * {INWC_TO_W_PER_CFM}) / NULLIF({zeff}, 0))", area,
             f"{zsp} > 0 AND {zeff} > 0",
             needs=("out.params.zone_hvac_fan_static_pressure..inwc",
                    "out.params.zone_hvac_fan_total_efficiency"),
             note="Static pressure x 0.117547 / total efficiency. " + ZFAN_NOTE,
             absent_note=ZFAN_ABSENT))
    a(Metric("zfan_sp", "Unitary / zone-equipment fan static pressure", "Fans & pumps",
             "in. w.c.", zsp, area, f"{zsp} > 0 AND {zeff} > 0",
             needs=("out.params.zone_hvac_fan_static_pressure..inwc",),
             note=ZFAN_NOTE, absent_note=ZFAN_ABSENT))
    a(Metric("zfan_eff", "Unitary / zone-equipment fan total efficiency", "Fans & pumps",
             "%", f"({zeff} * 100)", area, f"{zsp} > 0 AND {zeff} > 0",
             needs=("out.params.zone_hvac_fan_total_efficiency",),
             note=ZFAN_NOTE, absent_note=ZFAN_ABSENT))
    # Pumps. A service-hot-water loop with no real pump carries a zero-head
    # placeholder pump whose motor efficiency is exactly 100% and whose power
    # is nil; the reporting measure counts it like any other pump, as a
    # variable-speed SWH pump. The overall flow-weighted efficiency therefore
    # reads 100% for every building whose only "pump" is that placeholder, and
    # is pulled toward 100% wherever the placeholder shares a building with real
    # pumps. Only the separable populations are shown.
    PUMP_NOTE = ("Rated-flow-weighted motor efficiency within a building, building-"
                 "count weighted across buildings. A hot-water loop with no real "
                 "pump carries a zero-head placeholder pump whose motor efficiency is "
                 "reported as a perfect 1.0; buildings where that placeholder would "
                 "be blended into this figure are excluded, as is any exact 1.0.")
    a(Metric("pump_eff_swh", "SWH circulation pump motor efficiency", "Fans & pumps", "%",
             f"({ec} * 100)", W,
             f"{sc} > 0 AND {hc} = 0 AND {ec} > 0 AND {ec} < 1",
             needs=("out.params.pump_flow_weighted_avg_motor_efficiency_const_spd",
                    "out.params.pump_count_swh_const_spd", "out.params.pump_count_hvac_const_spd"),
             note="Constant-speed pumps in buildings whose constant-speed pumps are "
                  "all on service-hot-water loops. " + PUMP_NOTE,
             absent_note="no model of this type has a service-hot-water circulation "
                         "pump separable from the placeholder pump"))
    a(Metric("pump_eff_hvac_c", "HVAC constant-speed pump motor efficiency", "Fans & pumps",
             "%", f"({ec} * 100)", W,
             f"{hc} > 0 AND {sc} = 0 AND {ec} > 0 AND {ec} < 1",
             needs=("out.params.pump_flow_weighted_avg_motor_efficiency_const_spd",
                    "out.params.pump_count_hvac_const_spd", "out.params.pump_count_swh_const_spd"),
             note="Constant-speed pumps in buildings whose constant-speed pumps are "
                  "all on HVAC plant loops. " + PUMP_NOTE,
             absent_note="no model of this type has an HVAC constant-speed pump "
                         "separable from service-hot-water pumps"))
    a(Metric("pump_eff_hvac_v", "HVAC variable-speed pump motor efficiency", "Fans & pumps",
             "%", f"({ev} * 100)", W,
             f"{hv} > 0 AND {sv} = 0 AND {ev} > 0 AND {ev} < 1",
             needs=("out.params.pump_flow_weighted_avg_motor_efficiency_var_spd",
                    "out.params.pump_count_hvac_var_spd", "out.params.pump_count_swh_var_spd"),
             note="Variable-speed pumps in buildings with no variable-speed pump on "
                  "a service-hot-water loop (where the placeholder lives). " + PUMP_NOTE,
             absent_note="every model of this type with an HVAC variable-speed pump "
                         "also carries the placeholder hot-water pump, so the two "
                         "cannot be separated"))
    a(Metric("pump_w_ft2", "Rated pump power density", "Fans & pumps", "W/ft²",
             f"((COALESCE({pc}, 0) + COALESCE({pv}, 0)) / NULLIF({SQFT}, 0))", area,
             f"COALESCE({hc}, 0) + COALESCE({hv}, 0) + COALESCE({sc}, 0) > 0",
             needs=("out.params.pump_total_constant_speed_pump_power_w..w",
                    "out.params.pump_total_variable_speed_pump_power_w..w"),
             note="Rated power of every real pump (constant and variable speed, HVAC "
                  "and service hot water) over floor area. Buildings whose only "
                  "pump is the zero-power placeholder are excluded; the placeholder "
                  "itself has no rated power to add.",
             absent_note="no model of this type has a real pump"))

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
    # Gross wall (opaque + window), so the stock figure is total window area
    # over total wall area. Weighting by the opaque area alone understated
    # every high-ratio building.
    a(Metric("wwr", "Window-to-wall ratio", "Envelope", "%",
             f"({wwr} * 100)",
             f"{W} * (COALESCE({wall_a}, 0) + COALESCE({win_a}, 0))", f"{wwr} > 0",
             note="Window area over gross exterior wall area (opaque wall plus "
                  "window), weighted by that gross area.",
             weight_label="gross exterior wall area"))

    # ---- Water heating -----------------------------------------------------
    a(Metric("hw_ft2", "Hot water use", "Water heating", "gal/ft²·yr",
             f"({hw} * {M3_TO_GAL} / NULLIF({SQFT}, 0))", area, f"{hw} > 0",
             note="Hot-side draw. Buildings with no service hot water are excluded.",
             absent_note="no model of this type has service hot water"))
    a(Metric("hw_person", "Hot water per person", "Water heating", "gal/person·day",
             f"({hw} * {M3_TO_GAL} / 365.0"
             f" / NULLIF({occ} * {SQFT} / {M2_TO_FT2}, 0))",
             area, f"{hw} > 0 AND {occ} > 0",
             note="Design occupant count from occupant density x floor area. "
                  "Buildings with no hot water or no occupants are excluded.",
             absent_note="no model of this type has both service hot water and occupants"))
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
        "absent_note": m.absent_note,
    } for m in mets])


def _per_model_weight(expr: str) -> str:
    """A weight basis rewritten to use the per-model total weight.

    Only the bare `weight` token is replaced. The other factors in every basis
    (floor area, lighting power density, exterior areas) are model-level and
    identical across a model's geography rows, so they are left alone.
    """
    return re.sub(r"\bweight\b", "weight_model", expr)


def _resolve(sql: str, md_table: str, base_where: str) -> str:
    """Fill the table and baseline-filter tokens a guard's subquery may carry."""
    return sql.replace(TABLE_TOKEN, md_table).replace(WHERE_TOKEN, base_where)


def build_params_sql(md_table: str, metrics: list[Metric], dim: str | None,
                     by_btype: bool = False, base_where: str | None = None) -> str:
    """Weighted mean, median, p10/p90 and coverage for each metric.

    Coverage is the point of the CASE guards: it reports how much of the
    weighted stock each parameter actually applies to, so a figure computed over
    a third of the buildings cannot be mistaken for a stock-wide one.
    """
    where = base_where or athena.baseline_where(md_table)
    sel = []
    for m in metrics:
        # weight -> weight_model: the per-model total from the window below.
        # Every basis is `weight` times model-level factors, so this is an exact
        # substitution, not an approximation. See the module note on grain.
        g = _resolve(m.guard, md_table, where)
        e = _resolve(m.expr, md_table, where)
        w = _per_model_weight(m.weight)
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
            # the big buildings are the ones with central plant.
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
    # One row per MODEL PER CATEGORY, carrying the weight the model has IN THAT
    # CATEGORY. Without the de-duplication the APPROX_PERCENTILEs below run over
    # apportionment rows, so a model spread across k geographies counts k times
    # and the "unweighted across models" percentiles are really weighted by
    # geographic spread. But de-duplicating per model alone (the previous form)
    # kept an arbitrary first row, so a model apportioned across a census-
    # division or state line put its WHOLE weight into that first geography and
    # every dimension-specific mean, percentile and coverage was misallocated.
    # Partitioning by the grouping column as well makes it exact both ways: for
    # a model-level dimension (vintage, HVAC system, as-simulated climate zone)
    # the partition is the model, for a geographic one it is the model's share
    # in that category. Building type is model-level, so by_btype needs nothing.
    #
    # SELECT * is deliberate: the metric guards and expressions are arbitrary
    # SQL over columns this function never enumerates, so they must all survive.
    part = "bldg_id" + (f", {q(dim)}" if dim else "")
    per_model = (f"(SELECT *,\n"
                 f"        SUM({W}) OVER (PARTITION BY {part}) AS weight_model,\n"
                 f"        ROW_NUMBER() OVER (PARTITION BY {part}"
                 f" ORDER BY bldg_id) AS _rn\n"
                 f" FROM {md_table}\n WHERE {where}) t")
    return (f"SELECT\n{grp}"
            f"  COUNT(*) AS n_rows,\n  SUM(weight_model) AS w_total,\n"
            + ",\n".join(sel) + f"\nFROM {per_model}\nWHERE t._rn = 1\n{tail}")


def rows_from_result(df: pd.DataFrame, mets: list[Metric], run_key: str,
                     dim_key: str, dim_col: str | None, by_bt: bool) -> list[dict]:
    """One long row per (btype, category, metric) from one query result."""
    rows = []
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
            # The p10-p90 spread is carried on the stock-wide rows and on the
            # per-type national rows (dimension "none"), which the table shows
            # when one building type is selected. Dropping it there made the
            # page say "stock-wide only" about a spread that had been computed.
            # The per-type breakdown rows (type x vintage, ...) still omit it:
            # the figure that view draws has no use for it and it would roughly
            # double the payload.
            if not by_bt or dim_key == "none":
                row["p10"] = r.get(f"{m.key}__p10")
                row["p90"] = r.get(f"{m.key}__p90")
            rows.append(row)
    return rows


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
        rows += rows_from_result(df, mets, run_key, dim_key, dim_col, by_bt)
    return pd.DataFrame(rows)
