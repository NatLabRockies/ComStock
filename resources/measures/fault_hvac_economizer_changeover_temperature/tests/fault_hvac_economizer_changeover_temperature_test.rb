# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'fileutils'
require 'minitest/autorun'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'comstock-typical' # remove if not using openstudio-standards methods
require_relative '../measure'

class FaultHvacEconomizerChangeoverTemperatureTest < Minitest::Test
  # return file paths to test models in test directory
  def models_for_tests
    paths = Dir.glob(File.join(__dir__, '../../../tests/models/*.osm'))
    paths = paths.map { |path| File.expand_path(path) }
    return paths
  end

  # return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(__dir__, '../../../tests/weather/*.epw'))
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
    return "#{__dir__}/output/#{test_name}"
  end

  def model_output_path(test_name)
    return "#{run_dir(test_name)}/out.osm"
  end

  def sql_path(test_name)
    return "#{run_dir(test_name)}/run/eplusout.sql"
  end

  def report_path(test_name)
    return "#{run_dir(test_name)}/reports/eplustbl.html"
  end

  # applies the measure and then runs the model
  def apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false)
    assert(File.exist?(osm_path))
    assert(File.exist?(epw_path))

    # remove prior runs if they exist
    FileUtils.rm_f(model_output_path(test_name))
    FileUtils.rm_f(sql_path(test_name))
    FileUtils.rm_f(report_path(test_name))

    # create run directory if it does not exist
    FileUtils.mkdir_p(run_dir(test_name))

    # create an instance of a runner with OSW
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

    # load the test model
    model = load_model(osm_path)

    # set model weather file
    epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(epw_path))
    OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
    assert(model.weatherFile.is_initialized)

    # temporarily change directory to the run directory and run the measure
    # only necessary for measures that do a sizing run
    start_dir = Dir.pwd
    begin
      Dir.chdir(run_dir(test_name))

      # run the measure
      puts "\nAPPLYING MEASURE..."
      measure.run(model, runner, argument_map)
      result = runner.result
    ensure
      Dir.chdir(start_dir)
    end

    # show the output
    show_output(result)

    # save model
    model.save(model_output_path(test_name), true)

    if run_model && (result.value.valueName == 'Success')
      puts "\nRUNNING MODEL..."

      std = Standard.build('ComStock DEER 2020')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))

      # check that the model ran successfully
      assert(File.exist?(sql_path(test_name)))
    end

    return result
  end

  def test_number_of_arguments_and_argument_names
    # this test ensures that the current test is matched to the measure inputs
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = FaultHvacEconomizerChangeoverTemperature.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(3, arguments.size)
    assert_equal('econ_choice', arguments[0].name)
    assert_equal('changeovertemp', arguments[1].name)
    assert_equal('apply_measure', arguments[2].name)
  end

  # create an array of hashes with model name, weather, and expected result
  def models_to_test
    test_sets = []

    # test: building with no economizer
    test_sets << {
      model: '361_Small_Office_PSZ_Gas_3a',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'NA'
    }
    # test: building with economizers with fixed drybulb control only
    test_sets << {
      model: '361_Small_Office_PSZ_Gas_3a_economizer_allfdb',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'Success'
    }
    # test: building with economizers with some fixed drybulb control
    test_sets << {
      model: '361_Small_Office_PSZ_Gas_3a_economizer_notallfdb',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'Success'
    }
    # test: building with economizers with no fixed drybulb control
    test_sets << {
      model: '361_Small_Office_PSZ_Gas_3a_economizer_nofdb',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'NA'
    }
    return test_sets
  end

  def test_models
    puts "\n######\nTEST:#{__method__}\n######\n"

    models_to_test.each do |set|
      instance_test_name = set[:model]
      puts "instance test name: #{instance_test_name}"
      osm_path = models_for_tests.select { |x| set[:model] == File.basename(x, '.osm') }
      epw_path = epws_for_tests.select { |x| set[:weather] == File.basename(x, '.epw') }
      assert(!osm_path.empty?)
      assert(!epw_path.empty?)
      osm_path = osm_path[0]
      epw_path = epw_path[0]

      # create an instance of the measure
      measure = FaultHvacEconomizerChangeoverTemperature.new

      # load the model; only used here for populating arguments
      model = load_model(osm_path)

      # set arguments here; will vary by measure
      arguments = measure.arguments(model)
      argument_map = OpenStudio::Measure::OSArgumentMap.new

      # set arguments: choice of economizer
      econ_choice = arguments[0].clone
      assert(econ_choice.setValue('all available economizer'))
      argument_map['econ_choice'] = econ_choice

      # set arguments: changeover temperature C
      changeovertemp = arguments[1].clone
      assert(changeovertemp.setValue(10.88))
      argument_map['changeovertemp'] = changeovertemp

      # set arguments: apply measure
      apply_measure = arguments[2].clone
      assert(apply_measure.setValue(true))
      argument_map['apply_measure'] = apply_measure

      # apply the measure to the model and optionally run the model
      result = apply_measure_and_run(instance_test_name, measure, argument_map, osm_path, epw_path, run_model: false)

      # check the measure result; result values will equal Success, Fail, or Not Applicable (NA)
      # also check the amount of warnings, info, and error messages
      # use if or case statements to change expected assertion depending on model characteristics
      assert(result.value.valueName == set[:result])

      # to check that something changed in the model, load the model and the check the objects match expected new value
      model = load_model(model_output_path(instance_test_name))
    end
  end
end
