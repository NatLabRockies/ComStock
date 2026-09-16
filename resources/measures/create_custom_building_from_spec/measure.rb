# Routes ComStock's baseline model generation through
# OpenstudioStandards::CreateTypical.create_custom_building_from_spec instead of the
# create_bar_from_building_type_ratios -> create_typical_building_from_model pair.
#
# create_custom_building_from_spec subsumes both: it builds bar geometry from space type
# ratios, sets the building location from the climate zone, then runs
# create_typical_building_from_model. This measure therefore replaces both measures in
# the workflow rather than sitting alongside them.
#
# The point of this measure in the validation legs is to be a FAITHFUL TRANSLATION of the
# existing path, not a modelling change. ComStock's buildstock supplies building type
# ratios; the spec wants space type ratios, so the building types are expanded using
# ComStock's own building type definitions. Everything else is passed through unchanged, so
# any difference leg D shows against leg C is attributable to the API switch itself.
#
# ComStock owns the building type definition
# ------------------------------------------
# Space type ratios and building form defaults come from
# resources/create_custom/comstock_building_types.json, NOT from openstudio-standards at
# runtime. That is deliberate: adding or refining a ComStock building type should be a
# ComStock data edit, not a standards change. The only standards call left
# in this measure is create_custom_building_from_spec itself.
#
# Interim scaffolding
# -------------------
# Arguments are currently borrowed at runtime from the two measures being replaced, so the
# options_lookup rows that fed them can be retargeted here without rewriting argument
# values (see make_leg_d_options_lookup.py). That is a migration aid, not the end state:
# this measure is intended to REPLACE those measures outright, at which point it should
# declare its own arguments, drop the ones ComStock never consumed, and the replaced
# measures should be deleted rather than kept alive as argument definitions.

require 'openstudio-standards'
require 'json'

