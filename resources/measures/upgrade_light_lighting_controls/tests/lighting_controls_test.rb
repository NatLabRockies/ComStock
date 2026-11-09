# ComStock™, Copyright (c) 2023 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
require 'openstudio'
require 'openstudio/ruleset/ShowRunnerOutput'
require 'minitest/autorun'
require_relative '../measure'
require 'csv'
require 'fileutils'
require 'json'
require_relative '../../../../test/helpers/minitest_helper'

class LightingControlsTest < Minitest::Test
  # Build a windowless model with one 10 m x 10 m space per space type. Each entry is
  # [standards space type, lighting_space_type property (nil for a prototype space type), general W/ft2, other lights].
  # Typical models (create_custom_building_from_spec) carry the lighting_space_type property and name their lights
  # '<space type> General Lighting', '<space type> Task Lighting', ...
  def build_model(building_type, template, space_types)
    model = OpenStudio::Model::Model.new
    model.getBuilding.setStandardsBuildingType(building_type)
    model.getBuilding.additionalProperties.setFeature('energy_code_in_force_during_original_building_construction', template)
    space_types.each_with_index do |(name, lighting_space_type, general_w_ft2, other_lights), i|
      space_type = OpenStudio::Model::SpaceType.new(model)
      space_type.setName(name)
      space_type.setStandardsSpaceType(name)
      space_type.additionalProperties.setFeature('lighting_space_type', lighting_space_type) unless lighting_space_type.nil?
      lights = { 'General' => general_w_ft2 }.merge(other_lights || {})
      lights.each do |kind, w_ft2|
        next if w_ft2.nil?

        definition = OpenStudio::Model::LightsDefinition.new(model)
        definition.setName("#{name} #{kind} Lights Definition")
        definition.setWattsperSpaceFloorArea(OpenStudio.convert(w_ft2, 'W/ft^2', 'W/m^2').get)
        light = OpenStudio::Model::Lights.new(definition)
        light.setName("#{name} #{kind} Lighting")
        light.setSpaceType(space_type)
      end
      x0 = i * 10.0
      floor_print = OpenStudio::Point3dVector.new
      [[x0, 0, 0], [x0, 10, 0], [x0 + 10, 10, 0], [x0 + 10, 0, 0]].each { |p| floor_print << OpenStudio::Point3d.new(*p) }
      space = OpenStudio::Model::Space.fromFloorPrint(floor_print, 3.0, model).get
      space.setSpaceType(space_type)
      space.setThermalZone(OpenStudio::Model::ThermalZone.new(model))
    end
    model
  end

  def run_measure(model, apply_daylighting: true, apply_occupancy: true)
    measure = LightingControls.new
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    { 'apply_daylighting' => apply_daylighting, 'apply_occupancy' => apply_occupancy }.each do |name, value|
      argument = arguments.find { |a| a.name == name }.clone
      assert(argument.setValue(value))
      argument_map[name] = argument
    end
    measure.run(model, runner, argument_map)
    result = runner.result
    show_output(result)
    result
  end

  # lighting power density in W/ft2 of the lights named '<space type> <kind> Lighting'
  def lpd(model, space_type_name, kind = 'General')
    light = model.getLightss.find { |l| l.name.get == "#{space_type_name} #{kind} Lighting" }
    OpenStudio.convert(light.lightsDefinition.wattsperSpaceFloorArea.get, 'W/m^2', 'W/ft^2').get
  end

  # typical small office: [space type, lighting_space_type, general W/ft2, other lights, expected reduction]
  SMALL_OFFICE = [
    ['office', 'office_lighting', 0.428, { 'Wall Wash' => 0.099 }, 0.15],
    ['conference/meeting/multipurpose', 'conference_meeting_multipurpose_lighting', 0.457, nil, 0.0],
    ['corridor', 'corridor_lighting', 0.248, nil, 0.25],
    ['lobby', 'lobby_lighting', 0.405, nil, 0.25],
    ['restroom', 'restroom_lighting', 0.281, nil, 0.45],
    ['storage', 'storage_lighting', 0.173, nil, 0.45],
    ['stairwell', 'stairwell_lighting', 0.264, nil, 0.75],
    ['electrical/mechanical', 'electrical_mechanical_lighting', 0.194, nil, 0.30]
  ].freeze

  def test_number_of_arguments_and_argument_names
    arguments = LightingControls.new.arguments(OpenStudio::Model::Model.new)
    assert_equal(2, arguments.size)
    assert_equal('apply_daylighting', arguments[0].name)
    assert_equal('apply_occupancy', arguments[1].name)
  end

  # Typical offices are space by space: each space type takes its own reduction instead of the prototypes'
  # whole-building 15%. A windowless building gets no daylighting, so occupancy sensors alone make it applicable.
  def test_typical_small_office_space_by_space
    model = build_model('SmallOffice', 'ComStock DOE Ref Pre-1980', SMALL_OFFICE.map { |r| r[0..3] })
    result = run_measure(model)
    assert_equal('Success', result.value.valueName)
    assert_equal(0, model.getDaylightingControls.size)
    SMALL_OFFICE.each do |name, _lst, w_ft2, _other, reduction|
      assert_in_delta(w_ft2 * (1 - reduction), lpd(model, name), 1e-6, name)
    end
    # only general lighting is reduced
    assert_in_delta(0.099, lpd(model, 'office', 'Wall Wash'), 1e-6)
    assert_includes(result.finalCondition.get.logMessage, 'occupancy sensors were applied to 7 space types')
  end

  # 90.1-2010 already requires occupancy sensors in restrooms, storage and conference rooms (the prototype
  # Restroom/Storage/Conference skips carried over to the typical names).
  def test_typical_skip_list_90_1_2010
    model = build_model('SmallOffice', 'ComStock 90.1-2010', SMALL_OFFICE.map { |r| r[0..3] })
    result = run_measure(model)
    assert_equal('Success', result.value.valueName)
    skipped = ['restroom', 'storage', 'conference/meeting/multipurpose']
    SMALL_OFFICE.each do |name, _lst, w_ft2, _other, reduction|
      expected = skipped.include?(name) ? w_ft2 : w_ft2 * (1 - reduction)
      assert_in_delta(expected, lpd(model, name), 1e-6, name)
    end
  end

  # 90.1-2004/2007 skip only conference rooms and lounges, which carry no reduction anyway.
  def test_typical_skip_list_90_1_2007
    model = build_model('SmallOffice', 'ComStock 90.1-2007', SMALL_OFFICE.map { |r| r[0..3] })
    run_measure(model)
    SMALL_OFFICE.each do |name, _lst, w_ft2, _other, reduction|
      assert_in_delta(w_ft2 * (1 - reduction), lpd(model, name), 1e-6, name)
    end
  end

  # DEER 2014: classrooms, computer rooms and restrooms are skipped in schools; corridors and gyms are not.
  def test_typical_school_skip_list_deer_2014
    school = [
      ['classroom/lecture/training - primary school', 'classroom_lecture_training_lighting', 0.6, nil],
      ['computer room', 'computer_room_lighting', 0.8, nil],
      ['restroom - primary school', 'restroom_lighting', 0.3, nil],
      ['corridor - primary school', 'corridor_lighting', 0.25, nil],
      ['playing area - primary school', 'playing_area_lighting', 0.7, nil]
    ]
    model = build_model('PrimarySchool', 'ComStock DEER 2014', school)
    run_measure(model)
    assert_in_delta(0.6, lpd(model, 'classroom/lecture/training - primary school'), 1e-6)
    assert_in_delta(0.8, lpd(model, 'computer room'), 1e-6)
    assert_in_delta(0.3, lpd(model, 'restroom - primary school'), 1e-6)
    assert_in_delta(0.25 * 0.75, lpd(model, 'corridor - primary school'), 1e-6)
    assert_in_delta(0.7 * 0.65, lpd(model, 'playing area - primary school'), 1e-6)

    # the same school built before 90.1-2004 gets classroom sensors
    model = build_model('PrimarySchool', 'ComStock DOE Ref 1980-2004', school)
    run_measure(model)
    assert_in_delta(0.6 * 0.7, lpd(model, 'classroom/lecture/training - primary school'), 1e-6)
    assert_in_delta(0.8 * 0.75, lpd(model, 'computer room'), 1e-6)
  end

  # Guest rooms take the Table G3.7 reduction on general lighting only; typical guest rooms have none.
  def test_typical_guest_room_task_lit
    # Table G3.7 (and the measure documentation) gives guest rooms 0.45, but a typical guest room is task lit
    # (comstock-typical guest_room_lighting has no General Lighting) and task lighting is never reduced, so it is left
    # alone and a hotel with nothing else is not applicable
    model = build_model('SmallHotel', 'ComStock DOE Ref Pre-1980', [['guest room', 'guest_room_lighting', nil, { 'Task' => 0.3 }]])
    result = run_measure(model)
    assert_equal('NA', result.value.valueName)
    assert_in_delta(0.3, lpd(model, 'guest room', 'Task'), 1e-6)

    # a guest room that does carry general lighting gets the Table G3.7 reduction
    model = build_model('SmallHotel', 'ComStock DOE Ref Pre-1980', [['guest room', 'guest_room_lighting', 0.2, { 'Task' => 0.3 }]])
    result = run_measure(model)
    assert_equal('Success', result.value.valueName)
    assert_in_delta(0.2 * 0.55, lpd(model, 'guest room'), 1e-6)
    assert_in_delta(0.3, lpd(model, 'guest room', 'Task'), 1e-6)
  end

  # R3's retail daylighting exception carried over: no sidelighting control in a strip mall's 'retail' or a stand-alone
  # retail's 'lobby' (the prototype strip mall types and Entry); the stand-alone sales floor and a hotel's retail
  # space keep it. Occupancy sensors still apply to the strip mall.
  def test_typical_retail_daylighting_exception
    daylit_spaces = lambda do |building_type, space_types|
      model = build_model(building_type, 'ComStock DOE Ref Pre-1980', space_types)
      model.getSpaces.each do |space|
        wall = space.surfaces.find { |s| s.surfaceType == 'Wall' && s.outwardNormal.y < -0.9 }
        assert(wall.setWindowToWallRatio(0.4).is_initialized)
      end
      result = run_measure(model)
      [result, model, model.getDaylightingControls.map { |c| c.space.get.spaceType.get.standardsSpaceType.to_s }.uniq.sort]
    end

    result, model, daylit = daylit_spaces.call('RetailStripmall', [['retail', 'retail_sales_lighting', 0.7, nil]])
    assert_equal('Success', result.value.valueName)
    assert_empty(daylit)
    assert_in_delta(0.7 * 0.9, lpd(model, 'retail'), 1e-6)

    _result, _model, daylit = daylit_spaces.call('LargeHotel', [['retail', 'retail_sales_lighting', 0.7, nil]])
    assert_equal(['retail'], daylit)

    _result, _model, daylit = daylit_spaces.call('RetailStandalone', [['lobby', 'lobby_lighting', 0.4, nil],
                                                                       ['retail - mass merchandising', 'retail_mass_merchandising_lighting', 0.7, nil]])
    assert_equal(['retail - mass merchandising'], daylit)
  end

  # A typical space type missing from the typical table is reported, not silently skipped.
  def test_typical_space_type_missing_from_table_warns
    model = build_model('Office', 'ComStock DOE Ref Pre-1980', [['atrium', 'atrium_lighting', 0.5, nil]])
    result = run_measure(model)
    assert_equal('NA', result.value.valueName)
    assert(result.warnings.any? { |w| w.logMessage.include?("No LPD reduction specified for typical space type 'atrium'") })
    assert_in_delta(0.5, lpd(model, 'atrium'), 1e-6)
  end

  # Prototype models keep the prototype table and skip lists.
  def test_prototype_space_types_unchanged
    model = build_model('SmallOffice', 'ComStock DOE Ref 1980-2004', [['WholeBuilding - Sm Office', nil, 0.9, nil]])
    result = run_measure(model)
    assert_equal('Success', result.value.valueName)
    assert_in_delta(0.9 * 0.85, lpd(model, 'WholeBuilding - Sm Office'), 1e-6)

    model = build_model('SecondarySchool', 'ComStock 90.1-2010', [['Restroom', nil, 0.9, nil], ['Corridor', nil, 0.5, nil]])
    run_measure(model)
    assert_in_delta(0.9, lpd(model, 'Restroom'), 1e-6)
    assert_in_delta(0.5 * 0.75, lpd(model, 'Corridor'), 1e-6)
  end

  # A space whose 90.1-2019 setpoint is 'na' (ClosedOffice) gets no daylighting sensor; the rest of the measure,
  # including the occupancy sensors, still runs.
  def test_daylighting_na_setpoint_skips_only_that_space
    model = build_model('Office', 'ComStock 90.1-2019', [['ClosedOffice', nil, 0.8, nil], ['WholeBuilding - Sm Office', nil, 0.9, nil]])
    closed_office = model.getSpaceTypes.find { |st| st.name.get == 'ClosedOffice' }
    closed_office.setStandardsBuildingType('Office')
    wall = closed_office.spaces[0].surfaces.find { |s| s.surfaceType == 'Wall' && s.outwardNormal.y < -0.9 }
    assert(wall.setWindowToWallRatio(0.4).is_initialized)
    result = run_measure(model)
    assert_equal('Success', result.value.valueName)
    assert(result.info.any? { |m| m.logMessage.include?('daylighting is not appropriate') })
    assert_equal(0, model.getDaylightingControls.size)
    assert_in_delta(0.9 * 0.85, lpd(model, 'WholeBuilding - Sm Office'), 1e-6)
    assert_includes(result.finalCondition.get.logMessage, 'Daylighting sensors were applied to 0 spaces')
  end

  # Every space type ComStock builds has a row in the typical table.
  def test_typical_table_covers_comstock_space_types
    building_types_path = File.expand_path('../../../create_custom/comstock_building_types.json', __dir__)
    skip("#{building_types_path} not found") unless File.exist?(building_types_path)
    building_types = JSON.parse(File.read(building_types_path))['building_types']
    used = building_types.values.flat_map { |b| b['space_type_ratios'].flat_map { |r| r['space_types'].keys } }.uniq
    table = CSV.read(File.expand_path('../resources/occupancy_sensor_reduction_by_typical_space_type.csv', __dir__), headers: true)
    names = table.map { |r| r['standards_space_type'] }
    assert_empty(used - names, 'typical space types missing from occupancy_sensor_reduction_by_typical_space_type.csv')
    table.each { |r| assert((0.0..1.0).cover?(r['lpd_reduction'].to_f), r['standards_space_type']) }
  end
end
