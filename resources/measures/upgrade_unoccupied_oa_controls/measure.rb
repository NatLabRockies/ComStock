# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

class UnoccupiedOAControls < OpenStudio::Measure::ModelMeasure
  require 'comstock-typical'
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'Unoccupied OA Controls'
  end

  # human readable description
  def description
    return 'This measure sets minimum outdoor airflow to zero during extended periods of no occupancy (nighttime and weekends). Fans cycle during these unoccupied periods to meet the thermostat setpoints.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'This measure ensures that the minimum outdoor air schedule aligns with the occupancy schedule of the building, so that fans cycling during unoccupied hours do not bring in outdoor air for ventilation. If the mininum OA schedule has been changed to a constant schedule through the nighttime operation variability measure, this measure reverts that. This measure continues to allow for air-side economizing during unoccupied hours, since it is only the minimum outdoor air level being modified.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    return args
  end

  # Determine if the air loop is a unitary system
  # @return [Bool] Returns true if a unitary system is present, false if not.
  def self.air_loop_hvac_unitary_system?(air_loop_hvac)
    is_unitary_system = false
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_AirLoopHVAC_UnitarySystem', 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir', 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir_MultiSpeed', 'OS_AirLoopHVAC_UnitaryHeatCool_VAVChangeoverBypass'
        is_unitary_system = true
      end
    end
    return is_unitary_system
  end

  def no_change_zones?(air_loop_hvac)
    selected_air_loops = []
    # Space types this measure leaves alone, in the typical (all-level) space type vocabulary:
    # kitchens, laboratories and patient care spaces. Prototype space type names resolve to these
    # through the prototype space type crosswalk.
    space_types_no_change = [
      'food preparation',
      'patient room',
      'laboratory',
      'exam/treatment',
      'corridor - hospital',
      'operating room',
      'emergency room',
      'physical therapy'
    ]
    # Building types this measure leaves alone: healthcare, schools and hotels, by their ASHRAE and
    # DEER standards building type names. The prototype list matched these words in space type
    # names, which carry the building type on the prototype path only.
    building_types_no_change = /hospital|outpatient|school|hotel|\A(epr|ese|eun|ecc|hsp|nrs|htl|mtl)\z/i
    legacy_space_type_names_no_change = /outpatient|hospital|epr|school|k12|education|hotel|doas/i

    # skip DOAS loops, and buildings this measure does not apply to
    return true if air_loop_hvac.name.to_s =~ /doas/i
    building = air_loop_hvac.model.getBuilding
    if building.standardsBuildingType.is_initialized && building.standardsBuildingType.get.to_s =~ building_types_no_change
      return true
    end

    # check to see if airloop has applicable space types
    # exclude these space types: kitchens, laboratories, patient care rooms
    space_types_no_change_count = 0
    air_loop_hvac.thermalZones.sort.each do |zone|
      zone.spaces.each do |space|
        next if space.spaceType.empty?

        space_type = space.spaceType.get
        if OpenstudioStandards::SpaceType.space_type_matches?(space_type, space_types_no_change) || space_type.name.to_s =~ legacy_space_type_names_no_change
          space_types_no_change_count += 1
        end
      end
    end
    if space_types_no_change_count >= 1
      return true
    end

    return false
  end

  # determine if the air loop is residential (checks to see if there is outdoor air system object)
  def self.air_loop_res?(air_loop_hvac)
    is_res_system = true
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
	  next unless obj_type == 'OS_AirLoopHVAC_OutdoorAirSystem'
      is_res_system = false
    end
    return is_res_system
  end

  # Determine if the system is a DOAS based on
  # whether there is 100% OA in heating and cooling sizing.
  def self.air_loop_doas?(air_loop_hvac)
    is_doas = false
    sizing_system = air_loop_hvac.sizingSystem
    if sizing_system.allOutdoorAirinCooling && sizing_system.allOutdoorAirinHeating && (UnoccupiedOAControls.air_loop_res?(air_loop_hvac) == false) && (air_loop_hvac.name.to_s.include?("DOAS") || air_loop_hvac.name.to_s.include?("doas"))
      is_doas = true
    end
    return is_doas
  end

  # Determine if is evaporative cooler
  def self.air_loop_evaporative_cooler?(air_loop_hvac)
    is_evap = false
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_EvaporativeCooler_Direct_ResearchSpecial', 'OS_EvaporativeCooler_Indirect_ResearchSpecial', 'OS_EvaporativeFluidCooler_SingleSpeed', 'OS_EvaporativeFluidCooler_TwoSpeed'
        is_evap = true
      end
    end
    return is_evap
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments) # Do **NOT** remove this line

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end


    template = 'ComStock 90.1-2013'
    std = Standard.build(template)

    # loop through air loop
    li_unitary_systems = []
    li_non_unitary_systems = []
    constant_schedules = 0 # Counter for constant schedules in the model
    # Assess measure applicabilty
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      # skip systems that are residential, or are DOAS or evaporative coolers
      next if UnoccupiedOAControls.air_loop_res?(air_loop_hvac)
      next if UnoccupiedOAControls.air_loop_evaporative_cooler?(air_loop_hvac)
      next if UnoccupiedOAControls.air_loop_doas?(air_loop_hvac)
      # skip outpatient healthcare, hospitals, and schools
      next if no_change_zones?(air_loop_hvac) # screen out space types this shouldn't be applied to

      # check unitary systems
      if UnoccupiedOAControls.air_loop_hvac_unitary_system?(air_loop_hvac)
        li_unitary_systems << air_loop_hvac
      else
        li_non_unitary_systems << air_loop_hvac
      end
      # check min oa for constant schedules
      air_loop_oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
      if air_loop_oa_system.minimumOutdoorAirSchedule.get.to_ScheduleConstant.is_initialized
        constant_schedules = constant_schedules + 1
      end
      # check air loop availability for constant schedules
      avail_sched = air_loop_hvac.availabilitySchedule # got an error checking this for initialization
      if avail_sched.to_ScheduleConstant.is_initialized
        constant_schedules = constant_schedules + 1
      end
      # among unitary systems, check supply fan operating mode for constant schedules
      if UnoccupiedOAControls.air_loop_hvac_unitary_system?(air_loop_hvac)
        air_loop_hvac.supplyComponents.each do |component|
          obj_type = component.iddObjectType.valueName.to_s
          case obj_type
          when 'OS_AirLoopHVAC_UnitarySystem'
            component = component.to_AirLoopHVACUnitarySystem.get
          when 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir'
            component = component.to_AirLoopHVACUnitaryHeatPump_AirToAir.get
          when 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir_MultiSpeed'
            component = component.to_AirLoopHVACUnitaryHeatPumpAirToAirMultiSpeed.get
          when 'OS_AirLoopHVAC_UnitaryHeatCool_VAVChangeoverBypass'
            component = component.to_AirLoopHVACUnitaryHeatCoolVAVChangeoverBypass.get
            component.getSupplyAirFanOperatingModeSchedule
            if setMinimumOutdoorAirSchedule.to_ScheduleConstant.is_initialized
              constant_schedules = constant_schedules + 1
            end
          end
        end
      end
    end

    if constant_schedules == 0
      runner.registerAsNotApplicable('No constant HVAC operation schedules or no candidate air loops found--measure not applicable.')
      return true
    end


    if (li_unitary_systems.size + li_non_unitary_systems.size) < 1
      runner.registerAsNotApplicable('No applicable systems were found.')
      return true
    end

    # make changes to unitary systems
    # need to deal with non unitary systems, too
    li_unitary_systems.sort.each do |air_loop_hvac|
      # change night OA schedule to match hvac operation schedule for no night OA
      # Schedule to control whether or not unit ventilates at night - clone hvac availability schedule
      if air_loop_hvac.availabilitySchedule.clone.to_ScheduleRuleset.is_initialized
        air_loop_vent_sch = air_loop_hvac.availabilitySchedule.clone.to_ScheduleRuleset.get
        air_loop_vent_sch.setName("#{air_loop_hvac.name}_night_novent_schedule")
      end
      if air_loop_hvac.availabilitySchedule.clone.to_ScheduleConstant.is_initialized
        sch_ruleset = OpenstudioStandards::ThermalZone.thermal_zones_get_occupancy_schedule(thermal_zones = air_loop_hvac.thermalZones,
                                                               occupied_percentage_threshold: 0.05)
        # set air loop availability controls and night cycle manager, after oa system added
        sch_ruleset.setName("#{air_loop_hvac.name}_night_fancycle_novent_schedule")
        air_loop_hvac.setAvailabilitySchedule(sch_ruleset)
        air_loop_hvac.setNightCycleControlType('CycleOnAny')
        air_loop_vent_sch = sch_ruleset
      end
      if air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized
        air_loop_oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
        air_loop_oa_system.setMinimumOutdoorAirSchedule(air_loop_vent_sch)
      end

      # change fan operation schedule to new clone of hvac operation schedule to ensure night cycling of fans (removing any constant schedules)
      # Schedule to control whether or not unit ventilates at night - clone hvac availability schedule
      # Schedule to control the airloop fan operation schedule
      air_loop_hvac.supplyComponents.each do |component|
        obj_type = component.iddObjectType.valueName.to_s
        case obj_type
        when 'OS_AirLoopHVAC_UnitarySystem'
          component = component.to_AirLoopHVACUnitarySystem.get
          component.setSupplyAirFanOperatingModeSchedule(air_loop_vent_sch)
        when 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir'
          component = component.to_AirLoopHVACUnitaryHeatPump_AirToAir.get
          component.setSupplyAirFanOperatingModeSchedule(air_loop_vent_sch)
        when 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir_MultiSpeed'
          component = component.to_AirLoopHVACUnitaryHeatPumpAirToAirMultiSpeed.get
          component.setSupplyAirFanOperatingModeSchedule(air_loop_vent_sch)
        when 'OS_AirLoopHVAC_UnitaryHeatCool_VAVChangeoverBypass'
          component = component.to_AirLoopHVACUnitaryHeatCoolVAVChangeoverBypass.get
          component.setSupplyAirFanOperatingModeSchedule(air_loop_vent_sch)
        end
      end
    end

    # handle non-unitary systems
    li_non_unitary_systems.sort.each do |air_loop_hvac|
      # change night OA schedule to match hvac operation schedule for no night OA
      # case rtu_night_mode
      # when 'night_fancycle_novent'
      # Schedule to control whether or not unit ventilates at night - clone hvac availability schedule
      if air_loop_hvac.availabilitySchedule.clone.to_ScheduleRuleset.is_initialized
        air_loop_vent_sch = air_loop_hvac.availabilitySchedule.clone.to_ScheduleRuleset.get
        air_loop_vent_sch.setName("#{air_loop_hvac.name}_night_novent_schedule")
      end
      if air_loop_hvac.availabilitySchedule.clone.to_ScheduleConstant.is_initialized # handle constant schedule
        sch_ruleset = OpenstudioStandards::ThermalZone.thermal_zones_get_occupancy_schedule(thermal_zones = air_loop_hvac.thermalZones,
                                                               occupied_percentage_threshold: 0.05)
        # set air loop availability controls and night cycle manager, after oa system added
        air_loop_hvac.setAvailabilitySchedule(sch_ruleset)
        air_loop_hvac.setNightCycleControlType('CycleOnAny')
        sch_ruleset.setName("#{air_loop_hvac.name}_night_fancycle_novent_schedule")
        air_loop_vent_sch = sch_ruleset
      end
      next unless air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized
      air_loop_oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
      air_loop_oa_system.setMinimumOutdoorAirSchedule(air_loop_vent_sch)
    end

    return true
  end
end

# register the measure to be used by the application
UnoccupiedOAControls.new.registerWithApplication
