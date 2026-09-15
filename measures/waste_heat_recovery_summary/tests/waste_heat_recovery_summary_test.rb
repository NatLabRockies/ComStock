# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'csv'
require 'fileutils'
require 'minitest/autorun'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'openstudio-standards'
require 'json'
require 'open3'
require_relative '../measure'

class WasteHeatRecoverySummaryTest < Minitest::Test
  def run_dir(test_name)
    # always generate test output in specially named 'output' directory so result files are not made part of the measure
    return "#{__dir__}/output/#{test_name}"
  end

  def model_output_path(test_name)
    return "#{run_dir(test_name)}/example_model.osm"
  end

  def sql_path(test_name)
    return "#{run_dir(test_name)}/run/eplusout.sql"
  end

  def timeseries_output_csv_path(test_name)
    return "#{run_dir(test_name)}/timeseries_output.csv"
  end

  # Queries the PythonPlugin:OutputVariable timeseries produced by the measure
  # from the run's sql file and writes them to a single long-format CSV.
  def save_timeseries_csv(test_name)
    sql = OpenStudio::SqlFile.new(OpenStudio::Path.new(sql_path(test_name)))

    ann_env_pd = nil
    sql.availableEnvPeriods.each do |env_pd|
      env_type = sql.environmentType(env_pd)
      if env_type.is_initialized && (env_type.get == OpenStudio::EnvironmentType.new('WeatherRunPeriod'))
        ann_env_pd = env_pd
      end
    end
    assert(!ann_env_pd.nil?, 'Could not find a weather run period in the sql file')

    variable_names = [
      'total_heating_coil_energy',
      'total_cooling_coil_energy',
      'simultaneous_energy',
      'total_hot_water_volume',
      'avg_drain_temperature'
    ]

    csv_path = timeseries_output_csv_path(test_name)
    CSV.open(csv_path, 'w') do |csv|
      csv << ['datetime', 'variable_name', 'value', 'units']
      variable_names.each do |var_name|
        ts = sql.timeSeries(ann_env_pd, 'Zone Timestep', 'PythonPlugin:OutputVariable', var_name)
        next unless ts.is_initialized

        ts = ts.get
        date_times = ts.dateTimes
        values = ts.values
        units = ts.units
        (0...values.size).each do |i|
          csv << [date_times[i].to_s, var_name, values[i], units]
        end
      end
    end

    sql.close
    assert(File.exist?(csv_path), "Expected timeseries CSV to be created at #{csv_path}")
    return csv_path
  end

  def get_run_env()
    new_env = {}
    new_env['BUNDLER_ORIG_MANPATH'] = nil
    new_env['BUNDLER_ORIG_PATH'] = nil
    new_env['BUNDLER_VERSION'] = nil
    new_env['BUNDLE_BIN_PATH'] = nil
    new_env['RUBYLIB'] = nil
    new_env['RUBYOPT'] = nil
    new_env['GEM_PATH'] = nil
    new_env['GEM_HOME'] = nil
    new_env['BUNDLE_GEMFILE'] = nil
    new_env['BUNDLE_PATH'] = nil
    new_env['BUNDLE_WITHOUT'] = nil

    return new_env
  end

  def run_in_workflow(test_name, test_model_path, args_hash, epw_path)
    # Check that the input model exists
    assert(File.exist?(test_model_path))

    # Check that the epw file exists
    assert(File.exist?(epw_path))

    # Make the run directory for this test
    FileUtils.mkdir_p(run_dir(test_name)) unless File.exist?(run_dir(test_name))
    assert(File.exist?(run_dir(test_name)))

    # Remove the previous output model
    FileUtils.rm(model_output_path(test_name)) if File.exist?(model_output_path(test_name))

    osw_path = File.join(run_dir(test_name), 'in.osw')
    osw_path = File.absolute_path(osw_path)

    workflow = OpenStudio::WorkflowJSON.new
    workflow.setSeedFile(File.absolute_path(test_model_path))
    workflow.setWeatherFile(File.absolute_path(epw_path))
    workflow.addMeasurePath(File.absolute_path(File.join(File.dirname(__FILE__), '../../')))
    step = OpenStudio::MeasureStep.new('waste_heat_recovery_summary')
    args_hash.each do |key, value|
      step.setArgument(key, value)
    end

    check = workflow.setMeasureSteps(OpenStudio::MeasureType.new("ReportingMeasure"), [step])

    puts workflow

    workflow.saveAs(osw_path)

    cli_path = OpenStudio.getOpenStudioCLI
    command = "\"#{cli_path}\" run -w \"#{osw_path}\""
    stdout_str, stderr_str, status = Open3.capture3(get_run_env(), command)

    if status.success?
      puts "Successfully ran command: '#{command}'"
    else
      puts "Error running command: '#{command}'"
      puts "stdout: #{stdout_str}"
      puts "stderr: #{stderr_str}"
    end

    # Check that the sql file exists
    assert(File.exist?(sql_path(test_name)))
  end

  def test_number_of_arguments_and_argument_names
    # this test ensures that the current test is matched to the measure inputs
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = WasteHeatRecoverySummary.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments
    assert_equal(1, arguments.size)
    assert_equal('timeseries_output', arguments[0].name)
  end

  def test_office_vav_reheat
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/LargeOffice04.osm"
    epw_path = "#{__dir__}/USA_CO_Golden-NREL.724666_TMY3.epw"

    # enable timeseries output so the plugin variables are reported at Zone Timestep
    args_hash = { 'timeseries_output' => true }

    run_in_workflow(__method__, osm_path, args_hash, epw_path)

    csv_path = save_timeseries_csv(__method__)
    puts "Saved timeseries output to #{csv_path}"

    return true
  end

  def test_school_vav_reheat
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/school_vav.osm"
    epw_path = "#{__dir__}/USA_NY_New.York-John.F.Kennedy.Intl.AP.744860_TMY3.epw"

    # set the arguments to test
    args_hash = { 'timeseries_output' => true }

    # run the measure
    run_in_workflow(__method__, osm_path, args_hash, epw_path)

    csv_path = save_timeseries_csv(__method__)
    puts "Saved timeseries output to #{csv_path}"

    return true
  end

  def test_school_vav_pfp
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/school_vav_pfp.osm"
    epw_path = "#{__dir__}/USA_NY_New.York-John.F.Kennedy.Intl.AP.744860_TMY3.epw"

    # set the arguments to test
    args_hash = { 'timeseries_output' => true }

    # run the measure
    run_in_workflow(__method__, osm_path, args_hash, epw_path)

    csv_path = save_timeseries_csv(__method__)
    puts "Saved timeseries output to #{csv_path}"

    return true
  end

  def test_large_office_vav_pfp
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/large_office_vav_pfp.osm"
    epw_path = "#{__dir__}/USA_CO_Golden-NREL.724666_TMY3.epw"

    # set the arguments to test
    args_hash = { 'timeseries_output' => true }

    # run the measure
    run_in_workflow(__method__, osm_path, args_hash, epw_path)

    csv_path = save_timeseries_csv(__method__)
    puts "Saved timeseries output to #{csv_path}"

    return true
  end
end
