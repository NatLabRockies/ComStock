# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2018, Alliance for Sustainable Energy, LLC.
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# (1) Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# (2) Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# (3) Neither the name of the copyright holder nor the names of any contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission from the respective party.
#
# (4) Other than as required in clauses (1) and (2), distributions in any form
# of modifications or other derivative works may not use the "OpenStudio"
# trademark, "OS", "os", or any other confusingly similar designation without
# specific prior written permission from Alliance for Sustainable Energy, LLC.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER(S) AND ANY CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
# THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER(S), ANY CONTRIBUTORS, THE
# UNITED STATES GOVERNMENT, OR THE UNITED STATES DEPARTMENT OF ENERGY, NOR ANY OF
# THEIR EMPLOYEES, BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
# OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# *******************************************************************************

# dependencies
require 'openstudio'
require 'comstock-typical'
require 'openstudio/measure/ShowRunnerOutput'
require 'fileutils'
require 'minitest/autorun'
require_relative '../measure'
require 'csv'
require_relative '../../../../test/helpers/minitest_helper'

class HVACEconomizerTest < Minitest::Test
  def test_number_of_arguments_and_argument_names
    # this test ensures that the current test is matched to the measure inputs
    test_name = 'test_number_of_arguments_and_argument_names'
    puts "\n######\nTEST:#{test_name}\n######\n"

    # create an instance of the measure
    measure = HVACEconomizer.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # Get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(0, arguments.size)
  end

  # return file paths to test models in test directory
  def models_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/models/*.osm'))
    paths = paths.map { |path| File.expand_path(path) }
    return paths
  end

  # return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/weather/*.epw'))
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
    return "#{File.dirname(__FILE__)}/output/#{test_name}"
  end

  def model_output_path(test_name)
    return "#{run_dir(test_name)}/#{test_name}.osm"
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

    # create run directory if it does not exist
    FileUtils.mkdir_p(run_dir(test_name))
    assert(File.exist?(run_dir(test_name)))

    # change into run directory for tests
    start_dir = Dir.pwd
    Dir.chdir run_dir(test_name)

    # remove prior runs if they exist
    FileUtils.rm_f(model_output_path(test_name))
    FileUtils.rm_f(report_path(test_name))

    # copy the osm and epw to the test directory
    new_osm_path = "#{run_dir(test_name)}/#{File.basename(osm_path)}"
    FileUtils.cp(osm_path, new_osm_path)
    new_epw_path = "#{run_dir(test_name)}/#{File.basename(epw_path)}"
    FileUtils.cp(epw_path, new_epw_path)
    # create an instance of a runner
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

    # load the test model
    model = load_model(new_osm_path)

    # set model weather file
    epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(new_epw_path))
    OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
    assert(model.weatherFile.is_initialized)

    # run the measure
    puts "\nAPPLYING MEASURE..."
    measure.run(model, runner, argument_map)
    result = runner.result
    result_success = result.value.valueName == 'Success'

    # show the output
    show_output(result)

    # save model
    model.save(model_output_path(test_name), true)

    if run_model && result_success
      puts "\nRUNNING MODEL..."

      std = Standard.build('ComStock DEER 2020')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))

      # check that the model ran successfully
      assert(File.exist?(sql_path(test_name)))
    end

    # change back directory
    Dir.chdir(start_dir)

    return result
  end

  def economizer_available(model)
    economizer_availability = []
    model.getAirLoopHVACs.each do |air_loop_hvac|
      # get airLoopHVACOutdoorAirSystem
      oa_sys = air_loop_hvac.airLoopHVACOutdoorAirSystem
      if oa_sys.is_initialized
        oa_sys = oa_sys.get
      else
        OpenStudio.logFree(OpenStudio::Error, 'openstudio.prototype.Model', "#{air_loop.name} is required to have an economizer, but it has no OA system.")
        next
      end
      # get controller:outdoorair
      oa_control = oa_sys.getControllerOutdoorAir
      # change/check settings: control type
      if oa_control.getEconomizerControlType == 'NoEconomizer'
        economizer_availability << false
      else
        economizer_availability << true
      end
    end
    return economizer_availability.count(true)
  end

  def day_of_year_to_date(year, day_of_year)
    date = Date.new(year, 1, 1) + day_of_year - 1
    month = date.month
    day = date.day
    return month, day
  end

  def run_simulation_and_get_timeseries(model, year, max_doy, num_timesteps_in_hr, timeseriesnames, epw_path = nil, run_dir = "#{Dir.pwd}/output")
    # Make the directory if it doesn't exist
    FileUtils.mkdir_p(run_dir)

    # Load template
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)

    # Initialize runperiod
    begin_month, begin_day = day_of_year_to_date(year, 1)
    end_month, end_day = day_of_year_to_date(year, max_doy)

    # Set runperiod
    model.getYearDescription.setCalendarYear(year)
    model.getRunPeriod.setBeginMonth(begin_month)
    model.getRunPeriod.setBeginDayOfMonth(begin_day)
    model.getRunPeriod.setEndMonth(end_month)
    model.getRunPeriod.setEndDayOfMonth(end_day)
    if num_timesteps_in_hr != 4
      model.getTimestep.setNumberOfTimestepsPerHour(num_timesteps_in_hr)
    end
    model.getSimulationControl.setDoZoneSizingCalculation(false)
    model.getSimulationControl.setDoSystemSizingCalculation(false)
    model.getSimulationControl.setDoPlantSizingCalculation(false)

    # Save model
    osm_name = 'in.osm'
    osw_name = 'in.osw'
    OpenStudio.logFree(OpenStudio::Debug, 'openstudio.model.Model', "Starting simulation here: #{run_dir}.")
    OpenStudio.logFree(OpenStudio::Info, 'openstudio.model.Model', "Started simulation #{run_dir} at #{Time.now.strftime('%T.%L')}")
    osm_path = OpenStudio::Path.new("#{run_dir}/#{osm_name}")
    osw_path = OpenStudio::Path.new("#{run_dir}/#{osw_name}")
    model.save(osm_path, true)

    # Find the weather file
    if epw_path.nil?
      epw_path = OpenstudioStandards::Weather.model_get_full_weather_file_path(model)
      return false if epw_path.empty?

      epw_path = epw_path.get
      # puts epw_path
    end

    # Close current sql file
    model.resetSqlFile
    sql_path = nil

    # Initialize OSW
    begin
      workflow = OpenStudio::WorkflowJSON.new
    rescue NameError
      raise 'Cannot run simulation with OSW approach'
    end

    # Copy the weather file to this directory
    epw_name = 'in.epw'
    begin
      FileUtils.copy(epw_path.to_s, "#{run_dir}/#{epw_name}")
    rescue StandardError
      OpenStudio.logFree(OpenStudio::Error, 'openstudio.model.Model', "Due to limitations on Windows file path lengths, this measure won't work unless your project is located in a directory whose filepath is less than 90 characters long, including slashes.")
      return false
    end

    # Set OSW
    workflow.setSeedFile(osm_name)
    workflow.setWeatherFile(epw_name)
    workflow.saveAs(File.absolute_path(osw_path.to_s))

    # Run simulation
    cli_path = OpenStudio.getOpenStudioCLI
    cmd = "\"#{cli_path}\" run -w \"#{osw_path}\""
    puts cmd
    OpenstudioStandards.run_command(cmd)
    OpenStudio.logFree(OpenStudio::Info, 'openstudio.model.Model', "Finished simulation #{run_dir} at #{Time.now.strftime('%T.%L')}")
    sql_path = OpenStudio::Path.new("#{run_dir}/run/eplusout.sql")

    # Get sql
    sql_file = OpenStudio::SqlFile.new(sql_path)

    # Check available options
    available_env_periods = sql_file.availableEnvPeriods.to_a
    available_time_series = sql_file.availableTimeSeries.to_a
    available_reporting_frequencies = []
    available_env_periods.each do |envperiod|
      sql_file.availableReportingFrequencies(envperiod).to_a.each do |repfreq|
        available_reporting_frequencies << repfreq
      end
    end

    # Hard-code: run period set to 'RUN PERIOD 1'
    envperiod = nil
    raise "options for available_env_periods are not just one: #{available_env_periods}" unless available_env_periods.size == 1

    envperiod = 'RUN PERIOD 1'

    # Hard-code: reporting frequency to zone timestep
    reportingfrequency = 'Zone Timestep'
    unless available_reporting_frequencies.include?(reportingfrequency)
      # puts("### Debugging: Hourly reporting frequency is not available. Use Zone Timestep.")
      reportingfrequency = 'Zone Timestep'
      unless available_reporting_frequencies.include?(reportingfrequency)
        raise "reportingfrequency of #{reportingfrequency} not included in available options: #{available_reporting_frequencies}"
      end
    end

    # Check if timeseries name is available in sql
    timeseriesnames.each do |timeseriesname|
      unless available_env_periods.include?(envperiod)
        raise "envperiod of #{envperiod} not included in available options: #{available_env_periods}"
      end
      # puts("### DEBUGGING: available_time_series = #{available_time_series}")
      unless available_time_series.include?(timeseriesname)
        raise "timeseriesname of #{timeseriesname} not included in available options: #{available_time_series}"
      end
    end

    # Extract timeseries data
    timeseries_results_combined = {}

    timeseriesnames.each do |timeseriesname|
      available_key_values = sql_file.availableKeyValues(envperiod, reportingfrequency, timeseriesname).to_a

      # puts("### ------------------------------------------------")
      # puts("### DEBUGGING: timeseriesname = #{timeseriesname}")
      # puts("### DEBUGGING: available_key_values = #{available_key_values}")

      available_key_values.each do |key_value|
        unless timeseries_results_combined.key?(key_value)
          timeseries_results_combined[key_value] = {}
        end
        timeseries_result = sql_file.timeSeries(envperiod, reportingfrequency, timeseriesname, key_value).get
        vals = []
        elec_vals = timeseries_result.values
        for i in 0..(elec_vals.size - 1)
          vals << elec_vals[i].round(6)
        end
        # raise if vals is empty
        if vals.empty?
          raise 'load profile for the sample run returned empty'
        end

        timeseries_results_combined[key_value][timeseriesname] = vals
      end
    end

    return timeseries_results_combined
  end

  def models_to_test_final_oa_rates
    # suggestion: test all of these models locally but only include one model that can test quickly since the test requires simulation run.
    test_sets = []
    test_sets << { model: 'Outpatient_VAV_economizer_test', weather: 'VA_MANASSAS_724036_12', result: 'Success' }
    return test_sets
  end

  def compare_arrays_with_tolerance(array1, array2, tolerance1, tolerance2)
    # raise if array sizes are different
    return false if array1.length != array2.length

    # Count values that violate tolerance 1
    violations_count = array1.zip(array2).count { |a, b| (a - b).abs > (tolerance1 / 100.0) * a }

    # puts("#################################################################")
    # array1.zip(array2).each do |row|
    #   puts row.join(', ')
    # end
    # puts("#################################################################")

    # Check if the ratio of violations to the total count is within tolerance 2
    violations_ratio = violations_count.to_f / array1.length
    violation_final = violations_ratio > tolerance2 / 100.0

    # Report stats
    puts("### DEBUGGING: violations count = #{violations_count} based on #{tolerance1}% tolerance")
    puts("### DEBUGGING: violations % = #{(violations_ratio * 100).round(3)}% from total of #{array1.length} values")
    puts("### DEBUGGING: violation decision = #{violation_final} based on #{tolerance2}% tolerance")

    return violation_final
  end

  def test_final_oa_rates
    # Define test name
    test_name = 'test_final_oa_rates'
    puts "\n######\nTEST:#{test_name}\n######\n"

    number_of_days_to_test = 365
    number_of_timesteps_in_an_hr_test = 1
    viloation_results = []

    # loop through each model from models_to_test_final_oa_rates and conduct test
    models_to_test_final_oa_rates.each do |set|
      instance_test_name = set[:model]
      puts "instance test name: #{instance_test_name}"
      osm_path = models_for_tests.select { |x| set[:model] == File.basename(x, '.osm') }
      epw_path = epws_for_tests.select { |x| set[:weather] == File.basename(x, '.epw') }
      assert(!osm_path.empty?, "Could not find osm file at #{osm_path}")
      assert(!epw_path.empty?, "Could not find epw file at #{epw_path}")
      osm_path = osm_path[0]
      epw_path = epw_path[0]

      # Initialize variables
      timeseries_results_combined = {}

      # Create an instance of the measure
      measure = HVACEconomizer.new

      # Load the model; only used here for populating arguments
      model = load_model(osm_path)
      arguments = measure.arguments(model)
      argument_map = OpenStudio::Measure::OSArgumentMap.new

      # Set weather
      epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(epw_path))
      OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)

      # Define output vars for simulation before measure implementation
      timeseriesnames = [
        'Air System Outdoor Air Mechanical Ventilation Requested Mass Flow Rate',
        'Air System Outdoor Air Mass Flow Rate'
      ]

      # Add output vars for simulation before measure implementation
      timeseriesnames.each do |out_var_name|
        ov = OpenStudio::Model::OutputVariable.new('ov', model)
        ov.setKeyValue('*')
        ov.setReportingFrequency('timestep')
        ov.setVariableName(out_var_name)
      end

      # Check economizer availability
      economizer_count_before = economizer_available(model)

      # Run simulation prior to measure application
      puts('### DEBUGGING: first simulation prior to measure application')
      timeseries_results_combined_before = run_simulation_and_get_timeseries(model, 2016, number_of_days_to_test, number_of_timesteps_in_an_hr_test, timeseriesnames, epw_path = epw_path, run_dir = "#{run_dir(instance_test_name)}/beforemeasure")
      timeseries_results_combined['before'] = timeseries_results_combined_before

      # puts("### ##########################################################")
      # puts("### DEBUGGING: timeseries_results_combine = #{timeseries_results_combined}")
      # puts("### ##########################################################")

      # Apply the measure to the model
      result = apply_measure_and_run(instance_test_name, measure, argument_map, osm_path, epw_path, run_model: false)
      model = load_model(model_output_path(instance_test_name))

      # Check economizer availability
      economizer_count_after = economizer_available(model)
      assert(economizer_count_after > economizer_count_before)

      # Get EMS variables created by the measure
      li_ems_act_oa_flow = []
      model.getEnergyManagementSystemActuators.each do |ems_actuator|
        li_ems_act_oa_flow << ems_actuator
      end
      model.getEnergyManagementSystemGlobalVariables.each do |glo_var|
        li_ems_act_oa_flow << glo_var
      end

      # Create OutputEnergyManagementSystem object (a 'unique' object) and configure to allow EMS reporting
      output_ems = model.getOutputEnergyManagementSystem
      output_ems.setInternalVariableAvailabilityDictionaryReporting('Verbose')
      output_ems.setEMSRuntimeLanguageDebugOutputLevel('Verbose')
      output_ems.setActuatorAvailabilityDictionaryReporting('Verbose')

      # Create output var for EMS variables
      ems_output_variable_list = []
      li_ems_act_oa_flow.each do |act|
        name = act.name
        ems_act_oa_flow = OpenStudio::Model::EnergyManagementSystemOutputVariable.new(model, act)
        ems_act_oa_flow.setUpdateFrequency('Timestep')
        ems_act_oa_flow.setName("#{name}_ems_outvar")
        ems_output_variable_list << ems_act_oa_flow.name.to_s
      end

      # Add EMS output variables to regular output variables
      ems_output_variable_list.each do |variable|
        output = OpenStudio::Model::OutputVariable.new(variable, model)
        output.setKeyValue('*')
        output.setReportingFrequency('Timestep')
        timeseriesnames << variable
      end

      # Add output vars for simulation after measure implementation
      timeseriesnames.each do |out_var_name|
        ov = OpenStudio::Model::OutputVariable.new('ov', model)
        ov.setKeyValue('*')
        ov.setReportingFrequency('timestep')
        ov.setVariableName(out_var_name)
      end

      # Run simulation after measure application
      puts('### DEBUGGING: second simulation after measure application')
      timeseries_results_combined_after = run_simulation_and_get_timeseries(model, 2016, number_of_days_to_test, number_of_timesteps_in_an_hr_test, timeseriesnames, epw_path = epw_path, run_dir = "#{run_dir(instance_test_name)}/aftermeasure")
      timeseries_results_combined['after'] = timeseries_results_combined_after

      # puts("### ----------------------------------------------------------------------------")
      # puts("### DEBUGGING: timeseries_results_combined = #{timeseries_results_combined}")
      # puts("### ----------------------------------------------------------------------------")

      # Get unique identifier names
      unique_identifiers = timeseries_results_combined.values.flat_map(&:keys).uniq

      # Define interested output var name
      output_var_name = 'Air System Outdoor Air Mass Flow Rate'

      # Compare output var results before and after the measure
      unique_identifiers.each do |identifier|
        # skip if the output var key is EMS
        next if identifier == 'EMS'

        puts('### ----------------------------------------------------------------------------')
        puts("### DEBUGGING: identifier = #{identifier}")

        # get reference string for string match
        identifier_lowercase = identifier.gsub(' ', '_').downcase

        # get output var timeseries
        timeseries_outputvar_before = []
        timeseries_outputvar_after = []
        unless identifier == 'EMS'
          timeseries_outputvar_before = timeseries_results_combined['before'][identifier][output_var_name]
          timeseries_outputvar_after = timeseries_results_combined['after'][identifier][output_var_name]
        end

        # get reference (ems actuator) timeseries
        timeseries_reference = []
        timeseries_outputvar_ems_actuator = []
        timeseries_results_combined['after']['EMS'].keys.each do |output_var_ems|
          output_var_ems_lowercase = output_var_ems.downcase
          if (output_var_ems_lowercase.include?(identifier_lowercase)) & (output_var_ems_lowercase.include?('dummy_debugging'))
            timeseries_reference = timeseries_results_combined['after']['EMS'][output_var_ems]
          end
          if (output_var_ems_lowercase.include?(identifier_lowercase)) & (output_var_ems_lowercase.include?('act_oa_flow_'))
            timeseries_outputvar_ems_actuator = timeseries_results_combined['after']['EMS'][output_var_ems]
          end
        end
        puts("### DEBUGGING: length before applying measure | #{output_var_name} = #{timeseries_outputvar_before.size}")
        puts("### DEBUGGING: length after applying measure | #{output_var_name} = #{timeseries_outputvar_after.size}")
        puts("### DEBUGGING: length ems actuator = #{timeseries_outputvar_ems_actuator.size}")
        puts("### DEBUGGING: length dummy reference = #{timeseries_reference.size}")

        # Get indices of interest (when OA is forced to minimum)
        indices_of_interest = timeseries_reference.each_index.select { |i| timeseries_reference[i] == 1 } # 0 = ems not actuated | 1 = ems actuated (i.e., forced to minimum)
        puts("### DEBUGGING: number of times actuator override (= disable economizing) = #{indices_of_interest.size}")

        # Get filtered output vars
        timeseries_outputvar_before = timeseries_outputvar_before.values_at(*indices_of_interest)
        timeseries_outputvar_after = timeseries_outputvar_after.values_at(*indices_of_interest)
        timeseries_outputvar_ems_actuator = timeseries_outputvar_ems_actuator.values_at(*indices_of_interest)
        timeseries_reference = timeseries_reference.values_at(*indices_of_interest)
        puts("### DEBUGGING: length before applying measure | #{output_var_name} (filtered) = #{timeseries_outputvar_before.size}")
        puts("### DEBUGGING: length after applying measure | #{output_var_name} (filtered) = #{timeseries_outputvar_after.size}")
        puts("### DEBUGGING: length ems actuator (filtered) = #{timeseries_outputvar_ems_actuator.size}")
        puts("### DEBUGGING: length dummy reference (filtered) = #{timeseries_reference.size}")
        combined_pairs = timeseries_outputvar_before.zip(timeseries_outputvar_ems_actuator, timeseries_reference).map { |elements| elements.join(', ') }
        puts("### DEBUGGING: unique pairs (filtered) [timeseries_outputvar_before, timeseries_outputvar_ems_actuator, timeseries_reference] = #{combined_pairs.uniq}")

        # check violation with tolerance
        viloation_results << compare_arrays_with_tolerance(timeseries_outputvar_before, timeseries_outputvar_ems_actuator, 0.5, 1)
      end
      puts('### ----------------------------------------------------------------------------')
      puts("### DEBUGGING: viloation_results = #{viloation_results}")
      puts('### ----------------------------------------------------------------------------')
      assert(viloation_results.include?(true) == false)
    end
  end

  # create an array of hashes with model name, weather, and expected result
  def models_to_test
    test_sets = []
    test_sets << { model: 'PVAV_gas_heat_electric_reheat_4A', weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16', result: 'Success' }
    test_sets << { model: 'Baseboard_electric_heat_3B', weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16', result: 'NA' }
    test_sets << { model: 'PSZ-AC_with_gas_coil_heat_3B', weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16', result: 'Success' }
    test_sets << { model: 'Residential_AC_with_electric_baseboard_heat_3B', weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16', result: 'NA' }
    test_sets << { model: 'Residential_heat_pump_3B', weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16', result: 'NA' }
    test_sets << { model: 'DOAS_wshp_gshp_3A', weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16', result: 'NA' }
    test_sets << { model: 'Outpatient_VAV_chiller_PFP_boxes', weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16', result: 'Success' }
    return test_sets
  end

  def test_models
    test_name = 'test_models'
    puts "\n######\nTEST:#{test_name}\n######\n"

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
      measure = HVACEconomizer.new

      # load the model; only used here for populating arguments
      model = load_model(osm_path)

      # set arguments here; will vary by measure
      arguments = measure.arguments(model)
      argument_map = OpenStudio::Measure::OSArgumentMap.new

      # Set weather
      epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(epw_path))
      OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)

      # Apply the measure to the model and optionally run the model
      result = apply_measure_and_run(instance_test_name, measure, argument_map, osm_path, epw_path, run_model: false)

      # check the measure result; result values will equal Success, Fail, or Not Applicable
      # also check the amount of warnings, info, and error messages
      # use if or case statements to change expected assertion depending on model characteristics
      assert(result.value.valueName == set[:result])
    end
  end
end
