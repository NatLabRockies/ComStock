# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'minitest/autorun'
require 'fileutils'
require 'open3'

require_relative '../measure'
require_relative '../../../test/helpers/minitest_helper'

class LoadsSummaryTest < Minitest::Test
  def debug
    # return true
    return false
  end

  def timeseries
    # return true
    return true
  end

  def script_version
    # return true
    return 2 # change this to the version of the script you are testing
  end

  def teardown
    $stdout = STDOUT
  end

  def model_in_path_default
    return "#{File.dirname(__FILE__)}/example_model.osm"
  end

  def epw_path_default
    # make sure we have a weather data location
    epw = File.expand_path("#{File.dirname(__FILE__)}/USA_CO_Golden-NREL.724666_TMY3.epw")
    assert_path_exists(epw.to_s)
    return epw.to_s
  end

  def run_dir(test_name)
    # always generate test output in specially named 'output' directory so result files are not made part of the measure
    return "#{File.dirname(__FILE__)}/output/#{test_name}"
  end

  def model_out_path(test_name)
    return "#{run_dir(test_name)}/example_model.osm"
  end

  def sql_path(test_name)
    return "#{run_dir(test_name)}/run/eplusout.sql"
  end

  def report_path(test_name)
    return "#{run_dir(test_name)}/report.html"
  end

  def get_run_env
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

  def run_in_workflow(test_name, test_model_path, args_hash, epw_path = epw_path_default)
    # Check that the input model exists
    assert(File.exist?(test_model_path))

    # Check that the epw file exists
    assert(File.exist?(epw_path))

    # Make the run directory for this test
    FileUtils.mkdir_p(run_dir(test_name))
    assert(File.exist?(run_dir(test_name)))

    # Remove the previous output report
    FileUtils.rm_f(report_path(test_name))

    # Remove the previous output model
    FileUtils.rm_f(model_out_path(test_name))

    osw_path = File.join(run_dir(test_name), 'in.osw')
    osw_path = File.absolute_path(osw_path)

    workflow = OpenStudio::WorkflowJSON.new
    workflow.setSeedFile(File.absolute_path(test_model_path))
    workflow.setWeatherFile(File.absolute_path(epw_path))
    # puts File.absolute_path(File.join(File.dirname(__FILE__), '../../loads_summary'))
    # step = OpenStudio::MeasureStep.new(File.absolute_path(File.join(File.dirname(__FILE__), '../../measure.rb')))
    workflow.addMeasurePath(File.absolute_path(File.join(File.dirname(__FILE__), '../../')))
    step = OpenStudio::MeasureStep.new('loads_summary')
    args_hash.each do |key, value|
      step.setArgument(key, value)
    end

    check = workflow.setMeasureSteps(OpenStudio::MeasureType.new('ReportingMeasure'), [step])

    # # try not translating spaces
    # fto = OpenStudio::ForwardTranslatorOptions.new
    # fto.setExcludeSpaceTranslation(true)
    # fto.setExcludeLCCObjects(true)
    # ro = OpenStudio::RunOptions.new
    # ro.setSkipEnergyPlusPreprocess(true)
    # ro.setForwardTranslatorOptions(fto)
    # workflow.setRunOptions(ro)

    puts workflow

    workflow.saveAs(osw_path)

    cli_path = OpenStudio.getOpenStudioCLI
    command = "\"#{cli_path}\" run -w \"#{osw_path}\""
    stdout_str, stderr_str, status = Open3.capture3(get_run_env, command)

    if status.success?
      puts "Successfully ran command: '#{command}'"
    else
      puts "Error running command: '#{command}'"
      puts "stdout: #{stdout_str}"
      puts "stderr: #{stderr_str}"
    end

    # Check that the model output and sql file exist
    assert(File.exist?(sql_path(test_name)))
  end

  # create test files if they do not exist when the test first runs
  def setup_test(test_name, idf_output_requests, model_in_path = model_in_path_default, epw_path = epw_path_default)
    FileUtils.mkdir_p(run_dir(test_name))

    assert_path_exists(run_dir(test_name))


    FileUtils.rm_f(report_path(test_name))


    assert_path_exists(model_in_path)


    FileUtils.rm_f(model_out_path(test_name))


    # convert output requests to OSM for testing, OS App and PAT will add these to the E+ Idf
    workspace = OpenStudio::Workspace.new('Draft'.to_StrictnessLevel, 'EnergyPlus'.to_IddFileType)
    workspace.addObjects(idf_output_requests)
    rt = OpenStudio::EnergyPlus::ReverseTranslator.new
    request_model = rt.translateWorkspace(workspace)

    translator = OpenStudio::OSVersion::VersionTranslator.new
    model = translator.loadModel(model_in_path)
    refute_empty(model)
    model = model.get
    model.addObjects(request_model.objects)
    model.save(model_out_path(test_name), true)

    if ENV['OPENSTUDIO_TEST_NO_CACHE_SQLFILE']

      FileUtils.rm_f(sql_path(test_name))

    end

    osw_path = File.join(run_dir(test_name), 'in.osw')
    osw_path = File.absolute_path(osw_path)

    workflow = OpenStudio::WorkflowJSON.new
    workflow.setSeedFile(File.absolute_path(model_out_path(test_name)))
    workflow.setWeatherFile(File.absolute_path(epw_path))
    workflow.saveAs(osw_path)

    cli_path = OpenStudio.getOpenStudioCLI
    cmd = "\"#{cli_path}\" run -w \"#{osw_path}\""
    puts cmd
    system(cmd)
  end

  def test_simple_model
    test_name = __method__.to_s
    test_model_name = 'simple_test.osm'
    test_model_path = "#{__dir__}/#{test_model_name}"
    epw_path = "#{__dir__}/test.epw"

    args_hash = {}

    run_in_workflow(test_name, test_model_path, args_hash, epw_path)
  end

  def test_cz3C_small_office
    test_name = 'test_cz3C_small_office'
    test_model_name = 'CZ3C_small_office_10001_25000_PTHP.osm'
    test_model_path = "#{__dir__}/#{test_model_name}"
    epw_path = "#{__dir__}/G0600530.epw"

    # set the arguments to test
    args_hash = {}

    # run the measure
    run_in_workflow(test_name, test_model_path, args_hash, epw_path)

    # test with timeseries output
    run_in_workflow("#{test_name}_timeseries", test_model_path, { 'timeseries_output' => true }, epw_path)

    return true
  end

  def test_cz3C_small_office_multiplier
    test_name = __method__.to_s
    test_model_name = 'CZ3C_small_office_10001_25000_PTHPx10.osm'
    test_model_path = "#{__dir__}/#{test_model_name}"
    epw_path = "#{__dir__}/G0600530.epw"

    # set the arguments to test
    args_hash = {}

    # run the measure
    run_in_workflow(test_name, test_model_path, args_hash, epw_path)
    return true
  end

  def test_cz6A_grocery
    test_name = __method__.to_s
    test_model_name = 'CZ6A_grocery_40001_52000_PSZ-AC with gas coil.osm'
    test_model_path = "#{__dir__}/#{test_model_name}"
    epw_path = "#{__dir__}/G3600070.epw"

    # set the arguments to test
    args_hash = {}

    # run the measure
    run_in_workflow(test_name, test_model_path, args_hash, epw_path)
    return true
  end

  def test_cz4B_retail
    test_name = 'test_cz4B_retail'
    test_model_name = 'CZ4B_retail_10001_25000_PSZ-AC with gas coil.osm'
    test_model_path = "#{__dir__}/#{test_model_name}"
    epw_path = "#{__dir__}/G3500010.epw"

    # set the arguments to test
    args_hash = {}

    # run the measure
    run_in_workflow(test_name, test_model_path, args_hash, epw_path)
    # test with timeseries output

    run_in_workflow("#{test_name}_timeseries", test_model_path, { 'timeseries_output' => true }, epw_path)

    return true
  end

  def test_cz4C_warehouse
    test_name = 'test_cz4C_warehouse'
    test_model_name = 'CZ4C_warehouse_100001_200000_PVAV with PFP boxes.osm'
    test_model_path = "#{__dir__}/#{test_model_name}"
    epw_path = "#{__dir__}/G5300670.epw"

    # set the arguments to test
    args_hash = {}

    # run the measure
    run_in_workflow(test_name, test_model_path, args_hash, epw_path)

    return true
  end

  def test_cz2A_retail
    test_name = 'test_cz2A_retail'
    test_model_name = 'CZ2A_retail.osm'
    test_model_path = "#{__dir__}/#{test_model_name}"
    epw_path = "#{__dir__}/G1300990.epw"

    # set the arguments to test
    args_hash = {}

    # run the measure
    run_in_workflow(test_name, test_model_path, args_hash, epw_path)
    # test with timeseries output

    run_in_workflow("#{test_name}_timeseries", test_model_path, { 'timeseries_output' => true }, epw_path)

    return true
  end

  def test_cz2A_retail_adiabatic
    test_name = 'test_cz2A_retail_adiabatic'
    test_model_name = 'CZ2A_retail_adiabatic.osm'
    test_model_path = "#{__dir__}/#{test_model_name}"
    epw_path = "#{__dir__}/G1300990.epw"

    # set the arguments to test
    args_hash = {}

    # run the measure
    run_in_workflow(test_name, test_model_path, args_hash, epw_path)
    # test with timeseries output

    run_in_workflow("#{test_name}_timeseries", test_model_path, { 'timeseries_output' => true }, epw_path)

    return true
  end
end
