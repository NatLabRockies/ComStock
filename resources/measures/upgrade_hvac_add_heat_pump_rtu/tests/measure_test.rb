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
require_relative '../measure'
require_relative '../../../../test/helpers/minitest_helper'
require 'json'

class AddHeatPumpRtuTest < Minitest::Test
  # return file paths to test models in test directory
  def models_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/models/*.osm'))
    paths.map { |path| File.expand_path(path) }
  end

  # return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/weather/*.epw'))
    paths.map { |path| File.expand_path(path) }
  end

  def load_model(osm_path)
    translator = OpenStudio::OSVersion::VersionTranslator.new
    model = translator.loadModel(OpenStudio::Path.new(osm_path))
    assert(!model.empty?)
    model.get
  end

  def run_dir(test_name)
    # always generate test output in specially named 'output' directory so result files are not made part of the measure
    "#{File.dirname(__FILE__)}/output/#{test_name}"
  end

  def model_input_path(osm_name)
    # return models_for_tests.select { |x| set[:model] == osm_name }
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

  # applies the measure and then runs the model
  def set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, model: nil, apply: true, expected_results: 'Success')
    assert(File.exist?(osm_path))
    assert(File.exist?(epw_path))
    ddy_path = "#{epw_path.gsub('.epw', '')}.ddy"

    # create run directory if it does not exist
    FileUtils.mkdir_p(run_dir(test_name)) unless File.exist?(run_dir(test_name))
    assert(File.exist?(run_dir(test_name)))

    # change into run directory for tests
    start_dir = Dir.pwd
    Dir.chdir run_dir(test_name)

    # remove prior runs if they exist
    FileUtils.rm(model_output_path(test_name)) if File.exist?(model_output_path(test_name))
    FileUtils.rm(report_path(test_name)) if File.exist?(report_path(test_name))

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

    # set design days
    if File.exist?(ddy_path)

      # remove all the Design Day objects that are in the file
      model.getObjectsByType('OS:SizingPeriod:DesignDay'.to_IddObjectType).each(&:remove)

      # load ddy
      ddy_model = OpenStudio::EnergyPlus.loadAndTranslateIdf(ddy_path).get

      ddy_model.getDesignDays.sort.each do |d|
        # grab only the ones that matter
        ddy_list = [
          /Htg 99.6. Condns DB/, # Annual heating 99.6%
          /Clg .4. Condns WB=>MDB/, # Annual humidity (for cooling towers and evap coolers)
          /Clg .4. Condns DB=>MWB/, # Annual cooling
          /August .4. Condns DB=>MCWB/, # Monthly cooling DB=>MCWB (to handle solar-gain-driven cooling)
          /September .4. Condns DB=>MCWB/,
          /October .4. Condns DB=>MCWB/
        ]
        ddy_list.each do |ddy_name_regex|
          if d.name.get.to_s.match?(ddy_name_regex)
            runner.registerInfo("Adding object #{d.name}")

            # add the object to the existing model
            model.addObject(d.clone)
            break
          end
        end
      end

      # assert
      assert_equal(false, model.getDesignDays.size.zero?)
    end

    if apply
      # run the measure
      puts "\nAPPLYING MEASURE..."
      measure.run(model, runner, argument_map)
      result = runner.result
      result_success = result.value.valueName == 'Success'
      assert_equal(expected_results, result.value.valueName)

      # Show the output
      show_output(result)
    end

    # adding output variables (for debugging)
    out_vars = [
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
      'Zone Windows Total Transmitted Solar Radiation Rate',
    ]
    out_vars.each do |out_var_name|
        ov = OpenStudio::Model::OutputVariable.new('ov', model)
        ov.setKeyValue('*')
        ov.setReportingFrequency('hourly')
        ov.setVariableName(out_var_name)
    end
    model.getOutputControlFiles.setOutputCSV(true)

    # Save model
    model.save(model_output_path(test_name), true)

    if run_model
      puts "\nRUNNING MODEL..."

      std = Standard.build('90.1-2013')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))

      # Check that the model ran successfully
      assert(File.exist?(sql_path(test_name)))
    end

    # change back directory
    Dir.chdir(start_dir)

    result
  end

  def test_number_of_arguments_and_argument_names
    # This test ensures that the current test is matched to the measure inputs
    test_name = 'test_number_of_arguments_and_argument_names'
    puts "\n######\nTEST:#{test_name}\n######\n"

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Make an empty model
    model = OpenStudio::Model::Model.new

    # Get arguments and test that they are what we are expecting
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

    # assert default lockout temperatures; electric backup allows the compressor to run much colder
    # than gas backup, where the furnace is intended to take over at a milder outdoor temperature
    assert_equal(0.0, arguments[5].defaultValueAsDouble)
    assert_equal(25.0, arguments[6].defaultValueAsDouble)
  end

  def data_point_ordering_check(lookup_table_in_hash)
    tables = lookup_table_in_hash[:tables][:curves][:table]

    tables.each do |table|
      next unless table[:form] == 'MultiVariableLookupTable'

      puts("--- checking table format: #{table[:name]}")

      # Extract and sort data_point keys numerically
      points = table.select { |k, _| k.to_s.match?(/^data_point\d+$/) }
          .sort_by { |k, _| k.to_s.match(/\d+/)[0].to_i }
          .map { |_, v| v.split(',').first(2).map(&:to_f) }

      # Now check if x2 varies first (should see repeated x1s for several rows)
      x1s, x2s = points.transpose

      # Build pairs and check how they vary
      last_x1, last_x2 = points[0]
      x1_first_changes = 0
      x2_first_changes = 0

      points.each_cons(2) do |(x1a, x2a), (x1b, x2b)|
        if x1a != x1b && x2a == x2b
          x1_first_changes += 1
        elsif x1a == x1b && x2a != x2b
          x2_first_changes += 1
        end
      end

      # If x1 changes more frequently while x2 is stable, the ordering is wrong
      assert(x2_first_changes >= x1_first_changes, "Invalid data point order: x1 varies before x2 in some cases")
    end
  end

  def test_table_lookup_format
    # This test ensures the format of lookup tables
    test_name = 'test_lookup_table_format'
    puts "\n######\nTEST:#{test_name}\n######\n"

    path_to_jsons = "#{__dir__}/../resources/*.json"
    json_files = Dir.glob(path_to_jsons)
    json_files.each do |file_path|
      begin
        content = File.read(file_path)
        hash = JSON.parse(content, symbolize_names: true)
        puts("### checking json file: #{file_path}")

        # Now `hash` is your Ruby hash from JSON
        # You can insert your test logic here
        assert(hash[:tables], "Missing :tables key in #{file_path}")

        # check lookup table format
        data_point_ordering_check(hash)
      rescue JSON::ParserError => e
        flunk "JSON parsing failed for #{file_path}: #{e.message}"
      end
    end
  end

  def biquadratic_format_check(lookup_table_in_hash, file_path)
    tables = lookup_table_in_hash[:tables][:curves][:table]

    # Add the curve name and its related mode (heating or cooling)
    list_of_biquadratic_curves_to_check = {
      'cool_cap_ft1' => 'cooling',
      'cool_cap_ft2' => 'cooling',
      'cool_cap_ft3' => 'cooling',
      'cool_cap_ft4' => 'cooling',
      'cool_eir_ft1' => 'cooling',
      'cool_eir_ft2' => 'cooling',
      'cool_eir_ft3' => 'cooling',
      'cool_eir_ft4' => 'cooling',
      'defrost_eir'  => 'heating',
      'heat_cap_ft1' => 'heating',
      'heat_cap_ft2' => 'heating',
      'heat_cap_ft3' => 'heating',
      'heat_cap_ft4' => 'heating',
      'heat_eir_ft1' => 'heating',
      'heat_eir_ft2' => 'heating',
      'heat_eir_ft3' => 'heating',
      'heat_eir_ft4' => 'heating'
    }

    tables.each do |table|
      next unless table[:form] == 'BiQuadratic'
      next unless list_of_biquadratic_curves_to_check.key?(table[:name])

      mode = list_of_biquadratic_curves_to_check[table[:name]]

      case mode
      when 'cooling'
        puts("--- checking biquadratic cooling curve format: #{table[:name]}")
        max_oat = table[:maximum_independent_variable_2]
        max_iat = table[:maximum_independent_variable_1]

        assert(
          max_oat > max_iat,
          "Maximum OAT (#{max_oat}) for cooling curve seems to be lower than " \
          "Maximum IAT (#{max_iat}). Check curve (#{table[:name]}) or " \
          "mode classification in list_of_biquadratic_curves_to_check. File: #{file_path}"
        )

      when 'heating'
        puts("--- checking biquadratic heating curve format: #{table[:name]}")
        min_oat = table[:minimum_independent_variable_2]
        min_iat = table[:minimum_independent_variable_1]

        assert(
          min_oat < min_iat,
          "Minimum OAT (#{min_oat}) for heating curve seems to be higher than " \
          "Minimum IAT (#{min_iat}). Check curve (#{table[:name]}) or " \
          "mode classification in list_of_biquadratic_curves_to_check. File: #{file_path}"
        )
      end
    end
  end

  def test_biquadratic_format
    # This test ensures the format of biquadratic curves used in DX units
    test_name = 'test_biquadratic_format'
    puts "\n######\nTEST: #{test_name}\n######\n"

    path_to_jsons = "#{__dir__}/../resources/*.json"
    json_files = Dir.glob(path_to_jsons)

    json_files.each do |file_path|
      begin
        content = File.read(file_path)
        hash = JSON.parse(content, symbolize_names: true)

        assert(hash[:tables], "Missing :tables key in #{file_path}")

        # Check lookup table format
        biquadratic_format_check(hash, file_path)
      rescue JSON::ParserError => e
        flunk "JSON parsing failed for #{file_path}: #{e.message}"
      end
    end
  end

  def calc_cfm_per_ton_singlespdcoil_heating(model, cfm_per_ton_min, cfm_per_ton_max)
    # get relevant heating coils
    coils_heating = model.getCoilHeatingDXSingleSpeeds

    # check if there is at least one coil
    refute_equal(coils_heating.size, 0)

    # calc cfm/ton
    coils_heating.each do |heating_coil|
      # get coil specs
      if heating_coil.ratedTotalHeatingCapacity.is_initialized
        rated_capacity_w = heating_coil.ratedTotalHeatingCapacity.get
      end
      rated_airflow_m_3_per_sec = heating_coil.ratedAirFlowRate.get if heating_coil.ratedAirFlowRate.is_initialized

      # calc relevant metrics
      rated_capacity_ton = OpenStudio.convert(rated_capacity_w, 'W', 'ton').get
      rated_airflow_cfm = OpenStudio.convert(rated_airflow_m_3_per_sec, 'm^3/s', 'cfm').get
      cfm_per_ton = rated_airflow_cfm / rated_capacity_ton

      # check if resultant cfm/ton is violating min/max bounds
      assert_equal(cfm_per_ton.round(0) >= cfm_per_ton_min, true, "cfm_per_ton (#{cfm_per_ton}) is not larger than the threshold of cfm_per_ton_min (#{cfm_per_ton_min})")
      assert_equal(cfm_per_ton.round(0) <= cfm_per_ton_max, true, "cfm_per_ton (#{cfm_per_ton}) is not smaller than the threshold of cfm_per_ton_max (#{cfm_per_ton_max})")
    end
  end

  def calc_cfm_per_ton_multispdcoil_heating(model, cfm_per_ton_min, cfm_per_ton_max)
    # get relevant heating coils
    coils_heating = model.getCoilHeatingDXMultiSpeedStageDatas

    # check if there is at least one coil
    refute_equal(coils_heating.size, 0)

    # calc cfm/ton
    coils_heating.each do |heating_coil|
      # get coil specs
      if heating_coil.grossRatedHeatingCapacity.is_initialized
        rated_capacity_w = heating_coil.grossRatedHeatingCapacity.get
      end
      rated_airflow_m_3_per_sec = heating_coil.ratedAirFlowRate.get if heating_coil.ratedAirFlowRate.is_initialized

      # calc relevant metrics
      rated_capacity_ton = OpenStudio.convert(rated_capacity_w, 'W', 'ton').get
      rated_airflow_cfm = OpenStudio.convert(rated_airflow_m_3_per_sec, 'm^3/s', 'cfm').get
      cfm_per_ton = rated_airflow_cfm / rated_capacity_ton

      # check if resultant cfm/ton is violating min/max bounds
      assert_equal(cfm_per_ton.round(0) >= cfm_per_ton_min, true, "cfm_per_ton (#{cfm_per_ton}) is not larger than the threshold of cfm_per_ton_min (#{cfm_per_ton_min})")
      assert_equal(cfm_per_ton.round(0) <= cfm_per_ton_max, true, "cfm_per_ton (#{cfm_per_ton}) is not smaller than the threshold of cfm_per_ton_max (#{cfm_per_ton_max})")
    end
  end

  def calc_cfm_per_ton_multispdcoil_cooling(model, cfm_per_ton_min, cfm_per_ton_max)
    # get cooling coils
    coils_cooling = model.getCoilCoolingDXMultiSpeedStageDatas

    # check if there is at least one coil
    refute_equal(coils_cooling.size, 0)

    # calc cfm/ton
    coils_cooling.each do |cooling_coil|
      # get coil specs
      if cooling_coil.grossRatedTotalCoolingCapacity.is_initialized
        rated_capacity_w = cooling_coil.grossRatedTotalCoolingCapacity.get
      end
      rated_airflow_m_3_per_sec = cooling_coil.ratedAirFlowRate.get if cooling_coil.ratedAirFlowRate.is_initialized

      # calc relevant metrics
      rated_capacity_ton = OpenStudio.convert(rated_capacity_w, 'W', 'ton').get
      rated_airflow_cfm = OpenStudio.convert(rated_airflow_m_3_per_sec, 'm^3/s', 'cfm').get
      cfm_per_ton = rated_airflow_cfm / rated_capacity_ton

      # check if resultant cfm/ton is violating min/max bounds
      assert_equal(cfm_per_ton.round(0) >= cfm_per_ton_min, true, "cfm_per_ton (#{cfm_per_ton}) is not larger than the threshold of cfm_per_ton_min (#{cfm_per_ton_min})")
      assert_equal(cfm_per_ton.round(0) <= cfm_per_ton_max, true, "cfm_per_ton (#{cfm_per_ton}) is not smaller than the threshold of cfm_per_ton_max (#{cfm_per_ton_max})")
    end
  end

  def verify_cfm_per_ton(model, result)
    # define min and max limits of cfm/ton
    cfm_per_ton_min = 300
    cfm_per_ton_max = 450

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # initialize parameters
    performance_category = nil

    # check performance category
    result.stepValues.each do |input_arg|
      next unless input_arg.name == 'hprtu_scenario'

      performance_category = input_arg.valueAsString

      puts performance_category
    end
    refute_equal(performance_category, nil)

    # loop through coils and check cfm/ton values
    if performance_category.include?('high_eff')

      calc_cfm_per_ton_multispdcoil_cooling(model, cfm_per_ton_min, cfm_per_ton_max)
      calc_cfm_per_ton_multispdcoil_heating(model, cfm_per_ton_min, cfm_per_ton_max)

    elsif performance_category.include?('standard')

      calc_cfm_per_ton_multispdcoil_cooling(model, cfm_per_ton_min, cfm_per_ton_max)
      calc_cfm_per_ton_singlespdcoil_heating(model, cfm_per_ton_min, cfm_per_ton_max)

    end
  end

  def _mimic_hardsize_model(model, test_dir)
    standard = Standard.build('ComStock DOE Ref Pre-1980')

    # Run a sizing run to determine equipment capacities and flow rates
    if standard.model_run_sizing_run(model, test_dir.to_s) == false
      puts('Sizing run for Hardsize model failed, cannot hard-size model.')
      return false
    end

    # APPLY
    model.applySizingValues

    # TODO: remove once this functionality is added to the OpenStudio C++ for hard sizing UnitarySystems
    model.getAirLoopHVACUnitarySystems.each do |unitary|
      if model.version < OpenStudio::VersionString.new('3.7.0')
        unitary.setSupplyAirFlowRateMethodDuringCoolingOperation('SupplyAirFlowRate')
        unitary.setSupplyAirFlowRateMethodDuringHeatingOperation('SupplyAirFlowRate')
      else
        # unitary.applySizingValues
      end
    end
    # TODO: remove once this functionality is added to the OpenStudio C++ for hard sizing Sizing:System
    model.getSizingSystems.each do |sizing_system|
      next if sizing_system.isDesignOutdoorAirFlowRateAutosized

      sizing_system.setSystemOutdoorAirMethod('ZoneSum')
    end

    return model
  end

  # expect_gas_backup: set true when the measure is expected to create gas (dual fuel) backup coils
  # expected_lockout_temp_f: when given, asserts the compressor lockout temperature on each new DX heating coil
  def verify_hp_rtu(test_name, model, measure, argument_map, osm_path, epw_path, expect_gas_backup: false,
                    expected_lockout_temp_f: nil)
    # set weather file but not apply measure
    result = set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, apply: false)
    model = load_model(model_output_path(test_name))

    # hardsize model
    model = _mimic_hardsize_model(model, "#{run_dir(test_name)}/SR_before")

    # get initial gas heating coils
    li_gas_htg_coils_initial = model.getCoilHeatingGass

    # get initial number of applicable air loops
    li_unitary_sys_initial = model.getAirLoopHVACUnitarySystems

    # get initial unitary system schedules for outdoor air and general operation
    # these will be compared against applied HP-RTU system
    dict_oa_sched_min_initial = {}
    dict_min_oa_initial = {}
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      # get thermal zone for dictionary mapping
      thermal_zone = air_loop_hvac.thermalZones[0]

      # get OA schedule from OA controller
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      controller_oa = oa_system.getControllerOutdoorAir
      oa_schedule = controller_oa.minimumOutdoorAirSchedule.get
      dict_oa_sched_min_initial[thermal_zone.name.to_s] = oa_schedule

      # get min/max outdoor air flow rate
      min_oa = controller_oa.minimumOutdoorAirFlowRate.get
      max_oa = controller_oa.maximumOutdoorAirFlowRate.get
      dict_min_oa_initial[thermal_zone.name.to_s] = min_oa
    end

    # set weather file and apply measure
    result = set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    model = load_model(model_output_path(test_name))

    # hardsize model
    model = _mimic_hardsize_model(model, "#{run_dir(test_name)}/SR_after")

    # get final gas heating coils
    li_gas_htg_coils_final = model.getCoilHeatingGass

    # assert gas heating coils have been removed, unless gas backup heat was requested
    if expect_gas_backup
      assert(li_gas_htg_coils_final.size > 0,
             'expected gas backup heating coils to be present when backup heat matches an original gas heating fuel')
    else
      assert_equal(li_gas_htg_coils_final.size, 0)
    end

    # get list of final unitary systems
    li_unitary_sys_final = model.getAirLoopHVACUnitarySystems

    # assert same number of unitary systems as initial
    assert_equal(li_unitary_sys_initial.size, li_unitary_sys_final.size)

    # get final unitary system schedules for outdoor air and general operation
    # these will be compared against original system
    dict_oa_sched_min_final = {}
    dict_min_oa_final = {}
    dict_max_oa_final = {}
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      # get thermal zone for dictionary mapping
      thermal_zone = air_loop_hvac.thermalZones[0]

      # get OA schedule from OA controller
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      controller_oa = oa_system.getControllerOutdoorAir
      oa_schedule = controller_oa.minimumOutdoorAirSchedule.get
      dict_oa_sched_min_final[thermal_zone.name.to_s] = oa_schedule

      # get min/max outdoor air flow rate
      min_oa = controller_oa.minimumOutdoorAirFlowRate.get
      max_oa = controller_oa.maximumOutdoorAirFlowRate.get
      dict_min_oa_final[thermal_zone.name.to_s] = min_oa
    end

    # assert outdoor air values match between initial and new system
    model.getThermalZones.sort.each do |thermal_zone|
      assert_equal(dict_oa_sched_min_initial[thermal_zone.name.to_s], dict_oa_sched_min_final[thermal_zone.name.to_s])
      assert_in_epsilon(dict_min_oa_initial[thermal_zone.name.to_s].to_f, dict_min_oa_final[thermal_zone.name.to_s].to_f, 0.001)
    end

    # assert characteristics of new unitary systems
    li_unitary_sys_final.sort.each do |system|
      # assert new unitary systems all have variable speed fans
      fan = system.supplyFan.get
      assert(fan.to_FanVariableVolume.is_initialized)

      # ***heating***
      # assert new unitary systems all have multispeed DX heating coils
      htg_coil = system.heatingCoil.get
      assert(htg_coil.to_CoilHeatingDXMultiSpeed.is_initialized)
      htg_coil = htg_coil.to_CoilHeatingDXMultiSpeed.get

      # assert multispeed heating coil has 4 stages
      assert_equal(htg_coil.numberOfStages, 4)
      htg_coil_spd4 = htg_coil.stages[3]

      # assert speed 4 flowrate matches design flow rate
      htg_dsn_flowrate = system.supplyAirFlowRateDuringHeatingOperation
      assert_in_delta(htg_dsn_flowrate.to_f, htg_coil_spd4.ratedAirFlowRate.get, 0.000001)

      # assert flow rate reduces for lower speeds
      htg_coil_spd3 = htg_coil.stages[2]
      htg_coil_spd2 = htg_coil.stages[1]
      htg_coil_spd1 = htg_coil.stages[0]
      assert(htg_coil_spd4.ratedAirFlowRate.get > htg_coil_spd3.ratedAirFlowRate.get)
      assert(htg_coil_spd3.ratedAirFlowRate.get > htg_coil_spd2.ratedAirFlowRate.get)
      assert(htg_coil_spd2.ratedAirFlowRate.get > htg_coil_spd1.ratedAirFlowRate.get)

      # assert capacity reduces for lower speeds
      assert(htg_coil_spd4.grossRatedHeatingCapacity.get > htg_coil_spd3.grossRatedHeatingCapacity.get)
      assert(htg_coil_spd3.grossRatedHeatingCapacity.get > htg_coil_spd2.grossRatedHeatingCapacity.get)
      assert(htg_coil_spd2.grossRatedHeatingCapacity.get > htg_coil_spd1.grossRatedHeatingCapacity.get)

      # assert compressor lockout temperature matches the value expected for the backup heat type
      unless expected_lockout_temp_f.nil?
        expected_lockout_temp_c = OpenStudio.convert(expected_lockout_temp_f, 'F', 'C').get
        assert_in_delta(expected_lockout_temp_c,
                        htg_coil.minimumOutdoorDryBulbTemperatureforCompressorOperation, 0.01,
                        "compressor lockout temperature for #{system.name} does not match the expected #{expected_lockout_temp_f}F")
      end

      # assert supplemental heating coil type matches the user-specified backup heat type
      sup_htg_coil = system.supplementalHeatingCoil.get
      if expect_gas_backup
        assert(sup_htg_coil.to_CoilHeatingGas.is_initialized,
               "expected a gas backup heating coil for #{system.name}")
      else
        assert(sup_htg_coil.to_CoilHeatingElectric.is_initialized,
               "expected an electric resistance backup heating coil for #{system.name}")
      end

      # ***cooling***
      # assert new unitary systems all have multispeed DX cooling coils
      clg_coil = system.coolingCoil.get
      assert(clg_coil.to_CoilCoolingDXMultiSpeed.is_initialized)
      clg_coil = clg_coil.to_CoilCoolingDXMultiSpeed.get

      # assert multispeed heating coil has 4 stages
      assert_equal(clg_coil.numberOfStages, 4)
      clg_coil_spd4 = clg_coil.stages[3]

      # assert speed 4 flowrate matches design flow rate
      clg_dsn_flowrate = system.supplyAirFlowRateDuringCoolingOperation
      assert_in_delta(clg_dsn_flowrate.to_f, clg_coil_spd4.ratedAirFlowRate.get, 0.000001)

      # assert flow rate reduces for lower speeds
      clg_coil_spd3 = clg_coil.stages[2]
      clg_coil_spd2 = clg_coil.stages[1]
      clg_coil_spd1 = clg_coil.stages[0]
      assert(clg_coil_spd4.ratedAirFlowRate.get > clg_coil_spd3.ratedAirFlowRate.get)
      assert(clg_coil_spd3.ratedAirFlowRate.get > clg_coil_spd2.ratedAirFlowRate.get)
      assert(clg_coil_spd2.ratedAirFlowRate.get > clg_coil_spd1.ratedAirFlowRate.get)

      # assert capacity reduces for lower speeds
      assert(clg_coil_spd4.grossRatedTotalCoolingCapacity.get > clg_coil_spd3.grossRatedTotalCoolingCapacity.get)
      assert(clg_coil_spd3.grossRatedTotalCoolingCapacity.get > clg_coil_spd2.grossRatedTotalCoolingCapacity.get)
      assert(clg_coil_spd2.grossRatedTotalCoolingCapacity.get > clg_coil_spd1.grossRatedTotalCoolingCapacity.get)
    end
    result
  end

  def get_cooling_coil_capacity_and_cop(model, coil)
    capacity_w = 0.0
    coil_design_cop = 0.0

    if coil.to_CoilCoolingDXSingleSpeed.is_initialized
      coil = coil.to_CoilCoolingDXSingleSpeed.get

      # capacity
      if coil.ratedTotalCoolingCapacity.is_initialized
        capacity_w = coil.ratedTotalCoolingCapacity.get
      elsif coil.autosizedRatedTotalCoolingCapacity.is_initialized
        capacity_w = coil.autosizedRatedTotalCoolingCapacity.get
      else
        raise "Cooling coil capacity not available for coil '#{coil.name}'."
      end

      # cop
      if model.version > OpenStudio::VersionString.new('3.4.0')
        coil_design_cop = coil.ratedCOP
      else
        if coil.ratedCOP.is_initialized
          coil_design_cop = coil.ratedCOP.get
        else
          raise "'Rated COP' not available for DX coil '#{coil.name}'."
        end
      end
    elsif coil.to_CoilCoolingDXTwoSpeed.is_initialized
      coil = coil.to_CoilCoolingDXTwoSpeed.get

      # capacity
      if coil.ratedHighSpeedTotalCoolingCapacity.is_initialized
        capacity_w = coil.ratedHighSpeedTotalCoolingCapacity.get
      elsif coil.autosizedRatedHighSpeedTotalCoolingCapacity.is_initialized
        capacity_w = coil.autosizedRatedHighSpeedTotalCoolingCapacity.get
      else
        raise "Cooling coil capacity not available for coil '#{coil.name}'."
      end

      # cop, use high speed cop
      if model.version > OpenStudio::VersionString.new('3.4.0')
        coil_design_cop = coil.ratedHighSpeedCOP
      else
        if coil.ratedHighSpeedCOP.is_initialized
          coil_design_cop = coil.ratedHighSpeedCOP.get
        else
          raise "'Rated High Speed COP' not available for DX coil '#{coil.name}'."
        end
      end
    elsif coil.to_CoilCoolingDXMultiSpeed.is_initialized
      coil = coil.to_CoilCoolingDXMultiSpeed.get

      # capacity and cop, use cop at highest capacity
      temp_capacity_w = 0.0
      coil.stages.each do |stage|
        if stage.grossRatedTotalCoolingCapacity.is_initialized
          temp_capacity_w = stage.grossRatedTotalCoolingCapacity.get
        elsif stage.autosizedGrossRatedTotalCoolingCapacity.is_initialized
          temp_capacity_w = stage.autosizedGrossRatedTotalCoolingCapacity.get
        else
          raise "Cooling coil capacity not available for coil stage '#{stage.name}'."
        end

        # update cop if highest capacity
        temp_coil_design_cop = stage.grossRatedCoolingCOP
        coil_design_cop = temp_coil_design_cop if temp_capacity_w >= capacity_w

        # update if highest capacity
        capacity_w = temp_capacity_w if temp_capacity_w > capacity_w
      end
    elsif coil.to_CoilCoolingDXVariableSpeed.is_initialized
      coil = coil.to_CoilCoolingDXVariableSpeed.get

      # capacity and cop, use cop at highest capacity
      temp_capacity_w = 0.0
      coil.speeds.each do |speed|
        temp_capacity_w = speed.referenceUnitGrossRatedTotalCoolingCapacity

        # update cop if highest capacity
        temp_coil_design_cop = speed.referenceUnitGrossRatedCoolingCOP
        coil_design_cop = temp_coil_design_cop if temp_capacity_w >= capacity_w

        # update if highest capacity
        capacity_w = temp_capacity_w if temp_capacity_w > capacity_w
      end
    else
      raise 'Design capacity is only available for DX cooling coil types CoilCoolingDXSingleSpeed, CoilCoolingDXTwoSpeed, CoilCoolingDXMultiSpeed, CoilCoolingDXVariableSpeed.'
    end

    return capacity_w, coil_design_cop
  end

  def get_heating_coil_capacity_and_cop(model, coil)
    # get coil rated capacity and cop
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

      # get rated cop and cop at lower temperatures
      coil_design_cop = coil.ratedCOP
    elsif coil.to_CoilHeatingDXMultiSpeed.is_initialized
      coil = coil.to_CoilHeatingDXMultiSpeed.get
      temp_capacity_w = 0.0
      coil.stages.each do |stage|
        if stage.grossRatedHeatingCapacity.is_initialized
          temp_capacity_w = stage.grossRatedHeatingCapacity.get
        elsif stage.autosizedGrossRatedHeatingCapacity.is_initialized
          temp_capacity_w = stage.autosizedGrossRatedHeatingCapacity.get
        else
          raise "Heating coil capacity not available for coil stage '#{stage.name}'."
        end

        # get cop and cop at lower temperatures
        # pick cop at highest capacity
        temp_coil_design_cop = stage.grossRatedHeatingCOP
        coil_design_cop = temp_coil_design_cop if temp_capacity_w >= capacity_w

        # update if highest capacity
        capacity_w = temp_capacity_w if temp_capacity_w > capacity_w
      end
    elsif coil.to_CoilHeatingDXVariableSpeed.is_initialized
      coil = coil.to_CoilHeatingDXVariableSpeed.get
      coil.speeds.each do |speed|
        temp_capacity_w = speed.referenceUnitGrossRatedHeatingCapacity

        # get cop and cop at lower temperatures
        # pick cop at highest capacity
        temp_coil_design_cop = speed.referenceUnitGrossRatedHeatingCOP
        coil_design_cop = temp_coil_design_cop if temp_capacity_w >= capacity_w

        # update if highest capacity
        capacity_w = temp_capacity_w if temp_capacity_w > capacity_w
      end
    else
      raise 'Design COP and capacity for DX heating coil unavailable because of unrecognized coil type.'
    end

    return capacity_w, coil_design_cop
  end

  def get_sizing_summary(model)
    sizing_summary = {}
    sizing_summary['AirLoopHVACUnitarySystem'] = {}
    model.getAirLoopHVACUnitarySystems.each do |airloophvacunisys|
      name_obj = airloophvacunisys.name.to_s

      # get airflows
      sizing_summary['AirLoopHVACUnitarySystem'][name_obj] = {}
      sizing_summary['AirLoopHVACUnitarySystem'][name_obj]['supplyAirFlowRateDuringCoolingOperation'] = airloophvacunisys.supplyAirFlowRateDuringCoolingOperation.get
      sizing_summary['AirLoopHVACUnitarySystem'][name_obj]['supplyAirFlowRateDuringHeatingOperation'] = airloophvacunisys.supplyAirFlowRateDuringHeatingOperation.get

      # get coil capacity: cooling
      coil = airloophvacunisys.coolingCoil.get
      capacity_w, = get_cooling_coil_capacity_and_cop(model, coil)
      sizing_summary['AirLoopHVACUnitarySystem'][name_obj]['cooling_coil_capacity_w'] = capacity_w

      # get coil capacity: heating
      coil = airloophvacunisys.heatingCoil.get
      capacity_w, = get_heating_coil_capacity_and_cop(model, coil)
      sizing_summary['AirLoopHVACUnitarySystem'][name_obj]['heating_coil_capacity_w'] = capacity_w
    end
    sizing_summary['AirLoopHVAC'] = {}
    model.getAirLoopHVACs.each do |airloophvac|
      name_obj = airloophvac.name.to_s

      # get airflows
      sizing_summary['AirLoopHVAC'][name_obj] = {}
      sizing_summary['AirLoopHVAC'][name_obj]['designSupplyAirFlowRate'] = airloophvac.designSupplyAirFlowRate.get
    end
    sizing_summary['ControllerOutdoorAir'] = {}
    model.getControllerOutdoorAirs.each do |ctrloa|
      name_obj = ctrloa.name.to_s

      # get airflows
      sizing_summary['ControllerOutdoorAir'][name_obj] = {}
      sizing_summary['ControllerOutdoorAir'][name_obj]['maximumOutdoorAirFlowRate'] = ctrloa.maximumOutdoorAirFlowRate.get
    end
    sizing_summary
  end

  # this is checking parameters between regularly sized versus upsized model
  # but when upsizing does not make any impact on hotter region
  def check_sizing_results_no_upsizing(model, sizing_summary_reference)
    model.getAirLoopHVACUnitarySystems.each do |airloophvacunisys|
      name_obj = airloophvacunisys.name.to_s

      # check airflow: cooling
      value_before = sizing_summary_reference['AirLoopHVACUnitarySystem'][name_obj]['supplyAirFlowRateDuringCoolingOperation']
      value_after = airloophvacunisys.supplyAirFlowRateDuringCoolingOperation.get
      assert_in_epsilon(value_before, value_after, 0.000001, "values do not match: AirLoopHVACUnitarySystem | #{name_obj} | supplyAirFlowRateDuringCoolingOperation")

      # check airflow: heating
      value_before = sizing_summary_reference['AirLoopHVACUnitarySystem'][name_obj]['supplyAirFlowRateDuringHeatingOperation']
      value_after = airloophvacunisys.supplyAirFlowRateDuringHeatingOperation.get
      assert_in_epsilon(value_before, value_after, 0.000001, "values do not match: AirLoopHVACUnitarySystem | #{name_obj} | supplyAirFlowRateDuringHeatingOperation")

      # check capacity: cooling
      coil = airloophvacunisys.coolingCoil.get
      value_before = sizing_summary_reference['AirLoopHVACUnitarySystem'][name_obj]['cooling_coil_capacity_w']
      value_after, = get_cooling_coil_capacity_and_cop(model, coil)
      assert_in_epsilon(value_before, value_after, 0.000001, "values do not match: AirLoopHVACUnitarySystem | #{name_obj} | cooling_coil_capacity_w")

      # check capacity: heating
      coil = airloophvacunisys.heatingCoil.get
      value_before = sizing_summary_reference['AirLoopHVACUnitarySystem'][name_obj]['heating_coil_capacity_w']
      value_after, = get_heating_coil_capacity_and_cop(model, coil)
      assert_in_epsilon(value_before, value_after, 0.000001, "values do not match: AirLoopHVACUnitarySystem | #{name_obj} | heating_coil_capacity_w")
    end
    model.getAirLoopHVACs.each do |airloophvac|
      name_obj = airloophvac.name.to_s

      # check airflow
      value_before = sizing_summary_reference['AirLoopHVAC'][name_obj]['designSupplyAirFlowRate']
      value_after = airloophvac.designSupplyAirFlowRate.get
      assert_in_epsilon(value_before, value_after, 0.000001, "values do not match: AirLoopHVAC | #{name_obj} | designSupplyAirFlowRate")
    end
    model.getControllerOutdoorAirs.each do |ctrloa|
      name_obj = ctrloa.name.to_s

      # check airflow
      value_before = sizing_summary_reference['ControllerOutdoorAir'][name_obj]['maximumOutdoorAirFlowRate']
      value_after = ctrloa.maximumOutdoorAirFlowRate.get
      assert_in_epsilon(value_before, value_after, 0.000001, "values do not match: ControllerOutdoorAir | #{name_obj} | maximumOutdoorAirFlowRate")
    end
  end

  # this is checking parameters between regularly sized versus upsized model
  # and when upsizing does make an impact on colder region
  def check_sizing_results_upsizing(model, sizing_summary_reference)
    model.getAirLoopHVACUnitarySystems.each do |airloophvacunisys|
      name_obj = airloophvacunisys.name.to_s

      # check capacity: cooling
      coil = airloophvacunisys.coolingCoil.get
      value_before = sizing_summary_reference['AirLoopHVACUnitarySystem'][name_obj]['cooling_coil_capacity_w']
      value_after, = get_cooling_coil_capacity_and_cop(model, coil)
      relative_difference = (value_after - value_before) / value_before
      assert_in_epsilon(relative_difference, 0.25, 0.01, "values difference not close to threshold: AirLoopHVACUnitarySystem | #{name_obj} | cooling_coil_capacity_w")

      # check capacity: heating
      coil = airloophvacunisys.heatingCoil.get
      value_before = sizing_summary_reference['AirLoopHVACUnitarySystem'][name_obj]['heating_coil_capacity_w']
      value_after, = get_heating_coil_capacity_and_cop(model, coil)
      relative_difference = (value_after - value_before) / value_before
      assert_in_epsilon(relative_difference, 0.25, 0.01, "values difference not close to threshold: AirLoopHVACUnitarySystem | #{name_obj} | heating_coil_capacity_w")
    end
    model.getAirLoopHVACs.each do |airloophvac|
      name_obj = airloophvac.name.to_s

      # check airflow
      value_before = sizing_summary_reference['AirLoopHVAC'][name_obj]['designSupplyAirFlowRate']
      value_after = airloophvac.designSupplyAirFlowRate.get
      assert_in_epsilon(value_after, value_before, 0.01, "values difference not within threshold: AirLoopHVAC | #{name_obj} | designSupplyAirFlowRate")
    end
    model.getControllerOutdoorAirs.each do |ctrloa|
      name_obj = ctrloa.name.to_s

      # check airflow
      value_before = sizing_summary_reference['ControllerOutdoorAir'][name_obj]['maximumOutdoorAirFlowRate']
      value_after = ctrloa.maximumOutdoorAirFlowRate.get
      assert_in_epsilon(value_after, value_before, 0.01, "values difference not within threshold: AirLoopHVAC | #{name_obj} | maximumOutdoorAirFlowRate")
    end
  end

  def calc_cfm_per_ton_singlespdcoil_heating(model, cfm_per_ton_min, cfm_per_ton_max)
    # get relevant heating coils
    coils_heating = model.getCoilHeatingDXSingleSpeeds

    # check if there is at least one coil
    refute_equal(coils_heating.size, 0)

    # calc cfm/ton
    coils_heating.each do |heating_coil|
      # get coil specs
      if heating_coil.ratedTotalHeatingCapacity.is_initialized
        rated_capacity_w = heating_coil.ratedTotalHeatingCapacity.get
      end
      rated_airflow_m_3_per_sec = heating_coil.ratedAirFlowRate.get if heating_coil.ratedAirFlowRate.is_initialized

      # calc relevant metrics
      rated_capacity_ton = OpenStudio.convert(rated_capacity_w, 'W', 'ton').get
      rated_airflow_cfm = OpenStudio.convert(rated_airflow_m_3_per_sec, 'm^3/s', 'cfm').get
      cfm_per_ton = rated_airflow_cfm / rated_capacity_ton

      # check if resultant cfm/ton is violating min/max bounds
      assert_equal(cfm_per_ton.round(0) >= cfm_per_ton_min, true, "cfm_per_ton (#{cfm_per_ton}) is not larger than the threshold of cfm_per_ton_min (#{cfm_per_ton_min}) | heating_coil = #{heating_coil.name}")
      assert_equal(cfm_per_ton.round(0) <= cfm_per_ton_max, true, "cfm_per_ton (#{cfm_per_ton}) is not smaller than the threshold of cfm_per_ton_max (#{cfm_per_ton_max}) | heating_coil = #{heating_coil.name}")
    end
  end

  def calc_cfm_per_ton_multispdcoil_heating(model, cfm_per_ton_min, cfm_per_ton_max)
    # get relevant heating coils
    coils_heating = model.getCoilHeatingDXMultiSpeedStageDatas

    # check if there is at least one coil
    refute_equal(coils_heating.size, 0)

    # calc cfm/ton
    coils_heating.each do |heating_coil|
      # get coil specs
      if heating_coil.grossRatedHeatingCapacity.is_initialized
        rated_capacity_w = heating_coil.grossRatedHeatingCapacity.get
      end
      rated_airflow_m_3_per_sec = heating_coil.ratedAirFlowRate.get if heating_coil.ratedAirFlowRate.is_initialized

      # calc relevant metrics
      rated_capacity_ton = OpenStudio.convert(rated_capacity_w, 'W', 'ton').get
      rated_airflow_cfm = OpenStudio.convert(rated_airflow_m_3_per_sec, 'm^3/s', 'cfm').get
      cfm_per_ton = rated_airflow_cfm / rated_capacity_ton

      # check if resultant cfm/ton is violating min/max bounds
      assert_equal(cfm_per_ton.round(0) >= cfm_per_ton_min, true, "cfm_per_ton (#{cfm_per_ton}) is not larger than the threshold of cfm_per_ton_min (#{cfm_per_ton_min}) | heating_coil = #{heating_coil.name}")
      assert_equal(cfm_per_ton.round(0) <= cfm_per_ton_max, true, "cfm_per_ton (#{cfm_per_ton}) is not smaller than the threshold of cfm_per_ton_max (#{cfm_per_ton_max}) | heating_coil = #{heating_coil.name}")
    end
  end

  def calc_cfm_per_ton_multispdcoil_cooling(model, cfm_per_ton_min, cfm_per_ton_max)
    # get cooling coils
    coils_cooling = model.getCoilCoolingDXMultiSpeedStageDatas

    # check if there is at least one coil
    refute_equal(coils_cooling.size, 0)

    # calc cfm/ton
    coils_cooling.each do |cooling_coil|
      # get coil specs
      if cooling_coil.grossRatedTotalCoolingCapacity.is_initialized
        rated_capacity_w = cooling_coil.grossRatedTotalCoolingCapacity.get
      end
      rated_airflow_m_3_per_sec = cooling_coil.ratedAirFlowRate.get if cooling_coil.ratedAirFlowRate.is_initialized

      # calc relevant metrics
      rated_capacity_ton = OpenStudio.convert(rated_capacity_w, 'W', 'ton').get
      rated_airflow_cfm = OpenStudio.convert(rated_airflow_m_3_per_sec, 'm^3/s', 'cfm').get
      cfm_per_ton = rated_airflow_cfm / rated_capacity_ton

      # check if resultant cfm/ton is violating min/max bounds
      assert_equal(cfm_per_ton.round(0) >= cfm_per_ton_min, true, "cfm_per_ton (#{cfm_per_ton}) is not larger than the threshold of cfm_per_ton_min (#{cfm_per_ton_min}) | cooling_coil = #{cooling_coil.name}")
      assert_equal(cfm_per_ton.round(0) <= cfm_per_ton_max, true, "cfm_per_ton (#{cfm_per_ton}) is not smaller than the threshold of cfm_per_ton_max (#{cfm_per_ton_max}) | cooling_coil = #{cooling_coil.name}")
    end
  end

  def verify_cfm_per_ton(model, result)
    # define min and max limits of cfm/ton
    cfm_per_ton_min = 300
    cfm_per_ton_max = 450

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # initialize parameters
    performance_category = nil

    # check performance category
    result.stepValues.each do |input_arg|
      next unless input_arg.name == 'hprtu_scenario'

      performance_category = input_arg.valueAsString

      puts performance_category
    end
    refute_equal(performance_category, nil)

    # loop through coils and check cfm/ton values
    if performance_category.include?('high_eff')

      calc_cfm_per_ton_multispdcoil_cooling(model, cfm_per_ton_min, cfm_per_ton_max)
      calc_cfm_per_ton_multispdcoil_heating(model, cfm_per_ton_min, cfm_per_ton_max)

    elsif performance_category.include?('standard')

      calc_cfm_per_ton_multispdcoil_cooling(model, cfm_per_ton_min, cfm_per_ton_max)
      calc_cfm_per_ton_singlespdcoil_heating(model, cfm_per_ton_min, cfm_per_ton_max)

    end
  end

  # ##########################################################################
  # # Single building result examples
  # def test_single_building_result_examples
  #   osm_epw_pair = {
  #     # '380_Small_Office_psz_gas_1zone_not_hard_sized.osm' => 'USA_AK_Fairbanks.Intl.AP.702610_TMY3.epw',
  #     '380_Small_Office_psz_gas_1zone_not_hard_sized.osm' => 'USA_GA_Atlanta-Hartsfield-Jackson.Intl.AP.722190_TMY3.epw',
  #     # '380_Small_Office_psz_gas_1zone_not_hard_sized.osm' => 'USA_HI_Honolulu.Intl.AP.911820_TMY3.epw',
  #   }

  #   test_name = 'test_single_building_result_examples'

  #   puts "\n######\nTEST:#{test_name}\n######\n"

  #   osm_epw_pair.each_with_index do |(osm_name, epw_name), idx_run|

  #     osm_path = model_input_path(osm_name)
  #     epw_path = epw_input_path(epw_name)

  #     # Create an instance of the measure
  #     measure = AddHeatPumpRtu.new

  #     # Load the model; only used here for populating arguments
  #     model = load_model(osm_path)

  #     # get arguments
  #     arguments = measure.arguments(model)
  #     argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

  #     # populate specific argument for testing
  #     arguments.each_with_index do |arg, idx|
  #       temp_arg_var = arg.clone
  #       case arg.name
  #       when 'sizing_run'
  #         sizing_run = arguments[idx].clone
  #         sizing_run.setValue(true)
  #         argument_map[arg.name] = sizing_run
  #       when 'hprtu_scenario'
  #         hprtu_scenario = arguments[idx].clone
  #         hprtu_scenario.setValue('two_speed_standard_eff') # variable_speed_high_eff, two_speed_standard_eff
  #         argument_map[arg.name] = hprtu_scenario
  #       when 'performance_oversizing_factor'
  #         performance_oversizing_factor = arguments[idx].clone
  #         performance_oversizing_factor.setValue(0.0)
  #         argument_map[arg.name] = performance_oversizing_factor
  #       when 'window'
  #         window = arguments[idx].clone
  #         window.setValue(true)
  #         argument_map[arg.name] = window
  #       when 'debug_verbose'
  #         debug_verbose = arguments[idx].clone
  #         debug_verbose.setValue(true)
  #         argument_map[arg.name] = debug_verbose
  #       else
  #         argument_map[arg.name] = temp_arg_var
  #       end
  #     end

  #     # Don't apply the measure to the model and run the model
  #     result = set_weather_and_apply_measure_and_run("#{test_name}_#{idx_run}_b", measure, argument_map, osm_path, epw_path, run_model: true, apply: false)
  #     model = load_model(model_output_path("#{test_name}_#{idx_run}_b"))

  #     # Apply the measure to the model and run the model
  #     result = set_weather_and_apply_measure_and_run("#{test_name}_#{idx_run}_u", measure, argument_map, osm_path, epw_path, run_model: true, apply: true)
  #     model = load_model(model_output_path("#{test_name}_#{idx_run}_u"))

  #   end
  # end

  # ##########################################################################
  # This section tests upsizing algorithm
  # tests compare:
  # 1) regularly sized model versus upsized model in cold region
  # 2) regularly sized model versus upsized model in hot region
  def test_sizing_model_in_alaska
    osm_name = 'small_office_psz_not_hard_sized.osm'
    epw_name = 'USA_AK_Fairbanks.Intl.AP.702610_TMY3.epw'

    test_name = 'test_sizing_model_in_alaska'

    lookup_table_test = {
      'table_name': 'c_cap_high_T',
      'ind1': 22.22,
      'ind2': 29.44,
      'dep': 1.1677
    }

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate specific argument for testing
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      case arg.name
      when 'sizing_run'
        sizing_run = arguments[idx].clone
        sizing_run.setValue(true)
        argument_map[arg.name] = sizing_run
      when 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('two_speed_standard_eff') # variable_speed_high_eff, two_speed_standard_eff
        argument_map[arg.name] = hprtu_scenario
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # populate specific argument for testing: regular sizing scenario
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'performance_oversizing_factor'
        performance_oversizing_factor = arguments[idx].clone
        performance_oversizing_factor.setValue(0.0)
        argument_map[arg.name] = performance_oversizing_factor
      end
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run("#{test_name}_b", measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    model = load_model(model_output_path("#{test_name}_b"))

    # get sizing info from regular sized model
    sizing_summary_reference = get_sizing_summary(model)

    # populate specific argument for testing: upsizing scenario
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'performance_oversizing_factor'
        performance_oversizing_factor = arguments[idx].clone
        performance_oversizing_factor.setValue(0.25)
        argument_map[arg.name] = performance_oversizing_factor
      end
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run("#{test_name}_a", measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    model = load_model(model_output_path("#{test_name}_a"))

    # check performance category
    performance_category = nil
    result.stepValues.each do |input_arg|
      next unless input_arg.name == 'hprtu_scenario'
      performance_category = input_arg.valueAsString
    end

    # test lookup table values
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    if performance_category == 'two_speed_standard_eff'
      # Check if lookup table is available
      lookup_table_name = lookup_table_test[:table_name]
      #table_multivar_lookups = model.getTableMultiVariableLookups
      table_multivar_lookups = model.getTableLookups
      lookup_table = table_multivar_lookups.find { |table| table.name.to_s == lookup_table_name }
      refute_nil(lookup_table, "Cannot find table named #{lookup_table_name} from model.")

      # Compare table lookup value against hard-coded values
      dep_var_ref = lookup_table_test[:dep]
      dep_var = AddHeatPumpRtu.get_dep_var_from_lookup_table_with_interpolation(runner, lookup_table, lookup_table_test[:ind1], lookup_table_test[:ind2])
      # puts("### lookup table test")
      # puts("--- lookup_table_name = #{lookup_table_name}")
      # puts("--- input_var1 = #{lookup_table_test[:ind1]} | input_var2 = #{lookup_table_test[:ind2]}")
      # puts("--- dep_var reference = #{dep_var_ref} | dep_var from model = #{dep_var}")
      assert_in_epsilon(dep_var_ref, dep_var, 0.001, "Table lookup value test didn't pass: table name = #{lookup_table_name} | ind_var1 = #{lookup_table_test[:ind1]} | ind_var2 = #{lookup_table_test[:ind2]} | expected #{dep_var_ref} but got #{dep_var}")
    end

    # compare sizing summary of upsizing model with regular sized model
    check_sizing_results_upsizing(model, sizing_summary_reference)
  end

  def test_sizing_model_in_hawaii
    osm_name = 'small_office_psz_not_hard_sized.osm'
    epw_name = 'USA_HI_Honolulu.Intl.AP.911820_TMY3.epw'

    test_name = 'test_sizing_model_in_hawaii'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate specific argument for testing
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      case arg.name
      when 'sizing_run'
        sizing_run = arguments[idx].clone
        sizing_run.setValue(true)
        argument_map[arg.name] = sizing_run
      when 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff') # variable_speed_high_eff, two_speed_standard_eff
        argument_map[arg.name] = hprtu_scenario
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # populate specific argument for testing: regular sizing scenario
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'performance_oversizing_factor'
        performance_oversizing_factor = arguments[idx].clone
        performance_oversizing_factor.setValue(0.0)
        argument_map[arg.name] = performance_oversizing_factor
      end
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run("#{test_name}_b", measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    model = load_model(model_output_path("#{test_name}_b"))

    # get sizing info from regular sized model
    sizing_summary_reference = get_sizing_summary(model)

    # populate specific argument for testing: upsizing scenario
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'performance_oversizing_factor'
        performance_oversizing_factor = arguments[idx].clone
        performance_oversizing_factor.setValue(0.25)
        argument_map[arg.name] = performance_oversizing_factor
      end
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run("#{test_name}_a", measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    model = load_model(model_output_path("#{test_name}_a"))

    # compare sizing summary of upsizing model with regular sized model
    check_sizing_results_no_upsizing(model, sizing_summary_reference)
  end

  # ##########################################################################
  # This section tests proper application of measure on fully applicable models
  # tests include:
  # 1) running model to ensure succesful completion
  # 2) checking user-specified electric backup heating is applied
  # 3) checking that all gas heating couls have been removed from model
  # 4) all air loops contain multispeed heating coil
  # 5) coil speeds capacities and flow rates are ascending
  # 6) coil speeds fall within E+ specified cfm/ton ranges
  # 7) check roof/window measure related variables are saved or not saved in model

  def test_380_Small_Office_PSZ_Gas_2A
    osm_name = '380_Small_Office_PSZ_Gas_2A.osm'
    epw_name = 'SC_Columbia_Metro_723100_12.epw'

    test_name = 'test_380_Small_Office_PSZ_Gas_2A'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff') # override std_perf arg
        argument_map[arg.name] = hprtu_scenario
      elsif arg.name == 'roof'
        roof = arguments[idx].clone
        roof.setValue(true)
        argument_map[arg.name] = roof
      elsif arg.name == 'window'
        window = arguments[idx].clone
        window.setValue(true)
        argument_map[arg.name] = window
      else
        argument_map[arg.name] = temp_arg_var
      end
    end
    test_result = verify_hp_rtu(test_name, model, measure, argument_map, osm_path, epw_path)
    
    # check roof/window measure implementation
    roof_measure_implemented = false
    window_measure_implemented = false
    test_result = JSON.parse(test_result.to_s)
    test_result['step_values'].each do |step_value|

      # check if roof measure variable is available
      if step_value['name'] == 'env_roof_insul_roof_area_ft_2'
        roof_measure_implemented = true
      end

      # check if window measure variable is available
      if step_value['name'] == 'env_secondary_window_fen_area_ft_2'
        window_measure_implemented = true
      end

    end
    assert_equal(roof_measure_implemented, true, "cannot find variable that was saved in roof upgrade measure via registerValue: env_roof_insul_roof_area_ft_2")
    assert_equal(window_measure_implemented, true, "cannot find variable that was saved in window upgrade measure via registerValue: env_secondary_window_fen_area_ft_2")
  end

  def test_380_small_office_psz_gas_coil_7A
    osm_name = '380_small_office_psz_gas_coil_7A.osm'
    epw_name = 'NE_Kearney_Muni_725526_16.epw'

    test_name = 'test_380_small_office_psz_gas_coil_7A'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff') # override std_perf arg
        argument_map[arg.name] = hprtu_scenario
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    test_result = verify_hp_rtu(test_name, model, measure, argument_map, osm_path, epw_path)

    # check roof/window measure implementation
    roof_measure_implemented = false
    window_measure_implemented = false
    test_result = JSON.parse(test_result.to_s)
    test_result['step_values'].each do |step_value|

      # check if roof measure variable is available
      if step_value['name'] == 'env_roof_insul_roof_area_ft_2'
        roof_measure_implemented = true
      end

      # check if window measure variable is available
      if step_value['name'] == 'env_secondary_window_fen_area_ft_2'
        window_measure_implemented = true
      end

    end
    assert_equal(roof_measure_implemented, false, "cannot find variable that was saved in roof upgrade measure via registerValue: env_roof_insul_roof_area_ft_2")
    assert_equal(window_measure_implemented, false, "cannot find variable that was saved in window upgrade measure via registerValue: env_secondary_window_fen_area_ft_2")
  end

  # Verifies the dual fuel compressor lockout temperature is applied when the backup heating coil
  # ends up being a gas furnace. The electric backup lockout is deliberately set to a different
  # value so this test fails if the wrong argument is used.
  def test_gas_backup_lockout_7A
    osm_name = '380_small_office_psz_gas_coil_7A.osm'
    epw_name = 'NE_Kearney_Muni_725526_16.epw'

    test_name = 'test_gas_backup_lockout_7A'

    puts "
######
TEST:#{osm_name}
######
"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # a non-default gas backup lockout is used to confirm the argument is actually read
    elec_backup_lockout_temp_f = 0.0
    gas_backup_lockout_temp_f = 30.0

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff') # override std_perf arg
        argument_map[arg.name] = hprtu_scenario
      elsif arg.name == 'backup_ht_fuel_scheme'
        backup_ht_fuel_scheme = arguments[idx].clone
        backup_ht_fuel_scheme.setValue('match_original_primary_heating_fuel')
        argument_map[arg.name] = backup_ht_fuel_scheme
      elsif arg.name == 'hp_min_comp_lockout_temp_elec_backup_f'
        hp_min_comp_lockout_temp_elec_backup_f = arguments[idx].clone
        hp_min_comp_lockout_temp_elec_backup_f.setValue(elec_backup_lockout_temp_f)
        argument_map[arg.name] = hp_min_comp_lockout_temp_elec_backup_f
      elsif arg.name == 'hp_min_comp_lockout_temp_gas_backup_f'
        hp_min_comp_lockout_temp_gas_backup_f = arguments[idx].clone
        hp_min_comp_lockout_temp_gas_backup_f.setValue(gas_backup_lockout_temp_f)
        argument_map[arg.name] = hp_min_comp_lockout_temp_gas_backup_f
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # the original model heats with gas, so matching the original fuel gives gas backup coils
    # and the compressor should lock out at the gas backup temperature
    verify_hp_rtu(test_name, model, measure, argument_map, osm_path, epw_path, expect_gas_backup: true,
                                                                               expected_lockout_temp_f: gas_backup_lockout_temp_f)
  end

  # Verifies the gas backup lockout temperature is ignored when the backup heating coil is electric
  # resistance, even though the original model heats with gas.
  def test_elec_backup_lockout_7A
    osm_name = '380_small_office_psz_gas_coil_7A.osm'
    epw_name = 'NE_Kearney_Muni_725526_16.epw'

    test_name = 'test_elec_backup_lockout_7A'

    puts "
######
TEST:#{osm_name}
######
"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    elec_backup_lockout_temp_f = 0.0
    gas_backup_lockout_temp_f = 30.0

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff') # override std_perf arg
        argument_map[arg.name] = hprtu_scenario
      elsif arg.name == 'backup_ht_fuel_scheme'
        backup_ht_fuel_scheme = arguments[idx].clone
        backup_ht_fuel_scheme.setValue('electric_resistance_backup')
        argument_map[arg.name] = backup_ht_fuel_scheme
      elsif arg.name == 'hp_min_comp_lockout_temp_elec_backup_f'
        hp_min_comp_lockout_temp_elec_backup_f = arguments[idx].clone
        hp_min_comp_lockout_temp_elec_backup_f.setValue(elec_backup_lockout_temp_f)
        argument_map[arg.name] = hp_min_comp_lockout_temp_elec_backup_f
      elsif arg.name == 'hp_min_comp_lockout_temp_gas_backup_f'
        hp_min_comp_lockout_temp_gas_backup_f = arguments[idx].clone
        hp_min_comp_lockout_temp_gas_backup_f.setValue(gas_backup_lockout_temp_f)
        argument_map[arg.name] = hp_min_comp_lockout_temp_gas_backup_f
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # electric resistance backup was requested, so the electric lockout temperature applies
    verify_hp_rtu(test_name, model, measure, argument_map, osm_path, epw_path, expect_gas_backup: false,
                                                                               expected_lockout_temp_f: elec_backup_lockout_temp_f)
  end

  def test_small_office_psz_not_hard_sized
    osm_name = 'small_office_psz_not_hard_sized.osm'
    epw_name = 'USA_AK_Fairbanks.Intl.AP.702610_TMY3.epw'

    test_name = 'test_small_office_psz_not_hard_sized'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff')
        argument_map[arg.name] = hprtu_scenario
      elsif arg.name == 'roof'
        roof = arguments[idx].clone
        roof.setValue(true)
        argument_map[arg.name] = roof
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    test_result = verify_hp_rtu(test_name, model, measure, argument_map, osm_path, epw_path)

    # check roof/window measure implementation
    roof_measure_implemented = false
    window_measure_implemented = false
    test_result = JSON.parse(test_result.to_s)
    test_result['step_values'].each do |step_value|

      # check if roof measure variable is available
      if step_value['name'] == 'env_roof_insul_roof_area_ft_2'
        roof_measure_implemented = true
      end

      # check if window measure variable is available
      if step_value['name'] == 'env_secondary_window_fen_area_ft_2'
        window_measure_implemented = true
      end

    end
    assert_equal(roof_measure_implemented, true, "cannot find variable that was saved in roof upgrade measure via registerValue: env_roof_insul_roof_area_ft_2")
    assert_equal(window_measure_implemented, false, "cannot find variable that was saved in window upgrade measure via registerValue: env_secondary_window_fen_area_ft_2")
  end

  def test_380_retail_psz_gas_6B
    osm_name = '380_retail_psz_gas_6B.osm'
    epw_name = 'NE_Kearney_Muni_725526_16.epw'

    test_name = 'test_380_retail_psz_gas_6B'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff') # override std_perf arg
        argument_map[arg.name] = hprtu_scenario
      elsif arg.name == 'window'
        window = arguments[idx].clone
        window.setValue(true)
        argument_map[arg.name] = window
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    test_result = verify_hp_rtu(test_name, model, measure, argument_map, osm_path, epw_path)

    # check roof/window measure implementation
    roof_measure_implemented = false
    window_measure_implemented = false
    test_result = JSON.parse(test_result.to_s)
    test_result['step_values'].each do |step_value|

      # check if roof measure variable is available
      if step_value['name'] == 'env_roof_insul_roof_area_ft_2'
        roof_measure_implemented = true
      end

      # check if window measure variable is available
      if step_value['name'] == 'env_secondary_window_fen_area_ft_2'
        window_measure_implemented = true
      end

    end
    assert_equal(roof_measure_implemented, false, "cannot find variable that was saved in roof upgrade measure via registerValue: env_roof_insul_roof_area_ft_2")
    assert_equal(window_measure_implemented, true, "cannot find variable that was saved in window upgrade measure via registerValue: env_secondary_window_fen_area_ft_2")
  end

  ##########################################################################
  # This section tests proper classification of partially-applicable building types
  def test_380_full_service_restaurant_psz_gas_coil
    osm_name = '380_full_service_restaurant_psz_gas_coil.osm'
    epw_name = 'GA_ROBINS_AFB_722175_12.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff') # override std_perf arg
        argument_map[arg.name] = hprtu_scenario
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # get initial number of applicable air loops
    li_unitary_sys_initial = model.getAirLoopHVACUnitarySystems

    # determine air loops with/without kitchens
    tz_kitchens = []
    kitchen_htg_coils = []
    tz_all_other = []
    nonkitchen_htg_coils = []
    model.getAirLoopHVACUnitarySystems.sort.each do |unitary_sys|
      # skip kitchen spaces
      thermal_zone_names_to_exclude = ['Kitchen', 'kitchen', 'KITCHEN']
      if thermal_zone_names_to_exclude.any? { |word| (unitary_sys.name.to_s).include?(word) }
        tz_kitchens << unitary_sys

        # add kitchen heating coil to list
        kitchen_htg_coils << unitary_sys.heatingCoil.get

        next
      end

      # add non kitchen zone and heating coil to list
      tz_all_other << unitary_sys
      # add kitchen heating coil to list
      nonkitchen_htg_coils << unitary_sys.heatingCoil.get
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))

    # get heating coils from final model for kitchen and non kitchen spaces
    tz_kitchens_final = []
    kitchen_htg_coils_final = []
    tz_all_other_final = []
    nonkitchen_htg_coils_final = []
    model.getAirLoopHVACUnitarySystems.sort.each do |unitary_sys|
      # skip kitchen spaces
      thermal_zone_names_to_exclude = ['Kitchen', 'kitchen', 'KITCHEN']
      if thermal_zone_names_to_exclude.any? { |word| (unitary_sys.name.to_s).include?(word) }
        tz_kitchens_final << unitary_sys

        # add kitchen heating coil to list
        kitchen_htg_coils_final << unitary_sys.heatingCoil.get

        next
      end

      # add non kitchen zone and heating coil to list
      tz_all_other_final << unitary_sys
      # add kitchen heating coil to list
      nonkitchen_htg_coils_final << unitary_sys.heatingCoil.get
    end

    # assert no changes to kitchen unitary systems
    assert_equal(tz_kitchens_final, tz_kitchens)

    # assert non kitchen spaces contain multispeed DX heating coils
    nonkitchen_htg_coils_final.each do |htg_coil|
      assert(htg_coil.to_CoilHeatingDXMultiSpeed.is_initialized)
    end

    # assert kitchen spaces still contain gas coils
    kitchen_htg_coils_final.each do |htg_coil|
      assert(htg_coil.to_CoilHeatingGas.is_initialized)
    end

    # assert cfm/ton violation
    verify_cfm_per_ton(model, result)
  end

  ###########################################################################
  # This test is for cfm/ton check for standard performance unit
  def test_380_full_service_restaurant_psz_gas_coil_std_perf
    osm_name = '380_full_service_restaurant_psz_gas_coil.osm'
    epw_name = 'GA_ROBINS_AFB_722175_12.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    lookup_table_test = {
      'table_name': 'h_cap_T',
      'ind1': 21.11,
      'ind2': -17.78,
      'dep': 0.3974
    }

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('two_speed_standard_eff') # override std_perf arg
        argument_map[arg.name] = hprtu_scenario
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))

    # check performance category
    performance_category = nil
    result.stepValues.each do |input_arg|
      next unless input_arg.name == 'hprtu_scenario'
      performance_category = input_arg.valueAsString
    end

    # test lookup table values
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    if performance_category == 'two_speed_standard_eff'
      # Check if lookup table is available
      lookup_table_name = lookup_table_test[:table_name]
      #table_multivar_lookups = model.getTableMultiVariableLookups
      table_multivar_lookups = model.getTableLookups
      lookup_table = table_multivar_lookups.find { |table| table.name.to_s == lookup_table_name }
      refute_nil(lookup_table, "Cannot find table named #{lookup_table_name} from model.")

      # Compare table lookup value against hard-coded values
      dep_var_ref = lookup_table_test[:dep]
      dep_var = AddHeatPumpRtu.get_dep_var_from_lookup_table_with_interpolation(runner, lookup_table, lookup_table_test[:ind1], lookup_table_test[:ind2])
      # puts("### lookup table test")
      # puts("--- lookup_table_name = #{lookup_table_name}")
      # puts("--- input_var1 = #{lookup_table_test[:ind1]} | input_var2 = #{lookup_table_test[:ind2]}")
      # puts("--- dep_var reference = #{dep_var_ref} | dep_var from model = #{dep_var}")
      assert_in_epsilon(dep_var_ref, dep_var, 0.001, "Table lookup value test didn't pass: table name = #{lookup_table_name} | ind_var1 = #{lookup_table_test[:ind1]} | ind_var2 = #{lookup_table_test[:ind2]} | expected #{dep_var_ref} but got #{dep_var}")
    end

    # assert cfm/ton violation
    verify_cfm_per_ton(model, result)
  end

  ###########################################################################
  # This test is for cfm/ton check for upsized unit
  def test_380_full_service_restaurant_psz_gas_coil_upsizing
    osm_name = '380_full_service_restaurant_psz_gas_coil.osm'
    epw_name = 'GA_ROBINS_AFB_722175_12.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # get arguments
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      case arg.name
      when 'sizing_run'
        sizing_run = arguments[idx].clone
        sizing_run.setValue(false)
        argument_map[arg.name] = sizing_run
      when 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff') # variable_speed_high_eff, two_speed_standard_eff
        argument_map[arg.name] = hprtu_scenario
      when 'performance_oversizing_factor'
        performance_oversizing_factor = arguments[idx].clone
        performance_oversizing_factor.setValue(0.25) # override performance_oversizing_factor arg
        argument_map[arg.name] = performance_oversizing_factor
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))

    # assert cfm/ton violation
    verify_cfm_per_ton(model, result)
  end

  def test_380_small_office_psz_gas_coil_7A_upsizing_adv
    osm_name = '380_small_office_psz_gas_coil_7A.osm'
    epw_name = 'USA_AK_Fairbanks.Intl.AP.702610_TMY3.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate specific argument for testing
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      case arg.name
      when 'sizing_run'
        sizing_run = arguments[idx].clone
        sizing_run.setValue(true)
        argument_map[arg.name] = sizing_run
      when 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff') # variable_speed_high_eff, two_speed_standard_eff
        argument_map[arg.name] = hprtu_scenario
      when 'debug_verbose'
        debug_verbose = arguments[idx].clone
        debug_verbose.setValue(true)
        argument_map[arg.name] = debug_verbose
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # populate specific argument for testing: regular sizing scenario
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'performance_oversizing_factor'
        performance_oversizing_factor = arguments[idx].clone
        performance_oversizing_factor.setValue(0.25)
        argument_map[arg.name] = performance_oversizing_factor
      end
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))

    verify_cfm_per_ton(model, result)
  end

  def test_380_small_office_psz_gas_coil_7A_upsizing_std
    osm_name = '380_small_office_psz_gas_coil_7A.osm'
    epw_name = 'USA_AK_Fairbanks.Intl.AP.702610_TMY3.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    lookup_table_test = {
      'table_name': 'c_eir_high_T',
      'ind1': 22.22,
      'ind2': 35.0,
      'dep': 0.9438
    }

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate specific argument for testing
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      case arg.name
      when 'sizing_run'
        sizing_run = arguments[idx].clone
        sizing_run.setValue(true)
        argument_map[arg.name] = sizing_run
      when 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('two_speed_standard_eff') # variable_speed_high_eff, two_speed_standard_eff
        argument_map[arg.name] = hprtu_scenario
      when 'debug_verbose'
        debug_verbose = arguments[idx].clone
        debug_verbose.setValue(true)
        argument_map[arg.name] = debug_verbose
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # populate specific argument for testing: regular sizing scenario
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'performance_oversizing_factor'
        performance_oversizing_factor = arguments[idx].clone
        performance_oversizing_factor.setValue(0.25)
        argument_map[arg.name] = performance_oversizing_factor
      end
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))

    # check performance category
    performance_category = nil
    result.stepValues.each do |input_arg|
      next unless input_arg.name == 'hprtu_scenario'
      performance_category = input_arg.valueAsString
    end

    # test lookup table values
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    if performance_category == 'two_speed_standard_eff'
      # Check if lookup table is available
      lookup_table_name = lookup_table_test[:table_name]
      #table_multivar_lookups = model.getTableMultiVariableLookups
      table_multivar_lookups = model.getTableLookups
      lookup_table = table_multivar_lookups.find { |table| table.name.to_s == lookup_table_name }
      refute_nil(lookup_table, "Cannot find table named #{lookup_table_name} from model.")

      # Compare table lookup value against hard-coded values
      dep_var_ref = lookup_table_test[:dep]
      dep_var = AddHeatPumpRtu.get_dep_var_from_lookup_table_with_interpolation(runner, lookup_table, lookup_table_test[:ind1], lookup_table_test[:ind2])
      # puts("### lookup table test")
      # puts("--- lookup_table_name = #{lookup_table_name}")
      # puts("--- input_var1 = #{lookup_table_test[:ind1]} | input_var2 = #{lookup_table_test[:ind2]}")
      # puts("--- dep_var reference = #{dep_var_ref} | dep_var from model = #{dep_var}")
      assert_in_epsilon(dep_var_ref, dep_var, 0.001, "Table lookup value test didn't pass: table name = #{lookup_table_name} | ind_var1 = #{lookup_table_test[:ind1]} | ind_var2 = #{lookup_table_test[:ind2]} | expected #{dep_var_ref} but got #{dep_var}")
    end

    verify_cfm_per_ton(model, result)
  end

  ###########################################################################
  # This section tests proper classification of non applicable HVAC systems
  # assert that non applicable HVAC system registers as NA
  def test_380_StripMall_Residential_AC_with_residential_forced_air_furnace_2A
    # this makes sure measure registers an na for non applicable model
    osm_name = '380_StripMall_Residential AC with residential forced air furnace_2A.osm'
    epw_name = 'TN_KNOXVILLE_723260_12.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      argument_map[arg.name] = temp_arg_var
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false, apply: true, expected_results: 'NA')
  end

  # assert that non applicable HVAC system registers as NA
  def test_380_warehouse_pvav_gas_boiler_reheat_2A
    # this makes sure measure registers an na for non applicable model
    osm_name = '380_warehouse_pvav_gas_boiler_reheat_2A.osm'
    epw_name = 'TN_KNOXVILLE_723260_12.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff') # override std_perf arg
        argument_map[arg.name] = hprtu_scenario
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false, apply: true, expected_results: 'NA')
  end

  # assert that non applicable HVAC system registers as NA
  def test_380_medium_office_doas_fan_coil_acc_boiler_3A
    # this makes sure measure registers an na for non applicable model
    osm_name = '380_medium_office_doas_fan_coil_acc_boiler_3A.osm'
    epw_name = 'TN_KNOXVILLE_723260_12.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff') # override std_perf arg
        argument_map[arg.name] = hprtu_scenario
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false, apply: true, expected_results: 'NA')
  end

  # test that ERVs do no impact existing ERVs when ERV argument is NOT toggled
  def test_380_full_service_restaurant_psz_gas_coil_single_erv_3A
    # this makes sure measure registers an na for non applicable model
    osm_name = '380_full_service_restaurant_psz_gas_coil_single_erv_3A.osm'
    epw_name = 'SC_Columbia_Metro_723100_12.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff') # override std_perf arg
        argument_map[arg.name] = hprtu_scenario
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # get baseline ERVs
    ervs_baseline = model.getHeatExchangerAirToAirSensibleAndLatents

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    model = load_model(model_output_path(__method__))

    # assert no difference in ERVs in upgrade model
    ervs_upgrade = model.getHeatExchangerAirToAirSensibleAndLatents
    assert_equal(ervs_baseline, ervs_upgrade)
  end

  # test that ERVs do no impact non-applicable building types
  def test_380_full_service_restaurant_psz_gas_coil_single_erv_3A_na
    # this makes sure measure registers an na for non applicable model
    osm_name = '380_full_service_restaurant_psz_gas_coil_single_erv_3A.osm'
    epw_name = 'SC_Columbia_Metro_723100_12.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hprtu_scenario'
        hprtu_scenario = arguments[idx].clone
        hprtu_scenario.setValue('variable_speed_high_eff') # override std_perf arg
        argument_map[arg.name] = hprtu_scenario
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # get baseline ERVs
    ervs_baseline = model.getHeatExchangerAirToAirSensibleAndLatents

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false, apply: true)
    model = load_model(model_output_path(__method__))

    # assert no difference in ERVs in upgrade model
    ervs_upgrade = model.getHeatExchangerAirToAirSensibleAndLatents
    assert_equal(ervs_baseline, ervs_upgrade)
  end

  def test_confirm_heating_setback_change_square_wave
    # confirm that any heating setbacks are now 2F
    osm_name = 'Retail_PSZ-AC.osm'
    epw_name = 'NE_Kearney_Muni_725526_16.epw'

    test_name = 'confirm_heating_setback_change_square_wave'

    puts "\n######\nTEST:#{test_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    setback_val = 2.0
    setback_value_c = setback_val * 5 / 9

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'setback_value'
        setback_value_arg = arguments[idx].clone
        setback_value_arg.setValue(setback_val) # set setback value
        argument_map[arg.name] = setback_value_arg
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # run the measure
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path,
                                                   run_model: false)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))

    schedule_deltas = [] # keep track of differences between min and max values in schedules


    # Loop thru zones and look at temp setbacks
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      puts "loop class #{air_loop_hvac.class}"
      zones = air_loop_hvac.thermalZones


      zones.sort.each do |thermal_zone|
        next unless thermal_zone.thermostatSetpointDualSetpoint.is_initialized

        zone_thermostat = thermal_zone.thermostatSetpointDualSetpoint.get
        htg_schedule = zone_thermostat.heatingSetpointTemperatureSchedule
        if htg_schedule.empty?
          puts("Heating setpoint schedule not found for zone '#{zone.name.get}'")
          next
        elsif htg_schedule.get.to_ScheduleRuleset.empty?
          puts("Schedule '#{htg_schedule.get.name.get}' is not a ScheduleRuleset, will not be adjusted")
          next
        else
          htg_schedule = htg_schedule.get.to_ScheduleRuleset.get
        end
        profiles = [htg_schedule.defaultDaySchedule]
        htg_schedule.scheduleRules.each { |rule| profiles << rule.daySchedule }
        profiles.sort.each do |tstat_profile|
          tstat_profile.values.uniq.size
          tstat_profile_min = tstat_profile.values.min
          tstat_profile_max = tstat_profile.values.max
          schedule_deltas << tstat_profile_max - tstat_profile_min # assuming that any changes in the schedule during the day represent nighttime setbacks
        end
      end
    end

    # Make sure no deltas are greater than the expected setback value
    deltas_out_of_range = schedule_deltas.any? { |x| x > setback_value_c }
	
	puts("Temperature deltas in schedule match expected values: #{(deltas_out_of_range == false)}")

    assert_equal(deltas_out_of_range, false)
	
    true
  end

  def test_confirm_heating_setback_change_opt_start
    # confirm that any heating setbacks are now 2F
    osm_name = 'Retail_PSZ-AC_updated_39_opt_start.osm'
    epw_name = 'NE_Kearney_Muni_725526_16.epw'

    test_name = 'confirm_heating_setback_change_opt_start'

    puts "\n######\nTEST:#{test_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AddHeatPumpRtu.new

    # Load the model
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    setback_val = 2.0
    setback_value_c = setback_val * 5 / 9

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'setback_value'
        setback_value_arg = arguments[idx].clone
        setback_value_arg.setValue(setback_val) # set setback value
        argument_map[arg.name] = setback_value_arg
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # run the measure
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path,
                                                   run_model: false)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))


    schedule_deltas = [] # keep track of differences between min and max values in schedules


    # Loop thru zones and look at temp setbacks
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      zones = air_loop_hvac.thermalZones


      zones.sort.each do |thermal_zone|
        next unless thermal_zone.thermostatSetpointDualSetpoint.is_initialized

        zone_thermostat = thermal_zone.thermostatSetpointDualSetpoint.get
        htg_schedule = zone_thermostat.heatingSetpointTemperatureSchedule
        if htg_schedule.empty?
          puts("Heating setpoint schedule not found for zone '#{zone.name.get}'")
          next
        elsif htg_schedule.get.to_ScheduleRuleset.empty?
          puts("Schedule '#{htg_schedule.get.name.get}' is not a ScheduleRuleset, will not be adjusted")
          next
        else
          htg_schedule = htg_schedule.get.to_ScheduleRuleset.get
        end
        profiles = [htg_schedule.defaultDaySchedule]
        htg_schedule.scheduleRules.each { |rule| profiles << rule.daySchedule }
        profiles.sort.each do |tstat_profile|
          working_profile = tstat_profile.values.dup
          tstat_profile_min = tstat_profile.values.min
          tstat_profile.values.max
          tstat_profile.values.each_with_index do |value, i| # find minimum except for values during opt start
            # test values for optimum start (need to be at least the third timestep in the profile to test)
            if i > 3 && possible_opt_start(i, tstat_profile, tstat_profile_min) # identify if the time step could have been part of an optimum start
              working_profile.delete(value)
            end
          end
          tstat_profile_min_adj = working_profile.min
          tstat_profile_max_adj = working_profile.max
          schedule_deltas << tstat_profile_max_adj - tstat_profile_min_adj # assuming that any changes in the schedule during the day represent nighttime setbacks
        end
      end
    end

    # Make sure no deltas are greater than the expected setback value
    deltas_out_of_range = schedule_deltas.any? { |x| x > setback_value_c }
	
	
    puts("Temperature deltas in schedule match expected values: #{(deltas_out_of_range == false)}")

    assert_equal(deltas_out_of_range, false)
	
    true
  end

  # ===========================================================================
  # Supply fan representation and backup fuel type
  #
  # These cover behaviour that used to be shared across every hprtu_scenario:
  # one variable-speed part-load curve and one flat fan efficiency, and a backup
  # coil that was always natural gas. Each assertion below pins a value to the
  # source it comes from, so a future edit that collapses the scenarios back
  # together, or that reintroduces a literal, fails here.
  # ===========================================================================

  # Scenario performance json holding each scenario's fan_data record. The fan
  # curve and impeller efficiency live there, next to the compressor data, so
  # these tests assert the measure applies what the json says rather than
  # restating the coefficients - restating them here would just duplicate the
  # literals the json exists to replace.
  SCENARIO_PERFORMANCE_JSON = {
    'two_speed_standard_eff' => 'performance_maps_hprtu_std.json',
    'two_speed_lab_data' => 'performance_maps_hprtu_lab_data.json',
    'variable_speed_high_eff' => 'performance_maps_hprtu_variable_speed.json',
    'cchpc_2027_spec' => 'performance_map_CCHP_spec_2027.json'
  }.freeze

  def fan_data_for(scenario)
    path = File.join(File.dirname(__FILE__), '../resources', SCENARIO_PERFORMANCE_JSON.fetch(scenario))
    json = JSON.parse(File.read(path))
    json['tables']['curves']['table'].find { |e| e['name'] == 'fan_data' }
  end

  # The turndown the scenario json specifies, read before any cfm/ton adjustment.
  # The measure clamps the fan power minimum flow fraction at this value, so the
  # tests read it from the same place rather than restating a literal that could
  # drift from the json.
  def specified_min_flow_fraction_for(scenario)
    path = File.join(File.dirname(__FILE__), '../resources', SCENARIO_PERFORMANCE_JSON.fetch(scenario))
    json = JSON.parse(File.read(path))
    rec = json['tables']['curves']['table'].find { |e| e.key?('stage_flow_fractions_heating') }
    return nil if rec.nil?

    fracs = eval(rec['stage_flow_fractions_heating']).values +
            eval(rec['stage_flow_fractions_cooling']).values
    fracs.select { |v| v.is_a?(Numeric) && v > 0 }.min
  end

  # 90.1-2019 enclosed 4-pole nominal full-load motor efficiencies. Total fan
  # efficiency must be an impeller efficiency times one of these.
  ASHRAE_MOTOR_EFFICIENCIES = [0.855, 0.865, 0.895, 0.917, 0.924, 0.93, 0.936, 0.941, 0.95, 0.954, 0.958].freeze

  # Applies the measure for one scenario and returns the supply fans it created.
  def apply_and_get_supply_fans(test_name, osm_name, epw_name, scenario, extra_args: {})
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    args = { 'hprtu_scenario' => scenario }.merge(extra_args)
    arguments.each_with_index do |arg, idx|
      if args.key?(arg.name)
        cloned = arguments[idx].clone
        cloned.setValue(args[arg.name])
        argument_map[arg.name] = cloned
      else
        argument_map[arg.name] = arg.clone
      end
    end

    set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path,
                                          run_model: false, apply: true)
    applied = load_model(model_output_path(test_name))
    fans = applied.getAirLoopHVACUnitarySystems.map do |us|
      next nil unless us.supplyFan.is_initialized

      f = us.supplyFan.get
      f.to_FanVariableVolume.is_initialized ? f.to_FanVariableVolume.get : nil
    end.compact
    [applied, fans]
  end

  # OpenStudio returns some fan getters as plain Floats and some as Optionals
  # depending on version; unwrap either.
  def _optval(v)
    return nil if v.nil?
    return v if v.is_a?(Numeric)

    v.respond_to?(:is_initialized) ? (v.is_initialized ? v.get : nil) : v
  end

  def assert_fan_coefficients(fan, expected, label)
    actual = [fan.fanPowerCoefficient1, fan.fanPowerCoefficient2, fan.fanPowerCoefficient3,
              fan.fanPowerCoefficient4, fan.fanPowerCoefficient5].map { |c| _optval(c) || 0.0 }
    expected.each_with_index do |exp, i|
      assert_in_delta(exp, actual[i], 1e-6,
                      "#{label}: fan power coefficient #{i + 1} is #{actual[i]}, expected #{exp}")
    end
    # The curve must return design power at design flow, or the fan is mis-scaled.
    full_flow_power = actual.each_with_index.sum { |c, i| c * (1.0**i) }
    assert_in_delta(1.0, full_flow_power, 0.01,
                    "#{label}: part-load curve returns #{full_flow_power.round(4)} at full flow, expected 1.0")
  end

  # Total efficiency must be an impeller efficiency times a real 90.1 motor
  # efficiency, not a literal.
  def assert_efficiency_from_standards(fan, expected_impeller, label)
    total = fan.fanEfficiency
    motor = fan.motorEfficiency
    assert(ASHRAE_MOTOR_EFFICIENCIES.any? { |m| (m - motor).abs < 1e-6 },
           "#{label}: motor efficiency #{motor} is not a 90.1 table value")
    assert_in_delta(expected_impeller * motor, total, 1e-6,
                    "#{label}: total efficiency #{total} is not impeller #{expected_impeller} x motor #{motor}")
  end

  # Data-only check of the fan_data records themselves. Runs in milliseconds - no
  # model, no sizing run - so a bad curve in a json is caught immediately rather
  # than after a fifteen minute measure application.
  def test_fan_data_records_are_present_and_sane
    puts "
######
TEST:test_fan_data_records_are_present_and_sane
######
"
    SCENARIO_PERFORMANCE_JSON.each_key do |scenario|
      fd = fan_data_for(scenario)
      refute_nil(fd, "#{scenario}: no fan_data record in its performance json")

      assert(%w[two_speed variable_speed].include?(fd['fan_type']),
             "#{scenario}: fan_type #{fd['fan_type'].inspect} is not a recognised type")

      coeffs = fd['fan_power_coefficients']
      assert_equal(5, coeffs.size, "#{scenario}: expected 5 fan power coefficients")
      coeffs.each { |c| assert_kind_of(Numeric, c, "#{scenario}: non-numeric fan power coefficient") }

      # The curve must return design power at design flow or the fan is mis-scaled.
      full = coeffs.each_with_index.sum { |c, i| c * (1.0**i) }
      assert_in_delta(1.0, full, 0.01,
                      "#{scenario}: part-load curve gives #{full.round(4)} at full flow, expected 1.0")

      # Power must not exceed design anywhere in the operating range, and must
      # increase with flow - a curve that dips is a fitting error.
      prev = nil
      (20..100).step(5) do |pct|
        x = pct / 100.0
        pwr = coeffs.each_with_index.sum { |c, i| c * (x**i) }
        assert(pwr <= 1.02, "#{scenario}: power #{pwr.round(3)} exceeds design at flow #{x}")
        assert(pwr >= -0.01, "#{scenario}: negative power #{pwr.round(3)} at flow #{x}")
        assert(prev.nil? || pwr >= prev - 1e-6,
               "#{scenario}: power decreases between flow #{(x - 0.05).round(2)} and #{x}")
        prev = pwr
      end

      imp = fd['impeller_efficiency']
      assert(imp.is_a?(Numeric) && imp > 0.4 && imp < 0.85,
             "#{scenario}: impeller efficiency #{imp.inspect} is outside a plausible range")

      # Each value should carry its provenance, so a reviewer can trace it.
      refute_empty(fd['fan_power_coefficients_notes'].to_s,
                   "#{scenario}: fan_power_coefficients has no source note")
      refute_empty(fd['impeller_efficiency_notes'].to_s,
                   "#{scenario}: impeller_efficiency has no source note")
    end

    # A two-speed unit must not be given the variable-speed curve. Compare at the
    # 90.1 low-speed point, where the two representations differ most.
    two = fan_data_for('two_speed_standard_eff')['fan_power_coefficients']
    var = fan_data_for('variable_speed_high_eff')['fan_power_coefficients']
    at = ->(c, x) { c.each_with_index.sum { |k, i| k * (x**i) } }
    assert(at.call(two, 0.66) > at.call(var, 0.66) + 0.05,
           'two-speed and variable-speed fan curves are too close; they may have been collapsed')

    # 90.1 6.5.3.2.1 caps two-speed low-speed power at 40% of full-speed power.
    assert_in_delta(0.401, at.call(two, 0.66), 0.01,
                    'two-speed curve does not land on the 90.1 low-speed power point at 0.66 flow')
  end

  # Two-speed units cannot modulate continuously. The fan floor must come from the
  # lowest stage flow fraction in the scenario's staging data (0.59 in cooling),
  # or the outdoor air ratio when that is higher.
  def test_fan_two_speed_standard_eff
    test_name = 'test_fan_two_speed_standard_eff'
    puts "\n######\nTEST:#{test_name}\n######\n"
    _model, fans = apply_and_get_supply_fans(test_name, '380_small_office_psz_gas_coil_7A.osm',
                                             'NE_Kearney_Muni_725526_16.epw', 'two_speed_standard_eff')
    refute_empty(fans, 'no variable volume supply fans were created')

    fans.each do |fan|
      label = "two_speed_standard_eff #{fan.name}"
      assert_fan_coefficients(fan, fan_data_for('two_speed_standard_eff')['fan_power_coefficients'], label)
      assert_efficiency_from_standards(fan, fan_data_for('two_speed_standard_eff')['impeller_efficiency'], label)

      min_flow = _optval(fan.fanPowerMinimumFlowFraction)
      # The floor must be at least the turndown the json specifies (0.59 here).
      # adjust_cfm_per_ton_per_limits can push the realised lowest stage below that
      # to keep cfm/ton inside EnergyPlus's operating range - it moved this one to
      # 0.50 - but that guard is not a statement about how far the equipment turns
      # down, so the measure clamps the fan power curve back to the specified point.
      specified = specified_min_flow_fraction_for('two_speed_standard_eff')
      assert_in_delta(0.59, specified, 1e-6,
                      "the two-speed staging json should specify a 0.59 lowest stage, got #{specified}")
      assert(min_flow >= specified - 1e-6,
             "#{label}: minimum flow fraction #{min_flow.round(4)} is below the specified "              "turndown #{specified}; the cfm/ton guard must not lower the fan's claimed turndown")
      assert(min_flow <= 1.0 + 1e-6, "#{label}: minimum flow fraction #{min_flow.round(4)} exceeds 1.0")

      # power at the low stage should land on the 90.1 code point, not below it
      coeffs = fan_data_for('two_speed_standard_eff')['fan_power_coefficients']
      power_at_low = coeffs.each_with_index.sum { |c, i| c * (0.66**i) }
      assert_in_delta(0.401, power_at_low, 0.005,
                      "#{label}: power at 0.66 flow is #{power_at_low.round(4)}, expected the 90.1 point 0.401")
    end
  end

  # Variable-speed units get the 90.1 Single Zone VAV curve and can turn down to
  # the 0.40 lowest stage flow in their staging data.
  def test_fan_variable_speed_high_eff
    test_name = 'test_fan_variable_speed_high_eff'
    puts "\n######\nTEST:#{test_name}\n######\n"
    _model, fans = apply_and_get_supply_fans(test_name, '380_small_office_psz_gas_coil_7A.osm',
                                             'NE_Kearney_Muni_725526_16.epw', 'variable_speed_high_eff')
    refute_empty(fans, 'no variable volume supply fans were created')

    fans.each do |fan|
      label = "variable_speed_high_eff #{fan.name}"
      assert_fan_coefficients(fan, fan_data_for('variable_speed_high_eff')['fan_power_coefficients'], label)
      assert_efficiency_from_standards(fan, fan_data_for('variable_speed_high_eff')['impeller_efficiency'], label)

      min_flow = _optval(fan.fanPowerMinimumFlowFraction)
      # Same clamp as the two-speed case. On a one-zone small office the cfm/ton
      # guard moved heating stage 1 from 0.40 to 0.28, and fan power at 0.28 flow is
      # roughly half that at 0.40, so without the clamp this scenario would be
      # credited turndown it was never specified to have.
      specified = specified_min_flow_fraction_for('variable_speed_high_eff')
      assert_in_delta(0.40, specified, 1e-6,
                      "the variable-speed staging json should specify a 0.40 lowest stage, got #{specified}")
      assert(min_flow >= specified - 1e-6,
             "#{label}: minimum flow fraction #{min_flow.round(4)} is below the specified "              "turndown #{specified}; the cfm/ton guard must not lower the fan's claimed turndown")
      assert(min_flow <= 1.0 + 1e-6, "#{label}: minimum flow fraction #{min_flow.round(4)} exceeds 1.0")

      # The variable-speed advantage must come from the part-load curve, not from an
      # efficiency uplift: the impeller is deliberately held at the openstudio-standards
      # value for every scenario, so at design flow all these fans draw the same power.
      vs_coeffs = fan_data_for('variable_speed_high_eff')['fan_power_coefficients']
      ts_coeffs = fan_data_for('two_speed_standard_eff')['fan_power_coefficients']
      at = ->(c, x) { c.each_with_index.sum { |k, i| k * (x**i) } }
      assert(at.call(vs_coeffs, 0.5) < at.call(ts_coeffs, 0.5) - 0.02,
             "#{label}: variable-speed power at half flow #{at.call(vs_coeffs, 0.5).round(4)} is not "              "meaningfully below two-speed #{at.call(ts_coeffs, 0.5).round(4)}")
    end
  end

  # Regression guard: the two scenarios must not share a fan representation. This
  # is what was wrong before - one curve and one efficiency for every scenario.
  def test_fan_scenarios_are_differentiated
    puts "\n######\nTEST:test_fan_scenarios_are_differentiated\n######\n"
    _m1, two_speed = apply_and_get_supply_fans('test_fan_diff_two_speed',
                                               '380_small_office_psz_gas_coil_7A.osm',
                                               'NE_Kearney_Muni_725526_16.epw', 'two_speed_standard_eff')
    _m2, var_speed = apply_and_get_supply_fans('test_fan_diff_var_speed',
                                               '380_small_office_psz_gas_coil_7A.osm',
                                               'NE_Kearney_Muni_725526_16.epw', 'variable_speed_high_eff')
    refute_empty(two_speed)
    refute_empty(var_speed)

    ts = two_speed.first
    vs = var_speed.first
    refute_in_delta(_optval(ts.fanPowerCoefficient4), _optval(vs.fanPowerCoefficient4), 1e-6,
                    'two-speed and variable-speed scenarios share a part-load curve')
    # Deliberately EQUAL, not better. openstudio-standards does not distinguish fan
    # types, and no source was found for a higher impeller on a variable-speed wheel,
    # so the scenarios share one impeller and the advantage rests on the curve and the
    # turndown floor. If someone reintroduces an unsourced efficiency uplift, this fails.
    assert_in_delta(ts.fanEfficiency, vs.fanEfficiency, 1e-6,
                    "the scenarios should share an impeller efficiency; two-speed "                     "#{ts.fanEfficiency} vs variable-speed #{vs.fanEfficiency}")
    assert(_optval(vs.fanPowerMinimumFlowFraction) <= _optval(ts.fanPowerMinimumFlowFraction) + 1e-6,
           'variable speed should turn down at least as far as two-speed')

    # static pressure is a property of the duct system, not the equipment, and
    # must be identical between scenarios and unchanged from the original fan
    assert_in_delta(ts.pressureRise, vs.pressureRise, 1e-6,
                    'static pressure should not differ between scenarios')
  end

  # A dual-fuel backup coil must burn the building's original fuel. Fuel oil and
  # propane coils are CoilHeatingGas objects distinguished only by a fuelType
  # field, so they were previously all rebuilt as natural gas.
  def test_backup_coil_matches_original_fuel
    puts "\n######\nTEST:test_backup_coil_matches_original_fuel\n######\n"
    %w[FuelOilNo2 Propane NaturalGas].each do |fuel|
      test_name = "test_backup_fuel_#{fuel}"
      osm_path = model_input_path('380_small_office_psz_gas_coil_7A.osm')
      epw_path = epw_input_path('NE_Kearney_Muni_725526_16.epw')

      # restate the original model as burning this fuel
      model = load_model(osm_path)
      coils = model.getCoilHeatingGass
      refute_empty(coils, 'test model has no gas heating coils to relabel')
      coils.each { |c| c.setFuelType(fuel) }

      measure = AddHeatPumpRtu.new
      arguments = measure.arguments(model)
      argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
      args = { 'hprtu_scenario' => 'two_speed_standard_eff',
               'backup_ht_fuel_scheme' => 'match_original_primary_heating_fuel' }
      arguments.each_with_index do |arg, idx|
        if args.key?(arg.name)
          cloned = arguments[idx].clone
          cloned.setValue(args[arg.name])
          argument_map[arg.name] = cloned
        else
          argument_map[arg.name] = arg.clone
        end
      end

      set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path,
                                            run_model: false, apply: true, model: model)
      applied = load_model(model_output_path(test_name))
      backup_coils = applied.getCoilHeatingGass
      refute_empty(backup_coils, "no backup gas-type coil was created for original fuel #{fuel}")
      backup_coils.each do |c|
        assert_equal(fuel, c.fuelType,
                     "backup coil #{c.name} burns #{c.fuelType} but the original equipment burned #{fuel}")
      end
    end
  end

  # Verifies dual fuel backup is always a natural gas coil, regardless of the original heating fuel,
  # and that the gas backup compressor lockout temperature is used.
  def test_dual_fuel_backup_is_natural_gas
    puts "\n######\nTEST:test_dual_fuel_backup_is_natural_gas\n######\n"
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
      arguments = measure.arguments(model)
      argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
      args = { 'hprtu_scenario' => 'two_speed_standard_eff',
               'backup_ht_fuel_scheme' => 'dual_fuel_gas_furnace_backup',
               'hp_min_comp_lockout_temp_elec_backup_f' => 0.0,
               'hp_min_comp_lockout_temp_gas_backup_f' => gas_backup_lockout_temp_f }
      arguments.each_with_index do |arg, idx|
        if args.key?(arg.name)
          cloned = arguments[idx].clone
          cloned.setValue(args[arg.name])
          argument_map[arg.name] = cloned
        else
          argument_map[arg.name] = arg.clone
        end
      end

      set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path,
                                            run_model: false, apply: true, model: model)
      applied = load_model(model_output_path(test_name))
      unitary_systems = applied.getAirLoopHVACUnitarySystems
      refute_empty(unitary_systems, "no unitary systems after applying dual fuel to #{c[:name]} model")
      expected_lockout_temp_c = OpenStudio.convert(gas_backup_lockout_temp_f, 'F', 'C').get
      unitary_systems.each do |system|
        sup_htg_coil = system.supplementalHeatingCoil.get
        assert(sup_htg_coil.to_CoilHeatingGas.is_initialized,
               "expected a gas backup coil for #{system.name} (original fuel #{c[:name]})")
        assert_equal('NaturalGas', sup_htg_coil.to_CoilHeatingGas.get.fuelType,
                     "dual fuel backup coil for #{system.name} should burn natural gas (original fuel #{c[:name]})")

        htg_coil = system.heatingCoil.get
        htg_coil = htg_coil.to_CoilHeatingDXMultiSpeed.is_initialized ? htg_coil.to_CoilHeatingDXMultiSpeed.get : htg_coil.to_CoilHeatingDXSingleSpeed.get
        assert_in_delta(expected_lockout_temp_c, htg_coil.minimumOutdoorDryBulbTemperatureforCompressorOperation, 0.01,
                        "dual fuel compressor lockout for #{system.name} should use the gas backup temperature")
      end
    end
  end
  # Reads one hvac_add_heat_pump_rtu row from the options lookup and returns its measure arguments
  # as a name => value string hash, so a test can apply exactly what a ComStock run would.
  def options_lookup_args_for(option_name)
    path = File.join(File.dirname(__FILE__), '../../../options_lookup.tsv')
    row = File.readlines(path, chomp: true).map { |l| l.split("\t") }.find do |cols|
      cols[0] == 'hvac_add_heat_pump_rtu' && cols[1] == option_name
    end
    refute_nil(row, "options lookup has no hvac_add_heat_pump_rtu row named #{option_name}")
    assert_equal('upgrade_hvac_add_heat_pump_rtu', row[2], "#{option_name} points to the wrong measure")
    row[3..].reject(&:empty?).to_h { |a| a.split('=', 2) }
  end

  # Applies one dual fuel options lookup row and checks every RTU it creates: a natural gas backup
  # coil, the row's gas backup compressor lockout, the expected heating coil type and stage count,
  # and heating capacity curves from the row's performance category. Apply-only, so it runs in well
  # under a minute.
  def verify_dual_fuel_options_lookup_row(test_name, option_name, expected_hprtu_scenario,
                                          expected_heating_stages, expected_heating_cap_curves)
    lookup_args = options_lookup_args_for(option_name)
    assert_equal('dual_fuel_gas_furnace_backup', lookup_args['backup_ht_fuel_scheme'])
    assert_equal(expected_hprtu_scenario, lookup_args['hprtu_scenario'])

    osm_path = model_input_path('380_small_office_psz_gas_coil_7A.osm')
    epw_path = epw_input_path('NE_Kearney_Muni_725526_16.epw')
    measure = AddHeatPumpRtu.new
    model = load_model(osm_path)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # every argument in the row must be a measure argument, or the run would silently ignore it
    unknown_args = lookup_args.keys - arguments.map(&:name)
    assert_empty(unknown_args, "options lookup arguments not defined by the measure: #{unknown_args}")
    arguments.each_with_index do |arg, idx|
      cloned = arguments[idx].clone
      if lookup_args.key?(arg.name)
        value = lookup_args[arg.name]
        case arg.type.valueName
        when 'Double' then cloned.setValue(value.to_f)
        when 'Integer' then cloned.setValue(value.to_i)
        when 'Boolean' then cloned.setValue(value == 'true')
        else cloned.setValue(value)
        end
      end
      argument_map[arg.name] = cloned
    end

    set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path,
                                          run_model: false, apply: true, model: model)
    applied = load_model(model_output_path(test_name))
    unitary_systems = applied.getAirLoopHVACUnitarySystems
    refute_empty(unitary_systems, "no unitary systems after applying #{option_name}")

    expected_lockout_temp_c = OpenStudio.convert(lookup_args['hp_min_comp_lockout_temp_gas_backup_f'].to_f, 'F', 'C').get
    unitary_systems.each do |system|
      sup_htg_coil = system.supplementalHeatingCoil.get
      assert(sup_htg_coil.to_CoilHeatingGas.is_initialized, "expected a gas backup coil for #{system.name}")
      assert_equal('NaturalGas', sup_htg_coil.to_CoilHeatingGas.get.fuelType,
                   "dual fuel backup coil for #{system.name} should burn natural gas")

      htg_coil = system.heatingCoil.get
      if expected_heating_stages == 1
        assert(htg_coil.to_CoilHeatingDXSingleSpeed.is_initialized,
               "expected a single speed DX heating coil for #{system.name}")
        htg_coil = htg_coil.to_CoilHeatingDXSingleSpeed.get
        curve_names = [htg_coil.totalHeatingCapacityFunctionofTemperatureCurve.name.get]
      else
        assert(htg_coil.to_CoilHeatingDXMultiSpeed.is_initialized,
               "expected a multispeed DX heating coil for #{system.name}")
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

  # Scenario 1 (dual fuel RTU, standard performance): 30 F gas backup lockout and the single stage
  # two_speed_standard_eff heating curve.
  def test_dual_fuel_std_perf_lockout_30F_option
    puts "\n######\nTEST:test_dual_fuel_std_perf_lockout_30F_option\n######\n"
    verify_dual_fuel_options_lookup_row('test_dual_fuel_std_perf_lockout_30F_option', 'dual_fuel_std_perf_lockout_30F',
                                        'two_speed_standard_eff', 1, %w[h_cap_T])
  end

  # Scenario 2 (CCHPC challenge spec dual fuel RTU): -10 F gas backup lockout and the four
  # cchpc_2027_spec heating stages.
  def test_dual_fuel_cchpc_spec_lockout_neg10F_option
    puts "\n######\nTEST:test_dual_fuel_cchpc_spec_lockout_neg10F_option\n######\n"
    verify_dual_fuel_options_lookup_row('test_dual_fuel_cchpc_spec_lockout_neg10F_option', 'dual_fuel_cchpc_spec_lockout_neg10F',
                                        'cchpc_2027_spec', 4, %w[h_cap_low h_cap_medium h_cap_high h_cap_boost])
  end
end
