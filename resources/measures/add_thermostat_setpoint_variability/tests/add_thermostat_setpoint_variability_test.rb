# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'fileutils'
require_relative '../../../../test/helpers/minitest_helper'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require_relative '../measure'

class AddThermostatSetpointVariabilityTest < Minitest::Test
  # return file paths to test models in test directory
  def models_for_tests
    paths = Dir.glob(File.join(__dir__, '../../../tests/models/*.osm'))
    paths = paths.map { |path| File.expand_path(path) }
    return paths
  end

  # return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(__dir__, '../../../tests/weather/*.epw'))
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
    return "#{__dir__}/output/#{test_name}"
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

  def set_argument_map(model, measure, args_hash)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

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

  def get_sch_minmax(sch)
    profiles = [sch.defaultDaySchedule]
    sch.scheduleRules.each { |p| profiles << p.daySchedule }
    values = []
    profiles.each { |p| values << p.values }
    return { min: values.flatten.min, max: values.flatten.max }
  end

  # applies the measure and then runs the model
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

    # temporarily change directory to the run directory and run the measure
    # only necessary for measures that do a sizing run
    start_dir = Dir.pwd
    begin
      Dir.chdir(run_dir(test_name))

      # run the measure
      puts "\nAPPLYING MEASURE..."
      measure.run(model, runner, argument_map)
      result = runner.result
    ensure
      Dir.chdir(start_dir)
    end

    # show the output
    show_output(result)

    # save model
    model.save(model_output_path(test_name), true)

    if run_model && (result.value.valueName == 'Success')
      puts "\nRUNNING MODEL..."

      std = Standard.build('ComStock DEER 2020')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))

      # check that the model ran successfully
      assert(File.exist?(sql_path(test_name)))
    end

    return result
  end

  # create an array of hashes with model name, weather, and expected result
  def models_to_test
    test_sets = []
    test_sets << { model: 'PSZ-AC_with_gas_coil_heat_3B', weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16', result: 'Success' }
    test_sets << { model: 'Warehouse_5A', weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16', result: 'Success' }
    return test_sets
  end

  def test_number_of_arguments_and_argument_names
    # this test ensures that the current test is matched to the measure inputs
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = AddThermostatSetpointVariability.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(4, arguments.size)
    assert_equal('clg_sp_f', arguments[0].name)
    assert_equal('clg_delta_f', arguments[1].name)
    assert_equal('htg_sp_f', arguments[2].name)
    assert_equal('htg_delta_f', arguments[3].name)
  end

  def test_bad_argument_values
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = AddThermostatSetpointVariability.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # make an empty model
    model = OpenStudio::Model::Model.new
    tz = OpenStudio::Model::ThermalZone.new(model)

    # test low clg setpt
    argument_map = set_argument_map(model, measure, { 'clg_sp_f' => -2 })

    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result
    puts result.stepErrors
    assert_equal('Fail', result.value.valueName)

    # reset runner result
    runner.result.resetStepErrors

    # test high htg setpt
    argument_map = set_argument_map(model, measure, { 'htg_sp_f' => 120 })

    measure.run(model, runner, argument_map)
    result = runner.result
    puts result.stepErrors
    assert_equal('Fail', result.value.valueName)
  end

  def test_all_default
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = AddThermostatSetpointVariability.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # make an empty model
    model = OpenStudio::Model::Model.new
    tz = OpenStudio::Model::ThermalZone.new(model)

    argument_map = set_argument_map(model, measure, {})

    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result

    # assert that it ran correctly
    assert_equal('NA', result.value.valueName)
    assert(result.stepInfo.any? { |i| i.gsub('arugments', 'arguments').include?('All arguments are set to 999') })
  end

  def test_no_zones
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = AddThermostatSetpointVariability.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # make an empty model
    model = OpenStudio::Model::Model.new

    argument_map = set_argument_map(model, measure, { 'clg_sp_f' => 70 })
    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result

    # assert that it ran correctly
    assert_equal('NA', result.value.valueName)
    assert(result.stepInfo.any? { |i| i.gsub('conditioned', '').include?('no thermal zones') })
  end

  def test_overlapping_setpoint
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = AddThermostatSetpointVariability.new

    instance_test = models_to_test[0]
    osm_path = models_for_tests.select { |x| instance_test[:model] == File.basename(x, '.osm') }[0]
    epw_path = epws_for_tests.select { |x| instance_test[:weather] == File.basename(x, '.epw') }[0]
    model = load_model(osm_path)

    # set arguments here; will vary by measure
    args_hash = {
      'clg_sp_f' => 68,
      'clg_delta_f' => 4,
      'htg_sp_f' => 70,
      'htg_delta_f' => 4
    }
    # populate argument with specified hash value if specified
    argument_map = set_argument_map(model, measure, args_hash)

    # gather initial setpoint schedules
    clg_schs = []
    htg_schs = []
    model.getThermalZones.each do |zone|
      next unless zone.thermostatSetpointDualSetpoint.is_initialized
      next unless zone.thermostatSetpointDualSetpoint.get.coolingSetpointTemperatureSchedule.is_initialized
      next if clg_schs.include?(zone.thermostatSetpointDualSetpoint.get.coolingSetpointTemperatureSchedule.get)

      clg_schs << zone.thermostatSetpointDualSetpoint.get.coolingSetpointTemperatureSchedule.get

      next unless zone.thermostatSetpointDualSetpoint.get.heatingSetpointTemperatureSchedule.is_initialized
      next if htg_schs.include?(zone.thermostatSetpointDualSetpoint.get.heatingSetpointTemperatureSchedule.get)

      htg_schs << zone.thermostatSetpointDualSetpoint.get.heatingSetpointTemperatureSchedule.get
    end

    puts "#{clg_schs.size} Cooling Schedules"
    puts "#{htg_schs.size} Heating Schedules"

    before_vals = {}
    (clg_schs + htg_schs).each do |sch|
      sch = sch.to_ScheduleRuleset.get
      before_vals[sch.name.get] = get_sch_minmax(sch)
    end
    puts before_vals

    # apply the measure to the model and optionally run the model
    result = apply_measure_and_run(instance_test[:model], measure, argument_map, osm_path, epw_path, run_model: false)

    # show_output(result)

    assert(result.stepWarnings.any? { |w| w.include?('> 2F from the user-input cooling setpoint') })

    model = load_model(model_output_path(instance_test[:model]))
    model.getThermostatSetpointDualSetpoints.each do |tstat|
      clg = tstat.coolingSetpointTemperatureSchedule.get.to_ScheduleRuleset.get
      clg_name = clg.name.get

      # get new min/max
      min_clg = OpenStudio.convert(get_sch_minmax(clg)[:min], 'C', 'F').get

      # heating
      htg = tstat.heatingSetpointTemperatureSchedule.get.to_ScheduleRuleset.get
      htg_name = htg.name.get
      max_htg = OpenStudio.convert(get_sch_minmax(htg)[:max], 'C', 'F').get

      unless (OpenStudio.convert(before_vals[clg_name][:min], 'C', 'F').get == min_clg) || (OpenStudio.convert(before_vals[htg_name][:max], 'C', 'F').get == max_htg)
        puts "comparing changed #{clg_name} or #{htg_name}"
        assert_in_delta(min_clg, max_htg, 2.0001, "#{clg_name} or #{htg_name}")
      end
    end
  end

  def test_bad_setback
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = AddThermostatSetpointVariability.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # make an empty model
    model = OpenStudio::Model::Model.new

    # set arguments here; will vary by measure
    args_hash = {
      'clg_sp_f' => 70,
      'clg_delta_f' => -4,
      'htg_sp_f' => 70,
      'htg_delta_f' => 4
    }
    # populate argument with specified hash value if specified
    argument_map = set_argument_map(model, measure, args_hash)

    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result

    # show_output(result)

    assert_equal('Fail', result.value.valueName)
  end

  def test_non_ruleset_schedule
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = AddThermostatSetpointVariability.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # make an empty model
    model = OpenStudio::Model::Model.new
    tz = OpenStudio::Model::ThermalZone.new(model)
    tstat = OpenStudio::Model::ThermostatSetpointDualSetpoint.new(model)
    tstat.setHeatingSetpointTemperatureSchedule(OpenStudio::Model::ScheduleConstant.new(model))
    tstat.setCoolingSetpointTemperatureSchedule(OpenStudio::Model::ScheduleConstant.new(model))
    tz.setThermostat(tstat)

    # set arguments here; will vary by measure
    args_hash = {
      'clg_sp_f' => 70,
      'htg_sp_f' => 69
    }
    # populate argument with specified hash value if specified
    argument_map = set_argument_map(model, measure, args_hash)

    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result
    # show_output(result)

    assert_equal(result.stepWarnings.select { |w| w.include?('not a ScheduleRuleset') }.size, 2)
    assert(result.stepFinalCondition.get.include?('0 cooling and 0 heating schedules have been changed'))
  end

  def test_flat_schedule
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = AddThermostatSetpointVariability.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # make an empty model
    model = OpenStudio::Model::Model.new
    tz = OpenStudio::Model::ThermalZone.new(model)
    clg_sch = OpenStudio::Model::ScheduleRuleset.new(model, OpenStudio.convert(72, 'F', 'C').get)
    clg_sch.setName('Cooling Setpoint Sch')
    htg_sch = OpenStudio::Model::ScheduleRuleset.new(model, OpenStudio.convert(68, 'F', 'C').get)
    htg_sch.setName('Heating Setpoint Sch')
    tstat = OpenStudio::Model::ThermostatSetpointDualSetpoint.new(model)
    tstat.setHeatingSetpointTemperatureSchedule(htg_sch)
    tstat.setCoolingSetpointTemperatureSchedule(clg_sch)
    tz.setThermostat(tstat)

    # set arguments here; will vary by measure
    args_hash = {
      'clg_delta_f' => 4,
      'htg_delta_f' => 3
    }
    # populate argument with specified hash value if specified
    argument_map = set_argument_map(model, measure, args_hash)

    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result
    # show_output(result)

    assert_equal(result.stepWarnings.select { |w| w.include?('only has 1 temperature setpoint') }.size, 2)
  end

  def test_models
    puts "\n######\nTEST:#{__method__}\n######\n"

    # run all model test sets
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
      measure = AddThermostatSetpointVariability.new

      # load the model; only used here for populating arguments
      model = load_model(osm_path)

      # set arguments here; will vary by measure
      arguments = measure.arguments(model)
      argument_map = OpenStudio::Measure::OSArgumentMap.new

      args_hash = {
        'clg_sp_f' => 73,
        'clg_delta_f' => 4,
        'htg_sp_f' => 68,
        'htg_delta_f' => 4
      }

      # populate argument with specified hash value if specified
      arguments.each do |arg|
        temp_arg_var = arg.clone
        if args_hash.key?(arg.name)
          assert(temp_arg_var.setValue(args_hash[arg.name]))
        end
        argument_map[arg.name] = temp_arg_var
      end

      # gather initial setpoint schedules
      clg_schs = []
      htg_schs = []
      model.getThermalZones.each do |zone|
        next unless zone.thermostatSetpointDualSetpoint.is_initialized
        next unless zone.thermostatSetpointDualSetpoint.get.coolingSetpointTemperatureSchedule.is_initialized
        next if clg_schs.include?(zone.thermostatSetpointDualSetpoint.get.coolingSetpointTemperatureSchedule.get)

        clg_schs << zone.thermostatSetpointDualSetpoint.get.coolingSetpointTemperatureSchedule.get

        next unless zone.thermostatSetpointDualSetpoint.get.heatingSetpointTemperatureSchedule.is_initialized
        next if htg_schs.include?(zone.thermostatSetpointDualSetpoint.get.heatingSetpointTemperatureSchedule.get)

        htg_schs << zone.thermostatSetpointDualSetpoint.get.heatingSetpointTemperatureSchedule.get
      end

      puts "#{clg_schs.size} Cooling Schedules"
      puts "#{htg_schs.size} Heating Schedules"

      before_vals = {}
      (clg_schs + htg_schs).each do |sch|
        sch = sch.to_ScheduleRuleset.get
        before_vals[sch.name.get] = get_sch_minmax(sch)
      end

      # apply the measure to the model and optionally run the model
      result = apply_measure_and_run(instance_test_name, measure, argument_map, osm_path, epw_path, run_model: false)

      # check the measure result; result values will equal Success, Fail, or Not Applicable
      # also check the amount of warnings, info, and error messages
      # use if or case statements to change expected assertion depending on model characteristics
      assert(result.value.valueName == set[:result])

      # to check that something changed in the model, load the model and the check the objects match expected new value
      model = load_model(model_output_path(instance_test_name))

      changed_clg = []
      changed_htg = []
      model.getThermostatSetpointDualSetpoints.each do |tstat|
        clg = tstat.coolingSetpointTemperatureSchedule.get.to_ScheduleRuleset.get
        clg_name = clg.name.get

        # get new min/max
        min_clg = OpenStudio.convert(get_sch_minmax(clg)[:min], 'C', 'F').get
        max_clg = OpenStudio.convert(get_sch_minmax(clg)[:max], 'C', 'F').get

        if result.stepWarnings.any? { |w| w.include?("#{clg_name} has a minimum setpoint over") }
          # values beyond limits
          assert_equal(OpenStudio.convert(before_vals[clg_name][:min], 'C', 'F').get, min_clg)
        else
          # setpoint applied
          assert_in_delta(args_hash['clg_sp_f'], min_clg, 0.001)
          # test setback
          if result.stepWarnings.any? { |w| w.include?("#{clg_name} only has 1 temperature") }
            # flat schedule
            assert_in_delta(args_hash['clg_sp_f'], max_clg, 0.001)
          else
            # setback applied
            assert_in_delta(args_hash['clg_sp_f'] + args_hash['clg_delta_f'], max_clg, 0.001)
          end
        end

        # heating
        htg = tstat.heatingSetpointTemperatureSchedule.get.to_ScheduleRuleset.get
        htg_name = htg.name.get

        # get new min/max
        min_htg = OpenStudio.convert(get_sch_minmax(htg)[:min], 'C', 'F').get
        max_htg = OpenStudio.convert(get_sch_minmax(htg)[:max], 'C', 'F').get

        if result.stepWarnings.any? { |w| w.include?("#{htg_name} has a maximum setpoint under") } || (htg_name == 'Warehouse HtgSetp')
          # value beyond limits
          assert_equal(OpenStudio.convert(before_vals[htg_name][:max], 'C', 'F').get, max_htg)
        else
          # setpoint applied
          assert_in_delta(args_hash['htg_sp_f'], max_htg, 0.001)
          # test setback
          if result.stepWarnings.any? { |w| w.include?("#{htg_name} only has 1 temperature") }
            # flat schedule
            assert_in_delta(args_hash['htg_sp_f'], min_htg, 0.001)
          else
            # setback applied
            assert_in_delta(args_hash['htg_sp_f'] - args_hash['htg_delta_f'], min_htg, 0.001)
          end
        end
      end
    end
  end
end
