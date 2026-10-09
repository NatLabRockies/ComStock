# frozen_string_literal: true

# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2018, Alliance for Sustainable Energy, LLC.
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# (1) Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# (2) Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# (3) Neither the name of the copyright holder nor the names of any contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission from the respective party.
#
# (4) Other than as required in clauses (1) and (2), distributions in any form
# of modifications or other derivative works may not use the "OpenStudio"
# trademark, "OS", "os", or any other confusingly similar designation without
# specific prior written permission from Alliance for Sustainable Energy, LLC.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER(S) AND ANY CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
# THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER(S), ANY CONTRIBUTORS, THE
# UNITED STATES GOVERNMENT, OR THE UNITED STATES DEPARTMENT OF ENERGY, NOR ANY OF
# THEIR EMPLOYEES, BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
# OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# *******************************************************************************

# dependencies
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'fileutils'
require 'minitest/autorun'
require 'json'
require_relative '../measure'
require_relative '../../../../test/helpers/minitest_helper'

class AddHeatPumpRtuTest < Minitest::Test
  # ---------------------------------------------------------
  # constants
  # ---------------------------------------------------------

  # design days kept from the ddy file
  DESIGN_DAY_NAME_REGEXES = [
    /Htg 99.6. Condns DB/, # annual heating 99.6%
    /Clg .4. Condns WB=>MDB/, # annual humidity (for cooling towers and evap coolers)
    /Clg .4. Condns DB=>MWB/, # annual cooling
    /August .4. Condns DB=>MCWB/, # monthly cooling DB=>MCWB (to handle solar-gain-driven cooling)
    /September .4. Condns DB=>MCWB/,
    /October .4. Condns DB=>MCWB/
  ].freeze

  # output variables added to every saved model for debugging
  OUTPUT_VARIABLES = [
    'Air System Mixed Air Mass Flow Rate',
    'Fan Air Mass Flow Rate',
    'Unitary System Predicted Sensible Load to Setpoint Heat Transfer Rate',
    'Cooling Coil Total Cooling Rate',
    'Cooling Coil Electricity Rate',
    'Cooling Coil Runtime Fraction',
    'Heating Coil Heating Rate',
    'Heating Coil Electricity Rate',
    'Heating Coil Runtime Fraction',
    'Unitary System DX Coil Cycling Ratio',
    'Unitary System DX Coil Speed Ratio',
    'Unitary System DX Coil Speed Level',
    'Unitary System Total Cooling Rate',
    'Unitary System Total Heating Rate',
    'Unitary System Electricity Rate',
    'HVAC System Solver Iteration Count',
    'Site Outdoor Air Drybulb Temperature',
    'Heating Coil Crankcase Heater Electricity Rate',
    'Heating Coil Defrost Electricity Rate',
    'Zone Windows Total Transmitted Solar Radiation Rate'
  ].freeze

  # rated cfm/ton limits checked on the new coils
  CFM_PER_TON_MIN = 300
  CFM_PER_TON_MAX = 450

  # biquadratic curves checked for sensible temperature bounds, with the mode each belongs to
  BIQUADRATIC_CURVE_MODES = {
    'cool_cap_ft1' => 'cooling', 'cool_cap_ft2' => 'cooling', 'cool_cap_ft3' => 'cooling', 'cool_cap_ft4' => 'cooling',
    'cool_eir_ft1' => 'cooling', 'cool_eir_ft2' => 'cooling', 'cool_eir_ft3' => 'cooling', 'cool_eir_ft4' => 'cooling',
    'defrost_eir' => 'heating',
    'heat_cap_ft1' => 'heating', 'heat_cap_ft2' => 'heating', 'heat_cap_ft3' => 'heating', 'heat_cap_ft4' => 'heating',
    'heat_eir_ft1' => 'heating', 'heat_eir_ft2' => 'heating', 'heat_eir_ft3' => 'heating', 'heat_eir_ft4' => 'heating'
  }.freeze

  # scenario performance json holding each scenario's staging and fan_data records
  SCENARIO_PERFORMANCE_JSON = AddHeatPumpRtu::SCENARIO_PERFORMANCE_JSON

  # 90.1-2019 enclosed 4-pole nominal full-load motor efficiencies; total fan efficiency must be an impeller efficiency times one of these
  ASHRAE_MOTOR_EFFICIENCIES = [0.855, 0.865, 0.895, 0.917, 0.924, 0.93, 0.936, 0.941, 0.95, 0.954, 0.958].freeze

  # thermal zone name fragments identifying kitchens
  KITCHEN_NAME_WORDS = ['Kitchen', 'kitchen', 'KITCHEN'].freeze

  # ---------------------------------------------------------
  # path and model helpers
  # ---------------------------------------------------------

  # test output goes in the 'output' directory so result files are not made part of the measure
  def run_dir(test_name)
    "#{File.dirname(__FILE__)}/output/#{test_name}"
  end

  def model_input_path(osm_name)
    File.join(File.dirname(__FILE__), '../../../tests/models', osm_name)
  end

  def epw_input_path(epw_name)
    File.join(File.dirname(__FILE__), '../../../tests/weather', epw_name)
  end

  def model_output_path(test_name)
    "#{run_dir(test_name)}/#{test_name}.osm"
  end

  def sql_path(test_name)
    "#{run_dir(test_name)}/run/eplusout.sql"
  end

  def report_path(test_name)
    "#{run_dir(test_name)}/reports/eplustbl.html"
  end

  def load_model(osm_path)
    translator = OpenStudio::OSVersion::VersionTranslator.new
    model = translator.loadModel(OpenStudio::Path.new(osm_path))
    assert(!model.empty?)
    model.get
  end

  def announce_test(test_name)
    puts "\n######\nTEST:#{test_name}\n######\n"
  end

  # return an argument map with every argument at its default, overridden by the given name => value hash
  def build_argument_map(arguments, overrides = {})
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    arguments.each do |arg|
      cloned = arg.clone
      cloned.setValue(overrides[arg.name]) if overrides.key?(arg.name)
      argument_map[arg.name] = cloned
    end
    argument_map
  end

  # set the weather file and design days, optionally apply the measure, save the model, and optionally run it
  # @return [OpenStudio::Measure::OSResult, nil] measure result, or nil if the measure was not applied
  def set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, model: nil, apply: true, expected_results: 'Success')
    assert(File.exist?(osm_path))
    assert(File.exist?(epw_path))
    ddy_path = "#{epw_path.gsub('.epw', '')}.ddy"

    # create run directory if it does not exist
    FileUtils.mkdir_p(run_dir(test_name))
    assert(File.exist?(run_dir(test_name)))

    # change into run directory for tests
    start_dir = Dir.pwd
    Dir.chdir run_dir(test_name)

    # remove prior runs if they exist
    FileUtils.rm_f(model_output_path(test_name))
    FileUtils.rm_f(report_path(test_name))

    # copy the osm and epw to the test directory
    new_osm_path = "#{run_dir(test_name)}/#{File.basename(osm_path)}"
    FileUtils.cp(osm_path, new_osm_path)
    new_epw_path = "#{run_dir(test_name)}/#{File.basename(epw_path)}"
    FileUtils.cp(epw_path, new_epw_path)

    # create an instance of a runner
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

    # load the test model
    model = load_model(new_osm_path) if model.nil?

    # set model weather file
    epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(new_epw_path))
    OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
    assert(model.weatherFile.is_initialized)

    # replace the design days with the relevant ones from the ddy file
    if File.exist?(ddy_path)
      model.getObjectsByType('OS:SizingPeriod:DesignDay'.to_IddObjectType).each(&:remove)
      ddy_model = OpenStudio::EnergyPlus.loadAndTranslateIdf(ddy_path).get
      ddy_model.getDesignDays.sort.each do |d|
        next unless DESIGN_DAY_NAME_REGEXES.any? { |regex| d.name.get.to_s.match?(regex) }

        runner.registerInfo("Adding object #{d.name}")
        model.addObject(d.clone)
      end
      assert_equal(false, model.getDesignDays.empty?)
    end

    # apply the measure
    result = nil
    if apply
      puts "\nAPPLYING MEASURE..."
      measure.run(model, runner, argument_map)
      result = runner.result
      assert_equal(expected_results, result.value.valueName)
      show_output(result)
    end

    # add output variables for debugging
    OUTPUT_VARIABLES.each do |out_var_name|
      ov = OpenStudio::Model::OutputVariable.new('ov', model)
      ov.setKeyValue('*')
      ov.setReportingFrequency('hourly')
      ov.setVariableName(out_var_name)
    end
    model.getOutputControlFiles.setOutputCSV(true)

    # save model
    model.save(model_output_path(test_name), true)

    if run_model
      puts "\nRUNNING MODEL..."
      std = Standard.build('90.1-2013')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))
      assert(File.exist?(sql_path(test_name)))
    end

    # change back directory
    Dir.chdir(start_dir)

    result
  end

  # run a sizing run and apply the sizing values so the model reads as hard sized
  def mimic_hardsize_model(model, test_dir)
    standard = Standard.build('ComStock DOE Ref Pre-1980')
    if standard.model_run_sizing_run(model, test_dir.to_s) == false
      puts('Sizing run for Hardsize model failed, cannot hard-size model.')
      return false
    end
    model.applySizingValues

    # TODO: remove once this functionality is added to the OpenStudio C++ for hard sizing UnitarySystems
    if model.version < OpenStudio::VersionString.new('3.7.0')
      model.getAirLoopHVACUnitarySystems.each do |unitary|
        unitary.setSupplyAirFlowRateMethodDuringCoolingOperation('SupplyAirFlowRate')
        unitary.setSupplyAirFlowRateMethodDuringHeatingOperation('SupplyAirFlowRate')
      end
    end
    # TODO: remove once this functionality is added to the OpenStudio C++ for hard sizing Sizing:System
    model.getSizingSystems.each do |sizing_system|
      next if sizing_system.isDesignOutdoorAirFlowRateAutosized

      sizing_system.setSystemOutdoorAirMethod('ZoneSum')
    end

    model
  end

  # the hprtu_scenario argument value recorded in a measure result
  def scenario_from_result(result)
    step_value = result.stepValues.find { |input_arg| input_arg.name == 'hprtu_scenario' }
    step_value&.valueAsString
  end

  # parsed scenario performance json
  def scenario_json(scenario)
    path = File.join(File.dirname(__FILE__), '../resources', SCENARIO_PERFORMANCE_JSON.fetch(scenario))
    JSON.parse(File.read(path))
  end

  # the fan_data record of a scenario's performance json
  def fan_data_for(scenario)
    scenario_json(scenario)['tables']['curves']['table'].find { |e| e['name'] == 'fan_data' }
  end

  # the turndown a scenario's json specifies, before any cfm/ton adjustment
  # the measure clamps the fan power minimum flow fraction at this value, so the tests read it from the same place
  def specified_min_flow_fraction_for(scenario)
    rec = scenario_json(scenario)['tables']['curves']['table'].find { |e| e.key?('stage_flow_fractions_heating') }
    return nil if rec.nil?

    fracs = eval(rec['stage_flow_fractions_heating']).values + eval(rec['stage_flow_fractions_cooling']).values
    fracs.select { |v| v.is_a?(Numeric) && v > 0 }.min
  end

  # OpenStudio returns some fan getters as plain Floats and some as Optionals depending on version; unwrap either
  def unwrap_optional(value)
    return value if value.nil? || value.is_a?(Numeric)
    return value unless value.respond_to?(:is_initialized)

    value.is_initialized ? value.get : nil
  end

  # evaluate a fan power polynomial at a flow fraction
  def fan_power_at(coefficients, flow_fraction)
    coefficients.each_with_index.sum { |c, i| c * (flow_fraction**i) }
  end

  # ---------------------------------------------------------
  # coil capacity helpers
  # ---------------------------------------------------------

  # rated capacity and COP of a DX cooling coil; multispeed coils use the highest capacity stage
  def get_cooling_coil_capacity_and_cop(model, coil)
    capacity_w = 0.0
    coil_design_cop = 0.0

    if coil.to_CoilCoolingDXSingleSpeed.is_initialized
      coil = coil.to_CoilCoolingDXSingleSpeed.get
      if coil.ratedTotalCoolingCapacity.is_initialized
        capacity_w = coil.ratedTotalCoolingCapacity.get
      elsif coil.autosizedRatedTotalCoolingCapacity.is_initialized
        capacity_w = coil.autosizedRatedTotalCoolingCapacity.get
      else
        raise "Cooling coil capacity not available for coil '#{coil.name}'."
      end

      if model.version > OpenStudio::VersionString.new('3.4.0')
        coil_design_cop = coil.ratedCOP
      elsif coil.ratedCOP.is_initialized
        coil_design_cop = coil.ratedCOP.get
      else
        raise "'Rated COP' not available for DX coil '#{coil.name}'."
      end
    elsif coil.to_CoilCoolingDXTwoSpeed.is_initialized
      coil = coil.to_CoilCoolingDXTwoSpeed.get
      if coil.ratedHighSpeedTotalCoolingCapacity.is_initialized
        capacity_w = coil.ratedHighSpeedTotalCoolingCapacity.get
      elsif coil.autosizedRatedHighSpeedTotalCoolingCapacity.is_initialized
        capacity_w = coil.autosizedRatedHighSpeedTotalCoolingCapacity.get
      else
        raise "Cooling coil capacity not available for coil '#{coil.name}'."
      end

      if model.version > OpenStudio::VersionString.new('3.4.0')
        coil_design_cop = coil.ratedHighSpeedCOP
      elsif coil.ratedHighSpeedCOP.is_initialized
        coil_design_cop = coil.ratedHighSpeedCOP.get
      else
        raise "'Rated High Speed COP' not available for DX coil '#{coil.name}'."
      end
    elsif coil.to_CoilCoolingDXMultiSpeed.is_initialized
      coil = coil.to_CoilCoolingDXMultiSpeed.get
      coil.stages.each do |stage|
        if stage.grossRatedTotalCoolingCapacity.is_initialized
          temp_capacity_w = stage.grossRatedTotalCoolingCapacity.get
        elsif stage.autosizedGrossRatedTotalCoolingCapacity.is_initialized
          temp_capacity_w = stage.autosizedGrossRatedTotalCoolingCapacity.get
        else
          raise "Cooling coil capacity not available for coil stage '#{stage.name}'."
        end
        coil_design_cop = stage.grossRatedCoolingCOP if temp_capacity_w >= capacity_w
        capacity_w = temp_capacity_w if temp_capacity_w > capacity_w
      end
    elsif coil.to_CoilCoolingDXVariableSpeed.is_initialized
      coil = coil.to_CoilCoolingDXVariableSpeed.get
      coil.speeds.each do |speed|
        temp_capacity_w = speed.referenceUnitGrossRatedTotalCoolingCapacity
        coil_design_cop = speed.referenceUnitGrossRatedCoolingCOP if temp_capacity_w >= capacity_w
        capacity_w = temp_capacity_w if temp_capacity_w > capacity_w
      end
    else
      raise 'Design capacity is only available for DX cooling coil types CoilCoolingDXSingleSpeed, CoilCoolingDXTwoSpeed, CoilCoolingDXMultiSpeed, CoilCoolingDXVariableSpeed.'
    end

    [capacity_w, coil_design_cop]
  end

  # rated capacity and COP of a DX heating coil; multispeed coils use the highest capacity stage
  def get_heating_coil_capacity_and_cop(_model, coil)
    capacity_w = 0.0
    coil_design_cop = 0.0

    if coil.to_CoilHeatingDXSingleSpeed.is_initialized
      coil = coil.to_CoilHeatingDXSingleSpeed.get
      if coil.ratedTotalHeatingCapacity.is_initialized
        capacity_w = coil.ratedTotalHeatingCapacity.get
      elsif coil.autosizedRatedTotalHeatingCapacity.is_initialized
        capacity_w = coil.autosizedRatedTotalHeatingCapacity.get
      else
        raise "Heating coil capacity not available for coil '#{coil.name}'."
      end
      coil_design_cop = coil.ratedCOP
    elsif coil.to_CoilHeatingDXMultiSpeed.is_initialized
      coil = coil.to_CoilHeatingDXMultiSpeed.get
      coil.stages.each do |stage|
        if stage.grossRatedHeatingCapacity.is_initialized
          temp_capacity_w = stage.grossRatedHeatingCapacity.get
        elsif stage.autosizedGrossRatedHeatingCapacity.is_initialized
          temp_capacity_w = stage.autosizedGrossRatedHeatingCapacity.get
        else
          raise "Heating coil capacity not available for coil stage '#{stage.name}'."
        end
        coil_design_cop = stage.grossRatedHeatingCOP if temp_capacity_w >= capacity_w
        capacity_w = temp_capacity_w if temp_capacity_w > capacity_w
      end
    elsif coil.to_CoilHeatingDXVariableSpeed.is_initialized
      coil = coil.to_CoilHeatingDXVariableSpeed.get
      coil.speeds.each do |speed|
        temp_capacity_w = speed.referenceUnitGrossRatedHeatingCapacity
        coil_design_cop = speed.referenceUnitGrossRatedHeatingCOP if temp_capacity_w >= capacity_w
        capacity_w = temp_capacity_w if temp_capacity_w > capacity_w
      end
    else
      raise 'Design COP and capacity for DX heating coil unavailable because of unrecognized coil type.'
    end

    [capacity_w, coil_design_cop]
  end

  # ---------------------------------------------------------
  # assertion helpers
  # ---------------------------------------------------------

  # assert whether the roof and window upgrade measures registered their values in the result
  def assert_envelope_measures_applied(result, roof_expected:, window_expected:)
    step_value_names = JSON.parse(result.to_s)['step_values'].map { |step_value| step_value['name'] }
    assert_equal(roof_expected, step_value_names.include?('env_roof_insul_roof_area_ft_2'),
                 "roof upgrade measure value env_roof_insul_roof_area_ft_2 presence should be #{roof_expected}")
    assert_equal(window_expected, step_value_names.include?('env_secondary_window_fen_area_ft_2'),
                 "window upgrade measure value env_secondary_window_fen_area_ft_2 presence should be #{window_expected}")
  end

  # assert the interpolated value of a TableLookup in the model matches the reference value
  def verify_lookup_table_value(model, lookup_table_test)
    lookup_table_name = lookup_table_test[:table_name]
    lookup_table = model.getTableLookups.find { |table| table.name.to_s == lookup_table_name }
    refute_nil(lookup_table, "Cannot find table named #{lookup_table_name} from model.")

    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    dep_var_ref = lookup_table_test[:dep]
    dep_var = AddHeatPumpRtu.get_dep_var_from_lookup_table_with_interpolation(runner, lookup_table, lookup_table_test[:ind1], lookup_table_test[:ind2])
    assert_in_epsilon(dep_var_ref, dep_var, 0.001, "Table lookup value test didn't pass: table name = #{lookup_table_name} | ind_var1 = #{lookup_table_test[:ind1]} | ind_var2 = #{lookup_table_test[:ind2]} | expected #{dep_var_ref} but got #{dep_var}")
  end

  # assert the rated cfm/ton of every coil is within the limits; the block returns the rated capacity (W) of a coil
  def assert_cfm_per_ton_within_limits(coils, label)
    refute_equal(coils.size, 0)
    coils.each do |coil|
      rated_capacity_w = yield(coil)
      rated_airflow_m_3_per_sec = coil.ratedAirFlowRate.get if coil.ratedAirFlowRate.is_initialized
      rated_capacity_ton = OpenStudio.convert(rated_capacity_w, 'W', 'ton').get
      rated_airflow_cfm = OpenStudio.convert(rated_airflow_m_3_per_sec, 'm^3/s', 'cfm').get
      cfm_per_ton = rated_airflow_cfm / rated_capacity_ton
      assert(cfm_per_ton.round(0) >= CFM_PER_TON_MIN, "cfm_per_ton (#{cfm_per_ton}) is not larger than the threshold of cfm_per_ton_min (#{CFM_PER_TON_MIN}) | #{label} = #{coil.name}")
      assert(cfm_per_ton.round(0) <= CFM_PER_TON_MAX, "cfm_per_ton (#{cfm_per_ton}) is not smaller than the threshold of cfm_per_ton_max (#{CFM_PER_TON_MAX}) | #{label} = #{coil.name}")
    end
  end

  def assert_cfm_per_ton_singlespeed_heating(model)
    assert_cfm_per_ton_within_limits(model.getCoilHeatingDXSingleSpeeds, 'heating_coil') do |coil|
      coil.ratedTotalHeatingCapacity.get if coil.ratedTotalHeatingCapacity.is_initialized
    end
  end

  def assert_cfm_per_ton_multispeed_heating(model)
    assert_cfm_per_ton_within_limits(model.getCoilHeatingDXMultiSpeedStageDatas, 'heating_coil') do |coil|
      coil.grossRatedHeatingCapacity.get if coil.grossRatedHeatingCapacity.is_initialized
    end
  end

  def assert_cfm_per_ton_multispeed_cooling(model)
    assert_cfm_per_ton_within_limits(model.getCoilCoolingDXMultiSpeedStageDatas, 'cooling_coil') do |coil|
      coil.grossRatedTotalCoolingCapacity.get if coil.grossRatedTotalCoolingCapacity.is_initialized
    end
  end

  # check cfm/ton of the new coils for the coil types the scenario creates
  def verify_cfm_per_ton(model, result)
    performance_category = scenario_from_result(result)
    refute_nil(performance_category)

    if performance_category.include?('high_eff')
      assert_cfm_per_ton_multispeed_cooling(model)
      assert_cfm_per_ton_multispeed_heating(model)
    elsif performance_category.include?('standard')
      assert_cfm_per_ton_multispeed_cooling(model)
      assert_cfm_per_ton_singlespeed_heating(model)
    end
  end

  # outdoor air schedule and minimum flow rate of each air loop, keyed by thermal zone name
  def get_outdoor_air_summary(model)
    dict_oa_sched_min = {}
    dict_min_oa = {}
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      zone_name = air_loop_hvac.thermalZones[0].name.to_s
      controller_oa = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
      dict_oa_sched_min[zone_name] = controller_oa.minimumOutdoorAirSchedule.get
      dict_min_oa[zone_name] = controller_oa.minimumOutdoorAirFlowRate.get
    end
    [dict_oa_sched_min, dict_min_oa]
  end

  # apply the measure to a hard-sized version of the model and check the new heat pump RTUs:
  # - gas heating coils are removed unless gas backup heat is expected
  # - the number of unitary systems and the outdoor air settings are unchanged
  # - each unitary system has a variable speed fan and 4-stage multispeed DX coils with descending flow rates and capacities
  # - the supplemental coil type and, when given, the compressor lockout temperature match the backup heat type
  # @param expect_gas_backup [Boolean] true when the measure is expected to create gas (dual fuel) backup coils
  # @param expected_lockout_temp_f [Double, nil] when given, asserts the compressor lockout temperature on each new DX heating coil
  # @return [OpenStudio::Measure::OSResult] measure result
  def verify_hp_rtu(test_name, measure, argument_map, osm_path, epw_path, expect_gas_backup: false, expected_lockout_temp_f: nil)
    # set weather file without applying the measure, then hardsize the model
    set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, apply: false)
    model = load_model(model_output_path(test_name))
    model = mimic_hardsize_model(model, "#{run_dir(test_name)}/SR_before")

    # initial unitary systems and outdoor air settings, compared against the applied HP-RTU systems
    li_unitary_sys_initial = model.getAirLoopHVACUnitarySystems
    dict_oa_sched_min_initial, dict_min_oa_initial = get_outdoor_air_summary(model)

    # set weather file and apply the measure, then hardsize the model
    result = set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    model = load_model(model_output_path(test_name))
    model = mimic_hardsize_model(model, "#{run_dir(test_name)}/SR_after")

    # assert gas heating coils have been removed, unless gas backup heat was requested
    li_gas_htg_coils_final = model.getCoilHeatingGass
    if expect_gas_backup
      refute_empty(li_gas_htg_coils_final, 'expected gas backup heating coils to be present when backup heat matches an original gas heating fuel')
    else
      assert_equal(li_gas_htg_coils_final.size, 0)
    end

    # assert same number of unitary systems as initial
    li_unitary_sys_final = model.getAirLoopHVACUnitarySystems
    assert_equal(li_unitary_sys_initial.size, li_unitary_sys_final.size)

    # assert outdoor air values match between initial and new system
    dict_oa_sched_min_final, dict_min_oa_final = get_outdoor_air_summary(model)
    model.getThermalZones.sort.each do |thermal_zone|
      assert_equal(dict_oa_sched_min_initial[thermal_zone.name.to_s], dict_oa_sched_min_final[thermal_zone.name.to_s])
      assert_in_epsilon(dict_min_oa_initial[thermal_zone.name.to_s].to_f, dict_min_oa_final[thermal_zone.name.to_s].to_f, 0.001)
    end

    # assert characteristics of new unitary systems
    li_unitary_sys_final.sort.each do |system|
      # variable speed fan
      fan = system.supplyFan.get
      assert(fan.to_FanVariableVolume.is_initialized)

      # heating: 4-stage multispeed DX coil with the top stage at the design flow rate, and descending flow rates and capacities
      htg_coil = system.heatingCoil.get
      assert(htg_coil.to_CoilHeatingDXMultiSpeed.is_initialized)
      htg_coil = htg_coil.to_CoilHeatingDXMultiSpeed.get
      assert_equal(htg_coil.numberOfStages, 4)
      htg_coil_spd1, htg_coil_spd2, htg_coil_spd3, htg_coil_spd4 = htg_coil.stages
      htg_dsn_flowrate = system.supplyAirFlowRateDuringHeatingOperation
      assert_in_delta(htg_dsn_flowrate.to_f, htg_coil_spd4.ratedAirFlowRate.get, 0.000001)
      assert(htg_coil_spd4.ratedAirFlowRate.get > htg_coil_spd3.ratedAirFlowRate.get)
      assert(htg_coil_spd3.ratedAirFlowRate.get > htg_coil_spd2.ratedAirFlowRate.get)
      assert(htg_coil_spd2.ratedAirFlowRate.get > htg_coil_spd1.ratedAirFlowRate.get)
      assert(htg_coil_spd4.grossRatedHeatingCapacity.get > htg_coil_spd3.grossRatedHeatingCapacity.get)
      assert(htg_coil_spd3.grossRatedHeatingCapacity.get > htg_coil_spd2.grossRatedHeatingCapacity.get)
      assert(htg_coil_spd2.grossRatedHeatingCapacity.get > htg_coil_spd1.grossRatedHeatingCapacity.get)

      # compressor lockout temperature matches the value expected for the backup heat type
      unless expected_lockout_temp_f.nil?
        expected_lockout_temp_c = OpenStudio.convert(expected_lockout_temp_f, 'F', 'C').get
        assert_in_delta(expected_lockout_temp_c, htg_coil.minimumOutdoorDryBulbTemperatureforCompressorOperation, 0.01,
                        "compressor lockout temperature for #{system.name} does not match the expected #{expected_lockout_temp_f}F")
      end

      # supplemental heating coil type matches the backup heat type
      sup_htg_coil = system.supplementalHeatingCoil.get
      if expect_gas_backup
        assert(sup_htg_coil.to_CoilHeatingGas.is_initialized, "expected a gas backup heating coil for #{system.name}")
      else
        assert(sup_htg_coil.to_CoilHeatingElectric.is_initialized, "expected an electric resistance backup heating coil for #{system.name}")
      end

      # cooling: 4-stage multispeed DX coil with the top stage at the design flow rate, and descending flow rates and capacities
      clg_coil = system.coolingCoil.get
      assert(clg_coil.to_CoilCoolingDXMultiSpeed.is_initialized)
      clg_coil = clg_coil.to_CoilCoolingDXMultiSpeed.get
      assert_equal(clg_coil.numberOfStages, 4)
      clg_coil_spd1, clg_coil_spd2, clg_coil_spd3, clg_coil_spd4 = clg_coil.stages
      clg_dsn_flowrate = system.supplyAirFlowRateDuringCoolingOperation
      assert_in_delta(clg_dsn_flowrate.to_f, clg_coil_spd4.ratedAirFlowRate.get, 0.000001)
      assert(clg_coil_spd4.ratedAirFlowRate.get > clg_coil_spd3.ratedAirFlowRate.get)
      assert(clg_coil_spd3.ratedAirFlowRate.get > clg_coil_spd2.ratedAirFlowRate.get)
      assert(clg_coil_spd2.ratedAirFlowRate.get > clg_coil_spd1.ratedAirFlowRate.get)
      assert(clg_coil_spd4.grossRatedTotalCoolingCapacity.get > clg_coil_spd3.grossRatedTotalCoolingCapacity.get)
      assert(clg_coil_spd3.grossRatedTotalCoolingCapacity.get > clg_coil_spd2.grossRatedTotalCoolingCapacity.get)
      assert(clg_coil_spd2.grossRatedTotalCoolingCapacity.get > clg_coil_spd1.grossRatedTotalCoolingCapacity.get)
    end
    result
  end

  # load a model, apply the measure with the given argument overrides, verify the heat pump RTUs, and check the envelope measures
  def run_hp_rtu_test(test_name, osm_name, epw_name, overrides, roof_expected:, window_expected:)
    announce_test(osm_name)
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    argument_map = build_argument_map(measure.arguments(model), overrides)

    result = verify_hp_rtu(test_name, measure, argument_map, osm_path, epw_path)
    assert_envelope_measures_applied(result, roof_expected: roof_expected, window_expected: window_expected)
  end

  # apply the measure with the given argument overrides and assert it registers as not applicable
  def assert_measure_not_applicable(test_name, osm_name, epw_name, overrides = {})
    announce_test(osm_name)
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    argument_map = build_argument_map(measure.arguments(model), overrides)

    set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, apply: true, expected_results: 'NA')
  end

  # apply the measure with the given argument overrides and assert the existing ERVs are unchanged
  # @return [OpenStudio::Measure::OSResult] measure result
  def assert_existing_ervs_unchanged(test_name, osm_name, epw_name, overrides)
    announce_test(osm_name)
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    argument_map = build_argument_map(measure.arguments(model), overrides)

    ervs_baseline = model.getHeatExchangerAirToAirSensibleAndLatents
    result = set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    model = load_model(model_output_path(test_name))
    ervs_upgrade = model.getHeatExchangerAirToAirSensibleAndLatents
    assert_equal(ervs_baseline, ervs_upgrade)
    result
  end

  # apply the measure without hard sizing and check the backup coil type and compressor lockout temperature on every new RTU
  # @param expect_gas_backup [Boolean] true when a gas backup coil is expected, false for electric resistance
  # @param expected_lockout_temp_f [Double] expected compressor lockout temperature on each new DX heating coil
  # @param expected_backup_fuel_type [String, nil] when given, the fuel type expected on a gas backup coil
  def verify_backup_heat_and_lockout(test_name, measure, argument_map, osm_path, epw_path, expect_gas_backup:, expected_lockout_temp_f:,
                                     expected_backup_fuel_type: nil, model: nil)
    set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, apply: true, model: model)
    applied = load_model(model_output_path(test_name))
    unitary_systems = applied.getAirLoopHVACUnitarySystems
    refute_empty(unitary_systems, "no unitary systems after applying the measure in #{test_name}")

    expected_lockout_temp_c = OpenStudio.convert(expected_lockout_temp_f, 'F', 'C').get
    unitary_systems.each do |system|
      sup_htg_coil = system.supplementalHeatingCoil.get
      if expect_gas_backup
        assert(sup_htg_coil.to_CoilHeatingGas.is_initialized, "expected a gas backup heating coil for #{system.name}")
        unless expected_backup_fuel_type.nil?
          assert_equal(expected_backup_fuel_type, sup_htg_coil.to_CoilHeatingGas.get.fuelType,
                       "backup coil for #{system.name} should burn #{expected_backup_fuel_type}")
        end
      else
        assert(sup_htg_coil.to_CoilHeatingElectric.is_initialized, "expected an electric resistance backup heating coil for #{system.name}")
      end

      htg_coil = system.heatingCoil.get
      htg_coil = htg_coil.to_CoilHeatingDXMultiSpeed.is_initialized ? htg_coil.to_CoilHeatingDXMultiSpeed.get : htg_coil.to_CoilHeatingDXSingleSpeed.get
      assert_in_delta(expected_lockout_temp_c, htg_coil.minimumOutdoorDryBulbTemperatureforCompressorOperation, 0.01,
                      "compressor lockout temperature for #{system.name} does not match the expected #{expected_lockout_temp_f}F")
    end
  end

  # ---------------------------------------------------------
  # sizing comparison helpers
  # ---------------------------------------------------------

  # airflows and coil capacities of the unitary systems, air loops, and OA controllers
  def get_sizing_summary(model)
    sizing_summary = { 'AirLoopHVACUnitarySystem' => {}, 'AirLoopHVAC' => {}, 'ControllerOutdoorAir' => {} }
    model.getAirLoopHVACUnitarySystems.each do |airloophvacunisys|
      name_obj = airloophvacunisys.name.to_s
      cooling_capacity_w, = get_cooling_coil_capacity_and_cop(model, airloophvacunisys.coolingCoil.get)
      heating_capacity_w, = get_heating_coil_capacity_and_cop(model, airloophvacunisys.heatingCoil.get)
      sizing_summary['AirLoopHVACUnitarySystem'][name_obj] = {
        'supplyAirFlowRateDuringCoolingOperation' => airloophvacunisys.supplyAirFlowRateDuringCoolingOperation.get,
        'supplyAirFlowRateDuringHeatingOperation' => airloophvacunisys.supplyAirFlowRateDuringHeatingOperation.get,
        'cooling_coil_capacity_w' => cooling_capacity_w,
        'heating_coil_capacity_w' => heating_capacity_w
      }
    end
    model.getAirLoopHVACs.each do |airloophvac|
      sizing_summary['AirLoopHVAC'][airloophvac.name.to_s] = { 'designSupplyAirFlowRate' => airloophvac.designSupplyAirFlowRate.get }
    end
    model.getControllerOutdoorAirs.each do |ctrloa|
      sizing_summary['ControllerOutdoorAir'][ctrloa.name.to_s] = { 'maximumOutdoorAirFlowRate' => ctrloa.maximumOutdoorAirFlowRate.get }
    end
    sizing_summary
  end

  # compare a regularly sized model against an upsized model where upsizing has no impact (hot region)
  def check_sizing_results_no_upsizing(model, sizing_summary_reference)
    model.getAirLoopHVACUnitarySystems.each do |airloophvacunisys|
      name_obj = airloophvacunisys.name.to_s
      reference = sizing_summary_reference['AirLoopHVACUnitarySystem'][name_obj]

      value_after = airloophvacunisys.supplyAirFlowRateDuringCoolingOperation.get
      assert_in_epsilon(reference['supplyAirFlowRateDuringCoolingOperation'], value_after, 0.000001, "values do not match: AirLoopHVACUnitarySystem | #{name_obj} | supplyAirFlowRateDuringCoolingOperation")

      value_after = airloophvacunisys.supplyAirFlowRateDuringHeatingOperation.get
      assert_in_epsilon(reference['supplyAirFlowRateDuringHeatingOperation'], value_after, 0.000001, "values do not match: AirLoopHVACUnitarySystem | #{name_obj} | supplyAirFlowRateDuringHeatingOperation")

      value_after, = get_cooling_coil_capacity_and_cop(model, airloophvacunisys.coolingCoil.get)
      assert_in_epsilon(reference['cooling_coil_capacity_w'], value_after, 0.000001, "values do not match: AirLoopHVACUnitarySystem | #{name_obj} | cooling_coil_capacity_w")

      value_after, = get_heating_coil_capacity_and_cop(model, airloophvacunisys.heatingCoil.get)
      assert_in_epsilon(reference['heating_coil_capacity_w'], value_after, 0.000001, "values do not match: AirLoopHVACUnitarySystem | #{name_obj} | heating_coil_capacity_w")
    end
    model.getAirLoopHVACs.each do |airloophvac|
      name_obj = airloophvac.name.to_s
      value_before = sizing_summary_reference['AirLoopHVAC'][name_obj]['designSupplyAirFlowRate']
      assert_in_epsilon(value_before, airloophvac.designSupplyAirFlowRate.get, 0.000001, "values do not match: AirLoopHVAC | #{name_obj} | designSupplyAirFlowRate")
    end
    model.getControllerOutdoorAirs.each do |ctrloa|
      name_obj = ctrloa.name.to_s
      value_before = sizing_summary_reference['ControllerOutdoorAir'][name_obj]['maximumOutdoorAirFlowRate']
      assert_in_epsilon(value_before, ctrloa.maximumOutdoorAirFlowRate.get, 0.000001, "values do not match: ControllerOutdoorAir | #{name_obj} | maximumOutdoorAirFlowRate")
    end
  end

  # compare a regularly sized model against an upsized model where upsizing has an impact (cold region)
  def check_sizing_results_upsizing(model, sizing_summary_reference)
    model.getAirLoopHVACUnitarySystems.each do |airloophvacunisys|
      name_obj = airloophvacunisys.name.to_s
      reference = sizing_summary_reference['AirLoopHVACUnitarySystem'][name_obj]

      value_before = reference['cooling_coil_capacity_w']
      value_after, = get_cooling_coil_capacity_and_cop(model, airloophvacunisys.coolingCoil.get)
      relative_difference = (value_after - value_before) / value_before
      assert_in_epsilon(relative_difference, 0.25, 0.01, "values difference not close to threshold: AirLoopHVACUnitarySystem | #{name_obj} | cooling_coil_capacity_w")

      value_before = reference['heating_coil_capacity_w']
      value_after, = get_heating_coil_capacity_and_cop(model, airloophvacunisys.heatingCoil.get)
      relative_difference = (value_after - value_before) / value_before
      assert_in_epsilon(relative_difference, 0.25, 0.01, "values difference not close to threshold: AirLoopHVACUnitarySystem | #{name_obj} | heating_coil_capacity_w")
    end
    model.getAirLoopHVACs.each do |airloophvac|
      name_obj = airloophvac.name.to_s
      value_before = sizing_summary_reference['AirLoopHVAC'][name_obj]['designSupplyAirFlowRate']
      assert_in_epsilon(airloophvac.designSupplyAirFlowRate.get, value_before, 0.01, "values difference not within threshold: AirLoopHVAC | #{name_obj} | designSupplyAirFlowRate")
    end
    model.getControllerOutdoorAirs.each do |ctrloa|
      name_obj = ctrloa.name.to_s
      value_before = sizing_summary_reference['ControllerOutdoorAir'][name_obj]['maximumOutdoorAirFlowRate']
      assert_in_epsilon(ctrloa.maximumOutdoorAirFlowRate.get, value_before, 0.01, "values difference not within threshold: AirLoopHVAC | #{name_obj} | maximumOutdoorAirFlowRate")
    end
  end

  # apply the measure with a sizing run at no oversizing, then at 25% oversizing
  # @return [Array] sizing summary of the regularly sized model, measure result and model of the upsized run
  def run_sizing_comparison(test_name, osm_name, epw_name, scenario)
    announce_test(osm_name)
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    arguments = measure.arguments(model)

    # regular sizing
    argument_map = build_argument_map(arguments, 'sizing_run' => true, 'hprtu_scenario' => scenario, 'performance_oversizing_factor' => 0.0)
    set_weather_and_apply_measure_and_run("#{test_name}_b", measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    model = load_model(model_output_path("#{test_name}_b"))
    sizing_summary_reference = get_sizing_summary(model)

    # upsizing
    argument_map = build_argument_map(arguments, 'sizing_run' => true, 'hprtu_scenario' => scenario, 'performance_oversizing_factor' => 0.25)
    result = set_weather_and_apply_measure_and_run("#{test_name}_a", measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    model = load_model(model_output_path("#{test_name}_a"))

    [sizing_summary_reference, result, model]
  end

  # ---------------------------------------------------------
  # performance json format helpers
  # ---------------------------------------------------------

  # parse every performance json in the resources directory and yield its hash and path
  def each_performance_json
    Dir.glob("#{__dir__}/../resources/*.json").each do |file_path|
      hash = JSON.parse(File.read(file_path), symbolize_names: true)
      assert(hash[:tables], "Missing :tables key in #{file_path}")
      yield hash, file_path
    rescue JSON::ParserError => e
      flunk "JSON parsing failed for #{file_path}: #{e.message}"
    end
  end

  # assert the data points of each lookup table vary the second independent variable before the first
  def data_point_ordering_check(lookup_table_in_hash)
    lookup_table_in_hash[:tables][:curves][:table].each do |table|
      next unless table[:form] == 'MultiVariableLookupTable'

      puts("--- checking table format: #{table[:name]}")

      # data point coordinates sorted by data point number
      points = table.select { |k, _| k.to_s.match?(/^data_point\d+$/) }
                    .sort_by { |k, _| k.to_s.match(/\d+/)[0].to_i }
                    .map { |_, v| v.split(',').first(2).map(&:to_f) }

      # count which variable changes between consecutive points
      x1_first_changes = 0
      x2_first_changes = 0
      points.each_cons(2) do |(x1a, x2a), (x1b, x2b)|
        if x1a != x1b && x2a == x2b
          x1_first_changes += 1
        elsif x1a == x1b && x2a != x2b
          x2_first_changes += 1
        end
      end

      # if x1 changes more frequently while x2 is stable, the ordering is wrong
      assert(x2_first_changes >= x1_first_changes, 'Invalid data point order: x1 varies before x2 in some cases')
    end
  end

  # assert the temperature bounds of each biquadratic curve are sensible for its mode
  def biquadratic_format_check(lookup_table_in_hash, file_path)
    lookup_table_in_hash[:tables][:curves][:table].each do |table|
      next unless table[:form] == 'BiQuadratic'
      next unless BIQUADRATIC_CURVE_MODES.key?(table[:name])

      case BIQUADRATIC_CURVE_MODES[table[:name]]
      when 'cooling'
        puts("--- checking biquadratic cooling curve format: #{table[:name]}")
        max_oat = table[:maximum_independent_variable_2]
        max_iat = table[:maximum_independent_variable_1]
        assert(max_oat > max_iat,
               "Maximum OAT (#{max_oat}) for cooling curve seems to be lower than Maximum IAT (#{max_iat}). " \
               "Check curve (#{table[:name]}) or mode classification in BIQUADRATIC_CURVE_MODES. File: #{file_path}")
      when 'heating'
        puts("--- checking biquadratic heating curve format: #{table[:name]}")
        min_oat = table[:minimum_independent_variable_2]
        min_iat = table[:minimum_independent_variable_1]
        assert(min_oat < min_iat,
               "Minimum OAT (#{min_oat}) for heating curve seems to be higher than Minimum IAT (#{min_iat}). " \
               "Check curve (#{table[:name]}) or mode classification in BIQUADRATIC_CURVE_MODES. File: #{file_path}")
      end
    end
  end

  # ---------------------------------------------------------
  # fan helpers
  # ---------------------------------------------------------

  # apply the measure for one scenario and return the applied model and the variable volume supply fans it created
  def apply_and_get_supply_fans(test_name, osm_name, epw_name, scenario, extra_args: {})
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    argument_map = build_argument_map(measure.arguments(model), { 'hprtu_scenario' => scenario }.merge(extra_args))

    set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    applied = load_model(model_output_path(test_name))
    fans = applied.getAirLoopHVACUnitarySystems.map do |us|
      next nil unless us.supplyFan.is_initialized

      f = us.supplyFan.get
      f.to_FanVariableVolume.is_initialized ? f.to_FanVariableVolume.get : nil
    end.compact
    [applied, fans]
  end

  # assert the fan power coefficients match and return design power at design flow
  def assert_fan_coefficients(fan, expected, label)
    actual = [fan.fanPowerCoefficient1, fan.fanPowerCoefficient2, fan.fanPowerCoefficient3,
              fan.fanPowerCoefficient4, fan.fanPowerCoefficient5].map { |c| unwrap_optional(c) || 0.0 }
    expected.each_with_index do |exp, i|
      assert_in_delta(exp, actual[i], 1e-6, "#{label}: fan power coefficient #{i + 1} is #{actual[i]}, expected #{exp}")
    end
    # the curve must return design power at design flow, or the fan is mis-scaled
    full_flow_power = fan_power_at(actual, 1.0)
    assert_in_delta(1.0, full_flow_power, 0.01, "#{label}: part-load curve returns #{full_flow_power.round(4)} at full flow, expected 1.0")
  end

  # assert total efficiency is the impeller efficiency times a real 90.1 motor efficiency, not a literal
  def assert_efficiency_from_standards(fan, expected_impeller, label)
    total = fan.fanEfficiency
    motor = fan.motorEfficiency
    assert(ASHRAE_MOTOR_EFFICIENCIES.any? { |m| (m - motor).abs < 1e-6 }, "#{label}: motor efficiency #{motor} is not a 90.1 table value")
    assert_in_delta(expected_impeller * motor, total, 1e-6, "#{label}: total efficiency #{total} is not impeller #{expected_impeller} x motor #{motor}")
  end

  # assert the fan power minimum flow fraction is at least the turndown the scenario json specifies, and no more than 1.0
  # adjust_cfm_per_ton_per_limits can push the realised lowest stage below the specified turndown to keep cfm/ton inside the
  # EnergyPlus operating range, but that guard is not a statement of equipment turndown, so the measure clamps the fan power curve
  def assert_fan_min_flow_at_least_specified(fan, scenario, expected_specified, label)
    min_flow = unwrap_optional(fan.fanPowerMinimumFlowFraction)
    specified = specified_min_flow_fraction_for(scenario)
    assert_in_delta(expected_specified, specified, 1e-6, "the #{scenario} staging json should specify a #{expected_specified} lowest stage, got #{specified}")
    assert(min_flow >= specified - 1e-6,
           "#{label}: minimum flow fraction #{min_flow.round(4)} is below the specified turndown #{specified}; " \
           "the cfm/ton guard must not lower the fan's claimed turndown")
    assert(min_flow <= 1.0 + 1e-6, "#{label}: minimum flow fraction #{min_flow.round(4)} exceeds 1.0")
  end

  # ---------------------------------------------------------
  # setback helpers
  # ---------------------------------------------------------

  # apply the measure with the given setback value and return the applied model
  def apply_with_setback(test_name, osm_name, epw_name, setback_val)
    announce_test(test_name)
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    argument_map = build_argument_map(measure.arguments(model), 'setback_value' => setback_val)

    result = set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false)
    assert_equal('Success', result.value.valueName)
    load_model(model_output_path(test_name))
  end

  # heating setpoint day profiles of every zone served by an air loop
  def heating_setpoint_profiles(model)
    profiles = []
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      air_loop_hvac.thermalZones.sort.each do |thermal_zone|
        next unless thermal_zone.thermostatSetpointDualSetpoint.is_initialized

        htg_schedule = thermal_zone.thermostatSetpointDualSetpoint.get.heatingSetpointTemperatureSchedule
        if htg_schedule.empty?
          puts("Heating setpoint schedule not found for zone '#{thermal_zone.name.get}'")
          next
        elsif htg_schedule.get.to_ScheduleRuleset.empty?
          puts("Schedule '#{htg_schedule.get.name.get}' is not a ScheduleRuleset, will not be adjusted")
          next
        end
        htg_schedule = htg_schedule.get.to_ScheduleRuleset.get
        profiles << htg_schedule.defaultDaySchedule
        htg_schedule.scheduleRules.each { |rule| profiles << rule.daySchedule }
      end
    end
    profiles
  end

  # assert no profile's setback exceeds the expected value; the block returns the values of a profile to compare
  def assert_setback_deltas_within(profiles, setback_value_c)
    # any change in a profile during the day is assumed to be a nighttime setback
    schedule_deltas = profiles.map do |tstat_profile|
      values = yield(tstat_profile)
      values.max - values.min
    end
    deltas_out_of_range = schedule_deltas.any? { |x| x > setback_value_c }
    puts("Temperature deltas in schedule match expected values: #{deltas_out_of_range == false}")
    assert_equal(deltas_out_of_range, false)
  end

  # ---------------------------------------------------------
  # options lookup helpers
  # ---------------------------------------------------------

  # read one hvac_add_heat_pump_rtu row from the options lookup and return its measure arguments as a name => value string hash
  def options_lookup_args_for(option_name)
    path = File.join(File.dirname(__FILE__), '../../../options_lookup.tsv')
    row = File.readlines(path, chomp: true).map { |l| l.split("\t") }.find do |cols|
      cols[0] == 'hvac_add_heat_pump_rtu' && cols[1] == option_name
    end
    refute_nil(row, "options lookup has no hvac_add_heat_pump_rtu row named #{option_name}")
    assert_equal('upgrade_hvac_add_heat_pump_rtu', row[2], "#{option_name} points to the wrong measure")
    row[3..].reject(&:empty?).to_h { |a| a.split('=', 2) }
  end

  # apply one dual fuel options lookup row and check every RTU it creates: a natural gas backup coil, the row's gas backup
  # compressor lockout, the expected heating coil type and stage count, and heating capacity curves from the row's scenario
  # apply-only, so it runs in well under a minute
  def verify_dual_fuel_options_lookup_row(test_name, option_name, expected_hprtu_scenario, expected_heating_stages, expected_heating_cap_curves)
    announce_test(test_name)
    lookup_args = options_lookup_args_for(option_name)
    assert_equal('dual_fuel_gas_furnace_backup', lookup_args['backup_ht_fuel_scheme'])
    assert_equal(expected_hprtu_scenario, lookup_args['hprtu_scenario'])

    osm_path = model_input_path('380_small_office_psz_gas_coil_7A.osm')
    epw_path = epw_input_path('NE_Kearney_Muni_725526_16.epw')
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    arguments = measure.arguments(model)

    # every argument in the row must be a measure argument, or the run would silently ignore it
    unknown_args = lookup_args.keys - arguments.map(&:name)
    assert_empty(unknown_args, "options lookup arguments not defined by the measure: #{unknown_args}")

    # convert the row's string values to the argument types
    typed_args = lookup_args.to_h do |name, value|
      arg = arguments.find { |a| a.name == name }
      typed_value =
        case arg.type.valueName
        when 'Double' then value.to_f
        when 'Integer' then value.to_i
        when 'Boolean' then value == 'true'
        else value
        end
      [name, typed_value]
    end
    argument_map = build_argument_map(arguments, typed_args)

    set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, apply: true, model: model)
    applied = load_model(model_output_path(test_name))
    unitary_systems = applied.getAirLoopHVACUnitarySystems
    refute_empty(unitary_systems, "no unitary systems after applying #{option_name}")

    expected_lockout_temp_c = OpenStudio.convert(lookup_args['hp_min_comp_lockout_temp_gas_backup_f'].to_f, 'F', 'C').get
    unitary_systems.each do |system|
      sup_htg_coil = system.supplementalHeatingCoil.get
      assert(sup_htg_coil.to_CoilHeatingGas.is_initialized, "expected a gas backup coil for #{system.name}")
      assert_equal('NaturalGas', sup_htg_coil.to_CoilHeatingGas.get.fuelType, "dual fuel backup coil for #{system.name} should burn natural gas")

      htg_coil = system.heatingCoil.get
      if expected_heating_stages == 1
        assert(htg_coil.to_CoilHeatingDXSingleSpeed.is_initialized, "expected a single speed DX heating coil for #{system.name}")
        htg_coil = htg_coil.to_CoilHeatingDXSingleSpeed.get
        curve_names = [htg_coil.totalHeatingCapacityFunctionofTemperatureCurve.name.get]
      else
        assert(htg_coil.to_CoilHeatingDXMultiSpeed.is_initialized, "expected a multispeed DX heating coil for #{system.name}")
        htg_coil = htg_coil.to_CoilHeatingDXMultiSpeed.get
        assert_equal(expected_heating_stages, htg_coil.stages.size, "heating stage count for #{system.name}")
        curve_names = htg_coil.stages.map { |st| st.heatingCapacityFunctionofTemperatureCurve.name.get }
      end
      assert_in_delta(expected_lockout_temp_c, htg_coil.minimumOutdoorDryBulbTemperatureforCompressorOperation, 0.01,
                      "compressor lockout for #{system.name} should be the gas backup temperature in #{option_name}")
      assert(curve_names.all? { |n| expected_heating_cap_curves.include?(n) },
             "heating coil for #{system.name} uses #{curve_names}, expected #{expected_hprtu_scenario} curves #{expected_heating_cap_curves}")
    end
  end

  # ##########################################################################
  # measure arguments and performance json format
  # ##########################################################################

  # ensure the test is matched to the measure inputs
  def test_number_of_arguments_and_argument_names
    announce_test('test_number_of_arguments_and_argument_names')
    measure = AddHeatPumpRtu.new
    model = OpenStudio::Model::Model.new

    arguments = measure.arguments(model)
    assert_equal(17, arguments.size)
    assert_equal('backup_ht_fuel_scheme', arguments[0].name)
    assert_equal('performance_oversizing_factor', arguments[1].name)
    assert_equal('htg_sizing_option', arguments[2].name)
    assert_equal('clg_oversizing_estimate', arguments[3].name)
    assert_equal('htg_to_clg_hp_ratio', arguments[4].name)
    assert_equal('hp_min_comp_lockout_temp_elec_backup_f', arguments[5].name)
    assert_equal('hp_min_comp_lockout_temp_gas_backup_f', arguments[6].name)
    assert_equal('hprtu_scenario', arguments[7].name)
    assert_equal('hr', arguments[8].name)
    assert_equal('dcv', arguments[9].name)
    assert_equal('econ', arguments[10].name)
    assert_equal('roof', arguments[11].name)
    assert_equal('window', arguments[12].name)
    assert_equal('sizing_run', arguments[13].name)
    assert_equal('debug_verbose', arguments[14].name)
    assert_equal('modify_setbacks', arguments[15].name)
    assert_equal('setback_value', arguments[16].name)

    # default lockout temperatures; electric backup allows the compressor to run much colder than gas backup,
    # where the furnace is intended to take over at a milder outdoor temperature
    assert_equal(0.0, arguments[5].defaultValueAsDouble)
    assert_equal(25.0, arguments[6].defaultValueAsDouble)
  end

  # ensure the format of lookup tables in the performance jsons
  def test_table_lookup_format
    announce_test('test_table_lookup_format')
    each_performance_json do |hash, file_path|
      puts("### checking json file: #{file_path}")
      data_point_ordering_check(hash)
    end
  end

  # ensure the format of biquadratic curves used in DX units
  def test_biquadratic_format
    announce_test('test_biquadratic_format')
    each_performance_json do |hash, file_path|
      biquadratic_format_check(hash, file_path)
    end
  end

  # ##########################################################################
  # upsizing algorithm
  # compares a regularly sized model against an upsized model in a cold region (upsizing applies)
  # and in a hot region (upsizing has no impact)
  # ##########################################################################

  def test_sizing_model_in_alaska
    sizing_summary_reference, _result, model = run_sizing_comparison('test_sizing_model_in_alaska', 'small_office_psz_not_hard_sized.osm',
                                                                     'USA_AK_Fairbanks.Intl.AP.702610_TMY3.epw', 'two_speed_standard_eff')
    verify_lookup_table_value(model, table_name: 'c_cap_high_T', ind1: 22.22, ind2: 29.44, dep: 1.1677)
    check_sizing_results_upsizing(model, sizing_summary_reference)
  end

  def test_sizing_model_in_hawaii
    sizing_summary_reference, _result, model = run_sizing_comparison('test_sizing_model_in_hawaii', 'small_office_psz_not_hard_sized.osm',
                                                                     'USA_HI_Honolulu.Intl.AP.911820_TMY3.epw', 'variable_speed_high_eff')
    check_sizing_results_no_upsizing(model, sizing_summary_reference)
  end

  # ##########################################################################
  # fully applicable models
  # checks that the measure runs successfully, applies the user-specified backup heating, removes gas heating coils,
  # creates multispeed coils with ascending stage capacities and flow rates within the E+ cfm/ton ranges,
  # and that the roof/window measure values are saved in the result only when those upgrades are selected
  # ##########################################################################

  def test_380_Small_Office_PSZ_Gas_2A
    run_hp_rtu_test('test_380_Small_Office_PSZ_Gas_2A', '380_Small_Office_PSZ_Gas_2A.osm', 'SC_Columbia_Metro_723100_12.epw',
                    { 'hprtu_scenario' => 'variable_speed_high_eff', 'roof' => true, 'window' => true },
                    roof_expected: true, window_expected: true)
  end

  def test_380_small_office_psz_gas_coil_7A
    run_hp_rtu_test('test_380_small_office_psz_gas_coil_7A', '380_small_office_psz_gas_coil_7A.osm', 'NE_Kearney_Muni_725526_16.epw',
                    { 'hprtu_scenario' => 'variable_speed_high_eff' },
                    roof_expected: false, window_expected: false)
  end

  def test_small_office_psz_not_hard_sized
    run_hp_rtu_test('test_small_office_psz_not_hard_sized', 'small_office_psz_not_hard_sized.osm', 'USA_AK_Fairbanks.Intl.AP.702610_TMY3.epw',
                    { 'hprtu_scenario' => 'variable_speed_high_eff', 'roof' => true },
                    roof_expected: true, window_expected: false)
  end

  def test_380_retail_psz_gas_6B
    run_hp_rtu_test('test_380_retail_psz_gas_6B', '380_retail_psz_gas_6B.osm', 'NE_Kearney_Muni_725526_16.epw',
                    { 'hprtu_scenario' => 'variable_speed_high_eff', 'window' => true },
                    roof_expected: false, window_expected: true)
  end

  # ##########################################################################
  # compressor lockout temperature by backup heat type
  # ##########################################################################

  # the dual fuel compressor lockout temperature applies when the backup heating coil is a gas furnace
  # the electric backup lockout is deliberately set to a different value so this test fails if the wrong argument is used
  # apply-only: the lockout and backup coil type do not depend on hard sizing, which test_380_small_office_psz_gas_coil_7A covers
  def test_gas_backup_lockout_7A
    osm_name = '380_small_office_psz_gas_coil_7A.osm'
    announce_test(osm_name)
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path('NE_Kearney_Muni_725526_16.epw')
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)

    # a non-default gas backup lockout confirms the argument is actually read
    elec_backup_lockout_temp_f = 0.0
    gas_backup_lockout_temp_f = 30.0
    argument_map = build_argument_map(measure.arguments(model),
                                      'hprtu_scenario' => 'variable_speed_high_eff',
                                      'backup_ht_fuel_scheme' => 'match_original_primary_heating_fuel',
                                      'hp_min_comp_lockout_temp_elec_backup_f' => elec_backup_lockout_temp_f,
                                      'hp_min_comp_lockout_temp_gas_backup_f' => gas_backup_lockout_temp_f)

    # the original model heats with gas, so matching the original fuel gives gas backup coils
    # and the compressor should lock out at the gas backup temperature
    verify_backup_heat_and_lockout('test_gas_backup_lockout_7A', measure, argument_map, osm_path, epw_path,
                                   expect_gas_backup: true, expected_lockout_temp_f: gas_backup_lockout_temp_f)
  end

  # the gas backup lockout temperature is ignored when the backup heating coil is electric resistance,
  # even though the original model heats with gas
  # apply-only, like test_gas_backup_lockout_7A
  def test_elec_backup_lockout_7A
    osm_name = '380_small_office_psz_gas_coil_7A.osm'
    announce_test(osm_name)
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path('NE_Kearney_Muni_725526_16.epw')
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)

    elec_backup_lockout_temp_f = 0.0
    gas_backup_lockout_temp_f = 30.0
    argument_map = build_argument_map(measure.arguments(model),
                                      'hprtu_scenario' => 'variable_speed_high_eff',
                                      'backup_ht_fuel_scheme' => 'electric_resistance_backup',
                                      'hp_min_comp_lockout_temp_elec_backup_f' => elec_backup_lockout_temp_f,
                                      'hp_min_comp_lockout_temp_gas_backup_f' => gas_backup_lockout_temp_f)

    # electric resistance backup was requested, so the electric lockout temperature applies
    verify_backup_heat_and_lockout('test_elec_backup_lockout_7A', measure, argument_map, osm_path, epw_path,
                                   expect_gas_backup: false, expected_lockout_temp_f: elec_backup_lockout_temp_f)
  end

  # ##########################################################################
  # partially applicable building types and cfm/ton checks
  # ##########################################################################

  # kitchens are skipped while the other zones get heat pump RTUs
  def test_380_full_service_restaurant_psz_gas_coil
    osm_name = '380_full_service_restaurant_psz_gas_coil.osm'
    announce_test(osm_name)
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path('GA_ROBINS_AFB_722175_12.epw')
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    argument_map = build_argument_map(measure.arguments(model), 'hprtu_scenario' => 'variable_speed_high_eff')

    # kitchen unitary systems before the measure
    tz_kitchens, = model.getAirLoopHVACUnitarySystems.sort.partition { |unitary_sys| KITCHEN_NAME_WORDS.any? { |word| unitary_sys.name.to_s.include?(word) } }

    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))

    # kitchen and non kitchen unitary systems after the measure
    tz_kitchens_final, tz_all_other_final = model.getAirLoopHVACUnitarySystems.sort.partition { |unitary_sys| KITCHEN_NAME_WORDS.any? { |word| unitary_sys.name.to_s.include?(word) } }

    # assert no changes to kitchen unitary systems
    assert_equal(tz_kitchens_final, tz_kitchens)

    # assert non kitchen spaces contain multispeed DX heating coils
    tz_all_other_final.each do |unitary_sys|
      assert(unitary_sys.heatingCoil.get.to_CoilHeatingDXMultiSpeed.is_initialized)
    end

    # assert kitchen spaces still contain gas coils
    tz_kitchens_final.each do |unitary_sys|
      assert(unitary_sys.heatingCoil.get.to_CoilHeatingGas.is_initialized)
    end

    verify_cfm_per_ton(model, result)
  end

  # cfm/ton check for the standard performance unit, with a lookup table value check
  def test_380_full_service_restaurant_psz_gas_coil_std_perf
    osm_name = '380_full_service_restaurant_psz_gas_coil.osm'
    announce_test(osm_name)
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path('GA_ROBINS_AFB_722175_12.epw')
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    argument_map = build_argument_map(measure.arguments(model), 'hprtu_scenario' => 'two_speed_standard_eff')

    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))

    verify_lookup_table_value(model, table_name: 'h_cap_T', ind1: 21.11, ind2: -17.78, dep: 0.3974)
    verify_cfm_per_ton(model, result)
  end

  # cfm/ton check for the upsized unit
  def test_380_full_service_restaurant_psz_gas_coil_upsizing
    osm_name = '380_full_service_restaurant_psz_gas_coil.osm'
    announce_test(osm_name)
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path('GA_ROBINS_AFB_722175_12.epw')
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    argument_map = build_argument_map(measure.arguments(model),
                                      'sizing_run' => false, 'hprtu_scenario' => 'variable_speed_high_eff', 'performance_oversizing_factor' => 0.25)

    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))

    verify_cfm_per_ton(model, result)
  end

  # cfm/ton check for the upsized advanced unit with a sizing run and an annual simulation
  def test_380_small_office_psz_gas_coil_7A_upsizing_adv
    osm_name = '380_small_office_psz_gas_coil_7A.osm'
    announce_test(osm_name)
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path('USA_AK_Fairbanks.Intl.AP.702610_TMY3.epw')
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    argument_map = build_argument_map(measure.arguments(model),
                                      'sizing_run' => true, 'hprtu_scenario' => 'variable_speed_high_eff', 'debug_verbose' => true,
                                      'performance_oversizing_factor' => 0.25)

    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))

    verify_cfm_per_ton(model, result)
  end

  # cfm/ton check for the upsized standard unit with a sizing run and an annual simulation, with a lookup table value check
  def test_380_small_office_psz_gas_coil_7A_upsizing_std
    osm_name = '380_small_office_psz_gas_coil_7A.osm'
    announce_test(osm_name)
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path('USA_AK_Fairbanks.Intl.AP.702610_TMY3.epw')
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    argument_map = build_argument_map(measure.arguments(model),
                                      'sizing_run' => true, 'hprtu_scenario' => 'two_speed_standard_eff', 'debug_verbose' => true,
                                      'performance_oversizing_factor' => 0.25)

    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))

    verify_lookup_table_value(model, table_name: 'c_eir_high_T', ind1: 22.22, ind2: 35.0, dep: 0.9438)
    verify_cfm_per_ton(model, result)
  end

  # ##########################################################################
  # non applicable HVAC systems register as NA
  # ##########################################################################

  def test_380_StripMall_Residential_AC_with_residential_forced_air_furnace_2A
    assert_measure_not_applicable(__method__, '380_StripMall_Residential AC with residential forced air furnace_2A.osm', 'TN_KNOXVILLE_723260_12.epw')
  end

  def test_380_warehouse_pvav_gas_boiler_reheat_2A
    assert_measure_not_applicable(__method__, '380_warehouse_pvav_gas_boiler_reheat_2A.osm', 'TN_KNOXVILLE_723260_12.epw',
                                  'hprtu_scenario' => 'variable_speed_high_eff')
  end

  def test_380_medium_office_doas_fan_coil_acc_boiler_3A
    assert_measure_not_applicable(__method__, '380_medium_office_doas_fan_coil_acc_boiler_3A.osm', 'TN_KNOXVILLE_723260_12.epw',
                                  'hprtu_scenario' => 'variable_speed_high_eff')
  end

  # ##########################################################################
  # existing ERVs
  # ##########################################################################

  # existing ERVs are not affected when the ERV argument is NOT toggled
  def test_380_full_service_restaurant_psz_gas_coil_single_erv_3A
    assert_existing_ervs_unchanged(__method__, '380_full_service_restaurant_psz_gas_coil_single_erv_3A.osm', 'SC_Columbia_Metro_723100_12.epw',
                                   'hprtu_scenario' => 'variable_speed_high_eff')
  end

  # existing ERVs are not affected when energy recovery IS requested on a building type that is excluded from it
  # (full service restaurants); the measure warns and leaves the ERVs in place
  def test_380_full_service_restaurant_psz_gas_coil_single_erv_3A_na
    result = assert_existing_ervs_unchanged(__method__, '380_full_service_restaurant_psz_gas_coil_single_erv_3A.osm', 'SC_Columbia_Metro_723100_12.epw',
                                            'hprtu_scenario' => 'variable_speed_high_eff', 'hr' => true)
    assert(result.warnings.any? { |w| w.logMessage.include?('not applicable for energy recovery') },
           'expected a warning that the building type is not applicable for energy recovery')
  end

  # ##########################################################################
  # heating setbacks
  # ##########################################################################

  # confirm that any heating setbacks are now 2F for square wave profiles
  def test_confirm_heating_setback_change_square_wave
    setback_val = 2.0
    setback_value_c = setback_val * 5 / 9
    model = apply_with_setback(__method__, 'Retail_PSZ-AC.osm', 'NE_Kearney_Muni_725526_16.epw', setback_val)

    assert_setback_deltas_within(heating_setpoint_profiles(model), setback_value_c, &:values)
  end

  # confirm that any heating setbacks are now 2F on a model whose Sunday profile has an optimum start ramp
  # (an intermediate setpoint step before the occupied setpoint), and check the ramp branch of the measure directly:
  # every step below the new minimum is raised to it and the occupied setpoint is untouched
  def test_confirm_heating_setback_change_opt_start
    setback_val = 2.0
    setback_value_c = setback_val * 5 / 9
    osm_name = 'Retail_PSZ-AC_updated_39_opt_start.osm'

    # ramp profiles in the input model have more than two unique values
    ramp_profiles_before = heating_setpoint_profiles(load_model(model_input_path(osm_name))).select { |p| p.values.uniq.size > 2 }
    refute_empty(ramp_profiles_before, 'expected the opt-start model to contain a heating setpoint profile with a ramp')

    model = apply_with_setback(__method__, osm_name, 'NE_Kearney_Muni_725526_16.epw', setback_val)
    profiles_after = heating_setpoint_profiles(model)
    assert_setback_deltas_within(profiles_after, setback_value_c, &:values)

    # the measure modifies the day schedules in place, so pair them by name
    ramp_profiles_before.each do |before|
      after = profiles_after.find { |p| p.name.to_s == before.name.to_s }
      refute_nil(after, "profile #{before.name} is missing after the measure")
      new_min = before.values.max - setback_value_c
      assert_in_delta(before.values.max, after.values.max, 1e-6, "occupied setpoint of #{before.name} should be untouched")
      assert_equal(before.values.size, after.values.size, "#{before.name} should keep its time steps")
      before.values.zip(after.values).each do |value_before, value_after|
        expected = [value_before, new_min].max
        assert_in_delta(expected, value_after, 1e-6, "#{before.name}: #{value_before} C should become #{expected} C")
      end
    end
  end

  # ##########################################################################
  # supply fan representation and backup fuel type
  # these cover behaviour that used to be shared across every hprtu_scenario: one variable-speed part-load curve,
  # one flat fan efficiency, and a backup coil that was always natural gas
  # each assertion pins a value to the source it comes from, so an edit that collapses the scenarios back together,
  # or that reintroduces a literal, fails here
  # ##########################################################################

  # data-only check of the fan_data records; runs in milliseconds so a bad curve in a json is caught immediately
  def test_fan_data_records_are_present_and_sane
    announce_test('test_fan_data_records_are_present_and_sane')
    SCENARIO_PERFORMANCE_JSON.each_key do |scenario|
      fd = fan_data_for(scenario)
      refute_nil(fd, "#{scenario}: no fan_data record in its performance json")

      assert(['two_speed', 'variable_speed'].include?(fd['fan_type']), "#{scenario}: fan_type #{fd['fan_type'].inspect} is not a recognised type")

      coeffs = fd['fan_power_coefficients']
      assert_equal(5, coeffs.size, "#{scenario}: expected 5 fan power coefficients")
      coeffs.each { |c| assert_kind_of(Numeric, c, "#{scenario}: non-numeric fan power coefficient") }

      # the curve must return design power at design flow or the fan is mis-scaled
      full = fan_power_at(coeffs, 1.0)
      assert_in_delta(1.0, full, 0.01, "#{scenario}: part-load curve gives #{full.round(4)} at full flow, expected 1.0")

      # power must not exceed design anywhere in the operating range, and must increase with flow; a curve that dips is a fitting error
      prev = nil
      (20..100).step(5) do |pct|
        x = pct / 100.0
        pwr = fan_power_at(coeffs, x)
        assert(pwr <= 1.02, "#{scenario}: power #{pwr.round(3)} exceeds design at flow #{x}")
        assert(pwr >= -0.01, "#{scenario}: negative power #{pwr.round(3)} at flow #{x}")
        assert(prev.nil? || pwr >= prev - 1e-6, "#{scenario}: power decreases between flow #{(x - 0.05).round(2)} and #{x}")
        prev = pwr
      end

      imp = fd['impeller_efficiency']
      assert(imp.is_a?(Numeric) && imp > 0.4 && imp < 0.85, "#{scenario}: impeller efficiency #{imp.inspect} is outside a plausible range")

      # each value should carry its provenance, so a reviewer can trace it
      refute_empty(fd['fan_power_coefficients_notes'].to_s, "#{scenario}: fan_power_coefficients has no source note")
      refute_empty(fd['impeller_efficiency_notes'].to_s, "#{scenario}: impeller_efficiency has no source note")
    end

    # a two-speed unit must not be given the variable-speed curve; compare at the 90.1 low-speed point, where the two differ most
    two = fan_data_for('two_speed_standard_eff')['fan_power_coefficients']
    var = fan_data_for('variable_speed_high_eff')['fan_power_coefficients']
    assert(fan_power_at(two, 0.66) > fan_power_at(var, 0.66) + 0.05,
           'two-speed and variable-speed fan curves are too close; they may have been collapsed')

    # 90.1 6.5.3.2.1 caps two-speed low-speed power at 40% of full-speed power
    assert_in_delta(0.401, fan_power_at(two, 0.66), 0.01, 'two-speed curve does not land on the 90.1 low-speed power point at 0.66 flow')
  end

  # two-speed units cannot modulate continuously; the fan floor must come from the lowest stage flow fraction
  # in the scenario's staging data (0.59 in cooling), or the outdoor air ratio when that is higher
  def test_fan_two_speed_standard_eff
    test_name = 'test_fan_two_speed_standard_eff'
    announce_test(test_name)
    _model, fans = apply_and_get_supply_fans(test_name, '380_small_office_psz_gas_coil_7A.osm', 'NE_Kearney_Muni_725526_16.epw', 'two_speed_standard_eff')
    refute_empty(fans, 'no variable volume supply fans were created')

    fan_data = fan_data_for('two_speed_standard_eff')
    fans.each do |fan|
      label = "two_speed_standard_eff #{fan.name}"
      assert_fan_coefficients(fan, fan_data['fan_power_coefficients'], label)
      assert_efficiency_from_standards(fan, fan_data['impeller_efficiency'], label)
      # the cfm/ton guard moved the realised lowest stage of this model to 0.50; the floor must still be the specified 0.59
      assert_fan_min_flow_at_least_specified(fan, 'two_speed_standard_eff', 0.59, label)

      # power at the low stage should land on the 90.1 code point, not below it
      power_at_low = fan_power_at(fan_data['fan_power_coefficients'], 0.66)
      assert_in_delta(0.401, power_at_low, 0.005, "#{label}: power at 0.66 flow is #{power_at_low.round(4)}, expected the 90.1 point 0.401")
    end
  end

  # variable-speed units get the 90.1 Single Zone VAV curve and can turn down to the 0.40 lowest stage flow in their staging data
  def test_fan_variable_speed_high_eff
    test_name = 'test_fan_variable_speed_high_eff'
    announce_test(test_name)
    _model, fans = apply_and_get_supply_fans(test_name, '380_small_office_psz_gas_coil_7A.osm', 'NE_Kearney_Muni_725526_16.epw', 'variable_speed_high_eff')
    refute_empty(fans, 'no variable volume supply fans were created')

    fan_data = fan_data_for('variable_speed_high_eff')
    fans.each do |fan|
      label = "variable_speed_high_eff #{fan.name}"
      assert_fan_coefficients(fan, fan_data['fan_power_coefficients'], label)
      assert_efficiency_from_standards(fan, fan_data['impeller_efficiency'], label)
      # on a one-zone small office the cfm/ton guard moved heating stage 1 from 0.40 to 0.28, and fan power at 0.28 flow is roughly
      # half that at 0.40, so without the clamp this scenario would be credited turndown it was never specified to have
      assert_fan_min_flow_at_least_specified(fan, 'variable_speed_high_eff', 0.40, label)

      # the variable-speed advantage must come from the part-load curve, not from an efficiency uplift:
      # the impeller is held at the openstudio-standards value for every scenario, so at design flow all these fans draw the same power
      vs_coeffs = fan_data['fan_power_coefficients']
      ts_coeffs = fan_data_for('two_speed_standard_eff')['fan_power_coefficients']
      assert(fan_power_at(vs_coeffs, 0.5) < fan_power_at(ts_coeffs, 0.5) - 0.02,
             "#{label}: variable-speed power at half flow #{fan_power_at(vs_coeffs, 0.5).round(4)} is not " \
             "meaningfully below two-speed #{fan_power_at(ts_coeffs, 0.5).round(4)}")
    end
  end

  # regression guard: the two scenarios must not share a fan representation
  def test_fan_scenarios_are_differentiated
    announce_test('test_fan_scenarios_are_differentiated')
    _m1, two_speed = apply_and_get_supply_fans('test_fan_diff_two_speed', '380_small_office_psz_gas_coil_7A.osm', 'NE_Kearney_Muni_725526_16.epw', 'two_speed_standard_eff')
    _m2, var_speed = apply_and_get_supply_fans('test_fan_diff_var_speed', '380_small_office_psz_gas_coil_7A.osm', 'NE_Kearney_Muni_725526_16.epw', 'variable_speed_high_eff')
    refute_empty(two_speed)
    refute_empty(var_speed)
    assert_equal(two_speed.size, var_speed.size, 'the scenarios should create the same number of supply fans')

    # compare fan by fan: the fans are named after their air loops, which are the same in both scenarios, and the motor
    # efficiency bin varies by air loop (larger zones get a bigger motor), so comparing by position in an unordered list is not valid
    two_speed_by_name = two_speed.to_h { |fan| [fan.name.to_s, fan] }
    var_speed.each do |vs|
      ts = two_speed_by_name[vs.name.to_s]
      refute_nil(ts, "no two-speed fan named #{vs.name}")

      refute_in_delta(unwrap_optional(ts.fanPowerCoefficient4), unwrap_optional(vs.fanPowerCoefficient4), 1e-6,
                      "#{vs.name}: two-speed and variable-speed scenarios share a part-load curve")
      # deliberately EQUAL, not better: openstudio-standards does not distinguish fan types, and no source was found for a higher
      # impeller on a variable-speed wheel, so the scenarios share one impeller and the advantage rests on the curve and the turndown floor
      assert_in_delta(ts.fanEfficiency, vs.fanEfficiency, 1e-6,
                      "#{vs.name}: the scenarios should share an impeller efficiency; two-speed #{ts.fanEfficiency} vs variable-speed #{vs.fanEfficiency}")
      assert(unwrap_optional(vs.fanPowerMinimumFlowFraction) <= unwrap_optional(ts.fanPowerMinimumFlowFraction) + 1e-6,
             "#{vs.name}: variable speed should turn down at least as far as two-speed")

      # static pressure is a property of the duct system, not the equipment, and must be identical between scenarios and unchanged from the original fan
      assert_in_delta(ts.pressureRise, vs.pressureRise, 1e-6, "#{vs.name}: static pressure should not differ between scenarios")
    end
  end

  # a backup coil matching the original fuel must burn the building's original fuel; fuel oil and propane coils are
  # CoilHeatingGas objects distinguished only by a fuelType field, so they were previously all rebuilt as natural gas
  def test_backup_coil_matches_original_fuel
    announce_test('test_backup_coil_matches_original_fuel')
    ['FuelOilNo2', 'Propane', 'NaturalGas'].each do |fuel|
      test_name = "test_backup_fuel_#{fuel}"
      osm_path = model_input_path('380_small_office_psz_gas_coil_7A.osm')
      epw_path = epw_input_path('NE_Kearney_Muni_725526_16.epw')

      # restate the original model as burning this fuel
      model = load_model(osm_path)
      coils = model.getCoilHeatingGass
      refute_empty(coils, 'test model has no gas heating coils to relabel')
      coils.each { |c| c.setFuelType(fuel) }

      measure = AddHeatPumpRtu.new
      argument_map = build_argument_map(measure.arguments(model),
                                        'hprtu_scenario' => 'two_speed_standard_eff', 'backup_ht_fuel_scheme' => 'match_original_primary_heating_fuel')

      set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, apply: true, model: model)
      applied = load_model(model_output_path(test_name))
      backup_coils = applied.getCoilHeatingGass
      refute_empty(backup_coils, "no backup gas-type coil was created for original fuel #{fuel}")
      backup_coils.each do |c|
        assert_equal(fuel, c.fuelType, "backup coil #{c.name} burns #{c.fuelType} but the original equipment burned #{fuel}")
      end
    end
  end

  # dual fuel backup is always a natural gas coil, regardless of the original heating fuel,
  # and the gas backup compressor lockout temperature is used
  def test_dual_fuel_backup_is_natural_gas
    announce_test('test_dual_fuel_backup_is_natural_gas')
    gas_backup_lockout_temp_f = 30.0
    cases = [
      { name: 'FuelOilNo2', osm: '380_small_office_psz_gas_coil_7A.osm', relabel_fuel: 'FuelOilNo2' },
      { name: 'Propane', osm: '380_small_office_psz_gas_coil_7A.osm', relabel_fuel: 'Propane' },
      { name: 'electric', osm: '310_PSZ-AC with electric coil.osm', relabel_fuel: nil }
    ]
    cases.each do |c|
      test_name = "test_dual_fuel_backup_#{c[:name]}"
      osm_path = model_input_path(c[:osm])
      epw_path = epw_input_path('NE_Kearney_Muni_725526_16.epw')

      model = load_model(osm_path)
      model.getCoilHeatingGass.each { |coil| coil.setFuelType(c[:relabel_fuel]) } unless c[:relabel_fuel].nil?

      measure = AddHeatPumpRtu.new
      argument_map = build_argument_map(measure.arguments(model),
                                        'hprtu_scenario' => 'two_speed_standard_eff',
                                        'backup_ht_fuel_scheme' => 'dual_fuel_gas_furnace_backup',
                                        'hp_min_comp_lockout_temp_elec_backup_f' => 0.0,
                                        'hp_min_comp_lockout_temp_gas_backup_f' => gas_backup_lockout_temp_f)

      # dual fuel always gives a natural gas backup coil and the gas backup lockout, whatever the original fuel
      verify_backup_heat_and_lockout(test_name, measure, argument_map, osm_path, epw_path,
                                     model: model, expect_gas_backup: true, expected_lockout_temp_f: gas_backup_lockout_temp_f,
                                     expected_backup_fuel_type: 'NaturalGas')
    end
  end

  # ##########################################################################
  # dual fuel options lookup rows
  # ##########################################################################

  # scenario 1 (dual fuel RTU, standard performance): 30F gas backup lockout and the single stage two_speed_standard_eff heating curve
  def test_dual_fuel_std_perf_lockout_30F_option
    verify_dual_fuel_options_lookup_row('test_dual_fuel_std_perf_lockout_30F_option', 'dual_fuel_std_perf_lockout_30F',
                                        'two_speed_standard_eff', 1, ['h_cap_T'])
  end

  # scenario 2 (CCHPC challenge spec dual fuel RTU): -10F gas backup lockout and the four cchpc_2027_spec heating stages
  def test_dual_fuel_cchpc_spec_lockout_neg10F_option
    verify_dual_fuel_options_lookup_row('test_dual_fuel_cchpc_spec_lockout_neg10F_option', 'dual_fuel_cchpc_spec_lockout_neg10F',
                                        'cchpc_2027_spec', 4, ['h_cap_low', 'h_cap_medium', 'h_cap_high', 'h_cap_boost'])
  end
end
