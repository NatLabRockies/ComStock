

###### (Automatically generated documentation)

# add_heat_pump_rtu

## Description
Measure replaces existing packaged single-zone RTU system types with heat pump RTUs. Not applicable for water coil systems.

## Modeler Description
Modeler has option to set backup heat source, prevelence of heat pump oversizing, heat pump oversizing limit, and addition of energy recovery. This measure will work on unitary PSZ systems as well as single-zone, constant air volume air loop PSZ systems.

## Measure Type
ModelMeasure

## Taxonomy


## Arguments


### Backup Heat Type
Specifies if the backup heat fuel type is a gas furnace or electric resistance coil. If match original primary heating fuel is selected, the heating fuel type will match the primary heating fuel type of the original model. If electric resistance is selected, AHUs will get electric resistance backup. If dual fuel gas furnace is selected, AHUs will get a natural gas backup coil (dual fuel RTU) regardless of the original heating fuel.
**Name:** backup_ht_fuel_scheme,
**Type:** Choice,
**Units:** ,
**Required:** true,
**Model Dependent:** false

**Choice Display Names** ["match_original_primary_heating_fuel", "electric_resistance_backup", "dual_fuel_gas_furnace_backup"]


### Maximum Performance Oversizing Factor
When heating design load exceeds cooling design load, the design cooling capacity of the unit will only be allowed to increase up to this factor to accomodate additional heating capacity. Oversizing the compressor beyond 25% can cause cooling cycling issues, even with variable speed compressors.
**Name:** performance_oversizing_factor,
**Type:** Double,
**Units:** ,
**Required:** true,
**Model Dependent:** false


### Temperature to Sizing Heat Pump, F
Specifies temperature to size heating on. If design temperature for climate is higher than specified, program will use design temperature. Heat pump sizing will not exceed user-input oversizing factor.
**Name:** htg_sizing_option,
**Type:** Choice,
**Units:** ,
**Required:** true,
**Model Dependent:** false

**Choice Display Names** ["47F", "17F", "0F", "-10F"]


### Cooling Upsizing Factor Estimate
RTU selection involves sizing up to unit that meets your capacity needs, which creates natural oversizing. This factor estimates this oversizing. E.G. the sizing calc may require 8.7 tons of cooling, but the size options are 7.5 tons and 10 tons, so you choose the 10 ton unit. A value of 1 means to upsizing.
**Name:** clg_oversizing_estimate,
**Type:** Double,
**Units:** ,
**Required:** true,
**Model Dependent:** false


### Rated HP Heating to Cooling Ratio
At rated conditions, a compressor will generally have slightly more cooling capacity than heating capacity. This factor integrates this ratio into the unit sizing.
**Name:** htg_to_clg_hp_ratio,
**Type:** Double,
**Units:** ,
**Required:** true,
**Model Dependent:** false


### Minimum outdoor air temperature that locks out heat pump compressor with electric backup heat, F
Specifies minimum outdoor air temperature for locking out heat pump compressor when the backup heating coil is electric resistance. Heat pump heating does not operated below this temperature and backup heating will operate if heating is still needed.
**Name:** hp_min_comp_lockout_temp_elec_backup_f,
**Type:** Double,
**Units:** ,
**Required:** true,
**Model Dependent:** false


### Minimum outdoor air temperature that locks out heat pump compressor with gas backup heat, F
Specifies minimum outdoor air temperature for locking out heat pump compressor when the backup heating coil is a gas furnace (dual fuel). This only applies when the backup heat type is set to match the original primary heating fuel and that fuel is gas; otherwise the electric backup lockout temperature is used. Heat pump heating does not operated below this temperature and backup heating will operate if heating is still needed.
**Name:** hp_min_comp_lockout_temp_gas_backup_f,
**Type:** Double,
**Units:** ,
**Required:** true,
**Model Dependent:** false


### Heat Pump RTU Performance Type
Determines performance assumptions. two_speed_standard_eff is a standard efficiency system with 2 staged compressors (2 stages cooling, 1 stage heating). two_speed_lab_data is similar to two_speed_standard_eff but uses lab testing data to inform performance rather than public curves from manufacturers. variable_speed_high_eff is a higher efficiency variable speed system. cchpc_2027_spec is a hypothetical 4-stage unit intended to meet the requirements of the cold climate heat pump RTU challenge 2027 specification.  
**Name:** hprtu_scenario,
**Type:** Choice,
**Units:** ,
**Required:** true,
**Model Dependent:** false

**Choice Display Names** ["two_speed_standard_eff", "two_speed_lab_data", "variable_speed_high_eff", "cchpc_2027_spec"]


### Add Energy Recovery?

**Name:** hr,
**Type:** Boolean,
**Units:** ,
**Required:** true,
**Model Dependent:** false


### Add Demand Control Ventilation?

**Name:** dcv,
**Type:** Boolean,
**Units:** ,
**Required:** true,
**Model Dependent:** false


### Add Economizer?

**Name:** econ,
**Type:** Boolean,
**Units:** ,
**Required:** true,
**Model Dependent:** false


### Upgrade Roof Insulation?
Upgrade roof insulation per AEDG recommendations.
**Name:** roof,
**Type:** Boolean,
**Units:** ,
**Required:** true,
**Model Dependent:** false


### Upgrade Windows?
Upgrade window per AEDG recommendations.
**Name:** window,
**Type:** Boolean,
**Units:** ,
**Required:** true,
**Model Dependent:** false


### Do a sizing run for informing sizing instead of using hard-sized model parameters?

**Name:** sizing_run,
**Type:** Boolean,
**Units:** ,
**Required:** true,
**Model Dependent:** false


### Print out detailed debugging logs if this parameter is true

**Name:** debug_verbose,
**Type:** Boolean,
**Units:** ,
**Required:** true,
**Model Dependent:** false


### Modify setbacks in heating mode? True will adjust setbacks, according to value in setback value argument.

**Name:** modify_setbacks,
**Type:** Boolean,
**Units:** ,
**Required:** false,
**Model Dependent:** false


### Amount in deg F by which temperatures are set back during unoccupied periods in heating mode. Done only if modify setbacks is set to true.

**Name:** setback_value,
**Type:** Double,
**Units:** ,
**Required:** false,
**Model Dependent:** false






