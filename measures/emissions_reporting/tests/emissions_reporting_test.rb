# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'csv'
require 'fileutils'
require 'minitest/autorun'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'comstock-typical'
require_relative '../measure'

class EmissionsReportingTest < Minitest::Test
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

  def workspace_path(test_name)
    "#{run_dir(test_name)}/run/in.idf"
  end

  def report_path(test_name)
    return "#{run_dir(test_name)}/reports/eplustbl.html"
  end

  def test_number_of_arguments_and_argument_names
    # this test ensures that the current test is matched to the measure inputs
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = EmissionsReporting.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(3, arguments.size)
    assert_equal('grid_region', arguments[0].name)
    assert_equal('grid_state', arguments[1].name)
    assert_equal('emissions_scenario', arguments[2].name)
  end

  def print_step_values(result_h)
    CSV.open(File.join(run_dir('test_all_scenarios'), 'step_vals.csv'), 'w') do |csv|
      result_h['step_values'].each do |h|
        csv << [h['name']]
      end
    end
  end

  # process output names and field descriptions for comstock_column_definitions.csv
  def print_column_definitions(result_h, test_name)
    regex = /annual_?(.*)_(electricity|natural_gas|fuel_oil|propane|district_cooling|district_heating)_ghg_emissions_?(.*)_kg/
    result = ''
    result_h['step_values'].each do |h|
      result_string = "\nresults.csv,emissions_reporting."
      value_name = h['name']
      # make new col name
      result_string << "#{value_name},out.emissions"
      captures = value_name.scan(regex).flatten
      next if captures.empty?

      # fuel type
      fuel_type = captures[1]
      result_string << ".#{fuel_type}" unless fuel_type.empty?
      # end use
      end_use = captures[0]
      if end_use.include?('hvac')
        result_string << '.enduse_group.hvac'
      else
        result_string << ".#{end_use}" unless end_use.empty?
      end
      # scenario
      scenario = captures[2]

      if scenario.include?('egrid')
        result_string << ".#{scenario}"
        field_desc_string = "#{scenario.gsub('_', ' ').gsub('egrid', 'eGRID')} emissions intensity values"
      elsif scenario.include?('aer')
        result_string << ".#{scenario}_from_2023"
        field_desc_string = "Cambium 2022 #{scenario.gsub('_', ' ').gsub('aer', 'Average Emissions Rate').gsub('re', 'renewable energy').gsub('95', '95%')} non-levelized emissions intensity values from 2023"
      elsif scenario.include?('lrmer')
        field_desc_string = "Cambium 2022 #{scenario.gsub('_', ' ').gsub('lrmer', 'Long-Range Marginal Emissions Rate').gsub('re', 'renewable energy').gsub('95', '95%').gsub(/\s\d{2}$/, '').gsub(/\s\d{2}\s\d{4}\sstart/, '')} emissions intensity values "
        if scenario.match?(/_\d{2}_\d{4}_/)
          result_string << ".#{scenario}"
          matches = scenario.scan(/_(\d{2})_(\d{4})_start/).flatten
          field_desc_string << "levelized over #{matches[0]} years starting in #{matches[1]}"
        else
          result_string << ".#{scenario}_2023_start"
          matches = scenario.scan(/_\w{4}_(\d{2})/).flatten
          field_desc_string << "levelized over #{matches[0]} years starting in 2023"
        end
      end

      # full_metadata, basic_metadata, data_type, original_units, new_units
      result_string << ',TRUE,FALSE,float,co2e_kg,co2e_kg'

      # if end_use.empty?
      #   # include total emissions in basic metadata
      #   result_string << ',TRUE,TRUE,float,co2e_kg,co2e_kg'
      # else
      #   # only include end-use emissions in full metadata
      #   result_string << ',TRUE,FALSE,float,co2e_kg,co2e_kg'
      # end

      # process fuel string
      if end_use.empty?
        fuel_str = "total on-site #{fuel_type.gsub('_', ' ')}"
      else
        fuel_str = fuel_type.gsub('_', ' ').to_s
      end

      # end-use string
      end_use_str = "on-site #{end_use.gsub('_', ' ')}"

      # construct field_description
      if end_use.empty? && scenario.empty?
        # total non-electric fuel
        result_string << ",annual greenhouse gas emissions from #{fuel_str} use"
      elsif end_use.empty?
        # total electricity with case
        result_string << ",annual greenhouse gas emissions from #{fuel_str} use using #{field_desc_string}"
      elsif scenario.empty?
        # non-elec fuel with end-use
        result_string << ",annual greenhouse gas emissions from #{end_use_str} #{fuel_str} use"
      else
        # electricty end-use with case
        result_string << ",annual greenhouse gas emissions from #{end_use_str} #{fuel_str} use with #{field_desc_string}"
      end
      result << result_string
    end

    CSV.open(File.join(run_dir(test_name), 'emissions_columns.csv'), 'w') do |csv|
      result.split("\n").each do |row|
        csv << row.split(',')
      end
    end
  end

  def run_test(test_name, osm_path, epw_path, argument_map)
    # create run directory if it does not exist
    FileUtils.mkdir_p(run_dir(test_name))
    assert(File.exist?(run_dir(test_name)))

    # change into run directory for tests
    start_dir = Dir.pwd
    begin
      Dir.chdir run_dir(test_name)

      # create an instance of the measure
      measure = EmissionsReporting.new

      # create an instance of a runner
      runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

      # Load the input model to set up runner, this will happen automatically when measure is run in PAT or OpenStudio
      translator = OpenStudio::OSVersion::VersionTranslator.new
      model = translator.loadModel(osm_path)
      assert(model.is_initialized)
      model = model.get
      runner.setLastOpenStudioModel(model)

      # get the energyplus output requests, this will be done automatically by OS App and PAT
      idf_output_requests = measure.energyPlusOutputRequests(runner, argument_map)

      # convert output requests to OSM for testing, OS App and PAT will add these to the E+ Idf
      workspace = OpenStudio::Workspace.new('Draft'.to_StrictnessLevel, 'EnergyPlus'.to_IddFileType)
      workspace.addObjects(idf_output_requests)
      rt = OpenStudio::EnergyPlus::ReverseTranslator.new
      request_model = rt.translateWorkspace(workspace)

      # load the test model and add output requests
      translator = OpenStudio::OSVersion::VersionTranslator.new
      model = translator.loadModel(OpenStudio::Path.new(osm_path))
      assert(!model.empty?)
      model = model.get
      request_model.objects.each { |o| model.addObject(o) }
      # model.addObjects(request_model.objects)
      model.save(model_output_path(test_name), true)

      # set model weather file
      assert(File.exist?(epw_path))
      epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(epw_path))
      OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
      assert(model.weatherFile.is_initialized)

      # run the simulation if necessary
      unless File.exist?(sql_path(test_name))
        puts "\nRUNNING ANNUAL RUN FOR #{test_name}..."

        std = Standard.build('90.1-2013')
        std.model_run_simulation_and_log_errors(model, run_dir(test_name))
      end
      assert(File.exist?(model_output_path(test_name)))
      assert(File.exist?(sql_path(test_name)))

      # set up runner, this will happen automatically when measure is run in PAT or OpenStudio
      runner.setLastOpenStudioModelPath(OpenStudio::Path.new(model_output_path(test_name)))
      runner.setLastEnergyPlusWorkspacePath(OpenStudio::Path.new(workspace_path(test_name)))
      runner.setLastEpwFilePath(epw_path)
      runner.setLastEnergyPlusSqlFilePath(OpenStudio::Path.new(sql_path(test_name)))

      # run the measure
      puts "\nRUNNING MEASURE RUN FOR #{test_name}..."
      measure.run(runner, argument_map)
      result = runner.result
      show_output(result)
      assert_equal('Success', result.value.valueName)
    ensure
      # change back directory
      Dir.chdir(start_dir)
    end

    return result
  end

  def test_timeseries_lrmer
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/smalloffice.osm"
    epw_path = "#{__dir__}/FortCollins2016.epw"

    # create an instance of the measure
    measure = EmissionsReporting.new

    # set arguments
    arguments = measure.arguments(OpenStudio::Model::Model.new)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    grid_region = arguments[0].clone
    grid_state = arguments[1].clone
    emissions_scenario = arguments[2].clone
    assert(grid_region.setValue('Lookup from model'))
    assert(grid_state.setValue('Lookup from model'))
    assert(emissions_scenario.setValue('LRMER_MidCase_15'))
    argument_map['grid_region'] = grid_region
    argument_map['grid_state'] = grid_state
    argument_map['emissions_scenario'] = emissions_scenario

    assert(run_test(__method__, osm_path, epw_path, argument_map))
  end

  def test_all_scenarios
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/smalloffice.osm"
    epw_path = "#{__dir__}/FortCollins2016.epw"

    # create an instance of the measure
    measure = EmissionsReporting.new

    # set arguments
    arguments = measure.arguments(OpenStudio::Model::Model.new)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    grid_region = arguments[0].clone
    grid_state = arguments[1].clone
    emissions_scenario = arguments[2].clone
    assert(grid_region.setValue('RMPAc'))
    assert(grid_state.setValue('Lookup from model'))
    assert(emissions_scenario.setValue('All'))
    argument_map['grid_region'] = grid_region
    argument_map['grid_state'] = grid_state
    argument_map['emissions_scenario'] = emissions_scenario

    result = run_test(__method__, osm_path, epw_path, argument_map)
    assert(result)
    require 'json'
    result_h = JSON.parse(result.to_s)
    # test that runperiod totals same as summed hourly
    assert_in_delta(3384.63, result_h['step_values'].select { |v| v['name'] == 'annual_natural_gas_ghg_emissions_kg' }.first['value'], 0.1)

    # test that all electricity emissions are > 0
    result_h['step_values'].select { |v| v['name'].include?('cooling_electricity') }.each do |step_result|
      assert(step_result['value'] > 0, "Result for #{step_result['name']} is zero")
    end

    print_step_values(result_h)
    print_column_definitions(result_h, __method__)
  end

  def test_hawaii
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/smalloffice.osm"
    epw_path = "#{__dir__}/FortCollins2016.epw"

    # create an instance of the measure
    measure = EmissionsReporting.new

    # set arguments
    arguments = measure.arguments(OpenStudio::Model::Model.new)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    grid_region = arguments[0].clone
    grid_state = arguments[1].clone
    emissions_scenario = arguments[2].clone
    assert(grid_region.setValue('HIMS'))
    assert(grid_state.setValue('Lookup from model'))
    assert(emissions_scenario.setValue('LRMER_MidCase_15'))
    argument_map['grid_region'] = grid_region
    argument_map['grid_state'] = grid_state
    argument_map['emissions_scenario'] = emissions_scenario

    assert(run_test(__method__, osm_path, epw_path, argument_map))
  end

  def test_district_energy
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/../../../resources/tests/models/LargeOffice_VAV_district_chw_hw.osm"
    epw_path = "#{__dir__}/FortCollins2016.epw"

    # create an instance of the measure
    measure = EmissionsReporting.new

    # set arguments
    arguments = measure.arguments(OpenStudio::Model::Model.new)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    grid_region = arguments[0].clone
    grid_state = arguments[1].clone
    emissions_scenario = arguments[2].clone
    assert(grid_region.setValue('Lookup from model'))
    assert(grid_state.setValue('Lookup from model'))
    assert(emissions_scenario.setValue('LRMER_MidCase_15'))
    argument_map['grid_region'] = grid_region
    argument_map['grid_state'] = grid_state
    argument_map['emissions_scenario'] = emissions_scenario

    assert(run_test(__method__, osm_path, epw_path, argument_map))
  end

  def test_propane
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/../../../resources/tests/models/Quick_Service_Restaurant_Pre1980_3A.osm"
    epw_path = "#{__dir__}/FortCollins2016.epw"

    # create an instance of the measure
    measure = EmissionsReporting.new

    # set arguments
    arguments = measure.arguments(OpenStudio::Model::Model.new)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    grid_region = arguments[0].clone
    grid_state = arguments[1].clone
    emissions_scenario = arguments[2].clone
    assert(grid_region.setValue('Lookup from model'))
    assert(grid_state.setValue('Lookup from model'))
    assert(emissions_scenario.setValue('LRMER_MidCase_15'))
    argument_map['grid_region'] = grid_region
    argument_map['grid_state'] = grid_state
    argument_map['emissions_scenario'] = emissions_scenario

    assert(run_test(__method__, osm_path, epw_path, argument_map))
  end
end
