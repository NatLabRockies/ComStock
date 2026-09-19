# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
require 'comstock-typical'

# start the measure
class AddHvacNighttimeOperationVariability < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'add_hvac_nighttime_operation_variability'
  end

  # human readable description
  def description
    return 'Measure will set nighttime hvac operation behavior for fans and ventilation for PSZ and VAV systems. Fans can cycle  or run continuosly at night, and can do so with or without outdoor air ventilation.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'Measure will modify the fan and outdoor air behavior of PSZ and VAV systems during their nighttime operations through schedule changes. Options are 1) RTUs runs continuosly through the night, both fans and ventialtion, 2) RTUs shut off at night but cycle fans when needed to maintain zone thermostat loads with ventilation or 3)  RTUs shut off at night but cycle fans when needed to maintain zone thermostat loads without ventilation. A fourth option is possible where RTUs run continuously at night but ventilation shuts off during unoccupied hours, but this is unlikely in building operation and not recommended. '
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # make list of
    rtu_night_mode_options_li = ['night_fanon_vent', 'night_fancycle_vent', 'night_fancycle_novent', 'default_nochange']
    rtu_night_mode_options = OpenStudio::StringVector.new
    rtu_night_mode_options_li.each do |option|
      rtu_night_mode_options << option
    end

    rtu_night_mode = OpenStudio::Measure::OSArgument.makeChoiceArgument('rtu_night_mode', rtu_night_mode_options, true)
    rtu_night_mode.setDefaultValue('default_nochange')
    rtu_night_mode.setDisplayName('RTU Unoccupied Fan Behavior')
    rtu_night_mode.setDescription('This option will determine if the RTU fans run continuously through the night, or if they cycle at night only to meet thermostat requirements.')
    args << rtu_night_mode

    return args
  end

  # Determine if the air loop is a unitary system
  #
  # @return [Bool] Returns true if a unitary system is present, false if not.
  def air_loop_hvac_unitary_system?(air_loop_hvac)
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

  # determine if the air loop is residential (checks to see if there is outdoor air system object)
  def air_loop_res?(air_loop_hvac)
    is_res_system = true
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_AirLoopHVAC_OutdoorAirSystem'
        is_res_system = false
      end
    end
    return is_res_system
  end

  # Determine if the system is a DOAS based on
  # whether there is 100% OA in heating and cooling sizing.
  def air_loop_doas?(air_loop_hvac)
    is_doas = false
    sizing_system = air_loop_hvac.sizingSystem
    if sizing_system.allOutdoorAirinCooling && sizing_system.allOutdoorAirinHeating && (air_loop_res?(air_loop_hvac) == false) && air_loop_hvac.name.to_s.downcase.include?('doas')
      is_doas = true
    end
    return is_doas
  end

  # Determine if is evaporative cooler
  def air_loop_evaporative_cooler?(air_loop_hvac)
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
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # assign the user inputs to variables
    rtu_night_mode = runner.getStringArgumentValue('rtu_night_mode', user_arguments)

    # set na if 'no_change' was selected
    if rtu_night_mode == 'default_nochange'
      runner.registerAsNotApplicable("#{rtu_night_mode} was selected as the rtu night mode - no changes will be made to model as part of this measure.")
      return true
    end

    template = 'ComStock 90.1-2013'
    std = Standard.build(template)

    # loop through air loops
    unitary_system_count = 0
    li_unitary_systems = []
    non_unitary_system_count = 0
    li_non_unitary_systems = []
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      # skip systems that are residential, use evap coolers, or are DOAS
      next if air_loop_res?(air_loop_hvac)
      next if air_loop_evaporative_cooler?(air_loop_hvac)
      next if air_loop_doas?(air_loop_hvac)

      # skip data centers
      next if ['datacenter', 'data center'].any? { |word| air_loop_hvac.name.get.downcase.include?(word) }

      # check unitary systems
      if air_loop_hvac_unitary_system?(air_loop_hvac)
        unitary_system_count += 1
        li_unitary_systems << air_loop_hvac
      else
        li_non_unitary_systems << air_loop_hvac
        non_unitary_system_count += 1
      end
    end

    # report initial condition of model
    runner.registerInitialCondition("The building has #{unitary_system_count} unitary systems and #{non_unitary_system_count} non-unitary airloop systems applicable for nighttime operation changes. #{rtu_night_mode} is the selected nighttime operation mode.")

    if (non_unitary_system_count + unitary_system_count) < 1
      runner.registerAsNotApplicable('No applicable systems were found.')
      return true
    end

    oa_schd_1_count = 0
    oa_schd_op_count = 0
    op_schd_1_count = 0
    fan_schd_1_count = 0
    fan_sch_op_count = 0

    # adjust exhaust fan schedules
    # load lookup file and convert to hash table
    exhaust_fan_schedules_csv = "#{File.dirname(__FILE__)}/resources/exhaust_fan_schedules.csv"
    if !File.file?(exhaust_fan_schedules_csv)
      runner.registerError("Unable to find file: #{exhaust_fan_schedules_csv}")
      return nil
    end
    exhaust_fan_schedules_tbl = CSV.table(exhaust_fan_schedules_csv)
    exhaust_fan_schedules_hsh = exhaust_fan_schedules_tbl.map(&:to_hash)

    # loop through exhaust fans and change schedules
    model.getFanZoneExhausts.each do |exhaust_fan|
      # if the exhaust fan is a transfer air source, get the data for the target thermal zone instead
      if exhaust_fan.name.to_s.downcase.include?('transfer air source')
        target_thermal_zone_name = exhaust_fan.name.to_s.gsub(' Transfer Air Source', '')
        target_thermal_zone = model.getThermalZoneByName(target_thermal_zone_name)
        if target_thermal_zone.is_initialized
          target_thermal_zone = target_thermal_zone.get
          standards_building_type = OpenstudioStandards::ThermalZone.thermal_zone_get_building_type(target_thermal_zone)
          space_type = OpenstudioStandards::ThermalZone.thermal_zone_get_space_type(target_thermal_zone)
          runner.registerInfo("Exhaust fan #{exhaust_fan.name} is a Transfer Air Source. Looking up standards data for target zone #{target_thermal_zone.name} instead of exhaust fan zone #{exhaust_fan.thermalZone.get.name}.")
        else
          runner.registerWarning("Unable to find target thermal zone '#{target_thermal_zone_name}' for exhaust fan '#{exhaust_fan.name}'. Not adjusting '#{exhaust_fan.name}' schedule.")
          next
        end
      else
        thermal_zone = exhaust_fan.thermalZone
        next unless thermal_zone.is_initialized

        thermal_zone = thermal_zone.get
        standards_building_type = OpenstudioStandards::ThermalZone.thermal_zone_get_building_type(thermal_zone)
        space_type = OpenstudioStandards::ThermalZone.thermal_zone_get_space_type(thermal_zone)
      end
      if space_type.is_initialized
        space_type = space_type.get
        if space_type.standardsSpaceType.is_initialized
          standards_space_type = space_type.standardsSpaceType.get
        else
          runner.registerWarning("Unable to find standards space type for exhaust fan '#{exhaust_fan.name}'.")
          next
        end
      else
        runner.registerWarning("Unable to find space type for exhaust fan '#{exhaust_fan.name}'.")
        next
      end

      # lookup prototype space type
      sch_data = exhaust_fan_schedules_hsh.select { |r| (r[:building_type] == standards_building_type) && (r[:space_type] == standards_space_type) }
      if sch_data.empty?
        runner.registerWarning("Unable to find standards space type for '#{standards_building_type} - #{standards_space_type}'. Not adjusting exhaust fan '#{exhaust_fan.name}' schedule.")
        next
      end
      sch_data = sch_data[0]

      if sch_data[:exhaust_availability_schedule]
        exhaust_schedule = std.model_add_schedule(model, sch_data[:exhaust_availability_schedule])
        exhaust_fan.setAvailabilitySchedule(exhaust_schedule)
      end

      if sch_data[:exhaust_flow_fraction_schedule] && !exhaust_fan.name.to_s.downcase.include?('transfer air source')
        exhaust_flow_schedule = std.model_add_schedule(model, sch_data[:exhaust_flow_fraction_schedule])
        exhaust_fan.setFlowFractionSchedule(exhaust_flow_schedule)
      end

      if sch_data[:balanced_exhaust_fraction_schedule] && !exhaust_fan.name.to_s.downcase.include?('transfer air source')
        balanced_exhaust_schedule = std.model_add_schedule(model, sch_data[:balanced_exhaust_fraction_schedule])
        exhaust_fan.setBalancedExhaustFractionSchedule(balanced_exhaust_schedule)
        exhaust_fan.setPressureRise(1.0) # transfer air set pressure rise to negligable but non-zero value
      end
      runner.registerInfo("Exhaust fan '#{exhaust_fan.name}' schedule adjusted based on standards space type '#{standards_building_type} - #{standards_space_type}'.")
    end

    # make changes to unitary systems
    li_unitary_systems.sort.each do |air_loop_hvac|
      # change night OA schedule to match hvac operation schedule for no night OA
      case rtu_night_mode
      when 'night_fancycle_novent'
        # Schedule to control whether or not unit ventilates at night - clone hvac availability schedule
        next unless air_loop_hvac.availabilitySchedule.clone.to_ScheduleRuleset.is_initialized

        air_loop_vent_sch = air_loop_hvac.availabilitySchedule.clone.to_ScheduleRuleset.get
        air_loop_vent_sch.setName("#{air_loop_hvac.name}_night_novent_schedule")
        next unless air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized

        air_loop_oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
        next unless air_loop_oa_system.minimumOutdoorAirSchedule.is_initialized

        air_loop_oa_system.setMinimumOutdoorAirSchedule(air_loop_vent_sch)
        oa_schd_op_count += 1
      end

      # change night OA schedule to new schedule with constant value of 1
      case rtu_night_mode
      when 'night_fanon_vent', 'night_fancycle_vent'
        # Schedule to control whether or not unit ventilates at night
        air_loop_vent_sch = OpenStudio::Model::ScheduleConstant.new(model)
        air_loop_vent_sch.setName("#{air_loop_hvac.name}_night_ventcycle_schedule")
        air_loop_vent_sch.setValue(1)
        next unless air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized

        air_loop_oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
        next unless air_loop_oa_system.minimumOutdoorAirSchedule.is_initialized

        air_loop_oa_system.setMinimumOutdoorAirSchedule(air_loop_vent_sch)
        oa_schd_1_count += 1
      end

      # change fan operation schedule to new clone of hvac operation schedule to ensure night cycling of fans (removing any constant schedules)
      case rtu_night_mode
      when 'night_fancycle_novent', 'night_fancycle_vent'
        # Schedule to control whether or not unit ventilates at night - clone hvac availability schedule
        next unless air_loop_hvac.availabilitySchedule.to_ScheduleRuleset.is_initialized

        air_loop_fan_sch = air_loop_hvac.availabilitySchedule.clone.to_ScheduleRuleset.get
        air_loop_fan_sch.setName("#{air_loop_hvac.name}_night_fancycle_schedule")
        # Schedule to control the airloop fan operation schedule
        air_loop_hvac.supplyComponents.each do |component|
          obj_type = component.iddObjectType.valueName.to_s
          case obj_type
          when 'OS_AirLoopHVAC_UnitarySystem'
            component = component.to_AirLoopHVACUnitarySystem.get
            component.setSupplyAirFanOperatingModeSchedule(air_loop_fan_sch)
            fan_sch_op_count += 1
          when 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir'
            component = component.to_AirLoopHVACUnitaryHeatPump_AirToAir.get
            component.setSupplyAirFanOperatingModeSchedule(air_loop_fan_sch)
            fan_sch_op_count += 1
          when 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir_MultiSpeed'
            component = component.to_AirLoopHVACUnitaryHeatPumpAirToAirMultiSpeed.get
            component.setSupplyAirFanOperatingModeSchedule(air_loop_fan_sch)
            fan_sch_op_count += 1
          when 'OS_AirLoopHVAC_UnitaryHeatCool_VAVChangeoverBypass'
            component = component.to_AirLoopHVACUnitaryHeatCoolVAVChangeoverBypass.get
            component.setSupplyAirFanOperatingModeSchedule(air_loop_fan_sch)
            fan_sch_op_count += 1
          end
        end
      end

      # change HVAC operation schedule and fan availability schedule to new schedule with constant value of 1
      case rtu_night_mode
      when 'night_fanon_vent'
        # Schedule to control the airloop availability (HVAC Operation Schedule) and fan operation schedule
        air_loop_avail_sch = OpenStudio::Model::ScheduleConstant.new(model)
        air_loop_avail_sch.setName("#{air_loop_hvac.name}_constant_night_fan_schedule")
        air_loop_avail_sch.setValue(1)
        # State the type limits. The air loop availability and fan operating mode slots this
        # schedule goes into do not stamp them the way the OA controller's minimum outdoor
        # air slot stamps the vent schedule above, so without this EnergyPlus reports
        # "Schedule Type Limits Name is empty ... Schedule will not be validated" for it.
        air_loop_avail_sch.setScheduleTypeLimits(
          OpenstudioStandards::Schedules.create_schedule_type_limits(model, standard_schedule_type_limit: 'Fractional')
        )
        # set hvac avail schedule
        air_loop_hvac.setAvailabilitySchedule(air_loop_avail_sch)
        op_schd_1_count += 1

        # set unitary supply fan operation schedule - loop through air loop components to find unitary systems
        air_loop_hvac.supplyComponents.each do |component|
          obj_type = component.iddObjectType.valueName.to_s
          case obj_type
          when 'OS_AirLoopHVAC_UnitarySystem'
            component = component.to_AirLoopHVACUnitarySystem.get
            component.setSupplyAirFanOperatingModeSchedule(air_loop_avail_sch)
            fan_schd_1_count += 1
          when 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir'
            component = component.to_AirLoopHVACUnitaryHeatPump_AirToAir.get
            component.setSupplyAirFanOperatingModeSchedule(air_loop_avail_sch)
            fan_schd_1_count += 1
          when 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir_MultiSpeed'
            component = component.to_AirLoopHVACUnitaryHeatPumpAirToAirMultiSpeed.get
            component.setSupplyAirFanOperatingModeSchedule(air_loop_avail_sch)
            fan_schd_1_count += 1
          when 'OS_AirLoopHVAC_UnitaryHeatCool_VAVChangeoverBypass'
            component = component.to_AirLoopHVACUnitaryHeatCoolVAVChangeoverBypass.get
            component.setSupplyAirFanOperatingModeSchedule(air_loop_avail_sch)
            fan_schd_1_count += 1
          end
        end
      end
    end

    # make changes to non-unitary systems
    li_non_unitary_systems.sort.each do |air_loop_hvac|
      # change night OA schedule to match hvac operation schedule for no night OA
      case rtu_night_mode
      when 'night_fancycle_novent'
        # Schedule to control whether or not unit ventilates at night - clone hvac availability schedule
        next unless air_loop_hvac.availabilitySchedule.clone.to_ScheduleRuleset.is_initialized

        air_loop_vent_sch = air_loop_hvac.availabilitySchedule.clone.to_ScheduleRuleset.get
        air_loop_vent_sch.setName("#{air_loop_hvac.name}_night_novent_schedule")
        next unless air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized

        air_loop_oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
        next unless air_loop_oa_system.minimumOutdoorAirSchedule.is_initialized

        air_loop_oa_system.setMinimumOutdoorAirSchedule(air_loop_vent_sch)
        oa_schd_op_count += 1
      end

      # change night OA schedule to new schedule with constant value of 1
      case rtu_night_mode
      when 'night_fanon_vent', 'night_fancycle_vent'
        # Schedule to control whether or not unit ventilates at night
        air_loop_vent_sch = OpenStudio::Model::ScheduleConstant.new(model)
        air_loop_vent_sch.setName("#{air_loop_hvac.name}_night_ventcycle_schedule")
        air_loop_vent_sch.setValue(1)
        next unless air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized

        air_loop_oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
        next unless air_loop_oa_system.minimumOutdoorAirSchedule.is_initialized

        air_loop_oa_system.setMinimumOutdoorAirSchedule(air_loop_vent_sch)
        oa_schd_1_count += 1
      end

      # change HVAC operation schedule and fan availability schedule to new schedule with constant value of 1
      case rtu_night_mode
      when 'night_fanon_vent'
        # Schedule to control the airloop availability (HVAC Operation Schedule) and fan operation schedule
        air_loop_avail_sch = OpenStudio::Model::ScheduleConstant.new(model)
        air_loop_avail_sch.setName("#{air_loop_hvac.name}_constant_night_fan_schedule")
        air_loop_avail_sch.setValue(1)
        # State the type limits. The air loop availability and fan operating mode slots this
        # schedule goes into do not stamp them the way the OA controller's minimum outdoor
        # air slot stamps the vent schedule above, so without this EnergyPlus reports
        # "Schedule Type Limits Name is empty ... Schedule will not be validated" for it.
        air_loop_avail_sch.setScheduleTypeLimits(
          OpenstudioStandards::Schedules.create_schedule_type_limits(model, standard_schedule_type_limit: 'Fractional')
        )
        # set hvac avail schedule
        air_loop_hvac.setAvailabilitySchedule(air_loop_avail_sch)
        op_schd_1_count += 1
      end
    end

    # report final condition of model
    runner.registerFinalCondition("#{oa_schd_1_count} outdoor air shedules have been changed to contant one schedules for night ventilation (cycling or constant). #{oa_schd_op_count} outdoor air schedules have been changed to match the air loop operation schedule to remove night ventilation. #{op_schd_1_count} air loop operation schedules have been changed to a contant value of one for contant night fan operation. #{fan_schd_1_count} fan operation schedules (unitary systems only) have been changed to a contant value of one for contant night fan operation. #{fan_sch_op_count} fan operation schedules have been changed to match the air loop operation schedule to ensure night cycling.")
    return true
  end
end

# register the measure to be used by the application
AddHvacNighttimeOperationVariability.new.registerWithApplication
