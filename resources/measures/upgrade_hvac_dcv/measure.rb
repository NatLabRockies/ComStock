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

# dependencies
require 'comstock-typical'

# start the measure
class HVACDCV < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'HVAC DCV'
  end

  # human readable description
  def description
    return 'Add demand control ventilation to an HVAC system.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'Add demand control ventilation to variable volume HVAC systems. Requires that the design specification outdoor air objects have some part of the ventilation be specified as per person. Also requires that if zone hvac equipment is present, it takes load priority over the venilation system.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    if model.getBuilding.name.to_s.include?('hotel') || model.getBuilding.name.to_s.include?('Hotel') || model.getBuilding.name.to_s.include?('Htl') || model.getBuilding.name.to_s.include?('Mtl')
      runner.registerAsNotApplicable("Model building type '#{model.getBuilding.name}' is a hotel and not eligable for DCV. This measure is not applicable.")
      return true
    elsif ((model.getBuilding.name.to_s.include?('restaurant') || model.getBuilding.name.to_s.include?('Restaurant') || model.getBuilding.name.to_s.include?('RSD') || model.getBuilding.name.to_s.include?('RFF'))) && !(model.getBuilding.name.to_s.include?('Strip') || model.getBuilding.name.to_s.include?('strip'))
      runner.registerAsNotApplicable("Model building type '#{model.getBuilding.name}' is a restaurant and not eligable for DCV. This measure is not applicable.")
      return true
    end

    # # build standard to access methods
    orig_hvac_code_comstock = model.getBuilding.additionalProperties.getFeatureAsString('hvac_as_constructed_template')
    std = Standard.build(orig_hvac_code_comstock.to_s)

    # list of space types where DCV will not be applied
    # Space types this measure leaves alone, in the typical (all-level) space type vocabulary.
    # These are ventilation-driven or use no per-person ventilation rate. A level-1 name covers every
    # qualified variant ('food preparation' includes the school kitchens). Prototype space type names
    # ('Kitchen', 'PatRoom', 'IT_Room') resolve to the same names through the prototype space type
    # crosswalk, so this list reads both model vintages. The prototype list's 'Entry' (now 'lobby') and
    # 'BioHazard' (now 'storage') are not carried over: the typical names cover far more than they did.
    space_types_no_dcv = [
      'food preparation',
      'patient room',
      'laboratory',
      'exam/treatment',
      'operating room',
      'emergency room',
      'physical therapy',
      'datacenter/high ite',
      'datacenter/low ite',
      'corridor',
      'electrical/mechanical',
      'restroom',
      'dining',
      'locker room',
      'stairwell'
    ]

    no_outdoor_air_loops = 0
    no_per_person_rates_loops = 0
    constant_volume_doas_loops = 0
    existing_dcv_loops = 0
    ervs = 0
    ineligible_space_types = 0
    selected_air_loops = []
    model.getAirLoopHVACs.each do |air_loop_hvac|
      # check for prevelance of OA system in air loop; skip if none
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem
      if oa_system.is_initialized
        oa_system = oa_system.get
      else
        no_outdoor_air_loops += 1
        runner.registerInfo("Air loop '#{air_loop_hvac.name}' does not have outdoor air and cannot have demand control ventilation.")
        next
      end

      # check if airloop is DOAS; skip if true
      sizing_system = air_loop_hvac.sizingSystem
      type_of_load = sizing_system.typeofLoadtoSizeOn
      if type_of_load == 'VentilationRequirement'
        constant_volume_doas_loops += 1
        runner.registerInfo("Air loop '#{air_loop_hvac.name}' is a constant volume DOAS system and cannot have demand control ventilation.")
        next
      end

      # Check for ERV. If the air loop has an ERV, air loop is not applicable for DCV measure.
      erv_components = []
      air_loop_hvac.oaComponents.each do |component|
        component_name = component.name.to_s
        next if component_name.include? 'Node'

        if component_name.include? 'ERV'
          erv_components << component
        end
      end

      if erv_components.any?
        runner.registerInfo("Air loop '#{air_loop_hvac.name}' has an ERV. DCV will not be applied.")
        ervs += 1
        # next
      end

      # check to see if airloop has existing DCV
      # TODO - if it does have DCV, check to see if all zones are getting DCV
      controller_oa = oa_system.getControllerOutdoorAir
      controller_mv = controller_oa.controllerMechanicalVentilation
      if controller_mv.demandControlledVentilation
        existing_dcv_loops += 1
        runner.registerInfo("Air loop '#{air_loop_hvac.name}' already has demand control ventilation enabled.")
        next
      end

      # check to see if airloop has applicable space types
      # these space types are often ventilation driven, or generally do not use ventilation rates per person
      # exclude these space types: kitchens, laboratories, patient care rooms
      # TODO - add functionality to add DCV to multizone systems to applicable zones only
      space_no_dcv = 0
      space_dcv = 0
      air_loop_hvac.thermalZones.sort.each do |zone|
        zone.spaces.each do |space|
          if OpenstudioStandards::SpaceType.space_matches?(space, space_types_no_dcv)
            space_no_dcv += 1
          else
            space_dcv += 1
          end
        end
      end
      unless space_dcv >= 1
        runner.registerInfo("Air loop '#{air_loop_hvac.name}' serves only ineligible space types. DCV will not be applied.")
        ineligible_space_types += 1
        next
      end

      runner.registerInfo("Air loop '#{air_loop_hvac.name}' does not have existing demand control ventilation.  This measure will enable it.")
      selected_air_loops << air_loop_hvac
    end

    # report initial condition of model
    runner.registerInitialCondition("Out of #{model.getAirLoopHVACs.size} air loops, #{no_outdoor_air_loops} do not have outdoor air, #{no_per_person_rates_loops} have a zone without per-person OA rates, #{constant_volume_doas_loops} are constant volume DOAS systems, #{ervs} have ERVs, #{ineligible_space_types} serve ineligible space types, and #{existing_dcv_loops} already have demand control ventilation enabled, leaving #{selected_air_loops.size} eligible for demand control ventilation.")

    if selected_air_loops.empty?
      runner.registerAsNotApplicable('Model does not contain air loops eligible for enabling demand control ventilation.')
      return true
    end

    # enable DCV on selected air loops
    enabled_dcv = 0
    total_cooling_capacity_w = 0
    total_airflow_m3_s = 0
    selected_air_loops.each do |air_loop_hvac|
      air_loop_hvac.thermalZones.sort.each do |zone|
        zone.spaces.each do |space|
          dsn_oa = space.designSpecificationOutdoorAir
          next if dsn_oa.empty?

          dsn_oa = dsn_oa.get

          # set design specification outdoor air objects to sum
          dsn_oa.setOutdoorAirMethod('Sum')

          # Get the space properties
          floor_area = space.floorArea * space.multiplier
          number_of_people = space.numberOfPeople * space.multiplier
          people_per_m2 = space.peoplePerFloorArea

          # Sum up the total OA from all sources
          oa_for_people_per_m2 = people_per_m2 * dsn_oa.outdoorAirFlowperPerson
          oa_for_floor_area_per_m2 = dsn_oa.outdoorAirFlowperFloorArea
          tot_oa_per_m2 = oa_for_people_per_m2 + oa_for_floor_area_per_m2
          tot_oa_cfm_per_ft2 = OpenStudio.convert(OpenStudio.convert(tot_oa_per_m2, 'm^3/s', 'cfm').get, '1/m^2', '1/ft^2').get
          tot_oa_cfm = floor_area * tot_oa_cfm_per_ft2

          # if space is ineligible type, convert all OA to per-area to avoid DCV being applied
          if space_types_no_dcv.any? { |i| space.spaceType.get.name.to_s.include? i } & !dsn_oa.outdoorAirFlowperPerson.zero?
            runner.registerInfo("Space '#{space.name}' is an ineligable space type but is on an air loop that serves other DCV-eligible spaces. Converting all outdoor air to per-area.")
            dsn_oa.setOutdoorAirFlowperPerson(0.0)
            dsn_oa.setOutdoorAirFlowperFloorArea(tot_oa_per_m2)
            next
          end

          # if both per-area and per-person are present, does not need to be modified
          if !dsn_oa.outdoorAirFlowperPerson.zero? & !dsn_oa.outdoorAirFlowperFloorArea.zero?
            next

          # if both are zero, skip space
          elsif dsn_oa.outdoorAirFlowperPerson.zero? & dsn_oa.outdoorAirFlowperFloorArea.zero?
            runner.registerInfo("Space '#{space.name}' has 0 outdoor air per-person and per-area rates. DCV may be still be applied to this air loop, but it will not function on this space.")
            next

          # if per-person or per-area values are zero, set to 10 cfm / person and allocate the rest to per-area
          elsif dsn_oa.outdoorAirFlowperPerson.zero? || dsn_oa.outdoorAirFlowperFloorArea.zero?
            # puts "========Before Per Person========="
            # puts "Per-person", dsn_oa.outdoorAirFlowperPerson * people_per_m2
            # puts "Per-area", dsn_oa.outdoorAirFlowperFloorArea
            # puts "Total OA", tot_oa_per_m2

            if dsn_oa.outdoorAirFlowperPerson.zero?
              runner.registerInfo("Space '#{space.name}' per-person outdoor air rate is 0. Using a minimum of 10 cfm / person and assigning the remaining space outdoor air requirement to per-area.")
            elsif dsn_oa.outdoorAirFlowperFloorArea.zero?
              runner.registerInfo("Space '#{space.name}' per-area outdoor air rate is 0. Using a minimum of 10 cfm / person and assigning the remaining space outdoor air requirement to per-area.")
            end

            # default ventilation is 10 cfm / person
            per_person_ventilation_rate = OpenStudio.convert(10, 'ft^3/min', 'm^3/s').get

            # assign remaining oa to per-area
            new_oa_for_people_per_m2 = people_per_m2 * per_person_ventilation_rate
            new_oa_for_people_cfm_per_f2 = OpenStudio.convert(OpenStudio.convert(new_oa_for_people_per_m2, 'm^3/s', 'cfm').get, '1/m^2', '1/ft^2').get
            new_oa_for_people_cfm = number_of_people * new_oa_for_people_cfm_per_f2
            remaining_oa_per_m2 = tot_oa_per_m2 - new_oa_for_people_per_m2
            if remaining_oa_per_m2 <= 0
              runner.registerInfo("Space '#{space.name}' has #{number_of_people.round(1)} people which corresponds to a ventilation minimum requirement of #{new_oa_for_people_cfm.round(0)} cfm at 10 cfm / person, but total zone outdoor air is only #{tot_oa_cfm.round(0)} cfm. Setting all outdoor air as per-person.")
              per_person_ventilation_rate = tot_oa_per_m2 / people_per_m2
              dsn_oa.setOutdoorAirFlowperFloorArea(0.0)
            else
              oa_per_area_per_m2 = remaining_oa_per_m2
              dsn_oa.setOutdoorAirFlowperFloorArea(oa_per_area_per_m2)
            end
            dsn_oa.setOutdoorAirFlowperPerson(per_person_ventilation_rate)

            # puts "========After Per Person========="
            # puts "Per-person", dsn_oa.outdoorAirFlowperPerson * people_per_m2
            # puts "Per-area", dsn_oa.outdoorAirFlowperFloorArea
            # puts "Total OA", dsn_oa.outdoorAirFlowperPerson * people_per_m2 + dsn_oa.outdoorAirFlowperFloorArea
          end

          # zero-out the ACH, and flow requirements
          # dsn_oa.setOutdoorAirFlowAirChangesperHour(0.0)
          # dsn_oa.setOutdoorAirFlowRate(0.0)
        end
      end

      std.air_loop_hvac_enable_demand_control_ventilation(air_loop_hvac, '')
      enabled_dcv += 1
    end

    # report final condition of model
    runner.registerFinalCondition("Enabled DCV for #{enabled_dcv} air loops in the model.")

    return true
  end
end

# register the measure to be used by the application
HVACDCV.new.registerWithApplication