class CreateCustomBuildingFromSpec < OpenStudio::Measure::ModelMeasure
  # Measures whose arguments this one accepts, by directory and class name. Reusing their
  # argument objects keeps the argument definitions in exactly one place; if either measure
  # gains an argument, this measure accepts it automatically and the options_lookup rows
  # keep working.
  #
  # They are loaded lazily rather than with a load-time require_relative. Each of those
  # files calls registerWithApplication at file scope, and running that while buildstock's
  # meta_measure loader is itself inside a require breaks the measure load with an
  # Errno::EPIPE on stdout.
  SOURCE_MEASURES = [
    ['create_bar_from_building_type_ratios', 'CreateBarFromBuildingTypeRatios'],
    ['ChangeBuildingLocation', 'ChangeBuildingLocation'],
    ['create_typical_building_from_model', 'CreateTypicalBuildingFromModel'],
    ['add_thermostat_setpoint_variability', 'AddThermostatSetpointVariability']
  ].freeze

  # add_thermostat_setpoint_variability rewrote thermostat schedules after the fact, walking
  # every profile and substituting values. The spec sets the setpoints before the schedules
  # are built, so the sampled variability arrives as thermostat_overrides instead and the
  # schedules are correct the first time.
  #
  # Its no-op sentinel: an argument left at 999 F means "no change to this field".
  THERMOSTAT_NO_CHANGE = 999.0

  # Limits add_thermostat_setpoint_variability used to decide a schedule was not really
  # conditioned and should be left alone. A zone cooled to above 100 F is not cooled, and one
  # heated to below 32 F is not heated -- warehouse bulk storage sits at 122 F cooling, and
  # applying a sampled 75 F cooling setpoint to it would air-condition the warehouse.
  THERMOSTAT_COOLED_MAX_F = 100.0
  THERMOSTAT_HEATED_MIN_F = 32.0

  # Space types add_thermostat_setpoint_variability skipped. It matched on zone names
  # containing 'datacenter'; the equivalent here is the space types those zones are made of.
  THERMOSTAT_VARIABILITY_EXCLUDED = ['datacenter/high ite', 'datacenter/low ite'].freeze

  # Sampled base-to-peak ratios, replacing set_interior_lighting_bpr and
  # set_electric_equipment_bpr. Those measures rewrote finished schedules, rescaling every
  # profile toward its peak; the spec states the ratio before the schedules are built and
  # the parametric expansion produces the same values directly.
  #
  # Declared here rather than inherited from the two measures, which is what the other
  # replaced measures do, because both of them name their arguments modify_wkdy_bpr,
  # wkdy_bpr, modify_wknd_bpr and wknd_bpr. buildstockbatch accumulates arguments by name
  # across every row naming a measure, so inheriting would leave lighting and plug loads
  # fighting over one pair of values with the later row silently winning. Each load gets
  # its own argument names, and the options_lookup rows were rewritten to match.
  #
  # Entries are [argument name, load section, weekend]. A value of 999 means the ratio was
  # not sampled, matching the sentinel the thermostat arguments use.
  BPR_ARGUMENTS = [
    ['ltg_wkdy_bpr', 'lighting', false],
    ['ltg_wknd_bpr', 'lighting', true],
    ['plugload_wkdy_bpr', 'electric_equipment', false],
    ['plugload_wknd_bpr', 'electric_equipment', true]
  ].freeze
  BPR_NO_CHANGE = 999.0

  # Undisturbed ground temperature by climate zone, in degrees C. Lifted from
  # ChangeBuildingLocation so that measure can be retired; ComStock owns the table.
  # Used for ground source heat pump modelling.
  UNDISTURBED_GROUND_TEMPERATURES = {
    'ASHRAE 169-2013-1A' => 25.9, 'ASHRAE 169-2013-2A' => 20.9, 'ASHRAE 169-2013-2B' => 25.0,
    'ASHRAE 169-2013-3A' => 17.9, 'ASHRAE 169-2013-3B' => 19.7, 'ASHRAE 169-2013-3C' => 17.0,
    'ASHRAE 169-2013-4A' => 14.7, 'ASHRAE 169-2013-4B' => 16.3, 'ASHRAE 169-2013-4C' => 13.3,
    'ASHRAE 169-2013-5A' => 11.5, 'ASHRAE 169-2013-5B' => 12.9, 'ASHRAE 169-2013-6A' => 9.0,
    'ASHRAE 169-2013-6B' => 9.3, 'ASHRAE 169-2013-7A' => 7.0, 'ASHRAE 169-2013-7B' => 6.5,
    'ASHRAE 169-2013-7' => 5.4, 'ASHRAE 169-2013-8A' => 2.3, 'ASHRAE 169-2013-8' => 2.3,
    'T24-CEC1' => 16.3, 'T24-CEC2' => 17.0, 'T24-CEC3' => 17.0, 'T24-CEC4' => 17.0,
    'T24-CEC5' => 17.0, 'T24-CEC6' => 17.0, 'T24-CEC7' => 19.7, 'T24-CEC8' => 19.7,
    'T24-CEC9' => 19.7, 'T24-CEC10' => 19.7, 'T24-CEC11' => 19.7, 'T24-CEC12' => 19.7,
    'T24-CEC13' => 19.7, 'T24-CEC14' => 19.7, 'T24-CEC15' => 25.0, 'T24-CEC16' => 12.9
  }.freeze

  # Design days ComStock takes from the .ddy file, copied verbatim from
  # ChangeBuildingLocation so that measure can be retired. Six entries, not the standards
  # default of two: ComStock adds the annual humidity day for cooling towers and evaporative
  # coolers, and three monthly cooling days so solar-gain-driven cooling is sized correctly.
  DDY_LIST = [
    'Htg 99.6. Condns DB',            # annual heating 99.6%
    'Clg .4. Condns WB=>MDB',         # annual humidity, for cooling towers and evap coolers
    'Clg .4. Condns DB=>MWB',         # annual cooling
    'August .4. Condns DB=>MCWB',     # monthly cooling, for solar-gain-driven cooling
    'September .4. Condns DB=>MCWB',
    'October .4. Condns DB=>MCWB'
  ].freeze

  # Resolve the ComStock weather file for this datapoint, mirroring the lookup
  # ChangeBuildingLocation performed: substitute the sampled year into the file name, then
  # check the ComStock workflow weather directory before the OSW search paths.
  #
  # @return [String, nil] absolute path to the .epw, or nil when not found
  def weather_file_path(runner, weather_file_name, year)
    return nil if weather_file_name.to_s.empty?

    name = weather_file_name.gsub('YEAR', year.to_s)
    comstock_path = File.absolute_path(File.join(Dir.pwd, '../../../weather', name))
    return comstock_path if File.file?(comstock_path)

    osw_path = runner.workflow.findFile(name)
    return osw_path.get.to_s if osw_path.is_initialized

    runner.registerError("Did not find #{name} in the OSW search paths or in the ComStock workflow weather directory #{comstock_path}.")
    nil
  end

  # ComStock-owned building type definitions: space type ratios and building form defaults.
  # Deliberately read from ComStock rather than from openstudio-standards, so adding or
  # refining a building type is a ComStock data edit and does not require a standards
  # change. 
  BUILDING_TYPE_DATA_PATH = File.expand_path('../../create_custom/comstock_building_types.json', __dir__)

  # @return [Hash] the ComStock building type definitions, loaded once per measure instance
  def building_type_data
    @building_type_data ||= begin
      unless File.exist?(BUILDING_TYPE_DATA_PATH)
        raise "ComStock building type data not found at #{BUILDING_TYPE_DATA_PATH}."
      end
      JSON.parse(File.read(BUILDING_TYPE_DATA_PATH))
    end
  end

  # The construction spec for one building type under one template.
  #
  # The envelope is overwhelmingly a property of the template rather than of the building
  # type: every ComStock building type under one template shares its window, door, skylight
  # and interior constructions and differs only in the wall and roof type and in whether it
  # is residential. So construction_defaults carries what they share and a building type
  # carries only its differences, and the two are merged here.
  #
  # The merged spec names every surface, which means it does not depend on the standards
  # construction_sets table having a row for this building type under this template. That
  # table is keyed on the building types of the template family and holds no ASHRAE name
  # under a DEER template, which is what makes primary_building_type substitution
  # load-bearing today.
  #
  # @param building_type [String] e.g. 'SmallOffice'
  # @param template [String] e.g. 'ComStock 90.1-2013'
  # @return [Hash, nil] a construction spec, or nil where neither layer covers this template
  def constructions_for(building_type, template)
    applicable = lambda do |rows|
      Array(rows).find { |row| Array(row['applicable_templates']).include?(template) }
    end

    default = applicable.call(building_type_data['construction_defaults'])
    entry = applicable.call((building_type_data['building_types'][building_type] || {})['constructions'])
    return nil if default.nil? && entry.nil?

    spec = (default.nil? ? {} : default['spec']).merge(entry.nil? ? {} : entry['spec'])
    default_surfaces = default.nil? ? nil : default['spec']['surfaces']
    return spec unless default_surfaces.is_a?(Hash)

    entry_surfaces = (entry.nil? ? nil : entry['spec']['surfaces']) || {}
    spec = spec.merge('surfaces' => default_surfaces.merge(entry_surfaces))
    spec
  end

  # Building type definition for one building type, subtype and template, from ComStock data.
  #
  # Space type names are typical (all-level) names such as 'office' or
  # 'corridor - secondary school', so nothing needs translating at runtime. DEER templates
  # share the ASHRAE definitions, which is why there is no DEER branch here.
  #
  # @param building_type [String] e.g. 'SmallOffice'
  # @param building_subtype [String] e.g. 'warehouse_bulk20', or 'NA'
  # @param template [String] e.g. 'ComStock 90.1-2013'
  # @return [Hash, nil] {form_defaults:, space_types:}, or nil when undefined
  def definition_for(building_type, building_subtype, template)
    entry = building_type_data['building_types'][building_type]
    return nil if entry.nil?

    # space_type_ratios is a list of entries, each covering one subtype and a set of
    # templates. A subtype is emitted only where it differs from the default, so an exact
    # subtype match is preferred and 'NA' is the fallback meaning "any subtype".
    candidates = (entry['space_type_ratios'] || []).select do |row|
      Array(row['applicable_templates']).include?(template)
    end
    row = candidates.find { |r| r['building_subtype'].to_s == building_subtype.to_s } ||
          candidates.find { |r| r['building_subtype'].to_s == 'NA' }
    return nil if row.nil?

    {
      'form_defaults' => entry['form_defaults'],
      'deer_building_type' => entry['deer_building_type'],
      'thermostat_overrides' => entry['thermostat_overrides'],
      'service_water_heating_overrides' => entry['service_water_heating_overrides'],
      'exhaust_overrides' => entry['exhaust_overrides'],
      'ventilation_overrides' => entry['ventilation_overrides'],
      'occupancy_overrides' => entry['occupancy_overrides'],
      'constructions' => constructions_for(building_type, template),
      'space_types' => row['space_types']
    }
  end

  # @return [Array<OpenStudio::Measure::ModelMeasure>] instances of the replaced measures
  # The source measure whose arguments become typical_options keywords.
  #
  # Looked up by name. This used to be source_measures.last, which was correct only for as
  # long as create_typical stayed at the end of SOURCE_MEASURES. Appending
  # add_thermostat_setpoint_variability moved it, and the thermostat measure's four
  # arguments were forwarded into typical_options instead -- where spec validation rejects
  # anything that is not a keyword of create_typical_building_from_model, failing every
  # building in the run.
  #
  # @return [OpenStudio::Measure::ModelMeasure] the create_typical measure instance
  def typical_source_measure
    index = SOURCE_MEASURES.index { |dir, _| dir == 'create_typical_building_from_model' }
    raise 'create_typical_building_from_model is missing from SOURCE_MEASURES' if index.nil?

    source_measures[index]
  end

  # The keyword arguments forwarded to create_typical_building_from_model.
  #
  # Only arguments create_typical itself declares are forwarded. Spec validation rejects a
  # typical_options key that is not one of its keywords, and it rejects the whole spec, so
  # a single stray argument fails every building in a run. Anything this measure consumes
  # itself -- the sampled thermostat setpoints and base-to-peak ratios -- must not reach
  # here.
  #
  # Split out of run so it can be exercised without a workflow: the failure this guards
  # against is invisible to any test that builds a spec by hand.
  #
  # @param model [OpenStudio::Model::Model] OpenStudio model object
  # @param typed [Hash] typed measure arguments
  # @return [Hash] keyword arguments for create_typical_building_from_model
  def typical_options_from(model, typed)
    options = {}
    typical_source_measure.arguments(model).each do |argument|
      key = argument.name
      next if SPEC_MANAGED.include?(key)
      next if BAR_ONLY_ARGS.include?(key)
      next unless typed.key?(key)

      options[TYPICAL_ARG_RENAMES.fetch(key, key)] = typed[key]
    end

    # restate what the replaced measure hard-coded at its call site
    CALL_SITE_DEFAULTS.each { |key, value| options[key] = value }

    # ComStock builds its schedules parametrically. Stated here rather than left to the
    # method default, which follows the load method and is 'prototype' for standards-path
    # callers -- this spec is where ComStock's choice of schedule engine is recorded.
    options['schedule_method'] = 'parametric'

    # drives create_typical_interior_lighting on the typical load path
    options['lighting_generation'] = typed['lighting_generation'] if typed.key?('lighting_generation')
    options
  end

  def source_measures
    @source_measures ||= SOURCE_MEASURES.map do |dir, class_name|
      unless Object.const_defined?(class_name)
        require File.expand_path("../#{dir}/measure.rb", __dir__)
      end
      Object.const_get(class_name).new
    end
  end

  # Arguments consumed to build the spec's top level or its space_type_ratios. Everything
  # else that came from create_typical is forwarded as a typical_options keyword.
  BAR_ONLY_ARGS = %w[
    bldg_type_a bldg_type_b bldg_type_c bldg_type_d
    bldg_subtype_a bldg_subtype_b bldg_subtype_c bldg_subtype_d
    bldg_type_b_fract_bldg_area bldg_type_c_fract_bldg_area bldg_type_d_fract_bldg_area
    bldg_type_a_num_units bldg_type_b_num_units bldg_type_c_num_units bldg_type_d_num_units
    space_type_sort_logic use_upstream_args
  ].freeze

  # Keys spec[:form] accepts, taken from the "form" definition in
  # create_typical/data/custom_building_spec_schema.json. The schema rejects unknown keys,
  # and create_bar_from_building_type_ratios declares several arguments the spec has no
  # slot for -- the neighbor_* shading arguments and story_multiplier among them -- so
  # those are dropped rather than forwarded. See the note in run about what that means.
  FORM_ARGS = %w[
    bar_division_method bar_sep_dist_mult bar_width bottom_story_ground_exposed_floor
    building_form_defaults building_rotation custom_height_bar double_loaded_corridor
    floor_height make_mid_story_surfaces_adiabatic ns_to_ew_ratio num_stories_above_grade
    num_stories_below_grade party_wall_fraction party_wall_stories_east
    party_wall_stories_north party_wall_stories_south party_wall_stories_west perim_mult
    single_floor_area space_type_sort_logic story_multiplier_method
    top_story_exterior_exposed_roof total_bldg_floor_area wwr
  ].freeze

  # create_bar arguments with no spec[:form] equivalent. Recorded so the measure can report
  # what it dropped instead of silently discarding geometry inputs.
  UNMAPPED_BAR_ARGS = %w[
    story_multiplier building_height_relative_to_neighbors neighbor_height_method
    neighbor_height_north neighbor_height_south neighbor_height_east neighbor_height_west
    neighbor_offset_north neighbor_offset_south neighbor_offset_east neighbor_offset_west
  ].freeze

  # create_typical_building_from_model keyword arguments that the spec manages itself and
  # that typical_options is not allowed to carry.
  SPEC_MANAGED = %w[template climate_zone].freeze

  # Keywords create_typical_building_from_model accepts that the replaced measure sets at
  # its call site rather than exposing as measure arguments. They are invisible from the
  # argument list this measure inherits, so they have to be restated or the method's own
  # defaults silently apply. add_daylighting_controls is the one that bites: the method
  # defaults it to true, the measure passes nil, and letting the default through added
  # daylighting controls to buildings that had none, cutting interior lighting by up to 37%.
  CALL_SITE_DEFAULTS = {
    'add_daylighting_controls' => nil,
    'hoo_var_method' => nil,
    'user_hvac_mapping' => nil,
    'sizing_run_directory' => nil
  }.freeze

  # create_typical_building_from_model takes several keywords under different names than
  # the measure argument that feeds them. Copied from the call site in
  # create_typical_building_from_model/measure.rb so the translation stays faithful.
  TYPICAL_ARG_RENAMES = {
    'system_type' => 'hvac_system_type',
    'htg_src' => 'heating_fuel',
    'clg_src' => 'cooling_fuel',
    'swh_src' => 'service_water_heating_fuel',
    'unmet_hours_tolerance' => 'unmet_hours_tolerance_r'
  }.freeze

  def name
    'Create Custom Building From Spec'
  end

  def description
    'Builds the baseline model through OpenstudioStandards::CreateTypical.create_custom_building_from_spec, replacing create_bar_from_building_type_ratios and create_typical_building_from_model.'
  end

  def modeler_description
    'Assembles a custom building specification from the same buildstock-driven arguments the replaced measures received, expanding building type ratios into space type ratios, then calls create_custom_building_from_spec.'
  end

  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new
    seen = {}
    # Not exposed by any of the replaced measures: ComStock sampled lighting_generation
    # into set_interior_lighting_technology, whose work
    # OpenstudioStandards::InteriorLighting.create_typical_interior_lighting now does on
    # the typical load path. Without declaring it here the sampled value has nowhere to
    # land and every building falls back to the method default of gen4_led.
    lighting_generation = OpenStudio::Measure::OSArgument.makeStringArgument('lighting_generation', false)
    lighting_generation.setDisplayName('Lighting Generation')
    lighting_generation.setDescription('Lighting technology generation used to compute typical interior lighting power, e.g. gen4_led.')
    args << lighting_generation
    seen['lighting_generation'] = true

    # Sampled base-to-peak ratios. Named per load because the two measures they replace
    # share argument names and would otherwise collide, see BPR_ARGUMENTS.
    BPR_ARGUMENTS.each do |name, section, weekend|
      argument = OpenStudio::Measure::OSArgument.makeDoubleArgument(name, false)
      argument.setDefaultValue(BPR_NO_CHANGE)
      argument.setDisplayName("#{weekend ? 'Weekend' : 'Weekday'} #{section.tr('_', ' ')} base-to-peak ratio")
      argument.setDescription("Schedule fraction outside operating hours as a fraction of the peak. Enter #{BPR_NO_CHANGE.to_i} for no change.")
      args << argument
      seen[name] = true
    end

    source_measures.each do |measure|
      measure.arguments(model).each do |argument|
        next if seen[argument.name]

        seen[argument.name] = true
        args << argument
      end
    end
    args
  end

  # Thermostat overrides carrying the sampled setpoint variability, one entry per space
  # type in the building.
  #
  # This replaces add_thermostat_setpoint_variability. That measure rewrote finished
  # schedules; these overrides set the setpoints the schedules are built from, which is
  # both simpler and free of the profile-shape guesswork it needed -- it had to infer from
  # a profile's min and max which values were the occupied setpoint and which the setback.
  #
  # Per space type rather than a '*' wildcard, because applicability is per space type. The
  # replaced measure skipped a schedule it judged unconditioned, and a wildcard would lose
  # that: a sampled 75 F cooling setpoint applied to warehouse bulk storage, which sits at
  # 122 F, would air-condition a warehouse that has never been cooled. Setbacks are also
  # skipped where the space type holds a constant setpoint, matching the measure's warning
  # that a flat schedule has no setback to adjust.
  #
  # @param runner [OpenStudio::Measure::OSRunner] the measure runner
  # @param args [Hash] typed measure arguments
  # @param space_type_names [Array<String>] all_level space type names in the building
  # @return [Array<Hash>] thermostat_overrides entries, empty when nothing was sampled
  def thermostat_variability_overrides(runner, args, space_type_names)
    clg_sp_f = args['clg_sp_f'].to_f
    clg_delta_f = args['clg_delta_f'].to_f
    htg_sp_f = args['htg_sp_f'].to_f
    htg_delta_f = args['htg_delta_f'].to_f

    set_clg_sp = clg_sp_f != THERMOSTAT_NO_CHANGE
    set_clg_delta = clg_delta_f != THERMOSTAT_NO_CHANGE
    set_htg_sp = htg_sp_f != THERMOSTAT_NO_CHANGE
    set_htg_delta = htg_delta_f != THERMOSTAT_NO_CHANGE
    return [] unless set_clg_sp || set_clg_delta || set_htg_sp || set_htg_delta

    if set_clg_sp && clg_sp_f < THERMOSTAT_HEATED_MIN_F
      runner.registerError("Sampled cooling setpoint of #{clg_sp_f}F is below the minimum heating setpoint of #{THERMOSTAT_HEATED_MIN_F}F.")
      return nil
    end
    if set_htg_sp && htg_sp_f > THERMOSTAT_COOLED_MAX_F
      runner.registerError("Sampled heating setpoint of #{htg_sp_f}F is above the maximum cooling setpoint of #{THERMOSTAT_COOLED_MAX_F}F.")
      return nil
    end

    # keep a deadband between the two, as the replaced measure did
    if set_clg_sp && set_htg_sp && (htg_sp_f > (clg_sp_f - 2.0))
      runner.registerWarning("Sampled heating setpoint of #{htg_sp_f}F is within 2F of the sampled cooling setpoint of #{clg_sp_f}F. " \
                             "Using #{(clg_sp_f - 2.0).round(1)}F for heating to leave a deadband.")
      htg_sp_f = clg_sp_f - 2.0
    end

    # setpoints are absolute temperatures, deltas are temperature differences
    cooled_max_c = OpenStudio.convert(THERMOSTAT_COOLED_MAX_F, 'F', 'C').get
    heated_min_c = OpenStudio.convert(THERMOSTAT_HEATED_MIN_F, 'F', 'C').get

    overrides = []
    skipped = []
    space_type_names.uniq.sort.each do |space_type_name|
      if THERMOSTAT_VARIABILITY_EXCLUDED.include?(space_type_name)
        skipped << "#{space_type_name} (excluded)"
        next
      end

      stock = OpenstudioStandards::ThermalZone.space_type_thermostat_setpoints(space_type_name)
      if stock.nil?
        skipped << "#{space_type_name} (no setpoint data)"
        next
      end

      cooled = stock[:cooling_setpoint_c].to_f <= cooled_max_c
      heated = stock[:heating_setpoint_c].to_f >= heated_min_c
      thermostat = {}
      thermostat['cooling_setpoint_c'] = OpenStudio.convert(clg_sp_f, 'F', 'C').get if set_clg_sp && cooled
      thermostat['heating_setpoint_c'] = OpenStudio.convert(htg_sp_f, 'F', 'C').get if set_htg_sp && heated

      # The deadband holds against the stock setpoints too, not just between two sampled
      # values: a sampled heating setpoint alone can land within 2F of -- or above -- a
      # space type's stock cooling setpoint. Heating yields, matching the both-sampled
      # rule above; with only cooling sampled that means writing a heating setpoint the
      # sample did not carry, which is why it is logged per space type.
      deadband_k = OpenStudio.convert(2.0, 'R', 'K').get
      one_setpoint_sampled = (set_clg_sp || set_htg_sp) && !(set_clg_sp && set_htg_sp)
      if cooled && heated && one_setpoint_sampled
        cooling_c = thermostat['cooling_setpoint_c'] || stock[:cooling_setpoint_c].to_f
        heating_c = thermostat['heating_setpoint_c'] || stock[:heating_setpoint_c].to_f
        if heating_c > cooling_c - deadband_k
          thermostat['heating_setpoint_c'] = cooling_c - deadband_k
          runner.registerWarning("#{space_type_name}: heating setpoint of #{OpenStudio.convert(heating_c, 'C', 'F').get.round(1)}F " \
                                 "is within 2F of the cooling setpoint of #{OpenStudio.convert(cooling_c, 'C', 'F').get.round(1)}F. " \
                                 "Using #{OpenStudio.convert(thermostat['heating_setpoint_c'], 'C', 'F').get.round(1)}F for heating to leave a deadband.")
        end
      end
      # a space type that holds one temperature around the clock has no setback to move
      if set_clg_delta && cooled && stock[:cooling_setback_delta_c].to_f.positive?
        thermostat['cooling_setback_delta_c'] = OpenStudio.convert(clg_delta_f, 'R', 'K').get
      end
      if set_htg_delta && heated && stock[:heating_setback_delta_c].to_f.positive?
        thermostat['heating_setback_delta_c'] = OpenStudio.convert(htg_delta_f, 'R', 'K').get
      end

      if thermostat.empty?
        skipped << "#{space_type_name} (#{cooled ? '' : 'not cooled, '}#{heated ? '' : 'not heated, '}nothing to set)"
        next
      end

      overrides << { 'space_type' => space_type_name, 'thermostat' => thermostat }
    end

    sampled = { 'clg_sp_f' => set_clg_sp ? clg_sp_f : nil, 'clg_delta_f' => set_clg_delta ? clg_delta_f : nil,
                'htg_sp_f' => set_htg_sp ? htg_sp_f : nil, 'htg_delta_f' => set_htg_delta ? htg_delta_f : nil }
    runner.registerInfo("Thermostat setpoint variability #{sampled.compact.map { |k, v| "#{k}=#{v}" }.join(', ')} " \
                        "applied to #{overrides.size} space type(s).")
    runner.registerInfo("Thermostat setpoint variability not applied to: #{skipped.join(', ')}.") unless skipped.empty?
    overrides
  end

  # Schedule overrides carrying the sampled base-to-peak ratios.
  #
  # One entry keyed '*', not one per load: the override resolver takes the first wildcard
  # entry it finds, so two of them would leave the second silently unread. Both load
  # sections ride on the single entry.
  #
  # cap_wknd_base_at_wkdy reproduces a rule the replaced measures enforced -- a weekend
  # base was held at or below the weekday base, whatever the two sampled ratios said. The
  # ratios are drawn independently and the weekend is often the higher of the two, so
  # dropping the rule would raise weekend unoccupied loads across the stock.
  #
  # @param runner [OpenStudio::Measure::OSRunner] the measure runner
  # @param args [Hash] typed measure arguments
  # @return [Array<Hash>] schedule_overrides entries, empty when nothing was sampled
  def base_peak_ratio_overrides(runner, args)
    sections = {}
    sampled = []
    BPR_ARGUMENTS.each do |name, section, weekend|
      value = args[name]
      next if value.nil? || value.to_f == BPR_NO_CHANGE

      ratio = value.to_f
      unless ratio.between?(0.0, 1.0)
        runner.registerError("Sampled #{name} of #{ratio} is not a base-to-peak ratio between 0 and 1.")
        return nil
      end

      sections[section] ||= {}
      sections[section][weekend ? 'wknd_base_peak_ratio' : 'base_peak_ratio'] = ratio
      sampled << "#{name}=#{ratio}"
    end
    return [] if sections.empty?

    sections.each_value { |fields| fields['cap_wknd_base_at_wkdy'] = true }
    runner.registerInfo("Base-to-peak ratios #{sampled.join(', ')} applied to #{sections.keys.join(' and ')}.")
    [{ 'space_type' => '*' }.merge(sections)]
  end

  # Expand the building type mix into space type ratio entries covering the whole
  # building. Uses the same lookup create_bar_from_building_type_ratios uses, so the
  # resulting space type mix matches what the replaced path would have produced.
  #
  # Also captures the definition of every building type in the mix (@mix_definitions) and
  # the primary type's (@primary_definition), reset here rather than memoized so a reused
  # measure instance never applies the previous building's definitions.
  #
  # @return [Array<Hash>, nil] space type ratio entries, or nil if a lookup failed
  def space_type_ratios(runner, args)
    @primary_definition = nil
    @mix_definitions = []
    template = args['template']
    fract_b = args['bldg_type_b_fract_bldg_area'].to_f
    fract_c = args['bldg_type_c_fract_bldg_area'].to_f
    fract_d = args['bldg_type_d_fract_bldg_area'].to_f
    fract_a = 1.0 - fract_b - fract_c - fract_d
    if fract_a <= 0.0
      runner.registerError("Primary building type fraction of floor area must be greater than 0, got #{fract_a.round(4)}.")
      return nil
    end

    mix = [
      [args['bldg_type_a'], args['bldg_subtype_a'], fract_a],
      [args['bldg_type_b'], args['bldg_subtype_b'], fract_b],
      [args['bldg_type_c'], args['bldg_subtype_c'], fract_c],
      [args['bldg_type_d'], args['bldg_subtype_d'], fract_d]
    ]

    entries = []
    mix.each do |building_type, building_subtype, fraction|
      next if building_type.nil? || building_type.to_s.empty?
      next if fraction <= 0.0

      definition = definition_for(building_type, building_subtype, template)
      if definition.nil? || definition['space_types'].empty?
        runner.registerError("No ComStock space type ratios defined for building type '#{building_type}' " \
                             "subtype '#{building_subtype}' template '#{template}'. Add them to " \
                             "resources/create_custom/comstock_building_types.json.")
        return nil
      end

      @primary_definition = definition if @primary_definition.nil? && building_type == args['bldg_type_a']
      @mix_definitions << { 'building_type' => building_type, 'fraction' => fraction, 'definition' => definition }

      definition['space_types'].each do |space_type_name, properties|
        ratio = properties['ratio'].to_f * fraction
        next if ratio <= 0.0

        # No building_type on the entry. That routes create_custom down the typical load
        # path, where the space type name is a typical (all-level) name resolved directly
        # against all_level_space_types.json, and internal loads come from the typical
        # lighting, equipment and ventilation data rather than the standards space type
        # data. It is also what removes the DEER building type mapping: DEER templates
        # accept the ComStock building type as primary_building_type, so there is no
        # DOE-to-DEER translation left to get wrong.
        entry = { 'space_type' => space_type_name, 'ratio' => ratio }
        # Carry the per-entry geometry flags through. space_type_gen matters most: the bar
        # generator skips space type creation for entries flagged false (basements,
        # undeveloped area) while still counting their floor area, so dropping the flag
        # would give those areas real space types and shift the area-weighted load
        # densities. story_height, wwr, default and circ are passed for the same reason.
        %w[story_height wwr default circ space_type_gen].each do |flag|
          entry[flag] = properties[flag] if properties.key?(flag)
        end
        entries << entry
      end
    end

    return nil if entries.empty?

    # create_custom validates that the ratios sum to 1.0. The per building type ratios
    # come from the standards data and need not sum exactly to 1 on their own, so
    # renormalize over the whole mix rather than letting rounding fail validation.
    total = entries.sum { |entry| entry['ratio'] }
    if total <= 0.0
      runner.registerError('Space type ratios summed to zero.')
      return nil
    end
    entries.each { |entry| entry['ratio'] = entry['ratio'] / total }
    entries
  end

  # Override entries of one family from every building type in the mix, not just the
  # primary. A mixed building's Hospital wing needs Hospital's imaging exhaust zero-out
  # whether or not Hospital is the primary type. Entries are keyed by space type; the
  # primary type resolves a collision, then descending floor fraction, and the losing
  # entry is logged. A building type appearing twice in the mix (two subtypes) carries the
  # same overrides both times, so its own duplicates are skipped silently.
  #
  # @param runner [OpenStudio::Measure::OSRunner] the measure runner
  # @param family [String] the override family key, e.g. 'exhaust_overrides'
  # @return [Array<Hash>] merged entries, empty when no definition carries any
  def merged_overrides(runner, family)
    ordered = Array(@mix_definitions).sort_by.with_index do |mix, index|
      [mix['definition'].equal?(@primary_definition) ? 0 : 1, -mix['fraction'], index]
    end

    merged = []
    claimed = {}
    ordered.each do |mix|
      Array(mix['definition'][family]).each do |entry|
        key = entry['space_type'].to_s
        if claimed.key?(key)
          if claimed[key] != mix['building_type']
            runner.registerWarning("#{family} entry '#{key}' from #{mix['building_type']} is superseded by " \
                                   "#{claimed[key]}'s entry for the same space type.")
          end
          next
        end
        claimed[key] = mix['building_type']
        merged << entry.dup
      end
    end
    merged
  end

  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)
    return false unless runner.validateUserArguments(arguments(model), user_arguments)

    # Collect the supplied arguments by name, typed the way each was declared. Arguments
    # left unset keep the spec key absent so create_custom applies its own default rather
    # than receiving a nil.
    # same accessor the replaced measures use, so values arrive already typed
    typed = runner.getArgumentValues(arguments(model), user_arguments)
    typed = typed.collect { |key, value| [key.to_s, value] }.to_h
    typed.reject! { |_key, value| value.nil? }

    reset_log if respond_to?(:reset_log)

    ratios = space_type_ratios(runner, typed)
    return false if ratios.nil?

    form = {}
    FORM_ARGS.each { |key| form[key] = typed[key] if typed.key?(key) }

    # Supply the building-level form defaults from ComStock data rather than letting the
    # geometry generator fall back to its own lookup for the primary building type. Same
    # reason as the space type ratios: ComStock owns the building type definition.
    #
    # The primary building type is the ComStock name under every template, DEER included.
    # It used to be swapped for deer_building_type under a DEER template, because the
    # standards construction_sets table is keyed on the building types of the template family
    # and holds no ASHRAE name under DEER, so create_typical returned false before it built
    # anything. The spec now names its own constructions, so that no longer applies and the
    # substitution is gone.
    #
    # Two things read the building type rather than the space type and therefore change for
    # DEER models: refrigeration case and walk-in sizing, and the ComStock interior equipment 
    # power densities. The equipment data carries only one or two rows per DEER building type
    # against eight to sixteen per ASHRAE type, so most DEER space types have been taking a
    # median across building types rather than their own value; they now take the ASHRAE row.
    #
    # deer_building_type stays in the data file. Nothing reads it here today, but it is the
    # crosswalk itself and is needed to reproduce or revisit this decision.
    primary_type = typed['bldg_type_a']
    defaults = @primary_definition['form_defaults']
    if defaults.nil?
      runner.registerError("No ComStock form defaults defined for building type '#{primary_type}'. " \
                           'Add them to resources/create_custom/comstock_building_types.json.')
      return false
    end
    # only the keys spec[:form][:building_form_defaults] accepts
    form['building_form_defaults'] = defaults.slice('aspect_ratio', 'wwr', 'typical_story', 'first_story', 'perim_mult')

    # The spec has no slot for the neighbor shading arguments or story_multiplier, so those
    # buildstock inputs do not reach the model on this leg. Report them rather than letting
    # them disappear quietly -- a leg D difference in shading or story count traces here,
    # not to create_custom.
    dropped = UNMAPPED_BAR_ARGS.select { |key| typed.key?(key) }
    unless dropped.empty?
      runner.registerWarning("These create_bar arguments have no spec[:form] equivalent and were not applied: #{dropped.join(', ')}.")
    end

    typical_options = typical_options_from(model, typed)

    # Site section, replacing what ChangeBuildingLocation used to do. Without an explicit
    # weather file path create_custom falls back to the climate zone representative file,
    # which would silently replace ComStock's AMY weather -- and because equipment is sized
    # inside create_custom, sizing would follow the wrong weather too.
    epw_path = weather_file_path(runner, typed['weather_file_name'], typed['year'])
    return false if epw_path.nil? && !typed['weather_file_name'].to_s.empty?

    # 'City' matches what ChangeBuildingLocation hard-coded. Terrain sets the wind speed
    # profile and therefore infiltration; leaving it unset falls back to the EnergyPlus
    # default of Suburbs, which raises heating across every building type.
    site = { 'ddy_list' => DDY_LIST, 'terrain' => 'City' }
    site['weather_file_path'] = epw_path unless epw_path.nil?
    site['grid_region'] = typed['grid_region'] unless typed['grid_region'].to_s.empty?
    site['soil_conductivity'] = typed['soil_conductivity'] unless typed['soil_conductivity'].nil?
    ground_temp = UNDISTURBED_GROUND_TEMPERATURES[typed['climate_zone']]
    if ground_temp.nil?
      runner.registerWarning("No undisturbed ground temperature defined for climate zone '#{typed['climate_zone']}'; leaving the value derived from the .stat file in place.")
    else
      site['undisturbed_ground_temperature'] = ground_temp
    end

    spec = {
      'name' => typed['bldg_type_a'].to_s,
      'site' => site,
      'template' => typed['template'],
      'climate_zone' => typed['climate_zone'],
      # Stated explicitly rather than left to be inferred. create_typical_building_from_model
      # otherwise derives it from whichever space type holds the most floor area, which for a
      # SmallOffice yields 'Office' -- an artifact of the space type naming rather than the
      # type ComStock sampled. Accepted consequence: lookups keyed on the Building object's
      # standards building type now resolve against the ComStock type, which changes the
      # service water heating pump from circulating to water-mains-pressure-driven on some
      # buildings. See the primary-building-type entry in expected_changes.yml.
      'primary_building_type' => primary_type,
      'space_type_ratios' => ratios,
      'form' => form,
      'typical_options' => typical_options
    }

    # Two sources of thermostat overrides. First, setpoints where a building type in the
    # mix means something different by a space type than the openstudio-standards data
    # does. Second, the sampled setpoint variability that add_thermostat_setpoint_variability
    # used to apply after the fact. Both key on the space type, so where they collide the
    # sampled value wins on the fields it sets and the building type's stands on the rest.
    thermostat_overrides = merged_overrides(runner, 'thermostat_overrides')
    unless thermostat_overrides.empty?
      runner.registerInfo("Applying #{thermostat_overrides.size} building type thermostat override(s): " \
                          "#{thermostat_overrides.map { |o| o['space_type'] }.join(', ')}.")
    end

    schedule_overrides = base_peak_ratio_overrides(runner, typed)
    return false if schedule_overrides.nil?

    spec['schedule_overrides'] = schedule_overrides unless schedule_overrides.empty?

    variability = thermostat_variability_overrides(runner, typed, ratios.map { |r| r['space_type'] })
    return false if variability.nil?

    variability.each do |entry|
      existing = thermostat_overrides.find { |o| o['space_type'] == entry['space_type'] }
      if existing.nil?
        thermostat_overrides << entry
      else
        existing['thermostat'] = existing['thermostat'].merge(entry['thermostat'])
      end
    end
    spec['thermostat_overrides'] = thermostat_overrides unless thermostat_overrides.empty?

    # Water use equipment where a building type draws differently from what the space
    # type data says. typical_water_use_equipment keys on the all-level name alone, so
    # 'food preparation' is one rate for every kitchen in the stock; a hospital kitchen is
    # not a restaurant's, and the difference is six-fold.
    swh_overrides = merged_overrides(runner, 'service_water_heating_overrides')
    unless swh_overrides.empty?
      spec['service_water_heating_overrides'] = swh_overrides
      named = swh_overrides.map { |o| o['space_type'] }.join(', ')
      runner.registerInfo("Applying #{swh_overrides.size} service water heating override(s): #{named}.")
    end

    # Zone exhaust where an all-level space type is broader than the exhaust record behind it.
    # 'imaging' carries the outpatient MRI room's rate, which a hospital's radiology rooms did
    # not have on the prototype path.
    exhaust_overrides = merged_overrides(runner, 'exhaust_overrides')
    unless exhaust_overrides.empty?
      spec['exhaust_overrides'] = exhaust_overrides
      named = exhaust_overrides.map { |o| "#{o['space_type']} => #{o.dig('exhaust', 'exhaust_per_area')} cfm/ft2" }.join(', ')
      runner.registerInfo("Applying #{exhaust_overrides.size} zone exhaust override(s): #{named}.")
    end

    # Outdoor air and occupancy where the ventilation space type data is wrong for this building.
    # Both are keyed by the space type's ventilation space type, so one all-level space type
    # standing in for several real ones is corrected here rather than in the shared data.
    ventilation_overrides = merged_overrides(runner, 'ventilation_overrides')
    unless ventilation_overrides.empty?
      spec['ventilation_overrides'] = ventilation_overrides
      named = ventilation_overrides.map { |o| o['space_type'] }.join(', ')
      runner.registerInfo("Applying #{ventilation_overrides.size} ventilation override(s): #{named}.")
    end

    occupancy_overrides = merged_overrides(runner, 'occupancy_overrides')
    unless occupancy_overrides.empty?
      spec['occupancy_overrides'] = occupancy_overrides
      named = occupancy_overrides.map { |o| "#{o['space_type']} => #{o.dig('occupancy', 'people_per_1000_ft2')} ppl/1000 ft2" }.join(', ')
      runner.registerInfo("Applying #{occupancy_overrides.size} occupancy override(s): #{named}.")
    end

    # Envelope constructions, named rather than looked up from the primary building type row.
    # ComStock owns this data the same way it owns space type ratios, and the spec names every
    # surface, so the construction set no longer depends on the standards construction_sets
    # table carrying a row for this building type under this template.
    #
    # Deliberately the primary type's alone, unlike the overrides above: the envelope is a
    # building-level property, and every ComStock building type carries a construction spec,
    # so a mixed building follows its primary type the way the replaced path did. A secondary
    # type that should keep its own envelope is what the spec's constructions sets form is
    # for, once the data carries per-space-type sets.
    constructions = @primary_definition['constructions']
    if constructions.nil? || constructions.empty?
      runner.registerWarning("No construction spec defined for '#{primary_type}' under template '#{typed['template']}'. " \
                             'The construction set will come from the building type row in openstudio-standards. ' \
                             'Regenerate resources/create_custom/comstock_building_types.json.')
    else
      spec['constructions'] = constructions
      runner.registerInfo("Envelope constructions for #{primary_type}: #{constructions['exterior_wall_type']} walls, " \
                          "#{constructions['exterior_roof_type']} roof, #{constructions['building_category']} category, " \
                          "residential=#{constructions['is_residential']}.")
    end

    runner.registerInfo("Custom building spec: #{ratios.size} space type ratio entries across " \
                        "#{ratios.map { |r| r['building_type'] }.uniq.join(', ')}; " \
                        "template #{spec['template']}, climate zone #{spec['climate_zone']}.")
    runner.registerValue('create_custom_spec_space_type_count', ratios.size)

    result = OpenstudioStandards::CreateTypical.create_custom_building_from_spec(model, spec)

    log_messages_to_runner(runner, false) if respond_to?(:log_messages_to_runner)

    unless result
      runner.registerError('create_custom_building_from_spec failed, see previous errors.')
      return false
    end

    true
  end
end

CreateCustomBuildingFromSpec.new.registerWithApplication
