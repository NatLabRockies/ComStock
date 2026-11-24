# ComStock™, Copyright (c) 2023 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
require 'openstudio'
require 'minitest/autorun'
require_relative '../measure'
require_relative '../../../../test/helpers/minitest_helper'

class LightingControlsTest < Minitest::Test
  def test_number_of_arguments_and_argument_names
    measure = LightingControls.new
    model = OpenStudio::Model::Model.new

    arguments = measure.arguments(model)
    assert_equal(['apply_daylighting', 'apply_occupancy'], arguments.map(&:name))
  end

  def test_occupancy_controls_reduce_general_lighting
    model, lights_definition = classroom_model('ComStock 90.1-2004')

    result = run_measure(model, apply_daylighting: false, apply_occupancy: true)

    assert_equal('Success', result.value.valueName)
    assert_in_delta(7.0, lights_definition.wattsperSpaceFloorArea.get, 0.001)
    assert_empty(model.getDaylightingControls)
  end

  def test_occupancy_controls_skip_spaces_already_required_by_code
    model, lights_definition = classroom_model('ComStock 90.1-2013')

    result = run_measure(model, apply_daylighting: false, apply_occupancy: true)

    assert_equal('NA', result.value.valueName)
    assert_in_delta(10.0, lights_definition.wattsperSpaceFloorArea.get, 0.001)
  end

  def test_disabled_controls_leave_lighting_unchanged
    model, lights_definition = classroom_model('ComStock 90.1-2004')

    result = run_measure(model, apply_daylighting: false, apply_occupancy: false)

    assert_equal('NA', result.value.valueName)
    assert_in_delta(10.0, lights_definition.wattsperSpaceFloorArea.get, 0.001)
    assert_empty(model.getDaylightingControls)
  end

  def test_daylighting_controls_skip_spaces_without_exterior_fenestration
    model, lights_definition = classroom_model('ComStock 90.1-2004')

    result = run_measure(model, apply_daylighting: true, apply_occupancy: false)

    assert_equal('NA', result.value.valueName)
    assert_in_delta(10.0, lights_definition.wattsperSpaceFloorArea.get, 0.001)
    assert_empty(model.getDaylightingControls)
  end

  def classroom_model(template)
    model = OpenStudio::Model::Model.new
    model.getBuilding.additionalProperties.setFeature(
      'energy_code_in_force_during_original_building_construction', template
    )

    space_type = OpenStudio::Model::SpaceType.new(model)
    space_type.setStandardsBuildingType('SecondarySchool')
    space_type.setStandardsSpaceType('Classroom')

    space = OpenStudio::Model::Space.new(model)
    space.setSpaceType(space_type)
    space.setThermalZone(OpenStudio::Model::ThermalZone.new(model))

    lights_definition = OpenStudio::Model::LightsDefinition.new(model)
    lights_definition.setWattsperSpaceFloorArea(10.0)
    lights = OpenStudio::Model::Lights.new(lights_definition)
    lights.setName('Classroom General Lighting')
    lights.setSpaceType(space_type)

    [model, lights_definition]
  end

  def run_measure(model, apply_daylighting:, apply_occupancy:)
    measure = LightingControls.new
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    arguments = OpenStudio::Measure.convertOSArgumentVectorToMap(measure.arguments(model))
    { 'apply_daylighting' => apply_daylighting, 'apply_occupancy' => apply_occupancy }.each do |name, value|
      argument = arguments[name].clone
      assert(argument.setValue(value))
      arguments[name] = argument
    end

    assert(measure.run(model, runner, arguments))
    runner.result
  end
end
