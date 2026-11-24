# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'fileutils'
require_relative '../../../../test/helpers/minitest_helper'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require_relative '../measure'

class SimulationSettingsTest < Minitest::Test
  def test_defaults
    # create an instance of the measure
    measure = SimulationSettings.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # load the test model
    translator = OpenStudio::OSVersion::VersionTranslator.new
    path = "#{File.dirname(__FILE__)}/example_model.osm"
    model = translator.loadModel(path)
    assert(!model.empty?)
    model = model.get

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # create hash of argument values.
    # If the argument has a default that you want to use, you don't need it in the hash
    args_hash = {}
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

    # Timestep
    assert_equal(4, model.getTimestep.numberOfTimestepsPerHour, 'Timestep is wrong')

    # Daylight savings
    dst_control = model.getRunPeriodControlDaylightSavingTime
    start_dst = dst_control.getString(1).get
    end_dst = dst_control.getString(2).get
    assert_equal('2nd Sunday in March', start_dst, 'DST start wrong')
    assert_equal('1st Sunday in November', end_dst, 'DST end wrong')

    # Run period
    run_period = model.getRunPeriod
    assert_equal(1, run_period.getBeginMonth, 'Run period begin month wrong')
    assert_equal(1, run_period.getBeginDayOfMonth, 'Run period begin day wrong')
    assert_equal(12, run_period.getEndMonth, 'Run period end month wrong')
    assert_equal(31, run_period.getEndDayOfMonth, 'Run period end day wrong')

    # Translate to IDF to check start day of week
    ft = OpenStudio::EnergyPlus::ForwardTranslator.new
    idf = ft.translateModel(model)

    # Year
    yr_desc_idf = idf.getObjectsByType('RunPeriod'.to_IddObjectType)[0]
    assert_equal('2009', yr_desc_idf.getString(3).get)
    assert_equal('2009', yr_desc_idf.getString(6).get)
    assert_equal('Thursday', yr_desc_idf.getString(7).get, 'Day of week for start day is wrong') # start day 1/1/2009 is a Thursday

    # save the model to test output directory
    output_file_path = "#{File.dirname(__FILE__)}//output/test_defaults.osm"
    model.save(output_file_path, true)
  end

  def test_chosen_start_and_mid_year_start_day
    # create an instance of the measure
    measure = SimulationSettings.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # load the test model
    translator = OpenStudio::OSVersion::VersionTranslator.new
    path = "#{File.dirname(__FILE__)}/example_model.osm"
    model = translator.loadModel(path)
    assert(!model.empty?)
    model = model.get

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # create hash of argument values.
    # If the argument has a default that you want to use, you don't need it in the hash
    args_hash = {
      'calendar_year' => 0,
      'jan_first_day_of_wk' => 'Tuesday', # 2002 starts on a Tuesday
      'begin_month' => 4,
      'begin_day' => 10
    }
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

    # Timestep
    assert_equal(4, model.getTimestep.numberOfTimestepsPerHour, 'Timestep is wrong')

    # Run period
    run_period = model.getRunPeriod
    assert_equal(4, run_period.getBeginMonth, 'Run period begin month wrong')
    assert_equal(10, run_period.getBeginDayOfMonth, 'Run period begin day wrong')
    assert_equal(12, run_period.getEndMonth, 'Run period end month wrong')
    assert_equal(31, run_period.getEndDayOfMonth, 'Run period end day wrong')

    # Translate to IDF to check start day of week
    ft = OpenStudio::EnergyPlus::ForwardTranslator.new
    idf = ft.translateModel(model)

    # Year
    run_period_idf = idf.getObjectsByType('RunPeriod'.to_IddObjectType)[0]
    assert_equal('2002', run_period_idf.getString(3).get) # 2002 is closest year to 2009 where Jan 1st falls on a Tuesday
    assert_equal('2002', run_period_idf.getString(6).get)
    assert_equal('Wednesday', run_period_idf.getString(7).get, 'Day of week for start day is wrong') # start day 4/10/2002 is a Friday

    # save the model to test output directory
    output_file_path = "#{File.dirname(__FILE__)}//output/test_chosen_start_and_mid_year_start_day.osm"
    model.save(output_file_path, true)
  end

  def test_actual_2012
    # create an instance of the measure
    measure = SimulationSettings.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # load the test model
    translator = OpenStudio::OSVersion::VersionTranslator.new
    path = "#{File.dirname(__FILE__)}/example_model.osm"
    model = translator.loadModel(path)
    assert(!model.empty?)
    model = model.get

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # create hash of argument values.
    # If the argument has a default that you want to use, you don't need it in the hash
    args_hash = {
      'calendar_year' => 2012,
      'begin_month' => 1,
      'begin_day' => 1,
      'end_month' => 12,
      'end_day' => 30
    }
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

    # Timestep
    assert_equal(4, model.getTimestep.numberOfTimestepsPerHour, 'Timestep is wrong')

    # Daylight savings
    dst_control = model.getRunPeriodControlDaylightSavingTime
    start_dst = dst_control.getString(1).get
    end_dst = dst_control.getString(2).get
    assert_equal('2nd Sunday in March', start_dst, 'DST start wrong')
    assert_equal('1st Sunday in November', end_dst, 'DST end wrong')

    # Run period
    run_period = model.getRunPeriod
    assert_equal(1, run_period.getBeginMonth, 'Run period begin month wrong')
    assert_equal(1, run_period.getBeginDayOfMonth, 'Run period begin day wrong')
    assert_equal(12, run_period.getEndMonth, 'Run period end month wrong')
    assert_equal(30, run_period.getEndDayOfMonth, 'Run period end day wrong')

    # Translate to IDF to check start day of week
    ft = OpenStudio::EnergyPlus::ForwardTranslator.new
    idf = ft.translateModel(model)

    # Year
    yr_desc_idf = idf.getObjectsByType('RunPeriod'.to_IddObjectType)[0]
    assert_equal('2012', yr_desc_idf.getString(3).get)
    assert_equal('2012', yr_desc_idf.getString(6).get)
    assert_equal('Sunday', yr_desc_idf.getString(7).get, 'Day of week for start day is wrong') # start day 1/1/2012 is a Sunday

    # save the model to test output directory
    output_file_path = "#{File.dirname(__FILE__)}//output/test_actual_2012.osm"
    model.save(output_file_path, true)
  end

  def test_actual_2012_mid_year_start_day_no_dst
    # create an instance of the measure
    measure = SimulationSettings.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # load the test model
    translator = OpenStudio::OSVersion::VersionTranslator.new
    path = "#{File.dirname(__FILE__)}/example_model.osm"
    model = translator.loadModel(path)
    assert(!model.empty?)
    model = model.get

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # create hash of argument values.
    # If the argument has a default that you want to use, you don't need it in the hash
    args_hash = {
      'enable_dst' => false,
      'calendar_year' => 2012,
      'jan_first_day_of_wk' => 'Tuesday',
      'begin_month' => 2,
      'begin_day' => 11,
      'end_month' => 12,
      'end_day' => 30
    }
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

    # Timestep
    assert_equal(4, model.getTimestep.numberOfTimestepsPerHour, 'Timestep is wrong')

    # Run period
    run_period = model.getRunPeriod
    assert_equal(2, run_period.getBeginMonth, 'Run period begin month wrong')
    assert_equal(11, run_period.getBeginDayOfMonth, 'Run period begin day wrong')
    assert_equal(12, run_period.getEndMonth, 'Run period end month wrong')
    assert_equal(30, run_period.getEndDayOfMonth, 'Run period end day wrong')

    # Translate to IDF to check start day of week
    ft = OpenStudio::EnergyPlus::ForwardTranslator.new
    idf = ft.translateModel(model)

    # Year
    run_period_idf = idf.getObjectsByType('RunPeriod'.to_IddObjectType)[0]
    assert_equal('2012', run_period_idf.getString(3).get)
    assert_equal('2012', run_period_idf.getString(6).get)
    assert_equal('Saturday', run_period_idf.getString(7).get, 'Day of week for start day is wrong') # start day 2/11/2012 is a Saturday

    # Daylight savings
    dst_control_idfs = idf.getObjectsByType('RunPeriodControl:DaylightSavingTime'.to_IddObjectType)
    assert_equal(0, dst_control_idfs.size, 'Found unexpected RunPeriodControl:DaylightSavingTime object')
    assert_equal('No', run_period_idf.getString(9).get)

    # save the model to test output directory
    output_file_path = "#{File.dirname(__FILE__)}//output/test_mid_year_start_day_no_dst.osm"
    model.save(output_file_path, true)
  end
end
