# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
from __future__ import annotations
import re
import matplotlib.colors as mcolors
import polars as pl
import pandas as pd
from typing import Iterable, Dict, List, Union

class NamingMixin():
    # Column aliases for code readability
    # Add to this list for commonly-used columns
    DATASET = 'dataset'
    BLDG_ID = 'bldg_id'
    CEN_REG = 'in.census_region_name'
    CEN_DIV = 'in.census_division_name'
    STATE_NAME = 'in.state_name'
    STATE_ABBRV = 'in.state'
    FLR_AREA = 'in.sqft..ft2'
    FLR_AREA_CAT = 'in.floor_area_category'
    CBECS_BLDG_TYPE = 'in.cbecs_building_type'
    YEAR_BUILT = 'in.year_built'
    BLDG_WEIGHT = 'weight'
    BLDG_TYPE = 'in.comstock_building_type'
    BLDG_TYPE_GROUP = 'in.comstock_building_type_group'
    AEO_BLDG_TYPE = 'in.aeo_and_nems_building_type'
    VINTAGE = 'in.vintage'
    CZ_ASHRAE = 'in.ashrae_iecc_climate_zone_2006'
    CZ_ASHRAE_CEC_MIXED = 'in.ashrae_or_cec_climate_zone'
    CZ_CEC = 'in.cec_climate_zone'
    UPGRADE_NAME = 'in.upgrade_name'
    UPGRADE_ID = 'upgrade'
    UPGRADE_APPL = 'applicability'
    BASE_NAME = 'Baseline'
    BLDG_UP_ID = 'in.building_upgrade_id'
    HVAC_SYS = 'in.hvac_system_type'
    SEG_NAME = 'calc.segment'
    COMP_STATUS = 'completed_status'
    DIVISION = 'Division'
    MONTH = 'Month'
    UTIL_ID = 'in.electric_utility_eia_code'

    # As-simulated geography variables
    TRACT_ID_AS_SIM = 'in.as_simulated_nhgis_tract_gisjoin'
    COUNTY_ID_AS_SIM = 'in.as_simulated_nhgis_county_gisjoin'
    STATE_ID_AS_SIM = 'in.as_simulated_nhgis_state_gisjoin'
    CEN_DIV_AS_SIM = 'in.as_simulated_census_division_name'
    CZ_ASHRAE_AS_SIM = 'in.as_simulated_ashrae_iecc_climate_zone_2006'
    WF_2018_AS_SIM = 'in.as_simulated_weather_file_2018'
    WF_TMY3_AS_SIM = 'in.as_simulated_weather_file_tmy3'

    # Variables needed by the apportionment sampling regime
    SAMPLING_REGION = 'in.sampling_region_id'
    COUNTY_ID = 'in.nhgis_county_gisjoin'
    TRACT_ID = 'in.nhgis_tract_gisjoin'
    PUMA_ID = 'in.nhgis_puma_gisjoin'
    SH_FUEL = 'in.heating_fuel'
    SIZE_BIN = 'in.size_bin_id'
    STATE_ID = 'in.nhgis_state_gisjoin'
    TOT_EUI = 'out.site_energy.total.energy_consumption_intensity..kwh_per_ft2'
    SAMPLED_COLUMN_PREFIX = 'sampled.'
    POST_APPO_SIM_COL_PREFIX = 'in.as_simulated_'

    # Column Name type mapping for pandas DataFrame:
    COL_TYPE_SCHEMA = {
        CEN_DIV: "string",
        STATE_NAME: "string",
        CEN_REG: "string",
        STATE_ABBRV: "category",
        BLDG_TYPE: "category",
        BLDG_TYPE_GROUP: "category",
        VINTAGE: "category",
        DATASET: "category",
        UPGRADE_NAME: "string",
        CZ_ASHRAE: "category",
        HVAC_SYS: "category",
        DIVISION: "category",
        MONTH: "Int8"
    }

    # Geography-defining columns
    COLS_GEOG = [
        TRACT_ID_AS_SIM,
        COUNTY_ID_AS_SIM,
        STATE_ID_AS_SIM,
        CEN_DIV_AS_SIM,
        CZ_ASHRAE_AS_SIM,
        WF_2018_AS_SIM,
        WF_TMY3_AS_SIM,
        CZ_ASHRAE,
        CZ_ASHRAE_CEC_MIXED,
        CZ_CEC,
        'in.building_america_climate_zone',
        'in.cambium_grid_region',
        CEN_DIV,
        CEN_REG,
        'in.iso_rto_region',
        COUNTY_ID,
        PUMA_ID,
        TRACT_ID,
        'in.reeds_balancing_area',
        'in.county_name',
        STATE_ID,
        'in.state',
        'in.state_name',
        'in.cluster_id',
        'in.cluster_name',
        'in.weather_file_2018',
        'in.weather_file_tmy3',
        'in.ejscreen_census_tract_percentile_for_demographic_index',
        'in.ejscreen_census_tract_percentile_for_people_of_color',
        'in.cejst_is_disadvantaged',
        'in.ejscreen_census_tract_percentile_percent_people_under_5',
        'in.ejscreen_census_tract_percentile_for_less_than_hs_educ',
        'in.ejscreen_census_tract_percentile_for_low_income',
        'in.ejscreen_census_tract_percentile_for_people_over_64',
        'in.ejscreen_census_tract_percentile_for_people_in_ling_isol',
    ]

    # Total net energy
    ANN_TOT_NET_ENGY_KBTU = 'out.site_energy.net.energy_consumption..kwh' #new?
    ANN_TOT_NET_ELEC_KBTU = 'out.electricity.net.energy_consumption..kwh' #new?
    ANN_PURCHASED_ELEC_KBTU = 'out.electricity.purchased.energy_consumption..kwh' #new?

    # Total annual energy
    ANN_TOT_ENGY_KBTU = 'out.site_energy.total.energy_consumption..kwh'
    ANN_TOT_ELEC_KBTU = 'out.electricity.total.energy_consumption..kwh'
    ANN_TOT_GAS_KBTU = 'out.natural_gas.total.energy_consumption..kwh'
    ANN_TOT_PROPANE_KBTU = 'out.propane.total.energy_consumption..kwh'
    ANN_TOT_FUELOIL_KBTU = 'out.fuel_oil.total.energy_consumption..kwh'
    ANN_TOT_DISTHTG_KBTU = 'out.district_heating.total.energy_consumption..kwh'
    ANN_TOT_DISTCLG_KBTU = 'out.district_cooling.total.energy_consumption..kwh'

    # End use energy - electricity
    ANN_ELEC_COOL_KBTU = 'out.electricity.cooling.energy_consumption..kwh'
    ANN_ELEC_EXTLTG_KBTU = 'out.electricity.exterior_lighting.energy_consumption..kwh'
    ANN_ELEC_FANS_KBTU = 'out.electricity.fans.energy_consumption..kwh'
    ANN_ELEC_HEATREJECT_KBTU = 'out.electricity.heat_recovery.energy_consumption..kwh'
    ANN_ELEC_HEATRECOV_KBTU = 'out.electricity.heat_rejection.energy_consumption..kwh'
    ANN_ELEC_HEAT_KBTU = 'out.electricity.heating.energy_consumption..kwh'
    ANN_ELEC_INTEQUIP_KBTU = 'out.electricity.interior_equipment.energy_consumption..kwh'
    ANN_ELEC_INTLTG_KBTU = 'out.electricity.interior_lighting.energy_consumption..kwh'
    ANN_ELEC_PUMPS_KBTU = 'out.electricity.pumps.energy_consumption..kwh'
    ANN_ELEC_REFRIG_KBTU = 'out.electricity.refrigeration.energy_consumption..kwh'
    ANN_ELEC_REFRIG_MED_TEMP_CASE_DEFROST_KWH = 'out.params.refrigeration_med_temp_case_defrost_energy..kwh'
    ANN_ELEC_REFRIG_LOW_TEMP_CASE_DEFROST_KWH = 'out.params.refrigeration_low_temp_case_defrost_energy..kwh'
    ANN_ELEC_REFRIG_MED_TEMP_WALKIN_DEFROST_KWH = 'out.params.refrigeration_med_temp_walkin_defrost_energy..kwh'
    ANN_ELEC_REFRIG_LOW_TEMP_WALKIN_DEFROST_KWH = 'out.params.refrigeration_low_temp_walkin_defrost_energy..kwh'
    ANN_ELEC_SWH_KBTU = 'out.electricity.water_systems.energy_consumption..kwh'
    ANN_ELEC_PV_KBTU = 'out.electricity.pv.energy_consumption..kwh' #new?

    # End use energy - natural gas
    ANN_GAS_HEAT_KBTU = 'out.natural_gas.heating.energy_consumption..kwh'
    ANN_GAS_INTEQUIP_KBTU = 'out.natural_gas.interior_equipment.energy_consumption..kwh'
    ANN_GAS_SWH_KBTU = 'out.natural_gas.water_systems.energy_consumption..kwh'
    ANN_GAS_COOL_KBTU = 'out.natural_gas.cooling.energy_consumption..kwh'
    ANN_PEAK_ELEC_DEMAND_KW = 'out.electricity.total.peak_demand..kw'

    # End use energy - propane
    ANN_PROPANE_HEAT_KBTU = 'out.propane.heating.energy_consumption..kwh'
    ANN_PROPANE_INTEQUIP_KBTU = 'out.propane.interior_equipment.energy_consumption..kwh'
    ANN_PROPANE_SWH_KBTU = 'out.propane.water_systems.energy_consumption..kwh'

    # End use energy - fuel oil no 2
    ANN_FUELOIL_HEAT_KBTU = 'out.fuel_oil.heating.energy_consumption..kwh'
    ANN_FUELOIL_INTEQUIP_KBTU = 'out.fuel_oil.interior_equipment.energy_consumption..kwh'
    ANN_FUELOIL_SWH_KBTU = 'out.fuel_oil.water_systems.energy_consumption..kwh'

    # End use energy - district cooling
    ANN_DISTCLG_COOL_KBTU = 'out.district_cooling.cooling.energy_consumption..kwh'

    # End use energy - district heating
    ANN_DISTHTG_HEAT_KBTU = 'out.district_heating.heating.energy_consumption..kwh'
    ANN_DISTHTG_SWH_KBTU = 'out.district_heating.water_systems.energy_consumption..kwh'
    ANN_DISTHTG_INTEQUIP_KBTU = 'out.district_heating.interior_equipment.energy_consumption..kwh'
    ANN_DISTHTG_COOL_KBTU = 'out.district_heating.cooling.energy_consumption..kwh'

    # End use group energy - all fuels
    ANN_HEAT_GROUP_KBTU = 'calc.enduse_group.site_energy.heating.energy_consumption..kwh'
    ANN_COOL_GROUP_KBTU = 'calc.enduse_group.site_energy.cooling.energy_consumption..kwh'
    ANN_HVAC_GROUP_KBTU = 'calc.enduse_group.site_energy.hvac.energy_consumption..kwh'
    ANN_LTG_GROUP_KBTU = 'calc.enduse_group.site_energy.lighting.energy_consumption..kwh'
    ANN_INTEQUIP_GROUP_KBTU = 'calc.enduse_group.site_energy.interior_equipment.energy_consumption..kwh'
    ANN_REFRIG_GROUP_KBTU = 'calc.enduse_group.site_energy.refrigeration.energy_consumption..kwh'
    ANN_SWH_GROUP_KBTU = 'calc.enduse_group.site_energy.water_systems.energy_consumption..kwh'

    # End use group energy - electricity
    ANN_ELEC_HVAC_GROUP_KBTU = 'calc.enduse_group.electricity.hvac.energy_consumption..kwh'
    ANN_ELEC_LTG_GROUP_KBTU = 'calc.enduse_group.electricity.lighting.energy_consumption..kwh'
    ANN_ELEC_INTEQUIP_GROUP_KBTU = 'calc.enduse_group.electricity.interior_equipment.energy_consumption..kwh'
    ANN_ELEC_REFRIG_GROUP_KBTU = 'calc.enduse_group.electricity.refrigeration.energy_consumption..kwh'
    ANN_ELEC_SWH_GROUP_KBTU = 'calc.enduse_group.electricity.water_systems.energy_consumption..kwh'

    # End use group energy - natural gas
    ANN_GAS_HVAC_GROUP_KBTU = 'calc.enduse_group.natural_gas.hvac.energy_consumption..kwh'
    ANN_GAS_INTEQUIP_GROUP_KBTU = 'calc.enduse_group.natural_gas.interior_equipment.energy_consumption..kwh'
    ANN_GAS_SWH_GROUP_KBTU = 'calc.enduse_group.natural_gas.water_systems.energy_consumption..kwh'

    # End use group energy - propane
    ANN_PROPANE_HVAC_GROUP_KBTU = 'calc.enduse_group.propane.hvac.energy_consumption..kwh'
    ANN_PROPANE_SWH_GROUP_KBTU = 'calc.enduse_group.propane.water_systems.energy_consumption..kwh'
    ANN_PROPANE_INTEQUIP_GROUP_KBTU = 'calc.enduse_group.propane.interior_equipment.energy_consumption..kwh'

    # End use group energy - fuel oil
    ANN_FUELOIL_HVAC_GROUP_KBTU = 'calc.enduse_group.fuel_oil.hvac.energy_consumption..kwh'
    ANN_FUELOIL_SWH_GROUP_KBTU = 'calc.enduse_group.fuel_oil.water_systems.energy_consumption..kwh'
    ANN_FUELOIL_INTEQUIP_GROUP_KBTU = 'calc.enduse_group.fuel_oil.interior_equipment.energy_consumption..kwh'

    # End use group energy - district heating
    ANN_DISTHTG_HVAC_GROUP_KBTU = 'calc.enduse_group.district_heating.hvac.energy_consumption..kwh'
    ANN_DISTHTG_INTEQUIP_GROUP_KBTU = 'calc.enduse_group.district_heating.interior_equipment.energy_consumption..kwh'
    ANN_DISTHTG_SWH_GROUP_KBTU = 'calc.enduse_group.district_heating.water_systems.energy_consumption..kwh'

    # End use group energy - district cooling
    ANN_DISTCLG_HVAC_GROUP_KBTU = 'calc.enduse_group.district_cooling.hvac.energy_consumption..kwh'

    # Unmet hours columns
    COOLING_HOURS_UNMET = 'out.params.hours_cooling_setpoint_not_met..hr'
    HEATING_HOURS_UNMET = 'out.params.hours_heating_setpoint_not_met..hr'

    # List of total annual energy end use group columns
    COLS_ENDUSE_GROUP_TOT_ANN_ENGY = [
        ANN_HVAC_GROUP_KBTU,
        ANN_LTG_GROUP_KBTU,
        ANN_INTEQUIP_GROUP_KBTU,
        ANN_REFRIG_GROUP_KBTU,
        ANN_SWH_GROUP_KBTU
    ]

    # List of end use group columns
    COLS_ENDUSE_GROUP_ANN_ENGY = [
        ANN_ELEC_HVAC_GROUP_KBTU,
        ANN_ELEC_LTG_GROUP_KBTU,
        ANN_ELEC_INTEQUIP_GROUP_KBTU,
        ANN_ELEC_REFRIG_GROUP_KBTU,
        ANN_ELEC_SWH_GROUP_KBTU,
        ANN_GAS_HVAC_GROUP_KBTU,
        ANN_GAS_INTEQUIP_GROUP_KBTU,
        ANN_GAS_SWH_GROUP_KBTU,
        ANN_PROPANE_HVAC_GROUP_KBTU,
        ANN_PROPANE_SWH_GROUP_KBTU,
        ANN_PROPANE_INTEQUIP_GROUP_KBTU,
        ANN_FUELOIL_HVAC_GROUP_KBTU,
        ANN_FUELOIL_SWH_GROUP_KBTU,
        ANN_FUELOIL_INTEQUIP_GROUP_KBTU,
        ANN_DISTHTG_HVAC_GROUP_KBTU,
        ANN_DISTHTG_INTEQUIP_GROUP_KBTU,
        ANN_DISTHTG_SWH_GROUP_KBTU,
        ANN_DISTCLG_HVAC_GROUP_KBTU
    ]

    # Utility bills
    UTIL_BILL_ELEC = 'out.utility_bills.electricity_bill_mean..usd'
    UTIL_BILL_ELEC_MAX = 'out.utility_bills.electricity_bill_max..usd'
    UTIL_BILL_ELEC_MED = 'out.utility_bills.electricity_bill_median..usd'
    UTIL_BILL_ELEC_MIN = 'out.utility_bills.electricity_bill_min..usd'
    UTIL_BILL_GAS = 'out.utility_bills.natural_gas_bill_state_average..usd'
    UTIL_BILL_FUEL_OIL = 'out.utility_bills.fuel_oil_bill_state_average..usd'
    UTIL_BILL_PROPANE = 'out.utility_bills.propane_bill_state_average..usd'

    # Utility bill columns
    COLS_UTIL_BILLS = [
        UTIL_BILL_ELEC,
        UTIL_BILL_GAS,
        UTIL_BILL_FUEL_OIL,
        UTIL_BILL_PROPANE
    ]

    UTIL_BILL_EIA_ID = 'in.electric_utility_eia_code'
    UTIL_BILL_ELEC_RESULTS = 'out.utility_bills.electricity_utility_bill_results'
    UTIL_BILL_STATE_ELEC_RESULTS = 'out.utility_bills.state_average_electricity_cost_results'
    UTIL_BILL_STATE_GAS_RESULTS = 'out.utility_bills.state_average_natural_gas_cost_results'
    UTIL_BILL_STATE_PROPANE_RESULTS = 'out.utility_bills.state_average_propane_cost_results'
    UTIL_BILL_STATE_FUEL_OIL_RESULTS = 'out.utility_bills.state_average_fueloil_cost_results'

    COLS_STATE_UTIL_RESULTS = [
        UTIL_BILL_STATE_ELEC_RESULTS,
        UTIL_BILL_STATE_GAS_RESULTS,
        UTIL_BILL_STATE_PROPANE_RESULTS,
        UTIL_BILL_STATE_FUEL_OIL_RESULTS
    ]

    # Utility bills full results columms
    COLS_UTIL_BILL_RESULTS = [
        UTIL_BILL_ELEC_RESULTS
    ] + COLS_STATE_UTIL_RESULTS

    # utility bills extracted columns
    UTIL_ELEC_BILL_VALS = [
        'out.utility_bills.electricity_bill_min..usd',
        'out.utility_bills.electricity_bill_min_label',
        'out.utility_bills.electricity_bill_max..usd',
        'out.utility_bills.electricity_bill_max_label',
        'out.utility_bills.electricity_bill_median_low..usd',
        'out.utility_bills.electricity_bill_median_low_label',
        'out.utility_bills.electricity_bill_median_high..usd',
        'out.utility_bills.electricity_bill_median_high_label',
        # 'out.utility_bills.electricity_bill_median_dollars..usd',
        'out.utility_bills.electricity_bill_mean..usd',
        'out.utility_bills.electricity_demandcharge_flat_bill_min..usd',
        'out.utility_bills.electricity_demandcharge_flat_bill_min_label',
        'out.utility_bills.electricity_demandcharge_flat_bill_max..usd',
        'out.utility_bills.electricity_demandcharge_flat_bill_max_label',
        'out.utility_bills.electricity_demandcharge_flat_bill_median_low..usd',
        'out.utility_bills.electricity_demandcharge_flat_bill_median_low_label',
        'out.utility_bills.electricity_demandcharge_flat_bill_median_high..usd',
        'out.utility_bills.electricity_demandcharge_flat_bill_median_high_label',
        'out.utility_bills.electricity_demandcharge_flat_bill_mean..usd',
        'out.utility_bills.electricity_demandcharge_tou_bill_min..usd',
        'out.utility_bills.electricity_demandcharge_tou_bill_min_label',
        'out.utility_bills.electricity_demandcharge_tou_bill_max..usd',
        'out.utility_bills.electricity_demandcharge_tou_bill_max_label',
        'out.utility_bills.electricity_demandcharge_tou_bill_median_low..usd',
        'out.utility_bills.electricity_demandcharge_tou_bill_median_low_label',
        'out.utility_bills.electricity_demandcharge_tou_bill_median_high..usd',
        'out.utility_bills.electricity_demandcharge_tou_bill_median_high_label',
        'out.utility_bills.electricity_demandcharge_tou_bill_mean..usd',
        'out.utility_bills.electricity_energycharge_bill_min..usd',
        'out.utility_bills.electricity_energycharge_bill_min_label',
        'out.utility_bills.electricity_energycharge_bill_max..usd',
        'out.utility_bills.electricity_energycharge_bill_max_label',
        'out.utility_bills.electricity_energycharge_bill_median_low..usd',
        'out.utility_bills.electricity_energycharge_bill_median_low_label',
        'out.utility_bills.electricity_energycharge_bill_median_high..usd',
        'out.utility_bills.electricity_energycharge_bill_median_high_label',
        'out.utility_bills.electricity_energycharge_bill_mean..usd',
        'out.utility_bills.electricity_fixedcharge_bill_min..usd',
        'out.utility_bills.electricity_fixedcharge_bill_min_label',
        'out.utility_bills.electricity_fixedcharge_bill_max..usd',
        'out.utility_bills.electricity_fixedcharge_bill_max_label',
        'out.utility_bills.electricity_fixedcharge_bill_median_low..usd',
        'out.utility_bills.electricity_fixedcharge_bill_median_low_label',
        'out.utility_bills.electricity_fixedcharge_bill_median_high..usd',
        'out.utility_bills.electricity_fixedcharge_bill_median_high_label',
        'out.utility_bills.electricity_fixedcharge_bill_mean..usd',
        'out.utility_bills.electricity_bill_num_bills'
    ]

    UTIL_ELEC_BILL_COSTS = [col for col in UTIL_ELEC_BILL_VALS if 'usd' in col]
    UTIL_ELEC_BILL_LABEL = [col for col in UTIL_ELEC_BILL_VALS if 'label' in col]
    UTIL_ELEC_BILL_NUM_BILLS = UTIL_ELEC_BILL_VALS[-1]

    UTIL_STATE_AVG_ELEC_COST = 'out.utility_bills.electricity_bill_state_average..usd'
    UTIL_STATE_AVG_GAS_COST = 'out.utility_bills.natural_gas_bill_state_average..usd'
    UTIL_STATE_AVG_PROP_COST = 'out.utility_bills.propane_bill_state_average..usd'
    UTIL_STATE_AVG_FUEL_COST = 'out.utility_bills.fuel_oil_bill_state_average..usd'

    COST_STATE_UTIL_COSTS = [
        UTIL_STATE_AVG_ELEC_COST,
        UTIL_STATE_AVG_GAS_COST,
        UTIL_STATE_AVG_PROP_COST,
        UTIL_STATE_AVG_FUEL_COST
    ]

    # Combined utility bills
    UTIL_BILL_TOTAL_MEAN = 'out.utility_bills.total_bill_mean..usd'

    # GHG emissions columns
    ANN_GHG_EGRID = 'calc.emissions.total_with_egrid..co2e_kg'
    ANN_GHG_CAMBIUM = 'calc.emissions.total_with_cambium_mid_case_15y..co2e_kg'

    # GHG emissions columns to sum for eGrid total
    COLS_GHG_EGRID = [
        'out.emissions.natural_gas..co2e_kg',
        'out.emissions.fuel_oil..co2e_kg',
        'out.emissions.propane..co2e_kg',
        'out.emissions.district_cooling..co2e_kg',
        'out.emissions.district_heating..co2e_kg',
        'out.emissions.electricity.egrid_2021_subregion..co2e_kg'
    ]

    # GHG emissions columns to sum for Cambium total
    COLS_GHG_CAMBIUM = [
        'out.emissions.natural_gas..co2e_kg',
        'out.emissions.fuel_oil..co2e_kg',
        'out.emissions.propane..co2e_kg',
        'out.emissions.district_cooling..co2e_kg',
        'out.emissions.district_heating..co2e_kg',
        'out.emissions.electricity.lrmer_mid_case_15_2023_start..co2e_kg'
    ]

    # GHG emissions seasonal daily average from electricity consumption columns for eGrid
    COLS_GHG_ELEC_SEASONAL_DAILY_EGRID = [
        'out.emissions.electricity.winter_daily_average.egrid_2021_subregion..co2e_kg',
        'out.emissions.electricity.summer_daily_average.egrid_2021_subregion..co2e_kg',
        'out.emissions.electricity.shoulder_daily_average.egrid_2021_subregion..co2e_kg'
    ]

    # GHG emissions seasonal daily average from electricity consumption columns for Cambium
    COLS_GHG_ELEC_SEASONAL_DAILY_CAMBIUM = [
        'out.emissions.electricity.winter_daily_average.lrmer_high_re_cost_15_2023_start..co2e_kg',
        'out.emissions.electricity.summer_daily_average.lrmer_high_re_cost_15_2023_start..co2e_kg',
        'out.emissions.electricity.shoulder_daily_average.lrmer_high_re_cost_15_2023_start..co2e_kg',
        'out.emissions.electricity.winter_daily_average.lrmer_low_re_cost_15_2023_start..co2e_kg',
        'out.emissions.electricity.summer_daily_average.lrmer_low_re_cost_15_2023_start..co2e_kg',
        'out.emissions.electricity.shoulder_daily_average.lrmer_low_re_cost_15_2023_start..co2e_kg',
        'out.emissions.electricity.winter_daily_average.lrmer_mid_case_15_2023_start..co2e_kg',
        'out.emissions.electricity.summer_daily_average.lrmer_mid_case_15_2023_start..co2e_kg',
        'out.emissions.electricity.shoulder_daily_average.lrmer_mid_case_15_2023_start..co2e_kg'
    ]

    # QOI COLS
    QOI_MAX_SHOULDER_HR = 'out.qoi.maximum_daily_timing_shoulder_hour..hr'
    QOI_MAX_SUMMER_HR = 'out.qoi.maximum_daily_timing_summer_hour..hr'
    QOI_MAX_WINTER_HR = 'out.qoi.maximum_daily_timing_winter_hour..hr'

    QOI_MAX_SHOULDER_USE = 'out.qoi.maximum_daily_use_shoulder..kw'
    QOI_MAX_SUMMER_USE = 'out.qoi.maximum_daily_use_summer..kw'
    QOI_MAX_WINTER_USE = 'out.qoi.maximum_daily_use_winter..kw'

    QOI_MIN_SHOULDER_USE = 'out.qoi.minimum_daily_use_shoulder..kw'
    QOI_MIN_SUMMER_USE = 'out.qoi.minimum_daily_use_summer..kw'
    QOI_MIN_WINTER_USE = 'out.qoi.minimum_daily_use_winter..kw'

    QOI_MAX_SHOULDER_USE_NORMALIZED = 'out.qoi.maximum_daily_use_shoulder_intensity..w_per_ft2'
    QOI_MAX_SUMMER_USE_NORMALIZED = 'out.qoi.maximum_daily_use_summer_intensity..w_per_ft2'
    QOI_MAX_WINTER_USE_NORMALIZED = 'out.qoi.maximum_daily_use_winter_intensity..w_per_ft2'

    QOI_MIN_SHOULDER_USE_NORMALIZED = 'out.qoi.minimum_daily_use_shoulder_intensity..w_per_ft2'
    QOI_MIN_SUMMER_USE_NORMALIZED = 'out.qoi.minimum_daily_use_summer_intensity..w_per_ft2'
    QOI_MIN_WINTER_USE_NORMALIZED = 'out.qoi.minimum_daily_use_winter_intensity..w_per_ft2'

    COLS_QOI_MONTHLY_MAX_DAILY_PEAK = [
        'out.qoi.maximum_daily_peak_jan..kw',
        'out.qoi.maximum_daily_peak_feb..kw',
        'out.qoi.maximum_daily_peak_mar..kw',
        'out.qoi.maximum_daily_peak_apr..kw',
        'out.qoi.maximum_daily_peak_may..kw',
        'out.qoi.maximum_daily_peak_jun..kw',
        'out.qoi.maximum_daily_peak_jul..kw',
        'out.qoi.maximum_daily_peak_aug..kw',
        'out.qoi.maximum_daily_peak_sep..kw',
        'out.qoi.maximum_daily_peak_oct..kw',
        'out.qoi.maximum_daily_peak_nov..kw',
        'out.qoi.maximum_daily_peak_dec..kw'
    ]

    COLS_QOI_MONTHLY_MED_DAILY_PEAK = [
        'out.qoi.median_daily_peak_jan..kw',
        'out.qoi.median_daily_peak_feb..kw',
        'out.qoi.median_daily_peak_mar..kw',
        'out.qoi.median_daily_peak_apr..kw',
        'out.qoi.median_daily_peak_may..kw',
        'out.qoi.median_daily_peak_jun..kw',
        'out.qoi.median_daily_peak_jul..kw',
        'out.qoi.median_daily_peak_aug..kw',
        'out.qoi.median_daily_peak_sep..kw',
        'out.qoi.median_daily_peak_oct..kw',
        'out.qoi.median_daily_peak_nov..kw',
        'out.qoi.median_daily_peak_dec..kw'
    ]

    COLS_QOI_MONTHLY_MEAN_DAILY_PEAK = [
        'out.qoi.mean_daily_peak_jan..kw',
        'out.qoi.mean_daily_peak_feb..kw',
        'out.qoi.mean_daily_peak_mar..kw',
        'out.qoi.mean_daily_peak_apr..kw',
        'out.qoi.mean_daily_peak_may..kw',
        'out.qoi.mean_daily_peak_jun..kw',
        'out.qoi.mean_daily_peak_jul..kw',
        'out.qoi.mean_daily_peak_aug..kw',
        'out.qoi.mean_daily_peak_sep..kw',
        'out.qoi.mean_daily_peak_oct..kw',
        'out.qoi.mean_daily_peak_nov..kw',
        'out.qoi.mean_daily_peak_dec..kw'
    ]

    COLS_QOI_MONTHLY_MEAN_DAILY_PEAK_GRID_WIN = [
        'out.qoi.mean_daily_peak_grid_window_jan..kw',
        'out.qoi.mean_daily_peak_grid_window_feb..kw',
        'out.qoi.mean_daily_peak_grid_window_mar..kw',
        'out.qoi.mean_daily_peak_grid_window_apr..kw',
        'out.qoi.mean_daily_peak_grid_window_may..kw',
        'out.qoi.mean_daily_peak_grid_window_jun..kw',
        'out.qoi.mean_daily_peak_grid_window_jul..kw',
        'out.qoi.mean_daily_peak_grid_window_aug..kw',
        'out.qoi.mean_daily_peak_grid_window_sep..kw',
        'out.qoi.mean_daily_peak_grid_window_oct..kw',
        'out.qoi.mean_daily_peak_grid_window_nov..kw',
        'out.qoi.mean_daily_peak_grid_window_dec..kw'
    ]

    COLS_QOI_MONTHLY_MEAN_DAILY_PEAK_GRID_PEAK = [
        'out.qoi.mean_daily_peak_grid_peak_jan..kw',
        'out.qoi.mean_daily_peak_grid_peak_feb..kw',
        'out.qoi.mean_daily_peak_grid_peak_mar..kw',
        'out.qoi.mean_daily_peak_grid_peak_apr..kw',
        'out.qoi.mean_daily_peak_grid_peak_may..kw',
        'out.qoi.mean_daily_peak_grid_peak_jun..kw',
        'out.qoi.mean_daily_peak_grid_peak_jul..kw',
        'out.qoi.mean_daily_peak_grid_peak_aug..kw',
        'out.qoi.mean_daily_peak_grid_peak_sep..kw',
        'out.qoi.mean_daily_peak_grid_peak_oct..kw',
        'out.qoi.mean_daily_peak_grid_peak_nov..kw',
        'out.qoi.mean_daily_peak_grid_peak_dec..kw'
    ]

    # Greenhouse gas emissions columns
    GHG_NATURAL_GAS = 'out.emissions.natural_gas..co2e_kg'
    GHG_FUEL_OIL = 'out.emissions.fuel_oil..co2e_kg'
    GHG_PROPANE = 'out.emissions.propane..co2e_kg'
    GHG_DISTCLG = 'out.emissions.district_cooling..co2e_kg'
    GHG_DISTHTG = 'out.emissions.district_heating..co2e_kg'
    GHG_LRMER_LOW_RE_COST_15_ELEC = 'out.emissions.electricity.lrmer_low_re_cost_15_2023_start..co2e_kg'
    GHG_LRMER_MID_CASE_15_ELEC = 'out.emissions.electricity.lrmer_mid_case_15_2023_start..co2e_kg'
    GHG_LRMER_HIGH_RE_COST_15_ELEC = 'out.emissions.electricity.lrmer_high_re_cost_15_2023_start..co2e_kg'
    GHG_ELEC_EGRID = 'out.emissions.electricity.egrid_2021_subregion..co2e_kg'

    # Criteria pollutant emissions columns
    NOX_NATURAL_GAS = 'out.nox_emissions.natural_gas..nox_kg'
    CO_NATURAL_GAS = 'out.co_emissions.natural_gas..co_kg'
    PM_NATURAL_GAS = 'out.pm_emissions.natural_gas..pm_kg'
    SO2_NATURAL_GAS = 'out.so2_emissions.natural_gas..so2_kg'
    NOX_FUEL_OIL = 'out.nox_emissions.fuel_oil..nox_kg'
    CO_FUEL_OIL = 'out.co_emissions.fuel_oil..co_kg'
    PM_FUEL_OIL = 'out.pm_emissions.fuel_oil..pm_kg'
    SO2_FUEL_OIL = 'out.so2_emissions.fuel_oil..so2_kg'
    NOX_PROPANE = 'out.nox_emissions.propane..nox_kg'
    CO_PROPANE = 'out.co_emissions.propane..co_kg'
    PM_PROPANE = 'out.pm_emissions.propane..pm_kg'
    SO2_PROPANE = 'out.so2_emissions.propane..so2_kg'

    # Addressable segment columns
    SEG_A = 'A: Non Food-Service Buildings with Small Packaged Units'
    SEG_B = 'B: Food-Service Buildings with Small Packaged Units'
    SEG_C = 'C: Strip Malls with some Food-Service with Small Packaged Units'
    SEG_D = 'D: Buildings with Hydronically Heated Multizone Systems'
    SEG_E = 'E: Lodging with Zone-by-Zone Systems'
    SEG_F = 'F: Buildings with Electric Resistance Multizone Systems'
    SEG_G = 'G: Buildings with Furnace-Based Multizone Systems'
    SEG_H = 'H: Buildings with Residential Style Central Systems'
    SEG_I = 'I: Non-Lodging Buildings with Zone-by-Zone Systems'
    SEG_J = 'J: Other'

    # List of addressable segments
    COLS_SEGMENTS = [
        SEG_A,
        SEG_B,
        SEG_C,
        SEG_D,
        SEG_E,
        SEG_F,
        SEG_G,
        SEG_H,
        SEG_I,
        SEG_J
    ]

    # these columns are used to incorporate PV
    # this list is to get weighted and savings values for them
    COLS_GEN_ANN_ENGY = [
        ANN_TOT_NET_ENGY_KBTU,
        ANN_TOT_NET_ELEC_KBTU,
        ANN_PURCHASED_ELEC_KBTU,
    ]

    # List of total net annual energy columns (includes generated PV)
    COLS_NET_ANN_ENGY = [
        ANN_TOT_NET_ENGY_KBTU,
        ANN_TOT_NET_ELEC_KBTU,
        ANN_TOT_GAS_KBTU,
        ANN_TOT_FUELOIL_KBTU,
        ANN_TOT_PROPANE_KBTU,
        ANN_TOT_DISTHTG_KBTU,
        ANN_TOT_DISTCLG_KBTU
    ]

    # List of total net annual energy columns (includes generated PV)
    COLS_PURCHASED_ANN_ENGY = [
        ANN_PURCHASED_ELEC_KBTU,
        ANN_TOT_GAS_KBTU,
        ANN_TOT_FUELOIL_KBTU,
        ANN_TOT_PROPANE_KBTU,
        ANN_TOT_DISTHTG_KBTU,
        ANN_TOT_DISTCLG_KBTU
    ]

    # List of total annual energy columns
    COLS_TOT_ANN_ENGY = [
        ANN_TOT_ENGY_KBTU,
        ANN_TOT_ELEC_KBTU,
        ANN_TOT_GAS_KBTU,
        ANN_TOT_FUELOIL_KBTU,
        ANN_TOT_PROPANE_KBTU,
        ANN_TOT_DISTHTG_KBTU,
        ANN_TOT_DISTCLG_KBTU
    ]

    # List of end use annual energy columns
    COLS_ENDUSE_ANN_ENGY = [
        ANN_ELEC_COOL_KBTU,
        ANN_ELEC_EXTLTG_KBTU,
        ANN_ELEC_FANS_KBTU,
        ANN_ELEC_HEATREJECT_KBTU,
        ANN_ELEC_HEATRECOV_KBTU,
        ANN_ELEC_HEAT_KBTU,
        ANN_ELEC_INTEQUIP_KBTU,
        ANN_ELEC_INTLTG_KBTU,
        ANN_ELEC_PUMPS_KBTU,
        ANN_ELEC_REFRIG_KBTU,
        ANN_ELEC_SWH_KBTU,
        ANN_ELEC_PV_KBTU,
        ANN_GAS_HEAT_KBTU,
        ANN_GAS_INTEQUIP_KBTU,
        ANN_GAS_SWH_KBTU,
        ANN_GAS_COOL_KBTU,
        ANN_PROPANE_HEAT_KBTU,
        ANN_PROPANE_INTEQUIP_KBTU,
        ANN_PROPANE_SWH_KBTU,
        ANN_FUELOIL_HEAT_KBTU,
        ANN_FUELOIL_INTEQUIP_KBTU,
        ANN_FUELOIL_SWH_KBTU,
        ANN_DISTCLG_COOL_KBTU,
        ANN_DISTHTG_HEAT_KBTU,
        ANN_DISTHTG_INTEQUIP_KBTU,
        ANN_DISTHTG_SWH_KBTU,
        ANN_DISTHTG_COOL_KBTU,
    ]

    # List of natural gas end use columns
    COLS_GAS_ENDUSE = [
        ANN_GAS_HEAT_KBTU,
        ANN_GAS_SWH_KBTU,
        ANN_GAS_INTEQUIP_KBTU,
        ANN_GAS_COOL_KBTU
    ]

    # List of electricity end use columns
    COLS_ELEC_ENDUSE = [
        ANN_ELEC_COOL_KBTU,
        ANN_ELEC_EXTLTG_KBTU,
        ANN_ELEC_FANS_KBTU,
        ANN_ELEC_HEATREJECT_KBTU,
        ANN_ELEC_HEATRECOV_KBTU,
        ANN_ELEC_HEAT_KBTU,
        ANN_ELEC_INTEQUIP_KBTU,
        ANN_ELEC_INTLTG_KBTU,
        ANN_ELEC_PUMPS_KBTU,
        ANN_ELEC_REFRIG_KBTU,
        ANN_ELEC_SWH_KBTU,
        ANN_ELEC_PV_KBTU,
    ]

    # List of heating end use columns
    COLS_HEAT_ENDUSE = [
        ANN_ELEC_HEAT_KBTU,
        ANN_GAS_HEAT_KBTU,
        ANN_PROPANE_HEAT_KBTU,
        ANN_FUELOIL_HEAT_KBTU,
        ANN_DISTHTG_HEAT_KBTU
    ]

    # List of cooling end use columns
    COLS_COOL_ENDUSE = [
        ANN_ELEC_COOL_KBTU,
        ANN_GAS_COOL_KBTU,
        ANN_DISTHTG_COOL_KBTU,
        ANN_DISTCLG_COOL_KBTU
    ]

    # List of HVAC, electricity end use columns
    COLS_HVAC_ELEC_ENDUSE = [
        ANN_ELEC_COOL_KBTU,
        ANN_ELEC_HEAT_KBTU,
        ANN_ELEC_FANS_KBTU,
        ANN_ELEC_PUMPS_KBTU,
        ANN_ELEC_HEATRECOV_KBTU,
        ANN_ELEC_HEATREJECT_KBTU
    ]

    # List of HVAC, natural_gas end use columns
    COLS_HVAC_GAS_ENDUSE = [
        ANN_GAS_COOL_KBTU,
        ANN_GAS_HEAT_KBTU
    ]

    # List of HVAC, propane end use columns
    COLS_HVAC_PROPANE_ENDUSE = [
        ANN_PROPANE_HEAT_KBTU
    ]

    # List of HVAC, fuel oil end use columns
    COLS_HVAC_FUELOIL_ENDUSE = [
        ANN_FUELOIL_HEAT_KBTU
    ]

    # List of HVAC, district_heating end use columns
    COLS_HVAC_DISTHTG_ENDUSE = [
        ANN_DISTHTG_COOL_KBTU,
        ANN_DISTHTG_HEAT_KBTU
    ]

    # List of HVAC, district_cooling end use columns
    COLS_HVAC_DISTCLG_ENDUSE = [
        ANN_DISTCLG_COOL_KBTU
    ]

    # List of Lighting, electricity end use columns
    COLS_LTG_ELEC_ENDUSE = [
        ANN_ELEC_INTLTG_KBTU,
        ANN_ELEC_EXTLTG_KBTU
    ]

    # List of Interior Equipment, electricity end use columns
    COLS_INTEQUIP_ELEC_ENDUSE = [
        ANN_ELEC_INTEQUIP_KBTU
    ]

    # List of Interior Equipment, natural gas end use columns
    COLS_INTEQUIP_GAS_ENDUSE = [
        ANN_GAS_INTEQUIP_KBTU
    ]

    # List of Interior Equipment, propane end use columns
    COLS_INTEQUIP_PROPANE_ENDUSE = [
        ANN_PROPANE_INTEQUIP_KBTU
    ]

    # List of Interior Equipment, fuel oil no 2 end use columns
    COLS_INTEQUIP_FUELOIL_ENDUSE = [
        ANN_FUELOIL_INTEQUIP_KBTU
    ]

    # List of Interior Equipment, district_heating end use columns
    COLS_INTEQUIP_DISTHTG_ENDUSE = [
        ANN_DISTHTG_INTEQUIP_KBTU
    ]

    # List of Water Heating, electricity end use columns
    COLS_SWH_ELEC_ENDUSE = [
        ANN_ELEC_SWH_KBTU
    ]

    # List of Water Heating, natural gas end use columns
    COLS_SWH_GAS_ENDUSE = [
        ANN_GAS_SWH_KBTU
    ]

    # List of Water Heating, propane end use columns
    COLS_SWH_PROPANE_ENDUSE = [
        ANN_PROPANE_SWH_KBTU
    ]

    # List of Water Heating, fuel oil end use columns
    COLS_SWH_FUELOIL_ENDUSE = [
        ANN_FUELOIL_SWH_KBTU
    ]

    # List of Water Heating, district_heating end use columns
    COLS_SWH_DISTHTG_ENDUSE = [
        ANN_DISTHTG_SWH_KBTU
    ]

    # List of Refrigeration, electricity end use columns
    COLS_REFRIG_ELEC_ENDUSE = [
        ANN_ELEC_REFRIG_KBTU
    ]

    # Refrigeration sub-category detail columns for Grocery buildings (subset of refrigeration, not added to COLS_ENDUSE_ANN_ENGY)
    COLS_GROCERY_REFRIG_DEFROST_ENDUSE = [
        ANN_ELEC_REFRIG_MED_TEMP_CASE_DEFROST_KWH,
        ANN_ELEC_REFRIG_LOW_TEMP_CASE_DEFROST_KWH,
        ANN_ELEC_REFRIG_MED_TEMP_WALKIN_DEFROST_KWH,
        ANN_ELEC_REFRIG_LOW_TEMP_WALKIN_DEFROST_KWH
    ]

    # Refrigeration medium temperature detail columns for Grocery buildings
    COLS_GROCERY_REFRIG_MED_TEMP_DEFROST_ENDUSE = [
        ANN_ELEC_REFRIG_MED_TEMP_CASE_DEFROST_KWH,
        ANN_ELEC_REFRIG_MED_TEMP_WALKIN_DEFROST_KWH
    ]

    # Refrigeration low temperature detail columns for Grocery buildings
    COLS_GROCERY_REFRIG_LOW_TEMP_DEFROST_ENDUSE = [
        ANN_ELEC_REFRIG_LOW_TEMP_CASE_DEFROST_KWH,
        ANN_ELEC_REFRIG_LOW_TEMP_WALKIN_DEFROST_KWH
    ]

    # List of HVAC end use group columns
    COLS_HVAC_ENERGY = COLS_HVAC_ELEC_ENDUSE + COLS_HVAC_GAS_ENDUSE + COLS_HVAC_PROPANE_ENDUSE + COLS_HVAC_FUELOIL_ENDUSE + COLS_HVAC_DISTHTG_ENDUSE + COLS_HVAC_DISTCLG_ENDUSE

    # List of Equipment end use group columns
    COLS_INTEQUIP_ENERGY = [
        ANN_ELEC_INTEQUIP_KBTU,
        ANN_GAS_INTEQUIP_KBTU,
        ANN_PROPANE_INTEQUIP_KBTU,
        ANN_FUELOIL_INTEQUIP_KBTU,
        ANN_DISTHTG_INTEQUIP_KBTU
    ]

    # List of Water Heating end use group columns
    COLS_SWH_ENERGY = [
        ANN_ELEC_SWH_KBTU,
        ANN_GAS_SWH_KBTU,
        ANN_PROPANE_SWH_KBTU,
        ANN_FUELOIL_SWH_KBTU,
        ANN_DISTHTG_SWH_KBTU
    ]

    QOI_MAX_DAILY_TIMING_COLS = [
        QOI_MAX_SHOULDER_HR,
        QOI_MAX_SUMMER_HR,
        QOI_MAX_WINTER_HR
    ]

    QOI_MAX_USE_COLS = [
        QOI_MAX_SHOULDER_USE,
        QOI_MAX_SUMMER_USE,
        QOI_MAX_WINTER_USE
    ]

    QOI_MIN_USE_COLS = [
        QOI_MIN_SHOULDER_USE,
        QOI_MIN_SUMMER_USE,
        QOI_MIN_WINTER_USE
    ]

    QOI_MAX_USE_COLS_NORMALIZED = [
        QOI_MAX_SHOULDER_USE_NORMALIZED,
        QOI_MAX_SUMMER_USE_NORMALIZED,
        QOI_MAX_WINTER_USE_NORMALIZED
    ]

    QOI_MIN_USE_COLS_NORMALIZED = [
        QOI_MIN_SHOULDER_USE_NORMALIZED,
        QOI_MIN_SUMMER_USE_NORMALIZED,
        QOI_MIN_WINTER_USE_NORMALIZED
    ]

    GHG_FUEL_COLS = [
        GHG_NATURAL_GAS,
        GHG_FUEL_OIL,
        GHG_PROPANE,
        GHG_DISTCLG,
        GHG_DISTHTG,
        GHG_LRMER_LOW_RE_COST_15_ELEC,
        #GHG_LRMER_MID_CASE_15_ELEC,
        GHG_LRMER_HIGH_RE_COST_15_ELEC,
        GHG_ELEC_EGRID
    ]

    UNMET_HOURS_COLS = [
        COOLING_HOURS_UNMET,
        HEATING_HOURS_UNMET,
    ]

    UNWTD_COL_GROUPS = [
        # Energy
        {
            'cols': COLS_TOT_ANN_ENGY + COLS_ENDUSE_ANN_ENGY + COLS_GEN_ANN_ENGY,
            'weighted_units': 'tbtu'
        },
        # Peak Demand QOIs
        {
            'cols': (COLS_QOI_MONTHLY_MAX_DAILY_PEAK +
                            COLS_QOI_MONTHLY_MED_DAILY_PEAK +
                            COLS_QOI_MONTHLY_MEAN_DAILY_PEAK +
                            COLS_QOI_MONTHLY_MEAN_DAILY_PEAK_GRID_WIN +
                            COLS_QOI_MONTHLY_MEAN_DAILY_PEAK_GRID_PEAK +
                            [QOI_MAX_SHOULDER_USE,
                            QOI_MAX_SUMMER_USE,
                            QOI_MAX_WINTER_USE]),
            'weighted_units': 'gw'
        },
        # Emissions
        {
            'cols': (COLS_GHG_ELEC_SEASONAL_DAILY_EGRID +
                            COLS_GHG_ELEC_SEASONAL_DAILY_CAMBIUM +
                            [GHG_LRMER_MID_CASE_15_ELEC,
                            GHG_ELEC_EGRID,
                            ANN_GHG_EGRID,
                            ANN_GHG_CAMBIUM]),
            'weighted_units': 'co2e_mmt'
        },
        # NOX Emissions
        {
            'cols': ([NOX_NATURAL_GAS, NOX_FUEL_OIL, NOX_PROPANE]),
            'weighted_units': 'nox_kg'
        },
        # CO Emissions
        {
            'cols': ([CO_NATURAL_GAS, CO_FUEL_OIL, CO_PROPANE]),
            'weighted_units': 'co_kg'
        },
        # PM Emissions
        {
            'cols': ([PM_NATURAL_GAS, PM_FUEL_OIL, PM_PROPANE]),
            'weighted_units': 'pm_kg'
        },
        # SO2 Emissions
        {
            'cols': ([SO2_NATURAL_GAS, SO2_FUEL_OIL, SO2_PROPANE]),
            'weighted_units': 'so2_kg'
        }
    ]

    # Colors from https://davidmathlogic.com/colorblind Bang Wong color palette
    COLOR_COMSTOCK_BEFORE = '#0072B2'
    COLOR_COMSTOCK_AFTER = '#56B4E9'
    COLOR_CBECS_2012 = '#009E73'
    COLOR_CBECS_2018 = '#16f0b4'
    COLOR_EIA = '#D55E00'
    COLOR_AMI = '#CC79A7'

    # standard end use colors for plotting
    ENDUSE_COLOR_DICT = {
                'Photovoltaics Excess':'#8CC739',
                'Photovoltaics Used':'Green',
                'Heating':'#EF1C21',
                'Cooling':'#0071BD',
                'Interior Lighting':'#F7DF10',
                'Exterior Lighting':'#DEC310',
                'Interior Equipment':'#4A4D4A',
                'Exterior Equipment':'#B5B2B5',
                'Fans':'#FF79AD',
                'Pumps':'#632C94',
                'Heat Rejection':'#F75921',
                'Humidification':'#293094',
                'Heat Recovery': '#CE5921',
                'Water Systems': '#FFB239',
                'Refrigeration': '#29AAE7',
                'Generators': '#8CC739'
                }

    # Convert color codes to RGBA with opacity 1.0
    PLOTLY_ENDUSE_COLOR_DICT = {key: f"rgba({int(mcolors.to_rgba(value, alpha=1.0)[0]*255)},{int(mcolors.to_rgba(value, alpha=1.0)[1]*255)},{int(mcolors.to_rgba(value, alpha=1.0)[2]*255)},{mcolors.to_rgba(value, alpha=1.0)[3]})" for key, value in ENDUSE_COLOR_DICT.items()}

    # Define ordering for some categorical variables to make plots easier to interpret
    ORDERED_CATEGORIES = {
        FLR_AREA_CAT:
            ['1,000 square feet or less',
            '1,001 to 5,000 square feet',
            '5,001 to 10,000 square feet',
            '10,001 to 25,000 square feet',
            '25,001 to 50,000 square feet',
            '50,001 to 100,000 square feet',
            '100,001 to 200,000 square feet',
            '200,001 to 500,000 square feet',
            '500,001 to 1 million square feet',
            'Over 1 million square feet'],
        CEN_DIV:
            ['New England',
            'Middle Atlantic',
            'East North Central',
            'West North Central',
            'South Atlantic',
            'East South Central',
            'West South Central',
            'Mountain',
            'Pacific'],
        VINTAGE:
            ['Before 1946',
            '1946 to 1959',
            '1960 to 1969',
            '1970 to 1979',
            '1980 to 1989',
            '1990 to 1999',
            '2000 to 2012',
            '2013 to 2018'],
        BLDG_TYPE:
            ['FullServiceRestaurant',
            'QuickServiceRestaurant',
            'RetailStripmall',
            'RetailStandalone',
            'SmallOffice',
            'MediumOffice',
            'LargeOffice',
            'PrimarySchool',
            'SecondarySchool',
            'Outpatient',
            'Hospital',
            'SmallHotel',
            'LargeHotel',
            'Warehouse',
            'Grocery'],

         HVAC_SYS: [
             'Baseboard electric',
             'Direct evap coolers with baseboard electric',
             'Direct evap coolers with baseboard gas boiler',
             'Direct evap coolers with forced air furnace',
             'DOAS with fan coil air-cooled chiller with baseboard electric',
             'DOAS with fan coil air-cooled chiller with boiler',
             'DOAS with fan coil air-cooled chiller with district hot water',
             'DOAS with fan coil chiller with baseboard electric',
             'DOAS with fan coil chiller with boiler',
             'DOAS with fan coil chiller with district hot water',
             'DOAS with fan coil district chilled water with baseboard electric',
             'DOAS with fan coil district chilled water with boiler',
             'DOAS with fan coil district chilled water with district hot water',
             'DOAS with VRF',
             'DOAS with water source heat pumps cooling tower with boiler',
             'DOAS with water source heat pumps with ground source heat pump',
             'Gas unit heaters',
             'PSZ-AC district chilled water with electric coil',
             'PSZ-AC with district hot water',
             'PSZ-AC with electric coil',
             'PSZ-AC with gas boiler',
             'PSZ-AC with gas coil',
             'PSZ-HP',
             'PTAC with electric coil',
             'PTAC with gas boiler',
             'PTAC with gas coil',
             'PTHP',
             'PVAV with district hot water reheat',
             'PVAV with gas boiler reheat',
             'PVAV with gas heat with electric reheat',
             'PVAV with PFP boxes',
             'Residential AC with residential forced air furnace',
             'Residential forced air furnace',
             'VAV air-cooled chiller with district hot water reheat',
             'VAV air-cooled chiller with gas boiler reheat',
             'VAV air-cooled chiller with PFP boxes',
             'VAV chiller with district hot water reheat',
             'VAV chiller with gas boiler reheat',
             'VAV chiller with PFP boxes',
             'VAV district chilled water with district hot water reheat',
             'VAV district chilled water with gas boiler reheat',
             'VAV district chilled water with PFP boxes'
         ]
    }

    BLDG_TYPE_TO_SNAKE_CASE = {
        'FullServiceRestaurant': 'full_service_restaurant',
        'QuickServiceRestaurant': 'quick_service_restaurant',
        'RetailStripmall': 'strip_mall',
        'RetailStandalone': 'retail',
        'SmallOffice': 'small_office',
        'MediumOffice': 'medium_office',
        'LargeOffice': 'large_office',
        'PrimarySchool': 'primary_school',
        'SecondarySchool': 'secondary_school',
        'Outpatient': 'outpatient',
        'Hospital': 'hospital',
        'SmallHotel': 'small_hotel',
        'LargeHotel': 'large_hotel',
        'Warehouse': 'warehouse',
        'Grocery': 'grocery',
        'SuperMarket': 'grocery'
    }

    BLDG_TYPE_TO_ABBRV = {
        'FullServiceRestaurant': 'FSR',
        'QuickServiceRestaurant': 'QSR',
        'RetailStripmall': 'RSM',
        'RetailStandalone': 'RTL',
        'SmallOffice': 'SMOFF',
        'MediumOffice': 'MDOFF',
        'LargeOffice': 'LGOFF',
        'PrimarySchool': 'PRISCH',
        'SecondarySchool': 'SECSCH',
        'Outpatient': 'OUTPT',
        'Hospital': 'HSP',
        'SmallHotel': 'SMHOT',
        'LargeHotel': 'LGHOT',
        'Warehouse': 'WH',
        'Grocery': 'GROC'
    }

    END_USES = [
        'exterior_lighting',
        'interior_lighting',
        'interior_equipment',
        'water_systems',
        'heat_recovery',
        'heat_rejection',
        'cooling',
        'heating',
        'fans',
        'pumps',
        'refrigeration'
    ]

    LOAD_COMPONENTS = [
        'people_gain',
        'light_gain',
        'equip_gain',
        'ref_equip_gain',
        'win_sol',
        'ext_wall',
        'fnd_wall',
        'roof',
        'ext_flr',
        'gnd_flr',
        'win_cond',
        'door',
        'infil',
        'vent'
    ]

    LOAD_PERIODS = [
        'htg',
        'clg',
        'flt'
    ]

    LOAD_FUELS = [
        'natural_gas',
        'electricity',
        'district_cooling',
        'district_heating'
    ]

    END_USES_TIMESERIES_DICT = {
        'exterior_lighting': 'electricity_exterior_lighting_kwh',
        'interior_lighting': 'electricity_interior_lighting_kwh',
        'interior_equipment': 'electricity_interior_equipment_kwh',
        'water_systems': 'electricity_water_systems_kwh',
        'heat_recovery': 'electricity_heat_recovery_kwh',
        'heat_rejection': 'electricity_heat_rejection_kwh',
        'cooling': 'electricity_cooling_kwh',
        'heating': 'electricity_heating_kwh',
        'fans': 'electricity_fans_kwh',
        'pumps': 'electricity_pumps_kwh',
        'refrigeration': 'electricity_refrigeration_kwh'
    }

    STATE_NHGIS_TO_ABBRV = {
        'G010': 'AL',
        'G020': 'AK',
        'G040': 'AZ',
        'G050': 'AR',
        'G060': 'CA',
        'G080': 'CO',
        'G090': 'CT',
        'G100': 'DE',
        'G110': 'DC',
        'G120': 'FL',
        'G130': 'GA',
        'G150': 'HI',
        'G160': 'ID',
        'G170': 'IL',
        'G180': 'IN',
        'G190': 'IA',
        'G200': 'KS',
        'G210': 'KY',
        'G220': 'LA',
        'G230': 'ME',
        'G240': 'MD',
        'G250': 'MA',
        'G260': 'MI',
        'G270': 'MN',
        'G280': 'MS',
        'G290': 'MO',
        'G300': 'MT',
        'G310': 'NE',
        'G320': 'NV',
        'G330': 'NH',
        'G340': 'NJ',
        'G350': 'NM',
        'G360': 'NY',
        'G370': 'NC',
        'G380': 'ND',
        'G390': 'OH',
        'G400': 'OK',
        'G410': 'OR',
        'G420': 'PA',
        'G440': 'RI',
        'G450': 'SC',
        'G460': 'SD',
        'G470': 'TN',
        'G480': 'TX',
        'G490': 'UT',
        'G500': 'VT',
        'G510': 'VA',
        'G530': 'WA',
        'G540': 'WV',
        'G550': 'WI',
        'G560': 'WY',
    }

    MIXED_CZ_TO_ASHRAE_CZ = {
            'CEC1': '4B',
            'CEC2': '3C',
            'CEC3': '3C',
            'CEC4': '3C',
            'CEC5': '3C',
            'CEC6': '3C',
            'CEC7': '3B',
            'CEC8': '3B',
            'CEC9': '3B',
            'CEC10': '3B',
            'CEC11': '3B',
            'CEC12': '3B',
            'CEC13': '3B',
            'CEC14': '3B',
            'CEC15': '2B',
            'CEC16': '5B',
            '1A':'1A',
            '2A':'2A',
            '2B':'2B',
            '3A':'3A',
            '3B':'3B',
            '3C':'3C',
            '4A':'4A',
            '4B':'4B',
            '4C':'4C',
            '5A':'5A',
            '5B':'5B',
            '6A':'6A',
            '6B':'6B',
            '7A':'7',  # TODO remove 7A/7B from spatial_tract_lookup_table_publish_vN.csv?
            '7B':'7',  # TODO remove 7A/7B from spatial_tract_lookup_table_publish_vN.csv?
            '7':'7',
            '8':'8',
    }

    #Naming for RSE calculations
    REPL_WEIGHT_RE: re.Pattern = re.compile(
        r"^Unknown Eligibility and Nonresponse Adjusted Replicate Weight \d+$"
    )
    ALL_TOKEN: str = "All"


    def end_use_group(self, end_use):
        # Add an End Use Group
        end_use_groups = {
            'cooling': 'HVAC',
            'exterior_lighting': 'Lighting',
            'fans': 'HVAC',
            'generators': 'Power Generation',
            'heat_recovery': 'HVAC',
            'heat_rejection': 'HVAC',
            'heating': 'HVAC',
            'humidification': 'HVAC',
            'interior_equipment': 'Equipment',
            'interior_lighting': 'Lighting',
            'pumps': 'HVAC',
            'pv': 'Power Generation',
            'refrigeration': 'Refrigeration',
            'water_systems': 'Water Heating',
            'total': 'Total',
        }

        return end_use_groups[end_use]

    def units_from_col_name(self, col_name):
        # Extract the units from the column name
        match = re.search('\.\.(.*)', col_name)
        if match:
            units = match.group(1)
        else:
            units = ''

        return units

    def col_name_to_weighted(self, col_name, new_units=None):

        # 'if' statement to avoid "min." inclusion in "in." replace
        if col_name.startswith('in.'):
            col_name = col_name.replace('in.', 'out.')
        col_name = col_name.replace('out.', 'calc.')
        col_name = col_name.replace('calc.', 'calc.weighted.')
        if not new_units is None:
            old_units = self.units_from_col_name(col_name)
            col_name = col_name.replace(f'..{old_units}', f'..{new_units}')

        return col_name

    def col_name_to_weighted_savings(self, col_name, new_units=None):
        col_name = self.col_name_to_weighted(col_name, new_units)
        col_name = col_name.replace('.weighted.', '.weighted.savings.')
        return col_name

    def col_name_to_savings(self, col_name, new_units=None):
        converted_col_name = col_name.replace('.energy_consumption', '.energy_savings')
        if "_bill_" in converted_col_name:
            converted_col_name = converted_col_name.replace('_bill_', '_bill_savings_')
        elif "_bill.." in converted_col_name:
            converted_col_name = converted_col_name.replace('_bill..', '_bill_savings..')
        elif "_daily_peak_" in converted_col_name:
            converted_col_name = converted_col_name.replace('_daily_peak_', '_daily_peak_savings_')
        elif ".peak_" in converted_col_name:
            converted_col_name = converted_col_name.replace('.peak_', '.peak_savings_')
        elif "maximum_daily_use_" in converted_col_name:
            converted_col_name = converted_col_name.replace('maximum_daily_use_', 'peak_savings_')
        elif ".emissions." in converted_col_name:
            converted_col_name = converted_col_name.replace('.emissions.', '.emissions.savings.')
        elif ".nox_emissions." in converted_col_name:
            converted_col_name = converted_col_name.replace('.nox_emissions.', '.nox_emissions.savings.')
        elif ".co_emissions." in converted_col_name:
            converted_col_name = converted_col_name.replace('.co_emissions.', '.co_emissions.savings.')
        elif ".pm_emissions." in converted_col_name:
            converted_col_name = converted_col_name.replace('.pm_emissions.', '.pm_emissions.savings.')
        elif ".so2_emissions." in converted_col_name:
            converted_col_name = converted_col_name.replace('.so2_emissions.', '.so2_emissions.savings.')

        if converted_col_name == col_name:
            raise ValueError(f"Cannot convert column name {col_name} to savings column")

        return converted_col_name

    def col_name_to_percent_savings(self, col_name, new_units=None):
        # col_name = self.col_name_to_savings(col_name)
        col_name = col_name.replace('out.', 'calc.')
        col_name = col_name.replace('calc.', 'calc.percent_savings.')
        if not new_units is None:
            old_units = self.units_from_col_name(col_name)
            col_name = col_name.replace(f'..{old_units}', f'..{new_units}')

        return col_name

    def col_name_to_eui(self, col_name):
        engy_units = self.units_from_col_name(col_name)
        col_name = col_name.replace('energy_consumption', 'energy_consumption_intensity')
        col_name = col_name.replace('energy_savings', 'energy_savings_intensity')
        area_units = 'ft2'  # Hard-coded because in.sqft column name is required by SightGlass
        eui_units = f'{engy_units}_per_{area_units}'
        col_name = col_name.replace(f'..{engy_units}', f'..{eui_units}')

        return col_name

    def col_name_to_area_intensity(self, col_name):
        units = self.units_from_col_name(col_name)
        col_name = col_name.replace('energy_consumption', 'energy_consumption_intensity')
        col_name = col_name.replace('energy_savings', 'energy_savings_intensity')
        col_name = col_name.replace('loads', 'loads_intensity')
        col_name = col_name.replace('bill_state_average', 'bill_state_average_intensity')
        col_name = col_name.replace('bill_min', 'bill_min_intensity')
        col_name = col_name.replace('bill_max', 'bill_max_intensity')
        # col_name = col_name.replace('bill_median..usd', 'bill_median_intensity..usd')
        col_name = col_name.replace('bill_median_low', 'bill_median_low_intensity')
        col_name = col_name.replace('bill_median_high', 'bill_median_high_intensity')
        col_name = col_name.replace('bill_mean', 'bill_mean_intensity')
        col_name = col_name.replace('_daily_peak_', '_daily_peak_intensity_')
        col_name = col_name.replace('maximum_daily_use_', 'peak_intensity_')
        col_name = col_name.replace('.emissions.', '.emissions.intensity.')
        col_name = col_name.replace('.nox_emissions.', '.nox_emissions.intensity.')
        col_name = col_name.replace('.co_emissions.', '.co_emissions.intensity.')
        col_name = col_name.replace('.pm_emissions.', '.pm_emissions.intensity.')
        col_name = col_name.replace('.so2_emissions.', '.so2_emissions.intensity.')
        area_units = 'ft2'
        intensity_units = f'{units}_per_{area_units}'
        col_name = col_name.replace(f'..{units}', f'..{intensity_units}')

        return col_name

    def col_name_to_energy_rate(self, col_name):
        units = self.units_from_col_name(col_name)
        col_name = col_name.replace('bill_mean..usd', 'energy_rate..usd')
        col_name = col_name.replace('bill..usd', 'energy_rate..usd')
        energy_units = 'kwh'
        intensity_units = f'{units}_per_{energy_units}'
        col_name = col_name.replace(f'..{units}', f'..{intensity_units}')

        return col_name

    def col_name_to_nice_name(self, col_name):
        # out.natural_gas.heating.energy_consumption..kwh
        # becomes
        # Natural Gas Heating Energy Consumption
        units = self.units_from_col_name(col_name)
        col_name = col_name.replace(f'..{units}', '')
        col_name = col_name.replace('in.', '')
        col_name = col_name.replace('out.', '')
        col_name = col_name.replace('params.', '')
        col_name = col_name.replace('weighted.', '')
        col_name = col_name.replace('calc.', '')
        col_name = col_name.replace('.', ' ')
        col_name = col_name.replace('_', ' ')
        col_name = col_name.replace('Eui', 'EUI')
        col_name = col_name.title()

        return col_name


    def col_name_to_nice_saving_name(self, col_name):
        units = self.nice_units(self.units_from_col_name(col_name))
        col_name = self.col_name_to_nice_name(col_name)
        col_name = col_name.replace(f' {units}', '')
        col_name = col_name.replace("Savings", '')
        col_name = col_name.replace("Consumption", '')
        col_name = col_name.replace("Eui", '')
        col_name = col_name.replace("Energy", '')
        col_name = col_name.replace("Percent", '')
        col_name = col_name.replace("Total", '')

        return col_name

    def col_name_to_fuel(self, col_name):

        # list of fuel type
        list_fuel = [
            "electricity",
            "natural gas",
            "site",
        ]

        # initialize
        fueltype = ''

        # search for fuel in col_name
        for fuel in list_fuel:
            if fuel in col_name.lower():
                fueltype = fuel.title()
                break
            else:
                fueltype = ""

        return fueltype

    def engy_col_name_to_parts(self, col_name):
        # out.electricity.cooling.energy_consumption..kwh
        # out.eui.electricity.cooling.energy_consumption..kwh_per_ft2
        # out.weighted.electricity.cooling.energy_consumption..TBtu
        col_name = col_name.replace(f'..', '.')
        p = col_name.split('.')
        if len(p) == 5:
            p.insert(1, 'unweighted')
        parts = {
            'type': p[1],
            'fuel': p[2],
            'enduse': p[3],
            # p[4] currently always 'energy_consumption'
            'units': p[5]
        }

        # Add end use group
        parts['enduse_group'] = self.end_use_group(parts['enduse'])

        return parts

    def enduse_col_name_to_enduse(self, col_name):
        # out.electricity.cooling.energy_consumption..kwh
        # out.eui.electricity.cooling.energy_consumption..kwh_per_ft2
        # out.weighted.electricity.cooling.energy_consumption..TBtu
        col_name = col_name.replace(f'..', '.')
        p = col_name.split('.')
        if len(p) == 5:
            p.insert(1, 'unweighted')
        parts = {
            'type': p[1],
            'fuel': p[2],
            'enduse': p[3],
            # p[4] currently always 'energy_consumption'
            'units': p[5]
        }
        return parts

    def dataframe_sorted_with_nice_names(self, df):
        #

        # TODO Sort the index in a standard way
        # for old_name in df.index.names:
        #     if old_name in self.ORDERED_CATEGORIES.keys():
        #         print(f'Found fixed ordering for {old_name}:')
        #         print(f'{self.ORDERED_CATEGORIES[old_name]}')

        # Rename index to nice names
        new_names = []
        for old_name in df.index.names:
            new_names.append(self.col_name_to_nice_name(old_name))

        df.index.rename(names=new_names, inplace=True)
        return df

    def shorten_qoi_names(self, col_name):
        col_name = col_name.replace("out.qoi.", '')
        col_name = col_name.replace("maximum_daily_", '')
        col_name = col_name.replace("minimum_daily_", '')
        col_name = col_name.replace("timing_", '')
        col_name = col_name.replace("use_", '')
        col_name = col_name.replace("_w_per_ft2", '')
        col_name = col_name.replace("_hour..hr", '')
        col_name = col_name.replace("_normalized", '')

        return col_name

    def load_component_cols(self):
        loads_cols = []
        for period in (self.LOAD_PERIODS):
            for component in (self.LOAD_COMPONENTS):
                pre = 'out.loads'
                unit = '..gj'
                loads_cols.append(f"{pre}.{period}.{component}{unit}")
        return loads_cols


    ## Following 3 methods are Required for RSE calculations using replicate weights used in postprocessing charts

    # Determine if a column is a replicate-weight column
    @classmethod
    def is_replicate_weight_col(cls, col: str) -> bool:
        return bool(cls.REPL_WEIGHT_RE.match(col))

    # Return all replicate-weight columns present in a frame
    @classmethod
    def list_replicate_weight_cols(
        cls, frame: Union["pl.LazyFrame", pd.DataFrame, Iterable[str]]
    ) -> List[str]:
        """
        Return all replicate-weight columns (151 expected) present in:
        - polars LazyFrame,
        - pandas DataFrame,
        - or a plain list/iterable of column names.
        """
        if hasattr(frame, "columns"):
            cols = list(frame.collect_schema().names())  # works for polars
        else:
            cols = list(frame)
        return [c for c in cols if cls.is_replicate_weight_col(c)]

    # Ensure expected weight columns are present in a frame
    @classmethod
    def ensure_weight_columns_present(
        cls, frame: Union["pl.LazyFrame", pd.DataFrame, Iterable[str]],
        require_base: bool = True,
        require_reps: bool = False,
    ) -> None:
        if hasattr(frame, "columns"):
            cols = list(frame.collect_schema().names()) # polars DataFrame
        else:
            cols = list(frame)
        missing = []
        if require_base and cls.BLDG_WEIGHT not in cols:
            missing.append(cls.BLDG_WEIGHT)
        if require_reps:
            reps = cls.list_replicate_weight_cols(cols)
            if not reps:
                missing.append("replicate weights (151)")
        if missing:
            raise AssertionError(f"Missing expected weight columns: {missing}")

    # Build a dtype map for plotting
    @classmethod
    def build_cast_map_for_plotting(
        cls, cols: Iterable[str]
    ) -> Dict[str, str]:
        """
        Build a dtype map for plotting:
        - use schema if known,
        - else float64 for numeric-ish columns,
        - always float64 for base weight + replicate weights.
        """
        cast_map: Dict[str, str] = {}
        for c in cols:
            if c in cls.COL_TYPE_SCHEMA:
                cast_map[c] = cls.COL_TYPE_SCHEMA[c]
            elif c == cls.BLDG_WEIGHT or cls.is_replicate_weight_col(c):
                cast_map[c] = "float64"
            else:
                # default behavior: let caller decide; many plotting numerics prefer float64
                cast_map[c] = "float64"
        return cast_map



