# ComStock™, Copyright (c) 2023 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'minitest/autorun'
require_relative '../measure'
require 'fileutils'
require_relative '../../../../test/helpers/minitest_helper'

# require all .rb files in resources folder (sorted)
Dir["#{__dir__}/../resources/*.rb"].sort.each { |file| require file }

class DFLoadShedTest < Minitest::Test
  # def setup
  # end

  # def teardown
  # end

  # return file paths to test models in test directory
  def models_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/models/*.osm'))
    paths.map { |path| File.expand_path(path) }
  end

  # return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/weather/*.epw'))
    paths.map { |path| File.expand_path(path) }
  end

  # create an array of hashes with model name, weather, and expected result
  def models_to_test
    test_sets = []

    # test: applicable building type
    # test_sets << {
    #   model: 'Small_Office_2A',
    #   weather: 'TX_Port_Arthur_Jeffers_722410_16',
    #   result: 'Success'
    # }
    # test_sets << {
    #   model: '361_Medium_Office_PSZ_HP',
    #   weather: 'CO_FortCollins_16',
    #   result: 'Success'
    # }
    # test_sets << {
    #   model: 'LargeOffice_VAV_chiller_boiler',
    #   weather: 'NY_New_York_John_F_Ke_744860_16',
    #   result: 'Success'
    # }
    # test_sets << {
    #   model: 'Warehouse_5A',
    #   weather: 'MN_Cloquet_Carlton_Co_726558_16',
    #   result: 'Success'
    # }
    test_sets << {
      model: '3340_small_office_OS38', # small office
      weather: 'IL_Dupage_3340_18',
      result: 'Success'
    }
    test_sets << {
      model: '4774_secondary_school_OS38', # secondary school
      weather: 'MI_Tulip_City_4774_18',
      result: 'Success'
    }
    # test: not applicable building type
    test_sets << {
      model: 'Outpatient_VAV_chiller_PFP_boxes',
      weather: 'CO_FortCollins_16',
      result: 'NA'
    }

    test_sets
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

  def report_path(test_name)
    "#{run_dir(test_name)}/reports/eplustbl.html"
  end

  def sql_path(test_name)
    "#{run_dir(test_name)}/run/eplusout.sql"
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

      std = Standard.build('90.1-2013')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))

      # check that the model ran successfully
      assert(File.exist?(sql_path(test_name)))
    end

    # change back directory
    Dir.chdir(start_dir)

    result
  end

  def test_models
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
      measure = DFLoadShed.new

      # load the model; only used here for populating arguments
      model = load_model(osm_path)

      # set arguments here; will vary by measure
      arguments = measure.arguments(model)
      argument_map = OpenStudio::Measure::OSArgumentMap.new

      # set arguments:
      demand_flexibility_objective = arguments[0].clone
      assert(demand_flexibility_objective.setValue('peak load'))
      argument_map['demand_flexibility_objective'] = demand_flexibility_objective

      # set arguments:
      peak_len = arguments[1].clone
      assert(peak_len.setValue(4))
      argument_map['peak_len'] = peak_len

      # set arguments:
      thermostat_control = arguments[2].clone
      assert(thermostat_control.setValue(true))
      argument_map['thermostat_control'] = thermostat_control

      # set arguments:
      rebound_len = arguments[3].clone
      assert(rebound_len.setValue(2))
      argument_map['rebound_len'] = rebound_len

      # set arguments:
      sp_adjustment = arguments[4].clone
      assert(sp_adjustment.setValue(2.0))
      argument_map['sp_adjustment'] = sp_adjustment

      # set arguments:
      lighting_control = arguments[5].clone
      assert(lighting_control.setValue(true))
      argument_map['lighting_control'] = lighting_control

      # set arguments:
      light_adjustment_method = arguments[6].clone
      assert(light_adjustment_method.setValue('absolute change'))
      argument_map['light_adjustment_method'] = light_adjustment_method

      # set arguments:
      light_adjustment = arguments[7].clone
      assert(light_adjustment.setValue(30.0))
      argument_map['light_adjustment'] = light_adjustment

      # set arguments:
      num_timesteps_in_hr = arguments[8].clone
      assert(num_timesteps_in_hr.setValue(4))
      argument_map['num_timesteps_in_hr'] = num_timesteps_in_hr

      # set arguments:
      load_prediction_method = arguments[9].clone
      assert(load_prediction_method.setValue('full baseline')) # 'bin sample''part year bin sample'
      argument_map['load_prediction_method'] = load_prediction_method

      # set arguments:
      peak_window_strategy = arguments[10].clone
      assert(peak_window_strategy.setValue('center with peak')) # 'bin sample''part year bin sample'
      argument_map['peak_window_strategy'] = peak_window_strategy

      # set arguments:
      cambium_scenario = arguments[11].clone
      assert(cambium_scenario.setValue('LRMER_MidCase_15'))
      argument_map['cambium_scenario'] = cambium_scenario

      # set arguments:
      pv = arguments[12].clone
      assert(pv.setValue(true))
      argument_map['pv'] = pv

      # # set arguments:
      # apply_measure = arguments[13].clone
      # assert(apply_measure.setValue(true))#
      # argument_map['apply_measure'] = apply_measure

      # actual hourly timestep
      if (demand_flexibility_objective.valueAsString == 'grid peak load') || (demand_flexibility_objective.valueAsString == 'emissions')
        timestep = 1
      else
        timestep = num_timesteps_in_hr.valueAsInteger
      end

      # store baseline schedule for check later
      lights = model.getLightss
      light_schedules = {}
      lights.each do |light|
        light_sch = light.schedule
        next unless !light_sch.empty? && !light_schedules.key?(light_sch.get.name.to_s)

        schedule = light_sch.get.clone(model)
        schedule = schedule.to_Schedule.get
        schedule_ts = measure.get_interval_schedule_from_schedule_ruleset(model, schedule.to_ScheduleRuleset.get,
                                                                          8760 * timestep)
        light_schedules[light_sch.get.name.to_s] = schedule_ts
      end
      puts('-----------------------------------------------------------------')
      puts("light_schedules.key=#{light_schedules.keys}")
      # store baseline schedule for check later
      heat_schedules = {}
      cool_schedules = {}
      thermostats = model.getThermostatSetpointDualSetpoints
      thermostats.each do |thermostat|
        next unless thermostat.to_Thermostat.get.thermalZone.is_initialized

        thermalzone = thermostat.to_Thermostat.get.thermalZone.get
        clg_fueltypes = thermalzone.coolingFuelTypes.map(&:valueName).uniq
        htg_fueltypes = thermalzone.heatingFuelTypes.map(&:valueName).uniq
        # puts("### DEBUGGING: clg_fueltypes = #{clg_fueltypes}")
        # puts("### DEBUGGING: htg_fueltypes = #{htg_fueltypes}")
        if htg_fueltypes == ['Electricity']
          heat_sch = thermostat.heatingSetpointTemperatureSchedule
          if !heat_sch.empty? && !heat_schedules.key?(heat_sch.get.name.to_s)
            schedule = heat_sch.get.clone(model)
            schedule = schedule.to_Schedule.get
            schedule_ts = measure.get_interval_schedule_from_schedule_ruleset(model, schedule.to_ScheduleRuleset.get,
                                                                              8760 * timestep)
            heat_schedules[heat_sch.get.name.to_s] = schedule_ts
          end
        end
        next unless clg_fueltypes == ['Electricity']

        cool_sch = thermostat.coolingSetpointTemperatureSchedule
        next unless !cool_sch.empty? && !cool_schedules.key?(cool_sch.get.name.to_s)

        schedule = cool_sch.get.clone(model)
        schedule = schedule.to_Schedule.get
        schedule_ts = measure.get_interval_schedule_from_schedule_ruleset(model, schedule.to_ScheduleRuleset.get,
                                                                          8760 * timestep)
        cool_schedules[cool_sch.get.name.to_s] = schedule_ts
      end
      puts("heat_schedules.key=#{heat_schedules.keys}")
      puts("cool_schedules.key=#{cool_schedules.keys}")
      puts('-----------------------------------------------------------------')

      # apply the measure to the model and optionally run the model
      result = apply_measure_and_run(instance_test_name, measure, argument_map, osm_path, epw_path, run_model: true)

      # check the measure result; result values will equal Success, Fail, or Not Applicable (NA)
      # also check the amount of warnings, info, and error messages
      # use if or case statements to change expected assertion depending on model characteristics
      assert(result.value.valueName == set[:result])

      # to check that something changed in the model, load the model and the check the objects match expected new value
      model = load_model(model_output_path(instance_test_name))

      ### quick check on schedule update
      next unless set[:result] == 'Success'

      thermostats = model.getThermostatSetpointDualSetpoints
      lights = model.getLightss
      new_heat_schedules = {}
      new_cool_schedules = {}
      new_light_schedules = {}

      # quick check on schedule update
      nts_clg = 0
      nts_htg = 0
      nl = 0
      nla = 0
      # check on thermostat schedules
      thermostats.each do |thermostat|
        cool_sch = thermostat.coolingSetpointTemperatureSchedule
        clg_sch_name = cool_sch.get.name.to_s
        if clg_sch_name.include?(' df_adjusted')
          unless new_cool_schedules.key?(clg_sch_name)
            schedule = cool_sch.get.clone(model)
            schedule = schedule.to_ScheduleInterval.get
            new_cool_schedules[clg_sch_name] = schedule.timeSeries.values.to_a
          end
          nts_clg += 1
        end
        heat_sch = thermostat.heatingSetpointTemperatureSchedule
        heat_sch_name = heat_sch.get.name.to_s
        next unless heat_sch_name.include?(' df_adjusted')

        unless new_heat_schedules.key?(heat_sch_name)
          schedule = heat_sch.get.clone(model)
          schedule = schedule.to_ScheduleInterval.get
          new_heat_schedules[heat_sch_name] = schedule.timeSeries.values.to_a
        end
        nts_htg += 1
      end
      puts('-----------------------------------------------------------------')
      puts("--- Detected #{nts_clg} df adjusted cooling schedules and #{nts_htg} df adjusted heating schedules")
      assert((nts_clg + nts_htg).positive?)
      # check on light schedules
      lights.each do |light|
        light_sch = light.schedule
        light_sch_name = light_sch.get.name.to_s
        # puts("light schedule: #{light_sch_name}")
        if light_sch_name.include?(' df_adjusted')
          unless new_light_schedules.key?(light_sch_name)
            schedule = light_sch.get.clone(model)
            schedule = schedule.to_ScheduleInterval.get
            new_light_schedules[light_sch_name] = schedule.timeSeries.values.to_a
          end
          nla += 1
        end
        nl += 1
      end
      puts('-----------------------------------------------------------------')
      puts("--- Detected #{nla}/#{nl} lights with df adjusted lighting schedules")
      assert(nla == nl)

      # compare before/after schedules
      if nts_clg.positive?
        cool_schedules.each do |cool_sch_name, cool_sch_vals|
          new_cool_sch_vals = new_cool_schedules["#{cool_sch_name} df_adjusted"]
          diff = cool_sch_vals.zip(new_cool_sch_vals).map { |a, b| (b - a).round(2) }
          counts = diff.tally
          counts = counts.sort.to_h
          puts('-----------------------------------------------------------------')
          # puts("--- hourly light schedules changes #{diff*100.0}% everyday")
          puts("--- cooling schedule changes on average #{diff.sum / 365.0 / peak_len.valueAsInteger.to_f / timestep.to_f}C/hr for #{peak_len.valueAsInteger} hours everyday")
          counts.each do |value, count|
            next if value.abs < 1e-6 || count < timestep.to_f

            puts("--- cooling schedule changes #{value}C in #{count / peak_len.valueAsInteger.to_f / timestep.to_f} days")
            assert(value.abs <= sp_adjustment.valueAsDouble,
                   "Hourly change should not exceed the input #{sp_adjustment.valueAsDouble.round(1)}")
          end
          total_days = counts[sp_adjustment.valueAsDouble] / peak_len.valueAsInteger.to_f / timestep.to_f
          assert(total_days < 367 && total_days > 360,
                 "cooling schedule changes with input #{sp_adjustment.valueAsDouble}C in #{total_days} days")
        end
      end
      if nts_htg.positive?
        heat_schedules.each do |heat_sch_name, heat_sch_vals|
          new_heat_sch_vals = new_heat_schedules["#{heat_sch_name} df_adjusted"]
          diff = heat_sch_vals.zip(new_heat_sch_vals).map { |a, b| (a - b).round(2) }
          counts = diff.tally
          counts = counts.sort.to_h
          puts('-----------------------------------------------------------------')
          # puts("--- hourly light schedules changes #{diff*100.0}% everyday")
          puts("--- heating schedule changes on average #{diff.sum / 365.0 / peak_len.valueAsInteger.to_f / timestep.to_f}C/hr for #{peak_len.valueAsInteger} hours everyday")
          counts.each do |value, count|
            next if value.abs < 1e-6 || count < timestep.to_f

            puts("--- heating schedule changes #{value} in #{count / peak_len.valueAsInteger.to_f / timestep.to_f} days")
            assert(value.abs <= sp_adjustment.valueAsDouble,
                   "Hourly change should not exceed the input #{sp_adjustment.valueAsDouble.round(1)}")
          end
          total_days = counts[sp_adjustment.valueAsDouble] / peak_len.valueAsInteger.to_f / timestep.to_f
          assert(total_days < 367 && total_days > 360,
                 "heating schedule changes with input #{sp_adjustment.valueAsDouble}C in #{total_days} days")
        end
      end

      light_schedules.each do |light_sch_name, light_sch_vals|
        new_light_sch_vals = new_light_schedules["#{light_sch_name} df_adjusted"]
        # diff = light_sch_vals.sum - new_light_sch_vals.sum
        diff = light_sch_vals.zip(new_light_sch_vals).map { |a, b| (a - b).round(2) }
        counts = diff.tally
        counts = counts.sort.to_h
        puts('-----------------------------------------------------------------')
        # puts("--- hourly light schedules changes #{diff*100.0}% everyday")
        puts("--- light schedule changes on average #{(diff.sum / 3.650 / peak_len.valueAsInteger.to_f / timestep.to_f).round(2)}%/hr for #{peak_len.valueAsInteger} hours everyday")
        total_count = 0
        counts.each do |value, count|
          next if value.abs < 1e-6 || count < timestep.to_f

          puts("--- light schedule changes #{(value * 100.0).round(1)}% in #{count / peak_len.valueAsInteger.to_f / timestep.to_f} days")
          assert(value <= light_adjustment.valueAsDouble,
                 "Hourly change should not exceed the input #{light_adjustment.valueAsDouble.round(1)}")
          total_count += count
        end
        total_days = total_count / peak_len.valueAsInteger.to_f / timestep.to_f
        puts("--- Number of days with setpoint changed: #{total_days}")
        assert(total_days <= 366, 'Number of days should not exceed 366')
        assert(total_days > 100,
               "Number of days with valid adjusted setpoints (#{total_count / peak_len.valueAsInteger.to_f / timestep.to_f}) too small")
      end
      puts('=================================================================')
    end
  end
end
