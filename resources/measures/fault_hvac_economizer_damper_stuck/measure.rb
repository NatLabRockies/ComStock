# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

require 'date'
require 'comstock-typical'

# start the measure
class FaultHvacEconomizerDamperStuck < OpenStudio::Ruleset::ModelUserScript
  # define the name that a user will see, this method may be deprecated as
  # the display name in PAT comes from the name field in measure.xml
  def name
    return 'fault hvac economizer damper stuck'
  end

  def description
    return 'TBD'
  end

  def modeler_description
    return 'TBD'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Ruleset::OSArgumentVector.new

    # make choice arguments for economizers
    controlleroutdoorairs = model.getControllerOutdoorAirs
    chs = OpenStudio::StringVector.new
    chs << 'all available economizer'
    controlleroutdoorairs.each do |controlleroutdoorair|
      chs << controlleroutdoorair.name.to_s
    end
    econ_choice = OpenStudio::Ruleset::OSArgument.makeChoiceArgument('econ_choice', chs, true)
    econ_choice.setDisplayName("Choice of economizers. If you want to impose the fault on all economizers, choose 'all available economizer'")
    econ_choice.setDefaultValue('all available economizer')
    args << econ_choice

    # make a double argument for fault start month
    start_month = OpenStudio::Ruleset::OSArgument.makeIntegerArgument('start_month', false)
    start_month.setDisplayName('Month when faulted behavior starts.')
    start_month.setDefaultValue(1)
    args << start_month

    # make a double argument for fault start day
    start_day = OpenStudio::Ruleset::OSArgument.makeIntegerArgument('start_day', false)
    start_day.setDisplayName('Day of month when faulted behavior starts.')
    start_day.setDefaultValue(1)
    args << start_day

    # make a double argument for fault duration
    duration_days = OpenStudio::Ruleset::OSArgument.makeIntegerArgument('duration_days', false)
    duration_days.setDisplayName('Duration of faulted behavior in days.')
    duration_days.setDefaultValue(365)
    args << duration_days

    # make a double argument for the damper position
    damper_pos = OpenStudio::Ruleset::OSArgument.makeDoubleArgument('damper_pos', false)
    damper_pos.setDisplayName('The position of damper indicated between 0 and 1. Currently, only works for fully closed. Other values have implications.')
    damper_pos.setDefaultValue(0.0)
    args << damper_pos

    # apply/not-apply measure
    apply_measure = OpenStudio::Measure::OSArgument.makeBoolArgument('apply_measure', true)
    apply_measure.setDisplayName('Apply measure?')
    apply_measure.setDescription('')
    apply_measure.setDefaultValue(true)
    args << apply_measure

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # obtain input arguments
    econ_choice = runner.getStringArgumentValue('econ_choice', user_arguments)
    damper_pos = runner.getDoubleArgumentValue('damper_pos', user_arguments)
    start_month = runner.getIntegerArgumentValue('start_month', user_arguments)
    start_day = runner.getIntegerArgumentValue('start_day', user_arguments)
    duration_days = runner.getIntegerArgumentValue('duration_days', user_arguments)
    apply_measure = runner.getBoolArgumentValue('apply_measure', user_arguments)

    # get fault end date
    date_start = Date.new(2019, start_month, start_day)
    start_doy = date_start.yday
    date_end = date_start + duration_days
    start_doy = date_start.yday
    end_doy = date_end.yday
    # puts("--- fault start date = #{date_start} | #{start_doy} days from JAN 1st")
    # puts("--- duration = #{duration_days} days")
    # puts("--- fault end date = #{date_end} | #{end_doy} days from JAN 1st")

    # check if the damper position is between 0 and 1
    if damper_pos < 0.0 || damper_pos > 1.0
      runner.registerError("Damper position must be between 0 and 1 and it is now #{damper_pos}!")
      return false
    end

    # adding output variables (for debugging)
    # ov_eco_status = OpenStudio::Model::OutputVariable.new("debugging_ecostatus",model)
    # ov_eco_status.setKeyValue("*")
    # ov_eco_status.setReportingFrequency("timestep")
    # ov_eco_status.setVariableName("Air System Outdoor Air Economizer Status")

    # ov_oa_fraction = OpenStudio::Model::OutputVariable.new("debugging_ov_oafraction",model)
    # ov_oa_fraction.setKeyValue("*")
    # ov_oa_fraction.setReportingFrequency("timestep")
    # ov_oa_fraction.setVariableName("Air System Outdoor Air Flow Fraction")

    # ov_oa_mdot = OpenStudio::Model::OutputVariable.new("debugging_oamdot",model)
    # ov_oa_mdot.setKeyValue("*")
    # ov_oa_mdot.setReportingFrequency("timestep")
    # ov_oa_mdot.setVariableName("Air System Outdoor Air Mass Flow Rate")

    # ov_oat = OpenStudio::Model::OutputVariable.new("debugging_oat",model)
    # ov_oat.setKeyValue("*")
    # ov_oat.setReportingFrequency("timestep")
    # ov_oat.setVariableName("Site Outdoor Air Drybulb Temperature")

    # ov_coil_cooling = OpenStudio::Model::OutputVariable.new("debugging_cooling",model)
    # ov_coil_cooling.setKeyValue("*")
    # ov_coil_cooling.setReportingFrequency("timestep")
    # ov_coil_cooling.setVariableName("Cooling Coil Total Cooling Rate")

    # applicability check
    # don't apply measure if specified in input
    if apply_measure == false
      runner.registerAsNotApplicable('Measure is not applied based on user input.')
      return true
    end
    no_outdoor_air_loops = 0
    doas_loops = 0
    existing_economizer_loops = 0
    selected_air_loops = []
    model.getAirLoopHVACs.each do |air_loop_hvac|
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem
      if oa_system.is_initialized
        oa_system = oa_system.get
      else
        no_outdoor_air_loops += 1
        runner.registerInfo("Air loop #{air_loop_hvac.name} does not have outdoor air and cannot economize.")
        next
      end

      sizing_system = air_loop_hvac.sizingSystem
      type_of_load = sizing_system.typeofLoadtoSizeOn
      if type_of_load == 'VentilationRequirement'
        doas_loops += 1
        runner.registerInfo("Air loop #{air_loop_hvac.name} is a DOAS system and cannot economize.")
        next
      end

      oa_controller = oa_system.getControllerOutdoorAir
      economizer_type = oa_controller.getEconomizerControlType
      if economizer_type == 'NoEconomizer'
        runner.registerInfo("Air loop #{air_loop_hvac.name} does not have an existing economizer. This measure will skip this air loop.")
      else
        existing_economizer_loops += 1
        runner.registerInfo("Air loop #{air_loop_hvac.name} has an applicable #{economizer_type} economizer. This measure will impose fault to the economizer in this air loop.")
        selected_air_loops << air_loop_hvac
      end
    end

    # report initial condition of model
    runner.registerInitialCondition("Out of #{model.getAirLoopHVACs.size} air loops, #{no_outdoor_air_loops} do not have outdoor air, #{doas_loops} are DOAS systems, and #{existing_economizer_loops} have existing economizers. Leaving #{selected_air_loops.size} economizers applicable.")
    if selected_air_loops.empty?
      runner.registerAsNotApplicable('Model contains no air loops eligible for adding an outdoor air economizer.')
      return true
    end
    # build standard to access methods
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)

    # apply fault only to applicable economizers
    if (damper_pos >= 0.0) || (damper_pos <= 1.0)

      runner.registerInitialCondition("Fixing #{econ_choice} damper position to #{(damper_pos * 100).round}% open")

      # find the economizer to change
      # loop through air loops
      count_eco = 0
      selected_air_loops.each do |selected_air_loop|
        controlleroutdoorair = selected_air_loop.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
        if controlleroutdoorair.name.to_s.eql?(econ_choice) || econ_choice.eql?('all available economizer')

          runner.registerInfo("Modifying the economizer called #{controlleroutdoorair.name}")

          # create dummy min/max OA fraction schedules (meant for fault incidence) if there aren't any existing schedules
          identifier_ctrloa = OpenstudioStandards::HVAC.ems_friendly_name(controlleroutdoorair.name.to_s)
          sch_fraction_oa_min_type = nil
          sch_fraction_oa_max_type = nil
          if controlleroutdoorair.minimumFractionofOutdoorAirSchedule.empty?
            sch_fraction_oa_min = OpenStudio::Model::ScheduleConstant.new(model)
            sch_fraction_oa_min.setName("FRAC_OA_MIN_#{identifier_ctrloa}")
            sch_fraction_oa_min.setValue(0.0)
            sch_fraction_oa_min_type = 'Schedule:Constant'
          else
            sch_fraction_oa_min = controlleroutdoorair.minimumFractionofOutdoorAirSchedule.get
            sch_fraction_oa_min.setName("FRAC_OA_MIN_#{identifier_ctrloa}")
            if sch_fraction_oa_min.to_ScheduleRuleset.is_initialized
              sch_fraction_oa_min_type = 'Schedule:Year'
            elsif sch_fraction_oa_min.to_ScheduleConstant.is_initialized
              sch_fraction_oa_min_type = 'Schedule:Constant'
            elsif sch_fraction_oa_min.to_ScheduleCompact.is_initialized
              sch_fraction_oa_min_type = 'Schedule:Compact'
            end
          end
          if controlleroutdoorair.maximumFractionofOutdoorAirSchedule.empty?
            sch_fraction_oa_max = OpenStudio::Model::ScheduleConstant.new(model)
            sch_fraction_oa_max.setName("FRAC_OA_MAX_#{identifier_ctrloa}")
            sch_fraction_oa_max.setValue(1.0)
            sch_fraction_oa_max_type = 'Schedule:Constant'
          else
            sch_fraction_oa_max = controlleroutdoorair.maximumFractionofOutdoorAirSchedule.get
            sch_fraction_oa_max.setName("FRAC_OA_MAX_#{identifier_ctrloa}")
            if sch_fraction_oa_max.to_ScheduleRuleset.is_initialized
              sch_fraction_oa_max_type = 'Schedule:Year'
            elsif sch_fraction_oa_max.to_ScheduleConstant.is_initialized
              sch_fraction_oa_max_type = 'Schedule:Constant'
            elsif sch_fraction_oa_max.to_ScheduleCompact.is_initialized
              sch_fraction_oa_max_type = 'Schedule:Compact'
            end
          end

          # check economizer control type
          controltype = controlleroutdoorair.getEconomizerControlType
          if controltype.eql?('NoEconomizer')
            runner.registerAsNotApplicable("#{econ_choice} does not have an economizer. Skipping......")
            break
          end

          # apply faulted schedules to min/max outdoor air fraction
          if (start_month == 1) && (start_day == 1) && (duration_days == 365)
            runner.registerInfo('whole year selected for fault incidence')

            # create a schedule that the economizer is fixed at the damper_pos for the entire simulation period
            faultschedule = OpenStudio::Model::ScheduleRuleset.new(model)
            faultschedule.setName("damper_stuck_whole_yr_#{identifier_ctrloa}")
            faultscheduledefault = faultschedule.defaultDaySchedule
            faultscheduledefault.clearValues
            faultscheduledefault.addValue(OpenStudio::Time.new(0, 24, 0, 0), damper_pos)
            faultscheduledefault.setName("damper_stuck_whole_yr_default_#{identifier_ctrloa}")

            # set the faulted damper schedule
            controlleroutdoorair.setMinimumFractionofOutdoorAirSchedule(faultschedule)
            controlleroutdoorair.setMaximumFractionofOutdoorAirSchedule(faultschedule)

          else
            runner.registerInfo('partial period selected for fault incidence')

            # assign dummy schedule to controller:outdoorair
            controlleroutdoorair.setMinimumFractionofOutdoorAirSchedule(sch_fraction_oa_min)
            controlleroutdoorair.setMaximumFractionofOutdoorAirSchedule(sch_fraction_oa_max)

            # create EMS actuator object
            ema_actuator_frac_oa_min = OpenStudio::Model::EnergyManagementSystemActuator.new(sch_fraction_oa_min, sch_fraction_oa_min_type, 'Schedule Value')
            ema_actuator_frac_oa_min.setName("sch_fraction_oa_min_#{identifier_ctrloa}")

            # create EMS actuator object
            ema_actuator_frac_oa_max = OpenStudio::Model::EnergyManagementSystemActuator.new(sch_fraction_oa_max, sch_fraction_oa_max_type, 'Schedule Value')
            ema_actuator_frac_oa_max.setName("sch_fraction_oa_max_#{identifier_ctrloa}")

            # create new EnergyManagementSystem:Program object
            ems_program_sch_override = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
            ems_program_sch_override.setName('DamperStuckOverride')
            ems_program_sch_override.addLine("IF (DayOfYear >= #{start_doy}) && (DayOfYear < #{end_doy})")
            ems_program_sch_override.addLine("SET #{ema_actuator_frac_oa_min.name} = #{damper_pos}")
            ems_program_sch_override.addLine("SET #{ema_actuator_frac_oa_max.name} = #{damper_pos}")
            ems_program_sch_override.addLine('ELSE')
            ems_program_sch_override.addLine("SET #{ema_actuator_frac_oa_min.name} = Null")
            ems_program_sch_override.addLine("SET #{ema_actuator_frac_oa_max.name} = Null")
            ems_program_sch_override.addLine('ENDIF')

            # create new EnergyManagementSystem:ProgramCallingManager object
            ems_program_calling_mngr = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
            ems_program_calling_mngr.setName('DamperStuckOverrideCallMngr')
            ems_program_calling_mngr.setCallingPoint('AfterPredictorBeforeHVACManagers')
            ems_program_calling_mngr.addProgram(ems_program_sch_override)

            # create OutputEnergyManagementSystem object
            # output_EMS = model.getOutputEnergyManagementSystem
            # output_EMS.setInternalVariableAvailabilityDictionaryReporting('internal_variable_availability_dictionary_reporting')
            # output_EMS.setEMSRuntimeLanguageDebugOutputLevel('ems_runtime_language_debug_output_level')
            # output_EMS.setActuatorAvailabilityDictionaryReporting('actuator_availability_dictionary_reporting')

            # create output variables for reporting on EMS actuated objects
            # puts("*** creating output variable from EMS: sch_fraction_oa_variable_min")
            sch_fraction_oa_variable_min = OpenStudio::Model::OutputVariable.new('Schedule Value', model)
            sch_fraction_oa_variable_min.setReportingFrequency('timestep')
            sch_name = sch_fraction_oa_min.name.to_s
            sch_fraction_oa_variable_min.setKeyValue(sch_name)
            sch_fraction_oa_variable_min.setVariableName('Schedule Value')

            # create output variables for reporting on EMS actuated objects
            # puts("*** creating output variable from EMS: sch_fraction_oa_variable_max")
            sch_fraction_oa_variable_max = OpenStudio::Model::OutputVariable.new('Schedule Value', model)
            sch_fraction_oa_variable_max.setReportingFrequency('timestep')
            sch_name = sch_fraction_oa_max.name.to_s
            sch_fraction_oa_variable_max.setKeyValue(sch_name)
            sch_fraction_oa_variable_max.setVariableName('Schedule Value')

          end
          count_eco += 1
        end
      end
    else
      runner.registerAsNotApplicable("#{name} is not running for #{econ_choice}. Skipping......")
    end

    runner.registerFinalCondition("Out of #{model.getAirLoopHVACs.size} air loops, #{no_outdoor_air_loops} do not have outdoor air, #{doas_loops} are DOAS systems, and #{existing_economizer_loops} have existing economizers. From #{selected_air_loops.size} eligible economizers, #{count_eco} economizers are imposed with fault where damper is stuck at #{(damper_pos * 100).round}% open position. Fault imposed to the model starting from #{date_start} and lasted for #{duration_days} days.")

    return true
  end
end

# this allows the measure to be use by the application
FaultHvacEconomizerDamperStuck.new.registerWithApplication
