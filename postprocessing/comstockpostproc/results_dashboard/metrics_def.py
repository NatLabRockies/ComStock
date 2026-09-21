# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""Shared metric definitions for annual CBECS comparisons.

CBECS wide.csv (produced by comstockpostproc's CBECS class) already uses
ComStock-style column names, so one column list serves both datasets. The
parquet metadata tables on Athena use the same names.

Provenance:
  measured       — CBECS surveys/bills fuel totals and floor area directly
  disaggregated  — CBECS end-use splits are EIA statistical models, not metered
"""

KWH = ".energy_consumption..kwh"

# key -> (column, provenance)
FUEL_TOTALS = {
    "electricity.total": (f"out.electricity.total{KWH}", "measured"),
    "natural_gas.total": (f"out.natural_gas.total{KWH}", "measured"),
    "fuel_oil.total": (f"out.fuel_oil.total{KWH}", "measured"),
    "propane.total": (f"out.propane.total{KWH}", "measured"),
    "district_heating.total": (f"out.district_heating.total{KWH}", "measured"),
    "district_cooling.total": (f"out.district_cooling.total{KWH}", "measured"),
    "site_energy.total": (f"out.site_energy.total{KWH}", "measured (sum of fuels)"),
}

END_USES = {
    "electricity.heating": (f"out.electricity.heating{KWH}", "disaggregated"),
    "electricity.cooling": (f"out.electricity.cooling{KWH}", "disaggregated"),
    "electricity.fans": (f"out.electricity.fans{KWH}", "disaggregated"),
    "electricity.water_systems": (f"out.electricity.water_systems{KWH}", "disaggregated"),
    "electricity.interior_lighting": (f"out.electricity.interior_lighting{KWH}", "disaggregated"),
    "electricity.exterior_lighting": (f"out.electricity.exterior_lighting{KWH}", "disaggregated"),
    "electricity.refrigeration": (f"out.electricity.refrigeration{KWH}", "disaggregated"),
    "electricity.interior_equipment": (f"out.electricity.interior_equipment{KWH}", "disaggregated"),
    "natural_gas.heating": (f"out.natural_gas.heating{KWH}", "disaggregated"),
    "natural_gas.water_systems": (f"out.natural_gas.water_systems{KWH}", "disaggregated"),
    "natural_gas.interior_equipment": (f"out.natural_gas.interior_equipment{KWH}", "disaggregated"),
    "fuel_oil.heating": (f"out.fuel_oil.heating{KWH}", "disaggregated"),
    "propane.heating": (f"out.propane.heating{KWH}", "disaggregated"),
    "district_heating.heating": (f"out.district_heating.heating{KWH}", "disaggregated"),
    "fuel_oil.water_systems": (f"out.fuel_oil.water_systems{KWH}", "disaggregated"),
    "propane.water_systems": (f"out.propane.water_systems{KWH}", "disaggregated"),
    "district_heating.water_systems": (f"out.district_heating.water_systems{KWH}", "disaggregated"),
}

ALL_KWH_METRICS = {**FUEL_TOTALS, **END_USES}

# Derived cross-fuel diagnostics (computed from the rows above after aggregation).
DERIVED = {
    "all_fuel.heating": (
        ["electricity.heating", "natural_gas.heating", "fuel_oil.heating",
         "propane.heating", "district_heating.heating"],
        "disaggregated",
    ),
    "all_fuel.water_systems": (
        ["electricity.water_systems", "natural_gas.water_systems", "fuel_oil.water_systems",
         "propane.water_systems", "district_heating.water_systems"],
        "disaggregated",
    ),
    # CBECS "lighting" is all lighting and lands under interior_lighting;
    # ComStock splits interior/exterior. Combined is the fair comparison.
    "electricity.lighting_combined": (
        ["electricity.interior_lighting", "electricity.exterior_lighting"],
        "disaggregated",
    ),
}

SQFT_COL = "in.sqft..ft2"
BLDG_TYPE_COL = "in.comstock_building_type"
CEN_DIV_COL = "in.census_division_name"
VINTAGE_COL = "in.vintage"
# The national aggregate table carries only the as-simulated climate zone
# (verified via information_schema; the plain in.ashrae_iecc_climate_zone_2006
# does not resolve there). As-simulated is the zone of the weather location the
# model actually ran against.
CZ_COL = "in.as_simulated_ashrae_iecc_climate_zone_2006"
GAS_TOTAL_COL = f"out.natural_gas.total{KWH}"

# Cross-cutting dimensions. `cbecs` marks whether CBECS can serve as a reference:
# CBECS public-use microdata suppresses sub-regional geography, so it carries no
# ASHRAE/IECC climate zone at all — census division is its finest geography. A
# climate-zone view is therefore ComStock-only and must be labeled as such.
DIMENSIONS = {
    "building_type": {"col": BLDG_TYPE_COL, "label": "Building type", "cbecs": True},
    "census_division": {"col": CEN_DIV_COL, "label": "Census division", "cbecs": True},
    "vintage": {"col": VINTAGE_COL, "label": "Vintage", "cbecs": True},
    "size_bin": {"col": "size_bin", "label": "Floor area bin", "cbecs": True},
    "climate_zone": {"col": CZ_COL, "label": "Climate zone, as simulated (ComStock only)",
                     "cbecs": False},
}

# Floor-area bins derived from continuous floor area on BOTH sides with identical
# edges. 2025 R3 does not publish in.floor_area_category (2024 R2 and CBECS do),
# which is why the upstream floor-area groupby is still commented out; deriving
# the bins makes the dimension work on any release. Edges follow the CBECS bins.
# Labels stay ASCII so they survive SQL literals unchanged.
SIZE_BIN_EDGES = [0, 1_000, 5_000, 10_000, 25_000, 50_000,
                  100_000, 200_000, 500_000, 1_000_000, float("inf")]
SIZE_BIN_LABELS = ["<=1k", "1k-5k", "5k-10k", "10k-25k", "25k-50k",
                   "50k-100k", "100k-200k", "200k-500k", "500k-1M", ">1M"]


def size_bin_sql(sqft_col: str = SQFT_COL) -> str:
    """CASE expression binning continuous floor area, matching SIZE_BIN_EDGES."""
    parts = [
        f"WHEN \"{sqft_col}\" <= {int(hi)} THEN '{lab}'"
        for hi, lab in zip(SIZE_BIN_EDGES[1:-1], SIZE_BIN_LABELS[:-1])
    ]
    return "CASE " + " ".join(parts) + f" ELSE '{SIZE_BIN_LABELS[-1]}' END"

# Canonical orderings, mirroring naming_mixin.ORDERED_CATEGORIES. "2019 or newer"
# is deliberately included: both datasets emit it, but the package's ordering lists
# only 8 vintage bins, so seaborn silently drops post-2018 stock from every vintage
# figure. Values outside these lists are reported in coverage.json, never dropped
# silently.
ORDERED_CATEGORIES = {
    "census_division": [
        "New England", "Middle Atlantic", "East North Central", "West North Central",
        "South Atlantic", "East South Central", "West South Central", "Mountain", "Pacific",
    ],
    "vintage": [
        "Before 1946", "1946 to 1959", "1960 to 1969", "1970 to 1979", "1980 to 1989",
        "1990 to 1999", "2000 to 2012", "2013 to 2018", "2019 or newer",
    ],
    "building_type": [
        "FullServiceRestaurant", "Grocery", "Hospital", "LargeHotel", "LargeOffice",
        "MediumOffice", "Outpatient", "PrimarySchool", "QuickServiceRestaurant",
        "RetailStandalone", "RetailStripmall", "SecondarySchool", "SmallHotel",
        "SmallOffice", "Warehouse",
    ],
    "size_bin": SIZE_BIN_LABELS,
}

COMSTOCK_BLDG_TYPES = [
    "FullServiceRestaurant", "Grocery", "Hospital", "LargeHotel", "LargeOffice",
    "MediumOffice", "Outpatient", "PrimarySchool", "QuickServiceRestaurant",
    "RetailStandalone", "RetailStripmall", "SecondarySchool", "SmallHotel",
    "SmallOffice", "Warehouse",
]

BLDG_TYPE_TO_SNAKE = {
    "FullServiceRestaurant": "full_service_restaurant",
    "QuickServiceRestaurant": "quick_service_restaurant",
    "RetailStripmall": "strip_mall",
    "RetailStandalone": "retail",
    "SmallOffice": "small_office",
    "MediumOffice": "medium_office",
    "LargeOffice": "large_office",
    "PrimarySchool": "primary_school",
    "SecondarySchool": "secondary_school",
    "SmallHotel": "small_hotel",
    "LargeHotel": "large_hotel",
    "Hospital": "hospital",
    "Outpatient": "outpatient",
    "Warehouse": "warehouse",
}

KWH_TO_TBTU = 3412.141633 / 1e12

# OpenStudio / ComStock end-use palette, matching ENDUSE_COLOR_DICT in
# comstockpostproc/naming_mixin.py so these charts read the same as the ones in
# the ComStock repo.
ENDUSE_COLORS = {
    "exterior_lighting": "#DEC310",
    "interior_lighting": "#F7DF10",
    "interior_equipment": "#4A4D4A",
    "exterior_equipment": "#B5B2B5",
    "water_systems": "#FFB239",
    "heat_recovery": "#CE5921",
    "fans": "#FF79AD",
    "pumps": "#632C94",
    "heat_rejection": "#F75921",
    "humidification": "#293094",
    "cooling": "#0071BD",
    "heating": "#EF1C21",
    "refrigeration": "#29AAE7",
}

# Stacking order, bottom to top, following the declared order in
# plot_day_type_comparison_stacked_by_enduse. heat_rejection is included here:
# upstream it is queried from Athena but dropped before plotting (its rename map
# omits it), so it silently never reaches the chart. Since we query it, we stack
# it in its declared position rather than losing it.
ENDUSE_STACK_ORDER = [
    "exterior_lighting", "interior_lighting", "interior_equipment", "water_systems",
    "heat_recovery", "fans", "pumps", "heat_rejection", "cooling", "heating", "refrigeration",
]

# pv is deliberately excluded (generation, not an end use); total is the
# reference line, never a stack layer.
TS_ENDUSE_COL = "out.electricity.{}.energy_consumption"
