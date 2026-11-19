# insert your copyright here

require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'minitest/autorun'
require 'fileutils'

require_relative '../measure'

class UpgradeAddThermostatSetbackTest < Minitest::Test
  def models_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/models/*.osm'))
    paths.map { |path| File.expand_path(path) }
  end

  # return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/weather/*.epw'))
    paths.map { |path| File.expand_path(path) }
  end

  def load_model(osm_path)
    translator = OpenStudio::OSVersion::VersionTranslator.new
    model = translator.loadModel(OpenStudio::Path.new(osm_path))
    assert(!model.empty?)
    model.get
  end

  def run_dir(test_name)
    # always generate test output in specially named 'output' directory so result files are not made part of the measure
    "#{File.dirname(__FILE__)}/output/#{test_name}"
  end

  def model_input_path(osm_name)
    # return models_for_tests.select { |x| set[:model] == osm_name }
    File.join(File.dirname(__FILE__), '../../../tests/models', osm_name)
  end

  def epw_input_path(epw_name)
    File.join(File.dirname(__FILE__), '../../../tests/weather', epw_name)
  end

  def model_output_path(test_name)
    "#{run_dir(test_name)}/#{test_name}.osm"
  end

  def sql_path(test_name)
    "#{run_dir(test_name)}/run/eplusout.sql"
  end

  def report_path(test_name)
    "#{run_dir(test_name)}/reports/eplustbl.html"
  end

  # applies the measure and then runs the model
  def set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false,
                                            model: nil, apply: true, expected_results: 'Success')
    assert(File.exist?(osm_path))
    assert(File.exist?(epw_path))
    ddy_path = "#{epw_path.gsub('.epw', '')}.ddy"

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
    model = load_model(new_osm_path) if model.nil?

    # set model weather file
    epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(new_epw_path))
    OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
    assert(model.weatherFile.is_initialized)

    # set design days
    if File.exist?(ddy_path)

      # remove all the Design Day objects that are in the file
      model.getObjectsByType('OS:SizingPeriod:DesignDay'.to_IddObjectType).each(&:remove)

      # load ddy
      ddy_model = OpenStudio::EnergyPlus.loadAndTranslateIdf(ddy_path).get

      ddy_model.getDesignDays.sort.each do |d|
        # grab only the ones that matter
        ddy_list = [
          /Htg 99.6. Condns DB/, # Annual heating 99.6%
          /Clg .4. Condns WB=>MDB/, # Annual humidity (for cooling towers and evap coolers)
          /Clg .4. Condns DB=>MWB/, # Annual cooling
          /August .4. Condns DB=>MCWB/, # Monthly cooling DB=>MCWB (to handle solar-gain-driven cooling)
          /September .4. Condns DB=>MCWB/,
          /October .4. Condns DB=>MCWB/
        ]
        ddy_list.each do |ddy_name_regex|
          next unless d.name.get.to_s.match?(ddy_name_regex)

          runner.registerInfo("Adding object #{d.name}")

          # add the object to the existing model
          model.addObject(d.clone)
          break
        end
      end

      # assert
      assert_equal(false, model.getDesignDays.empty?)
    end

    if apply
      # run the measure
      puts "\nAPPLYING MEASURE..."
      measure.run(model, runner, argument_map)
      result = runner.result
      result.value.valueName
      assert_equal(expected_results, result.value.valueName)

      # Show the output
      show_output(result)
    end

    model.getOutputControlFiles.setOutputCSV(true)

    # Save model
    model.save(model_output_path(test_name), true)

    if run_model
      puts "\nRUNNING MODEL..."

      std = Standard.build('90.1-2013')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))

      # Check that the model ran successfully
      assert(File.exist?(sql_path(test_name)))
    end

    # change back directory
    Dir.chdir(start_dir)

    result
  end

  def test_number_of_arguments_and_argument_names
    # This test ensures that the current test is matched to the measure inputs
    test_name = 'test_number_of_arguments_and_argument_names'
    puts "\n######\nTEST:#{test_name}\n######\n"

    # Create an instance of the measure
    measure = UpgradeAddThermostatSetback.new

    # Make an empty model
    model = OpenStudio::Model::Model.new

    # Get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(6, arguments.size)
    assert_equal('clg_setback', arguments[0].name)
    assert_equal('htg_setback', arguments[1].name)
    assert_equal('opt_start', arguments[2].name)
    assert_equal('opt_start_len', arguments[3].name)
    assert_equal('htg_min', arguments[4].name)
    assert_equal('clg_max', arguments[5].name)
  end

  def test_confirm_heating_setback_change_square_wave
    # confirm that any heating setbacks are now 2F
    osm_name = '380_psz_ac_with_gas_boiler.osm'
    epw_name = 'NE_Kearney_Muni_725526_16.epw'

    test_name = 'confirm_heating_setback_change_square_wave'

    puts "\n######\nTEST:#{test_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_input_path(epw_name)

    # Create an instance of the measure
    measure = UpgradeAddThermostatSetback.new

    # Load the model
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    conv_factor = Rational(5, 9)
    htg_setback = 5.0
    htg_setback_c = htg_setback.to_f * conv_factor

    # Use default argument values

    # run the measure
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path,
                                                   run_model: false)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__)) # keep track of differences between min and max values in schedules

    schedule_deltas = [] # keep track of differences between min and max values in schedules

    # Loop thru zones and look at temp setbacks
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      zones = air_loop_hvac.thermalZones
      zones.sort.each do |thermal_zone|
        next unless thermal_zone.thermostatSetpointDualSetpoint.is_initialized

        zone_thermostat = thermal_zone.thermostatSetpointDualSetpoint.get
        htg_schedule = zone_thermostat.heatingSetpointTemperatureSchedule
        if htg_schedule.empty?
          puts("Heating setpoint schedule not found for zone '#{thermal_zone.name.get}'")
          next
        elsif htg_schedule.get.to_ScheduleRuleset.empty?
          puts("Schedule '#{htg_schedule.get.name.get}' is not a ScheduleRuleset, will not be adjusted")
          next
        else
          htg_schedule = htg_schedule.get.to_ScheduleRuleset.get
        end
        profiles = [htg_schedule.defaultDaySchedule]
        htg_schedule.scheduleRules.each { |rule| profiles << rule.daySchedule }
        profiles.sort.each do |tstat_profile|
          # working_profile = tstat_profile.values.dup
          tstat_profile_min = tstat_profile.values.min
          tstat_profile_max = tstat_profile.values.max
          schedule_deltas << (tstat_profile_max - tstat_profile_min) # assuming that any changes in the schedule during the day represent nighttime setbacks
        end
      end
    end

    # Make sure no deltas are greater than the expected setback value
    deltas_out_of_range = schedule_deltas.any? { |x| x > htg_setback_c + 0.2 } # add a margin for unit conversion

    puts("Temperature deltas in schedule match expected values: #{deltas_out_of_range == false}")

    assert_equal(deltas_out_of_range, false)
    true
  end
end
