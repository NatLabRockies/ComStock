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

class AdvancedRTUControlTest < Minitest::Test
  # return file paths to test models in test directory
  def models_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/models/*.osm'))
    paths = paths.map { |path| File.expand_path(path) }
    return paths
  end

  # return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/weather/*.epw'))
    paths = paths.map { |path| File.expand_path(path) }
    return paths
  end

  def load_model(osm_path)
    translator = OpenStudio::OSVersion::VersionTranslator.new
    model = translator.loadModel(OpenStudio::Path.new(osm_path))
    assert(!model.empty?)
    model = model.get
    return model
  end

  def run_dir(test_name)
    # always generate test output in specially named 'output' directory so result files are not made part of the measure
    puts "run dir expanded=#{File.expand_path(File.join(File.dirname(__FILE__), 'output', test_name.to_s))}"
    return File.join(File.dirname(__FILE__), 'output', test_name.to_s)
  end

  def model_input_path(osm_name)
    # return models_for_tests.select { |x| set[:model] == osm_name }
    puts(__dir__) # expands path relative to current wd, passing abs path back
    return File.expand_path(File.join(File.dirname(__FILE__), '../../../tests/models', osm_name))
  end

  def epw_input_path(epw_name)
    return File.join(File.dirname(__FILE__), '../../../tests/weather', epw_name)
  end

  def model_output_path(test_name)
    return "#{run_dir(test_name)}/#{test_name}.osm"
  end

  def sql_path(test_name)
    return "#{run_dir(test_name)}/run/eplusout.sql"
  end

  def report_path(test_name)
    return "#{run_dir(test_name)}/reports/eplustbl.html"
  end

  # applies the measure and then runs the model
  def apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, model: nil)
    assert(File.exist?(osm_path))
    assert(File.exist?(epw_path))

    # create run directory if it does not exist

    FileUtils.mkdir_p(run_dir(test_name))

    assert(File.exist?(run_dir(test_name)))

    # remove prior runs if they exist
    # if File.exist?(model_output_path(test_name))
    # FileUtils.rm(model_output_path(test_name))
    # end

    FileUtils.rm_f(report_path(test_name))

    # copy the osm and epw to the test directory
    # osm_path = File.expand_path(osm_path)
    puts(osm_path)
    new_osm_path = "#{run_dir(test_name)}/#{File.basename(osm_path)}"
    new_osm_path = File.expand_path(new_osm_path)
    puts(new_osm_path)
    FileUtils.cp(osm_path, new_osm_path)
    new_epw_path = File.expand_path("#{run_dir(test_name)}/#{File.basename(epw_path)}")
    FileUtils.cp(epw_path, new_epw_path)
    # create an instance of a runner
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

    # load the test model
    if model.nil?
      model = load_model(new_osm_path)
    end

    # set model weather file
    epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(new_epw_path))
    OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
    assert(model.weatherFile.is_initialized)

    # run the simulation if necessary
    unless File.exist?(sql_path(test_name))
      puts "\nRUNNING SIZING RUN FOR #{test_name}..."
      std = Standard.build('90.1-2013')
      std.model_run_sizing_run(model, run_dir(test_name))
    end
    assert(File.exist?(File.join(run_dir(test_name), 'in.osm')))
    assert(File.exist?(sql_path(test_name)))

    # change into run directory for tests
    start_dir = Dir.pwd
    Dir.chdir run_dir(test_name)

    # run the measure
    puts "\nAPPLYING MEASURE..."
    measure.run(model, runner, argument_map)
    result = runner.result
    result_success = result.value.valueName == 'Success'

    # change back directory
    Dir.chdir(start_dir)

    # Show the output
    show_output(result)

    # Save model
    puts "saving model to#{File.expand_path(model_output_path(test_name))}"
    model.save(File.expand_path(model_output_path(test_name)), true)

    if run_model && result_success
      puts "\nRUNNING MODEL..."

      std = Standard.build('90.1-2013')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))

      # Check that the model ran successfully
      assert(File.exist?(sql_path(test_name)))
    end

    return result
  end

  def test_number_of_arguments_and_argument_names
    # This test ensures that the current test is matched to the measure inputs
    # Create an instance of the measure
    measure = AdvancedRTUControl.new

    # Make an empty model
    model = OpenStudio::Model::Model.new

    # Get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(2, arguments.size)
  end

  def test_econo
    osm_name = '361_Small_Office_PSZ_Gas_3a.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AdvancedRTUControl.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    # put base case assertions here
    # create hash of argument values
    args_hash = { 'add_econo' => true, 'add_dcv' => false }
    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      if args_hash.key?(arg.name)
        assert(temp_arg_var.setValue(args_hash[arg.name]), "Could not set #{arg.name} to #{args_hash[arg.name]}")
      end
      argument_map[arg.name] = temp_arg_var
    end

    # Apply the measure to the model and optionally run the model
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false)
    model = load_model(File.expand_path(model_output_path(__method__)))
    # confirm that at least one air loop now has an economizer
    has_econo = false
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem
      if oa_system.is_initialized
        oa_system = oa_system.get
        oa_controller = oa_system.getControllerOutdoorAir
        economizer_type = oa_controller.getEconomizerControlType
        if economizer_type != 'NoEconomizer'
          has_econo = true
        end
      else
        runner.registerInfo("Air loop #{air_loop_hvac.name} does not have outdoor air and cannot economize.")
      end
    end
    assert(has_econo)
    # put in assertions here
    # then duplicate it for other models if needed
  end

  def test_var_vol_fan
    osm_name = '361_Retail_PSZ_Gas_5a.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = AdvancedRTUControl.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    # put base case assertions here
    # create hash of argument values
    args_hash = { 'add_econo' => false, 'add_dcv' => false }
    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      if args_hash.key?(arg.name)
        assert(temp_arg_var.setValue(args_hash[arg.name]), "Could not set #{arg.name} to #{args_hash[arg.name]}")
      end
      argument_map[arg.name] = temp_arg_var
    end

    # Apply the measure to the model and optionally run the model
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false)
    model = load_model(File.expand_path(model_output_path(__method__)))

    var_vol_fan = false
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      air_loop_hvac.supplyComponents.each do |component|
        obj_type = component.iddObjectType.valueName.to_s
        case obj_type
          when 'OS_AirLoopHVAC_UnitarySystem'
            component = component.to_AirLoopHVACUnitarySystem.get
            sup_fan = component.supplyFan
            if sup_fan.is_initialized
              sup_fan = sup_fan.get
              if sup_fan.to_FanVariableVolume.is_initialized
                var_vol_fan = true
                assert_in_delta(0.027827882, sup_fan.to_FanVariableVolume.get.fanPowerCoefficient1.get, 0.000001)
              end
            end
        end
      end
    end

    assert(var_vol_fan)
  end
end
