# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.


require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'minitest/autorun'
require_relative '../measure'
require_relative '../../../../test/helpers/minitest_helper'
require 'fileutils'

class HvacDoasHpMinisplitsTest < Minitest::Test
  # def setup
  # end

  # def teardown
  # end

  def test_number_of_arguments_and_argument_names
    # create an instance of the measure
    measure = HvacDoasHpMinisplits.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(3, arguments.size)
    assert_equal(['area_limit_sf', 'doas_htg_fuel', 'performance_oversizing_factor'], arguments.map(&:name))
  end

  def test_bad_argument_values
    # create an instance of the measure
    measure = HvacDoasHpMinisplits.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # get arguments
    arguments = measure.arguments(model)

    # create hash of argument values: a DOAS heating fuel that is not one of the choices
    args_hash = {}
    args_hash['doas_htg_fuel'] = 'district_heating'

    # the measure checks no argument values itself, so a bad value is one the argument refuses
    arguments.each do |arg|
      temp_arg_var = arg.clone
      if args_hash.key?(arg.name)
        refute(temp_arg_var.setValue(args_hash[arg.name]))
      end
    end
  end

  def test_good_argument_values
    # create an instance of the measure
    measure = HvacDoasHpMinisplits.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # load a small office with packaged single-zone units from the shared test models
    translator = OpenStudio::OSVersion::VersionTranslator.new
    path = File.expand_path('../../../tests/models/380_Small_Office_PSZ_Gas_2A.osm', __dir__)
    model = translator.loadModel(path)
    assert(!model.empty?)
    model = model.get

    # the measure runs a sizing run, which needs a weather file
    epw_path = File.expand_path('../../../tests/weather/SC_Columbia_Metro_723100_12.epw', __dir__)
    OpenStudio::Model::WeatherFile.setWeatherFile(model, OpenStudio::EpwFile.new(OpenStudio::Path.new(epw_path)))

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # create hash of argument values: the values the options lookup uses
    args_hash = {}
    args_hash['area_limit_sf'] = 20000.0
    args_hash['doas_htg_fuel'] = 'electric_resistance'
    args_hash['performance_oversizing_factor'] = 0.35

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      if args_hash.key?(arg.name)
        assert(temp_arg_var.setValue(args_hash[arg.name]))
      end
      argument_map[arg.name] = temp_arg_var
    end

    # run the measure in the test output directory, where its sizing run writes
    output_dir = File.join(__dir__, 'output', 'test_good_argument_values')
    FileUtils.mkdir_p(output_dir)
    Dir.chdir(output_dir) { measure.run(model, runner, argument_map) }
    result = runner.result

    # show the output
    show_output(result)

    # assert that it ran correctly and added the zone minisplits
    assert_equal('Success', result.value.valueName)
    refute_empty(model.getAirLoopHVACUnitarySystems.select { |unit| unit.name.to_s.end_with?('Zone Mini Split Heat Pump') })

    # save the model to test output directory
    output_file_path = File.join(output_dir, 'test_output.osm')
    model.save(output_file_path, true)
  end
end
