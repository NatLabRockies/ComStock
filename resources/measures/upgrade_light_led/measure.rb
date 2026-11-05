# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2018, Alliance for Sustainable Energy, LLC.
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# (1) Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# (2) Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# (3) Neither the name of the copyright holder nor the names of any contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission from the respective party.
#
# (4) Other than as required in clauses (1) and (2), distributions in any form
# of modifications or other derivative works may not use the "OpenStudio"
# trademark, "OS", "os", or any other confusingly similar designation without
# specific prior written permission from Alliance for Sustainable Energy, LLC.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER(S) AND ANY CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
# THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER(S), ANY CONTRIBUTORS, THE
# UNITED STATES GOVERNMENT, OR THE UNITED STATES DEPARTMENT OF ENERGY, NOR ANY OF
# THEIR EMPLOYEES, BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
# OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# *******************************************************************************

require 'csv'
require 'json'
require 'comstock-typical'

# start the measure
class LightLED < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    return 'light_led'
  end

  # human readable description
  def description
    return 'This measure takes in lighting technology for different kinds of lighting and adds LED lighting to space types depending on the prototype lighting space type illuminance targets.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'This measure takes in lighting technology defined in lumens per watt for different kinds of lighting and adds lighting attached to OS:SpaceType objects depending on the horiztontal illumance target in lumens.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # Lighting generations
    lighting_generations = [
      'gen4_led',
      'gen5_led',
      'gen6_led',
      'gen7_led',
      'gen8_led'
    ]

    # Populate lighting generation options
    lighting_generation_chs = OpenStudio::StringVector.new
    lighting_generations.each do |lighting_generation|
      lighting_generation_chs << lighting_generation
    end

    # Make an argument for lighting generation
    lighting_generation = OpenStudio::Measure::OSArgument.makeChoiceArgument('lighting_generation', lighting_generation_chs, true)
    lighting_generation.setDisplayName('Lighting Generation')
    lighting_generation.setDescription('Lighting generation to determine efficiency level of interior lighting.')
    lighting_generation.setDefaultValue('gen4_led')
    args << lighting_generation

    return args
  end

  # change lighting technology if new generation is more efficient by lighting system
  def change_lighting_technology(runner, lights_definition, initial_lighting_technologies, new_lighting_technologies, prototype_lighting_space_type_properties)
    # existing lighting power
    if lights_definition.wattsperSpaceFloorArea.is_initialized
      initial_lpd_w_per_m2 = lights_definition.wattsperSpaceFloorArea.get
      initial_lpd_w_per_ft2 = OpenStudio.convert(initial_lpd_w_per_m2, 'W/m^2', 'W/ft^2').get
    else
      runner.registerWarning("Lights definition '#{lights_definition.name}' does not have an initial LPD.  Overriding with new lighting technology.")
      initial_lpd_w_per_ft2 = 999.0
    end

    # get the lighting system type if available
    has_lighting_system_type = lights_definition.additionalProperties.hasFeature('lighting_system_type')
    unless has_lighting_system_type
      runner.registerWarning("Lights definition '#{lights_definition.name}' does not have a lighting_system_type property assigned.  Cannot change lighting technology.")
      return false
    end
    lighting_system_type = lights_definition.additionalProperties.getFeatureAsString('lighting_system_type').to_s

    # get space type properties for lighting power density calculation
    total_horizontal_illuminance = prototype_lighting_space_type_properties[:total_horizontal_illuminance_lumens_per_ft2].to_f
    rsdd = prototype_lighting_space_type_properties[:room_surface_dirt_depreciation].to_f
    space_type_average_height_ft = prototype_lighting_space_type_properties[:space_type_average_height_ft].to_f
    case lighting_system_type
    when 'general'
      lighting_fraction = prototype_lighting_space_type_properties[:general_lighting_fraction].to_f
      cu = prototype_lighting_space_type_properties[:general_lighting_coefficient_of_utilization].to_f
    when 'task'
      lighting_fraction = prototype_lighting_space_type_properties[:task_lighting_fraction].to_f
      cu = prototype_lighting_space_type_properties[:task_lighting_coefficient_of_utilization].to_f
    when 'supplemental'
      lighting_fraction = prototype_lighting_space_type_properties[:supplemental_lighting_fraction].to_f
      cu = prototype_lighting_space_type_properties[:supplemental_lighting_coefficient_of_utilization].to_f
    when 'wall_wash'
      lighting_fraction = prototype_lighting_space_type_properties[:wall_wash_lighting_fraction].to_f
      cu = prototype_lighting_space_type_properties[:wall_wash_lighting_coefficient_of_utilization].to_f
    end

    # select new lighting technology based on lighting system type
    matching_objects = new_lighting_technologies.select { |r| (r[:lighting_system_type] == lighting_system_type) }
    matching_objects = matching_objects.reject { |r| space_type_average_height_ft.to_f.round(1) > r[:fixture_max_height_ft].to_f.round(1) }
    matching_objects = matching_objects.reject { |r| space_type_average_height_ft.to_f.round(1) <= r[:fixture_min_height_ft].to_f.round(1) }
    new_lighting_technology = matching_objects[0]
    luminous_efficacy = new_lighting_technology[:source_efficacy_lumens_per_watt].to_f
    llf = new_lighting_technology[:lighting_loss_factor].to_f
    return_air_fraction = new_lighting_technology[:return_air_fraction].to_f
    radiant_fraction = new_lighting_technology[:radiant_fraction].to_f
    visible_fraction = new_lighting_technology[:visible_fraction].to_f
    new_lighting_technology_name = new_lighting_technology[:lighting_technology]

    # calculate new lighting power density based on the lighting technology generation
    # <lighting_type>_lpd_w_per_ft2 =
    # (total_horizontal_illuminance * <lighting_type>_lighting_fraction) / (rsdd * luminous_efficacy * llf * <lighting_type>_cu)
    # ignore depreciation terms (rsdd, llf) when setting installed lighting power
    new_lpd_w_per_ft2 = (total_horizontal_illuminance * lighting_fraction) / (luminous_efficacy * cu)

    lights_changed = false
    if initial_lighting_technologies[0].keys.to_s.include?('LED')
      runner.registerAsNotApplicable('Model already contains LED lighting. This measure is not applicable.')
      return true
    else
      runner.registerInfo("Initial lighting power density '#{initial_lpd_w_per_ft2.round(3)} is greater than new lighting power density #{new_lpd_w_per_ft2.round(3)} for Lights Definition #{lights_definition.name} with lighting system type #{lighting_system_type}. Changing lights.")

      # set new properties on existing lights definition
      lights_definition.setWattsperSpaceFloorArea(OpenStudio.convert(new_lpd_w_per_ft2, 'W/ft^2', 'W/m^2').get)
      lights_definition.setReturnAirFraction(return_air_fraction)
      lights_definition.setFractionRadiant(radiant_fraction)
      lights_definition.setFractionVisible(visible_fraction)
      lights_definition.additionalProperties.setFeature('lighting_technology', new_lighting_technology_name)
      lights_changed = true
    end

    return lights_changed
  end

  # define what happens when the measure is run
  # The gem's lighting space type rows, read from the loaded gem (nil and an error if the file is missing).
  def load_gem_lighting_space_types(runner)
    source = OpenstudioStandards::InteriorLighting.method(:create_typical_interior_lighting).source_location.first
    path = File.join(File.dirname(source), 'data', 'lighting_space_types.json')
    unless File.file?(path)
      runner.registerError("Unable to find the gem's lighting space type data at #{path}")
      return nil
    end
    JSON.parse(File.read(path), symbolize_names: true)[:lighting_space_types]
  end

  # Map a gem lighting space type row onto the CSV field names change_lighting_technology expects
  # (the gem's target illuminance is in lux, the CSV's in footcandles).
  def gem_row_to_csv_fields(row)
    illuminance = row[:lighting_space_type_target_illuminance_setpoint].to_f
    units = row[:lighting_space_type_target_illuminance_units].to_s.downcase
    illuminance_fc = units == 'lux' ? illuminance / 10.7639 : illuminance
    {
      prototype_lighting_space_type: row[:lighting_space_type_name].to_s,
      total_horizontal_illuminance_lumens_per_ft2: illuminance_fc,
      room_surface_dirt_depreciation: 1.0, # not in the gem data; the LPD formula ignores depreciation terms
      general_lighting_fraction: row[:general_lighting_fraction].to_f,
      general_lighting_coefficient_of_utilization: row[:general_lighting_coefficient_of_utilization].to_f,
      task_lighting_fraction: row[:task_lighting_fraction].to_f,
      task_lighting_coefficient_of_utilization: row[:task_lighting_coefficient_of_utilization].to_f,
      supplemental_lighting_fraction: row[:supplemental_lighting_fraction].to_f,
      supplemental_lighting_coefficient_of_utilization: row[:supplemental_lighting_coefficient_of_utilization].to_f,
      wall_wash_lighting_fraction: row[:wall_wash_lighting_fraction].to_f,
      wall_wash_lighting_coefficient_of_utilization: row[:wall_wash_lighting_coefficient_of_utilization].to_f
    }
  end

  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # Assign the user input lighting generation to a variable
    lighting_generation = runner.getStringArgumentValue('lighting_generation', user_arguments)

    # load lookup file and convert to hash table
    prototype_lighting_space_type_csv = "#{File.dirname(__FILE__)}/resources/prototype_lighting_space_type.csv"
    if !File.file?(prototype_lighting_space_type_csv)
      runner.registerError("Unable to find file: #{prototype_lighting_space_type_csv}")
      return nil
    end
    prototype_lighting_space_type_tbl = CSV.table(prototype_lighting_space_type_csv)
    prototype_lighting_space_type_hsh = prototype_lighting_space_type_tbl.map(&:to_hash)

    # load lighting technology file and convert to hash table
    lighting_technology_csv = "#{File.dirname(__FILE__)}/resources/lighting_technology.csv"
    if !File.file?(lighting_technology_csv)
      runner.registerError("Unable to find file: #{lighting_technology_csv}")
      return nil
    end
    lighting_technology_tbl = CSV.table(lighting_technology_csv)
    lighting_technology_hsh = lighting_technology_tbl.map(&:to_hash)

    # lighting space type data from the gem, for typical models (see the lookup in the space type loop)
    gem_lighting_space_types = load_gem_lighting_space_types(runner)
    return false if gem_lighting_space_types.nil?

    # get lighting technology for the user-selected lighting generation
    lighting_technologies = lighting_technology_hsh.select { |r| (r[:lighting_generation] == lighting_generation) }
    if lighting_technologies.empty?
      runner.registerError("Unable to find lighting technologies for lighting generation '#{lighting_generation}'")
      return nil
    end

    # collectors for building lighting power and floor area
    building_lighting_floor_area = 0.0
    starting_building_lighting_power = 0.0
    ending_building_lighting_power = 0.0
    initial_lighting_technologies = []
    final_lighting_technologies = []
    any_lights_changed = false

    # model get standards space types
    model.getSpaceTypes.each do |space_type|
      # get space type area and volume
      space_type_floor_area = space_type.floorArea
      if space_type_floor_area.zero?
        runner.registerWarning("Space type #{space_type} floor area is zero.  Ignoring space type.")
        next
      end

      space_type_volume = 0.0
      space_type.spaces.each do |space|
        space_type_volume += space.volume * space.multiplier
      end

      if space_type_volume.zero?
        runner.registerError("Volume for space type #{space_type.name} is zero.")
        return false
      elsif space_type_volume.nil?
        runner.registerError("Unable to determine volume for space type #{space_type.name}.")
        return false
      end

      # calculate average space_type height
      space_type_average_height_m = space_type_volume / space_type_floor_area
      space_type_average_height_ft = OpenStudio.convert(space_type_average_height_m, 'm', 'ft').get

      # get number of people for lighting calculations
      space_type_number_of_people = space_type.getNumberOfPeople(space_type_floor_area)

      # Typical models carry 'lighting_space_type' (the gem data the baseline lighting came from); prototype
      # models carry 'prototype_lighting_space_type' (the measure's CSV). Both map onto the CSV fields.
      if space_type.additionalProperties.hasFeature('lighting_space_type')
        prototype_lighting_space_type = space_type.additionalProperties.getFeatureAsString('lighting_space_type').to_s
        row = gem_lighting_space_types.select { |r| r[:lighting_space_type_name] == prototype_lighting_space_type }
        if prototype_lighting_space_type == 'na' || row.empty?
          runner.registerWarning("Space type '#{space_type.name}' has lighting space type '#{prototype_lighting_space_type}' with no lighting data, so it had no typical lighting. Skipping.")
          next
        end
        prototype_lighting_space_type_properties = gem_row_to_csv_fields(row[0])
      elsif space_type.additionalProperties.hasFeature('prototype_lighting_space_type')
        prototype_lighting_space_type = space_type.additionalProperties.getFeatureAsString('prototype_lighting_space_type').to_s
        row = prototype_lighting_space_type_hsh.select { |r| (r[:prototype_lighting_space_type] == prototype_lighting_space_type) }
        if row.empty?
          runner.registerError("Unable to find prototype lighting space type data for '#{prototype_lighting_space_type}'")
          break
        end
        prototype_lighting_space_type_properties = row[0]
      else
        runner.registerWarning("Space type '#{space_type.name}' has neither a lighting_space_type nor a prototype_lighting_space_type property. Skipping.")
        next
      end
      prototype_lighting_space_type_properties[:space_type_average_height_ft] = space_type_average_height_ft

      # get initial conditions
      building_lighting_floor_area += space_type_floor_area
      starting_space_type_lighting_power = space_type.getLightingPower(space_type_floor_area, space_type_number_of_people)
      starting_building_lighting_power += starting_space_type_lighting_power

      # log initial lighting technologies and power in space types
      space_type_lights_definitions = []
      space_type.lights.sort.each do |light|
        lights_definition = light.lightsDefinition
        space_type_lights_definitions << lights_definition
        has_lighting_technology = lights_definition.additionalProperties.hasFeature('lighting_technology')
        unless has_lighting_technology
          runner.registerWarning("Lights definition '#{lights_definition.name}' for space type '#{space_type.name}' does not have a lighting_technology property assigned.  Cannot get initial lighting power.")
          break
        end
        initial_light_lighting_technology = lights_definition.additionalProperties.getFeatureAsString('lighting_technology').to_s

        # get the initial lighting power
        initial_lighting_power_w = light.getLightingPower(space_type_floor_area, space_type_number_of_people)

        # log initial value
        initial_lighting_technologies << { "#{initial_light_lighting_technology}": initial_lighting_power_w }
      end

      # if initial_lighting_technologies[0].keys.to_s.include?("LED")
      #   runner.registerAsNotApplicable("Model already contains LED lighting. This measure is not applicable.")
      #   return true
      # end

      # change the lights based on the new lighting technology and lighting system
      space_type_lights_definitions.uniq.sort.each do |lights_definition|
        lights_changed = change_lighting_technology(runner, lights_definition, initial_lighting_technologies, lighting_technologies, prototype_lighting_space_type_properties)
        any_lights_changed = true if lights_changed
      end

      # log final lighting technologies and power in space types
      space_type.lights.sort.each do |light|
        lights_definition = light.lightsDefinition
        has_lighting_technology = lights_definition.additionalProperties.hasFeature('lighting_technology')
        unless has_lighting_technology
          runner.registerWarning("Lights definition '#{lights_definition.name}' for space type '#{space_type.name}' does not have a lighting_technology property assigned.  Cannot get final lighting power.")
          break
        end
        final_light_lighting_technology = lights_definition.additionalProperties.getFeatureAsString('lighting_technology').to_s

        # get the final lighting power
        final_lighting_power_w = light.getLightingPower(space_type_floor_area, space_type_number_of_people)

        # log final value
        final_lighting_technologies << { "#{final_light_lighting_technology}": final_lighting_power_w }
      end

      # log initial lighting technologies and power in spaces
      spaces_lights_definitions = []
      space_type.spaces.each do |space|
        space_floor_area = space.floorArea * space.multiplier
        space_number_of_people = space.numberOfPeople * space.multiplier
        space.lights.sort.each do |light|
          lights_definition = light.lightsDefinition
          spaces_lights_definitions << lights_definition
          has_lighting_technology = lights_definition.additionalProperties.hasFeature('lighting_technology')
          unless has_lighting_technology
            runner.registerWarning("Lights definition '#{lights_definition.name}' for space '#{space.name}' does not have a lighting_technology property assigned.  Cannot get initial lighting power.")
            break
          end
          initial_light_lighting_technology = lights_definition.additionalProperties.getFeatureAsString('lighting_technology').to_s

          # get the initial lighting power
          initial_lighting_power_w = light.getLightingPower(space_floor_area, space_number_of_people)

          # log initial value
          initial_lighting_technologies << { "#{initial_light_lighting_technology}": initial_lighting_power_w }
        end
      end

      # change the lights based on the new lighting technology and lighting system
      spaces_lights_definitions.uniq.sort.each do |lights_definition|
        lights_changed = change_lighting_technology(runner, lights_definition, initial_lighting_technologies, lighting_technologies, prototype_lighting_space_type_properties)
        any_lights_changed = true if lights_changed
      end

      # log final lighting technologies and power in spaces
      space_type.spaces.each do |space|
        space_floor_area = space.floorArea * space.multiplier
        space_number_of_people = space.numberOfPeople * space.multiplier
        space.lights.sort.each do |light|
          lights_definition = light.lightsDefinition
          has_lighting_technology = lights_definition.additionalProperties.hasFeature('lighting_technology')
          unless has_lighting_technology
            runner.registerWarning("Lights definition '#{lights_definition.name}' for space '#{space.name}' does not have a lighting_technology property assigned.  Cannot get final lighting power.")
            break
          end
          final_light_lighting_technology = lights_definition.additionalProperties.getFeatureAsString('lighting_technology').to_s

          # get the final lighting power
          final_lighting_power_w = light.getLightingPower(space_floor_area, space_number_of_people)

          # log final value
          final_lighting_technologies << { "#{final_light_lighting_technology}": final_lighting_power_w }
        end
      end

      ending_space_type_lighting_power = space_type.getLightingPower(space_type_floor_area, space_type_number_of_people)
      ending_building_lighting_power += ending_space_type_lighting_power

      if space_type_floor_area > 0
        starting_space_type_lpd = OpenStudio.convert(starting_space_type_lighting_power / space_type_floor_area, 'W/m^2', 'W/ft^2').get
        ending_space_type_lpd = OpenStudio.convert(ending_space_type_lighting_power / space_type_floor_area, 'W/m^2', 'W/ft^2').get
      else
        starting_space_type_lpd = 'na - no area'
        ending_space_type_lpd = 'na - no area'
      end

      runner.registerInfo("Space type '#{space_type.name}' with prototype lighting space type '#{prototype_lighting_space_type}' starting LPD #{starting_space_type_lpd.round(2)} W/ft2, ending LPD #{ending_space_type_lpd.round(2)} W/ft2.")
    end

    # register as not applicable if no lights were changed
    # unless any_lights_changed
    #   runner.registerAsNotApplicable('Not Applicable - existing lighting is already as or more efficient than new lighting technology.')
    #   return true
    # end

    if building_lighting_floor_area > 0
      starting_building_lpd = OpenStudio.convert(starting_building_lighting_power / building_lighting_floor_area, 'W/m^2', 'W/ft^2').get
      ending_building_lpd = OpenStudio.convert(ending_building_lighting_power / building_lighting_floor_area, 'W/m^2', 'W/ft^2').get
    else
      runner.registerWarning('Building lighting floor area is zero.  This can happen if space types are not assigned to spaces.  Unable to report out building level LPDs.')
      starting_building_lpd = 0
      ending_building_lpd = 0
    end
    runner.registerFinalCondition("Set building lighting to #{lighting_generation}. Building lighting started with #{starting_building_lighting_power.round(2)} W (average LPD #{starting_building_lpd.round(2)} W/ft2) and ended with #{ending_building_lighting_power.round(2)} W (average LPD #{ending_building_lpd.round(2)} W/ft2).")
    runner.registerValue('light_lighting_technology_initial_lighting_power', starting_building_lighting_power, 'W')
    runner.registerValue('light_lighting_technology_initial_lighting_power_density', starting_building_lpd, 'W/ft^2')
    runner.registerValue('light_lighting_technology_final_lighting_power', ending_building_lighting_power, 'W')
    runner.registerValue('light_lighting_technology_final_lighting_power_density', ending_building_lpd, 'W/ft^2')

    # log by lighting technology
    initial_technology_power_log = initial_lighting_technologies.inject { |a, b| a.merge(b) { |_, x, y| x + y } }.to_s.gsub(/[:,{}"]/, '')
    final_technology_power_log = final_lighting_technologies.inject { |a, b| a.merge(b) { |_, x, y| x + y } }.to_s.gsub(/[:,{}"]/, '')
    runner.registerInfo("Initial power by lighting technology in watts: #{initial_technology_power_log}")
    runner.registerInfo("Final power by lighting technology in watts: #{final_technology_power_log}")
    runner.registerValue('light_lighting_technology_initial_power_by_technology_w', initial_technology_power_log, 'W')
    runner.registerValue('light_lighting_technology_final_power_by_technology_w', final_technology_power_log, 'W')

    return true
  end
end

# register the measure to be used by the application
LightLED.new.registerWithApplication
