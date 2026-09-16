# ComStock™, Copyright (c) 2026 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# Spec-assembly tests: everything the measure computes before handing the spec to
# create_custom_building_from_spec, exercised without a workflow or a simulation. The
# failure class these guard against is invisible to end-to-end runs until it fails every
# building at once -- a stray argument forwarded into typical_options, a stale definition
# from a previous run, a secondary building type's overrides silently dropped.

# dependencies
require 'minitest/autorun'
require 'openstudio'
require_relative '../measure'

class CreateCustomBuildingFromSpecTest < Minitest::Test
  def setup
    @measure = CreateCustomBuildingFromSpec.new
    @runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
  end

  def warnings
    @runner.result.warnings.map(&:logMessage)
  end

  def errors
    @runner.result.errors.map(&:logMessage)
  end

  # arguments for a single-type building; override to mix
  def base_args(building_type = 'Warehouse', template = 'ComStock 90.1-2013')
    {
      'template' => template,
      'bldg_type_a' => building_type,
      'bldg_subtype_a' => 'NA',
      'bldg_type_b_fract_bldg_area' => 0.0,
      'bldg_type_c_fract_bldg_area' => 0.0,
      'bldg_type_d_fract_bldg_area' => 0.0
    }
  end

  # --- typical_options assembly -------------------------------------------------------

  def test_typical_options_forwards_renames_and_call_site_defaults
    model = OpenStudio::Model::Model.new
    typed = {
      'template' => 'ComStock 90.1-2013',        # spec-managed, must not forward
      'climate_zone' => 'ASHRAE 169-2013-4A',    # spec-managed, must not forward
      'system_type' => 'PSZ-AC with gas coil',   # renamed keyword
      'swh_src' => 'NaturalGas',                 # renamed keyword
      'add_refrigeration' => false,              # forwarded as-is
      'bldg_type_a' => 'Warehouse',              # bar-only, must not forward
      'clg_sp_f' => 75.0,                        # consumed by this measure, must not forward
      'ltg_wkdy_bpr' => 0.3,                     # consumed by this measure, must not forward
      'lighting_generation' => 'gen4_led'
    }
    options = @measure.typical_options_from(model, typed)

    assert_equal('PSZ-AC with gas coil', options['hvac_system_type'], 'system_type should forward under its keyword name')
    assert_equal('NaturalGas', options['service_water_heating_fuel'])
    assert_equal(false, options['add_refrigeration'])
    assert_equal('gen4_led', options['lighting_generation'])
    assert_equal('parametric', options['schedule_method'], 'ComStock states its schedule engine explicitly')

    # call-site defaults restated so the method defaults cannot silently apply
    assert(options.key?('add_daylighting_controls'))
    assert_nil(options['add_daylighting_controls'])

    # nothing spec-managed, bar-only, or consumed by this measure reaches typical_options
    %w[template climate_zone bldg_type_a system_type swh_src clg_sp_f ltg_wkdy_bpr].each do |key|
      refute(options.key?(key), "'#{key}' should not be forwarded")
    end
  end

  # --- building type definitions ------------------------------------------------------

  def test_definition_prefers_the_exact_subtype_and_falls_back_to_na
    plain = @measure.definition_for('Warehouse', 'NA', 'ComStock 90.1-2013')
    bulk = @measure.definition_for('Warehouse', 'warehouse_bulk100', 'ComStock 90.1-2013')
    refute_nil(plain)
    refute_nil(bulk)
    refute_equal(plain['space_types'], bulk['space_types'], 'the subtype should carry its own mix')

    # an unknown subtype falls back to the NA row rather than failing
    fallback = @measure.definition_for('Warehouse', 'no_such_subtype', 'ComStock 90.1-2013')
    assert_equal(plain['space_types'], fallback['space_types'])

    assert_nil(@measure.definition_for('NoSuchBuildingType', 'NA', 'ComStock 90.1-2013'))
  end

  def test_constructions_merge_defaults_under_the_building_type
    spec = @measure.constructions_for('Warehouse', 'ComStock 90.1-2013')
    refute_nil(spec)
    assert(spec.key?('exterior_wall_type'), 'the building type layer carries the wall type')
    assert(spec['surfaces'].is_a?(Hash), 'the template defaults layer carries the shared surfaces')
    refute(spec.key?('slots'))
    assert_nil(@measure.constructions_for('Warehouse', 'ComStock No Such Template'))
  end

  # --- space type ratio expansion -----------------------------------------------------

  def test_single_type_ratios_normalize_and_carry_geometry_flags
    ratios = @measure.space_type_ratios(@runner, base_args)
    refute_nil(ratios, "expansion failed: #{errors}")
    assert_in_delta(1.0, ratios.sum { |r| r['ratio'] }, 1.0e-9, 'ratios should renormalize to 1.0')
    refute(ratios.any? { |r| r.key?('building_type') }, 'typical entries carry no building_type')
  end

  def test_unknown_building_type_is_an_error
    assert_nil(@measure.space_type_ratios(@runner, base_args('NoSuchBuildingType')))
    assert(errors.any? { |e| e.include?('NoSuchBuildingType') })
  end

  def test_mixed_types_expand_by_fraction
    args = base_args('Warehouse').merge('bldg_type_b' => 'Hospital', 'bldg_subtype_b' => 'NA',
                                        'bldg_type_b_fract_bldg_area' => 0.4)
    ratios = @measure.space_type_ratios(@runner, args)
    refute_nil(ratios, "expansion failed: #{errors}")
    assert_in_delta(1.0, ratios.sum { |r| r['ratio'] }, 1.0e-9)
    hospital_only = @measure.space_type_ratios(@runner, base_args('Hospital'))
    assert(ratios.size > hospital_only.size, 'the mix should carry both types\' space types')
  end

  # --- F4: overrides come from the whole mix ------------------------------------------

  def test_secondary_building_type_overrides_are_carried
    args = base_args('Warehouse').merge('bldg_type_b' => 'Hospital', 'bldg_subtype_b' => 'NA',
                                        'bldg_type_b_fract_bldg_area' => 0.4)
    refute_nil(@measure.space_type_ratios(@runner, args))

    exhaust = @measure.merged_overrides(@runner, 'exhaust_overrides')
    assert(exhaust.any? { |o| o['space_type'] == 'imaging' },
           "Hospital's imaging exhaust override should ride along as a secondary type: #{exhaust}")
    swh = @measure.merged_overrides(@runner, 'service_water_heating_overrides')
    assert(swh.any? { |o| o['space_type'] == 'food preparation' })
  end

  def test_override_collisions_prefer_the_primary_type_and_warn
    # Hospital and LargeHotel both override 'food preparation' service water heating
    args = base_args('Hospital').merge('bldg_type_b' => 'LargeHotel', 'bldg_subtype_b' => 'NA',
                                       'bldg_type_b_fract_bldg_area' => 0.4)
    refute_nil(@measure.space_type_ratios(@runner, args))

    swh = @measure.merged_overrides(@runner, 'service_water_heating_overrides')
    food_prep = swh.select { |o| o['space_type'] == 'food preparation' }
    assert_equal(1, food_prep.size, 'a colliding space type should appear once')
    hospital_entry = @measure.definition_for('Hospital', 'NA', 'ComStock 90.1-2013')['service_water_heating_overrides']
                             .find { |o| o['space_type'] == 'food preparation' }
    assert_equal(hospital_entry, food_prep.first, "the primary type's entry should win")
    assert(warnings.any? { |w| w.include?('food preparation') && w.include?('LargeHotel') },
           "the superseded entry should be logged: #{warnings}")
  end

  # --- F5: no state leaks between runs ------------------------------------------------

  def test_definitions_reset_between_runs
    hospital_args = base_args('Hospital')
    refute_nil(@measure.space_type_ratios(@runner, hospital_args))
    assert(@measure.merged_overrides(@runner, 'exhaust_overrides').any?,
           'Hospital carries an exhaust override')

    refute_nil(@measure.space_type_ratios(@runner, base_args('Warehouse')))
    assert_empty(@measure.merged_overrides(@runner, 'exhaust_overrides'),
                 "the previous run's Hospital definition leaked into the Warehouse run")
    primary = @measure.instance_variable_get(:@primary_definition)
    refute_nil(primary)
    assert(primary['space_types'].keys.any? { |name| name.include?('storage') },
           'the primary definition should now be the Warehouse mix')
  end

  # --- sampled thermostat variability -------------------------------------------------

  def test_thermostat_variability_sentinels_are_a_no_op
    typed = { 'clg_sp_f' => 999.0, 'clg_delta_f' => 999.0, 'htg_sp_f' => 999.0, 'htg_delta_f' => 999.0 }
    assert_empty(@measure.thermostat_variability_overrides(@runner, typed, ['office']))
  end

  def test_thermostat_variability_applies_per_space_type
    typed = { 'clg_sp_f' => 75.0, 'clg_delta_f' => 999.0, 'htg_sp_f' => 68.0, 'htg_delta_f' => 999.0 }
    names = ['office', 'datacenter/high ite']
    overrides = @measure.thermostat_variability_overrides(@runner, typed, names)
    office = overrides.find { |o| o['space_type'] == 'office' }
    refute_nil(office, "office should receive the sampled setpoints: #{overrides}")
    assert_in_delta(OpenStudio.convert(75.0, 'F', 'C').get, office['thermostat']['cooling_setpoint_c'], 1.0e-6)
    refute(overrides.any? { |o| o['space_type'] == 'datacenter/high ite' }, 'datacenters are excluded')
  end

  def test_thermostat_variability_keeps_a_deadband
    typed = { 'clg_sp_f' => 70.0, 'clg_delta_f' => 999.0, 'htg_sp_f' => 69.5, 'htg_delta_f' => 999.0 }
    overrides = @measure.thermostat_variability_overrides(@runner, typed, ['office'])
    office = overrides.find { |o| o['space_type'] == 'office' }
    assert_in_delta(OpenStudio.convert(68.0, 'F', 'C').get, office['thermostat']['heating_setpoint_c'], 1.0e-6,
                    'heating should be pushed 2F under the sampled cooling setpoint')
    assert(warnings.any? { |w| w.include?('deadband') })
  end

  def test_one_sided_heating_sample_holds_the_deadband_against_stock_cooling
    # office stock cooling is ~75F; a sampled 74F heating setpoint alone would sit inside
    # the deadband. Heating yields, per the both-sampled rule.
    typed = { 'clg_sp_f' => 999.0, 'clg_delta_f' => 999.0, 'htg_sp_f' => 74.0, 'htg_delta_f' => 999.0 }
    overrides = @measure.thermostat_variability_overrides(@runner, typed, ['office'])
    office = overrides.find { |o| o['space_type'] == 'office' }
    refute_nil(office)
    stock = OpenstudioStandards::ThermalZone.space_type_thermostat_setpoints('office')
    deadband_k = OpenStudio.convert(2.0, 'R', 'K').get
    assert_in_delta(stock[:cooling_setpoint_c].to_f - deadband_k, office['thermostat']['heating_setpoint_c'], 1.0e-6,
                    'the sampled heating setpoint should be clamped under the stock cooling setpoint')
    refute(office['thermostat'].key?('cooling_setpoint_c'), 'the unsampled cooling setpoint stays untouched')
    assert(warnings.any? { |w| w.include?('office') && w.include?('deadband') })
  end

  def test_one_sided_cooling_sample_pushes_stock_heating_down
    # a sampled cooling setpoint below the stock heating setpoint writes the heating
    # setpoint the sample did not carry, to keep the deadband
    stock = OpenstudioStandards::ThermalZone.space_type_thermostat_setpoints('office')
    stock_htg_f = OpenStudio.convert(stock[:heating_setpoint_c].to_f, 'C', 'F').get
    typed = { 'clg_sp_f' => stock_htg_f + 1.0, 'clg_delta_f' => 999.0, 'htg_sp_f' => 999.0, 'htg_delta_f' => 999.0 }
    overrides = @measure.thermostat_variability_overrides(@runner, typed, ['office'])
    office = overrides.find { |o| o['space_type'] == 'office' }
    refute_nil(office)
    deadband_k = OpenStudio.convert(2.0, 'R', 'K').get
    assert_in_delta(office['thermostat']['cooling_setpoint_c'] - deadband_k, office['thermostat']['heating_setpoint_c'], 1.0e-6)
    assert(warnings.any? { |w| w.include?('deadband') })
  end

  def test_one_sided_sample_clear_of_the_stock_setpoint_is_untouched
    typed = { 'clg_sp_f' => 999.0, 'clg_delta_f' => 999.0, 'htg_sp_f' => 66.0, 'htg_delta_f' => 999.0 }
    overrides = @measure.thermostat_variability_overrides(@runner, typed, ['office'])
    office = overrides.find { |o| o['space_type'] == 'office' }
    assert_in_delta(OpenStudio.convert(66.0, 'F', 'C').get, office['thermostat']['heating_setpoint_c'], 1.0e-6)
    refute(office['thermostat'].key?('cooling_setpoint_c'))
  end

  # --- sampled base-to-peak ratios ----------------------------------------------------

  def test_base_peak_ratios_ride_on_one_wildcard_entry
    typed = { 'ltg_wkdy_bpr' => 0.3, 'ltg_wknd_bpr' => 999.0,
              'plugload_wkdy_bpr' => 0.5, 'plugload_wknd_bpr' => 0.4 }
    overrides = @measure.base_peak_ratio_overrides(@runner, typed)
    assert_equal(1, overrides.size, 'both load sections ride on a single wildcard entry')
    entry = overrides.first
    assert_equal('*', entry['space_type'])
    assert_equal(0.3, entry['lighting']['base_peak_ratio'])
    refute(entry['lighting'].key?('wknd_base_peak_ratio'), 'the unsampled weekend ratio stays absent')
    assert_equal(0.4, entry['electric_equipment']['wknd_base_peak_ratio'])
    assert(entry['lighting']['cap_wknd_base_at_wkdy'])
  end

  def test_base_peak_ratio_out_of_range_is_an_error
    assert_nil(@measure.base_peak_ratio_overrides(@runner, { 'ltg_wkdy_bpr' => 1.4 }))
    assert(errors.any? { |e| e.include?('ltg_wkdy_bpr') })
    assert_empty(@measure.base_peak_ratio_overrides(@runner, {}))
  end
end
