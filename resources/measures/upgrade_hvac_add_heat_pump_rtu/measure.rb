# frozen_string_literal: true

# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/
require 'openstudio-standards'
Dir["#{File.dirname(__FILE__)}/resources/*.rb"].sort.each { |file| require file }

# start the measure
class AddHeatPumpRtu < OpenStudio::Measure::ModelMeasure
  # rated cfm/ton limits enforced by EnergyPlus for DX coils
  # comparisons use a rounding tolerance because EnergyPlus unit conversion differs from manual conversion
  # reference: https://github.com/NREL/EnergyPlus/blob/337bfbadf019a80052578d1bad6112dca43036db/src/EnergyPlus/DataHVACGlobals.hh#L362-L368
  # EnergyPlus operational limits, for reference: 200 cfm/ton minimum, 600 cfm/ton maximum heating, 500 cfm/ton maximum cooling
  CFM_PER_TON_MIN_RATED = 300
  CFM_PER_TON_MAX_RATED = 450

  # performance json for each heat pump RTU scenario
  SCENARIO_PERFORMANCE_JSON = {
    'two_speed_standard_eff' => 'performance_maps_hprtu_std.json',
    'two_speed_lab_data' => 'performance_maps_hprtu_lab_data.json',
    'variable_speed_high_eff' => 'performance_maps_hprtu_variable_speed.json',
    'cchpc_2027_spec' => 'performance_map_CCHP_spec_2027.json'
  }.freeze

  # performance curve names in each scenario's json, listed by stage (first entry is stage 1)
  # a curve repeated across stages is applied to each of those stages
  TWO_SPEED_CURVE_NAMES = {
    cool_cap_ft: ['c_cap_low_T', 'c_cap_high_T'],
    cool_eir_ft: ['c_eir_low_T', 'c_eir_high_T'],
    cool_cap_ff: ['c_cap_low_ff', 'c_cap_high_ff'],
    cool_eir_ff: ['c_eir_low_ff', 'c_eir_high_ff'],
    heat_cap_ft: ['h_cap_T'],
    heat_eir_ft: ['h_eir_T'],
    heat_cap_ff: ['h_cap_allstages_ff'],
    heat_eir_ff: ['h_eir_allstages_ff']
  }.freeze
  SCENARIO_CURVE_NAMES = {
    'two_speed_standard_eff' => TWO_SPEED_CURVE_NAMES,
    'two_speed_lab_data' => TWO_SPEED_CURVE_NAMES,
    'variable_speed_high_eff' => {
      cool_cap_ft: ['cool_cap_ft1', 'cool_cap_ft2', 'cool_cap_ft3', 'cool_cap_ft4'],
      cool_eir_ft: ['cool_eir_ft1', 'cool_eir_ft2', 'cool_eir_ft3', 'cool_eir_ft4'],
      cool_cap_ff: ['cool_cap_ff1'] * 4,
      cool_eir_ff: ['cool_eir_ff1'] * 4,
      heat_cap_ft: ['heat_cap_ft1', 'heat_cap_ft2', 'heat_cap_ft3', 'heat_cap_ft4'],
      heat_eir_ft: ['heat_eir_ft1', 'heat_eir_ft2', 'heat_eir_ft3', 'heat_eir_ft4'],
      heat_cap_ff: ['heat_cap_ff1'] * 4,
      heat_eir_ff: ['heat_eir_ff1'] * 4
    }.freeze,
    'cchpc_2027_spec' => {
      cool_cap_ft: ['cool_cap_ft1', 'cool_cap_ft2', 'cool_cap_ft3', 'cool_cap_ft4'],
      cool_eir_ft: ['cool_eir_ft1', 'cool_eir_ft2', 'cool_eir_ft3', 'cool_eir_ft4'],
      cool_cap_ff: ['cool_cap_ff1'] * 4,
      cool_eir_ff: ['cool_eir_ff1'] * 4,
      heat_cap_ft: ['h_cap_low', 'h_cap_medium', 'h_cap_high', 'h_cap_boost'],
      heat_eir_ft: ['h_eir_low', 'h_eir_medium', 'h_eir_high', 'h_eir_boost'],
      heat_cap_ff: ['h_cap_allstages_ff'] * 4,
      heat_eir_ff: ['h_eir_allstages_ff'] * 4
    }.freeze
  }.freeze

  # rated COP regressions, COP = intercept + slope * capacity_kw, clamped to the fitted product range
  # fitted to Carrier/Lennox products meeting the 2023 federal minimum efficiency requirements
  # COPs exclude blower power and blower heat gain
  RATED_COP_REGRESSIONS = {
    cooling: { intercept: 3.881009, slope: -0.01034, min: 3.02, max: 3.97 },
    heating: { intercept: 3.957724, slope: -0.008502, min: 3.46, max: 3.99 }
  }.freeze

  # user-selectable heat pump heating sizing temperatures
  HTG_SIZING_OPTIONS_F = { '47F' => 47, '17F' => 17, '0F' => 0, '-10F' => -10 }.freeze

  # air loop name fragments used for applicability screening
  HP_NAME_WORDS = ['HP', 'hp', 'heat pump', 'Heat Pump'].freeze
  DATA_CENTER_NAME_WORDS = ['Data Center', 'DataCenter', 'data center', 'datacenter', 'DATACENTER', 'DATA CENTER'].freeze
  KITCHEN_NAME_WORDS = ['Kitchen', 'KITCHEN'].freeze
  VAV_NAME_WORDS = ['VAV', 'PVAV'].freeze

  # supply component types used for applicability screening
  EVAPORATIVE_COOLER_TYPES = ['OS_EvaporativeCooler_Direct_ResearchSpecial', 'OS_EvaporativeCooler_Indirect_ResearchSpecial', 'OS_EvaporativeFluidCooler_SingleSpeed', 'OS_EvaporativeFluidCooler_TwoSpeed'].freeze
  UNITARY_SYSTEM_TYPES = ['OS_AirLoopHVAC_UnitarySystem', 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir', 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir_MultiSpeed', 'OS_AirLoopHVAC_UnitaryHeatCool_VAVChangeoverBypass'].freeze

  # space type name fragments for zones whose heating setbacks are not modified
  SPACE_TYPES_NO_SETBACK = ['PatRm', 'PatRoom', 'Lab', 'Exam', 'PatCorridor', 'BioHazard', 'OR', 'PreOp', 'Soil Work', 'Trauma',
                            'Triage', 'Data Center', 'Mechanical', 'Entry', 'IT_Room', 'Toilet', 'MechElecRoom', 'Guest Room',
                            'guest room'].freeze

  # energy recovery applicability; building types are compared in lowercase
  ERV_EXCLUDED_BUILDING_TYPES = ['rff', 'rsd', 'quickservicerestaurant', 'fullservicerestaurant'].freeze
  ERV_EXCLUDED_ZONE_NAME_WORDS = ['Kitchen', 'kitchen', 'KITCHEN', 'Dining', 'dining', 'DINING'].freeze

  # human readable name
  def name
    'add_heat_pump_rtu'
  end

  # human readable description
  def description
    'Measure replaces existing packaged single-zone RTU system types with heat pump RTUs. Not applicable for water coil systems.'
  end

  # human readable description of modeling approach
  def modeler_description
    'Modeler has option to set backup heat source, prevelence of heat pump oversizing, heat pump oversizing limit, and addition of energy recovery. This measure will work on unitary PSZ systems as well as single-zone, constant air volume air loop PSZ systems.'
  end

  # define the arguments that the user will input
  def arguments(_model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # backup heat type
    backup_heat_options = ['match_original_primary_heating_fuel', 'electric_resistance_backup', 'dual_fuel_gas_furnace_backup']
    backup_ht_fuel_scheme = OpenStudio::Measure::OSArgument.makeChoiceArgument('backup_ht_fuel_scheme', backup_heat_options, true)
    backup_ht_fuel_scheme.setDisplayName('Backup Heat Type')
    backup_ht_fuel_scheme.setDescription('Specifies if the backup heat fuel type is a gas furnace or electric resistance coil. If match original primary heating fuel is selected, the heating fuel type will match the primary heating fuel type of the original model. If electric resistance is selected, AHUs will get electric resistance backup. If dual fuel gas furnace is selected, AHUs will get a natural gas backup coil (dual fuel RTU) regardless of the original heating fuel.')
    backup_ht_fuel_scheme.setDefaultValue('electric_resistance_backup')
    args << backup_ht_fuel_scheme

    # maximum oversizing factor for heating
    performance_oversizing_factor = OpenStudio::Measure::OSArgument.makeDoubleArgument('performance_oversizing_factor', true)
    performance_oversizing_factor.setDisplayName('Maximum Performance Oversizing Factor')
    performance_oversizing_factor.setDefaultValue(0)
    performance_oversizing_factor.setDescription('When heating design load exceeds cooling design load, the design cooling capacity of the unit will only be allowed to increase up to this factor to accomodate additional heating capacity. Oversizing the compressor beyond 25% can cause cooling cycling issues, even with variable speed compressors.')
    args << performance_oversizing_factor

    # heating sizing temperature
    htg_sizing_option = OpenStudio::Measure::OSArgument.makeChoiceArgument('htg_sizing_option', HTG_SIZING_OPTIONS_F.keys, true)
    htg_sizing_option.setDefaultValue('0F')
    htg_sizing_option.setDisplayName('Temperature to Sizing Heat Pump, F')
    htg_sizing_option.setDescription('Specifies temperature to size heating on. If design temperature for climate is higher than specified, program will use design temperature. Heat pump sizing will not exceed user-input oversizing factor.')
    args << htg_sizing_option

    # assumed oversizing factor for cooling
    clg_oversizing_estimate = OpenStudio::Measure::OSArgument.makeDoubleArgument('clg_oversizing_estimate', true)
    clg_oversizing_estimate.setDisplayName('Cooling Upsizing Factor Estimate')
    clg_oversizing_estimate.setDefaultValue(1)
    clg_oversizing_estimate.setDescription('RTU selection involves sizing up to unit that meets your capacity needs, which creates natural oversizing. This factor estimates this oversizing. E.G. the sizing calc may require 8.7 tons of cooling, but the size options are 7.5 tons and 10 tons, so you choose the 10 ton unit. A value of 1 means to upsizing.')
    args << clg_oversizing_estimate

    # ratio of heating to cooling capacity
    htg_to_clg_hp_ratio = OpenStudio::Measure::OSArgument.makeDoubleArgument('htg_to_clg_hp_ratio', true)
    htg_to_clg_hp_ratio.setDisplayName('Rated HP Heating to Cooling Ratio')
    htg_to_clg_hp_ratio.setDefaultValue(1)
    htg_to_clg_hp_ratio.setDescription('At rated conditions, a compressor will generally have slightly more cooling capacity than heating capacity. This factor integrates this ratio into the unit sizing.')
    args << htg_to_clg_hp_ratio

    # compressor lockout outdoor air temperature for electric backup heat
    hp_min_comp_lockout_temp_elec_backup_f = OpenStudio::Measure::OSArgument.makeDoubleArgument('hp_min_comp_lockout_temp_elec_backup_f', true)
    hp_min_comp_lockout_temp_elec_backup_f.setDisplayName('Minimum outdoor air temperature that locks out heat pump compressor with electric backup heat, F')
    hp_min_comp_lockout_temp_elec_backup_f.setDefaultValue(0.0)
    hp_min_comp_lockout_temp_elec_backup_f.setDescription('Specifies minimum outdoor air temperature for locking out heat pump compressor when the backup heating coil is electric resistance. Heat pump heating does not operated below this temperature and backup heating will operate if heating is still needed.')
    args << hp_min_comp_lockout_temp_elec_backup_f

    # compressor lockout outdoor air temperature for gas backup heat (dual fuel)
    hp_min_comp_lockout_temp_gas_backup_f = OpenStudio::Measure::OSArgument.makeDoubleArgument('hp_min_comp_lockout_temp_gas_backup_f', true)
    hp_min_comp_lockout_temp_gas_backup_f.setDisplayName('Minimum outdoor air temperature that locks out heat pump compressor with gas backup heat, F')
    hp_min_comp_lockout_temp_gas_backup_f.setDefaultValue(25.0)
    hp_min_comp_lockout_temp_gas_backup_f.setDescription('Specifies minimum outdoor air temperature for locking out heat pump compressor when the backup heating coil is a gas furnace (dual fuel). This only applies when the backup heat type is set to match the original primary heating fuel and that fuel is gas; otherwise the electric backup lockout temperature is used. Heat pump heating does not operated below this temperature and backup heating will operate if heating is still needed.')
    args << hp_min_comp_lockout_temp_gas_backup_f

    # heat pump RTU performance scenario
    hprtu_scenario = OpenStudio::Measure::OSArgument.makeChoiceArgument('hprtu_scenario', SCENARIO_PERFORMANCE_JSON.keys, true)
    hprtu_scenario.setDisplayName('Heat Pump RTU Performance Type')
    hprtu_scenario.setDescription('Determines performance assumptions. two_speed_standard_eff is a standard efficiency system with 2 staged compressors (2 stages cooling, 1 stage heating). two_speed_lab_data is similar to two_speed_standard_eff but uses lab testing data to inform performance rather than public curves from manufacturers. variable_speed_high_eff is a higher efficiency variable speed system. cchpc_2027_spec is a hypothetical 4-stage unit intended to meet the requirements of the cold climate heat pump RTU challenge 2027 specification.  ')
    hprtu_scenario.setDefaultValue('two_speed_standard_eff')
    args << hprtu_scenario

    # energy recovery
    hr = OpenStudio::Measure::OSArgument.makeBoolArgument('hr', true)
    hr.setDisplayName('Add Energy Recovery?')
    hr.setDefaultValue(false)
    args << hr

    # demand control ventilation
    dcv = OpenStudio::Measure::OSArgument.makeBoolArgument('dcv', true)
    dcv.setDisplayName('Add Demand Control Ventilation?')
    dcv.setDefaultValue(false)
    args << dcv

    # economizer
    econ = OpenStudio::Measure::OSArgument.makeBoolArgument('econ', true)
    econ.setDisplayName('Add Economizer?')
    econ.setDefaultValue(false)
    args << econ

    # roof insulation upgrade
    roof = OpenStudio::Measure::OSArgument.makeBoolArgument('roof', true)
    roof.setDisplayName('Upgrade Roof Insulation?')
    roof.setDescription('Upgrade roof insulation per AEDG recommendations.')
    roof.setDefaultValue(false)
    args << roof

    # window upgrade
    window = OpenStudio::Measure::OSArgument.makeBoolArgument('window', true)
    window.setDisplayName('Upgrade Windows?')
    window.setDescription('Upgrade window per AEDG recommendations.')
    window.setDefaultValue(false)
    args << window

    # sizing run
    sizing_run = OpenStudio::Measure::OSArgument.makeBoolArgument('sizing_run', true)
    sizing_run.setDisplayName('Do a sizing run for informing sizing instead of using hard-sized model parameters?')
    sizing_run.setDefaultValue(false)
    args << sizing_run

    # debugging logs
    debug_verbose = OpenStudio::Measure::OSArgument.makeBoolArgument('debug_verbose', true)
    debug_verbose.setDisplayName('Print out detailed debugging logs if this parameter is true')
    debug_verbose.setDefaultValue(false)
    args << debug_verbose

    # heating setback modification
    modify_setbacks = OpenStudio::Measure::OSArgument.makeBoolArgument('modify_setbacks', false)
    modify_setbacks.setDisplayName('Modify setbacks in heating mode? True will adjust setbacks, according to value in setback value argument.')
    modify_setbacks.setDefaultValue(true)
    args << modify_setbacks

    # heating setback value
    setback_value = OpenStudio::Measure::OSArgument.makeDoubleArgument('setback_value', false)
    setback_value.setDisplayName('Amount in deg F by which temperatures are set back during unoccupied periods in heating mode. Done only if modify setbacks is set to true.')
    setback_value.setDefaultValue(2)
    args << setback_value

    args
  end

  # define the outputs that the measure will create
  def outputs
    OpenStudio::Measure::OSOutputVector.new
  end

  # ---------------------------------------------------------
  # applicability helpers
  # ---------------------------------------------------------

  # determine if a name contains any of the given words
  def name_matches_any?(name, words)
    words.any? { |word| name.include?(word) }
  end

  # determine if any supply component of the air loop is one of the given object types
  def air_loop_has_supply_component_type?(air_loop_hvac, object_types)
    air_loop_hvac.supplyComponents.any? { |component| object_types.include?(component.iddObjectType.valueName.to_s) }
  end

  # determine if the air loop is residential, meaning it has no outdoor air system
  def air_loop_res?(air_loop_hvac)
    !air_loop_has_supply_component_type?(air_loop_hvac, ['OS_AirLoopHVAC_OutdoorAirSystem'])
  end

  # determine if the air loop has an evaporative cooler
  def air_loop_evaporative_cooler?(air_loop_hvac)
    air_loop_has_supply_component_type?(air_loop_hvac, EVAPORATIVE_COOLER_TYPES)
  end

  # determine if the air loop has a unitary system
  def air_loop_hvac_unitary_system?(air_loop_hvac)
    air_loop_has_supply_component_type?(air_loop_hvac, UNITARY_SYSTEM_TYPES)
  end

  # ---------------------------------------------------------
  # performance data helpers
  # ---------------------------------------------------------

  # set independent variable and output limits on a curve from a json record
  # y limits are only set for curves with two independent variables
  def set_curve_limits(curve, data, two_variables: false)
    curve.setMinimumValueofx(data['minimum_independent_variable_1']) if data['minimum_independent_variable_1']
    curve.setMaximumValueofx(data['maximum_independent_variable_1']) if data['maximum_independent_variable_1']
    if two_variables
      curve.setMinimumValueofy(data['minimum_independent_variable_2']) if data['minimum_independent_variable_2']
      curve.setMaximumValueofy(data['maximum_independent_variable_2']) if data['maximum_independent_variable_2']
    end
    curve.setMinimumCurveOutput(data['minimum_dependent_variable_output']) if data['minimum_dependent_variable_output']
    curve.setMaximumCurveOutput(data['maximum_dependent_variable_output']) if data['maximum_dependent_variable_output']
  end

  # load a curve into the model from a json record, or return the existing curve of the same name
  # modified version of the OS Standards method to read from a custom json file
  def model_add_curve(model, curve_name, standards_data_curve, std)
    # return the curve if it already exists in the model
    existing_curves = []
    existing_curves += model.getCurveLinears
    existing_curves += model.getCurveCubics
    existing_curves += model.getCurveQuadratics
    existing_curves += model.getCurveBicubics
    existing_curves += model.getCurveBiquadratics
    existing_curves += model.getCurveQuadLinears
    existing_curve = existing_curves.sort.find { |curve| curve.name.get.to_s == curve_name }
    return existing_curve unless existing_curve.nil?

    # find curve data
    data = std.model_find_object(standards_data_curve['tables']['curves'], 'name' => curve_name)
    return nil if data.nil?

    # make the correct type of curve
    curve =
      case data['form']
      when 'Linear'
        curve = OpenStudio::Model::CurveLinear.new(model)
        curve.setCoefficient1Constant(data['coeff_1'])
        curve.setCoefficient2x(data['coeff_2'])
        set_curve_limits(curve, data)
        curve
      when 'Cubic'
        curve = OpenStudio::Model::CurveCubic.new(model)
        curve.setCoefficient1Constant(data['coeff_1'])
        curve.setCoefficient2x(data['coeff_2'])
        curve.setCoefficient3xPOW2(data['coeff_3'])
        curve.setCoefficient4xPOW3(data['coeff_4'])
        set_curve_limits(curve, data)
        curve
      when 'Quadratic'
        curve = OpenStudio::Model::CurveQuadratic.new(model)
        curve.setCoefficient1Constant(data['coeff_1'])
        curve.setCoefficient2x(data['coeff_2'])
        curve.setCoefficient3xPOW2(data['coeff_3'])
        set_curve_limits(curve, data)
        curve
      when 'BiCubic'
        curve = OpenStudio::Model::CurveBicubic.new(model)
        curve.setCoefficient1Constant(data['coeff_1'])
        curve.setCoefficient2x(data['coeff_2'])
        curve.setCoefficient3xPOW2(data['coeff_3'])
        curve.setCoefficient4y(data['coeff_4'])
        curve.setCoefficient5yPOW2(data['coeff_5'])
        curve.setCoefficient6xTIMESY(data['coeff_6'])
        curve.setCoefficient7xPOW3(data['coeff_7'])
        curve.setCoefficient8yPOW3(data['coeff_8'])
        curve.setCoefficient9xPOW2TIMESY(data['coeff_9'])
        curve.setCoefficient10xTIMESYPOW2(data['coeff_10'])
        set_curve_limits(curve, data, two_variables: true)
        curve
      when 'BiQuadratic'
        curve = OpenStudio::Model::CurveBiquadratic.new(model)
        curve.setCoefficient1Constant(data['coeff_1'])
        curve.setCoefficient2x(data['coeff_2'])
        curve.setCoefficient3xPOW2(data['coeff_3'])
        curve.setCoefficient4y(data['coeff_4'])
        curve.setCoefficient5yPOW2(data['coeff_5'])
        curve.setCoefficient6xTIMESY(data['coeff_6'])
        set_curve_limits(curve, data, two_variables: true)
        curve
      when 'BiLinear'
        curve = OpenStudio::Model::CurveBiquadratic.new(model)
        curve.setCoefficient1Constant(data['coeff_1'])
        curve.setCoefficient2x(data['coeff_2'])
        curve.setCoefficient4y(data['coeff_3'])
        set_curve_limits(curve, data, two_variables: true)
        curve
      when 'QuadLinear'
        curve = OpenStudio::Model::CurveQuadLinear.new(model)
        curve.setCoefficient1Constant(data['coeff_1'])
        curve.setCoefficient2w(data['coeff_2'])
        curve.setCoefficient3x(data['coeff_3'])
        curve.setCoefficient4y(data['coeff_4'])
        curve.setCoefficient5z(data['coeff_5'])
        curve.setMinimumValueofw(data['minimum_independent_variable_w'])
        curve.setMaximumValueofw(data['maximum_independent_variable_w'])
        curve.setMinimumValueofx(data['minimum_independent_variable_x'])
        curve.setMaximumValueofx(data['maximum_independent_variable_x'])
        curve.setMinimumValueofy(data['minimum_independent_variable_y'])
        curve.setMaximumValueofy(data['maximum_independent_variable_y'])
        curve.setMinimumValueofz(data['minimum_independent_variable_z'])
        curve.setMaximumValueofz(data['maximum_independent_variable_z'])
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
        curve
      when 'MultiVariableLookupTable'
        num_ind_var = data['number_independent_variables'].to_i
        table = OpenStudio::Model::TableLookup.new(model)
        table.setNormalizationDivisor(data['normalization_reference'].to_f)
        table.setOutputUnitType(data['output_unit_type'])
        # data points are sorted in ascending order of the independent variables
        data_points = data.each.select { |key, _value| key.include? 'data_point' }
        data_points = data_points.sort_by { |item| item[1].split(',').map(&:to_f) }
        data_points.each do |_key, value|
          var_dep = value.split(',')[num_ind_var].to_f
          table.addOutputValue(var_dep)
        end
        num_ind_var.times do |i|
          table_indvar = OpenStudio::Model::TableIndependentVariable.new(model)
          table_indvar.setName(data['name'] + "_ind_#{i + 1}")
          table_indvar.setInterpolationMethod(data['interpolation_method'])
          table_indvar.setMinimumValue(data["minimum_independent_variable_#{i + 1}"].to_f)
          table_indvar.setMaximumValue(data["maximum_independent_variable_#{i + 1}"].to_f)
          table_indvar.setUnitType(data["input_unit_type_x#{i + 1}"].to_s)
          var_ind_unique = data_points.map { |_key, value| value.split(',')[i].to_f }.uniq
          var_ind_unique.each { |var_ind| table_indvar.addValue(var_ind) }
          table.addIndependentVariable(table_indvar)
        end
        table
      end
    curve&.setName(data['name'])
    curve
  end

  # build a stage => curve hash from a list of curve names, where the first name is stage 1
  def stage_curves(model, curve_names, custom_data_json, std)
    curve_names.each_with_index.to_h { |curve_name, i| [i + 1, model_add_curve(model, curve_name, custom_data_json, std)] }
  end

  # read staging data from the scenario's performance json
  # @return [Hash] staging data with stage hashes parsed from their string form, or nil if absent
  def assign_staging_data(staging_data_json, std)
    staging_data = std.model_find_object(staging_data_json['tables']['curves'], 'name' => 'staging_data')
    return nil if staging_data.nil?

    {
      num_heating_stages: staging_data['num_heating_stages'],
      num_cooling_stages: staging_data['num_cooling_stages'],
      rated_stage_num_heating: staging_data['rated_stage_num_heating'],
      rated_stage_num_cooling: staging_data['rated_stage_num_cooling'],
      final_rated_cooling_cop: staging_data['final_rated_cooling_cop'],
      final_rated_heating_cop: staging_data['final_rated_heating_cop'],
      stage_cap_fractions_heating: eval(staging_data['stage_cap_fractions_heating']),
      stage_flow_fractions_heating: eval(staging_data['stage_flow_fractions_heating']),
      stage_cap_fractions_cooling: eval(staging_data['stage_cap_fractions_cooling']),
      stage_flow_fractions_cooling: eval(staging_data['stage_flow_fractions_cooling']),
      stage_rated_cop_frac_heating: eval(staging_data['stage_rated_cop_frac_heating']),
      stage_rated_cop_frac_cooling: eval(staging_data['stage_rated_cop_frac_cooling']),
      boost_stage_num_and_max_temp_tuple: eval(staging_data['boost_stage_num_and_max_temp_tuple']),
      stage_gross_rated_sensible_heat_ratio_cooling: eval(staging_data['stage_gross_rated_sensible_heat_ratio_cooling']),
      enable_cycling_losses_above_lowest_speed: staging_data['enable_cycling_losses_above_lowest_speed'],
      reference_cooling_cfm_per_ton: staging_data['reference_cooling_cfm_per_ton'],
      # TODO: this reads the cooling key; confirm whether reference_heating_cfm_per_ton in the json was intended
      reference_heating_cfm_per_ton: staging_data['reference_cooling_cfm_per_ton']
    }
  end

  # read supply fan data from the scenario's performance json
  # the fan curve and impeller efficiency live alongside the compressor data so that defining a scenario
  # and defining its fan are the same action; fan_type selects behaviour and stays a discriminator here
  # @return [Array] fan type, power coefficients, impeller efficiency; nils if absent
  def assign_fan_data(fan_data_json, std)
    fan_data = std.model_find_object(fan_data_json['tables']['curves'], 'name' => 'fan_data')
    return [nil, nil, nil] if fan_data.nil?

    [fan_data['fan_type'], fan_data['fan_power_coefficients'], fan_data['impeller_efficiency']]
  end

  # ---------------------------------------------------------
  # sizing and performance helpers
  # ---------------------------------------------------------

  # rated COP from a fitted regression on rated capacity
  def rated_cop_from_regression(rated_capacity_w, regression)
    rated_capacity_kw = rated_capacity_w / 1000 # W to kW
    rated_cop = regression[:intercept] + (regression[:slope] * rated_capacity_kw)
    rated_cop.clamp(regression[:min], regression[:max])
  end

  # rated cooling COP from fitted regression
  def get_rated_cop_cooling(rated_capacity_w)
    rated_cop_from_regression(rated_capacity_w, RATED_COP_REGRESSIONS[:cooling])
  end

  # rated heating COP from fitted regression
  def get_rated_cop_heating(rated_capacity_w)
    rated_cop_from_regression(rated_capacity_w, RATED_COP_REGRESSIONS[:heating])
  end

  # convert cfm/ton to m3/s per W
  def cfm_per_ton_to_m_3_per_sec_watts(cfm_per_ton)
    OpenStudio.convert(OpenStudio.convert(cfm_per_ton, 'cfm', 'm^3/s').get, 'W', 'ton').get
  end

  # convert m3/s per W to cfm/ton
  def m_3_per_sec_watts_to_cfm_per_ton(m_3_per_sec_watts)
    OpenStudio.convert(OpenStudio.convert(m_3_per_sec_watts, 'm^3/s', 'cfm').get, 'ton', 'W').get
  end

  # crankcase heater power, W, from rated capacity, W (converted to tons)
  # methods from "TECHNICAL SUPPORT DOCUMENT: ENERGY EFFICIENCY PROGRAM FOR CONSUMER PRODUCTS AND COMMERCIAL AND INDUSTRIAL EQUIPMENT AIR-COOLED COMMERCIAL UNITARY AIR CONDITIONERS AND COMMERCIAL UNITARY HEAT PUMPS"
  def crankcase_heater_power_w(rated_capacity_w)
    60 * ((rated_capacity_w * 0.0002843451 / 10)**0.67)
  end

  # adjust rated COP from the reference cfm/ton to the sized cfm/ton using the EIR flow fraction curve
  def adjust_rated_cop_from_ref_cfm_per_ton(runner, airflow_sized_m_3_per_s, reference_cfm_per_ton, rated_capacity_w,
                                            original_rated_cop, eir_modifier_curve_flow)
    airflow_reference_m_3_per_s = cfm_per_ton_to_m_3_per_sec_watts(reference_cfm_per_ton) * rated_capacity_w
    flow_fraction = airflow_sized_m_3_per_s / airflow_reference_m_3_per_s

    modifier_eir = nil
    if eir_modifier_curve_flow.to_CurveBiquadratic.is_initialized
      modifier_eir = eir_modifier_curve_flow.evaluate(flow_fraction, 0)
    elsif eir_modifier_curve_flow.to_CurveCubic.is_initialized || eir_modifier_curve_flow.to_CurveQuadratic.is_initialized
      modifier_eir = eir_modifier_curve_flow.evaluate(flow_fraction)
    else
      runner.registerError("CurveBiquadratic|CurveQuadratic|CurveCubic are only supported at the moment for modifier_eir (function of flow fraction) calculation: eir_modifier_curve_flow = #{eir_modifier_curve_flow.name}")
    end

    # COP = 1 / EIR
    original_rated_cop * (1.0 / modifier_eir)
  end

  # adjust stage airflows and capacities to keep each stage within the rated cfm/ton limits
  # the rated stage is left as-is; lower stages are adjusted in order of preference:
  #   - flow/ton too low: increase stage airflow to the minimum
  #   - flow/ton too high: reduce stage airflow if the minimum airflow ratio allows, otherwise increase the
  #     stage capacity up to 65% of the range to the next stage, otherwise remove the stage (set to false)
  # the stage hashes are modified in place and returned
  def adjust_cfm_per_ton_per_limits(stage_cap_fractions, stage_flows, stage_flow_fractions, dx_rated_cap_applied,
                                    rated_stage_num, old_terminal_sa_flow_m3_per_s, min_airflow_ratio, air_loop_hvac, heating_or_cooling, runner, debug_verbose)
    m_3_per_s_per_w_min = cfm_per_ton_to_m_3_per_sec_watts(CFM_PER_TON_MIN_RATED)
    m_3_per_s_per_w_max = cfm_per_ton_to_m_3_per_sec_watts(CFM_PER_TON_MAX_RATED)

    stage_caps = {}
    stage_cap_fractions.sort.each do |stage, ratio|
      airflow = stage_flows[stage]
      stage_capacity = dx_rated_cap_applied * ratio
      flow_per_ton = airflow / stage_capacity

      if debug_verbose
        runner.registerInfo('stage summary: ---------------------------------------------------------------')
        runner.registerInfo("stage summary: air_loop_hvac: #{air_loop_hvac.name}")
        runner.registerInfo("stage summary: #{heating_or_cooling} Stage #{stage}")
        runner.registerInfo("stage summary: min_airflow_ratio: #{min_airflow_ratio}")
        runner.registerInfo("stage summary: airflow: #{airflow}")
        runner.registerInfo("stage summary: stage_capacity: #{stage_capacity}")
        runner.registerInfo("stage summary: flow_per_ton: #{flow_per_ton}")
        runner.registerInfo("stage summary: m_3_per_s_per_w_max: #{m_3_per_s_per_w_max.round(8)}")
        runner.registerInfo("stage summary: In Bounds: #{(flow_per_ton.round(8) >= m_3_per_s_per_w_min.round(8)) && (flow_per_ton.round(8) <= m_3_per_s_per_w_max.round(8))}")
      end

      if (flow_per_ton.round(8) < m_3_per_s_per_w_min.round(8)) && (stage < rated_stage_num)
        # flow/ton below minimum: increase the stage airflow to meet the minimum
        new_stage_airflow = m_3_per_s_per_w_min * stage_capacity
        stage_flows[stage] = new_stage_airflow
        stage_flow_fractions[stage] = new_stage_airflow / old_terminal_sa_flow_m3_per_s # TODO: check if airflow can exceed design airflow; if so, adjust min OA
        stage_caps[stage] = stage_capacity
        if debug_verbose
          runner.registerInfo('stage summary: entered flow/ton too low loop....')
          runner.registerInfo("stage summary: #{air_loop_hvac.name} | cfm/ton low limit violation | #{heating_or_cooling} | stage = #{stage} | cfm/ton after adjustment = #{m_3_per_sec_watts_to_cfm_per_ton(stage_flows[stage] / stage_caps[stage])}")
        end
      elsif (flow_per_ton.round(8) > m_3_per_s_per_w_max.round(8)) && (stage < rated_stage_num)
        # flow/ton above maximum
        if debug_verbose
          runner.registerInfo('stage summary: entered flow/ton too high loop....')
          runner.registerInfo("stage summary: air_loop_hvac: #{air_loop_hvac.name}")
          runner.registerInfo("stage summary: ratio: #{ratio}")
          runner.registerInfo("stage summary: stage: #{stage}")
          runner.registerInfo("stage summary: stage_cap_fractions: #{stage_cap_fractions}")
          runner.registerInfo("stage summary: dx_rated_cap_applied: #{dx_rated_cap_applied}")
        end

        # capacity ratio allowance: up to 65% of the range to the next stage (variable name is historical)
        ratio_allowance_50_pct = ratio + ((stage_cap_fractions[stage + 1] - ratio) * 0.65)
        required_stage_cap_ratio = airflow / m_3_per_s_per_w_max / (stage_cap_fractions[rated_stage_num] * dx_rated_cap_applied)
        stage_airflow_limit_max = m_3_per_s_per_w_max * stage_capacity
        if (stage_airflow_limit_max / old_terminal_sa_flow_m3_per_s) >= min_airflow_ratio
          # reduce the stage airflow without violating the minimum airflow ratio
          stage_flows[stage] = stage_airflow_limit_max
          stage_flow_fractions[stage] = stage_airflow_limit_max / old_terminal_sa_flow_m3_per_s
          stage_caps[stage] = stage_capacity
          if debug_verbose
            runner.registerInfo("stage summary: #{air_loop_hvac.name} | cfm/ton high limit violation | #{heating_or_cooling} | stage = #{stage} | cfm/ton after adjustment = #{m_3_per_sec_watts_to_cfm_per_ton(stage_flows[stage] / stage_caps[stage])}")
          end
        elsif required_stage_cap_ratio <= ratio_allowance_50_pct
          # increase the stage capacity to the required ratio, which is within the allowance
          stage_cap_fractions[stage] = required_stage_cap_ratio
          stage_caps[stage] = required_stage_cap_ratio * (stage_cap_fractions[rated_stage_num] * dx_rated_cap_applied)
          if debug_verbose
            runner.registerInfo("stage summary: #{air_loop_hvac.name} | cfm/ton high limit violation (ratio_allowance_50_pct) | #{heating_or_cooling} | stage = #{stage} | cfm/ton after adjustment = #{m_3_per_sec_watts_to_cfm_per_ton(stage_flows[stage] / stage_caps[stage])}")
          end
        elsif stage == (rated_stage_num - 1)
          # at least 2 stages are needed; apply the allowance and accept being somewhat out of range
          stage_cap_fractions[stage] = ratio_allowance_50_pct
          stage_caps[stage] = ratio_allowance_50_pct * (stage_cap_fractions[rated_stage_num] * dx_rated_cap_applied)
          if debug_verbose
            runner.registerInfo("stage summary: #{air_loop_hvac.name} | cfm/ton high limit violation (rated_stage_num) | #{heating_or_cooling} | stage = #{stage} | cfm/ton after adjustment = #{m_3_per_sec_watts_to_cfm_per_ton(stage_flows[stage] / stage_caps[stage])}")
          end
        else
          # remove the stage
          runner.registerInfo('stage summary: stage removed') if debug_verbose
          stage_flows[stage] = false
          stage_flow_fractions[stage] = false
          stage_caps[stage] = false
          stage_cap_fractions[stage] = false
          if debug_verbose
            runner.registerInfo("stage summary: #{air_loop_hvac.name} | cfm/ton high limit violation (removing stage) | #{heating_or_cooling} | stage = #{stage} | cfm/ton after adjustment = n/a")
          end
        end
      else
        # within limits; no adjustment
        stage_caps[stage] = stage_capacity
        if debug_verbose
          runner.registerInfo('stage summary: entered no adjustment loop')
          runner.registerInfo("stage summary: #{air_loop_hvac.name} | no cfm/ton violation | #{heating_or_cooling} | stage = #{stage} | cfm/ton = #{m_3_per_sec_watts_to_cfm_per_ton(stage_flows[stage] / stage_caps[stage])}")
        end
      end
    end

    num_stages = stage_caps.length

    [stage_flows, stage_caps, stage_flow_fractions, stage_cap_fractions, num_stages]
  end

  # create the DX cooling coil; single speed for 1 stage, otherwise multispeed
  def set_cooling_coil_stages(model, runner, stage_flows_cooling, stage_caps_cooling, num_cooling_stages, final_rated_cooling_cop, cool_cap_ft_curve_stages, cool_eir_ft_curve_stages,
                              cool_cap_ff_curve_stages, cool_eir_ff_curve_stages, cool_plf_fplr1, stage_rated_cop_frac_cooling, stage_gross_rated_sensible_heat_ratio_cooling,
                              rated_stage_num_cooling, enable_cycling_losses_above_lowest_speed, air_loop_hvac, always_on, debug_verbose)
    # validate number of stages
    if stage_flows_cooling.values.count(&:itself) == stage_caps_cooling.values.count(&:itself)
      num_cooling_stages = stage_flows_cooling.values.count(&:itself)
      if debug_verbose
        runner.registerInfo("stage summary: The final number of cooling stages for #{air_loop_hvac.name} is #{num_cooling_stages}.")
      end
    else
      runner.registerError("For airloop #{air_loop_hvac.name}, the number of stages of cooling capacity is different from number of stages of cooling airflow. Revise measure as needed.")
    end

    crankcase_heater_power = crankcase_heater_power_w(stage_caps_cooling[rated_stage_num_cooling])

    if num_cooling_stages == 1
      new_dx_cooling_coil = OpenStudio::Model::CoilCoolingDXSingleSpeed.new(model)
      new_dx_cooling_coil.setName("#{air_loop_hvac.name} Heat Pump Cooling Coil")
      new_dx_cooling_coil.setAvailabilitySchedule(always_on)
      new_dx_cooling_coil.setCondenserType('AirCooled')
      new_dx_cooling_coil.setRatedCOP(final_rated_cooling_cop * stage_rated_cop_frac_cooling[rated_stage_num_cooling])
      new_dx_cooling_coil.setRatedTotalCoolingCapacity(stage_caps_cooling[rated_stage_num_cooling])
      new_dx_cooling_coil.setGrossRatedSensibleHeatRatio(stage_gross_rated_sensible_heat_ratio_cooling[rated_stage_num_cooling])
      new_dx_cooling_coil.setRatedAirFlowRate(stage_flows_cooling[rated_stage_num_cooling])
      new_dx_cooling_coil.setRatedEvaporatorFanPowerPerVolumeFlowRate2017(773.3)
      new_dx_cooling_coil.setTotalCoolingCapacityFunctionOfTemperatureCurve(cool_cap_ft_curve_stages[rated_stage_num_cooling])
      new_dx_cooling_coil.setTotalCoolingCapacityFunctionOfFlowFractionCurve(cool_cap_ff_curve_stages[rated_stage_num_cooling])
      new_dx_cooling_coil.setEnergyInputRatioFunctionOfTemperatureCurve(cool_eir_ft_curve_stages[rated_stage_num_cooling])
      new_dx_cooling_coil.setEnergyInputRatioFunctionOfFlowFractionCurve(cool_eir_ff_curve_stages[rated_stage_num_cooling])
      new_dx_cooling_coil.setPartLoadFractionCorrelationCurve(cool_plf_fplr1)
      new_dx_cooling_coil.setEvaporativeCondenserEffectiveness(0.9)
      new_dx_cooling_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(4.4)
      new_dx_cooling_coil.setNominalTimeforCondensateRemovaltoBegin(1000)
      new_dx_cooling_coil.setRatioofInitialMoistureEvaporationRateandSteadyStateLatentCapacity(1.5)
      new_dx_cooling_coil.setLatentCapacityTimeConstant(45)
      new_dx_cooling_coil.setCrankcaseHeaterCapacity(crankcase_heater_power)
      new_dx_cooling_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(-25)
    else
      new_dx_cooling_coil = OpenStudio::Model::CoilCoolingDXMultiSpeed.new(model)
      new_dx_cooling_coil.setName("#{air_loop_hvac.name} Heat Pump Cooling Coil")
      new_dx_cooling_coil.setCondenserType('AirCooled')
      new_dx_cooling_coil.setAvailabilitySchedule(always_on)
      new_dx_cooling_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(-25)
      new_dx_cooling_coil.setApplyPartLoadFractiontoSpeedsGreaterthan1(enable_cycling_losses_above_lowest_speed)
      new_dx_cooling_coil.setApplyLatentDegradationtoSpeedsGreaterthan1(false)
      new_dx_cooling_coil.setFuelType('Electricity')
      new_dx_cooling_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(4.4)
      new_dx_cooling_coil.setCrankcaseHeaterCapacity(crankcase_heater_power)

      stage_caps_cooling.sort.each do |stage, cap|
        # use the current stage if allowed; otherwise use the lowest available stage as a "dummy"
        # this is a temporary workaround until the OS translator supports different numbers of speed levels between heating and cooling
        # GitHub issue: https://github.com/NREL/OpenStudio/issues/5277
        applied_stage = stage
        applied_stage = stage_caps_cooling.reject { |_k, v| v == false }.keys.min if cap == false

        dx_coil_speed_data = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
        dx_coil_speed_data.setGrossRatedTotalCoolingCapacity(stage_caps_cooling[applied_stage])
        dx_coil_speed_data.setGrossRatedSensibleHeatRatio(stage_gross_rated_sensible_heat_ratio_cooling[applied_stage])
        dx_coil_speed_data.setRatedAirFlowRate(stage_flows_cooling[applied_stage])
        dx_coil_speed_data.setGrossRatedCoolingCOP(final_rated_cooling_cop * stage_rated_cop_frac_cooling[applied_stage])
        dx_coil_speed_data.setRatedEvaporatorFanPowerPerVolumeFlowRate2017(773.3)
        dx_coil_speed_data.setTotalCoolingCapacityFunctionofTemperatureCurve(cool_cap_ft_curve_stages[applied_stage])
        dx_coil_speed_data.setTotalCoolingCapacityFunctionofFlowFractionCurve(cool_cap_ff_curve_stages[applied_stage])
        dx_coil_speed_data.setEnergyInputRatioFunctionofTemperatureCurve(cool_eir_ft_curve_stages[applied_stage])
        dx_coil_speed_data.setEnergyInputRatioFunctionofFlowFractionCurve(cool_eir_ff_curve_stages[applied_stage])
        dx_coil_speed_data.setPartLoadFractionCorrelationCurve(cool_plf_fplr1)
        dx_coil_speed_data.setEvaporativeCondenserEffectiveness(0.9)
        dx_coil_speed_data.setNominalTimeforCondensateRemovaltoBegin(1000)
        dx_coil_speed_data.setRatioofInitialMoistureEvaporationRateandSteadyStateLatentCapacity(1.5)
        dx_coil_speed_data.setLatentCapacityTimeConstant(45)
        dx_coil_speed_data.autosizeEvaporativeCondenserAirFlowRate
        dx_coil_speed_data.autosizeRatedEvaporativeCondenserPumpPowerConsumption
        new_dx_cooling_coil.addStage(dx_coil_speed_data)
      end
    end
    new_dx_cooling_coil
  end

  # create the DX heating coil; single speed for 1 stage, otherwise multispeed
  def set_heating_coil_stages(model, runner, stage_flows_heating, stage_caps_heating, num_heating_stages, final_rated_heating_cop, heat_cap_ft_curve_stages, heat_eir_ft_curve_stages,
                              heat_cap_ff_curve_stages, heat_eir_ff_curve_stages, heat_plf_fplr1, defrost_eir, stage_rated_cop_frac_heating, rated_stage_num_heating, air_loop_hvac, hp_min_comp_lockout_temp_f,
                              enable_cycling_losses_above_lowest_speed, always_on, debug_verbose)
    # validate number of stages
    if stage_flows_heating.values.count(&:itself) == stage_caps_heating.values.count(&:itself)
      num_heating_stages = stage_flows_heating.values.count(&:itself)
      if debug_verbose
        runner.registerInfo("stage summary: num_heating_stages: #{num_heating_stages}")
        runner.registerInfo("stage summary: The final number of heating stages for #{air_loop_hvac.name} is #{num_heating_stages}.")
      end
    else
      runner.registerError("For airloop #{air_loop_hvac.name}, the number of stages of heating capacity is different from number of stages of heating airflow. Revise measure as needed.")
    end

    hp_min_comp_lockout_temp_c = OpenStudio.convert(hp_min_comp_lockout_temp_f, 'F', 'C').get
    crankcase_heater_power = crankcase_heater_power_w(stage_caps_heating[rated_stage_num_heating])

    if num_heating_stages == 1
      new_dx_heating_coil = OpenStudio::Model::CoilHeatingDXSingleSpeed.new(model)
      new_dx_heating_coil.setName("#{air_loop_hvac.name} Heat Pump heating Coil")
      new_dx_heating_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(hp_min_comp_lockout_temp_c)
      new_dx_heating_coil.setAvailabilitySchedule(always_on)
      new_dx_heating_coil.setRatedTotalHeatingCapacity(stage_caps_heating[rated_stage_num_heating])
      new_dx_heating_coil.setRatedAirFlowRate(stage_flows_heating[rated_stage_num_heating])
      new_dx_heating_coil.setRatedCOP(final_rated_heating_cop)
      new_dx_heating_coil.setRatedSupplyFanPowerPerVolumeFlowRate2017(773.3)
      new_dx_heating_coil.setTotalHeatingCapacityFunctionofTemperatureCurve(heat_cap_ft_curve_stages[rated_stage_num_heating])
      new_dx_heating_coil.setTotalHeatingCapacityFunctionofFlowFractionCurve(heat_cap_ff_curve_stages[rated_stage_num_heating])
      new_dx_heating_coil.setEnergyInputRatioFunctionofTemperatureCurve(heat_eir_ft_curve_stages[rated_stage_num_heating])
      new_dx_heating_coil.setEnergyInputRatioFunctionofFlowFractionCurve(heat_eir_ff_curve_stages[rated_stage_num_heating])
      new_dx_heating_coil.setPartLoadFractionCorrelationCurve(heat_plf_fplr1)
      new_dx_heating_coil.setCrankcaseHeaterCapacity(crankcase_heater_power)
      new_dx_heating_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(4.4)
      new_dx_heating_coil.setDefrostEnergyInputRatioFunctionofTemperatureCurve(defrost_eir)
      new_dx_heating_coil.setMaximumOutdoorDryBulbTemperatureforDefrostOperation(4.444)
      new_dx_heating_coil.setDefrostStrategy('ReverseCycle')
      new_dx_heating_coil.setDefrostControl('OnDemand')
      new_dx_heating_coil.setDefrostTimePeriodFraction(0.058333)
    else
      new_dx_heating_coil = OpenStudio::Model::CoilHeatingDXMultiSpeed.new(model)
      new_dx_heating_coil.setName("#{air_loop_hvac.name} Heat Pump heating Coil")
      new_dx_heating_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(hp_min_comp_lockout_temp_c)
      new_dx_heating_coil.setAvailabilitySchedule(always_on)
      new_dx_heating_coil.setApplyPartLoadFractiontoSpeedsGreaterthan1(enable_cycling_losses_above_lowest_speed)
      new_dx_heating_coil.setFuelType('Electricity')
      new_dx_heating_coil.setCrankcaseHeaterCapacity(crankcase_heater_power)
      new_dx_heating_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(4.4)
      new_dx_heating_coil.setDefrostEnergyInputRatioFunctionofTemperatureCurve(defrost_eir)
      new_dx_heating_coil.setMaximumOutdoorDryBulbTemperatureforDefrostOperation(4.444)
      new_dx_heating_coil.setDefrostStrategy('ReverseCycle')
      new_dx_heating_coil.setDefrostControl('OnDemand')
      new_dx_heating_coil.setDefrostTimePeriodFraction(0.058333)

      stage_caps_heating.sort.each do |stage, cap|
        # use the current stage if allowed; otherwise use the lowest available stage as a "dummy"
        # this is a temporary workaround until the OS translator supports different numbers of speed levels between heating and cooling
        # GitHub issue: https://github.com/NREL/OpenStudio/issues/5277
        applied_stage = stage
        applied_stage = stage_caps_heating.reject { |_k, v| v == false }.keys.min if cap == false

        dx_coil_speed_data = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
        dx_coil_speed_data.setGrossRatedHeatingCapacity(stage_caps_heating[applied_stage])
        dx_coil_speed_data.setGrossRatedHeatingCOP(final_rated_heating_cop * stage_rated_cop_frac_heating[applied_stage])
        dx_coil_speed_data.setRatedAirFlowRate(stage_flows_heating[applied_stage])
        dx_coil_speed_data.setRatedSupplyAirFanPowerPerVolumeFlowRate2017(773.3)
        dx_coil_speed_data.setHeatingCapacityFunctionofTemperatureCurve(heat_cap_ft_curve_stages[applied_stage])
        dx_coil_speed_data.setHeatingCapacityFunctionofFlowFractionCurve(heat_cap_ff_curve_stages[applied_stage])
        dx_coil_speed_data.setEnergyInputRatioFunctionofTemperatureCurve(heat_eir_ft_curve_stages[applied_stage])
        dx_coil_speed_data.setEnergyInputRatioFunctionofFlowFractionCurve(heat_eir_ff_curve_stages[applied_stage])
        dx_coil_speed_data.setPartLoadFractionCorrelationCurve(heat_plf_fplr1)
        new_dx_heating_coil.addStage(dx_coil_speed_data)
      end
    end
    new_dx_heating_coil
  end

  # get a value from the tabular data in the sql file
  def get_tabular_data(runner, sql, report_name, report_for_string, table_name, row_name, column_name)
    result = OpenStudio::OptionalDouble.new
    var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = '#{report_name}' AND ReportForString = '#{report_for_string}' AND TableName = '#{table_name}' AND RowName = '#{row_name}' AND ColumnName = '#{column_name}'"
    val = sql.execAndReturnFirstDouble(var_val_query)
    if val.is_initialized
      result = OpenStudio::OptionalDouble.new(val.get)
    else
      runner.registerError("Cannot query: #{report_name} | #{report_for_string} | #{table_name} | #{row_name} | #{column_name}")
    end
    result
  end

  # bilinear interpolation of a two-variable TableLookup; inputs are clamped to the table bounds
  # @return [Double, false] interpolated value, or false if the table is not two-dimensional or is malformed
  def self.get_dep_var_from_lookup_table_with_interpolation(runner, lookup_table, input1, input2)
    unless lookup_table.independentVariables.size == 2
      runner.registerError('TableLookup object does not have exactly two independent variables.')
      return false
    end

    ind_var_1 = lookup_table.independentVariables[0].values.to_a
    ind_var_2 = lookup_table.independentVariables[1].values.to_a
    dep_var = lookup_table.outputValues.to_a

    if ind_var_1.size * ind_var_2.size != dep_var.size
      runner.registerError("Table dimensions do not match output size for TableLookup object: #{lookup_table.name}")
      return false
    end

    # clamp inputs to bounds
    if input1 < ind_var_1.first
      runner.registerWarning("input1 (#{input1}) below range, clamping to #{ind_var_1.first}")
      input1 = ind_var_1.first
    elsif input1 > ind_var_1.last
      runner.registerWarning("input1 (#{input1}) above range, clamping to #{ind_var_1.last}")
      input1 = ind_var_1.last
    end
    if input2 < ind_var_2.first
      runner.registerWarning("input2 (#{input2}) below range, clamping to #{ind_var_2.first}")
      input2 = ind_var_2.first
    elsif input2 > ind_var_2.last
      runner.registerWarning("input2 (#{input2}) above range, clamping to #{ind_var_2.last}")
      input2 = ind_var_2.last
    end

    # bounding indices
    i1_upper = ind_var_1.index { |val| val >= input1 } || (ind_var_1.size - 1)
    i1_lower = [i1_upper - 1, 0].max
    i2_upper = ind_var_2.index { |val| val >= input2 } || (ind_var_2.size - 1)
    i2_lower = [i2_upper - 1, 0].max

    x1 = ind_var_1[i1_lower]
    x2 = ind_var_1[i1_upper]
    y1 = ind_var_2[i2_lower]
    y2 = ind_var_2[i2_upper]

    # dependent variable values at the bounding corners
    v11 = dep_var[(i1_lower * ind_var_2.size) + i2_lower] # (x1, y1)
    v12 = dep_var[(i1_lower * ind_var_2.size) + i2_upper] # (x1, y2)
    v21 = dep_var[(i1_upper * ind_var_2.size) + i2_lower] # (x2, y1)
    v22 = dep_var[(i1_upper * ind_var_2.size) + i2_upper] # (x2, y2)

    # exact match
    return v11 if input1 == x1 && input2 == y1
    return v12 if input1 == x1 && input2 == y2
    return v21 if input1 == x2 && input2 == y1
    return v22 if input1 == x2 && input2 == y2

    # edge cases where interpolation becomes linear
    dx = x2 - x1
    dy = y2 - y1
    return v11 if dx == 0 && dy == 0
    return v11 + ((v21 - v11) * (input1 - x1) / dx) if dy == 0
    return v11 + ((v12 - v11) * (input2 - y1) / dy) if dx == 0

    # bilinear interpolation
    interpolated_value =
      (v11 * (x2 - input1) * (y2 - input2)) +
      (v21 * (input1 - x1) * (y2 - input2)) +
      (v12 * (x2 - input1) * (input2 - y1)) +
      (v22 * (input1 - x1) * (input2 - y1))
    interpolated_value / ((x2 - x1) * (y2 - y1))
  end

  # ---------------------------------------------------------
  # heating setback helpers
  # ---------------------------------------------------------

  # determine if a thermostat schedule contains part of an optimum start sequence at a given index:
  # the zone becomes occupied within the next two timesteps and the setpoint is between the weekly min and max
  def opt_start?(sch_zone_occ_annual_profile, htg_schedule_annual_profile, min_value, max_value, idx)
    (sch_zone_occ_annual_profile[idx + 1] == 1 || sch_zone_occ_annual_profile[idx + 2] == 1) &&
      (htg_schedule_annual_profile[idx] > min_value && htg_schedule_annual_profile[idx] < max_value)
  end

  # modify heating setbacks for the zones served by an air loop
  # zones with excluded space types or without a ScheduleRuleset heating setpoint schedule are skipped
  # zones with People objects and no existing setback get a new schedule built from the occupancy schedule;
  # all other zones have the unoccupied values of their existing profiles set to the desired setback
  def modify_heating_setbacks(model, runner, air_loop_hvac, setback_value_f)
    setback_value_c = setback_value_f * 5 / 9

    air_loop_hvac.thermalZones.sort.each do |thermal_zone|
      # skip zones with space types excluded from setback modification
      zone_space_types = thermal_zone.spaces.map { |space| space.spaceType.get.name.to_s }
      next if SPACE_TYPES_NO_SETBACK.any? { |substring| zone_space_types.any? { |str| str.include?(substring) } }

      next unless thermal_zone.thermostatSetpointDualSetpoint.is_initialized

      zone_thermostat = thermal_zone.thermostatSetpointDualSetpoint.get
      htg_schedule = zone_thermostat.heatingSetpointTemperatureSchedule
      if htg_schedule.empty?
        runner.registerWarning("Heating setpoint schedule not found for zone '#{thermal_zone.name.get}'")
        next
      elsif htg_schedule.get.to_ScheduleRuleset.empty?
        runner.registerWarning("Schedule '#{htg_schedule.name}' is not a ScheduleRuleset, will not be adjusted")
        next
      end
      htg_schedule = htg_schedule.get.to_ScheduleRuleset.get

      sch_zone_occ = OpenstudioStandards::ThermalZone.thermal_zones_get_occupancy_schedule([thermal_zone], occupied_percentage_threshold: 0.05)

      # determine if setbacks are present
      has_setback = get_tstat_profiles_and_stats(htg_schedule)[:profiles].any? { |profile| profile.values.max > profile.values.min }
      has_people = !thermal_zone.numberOfPeople.zero?

      if has_people && !has_setback
        # build a new setpoint profile from occupancy
        runner.registerInfo("in no setback #{thermal_zone.name}")
        htg_schedule_annual_profile = get_8760_values_from_schedule_ruleset(model, htg_schedule)
        sch_zone_occ_annual_profile = get_8760_values_from_schedule_ruleset(model, sch_zone_occ)
        weekly_values = htg_schedule_annual_profile.each_slice(168).to_a
        htg_schedule_annual_profile_updated = OpenStudio::DoubleVector.new
        htg_schedule_annual_profile.each_with_index do |_val, idx|
          week_values = weekly_values[idx / 168]
          max_value = week_values.max
          min_value = week_values.min
          # skip timesteps where the setpoint is adjusted for an optimum start
          # the check needs two more timesteps in the profile; the final two timesteps of the year are not optimum start anyway
          next if (idx < htg_schedule_annual_profile.size - 2) && opt_start?(sch_zone_occ_annual_profile, htg_schedule_annual_profile, min_value, max_value, idx)

          htg_schedule_annual_profile_updated[idx] = sch_zone_occ_annual_profile[idx].zero? ? max_value - setback_value_c : max_value
        end
        htg_tstat_sch_limits = OpenStudio::Model::ScheduleTypeLimits.new(model)
        htg_tstat_sch_limits.setUnitType('Temperature')
        htg_tstat_sch_limits.setNumericType('Continuous')
        htg_sch_new = make_ruleset_sched_from_8760(model, runner, htg_schedule_annual_profile_updated, "#{htg_schedule.name} Modified Setpoints", htg_tstat_sch_limits)

        # the method above makes an unintended rule for the day of week of 12/31; on leap years, a separate rule for 12/30 and 12/31
        # extend rules ending on 12/29 or 12/30 to 12/31, then remove rules covering only 12/30-12/31 or 12/31
        model_year = model.getYearDescription.assumedYear
        dec_29_date = OpenStudio::Date.new(OpenStudio::MonthOfYear.new('December'), 29, model_year)
        dec_30_date = OpenStudio::Date.new(OpenStudio::MonthOfYear.new('December'), 30, model_year)
        dec_31_date = OpenStudio::Date.new(OpenStudio::MonthOfYear.new('December'), 31, model_year)
        htg_sch_new.scheduleRules.each do |tstat_rule|
          tstat_rule.setEndDate(dec_31_date) if tstat_rule.endDate.get == dec_30_date || tstat_rule.endDate.get == dec_29_date
          next unless tstat_rule.endDate.get == dec_31_date && (tstat_rule.startDate.get == dec_31_date || tstat_rule.startDate.get == dec_30_date)

          tstat_rule.remove
        end
        zone_thermostat.setHeatingSchedule(htg_sch_new)
      else
        # adjust the existing profiles so the unoccupied setpoint equals the maximum minus the setback
        profiles = [htg_schedule.defaultDaySchedule]
        htg_schedule.scheduleRules.each { |rule| profiles << rule.daySchedule }
        profiles.each do |tstat_profile|
          tstat_profile_min = tstat_profile.values.min
          tstat_profile_max = tstat_profile.values.max
          num_unique_values = tstat_profile.values.uniq.size
          time_h = tstat_profile.times
          new_setback_value = tstat_profile_max - setback_value_c
          if num_unique_values == 2
            # square wave (occupied vs unoccupied)
            tstat_profile.values.each_with_index do |value, i|
              tstat_profile.addValue(time_h[i], new_setback_value) if value == tstat_profile_min
            end
          elsif num_unique_values > 2
            # possibly an optimum start ramp; also raise intermediate values that fall below the new minimum
            tstat_profile.values.each_with_index do |value, i|
              is_min = value == tstat_profile_min
              is_ramp_below_new_min = value > tstat_profile_min && value < tstat_profile_max && value < new_setback_value
              tstat_profile.addValue(time_h[i], new_setback_value) if is_min || is_ramp_below_new_min
            end
          end
        end
      end
    end
  end

  # ---------------------------------------------------------
  # existing equipment helpers
  # ---------------------------------------------------------

  # cast the supply fan to its concrete type and return its availability schedule and pressure rise
  # @return [Array, nil] availability schedule and pressure rise, or nil after registering an error if unsupported
  def get_supply_fan_properties(runner, air_loop_hvac, supply_fan)
    if supply_fan.to_FanConstantVolume.is_initialized
      supply_fan = supply_fan.to_FanConstantVolume.get
    elsif supply_fan.to_FanOnOff.is_initialized
      supply_fan = supply_fan.to_FanOnOff.get
    elsif supply_fan.to_FanVariableVolume.is_initialized
      supply_fan = supply_fan.to_FanVariableVolume.get
    else
      runner.registerError("Supply fan type for #{air_loop_hvac.name} not supported.")
      return nil
    end

    supply_fan_avail_sched = supply_fan.availabilitySchedule
    if supply_fan_avail_sched.to_ScheduleConstant.is_initialized
      supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
    elsif supply_fan_avail_sched.to_ScheduleRuleset.is_initialized
      supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleRuleset.get
    else
      runner.registerError("Supply fan availability schedule type for #{supply_fan.name} not supported.")
      return nil
    end

    [supply_fan_avail_sched, supply_fan.pressureRise]
  end

  # get the original cooling and heating coil capacities from a unitary system, either hard-sized or autosized
  # @return [Array] cooling capacity W, heating capacity W; nil where unavailable, with errors registered
  def get_original_coil_capacities(runner, air_loop_hvac, unitary_sys)
    orig_clg_coil_gross_cap = nil
    orig_clg_coil = unitary_sys.coolingCoil.get
    if orig_clg_coil.to_CoilCoolingDXSingleSpeed.is_initialized
      orig_clg_coil = orig_clg_coil.to_CoilCoolingDXSingleSpeed.get
      if orig_clg_coil.isRatedTotalCoolingCapacityAutosized
        orig_clg_coil_gross_cap = orig_clg_coil.autosizedRatedTotalCoolingCapacity.get
      elsif orig_clg_coil.ratedTotalCoolingCapacity.is_initialized
        orig_clg_coil_gross_cap = orig_clg_coil.ratedTotalCoolingCapacity.to_f
      else
        runner.registerError("Original cooling coil capacity for #{air_loop_hvac.name} not found. Either it was not directly specified, or sizing run data is not available.")
      end
    elsif orig_clg_coil.to_CoilCoolingDXTwoSpeed.is_initialized
      orig_clg_coil = orig_clg_coil.to_CoilCoolingDXTwoSpeed.get
      if orig_clg_coil.autosizedRatedHighSpeedTotalCoolingCapacity.is_initialized
        orig_clg_coil_gross_cap = orig_clg_coil.autosizedRatedHighSpeedTotalCoolingCapacity.get
      elsif orig_clg_coil.ratedHighSpeedTotalCoolingCapacity.is_initialized
        orig_clg_coil_gross_cap = orig_clg_coil.ratedHighSpeedTotalCoolingCapacity.get
      else
        runner.registerError("Original cooling coil capacity for #{air_loop_hvac.name} not found. Either it was not directly specified, or sizing run data is not available.")
      end
    else
      runner.registerError("Original cooling coil is of type #{orig_clg_coil.class} which is not currently supported by this measure.")
    end

    orig_htg_coil_gross_cap = nil
    orig_htg_coil = unitary_sys.heatingCoil.get
    if orig_htg_coil.to_CoilHeatingElectric.is_initialized
      orig_htg_coil = orig_htg_coil.to_CoilHeatingElectric.get
    elsif orig_htg_coil.to_CoilHeatingGas.is_initialized
      orig_htg_coil = orig_htg_coil.to_CoilHeatingGas.get
    else
      runner.registerError("Heating coil for #{air_loop_hvac.name} is of an unsupported type. This measure currently supports CoilHeatingElectric and CoilHeatingGas object types.")
    end
    if orig_htg_coil.isNominalCapacityAutosized
      orig_htg_coil_gross_cap = orig_htg_coil.autosizedNominalCapacity.get
    elsif orig_htg_coil.nominalCapacity.is_initialized
      orig_htg_coil_gross_cap = orig_htg_coil.nominalCapacity.to_f
    else
      runner.registerError("Original heating coil capacity for #{air_loop_hvac.name} not found. Either it was not directly specified, or sizing run data is not available.")
    end

    [orig_clg_coil_gross_cap, orig_htg_coil_gross_cap]
  end

  # get the original heating fuel of a CoilHeatingGas in the air loop, directly or inside a unitary system
  # fuel oil and propane heating coils are CoilHeatingGas objects that differ only in fuelType, so the object
  # class alone does not identify the fuel; the value is written back unchanged to the backup coil
  # @return [String, nil] fuel type, or nil if no CoilHeatingGas is present
  def get_original_heating_coil_fuel_type(air_loop_hvac)
    orig_htg_coil_fuel_type = nil
    air_loop_hvac.supplyComponents.each do |component|
      if component.to_CoilHeatingGas.is_initialized
        orig_htg_coil_fuel_type = component.to_CoilHeatingGas.get.fuelType
      elsif component.to_AirLoopHVACUnitarySystem.is_initialized
        unitary = component.to_AirLoopHVACUnitarySystem.get
        next unless unitary.heatingCoil.is_initialized

        htg = unitary.heatingCoil.get
        orig_htg_coil_fuel_type = htg.to_CoilHeatingGas.get.fuelType if htg.to_CoilHeatingGas.is_initialized
      end
    end
    orig_htg_coil_fuel_type
  end

  # get the minimum outdoor air flow rate from the controller, hard-sized or autosized
  # @return [Double, nil] flow rate m3/s, or nil after registering an error if unavailable
  def get_min_oa_flow_m3_per_s(runner, controller_oa)
    if controller_oa.minimumOutdoorAirFlowRate.is_initialized
      controller_oa.minimumOutdoorAirFlowRate.get
    elsif controller_oa.autosizedMinimumOutdoorAirFlowRate.is_initialized
      controller_oa.autosizedMinimumOutdoorAirFlowRate.get
    else
      runner.registerError("No outdoor air sizing information was found for #{controller_oa.name}, which is required for setting ERV wheel power consumption.")
      nil
    end
  end

  # get the design supply air flow rate of the air loop, hard-sized or autosized
  # @return [Double, nil] flow rate m3/s, or nil after registering an error if unavailable
  def get_design_supply_air_flow_m3_per_s(runner, air_loop_hvac)
    if air_loop_hvac.designSupplyAirFlowRate.is_initialized
      air_loop_hvac.designSupplyAirFlowRate.get
    elsif air_loop_hvac.isDesignSupplyAirFlowRateAutosized
      air_loop_hvac.autosizedDesignSupplyAirFlowRate.get
    else
      runner.registerError("No sizing data available for air loop #{air_loop_hvac.name} zone terminal box.")
      nil
    end
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    return false unless runner.validateUserArguments(arguments(model), user_arguments)

    # ---------------------------------------------------------
    # assign the user inputs to variables
    # ---------------------------------------------------------
    backup_ht_fuel_scheme = runner.getStringArgumentValue('backup_ht_fuel_scheme', user_arguments)
    performance_oversizing_factor = runner.getDoubleArgumentValue('performance_oversizing_factor', user_arguments)
    htg_sizing_option = runner.getStringArgumentValue('htg_sizing_option', user_arguments)
    clg_oversizing_estimate = runner.getDoubleArgumentValue('clg_oversizing_estimate', user_arguments)
    htg_to_clg_hp_ratio = runner.getDoubleArgumentValue('htg_to_clg_hp_ratio', user_arguments)
    hp_min_comp_lockout_temp_elec_backup_f = runner.getDoubleArgumentValue('hp_min_comp_lockout_temp_elec_backup_f', user_arguments)
    hp_min_comp_lockout_temp_gas_backup_f = runner.getDoubleArgumentValue('hp_min_comp_lockout_temp_gas_backup_f', user_arguments)
    hprtu_scenario = runner.getStringArgumentValue('hprtu_scenario', user_arguments)
    hr = runner.getBoolArgumentValue('hr', user_arguments)
    dcv = runner.getBoolArgumentValue('dcv', user_arguments)
    econ = runner.getBoolArgumentValue('econ', user_arguments)
    roof = runner.getBoolArgumentValue('roof', user_arguments)
    window = runner.getBoolArgumentValue('window', user_arguments)
    sizing_run = runner.getBoolArgumentValue('sizing_run', user_arguments)
    debug_verbose = runner.getBoolArgumentValue('debug_verbose', user_arguments)
    setback_value = runner.getDoubleArgumentValue('setback_value', user_arguments)
    modify_setbacks = runner.getBoolArgumentValue('modify_setbacks', user_arguments)

    # build standard to use OS standards methods
    std = Standard.build('ComStock 90.1-2019')

    # ---------------------------------------------------------
    # get applicable psz hvac air loops
    # ---------------------------------------------------------
    selected_air_loops = []
    applicable_area_m2 = 0
    prim_ht_fuel_type = 'electric' # assume electric unless a gas coil is found in any air loop
    is_sizing_run_needed = true
    unitary_sys = nil
    orig_airloop_heating_coil_map = {}
    model.getAirLoopHVACs.each do |air_loop_hvac|
      air_loop_name = air_loop_hvac.name.to_s

      # skip units that are not single zone
      next if air_loop_hvac.thermalZones.length > 1

      # skip DOAS units; check sizing for all OA and for DOAS in name
      sizing_system = air_loop_hvac.sizingSystem
      if sizing_system.allOutdoorAirinCooling && sizing_system.allOutdoorAirinHeating && !air_loop_res?(air_loop_hvac) && name_matches_any?(air_loop_name, ['DOAS', 'doas'])
        next
      end

      # inspect supply components for heat pump, water coil, and gas heating
      is_hp = false
      is_water_coil = false
      has_heating_coil = true
      air_loop_hvac.supplyComponents.each do |component|
        obj_type = component.iddObjectType.valueName.to_s
        # water coils make the air loop not applicable
        is_water_coil = true if ['Coil_Heating_Water', 'Coil_Cooling_Water'].any? { |word| obj_type.include?(word) }
        # a gas coil in any air loop sets the primary heating fuel to gas
        prim_ht_fuel_type = 'gas' if ['Gas', 'GAS', 'gas'].any? { |word| obj_type.include?(word) }
        if obj_type == 'OS_AirLoopHVAC_UnitarySystem'
          unitary_sys = component.to_AirLoopHVACUnitarySystem.get
          # check the heating coil for DX, water, or gas
          if unitary_sys.heatingCoil.is_initialized
            htg_coil = unitary_sys.heatingCoil.get.iddObjectType.valueName.to_s
            if htg_coil.include?('Heating_DX')
              is_hp = true
            elsif htg_coil.include?('Water')
              is_water_coil = true
            elsif ['Gas', 'GAS', 'gas'].any? { |word| htg_coil.include?(word) }
              prim_ht_fuel_type = 'gas'
            end
          else
            runner.registerWarning("No heating coil was found for air loop: #{air_loop_hvac.name} - this equipment will be skipped.")
            has_heating_coil = false
          end
          # check the cooling coil for water
          if unitary_sys.coolingCoil.is_initialized
            clg_coil = unitary_sys.coolingCoil.get.iddObjectType.valueName.to_s
            is_water_coil = true if clg_coil.include?('Water')
          end
        elsif obj_type.include?('Heating_DX')
          is_hp = true
        end
      end

      # skip existing heat pumps, by DX heating component or by name
      next if is_hp || name_matches_any?(air_loop_name, HP_NAME_WORDS)
      # skip data centers, kitchens, and VAV systems by name
      next if name_matches_any?(air_loop_name, DATA_CENTER_NAME_WORDS)
      next if name_matches_any?(air_loop_name, KITCHEN_NAME_WORDS)
      next if name_matches_any?(air_loop_name, VAV_NAME_WORDS)
      # skip residential systems; no outdoor air system is also an indication of a residential system
      next if air_loop_res?(air_loop_hvac)
      next unless air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized
      # skip evaporative cooling and water coil systems
      next if air_loop_evaporative_cooler?(air_loop_hvac)
      next if is_water_coil

      # skip if the zone is not both heated and cooled
      thermal_zone = air_loop_hvac.thermalZones[0]
      next unless OpenstudioStandards::ThermalZone.thermal_zone_heated?(thermal_zone) && OpenstudioStandards::ThermalZone.thermal_zone_cooled?(thermal_zone)
      # skip if no heating coil
      next unless has_heating_coil

      # add applicable air loop and the area it serves
      selected_air_loops << air_loop_hvac
      applicable_area_m2 += thermal_zone.floorArea * thermal_zone.multiplier

      # determine if the equipment has been hard sized; a sizing run is only needed if it has not
      controller_oa = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
      oa_flow_hardsized = controller_oa.minimumOutdoorAirFlowRate.is_initialized
      sa_flow_hardsized = air_loop_hvac.designSupplyAirFlowRate.is_initialized

      orig_clg_coil = unitary_sys.coolingCoil.get
      clg_cap_hardsized = false
      if orig_clg_coil.to_CoilCoolingDXSingleSpeed.is_initialized
        clg_cap_hardsized = orig_clg_coil.to_CoilCoolingDXSingleSpeed.get.ratedTotalCoolingCapacity.is_initialized
      end

      orig_htg_coil = unitary_sys.heatingCoil.get
      if orig_htg_coil.to_CoilHeatingElectric.is_initialized
        orig_htg_coil = orig_htg_coil.to_CoilHeatingElectric.get
      elsif orig_htg_coil.to_CoilHeatingGas.is_initialized
        orig_htg_coil = orig_htg_coil.to_CoilHeatingGas.get
      end
      htg_cap_hardsized = orig_htg_coil.nominalCapacity.is_initialized

      # map heating coil with air loop name for the sizing algorithm later
      orig_airloop_heating_coil_map[air_loop_name] = orig_htg_coil.name.to_s.upcase

      is_sizing_run_needed = false if oa_flow_hardsized && sa_flow_hardsized && clg_cap_hardsized && htg_cap_hardsized
    end

    # ---------------------------------------------------------
    # check if any air loops are applicable to measure
    # ---------------------------------------------------------
    if selected_air_loops.empty?
      runner.registerAsNotApplicable('No applicable air loops in model. No changes will be made.')
      return true
    end

    # ---------------------------------------------------------
    # determine which compressor lockout temperature applies
    # ---------------------------------------------------------
    # backup heat is electric when requested, or when matching an original primary heating fuel that is electric;
    # dual fuel always gets gas backup regardless of the original fuel.
    # this mirrors the backup heating coil selection made for each air loop below.
    backup_ht_is_electric = (backup_ht_fuel_scheme == 'electric_resistance_backup') ||
                            ((backup_ht_fuel_scheme == 'match_original_primary_heating_fuel') && (prim_ht_fuel_type == 'electric'))
    if backup_ht_is_electric
      hp_min_comp_lockout_temp_f = hp_min_comp_lockout_temp_elec_backup_f
      runner.registerInfo("Backup heat will be electric resistance; using electric backup compressor lockout temperature of #{hp_min_comp_lockout_temp_f}F.")
    else
      hp_min_comp_lockout_temp_f = hp_min_comp_lockout_temp_gas_backup_f
      runner.registerInfo("Backup heat will be a gas furnace (dual fuel); using gas backup compressor lockout temperature of #{hp_min_comp_lockout_temp_f}F.")
    end

    # ---------------------------------------------------------
    # roof and/or window upgrades based on user input
    # ---------------------------------------------------------
    condition_initial_roof = ''
    condition_final_roof = ''
    condition_initial_window = ''
    condition_final_window = ''
    if roof
      runner.registerInfo('Running Roof Insulation measure....')
      results_roof, runner = call_roof(model, runner)
      condition_initial_roof = results_roof.stepInitialCondition.get if results_roof.stepInitialCondition.is_initialized
      condition_final_roof = results_roof.stepFinalCondition.get if results_roof.stepFinalCondition.is_initialized
    end
    if window
      runner.registerInfo('Running New Windows measure....')
      results_window, runner = call_windows(model, runner)
      # TODO: these overwrite the roof conditions; condition_initial_window and condition_final_window are never set
      condition_initial_roof = results_window.stepInitialCondition.get if results_window.stepInitialCondition.is_initialized
      condition_final_roof = results_window.stepFinalCondition.get if results_window.stepFinalCondition.is_initialized
    end

    # ---------------------------------------------------------
    # sizing run, if needed, to set sizing-specific features
    # ---------------------------------------------------------
    if is_sizing_run_needed || sizing_run
      runner.registerInfo('sizing summary: sizing run needed')
      return false if std.model_run_sizing_run(model, "#{Dir.pwd}/SR1") == false

      model.applySizingValues if is_sizing_run_needed
    end

    # get sql from the sizing run for extracting sizing information
    sql = nil
    if sizing_run
      sql = model.sqlFile
      if sql.empty?
        runner.registerError('Cannot find last sql file.')
        return false
      end
      sql = sql.get
    end

    # ---------------------------------------------------------
    # temporary: remove units with high OA fractions and night cycling
    # ---------------------------------------------------------
    # due to an EnergyPlus night cycling bug with multispeed coils; remove this section when the fix is in place
    oa_ratio_allowance = 0.55
    selected_air_loops.each do |air_loop_hvac|
      thermal_zone = air_loop_hvac.thermalZones[0]

      # unit OA fraction
      controller_oa = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
      oa_flow_m3_per_s = get_min_oa_flow_m3_per_s(runner, controller_oa)
      return false if oa_flow_m3_per_s.nil?

      old_terminal_sa_flow_m3_per_s = get_design_supply_air_flow_m3_per_s(runner, air_loop_hvac)
      min_oa_flow_ratio = (oa_flow_m3_per_s / old_terminal_sa_flow_m3_per_s)

      # supply fan operating mode schedule values, to check for night cycling
      night_cyc_sched_vals = []
      air_loop_hvac.supplyComponents.each do |component|
        next unless component.iddObjectType.valueName.to_s.include?('Unitary')

        unitary = component.to_AirLoopHVACUnitarySystem.get
        next unless unitary.supplyAirFanOperatingModeSchedule.is_initialized

        sf_sched = unitary.supplyAirFanOperatingModeSchedule.get
        if sf_sched.to_ScheduleRuleset.is_initialized
          sf_sched.to_ScheduleRuleset.get.scheduleRules.each do |sched_rule|
            sched_rule.daySchedule.values.each { |value| night_cyc_sched_vals << value }
          end
        elsif sf_sched.to_ScheduleConstant.is_initialized
          night_cyc_sched_vals << sf_sched.to_ScheduleConstant.get.value
        end
      end

      # the unit night cycles if the supply fan operating schedule includes a 0
      # TODO: include?([0, 0.0]) tests for an array element and is never true; the intended check is likely for 0 or 0.0
      unit_night_cycles = night_cyc_sched_vals.include?([0, 0.0])

      # remove from applicability if the OA limit is exceeded and the unit night cycles
      next unless (min_oa_flow_ratio > oa_ratio_allowance) && unit_night_cycles

      runner.registerWarning("Air loop #{air_loop_hvac.name} has night cycling operations and an outdoor air ratio of #{min_oa_flow_ratio.round(2)} which exceeds the maximum allowable limit of #{oa_ratio_allowance} (due to an EnergyPlus night cycling bug with multispeed coils) making this RTU not applicable at this time.")
      selected_air_loops.delete(air_loop_hvac)
      applicable_area_m2 -= thermal_zone.floorArea * thermal_zone.multiplier
    end

    # ---------------------------------------------------------
    # check if any air loops are applicable to measure
    # ---------------------------------------------------------
    if selected_air_loops.empty?
      runner.registerAsNotApplicable('No applicable air loops in model. No changes will be made.')
      return true
    end

    # ---------------------------------------------------------
    # report initial condition with applicable floor area
    # ---------------------------------------------------------
    if model.building.get.conditionedFloorArea.empty?
      runner.registerWarning('model.building.get.conditionedFloorArea() is empty; applicable floor area fraction will not be reported.')
      condition_initial_hprtu = "The building has #{selected_air_loops.size} applicable air loops (out of the total #{model.getAirLoopHVACs.size} airloops in the model) that will be replaced with heat pump RTUs, serving #{applicable_area_m2.round(0)} m2 of floor area. The remaning airloops were determined to be not applicable."
    else
      total_area_m2 = model.building.get.conditionedFloorArea.get
      applicable_floorspace_frac = applicable_area_m2 / total_area_m2
      condition_initial_hprtu = "The building has #{selected_air_loops.size} applicable air loops that will be replaced with heat pump RTUs, representing #{(applicable_floorspace_frac * 100).round(2)}% of the building floor area. #{condition_initial_roof}. #{condition_initial_window}."
    end
    condition_initial = [condition_initial_hprtu, condition_initial_roof, condition_initial_window].reject(&:empty?).join(' | ')
    runner.registerInitialCondition(condition_initial)

    # ---------------------------------------------------------
    # applicability checks for heat recovery; building type
    # ---------------------------------------------------------
    # building types not applicable to ERVs receive no new or modified ERV systems; this is only relevant if the user selected to add ERVs
    # space type applicability is handled later when looping through individual air loops
    if model.getBuilding.standardsBuildingType.is_initialized
      model_building_type = model.getBuilding.standardsBuildingType.get
    else
      runner.registerError('Building type not found.')
      return true
    end
    btype_erv_applicable = !ERV_EXCLUDED_BUILDING_TYPES.include?(model_building_type.downcase)
    if hr && !btype_erv_applicable
      runner.registerWarning("The user chose to include energy recovery in the heat pump RTUs, but the building type -#{model_building_type}- is not applicable for energy recovery. Energy recovery will not be added.")
    end

    # climate zone and energy recovery type (ERV in humid climates, HRV otherwise)
    climate_zone = OpenstudioStandards::Weather.model_get_climate_zone(model)
    climate_zone_classification = climate_zone.split('-')[-1]
    doas_type = ['1A', '2A', '3A', '4A', '5A', '6A', '7', '7A', '8', '8A'].include?(climate_zone_classification) ? 'ERV' : 'HRV'

    # ---------------------------------------------------------
    # load performance data and curves for the scenario
    # ---------------------------------------------------------
    path_data_curve = "#{File.dirname(__FILE__)}/resources/#{SCENARIO_PERFORMANCE_JSON.fetch(hprtu_scenario)}"
    custom_data_json = JSON.parse(File.read(path_data_curve))
    curve_names = SCENARIO_CURVE_NAMES.fetch(hprtu_scenario)

    # cooling curves by stage
    cool_cap_ft_curve_stages = stage_curves(model, curve_names[:cool_cap_ft], custom_data_json, std)
    cool_eir_ft_curve_stages = stage_curves(model, curve_names[:cool_eir_ft], custom_data_json, std)
    cool_cap_ff_curve_stages = stage_curves(model, curve_names[:cool_cap_ff], custom_data_json, std)
    cool_eir_ff_curve_stages = stage_curves(model, curve_names[:cool_eir_ff], custom_data_json, std)
    cool_plf_fplr1 = model_add_curve(model, 'cool_plf_plr1', custom_data_json, std)

    # heating curves by stage
    heat_cap_ft_curve_stages = stage_curves(model, curve_names[:heat_cap_ft], custom_data_json, std)
    heat_eir_ft_curve_stages = stage_curves(model, curve_names[:heat_eir_ft], custom_data_json, std)
    heat_cap_ff_curve_stages = stage_curves(model, curve_names[:heat_cap_ff], custom_data_json, std)
    heat_eir_ff_curve_stages = stage_curves(model, curve_names[:heat_eir_ff], custom_data_json, std)
    heat_plf_fplr1 = model_add_curve(model, 'heat_plf_plr1', custom_data_json, std)
    defrost_eir = model_add_curve(model, 'defrost_eir', custom_data_json, std)

    # ---------------------------------------------------------
    # replace existing applicable air loops with new heat pump rtu air loops
    # ---------------------------------------------------------
    selected_air_loops.sort.each do |air_loop_hvac|
      thermal_zone = air_loop_hvac.thermalZones[0]
      hvac_operation_sched = air_loop_hvac.availabilitySchedule
      always_on = model.alwaysOnDiscreteSchedule

      # capture the original combustion fuel before the existing equipment is removed, for a backup coil matching the original fuel
      orig_htg_coil_fuel_type = get_original_heating_coil_fuel_type(air_loop_hvac)

      # modify heating setbacks
      modify_heating_setbacks(model, runner, air_loop_hvac, setback_value) if modify_setbacks

      # ---------------------------------------------------------
      # store information from the existing equipment, then remove it
      # ---------------------------------------------------------
      unitary_availability_sched = nil
      control_zone = nil
      dehumid_type = nil
      supply_fan_op_sched = nil
      supply_fan_avail_sched = nil
      fan_static_pressure = nil
      orig_clg_coil_gross_cap = nil
      orig_htg_coil_gross_cap = nil
      equip_to_delete = []
      if air_loop_hvac_unitary_system?(air_loop_hvac)
        air_loop_hvac.supplyComponents.each do |component|
          obj_type = component.iddObjectType.valueName.to_s
          next unless ['Fan', 'Unitary', 'Coil'].any? { |word| obj_type.include?(word) }

          equip_to_delete << component
          next unless obj_type.include?('Unitary')

          # schedules, control zone, and dehumidification type from the unitary system
          unitary_sys = component.to_AirLoopHVACUnitarySystem.get
          unitary_availability_sched = unitary_sys.availabilitySchedule.get
          control_zone = unitary_sys.controllingZoneorThermostatLocation.get
          dehumid_type = unitary_sys.dehumidificationControlType
          supply_fan_op_sched = unitary_sys.supplyAirFanOperatingModeSchedule.get

          # supply fan availability schedule and static pressure
          supply_fan_avail_sched, fan_static_pressure = get_supply_fan_properties(runner, air_loop_hvac, unitary_sys.supplyFan.get)
          return false if supply_fan_avail_sched.nil?

          # original coil capacities
          orig_clg_coil_gross_cap, orig_htg_coil_gross_cap = get_original_coil_capacities(runner, air_loop_hvac, unitary_sys)
        end
      else
        air_loop_hvac.supplyComponents.each do |component|
          obj_type = component.iddObjectType.valueName.to_s
          next unless ['Fan', 'Unitary', 'Coil'].any? { |word| obj_type.include?(word) }

          equip_to_delete << component
          next unless obj_type.include?('Fan')

          # supply fan availability schedule and static pressure
          supply_fan_avail_sched, fan_static_pressure = get_supply_fan_properties(runner, air_loop_hvac, component)
          return false if supply_fan_avail_sched.nil?

          # non-unitary systems use the air loop schedule for fan operation, no dehumidification, and an always on availability schedule
          supply_fan_op_sched = hvac_operation_sched
          dehumid_type = 'None'
          control_zone = thermal_zone
          unitary_availability_sched = always_on
        end
      end

      # delete equipment from original loop
      equip_to_delete.each(&:remove)

      # minimum outdoor air flow rate
      controller_oa = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
      oa_flow_m3_per_s = get_min_oa_flow_m3_per_s(runner, controller_oa)
      return false if oa_flow_m3_per_s.nil?

      # change sizing parameter to vav
      air_loop_hvac.sizingSystem.setCentralCoolingCapacityControlMethod('VAV')

      # get the existing terminal box
      terminal = thermal_zone.airLoopHVACTerminal.get
      old_terminal =
        if terminal.to_AirTerminalSingleDuctConstantVolumeReheat.is_initialized
          terminal.to_AirTerminalSingleDuctConstantVolumeReheat.get
        elsif terminal.to_AirTerminalSingleDuctConstantVolumeNoReheat.is_initialized
          terminal.to_AirTerminalSingleDuctConstantVolumeNoReheat.get
        elsif terminal.to_AirTerminalSingleDuctVAVHeatAndCoolNoReheat.is_initialized
          terminal.to_AirTerminalSingleDuctVAVHeatAndCoolNoReheat.get
        elsif terminal.to_AirTerminalSingleDuctVAVHeatAndCoolReheat.is_initialized
          terminal.to_AirTerminalSingleDuctVAVHeatAndCoolReheat.get
        elsif terminal.to_AirTerminalSingleDuctVAVNoReheat.is_initialized
          terminal.to_AirTerminalSingleDuctVAVNoReheat.get
        elsif terminal.to_AirTerminalSingleDuctVAVReheat.is_initialized
          terminal.to_AirTerminalSingleDuctVAVReheat.get
        else
          runner.registerError("Terminal box type for air loop #{air_loop_hvac.name} not supported.")
          return false
        end

      # design supply air flow rate
      old_terminal_sa_flow_m3_per_s = get_design_supply_air_flow_m3_per_s(runner, air_loop_hvac)

      # minimum flow ratio needed to maintain ventilation; remove any maximum OA fraction schedule
      controller_oa.resetMaximumFractionofOutdoorAirSchedule if controller_oa.maximumFractionofOutdoorAirSchedule.is_initialized
      min_oa_flow_ratio = (oa_flow_m3_per_s / old_terminal_sa_flow_m3_per_s)

      # replace the terminal box with a no reheat VAV terminal box
      old_terminal.remove
      air_loop_hvac.removeBranchForZone(thermal_zone)
      new_terminal = OpenStudio::Model::AirTerminalSingleDuctVAVHeatAndCoolNoReheat.new(model)
      new_terminal.setName("#{thermal_zone.name} VAV Terminal")
      air_loop_hvac.addBranchForZone(thermal_zone, new_terminal.to_StraightComponent)

      # ---------------------------------------------------------
      # sizing: heat pump sizing temperature
      # ---------------------------------------------------------
      # coldest heating design day temperature
      li_htg_dsgn_day_temps = model.getDesignDays.sort.select { |dd| dd.dayType == 'WinterDesignDay' }.map(&:maximumDryBulbTemperature)
      wntr_design_day_temp_c = li_htg_dsgn_day_temps.min

      # heat pump sizing temperature is the warmer of the user-input temperature and the design day temperature
      htg_sizing_option_c = OpenStudio.convert(HTG_SIZING_OPTIONS_F[htg_sizing_option], 'F', 'C').get
      hp_sizing_temp_c = [htg_sizing_option_c, wntr_design_day_temp_c].max
      if debug_verbose
        sizing_temp_message = "sizing summary: For heat pump sizing, heating design day temperature is #{OpenStudio.convert(wntr_design_day_temp_c, 'C', 'F').get.round(0)}F, and the user-input temperature to size on is #{OpenStudio.convert(htg_sizing_option_c, 'C', 'F').get.round(0)}F. "
        if htg_sizing_option_c >= wntr_design_day_temp_c
          runner.registerInfo("#{sizing_temp_message}User-input temperature is larger than design day temperature, so user-input temperature will be used.")
        else
          runner.registerInfo("#{sizing_temp_message}The heating design day temperature is higher than the user-specified temperature which is not realistic, therefore the heating design day temperature will be used.")
        end
      end

      # number of stages, and capacity/airflow fractions for each stage; read per air loop because the hashes are adjusted in place
      staging = assign_staging_data(custom_data_json, std)
      rated_stage_num_heating = staging[:rated_stage_num_heating]
      rated_stage_num_cooling = staging[:rated_stage_num_cooling]
      final_rated_cooling_cop = staging[:final_rated_cooling_cop]
      final_rated_heating_cop = staging[:final_rated_heating_cop]
      stage_cap_fractions_heating = staging[:stage_cap_fractions_heating]
      stage_flow_fractions_heating = staging[:stage_flow_fractions_heating]
      stage_cap_fractions_cooling = staging[:stage_cap_fractions_cooling]
      stage_flow_fractions_cooling = staging[:stage_flow_fractions_cooling]
      stage_rated_cop_frac_heating = staging[:stage_rated_cop_frac_heating]
      stage_rated_cop_frac_cooling = staging[:stage_rated_cop_frac_cooling]
      stage_gross_rated_sensible_heat_ratio_cooling = staging[:stage_gross_rated_sensible_heat_ratio_cooling]
      enable_cycling_losses_above_lowest_speed = staging[:enable_cycling_losses_above_lowest_speed]
      reference_cooling_cfm_per_ton = staging[:reference_cooling_cfm_per_ton]
      reference_heating_cfm_per_ton = staging[:reference_heating_cfm_per_ton]

      # ---------------------------------------------------------
      # sizing: design heating load
      # ---------------------------------------------------------
      orig_htg_coil_gross_cap_old = orig_htg_coil_gross_cap
      design_air_flow_from_zone_sizing_heating_m_3_per_s = old_terminal_sa_flow_m3_per_s
      if sizing_run
        thermal_zones = air_loop_hvac.thermalZones
        if thermal_zones.size != 1
          runner.registerError("The airloop (#{air_loop_hvac.name}) includes multiple (#{thermal_zones.size}) thermal zones instead of just a single zone.")
        end

        # design heating airflow with sizing factor applied, from the design day simulation
        zone_row_name = thermal_zones.first.name.to_s.upcase
        design_air_flow_from_zone_sizing_heating_m_3_per_s = get_tabular_data(runner, sql, 'HVACSizingSummary', 'Entire Facility', 'Zone Sensible Heating', zone_row_name, 'User Design Air Flow').to_f

        # heating coil sizing details
        coil_row_name = orig_airloop_heating_coil_map[air_loop_hvac.name.to_s]
        coil_sizing_detail = lambda do |column_name|
          get_tabular_data(runner, sql, 'CoilSizingDetails', 'Entire Facility', 'Coils', coil_row_name, column_name).to_f
        end
        coil_entering_temperature_c = coil_sizing_detail.call('Coil Entering Air Drybulb at Ideal Loads Peak')
        coil_leaving_temperature_c = coil_sizing_detail.call('Coil Leaving Air Drybulb at Ideal Loads Peak')
        air_density_kg_per_m_3 = coil_sizing_detail.call('Standard Air Density Adjusted for Elevation')
        air_heat_capacity_j_per_kg_k = coil_sizing_detail.call('Dry Air Heat Capacity')

        # override design heating load with Q = vdot * rho * cp * (Tout - Tin)
        orig_htg_coil_gross_cap = design_air_flow_from_zone_sizing_heating_m_3_per_s * air_density_kg_per_m_3 * air_heat_capacity_j_per_kg_k * (coil_leaving_temperature_c - coil_entering_temperature_c)
        if debug_verbose
          runner.registerInfo("sizing summary: original heating design load overriden from sizing run: #{orig_htg_coil_gross_cap_old.round(3)} W to  #{orig_htg_coil_gross_cap.round(3)} W for airloop (#{air_loop_hvac.name})")
        end
      end

      # heating load curve, y = mx + b, assuming 0 load at 60F (15.556C)
      htg_load_slope = (0 - orig_htg_coil_gross_cap) / (15.5556 - wntr_design_day_temp_c)
      htg_load_intercept = orig_htg_coil_gross_cap - (htg_load_slope * wntr_design_day_temp_c)

      # heat pump design load, derate factor, and required rated capacity at the sizing temperature; assumes 75F interior temp (23.8889C)
      ia_temp_c = 23.8889
      oa_temp_c = hp_sizing_temp_c
      dns_htg_load_at_user_dsn_temp = (htg_load_slope * hp_sizing_temp_c) + htg_load_intercept
      rated_heat_cap_ft_curve = heat_cap_ft_curve_stages[rated_stage_num_heating]
      if rated_heat_cap_ft_curve.to_TableLookup.is_initialized
        hp_derate_factor_at_user_dsn = AddHeatPumpRtu.get_dep_var_from_lookup_table_with_interpolation(runner, rated_heat_cap_ft_curve.to_TableLookup.get, ia_temp_c, oa_temp_c)
      else
        hp_derate_factor_at_user_dsn = rated_heat_cap_ft_curve.evaluate(ia_temp_c, oa_temp_c)
      end
      req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn = dns_htg_load_at_user_dsn_temp / hp_derate_factor_at_user_dsn

      # ---------------------------------------------------------
      # sizing: rated capacities and design airflows
      # ---------------------------------------------------------
      # cooling capacity with the estimated upsizing, and the maximum capacities allowed by the oversizing limit
      autosized_tot_clg_cap_upsized = orig_clg_coil_gross_cap * clg_oversizing_estimate
      max_cool_cap_w_upsize = autosized_tot_clg_cap_upsized * (performance_oversizing_factor + 1)
      max_heat_cap_w_upsize = autosized_tot_clg_cap_upsized * (performance_oversizing_factor + 1) * htg_to_clg_hp_ratio

      # sizing decision based on heating load level:
      # - small: required heating capacity is within the heating to cooling ratio, so size on cooling
      # - moderate: heating requires upsizing within the oversizing limit, so size on the design heating load
      # - large: size to the maximum oversizing factor
      design_cooling_airflow_m_3_per_s = old_terminal_sa_flow_m3_per_s
      if (req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn / autosized_tot_clg_cap_upsized) <= htg_to_clg_hp_ratio
        heating_load_category = 'Small heating load'
        dx_rated_htg_cap_applied = autosized_tot_clg_cap_upsized * htg_to_clg_hp_ratio
        dx_rated_clg_cap_applied = autosized_tot_clg_cap_upsized
        design_heating_airflow_m_3_per_s = old_terminal_sa_flow_m3_per_s
      elsif req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn <= max_heat_cap_w_upsize
        heating_load_category = 'Moderate heating load'
        dx_rated_htg_cap_applied = req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn
        dx_rated_clg_cap_applied = req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn / htg_to_clg_hp_ratio
        design_heating_airflow_m_3_per_s = design_air_flow_from_zone_sizing_heating_m_3_per_s
      else
        heating_load_category = 'Large heating load'
        dx_rated_htg_cap_applied = max_cool_cap_w_upsize * htg_to_clg_hp_ratio
        dx_rated_clg_cap_applied = max_cool_cap_w_upsize
        design_heating_airflow_m_3_per_s = design_air_flow_from_zone_sizing_heating_m_3_per_s
      end

      # sizing result summary for measure documentation
      if debug_verbose
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): air_loop_hvac name  =  #{air_loop_hvac.name}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): heating_load_category = #{heating_load_category}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): original rated cooling capacity W = #{orig_clg_coil_gross_cap.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): design heating load (from load curve based on user specified design temp) W = #{dns_htg_load_at_user_dsn_temp.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): design heating load (from original heating coil) W = #{orig_htg_coil_gross_cap.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): minimum heating capacity threshold W = #{(autosized_tot_clg_cap_upsized * htg_to_clg_hp_ratio).round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): maximum heating capacity threshold W = #{max_heat_cap_w_upsize.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): required rated heating capacity to meet design heating load W = #{req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): heat pump heating sizing temperature F = #{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): heating capacity derating factor at design temperature = #{hp_derate_factor_at_user_dsn.round(3)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): upsized rated heating capacity W = #{dx_rated_htg_cap_applied.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): upsized rated cooling capacity W = #{dx_rated_clg_cap_applied.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): final upsizing percentage % = #{((dx_rated_htg_cap_applied - orig_clg_coil_gross_cap) / orig_clg_coil_gross_cap * 100).round(2)}")
      end

      # applied upsizing factor
      upsize_factor = (dx_rated_htg_cap_applied - orig_clg_coil_gross_cap) / orig_clg_coil_gross_cap

      if debug_verbose
        runner.registerInfo('sizing summary: before rated cfm/ton adjustmant')
        runner.registerInfo("sizing summary: dx_rated_htg_cap_applied = #{dx_rated_htg_cap_applied}")
        runner.registerInfo("sizing summary: design_heating_airflow_m_3_per_s = #{design_heating_airflow_m_3_per_s}")
        runner.registerInfo("sizing summary: cfm/ton heating = #{m_3_per_sec_watts_to_cfm_per_ton(design_heating_airflow_m_3_per_s / dx_rated_htg_cap_applied)}")
        runner.registerInfo("sizing summary: dx_rated_clg_cap_applied = #{dx_rated_clg_cap_applied}")
        runner.registerInfo("sizing summary: design_cooling_airflow_m_3_per_s = #{design_cooling_airflow_m_3_per_s}")
        runner.registerInfo("sizing summary: cfm/ton heating = #{m_3_per_sec_watts_to_cfm_per_ton(design_cooling_airflow_m_3_per_s / dx_rated_clg_cap_applied)}")
      end

      # adjust design airflows if the rated stage cfm/ton limits are violated
      cfm_per_ton_rated_heating = m_3_per_sec_watts_to_cfm_per_ton(design_heating_airflow_m_3_per_s / dx_rated_htg_cap_applied)
      cfm_per_ton_rated_cooling = m_3_per_sec_watts_to_cfm_per_ton(design_cooling_airflow_m_3_per_s / dx_rated_clg_cap_applied)
      if cfm_per_ton_rated_heating < CFM_PER_TON_MIN_RATED
        design_heating_airflow_m_3_per_s = cfm_per_ton_to_m_3_per_sec_watts(CFM_PER_TON_MIN_RATED) * dx_rated_htg_cap_applied
      elsif cfm_per_ton_rated_heating > CFM_PER_TON_MAX_RATED
        design_heating_airflow_m_3_per_s = cfm_per_ton_to_m_3_per_sec_watts(CFM_PER_TON_MAX_RATED) * dx_rated_htg_cap_applied
      end
      if cfm_per_ton_rated_cooling < CFM_PER_TON_MIN_RATED
        design_cooling_airflow_m_3_per_s = cfm_per_ton_to_m_3_per_sec_watts(CFM_PER_TON_MIN_RATED) * dx_rated_clg_cap_applied
      elsif cfm_per_ton_rated_cooling > CFM_PER_TON_MAX_RATED
        design_cooling_airflow_m_3_per_s = cfm_per_ton_to_m_3_per_sec_watts(CFM_PER_TON_MAX_RATED) * dx_rated_clg_cap_applied
      end

      if debug_verbose
        runner.registerInfo('sizing summary: after rated cfm/ton adjustmant')
        runner.registerInfo("sizing summary: dx_rated_htg_cap_applied = #{dx_rated_htg_cap_applied}")
        runner.registerInfo("sizing summary: design_heating_airflow_m_3_per_s = #{design_heating_airflow_m_3_per_s}")
        runner.registerInfo("sizing summary: cfm/ton heating = #{m_3_per_sec_watts_to_cfm_per_ton(design_heating_airflow_m_3_per_s / dx_rated_htg_cap_applied)}")
        runner.registerInfo("sizing summary: dx_rated_clg_cap_applied = #{dx_rated_clg_cap_applied}")
        runner.registerInfo("sizing summary: design_cooling_airflow_m_3_per_s = #{design_cooling_airflow_m_3_per_s}")
        runner.registerInfo("sizing summary: cfm/ton heating = #{m_3_per_sec_watts_to_cfm_per_ton(design_cooling_airflow_m_3_per_s / dx_rated_clg_cap_applied)}")
        runner.registerInfo("sizing summary: upsize_factor = #{upsize_factor}")
        runner.registerInfo("sizing summary: heating_load_category = #{heating_load_category}")
      end

      # air loop design airflow is the larger of the heating and cooling design airflows, and no less than the minimum OA
      design_airflow_for_sizing_m_3_per_s = [design_cooling_airflow_m_3_per_s, design_heating_airflow_m_3_per_s].max
      design_airflow_for_sizing_m_3_per_s = oa_flow_m3_per_s if oa_flow_m3_per_s > design_airflow_for_sizing_m_3_per_s
      design_cooling_airflow_m_3_per_s = oa_flow_m3_per_s if oa_flow_m3_per_s > design_cooling_airflow_m_3_per_s
      design_heating_airflow_m_3_per_s = oa_flow_m3_per_s if oa_flow_m3_per_s > design_heating_airflow_m_3_per_s

      # minimum airflow ratio is 0.40, or higher as needed to maintain outdoor air requirements
      min_flow = 0.40
      current_min_oa_flow_ratio = oa_flow_m3_per_s / design_heating_airflow_m_3_per_s
      min_airflow_ratio = [current_min_oa_flow_ratio, min_flow].max
      min_airflow_m3_per_s = min_airflow_ratio * design_airflow_for_sizing_m_3_per_s

      # increase design airflow to accommodate upsizing
      air_loop_hvac.setDesignSupplyAirFlowRate(design_airflow_for_sizing_m_3_per_s)
      controller_oa.setMaximumOutdoorAirFlowRate(design_airflow_for_sizing_m_3_per_s)

      if debug_verbose
        runner.registerInfo("sizing summary: design_airflow_for_sizing_m_3_per_s = #{design_airflow_for_sizing_m_3_per_s}")
        runner.registerInfo("sizing summary: min_oa_flow_ratio = #{min_oa_flow_ratio} | min_flow = #{min_flow}")
        runner.registerInfo("sizing summary: min_airflow_m3_per_s = #{min_airflow_m3_per_s}")
      end

      # ---------------------------------------------------------
      # sizing: stage airflows and capacities
      # ---------------------------------------------------------
      # the lowest flow fraction the scenario's json specifies, captured before adjust_cfm_per_ton_per_limits changes the hashes in place
      # the cfm/ton limits are a numerical guard for the EnergyPlus operating range, not a statement of equipment turndown,
      # so this is used below as a floor on the fan power minimum flow fraction
      specified_min_flow_fraction = (stage_flow_fractions_heating.values + stage_flow_fractions_cooling.values)
                                    .select { |v| v.is_a?(Numeric) && v > 0 }.min

      # stage airflows are the higher of the stage flow fraction and the minimum airflow
      # lower stages may be removed later if cfm/ton bounds cannot be maintained due to minimum OA limits
      # heating uses the cooling design airflow when no oversizing is applied (upsize_factor = 0.0)
      stage_flows_heating = {}
      stage_flow_fractions_heating.each do |stage, ratio|
        airflow = upsize_factor == 0.0 ? ratio * design_cooling_airflow_m_3_per_s : ratio * design_heating_airflow_m_3_per_s
        stage_flows_heating[stage] = [airflow, min_airflow_m3_per_s].max
      end
      stage_flows_cooling = {}
      stage_flow_fractions_cooling.sort.each do |stage, ratio|
        airflow = ratio * design_cooling_airflow_m_3_per_s
        stage_flows_cooling[stage] = [airflow, min_airflow_m3_per_s].max
      end

      if debug_verbose
        runner.registerInfo('sizing summary: before cfm/ton adjustments for lower stages')
        runner.registerInfo("sizing summary: stage_flow_fractions_heating = #{stage_flow_fractions_heating}")
        runner.registerInfo("sizing summary: stage_flow_fractions_cooling = #{stage_flow_fractions_cooling}")
        runner.registerInfo("sizing summary: stage_flows_heating = #{stage_flows_heating}")
        runner.registerInfo("sizing summary: stage_flows_cooling = #{stage_flows_cooling}")
      end

      # align stage cfm/ton with the limits where possible; this may remove some lower stages
      stage_flows_heating, stage_caps_heating, _, _, num_heating_stages = adjust_cfm_per_ton_per_limits(
        stage_cap_fractions_heating, stage_flows_heating, stage_flow_fractions_heating, dx_rated_htg_cap_applied, rated_stage_num_heating,
        design_heating_airflow_m_3_per_s, min_airflow_ratio, air_loop_hvac, 'heating', runner, debug_verbose
      )
      stage_flows_cooling, stage_caps_cooling, _, _, num_cooling_stages = adjust_cfm_per_ton_per_limits(
        stage_cap_fractions_cooling, stage_flows_cooling, stage_flow_fractions_cooling, dx_rated_clg_cap_applied, rated_stage_num_cooling,
        design_cooling_airflow_m_3_per_s, min_airflow_ratio, air_loop_hvac, 'cooling', runner, debug_verbose
      )

      if debug_verbose
        runner.registerInfo('sizing summary: after cfm/ton adjustments for lower stages')
        runner.registerInfo("sizing summary: stage_flows_heating = #{stage_flows_heating}")
        runner.registerInfo("sizing summary: stage_flows_cooling = #{stage_flows_cooling}")
      end

      # ---------------------------------------------------------
      # cooling coil
      # ---------------------------------------------------------
      # adjust rated cooling COP for the sized cfm/ton if the json does not specify a final rated COP
      if final_rated_cooling_cop == false
        final_rated_cooling_cop = adjust_rated_cop_from_ref_cfm_per_ton(runner, stage_flows_cooling[rated_stage_num_cooling],
                                                                        reference_cooling_cfm_per_ton,
                                                                        stage_caps_cooling[rated_stage_num_cooling],
                                                                        get_rated_cop_cooling(stage_caps_cooling[rated_stage_num_cooling]),
                                                                        cool_eir_ff_curve_stages[rated_stage_num_cooling])
        runner.registerInfo("sizing summary: rated cooling COP adjusted from #{get_rated_cop_cooling(stage_caps_cooling[rated_stage_num_cooling]).round(3)} to #{final_rated_cooling_cop.round(3)} based on reference cfm/ton of #{reference_cooling_cfm_per_ton.round(0)} (i.e., average value of actual products)")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): final rated cooling COP = #{final_rated_cooling_cop.round(3)}")
      end

      new_dx_cooling_coil = set_cooling_coil_stages(
        model, runner, stage_flows_cooling, stage_caps_cooling, num_cooling_stages, final_rated_cooling_cop,
        cool_cap_ft_curve_stages, cool_eir_ft_curve_stages, cool_cap_ff_curve_stages, cool_eir_ff_curve_stages, cool_plf_fplr1,
        stage_rated_cop_frac_cooling, stage_gross_rated_sensible_heat_ratio_cooling, rated_stage_num_cooling,
        enable_cycling_losses_above_lowest_speed, air_loop_hvac, always_on, debug_verbose
      )

      # ---------------------------------------------------------
      # heating coil
      # ---------------------------------------------------------
      # adjust rated heating COP for the sized cfm/ton if the json does not specify a final rated COP
      if final_rated_heating_cop == false
        final_rated_heating_cop = adjust_rated_cop_from_ref_cfm_per_ton(runner, stage_flows_heating[rated_stage_num_heating],
                                                                        reference_heating_cfm_per_ton,
                                                                        stage_caps_heating[rated_stage_num_heating],
                                                                        get_rated_cop_heating(stage_caps_heating[rated_stage_num_heating]),
                                                                        heat_eir_ff_curve_stages[rated_stage_num_heating])
        runner.registerInfo("sizing summary: rated heating COP adjusted from #{get_rated_cop_heating(stage_caps_heating[rated_stage_num_heating]).round(3)} to #{final_rated_heating_cop.round(3)} based on reference cfm/ton of #{reference_heating_cfm_per_ton.round(0)} (i.e., average value of actual products)")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): final rated heating COP = #{final_rated_heating_cop.round(3)}")
      end

      new_dx_heating_coil = set_heating_coil_stages(
        model, runner, stage_flows_heating, stage_caps_heating, num_heating_stages, final_rated_heating_cop,
        heat_cap_ft_curve_stages, heat_eir_ft_curve_stages, heat_cap_ff_curve_stages, heat_eir_ff_curve_stages, heat_plf_fplr1, defrost_eir,
        stage_rated_cop_frac_heating, rated_stage_num_heating, air_loop_hvac, hp_min_comp_lockout_temp_f,
        enable_cycling_losses_above_lowest_speed, always_on, debug_verbose
      )

      # ---------------------------------------------------------
      # backup heating coil, sized to meet the full heating load
      # ---------------------------------------------------------
      if backup_ht_is_electric
        new_backup_heating_coil = OpenStudio::Model::CoilHeatingElectric.new(model)
        new_backup_heating_coil.setEfficiency(1.0)
        new_backup_heating_coil.setName("#{air_loop_hvac.name} electric resistance backup coil")
      else
        new_backup_heating_coil = OpenStudio::Model::CoilHeatingGas.new(model)
        new_backup_heating_coil.setGasBurnerEfficiency(0.80)
        if backup_ht_fuel_scheme == 'dual_fuel_gas_furnace_backup'
          # dual fuel RTU: natural gas backup regardless of the original heating fuel
          new_backup_heating_coil.setFuelType('NaturalGas')
          backup_fuel_note = 'for dual fuel RTU'
        else
          # match the original combustion fuel so a fuel oil or propane building keeps its own fuel as backup
          if orig_htg_coil_fuel_type.nil? || orig_htg_coil_fuel_type.to_s.empty?
            runner.registerWarning("Could not determine the original combustion fuel for #{air_loop_hvac.name}; backup coil defaults to #{new_backup_heating_coil.fuelType}.")
          else
            new_backup_heating_coil.setFuelType(orig_htg_coil_fuel_type)
          end
          backup_fuel_note = 'matching the original heating fuel'
        end
        backup_fuel_label = new_backup_heating_coil.fuelType.to_s
        new_backup_heating_coil.setName("#{air_loop_hvac.name} #{backup_fuel_label} backup coil")
        runner.registerInfo("Backup heat for #{air_loop_hvac.name} set to #{backup_fuel_label}, #{backup_fuel_note}.")
      end
      new_backup_heating_coil.setAvailabilitySchedule(always_on)
      new_backup_heating_coil.setNominalCapacity(orig_htg_coil_gross_cap_old)

      # ---------------------------------------------------------
      # supply fan
      # ---------------------------------------------------------
      new_fan = OpenStudio::Model::FanVariableVolume.new(model, always_on)
      new_fan.setAvailabilitySchedule(supply_fan_avail_sched)
      new_fan.setName("#{air_loop_hvac.name} Supply Fan")
      new_fan.setFanPowerMinimumFlowRateInputMethod('Fraction')
      new_fan.setPressureRise(fan_static_pressure) # from the original fan

      # part-load curve and impeller efficiency come from the scenario's performance json, alongside the compressor data,
      # so two-speed units are not credited with the continuous modulation of a variable-speed fan
      fan_type, fan_power_coefficients, fan_impeller_efficiency = assign_fan_data(custom_data_json, std)
      if fan_power_coefficients.nil? || fan_power_coefficients.size < 5 || fan_impeller_efficiency.nil?
        # fall back to the more conservative two-speed representation and warn
        runner.registerWarning('No usable fan_data record in the performance json for scenario ' \
                               "#{hprtu_scenario}; falling back to the two-speed fan representation. " \
                               'Add a fan_data record to that json.')
        fan_type = 'two_speed'
        fan_power_coefficients = [0.005131596, -0.061344439, 0.870911024, 0.221907644, -0.036605825]
        fan_impeller_efficiency = std.fan_baseline_impeller_efficiency(new_fan)
      end
      new_fan.setFanPowerCoefficient1(fan_power_coefficients[0])
      new_fan.setFanPowerCoefficient2(fan_power_coefficients[1])
      new_fan.setFanPowerCoefficient3(fan_power_coefficients[2])
      new_fan.setFanPowerCoefficient4(fan_power_coefficients[3])
      new_fan.setFanPowerCoefficient5(fan_power_coefficients[4])

      # total efficiency is impeller x motor, with the motor efficiency looked up from the 90.1 table by size
      # ComStock PSZ supply fans are small (median 0.5 bhp, two-thirds at or below 1 hp), so a single literal misrepresents most of the stock
      # brake horsepower is air power divided by impeller efficiency
      fan_brake_hp = (fan_static_pressure * design_airflow_for_sizing_m_3_per_s) / (fan_impeller_efficiency * 745.7)
      # size the motor the way openstudio-standards sizes baseline fan motors, or the upgraded fan can be less efficient than the one it replaces:
      # the 90.1 table is indexed by nominal nameplate size and brake horsepower is about 90% of it (Thornton et al. 2011),
      # so prototype_fan_apply_prototype_fan_efficiency looks up at brake_hp * 1.1; the rounding nudge is copied from that method
      fan_nominal_motor_hp = fan_brake_hp * 1.1
      if fan_nominal_motor_hp > 0.1
        fan_nominal_motor_hp = fan_nominal_motor_hp.round(2) + 0.0001
      elsif fan_nominal_motor_hp < 0.01
        fan_nominal_motor_hp = 0.01
      end
      fan_motor_efficiency, fan_nominal_hp = std.fan_standard_minimum_motor_efficiency_and_size(new_fan, fan_nominal_motor_hp)
      new_fan.setMotorEfficiency(fan_motor_efficiency)
      new_fan.setFanTotalEfficiency(fan_impeller_efficiency * fan_motor_efficiency)

      # the fan power minimum flow fraction is the lowest stage flow the equipment can deliver, from this scenario's staging
      # (nominally 0.59 for two-speed units and 0.40 for four-stage units), with three floors:
      # - the realised lowest stage airflow, which is absolute m3/s and so is divided by the loop design airflow
      #   (the staging hashes are on a different basis and can hold false where a stage was removed)
      # - the turndown the json specifies, because the cfm/ton guard can push a lowest stage below it
      #   (e.g. variable-speed heating stage 1 from 0.40 to 0.28, roughly halving fan power) and must not credit unspecified turndown;
      #   EnergyPlus still moves the lower airflow, only the power curve is floored, which is the conservative direction
      # - the minimum OA ratio, which is a physical floor
      stage_flows_all = (stage_flows_heating.values + stage_flows_cooling.values).select { |v| v.is_a?(Numeric) && v > 0 }
      lowest_stage_flow_ratio = if stage_flows_all.empty? || design_airflow_for_sizing_m_3_per_s.to_f <= 0
                                  min_flow
                                else
                                  stage_flows_all.min / design_airflow_for_sizing_m_3_per_s
                                end
      fan_min_flow_ratio = [lowest_stage_flow_ratio, specified_min_flow_fraction.to_f, current_min_oa_flow_ratio].max
      fan_min_flow_ratio = [fan_min_flow_ratio, 1.0].min
      new_fan.setFanPowerMinimumFlowFraction(fan_min_flow_ratio)

      if debug_verbose
        runner.registerInfo("fan summary: scenario=#{hprtu_scenario} | fan_type=#{fan_type} | impeller_eff=#{fan_impeller_efficiency.round(3)} | " \
                            "bhp=#{fan_brake_hp.round(2)} | nominal_hp=#{fan_nominal_hp} | motor_eff=#{fan_motor_efficiency.round(3)} | " \
                            "total_eff=#{(fan_impeller_efficiency * fan_motor_efficiency).round(3)} | " \
                            "lowest_stage_flow=#{lowest_stage_flow_ratio} | specified_min_flow=#{specified_min_flow_fraction} | " \
                            "min_oa_ratio=#{current_min_oa_flow_ratio.round(3)} | " \
                            "fan_min_flow=#{fan_min_flow_ratio.round(3)}")
      end

      # ---------------------------------------------------------
      # unitary system
      # ---------------------------------------------------------
      new_air_to_air_heatpump = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
      new_air_to_air_heatpump.setName("#{air_loop_hvac.name} Unitary Heat Pump System")
      new_air_to_air_heatpump.setSupplyFan(new_fan)
      new_air_to_air_heatpump.setHeatingCoil(new_dx_heating_coil)
      new_air_to_air_heatpump.setCoolingCoil(new_dx_cooling_coil)
      new_air_to_air_heatpump.setSupplementalHeatingCoil(new_backup_heating_coil)
      new_air_to_air_heatpump.addToNode(air_loop_hvac.supplyOutletNode)
      new_air_to_air_heatpump.setControllingZoneorThermostatLocation(control_zone)
      new_air_to_air_heatpump.setFanPlacement('DrawThrough')
      new_air_to_air_heatpump.setAvailabilitySchedule(unitary_availability_sched)
      new_air_to_air_heatpump.setDehumidificationControlType(dehumid_type)
      new_air_to_air_heatpump.setSupplyAirFanOperatingModeSchedule(supply_fan_op_sched)
      new_air_to_air_heatpump.setControlType('Load')
      new_air_to_air_heatpump.setName("#{thermal_zone.name} RTU SZ-VAV Heat Pump")
      new_air_to_air_heatpump.setMaximumSupplyAirTemperature(50)
      new_air_to_air_heatpump.setDXHeatingCoilSizingRatio(1 + performance_oversizing_factor)

      # handle deprecated methods for OS Version 3.7.0
      if model.version < OpenStudio::VersionString.new('3.7.0')
        new_air_to_air_heatpump.resetSupplyAirFlowRateMethodWhenNoCoolingorHeatingisRequired
      end
      # design flow rates for cooling, heating, and no load
      new_air_to_air_heatpump.setSupplyAirFlowRateDuringCoolingOperation(stage_flows_cooling[num_cooling_stages])
      new_air_to_air_heatpump.setSupplyAirFlowRateDuringHeatingOperation(stage_flows_heating[num_heating_stages])
      new_air_to_air_heatpump.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(min_airflow_m3_per_s)

      # ---------------------------------------------------------
      # outdoor air controls
      # ---------------------------------------------------------
      # demand control ventilation
      controller_oa.controllerMechanicalVentilation.setDemandControlledVentilation(true) if dcv

      # economizer; differential enthalpy with a 75F drybulb limit per 90.1-2013 for all climates, and integrated with heating
      if econ
        controller_oa.setEconomizerControlType('DifferentialEnthalpy')
        controller_oa.setEconomizerMaximumLimitDryBulbTemperature(OpenStudio.convert(75, 'F', 'C').get)
        controller_oa.setLockoutType('LockoutWithHeating')
      end

      # make sure any existing economizer is integrated, or it will not work with the multispeed coil
      controller_oa.setLockoutType('LockoutWithHeating') unless controller_oa.getEconomizerControlType == 'NoEconomizer'

      # ---------------------------------------------------------
      # energy recovery
      # ---------------------------------------------------------
      # existing ERV components are removed and replaced if the ERV flag is selected; otherwise they remain in place as-is
      erv_components = []
      air_loop_hvac.oaComponents.each do |component|
        component_name = component.name.to_s
        next if component_name.include? 'Node'

        erv_components << component if component_name.include? 'ERV'
      end
      erv_components = erv_components.uniq

      # add energy recovery if specified by user and if the building type is applicable
      next unless hr && btype_erv_applicable

      # skip air loops serving non-applicable space types and warn user
      if name_matches_any?(thermal_zone.name.to_s, ERV_EXCLUDED_ZONE_NAME_WORDS)
        runner.registerWarning("The user selected to add energy recovery to the HP-RTUs, but thermal zone #{thermal_zone.name} is a non-applicable space type for energy recovery. Any existing energy recovery will remain for consistancy, but no new energy recovery will be added.")
        next
      end

      # replace existing ERV equipment with new ERV equipment
      erv_components.each(&:remove)
      oa_sys = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      std.air_loop_hvac_apply_energy_recovery_ventilator(air_loop_hvac, climate_zone)

      # design outdoor air flow rate, used to estimate wheel "fan" power
      oa_flow_m3_per_s = 0
      air_loop_hvac.thermalZones.each do |tz|
        space = tz.spaces[0]
        fa = tz.floorArea * tz.multiplier
        vol = tz.airVolume * tz.multiplier
        num_people = tz.numberOfPeople * tz.multiplier
        next unless space.designSpecificationOutdoorAir.is_initialized

        dsn_spec_oa = space.designSpecificationOutdoorAir.get
        oa_flow_m3_per_s += dsn_spec_oa.outdoorAirFlowperFloorArea * fa
        oa_flow_m3_per_s += dsn_spec_oa.outdoorAirFlowperPerson * num_people
        oa_flow_m3_per_s += (dsn_spec_oa.outdoorAirFlowAirChangesperHour * vol) / 60
      end

      oa_sys.oaComponents.each do |oa_comp|
        next unless oa_comp.to_HeatExchangerAirToAirSensibleAndLatent.is_initialized

        hx = oa_comp.to_HeatExchangerAirToAirSensibleAndLatent.get
        # controls
        hx.setSupplyAirOutletTemperatureControl(true)
        hx.setEconomizerLockout(true)
        hx.setFrostControlType('MinimumExhaustTemperature')
        hx.setThresholdTemperature(1.66667) # 35F, from E+ recommendation
        hx.setHeatExchangerType('Rotary') # rotary is used for fan power modulation when bypass is active; only affects supply temp control with bypass

        # setpoint manager OA pretreat to control the ERV
        spm_oa_pretreat = OpenStudio::Model::SetpointManagerOutdoorAirPretreat.new(air_loop_hvac.model)
        spm_oa_pretreat.setMinimumSetpointTemperature(-99.0)
        spm_oa_pretreat.setMaximumSetpointTemperature(99.0)
        spm_oa_pretreat.setMinimumSetpointHumidityRatio(0.00001)
        spm_oa_pretreat.setMaximumSetpointHumidityRatio(1.0)
        # reference setpoint node and mixed air stream node are the outlet node of the OA system
        mixed_air_node = oa_sys.mixedAirModelObject.get.to_Node.get
        spm_oa_pretreat.setReferenceSetpointNode(mixed_air_node)
        spm_oa_pretreat.setMixedAirStreamNode(mixed_air_node)
        # outdoor air node is the outboard OA node of the OA system
        spm_oa_pretreat.setOutdoorAirStreamNode(oa_sys.outboardOANode.get)
        # return air node is the inlet node of the OA system
        return_air_node = oa_sys.returnAirModelObject.get.to_Node.get
        spm_oa_pretreat.setReturnAirStreamNode(return_air_node)
        # attach to the outlet of the HX
        hx_outlet = hx.primaryAirOutletModelObject.get.to_Node.get
        spm_oa_pretreat.addToNode(hx_outlet)

        # effectiveness; assumes 90% of airflow returned to the unit
        case doas_type
        when 'ERV'
          hx.setSensibleEffectivenessat100HeatingAirFlow(0.75 * 0.9)
          hx.setSensibleEffectivenessat75HeatingAirFlow(0.78 * 0.9)
          hx.setLatentEffectivenessat100HeatingAirFlow(0.61 * 0.9)
          hx.setLatentEffectivenessat75HeatingAirFlow(0.68 * 0.9)
          hx.setSensibleEffectivenessat100CoolingAirFlow(0.75 * 0.9)
          hx.setSensibleEffectivenessat75CoolingAirFlow(0.78 * 0.9)
          hx.setLatentEffectivenessat100CoolingAirFlow(0.55 * 0.9)
          hx.setLatentEffectivenessat75CoolingAirFlow(0.60 * 0.9)
        when 'HRV'
          hx.setSensibleEffectivenessat100HeatingAirFlow(0.84 * 0.9)
          hx.setSensibleEffectivenessat75HeatingAirFlow(0.86 * 0.9)
          hx.setLatentEffectivenessat100HeatingAirFlow(0)
          hx.setLatentEffectivenessat75HeatingAirFlow(0)
          hx.setSensibleEffectivenessat100CoolingAirFlow(0.83 * 0.9)
          hx.setSensibleEffectivenessat75CoolingAirFlow(0.84 * 0.9)
          hx.setLatentEffectivenessat100CoolingAirFlow(0)
          hx.setLatentEffectivenessat75CoolingAirFlow(0)
        end

        # wheel power; fan efficiency ranges from 40-60% (Energy Modeling Guide for Very High Efficiency DOAS Final Report)
        default_fan_efficiency = 0.55
        power = (oa_flow_m3_per_s * 174.188 / default_fan_efficiency) + ((oa_flow_m3_per_s * 0.9 * 124.42) / default_fan_efficiency)
        hx.setNominalElectricPower(power)
      end
    end

    # report final condition of model
    condition_final_hprtu = "The building finished with heat pump RTUs replacing the HVAC equipment for #{selected_air_loops.size} air loops."
    condition_final = [condition_final_hprtu, condition_final_roof, condition_final_window].reject(&:empty?).join(' | ')
    runner.registerFinalCondition(condition_final)

    true
  end
end

# register the measure to be used by the application
AddHeatPumpRtu.new.registerWithApplication
