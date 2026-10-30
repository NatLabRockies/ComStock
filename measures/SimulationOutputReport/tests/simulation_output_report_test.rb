# ComStock™, Copyright (c) 2024 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'fileutils'
require 'minitest/autorun'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'comstock-typical'
require_relative '../measure'

class SimulationOutputReportTest < Minitest::Test
  def run_dir(test_name)
    # always generate test output in specially named 'output' directory so result files are not made part of the measure
    return "#{__dir__}/output/#{test_name}"
  end

  def model_output_path(test_name)
    return "#{run_dir(test_name)}/out.osm"
  end

  def workspace_path(test_name)
    return "#{run_dir(test_name)}/run/in.idf"
  end

  def sql_path(test_name)
    return "#{run_dir(test_name)}/run/eplusout.sql"
  end

  def report_path(test_name)
    return "#{run_dir(test_name)}/reports/eplustbl.html"
  end

  def run_test(test_name, osm_path, epw_path)
    # create run directory if it does not exist
    FileUtils.mkdir_p(run_dir(test_name))
    assert(File.exist?(run_dir(test_name)))

    # change into run directory for tests
    start_dir = Dir.pwd
    begin
      Dir.chdir run_dir(test_name)

      # create an instance of the measure
      measure = SimulationOutputReport.new

      # create an instance of a runner
      runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

      # Load the input model to set up runner, this will happen automatically when measure is run in PAT or OpenStudio
      translator = OpenStudio::OSVersion::VersionTranslator.new
      model = translator.loadModel(osm_path)
      assert(model.is_initialized)
      model = model.get
      runner.setLastOpenStudioModel(model)

      # get arguments
      arguments = measure.arguments
      argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

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
      model.addObjects(request_model.objects)
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

      # delete the output if it exists

      FileUtils.rm_f(report_path(test_name))

      assert(!File.exist?(report_path(test_name)))

      # run the measure
      puts "\nRUNNING MEASURE RUN FOR #{test_name}..."
      measure.run(runner, argument_map)
      result = runner.result
      show_output(result)

      # log result to file for comparisons
      values = result.stepValues.map(&:string)
      File.write("#{run_dir(test_name)}/output.txt", "[\n#{values.join(',').strip}\n]")

      assert_equal('Success', result.value.valueName)
    ensure
      # change back directory
      Dir.chdir(start_dir)
    end

    return true
  end

  def test_number_of_arguments_and_argument_names
    # this test ensures that the current test is matched to the measure inputs
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = SimulationOutputReport.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments
    assert_equal(0, arguments.size)
  end

  def test_fuel_oil_boiler
    # fuel_oil_boiler
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0000034.osm"
    epw_path = "#{__dir__}/USA_MD_Baltimore-Washington.Intl.AP.724060_TMY3.epw"
    assert(run_test(__method__, osm_path, epw_path))
    sql = OpenStudio::SqlFile.new(sql_path("#{__method__}"))
    assert(sql.fuelOilNo2TotalEndUses.get > 0)
    assert(sql.fuelOilNo2Heating.get > 0)
  end

  def test_propane_boiler
    # propane_boiler
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0000090.osm"
    epw_path = "#{__dir__}/USA_NV_Nellis.Afb.723865_2012.epw"
    assert(run_test(__method__, osm_path, epw_path))
    sql = OpenStudio::SqlFile.new(sql_path("#{__method__}"))
    assert(sql.propaneTotalEndUses.get > 0)
    assert(sql.propaneHeating.get > 0)
  end

  def test_heat_pump_boiler_1
    # heat_pump_boiler_1
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/heat_pump_boiler_1.osm"
    epw_path = "#{__dir__}/USA_MN_Duluth.Intl.AP.727450_TMY.epw"
    assert(run_test(__method__, osm_path, epw_path))
    sql = OpenStudio::SqlFile.new(sql_path("#{__method__}"))
    assert(sql.electricityHeating.get > 0)
    assert(sql.naturalGasHeating.get == 0)
  end
end
