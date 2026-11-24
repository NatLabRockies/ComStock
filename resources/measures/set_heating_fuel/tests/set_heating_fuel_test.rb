# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'fileutils'
require_relative '../../../../test/helpers/minitest_helper'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require_relative '../measure'

class MeasureTest < Minitest::Test
  def test_retail_propane_and_gas_to_fuel_oil
    # create an instance of the measure
    measure = SetHeatingFuel.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # load the test model
    test_model_name = 'retail_propane_and_gas'
    translator = OpenStudio::OSVersion::VersionTranslator.new
    path = "#{File.dirname(__FILE__)}/#{test_model_name}.osm"
    model = translator.loadModel(path)
    assert(!model.empty?)
    model = model.get

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # create hash of argument values.
    # If the argument has a default that you want to use, you don't need it in the hash
    args_hash = {}
    args_hash['heating_fuel'] = 'FuelOil'
    # using defaults values from measure.rb for other arguments

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      if args_hash.key?(arg.name)
        assert(temp_arg_var.setValue(args_hash[arg.name]))
      end
      argument_map[arg.name] = temp_arg_var
    end

    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result

    # show the output
    show_output(result)

    # assert that it ran correctly
    assert_equal('Success', result.value.valueName)
    assert_equal('Changed heating fuel to FuelOil in 3 heating coils and 1 boilers.', result.info.last.logMessage)

    # save the model to test output directory
    output_file_path = "#{File.dirname(__FILE__)}/output/test_retail_propane_and_gas_to_fuel_oil.osm"
    model.save(output_file_path, true)
  end

  def test_retail_propane_and_gas_to_propane
    # create an instance of the measure
    measure = SetHeatingFuel.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # load the test model
    test_model_name = 'retail_propane_and_gas'
    translator = OpenStudio::OSVersion::VersionTranslator.new
    path = "#{File.dirname(__FILE__)}/#{test_model_name}.osm"
    model = translator.loadModel(path)
    assert(!model.empty?)
    model = model.get

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # create hash of argument values.
    # If the argument has a default that you want to use, you don't need it in the hash
    args_hash = {}
    args_hash['heating_fuel'] = 'Propane'
    # using defaults values from measure.rb for other arguments

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      if args_hash.key?(arg.name)
        assert(temp_arg_var.setValue(args_hash[arg.name]))
      end
      argument_map[arg.name] = temp_arg_var
    end

    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result

    # show the output
    show_output(result)

    # assert that it ran correctly
    assert_equal('Success', result.value.valueName)
    assert_equal('Changed heating fuel to Propane in 0 heating coils and 1 boilers.', result.info.last.logMessage)

    # save the model to test output directory
    output_file_path = "#{File.dirname(__FILE__)}/output/test_retail_propane_and_gas_to_propane.osm"
    model.save(output_file_path, true)
  end

  def test_retail_propane_and_gas_to_electricity
    # create an instance of the measure
    measure = SetHeatingFuel.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # load the test model
    test_model_name = 'retail_propane_and_gas'
    translator = OpenStudio::OSVersion::VersionTranslator.new
    path = "#{File.dirname(__FILE__)}/#{test_model_name}.osm"
    model = translator.loadModel(path)
    assert(!model.empty?)
    model = model.get

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # create hash of argument values.
    # If the argument has a default that you want to use, you don't need it in the hash
    args_hash = {}
    args_hash['heating_fuel'] = 'Electricity'
    # using defaults values from measure.rb for other arguments

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      if args_hash.key?(arg.name)
        assert(temp_arg_var.setValue(args_hash[arg.name]))
      end
      argument_map[arg.name] = temp_arg_var
    end

    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result

    # show the output
    show_output(result)

    # assert that it ran correctly
    assert_equal('NA', result.value.valueName)
    assert_equal('HVAC systems already use Electricity as the heating fuel.', result.info.last.logMessage)

    # save the model to test output directory
    output_file_path = "#{File.dirname(__FILE__)}/output/test_retail_propane_and_gas_to_electricity.osm"
    model.save(output_file_path, true)
  end

  def test_full_service_restaurant_gas_ht_to_fuel_oil
    # create an instance of the measure
    measure = SetHeatingFuel.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # load the test model
    test_model_name = 'full_service_restaurant_gas_ht'
    translator = OpenStudio::OSVersion::VersionTranslator.new
    path = "#{File.dirname(__FILE__)}/#{test_model_name}.osm"
    model = translator.loadModel(path)
    assert(!model.empty?)
    model = model.get

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # create hash of argument values.
    # If the argument has a default that you want to use, you don't need it in the hash
    args_hash = {}
    args_hash['heating_fuel'] = 'FuelOil'
    # using defaults values from measure.rb for other arguments

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      if args_hash.key?(arg.name)
        assert(temp_arg_var.setValue(args_hash[arg.name]))
      end
      argument_map[arg.name] = temp_arg_var
    end

    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result

    # show the output
    show_output(result)

    # assert that it ran correctly
    assert_equal('Success', result.value.valueName)
    assert_equal('Changed heating fuel to FuelOil in 2 heating coils and 0 boilers.', result.info.last.logMessage)

    # save the model to test output directory
    output_file_path = "#{File.dirname(__FILE__)}/output/test_retail_propane_and_gas_to_electricity.osm"
    model.save(output_file_path, true)
  end
end
