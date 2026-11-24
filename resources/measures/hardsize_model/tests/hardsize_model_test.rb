# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'fileutils'
require_relative '../../../../test/helpers/minitest_helper'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require_relative '../measure'

class HardsizeModelTest < Minitest::Test
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

  def model_input_path(osm_name)
    return File.join(File.dirname(__FILE__), '../../../tests/models', osm_name)
  end

  def epw_input_path(epw_name)
    return File.join(File.dirname(__FILE__), '../../../tests/weather', epw_name)
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

  def populate_argument_map(measure, osm_path, args_hash)
    # Load the model; only used here for populating arguments
    model = load_model(osm_path)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure::OSArgumentMap.new

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      if args_hash.key?(arg.name)
        assert(temp_arg_var.setValue(args_hash[arg.name]))
      end
      argument_map[arg.name] = temp_arg_var
    end

    return argument_map
  end

  # Runs the model, applies the measure, reruns the model, and checks that
  # before/after annual energy consumption results are identical
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

    # Change the runperiod to 1 week for testing only
    run_period = model.getRunPeriod
    run_period.setBeginMonth(4)
    run_period.setBeginDayOfMonth(1)
    run_period.setEndMonth(4)
    run_period.setEndDayOfMonth(15)
    run_period.setNumTimePeriodRepeats(1)

    # Run simulation for sizing periods
    sim_control = model.getSimulationControl
    sim_control.setDoZoneSizingCalculation(true)
    sim_control.setDoSystemSizingCalculation(true)
    sim_control.setDoPlantSizingCalculation(true)

    # temporarily change directory to the run directory and run the measure
    # only necessary for measures that do a sizing run
    start_dir = Dir.pwd
    begin
      Dir.chdir(run_dir(test_name))

      # Run the model before applying the measure and get annual energy consumption
      std = Standard.build('90.1-2013')
      if run_model
        puts "\nRUNNING MODEL BEFORE MEASURE..."
        assert(std.model_run_simulation_and_log_errors(model, File.join(run_dir(test_name), 'before')))
      end
      tot_engy_bef = model.sqlFile.get.totalSiteEnergy.get

      # Run the measure
      puts "\nAPPLYING MEASURE..."
      measure.run(model, runner, argument_map)
      result = runner.result

      # Show the output
      show_output(result)

      # Save model
      model.save(model_output_path(test_name), true)

      # Run the model after applying the measure and get annual energy consumption
      if run_model && (result.value.valueName == 'Success')
        puts "\nRUNNING MODEL AFTER MEASURE..."

        assert(std.model_run_simulation_and_log_errors(model, File.join(run_dir(test_name), 'after')))
        tot_engy_aft = model.sqlFile.get.totalSiteEnergy.get
      end

      # Assert that there was no change in energy consumption caused by
      # hard-sizing the model.
      assert_in_delta(tot_engy_bef, tot_engy_aft, 1.0)
    ensure
      # change back directory
      Dir.chdir(start_dir)
    end

    return result
  end

  def test_number_of_arguments_and_argument_names
    # Create an instance of the measure
    measure = HardsizeModel.new

    # Make an empty model
    model = OpenStudio::Model::Model.new

    # Get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(1, arguments.size)
    assert_equal('apply_hardsize', arguments[0].name)
  end

  def test_outpatient_vav_chiller_pfp_boxes
    osm_name = 'Outpatient_VAV_chiller_PFP_boxes.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = HardsizeModel.new
    args_hash = { 'apply_hardsize' => true }
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  def test_largeoffice_vav_district_chw_hw
    osm_name = 'LargeOffice_VAV_district_chw_hw.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = HardsizeModel.new
    args_hash = { 'apply_hardsize' => true }
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  def test_largeoffice_vav_chiller_boiler
    osm_name = 'LargeOffice_VAV_chiller_boiler.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = HardsizeModel.new
    args_hash = { 'apply_hardsize' => true }
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  def test_largeoffice_vav_chiller_boiler_2
    osm_name = 'LargeOffice_VAV_chiller_boiler_2.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = HardsizeModel.new
    args_hash = { 'apply_hardsize' => true }
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  def test_retail_pvav_gas_ht_elec_rht
    osm_name = 'Retail_PVAV_gas_ht_elec_rht.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = HardsizeModel.new
    args_hash = { 'apply_hardsize' => true }
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  def test_secondaryschool_pthp
    osm_name = 'SecondarySchool_PTHP.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = HardsizeModel.new
    args_hash = { 'apply_hardsize' => true }
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end

  def test_retail_psz_ac
    osm_name = 'Retail_PSZ-AC.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'
    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)
    measure = HardsizeModel.new
    args_hash = { 'apply_hardsize' => true }
    argument_map = populate_argument_map(measure, osm_path, args_hash)
    # Apply the measure and check if before/after results are identical
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: true)
  end
end
