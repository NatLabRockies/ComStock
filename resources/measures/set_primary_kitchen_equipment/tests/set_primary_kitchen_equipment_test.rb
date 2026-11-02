# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'fileutils'
require 'minitest/autorun'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require_relative '../measure'

class SetPrimaryKitchenEquipmentTest < Minitest::Test
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

  def test_number_of_arguments_and_argument_names
    # this test ensures that the current test is matched to the measure inputs
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = SetPrimaryKitchenEquipment.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(13, arguments.size)
    assert_equal('cook_dining_type', arguments[0].name)
    assert_equal('cook_fuel_broiler', arguments[1].name)
    assert_equal('cook_broilers_counts', arguments[2].name)
    assert_equal('cook_fuel_griddle', arguments[3].name)
    assert_equal('cook_griddles_counts', arguments[4].name)
    assert_equal('cook_fuel_fryer', arguments[5].name)
    assert_equal('cook_fryers_counts', arguments[6].name)
    assert_equal('cook_fuel_oven', arguments[7].name)
    assert_equal('cook_ovens_counts', arguments[8].name)
    assert_equal('cook_fuel_range', arguments[9].name)
    assert_equal('cook_ranges_counts', arguments[10].name)
    assert_equal('cook_fuel_steamer', arguments[11].name)
    assert_equal('cook_steamers_counts', arguments[12].name)
  end

  # create an array of hashes with model name, weather, and expected result
  def models_to_test
    test_sets = []
    test_sets << {
      model: 'Full_Service_Restaurant_4A',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'Success',
      arg_hash: {
        'cook_dining_type' => 'None',
        'cook_fuel_broiler' => 'Gas',
        'cook_broilers_counts' => 1,
        'cook_fuel_griddle' => 'Gas',
        'cook_griddles_counts' => 1,
        'cook_fuel_fryer' => 'Gas',
        'cook_fryers_counts' => 1,
        'cook_fuel_oven' => 'Gas',
        'cook_ovens_counts' => 1,
        'cook_fuel_range' => 'Gas',
        'cook_ranges_counts' => 1,
        'cook_fuel_steamer' => 'Gas',
        'cook_steamers_counts' => 1
      }
    }

    test_sets << {
      model: 'Quick_Service_Restaurant_CA',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'Success',
      arg_hash: {
        'cook_dining_type' => 'None',
        'cook_fuel_broiler' => 'Electric',
        'cook_broilers_counts' => 1,
        'cook_fuel_griddle' => 'Electric',
        'cook_griddles_counts' => 1,
        'cook_fuel_fryer' => 'Electric',
        'cook_fryers_counts' => 1,
        'cook_fuel_oven' => 'Electric',
        'cook_ovens_counts' => 1,
        'cook_fuel_range' => 'Electric',
        'cook_ranges_counts' => 1,
        'cook_fuel_steamer' => 'Electric',
        'cook_steamers_counts' => 1
      }
    }

    return test_sets
  end

  def test_models
    puts "\n######\nTEST:#{__method__}\n######\n"

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
      measure = SetPrimaryKitchenEquipment.new

      # load the model; only used here for populating arguments
      model = load_model(osm_path)

      # set arguments here; will vary by measure
      arguments = measure.arguments(model)
      argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

      # populate argument with specified hash value if specified
      arguments.each do |arg|
        temp_arg_var = arg.clone
        if !set[:arg_hash].nil? && set[:arg_hash].key?(arg.name)
          assert(temp_arg_var.setValue(set[:arg_hash][arg.name]))
        end
        argument_map[arg.name] = temp_arg_var
      end

      # apply the measure to the model and optionally run the model
      result = apply_measure_and_run(instance_test_name, measure, argument_map, osm_path, epw_path, run_model: false)

      # check the measure result; result values will equal Success, Fail, or Not Applicable
      # also check the amount of warnings, info, and error messages
      # use if or case statements to change expected assertion depending on model characteristics
      assert(result.value.valueName == set[:result])

      # to check that something changed in the model, load the model and the check the objects match expected new value
      model = load_model(model_output_path(instance_test_name))
    end
  end

  # names the measure must and must not treat as a commercial kitchen
  def test_kitchen_name_matching
    puts "\n######\nTEST:#{__method__}\n######\n"
    measure = SetPrimaryKitchenEquipment.new

    # prototype spellings
    assert(measure.kitchen_name?('Kitchen'))
    assert(measure.kitchen_name?('PrimarySchool Kitchen - 90.1-2004'))
    assert(measure.kitchen_name?('Hospital Kitchen - ComStock DOE Ref Pre-1980'))
    # all-level spellings from a ComStock building spec
    assert(measure.kitchen_name?('food preparation'))
    assert(measure.kitchen_name?('food preparation - primary school'))
    assert(measure.kitchen_name?('food preparation - secondary school'))
    assert(measure.kitchen_name?('food preparation A - Story mid'))
    assert(measure.kitchen_name?('SuperMarket food preparation'))
    # grocery service areas and everything else
    assert(!measure.kitchen_name?('food preparation - bakery'))
    assert(!measure.kitchen_name?('food preparation - deli'))
    assert(!measure.kitchen_name?('food preparation - deli/bakery'))
    assert(!measure.kitchen_name?('dining - cafeteria/fast food'))
    assert(!measure.kitchen_name?('dining'))
    assert(!measure.kitchen_name?('Office'))
  end

  # Build a model the way create_custom_building_from_spec does: the kitchen space type is the
  # all-level 'food preparation' with no standards building type, its loads sit on the space type
  # with schedules inherited from a default schedule set, and the spaces are named after the space
  # type. The kitchen spaces sit in zones with a multiplier, as a mid-story kitchen does.
  def spec_style_model(kitchen_space_type_name:, num_kitchens:, zone_multiplier:)
    model = OpenStudio::Model::Model.new

    ruleset = OpenStudio::Model::ScheduleRuleset.new(model, 0.5)
    ruleset.setName("#{kitchen_space_type_name} gas equipment")
    schedule_set = OpenStudio::Model::DefaultScheduleSet.new(model)
    schedule_set.setName("#{kitchen_space_type_name} Schedule Set")
    schedule_set.setGasEquipmentSchedule(ruleset)
    schedule_set.setElectricEquipmentSchedule(ruleset)

    kitchen_type = OpenStudio::Model::SpaceType.new(model)
    kitchen_type.setName(kitchen_space_type_name)
    kitchen_type.setStandardsSpaceType(kitchen_space_type_name)
    kitchen_type.setDefaultScheduleSet(schedule_set)

    gas_def = OpenStudio::Model::GasEquipmentDefinition.new(model)
    gas_def.setName("#{kitchen_space_type_name} Gas Equip Definition")
    gas_def.setWattsperSpaceFloorArea(649.25) # 205.81 Btu/hr-ft2, the cross-building median
    gas = OpenStudio::Model::GasEquipment.new(gas_def)
    gas.setName("#{kitchen_space_type_name} Gas Equip")
    gas.setSpaceType(kitchen_type)

    elec_def = OpenStudio::Model::ElectricEquipmentDefinition.new(model)
    elec_def.setName("#{kitchen_space_type_name} Elec Equip Definition")
    elec_def.setWattsperSpaceFloorArea(240.8)
    elec = OpenStudio::Model::ElectricEquipment.new(elec_def)
    elec.setName("#{kitchen_space_type_name} Elec Equip")
    elec.setSpaceType(kitchen_type)

    dining_type = OpenStudio::Model::SpaceType.new(model)
    dining_type.setName('dining - cafeteria/fast food')
    dining_type.setStandardsSpaceType('dining - cafeteria/fast food')

    # 10 m x 10 m floor plates
    polygon = OpenStudio::Point3dVector.new
    polygon << OpenStudio::Point3d.new(0, 0, 0)
    polygon << OpenStudio::Point3d.new(0, 10, 0)
    polygon << OpenStudio::Point3d.new(10, 10, 0)
    polygon << OpenStudio::Point3d.new(10, 0, 0)

    ('A'..'Z').first(num_kitchens).each do |letter|
      space = OpenStudio::Model::Space.fromFloorPrint(polygon, 3.0, model).get
      space.setName("#{kitchen_space_type_name} #{letter} - Story mid")
      space.setSpaceType(kitchen_type)
      zone = OpenStudio::Model::ThermalZone.new(model)
      zone.setName("Zone #{space.name}")
      zone.setMultiplier(zone_multiplier)
      space.setThermalZone(zone)
    end

    dining = OpenStudio::Model::Space.fromFloorPrint(polygon, 3.0, model).get
    dining.setName('dining - cafeteria/fast food A - Story mid')
    dining.setSpaceType(dining_type)
    dining.setThermalZone(OpenStudio::Model::ThermalZone.new(model))

    return model
  end

  def run_measure_on(model, arg_hash)
    measure = SetPrimaryKitchenEquipment.new
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    arguments.each do |arg|
      temp_arg_var = arg.clone
      assert(temp_arg_var.setValue(arg_hash[arg.name])) if arg_hash.key?(arg.name)
      argument_map[arg.name] = temp_arg_var
    end
    measure.run(model, runner, argument_map)
    result = runner.result
    show_output(result)
    return result
  end

  # building-level appliance power, summing zone multipliers, in W
  def building_gas_equipment_w(model)
    total = 0.0
    model.getSpaces.each do |space|
      space.gasEquipment.each { |g| total += g.getDesignLevel(space.floorArea, space.numberOfPeople) * space.multiplier }
      next if space.spaceType.empty?

      space.spaceType.get.gasEquipment.each { |g| total += g.getDesignLevel(space.floorArea, space.numberOfPeople) * space.multiplier }
    end
    return total
  end

  def test_spec_style_food_preparation_kitchen
    puts "\n######\nTEST:#{__method__}\n######\n"
    model = spec_style_model(kitchen_space_type_name: 'food preparation', num_kitchens: 3, zone_multiplier: 5)
    # three 100 m2 kitchens in zones of multiplier 5, at 649.25 W/m2
    assert_in_delta(3 * 5 * 100.0 * 649.25, building_gas_equipment_w(model), 1.0)

    result = run_measure_on(model, {
      'cook_dining_type' => 'Restaurant A',
      'cook_fuel_fryer' => 'Gas', 'cook_fryers_counts' => 2,
      'cook_fuel_range' => 'Gas', 'cook_ranges_counts' => 1,
      'cook_fuel_oven' => 'Electric', 'cook_ovens_counts' => 1
    })
    assert_equal('Success', result.value.valueName)

    kitchen_type = model.getSpaceTypeByName('food preparation').get
    # the per-area gas load is gone, replaced by one instance per gas appliance type
    assert(kitchen_type.gasEquipment.none? { |g| g.name.to_s == 'food preparation Gas Equip' })
    assert_equal(2, kitchen_type.gasEquipment.size)
    # the building holds 2 fryers and 1 range regardless of how many kitchen spaces or zone multipliers
    assert_in_delta((2 * 23.447 + 1 * 42.497) * 1000.0, building_gas_equipment_w(model), 1.0)
    kitchen_type.gasEquipment.each do |g|
      assert_in_delta(1.0 / 15, g.multiplier, 1e-9)
      assert_equal('food preparation gas equipment', g.schedule.get.name.to_s)
    end
    # the electric oven was added and the misc electric load cut to 10%
    elec_names = kitchen_type.electricEquipment.map { |e| e.name.to_s }
    assert(elec_names.include?('electric_oven_equipment_bldg_quantity=1.0'), elec_names.inspect)
    misc = kitchen_type.electricEquipment.find { |e| e.name.to_s == 'misc_electric_kitchen_equipment' }
    assert(!misc.nil?, elec_names.inspect)
    assert_in_delta(24.08, misc.electricEquipmentDefinition.wattsperSpaceFloorArea.get, 0.01)
    # the dining space type is untouched
    dining_type = model.getSpaceTypeByName('dining - cafeteria/fast food').get
    assert(dining_type.gasEquipment.empty?)
  end

  def test_spec_style_school_kitchen_with_no_appliances
    puts "\n######\nTEST:#{__method__}\n######\n"
    model = spec_style_model(kitchen_space_type_name: 'food preparation - primary school', num_kitchens: 1, zone_multiplier: 1)
    result = run_measure_on(model, { 'cook_dining_type' => 'None' })
    assert_equal('Success', result.value.valueName)
    # no sampled appliances: the prototype gas load is removed and nothing replaces it
    assert_in_delta(0.0, building_gas_equipment_w(model), 1e-6)
  end

  def test_grocery_bakery_is_not_a_kitchen
    puts "\n######\nTEST:#{__method__}\n######\n"
    model = spec_style_model(kitchen_space_type_name: 'food preparation - bakery', num_kitchens: 1, zone_multiplier: 1)
    before = building_gas_equipment_w(model)
    result = run_measure_on(model, { 'cook_dining_type' => 'None' })
    assert_equal('NA', result.value.valueName)
    assert_in_delta(before, building_gas_equipment_w(model), 1e-6)
  end

  # a building spec can name several gas equipment objects for one space type; all are replaced
  def test_spec_style_kitchen_with_several_gas_objects
    puts "
######
TEST:#{__method__}
######
"
    model = spec_style_model(kitchen_space_type_name: 'food preparation', num_kitchens: 2, zone_multiplier: 1)
    kitchen_type = model.getSpaceTypeByName('food preparation').get
    second_def = OpenStudio::Model::GasEquipmentDefinition.new(model)
    second_def.setName('food preparation bakery Gas Equip Definition')
    second_def.setWattsperSpaceFloorArea(26.9)
    second = OpenStudio::Model::GasEquipment.new(second_def)
    second.setName('food preparation bakery Gas Equip')
    second.setSpaceType(kitchen_type)
    assert_equal(2, kitchen_type.gasEquipment.size)

    result = run_measure_on(model, { 'cook_dining_type' => 'Cafe', 'cook_fuel_oven' => 'Gas', 'cook_ovens_counts' => 1 })
    assert_equal('Success', result.value.valueName)
    assert_equal(['gas_oven_equipment_bldg_quantity=1.0'], kitchen_type.gasEquipment.map { |g| g.name.to_s })
    assert_in_delta(12.896 * 1000.0, building_gas_equipment_w(model), 1.0)
    assert_equal(0, model.getGasEquipmentDefinitions.count { |d| d.name.to_s.include?('bakery') })
  end
end
