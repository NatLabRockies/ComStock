# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.


# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

# start the measure
class AddThermostatSetpointVariability < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'add_thermostat_setpoint_variability'
  end

  # human readable description
  def description
    return 'Measure will alter the models current thermostat setpoint and setback behavior. If user selects no_setback, the measure will remove heating and cooling thermostat setbacks if they exist. If the user selects setback, the model will add setbacks if none exist. The measure will also alter a models setpoint and setback delta based on user-input values. MEASURE SHOULD BE USED WITH SQUARE-WAVE SCHEDULES ONLY.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'Measure will alter the models current thermostat setpoint and setback behavior. If user selects no_setback, the measure will remove heating and cooling thermostat setbacks if they exist. If the user selects setback, the model will add setbacks if none exist. The measure will also alter a models setpoint and setback delta based on user-input values. MEASURE SHOULD BE USED WITH SQUARE-WAVE SCHEDULES ONLY. '
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # make an argument for occupied cooling setpoint
    clg_sp_f = OpenStudio::Measure::OSArgument.makeDoubleArgument('clg_sp_f', true)
    clg_sp_f.setDefaultValue('999')
    clg_sp_f.setDisplayName('Cooling Thermostat Occupied Setpoint')
    clg_sp_f.setDescription('Enter 999 for no change to setpoint.')
    clg_sp_f.setUnits('F')
    args << clg_sp_f

    # make an argument for cooling setback
    clg_delta_f = OpenStudio::Measure::OSArgument.makeDoubleArgument('clg_delta_f', true)
    clg_delta_f.setDefaultValue('999')
    clg_delta_f.setDisplayName('Cooling Thermostat Delta Setback')
    clg_delta_f.setDescription('Enter 999 for no change to setback.')
    clg_delta_f.setUnits('F')
    clg_delta_f.setMinValue(0)
    args << clg_delta_f

    # make an argument for occuped heating setpoint
    htg_sp_f = OpenStudio::Measure::OSArgument.makeDoubleArgument('htg_sp_f', true)
    htg_sp_f.setDefaultValue('999')
    htg_sp_f.setDisplayName('Heating Thermostat Occupied Setpoint')
    htg_sp_f.setDescription('Enter 999 for no change to setpoint.')
    htg_sp_f.setUnits('F')
    args << htg_sp_f

    # make an argument for heating setback
    htg_delta_f = OpenStudio::Measure::OSArgument.makeDoubleArgument('htg_delta_f', true)
    htg_delta_f.setDefaultValue('999')
    htg_delta_f.setDisplayName('Heating Thermostat Delta Setback')
    htg_delta_f.setDescription('Enter 999 for no change to setback.')
    htg_delta_f.setUnits('F')
    htg_delta_f.setMinValue(0)
    args << htg_delta_f

    return args
  end

  # get tstat schedule info
  def get_tstat_profiles_and_stats(tstat_schedule)
    if tstat_schedule.to_ScheduleRuleset.empty?
      runner.registerWarning("Schedule '#{tstat_schedule.name.get}' is not a ScheduleRuleset, will not be adjusted")
      return false
    else
      tstat_schedule = tstat_schedule.to_ScheduleRuleset.get

      profiles = [tstat_schedule.defaultDaySchedule]
      tstat_schedule.scheduleRules.each { |rule| profiles << rule.daySchedule }

      values = []
      profiles.each { |profile| values << profile.values }
      values = values.flatten
      sch_min = values.min
      sch_max = values.max
      num_vals = values.uniq.size
      return { profiles: profiles, values: values, min: sch_min, max: sch_max, num_vals: num_vals }
    end
  end

  # setpoint limits
  CLG_MAX_F = 100
  CLG_MAX_C = OpenStudio.convert(CLG_MAX_F, 'F', 'C').get
  HTG_MIN_F = 32
  HTG_MIN_C = OpenStudio.convert(HTG_MIN_F, 'F', 'C').get

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # assign the user inputs to variables
    clg_sp_f = runner.getDoubleArgumentValue('clg_sp_f', user_arguments)
    clg_delta_f = runner.getDoubleArgumentValue('clg_delta_f', user_arguments)
    htg_sp_f = runner.getDoubleArgumentValue('htg_sp_f', user_arguments)
    htg_delta_f = runner.getDoubleArgumentValue('htg_delta_f', user_arguments)

    # turn no-op args into bools
    adjust_clg_setpt = (clg_sp_f != 999)
    adjust_clg_setback = (clg_delta_f != 999)
    adjust_cooling = adjust_clg_setpt || adjust_clg_setback

    adjust_htg_setpt = (htg_sp_f != 999)
    adjust_htg_setback = (htg_delta_f != 999)
    adjust_heating = adjust_htg_setpt || adjust_htg_setback

    if !adjust_cooling && !adjust_heating
      runner.registerAsNotApplicable('All arguments are set to 999 which registers no change to model.')
      return true
    end

    # Write 'As Not Applicable' message
    if model.getThermalZones.empty?
      runner.registerAsNotApplicable('There are no thermal zones in the model. Measure is not applicable.')
      return true
    end

    # check inputs for reasonableness
    if adjust_clg_setpt && clg_sp_f < HTG_MIN_F
      runner.registerError("User-input cooling setpoint #{clg_sp_f} is less than minimum allowed heating setpoint of #{HTG_MIN_F}. Check input.")
      return false
    end

    if adjust_htg_setpt && htg_sp_f > CLG_MAX_F
      runner.registerError("User-input heating setpoint #{htg_sp_f} is greater than maximum allowed cooling setpoint of #{CLG_MAX_F}. Check input.")
      return false
    end

    # adjust heating setpoint if too close to cooling setpoint
    if adjust_clg_setpt && adjust_htg_setpt && (htg_sp_f > (clg_sp_f - 2))
      runner.registerWarning("User-input heating setpoint of #{htg_sp_f}F is > 2F from the user-input cooling setpoint of #{clg_sp_f}F which is not permitted. The user-input heating setpoint is now #{clg_sp_f - 2.0}F to allow a reasonable deadband range.")
      htg_sp_f = clg_sp_f - 2.0
    end

    # make conversions for cooling
    clg_sp_c = OpenStudio.convert(clg_sp_f, 'F', 'C').get
    clg_sb_f = clg_sp_f + clg_delta_f
    clg_delta_c = OpenStudio.convert(clg_delta_f, 'R', 'K').get
    clg_sb_c = OpenStudio.convert(clg_sb_f, 'F', 'C').get

    # make conversions for heating
    htg_sp_c = OpenStudio.convert(htg_sp_f, 'F', 'C').get
    htg_sb_f = htg_sp_f - htg_delta_f
    htg_delta_c = OpenStudio.convert(htg_delta_f, 'R', 'K').get
    htg_sb_c = OpenStudio.convert(htg_sb_f, 'F', 'C').get

    # Initialize arrays
    clg_tstat_schedules = []
    htg_tstat_schedules = []

    # Collect zone thermostat schedules
    model.getThermalZones.each do |thermal_zone|
      # skip data centers
      next if thermal_zone.name.get.downcase.gsub(' ', '').include?('datacenter')

      # skip zones without thermostats
      next unless thermal_zone.thermostatSetpointDualSetpoint.is_initialized

      zone_thermostat = thermal_zone.thermostatSetpointDualSetpoint.get

      clg_schedule = zone_thermostat.coolingSetpointTemperatureSchedule
      if adjust_cooling
        if clg_schedule.empty?
          runner.registerWarning("Cooling setpoint schedule not found for zone '#{thermal_zone.name.get}'")
        elsif clg_schedule.get.to_ScheduleRuleset.empty?
          runner.registerWarning("Schedule '#{clg_schedule.get.name.get}' is not a ScheduleRuleset, will not be adjusted")
        else
          clg_tstat_schedules << clg_schedule.get.to_ScheduleRuleset.get
        end
      end

      htg_schedule = zone_thermostat.heatingSetpointTemperatureSchedule
      if adjust_heating
        if htg_schedule.empty?
          runner.registerWarning("Heating setpoint schedule not found for zone '#{thermal_zone.name.get}'")
        elsif htg_schedule.get.to_ScheduleRuleset.empty?
          runner.registerWarning("Schedule '#{htg_schedule.get.name.get}' is not a ScheduleRuleset, will not be adjusted")
        else
          htg_tstat_schedules << htg_schedule.get.to_ScheduleRuleset.get
        end
      end
    end

    # adjust cooling schedules
    clg_tstat_schedules.uniq.each do |clg_sch|
      sch_info = get_tstat_profiles_and_stats(clg_sch)
      next if !sch_info

      if sch_info[:min] > CLG_MAX_C
        runner.registerWarning("Cooling schedule #{clg_sch.name} has a minimum setpoint over #{CLG_MAX_F}F, and therefore is not applicable for this measure as it is likely a non-cooled zone. It will be skipped.")
        next
      end

      # warn if setback input for flat schedule
      if adjust_clg_setback && (sch_info[:num_vals] == 1)
        runner.registerWarning("Cooling schedule #{clg_sch.name} only has 1 temperature setpoint and is therefore not applicable for adding any setbacks to the temperature schedules.")
      end

      # set design day schedules
      if adjust_clg_setpt
        des_day = OpenStudio::Model::ScheduleDay.new(model, clg_sp_c)
        clg_sch.setSummerDesignDaySchedule(des_day)
        clg_sch.setWinterDesignDaySchedule(des_day)
      end

      # Loop through schedules and make changes
      sch_info[:profiles].each do |profile|
        profile_name = profile.name
        profile_min = profile.values.min
        profile_max = profile.values.max
        profile_size = profile.values.uniq.size
        time_h = profile.times

        # if only adjust setback, use existing schedule min as setpoint
        if !adjust_clg_setpt && adjust_clg_setback
          clg_sp_c = sch_info[:min]
          clg_sb_c = sch_info[:min] + clg_delta_c
        end

        # if only adjust setpoint, use existing setback unless it's within 2F of new setpoint
        if adjust_clg_setpt && !adjust_clg_setback
          if sch_info[:max] < (clg_sp_c + OpenStudio.convert(2.0, 'R', 'K').get)
            runner.registerWarning("User input requests cooling setpoint temp of #{clg_sp_f}F is within 2 degrees of existing cooling temperature setback of #{OpenStudio.convert(sch_info[:max], 'C', 'F').get.round(1)}F. Setback will be adjusted to 2F.")
            clg_sb_c = clg_sp_c + OpenStudio.convert(2.0, 'R', 'K').get
          else
            clg_sb_c = sch_info[:max]
          end
        end

        # adjust schedules and setbacks depending on existing profile structure
        if profile_size == 1
          if profile_min == sch_info[:min]
            # profile is constant sched that matches minimum schedule value (i.e. occupied cooling setpoint)
            profile.values.each_with_index { |value, i| profile.addValue(time_h[i], clg_sp_c) }
          elsif profile_max == sch_info[:max]
            # profile is constant sched that matches maximum schedule value (i.e. occupied setback)
            profile.values.each_with_index { |value, i| profile.addValue(time_h[i], clg_sb_c) }
          elsif (profile_max != sch_info[:max]) && (profile_min != sch_info[:min])
            # profile is constant and does not match max or min
            runner.registerWarning("For #{clg_sch.name} cooling thermostat schedule, cooling profile #{profile_name} is constant with a value of #{OpenStudio.convert(profile_max, 'C', 'F').get.round(1)}F, which does not match the max or min of the original profile, making it unknown if this is an occupied or unnocupied setpoint. Profile will not be changed.")
          end
        elsif profile_size == 2
          # profile is square wave (2 setpoints, occupied vs unoccupied)
          profile.values.each_with_index do |value, i|
            if value == profile_min
              profile.addValue(time_h[i], clg_sp_c)
              # warn if profile min does not match schedule min
              if profile_min != sch_info[:min]
                runner.registerWarning("Cooling Setpoint Schedule '#{clg_sch.name}' profile '#{profile_name}' min value of #{OpenStudio.convert(profile_min, 'C', 'F').get.round(1)}F does not match Schedule minimum of #{OpenStudio.convert(sch_info[:min], 'C', 'F').get.round(1)}F. The profile value will be updated to the user-entered setpoint of #{clg_sp_f}F")
              end
            elsif value == profile_max
              profile.addValue(time_h[i], clg_sb_c)
              # warn if profile max does not match schedule max
              if profile_max != sch_info[:max]
                runner.registerWarning("Cooling Setpoint Schedule '#{clg_sch.name}' profile '#{profile_name}' max value of #{OpenStudio.convert(profile_max, 'C', 'F').get.round(1)}F does not match Schedule maximum of #{OpenStudio.convert(sch_info[:max], 'C', 'F').get.round(1)}F. The profile value will be updated to the user-entered setpoint of #{clg_sb_f}F")
              end
            end
          end
        elsif profile_size > 2
          values_uniq_ramps = profile.values - [profile_min, profile_max]

          # create hash of ramp values and their proportion to original setpoint and setback
          ramp_fracs = {}
          values_uniq_ramps.each do |ramp|
            ramp_fracs[ramp] = (ramp - profile_min) / (profile_max - profile_min)
          end

          # loop through profiles and add new setpoints
          profile.values.each_with_index do |value, i|
            if value == profile_min
              profile.addValue(time_h[i], clg_sp_c)
            elsif value == profile_max
              profile.addValue(time_h[i], clg_sb_c)
            else
              ramp_new = (ramp_fracs[value] * clg_delta_c) + clg_sp_c
              profile.addValue(time_h[i], ramp_new)
            end
          end
        end
      end
    end

    # adjust heating schedules
    htg_tstat_schedules.uniq.each do |htg_sch|
      sch_info = get_tstat_profiles_and_stats(htg_sch)
      next if !sch_info

      if sch_info[:max] < HTG_MIN_C
        runner.registerWarning("Heating schedule #{htg_sch.name} has a maximum setpoint under #{HTG_MIN_F}F, and therefore is not applicable for this measure as it is likely a non-heated zone. It will be skipped.")
        next
      end

      # temporary workaround to not adjust warehouse office space types
      # don't allow heating setpoint reduction
      if (model.getBuilding.name.get.include? 'Warehouse') && adjust_htg_setpt && (htg_sp_c < sch_info[:max])
        runner.registerWarning("User-input heating setpoint temp of #{htg_sp_f}F would reduce heating setpoint for schedule #{htg_sch.name}. Skipping.")
        next
      end

      # warn if setback input for flat schedule
      if adjust_htg_setback && (sch_info[:num_vals] == 1)
        runner.registerWarning("Heating schedule #{htg_sch.name} only has 1 temperature setpoint and is therefore not applicable for adding any setbacks to the temperature schedules.")
      end

      # set design day schedules
      if adjust_htg_setpt
        des_day = OpenStudio::Model::ScheduleDay.new(model, htg_sp_c)
        htg_sch.setSummerDesignDaySchedule(des_day)
        htg_sch.setWinterDesignDaySchedule(des_day)
      end

      # Loop through schedules and make changes
      sch_info[:profiles].each do |profile|
        profile_name = profile.name
        profile_min = profile.values.min
        profile_max = profile.values.max
        profile_size = profile.values.uniq.size
        time_h = profile.times

        # if only adjust setback, use existing schedule min as setpoint
        if !adjust_htg_setpt && adjust_htg_setback
          htg_sp_c = sch_info[:max]
          htg_sb_c = sch_info[:max] - htg_delta_c
        end

        # if only adjust setpoint, use existing setback unless it's within 2F of new setpoint
        if adjust_htg_setpt && !adjust_htg_setback
          if sch_info[:min] > (htg_sp_c - OpenStudio.convert(2.0, 'R', 'K').get)
            runner.registerWarning("User input requests heating setpoint temp of #{htg_sp_f}F is within 2 degrees of existing heating temperature setback of #{OpenStudio.convert(sch_info[:min], 'C', 'F').get.round(1)}F. Setback will be adjusted to 2F.")
            htg_sb_c = htg_sp_c - OpenStudio.convert(2.0, 'R', 'K').get
          else
            htg_sb_c = sch_info[:max]
          end
        end

        # adjust schedules and setbacks depending on existing profile structure
        if profile_size == 1
          if profile_min == sch_info[:max]
            # profile is constant sched that matches maximum schedule value (i.e. occupied heating setpoint)
            profile.values.each_with_index { |value, i| profile.addValue(time_h[i], htg_sp_c) }
          elsif profile_max == sch_info[:min]
            # profile is constant sched that matches maximum schedule value (i.e. occupied setback)
            profile.values.each_with_index { |value, i| profile.addValue(time_h[i], htg_sb_c) }
          elsif (profile_max != sch_info[:max]) && (profile_min != sch_info[:min])
            # profile is constant and does not match max or min
            runner.registerWarning("For #{htg_sch.name} heating thermostat schedule, heating profile #{profile_name} is constant with a value of #{OpenStudio.convert(profile_max, 'C', 'F').get.round(1)}F, which does not match the max or min of the original profile, making it unknown if this is an occupied or unnocupied setpoint. Profile will not be changed.")
          end
        elsif profile_size == 2
          # profile is square wave (2 setpoints, occupied vs unoccupied)
          profile.values.each_with_index do |value, i|
            if value == profile_max
              profile.addValue(time_h[i], htg_sp_c)
              # warn if profile max does not match schedule min
              if profile_max != sch_info[:max]
                runner.registerWarning("Heating Setpoint Schedule '#{htg_sch.name}' profile '#{profile_name}' max value of #{OpenStudio.convert(profile_max, 'C', 'F').get.round(1)}F does not match Schedule maximum of #{OpenStudio.convert(sch_info[:max], 'C', 'F').get.round(1)}F. The profile value will be updated to the user-entered setpoint of #{htg_sp_f}F")
              end
            elsif value == profile_min
              profile.addValue(time_h[i], htg_sb_c)
              # warn if profile max does not match schedule max
              if profile_min != sch_info[:min]
                runner.registerWarning("Heatng Setpoint Schedule '#{htg_sch.name}' profile '#{profile_name}' min value of #{OpenStudio.convert(profile_min, 'C', 'F').get.round(1)}F does not match Schedule minimum of #{OpenStudio.convert(sch_info[:min], 'C', 'F').get.round(1)}F. The profile value will be updated to the user-entered setpoint of #{htg_sb_f}F")
              end
            end
          end
        elsif profile_size > 2
          values_uniq_ramps = profile.values - [profile_min, profile_max]

          # create hash of ramp values and their proportion to original setpoint and setback
          ramp_fracs = {}
          values_uniq_ramps.each do |ramp|
            ramp_fracs[ramp] = (ramp - profile_min) / (profile_max - profile_min)
          end

          # loop through profiles and add new setpoints
          profile.values.each_with_index do |value, i|
            if value == profile_max
              profile.addValue(time_h[i], htg_sp_c)
            elsif value == profile_min
              profile.addValue(time_h[i], htg_sb_c)
            else
              ramp_new = (ramp_fracs[value] * htg_delta_c) + htg_sb_c
              profile.addValue(time_h[i], ramp_new)
            end
          end
        end
      end
    end

    # report initial condition of model
    runner.registerInitialCondition("The building started with #{clg_tstat_schedules.uniq.size} unique cooling thermostat schedules and #{htg_tstat_schedules.uniq.size} unique heating thermostat schedules. User-input occupied cooling setpoint is #{clg_sp_f}F with a #{clg_delta_f}F unoccupied setpoint delta. User-input heating occupied setpoint is #{htg_sp_f}F with a #{htg_delta_f}F unnocupied setpoint delta. A value of 999 indicates no user-specified change.")

    # report final condition of model
    runner.registerFinalCondition("#{clg_tstat_schedules.uniq.size} cooling and #{htg_tstat_schedules.uniq.size} heating schedules have been changed in accordance to user inputs.")

    return true
  end
end

# register the measure to be used by the application
AddThermostatSetpointVariability.new.registerWithApplication
