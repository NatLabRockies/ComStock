# frozen_string_literal: true

# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/
require 'comstock-typical'
Dir[File.dirname(__FILE__) + '/resources/*.rb'].each { |file| require file }

# start the measure
class AddHeatPumpRtu < OpenStudio::Measure::ModelMeasure
  # defining global variable
  # adding tolerance because EnergyPlus unit conversion differs from manual conversion
  # reference: https://github.com/NREL/EnergyPlus/blob/337bfbadf019a80052578d1bad6112dca43036db/src/EnergyPlus/DataHVACGlobals.hh#L362-L368
  CFM_PER_TON_MIN_RATED = 300 # hard limit of 300
  CFM_PER_TON_MAX_RATED = 450 # hard limit of 450
  # CFM_PER_TON_MIN_OPERATIONAL = 200 # hard limit of 200 for operational minimum threshold for both heating/cooling
  # CFM_PER_TON_MAX_OPERATIONAL_HEATING = 600 # hard limit of 600 for operational maximum threshold for both heating
  # CFM_PER_TON_MAX_OPERATIONAL_COOLING = 500 # hard limit of 500 for operational maximum threshold for both cooling

  # human readable name
  def name
    # Measure name should be the title case of the class name.
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

    # make list of backup heat options
    li_backup_heat_options = %w[match_original_primary_heating_fuel electric_resistance_backup]
    v_backup_heat_options = OpenStudio::StringVector.new
    li_backup_heat_options.each do |option|
      v_backup_heat_options << option
    end
    # add backup heat option arguments
    backup_ht_fuel_scheme = OpenStudio::Measure::OSArgument.makeChoiceArgument('backup_ht_fuel_scheme',
                                                                               v_backup_heat_options, true)
    backup_ht_fuel_scheme.setDisplayName('Backup Heat Type')
    backup_ht_fuel_scheme.setDescription('Specifies if the backup heat fuel type is a gas furnace or electric resistance coil. If match original primary heating fuel is selected, the heating fuel type will match the primary heating fuel type of the original model. If electric resistance is selected, AHUs will get electric resistance backup.')
    backup_ht_fuel_scheme.setDefaultValue('electric_resistance_backup')
    args << backup_ht_fuel_scheme

    # add RTU oversizing factor for heating
    performance_oversizing_factor = OpenStudio::Measure::OSArgument.makeDoubleArgument('performance_oversizing_factor',
                                                                                       true)
    performance_oversizing_factor.setDisplayName('Maximum Performance Oversizing Factor')
    performance_oversizing_factor.setDefaultValue(0)
    performance_oversizing_factor.setDescription('When heating design load exceeds cooling design load, the design cooling capacity of the unit will only be allowed to increase up to this factor to accomodate additional heating capacity. Oversizing the compressor beyond 25% can cause cooling cycling issues, even with variable speed compressors.')
    args << performance_oversizing_factor

    # heating sizing options TODO
    li_htg_sizing_option = ['47F', '17F', '0F', '-10F']
    v_htg_sizing_option = OpenStudio::StringVector.new
    li_htg_sizing_option.each do |option|
      v_htg_sizing_option << option
    end

    htg_sizing_option = OpenStudio::Measure::OSArgument.makeChoiceArgument('htg_sizing_option', li_htg_sizing_option,
                                                                           true)
    htg_sizing_option.setDefaultValue('0F')
    htg_sizing_option.setDisplayName('Temperature to Sizing Heat Pump, F')
    htg_sizing_option.setDescription('Specifies temperature to size heating on. If design temperature for climate is higher than specified, program will use design temperature. Heat pump sizing will not exceed user-input oversizing factor.')
    args << htg_sizing_option

    # add assumed oversizing factor for cooling
    clg_oversizing_estimate = OpenStudio::Measure::OSArgument.makeDoubleArgument('clg_oversizing_estimate', true)
    clg_oversizing_estimate.setDisplayName('Cooling Upsizing Factor Estimate')
    clg_oversizing_estimate.setDefaultValue(1)
    clg_oversizing_estimate.setDescription('RTU selection involves sizing up to unit that meets your capacity needs, which creates natural oversizing. This factor estimates this oversizing. E.G. the sizing calc may require 8.7 tons of cooling, but the size options are 7.5 tons and 10 tons, so you choose the 10 ton unit. A value of 1 means to upsizing.')
    args << clg_oversizing_estimate

    # add ratio of heating to cooling
    htg_to_clg_hp_ratio = OpenStudio::Measure::OSArgument.makeDoubleArgument('htg_to_clg_hp_ratio', true)
    htg_to_clg_hp_ratio.setDisplayName('Rated HP Heating to Cooling Ratio')
    htg_to_clg_hp_ratio.setDefaultValue(1)
    htg_to_clg_hp_ratio.setDescription('At rated conditions, a compressor will generally have slightly more cooling capacity than heating capacity. This factor integrates this ratio into the unit sizing.')
    args << htg_to_clg_hp_ratio

    # add heat pump minimum compressor lockout outdoor air temperature
    hp_min_comp_lockout_temp_f = OpenStudio::Measure::OSArgument.makeDoubleArgument('hp_min_comp_lockout_temp_f', true)
    hp_min_comp_lockout_temp_f.setDisplayName('Minimum outdoor air temperature that locks out heat pump compressor, F')
    hp_min_comp_lockout_temp_f.setDefaultValue(0.0)
    hp_min_comp_lockout_temp_f.setDescription('Specifies minimum outdoor air temperature for locking out heat pump compressor. Heat pump heating does not operated below this temperature and backup heating will operate if heating is still needed.')
    args << hp_min_comp_lockout_temp_f

    # make list of cchpc scenarios
    li_hprtu_scenarios = %w[two_speed_standard_eff two_speed_lab_data variable_speed_high_eff cchpc_2027_spec]
    v_li_hprtu_scenarios = OpenStudio::StringVector.new
    li_hprtu_scenarios.each do |option|
      v_li_hprtu_scenarios << option
    end
    # add cold climate heat pump challenge hp rtu scenario arguments
    hprtu_scenario = OpenStudio::Measure::OSArgument.makeChoiceArgument('hprtu_scenario', v_li_hprtu_scenarios, true)
    hprtu_scenario.setDisplayName('Heat Pump RTU Performance Type')
    hprtu_scenario.setDescription('Determines performance assumptions. two_speed_standard_eff is a standard efficiency system with 2 staged compressors (2 stages cooling, 1 stage heating). two_speed_lab_data is similar to two_speed_standard_eff but uses lab testing data to inform performance rather than public curves from manufacturers. variable_speed_high_eff is a higher efficiency variable speed system. cchpc_2027_spec is a hypothetical 4-stage unit intended to meet the requirements of the cold climate heat pump RTU challenge 2027 specification.  ')
    hprtu_scenario.setDefaultValue('two_speed_standard_eff')
    args << hprtu_scenario

    # add heat recovery option
    hr = OpenStudio::Measure::OSArgument.makeBoolArgument('hr', true)
    hr.setDisplayName('Add Energy Recovery?')
    hr.setDefaultValue(false)
    args << hr

    # add dcv option
    dcv = OpenStudio::Measure::OSArgument.makeBoolArgument('dcv', true)
    dcv.setDisplayName('Add Demand Control Ventilation?')
    dcv.setDefaultValue(false)
    args << dcv

    # add economizer option
    econ = OpenStudio::Measure::OSArgument.makeBoolArgument('econ', true)
    econ.setDisplayName('Add Economizer?')
    econ.setDefaultValue(false)
    args << econ

    # add roof insulation option
    roof = OpenStudio::Measure::OSArgument.makeBoolArgument('roof', true)
    roof.setDisplayName('Upgrade Roof Insulation?')
    roof.setDescription('Upgrade roof insulation per AEDG recommendations.')
    roof.setDefaultValue(false)
    args << roof

    # upgrade window option
    window = OpenStudio::Measure::OSArgument.makeBoolArgument('window', true)
    window.setDisplayName('Upgrade Windows?')
    window.setDescription('Upgrade window per AEDG recommendations.')
    window.setDefaultValue(false)
    args << window

    # do a sizing run for sizing?
    sizing_run = OpenStudio::Measure::OSArgument.makeBoolArgument('sizing_run', true)
    sizing_run.setDisplayName('Do a sizing run for informing sizing instead of using hard-sized model parameters?')
    sizing_run.setDefaultValue(false)
    args << sizing_run

    # do a sizing run for sizing?
    debug_verbose = OpenStudio::Measure::OSArgument.makeBoolArgument('debug_verbose', true)
    debug_verbose.setDisplayName('Print out detailed debugging logs if this parameter is true')
    debug_verbose.setDefaultValue(false)
    args << debug_verbose

    # modify setbacks or not
    modify_setbacks = OpenStudio::Measure::OSArgument.makeBoolArgument('modify_setbacks', false)
    modify_setbacks.setDisplayName('Modify setbacks in heating mode? True will adjust setbacks, according to value in setback value argument.')
    modify_setbacks.setDefaultValue(true)
    args << modify_setbacks

    # setback value
    setback_value = OpenStudio::Measure::OSArgument.makeDoubleArgument('setback_value', false)
    setback_value.setDisplayName('Amount in deg F by which temperatures are set back during unoccupied periods in heating mode. Done only if modify setbacks is set to true.')
    setback_value.setDefaultValue(2)
    args << setback_value

    args
  end

  # define the outputs that the measure will create
  def outputs
    # outs = OpenStudio::Measure::OSOutputVector.new
    output_names = []

    result = OpenStudio::Measure::OSOutputVector.new
    output_names.each do |output|
      result << OpenStudio::Measure::OSOutput.makeDoubleOutput(output)
    end

    result
  end

  #### Predefined functions
  # determine if the air loop is residential (checks to see if there is outdoor air system object)
  def air_loop_res?(air_loop_hvac)
    is_res_system = true
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_AirLoopHVAC_OutdoorAirSystem'
        is_res_system = false
      end
    end
    is_res_system
  end

  # Determine if is evaporative cooler
  def air_loop_evaporative_cooler?(air_loop_hvac)
    is_evap = false
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_EvaporativeCooler_Direct_ResearchSpecial', 'OS_EvaporativeCooler_Indirect_ResearchSpecial', 'OS_EvaporativeFluidCooler_SingleSpeed', 'OS_EvaporativeFluidCooler_TwoSpeed'
        is_evap = true
      end
    end
    is_evap
  end

  # Determine if the air loop is a unitary system
  # @return [Bool] Returns true if a unitary system is present, false if not.
  def air_loop_hvac_unitary_system?(air_loop_hvac)
    is_unitary_system = false
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_AirLoopHVAC_UnitarySystem', 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir', 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir_MultiSpeed', 'OS_AirLoopHVAC_UnitaryHeatCool_VAVChangeoverBypass'
        is_unitary_system = true
      end
    end
    is_unitary_system
  end

  # Load curve to model from json
  # modified version from OS Standards to read from custom json file
  def model_add_curve(model, curve_name, standards_data_curve, std)
    # First check model and return curve if it already exists
    existing_curves = []
    existing_curves += model.getCurveLinears
    existing_curves += model.getCurveCubics
    existing_curves += model.getCurveQuadratics
    existing_curves += model.getCurveBicubics
    existing_curves += model.getCurveBiquadratics
    existing_curves += model.getCurveQuadLinears
    existing_curves.sort.each do |curve|
      if curve.name.get.to_s == curve_name
        # OpenStudio.logFree(OpenStudio::Debug, 'openstudio.standards.Model', "Already added curve: #{curve_name}")
        return curve
      end
    end

    # OpenStudio::logFree(OpenStudio::Info, "openstudio.prototype.addCurve", "Adding curve '#{curve_name}' to the model.")

    # Find curve data
    data = std.model_find_object(standards_data_curve['tables']['curves'], 'name' => curve_name)
    if data.nil?
      # OpenStudio.logFree(OpenStudio::Warn, 'openstudio.Model.Model', "Could not find a curve called '#{curve_name}' in the standards.")
      return nil
    end

    # Make the correct type of curve
    case data['form']
    when 'Linear'
      curve = OpenStudio::Model::CurveLinear.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'])
      curve.setCoefficient2x(data['coeff_2'])
      curve.setMinimumValueofx(data['minimum_independent_variable_1']) if data['minimum_independent_variable_1']
      curve.setMaximumValueofx(data['maximum_independent_variable_1']) if data['maximum_independent_variable_1']
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
      end
      curve
    when 'Cubic'
      curve = OpenStudio::Model::CurveCubic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'])
      curve.setCoefficient2x(data['coeff_2'])
      curve.setCoefficient3xPOW2(data['coeff_3'])
      curve.setCoefficient4xPOW3(data['coeff_4'])
      curve.setMinimumValueofx(data['minimum_independent_variable_1']) if data['minimum_independent_variable_1']
      curve.setMaximumValueofx(data['maximum_independent_variable_1']) if data['maximum_independent_variable_1']
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
      end
      curve
    when 'Quadratic'
      curve = OpenStudio::Model::CurveQuadratic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'])
      curve.setCoefficient2x(data['coeff_2'])
      curve.setCoefficient3xPOW2(data['coeff_3'])
      curve.setMinimumValueofx(data['minimum_independent_variable_1']) if data['minimum_independent_variable_1']
      curve.setMaximumValueofx(data['maximum_independent_variable_1']) if data['maximum_independent_variable_1']
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
      end
      curve
    when 'BiCubic'
      curve = OpenStudio::Model::CurveBicubic.new(model)
      curve.setName(data['name'])
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
      curve.setMinimumValueofx(data['minimum_independent_variable_1']) if data['minimum_independent_variable_1']
      curve.setMaximumValueofx(data['maximum_independent_variable_1']) if data['maximum_independent_variable_1']
      curve.setMinimumValueofy(data['minimum_independent_variable_2']) if data['minimum_independent_variable_2']
      curve.setMaximumValueofy(data['maximum_independent_variable_2']) if data['maximum_independent_variable_2']
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
      end
      curve
    when 'BiQuadratic'
      curve = OpenStudio::Model::CurveBiquadratic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'])
      curve.setCoefficient2x(data['coeff_2'])
      curve.setCoefficient3xPOW2(data['coeff_3'])
      curve.setCoefficient4y(data['coeff_4'])
      curve.setCoefficient5yPOW2(data['coeff_5'])
      curve.setCoefficient6xTIMESY(data['coeff_6'])
      curve.setMinimumValueofx(data['minimum_independent_variable_1']) if data['minimum_independent_variable_1']
      curve.setMaximumValueofx(data['maximum_independent_variable_1']) if data['maximum_independent_variable_1']
      curve.setMinimumValueofy(data['minimum_independent_variable_2']) if data['minimum_independent_variable_2']
      curve.setMaximumValueofy(data['maximum_independent_variable_2']) if data['maximum_independent_variable_2']
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
      end
      curve
    when 'BiLinear'
      curve = OpenStudio::Model::CurveBiquadratic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'])
      curve.setCoefficient2x(data['coeff_2'])
      curve.setCoefficient4y(data['coeff_3'])
      curve.setMinimumValueofx(data['minimum_independent_variable_1']) if data['minimum_independent_variable_1']
      curve.setMaximumValueofx(data['maximum_independent_variable_1']) if data['maximum_independent_variable_1']
      curve.setMinimumValueofy(data['minimum_independent_variable_2']) if data['minimum_independent_variable_2']
      curve.setMaximumValueofy(data['maximum_independent_variable_2']) if data['maximum_independent_variable_2']
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
      end
      curve
    when 'QuadLinear'
      curve = OpenStudio::Model::CurveQuadLinear.new(model)
      curve.setName(data['name'])
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
      table.setName(data['name'])
      table.setNormalizationDivisor(data['normalization_reference'].to_f)
      table.setOutputUnitType(data['output_unit_type'])
      data_points = data.each.select { |key, _value| key.include? 'data_point' }
      data_points = data_points.sort_by { |item| item[1].split(',').map(&:to_f) } # sorting data in ascending order
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
  end

  # Assign staging data from json
  def assign_staging_data(staging_data_json, std)
    # Parse the JSON string into a Ruby hash
    # Find curve data
    staging_data = std.model_find_object(staging_data_json['tables']['curves'], 'name' => 'staging_data')
    return nil if staging_data.nil?

    # Check cchpc value and assign variables from JSON data
    num_heating_stages = staging_data['num_heating_stages']
    num_cooling_stages = staging_data['num_cooling_stages']
    rated_stage_num_heating = staging_data['rated_stage_num_heating']
    rated_stage_num_cooling = staging_data['rated_stage_num_cooling']
    final_rated_cooling_cop = staging_data['final_rated_cooling_cop']
    final_rated_heating_cop = staging_data['final_rated_heating_cop']
    stage_cap_fractions_heating = eval(staging_data['stage_cap_fractions_heating'])
    stage_flow_fractions_heating = eval(staging_data['stage_flow_fractions_heating'])
    stage_cap_fractions_cooling = eval(staging_data['stage_cap_fractions_cooling'])
    stage_flow_fractions_cooling = eval(staging_data['stage_flow_fractions_cooling'])
    stage_rated_cop_frac_heating = eval(staging_data['stage_rated_cop_frac_heating'])
    stage_rated_cop_frac_cooling = eval(staging_data['stage_rated_cop_frac_cooling'])
    boost_stage_num_and_max_temp_tuple = eval(staging_data['boost_stage_num_and_max_temp_tuple'])
    stage_gross_rated_sensible_heat_ratio_cooling = eval(staging_data['stage_gross_rated_sensible_heat_ratio_cooling'])
    enable_cycling_losses_above_lowest_speed = staging_data['enable_cycling_losses_above_lowest_speed']
    reference_cooling_cfm_per_ton = staging_data['reference_cooling_cfm_per_ton']
    reference_heating_cfm_per_ton = staging_data['reference_cooling_cfm_per_ton']

    # Return assigned variables
    [num_heating_stages, num_cooling_stages, rated_stage_num_heating, rated_stage_num_cooling, final_rated_cooling_cop, final_rated_heating_cop, stage_cap_fractions_heating, stage_flow_fractions_heating,
     stage_cap_fractions_cooling, stage_flow_fractions_cooling, stage_rated_cop_frac_heating, stage_rated_cop_frac_cooling, boost_stage_num_and_max_temp_tuple, stage_gross_rated_sensible_heat_ratio_cooling,
     enable_cycling_losses_above_lowest_speed, reference_cooling_cfm_per_ton, reference_heating_cfm_per_ton]
  end

  # Get rated cooling COP from fitted regression
  # based on actual product performances (Carrier/Lennox) which meet 2023 federal minimum efficiency requirements
  # reflecting rated COP without blower power and blower heat gain
  def get_rated_cop_cooling(rated_capacity_w)
    intercept = 3.881009
    coef_1 = -0.01034
    min_cop = 3.02
    max_cop = 3.97
    rated_capacity_kw = rated_capacity_w / 1000 # W to kW
    rated_cop_cooling = intercept + (coef_1 * rated_capacity_kw)
    rated_cop_cooling.clamp(min_cop, max_cop)
  end

  # Get rated heating COP from fitted regression
  # based on actual product performances (Carrier/Lennox) which meet 2023 federal minimum efficiency requirements
  # reflecting rated COP without blower power and blower heat gain
  def get_rated_cop_heating(rated_capacity_w)
    intercept = 3.957724
    coef_1 = -0.008502
    min_cop = 3.46
    max_cop = 3.99
    rated_capacity_kw = rated_capacity_w / 1000 # W to kW
    rated_cop_heating = intercept + (coef_1 * rated_capacity_kw)
    rated_cop_heating.clamp(min_cop, max_cop)
  end

  # Get rated cooling COP from fitted regression - for advanced HP RTU (from Daikin Rebel data)
  def get_rated_cop_cooling_adv(rated_capacity_w)
    intercept = 4.140806
    coef_1 = -0.007577
    min_cop = 3.34
    max_cop = 4.29
    rated_capacity_kw = rated_capacity_w / 1000 # W to kW
    rated_cop_cooling = intercept + (coef_1 * rated_capacity_kw)
    rated_cop_cooling.clamp(min_cop, max_cop)
  end

  # Get rated heating COP from fitted regression - for advanced HP RTU (from Daikin Rebel data)
  def get_rated_cop_heating_adv(rated_capacity_w)
    intercept = 3.861114
    coef_1 = -0.003304
    min_cop = 3.5
    max_cop = 3.87
    rated_capacity_kw = rated_capacity_w / 1000 # W to kW
    rated_cop_heating = intercept + (coef_1 * rated_capacity_kw)
    rated_cop_heating.clamp(min_cop, max_cop)
  end

  # Convert unit
  def cfm_per_ton_to_m_3_per_sec_watts(cfm_per_ton)
    OpenStudio.convert(OpenStudio.convert(cfm_per_ton, 'cfm', 'm^3/s').get, 'W', 'ton').get
  end

  # Convert unit
  def m_3_per_sec_watts_to_cfm_per_ton(m_3_per_sec_watts)
    OpenStudio.convert(OpenStudio.convert(m_3_per_sec_watts, 'm^3/s', 'cfm').get, 'ton', 'W').get
  end

  # Adjust rated COP based on reference CFM/ton
  def adjust_rated_cop_from_ref_cfm_per_ton(runner, airflow_sized_m_3_per_s, reference_cfm_per_ton, rated_capacity_w,
                                            original_rated_cop, eir_modifier_curve_flow)
    # get reference airflow
    airflow_reference_m_3_per_s = cfm_per_ton_to_m_3_per_sec_watts(reference_cfm_per_ton) * rated_capacity_w

    # get flow fraction
    flow_fraction = airflow_sized_m_3_per_s / airflow_reference_m_3_per_s

    # calculate modifiers
    modifier_eir = nil
    if eir_modifier_curve_flow.to_CurveBiquadratic.is_initialized
      modifier_eir = eir_modifier_curve_flow.evaluate(flow_fraction, 0)
    elsif eir_modifier_curve_flow.to_CurveCubic.is_initialized
      modifier_eir = eir_modifier_curve_flow.evaluate(flow_fraction)
    elsif eir_modifier_curve_flow.to_CurveQuadratic.is_initialized
      modifier_eir = eir_modifier_curve_flow.evaluate(flow_fraction)
    else
      runner.registerError("CurveBiquadratic|CurveQuadratic|CurveCubic are only supported at the moment for modifier_eir (function of flow fraction) calculation: eir_modifier_curve_flow = #{eir_modifier_curve_flow.name}")
    end

    # adjust rated COP (COP = 1 / EIR)
    original_rated_cop * (1.0 / modifier_eir)
  end

  # Adjust CFM/ton based on limits
  def adjust_cfm_per_ton_per_limits(stage_cap_fractions, stage_flows, stage_flow_fractions, dx_rated_cap_applied,
                                    rated_stage_num, old_terminal_sa_flow_m3_per_s, min_airflow_ratio, air_loop_hvac, heating_or_cooling, runner, debug_verbose)
    # determine capacities for each stage
    # this is based on user-input capacities for each stage and any upsizing applied
    # Flow per ton will be maintained between 300 CFM/Ton and 450 CFM/Ton
    # If current capacity fractions and airflow violate this for lower speeds, those speeds will set to false
    # If the highest speed is violated, the max airflow will be increased to accommodate.
    stage_caps = {}
    # Calculate and store each stage's capacity
    stage_cap_fractions.sort.each do |stage, ratio|
      # define cfm/ton bounds
      cfm_per_ton_min = CFM_PER_TON_MIN_RATED
      cfm_per_ton_max = CFM_PER_TON_MAX_RATED
      m_3_per_s_per_w_min = cfm_per_ton_to_m_3_per_sec_watts(cfm_per_ton_min)
      m_3_per_s_per_w_max = cfm_per_ton_to_m_3_per_sec_watts(cfm_per_ton_max)

      # Calculate the airflow for the current stage
      airflow = stage_flows[stage]
      # Calculate the capacity for the current stage considering upsizing
      stage_capacity = dx_rated_cap_applied * ratio
      # Calculate the flow per ton
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

      # If flow/ton is less than minimum, increase airflow of stage to meet minimum
      if (flow_per_ton.round(8) < m_3_per_s_per_w_min.round(8)) && (stage < rated_stage_num)
        # calculate minimum airflow to achieve
        new_stage_airflow = m_3_per_s_per_w_min * stage_capacity
        # update airflow
        stage_flows[stage] = new_stage_airflow
        # update airflow fraction
        stage_flow_fractions[stage] = new_stage_airflow / old_terminal_sa_flow_m3_per_s # TODO: - need to check if we can go over design airflow. If so, need to adjust min OA.
        stage_caps[stage] = stage_capacity
        if debug_verbose
          runner.registerInfo('stage summary: entered flow/ton too low loop....')
          runner.registerInfo("stage summary: #{air_loop_hvac.name} | cfm/ton low limit violation | #{heating_or_cooling} | stage = #{stage} | cfm/ton after adjustment = #{m_3_per_sec_watts_to_cfm_per_ton(stage_flows[stage] / stage_caps[stage])}")
        end
      # If flow/ton is greater than maximum,
      elsif (flow_per_ton.round(8) > m_3_per_s_per_w_max.round(8)) && (stage < rated_stage_num)
        # reduce airflow of stage without violating minimum flow or outdoor air requirements
        # if maximum flow/ton ratio cannot be accommodated without violating minimum airflow ratios
        # if cfm/ton limit can't be met by reducing airflow, allow increase capacity of up to 65% range between capacities
        # calculate maximum allowable ratio, no more than 50% increase between specified stages

        if debug_verbose
          runner.registerInfo('stage summary: entered flow/ton too high loop....')
          runner.registerInfo("stage summary: air_loop_hvac: #{air_loop_hvac.name}")
          runner.registerInfo("stage summary: ratio: #{ratio}")
          runner.registerInfo("stage summary: stage: #{stage}")
          runner.registerInfo("stage summary: stage_cap_fractions: #{stage_cap_fractions}")
          runner.registerInfo("stage summary: dx_rated_cap_applied: #{dx_rated_cap_applied}")
        end

        ratio_allowance_50_pct = ratio + (stage_cap_fractions[stage + 1] - ratio) * 0.65
        required_stage_cap_ratio = airflow / m_3_per_s_per_w_max / (stage_cap_fractions[rated_stage_num] * dx_rated_cap_applied)
        stage_airflow_limit_max = m_3_per_s_per_w_max * stage_capacity
        # if not violating min airflow requirement
        if (stage_airflow_limit_max / old_terminal_sa_flow_m3_per_s) >= min_airflow_ratio
          stage_flows[stage] = stage_airflow_limit_max
          stage_flow_fractions[stage] = stage_airflow_limit_max / old_terminal_sa_flow_m3_per_s
          stage_caps[stage] = stage_capacity
          if debug_verbose
            runner.registerInfo("stage summary: #{air_loop_hvac.name} | cfm/ton high limit violation | #{heating_or_cooling} | stage = #{stage} | cfm/ton after adjustment = #{m_3_per_sec_watts_to_cfm_per_ton(stage_flows[stage] / stage_caps[stage])}")
          end
        # when equal or less than 50% ratio allowance
        elsif required_stage_cap_ratio <= ratio_allowance_50_pct
          stage_cap_fractions[stage] = required_stage_cap_ratio
          stage_caps[stage] = required_stage_cap_ratio * (stage_cap_fractions[rated_stage_num] * dx_rated_cap_applied)
          if debug_verbose
            runner.registerInfo("stage summary: #{air_loop_hvac.name} | cfm/ton high limit violation (ratio_allowance_50_pct) | #{heating_or_cooling} | stage = #{stage} | cfm/ton after adjustment = #{m_3_per_sec_watts_to_cfm_per_ton(stage_flows[stage] / stage_caps[stage])}")
          end
        # we need at least 2 stages; apply the allowance value and accept some degree of being out of range
        elsif stage == (rated_stage_num - 1)
          stage_cap_fractions[stage] = ratio_allowance_50_pct
          stage_caps[stage] = ratio_allowance_50_pct * (stage_cap_fractions[rated_stage_num] * dx_rated_cap_applied)
          if debug_verbose
            runner.registerInfo("stage summary: #{air_loop_hvac.name} | cfm/ton high limit violation (rated_stage_num) | #{heating_or_cooling} | stage = #{stage} | cfm/ton after adjustment = #{m_3_per_sec_watts_to_cfm_per_ton(stage_flows[stage] / stage_caps[stage])}")
          end
        # remove stage if maximum flow/ton ratio cannot be accommodated without violating minimum airflow ratios
        else
          runner.registerInfo('stage summary: stage removed') if debug_verbose
          stage_flows[stage] = false
          stage_flow_fractions[stage] = false
          stage_caps[stage] = false
          stage_cap_fractions[stage] = false
          if debug_verbose
            runner.registerInfo("stage summary: #{air_loop_hvac.name} | cfm/ton high limit violation (removing stage) | #{heating_or_cooling} | stage = #{stage} | cfm/ton after adjustment = n/a")
          end
        end
      # Do nothing if not violated
      else
        stage_caps[stage] = stage_capacity
        if debug_verbose
          runner.registerInfo('stage summary: entered no adjustment loop')
          runner.registerInfo("stage summary: #{air_loop_hvac.name} | no cfm/ton violation | #{heating_or_cooling} | stage = #{stage} | cfm/ton = #{m_3_per_sec_watts_to_cfm_per_ton(stage_flows[stage] / stage_caps[stage])}")
        end
      end
    end

    # get updated number of stages
    num_stages = stage_caps.length

    [stage_flows, stage_caps, stage_flow_fractions, stage_cap_fractions, num_stages]
  end

  # Set coling coil stages in relevant objects/fields
  def set_cooling_coil_stages(model, runner, stage_flows_cooling, stage_caps_cooling, num_cooling_stages, final_rated_cooling_cop, cool_cap_ft_curve_stages, cool_eir_ft_curve_stages,
                              cool_cap_ff_curve_stages, cool_eir_ff_curve_stages, cool_plf_fplr1, stage_rated_cop_frac_cooling, stage_gross_rated_sensible_heat_ratio_cooling,
                              rated_stage_num_cooling, enable_cycling_losses_above_lowest_speed, air_loop_hvac, always_on, _stage_caps_heating, debug_verbose)
    if (stage_flows_cooling.values.count(&:itself)) == (stage_caps_cooling.values.count(&:itself))
      num_cooling_stages = stage_flows_cooling.values.count(&:itself)
      if debug_verbose
        runner.registerInfo("stage summary: The final number of cooling stages for #{air_loop_hvac.name} is #{num_cooling_stages}.")
      end
    else
      runner.registerError("For airloop #{air_loop_hvac.name}, the number of stages of cooling capacity is different from number of stages of cooling airflow. Revise measure as needed.")
    end

    # use single speed DX cooling coil if only 1 speed
    new_dx_cooling_coil = nil
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
      # For crankcase heater, conversion is watts to tons
      # methods from "TECHNICAL SUPPORT DOCUMENT: ENERGY EFFICIENCY PROGRAM FOR CONSUMER PRODUCTS AND COMMERCIAL AND INDUSTRIAL EQUIPMENT AIR-COOLED COMMERCIAL UNITARY AIR CONDITIONERS AND COMMERCIAL UNITARY HEAT PUMPS"
      crankcase_heater_power = ((60 * (stage_caps_cooling[rated_stage_num_cooling] * 0.0002843451 / 10)**0.67))
      new_dx_cooling_coil.setCrankcaseHeaterCapacity(crankcase_heater_power)
      new_dx_cooling_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(-25)

    # use multi speed DX cooling coil if multiple speeds are defined
    else

      # define multi speed cooling coil
      new_dx_cooling_coil = OpenStudio::Model::CoilCoolingDXMultiSpeed.new(model)
      new_dx_cooling_coil.setName("#{air_loop_hvac.name} Heat Pump Cooling Coil")
      new_dx_cooling_coil.setCondenserType('AirCooled')
      new_dx_cooling_coil.setAvailabilitySchedule(always_on)
      new_dx_cooling_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(-25)
      new_dx_cooling_coil.setApplyPartLoadFractiontoSpeedsGreaterthan1(enable_cycling_losses_above_lowest_speed)
      new_dx_cooling_coil.setApplyLatentDegradationtoSpeedsGreaterthan1(false)
      new_dx_cooling_coil.setFuelType('Electricity')
      new_dx_cooling_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(4.4)
      # methods from "TECHNICAL SUPPORT DOCUMENT: ENERGY EFFICIENCY PROGRAM FOR CONSUMER PRODUCTS AND COMMERCIAL AND INDUSTRIAL EQUIPMENT AIR-COOLED COMMERCIAL UNITARY AIR CONDITIONERS AND COMMERCIAL UNITARY HEAT PUMPS"
      crankcase_heater_power = ((60 * (stage_caps_cooling[rated_stage_num_cooling] * 0.0002843451 / 10)**0.67))
      new_dx_cooling_coil.setCrankcaseHeaterCapacity(crankcase_heater_power)
      new_dx_cooling_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(-25)

      # loop through stages
      stage_caps_cooling.sort.each do |stage, cap|
        # use current stage if allowed; otherwise use highest available stage as "dummy"
        # this is a temporary workaround until OS translator supports different numbers of speed levels between heating and cooling
        # GitHub issue: https://github.com/NREL/OpenStudio/issues/5277
        applied_stage = stage
        applied_stage = stage_caps_cooling.reject { |_k, v| v == false }.keys.min if cap == false

        # add speed data for each stage
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

        # add speed data to multispeed coil object
        new_dx_cooling_coil.addStage(dx_coil_speed_data) # unless stage_caps_heating[stage] == false
      end
    end
    new_dx_cooling_coil
  end

  # Set coling coil stages in relevant objects/fields
  def set_heating_coil_stages(model, runner, stage_flows_heating, stage_caps_heating, num_heating_stages, final_rated_heating_cop, heat_cap_ft_curve_stages, heat_eir_ft_curve_stages,
                              heat_cap_ff_curve_stages, heat_eir_ff_curve_stages, heat_plf_fplr1, defrost_eir, _stage_rated_cop_frac_heating, rated_stage_num_heating, air_loop_hvac, hp_min_comp_lockout_temp_f,
                              enable_cycling_losses_above_lowest_speed, always_on, _stage_caps_cooling, debug_verbose)
    # validate number of stages
    if (stage_flows_heating.values.count(&:itself)) == (stage_caps_heating.values.count(&:itself))
      num_heating_stages = stage_flows_heating.values.count(&:itself)
      if debug_verbose
        runner.registerInfo("stage summary: num_heating_stages: #{num_heating_stages}")
        runner.registerInfo("stage summary: The final number of heating stages for #{air_loop_hvac.name} is #{num_heating_stages}.")
      end
    else
      runner.registerError("For airloop #{air_loop_hvac.name}, the number of stages of heating capacity is different from number of stages of heating airflow. Revise measure as needed.")
    end

    # use single speed DX heating coil if only 1 speed
    new_dx_heating_coil = nil
    if num_heating_stages == 1
      new_dx_heating_coil = OpenStudio::Model::CoilHeatingDXSingleSpeed.new(model)
      new_dx_heating_coil.setName("#{air_loop_hvac.name} Heat Pump heating Coil")
      new_dx_heating_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(OpenStudio.convert(
        hp_min_comp_lockout_temp_f, 'F', 'C'
      ).get)
      new_dx_heating_coil.setAvailabilitySchedule(always_on)
      new_dx_heating_coil.setRatedTotalHeatingCapacity(stage_caps_heating[rated_stage_num_heating])
      new_dx_heating_coil.setRatedAirFlowRate(stage_flows_heating[rated_stage_num_heating])
      new_dx_heating_coil.setRatedCOP(final_rated_heating_cop)
      new_dx_heating_coil.setRatedSupplyFanPowerPerVolumeFlowRate2017(773.3)
      # set performance curves
      new_dx_heating_coil.setTotalHeatingCapacityFunctionofTemperatureCurve(heat_cap_ft_curve_stages[rated_stage_num_heating])
      new_dx_heating_coil.setTotalHeatingCapacityFunctionofFlowFractionCurve(heat_cap_ff_curve_stages[rated_stage_num_heating])
      new_dx_heating_coil.setEnergyInputRatioFunctionofTemperatureCurve(heat_eir_ft_curve_stages[rated_stage_num_heating])
      new_dx_heating_coil.setEnergyInputRatioFunctionofFlowFractionCurve(heat_eir_ff_curve_stages[rated_stage_num_heating])
      new_dx_heating_coil.setPartLoadFractionCorrelationCurve(heat_plf_fplr1)
      # For crankcase heater, conversion is watts to tons
      # methods from "TECHNICAL SUPPORT DOCUMENT: ENERGY EFFICIENCY PROGRAM FOR CONSUMER PRODUCTS AND COMMERCIAL AND INDUSTRIAL EQUIPMENT AIR-COOLED COMMERCIAL UNITARY AIR CONDITIONERS AND COMMERCIAL UNITARY HEAT PUMPS"
      crankcase_heater_power = ((60 * (stage_caps_heating[rated_stage_num_heating] * 0.0002843451 / 10)**0.67))
      new_dx_heating_coil.setCrankcaseHeaterCapacity(crankcase_heater_power)
      new_dx_heating_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(4.4)
      new_dx_heating_coil.setDefrostEnergyInputRatioFunctionofTemperatureCurve(defrost_eir)
      new_dx_heating_coil.setMaximumOutdoorDryBulbTemperatureforDefrostOperation(4.444)
      new_dx_heating_coil.setDefrostStrategy('ReverseCycle')
      new_dx_heating_coil.setDefrostControl('OnDemand')
      new_dx_heating_coil.setDefrostTimePeriodFraction(0.058333)

    # use multi speed DX heating coil if multiple speeds are defined
    else
      # define multi speed heating coil
      new_dx_heating_coil = OpenStudio::Model::CoilHeatingDXMultiSpeed.new(model)
      new_dx_heating_coil.setName("#{air_loop_hvac.name} Heat Pump heating Coil")
      new_dx_heating_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(OpenStudio.convert(
        hp_min_comp_lockout_temp_f, 'F', 'C'
      ).get)
      new_dx_heating_coil.setAvailabilitySchedule(always_on)
      new_dx_heating_coil.setApplyPartLoadFractiontoSpeedsGreaterthan1(enable_cycling_losses_above_lowest_speed)
      new_dx_heating_coil.setFuelType('Electricity')
      # methods from "TECHNICAL SUPPORT DOCUMENT: ENERGY EFFICIENCY PROGRAM FOR CONSUMER PRODUCTS AND COMMERCIAL AND INDUSTRIAL EQUIPMENT AIR-COOLED COMMERCIAL UNITARY AIR CONDITIONERS AND COMMERCIAL UNITARY HEAT PUMPS"
      crankcase_heater_power = ((60 * (stage_caps_heating[rated_stage_num_heating] * 0.0002843451 / 10)**0.67))
      new_dx_heating_coil.setCrankcaseHeaterCapacity(crankcase_heater_power)
      new_dx_heating_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(4.4)
      new_dx_heating_coil.setDefrostEnergyInputRatioFunctionofTemperatureCurve(defrost_eir)
      new_dx_heating_coil.setMaximumOutdoorDryBulbTemperatureforDefrostOperation(4.444)
      new_dx_heating_coil.setDefrostStrategy('ReverseCycle')
      new_dx_heating_coil.setDefrostControl('OnDemand')
      new_dx_heating_coil.setDefrostTimePeriodFraction(0.058333)
      new_dx_heating_coil.setFuelType('Electricity')

      # loop through stages
      stage_caps_heating.sort.each do |stage, cap|
        # use current stage if allowed; otherwise use highest available stage as "dummy"
        # the stage that is actually used to articulate the speed level is the 'applied_stage'
        # this is a temporary workaround until OS translator supports different numbers of speed levels between heating and cooling
        # GitHub issue: https://github.com/NREL/OpenStudio/issues/5277
        applied_stage = stage
        applied_stage = stage_caps_heating.reject { |_k, v| v == false }.keys.min if cap == false

        # add speed data for each stage
        dx_coil_speed_data = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
        dx_coil_speed_data.setGrossRatedHeatingCapacity(stage_caps_heating[applied_stage])
        dx_coil_speed_data.setGrossRatedHeatingCOP(final_rated_heating_cop * _stage_rated_cop_frac_heating[applied_stage])
        dx_coil_speed_data.setRatedAirFlowRate(stage_flows_heating[applied_stage])
        dx_coil_speed_data.setRatedSupplyAirFanPowerPerVolumeFlowRate2017(773.3)
        dx_coil_speed_data.setHeatingCapacityFunctionofTemperatureCurve(heat_cap_ft_curve_stages[applied_stage])
        # set performance curves
        dx_coil_speed_data.setHeatingCapacityFunctionofTemperatureCurve(heat_cap_ft_curve_stages[applied_stage])
        dx_coil_speed_data.setHeatingCapacityFunctionofFlowFractionCurve(heat_cap_ff_curve_stages[applied_stage])
        dx_coil_speed_data.setEnergyInputRatioFunctionofTemperatureCurve(heat_eir_ft_curve_stages[applied_stage])
        dx_coil_speed_data.setEnergyInputRatioFunctionofFlowFractionCurve(heat_eir_ff_curve_stages[applied_stage])
        dx_coil_speed_data.setPartLoadFractionCorrelationCurve(heat_plf_fplr1)
        # add speed data to multispeed coil object
        new_dx_heating_coil.addStage(dx_coil_speed_data) # falseunless stage_caps_cooling[stage] == false # temporary 'unless' until bug fix for (https://github.com/NREL/OpenStudio/issues/5277)
      end
    end
    new_dx_heating_coil
  end

  # Get tabular data from sql file
  def get_tabular_data(runner, _model, sql, report_name, report_for_string, table_name, row_name, column_name)
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

  def self.get_dep_var_from_lookup_table_with_interpolation(runner, lookup_table, input1, input2)
    if lookup_table.independentVariables.size == 2
      # Extract independent variable arrays
      ind_var_1 = lookup_table.independentVariables[0].values.to_a
      ind_var_2 = lookup_table.independentVariables[1].values.to_a
      dep_var = lookup_table.outputValues.to_a

      if ind_var_1.size * ind_var_2.size != dep_var.size
        runner.registerError("Table dimensions do not match output size for TableLookup object: #{lookup_table.name}")
        return false
      end

      # Clamp input1 to bounds
      if input1 < ind_var_1.first
        runner.registerWarning("input1 (#{input1}) below range, clamping to #{ind_var_1.first}")
        input1 = ind_var_1.first
      elsif input1 > ind_var_1.last
        runner.registerWarning("input1 (#{input1}) above range, clamping to #{ind_var_1.last}")
        input1 = ind_var_1.last
      end

      # Clamp input2 to bounds
      if input2 < ind_var_2.first
        runner.registerWarning("input2 (#{input2}) below range, clamping to #{ind_var_2.first}")
        input2 = ind_var_2.first
      elsif input2 > ind_var_2.last
        runner.registerWarning("input2 (#{input2}) above range, clamping to #{ind_var_2.last}")
        input2 = ind_var_2.last
      end

      # Find bounding indices for input1
      i1_upper = ind_var_1.index { |val| val >= input1 } || (ind_var_1.size - 1)
      i1_lower = [i1_upper - 1, 0].max

      # Find bounding indices for input2
      i2_upper = ind_var_2.index { |val| val >= input2 } || (ind_var_2.size - 1)
      i2_lower = [i2_upper - 1, 0].max

      x1 = ind_var_1[i1_lower]
      x2 = ind_var_1[i1_upper]
      y1 = ind_var_2[i2_lower]
      y2 = ind_var_2[i2_upper]

      # Get dependent variable values for bilinear interpolation
      v11 = dep_var[i1_lower * ind_var_2.size + i2_lower]  # (x1, y1)
      v12 = dep_var[i1_lower * ind_var_2.size + i2_upper]  # (x1, y2)
      v21 = dep_var[i1_upper * ind_var_2.size + i2_lower]  # (x2, y1)
      v22 = dep_var[i1_upper * ind_var_2.size + i2_upper]  # (x2, y2)

      # If exact match, return directly
      if input1 == x1 && input2 == y1
        return v11
      elsif input1 == x1 && input2 == y2
        return v12
      elsif input1 == x2 && input2 == y1
        return v21
      elsif input1 == x2 && input2 == y2
        return v22
      end

      # Handle edge cases where interpolation becomes linear
      dx = x2 - x1
      dy = y2 - y1
      return v11 if dx == 0 && dy == 0
      return v11 + (v21 - v11) * (input1 - x1) / dx if dy == 0
      return v11 + (v12 - v11) * (input2 - y1) / dy if dx == 0

      # Bilinear interpolation
      interpolated_value =
        v11 * (x2 - input1) * (y2 - input2) +
        v21 * (input1 - x1) * (y2 - input2) +
        v12 * (x2 - input1) * (input2 - y1) +
        v22 * (input1 - x1) * (input2 - y1)

      interpolated_value /= (x2 - x1) * (y2 - y1)

      interpolated_value
    else
      runner.registerError('TableLookup object does not have exactly two independent variables.')
      false
    end
  end

  def opt_start?(sch_zone_occ_annual_profile, htg_schedule_annual_profile, min_value, max_value, idx)
    # method to determine if a thermostat schedule contains part of an optimum start sequence at a given index
    if (sch_zone_occ_annual_profile[idx + 1] == 1 || sch_zone_occ_annual_profile[idx + 2] == 1) &&
       (htg_schedule_annual_profile[idx] > min_value && htg_schedule_annual_profile[idx] < max_value)
      true
    end
  end

  #### End predefined functions

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # ---------------------------------------------------------
    # use the built-in error checking
    # ---------------------------------------------------------
    return false unless runner.validateUserArguments(arguments(model), user_arguments)

    # ---------------------------------------------------------
    # assign the user inputs to variables
    # ---------------------------------------------------------
    backup_ht_fuel_scheme = runner.getStringArgumentValue('backup_ht_fuel_scheme', user_arguments)
    performance_oversizing_factor = runner.getDoubleArgumentValue('performance_oversizing_factor', user_arguments)
    htg_sizing_option = runner.getStringArgumentValue('htg_sizing_option', user_arguments)
    clg_oversizing_estimate = runner.getDoubleArgumentValue('clg_oversizing_estimate', user_arguments)
    htg_to_clg_hp_ratio = runner.getDoubleArgumentValue('htg_to_clg_hp_ratio', user_arguments)
    hp_min_comp_lockout_temp_f = runner.getDoubleArgumentValue('hp_min_comp_lockout_temp_f', user_arguments)
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
    # ---------------------------------------------------------
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)

    # ---------------------------------------------------------
    # get applicable psz hvac air loops
    # ---------------------------------------------------------
    selected_air_loops = []
    applicable_area_m2 = 0
    prim_ht_fuel_type = 'electric' # we assume electric unless we find a gas coil in any air loop
    is_sizing_run_needed = true
    unitary_sys = nil
    orig_airloop_heating_coil_map = {}
    model.getAirLoopHVACs.each do |air_loop_hvac|
      # skip units that are not single zone
      next if air_loop_hvac.thermalZones.length > 1

      # skip DOAS units; check sizing for all OA and for DOAS in name
      sizing_system = air_loop_hvac.sizingSystem
      if sizing_system.allOutdoorAirinCooling && sizing_system.allOutdoorAirinHeating && (air_loop_res?(air_loop_hvac) == false) && (air_loop_hvac.name.to_s.include?('DOAS') || air_loop_hvac.name.to_s.include?('doas'))
        next
      end

      # skip if already heat pump RTU
      # loop throug air loop components to check for heat pump or water coils
      is_hp = false
      is_water_coil = false
      has_heating_coil = true
      air_loop_hvac.supplyComponents.each do |component|
        obj_type = component.iddObjectType.valueName.to_s
        # flag system if contains water coil; this will cause air loop to be skipped
        is_water_coil = true if %w[Coil_Heating_Water Coil_Cooling_Water].any? { |word| obj_type.include?(word) }
        # flag gas heating as true if gas coil is found in any airloop
        prim_ht_fuel_type = 'gas' if %w[Gas GAS gas].any? { |word| obj_type.include?(word) }
        # check unitary systems for DX heating or water coils
        if obj_type == 'OS_AirLoopHVAC_UnitarySystem'
          unitary_sys = component.to_AirLoopHVACUnitarySystem.get

          # check if heating coil is DX or water-based; if so, flag the air loop to be skipped
          if unitary_sys.heatingCoil.is_initialized
            htg_coil = unitary_sys.heatingCoil.get.iddObjectType.valueName.to_s
            # check for DX heating coil
            if ['Heating_DX'].any? { |word| htg_coil.include?(word) }
              is_hp = true
            # check for water heating coil
            elsif ['Water'].any? { |word| htg_coil.include?(word) }
              is_water_coil = true
            # check for gas heating
            elsif %w[Gas GAS gas].any? { |word| htg_coil.include?(word) }
              prim_ht_fuel_type = 'gas'
            end
          else
            runner.registerWarning("No heating coil was found for air loop: #{air_loop_hvac.name} - this equipment will be skipped.")
            has_heating_coil = false
          end
          # check if cooling coil is water-based
          if unitary_sys.coolingCoil.is_initialized
            clg_coil = unitary_sys.coolingCoil.get.iddObjectType.valueName.to_s
            # skip unless coil is water based
            next unless ['Water'].any? { |word| clg_coil.include?(word) }

            is_water_coil = true
          end
        # flag as hp if air loop contains a heating dx coil
        elsif ['Heating_DX'].any? { |word| obj_type.include?(word) }
          is_hp = true
        end
      end
      # also skip based on string match, or if dx heating component existed
      if (is_hp == true) | (air_loop_hvac.name.to_s.include?('HP') || air_loop_hvac.name.to_s.include?('hp') || air_loop_hvac.name.to_s.include?('heat pump') || air_loop_hvac.name.to_s.include?('Heat Pump'))
        next
      end
      # skip data centers
      next if ['Data Center', 'DataCenter', 'data center', 'datacenter', 'DATACENTER', 'DATA CENTER'].any? do |word|
                air_loop_hvac.name.get.include?(word)
              end
      # skip kitchens
      next if %w[Kitchen KITCHEN Kitchen].any? { |word| air_loop_hvac.name.get.include?(word) }
      # skip VAV sysems
      next if %w[VAV PVAV].any? { |word| air_loop_hvac.name.get.include?(word) }
      # skip if residential system
      next if air_loop_res?(air_loop_hvac)
      # skip if system has no outdoor air, also indication of residential system
      next unless air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized
      # skip if evaporative cooling systems
      next if air_loop_evaporative_cooler?(air_loop_hvac)
      # skip if water heating or cooled system
      next if is_water_coil == true
      # skip if space is not heated and cooled
      unless OpenstudioStandards::ThermalZone.thermal_zone_heated?(air_loop_hvac.thermalZones[0]) && OpenstudioStandards::ThermalZone.thermal_zone_cooled?(air_loop_hvac.thermalZones[0])
        next
      end
      # next if no heating coil
      next if has_heating_coil == false

      # add applicable air loop to list
      selected_air_loops << air_loop_hvac
      # add area served by air loop
      thermal_zone = air_loop_hvac.thermalZones[0]
      applicable_area_m2 += thermal_zone.floorArea * thermal_zone.multiplier

      ############# Determine if equipment has been hardsized to avoid sizing run
      oa_flow_m3_per_s = nil
      old_terminal_sa_flow_m3_per_s = nil
      orig_clg_coil_gross_cap = nil
      orig_htg_coil_gross_cap = nil

      # determine if sizing run is needed
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      controller_oa = oa_system.getControllerOutdoorAir
      if controller_oa.minimumOutdoorAirFlowRate.is_initialized
        oa_flow_m3_per_s = controller_oa.minimumOutdoorAirFlowRate.get
      end

      # get design supply air flow rate
      if air_loop_hvac.designSupplyAirFlowRate.is_initialized
        old_terminal_sa_flow_m3_per_s = air_loop_hvac.designSupplyAirFlowRate.get
      end

      # get previous cooling coil capacity
      orig_clg_coil = unitary_sys.coolingCoil.get
      if orig_clg_coil.to_CoilCoolingDXSingleSpeed.is_initialized
        orig_clg_coil = orig_clg_coil.to_CoilCoolingDXSingleSpeed.get
        # get either autosized or specified cooling capacityet
        if orig_clg_coil.ratedTotalCoolingCapacity.is_initialized
          orig_clg_coil_gross_cap = orig_clg_coil.ratedTotalCoolingCapacity.to_f
        end
      end

      # get original heating coil capacity
      orig_htg_coil = unitary_sys.heatingCoil.get
      # get coil object if electric resistance
      if orig_htg_coil.to_CoilHeatingElectric.is_initialized
        orig_htg_coil = orig_htg_coil.to_CoilHeatingElectric.get
      # get coil object if gas
      elsif orig_htg_coil.to_CoilHeatingGas.is_initialized
        orig_htg_coil = orig_htg_coil.to_CoilHeatingGas.get
      end
      # get either autosized or specified capacity
      orig_htg_coil_gross_cap = orig_htg_coil.nominalCapacity.to_f if orig_htg_coil.nominalCapacity.is_initialized

      # map heating coil with airloop name for sizing algorithm later
      orig_airloop_heating_coil_map[air_loop_hvac.name.to_s] = orig_htg_coil.name.to_s.upcase

      # only require sizing run if required attributes have not been hardsized.
      next if oa_flow_m3_per_s.nil?
      next if old_terminal_sa_flow_m3_per_s.nil?
      next if orig_clg_coil_gross_cap.nil?
      next if orig_htg_coil_gross_cap.nil?

      is_sizing_run_needed = false
    end

    # ---------------------------------------------------------
    # check if any air loops are applicable to measure
    # ---------------------------------------------------------
    if selected_air_loops.empty?
      runner.registerAsNotApplicable('No applicable air loops in model. No changes will be made.')
      return true
    end

    # call roof and/or window upgrades based on user input
    condition_initial_roof = ''
    condition_final_roof = ''
    condition_initial_window = ''
    condition_final_window = ''
    unless selected_air_loops.empty?
      if roof == true
        runner.registerInfo('Running Roof Insulation measure....')
        results_roof, runner = call_roof(model, runner)
        if results_roof.stepInitialCondition.is_initialized
          condition_initial_roof = results_roof.stepInitialCondition.get
        end
        condition_final_roof = results_roof.stepFinalCondition.get if results_roof.stepFinalCondition.is_initialized
      end
      if window == true
        runner.registerInfo('Running New Windows measure....')
        results_window, runner = call_windows(model, runner)
        if results_window.stepInitialCondition.is_initialized
          condition_initial_roof = results_window.stepInitialCondition.get
        end
        condition_final_roof = results_window.stepFinalCondition.get if results_window.stepFinalCondition.is_initialized
      end
    end

    # ---------------------------------------------------------
    # do sizing run with new equipment to set sizing-specific features
    # ---------------------------------------------------------
    if (is_sizing_run_needed == true) || (sizing_run == true)
      runner.registerInfo('sizing summary: sizing run needed')
      return false if std.model_run_sizing_run(model, "#{Dir.pwd}/SR1") == false

      model.applySizingValues if is_sizing_run_needed == true
    end

    # ---------------------------------------------------------
    # get sql from sizing run
    # ---------------------------------------------------------
    sql = nil
    if sizing_run == true
      # get sql (for extracting sizing information)
      sql = model.sqlFile
      if sql.empty?
        runner.registerError('Cannot find last sql file.')
        return false
      end
      sql = sql.get if sql.is_initialized
    end

    #########################################################################################################
    ### This section includes temporary code to remove units with high OA fractiosn and night cycling
    ### This code should be removed when fix is initiated
    # add systems with high outdoor air ratios to a list for non-applicability
    oa_ration_allowance = 0.55
    selected_air_loops.each do |air_loop_hvac|
      thermal_zone = air_loop_hvac.thermalZones[0]

      # get the min OA flow rate for calculating unit OA fraction
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      controller_oa = oa_system.getControllerOutdoorAir
      oa_flow_m3_per_s = nil
      if controller_oa.minimumOutdoorAirFlowRate.is_initialized
        oa_flow_m3_per_s = controller_oa.minimumOutdoorAirFlowRate.get
      elsif controller_oa.autosizedMinimumOutdoorAirFlowRate.is_initialized
        oa_flow_m3_per_s = controller_oa.autosizedMinimumOutdoorAirFlowRate.get
      else
        runner.registerError("No outdoor air sizing information was found for #{controller_oa.name}, which is required for setting ERV wheel power consumption.")
        return false
      end

      # get design supply air flow rate
      old_terminal_sa_flow_m3_per_s = nil
      if air_loop_hvac.designSupplyAirFlowRate.is_initialized
        old_terminal_sa_flow_m3_per_s = air_loop_hvac.designSupplyAirFlowRate.get
      elsif air_loop_hvac.isDesignSupplyAirFlowRateAutosized
        old_terminal_sa_flow_m3_per_s = air_loop_hvac.autosizedDesignSupplyAirFlowRate.get
      else
        runner.registerError("No sizing data available for air loop #{air_loop_hvac.name} zone terminal box.")
      end

      # define minimum flow rate needed to maintain ventilation - add in max fraction if in model
      min_oa_flow_ratio = (oa_flow_m3_per_s / old_terminal_sa_flow_m3_per_s)

      # check to see if there is night cycling operation for unit
      night_cyc_sched_vals = []
      air_loop_hvac.supplyComponents.each do |component|
        # convert component to string name
        obj_type = component.iddObjectType.valueName.to_s
        # skip unless component is of relevant type
        next unless ['Unitary'].any? { |word| obj_type.include?(word) }

        unitary_sys = component.to_AirLoopHVACUnitarySystem.get
        # get supply fan operating schedule
        next unless unitary_sys.supplyAirFanOperatingModeSchedule.is_initialized

        sf_sched = unitary_sys.supplyAirFanOperatingModeSchedule.get
        if sf_sched.to_ScheduleRuleset.is_initialized
          sf_sched = sf_sched.to_ScheduleRuleset.get
        elsif sf_sched.to_ScheduleConstant.is_initialized
          sf_sched = sf_sched.to_ScheduleConstant.get
        end

        if sf_sched.to_ScheduleRuleset.is_initialized
          sf_sched_rules_ar = sf_sched.scheduleRules
          # loop through schedules in ruleset
          sf_sched_rules_ar.each do |sched_rule|
            sched_values = sched_rule.daySchedule.values
            # loop through schedule values and add to array
            sched_values.each do |value|
              night_cyc_sched_vals << value
            end
          end
        elsif sf_sched.to_ScheduleConstant.is_initialized
          value = sf_sched.value
          night_cyc_sched_vals << value
        end
      end

      # if supply operating schedule does not include a 0, the unit does not night cycle
      unit_night_cycles = night_cyc_sched_vals.include? [0, 0.0]

      # register as not applicable if OA limit exceeded and unit has night cycling schedules
      next unless (min_oa_flow_ratio > oa_ration_allowance) && (unit_night_cycles == true)

      runner.registerWarning("Air loop #{air_loop_hvac.name} has night cycling operations and an outdoor air ratio of #{min_oa_flow_ratio.round(2)} which exceeds the maximum allowable limit of #{oa_ration_allowance} (due to an EnergyPlus night cycling bug with multispeed coils) making this RTU not applicable at this time.")
      # remove air loop from applicable list
      selected_air_loops.delete(air_loop_hvac)
      applicable_area_m2 -= thermal_zone.floorArea * thermal_zone.multiplier
      # remove area served by air loop from applicability
    end
    ### End of temp section
    #########################################################################################################

    # ---------------------------------------------------------
    # check if any air loops are applicable to measure
    # ---------------------------------------------------------
    if selected_air_loops.empty?
      runner.registerAsNotApplicable('No applicable air loops in model. No changes will be made.')
      return true
    end

    # ---------------------------------------------------------
    # get model conditioned square footage for reporting
    # ---------------------------------------------------------
    if model.building.get.conditionedFloorArea.empty?
      runner.registerWarning('model.building.get.conditionedFloorArea() is empty; applicable floor area fraction will not be reported.')
      # report initial condition of model
      condition_initial_hprtu = "The building has #{selected_air_loops.size} applicable air loops (out of the total #{model.getAirLoopHVACs.size} airloops in the model) that will be replaced with heat pump RTUs, serving #{applicable_area_m2.round(0)} m2 of floor area. The remaning airloops were determined to be not applicable."
      condition_initial = [condition_initial_hprtu, condition_initial_roof,
                           condition_initial_window].reject(&:empty?).join(' | ')
      runner.registerInitialCondition(condition_initial)
    else
      total_area_m2 = model.building.get.conditionedFloorArea.get

      # fraction of conditioned floorspace
      applicable_floorspace_frac = applicable_area_m2 / total_area_m2

      # report initial condition of model
      condition_initial_hprtu = "The building has #{selected_air_loops.size} applicable air loops that will be replaced with heat pump RTUs, representing #{(applicable_floorspace_frac * 100).round(2)}% of the building floor area. #{condition_initial_roof}. #{condition_initial_window}."
      condition_initial = [condition_initial_hprtu, condition_initial_roof,
                           condition_initial_window].reject(&:empty?).join(' | ')
      runner.registerInitialCondition(condition_initial)
    end

    # ---------------------------------------------------------
    # applicability checks for heat recovery; building type
    # ---------------------------------------------------------
    # building type not applicable to ERVs as part of this measure will receive no additional or modification of ERV systems
    # this is only relevant if the user selected to add ERVs
    # space type applicability is handled later in the code when looping through individual air loops
    building_types_to_exclude = %w[RFF RSD QuickServiceRestaurant FullServiceRestaurant]
    # determine building type applicability for ERV
    btype_erv_applicable = true
    building_types_to_exclude = building_types_to_exclude.map(&:downcase)
    # get Standards building type name and check against building type applicability list
    model_building_type = nil
    if model.getBuilding.standardsBuildingType.is_initialized
      model_building_type = model.getBuilding.standardsBuildingType.get
    else
      runner.registerError('Building type not found.')
      return true
    end
    # register applicability; this will be used in code section where ERV is added
    btype_erv_applicable = false if building_types_to_exclude.include?(model_building_type.downcase)
    # warn user if they selected to add ERV but building type is not applicable for ERV
    if (hr == true) && (btype_erv_applicable == false)
      runner.registerWarning("The user chose to include energy recovery in the heat pump RTUs, but the building type -#{model_building_type}- is not applicable for energy recovery. Energy recovery will not be added.")
    end

    # get climate full string and classification (i.e. "5A")
    climate_zone = OpenstudioStandards::Weather.model_get_climate_zone(model)
    climate_zone_classification = climate_zone.split('-')[-1]

    # Get ER/HR type from climate zone
    _, _, doas_type =
      if %w[1A 2A 3A 4A 5A 6A 7 7A 8 8A].include?(climate_zone_classification)
        [12.7778, 19.4444, 'ERV']
      else
        [15.5556, 19.4444, 'HRV']
      end

    # ---------------------------------------------------------
    # load performance data for standard performance units
    # ---------------------------------------------------------
    custom_data_json = nil
    # if cchpc scenarios are set, use those curves. else, use the standard performance curves
    case hprtu_scenario
    when 'cchpc_2027_spec'
      # read performance data
      path_data_curve = "#{File.dirname(__FILE__)}/resources/performance_map_CCHP_spec_2027.json"
      custom_data_json = JSON.parse(File.read(path_data_curve))
    when 'variable_speed_high_eff'
      # read performance data
      path_data_curve = "#{File.dirname(__FILE__)}/resources/performance_maps_hprtu_variable_speed.json"
      custom_data_json = JSON.parse(File.read(path_data_curve))
    when 'two_speed_standard_eff'
      # read performance data
      path_data_curve = "#{File.dirname(__FILE__)}/resources/performance_maps_hprtu_std.json"
      custom_data_json = JSON.parse(File.read(path_data_curve))
    when 'two_speed_lab_data'
      # read performance data
      path_data_curve = "#{File.dirname(__FILE__)}/resources/performance_maps_hprtu_lab_data.json"
      custom_data_json = JSON.parse(File.read(path_data_curve))
    end

    # ---------------------------------------------------------
    # define performance curves for cooling
    # ---------------------------------------------------------
    # Curve Import - Cooling capacity as a function of temperature
    case hprtu_scenario
    when 'variable_speed_high_eff'
      cool_cap_ft1 = model_add_curve(model, 'cool_cap_ft1', custom_data_json, std)
      cool_cap_ft2 = model_add_curve(model, 'cool_cap_ft2', custom_data_json, std)
      cool_cap_ft3 = model_add_curve(model, 'cool_cap_ft3', custom_data_json, std)
      cool_cap_ft4 = model_add_curve(model, 'cool_cap_ft4', custom_data_json, std)
      cool_cap_ft_curve_stages = { 1 => cool_cap_ft1, 2 => cool_cap_ft2, 3 => cool_cap_ft3, 4 => cool_cap_ft4 }
    when 'two_speed_standard_eff'
      cool_cap_ft1 = model_add_curve(model, 'c_cap_low_T', custom_data_json, std)
      cool_cap_ft2 = model_add_curve(model, 'c_cap_high_T', custom_data_json, std)
      cool_cap_ft_curve_stages = { 1 => cool_cap_ft1, 2 => cool_cap_ft2 }
    when 'two_speed_lab_data'
      cool_cap_ft1 = model_add_curve(model, 'c_cap_low_T', custom_data_json, std)
      cool_cap_ft2 = model_add_curve(model, 'c_cap_high_T', custom_data_json, std)
      cool_cap_ft_curve_stages = { 1 => cool_cap_ft1, 2 => cool_cap_ft2 }
    when 'cchpc_2027_spec'
      cool_cap_ft1 = model_add_curve(model, 'cool_cap_ft1', custom_data_json, std)
      cool_cap_ft2 = model_add_curve(model, 'cool_cap_ft2', custom_data_json, std)
      cool_cap_ft3 = model_add_curve(model, 'cool_cap_ft3', custom_data_json, std)
      cool_cap_ft4 = model_add_curve(model, 'cool_cap_ft4', custom_data_json, std)
      cool_cap_ft_curve_stages = { 1 => cool_cap_ft1, 2 => cool_cap_ft2, 3 => cool_cap_ft3, 4 => cool_cap_ft4 }
    end

    # Curve Import - Cooling efficiency as a function of temperature
    case hprtu_scenario
    when 'variable_speed_high_eff'
      cool_eir_ft1 = model_add_curve(model, 'cool_eir_ft1', custom_data_json, std)
      cool_eir_ft2 = model_add_curve(model, 'cool_eir_ft2', custom_data_json, std)
      cool_eir_ft3 = model_add_curve(model, 'cool_eir_ft3', custom_data_json, std)
      cool_eir_ft4 = model_add_curve(model, 'cool_eir_ft4', custom_data_json, std)
      cool_eir_ft_curve_stages = { 1 => cool_eir_ft1, 2 => cool_eir_ft2, 3 => cool_eir_ft3, 4 => cool_eir_ft4 }
    when 'two_speed_standard_eff'
      cool_eir_ft1 = model_add_curve(model, 'c_eir_low_T', custom_data_json, std)
      cool_eir_ft2 = model_add_curve(model, 'c_eir_high_T', custom_data_json, std)
      cool_eir_ft_curve_stages = { 1 => cool_eir_ft1, 2 => cool_eir_ft2 }
    when 'two_speed_lab_data'
      cool_eir_ft1 = model_add_curve(model, 'c_eir_low_T', custom_data_json, std)
      cool_eir_ft2 = model_add_curve(model, 'c_eir_high_T', custom_data_json, std)
      cool_eir_ft_curve_stages = { 1 => cool_eir_ft1, 2 => cool_eir_ft2 }
    when 'cchpc_2027_spec'
      cool_eir_ft1 = model_add_curve(model, 'cool_eir_ft1', custom_data_json, std)
      cool_eir_ft2 = model_add_curve(model, 'cool_eir_ft2', custom_data_json, std)
      cool_eir_ft3 = model_add_curve(model, 'cool_eir_ft3', custom_data_json, std)
      cool_eir_ft4 = model_add_curve(model, 'cool_eir_ft4', custom_data_json, std)
      cool_eir_ft_curve_stages = { 1 => cool_eir_ft1, 2 => cool_eir_ft2, 3 => cool_eir_ft3, 4 => cool_eir_ft4 }
    end

    # Curve Import - Cooling capacity as a function of flow rate
    case hprtu_scenario
    when 'variable_speed_high_eff'
      cool_cap_ff1 = model_add_curve(model, 'cool_cap_ff1', custom_data_json, std)
      cool_cap_ff_curve_stages = { 1 => cool_cap_ff1, 2 => cool_cap_ff1, 3 => cool_cap_ff1, 4 => cool_cap_ff1 }
    when 'two_speed_standard_eff'
      cool_cap_ff1 = model_add_curve(model, 'c_cap_low_ff', custom_data_json, std)
      cool_cap_ff2 = model_add_curve(model, 'c_cap_high_ff', custom_data_json, std)
      cool_cap_ff_curve_stages = { 1 => cool_cap_ff1, 2 => cool_cap_ff2 }
    when 'two_speed_lab_data'
      cool_cap_ff1 = model_add_curve(model, 'c_cap_low_ff', custom_data_json, std)
      cool_cap_ff2 = model_add_curve(model, 'c_cap_high_ff', custom_data_json, std)
      cool_cap_ff_curve_stages = { 1 => cool_cap_ff1, 2 => cool_cap_ff2 }
    when 'cchpc_2027_spec'
      cool_cap_ff1 = model_add_curve(model, 'cool_cap_ff1', custom_data_json, std)
      cool_cap_ff_curve_stages = { 1 => cool_cap_ff1, 2 => cool_cap_ff1, 3 => cool_cap_ff1, 4 => cool_cap_ff1 }
    end

    # Curve Import - Cooling efficiency as a function of flow rate
    case hprtu_scenario
    when 'variable_speed_high_eff'
      cool_eir_ff1 = model_add_curve(model, 'cool_eir_ff1', custom_data_json, std)
      cool_eir_ff_curve_stages = { 1 => cool_eir_ff1, 2 => cool_eir_ff1, 3 => cool_eir_ff1, 4 => cool_eir_ff1 }
    when 'two_speed_standard_eff'
      cool_eir_ff1 = model_add_curve(model, 'c_eir_low_ff', custom_data_json, std)
      cool_eir_ff2 = model_add_curve(model, 'c_eir_high_ff', custom_data_json, std)
      cool_eir_ff_curve_stages = { 1 => cool_eir_ff1, 2 => cool_eir_ff2 }
    when 'two_speed_lab_data'
      cool_eir_ff1 = model_add_curve(model, 'c_eir_low_ff', custom_data_json, std)
      cool_eir_ff2 = model_add_curve(model, 'c_eir_high_ff', custom_data_json, std)
      cool_eir_ff_curve_stages = { 1 => cool_eir_ff1, 2 => cool_eir_ff2 }
    when 'cchpc_2027_spec'
      cool_eir_ff1 = model_add_curve(model, 'cool_eir_ff1', custom_data_json, std)
      cool_eir_ff_curve_stages = { 1 => cool_eir_ff1, 2 => cool_eir_ff1, 3 => cool_eir_ff1, 4 => cool_eir_ff1 }
    end

    # Curve Import - Cooling efficiency as a function of part load ratio
    case hprtu_scenario
    when 'variable_speed_high_eff'
      cool_plf_fplr1 = model_add_curve(model, 'cool_plf_plr1', custom_data_json, std)
    when 'two_speed_standard_eff'
      cool_plf_fplr1 = model_add_curve(model, 'cool_plf_plr1', custom_data_json, std)
    when 'two_speed_lab_data'
      cool_plf_fplr1 = model_add_curve(model, 'cool_plf_plr1', custom_data_json, std)
    when 'cchpc_2027_spec'
      cool_plf_fplr1 = model_add_curve(model, 'cool_plf_plr1', custom_data_json, std)
    end

    # ---------------------------------------------------------
    # define performance curves for heating
    # ---------------------------------------------------------
    # Curve Import - Heating capacity as a function of temperature
    case hprtu_scenario
    when 'variable_speed_high_eff'
      heat_cap_ft1 = model_add_curve(model, 'heat_cap_ft1', custom_data_json, std)
      heat_cap_ft2 = model_add_curve(model, 'heat_cap_ft2', custom_data_json, std)
      heat_cap_ft3 = model_add_curve(model, 'heat_cap_ft3', custom_data_json, std)
      heat_cap_ft4 = model_add_curve(model, 'heat_cap_ft4', custom_data_json, std)
      heat_cap_ft_curve_stages = { 1 => heat_cap_ft1, 2 => heat_cap_ft2, 3 => heat_cap_ft3, 4 => heat_cap_ft4 }
    when 'two_speed_standard_eff'
      heat_cap_ft1 = model_add_curve(model, 'h_cap_T', custom_data_json, std)
      heat_cap_ft_curve_stages = { 1 => heat_cap_ft1 }
    when 'two_speed_lab_data'
      heat_cap_ft1 = model_add_curve(model, 'h_cap_T', custom_data_json, std)
      heat_cap_ft_curve_stages = { 1 => heat_cap_ft1 }
    when 'cchpc_2027_spec'
      heat_cap_ft1 = model_add_curve(model, 'h_cap_low', custom_data_json, std)
      heat_cap_ft2 = model_add_curve(model, 'h_cap_medium', custom_data_json, std)
      heat_cap_ft3 = model_add_curve(model, 'h_cap_high', custom_data_json, std)
      heat_cap_ft4 = model_add_curve(model, 'h_cap_boost', custom_data_json, std)
      heat_cap_ft_curve_stages = { 1 => heat_cap_ft1, 2 => heat_cap_ft2, 3 => heat_cap_ft3, 4 => heat_cap_ft4 }
    end

    # Curve Import - Heating efficiency as a function of temperature
    case hprtu_scenario
    when 'variable_speed_high_eff'
      heat_eir_ft1 = model_add_curve(model, 'heat_eir_ft1', custom_data_json, std)
      heat_eir_ft2 = model_add_curve(model, 'heat_eir_ft2', custom_data_json, std)
      heat_eir_ft3 = model_add_curve(model, 'heat_eir_ft3', custom_data_json, std)
      heat_eir_ft4 = model_add_curve(model, 'heat_eir_ft4', custom_data_json, std)
      heat_eir_ft_curve_stages = { 1 => heat_eir_ft1, 2 => heat_eir_ft2, 3 => heat_eir_ft3, 4 => heat_eir_ft4 }
    when 'two_speed_standard_eff'
      heat_eir_ft1 = model_add_curve(model, 'h_eir_T', custom_data_json, std)
      heat_eir_ft_curve_stages = { 1 => heat_eir_ft1 }
    when 'two_speed_lab_data'
      heat_eir_ft1 = model_add_curve(model, 'h_eir_T', custom_data_json, std)
      heat_eir_ft_curve_stages = { 1 => heat_eir_ft1 }
    when 'cchpc_2027_spec'
      heat_eir_ft1 = model_add_curve(model, 'h_eir_low', custom_data_json, std)
      heat_eir_ft2 = model_add_curve(model, 'h_eir_medium', custom_data_json, std)
      heat_eir_ft3 = model_add_curve(model, 'h_eir_high', custom_data_json, std)
      heat_eir_ft4 = model_add_curve(model, 'h_eir_boost', custom_data_json, std)
      heat_eir_ft_curve_stages = { 1 => heat_eir_ft1, 2 => heat_eir_ft2, 3 => heat_eir_ft3, 4 => heat_eir_ft4 }
    end

    # Curve Import - Heating capacity as a function of flow rate
    case hprtu_scenario
    when 'variable_speed_high_eff'
      heat_cap_ff1 = model_add_curve(model, 'heat_cap_ff1', custom_data_json, std)
      heat_cap_ff_curve_stages = { 1 => heat_cap_ff1, 2 => heat_cap_ff1, 3 => heat_cap_ff1, 4 => heat_cap_ff1 }
    when 'two_speed_standard_eff'
      heat_cap_ff1 = model_add_curve(model, 'h_cap_allstages_ff', custom_data_json, std)
      heat_cap_ff_curve_stages = { 1 => heat_cap_ff1 }
    when 'two_speed_lab_data'
      heat_cap_ff1 = model_add_curve(model, 'h_cap_allstages_ff', custom_data_json, std)
      heat_cap_ff_curve_stages = { 1 => heat_cap_ff1 }
    when 'cchpc_2027_spec'
      heat_cap_ff1 = model_add_curve(model, 'h_cap_allstages_ff', custom_data_json, std)
      heat_cap_ff_curve_stages = { 1 => heat_cap_ff1, 2 => heat_cap_ff1, 3 => heat_cap_ff1, 4 => heat_cap_ff1 }
    end

    # Curve Import - Heating efficiency as a function of flow rate
    case hprtu_scenario
    when 'variable_speed_high_eff'
      heat_eir_ff1 = model_add_curve(model, 'heat_eir_ff1', custom_data_json, std)
      heat_eir_ff_curve_stages = { 1 => heat_eir_ff1, 2 => heat_eir_ff1, 3 => heat_eir_ff1, 4 => heat_eir_ff1 }
    when 'two_speed_standard_eff'
      heat_eir_ff1 = model_add_curve(model, 'h_eir_allstages_ff', custom_data_json, std)
      heat_eir_ff_curve_stages = { 1 => heat_eir_ff1 }
    when 'two_speed_lab_data'
      heat_eir_ff1 = model_add_curve(model, 'h_eir_allstages_ff', custom_data_json, std)
      heat_eir_ff_curve_stages = { 1 => heat_eir_ff1 }
    when 'cchpc_2027_spec'
      heat_eir_ff1 = model_add_curve(model, 'h_eir_allstages_ff', custom_data_json, std)
      heat_eir_ff_curve_stages = { 1 => heat_eir_ff1, 2 => heat_eir_ff1, 3 => heat_eir_ff1, 4 => heat_eir_ff1 }
    end

    # Curve Import - Heating efficiency as a function of part load ratio
    heat_plf_fplr1 = nil
    case hprtu_scenario
    when 'variable_speed_high_eff'
      heat_plf_fplr1 = model_add_curve(model, 'heat_plf_plr1', custom_data_json, std)
    when 'two_speed_standard_eff'
      heat_plf_fplr1 = model_add_curve(model, 'heat_plf_plr1', custom_data_json, std)
    when 'two_speed_lab_data'
      heat_plf_fplr1 = model_add_curve(model, 'heat_plf_plr1', custom_data_json, std)
    when 'cchpc_2027_spec'
      heat_plf_fplr1 = model_add_curve(model, 'heat_plf_plr1', custom_data_json, std)
    end

    # Curve Import - Defrost energy as a function of temperature
    defrost_eir = nil
    case hprtu_scenario
    when 'variable_speed_high_eff'
      defrost_eir = model_add_curve(model, 'defrost_eir', custom_data_json, std)
    when 'two_speed_standard_eff'
      defrost_eir = model_add_curve(model, 'defrost_eir', custom_data_json, std)
    when 'two_speed_lab_data'
      defrost_eir = model_add_curve(model, 'defrost_eir', custom_data_json, std)
    when 'cchpc_2027_spec'
      defrost_eir = model_add_curve(model, 'defrost_eir', custom_data_json, std)
    end

    # ---------------------------------------------------------
    # replace existing applicable air loops with new heat pump rtu air loops
    # ---------------------------------------------------------
    selected_air_loops.sort.each do |air_loop_hvac|
      # get necessary schedules, etc. from unitary system object
      # initialize variables before loop
      hvac_operation_sched = air_loop_hvac.availabilitySchedule
      unitary_availability_sched = 'tmp'
      control_zone = 'tmp'
      dehumid_type = 'tmp'
      supply_fan_op_sched = 'tmp'
      supply_fan_avail_sched = 'tmp'
      fan_tot_eff = 'tmp'
      fan_mot_eff = 'tmp'
      fan_static_pressure = 'tmp'
      orig_clg_coil_gross_cap = nil
      orig_htg_coil_gross_cap = nil

      equip_to_delete = []

      space_types_no_setback = [
        # 'Kitchen',
        # 'kitchen',
        'PatRm',
        'PatRoom',
        'Lab',
        'Exam',
        'PatCorridor',
        'BioHazard',
        'Exam',
        'OR',
        'PreOp',
        'Soil Work',
        'Trauma',
        'Triage',
        # 'PhysTherapy',
        'Data Center',
        # 'CorridorStairway',
        # 'Corridor',
        'Mechanical',
        # 'Restroom',
        'Entry',
        # 'Dining',
        'IT_Room',
        # 'LockerRoom',
        # 'Stair',
        'Toilet',
        'MechElecRoom',
        'Guest Room',
        'guest room'
      ]

      setback_value_c = setback_value * 5 / 9 # convert to c

      if modify_setbacks # modify setbacks if argument set to true
        zones = air_loop_hvac.thermalZones
        zones.sort.each do |thermal_zone|
          no_people_obj = false # flag for not having People object associated with it
          zone_space_types = []
          thermal_zone.spaces.each do |space| # check for space types this measure won't apply to
            zone_space_types << space.spaceType.get.name.to_s
          end

          skip_space_types = space_types_no_setback.any? do |substring|
            zone_space_types.any? do |str|
              str.include?(substring)
            end
          end

          no_people_obj = true if thermal_zone.numberOfPeople.zero?

          if skip_space_types
            next # go to the next zone if this zone has space types that are skipped for the setback
          end

          next unless thermal_zone.thermostatSetpointDualSetpoint.is_initialized

          zone_thermostat = thermal_zone.thermostatSetpointDualSetpoint.get
          htg_schedule = zone_thermostat.heatingSetpointTemperatureSchedule
          if htg_schedule.empty?
            runner.registerWarning("Heating setpoint schedule not found for zone '#{zone.name.get}'")
            next
          elsif htg_schedule.get.to_ScheduleRuleset.empty?
            runner.registerWarning("Schedule '#{htg_schedule.name}' is not a ScheduleRuleset, will not be adjusted")
            next
          else
            htg_schedule = htg_schedule.get.to_ScheduleRuleset.get
          end
          sch_zone_occ = OpenstudioStandards::ThermalZone.thermal_zones_get_occupancy_schedule(
            [thermal_zone], occupied_percentage_threshold: 0.05
          )

          # Determine if setbacks present
          tstat_profiles_stats = get_tstat_profiles_and_stats(htg_schedule)
          has_setback = false
          for profile in tstat_profiles_stats[:profiles]
            sched_min = profile.values.min
            sched_max = profile.values.max
            has_setback = true if sched_max > sched_min
          end

          if !no_people_obj && !has_setback # select zones that have People objects assigned (further steps based on occupancy)
            runner.registerInfo("in no setback #{thermal_zone.name}")
            htg_schedule_annual_profile = get_8760_values_from_schedule_ruleset(model, htg_schedule)
            sch_zone_occ_annual_profile = get_8760_values_from_schedule_ruleset(model, sch_zone_occ)
            htg_schedule_annual_profile_updated = OpenStudio::DoubleVector.new
            htg_schedule_annual_profile.each_with_index do |_val, idx| # Create new profile based on occupancy
              # Find maximum value of schedule for the week
              week_values = htg_schedule_annual_profile.each_slice(168).to_a[(idx / 168).round]
              max_value = week_values.max
              min_value = week_values.min
              # Check for case where setpoint is adjusted for an optimum start, and skip
              # Need at least two more timesteps in the profile to perform optimum start check
              # Final two timesteps of year will not be optimum start, anyway
              if (idx < htg_schedule_annual_profile.size - 2) && opt_start?(sch_zone_occ_annual_profile,
                                                                            htg_schedule_annual_profile,
                                                                            min_value,
                                                                            max_value,
                                                                            idx)
                next
              end

              htg_schedule_annual_profile_updated[idx] = if sch_zone_occ_annual_profile[idx].zero?
                                                           max_value - setback_value_c
                                                         else
                                                           max_value # keeping same setback regime
                                                         end
            end
            htg_tstat_sch_limits = OpenStudio::Model::ScheduleTypeLimits.new(model)
            htg_tstat_sch_limits.setUnitType('Temperature')
            htg_tstat_sch_limits.setNumericType('Continuous')
            htg_sch_new = make_ruleset_sched_from_8760(model, runner, htg_schedule_annual_profile_updated,
                                                       "#{htg_schedule.name} Modified Setpoints", htg_tstat_sch_limits)
            # Handle behavior on last day of year--above method makes a schedule ruleset
            # that has a schedule with a specified day
            # of week for 12/31 that isn't intended
            # On leap years, need to correct separate rule made for 12/30 and 12/31
            model_year = model.getYearDescription.assumedYear
            dec_29_date = OpenStudio::Date.new(OpenStudio::MonthOfYear.new('December'), 29, model_year)
            dec_30_date = OpenStudio::Date.new(OpenStudio::MonthOfYear.new('December'), 30, model_year)
            dec_31_date = OpenStudio::Date.new(OpenStudio::MonthOfYear.new('December'), 31, model_year)
            for tstat_rule in htg_sch_new.scheduleRules
              if tstat_rule.endDate.get == dec_30_date ||
                 (tstat_rule.endDate.get == dec_29_date)
                tstat_rule.setEndDate(dec_31_date)
              end
              next unless ((tstat_rule.endDate.get == dec_31_date) &&
                                     (tstat_rule.startDate.get == dec_31_date)) || ((tstat_rule.endDate.get == dec_31_date) && (tstat_rule.startDate.get == dec_30_date))

              tstat_rule.remove
             end
            zone_thermostat.setHeatingSchedule(htg_sch_new)
          else # Handle zones with setbacks or with spaces without People objects
            profiles = [htg_schedule.defaultDaySchedule]
            htg_schedule.scheduleRules.each { |rule| profiles << rule.daySchedule }
            for tstat_profile in profiles
              tstat_profile_min = tstat_profile.values.min
              tstat_profile_max = tstat_profile.values.max
              tstat_profile_size = tstat_profile.values.uniq.size
              time_h = tstat_profile.times
              if tstat_profile_size == 2 # profile is square wave (2 setpoints, occupied vs unoccupied)
                tstat_profile.values.each_with_index do |value, i| # iterate thru profile and modify values as needed
                  if value == tstat_profile_min
                    tstat_profile.addValue(time_h[i],
                                           tstat_profile_max - setback_value_c)
                  end
                end
              end
              next unless tstat_profile_size > 2 # could be optimal start with ramp

              tstat_profile.values.each_with_index do |value, i|
                if value == tstat_profile_min
                  tstat_profile.addValue(time_h[i], tstat_profile_max - setback_value_c) # set min value back to desired setback
                elsif value > tstat_profile_min && value < tstat_profile_max # dealing with optimum start case
                  if value < tstat_profile_max - setback_value_c # value now less than new min
                    tstat_profile.addValue(time_h[i], tstat_profile_max - setback_value_c) # set so that minimum value is now equal to maximum - setback
                  end
                end
              end
             end
          end
        end
      end
      # end of setback modification

      # for unitary systems
      if air_loop_hvac_unitary_system?(air_loop_hvac)

        # loop through each relevant component.
        # store information needed as variable
        # remove the existing equipment
        air_loop_hvac.supplyComponents.each do |component|
          # convert component to string name
          obj_type = component.iddObjectType.valueName.to_s
          # skip unless component is of relevant type
          next unless %w[Fan Unitary Coil].any? { |word| obj_type.include?(word) }

          # make list of equipment to delete
          equip_to_delete << component

          # get information specifically from unitary system object
          next unless ['Unitary'].any? do |word|
                        obj_type.include?(word)
                      end

          # get unitary system
          unitary_sys = component.to_AirLoopHVACUnitarySystem.get
          # get availability schedule
          unitary_availability_sched = unitary_sys.availabilitySchedule.get
          # get control zone
          control_zone = unitary_sys.controllingZoneorThermostatLocation.get
          # get dehumidification control type
          dehumid_type = unitary_sys.dehumidificationControlType
          # get supply fan operation schedule
          supply_fan_op_sched = unitary_sys.supplyAirFanOperatingModeSchedule.get
          # get supply fan availability schedule
          supply_fan = unitary_sys.supplyFan.get
          # convert supply fan to appropriate object to access methods
          if supply_fan.to_FanConstantVolume.is_initialized
            supply_fan = supply_fan.to_FanConstantVolume.get
          elsif supply_fan.to_FanOnOff.is_initialized
            supply_fan = supply_fan.to_FanOnOff.get
          elsif supply_fan.to_FanVariableVolume.is_initialized
            supply_fan = supply_fan.to_FanVariableVolume.get
          else
            runner.registerError("Supply fan type for #{air_loop_hvac.name} not supported.")
            return false
          end
          # get the availability schedule
          supply_fan_avail_sched = supply_fan.availabilitySchedule
          if supply_fan_avail_sched.to_ScheduleConstant.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          elsif supply_fan_avail_sched.to_ScheduleRuleset.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          else
            runner.registerError("Supply fan availability schedule type for #{supply_fan.name} not supported.")
            return false
          end
          # get supply fan motor efficiency
          fan_tot_eff = supply_fan.fanTotalEfficiency
          # get supply motor efficiency
          fan_mot_eff = supply_fan.motorEfficiency
          # get supply fan static pressure
          fan_static_pressure = supply_fan.pressureRise
          # get previous cooling coil capacity
          orig_clg_coil = unitary_sys.coolingCoil.get

          # check for single speed DX cooling coil
          if orig_clg_coil.to_CoilCoolingDXSingleSpeed.is_initialized
            orig_clg_coil = orig_clg_coil.to_CoilCoolingDXSingleSpeed.get
            # get either autosized or specified cooling capacity
            if orig_clg_coil.isRatedTotalCoolingCapacityAutosized == true
              orig_clg_coil_gross_cap = orig_clg_coil.autosizedRatedTotalCoolingCapacity.get
            elsif orig_clg_coil.ratedTotalCoolingCapacity.is_initialized
              orig_clg_coil_gross_cap = orig_clg_coil.ratedTotalCoolingCapacity.to_f
            else
              runner.registerError("Original cooling coil capacity for #{air_loop_hvac.name} not found. Either it was not directly specified, or sizing run data is not available.")
            end
          # check for two speed DX cooling coil
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

          # get original heating coil capacity
          orig_htg_coil = unitary_sys.heatingCoil.get
          # get coil object if electric resistance
          if orig_htg_coil.to_CoilHeatingElectric.is_initialized
            orig_htg_coil = orig_htg_coil.to_CoilHeatingElectric.get
          # get coil object if gas
          elsif orig_htg_coil.to_CoilHeatingGas.is_initialized
            orig_htg_coil = orig_htg_coil.to_CoilHeatingGas.get
          else
            runner.registerError("Heating coil for #{air_loop_hvac.name} is of an unsupported type. This measure currently supports CoilHeatingElectric and CoilHeatingGas object types.")
          end
          # get either autosized or specified capacity
          if orig_htg_coil.isNominalCapacityAutosized == true
            orig_htg_coil_gross_cap = orig_htg_coil.autosizedNominalCapacity.get
          elsif orig_htg_coil.nominalCapacity.is_initialized
            orig_htg_coil_gross_cap = orig_htg_coil.nominalCapacity.to_f
          else
            runner.registerError("Original heating coil capacity for #{air_loop_hvac.name} not found. Either it was not directly specified, or sizing run data is not available.")
          end
        end

      # get non-unitary system objects.
      else
        # loop through components
        air_loop_hvac.supplyComponents.each do |component|
          # convert component to string name
          obj_type = component.iddObjectType.valueName.to_s
          # skip unless component is of relevant type
          next unless %w[Fan Unitary Coil].any? { |word| obj_type.include?(word) }

          # make list of equipment to delete
          equip_to_delete << component
          # check for fan
          next unless ['Fan'].any? { |word| obj_type.include?(word) }

          supply_fan = component
          if supply_fan.to_FanConstantVolume.is_initialized
            supply_fan = supply_fan.to_FanConstantVolume.get
          elsif supply_fan.to_FanOnOff.is_initialized
            supply_fan = supply_fan.to_FanOnOff.get
          elsif supply_fan.to_FanVariableVolume.is_initialized
            supply_fan = supply_fan.to_FanVariableVolume.get
          else
            runner.registerError("Supply fan type for #{air_loop_hvac.name} not supported.")
            return false
          end
          # get the availability schedule
          supply_fan_avail_sched = supply_fan.availabilitySchedule
          if supply_fan_avail_sched.to_ScheduleConstant.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          elsif supply_fan_avail_sched.to_ScheduleRuleset.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          else
            runner.registerError("Supply fan availability schedule type for #{supply_fan.name} not supported.")
            return false
          end
          # get supply fan motor efficiency
          fan_tot_eff = supply_fan.fanTotalEfficiency
          # get supply motor efficiency
          fan_mot_eff = supply_fan.motorEfficiency
          # get supply fan static pressure
          fan_static_pressure = supply_fan.pressureRise
          # set unitary supply fan operating schedule equal to system schedule for non-unitary systems
          supply_fan_op_sched = hvac_operation_sched
          # set dehumidification type
          dehumid_type = 'None'
          # set control zone to the thermal zone. This will be used in new unitary system object
          control_zone = air_loop_hvac.thermalZones[0]
          # set unitary availability schedule to be always on. This will be used in new unitary system object.
          unitary_availability_sched = model.alwaysOnDiscreteSchedule
        end
      end

      # delete equipment from original loop
      equip_to_delete.each(&:remove)

      # set always on schedule; this will be used in other object definitions
      always_on = model.alwaysOnDiscreteSchedule

      # get thermal zone
      thermal_zone = air_loop_hvac.thermalZones[0]

      # Get the min OA flow rate from the OA; this is used below
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      controller_oa = oa_system.getControllerOutdoorAir
      oa_flow_m3_per_s = nil
      if controller_oa.minimumOutdoorAirFlowRate.is_initialized
        oa_flow_m3_per_s = controller_oa.minimumOutdoorAirFlowRate.get
      elsif controller_oa.autosizedMinimumOutdoorAirFlowRate.is_initialized
        oa_flow_m3_per_s = controller_oa.autosizedMinimumOutdoorAirFlowRate.get
      else
        runner.registerError("No outdoor air sizing information was found for #{controller_oa.name}, which is required for setting ERV wheel power consumption.")
        return false
      end

      # change sizing parameter to vav
      sizing = air_loop_hvac.sizingSystem
      sizing.setCentralCoolingCapacityControlMethod('VAV') # CC-TMP

      # replace any CV terminal box with no reheat VAV terminal box
      # get old terminal box
      if thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeReheat.is_initialized
        old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeReheat.get
      elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeNoReheat.is_initialized
        old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeNoReheat.get
      elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVHeatAndCoolNoReheat.is_initialized
        old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVHeatAndCoolNoReheat.get
      elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVHeatAndCoolReheat.is_initialized
        old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVHeatAndCoolReheat.get
      elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVNoReheat.is_initialized
        old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVNoReheat.get
      elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVReheat.is_initialized
        old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVReheat.get
      else
        runner.registerError("Terminal box type for air loop #{air_loop_hvac.name} not supported.")
        return false
      end

      # get design supply air flow rate
      old_terminal_sa_flow_m3_per_s = nil
      if air_loop_hvac.designSupplyAirFlowRate.is_initialized
        old_terminal_sa_flow_m3_per_s = air_loop_hvac.designSupplyAirFlowRate.get
      elsif air_loop_hvac.isDesignSupplyAirFlowRateAutosized
        old_terminal_sa_flow_m3_per_s = air_loop_hvac.autosizedDesignSupplyAirFlowRate.get
      else
        runner.registerError("No sizing data available for air loop #{air_loop_hvac.name} zone terminal box.")
      end

      # define minimum flow rate needed to maintain ventilation - add in max fraction if in model
      if controller_oa.maximumFractionofOutdoorAirSchedule.is_initialized
        controller_oa.resetMaximumFractionofOutdoorAirSchedule
      end
      min_oa_flow_ratio = (oa_flow_m3_per_s / old_terminal_sa_flow_m3_per_s)

      # remove old equipment
      old_terminal.remove
      air_loop_hvac.removeBranchForZone(thermal_zone)
      # define new terminal box
      # new_terminal = OpenStudio::Model::AirTerminalSingleDuctConstantVolumeNoReheat.new(model, always_on)
      new_terminal = OpenStudio::Model::AirTerminalSingleDuctVAVHeatAndCoolNoReheat.new(model)
      # set name of terminal box and add
      new_terminal.setName("#{thermal_zone.name} VAV Terminal")
      air_loop_hvac.addBranchForZone(thermal_zone, new_terminal.to_StraightComponent)

      #################################### Start Sizing Logic

      # get heating design day temperatures into list
      li_design_days = model.getDesignDays
      li_htg_dsgn_day_temps = []
      # loop through list of design days, add heating temps
      li_design_days.sort.each do |dd|
        day_type = dd.dayType
        # add design day drybulb temperature if winter design day
        next unless day_type == 'WinterDesignDay'

        li_htg_dsgn_day_temps << dd.maximumDryBulbTemperature
      end
      # get coldest design day temp for manual sizing
      wntr_design_day_temp_c = li_htg_dsgn_day_temps.min

      # get user-input heating sizing temperature
      htg_sizing_option_hash = { '47F' => 47, '17F' => 17, '0F' => 0, '-10F' => -10 }
      htg_sizing_option_f = htg_sizing_option_hash[htg_sizing_option]
      htg_sizing_option_c = OpenStudio.convert(htg_sizing_option_f, 'F', 'C').get
      hp_sizing_temp_c = nil
      # set heat pump sizing temp based on user-input value and design day
      if htg_sizing_option_c >= wntr_design_day_temp_c
        hp_sizing_temp_c = htg_sizing_option_c
        if debug_verbose
          runner.registerInfo("sizing summary: For heat pump sizing, heating design day temperature is #{OpenStudio.convert(
            wntr_design_day_temp_c, 'C', 'F'
          ).get.round(0)}F, and the user-input temperature to size on is #{OpenStudio.convert(
            htg_sizing_option_c, 'C', 'F'
          ).get.round(0)}F. User-input temperature is larger than design day temperature, so user-input temperature will be used.")
        end
      else
        hp_sizing_temp_c = wntr_design_day_temp_c
        if debug_verbose
          runner.registerInfo("sizing summary: For heat pump sizing, heating design day temperature is #{OpenStudio.convert(
            wntr_design_day_temp_c, 'C', 'F'
          ).get.round(0)}F, and the user-input temperature to size on is #{OpenStudio.convert(
            htg_sizing_option_c, 'C', 'F'
          ).get.round(0)}F. The heating design day temperature is higher than the user-specified temperature which is not realistic, therefore the heating design day temperature will be used.")
        end
      end

      ## define number of stages, and capacity/airflow fractions for each stage
      (_, _, rated_stage_num_heating, rated_stage_num_cooling, final_rated_cooling_cop, final_rated_heating_cop, stage_cap_fractions_heating,
      stage_flow_fractions_heating, stage_cap_fractions_cooling, stage_flow_fractions_cooling, stage_rated_cop_frac_heating,
      stage_rated_cop_frac_cooling, _, stage_gross_rated_sensible_heat_ratio_cooling, enable_cycling_losses_above_lowest_speed, reference_cooling_cfm_per_ton,
      reference_heating_cfm_per_ton) = assign_staging_data(custom_data_json, std)

      # get appropriate design heating load
      orig_htg_coil_gross_cap_old = orig_htg_coil_gross_cap
      design_air_flow_from_zone_sizing_heating_m_3_per_s = old_terminal_sa_flow_m3_per_s
      if sizing_run

        # get thermal zones for the air loop
        thermal_zones = air_loop_hvac.thermalZones
        if thermal_zones.size != 1
          runner.registerError("The airloop (#{air_loop_hvac.name}) includes multiple (#{thermal_zones.size}) thermal zones instead of just a single zone.")
        end

        # get design airflow rate for heating with sizing factor applied from design day simulation
        report_name = 'HVACSizingSummary'
        table_name = 'Zone Sensible Heating'
        column_name = 'User Design Air Flow'
        row_name = thermal_zones.first.name.to_s.upcase
        design_air_flow_from_zone_sizing_heating_m_3_per_s = get_tabular_data(runner, model, sql, report_name,
                                                                              'Entire Facility', table_name, row_name, column_name).to_f

        # get temperature (Tin from the delta T)
        report_name = 'CoilSizingDetails'
        table_name = 'Coils'
        column_name = 'Coil Entering Air Drybulb at Ideal Loads Peak'
        row_name = orig_airloop_heating_coil_map[air_loop_hvac.name.to_s]
        coil_entering_temperature_c = get_tabular_data(runner, model, sql, report_name, 'Entire Facility', table_name,
                                                       row_name, column_name).to_f

        # get temperature (Tout from the delta T)
        report_name = 'CoilSizingDetails'
        table_name = 'Coils'
        column_name = 'Coil Leaving Air Drybulb at Ideal Loads Peak'
        row_name = orig_airloop_heating_coil_map[air_loop_hvac.name.to_s]
        coil_leaving_temperature_c = get_tabular_data(runner, model, sql, report_name, 'Entire Facility', table_name, row_name,
                                                      column_name).to_f

        # get air density
        report_name = 'CoilSizingDetails'
        table_name = 'Coils'
        column_name = 'Standard Air Density Adjusted for Elevation'
        row_name = orig_airloop_heating_coil_map[air_loop_hvac.name.to_s]
        air_density_kg_per_m_3 = get_tabular_data(runner, model, sql, report_name, 'Entire Facility', table_name, row_name,
                                                  column_name).to_f

        # get heat capacity
        report_name = 'CoilSizingDetails'
        table_name = 'Coils'
        column_name = 'Dry Air Heat Capacity'
        row_name = orig_airloop_heating_coil_map[air_loop_hvac.name.to_s]
        air_heat_capacity_j_per_kg_k = get_tabular_data(runner, model, sql, report_name, 'Entire Facility', table_name,
                                                        row_name, column_name).to_f

        # override design heating load with Q = vdot * rho * cp * (Tout - Tin)
        orig_htg_coil_gross_cap = design_air_flow_from_zone_sizing_heating_m_3_per_s * air_density_kg_per_m_3 * air_heat_capacity_j_per_kg_k * (coil_leaving_temperature_c - coil_entering_temperature_c)
        if debug_verbose
          runner.registerInfo("sizing summary: original heating design load overriden from sizing run: #{orig_htg_coil_gross_cap_old.round(3)} W to  #{orig_htg_coil_gross_cap.round(3)} W for airloop (#{air_loop_hvac.name})")
        end
      end

      # determine heating load curve; y=mx+b
      # assumes 0 load at 60F (15.556 C)
      htg_load_slope = (0 - orig_htg_coil_gross_cap) / (15.5556 - wntr_design_day_temp_c)
      htg_load_intercept = orig_htg_coil_gross_cap - (htg_load_slope * wntr_design_day_temp_c)

      # calculate heat pump design load, derate factors, and required rated capacities (at stage 4) for different OA temperatures; assumes 75F interior temp (23.8889C)
      ia_temp_c = 23.8889

      # user-specified design
      oa_temp_c = hp_sizing_temp_c
      dns_htg_load_at_user_dsn_temp = htg_load_slope * hp_sizing_temp_c + htg_load_intercept
      if heat_cap_ft_curve_stages[rated_stage_num_heating].to_TableLookup.is_initialized
        table_lookup_obj = heat_cap_ft_curve_stages[rated_stage_num_heating].to_TableLookup.get
        hp_derate_factor_at_user_dsn = AddHeatPumpRtu.get_dep_var_from_lookup_table_with_interpolation(runner, table_lookup_obj,
                                                                                                       ia_temp_c, oa_temp_c)
      else
        hp_derate_factor_at_user_dsn = heat_cap_ft_curve_stages[rated_stage_num_heating].evaluate(ia_temp_c, oa_temp_c)
      end
      req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn = dns_htg_load_at_user_dsn_temp / hp_derate_factor_at_user_dsn

      # determine heat pump system sizing based on user-specified sizing temperature and user-specified maximum upsizing limits
      # upsize total cooling capacity using user-specified factor
      autosized_tot_clg_cap_upsized = orig_clg_coil_gross_cap * clg_oversizing_estimate
      # get maximum cooling capacity with user-specified upsizing
      max_cool_cap_w_upsize = autosized_tot_clg_cap_upsized * (performance_oversizing_factor + 1)
      # get maximum heating capacity based on max cooling capacity and heating-to-cooling ratio
      max_heat_cap_w_upsize = autosized_tot_clg_cap_upsized * (performance_oversizing_factor + 1) * htg_to_clg_hp_ratio

      # Sizing decision based on heating load level
      heating_load_category = ''
      # If ratio of required heating capacity at rated conditions to cooling capacity is less than specified heating to cooling ratio, then size everything based on cooling
      # If heating load requires upsizing, but is below user-input cooling upsizing limit, then size based on design heating load
      # Else, size to maximum oversizing factor
      design_heating_airflow_m_3_per_s = nil
      design_cooling_airflow_m_3_per_s = nil
      if (req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn / autosized_tot_clg_cap_upsized) <= htg_to_clg_hp_ratio
        heating_load_category = 'Small heating load'
        # set rated heating capacity equal to upsized cooling capacity times the user-specified heating to cooling sizing ratio
        dx_rated_htg_cap_applied = autosized_tot_clg_cap_upsized * htg_to_clg_hp_ratio
        # set rated cooling capacity
        dx_rated_clg_cap_applied = autosized_tot_clg_cap_upsized
        # define design airflows
        design_cooling_airflow_m_3_per_s = old_terminal_sa_flow_m3_per_s
        design_heating_airflow_m_3_per_s = old_terminal_sa_flow_m3_per_s
      elsif req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn <= max_heat_cap_w_upsize
        heating_load_category = 'Moderate heating load'
        # set rated heating coil equal to desired sized value, which should be below the suer-input limit
        dx_rated_htg_cap_applied = req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn
        # set cooling capacity to appropriate ratio based on heating capacity needs
        cool_cap = req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn / htg_to_clg_hp_ratio
        dx_rated_clg_cap_applied = cool_cap
        # define design airflows
        design_cooling_airflow_m_3_per_s = old_terminal_sa_flow_m3_per_s
        design_heating_airflow_m_3_per_s = design_air_flow_from_zone_sizing_heating_m_3_per_s
      else
        heating_load_category = 'Large heating load'
        # set rated heating capacity to maximum allowable based on cooling capacity maximum limit
        dx_rated_htg_cap_applied = max_cool_cap_w_upsize * htg_to_clg_hp_ratio
        # set rated cooling capacity to maximum allowable based on oversizing limit
        dx_rated_clg_cap_applied = max_cool_cap_w_upsize
        # define design airflows
        design_cooling_airflow_m_3_per_s = old_terminal_sa_flow_m3_per_s
        design_heating_airflow_m_3_per_s = design_air_flow_from_zone_sizing_heating_m_3_per_s
      end

      # sizing result summary output log using for measure documentation
      if debug_verbose
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): air_loop_hvac name  =  #{air_loop_hvac.name}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): heating_load_category = #{heating_load_category}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): original rated cooling capacity W = #{orig_clg_coil_gross_cap.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): design heating load (from load curve based on user specified design temp) W = #{dns_htg_load_at_user_dsn_temp.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): design heating load (from original heating coil) W = #{orig_htg_coil_gross_cap.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): minimum heating capacity threshold W = #{(autosized_tot_clg_cap_upsized * htg_to_clg_hp_ratio).round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): maximum heating capacity threshold W = #{max_heat_cap_w_upsize.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): required rated heating capacity to meet design heating load W = #{req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): heat pump heating sizing temperature F = #{OpenStudio.convert(
          hp_sizing_temp_c, 'C', 'F'
        ).get.round(0)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): heating capacity derating factor at design temperature = #{hp_derate_factor_at_user_dsn.round(3)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): upsized rated heating capacity W = #{dx_rated_htg_cap_applied.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): upsized rated cooling capacity W = #{dx_rated_clg_cap_applied.round(2)}")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): final upsizing percentage % = #{((dx_rated_htg_cap_applied - orig_clg_coil_gross_cap) / orig_clg_coil_gross_cap * 100).round(2)}")
      end

      # calculate applied upsizing factor
      upsize_factor = (dx_rated_htg_cap_applied - orig_clg_coil_gross_cap) / orig_clg_coil_gross_cap

      # upsize airflow accordingly
      # design_heating_airflow_m_3_per_s *= (1 + upsize_factor)
      # design_cooling_airflow_m_3_per_s *= (1 + upsize_factor)

      if debug_verbose
        runner.registerInfo('sizing summary: before rated cfm/ton adjustmant')
        runner.registerInfo("sizing summary: dx_rated_htg_cap_applied = #{dx_rated_htg_cap_applied}")
        runner.registerInfo("sizing summary: design_heating_airflow_m_3_per_s = #{design_heating_airflow_m_3_per_s}")
        runner.registerInfo("sizing summary: cfm/ton heating = #{m_3_per_sec_watts_to_cfm_per_ton(design_heating_airflow_m_3_per_s / dx_rated_htg_cap_applied)}")
        runner.registerInfo("sizing summary: dx_rated_clg_cap_applied = #{dx_rated_clg_cap_applied}")
        runner.registerInfo("sizing summary: design_cooling_airflow_m_3_per_s = #{design_cooling_airflow_m_3_per_s}")
        runner.registerInfo("sizing summary: cfm/ton heating = #{m_3_per_sec_watts_to_cfm_per_ton(design_cooling_airflow_m_3_per_s / dx_rated_clg_cap_applied)}")
      end

      # adjust if rated/highest stage cfm/ton is violated
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

      # set airloop design airflow based on the maximum of heating and cooling design flow
      design_airflow_for_sizing_m_3_per_s = if design_cooling_airflow_m_3_per_s < design_heating_airflow_m_3_per_s
                                              design_heating_airflow_m_3_per_s
                                            else
                                              design_cooling_airflow_m_3_per_s
                                            end

      # reset supply airflow if less than minimum OA
      design_airflow_for_sizing_m_3_per_s = oa_flow_m3_per_s if oa_flow_m3_per_s > design_airflow_for_sizing_m_3_per_s
      design_cooling_airflow_m_3_per_s = oa_flow_m3_per_s if oa_flow_m3_per_s > design_cooling_airflow_m_3_per_s
      design_heating_airflow_m_3_per_s = oa_flow_m3_per_s if oa_flow_m3_per_s > design_heating_airflow_m_3_per_s

      # set minimum flow rate to 0.40, or higher as needed to maintain outdoor air requirements
      min_flow = 0.40

      # determine minimum airflow ratio for sizing; 0.4 is used unless OA requires higher
      min_airflow_m3_per_s = nil
      current_min_oa_flow_ratio = oa_flow_m3_per_s / design_heating_airflow_m_3_per_s
      if current_min_oa_flow_ratio > min_flow
        min_airflow_ratio = current_min_oa_flow_ratio
        min_airflow_m3_per_s = min_airflow_ratio * design_airflow_for_sizing_m_3_per_s
      else
        min_airflow_ratio = min_flow
        min_airflow_m3_per_s = min_airflow_ratio * design_airflow_for_sizing_m_3_per_s
      end

      # increase design airflow to accomodate upsizing
      air_loop_hvac.setDesignSupplyAirFlowRate(design_airflow_for_sizing_m_3_per_s)
      controller_oa.setMaximumOutdoorAirFlowRate(design_airflow_for_sizing_m_3_per_s)

      if debug_verbose
        runner.registerInfo("sizing summary: design_airflow_for_sizing_m_3_per_s = #{design_airflow_for_sizing_m_3_per_s}")
        runner.registerInfo("sizing summary: min_oa_flow_ratio = #{min_oa_flow_ratio} | min_flow = #{min_flow}")
        runner.registerInfo("sizing summary: min_airflow_m3_per_s = #{min_airflow_m3_per_s}")
      end

      # determine airflows for each stage of heating
      # airflow for each stage will be the higher of the user-input stage ratio or the minimum OA
      # lower stages may be removed later if cfm/ton bounds cannot be maintained due to minimum OA limits
      # if oversizing is not specified (upsize_factor = 0.0), then use cooling design airflow
      stage_flows_heating = {}
      stage_flow_fractions_heating.each do |stage, ratio|
        airflow = if upsize_factor == 0.0
                    ratio * design_cooling_airflow_m_3_per_s
                  else
                    ratio * design_heating_airflow_m_3_per_s
                  end
        stage_flows_heating[stage] = airflow >= min_airflow_m3_per_s ? airflow : min_airflow_m3_per_s
      end

      # determine airflows for each stage of cooling
      # airflow for each stage will be the higher of the user-input stage ratio or the minimum OA
      # lower stages may be removed later if cfm/ton bounds cannot be maintained due to minimum OA limits
      stage_flows_cooling = {}
      stage_flow_fractions_cooling.sort.each do |stage, ratio|
        airflow = ratio * design_cooling_airflow_m_3_per_s
        stage_flows_cooling[stage] = airflow >= min_airflow_m3_per_s ? airflow : min_airflow_m3_per_s
      end

      if debug_verbose
        runner.registerInfo('sizing summary: before cfm/ton adjustments for lower stages')
        runner.registerInfo("sizing summary: stage_flow_fractions_heating = #{stage_flow_fractions_heating}")
        runner.registerInfo("sizing summary: stage_flow_fractions_cooling = #{stage_flow_fractions_cooling}")
        runner.registerInfo("sizing summary: stage_flows_heating = #{stage_flows_heating}")
        runner.registerInfo("sizing summary: stage_flows_cooling = #{stage_flows_cooling}")
      end

      # heating - align stage CFM/ton bounds where possible
      # this may remove some lower stages
      stage_flows_heating, stage_caps_heating, _, _, num_heating_stages = adjust_cfm_per_ton_per_limits(
        stage_cap_fractions_heating,
        stage_flows_heating,
        stage_flow_fractions_heating,
        dx_rated_htg_cap_applied,
        rated_stage_num_heating,
        design_heating_airflow_m_3_per_s,
        min_airflow_ratio,
        air_loop_hvac,
        'heating',
        runner,
        debug_verbose
      )

      # cooling - align stage CFM/ton bounds where possible
      # this may remove some lower stages
      stage_flows_cooling, stage_caps_cooling, _, _, num_cooling_stages = adjust_cfm_per_ton_per_limits(
        stage_cap_fractions_cooling,
        stage_flows_cooling,
        stage_flow_fractions_cooling,
        dx_rated_clg_cap_applied,
        rated_stage_num_cooling,
        design_cooling_airflow_m_3_per_s,
        min_airflow_ratio,
        air_loop_hvac,
        'cooling',
        runner,
        debug_verbose
      )

      if debug_verbose
        runner.registerInfo('sizing summary: after cfm/ton adjustments for lower stages')
        runner.registerInfo("sizing summary: stage_flows_heating = #{stage_flows_heating}")
        runner.registerInfo("sizing summary: stage_flows_cooling = #{stage_flows_cooling}")
      end
      #################################### Start performance curve assignment

      # ---------------------------------------------------------
      # cooling curve assignments
      # ---------------------------------------------------------
      # adjust rated cooling cop
      if final_rated_cooling_cop == false
        final_rated_cooling_cop = adjust_rated_cop_from_ref_cfm_per_ton(runner, stage_flows_cooling[rated_stage_num_cooling],
                                                                        reference_cooling_cfm_per_ton,
                                                                        stage_caps_cooling[rated_stage_num_cooling],
                                                                        get_rated_cop_cooling(stage_caps_cooling[rated_stage_num_cooling]),
                                                                        cool_eir_ff_curve_stages[rated_stage_num_cooling])
        runner.registerInfo("sizing summary: rated cooling COP adjusted from #{get_rated_cop_cooling(stage_caps_cooling[rated_stage_num_cooling]).round(3)} to #{final_rated_cooling_cop.round(3)} based on reference cfm/ton of #{reference_cooling_cfm_per_ton.round(0)} (i.e., average value of actual products)")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): final rated cooling COP = #{final_rated_cooling_cop.round(3)}")
      end

      # define new cooling coil
      # single speed is used for 1 stage units, otherwise multispeed is used.
      new_dx_cooling_coil = set_cooling_coil_stages(
        model,
        runner,
        stage_flows_cooling,
        stage_caps_cooling,
        num_cooling_stages,
        final_rated_cooling_cop,
        cool_cap_ft_curve_stages,
        cool_eir_ft_curve_stages,
        cool_cap_ff_curve_stages,
        cool_eir_ff_curve_stages,
        cool_plf_fplr1,
        stage_rated_cop_frac_cooling,
        stage_gross_rated_sensible_heat_ratio_cooling,
        rated_stage_num_cooling,
        enable_cycling_losses_above_lowest_speed,
        air_loop_hvac,
        always_on,
        stage_caps_heating,
        debug_verbose
      )

      # ---------------------------------------------------------
      # heating curve assignments
      # ---------------------------------------------------------
      # adjust rated heating cop
      if final_rated_heating_cop == false
        final_rated_heating_cop = adjust_rated_cop_from_ref_cfm_per_ton(runner, stage_flows_heating[rated_stage_num_heating],
                                                                        reference_heating_cfm_per_ton,
                                                                        stage_caps_heating[rated_stage_num_heating],
                                                                        get_rated_cop_heating(stage_caps_heating[rated_stage_num_heating]),
                                                                        heat_eir_ff_curve_stages[rated_stage_num_heating])
        runner.registerInfo("sizing summary: rated heating COP adjusted from #{get_rated_cop_heating(stage_caps_heating[rated_stage_num_heating]).round(3)} to #{final_rated_heating_cop.round(3)} based on reference cfm/ton of #{reference_heating_cfm_per_ton.round(0)} (i.e., average value of actual products)")
        runner.registerInfo("sizing summary: sizing air loop (#{air_loop_hvac.name}): final rated heating COP = #{final_rated_heating_cop.round(3)}")
      end

      # define new heating coil
      # single speed is used for 1 stage units, otherwise multispeed is used.
      new_dx_heating_coil = set_heating_coil_stages(
        model,
        runner,
        stage_flows_heating,
        stage_caps_heating,
        num_heating_stages,
        final_rated_heating_cop,
        heat_cap_ft_curve_stages,
        heat_eir_ft_curve_stages,
        heat_cap_ff_curve_stages,
        heat_eir_ff_curve_stages,
        heat_plf_fplr1,
        defrost_eir,
        stage_rated_cop_frac_heating,
        rated_stage_num_heating,
        air_loop_hvac,
        hp_min_comp_lockout_temp_f,
        enable_cycling_losses_above_lowest_speed,
        always_on,
        stage_caps_cooling,
        debug_verbose
      )

      #################################### End performance curve assignment

      # add new supplemental heating coil
      new_backup_heating_coil = nil
      # define backup heat source TODO: set capacity to equal full heating capacity
      if (prim_ht_fuel_type == 'electric') || (backup_ht_fuel_scheme == 'electric_resistance_backup')
        new_backup_heating_coil = OpenStudio::Model::CoilHeatingElectric.new(model)
        new_backup_heating_coil.setEfficiency(1.0)
        new_backup_heating_coil.setName("#{air_loop_hvac.name} electric resistance backup coil")
      else
        new_backup_heating_coil = OpenStudio::Model::CoilHeatingGas.new(model)
        new_backup_heating_coil.setGasBurnerEfficiency(0.80)
        new_backup_heating_coil.setName("#{air_loop_hvac.name} gas backup coil")
      end
      # set availability schedule
      new_backup_heating_coil.setAvailabilitySchedule(always_on)
      # set capacity of backup heat to meet full heating load
      new_backup_heating_coil.setNominalCapacity(orig_htg_coil_gross_cap_old)

      # add new fan
      new_fan = OpenStudio::Model::FanVariableVolume.new(model, always_on)
      new_fan.setAvailabilitySchedule(supply_fan_avail_sched)
      new_fan.setName("#{air_loop_hvac.name} VFD Fan")
      new_fan.setMotorEfficiency(fan_mot_eff) # from Daikin Rebel E+ file
      new_fan.setFanPowerMinimumFlowRateInputMethod('Fraction')

      # set fan total efficiency, which determines fan power
      if hprtu_scenario == 'variable_speed_high_eff'
        # new_fan.setFanTotalEfficiency(0.57) # from PNNL
        std.fan_change_motor_efficiency(new_fan, fan_mot_eff)
      else
        new_fan.setFanTotalEfficiency(0.63) # from PNNL
      end
      new_fan.setFanPowerCoefficient1(0.259905264) # from Daikin Rebel E+ file
      new_fan.setFanPowerCoefficient2(-1.569867715) # from Daikin Rebel E+ file
      new_fan.setFanPowerCoefficient3(4.819732387) # from Daikin Rebel E+ file
      new_fan.setFanPowerCoefficient4(-3.904544154) # from Daikin Rebel E+ file
      new_fan.setFanPowerCoefficient5(1.394774218) # from Daikin Rebel E+ file

      # set minimum fan power flow fraction to the higher of 0.40 or the min flow fraction
      if min_airflow_ratio > min_flow
        new_fan.setFanPowerMinimumFlowFraction(min_airflow_ratio)
      else
        new_fan.setFanPowerMinimumFlowFraction(min_flow)
      end
      new_fan.setPressureRise(fan_static_pressure) # set from origial fan power; 0.5in will be added later if adding HR

      # add new unitary system object
      new_air_to_air_heatpump = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
      new_air_to_air_heatpump.setName("#{air_loop_hvac.name} Unitary Heat Pump System")
      new_air_to_air_heatpump.setSupplyFan(new_fan)
      new_air_to_air_heatpump.setHeatingCoil(new_dx_heating_coil)
      new_air_to_air_heatpump.setCoolingCoil(new_dx_cooling_coil)
      new_air_to_air_heatpump.setSupplementalHeatingCoil(new_backup_heating_coil)
      new_air_to_air_heatpump.addToNode(air_loop_hvac.supplyOutletNode)

      # set other features
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
        # set no load design flow rate
        new_air_to_air_heatpump.resetSupplyAirFlowRateMethodWhenNoCoolingorHeatingisRequired
      end
      # set cooling design flow rate
      new_air_to_air_heatpump.setSupplyAirFlowRateDuringCoolingOperation(stage_flows_cooling[num_cooling_stages])
      # set heating design flow rate
      new_air_to_air_heatpump.setSupplyAirFlowRateDuringHeatingOperation(stage_flows_heating[num_heating_stages])
      # set no load design flow rate
      new_air_to_air_heatpump.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(min_airflow_m3_per_s)

      # add dcv to air loop if dcv flag is true
      if dcv == true
        oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
        controller_oa = oa_system.getControllerOutdoorAir
        controller_mv = controller_oa.controllerMechanicalVentilation
        controller_mv.setDemandControlledVentilation(true)
      end

      # add economizer
      if econ == true
        # set parameters
        oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
        controller_oa = oa_system.getControllerOutdoorAir
        # econ_type = std.model_economizer_type(model, climate_zone)
        # set economizer type
        controller_oa.setEconomizerControlType('DifferentialEnthalpy')
        # set drybulb temperature limit; per 90.1-2013, this is constant 75F for all climates
        drybulb_limit_f = 75
        drybulb_limit_c = OpenStudio.convert(drybulb_limit_f, 'F', 'C').get
        controller_oa.setEconomizerMaximumLimitDryBulbTemperature(drybulb_limit_c)
        # set lockout for integrated heating
        controller_oa.setLockoutType('LockoutWithHeating')
      end

      # make sure existing economizer is integrated or it wont work with multispeed coil
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      controller_oa = oa_system.getControllerOutdoorAir
      controller_oa.setLockoutType('LockoutWithHeating') unless controller_oa.getEconomizerControlType == 'NoEconomizer'

      # Energy recovery
      # check for ERV, and get components
      # ERV components will be removed and replaced if ERV flag was selected
      # If ERV flag was not selected, ERV equipment will remain in place as-is
      erv_components = []
      air_loop_hvac.oaComponents.each do |component|
        component_name = component.name.to_s
        next if component_name.include? 'Node'

        if component_name.include? 'ERV'
          erv_components << component
          erv_components = erv_components.uniq
        end
      end

      # add energy recovery if specified by user and if the building type is applicable
      next unless (hr == true) && (btype_erv_applicable == true)

      # check for space type applicability
      thermal_zone_names_to_exclude = %w[Kitchen kitchen KITCHEN Dining dining DINING]
      # skip air loops that serve non-applicable space types and warn user
      if thermal_zone_names_to_exclude.any? { |word| thermal_zone.name.to_s.include?(word) }
        runner.registerWarning("The user selected to add energy recovery to the HP-RTUs, but thermal zone #{thermal_zone.name} is a non-applicable space type for energy recovery. Any existing energy recovery will remain for consistancy, but no new energy recovery will be added.")
      else
        # remove existing ERV; these will be replaced with new ERV equipment
        erv_components.each(&:remove)
        # get oa system
        oa_sys = air_loop_hvac.airLoopHVACOutdoorAirSystem
        std.air_loop_hvac_apply_energy_recovery_ventilator(air_loop_hvac, climate_zone)
        # set heat exchanger efficiency levels
        # get outdoor airflow (which is used for sizing)
        oa_sys = oa_sys.get
        # get design outdoor air flow rate
        # this is used to estimate wheel "fan" power
        # loop through thermal zones
        oa_flow_m3_per_s = 0
        air_loop_hvac.thermalZones.each do |tz|
          space = tz.spaces[0]

          # get zone area
          fa = tz.floorArea * tz.multiplier

          # get zone volume
          vol = tz.airVolume * tz.multiplier

          # get zone design people
          num_people = tz.numberOfPeople * tz.multiplier

          next unless space.designSpecificationOutdoorAir.is_initialized

          dsn_spec_oa = space.designSpecificationOutdoorAir.get

          # add floor area component
          oa_area = dsn_spec_oa.outdoorAirFlowperFloorArea
          oa_flow_m3_per_s += oa_area * fa

          # add per person component
          oa_person = dsn_spec_oa.outdoorAirFlowperPerson
          oa_flow_m3_per_s += oa_person * num_people

          # add air change component
          oa_ach = dsn_spec_oa.outdoorAirFlowAirChangesperHour
          oa_flow_m3_per_s += (oa_ach * vol) / 60
        end

        oa_sys.oaComponents.each do |oa_comp|
          next unless oa_comp.to_HeatExchangerAirToAirSensibleAndLatent.is_initialized

          hx = oa_comp.to_HeatExchangerAirToAirSensibleAndLatent.get
          # set controls
          hx.setSupplyAirOutletTemperatureControl(true)
          hx.setEconomizerLockout(true)
          hx.setFrostControlType('MinimumExhaustTemperature')
          hx.setThresholdTemperature(1.66667) # 35F, from E+ recommendation
          hx.setHeatExchangerType('Rotary') # rotary is used for fan power modulation when bypass is active. Only affects supply temp control with bypass.
          # add setpoint manager to control recovery
          # Add a setpoint manager OA pretreat to control the ERV
          spm_oa_pretreat = OpenStudio::Model::SetpointManagerOutdoorAirPretreat.new(air_loop_hvac.model)
          spm_oa_pretreat.setMinimumSetpointTemperature(-99.0)
          spm_oa_pretreat.setMaximumSetpointTemperature(99.0)
          spm_oa_pretreat.setMinimumSetpointHumidityRatio(0.00001)
          spm_oa_pretreat.setMaximumSetpointHumidityRatio(1.0)
          # Reference setpoint node and mixed air stream node are outlet node of the OA system
          mixed_air_node = oa_sys.mixedAirModelObject.get.to_Node.get
          spm_oa_pretreat.setReferenceSetpointNode(mixed_air_node)
          spm_oa_pretreat.setMixedAirStreamNode(mixed_air_node)
          # Outdoor air node is the outboard OA node of the OA system
          spm_oa_pretreat.setOutdoorAirStreamNode(oa_sys.outboardOANode.get)
          # Return air node is the inlet node of the OA system
          return_air_node = oa_sys.returnAirModelObject.get.to_Node.get
          spm_oa_pretreat.setReturnAirStreamNode(return_air_node)
          # Attach to the outlet of the HX
          hx_outlet = hx.primaryAirOutletModelObject.get.to_Node.get
          spm_oa_pretreat.addToNode(hx_outlet)

          # set parameters for ERV
          case doas_type
          when 'ERV'
            # set efficiencies; assumed 90% airflow returned to unit
            hx.setSensibleEffectivenessat100HeatingAirFlow(0.75 * 0.9)
            hx.setSensibleEffectivenessat75HeatingAirFlow(0.78 * 0.9)
            hx.setLatentEffectivenessat100HeatingAirFlow(0.61 * 0.9)
            hx.setLatentEffectivenessat75HeatingAirFlow(0.68 * 0.9)
            hx.setSensibleEffectivenessat100CoolingAirFlow(0.75 * 0.9)
            hx.setSensibleEffectivenessat75CoolingAirFlow(0.78 * 0.9)
            hx.setLatentEffectivenessat100CoolingAirFlow(0.55 * 0.9)
            hx.setLatentEffectivenessat75CoolingAirFlow(0.60 * 0.9)
          # set parameters for HRV
          when 'HRV'
            # set efficiencies; assumed 90% airflow returned to unit
            hx.setSensibleEffectivenessat100HeatingAirFlow(0.84 * 0.9)
            hx.setSensibleEffectivenessat75HeatingAirFlow(0.86 * 0.9)
            hx.setLatentEffectivenessat100HeatingAirFlow(0)
            hx.setLatentEffectivenessat75HeatingAirFlow(0)
            hx.setSensibleEffectivenessat100CoolingAirFlow(0.83 * 0.9)
            hx.setSensibleEffectivenessat75CoolingAirFlow(0.84 * 0.9)
            hx.setLatentEffectivenessat100CoolingAirFlow(0)
            hx.setLatentEffectivenessat75CoolingAirFlow(0)
          end

          # fan efficiency ranges from 40-60% (Energy Modeling Guide for Very High Efficiency DOAS Final Report)
          default_fan_efficiency = 0.55
          power = (oa_flow_m3_per_s * 174.188 / default_fan_efficiency) + ((oa_flow_m3_per_s * 0.9 * 124.42) / default_fan_efficiency)
          hx.setNominalElectricPower(power)
        end
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
