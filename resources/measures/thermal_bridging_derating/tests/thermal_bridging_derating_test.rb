# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2020, Alliance for Sustainable Energy, LLC.
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

require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require_relative '../../../../test/helpers/minitest_helper'
require 'fileutils'
require_relative '../measure'

class ThermalBridgingDeratingTest < Minitest::Test
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
    return File.join(File.dirname(__FILE__), 'output', test_name.to_s)
  end

  def model_input_path(osm_name)
    # return models_for_tests.select { |x| set[:model] == osm_name }
    return File.expand_path(File.join(File.dirname(__FILE__), '../../../tests/models', osm_name))
  end

  def epw_input_path(epw_name)
    return File.join(File.dirname(__FILE__), '../../../tests/weather', epw_name)
  end

  def model_output_path(test_name)
    return "#{run_dir(test_name)}/#{test_name}_out.osm"
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
    FileUtils.rm_f(model_output_path(test_name))
    FileUtils.rm_f(report_path(test_name))

    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

    # load the test model
    if model.nil?
      model = load_model(osm_path)
    end

    # set model weather file
    epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(epw_path))
    OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
    assert(model.weatherFile.is_initialized)

    # run the measure
    puts "\nAPPLYING MEASURE..."
    measure.run(model, runner, argument_map)
    result = runner.result
    result_success = result.value.valueName == 'Success'

    # Show the output
    show_output(result)

    # Save model
    model.save(model_output_path(test_name), true)

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
    measure = ThermalBridgingDerating.new
    model = OpenStudio::Model::Model.new
    arguments = measure.arguments(model)
    assert_equal(1, arguments.size)
  end

  def test_efficient_thermal_bridging
    # select
    osm_name = '361_Strip_Mall_PSZ_Gas_3a.osm'
    epw_name = 'TN_KNOXVILLE_723260_12.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # create a new instance of the measure
    measure = ThermalBridgingDerating.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure::OSArgumentMap.new

    # set arguments
    option = arguments[0].clone
    assert(option.setValue('efficient (BETBG)'))
    argument_map['option'] = option

    # Apply the measure to the model and optionally run the model
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false)
    assert_equal('Success', result.value.valueName)
  end
end
