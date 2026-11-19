# ComStock™, Copyright (c) 2020 Alliance for Sustainable Energy, LLC. All rights reserved.
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
require 'open3'
require_relative '../measure'
require_relative '../../../../test/helpers/minitest_helper'


class ConsoleGTHPTest < Minitest::Test
  def setup
    # Check that the test is being run in an environment that has the GHEdesigner package
    command = 'ghedesigner --help'
    begin
      Open3.capture3(command)
    rescue StandardError
      msg = 'GHEDesigner python package not found in this test environment, pip install GHEDesigner and retry'
      raise LoadError, msg
    end
  end

  # return file paths to test models in test directory
  def models_for_tests
    paths = Dir.glob(File.join(__dir__, '../../../tests/models/*.osm'))
    paths.map { |path| File.expand_path(path) }
  end

  # return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(__dir__, '../../../tests/weather/*.epw'))
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
    rd = File.absolute_path(File.join(__dir__, 'output', test_name.to_s))
    puts "caller: #{caller[0]} run_dir(#{test_name}) = #{rd}"
    File.absolute_path(File.join(__dir__, 'output', test_name.to_s))
  end

  def model_input_path(osm_name)
    File.absolute_path(File.join(__dir__, '../../../tests/models', osm_name))
  end

  def epw_input_path(epw_name)
    File.absolute_path(File.join(__dir__, '../../../tests/weather', epw_name))
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

  def populate_argument_map(measure, osm_path, args_hash)
    # Load the model; only used here for populating arguments
    model = load_model(osm_path)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure::OSArgumentMap.new

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      assert(temp_arg_var.setValue(args_hash[arg.name])) if args_hash.key?(arg.name)
      argument_map[arg.name] = temp_arg_var
    end

    argument_map
  end

  # Runs the model, applies the measure, reruns the model, and checks that
  # before/after annual energy consumption results are identical
  def apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, model: nil)
    assert(File.exist?(osm_path))
    assert(File.exist?(epw_path))

    # create run directory if it does not exist
    FileUtils.mkdir_p(run_dir(test_name))
    assert(File.exist?(run_dir(test_name)))

    # change into run directory for tests
    start_dir = Dir.pwd
    Dir.chdir run_dir(test_name)

    # remove prior runs if they exist
    FileUtils.rm_f(model_output_path(test_name))

    # copy the osm and epw to the test directory
    puts File.basename(osm_path)
    puts run_dir(test_name)
    new_osm_path = File.join(run_dir(test_name), File.basename(osm_path))
    puts "Copying #{osm_path}"
    puts "To #{new_osm_path}"

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

    # If the sql file from the sizing run exists, assign
    # it to the model for faster test runtime
    siz_sql_path = "#{run_dir(test_name)}/AnnualGHELoadsRun/run/eplusout.sql"
    puts "size_sql_path = #{siz_sql_path}"
    if File.exist?(siz_sql_path)
      puts('Reloading sql file from sizing run to speed testing')
      sql_path = OpenStudio::Path.new(siz_sql_path)
      sql = OpenStudio::SqlFile.new(sql_path)
      model.setSqlFile(sql)
    end

    # Run the measure
    puts "\nAPPLYING MEASURE..."
    measure.run(model, runner, argument_map)
    result = runner.result
    result_success = result.value.valueName == 'Success'

    # Show the output
    show_output(result)

    # Save model
    model.save(model_output_path(test_name), true)

    # Run the model after applying the measure and get annual energy consumption
    std = Standard.build('90.1-2013')
    if run_model && result_success
      puts "\nRUNNING MODEL AFTER MEASURE..."
      assert(std.model_run_simulation_and_log_errors(model, File.join(run_dir(test_name), 'AnnualRunRealGHEObjects')))
    end

    # change back directory
    Dir.chdir(start_dir)

    result
  end

  def test_number_of_arguments_and_argument_names
    # Create an instance of the measure
    measure = AddConsoleGSHP.new

    # Make an empty model
    model = OpenStudio::Model::Model.new

    # Get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(4, arguments.size)
  end

  def test_pthp
    osm_name = 'PTHP_3B.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddConsoleGSHP.new
    args_hash = {}
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  def test_ptac_electric_heat
    osm_name = 'PTAC_with_electric_coil.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddConsoleGSHP.new
    args_hash = {}
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  # test all applicable system types
  def test_ptac_gas_heat
    osm_name = 'PTAC_with_gas_coil_heat_3B.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddConsoleGSHP.new
    args_hash = {}
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  def test_ptac_gas_boiler
    osm_name = 'PTAC_with_gas_boiler.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddConsoleGSHP.new
    args_hash = {}
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  def test_gas_unit_heaters
    osm_name = 'Unit_heaters.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddConsoleGSHP.new
    args_hash = {}
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  def test_baseboard_electric
    osm_name = 'Baseboard_electric.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddConsoleGSHP.new
    args_hash = {}
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  def test_residential_ac
    osm_name = 'Residential_AC.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddConsoleGSHP.new
    args_hash = {}
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  # test a few non-applicable system types
  def test_direct_evap_coolers_baseboard_gas_boiler
    osm_name = 'Direct_evap_coolers_boiler.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddConsoleGSHP.new
    args_hash = {}
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  def test_pszhp
    osm_name = 'PSZ-HP_gthp.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddConsoleGSHP.new
    args_hash = {}
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  def test_pvav_gas_heat_electric_reheat
    osm_name = 'PVAV_gas_heat_electric_reheat.osm'
    epw_name = 'NY_New_York_John_F_Ke_744860_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = AddConsoleGSHP.new
    args_hash = {}
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end
end
