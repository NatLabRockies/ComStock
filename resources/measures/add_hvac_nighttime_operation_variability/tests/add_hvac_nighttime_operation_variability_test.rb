# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'fileutils'
require 'minitest/autorun'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require_relative '../measure'

class AddHvacNighttimeOperationVariabilityTest < Minitest::Test
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
      reset_log
      measure.run(model, runner, argument_map)
      result = runner.result

      # log messages
      log_messages_to_file("#{run_dir(test_name)}/measure.log", false)
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

  def test_number_of_arguments_and_argument_names
    # this test ensures that the current test is matched to the measure inputs
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = AddHvacNighttimeOperationVariability.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(1, arguments.size)
    assert_equal('rtu_night_mode', arguments[0].name)
  end

  def test_models
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an array of hashes with model name, weather, expected result, and any specific
    models_to_test = []
    models_to_test << { model: 'LargeOffice_VAV_chiller_boiler', weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16', result: 'Success' }

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
      measure = AddHvacNighttimeOperationVariability.new

      # load the model; only used here for populating arguments
      model = load_model(osm_path)

      # set arguments here; will vary by measure
      arguments = measure.arguments(model)
      argument_map = OpenStudio::Measure::OSArgumentMap.new

      rtu_night_mode = arguments[0].clone
      assert(rtu_night_mode.setValue('night_fancycle_novent'))
      argument_map['rtu_night_mode'] = rtu_night_mode

      # apply the measure to the model and optionally run the model
      result = apply_measure_and_run(instance_test_name, measure, argument_map, osm_path, epw_path, run_model: false)

      # check the measure result; result values will equal Success, Fail, or Not Applicable
      # also check the amount of warnings, info, and error messages
      # use if or case statements to change expected assertion depending on model characteristics
      assert(result.value.valueName == set[:result])

      # to check that something changed in the model, load the model and the check the objects match expected new value
      model = load_model(model_output_path(instance_test_name))

      # Check the schedules
      air_loop_hvac = model.getAirLoopHVACs.first
      assert(air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized)
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
      assert(oa_system.minimumOutdoorAirSchedule.is_initialized)
      assert_equal("#{air_loop_hvac.name}_night_ventcycle_schedule", oa_system.minimumOutdoorAirSchedule.get.name.get)
    end
  end

  def test_restaurant_exhaust_fan_schedule
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = AddHvacNighttimeOperationVariability.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # load the test model
    osm_path = "#{__dir__}/restaurant.osm"
    epw_path = epws_for_tests.select { |x| 'MI_DETROIT_725375_12' == File.basename(x, '.epw') }[0]

    # set arguments here; will vary by measure
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure::OSArgumentMap.new
    rtu_night_mode = arguments[0].clone
    assert(rtu_night_mode.setValue('night_fancycle_novent'))
    argument_map['rtu_night_mode'] = rtu_night_mode

    # apply the measure to the model and optionally run the model
    result = apply_measure_and_run('test_restaurant_exhaust_fan_change', measure, argument_map, osm_path, epw_path, run_model: false)

    assert(result.value.valueName == 'Success')

    # check that schedules changed
    model = load_model(model_output_path('test_restaurant_exhaust_fan_change'))
    kitchen_exhaust_fan = model.getFanZoneExhaustByName('Zone FullServiceRestaurant Kitchen  - Story ground Exhaust Fan').get
    tranfer_air_fan = model.getFanZoneExhaustByName('Zone FullServiceRestaurant Kitchen  - Story ground Transfer Air Source').get
    assert_equal('RestaurantSitDown Kitchen_Exhaust_SCH', kitchen_exhaust_fan.availabilitySchedule.get.name.get)
    assert_equal('RestaurantSitDown Kitchen_Exhaust_SCH', kitchen_exhaust_fan.flowFractionSchedule.get.name.get)
    assert_equal('RestaurantSitDown Kitchen Exhaust Fan Balanced Exhaust Fraction Schedule', kitchen_exhaust_fan.balancedExhaustFractionSchedule.get.name.get)
    assert_equal('RestaurantSitDown Kitchen_Exhaust_SCH', tranfer_air_fan.availabilitySchedule.get.name.get)
  end

  # A packaged unit whose HVAC template set its fan to cycle during occupied hours keeps cycling
  # under the night modes; an untagged unit gets the cloned availability schedule as before. Both
  # get the night outdoor air schedule. No shipped template cycles fans, so the test overrides the
  # template's air_loop_hvac_unitary_supply_fan_cycles? to stand in for one that does.
  def test_template_cycling_fans_keep_cycling
    puts "\n######\nTEST:#{__method__}\n######\n"
    model = OpenStudio::Model::Model.new
    std = Standard.build('ComStock DOE Ref 1980-2004')
    std.define_singleton_method(:air_loop_hvac_unitary_supply_fan_cycles?) { |_air_loop_hvac| true }
    zones = (0...2).map do |i|
      polygon = OpenStudio::Point3dVector.new
      [[0, 0], [0, 10], [10, 10], [10, 0]].each { |x, y| polygon << OpenStudio::Point3d.new(x + (i * 20), y, 0) }
      space = OpenStudio::Model::Space.fromFloorPrint(polygon, 3.0, model).get
      zone = OpenStudio::Model::ThermalZone.new(model)
      space.setThermalZone(zone)
      zone
    end
    loops = zones.map { |zone| std.model_add_psz_ac(model, [zone]).first }
    loops.each do |loop|
      availability = OpenStudio::Model::ScheduleRuleset.new(model, 1.0)
      loop.setAvailabilitySchedule(availability)
      loop.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir.setMinimumOutdoorAirSchedule(availability)
    end
    std.air_loop_hvac_apply_unitary_supply_fan_operating_mode(loops[0])
    units = loops.map { |loop| loop.supplyComponents.map(&:to_AirLoopHVACUnitarySystem).find(&:is_initialized).get }
    assert_equal(model.alwaysOffDiscreteSchedule, units[0].supplyAirFanOperatingModeSchedule.get)

    measure = AddHvacNighttimeOperationVariability.new
    argument_map = OpenStudio::Measure::OSArgumentMap.new
    rtu_night_mode = measure.arguments(model)[0].clone
    assert(rtu_night_mode.setValue('night_fancycle_vent'))
    argument_map['rtu_night_mode'] = rtu_night_mode
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    measure.run(model, runner, argument_map)
    assert_equal('Success', runner.result.value.valueName)

    assert_equal(model.alwaysOffDiscreteSchedule, units[0].supplyAirFanOperatingModeSchedule.get, 'template cycling fan should keep cycling')
    assert_includes(units[1].supplyAirFanOperatingModeSchedule.get.name.to_s, 'night_fancycle_schedule')
    loops.each do |loop|
      assert_includes(loop.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir.minimumOutdoorAirSchedule.get.name.to_s, 'night_ventcycle_schedule')
    end
  end
end
