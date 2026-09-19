# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'csv'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require_relative '../measure'

class TimeseriesCSVExportTest < Minitest::Test
  def openstudio_2?
    begin
      OpenStudio::WorkflowJSON.new
    rescue StandardError
      return false
    end
    true
  end

  def model_in_path_default
    "#{__dir__}/ExampleModel.osm"
  end

  def epw_path_default
    # make sure we have a weather data location
    epw = OpenStudio::Path.new("#{__dir__}/USA_CO_Golden-NREL.724666_TMY3.epw")
    assert(File.exist?(epw.to_s))
    epw.to_s
  end

  def run_dir(test_name)
    # always generate test output in specially named 'output' directory so result files are not made part of the measure
    "#{__dir__}/output/#{test_name}/run"
  end

  def model_out_path(test_name)
    "#{run_dir(test_name)}/TestOutput.osm"
  end

  def workspace_path(test_name)
    return "#{run_dir(test_name)}/run/in.idf" if openstudio_2?


    "#{run_dir(test_name)}/ModelToIdf/in.idf"
  end

  def sql_path(test_name)
    return "#{run_dir(test_name)}/run/eplusout.sql" if openstudio_2?


    "#{run_dir(test_name)}/ModelToIdf/EnergyPlusPreProcess-0/EnergyPlus-0/eplusout.sql"
  end

  def report_path(test_name)
    "#{run_dir(test_name)}/run/enduse_timeseries.csv"
  end

  # method for running the test simulation using OpenStudio 1.x API
  def setup_test_1(test_name, epw_path)
    co = OpenStudio::Runmanager::ConfigOptions.new(true)
    co.findTools(false, true, false, true)

    return if File.exist?(sql_path(test_name))

    puts 'Running EnergyPlus'

    wf = OpenStudio::Runmanager::Workflow.new('modeltoidf->energypluspreprocess->energyplus')
    wf.add(co.getTools)
    job = wf.create(OpenStudio::Path.new(run_dir(test_name)), OpenStudio::Path.new(model_out_path(test_name)),
                    OpenStudio::Path.new(epw_path))

    rm = OpenStudio::Runmanager::RunManager.new
    rm.enqueue(job, true)
    rm.waitForFinished
  end

  # method for running the test simulation using OpenStudio 2.x API
  def setup_test_2(test_name, epw_path)
    unless File.exist?(sql_path(test_name))
      osw_path = File.join(run_dir(test_name), 'in.osw')
      osw_path = File.absolute_path(osw_path)

      workflow = OpenStudio::WorkflowJSON.new
      workflow.setSeedFile(File.absolute_path(model_out_path(test_name)))
      workflow.setWeatherFile(File.absolute_path(epw_path))
      workflow.saveAs(osw_path)

      cli_path = OpenStudio.getOpenStudioCLI
      cmd = "\"#{cli_path}\" run -w \"#{osw_path}\""

      # blank out bundler and gem path modifications, will be re-setup by new call
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

      stdout_str, stderr_str, status = Open3.capture3(new_env, cmd)

      unless status.success?
        puts("Error running command: '#{cmd}'")
        puts("stdout: #{stdout_str}")
        puts("stderr: #{stderr_str}")
        cmd2 = "\"#{cli_path}\" gem_list"
        stdout_str_2, = Open3.capture3(new_env, cmd2)
        puts("Gems available to openstudio cli according to (openstudio gem_list): \n #{stdout_str_2}")
      end
    end

    true
  end

  # create test files if they do not exist when the test first runs
  def setup_test(test_name, measure, argument_map, idf_output_requests, model_in_path = model_in_path_default,
                 epw_path = epw_path_default)
    FileUtils.mkdir_p(run_dir(test_name))
    assert(File.exist?(run_dir(test_name)))
    FileUtils.rm_f(report_path(test_name))
    assert(File.exist?(model_in_path))
    FileUtils.rm_f(model_out_path(test_name))

    # convert output requests to OSM for testing, OS App and PAT will add these to the E+ Idf
    workspace = OpenStudio::Workspace.new('Draft'.to_StrictnessLevel, 'EnergyPlus'.to_IddFileType)
    workspace.addObjects(idf_output_requests)
    rt = OpenStudio::EnergyPlus::ReverseTranslator.new
    request_model = rt.translateWorkspace(workspace)

    translator = OpenStudio::OSVersion::VersionTranslator.new
    model = translator.loadModel(model_in_path)
    assert(!model.empty?)
    model = model.get
    model.addObjects(request_model.objects)

    # add the reporting-related model objects requested by the measure, in this case the request
    # for the native EnergyPlus CSV output.  The C++ CLI does this automatically when the measure
    # is run as part of a workflow.
    measure.modelOutputRequests(model, OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new), argument_map)

    model.save(model_out_path(test_name), true)

    FileUtils.rm_f(sql_path(test_name)) if ENV['OPENSTUDIO_TEST_NO_CACHE_SQLFILE'] && File.exist?(sql_path(test_name))

    if openstudio_2?
      setup_test_2(test_name, epw_path)
    else
      setup_test_1(test_name, epw_path)
    end
  end

  # assert that no section errors were thrown
  def section_errors(runner)
    test_string = 'section failed and was skipped because'

    if openstudio_2?
      section_errors = []
      runner.result.stepWarnings.each do |warning|
        section_errors << warning if warning.include?(test_string)
      end
      assert(section_errors.empty?)
    else
      section_errors = []
      runner.result.warnings.each do |warning|
        section_errors << warning if warning.logMessage.include?(test_string)
      end
      assert(section_errors.empty?)
    end

    section_errors
  end

  # assert that the exported timeseries has the timestamp columns, at least one end use,
  # and at least one row of results
  def assert_report_contents(test_name)
    rows = CSV.read(report_path(test_name))
    header = rows.first
    assert_equal(['Time', 'TimeDST', 'TimeUTC'], header[0..2])
    assert(header.include?('total_site_electricity_kwh'))
    assert(rows.size > 1, "Expected timeseries results in #{report_path(test_name)}, but found no rows")
  end

  def test_sm_hotel
    test_name = 'sm_hotel'
    model_in_path = "#{__dir__}/1004_SmallHotel_a.osm"

    # create an instance of the measure
    measure = TimeseriesCSVExport.new

    # create an instance of a runner
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

    # get arguments
    arguments = measure.arguments
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # create hash of argument values
    args_hash = {
      'reporting_frequency' => 'Timestep',
      'inc_output_variables' => true
    }

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      assert(temp_arg_var.setValue(args_hash[arg.name])) if args_hash[arg.name]
      argument_map[arg.name] = temp_arg_var
    end

    # get the energyplus output requests, this will be done automatically by OS App and PAT
    idf_output_requests = measure.energyPlusOutputRequests(
      OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new), argument_map
    )
    assert(!idf_output_requests.empty?, 'Expected IDF output requests, but none were found')

    # mimic the process of running this measure in OS App or PAT
    epw_path_default
    setup_test(test_name, measure, argument_map, idf_output_requests, model_in_path)

    assert(File.exist?(model_out_path(test_name)))
    assert(File.exist?(sql_path(test_name)), "Could not find sql file at #{sql_path(test_name)}")
    # assert(File.exist?(''))

    # set up runner, this will happen automatically when measure is run in PAT or OpenStudio
    runner.setLastOpenStudioModelPath(OpenStudio::Path.new(model_out_path(test_name)))
    runner.setLastEnergyPlusWorkspacePath(OpenStudio::Path.new(workspace_path(test_name)))
    runner.setLastEpwFilePath('')
    runner.setLastEnergyPlusSqlFilePath(OpenStudio::Path.new(sql_path(test_name)))

    # delete the output if it exists
    FileUtils.rm_f(report_path(test_name))
    assert(!File.exist?(report_path(test_name)))

    # temporarily change directory to the run directory and run the measure
    start_dir = Dir.pwd
    begin
      Dir.chdir(run_dir(test_name))

      # run the measure
      start_time = Time.new
      measure.run(runner, argument_map)
      end_time = Time.new
      puts "*********Timing: measure elapsed time = #{end_time - start_time}"
      result = runner.result
      show_output(result)
      assert_equal('Success', result.value.valueName)

      # look for section_errors
      assert(section_errors(runner).empty?)
    ensure
      Dir.chdir(start_dir)
    end

    # make sure the report file exists and holds the expected timeseries
    assert(File.exist?(report_path(test_name)))
    assert_report_contents(test_name)
  end

  def test_restaurant
    test_name = 'restaurant'
    model_in_path = "#{__dir__}/FullServiceRestaurant.osm"

    # create an instance of the measure
    measure = TimeseriesCSVExport.new

    # create an instance of a runner
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

    # get arguments
    arguments = measure.arguments
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # create hash of argument values
    args_hash = {
      'reporting_frequency' => 'Timestep',
      'inc_output_variables' => true
    }

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      assert(temp_arg_var.setValue(args_hash[arg.name])) if args_hash[arg.name]
      argument_map[arg.name] = temp_arg_var
    end

    # get the energyplus output requests, this will be done automatically by OS App and PAT
    idf_output_requests = measure.energyPlusOutputRequests(
      OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new), argument_map
    )
    assert(!idf_output_requests.empty?, 'Expected IDF output requests, but none were found')

    # mimic the process of running this measure in OS App or PAT
    epw_path_default
    setup_test(test_name, measure, argument_map, idf_output_requests, model_in_path)

    assert(File.exist?(model_out_path(test_name)))
    assert(File.exist?(sql_path(test_name)), "Could not find sql file at #{sql_path(test_name)}")
    # assert(File.exist?(''))

    # set up runner, this will happen automatically when measure is run in PAT or OpenStudio
    runner.setLastOpenStudioModelPath(OpenStudio::Path.new(model_out_path(test_name)))
    runner.setLastEnergyPlusWorkspacePath(OpenStudio::Path.new(workspace_path(test_name)))
    runner.setLastEpwFilePath('')
    runner.setLastEnergyPlusSqlFilePath(OpenStudio::Path.new(sql_path(test_name)))

    # delete the output if it exists
    FileUtils.rm_f(report_path(test_name))
    assert(!File.exist?(report_path(test_name)))

    # temporarily change directory to the run directory and run the measure
    start_dir = Dir.pwd
    begin
      Dir.chdir(run_dir(test_name))

      # run the measure
      start_time = Time.new
      measure.run(runner, argument_map)
      end_time = Time.new
      puts "*********Timing: measure elapsed time = #{end_time - start_time}"
      result = runner.result
      show_output(result)
      assert_equal('Success', result.value.valueName)

      # look for section_errors
      assert(section_errors(runner).empty?)
    ensure
      Dir.chdir(start_dir)
    end

    # make sure the report file exists
    assert(File.exist?(report_path(test_name)))
    assert_report_contents(test_name)

    # make sure that the expected columns are in the file
    File.open(report_path(test_name), 'r').each_with_index do |line, i|
      next unless i == 0

      cols = line.split(',')
      # Electricity
      assert(cols.include?('total_site_electricity_kwh'))
      assert(cols.include?('total_net_site_electricity_kwh'))
      assert(cols.include?('total_purchased_site_electricity_kwh'))
      assert(cols.include?('electricity_heating_kwh'))
      assert(cols.include?('electricity_cooling_kwh'))
      assert(cols.include?('electricity_interior_lighting_kwh'))
      assert(cols.include?('electricity_interior_equipment_kwh'))
      assert(cols.include?('electricity_exterior_lighting_kwh'))
      assert(cols.include?('electricity_fans_kwh'))
      assert(cols.include?('electricity_pumps_kwh'))
      assert(cols.include?('electricity_refrigeration_kwh'))
      assert(cols.include?('electricity_water_systems_kwh'))
      assert(!cols.include?('electricity_exterior_equipment_kwh'))
      assert(!cols.include?('electricity_heat_rejection_kwh'))
      assert(!cols.include?('electricity_humidification_kwh'))
      assert(!cols.include?('electricity_heat_recovery_kwh'))
      assert(!cols.include?('electricity_generators_kwh'))
      assert(!cols.include?('electricity_pv_kwh'))
      # Natural Gas
      assert(cols.include?('total_site_gas_kbtu'))
      assert(cols.include?('gas_interior_equipment_kbtu'))
      assert(cols.include?('gas_water_systems_kbtu'))
      assert(!cols.include?('gas_heating_kbtu'))
      assert(!cols.include?('gas_exterior_equipment_kbtu'))
      # Fuel Oil No 2
      assert(cols.include?('total_site_fueloil_kbtu'))
      assert(cols.include?('fueloil_water_systems_kbtu'))
      assert(!cols.include?('fueloil_heating_kbtu'))
      # Propane
      assert(cols.include?('total_site_propane_kbtu'))
      assert(cols.include?('propane_water_systems_kbtu'))
      assert(!cols.include?('propane_heating_kbtu'))
      # District Heating
      assert(!cols.include?('total_site_districtheating_kbtu'))
      assert(!cols.include?('districtheating_water_systems_kbtu'))
      assert(!cols.include?('districtheating_heating_kbtu'))
      # District Cooling
      assert(!cols.include?('total_site_districtcooling_kbtu'))
      assert(!cols.include?('districtcooling_cooling_kbtu'))
      # Water
      assert(cols.include?('total_site_water_gal'))
      assert(!cols.include?('cooling_gal'))
      assert(cols.include?('water_systems_gal'))
      assert(!cols.include?('heat_rejection_gal'))
    end
  end

  def test_retail
    test_name = 'retail'
    model_in_path = "#{__dir__}/Retail.osm"

    # create an instance of the measure
    measure = TimeseriesCSVExport.new

    # create an instance of a runner
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

    # get arguments
    arguments = measure.arguments
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # get the energyplus output requests, this will be done automatically by OS App and PAT
    idf_output_requests = measure.energyPlusOutputRequests(
      OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new), argument_map
    )
    assert(!idf_output_requests.empty?, 'Expected IDF output requests, but none were found')

    # mimic the process of running this measure in OS App or PAT
    epw_path_default
    setup_test(test_name, measure, argument_map, idf_output_requests, model_in_path)

    assert(File.exist?(model_out_path(test_name)))
    assert(File.exist?(sql_path(test_name)), "Could not find sql file at #{sql_path(test_name)}")
    # assert(File.exist?(''))

    # set up runner, this will happen automatically when measure is run in PAT or OpenStudio
    runner.setLastOpenStudioModelPath(OpenStudio::Path.new(model_out_path(test_name)))
    runner.setLastEnergyPlusWorkspacePath(OpenStudio::Path.new(workspace_path(test_name)))
    runner.setLastEpwFilePath('')
    runner.setLastEnergyPlusSqlFilePath(OpenStudio::Path.new(sql_path(test_name)))

    # delete the output if it exists
    FileUtils.rm_f(report_path(test_name))
    assert(!File.exist?(report_path(test_name)))

    # temporarily change directory to the run directory and run the measure
    start_dir = Dir.pwd
    begin
      Dir.chdir(run_dir(test_name))

      # run the measure
      start_time = Time.new
      measure.run(runner, argument_map)
      end_time = Time.new
      puts "*********Timing: measure elapsed time = #{end_time - start_time}"
      result = runner.result
      show_output(result)
      assert_equal('Success', result.value.valueName)

      # look for section_errors
      assert(section_errors(runner).empty?)
    ensure
      Dir.chdir(start_dir)
    end

    # make sure the report file exists and holds the expected timeseries
    assert(File.exist?(report_path(test_name)))
    assert_report_contents(test_name)
  end
end
