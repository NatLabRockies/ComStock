# ComStock™, Copyright (c) 2023 Alliance for Sustainable Energy, LLC. All rights reserved.
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
require 'comstock-typical'

# require all .rb files in resources folder
Dir[File.dirname(__FILE__) + '/resources/*.rb'].each { |file| require file }

# start the measure
class LightingControls < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    'lighting_controls'
  end

  # human readable description
  def description
    'This measure applies lighting controls (daylighting sensors, occupancy sensors) to spaces where they are not already present. '
  end

  # human readable description of modeling approach
  def modeler_description
    'This measure loops through space types in the model and applies daylighting controls and occupancy sensors where they are not already present. Daylighting sensors are added via the built-in energy plus daylighting objects, while occupancy sensors are applied via a percent LPD reduction by space type based on ASHRAE 90.1 Appendix Table G3.7.'
  end

  # define the arguments that the user will input
  def arguments(_model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # apply daylighting controls?
    apply_daylighting = OpenStudio::Measure::OSArgument.makeBoolArgument('apply_daylighting', true)
    apply_daylighting.setDisplayName('Apply daylighting controls?')
    apply_daylighting.setDescription('')
    apply_daylighting.setDefaultValue(true)
    args << apply_daylighting

    # apply daylighting controls?
    apply_occupancy = OpenStudio::Measure::OSArgument.makeBoolArgument('apply_occupancy', true)
    apply_occupancy.setDisplayName('Apply occupancy controls?')
    apply_occupancy.setDescription('')
    apply_occupancy.setDefaultValue(true)
    args << apply_occupancy

    args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    return false unless runner.validateUserArguments(arguments(model), user_arguments)

    # get user arguments
    apply_daylighting = runner.getBoolArgumentValue('apply_daylighting', user_arguments)
    apply_occupancy = runner.getBoolArgumentValue('apply_occupancy', user_arguments)

    # Get additional properties of the model. Used to look up template of original construction, which informs which spaces should already have occupancy sensors by code.
    addtl_props = model.getBuilding.additionalProperties

    if addtl_props.getFeatureAsString('energy_code_in_force_during_original_building_construction').is_initialized
      template = addtl_props.getFeatureAsString('energy_code_in_force_during_original_building_construction').get
      runner.registerInfo("Energy code in force during original building construction is: #{template}.")
    else
      runner.registerError('Energy code could not be found. Measure will not be applied.')
    end

    # Make a standard that follows 90.1-2019 (the code year that will be used for lighting controls assumptions)
    standard = Standard.build('ComStock 90.1-2019')

    # track how many spaces are receiving new daylighting sensors.
    num_spaces_to_get_daylighting_sensors = 0

    if apply_daylighting == true
      # start daylighting method
      remove_existing_controls = false
      draw_daylight_areas_for_debugging = false

      model.getSpaces.sort.each do |space|
        runner.registerInfo("******For #{space.name}, adding daylight controls.")

        # Get the space thermal zone
        zone = space.thermalZone
        if zone.empty?
          runner.registerError("Space #{space.name} has no thermal zone; cannot set daylighting controls for zone.")
        else
          zone = zone.get
        end

        # Check for existing daylighting controls
        # and remove if specified in the input
        existing_daylighting_controls = space.daylightingControls
        unless existing_daylighting_controls.empty?
          if remove_existing_controls
            space_remove_daylighting_controls(space)
            zone.resetFractionofZoneControlledbyPrimaryDaylightingControl
            zone.resetFractionofZoneControlledbySecondaryDaylightingControl
          else
            runner.registerInfo("For #{space.name}, daylight controls were already present, no additional controls added.")
            next
          end
        end

        # Skip this space if it has no exterior windows or skylights
        ext_fen_area_m2 = 0
        has_shading_controls = false
        space.surfaces.each do |surface|
          next unless surface.outsideBoundaryCondition == 'Outdoors'

          surface.subSurfaces.each do |sub_surface|
            next unless %w[FixedWindow OperableWindow Skylight
                          GlassDoor].include?(sub_surface.subSurfaceType)

            # get window area, if area is 0, no exterior fenestration
            ext_fen_area_m2 += sub_surface.netArea

            # check if any shading controls are present
            unless sub_surface.shadingControls.empty?
              has_shading_controls = true
            end
          end
        end
        if ext_fen_area_m2.zero?
          runner.registerInfo("For #{space.name}, daylighting control not applicable because no exterior fenestration is present.")
          next
        end

        if has_shading_controls
          runner.registerInfo("For #{space.name}, daylighting control not applicable because shading controls are already present.")
          next
        end

        # Get the daylighting areas
        areas = standard.space_daylighted_areas(space, draw_daylight_areas_for_debugging)

        # Determine the type of daylighting controls required
        # use most of the criteria from the space_daylighting_controls_required? method but get rid of lighting power limits
        # this allows the daylighting sensors to be applied to more spaces besides just the ones required by ASHRAE
        req_top_ctrl = true
        req_pri_ctrl = true
        req_sec_ctrl = true

        # Get the LPD of the space
        space_lpd_w_per_m2 = space.lightingPowerPerFloorArea

        # Primary Sidelighting
        # Check if primary sidelighted area is non-zero, then check if window is large enough
        if areas['primary_sidelighted_area'] < 0.01
          runner.registerInfo("For #{space.name}, primary sidelighting control not required because primary sidelighted area = 0ft2 per 9.4.1.1(e).")
          req_pri_ctrl = false
        else
          if areas['total_window_area'] < OpenStudio.convert(20.0, 'ft^2', 'm^2').get
            runner.registerInfo("For #{space.name}, primary sidelighting control not required because there are less than 20ft2 of window per 9.4.1.1(e) Exception 2.")
            req_pri_ctrl = false
          end
        end

        # Secondary Sidelighting
        # Check if secondary sidelighted area is non-zero, then check if window is large enough
        if areas['secondary_sidelighted_area'] < 0.01
          runner.registerInfo("For #{space.name}, secondary sidelighting control not required because secondary sidelighted area = 0ft2 per 9.4.1.1(e).")
          req_sec_ctrl = false
        else
          if areas['total_window_area'] < OpenStudio.convert(20.0, 'ft^2', 'm^2').get
            runner.registerInfo("For #{space.name}, secondary sidelighting control not required because there are less than 20ft2 of window per 9.4.1.1(e) Exception 2.")
            req_sec_ctrl = false
          end
        end

        # Toplighting
        # Check if toplighting area is non-zero
        if areas['toplighted_area'] < 0.01
          runner.registerInfo("For #{space.name}, toplighting control not required because toplighted area = 0ft2 per 9.4.1.1(f).")
          req_top_ctrl = false
        end

        # Exceptions
        if space.spaceType.is_initialized
          case space.spaceType.get.standardsSpaceType.to_s
          when 'Core_Retail'
            # Retail spaces exception (c) to Section 9.4.1.4
            # req_sec_ctrl set to true to create a second reference point
            req_pri_ctrl = false
            req_sec_ctrl = true
          when 'Entry', 'Front_Retail', 'Point_of_Sale', 'Strip mall - type 1', 'Strip mall - type 2', 'Strip mall - type 3'
            # Retail, Strip mall
            req_pri_ctrl = false
            req_sec_ctrl = false
          end
        end

        # Output the daylight control requirements
        runner.registerInfo("For #{space.name}, toplighting control required = #{req_top_ctrl}")
        runner.registerInfo("For #{space.name}, primary sidelighting control required = #{req_pri_ctrl}")
        runner.registerInfo("For #{space.name}, secondary sidelighting control required = #{req_sec_ctrl}")

        if req_pri_ctrl || req_sec_ctrl || req_top_ctrl
          # if any one of the daylighting sensors is required, add to list of spaces getting daylighting sensors
          num_spaces_to_get_daylighting_sensors += 1
        else
          runner.registerInfo("Primary sidelighting, secondary sidelighting, and toplighting not required for #{space.name}. Not adding daylighting sensors.")
          next
        end

        # Record a floor in the space for later use
        floor_surface = nil
        space.surfaces.sort.each do |surface|
          if surface.surfaceType == 'Floor'
            floor_surface = surface
            break
          end
        end

        # Find all exterior windows/skylights in the space and record their azimuths and areas
        windows = {}
        skylights = {}
        space.surfaces.sort.each do |surface|
          next unless surface.outsideBoundaryCondition == 'Outdoors' && %w[Wall
                                                                          RoofCeiling].include?(surface.surfaceType)

          # Skip non-vertical walls and non-horizontal roofs
          straight_upward = OpenStudio::Vector3d.new(0, 0, 1)
          surface_normal = surface.outwardNormal
          if surface.surfaceType == 'Wall'
            # @todo stop skipping non-vertical walls
            if !(surface_normal.z.abs < 0.001) && !surface.subSurfaces.empty?
              runner.registerWarning("Cannot currently handle non-vertical walls; skipping windows on #{surface.name} in #{space.name} for daylight sensor positioning.")
              next
            end
          elsif surface.surfaceType == 'RoofCeiling'
            # @todo stop skipping non-horizontal roofs
            if !(surface_normal.to_s == straight_upward.to_s) && !surface.subSurfaces.empty?
              runner.registerWarning("Cannot currently handle non-horizontal roofs; skipping skylights on #{surface.name} in #{space.name} for daylight sensor positioning.")
              runner.registerInfo("---Surface #{surface.name} has outward normal of #{surface_normal.to_s.gsub(
                /\[|\]/, '|'
              )}; up is #{straight_upward.to_s.gsub(/\[|\]/, '|')}.")
              next
            end
          end

          # Find the azimuth of the facade
          facade = nil
          group = surface.planarSurfaceGroup
          # The surface is not in a group; should not hit, since called from Space.surfaces
          next unless group.is_initialized

          group = group.get
          site_transformation = group.buildingTransformation
          site_vertices = site_transformation * surface.vertices
          site_outward_normal = OpenStudio.getOutwardNormal(site_vertices)
          if site_outward_normal.empty?
            runner.registerError("Could not compute outward normal for #{surface.name.get}")
            next
          end
          site_outward_normal = site_outward_normal.get
          north = OpenStudio::Vector3d.new(0.0, 1.0, 0.0)
          azimuth = if site_outward_normal.x < 0.0
                      360.0 - OpenStudio.radToDeg(OpenStudio.getAngle(site_outward_normal, north))
                    else
                      OpenStudio.radToDeg(OpenStudio.getAngle(site_outward_normal, north))
                    end

          # @todo modify to work for buildings in the southern hemisphere?
          if azimuth >= 315.0 || azimuth < 45.0
            facade = '4-North'
          elsif azimuth >= 45.0 && azimuth < 135.0
            facade = '3-East'
          elsif azimuth >= 135.0 && azimuth < 225.0
            facade = '1-South'
          elsif azimuth >= 225.0 && azimuth < 315.0
            facade = '2-West'
          end

          # Label the facade as "Up" if it is a skylight
          facade = '0-Up' if surface_normal.to_s == straight_upward.to_s

          # Loop through all subsurfaces and
          surface.subSurfaces.sort.each do |sub_surface|
            next unless sub_surface.outsideBoundaryCondition == 'Outdoors' && %w[FixedWindow OperableWindow
                                                                                Skylight].include?(sub_surface.subSurfaceType)

            # Find the area
            net_area_m2 = sub_surface.netArea

            # Find the head height and sill height of the window
            vertex_heights_above_floor = []
            sub_surface.vertices.each do |vertex|
              vertex_on_floorplane = floor_surface.plane.project(vertex)
              vertex_heights_above_floor << (vertex - vertex_on_floorplane).length
            end
            head_height_m = vertex_heights_above_floor.max
            # OpenStudio::logFree(OpenStudio::Info, "openstudio.standards.Space", "---head height = #{head_height_m}m, sill height = #{sill_height_m}m")

            # Log the window properties to use when creating daylight sensors
            properties = { facade: facade, area_m2: net_area_m2, handle: sub_surface.handle,
                          head_height_m: head_height_m, name: sub_surface.name.get.to_s }
            if facade == '0-Up'
              skylights[sub_surface] = properties
            else
              windows[sub_surface] = properties
            end
          end
        end

        # Determine the illuminance setpoint for the controls based on space type
        daylight_stpt_lux = 375

        # find the specific space_type properties
        space_type = space.spaceType
        if space_type.empty?
          runner.registerWarning("Space #{space_type} is an unknown space type, assuming #{daylight_stpt_lux} Lux daylight setpoint")
        else
          space_type = space_type.get
          standards_building_type = nil
          standards_space_type = nil
          data = nil
          standards_building_type = space_type.standardsBuildingType.get if space_type.standardsBuildingType.is_initialized
          standards_space_type = space_type.standardsSpaceType.get if space_type.standardsSpaceType.is_initialized

          unless standards_building_type.nil? || standards_space_type.nil?
            # use the building type (standards_building_type) and space type (standards_space_type)
            # as well as template to locate the space type data
            search_criteria = {
              'template' => template,
              'building_type' => standards_building_type,
              'space_type' => standards_space_type
            }
            data = standard.model_find_object(standard.standards_data['space_types'], search_criteria)
          end

          if standards_building_type.nil? || standards_space_type.nil?
            runner.registerWarning("Unable to determine standards building type and standards space type for space '#{space.name}' with space type '#{space_type.name}'. Assign a standards building type and standards space type to the space type object. Defaulting to a #{daylight_stpt_lux} Lux daylight setpoint.")
          elsif data.nil?
            runner.registerWarning("Unable to find target illuminance setpoint data for space type '#{space_type.name}' with #{template} space type '#{standards_space_type}' in building type '#{standards_building_type}'. Defaulting to a #{daylight_stpt_lux} Lux daylight setpoint.")
            if daylight_stpt_lux == 'na'
              runner.registerInfo("For #{space.name}: daylighting is not appropriate for #{template} #{standards_building_type} #{standards_space_type}.")
              return true
            end
            # If a setpoint is specified, use that.  Otherwise use a default.
            daylight_stpt_lux = daylight_stpt_lux.to_f
            if daylight_stpt_lux.zero?
              daylight_stpt_lux = 375
              runner.registerInfo('openstudio.standards.Space',
                                  "For #{space.name}: no specific illuminance setpoint defined for #{template} #{standards_building_type} #{standards_space_type}, assuming #{daylight_stpt_lux} Lux.")
            else
              runner.registerInfo("For #{space.name}: illuminance setpoint = #{daylight_stpt_lux} Lux")
            end
          # for the office prototypes where core and perimeter zoning is used,
          # # there are additional assumptions about how much of the daylit area can be used.
          # if standards_building_type == 'Office' && standards_space_type.include?('WholeBuilding')
          #   psa_nongeo_frac = standard.data['psa_nongeometry_fraction'].to_f
          #   ssa_nongeo_frac = standard.data['ssa_nongeometry_fraction'].to_f
          #   runner.registerInfo("For #{space.name}: assuming only #{(psa_nongeo_frac * 100).round}% of the primary sidelit area is daylightable based on typical design practice.")
          #   runner.registerInfo("For #{space.name}: assuming only #{(ssa_nongeo_frac * 100).round}% of the secondary sidelit area is daylightable based on typical design practice.")
          # end
          else
            # Read the illuminance setpoint value
            # If 'na', daylighting is not appropriate for this space type for some reason
            daylight_stpt_lux = data['target_illuminance_setpoint']
            if daylight_stpt_lux == 'na'
              runner.registerInfo("For #{space.name}: daylighting is not appropriate for #{template} #{standards_building_type} #{standards_space_type}.")
              return true
            end
            # If a setpoint is specified, use that.  Otherwise use a default.
            daylight_stpt_lux = daylight_stpt_lux.to_f
            if daylight_stpt_lux.zero?
              daylight_stpt_lux = 375
              runner.registerInfo('openstudio.standards.Space',
                                  "For #{space.name}: no specific illuminance setpoint defined for #{template} #{standards_building_type} #{standards_space_type}, assuming #{daylight_stpt_lux} Lux.")
            else
              runner.registerInfo("For #{space.name}: illuminance setpoint = #{daylight_stpt_lux} Lux")
            end
            # for the office prototypes where core and perimeter zoning is used,
            # there are additional assumptions about how much of the daylit area can be used.
            if standards_building_type == 'Office' && standards_space_type.include?('WholeBuilding')
              psa_nongeo_frac = data['psa_nongeometry_fraction'].to_f
              ssa_nongeo_frac = data['ssa_nongeometry_fraction'].to_f
              runner.registerInfo("For #{space.name}: assuming only #{(psa_nongeo_frac * 100).round}% of the primary sidelit area is daylightable based on typical design practice.")
              runner.registerInfo("For #{space.name}: assuming only #{(ssa_nongeo_frac * 100).round}% of the secondary sidelit area is daylightable based on typical design practice.")
            end
          end

          # Sort by priority; first by facade, then by area,
          # then by name to ensure deterministic in case identical in other ways
          sorted_windows = windows.sort_by { |_window, vals| [vals[:facade], vals[:area], vals[:name]] }
          sorted_skylights = skylights.sort_by { |_skylight, vals| [vals[:facade], vals[:area], vals[:name]] }

          # Determine the sensor fractions and the attached windows
          sensor_1_frac, sensor_2_frac, sensor_1_window, sensor_2_window = standard.space_daylighting_fractions_and_windows(space,
                                                                                                                            areas,
                                                                                                                            sorted_windows,
                                                                                                                            sorted_skylights,
                                                                                                                            req_top_ctrl,
                                                                                                                            req_pri_ctrl,
                                                                                                                            req_sec_ctrl)

          # Further adjust the sensor controlled fraction for the three
          # office prototypes based on assumptions about geometry that is not explicitly
          # defined in the model.
          if standards_building_type == 'Office' && standards_space_type.include?('WholeBuilding')
            sensor_1_frac *= psa_nongeo_frac unless psa_nongeo_frac.nil?
            sensor_2_frac *= ssa_nongeo_frac unless ssa_nongeo_frac.nil?
          end

          # Ensure that total controlled fraction
          # is never set above 1 (100%)
          sensor_1_frac = sensor_1_frac.round(3)
          sensor_2_frac = sensor_2_frac.round(3)
          sensor_1_frac = 1.0 - 0.001 if sensor_1_frac >= 1.0
          if sensor_1_frac + sensor_2_frac >= 1.0
            # Lower sensor_2_frac so that the total
            # is just slightly lower than 1.0
            sensor_2_frac = 1.0 - sensor_1_frac - 0.001
          end

          # Sensors
          if sensor_1_frac > 0.0
            runner.registerInfo("For #{space.name}: sensor 1 controls #{(sensor_1_frac * 100).round}% of the zone lighting.")
          end
          if sensor_2_frac > 0.0
            runner.registerInfo("For #{space.name}: sensor 2 controls #{(sensor_2_frac * 100).round}% of the zone lighting.")
          end

          # First sensor
          if sensor_1_window
            sensor_1 = OpenStudio::Model::DaylightingControl.new(space.model)
            sensor_1.setName("#{space.name} Daylt Sensor 1")
            sensor_1.setSpace(space)
            sensor_1.setIlluminanceSetpoint(daylight_stpt_lux)
            sensor_1.setLightingControlType(standard.space_daylighting_control_type(space))
            # all sensors 3-step per design
            sensor_1.setNumberofSteppedControlSteps(3) unless standard.space_daylighting_control_type(space) != 'Stepped'
            sensor_1.setMinimumInputPowerFractionforContinuousDimmingControl(standard.space_daylighting_minimum_input_power_fraction(space))
            sensor_1.setMinimumLightOutputFractionforContinuousDimmingControl(0.2)
            sensor_1.setProbabilityLightingwillbeResetWhenNeededinManualSteppedControl(1.0)
            sensor_1.setMaximumAllowableDiscomfortGlareIndex(22.0)

            # Place sensor depending on skylight or window
            sensor_vertex = nil
            if sensor_1_window[1][:facade] == '0-Up'
              sub_surface = sensor_1_window[0]
              outward_normal = sub_surface.outwardNormal
              centroid = OpenStudio.getCentroid(sub_surface.vertices).get
              ht_above_flr = OpenStudio.convert(2.5, 'ft', 'm').get
              outward_normal.setLength(sensor_1_window[1][:head_height_m] - ht_above_flr)
              sensor_vertex = centroid + outward_normal.reverseVector
            else
              sub_surface = sensor_1_window[0]
              window_outward_normal = sub_surface.outwardNormal
              window_centroid = OpenStudio.getCentroid(sub_surface.vertices).get
              window_outward_normal.setLength(sensor_1_window[1][:head_height_m] * 0.66)
              vertex = window_centroid + window_outward_normal.reverseVector
              vertex_on_floorplane = floor_surface.plane.project(vertex)
              floor_outward_normal = floor_surface.outwardNormal
              floor_outward_normal.setLength(OpenStudio.convert(2.5, 'ft', 'm').get)
              sensor_vertex = vertex_on_floorplane + floor_outward_normal.reverseVector
            end
            sensor_1.setPosition(sensor_vertex)

            # @todo rotate sensor to face window (only needed for glare calcs)
            zone.setPrimaryDaylightingControl(sensor_1)
            if zone.fractionofZoneControlledbyPrimaryDaylightingControl + sensor_1_frac > 1
              zone.resetFractionofZoneControlledbySecondaryDaylightingControl
            end
            zone.setFractionofZoneControlledbyPrimaryDaylightingControl(sensor_1_frac)
          end

          # Second sensor
          if sensor_2_window
            sensor_2 = OpenStudio::Model::DaylightingControl.new(space.model)
            sensor_2.setName("#{space.name} Daylt Sensor 2")
            sensor_2.setSpace(space)
            sensor_2.setIlluminanceSetpoint(daylight_stpt_lux)
            sensor_2.setLightingControlType(standard.space_daylighting_control_type(space))
            # all sensors 3-step per design
            sensor_2.setNumberofSteppedControlSteps(3) unless standard.space_daylighting_control_type(space) != 'Stepped'
            sensor_2.setMinimumInputPowerFractionforContinuousDimmingControl(standard.space_daylighting_minimum_input_power_fraction(space))
            sensor_2.setMinimumLightOutputFractionforContinuousDimmingControl(0.2)
            sensor_2.setProbabilityLightingwillbeResetWhenNeededinManualSteppedControl(1.0)
            sensor_2.setMaximumAllowableDiscomfortGlareIndex(22.0)

            # Place sensor depending on skylight or window
            sensor_vertex = nil
            if sensor_2_window[1][:facade] == '0-Up'
              sub_surface = sensor_2_window[0]
              outward_normal = sub_surface.outwardNormal
              centroid = OpenStudio.getCentroid(sub_surface.vertices).get
              ht_above_flr = OpenStudio.convert(2.5, 'ft', 'm').get
              outward_normal.setLength(sensor_2_window[1][:head_height_m] - ht_above_flr)
              sensor_vertex = centroid + outward_normal.reverseVector
            else
              sub_surface = sensor_2_window[0]
              window_outward_normal = sub_surface.outwardNormal
              window_centroid = OpenStudio.getCentroid(sub_surface.vertices).get
              window_outward_normal.setLength(sensor_2_window[1][:head_height_m] * 1.33)
              vertex = window_centroid + window_outward_normal.reverseVector
              vertex_on_floorplane = floor_surface.plane.project(vertex)
              floor_outward_normal = floor_surface.outwardNormal
              floor_outward_normal.setLength(OpenStudio.convert(2.5, 'ft', 'm').get)
              sensor_vertex = vertex_on_floorplane + floor_outward_normal.reverseVector
            end
            sensor_2.setPosition(sensor_vertex)

            # @todo rotate sensor to face window (only needed for glare calcs)
            zone.setSecondaryDaylightingControl(sensor_2)
            if zone.fractionofZoneControlledbySecondaryDaylightingControl + sensor_2_frac > 1
              zone.resetFractionofZoneControlledbyPrimaryDaylightingControl
            end
            zone.setFractionofZoneControlledbySecondaryDaylightingControl(sensor_2_frac)
          end
        end
      end
    else
      runner.registerInfo('User argument does not request daylighting controls, so none will be added.')
    end

    # track how many spaces are receiving new daylighting sensors.
    num_spaces_to_get_occupancy_sensors = 0

    if apply_occupancy == true
      # set list of spaces to skip for each code year
      # In these spaces, ASHRAE 90.1 already requires occuapancy sensors, therefore we will skip these zones when applying the LPD reduction so as to not overestimate savings.
      spaces_to_skip = []
      if ['ComStock 90.1-2004', 'ComStock 90.1-2007'].include?(template)
        spaces_to_skip = %w[Meeting StaffLounge Conference]
      elsif template == 'ComStock 90.1-2010'
        spaces_to_skip = %w[Auditorium Classroom ComputerRoom Restroom Meeting PublicRestroom StaffLounge
                            Storage Back_Space Conference DressingRoom Janitor LockerRoom CompRoomClassRm
                            OfficeSmall StockRoom]
      elsif template == 'ComStock 90.1-2013'
        spaces_to_skip = %w[Auditorium Classroom ComputerRoom Restroom Meeting PublicRestroom StaffLounge
                            Storage Back_Space Conference DressingRoom Janitor LockerRoom CompRoomClassRm
                            OfficeSmall StockRoom GuestLounge Banquet Lounge]
      elsif template == 'ComStock DEER 2011'
        spaces_to_skip = %w[Classroom ComputerRoom Meeting CompRoomClassRm OfficeSmall]
      elsif ['ComStock DEER 2014', 'ComStock DEER 2015', 'ComStock DEER 2017'].include?(template)
        spaces_to_skip = %w[Classroom ComputerRoom Meeting CompRoomClassRm OfficeSmall Restroom GuestLounge
                            PublicRestroom StaffLounge Storage LockerRoom Lounge]
      end

      # set location for csv lookup file
      occupancy_sensor_reduction_by_space_type = File.join(File.dirname(__FILE__), 'resources',
                                                           'occupancy_sensor_reduction_by_space_type.csv')

      model.getSpaceTypes.sort.each do |space_type|
        standard_space_type = space_type.standardsSpaceType.to_s

        lpd_reduction = 0
        found_match = false

        if spaces_to_skip.include?(standard_space_type)
          runner.registerInfo("Occupancy sensors already required by code in space type #{standard_space_type}. This space type will not be modidied.")
        else
          # Do csv lookup using standard_space_type name
          runner.registerInfo("stanard space type = #{standard_space_type}")
          CSV.foreach(occupancy_sensor_reduction_by_space_type, headers: true) do |row|
            if row['standard_space_type'] == standard_space_type
              lpd_reduction = row['lpd_reduction'].to_f
              runner.registerInfo("Interior lighting power reduction for space type #{space_type.name} = #{(lpd_reduction * 100).round(0)}%")
              found_match = true
              runner.registerInfo("found match = #{found_match}")
              break
            end
          end

          if lpd_reduction > 0
            # if the space has a non-zero % reduction, add to list of spaces recieving occupancy controls
            num_spaces_to_get_occupancy_sensors += 1
          end

          unless found_match
            runner.registerInfo("No LPD reduction specified for space type #{space_type.name}. Not adding occupancy sensors.")
          end

          space_type.lights.each do |light|
            next unless light.name.get.include?('General Lighting')

            lights_definition = light.lightsDefinition
            if lights_definition.wattsperSpaceFloorArea.is_initialized
              lpd_existing = lights_definition.wattsperSpaceFloorArea.get
              lpd_new = lpd_existing * (1 - lpd_reduction)

              lights_definition.setWattsperSpaceFloorArea(lpd_new)

              runner.registerInfo("Interior lighting power density for space type #{space_type.name} was reduced by #{(lpd_reduction * 100).round(0)}% from #{lpd_existing.round(2)} W/ft2 to #{lpd_new.round(2)} W/ft2 due to the addition of occupancy sensors.")
            else
              runner.registerWarning("Lighting power is specified using Lighting Level (W) or Lighting Level per Person (W/person) for space type: #{space_type.name}. Measure will not modify lights in this space type.")
            end
          end
        end
      end
    else
      runner.registerInfo('User argument does not request occupancy controls, so none will be added.')
    end

    if num_spaces_to_get_occupancy_sensors + num_spaces_to_get_daylighting_sensors == 0
      runner.registerAsNotApplicable("Neither daylighting sensors nor occupancy sensors were applicable to any spaces in the model. Measure is not applicable.")
      return true
    end

    runner.registerFinalCondition("Daylighting sensors were applied to #{num_spaces_to_get_daylighting_sensors} spaces and occupancy sensors were applied to #{num_spaces_to_get_occupancy_sensors} spaces in the model.")

    true
  end
end

# register the measure to be used by the application
LightingControls.new.registerWithApplication
