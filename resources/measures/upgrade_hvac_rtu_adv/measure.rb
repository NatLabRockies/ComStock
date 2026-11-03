# frozen_string_literal: true

# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/
require 'comstock-typical'
require 'json'

# start the measure
class UpgradeHvacRtuAdv < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    return 'upgrade_hvac_rtu_adv'
  end

  # human readable description
  def description
    return 'replaces exisiting RTUs with top-of-the-line RTUs in the current (as of 7/30/2025)'\
           ' market. Improvements are from increased rated efficiencies, off-rated performances,'\
           ' and part-load performances.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'The high-efficiency RTU measure is applicable to ComStock models with either gas'\
           ' furnace RTUs (“PSZ-AC with gas coil”), electric resistance RTUs (“PSZ-AC with'\
           ' electric coil”), gas boilers (“PSZ-AC with gas boiler”), or district heating'\
           ' (“PSZ-AC with district hot water”). This analysis includes only products that'\
           ' meet or exceed current building energy'\
           ' codes while representing the highest-performing'\
           ' models available on the market today. If the building currently uses gas for space'\
           ' heating, the upgraded RTU will be equipped with a gas furnace. If the building uses'\
           ' electricity for space heating, the RTU will include electric resistance heating.'\
           ' Heat/Energy Recovery Ventilator (H/ERVs) can be included in this measure,'\
           ' and the implementation and modeling will follow'\
           ' the approach used in previous H/ERV work.'\
           ' Demand Control Ventilation (DCV) can be included in this measure,'\
           ' and the implementation and modeling will follow'\
           ' the approach used in previous DCV work.'
  end

  # define the arguments that the user will input
  def arguments(_model)
    args = OpenStudio::Measure::OSArgumentVector.new

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

    # enable/disable debugging outputs
    debug_verbose = OpenStudio::Measure::OSArgument.makeBoolArgument('debug_verbose', true)
    debug_verbose.setDisplayName('Enable Debugging Outputs?')
    debug_verbose.setDefaultValue(false)
    args << debug_verbose

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

  # Returns true if the air loop is residential (no outdoor air system), false otherwise.
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

  # Returns true if the air loop contains an evaporative cooler, false otherwise.
  def air_loop_evaporative_cooler?(air_loop_hvac)
    is_evap = false
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_EvaporativeCooler_Direct_ResearchSpecial',
          'OS_EvaporativeCooler_Indirect_ResearchSpecial',
          'OS_EvaporativeFluidCooler_SingleSpeed',
          'OS_EvaporativeFluidCooler_TwoSpeed'
        is_evap = true
      end
    end
    is_evap
  end

  # Returns true if the air loop contains a unitary system, false otherwise.
  def air_loop_hvac_unitary_system?(air_loop_hvac)
    is_unitary_system = false
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_AirLoopHVAC_UnitarySystem',
        'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir',
        'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir_MultiSpeed',
        'OS_AirLoopHVAC_UnitaryHeatCool_VAVChangeoverBypass'
        is_unitary_system = true
      end
    end
    is_unitary_system
  end

  # Returns combined performance curves from resources folder
  def combine_all_performance_curves
    combined_data = {
      'tables' => {
        'curves' => {
          'table' => []
        }
      }
    }

    Dir[File.join(File.dirname(__FILE__), 'resources', '*.json')].each do |file_path|
      json_data = JSON.parse(File.read(file_path))
      tables = json_data.dig('tables', 'curves', 'table')
      raise "Unexpected JSON structure in #{file_path}" unless tables.is_a?(Array)

      combined_data['tables']['curves']['table'].concat(tables)
    end
    combined_data
  end

  # Returns the curve object based on curve type, unit size, and operation stage.
  def model_add_curve(runner, model, curve_name, standards_data_curve, std, debug_verbose)
    # Return existing curve if found
    existing_curve = (
      model.getCurveLinears +
      model.getCurveCubics +
      model.getCurveQuadratics +
      model.getCurveBicubics +
      model.getCurveBiquadratics +
      model.getCurveQuadLinears
    ).find { |curve| curve.name.get.to_s == curve_name }

    if existing_curve
      if debug_verbose
        runner.registerInfo("--- found curve already existing from the model: #{
          existing_curve.name
        }")
      end
      return existing_curve
    end

    # Find curve data from JSON
    data = std.model_find_object(
      standards_data_curve['tables']['curves'],
      'name' => curve_name
    )
    return nil unless data

    case data['form']
    when 'Linear'
      curve = OpenStudio::Model::CurveLinear.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'] || 0)
      curve.setCoefficient2x(data['coeff_2'] || 0)
      if data['minimum_independent_variable_1']
        curve.setMinimumValueofx(
          data['minimum_independent_variable_1'].to_f
        )
      end
      if data['maximum_independent_variable_1']
        curve.setMaximumValueofx(
          data['maximum_independent_variable_1'].to_f
        )
      end
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(
          data['minimum_dependent_variable_output'].to_f
        )
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(
          data['maximum_dependent_variable_output'].to_f
        )
      end
      return curve

    when 'Cubic'
      curve = OpenStudio::Model::CurveCubic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'] || 0)
      curve.setCoefficient2x(data['coeff_2'] || 0)
      curve.setCoefficient3xPOW2(data['coeff_3'] || 0)
      curve.setCoefficient4xPOW3(data['coeff_4'] || 0)
      if data['minimum_independent_variable_1']
        curve.setMinimumValueofx(data['minimum_independent_variable_1'].to_f)
      end
      if data['maximum_independent_variable_1']
        curve.setMaximumValueofx(data['maximum_independent_variable_1'].to_f)
      end
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'].to_f)
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'].to_f)
      end
      return curve

    when 'Quadratic'
      curve = OpenStudio::Model::CurveQuadratic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'] || 0)
      curve.setCoefficient2x(data['coeff_2'] || 0)
      curve.setCoefficient3xPOW2(data['coeff_3'] || 0)
      if data['minimum_independent_variable_1']
        curve.setMinimumValueofx(data['minimum_independent_variable_1'].to_f)
      end
      if data['maximum_independent_variable_1']
        curve.setMaximumValueofx(data['maximum_independent_variable_1'].to_f)
      end
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'].to_f)
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'].to_f)
      end
      return curve

    when 'BiCubic'
      curve = OpenStudio::Model::CurveBicubic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'] || 0)
      curve.setCoefficient2x(data['coeff_2'] || 0)
      curve.setCoefficient3xPOW2(data['coeff_3'] || 0)
      curve.setCoefficient4y(data['coeff_4'] || 0)
      curve.setCoefficient5yPOW2(data['coeff_5'] || 0)
      curve.setCoefficient6xTIMESY(data['coeff_6'] || 0)
      curve.setCoefficient7xPOW3(data['coeff_7'] || 0)
      curve.setCoefficient8yPOW3(data['coeff_8'] || 0)
      curve.setCoefficient9xPOW2TIMESY(data['coeff_9'] || 0)
      curve.setCoefficient10xTIMESYPOW2(data['coeff_10'] || 0)
      if data['minimum_independent_variable_1']
        curve.setMinimumValueofx(data['minimum_independent_variable_1'].to_f)
      end
      if data['maximum_independent_variable_1']
        curve.setMaximumValueofx(data['maximum_independent_variable_1'].to_f)
      end
      if data['minimum_independent_variable_2']
        curve.setMinimumValueofy(data['minimum_independent_variable_2'].to_f)
      end
      if data['maximum_independent_variable_2']
        curve.setMaximumValueofy(data['maximum_independent_variable_2'].to_f)
      end
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'].to_f)
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'].to_f)
      end
      return curve

    when 'BiQuadratic'
      curve = OpenStudio::Model::CurveBiquadratic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'] || 0)
      curve.setCoefficient2x(data['coeff_2'] || 0)
      curve.setCoefficient3xPOW2(data['coeff_3'] || 0)
      curve.setCoefficient4y(data['coeff_4'] || 0)
      curve.setCoefficient5yPOW2(data['coeff_5'] || 0)
      curve.setCoefficient6xTIMESY(data['coeff_6'] || 0)
      if data['minimum_independent_variable_1']
        curve.setMinimumValueofx(data['minimum_independent_variable_1'].to_f)
      end
      if data['maximum_independent_variable_1']
        curve.setMaximumValueofx(data['maximum_independent_variable_1'].to_f)
      end
      if data['minimum_independent_variable_2']
        curve.setMinimumValueofy(data['minimum_independent_variable_2'].to_f)
      end
      if data['maximum_independent_variable_2']
        curve.setMaximumValueofy(data['maximum_independent_variable_2'].to_f)
      end
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'].to_f)
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'].to_f)
      end
      return curve

    when 'BiLinear'
      curve = OpenStudio::Model::CurveBiquadratic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'] || 0)
      curve.setCoefficient2x(data['coeff_2'] || 0)
      curve.setCoefficient4y(data['coeff_3'] || 0)
      if data['minimum_independent_variable_1']
        curve.setMinimumValueofx(data['minimum_independent_variable_1'].to_f)
      end
      if data['maximum_independent_variable_1']
        curve.setMaximumValueofx(data['maximum_independent_variable_1'].to_f)
      end
      if data['minimum_independent_variable_2']
        curve.setMinimumValueofy(data['minimum_independent_variable_2'].to_f)
      end
      if data['maximum_independent_variable_2']
        curve.setMaximumValueofy(data['maximum_independent_variable_2'].to_f)
      end
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'].to_f)
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'].to_f)
      end
      return curve

    when 'QuadLinear'
      curve = OpenStudio::Model::CurveQuadLinear.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'] || 0)
      curve.setCoefficient2w(data['coeff_2'] || 0)
      curve.setCoefficient3x(data['coeff_3'] || 0)
      curve.setCoefficient4y(data['coeff_4'] || 0)
      curve.setCoefficient5z(data['coeff_5'] || 0)
      curve.setMinimumValueofw(data['minimum_independent_variable_w'].to_f)
      curve.setMaximumValueofw(data['maximum_independent_variable_w'].to_f)
      curve.setMinimumValueofx(data['minimum_independent_variable_x'].to_f)
      curve.setMaximumValueofx(data['maximum_independent_variable_x'].to_f)
      curve.setMinimumValueofy(data['minimum_independent_variable_y'].to_f)
      curve.setMaximumValueofy(data['maximum_independent_variable_y'].to_f)
      curve.setMinimumValueofz(data['minimum_independent_variable_z'].to_f)
      curve.setMaximumValueofz(data['maximum_independent_variable_z'].to_f)
      curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'].to_f)
      curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'].to_f)
      return curve

    when 'MultiVariableLookupTable'
      num_ind_var = data['number_independent_variables'].to_i
      table = OpenStudio::Model::TableLookup.new(model)
      table.setName(data['name'])
      table.setNormalizationDivisor(data['normalization_reference'].to_f)
      table.setOutputUnitType(data['output_unit_type'])

      data_points = data.select { |k, _| k.include?('data_point') }
                        .sort_by { |_, v| v.split(',').map(&:to_f) }

      data_points.each do |_, v|
        table.addOutputValue(v.split(',')[num_ind_var].to_f)
      end

      num_ind_var.times do |i|
        ivar = OpenStudio::Model::TableIndependentVariable.new(model)
        ivar.setName("#{data['name']}_ind_#{i + 1}")
        ivar.setInterpolationMethod(data['interpolation_method'])
        ivar.setMinimumValue(data["minimum_independent_variable_#{i + 1}"].to_f)
        ivar.setMaximumValue(data["maximum_independent_variable_#{i + 1}"].to_f)
        ivar.setUnitType(data["input_unit_type_x#{i + 1}"])
        unique_vals = data_points.map { |_, val| val.split(',')[i].to_f }.uniq
        unique_vals.each { |v| ivar.addValue(v) }
        table.addIndependentVariable(ivar)
      end

      return table
    end
  end

  # Returns the curve object based on curve type, unit size, and operation stage.
  def get_curve_name(runner, type, reference_capacity, operation_stage, debug_verbose)
    # Determine prefix and suffix
    prefix_suffix_map = {
      'fn_of_t' => ['lookup', ''],
      'fn_of_ff' => ['poly', ''],
      'fn_of_plr' => ['poly', 'plr']
    }
    curve_name_prefix, curve_name_suffix = prefix_suffix_map.find do |k, _|
      type.include?(k)
    end&.last || [nil, nil]

    # Determine dependent variable
    curve_name_dep_var =
      if type.include?('capacity_')
        'capacity'
      elsif type.include?('eir_')
        'eir'
      end

    # Determine operation stage
    curve_name_stage = case operation_stage
                      when 'rated' then ''
                      when 1        then 'low'
                      when 2        then 'med'
                      when 3        then 'high'
                       end

    # Determine size category
    curve_name_size, = UpgradeHvacRtuAdv.get_capacity_category(rated_capacity_w)

    # Manual overrides
    if curve_name_suffix != 'plr' && curve_name_size == '20_9999' &&
       curve_name_dep_var == 'eir' && [
         'low', 'med'
       ].include?(curve_name_stage)
      curve_name_stage = 'high'
    end
    curve_name_size = '11_20' if curve_name_suffix == 'plr' && curve_name_size == '20_9999'

    # Construct curve name
    parts = [curve_name_prefix, 'rtu_adv', curve_name_dep_var, curve_name_size, curve_name_suffix,
             curve_name_stage]
    curve_name = parts.reject(&:empty?).join('_')

    if debug_verbose
      runner.registerInfo("--- stage #{
        operation_stage
      } | reference_capacity_w = #{
          reference_capacity
        } | curve = #{
            curve_name
          }")
    end

    curve_name
  end

  # Return capacity category based on rated capacity
  def self.get_capacity_category(runner, rated_capacity_w)
    if rated_capacity_w <= 0
      runner.registerError("Invalid rated capacity: #{rated_capacity_w}. Must be greater than 0.")
      return nil, nil
    end

    case rated_capacity_w
    when 0.00001..39_564.59445
      label_curve = '0_11'
      label_category = 'small_unit'
    when 39_564.59446..70_337.0568
      label_curve = '11_20'
      label_category = 'medium_unit'
    else # anything above 70,337.0568
      label_curve = '20_9999'
      label_category = 'large_unit'
    end

    return label_curve, label_category
  end

  # Return stage category based on stage number
  def self.get_stage_category(runner, stage_number)
    case stage_number
    when 3
      label_stage = 'high_stage'
    when 2
      label_stage = 'medium_stage'
    when 1
      label_stage = 'low_stage'
    else
      runner.registerError("Invalid stage number: #{stage_number}. Must be 1, 2, or 3.")
      return nil
    end
    return label_stage
  end

  # Return sensible heat ratio based on stage
  # SHR values averaged from rated conditions of manufacturer data
  def self.get_shr(runner, stage_number)
    case stage_number
    when 3
      return 0.626 # 0.7279780362307693
    when 2
      return 0.637 # 0.7402533904615385
    when 1
      return 0.7 # 0.8136649204374999
    else
      runner.registerError("Invalid stage number: #{stage_number}. Must be 1, 2, or 3.")
      return nil
    end
  end

  # Return reference COP ratio based on stage
  # ratio values averaged from rated conditions of manufacturer data
  def self.get_reference_cop_ratio(runner, stage_number)
    case stage_number
    when 3
      return 1.0
    when 2
      return 1.096739
    when 1
      return 1.130014
    else
      runner.registerError("Invalid stage number: #{stage_number}. Must be 1, 2, or 3.")
      return nil
    end
  end

  # Return rated cfm/ton value that best represents actual product
  def self.get_rated_cfm_per_ton(runner, rated_capacity_w)
    # Determine capacity category once to avoid repeated calls
    _, capacity_category = UpgradeHvacRtuAdv.get_capacity_category(runner, rated_capacity_w)

    # Assign reference CFM/ton based on capacity category
    rated_cfm_per_ton = case capacity_category
                        when 'small_unit'
                          (-3.0642e-03 * rated_capacity_w) + 457.77
                        when 'medium_unit'
                          (3.1376e-05 * rated_capacity_w) + 353.36
                        when 'large_unit'
                          (-2.1111e-04 * rated_capacity_w) + 368.08
                        else
                          runner.registerError("Invalid capacity category: #{
                            capacity_category
                          } for capacity value of #{rated_capacity_w} W.")
                          return nil
                        end

    # Cap the output between 324 and 400
    rated_cfm_per_ton.clamp(324, 400)
  end

  # Returns the rated cooling COP for advanced RTU given the rated capacity (W).
  def self.get_rated_cop_cooling_adv(runner, rated_capacity_w)
    intercept = nil
    coef_1 = nil
    min_cop = nil
    max_cop = nil
    _, label_category = UpgradeHvacRtuAdv.get_capacity_category(runner, rated_capacity_w)
    case label_category
    when 'small_unit'
      intercept = 4.26
      coef_1 = -0.0000027392
      min_cop = 4.15
      max_cop = 4.26
    when 'medium_unit'
      intercept = 4.24
      coef_1 = -0.0000057962
      min_cop = 3.83
      max_cop = 4.01
    when 'large_unit'
      intercept = 3.68
      coef_1 = -1.6479e-07
      min_cop = 3.62
      max_cop = 3.67
    else
      runner.registerError("Invalid capacity category: #{
        label_category
      } for capacity value of #{
          rated_capacity_w
        } W.")
      return nil
    end
    rated_cop_cooling = intercept + (coef_1 * rated_capacity_w)
    rated_cop_cooling.clamp(min_cop, max_cop)
  end

  # Converts CFM/ton to m^3/s per W.
  def cfm_per_ton_to_m_3_per_sec_watts(cfm_per_ton)
    OpenStudio.convert(OpenStudio.convert(cfm_per_ton, 'cfm', 'm^3/s').get, 'W', 'ton').get
  end

  # Adjusts the rated COP based on EnergyPlus-sized airflow and
  # a reference airflow derived from manufacturer-based CFM/ton.
  def adjust_rated_cop_from_ref_cfm_per_ton(runner, airflow_sized_m_3_per_s, rated_capacity_w,
                                            original_rated_cop, eir_modifier_curve_flow)
    reference_cfm_per_ton = UpgradeHvacRtuAdv.get_rated_cfm_per_ton(runner, rated_capacity_w)

    # Convert reference CFM/ton to m³/s
    airflow_reference_m_3_per_s = cfm_per_ton_to_m_3_per_sec_watts(reference_cfm_per_ton) *
                                  rated_capacity_w

    # Prevent divide-by-zero
    if airflow_reference_m_3_per_s <= 0
      runner.registerError("Reference airflow is zero or negative (#{
        airflow_reference_m_3_per_s
      }). Cannot compute flow fraction.")
      return nil
    end

    # Calculate flow fraction (actual/reference)
    flow_fraction = airflow_sized_m_3_per_s / airflow_reference_m_3_per_s

    # Evaluate the energy input ratio (EIR) modifier based on flow fraction
    modifier_eir = nil
    if eir_modifier_curve_flow.to_CurveBiquadratic.is_initialized
      modifier_eir = eir_modifier_curve_flow.evaluate(flow_fraction, 0)
    elsif eir_modifier_curve_flow.to_CurveCubic.is_initialized ||
          eir_modifier_curve_flow.to_CurveQuadratic.is_initialized
      modifier_eir = eir_modifier_curve_flow.evaluate(flow_fraction)
    else
      runner.registerError("Unsupported curve type for EIR modifier: #{
        eir_modifier_curve_flow.name
      }. Must be CurveBiquadratic, CurveQuadratic, or CurveCubic.")
      return nil
    end

    # Adjust rated COP (COP = 1 / EIR)
    adjusted_cop = original_rated_cop * (1.0 / modifier_eir)
    return adjusted_cop
  end

  #### End predefined functions

  # define what happens when the measure is run
  # rubocop:disable Naming/PredicateMethod
  def run(model, runner, user_arguments)
    super

    # ---------------------------------------------------------
    # use the built-in error checking
    # ---------------------------------------------------------
    return false unless runner.validateUserArguments(arguments(model), user_arguments)

    # ---------------------------------------------------------
    # assign the user inputs to variables
    # ---------------------------------------------------------
    hr = runner.getBoolArgumentValue('hr', user_arguments)
    dcv = runner.getBoolArgumentValue('dcv', user_arguments)
    debug_verbose = runner.getBoolArgumentValue('debug_verbose', user_arguments)

    # ---------------------------------------------------------
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
    is_sizing_run_needed = true
    model.getAirLoopHVACs.each do |air_loop_hvac|
      # skip units that are not single zone
      next if air_loop_hvac.thermalZones.length > 1

      # skip DOAS units; check sizing for all OA and for DOAS in name
      sizing_system = air_loop_hvac.sizingSystem
      if sizing_system.allOutdoorAirinCooling &&
         sizing_system.allOutdoorAirinHeating &&
         (air_loop_res?(air_loop_hvac) == false) &&
         (air_loop_hvac.name.to_s.include?('DOAS') ||
           air_loop_hvac.name.to_s.include?('doas'))
        next
      end

      # skip if already heat pump RTU
      # loop throug air loop components to check for heat pump or water coils
      is_hp = false
      is_water_cooling_coil = false
      has_heating_coil = true
      air_loop_hvac.supplyComponents.each do |component|
        obj_type = component.iddObjectType.valueName.to_s
        # flag system if contains water coil; this will cause air loop to be skipped
        is_water_cooling_coil = true if ['Coil_Cooling_Water'].any? do |word|
          obj_type.include?(word)
        end
        # flag gas heating as true if gas coil is found in any airloop
        prim_ht_fuel_type = 'gas' if ['Gas', 'GAS', 'gas'].any? { |word| obj_type.include?(word) }
        # check unitary systems for DX heating
        if obj_type == 'OS_AirLoopHVAC_UnitarySystem'
          unitary_sys = component.to_AirLoopHVACUnitarySystem.get

          # check if heating coil is DX or water-based; if so, flag the air loop to be skipped
          if unitary_sys.heatingCoil.is_initialized
            htg_coil = unitary_sys.heatingCoil.get.iddObjectType.valueName.to_s
            # check for DX heating coil
            if ['Heating_DX'].any? { |word| htg_coil.include?(word) }
              is_hp = true
            # check for gas heating
            elsif ['Gas', 'GAS', 'gas'].any? { |word| htg_coil.include?(word) }
              prim_ht_fuel_type = 'gas'
            end
          else
            runner.registerWarning("No heating coil was found for air loop: #{
              air_loop_hvac.name
            } - this equipment will be skipped.")
            has_heating_coil = false
          end
          # check if cooling coil is water-based
          if unitary_sys.coolingCoil.is_initialized
            clg_coil = unitary_sys.coolingCoil.get.iddObjectType.valueName.to_s
            # skip unless coil is water based
            next unless ['Water'].any? { |word| clg_coil.include?(word) }

            is_water_cooling_coil = true
          end
        # flag as hp if air loop contains a heating dx coil
        elsif ['Heating_DX'].any? { |word| obj_type.include?(word) }
          is_hp = true
        end
      end
      # also skip based on string match, or if dx heating component existed
      if (is_hp == true) |
         (air_loop_hvac.name.to_s.include?('HP') ||
           air_loop_hvac.name.to_s.include?('hp') ||
             air_loop_hvac.name.to_s.include?('heat pump') ||
               air_loop_hvac.name.to_s.include?('Heat Pump'))
        next
      end
      # skip data centers
      next if ['Data Center', 'DataCenter', 'data center', 'datacenter', 'DATACENTER',
               'DATA CENTER'].any? do |word|
                air_loop_hvac.name.get.include?(word)
              end
      # skip kitchens
      next if OpenstudioStandards::SpaceType.air_loop_hvac_serves_space_types?(air_loop_hvac, ['food preparation'])
      # skip VAV sysems
      next if ['VAV', 'PVAV'].any? { |word| air_loop_hvac.name.get.include?(word) }
      # skip if residential system
      next if air_loop_res?(air_loop_hvac)
      # skip if system has no outdoor air, also indication of residential system
      next unless air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized
      # skip if evaporative cooling systems
      next if air_loop_evaporative_cooler?(air_loop_hvac)
      # skip if water cooling or cooled system
      next if is_water_cooling_coil == true
      # skip if space is not heated and cooled
      unless OpenstudioStandards::ThermalZone.thermal_zone_heated?(air_loop_hvac.thermalZones[0]) &&
             OpenstudioStandards::ThermalZone.thermal_zone_cooled?(air_loop_hvac.thermalZones[0])
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
      if orig_htg_coil.to_CoilHeatingElectric.is_initialized
        orig_htg_coil = orig_htg_coil.to_CoilHeatingElectric.get
        if orig_htg_coil.nominalCapacity.is_initialized
          orig_htg_coil_gross_cap = orig_htg_coil.nominalCapacity.to_f
        end
      elsif orig_htg_coil.to_CoilHeatingGas.is_initialized
        orig_htg_coil = orig_htg_coil.to_CoilHeatingGas.get
        if orig_htg_coil.nominalCapacity.is_initialized
          orig_htg_coil_gross_cap = orig_htg_coil.nominalCapacity.to_f
        end
      elsif orig_htg_coil.to_CoilHeatingWater.is_initialized
        orig_htg_coil = orig_htg_coil.to_CoilHeatingWater.get
        if orig_htg_coil.ratedCapacity.is_initialized
          orig_htg_coil_gross_cap = orig_htg_coil.ratedCapacity.to_f
        end
      end

      # only require sizing run if required attributes have not been hardsized.
      next if oa_flow_m3_per_s.nil?
      next if old_terminal_sa_flow_m3_per_s.nil?
      next if orig_clg_coil_gross_cap.nil?
      next if orig_htg_coil_gross_cap.nil?

      is_sizing_run_needed = false
    end

    # ---------------------------------------------------------
    # do sizing run if model is not hard-sized
    # ---------------------------------------------------------
    if is_sizing_run_needed == true
      runner.registerInfo('sizing summary: sizing run needed')
      return false if std.model_run_sizing_run(model, "#{Dir.pwd}/SR1") == false

      model.applySizingValues
    end

    # ---------------------------------------------------------
    # remove units with high OA fractions and night cycling
    # ---------------------------------------------------------
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
        runner.registerError("No outdoor air sizing information was found for #{
          controller_oa.name
        }, which is required for setting ERV wheel power consumption.")
        return false
      end

      # get design supply air flow rate
      old_terminal_sa_flow_m3_per_s = nil
      if air_loop_hvac.designSupplyAirFlowRate.is_initialized
        old_terminal_sa_flow_m3_per_s = air_loop_hvac.designSupplyAirFlowRate.get
      elsif air_loop_hvac.isDesignSupplyAirFlowRateAutosized
        old_terminal_sa_flow_m3_per_s = air_loop_hvac.autosizedDesignSupplyAirFlowRate.get
      else
        runner.registerError("No sizing data available for air loop #{
          air_loop_hvac.name
        } zone terminal box.")
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

      runner.registerWarning("Air loop #{
        air_loop_hvac.name
      } has night cycling operations and an outdoor air ratio of #{
          min_oa_flow_ratio.round(2)
        } which exceeds the maximum allowable limit of #{
            oa_ration_allowance
          } (due to an EnergyPlus night cycling bug with multispeed coils)"\
            ' making this RTU not applicable at this time.')
      # remove air loop from applicable list
      selected_air_loops.delete(air_loop_hvac)
      applicable_area_m2 -= thermal_zone.floorArea * thermal_zone.multiplier
      # remove area served by air loop from applicability
    end

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
    # report initial condition of model
    condition = "The building has #{
      selected_air_loops.size
    } applicable air loops (out of the total #{
        model.getAirLoopHVACs.size
      } airloops in the model) that will be replaced with high-efficiency RTUs, serving #{
          applicable_area_m2.round(0)
        } m2 of floor area. The remaning airloops were determined to be not applicable."
    runner.registerInitialCondition(condition)

    # ---------------------------------------------------------
    # applicability checks for heat recovery; building type
    # ---------------------------------------------------------
    # building type not applicable to ERVs as part of this measure will receive
    # no additional or modification of ERV systems
    # this is only relevant if the user selected to add ERVs
    # space type applicability is handled later
    # in the code when looping through individual air loops
    building_types_to_exclude = ['RFF', 'RSD', 'QuickServiceRestaurant', 'FullServiceRestaurant']
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
      runner.registerWarning('The user chose to include energy recovery in the'\
                              ' high-efficiency RTUs,'\
                             " but the building type -#{
                              model_building_type
                            }- is not applicable for energy recovery."\
                             ' Energy recovery will not be added.')
    end

    # get climate full string and classification (i.e. "5A")
    climate_zone = OpenstudioStandards::Weather.model_get_climate_zone(model)
    climate_zone_classification = climate_zone.split('-')[-1]

    # Get ER/HR type from climate zone
    _, _, doas_type =
      if ['1A', '2A', '3A', '4A', '5A', '6A', '7', '7A', '8',
          '8A'].include?(climate_zone_classification)
        [12.7778, 19.4444, 'ERV']
      else
        [15.5556, 19.4444, 'HRV']
      end

    # ---------------------------------------------------------
    # pre-load curves and tables
    # ---------------------------------------------------------
    if debug_verbose
      runner.registerInfo('--- gathering custom data into a variable')
    end
    custom_performance_map_data = combine_all_performance_curves

    # curve/table mapping
    curve_table_map = {
      'high_stage' => {
        'small_unit' => {
          'eir_fn_of_plr' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_0_11_plr',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_capacity_0_11_high',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_capacity_0_11_high',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_eir_0_11_high',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_0_11_high',
            custom_performance_map_data, std, debug_verbose
          )
        },
        'medium_unit' => {
          'eir_fn_of_plr' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_11_20_plr',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_capacity_11_20_high',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_capacity_11_20_high',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_eir_11_20_high',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_11_20_high',
            custom_performance_map_data, std, debug_verbose
          )
        },
        'large_unit' => {
          'eir_fn_of_plr' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_11_20_plr',
            custom_performance_map_data, std, debug_verbose
          ), # missing (i.e., data unavailable) curve assumed
          'capacity_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_capacity_20_9999_high',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_capacity_20_9999_high',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_eir_20_9999_high',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_20_9999_high',
            custom_performance_map_data, std, debug_verbose
          )
        }
      },
      'medium_stage' => {
        'small_unit' => {
          'eir_fn_of_plr' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_0_11_plr',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_capacity_0_11_med',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_capacity_0_11_med',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_eir_0_11_med',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_0_11_med',
            custom_performance_map_data, std, debug_verbose
          )
        },
        'medium_unit' => {
          'eir_fn_of_plr' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_11_20_plr',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_capacity_11_20_med',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_capacity_11_20_med',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_eir_11_20_med',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_11_20_med',
            custom_performance_map_data, std, debug_verbose
          )
        },
        'large_unit' => {
          'eir_fn_of_plr' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_11_20_plr',
            custom_performance_map_data, std, debug_verbose
          ), # missing (i.e., data unavailable) curve assumed
          'capacity_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_capacity_20_9999_med',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_capacity_20_9999_med',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_eir_20_9999_high',
            custom_performance_map_data, std, debug_verbose
          ), # missing (i.e., data unavailable) curve assumed
          'eir_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_20_9999_high',
            custom_performance_map_data, std, debug_verbose
          ) # missing (i.e., data unavailable) curve assumed
        }
      },
      'low_stage' => {
        'small_unit' => {
          'eir_fn_of_plr' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_0_11_plr',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_capacity_0_11_low',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_capacity_0_11_low',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_eir_0_11_low',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_0_11_low',
            custom_performance_map_data, std, debug_verbose
          )
        },
        'medium_unit' => {
          'eir_fn_of_plr' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_11_20_plr',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_capacity_11_20_low',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_capacity_11_20_low',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_eir_11_20_low',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_11_20_low',
            custom_performance_map_data, std, debug_verbose
          )
        },
        'large_unit' => {
          'eir_fn_of_plr' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_11_20_plr',
            custom_performance_map_data, std, debug_verbose
          ), # missing (i.e., data unavailable) curve assumed
          'capacity_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_capacity_20_9999_low',
            custom_performance_map_data, std, debug_verbose
          ),
          'capacity_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_capacity_20_9999_low',
            custom_performance_map_data, std, debug_verbose
          ),
          'eir_fn_of_t' => model_add_curve(
            runner, model, 'lookup_rtu_adv_eir_20_9999_high',
            custom_performance_map_data, std, debug_verbose
          ), # missing (i.e., data unavailable) curve assumed
          'eir_fn_of_ff' => model_add_curve(
            runner, model, 'poly_rtu_adv_eir_20_9999_high',
            custom_performance_map_data, std, debug_verbose
          ) # missing (i.e., data unavailable) curve assumed
        }
      }
    }

    # ---------------------------------------------------------
    # replace existing applicable air loops with new high-efficiency rtu air loops
    # ---------------------------------------------------------
    selected_air_loops.sort.each do |air_loop_hvac|
      if debug_verbose
        runner.registerInfo('### ----------------------------------------------------------------')
        runner.registerInfo("### processing air loop: #{air_loop_hvac.name} ")
        runner.registerInfo('### ----------------------------------------------------------------')
      end

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
      orig_clg_coil_rated_airflow_m_3_per_s = nil
      orig_htg_coil_obj_existing = nil
      supply_airflow_during_cooling = nil
      supply_airflow_during_heating = nil
      hot_water_loop = nil

      # -------------------------------------------------------
      # delete existing system
      # -------------------------------------------------------
      equip_to_delete = []
      # for unitary systems
      if air_loop_hvac_unitary_system?(air_loop_hvac)

        # loop through each relevant component.
        # store information needed as variable
        # remove the existing equipment
        air_loop_hvac.supplyComponents.each do |component|
          # convert component to string name
          obj_type = component.iddObjectType.valueName.to_s
          # skip unless component is of relevant type
          next unless ['Fan', 'Unitary', 'Coil'].any? { |word| obj_type.include?(word) }

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
          # get airflow during cooling/heating operation
          supply_airflow_during_cooling = unitary_sys.supplyAirFlowRateDuringCoolingOperation.get
          supply_airflow_during_heating = unitary_sys.supplyAirFlowRateDuringHeatingOperation.get
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
          if supply_fan_avail_sched.to_ScheduleConstant.is_initialized ||
             supply_fan_avail_sched.to_ScheduleRuleset.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          else
            runner.registerError("Supply fan availability schedule type for #{
              supply_fan.name
            } not supported.")
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
              runner.registerError("Original cooling coil capacity for #{
                air_loop_hvac.name
              } not found. Either it was not directly specified,"\
                ' or sizing run data is not available.')
            end
            if orig_clg_coil.autosizedRatedAirFlowRate == true
              orig_clg_coil_rated_airflow_m_3_per_s = orig_clg_coil.autosizedRatedAirFlowRate.get
            elsif orig_clg_coil.ratedAirFlowRate.is_initialized
              orig_clg_coil_rated_airflow_m_3_per_s = orig_clg_coil.ratedAirFlowRate.to_f
            else
              runner.registerError("Original cooling coil airflow for #{
                air_loop_hvac.name
              } not found. Either it was not directly specified,"\
                ' or sizing run data is not available.')
            end
          # check for two speed DX cooling coil
          elsif orig_clg_coil.to_CoilCoolingDXTwoSpeed.is_initialized
            orig_clg_coil = orig_clg_coil.to_CoilCoolingDXTwoSpeed.get
            if orig_clg_coil.autosizedRatedHighSpeedTotalCoolingCapacity.is_initialized
              orig_clg_coil_gross_cap =
                orig_clg_coil.autosizedRatedHighSpeedTotalCoolingCapacity.get
            elsif orig_clg_coil.ratedHighSpeedTotalCoolingCapacity.is_initialized
              orig_clg_coil_gross_cap =
                orig_clg_coil.ratedHighSpeedTotalCoolingCapacity.get
            else
              runner.registerError("Original cooling coil capacity for #{
                air_loop_hvac.name
              } not found. Either it was not directly specified,"\
                ' or sizing run data is not available.')
            end
            if orig_clg_coil.autosizedRatedHighSpeedAirFlowRate.is_initialized
              orig_clg_coil_rated_airflow_m_3_per_s =
                orig_clg_coil.autosizedRatedHighSpeedAirFlowRate.get
            elsif orig_clg_coil.ratedHighSpeedAirFlowRate.is_initialized
              orig_clg_coil_rated_airflow_m_3_per_s =
                orig_clg_coil.ratedHighSpeedAirFlowRate.get
            else
              runner.registerError("Original cooling coil airflow for #{
                air_loop_hvac.name
              } not found. Either it was not directly specified,"\
                ' or sizing run data is not available.')
            end
          else
            runner.registerError("Original cooling coil is of type #{
              orig_clg_coil.class
            } which is not currently supported by this measure.")
          end

          # get original heating coil capacity
          orig_htg_coil = unitary_sys.heatingCoil.get
          if orig_htg_coil.to_CoilHeatingElectric.is_initialized
            orig_htg_coil = orig_htg_coil.to_CoilHeatingElectric.get
            orig_htg_coil_obj_existing = orig_htg_coil.clone(model).to_CoilHeatingElectric.get
            if orig_htg_coil.isNominalCapacityAutosized == true
              orig_htg_coil_gross_cap = orig_htg_coil.autosizedNominalCapacity.get
            elsif orig_htg_coil.nominalCapacity.is_initialized
              orig_htg_coil_gross_cap = orig_htg_coil.nominalCapacity.to_f
            else
              runner.registerError("Original heating coil capacity for #{
                air_loop_hvac.name
              } not found. Either it was not directly specified,"\
                ' or sizing run data is not available.')
            end
          elsif orig_htg_coil.to_CoilHeatingGas.is_initialized
            orig_htg_coil = orig_htg_coil.to_CoilHeatingGas.get
            orig_htg_coil_obj_existing = orig_htg_coil.clone(model).to_CoilHeatingGas.get
            if orig_htg_coil.isNominalCapacityAutosized == true
              orig_htg_coil_gross_cap = orig_htg_coil.autosizedNominalCapacity.get
            elsif orig_htg_coil.nominalCapacity.is_initialized
              orig_htg_coil_gross_cap = orig_htg_coil.nominalCapacity.to_f
            else
              runner.registerError("Original heating coil capacity for #{
                air_loop_hvac.name
              } not found. Either it was not directly specified,"\
                ' or sizing run data is not available.')
            end
          elsif orig_htg_coil.to_CoilHeatingWater.is_initialized
            orig_htg_coil = orig_htg_coil.to_CoilHeatingWater.get
            hot_water_loop = orig_htg_coil.plantLoop.get
            orig_htg_coil_obj_existing = orig_htg_coil.clone(model).to_CoilHeatingWater.get
            if orig_htg_coil.isRatedCapacityAutosized == true
              orig_htg_coil_gross_cap = orig_htg_coil.autosizedRatedCapacity.get
            elsif orig_htg_coil.ratedCapacity.is_initialized
              orig_htg_coil_gross_cap = orig_htg_coil.ratedCapacity.to_f
            else
              runner.registerError("Original heating coil capacity for #{
                air_loop_hvac.name
              } not found. Either it was not directly specified,"\
              ' or sizing run data is not available.')
            end
          else
            runner.registerError("Heating coil for #{
              air_loop_hvac.name
            } is of an unsupported type. This measure currently supports"\
              ' CoilHeatingElectric and CoilHeatingGas object types.')
          end
        end

        if debug_verbose
          runner.registerInfo("--- found unitary system object: #{air_loop_hvac.name}")
          runner.registerInfo("--- found existing heating coil in unitary system object: #{
            orig_htg_coil_obj_existing.name
          }")
        end

      # get non-unitary system objects.
      else
        # loop through components
        air_loop_hvac.supplyComponents.each do |component|
          # convert component to string name
          obj_type = component.iddObjectType.valueName.to_s
          # skip unless component is of relevant type
          next unless ['Fan', 'Unitary', 'Coil'].any? { |word| obj_type.include?(word) }

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
          if supply_fan_avail_sched.to_ScheduleConstant.is_initialized ||
             supply_fan_avail_sched.to_ScheduleRuleset.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          else
            runner.registerError("Supply fan availability schedule type for #{
              supply_fan.name
            } not supported.")
            return false
          end
          # get supply fan motor efficiency
          fan_tot_eff = supply_fan.fanTotalEfficiency
          # get supply motor efficiency
          fan_mot_eff = supply_fan.motorEfficiency
          # get supply fan static pressure
          fan_static_pressure = supply_fan.pressureRise
          # set unitary supply fan operating schedule equal to
          # system schedule for non-unitary systems
          supply_fan_op_sched = hvac_operation_sched
          # set dehumidification type
          dehumid_type = 'None'
          # set control zone to the thermal zone.
          # This will be used in new unitary system object
          control_zone = air_loop_hvac.thermalZones[0]
          # set unitary availability schedule to be always on.
          # This will be used in new unitary system object.
          unitary_availability_sched = model.alwaysOnDiscreteSchedule
        end

        if debug_verbose
          runner.registerInfo("--- found non-unitary system object: #{air_loop_hvac.name}")
        end
      end

      # delete equipment from original loop
      equip_to_delete.each(&:remove)
      if debug_verbose
        runner.registerInfo('--- deleting applicable equipment from the air loop')
      end

      # -------------------------------------------------------
      # Update others
      # -------------------------------------------------------
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
        runner.registerError("No outdoor air sizing information was found for #{
          controller_oa.name
        }, which is required for setting ERV wheel power consumption.")
        return false
      end

      # change sizing parameter to vav
      sizing = air_loop_hvac.sizingSystem
      sizing.setCentralCoolingCapacityControlMethod('VAV') # CC-TMP

      # replace any CV terminal box with no reheat VAV terminal box
      # get old terminal box
      terminal = thermal_zone.airLoopHVACTerminal.get
      if terminal.to_AirTerminalSingleDuctConstantVolumeReheat.is_initialized
        old_terminal = terminal.to_AirTerminalSingleDuctConstantVolumeReheat.get
      elsif terminal.to_AirTerminalSingleDuctConstantVolumeNoReheat.is_initialized
        old_terminal = terminal.to_AirTerminalSingleDuctConstantVolumeNoReheat.get
      elsif terminal.to_AirTerminalSingleDuctVAVHeatAndCoolNoReheat.is_initialized
        old_terminal = terminal.to_AirTerminalSingleDuctVAVHeatAndCoolNoReheat.get
      elsif terminal.to_AirTerminalSingleDuctVAVHeatAndCoolReheat.is_initialized
        old_terminal = terminal.to_AirTerminalSingleDuctVAVHeatAndCoolReheat.get
      elsif terminal.to_AirTerminalSingleDuctVAVNoReheat.is_initialized
        old_terminal = terminal.to_AirTerminalSingleDuctVAVNoReheat.get
      elsif terminal.to_AirTerminalSingleDuctVAVReheat.is_initialized
        old_terminal = terminal.to_AirTerminalSingleDuctVAVReheat.get
      else
        runner.registerError(
          "Terminal box type for air loop #{air_loop_hvac.name} not supported."
        )
        return false
      end

      # get design supply air flow rate
      old_terminal_sa_flow_m3_per_s = nil
      if air_loop_hvac.designSupplyAirFlowRate.is_initialized
        old_terminal_sa_flow_m3_per_s = air_loop_hvac.designSupplyAirFlowRate.get
      elsif air_loop_hvac.isDesignSupplyAirFlowRateAutosized
        old_terminal_sa_flow_m3_per_s = air_loop_hvac.autosizedDesignSupplyAirFlowRate.get
      else
        runner.registerError("No sizing data available for air loop #{
          air_loop_hvac.name
        } zone terminal box.")
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
      new_terminal = OpenStudio::Model::AirTerminalSingleDuctVAVHeatAndCoolNoReheat.new(model)
      # set name of terminal box and add
      new_terminal.setName("#{thermal_zone.name} VAV Terminal")
      air_loop_hvac.addBranchForZone(thermal_zone, new_terminal.to_StraightComponent)

      # -------------------------------------------------------
      # fan update
      # -------------------------------------------------------
      # add new fan
      new_fan = OpenStudio::Model::FanVariableVolume.new(model, always_on)
      new_fan.setAvailabilitySchedule(supply_fan_avail_sched)
      new_fan.setName("#{air_loop_hvac.name} VFD Fan")
      new_fan.setMotorEfficiency(fan_mot_eff) # from Daikin Rebel E+ file
      new_fan.setFanPowerMinimumFlowRateInputMethod('Fraction')
      std.fan_change_motor_efficiency(new_fan, fan_mot_eff)
      new_fan.setFanPowerCoefficient1(0.259905264) # from Daikin Rebel E+ file
      new_fan.setFanPowerCoefficient2(-1.569867715) # from Daikin Rebel E+ file
      new_fan.setFanPowerCoefficient3(4.819732387) # from Daikin Rebel E+ file
      new_fan.setFanPowerCoefficient4(-3.904544154) # from Daikin Rebel E+ file
      new_fan.setFanPowerCoefficient5(1.394774218) # from Daikin Rebel E+ file

      # set minimum flow rate to 0.40, or higher as needed to maintain outdoor air requirements
      min_flow = 0.40

      # determine minimum airflow ratio for sizing; 0.4 is used unless OA requires higher
      min_airflow_m3_per_s = nil
      current_min_oa_flow_ratio = oa_flow_m3_per_s / old_terminal_sa_flow_m3_per_s
      if current_min_oa_flow_ratio > min_flow
        min_airflow_ratio = current_min_oa_flow_ratio
        min_airflow_m3_per_s = min_airflow_ratio * old_terminal_sa_flow_m3_per_s
      else
        min_airflow_ratio = min_flow
        min_airflow_m3_per_s = min_airflow_ratio * old_terminal_sa_flow_m3_per_s
      end

      # set minimum fan power flow fraction to the higher of 0.40 or the min flow fraction
      if min_airflow_ratio > min_flow
        new_fan.setFanPowerMinimumFlowFraction(min_airflow_ratio)
      else
        new_fan.setFanPowerMinimumFlowFraction(min_flow)
      end
      # set from origial fan power; 0.5in will be added later if adding HR
      new_fan.setPressureRise(fan_static_pressure)

      # -------------------------------------------------------
      # create coils: cooling
      # -------------------------------------------------------
      # define variable speed cooling coil
      if debug_verbose
        runner.registerInfo('--- adding new variable speed cooling coil')
      end
      _, size_category = UpgradeHvacRtuAdv.get_capacity_category(runner, orig_clg_coil_gross_cap)
      new_dx_cooling_coil = OpenStudio::Model::CoilCoolingDXVariableSpeed.new(model)
      new_dx_cooling_coil.setName("#{air_loop_hvac.name} Adv RTU Cooling Coil")
      new_dx_cooling_coil.setCondenserType('AirCooled')
      new_dx_cooling_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(-25)
      new_dx_cooling_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(4.4)
      # methods from "TECHNICAL SUPPORT DOCUMENT: ENERGY EFFICIENCY PROGRAM FOR CONSUMER PRODUCTS
      # AND COMMERCIAL AND INDUSTRIAL EQUIPMENT AIR-COOLED COMMERCIAL UNITARY AIR CONDITIONERS
      # AND COMMERCIAL UNITARY HEAT PUMPS"
      crankcase_heater_power = ((60 * ((orig_clg_coil_gross_cap * 0.0002843451 / 10)**0.67)))
      new_dx_cooling_coil.setCrankcaseHeaterCapacity(crankcase_heater_power)
      new_dx_cooling_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(-25)
      new_dx_cooling_coil.setNominalTimeforCondensatetoBeginLeavingtheCoil(1000)
      new_dx_cooling_coil.setInitialMoistureEvaporationRateDividedbySteadyStateACLatentCapacity(1.5)
      new_dx_cooling_coil.setLatentCapacityTimeConstant(45)
      new_dx_cooling_coil.setEnergyPartLoadFractionCurve(
        curve_table_map['high_stage'][size_category]['eir_fn_of_plr']
      )
      new_dx_cooling_coil.setNominalSpeedLevel(3)

      # define rated to lower stage ratios: low, medium, high stages
      stage_ratios = [0.333, 0.666, 1.0] # lower stage to higher stage

      # estimate rated COP
      rated_cop_pre_rated_airflow_adjust = UpgradeHvacRtuAdv.get_rated_cop_cooling_adv(
        runner,
        orig_clg_coil_gross_cap
      )
      rated_cop_post_rated_airflow_adjust = adjust_rated_cop_from_ref_cfm_per_ton(
        runner,
        orig_clg_coil_rated_airflow_m_3_per_s,
        orig_clg_coil_gross_cap,
        rated_cop_pre_rated_airflow_adjust,
        curve_table_map['high_stage'][size_category]['eir_fn_of_ff']
      )

      # loop through stages
      stage_ratios.sort.each_with_index do |ratio, index|
        # convert index to stage number
        stage = index + 1

        # stage label
        stage_label = UpgradeHvacRtuAdv.get_stage_category(runner, stage)

        # calculate reference capacity
        if stage == 3
          reference_capacity_w = orig_clg_coil_gross_cap
          reference_airflow_m_3_per_s = orig_clg_coil_rated_airflow_m_3_per_s
        else
          reference_capacity_w = orig_clg_coil_gross_cap * ratio
          reference_airflow_m_3_per_s = orig_clg_coil_rated_airflow_m_3_per_s * ratio
        end
        if debug_verbose
          runner.registerInfo("--- stage #{stage} | reference_capacity_w = #{
            reference_capacity_w
          }")
          runner.registerInfo("--- stage #{stage} | reference_airflow_m_3_per_s = #{
            reference_airflow_m_3_per_s
          }")
        end

        # add speed data for each stage
        dx_coil_speed_data = OpenStudio::Model::CoilCoolingDXVariableSpeedSpeedData.new(model)
        dx_coil_speed_data.setReferenceUnitGrossRatedTotalCoolingCapacity(reference_capacity_w)
        dx_coil_speed_data.setReferenceUnitRatedAirFlowRate(reference_airflow_m_3_per_s)
        dx_coil_speed_data.setReferenceUnitGrossRatedSensibleHeatRatio(UpgradeHvacRtuAdv.get_shr(
                                                                         runner, stage
                                                                       ))
        dx_coil_speed_data.setReferenceUnitGrossRatedCoolingCOP(
          rated_cop_post_rated_airflow_adjust * UpgradeHvacRtuAdv.get_reference_cop_ratio(
            runner, stage
          )
        )
        dx_coil_speed_data.setRatedEvaporatorFanPowerPerVolumeFlowRate2017(773.3)
        dx_coil_speed_data.setTotalCoolingCapacityFunctionofTemperatureCurve(
          curve_table_map[stage_label][size_category]['capacity_fn_of_t']
        )
        dx_coil_speed_data.setTotalCoolingCapacityFunctionofAirFlowFractionCurve(
          curve_table_map[stage_label][size_category]['capacity_fn_of_ff']
        )
        dx_coil_speed_data.setEnergyInputRatioFunctionofTemperatureCurve(
          curve_table_map[stage_label][size_category]['eir_fn_of_t']
        )
        dx_coil_speed_data.setEnergyInputRatioFunctionofAirFlowFractionCurve(
          curve_table_map[stage_label][size_category]['eir_fn_of_ff']
        )

        # add speed data to variable speed coil object
        new_dx_cooling_coil.addSpeed(dx_coil_speed_data)

        if stage == 3
          new_dx_cooling_coil.setGrossRatedTotalCoolingCapacityAtSelectedNominalSpeedLevel(reference_capacity_w)
          new_dx_cooling_coil.setRatedAirFlowRateAtSelectedNominalSpeedLevel(reference_airflow_m_3_per_s)
        end
      end

      # -------------------------------------------------------
      # create coils: backup heating
      # -------------------------------------------------------
      if debug_verbose
        runner.registerInfo('--- adding new backup heating coil')
      end
      # add new supplemental heating coil
      new_backup_heating_coil = nil
      # define backup heat source
      if prim_ht_fuel_type == 'electric'
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
      new_backup_heating_coil.setNominalCapacity(orig_htg_coil_gross_cap)

      # -------------------------------------------------------
      # add existing main heating coil back to hot water loop
      # -------------------------------------------------------
      if orig_htg_coil_obj_existing.instance_of?(OpenStudio::Model::CoilHeatingWater)
        if debug_verbose
          runner.registerInfo('--- adding existing main water heating coil back'\
                              ' to the hot water loop')
        end
        hot_water_loop.addDemandBranchForComponent(orig_htg_coil_obj_existing)
      end

      # -------------------------------------------------------
      # unitary system update
      # -------------------------------------------------------
      if debug_verbose
        runner.registerInfo('--- adding new unitary system')
        runner.registerInfo('--- and re-applying existing heating coil to the'\
                            " new unitary system: #{orig_htg_coil_obj_existing.name}")
      end
      # add new unitary system object
      new_rtu = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
      new_rtu.setName("#{air_loop_hvac.name} Unitary high-efficiency System")
      new_rtu.setSupplyFan(new_fan)
      new_rtu.setHeatingCoil(orig_htg_coil_obj_existing)
      new_rtu.setCoolingCoil(new_dx_cooling_coil)
      new_rtu.setSupplementalHeatingCoil(new_backup_heating_coil)
      new_rtu.addToNode(air_loop_hvac.supplyOutletNode)

      # set other features
      new_rtu.setControllingZoneorThermostatLocation(control_zone)
      new_rtu.setFanPlacement('DrawThrough')
      new_rtu.setAvailabilitySchedule(unitary_availability_sched)
      new_rtu.setDehumidificationControlType(dehumid_type)
      new_rtu.setSupplyAirFanOperatingModeSchedule(supply_fan_op_sched)
      new_rtu.setControlType('Load')
      new_rtu.setName("#{thermal_zone.name} RTU SZ-VAV high-efficiency")
      new_rtu.setMaximumSupplyAirTemperature(50)
      new_rtu.setDXHeatingCoilSizingRatio(1)

      # handle deprecated methods for OS Version 3.7.0
      if model.version < OpenStudio::VersionString.new('3.7.0')
        # set no load design flow rate
        new_rtu.resetSupplyAirFlowRateMethodWhenNoCoolingorHeatingisRequired
      end
      # set cooling design flow rate
      new_rtu.setSupplyAirFlowRateDuringCoolingOperation(supply_airflow_during_cooling)
      # set heating design flow rate
      new_rtu.setSupplyAirFlowRateDuringHeatingOperation(supply_airflow_during_heating)
      # set no load design flow rate
      new_rtu.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(min_airflow_m3_per_s)

      # -------------------------------------------------------
      # DCV update
      # -------------------------------------------------------
      # add dcv to air loop if dcv flag is true
      if dcv == true
        if debug_verbose
          runner.registerInfo('--- adding DCV')
        end
        oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
        controller_oa = oa_system.getControllerOutdoorAir
        controller_mv = controller_oa.controllerMechanicalVentilation
        controller_mv.setDemandControlledVentilation(true)
      end

      # -------------------------------------------------------
      # E/HRV update
      # -------------------------------------------------------
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

      # check for space type applicability: no energy recovery on kitchens and dining
      if OpenstudioStandards::SpaceType.thermal_zone_serves_space_types?(thermal_zone, ['food preparation', 'dining'])
        runner.registerWarning('The user selected to add energy recovery to the HP-RTUs,'\
        " but thermal zone #{
          thermal_zone.name
        } is a non-applicable space type for energy recovery. Any existing energy recovery will"\
          ' remain for consistancy, but no new energy recovery will be added.')
      else
        if debug_verbose
          runner.registerInfo('--- adding H/ERV')
        end
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
          # rotary is used for fan power modulation when bypass is active.
          # Only affects supply temp control with bypass.
          hx.setHeatExchangerType('Rotary')
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

          # fan efficiency ranges from 40-60%
          # (Energy Modeling Guide for Very High Efficiency DOAS Final Report)
          default_fan_efficiency = 0.55
          power =
            (oa_flow_m3_per_s * 174.188 / default_fan_efficiency) +
            ((oa_flow_m3_per_s * 0.9 * 124.42) / default_fan_efficiency)
          hx.setNominalElectricPower(power)
        end
      end
    end

    # report final condition of model
    condition_final = 'The building finished with high-efficiency RTUs replacing'\
                      " the HVAC equipment for #{selected_air_loops.size} air loops."
    runner.registerFinalCondition(condition_final)

    true
  end
  # rubocop:enable Naming/PredicateMethod
end

# register the measure to be used by the application
UpgradeHvacRtuAdv.new.registerWithApplication
