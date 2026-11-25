# frozen_string_literal: true

# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/
require 'comstock-typical'
require 'json'

# start the measure
class UpgradeHvacRtuAdv < OpenStudio::Measure::ModelMeasure
  # ASHRAE 90.1-2016 Appendix G, System Type 11 (Single Zone VAV) fan part-load curve -
  # the reference case for packaged single-zone equipment, and the same coefficients
  # OpenstudioStandards::HVAC.fan_variable_volume_set_control_type installs for control
  # type 'Single Zone VAV'.
  #
  # This replaces a curve previously carried inline here as
  # [0.259905264, -1.569867715, 4.819732387, -3.904544154, 1.394774218], commented only
  # as "from Daikin Rebel E+ file" - one vendor's numbers of unknown provenance, taken from an
  # EnergyPlus file the manufacturer sent, with no record of how they were derived, in a file
  # not in this repository and so not checkable. The two curves differ materially: at 40%
  # flow the Daikin curve returns 0.189 against 0.091 here, a factor of 2.1. Standardising
  # on the citable source keeps this measure and upgrade_hvac_add_heat_pump_rtu, which
  # both install variable-speed RTU fans, on one representation.
  #
  # Note the direction: this LOWERS part-load fan power and so increases the fan savings
  # this measure reports.
  SINGLE_ZONE_VAV_FAN_POWER_COEFFICIENTS = [0.027827882, 0.026583195, -0.0870687,
                                            1.03091975, 0.0].freeze

  # rated airflow per capacity limits EnergyPlus applies to DX cooling coils, as in upgrade_hvac_add_heat_pump_rtu
  CFM_PER_TON_MIN_RATED = 300
  CFM_PER_TON_MAX_RATED = 450

  # capacity and airflow of the low, medium and high cooling stage as fractions of the high stage, before the unit's
  # minimum airflow and the cfm/ton limits are applied (see cooling_stage_flows_and_capacities)
  COOLING_STAGE_FRACTIONS = { 1 => 0.333, 2 => 0.666, 3 => 1.0 }.freeze
  RATED_COOLING_STAGE = 3

  # name of the part-load fraction curve the cooling coils share (see cooling_part_load_fraction_curve)
  COOLING_PLF_CURVE_NAME = 'rtu_adv_cool_plf_fplr'

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

  # Return a cooling stage's gross rated sensible heat ratio (SHR) from its rated airflow per rated capacity.
  # This is EnergyPlus' relation for an autosized DX cooling coil, a regression of actual coils that gives 0.676 at
  # 300 cfm/ton and 0.798 at 450 cfm/ton. It sized the SHR of the coil this unit replaces, so a stage with the same
  # airflow per ton removes moisture as that coil did. At the airflows of the manufacturer data behind this measure it
  # also returns that data's SHRs: 0.72 at 350 cfm/ton (data: 0.73 at the high stage) and 0.80 at 450 cfm/ton (data:
  # 0.81 at the low stage, which moves more air per ton).
  # Fixed values of 0.626, 0.637 and 0.700 (high to low stage) were used before, lowered from the data so that the
  # coil outlet stayed below saturation at a low airflow per ton.
  def self.stage_rated_shr(airflow_m_3_per_s, capacity_w)
    m_3_per_s_per_w_per_cfm_per_ton = OpenStudio.convert(OpenStudio.convert(1.0, 'cfm', 'm^3/s').get, 'W', 'ton').get
    cfm_per_ton = airflow_m_3_per_s / capacity_w / m_3_per_s_per_w_per_cfm_per_ton
    cfm_per_ton = cfm_per_ton.clamp(CFM_PER_TON_MIN_RATED, CFM_PER_TON_MAX_RATED)
    0.431 + (6086.0 * cfm_per_ton * m_3_per_s_per_w_per_cfm_per_ton)
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

  # Converts m^3/s per W to CFM/ton.
  def m_3_per_sec_watts_to_cfm_per_ton(m_3_per_sec_watts)
    m_3_per_sec_watts / cfm_per_ton_to_m_3_per_sec_watts(1.0)
  end

  # Return the part-load fraction curve of the cooling coils, creating it once per model: the cycling losses of a
  # compressor that cycles below its lowest stage. It is the curve upgrade_hvac_add_heat_pump_rtu uses (cool_plf_plr1
  # in its performance files), 0.75 + 0.25 x part-load ratio and not below 0.7, so both RTU upgrades are charged alike.
  # A fit of normalized power against part-load ratio was used before (Figure 11 of the measure documentation, from
  # catalog data between 33% and 100% of a unit's load: 0.098 + 0.911 x part-load ratio for the smaller units; the
  # eir_*_plr files in resources). EnergyPlus reads this curve as the part-load fraction, the efficiency while cycling
  # over the steady-state efficiency, applies it below the lowest stage, and holds it at 0.7 or above. The fit is below
  # 0.7 for part-load ratios under two thirds, so there the compressor drew 43% more electricity than in proportion to
  # its load; the heat pump RTU curve gives 14% more at half load and the coils of the units this one replaces 4% to
  # 9% more. Between 33% and 100% of the unit's load the stages and their COP ratios carry the part-load efficiency.
  def cooling_part_load_fraction_curve(model)
    existing_curve = model.getCurveQuadratics.find { |curve| curve.name.to_s == COOLING_PLF_CURVE_NAME }
    return existing_curve if existing_curve

    curve = OpenStudio::Model::CurveQuadratic.new(model)
    curve.setName(COOLING_PLF_CURVE_NAME)
    curve.setCoefficient1Constant(0.75)
    curve.setCoefficient2x(0.25)
    curve.setCoefficient3xPOW2(0.0)
    curve.setMinimumValueofx(0.0)
    curve.setMaximumValueofx(1.0)
    curve.setMinimumCurveOutput(0.7)
    curve.setMaximumCurveOutput(1.0)
    curve
  end

  # Return the airflow (m3/s) and capacity (W) of each cooling stage, as two hashes keyed by stage number, following
  # upgrade_hvac_add_heat_pump_rtu.
  # Each stage starts at its COOLING_STAGE_FRACTIONS share of the high stage's capacity and airflow. A lower stage's
  # airflow is then raised to the unit's minimum airflow where it is below it, so the unit never moves less than its
  # minimum airflow, and with it the minimum outdoor air, while it cools. Before, the low stage ran at a third of the
  # design airflow whatever the minimum was.
  # That raises the stage's airflow per capacity, which is kept within the rated cfm/ton limits where possible. The
  # high stage keeps the capacity and airflow of the coil it replaces. A lower stage, in order of preference:
  #   - below the minimum cfm/ton: its airflow is raised to the minimum cfm/ton
  #   - above the maximum cfm/ton: its airflow is lowered to the maximum cfm/ton if the unit's minimum airflow allows;
  #     otherwise its capacity is raised, by up to 65% of the step to the next stage; otherwise the stage is removed.
  #     The medium stage is never removed, because a multispeed coil needs two stages: it takes the full capacity
  #     allowance and can stay above the maximum cfm/ton.
  # The unit's minimum airflow is at least its minimum outdoor air flow, so no stage airflow is below that either.
  # @return [Array<Hash>] stage airflows and stage capacities; a removed stage is in neither
  def cooling_stage_flows_and_capacities(rated_capacity_w, rated_airflow_m3_per_s, min_airflow_m3_per_s)
    flow_per_w_min = cfm_per_ton_to_m_3_per_sec_watts(CFM_PER_TON_MIN_RATED)
    flow_per_w_max = cfm_per_ton_to_m_3_per_sec_watts(CFM_PER_TON_MAX_RATED)
    stage_flows = {}
    stage_caps = {}
    COOLING_STAGE_FRACTIONS.sort.each do |stage, fraction|
      capacity = fraction * rated_capacity_w
      if stage == RATED_COOLING_STAGE
        stage_flows[stage] = rated_airflow_m3_per_s
        stage_caps[stage] = capacity
        next
      end

      # a lower stage never moves more air than the high stage, also where the minimum airflow is above that
      airflow = [fraction * rated_airflow_m3_per_s, min_airflow_m3_per_s].max
      airflow = rated_airflow_m3_per_s if airflow > rated_airflow_m3_per_s
      flow_per_w = airflow / capacity
      if flow_per_w.round(8) < flow_per_w_min.round(8)
        airflow = [flow_per_w_min * capacity, rated_airflow_m3_per_s].min
      elsif flow_per_w.round(8) > flow_per_w_max.round(8)
        airflow_at_limit = flow_per_w_max * capacity
        fraction_required = airflow / flow_per_w_max / rated_capacity_w
        fraction_allowed = fraction + ((COOLING_STAGE_FRACTIONS[stage + 1] - fraction) * 0.65)
        if airflow_at_limit >= min_airflow_m3_per_s
          airflow = airflow_at_limit
        elsif fraction_required <= fraction_allowed
          capacity = fraction_required * rated_capacity_w
        elsif stage == RATED_COOLING_STAGE - 1
          capacity = fraction_allowed * rated_capacity_w
        else
          next
        end
      end
      stage_flows[stage] = airflow
      stage_caps[stage] = capacity
    end
    [stage_flows, stage_caps]
  end

  #### End predefined functions

  # define what happens when the measure is run
  # rubocop:disable Naming/PredicateMethod
  # Real energy recovery units stop the wheel and open bypass dampers when recovery would not help (90.1 section 6.5.6.1),
  # which removes the wheel's added fan pressure; EnergyPlus charges Nominal Electric Power whenever the HX is available.
  # An EMS program keeps the HX available only when it would warm or cool the outdoor air toward its outlet setpoint.
  # @param model [OpenStudio::Model::Model]
  # @param hx [OpenStudio::Model::HeatExchangerAirToAirSensibleAndLatent] HX in the air loop's outdoor air system
  # @param oa_sys [OpenStudio::Model::AirLoopHVACOutdoorAirSystem] the outdoor air system holding the HX
  # @param deadband_c [Double] temperature margin before the wheel runs, deg C
  # @return [Boolean] true if the bypass control was added
  def add_erv_bypass_control(model, hx, oa_sys, deadband_c = 0.5)
    oa_node = oa_sys.outboardOANode
    ra_node = oa_sys.returnAirModelObject
    hx_out = hx.primaryAirOutletModelObject
    return false unless oa_node.is_initialized && ra_node.is_initialized && hx_out.is_initialized

    avail = OpenStudio::Model::ScheduleConstant.new(model)
    avail.setName("#{hx.name} Bypass Control")
    avail.setValue(1.0)
    hx.setAvailabilitySchedule(avail)

    tag = "erv_bypass_#{model.getEnergyManagementSystemPrograms.size + 1}"
    sensors = { 'toa' => ['System Node Temperature', oa_node.get.name.to_s],
                'tra' => ['System Node Temperature', ra_node.get.name.to_s],
                'tsp' => ['System Node Setpoint Temperature', hx_out.get.name.to_s] }
    sensors.each do |var, (output, key)|
      sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, output)
      sensor.setName("#{tag}_#{var}")
      sensor.setKeyName(key)
    end
    actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(avail, 'Schedule:Constant', 'Schedule Value')
    actuator.setName("#{tag}_avail")

    # heating: outdoor air below both the return air and the HX outlet setpoint; cooling: above both
    program = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
    program.setName("#{tag}_program")
    program.setBody(<<~ERL)
      IF (#{tag}_toa < (#{tag}_tra - #{deadband_c})) && (#{tag}_toa < (#{tag}_tsp - #{deadband_c}))
        SET #{tag}_avail = 1
      ELSEIF (#{tag}_toa > (#{tag}_tra + #{deadband_c})) && (#{tag}_toa > (#{tag}_tsp + #{deadband_c}))
        SET #{tag}_avail = 1
      ELSE
        SET #{tag}_avail = 0
      ENDIF
    ERL
    manager = model.getEnergyManagementSystemProgramCallingManagers.find { |m| m.name.to_s == 'ERV Bypass Control' }
    if manager.nil?
      manager = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
      manager.setName('ERV Bypass Control')
      manager.setCallingPoint('AfterPredictorAfterHVACManagers')
    end
    manager.addProgram(program)
    true
  end

  # Give a unitary system with a multispeed DX cooling coil its own UnitarySystemPerformance:Multispeed so its
  # continuous-fan no-load airflow is no_load_flow_m3_per_s. EnergyPlus ignores the unitary system's no-load supply air
  # flow rate when that object is present: it resets the no-load flow to the cooling supply air flow times the object's
  # No Load Supply Air Flow Rate Ratio. OpenStudio generates the object at translation when none is assigned, with the
  # ratio blank (EnergyPlus default 1), so the units ran at full design airflow whenever the fan ran with no load.
  # The stage ratios here are the ones the OpenStudio translator generates: each cooling stage's rated airflow over the
  # unit's cooling supply air flow, and 1.0 for the single-speed heating coil.
  # upgrade_hvac_add_heat_pump_rtu has the same method for its multispeed coils.
  # @return [OpenStudio::Model::UnitarySystemPerformanceMultispeed, nil] the object assigned, or nil if none
  def assign_multispeed_performance(model, runner, unitary, cooling_coil, no_load_flow_m3_per_s)
    stages = cooling_coil.stages
    clg_flow = unitary.supplyAirFlowRateDuringCoolingOperation
    if stages.empty? || clg_flow.empty? || stages.any? { |stage| stage.ratedAirFlowRate.empty? }
      runner.registerWarning("#{unitary.name}: cooling stage airflows or the cooling supply airflow are missing, so the no-load airflow ratio was not set and the unit runs at full airflow with no load.")
      return nil
    end
    clg_flow = clg_flow.get

    ratio_fields = stages.map do |stage|
      OpenStudio::Model::SupplyAirflowRatioField.new(1.0, stage.ratedAirFlowRate.get / clg_flow)
    end
    no_load_ratio = (no_load_flow_m3_per_s / clg_flow).clamp(0.0, 1.0)

    performance = OpenStudio::Model::UnitarySystemPerformanceMultispeed.new(model)
    performance.setName("#{unitary.name} Unitary System Performance")
    performance.setSingleModeOperation(false)
    performance.setNoLoadSupplyAirflowRateRatio(no_load_ratio)
    performance.setSupplyAirflowRatioFields(ratio_fields)
    unitary.setDesignSpecificationMultispeedObject(performance)
    performance
  end

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
      # Original combustion fuel, carried through to the backup coil below. This is an
      # efficiency upgrade, not a fuel switch.
      orig_htg_coil_fuel_type = nil
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
            # CoilHeatingGas covers natural gas, propane and fuel oil - the fuel is a
            # field, not a separate class. Read as-is so it is by construction a valid
            # fuel string for this model's OpenStudio version.
            orig_htg_coil_fuel_type = orig_htg_coil.fuelType
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
      new_fan.setFanPowerMinimumFlowRateInputMethod('Fraction')

      # Total fan efficiency is impeller x motor, and it has to be set explicitly.
      #
      # The previous two lines here were setMotorEfficiency(fan_mot_eff) followed by
      # std.fan_change_motor_efficiency(new_fan, fan_mot_eff), which is a no-op: that
      # helper derives the impeller from the fan's CURRENT total efficiency, and at this
      # point that is still the OpenStudio FanVariableVolume default of 0.6045 because
      # setFanTotalEfficiency has never been called. It therefore computes
      # 0.6045 / motor x motor and writes 0.6045 straight back. Measured on the strip
      # mall test model, all 48 supply fans came out at exactly 0.6045 regardless of
      # size, with an implied impeller efficiency of 0.733 that is an artefact of that
      # arithmetic rather than a property of any fan.
      #
      # Impeller comes from openstudio-standards and the motor from the 90.1 table by
      # brake horsepower, so the motor tracks fan size. Brake horsepower is air power
      # divided by impeller efficiency, which is what that lookup expects. This matches
      # upgrade_hvac_add_heat_pump_rtu so the two RTU measures represent fans the same way.
      fan_impeller_efficiency = std.fan_baseline_impeller_efficiency(new_fan)
      fan_brake_hp = (fan_static_pressure * old_terminal_sa_flow_m3_per_s) /
                     (fan_impeller_efficiency * 745.7)
      # Size the motor the way openstudio-standards sizes BASELINE fan motors, or the
      # upgraded fan can come out less efficient than the fan it replaces. The 90.1
      # motor table is indexed by nominal nameplate size, and brake horsepower is about
      # 90% of it (Thornton et al. 2011), so prototype_fan_apply_prototype_fan_efficiency
      # looks up at brake_hp * 1.1. Looking up at brake horsepower instead lands one
      # motor size low near a bin boundary: at 2 bhp that is motor 0.865 against the
      # baseline's 0.895, and at 5 bhp 0.895 against 0.917. The rounding nudge is copied
      # from that method so ties break the same way.
      fan_nominal_motor_hp = fan_brake_hp * 1.1
      if fan_nominal_motor_hp > 0.1
        fan_nominal_motor_hp = fan_nominal_motor_hp.round(2) + 0.0001
      elsif fan_nominal_motor_hp < 0.01
        fan_nominal_motor_hp = 0.01
      end
      fan_motor_efficiency, fan_nominal_hp =
        std.fan_standard_minimum_motor_efficiency_and_size(new_fan, fan_nominal_motor_hp)
      new_fan.setMotorEfficiency(fan_motor_efficiency)
      new_fan.setFanTotalEfficiency(fan_impeller_efficiency * fan_motor_efficiency)
      if debug_verbose
        runner.registerInfo("fan summary: #{air_loop_hvac.name} | impeller=#{fan_impeller_efficiency.round(3)} | "                             "bhp=#{fan_brake_hp.round(2)} | nominal_hp=#{fan_nominal_hp} | "                             "motor_eff=#{fan_motor_efficiency.round(3)} | "                             "total_eff=#{(fan_impeller_efficiency * fan_motor_efficiency).round(4)}")
      end

      # 90.1-2016 Appendix G Single Zone VAV; see the constant for provenance.
      c1, c2, c3, c4, c5 = SINGLE_ZONE_VAV_FAN_POWER_COEFFICIENTS
      new_fan.setFanPowerCoefficient1(c1)
      new_fan.setFanPowerCoefficient2(c2)
      new_fan.setFanPowerCoefficient3(c3)
      new_fan.setFanPowerCoefficient4(c4)
      new_fan.setFanPowerCoefficient5(c5)

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

      # the new terminal's maximum flow is the loop design flow, as the terminal it replaces had, and its minimum flow is
      # the unit's minimum airflow, so the terminal minimum equals the unit's no-load airflow.
      # Left to autosize, EnergyPlus sizes the maximum from the zone design loads, which can come out below the unit's
      # airflow. Left at its default of 0, the minimum lets the terminal ask for no air when its zone has no load. In
      # models with no zone exhaust fan EnergyPlus then passes zero flow to the outdoor air controller, which closes the
      # outdoor air while the unit's fan keeps running at its no-load airflow.
      new_terminal.setMaximumAirFlowRate(old_terminal_sa_flow_m3_per_s)
      new_terminal.setZoneMinimumAirFlowFraction([min_airflow_ratio, 1.0].min)

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
      # define the cooling coil: up to three stages (low, medium, high) of a variable-capacity compressor, as a
      # multispeed DX coil object. The variable-speed coil object with three speeds was used before; EnergyPlus stages
      # both the same way in a unitary system (it blends neighboring stages and cycles at the lowest), but the unit's
      # no-load airflow can only be set through its UnitarySystemPerformance:Multispeed object, and OpenStudio 3.10
      # writes that object with one cooling speed for a variable-speed coil once the model assigns it, which stops
      # EnergyPlus.
      # One thing EnergyPlus 25.1 does differently with the same inputs: the multispeed coil runs its crankcase heater
      # whenever the compressor is off below the temperature limit (the variable-speed coil only counted it in
      # timesteps with the compressor on).
      if debug_verbose
        runner.registerInfo('--- adding new cooling coil')
      end
      _, size_category = UpgradeHvacRtuAdv.get_capacity_category(runner, orig_clg_coil_gross_cap)
      new_dx_cooling_coil = OpenStudio::Model::CoilCoolingDXMultiSpeed.new(model)
      new_dx_cooling_coil.setName("#{air_loop_hvac.name} Adv RTU Cooling Coil")
      new_dx_cooling_coil.setCondenserType('AirCooled')
      new_dx_cooling_coil.setAvailabilitySchedule(always_on)
      new_dx_cooling_coil.setFuelType('Electricity')
      new_dx_cooling_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(-25)
      new_dx_cooling_coil.setMaximumOutdoorDryBulbTemperatureforCrankcaseHeaterOperation(4.4)
      # the stages represent a variable-speed compressor: above the lowest stage it modulates between two stages and
      # does not cycle, so cycling losses (the part-load fraction curve) apply only below the lowest stage
      new_dx_cooling_coil.setApplyPartLoadFractiontoSpeedsGreaterthan1(false)
      new_dx_cooling_coil.setApplyLatentDegradationtoSpeedsGreaterthan1(false)
      # methods from "TECHNICAL SUPPORT DOCUMENT: ENERGY EFFICIENCY PROGRAM FOR CONSUMER PRODUCTS
      # AND COMMERCIAL AND INDUSTRIAL EQUIPMENT AIR-COOLED COMMERCIAL UNITARY AIR CONDITIONERS
      # AND COMMERCIAL UNITARY HEAT PUMPS"
      crankcase_heater_power = ((60 * ((orig_clg_coil_gross_cap * 0.0002843451 / 10)**0.67)))
      new_dx_cooling_coil.setCrankcaseHeaterCapacity(crankcase_heater_power)

      # part-load fraction curve of the coil: the cycling losses below the lowest stage (see the method)
      plf_curve = cooling_part_load_fraction_curve(model)

      # airflow and capacity of each stage: no stage moves less air than the unit's minimum airflow, and the lower
      # stages are kept within the rated cfm/ton limits where that allows (see the method)
      stage_flows_cooling, stage_caps_cooling = cooling_stage_flows_and_capacities(
        orig_clg_coil_gross_cap, orig_clg_coil_rated_airflow_m_3_per_s, min_airflow_m3_per_s
      )
      removed_stages = COOLING_STAGE_FRACTIONS.keys - stage_caps_cooling.keys
      unless removed_stages.empty?
        runner.registerWarning("#{air_loop_hvac.name}: cooling stage #{removed_stages.join(', ')} removed, above #{CFM_PER_TON_MAX_RATED} cfm/ton at the unit's minimum airflow (#{min_airflow_ratio.round(3)} of the design airflow).")
      end
      stages_out_of_range = stage_caps_cooling.sort.filter_map do |stage, capacity_w|
        cfm_per_ton = m_3_per_sec_watts_to_cfm_per_ton(stage_flows_cooling[stage] / capacity_w).round(0)
        "stage #{stage} at #{cfm_per_ton.to_i} cfm/ton" if cfm_per_ton < CFM_PER_TON_MIN_RATED || cfm_per_ton > CFM_PER_TON_MAX_RATED
      end
      unless stages_out_of_range.empty?
        runner.registerWarning("#{air_loop_hvac.name}: cooling #{stages_out_of_range.join(', ')} left outside the #{CFM_PER_TON_MIN_RATED} to #{CFM_PER_TON_MAX_RATED} cfm/ton limits (minimum airflow #{min_airflow_ratio.round(3)} of the design airflow).")
      end

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

      # loop through the stages that are kept; a stage keeps its own curves and COP ratio whatever its position
      stage_caps_cooling.sort.each do |stage, reference_capacity_w|
        # stage label
        stage_label = UpgradeHvacRtuAdv.get_stage_category(runner, stage)

        reference_airflow_m_3_per_s = stage_flows_cooling[stage]
        if debug_verbose
          runner.registerInfo("--- stage #{stage} | reference_capacity_w = #{
            reference_capacity_w
          }")
          runner.registerInfo("--- stage #{stage} | reference_airflow_m_3_per_s = #{
            reference_airflow_m_3_per_s
          }")
        end

        # add stage data for each stage
        dx_coil_stage_data = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
        dx_coil_stage_data.setGrossRatedTotalCoolingCapacity(reference_capacity_w)
        dx_coil_stage_data.setRatedAirFlowRate(reference_airflow_m_3_per_s)
        dx_coil_stage_data.setGrossRatedSensibleHeatRatio(
          UpgradeHvacRtuAdv.stage_rated_shr(reference_airflow_m_3_per_s, reference_capacity_w)
        )
        dx_coil_stage_data.setGrossRatedCoolingCOP(
          rated_cop_post_rated_airflow_adjust * UpgradeHvacRtuAdv.get_reference_cop_ratio(
            runner, stage
          )
        )
        dx_coil_stage_data.setRatedEvaporatorFanPowerPerVolumeFlowRate2017(773.3)
        dx_coil_stage_data.setTotalCoolingCapacityFunctionofTemperatureCurve(
          curve_table_map[stage_label][size_category]['capacity_fn_of_t']
        )
        dx_coil_stage_data.setTotalCoolingCapacityFunctionofFlowFractionCurve(
          curve_table_map[stage_label][size_category]['capacity_fn_of_ff']
        )
        dx_coil_stage_data.setEnergyInputRatioFunctionofTemperatureCurve(
          curve_table_map[stage_label][size_category]['eir_fn_of_t']
        )
        dx_coil_stage_data.setEnergyInputRatioFunctionofFlowFractionCurve(
          curve_table_map[stage_label][size_category]['eir_fn_of_ff']
        )
        # one part-load fraction curve for the coil, as the variable-speed coil object had; it acts at the lowest stage
        dx_coil_stage_data.setPartLoadFractionCorrelationCurve(plf_curve)
        # no latent degradation inputs (moisture that evaporates from the coil while the compressor is off and the fan
        # runs): the stage data's defaults of 0 leave that model off, as it is for the coils of the units this one
        # replaces and for the coils of upgrade_hvac_add_heat_pump_rtu. Modeled for this unit alone, it lowered the
        # compressor's electricity by up to 5% in test buildings against units that are not charged the same effect,
        # and left the zones more humid than the baseline's.
        # To model it, set all four: nominal time for condensate removal to begin (1000 s), ratio of initial moisture
        # evaporation rate and steady state latent capacity (1.5), maximum cycling rate (2.5 per hour; the stage
        # data's default of 0 turns the model off whatever the other three are) and latent capacity time constant (45 s).
        dx_coil_stage_data.setEvaporativeCondenserEffectiveness(0.9)
        dx_coil_stage_data.autosizeEvaporativeCondenserAirFlowRate
        dx_coil_stage_data.autosizeRatedEvaporativeCondenserPumpPowerConsumption

        # add stage data to the multispeed coil object
        new_dx_cooling_coil.addStage(dx_coil_stage_data)
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
        # Match the building's original combustion fuel rather than defaulting to natural
        # gas. prim_ht_fuel_type only distinguishes 'electric' from 'gas', and a new
        # CoilHeatingGas defaults to NaturalGas, so a fuel oil or propane building was
        # silently switched to gas. Measured on the strip mall test model relabelled to
        # FuelOilNo2, the result contained NaturalGas backup coils.
        if orig_htg_coil_fuel_type.nil? || orig_htg_coil_fuel_type.to_s.empty?
          runner.registerWarning("Could not determine the original combustion fuel for #{air_loop_hvac.name}; backup coil defaults to #{new_backup_heating_coil.fuelType}.")
        else
          new_backup_heating_coil.setFuelType(orig_htg_coil_fuel_type)
        end
        backup_fuel_label = new_backup_heating_coil.fuelType.to_s
        new_backup_heating_coil.setName("#{air_loop_hvac.name} #{backup_fuel_label} backup coil")
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
      # a unit with a multispeed coil takes its no-load airflow from its UnitarySystemPerformance:Multispeed object
      # (see the method)
      assign_multispeed_performance(model, runner, new_rtu, new_dx_cooling_coil, min_airflow_m3_per_s)

      # -------------------------------------------------------
      # DCV update
      # -------------------------------------------------------
      # add dcv to air loop if dcv flag is true
      if dcv == true
        runner.registerInfo('--- adding DCV') if debug_verbose
        # the DCV measure's eligibility and per-loop changes, so this option matches upgrade_hvac_dcv
        require_relative '../upgrade_hvac_dcv/measure'
        reason = HVACDCV.building_ineligibility(model) || HVACDCV.air_loop_ineligibility(air_loop_hvac)
        if reason.nil?
          HVACDCV.enable_dcv(model, air_loop_hvac, std, runner)
        else
          runner.registerInfo("DCV not added to '#{air_loop_hvac.name}': #{HVACDCV::INELIGIBILITY_TEXT[reason]}.")
        end
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
        # design OA via the standards helper: it honours the Maximum method (Title 24 zones) and divides air changes
        # per hour by 3600; the old hand sum always added per-area and per-person and divided air changes by 60
        oa_flow_m3_per_s = air_loop_hvac.thermalZones.sum { |z| OpenstudioStandards::ThermalZone.thermal_zone_get_outdoor_airflow_rate(z) * z.multiplier }

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
          # size the wheel to the outdoor air it handles; autosizing used the supply air flow, about 4x larger
          hx.setNominalSupplyAirFlowRate(oa_flow_m3_per_s) if oa_flow_m3_per_s > 0
          add_erv_bypass_control(model, hx, oa_sys)
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
