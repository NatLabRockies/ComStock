# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'fileutils'
require 'minitest/autorun'
require_relative '../measure'
require_relative '../../set_primary_kitchen_equipment/measure'
require_relative '../../../../test/helpers/minitest_helper'

class ElectrifyKitchenEquipmentTest < Minitest::Test
  def models_for_tests
    paths = Dir.glob(File.join(__dir__, '../../../tests/models/*.osm'))
    paths = paths.map { |path| File.expand_path(path) }
    return paths
  end

  def load_model(osm_path)
    translator = OpenStudio::OSVersion::VersionTranslator.new
    model = translator.loadModel(OpenStudio::Path.new(osm_path))
    assert(!model.empty?)
    return model.get
  end

  def run_dir(test_name)
    return "#{__dir__}/output/#{test_name}"
  end

  # run a measure on a model with the given argument values; returns the runner result
  def run_measure_on(measure, model, arg_hash = {})
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

  # the sampled appliances set_primary_kitchen_equipment installs before this measure runs
  def install_gas_appliances(model, counts)
    arg_hash = { 'cook_dining_type' => 'Restaurant A' }
    counts.each do |type, count|
      arg_hash["cook_fuel_#{type}"] = 'Gas'
      arg_hash["cook_#{type}s_counts"] = count
    end
    result = run_measure_on(SetPrimaryKitchenEquipment.new, model, arg_hash)
    assert_equal('Success', result.value.valueName)
  end

  # building-level design power, summing zone multipliers, in W
  def building_equipment_w(model, fuel)
    total = 0.0
    model.getSpaces.each do |space|
      next if space.spaceType.empty?

      instances = fuel == :gas ? space.spaceType.get.gasEquipment : space.spaceType.get.electricEquipment
      instances.each { |i| total += i.getDesignLevel(space.floorArea, space.numberOfPeople) * space.multiplier }
    end
    return total
  end

  # Build a model the way create_custom_building_from_spec does: the kitchen space type is the
  # all-level 'food preparation' with no standards building type, its loads sit on the space type
  # with schedules from a default schedule set, and the spaces are named after the space type.
  def spec_style_model(kitchen_space_type_name:, num_kitchens:, zone_multiplier:)
    model = OpenStudio::Model::Model.new

    ruleset = OpenStudio::Model::ScheduleRuleset.new(model, 0.5)
    ruleset.setName("#{kitchen_space_type_name} gas equipment")
    schedule_set = OpenStudio::Model::DefaultScheduleSet.new(model)
    schedule_set.setGasEquipmentSchedule(ruleset)
    schedule_set.setElectricEquipmentSchedule(ruleset)

    kitchen_type = OpenStudio::Model::SpaceType.new(model)
    kitchen_type.setName(kitchen_space_type_name)
    kitchen_type.setStandardsSpaceType(kitchen_space_type_name)
    kitchen_type.setDefaultScheduleSet(schedule_set)

    gas_def = OpenStudio::Model::GasEquipmentDefinition.new(model)
    gas_def.setName("#{kitchen_space_type_name} Gas Equip Definition")
    gas_def.setWattsperSpaceFloorArea(649.25)
    gas = OpenStudio::Model::GasEquipment.new(gas_def)
    gas.setName("#{kitchen_space_type_name} Gas Equip")
    gas.setSpaceType(kitchen_type)

    elec_def = OpenStudio::Model::ElectricEquipmentDefinition.new(model)
    elec_def.setWattsperSpaceFloorArea(240.8)
    elec = OpenStudio::Model::ElectricEquipment.new(elec_def)
    elec.setName("#{kitchen_space_type_name} Elec Equip")
    elec.setSpaceType(kitchen_type)

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
      zone.setMultiplier(zone_multiplier)
      space.setThermalZone(zone)
    end

    return model
  end

  def test_number_of_arguments_and_argument_names
    puts "\n######\nTEST:#{__method__}\n######\n"
    measure = ElectrifyKitchenEquipment.new
    model = OpenStudio::Model::Model.new
    assert_equal(0, measure.arguments(model).size)
  end

  def test_appliance_name_parsing
    puts "\n######\nTEST:#{__method__}\n######\n"
    measure = ElectrifyKitchenEquipment.new
    assert_equal(2.0, measure.get_quantity_from_name('gas_fryer_equipment_bldg_quantity=2.0'))
    assert_equal('fryer', measure.get_equip_type_from_name('gas_fryer_equipment_bldg_quantity=2.0'))
    assert_nil(measure.get_quantity_from_name('food preparation Gas Equip'))
    assert_nil(measure.get_equip_type_from_name('food preparation bakery Gas Equip'))
  end

  # a prototype-derived model: kitchen spaces named 'Kitchen'
  def test_prototype_full_service_restaurant
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = models_for_tests.find { |p| File.basename(p) == 'Full_Service_Restaurant_4A.osm' }
    assert(!osm_path.nil?)
    model = load_model(osm_path)
    install_gas_appliances(model, { 'fryer' => 2, 'range' => 1, 'oven' => 1 })
    gas_before = building_equipment_w(model, :gas)
    assert_in_delta((2 * 23.447 + 42.497 + 12.896) * 1000.0, gas_before, 1.0)

    result = run_measure_on(ElectrifyKitchenEquipment.new, model)
    assert_equal('Success', result.value.valueName)
    assert_in_delta(0.0, building_equipment_w(model, :gas), 1e-6)
    kitchen_type = model.getSpaceTypes.find { |st| st.name.to_s.include?('Kitchen') }
    names = kitchen_type.electricEquipment.map { |e| e.name.to_s }
    assert(names.include?('electric_fryer_equipment_bldg_quantity=2.0'), names.inspect)
    assert(names.include?('electric_range_equipment_bldg_quantity=1.0'), names.inspect)
    assert(names.include?('electric_oven_equipment_bldg_quantity=1.0'), names.inspect)
  end

  # a spec-style model: kitchen spaces named 'food preparation', zones with multipliers
  def test_spec_style_food_preparation_kitchen
    puts "\n######\nTEST:#{__method__}\n######\n"
    model = spec_style_model(kitchen_space_type_name: 'food preparation', num_kitchens: 3, zone_multiplier: 5)
    install_gas_appliances(model, { 'fryer' => 2, 'griddle' => 1 })
    assert_in_delta((2 * 23.447 + 26.377) * 1000.0, building_equipment_w(model, :gas), 1.0)
    elec_before = building_equipment_w(model, :elec)

    result = run_measure_on(ElectrifyKitchenEquipment.new, model)
    assert_equal('Success', result.value.valueName)
    # all gas appliances are gone; the electric equivalents carry the same building-level count
    assert_in_delta(0.0, building_equipment_w(model, :gas), 1e-6)
    assert_in_delta(elec_before + (2 * 14009.0 + 17116.0), building_equipment_w(model, :elec), 1.0)
    kitchen_type = model.getSpaceTypeByName('food preparation').get
    fryer = kitchen_type.electricEquipment.find { |e| e.name.to_s == 'electric_fryer_equipment_bldg_quantity=2.0' }
    assert(!fryer.nil?)
    assert_in_delta(1.0 / 15, fryer.multiplier, 1e-9)
    assert_equal('food preparation gas equipment', fryer.schedule.get.name.to_s)
    assert_equal(0, model.getGasEquipmentDefinitions.size)
  end

  # gas equipment that is not a sampled appliance is left alone and reported
  def test_non_appliance_gas_equipment_is_left_as_gas
    puts "\n######\nTEST:#{__method__}\n######\n"
    model = spec_style_model(kitchen_space_type_name: 'food preparation - secondary school', num_kitchens: 1, zone_multiplier: 1)
    gas_before = building_equipment_w(model, :gas)
    result = run_measure_on(ElectrifyKitchenEquipment.new, model)
    assert_equal('NA', result.value.valueName)
    assert_in_delta(gas_before, building_equipment_w(model, :gas), 1e-6)
    assert(result.warnings.any? { |w| w.logMessage.include?('left as gas') })
  end

  def test_no_kitchen_is_not_applicable
    puts "\n######\nTEST:#{__method__}\n######\n"
    model = spec_style_model(kitchen_space_type_name: 'food preparation - bakery', num_kitchens: 1, zone_multiplier: 1)
    result = run_measure_on(ElectrifyKitchenEquipment.new, model)
    assert_equal('NA', result.value.valueName)
  end
end
