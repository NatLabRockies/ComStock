# insert your copyright here

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

require 'comstock-typical'
Dir[File.dirname(__FILE__) + '/resources/*.rb'].each { |file| require file }
# start the measure
class UpgradeAddThermostatSetback < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    'Upgrade_Add_Thermostat_Setback'
  end

  # human readable description
  def description
    'This measure implements thermostat setbacks during unoccupied periods.'
  end

  # human readable description of modeling approach
  def modeler_description
    'This measure implements thermostat setbacks during unoccupied periods.'
  end

  # define the arguments that the user will input
  def arguments(_model)
    args = OpenStudio::Measure::OSArgumentVector.new

    clg_setback = OpenStudio::Measure::OSArgument.makeIntegerArgument('clg_setback', true)
    clg_setback.setDisplayName('Cooling setback magnitude')
    clg_setback.setDescription('Setback magnitude in cooling.')
    clg_setback.setDefaultValue(5)
    args << clg_setback

    htg_setback = OpenStudio::Measure::OSArgument.makeIntegerArgument('htg_setback', true)
    htg_setback.setDisplayName('Heating setback magnitude')
    htg_setback.setDescription('Setback magnitude in heating.')
    htg_setback.setDefaultValue(5)
    args << htg_setback

    opt_start = OpenStudio::Measure::OSArgument.makeBoolArgument('opt_start', true)
    opt_start.setDisplayName('Model an optimum start different from what currently exists?')
    opt_start.setDescription('True if yes; false if no. If false, any existing optimum starts will be preserved.')
    opt_start.setDefaultValue(true)
    args << opt_start

    opt_start_len = OpenStudio::Measure::OSArgument.makeIntegerArgument('opt_start_len', true)
    opt_start_len.setDisplayName('Length of optimum start.')
    opt_start_len.setDefaultValue(3)
    opt_start_len.setDescription('Length of period (in hours) over which optimum start takes place before occupancy. If previous argument is false, this option is disregarded.')
    args << opt_start_len

    htg_min = OpenStudio::Measure::OSArgument.makeIntegerArgument('htg_min', true)
    htg_min.setDisplayName('Minimum heating setpoint')
    htg_min.setDescription('Minimum heating setpoint')
    htg_min.setDefaultValue(55)
    args << htg_min

    clg_max = OpenStudio::Measure::OSArgument.makeIntegerArgument('clg_max', true)
    clg_max.setDisplayName('Maximum cooling setpoint')
    clg_max.setDescription('Maximum cooling setpoint')
    clg_max.setDefaultValue(82)
    args << clg_max

    args
  end

  def air_loop_res?(air_loop_hvac)
    is_res_system = true
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_AirLoopHVAC_OutdoorAirSystem'
        is_res_system = false
      end
    end
    is_res_system
  end

  def opt_start?(sch_zone_occ_annual_profile, htg_schedule_annual_profile, min_value, max_value, idx)
    # method to determine if a thermostat schedule contains part of an optimum start sequence at a given index
    if (sch_zone_occ_annual_profile[idx + 1] == 1 || sch_zone_occ_annual_profile[idx + 2] == 1) &&
       (htg_schedule_annual_profile[idx] > min_value && htg_schedule_annual_profile[idx] < max_value)
      true
    end
  end

  def hours_to_occ(_runner, sch_zone_occ_annual_profile, idx)
    remaining_values = sch_zone_occ_annual_profile.to_a[(idx + 1)..]
    next_occ_index = remaining_values.index(1) # find index of next occupied timestep
    if next_occ_index.nil?
      900 # high value
    else
      next_occ_index + 1 # reindexed in new array
    end
  end

  def valid_tstat_schedule(sched, type, zone)
    valid = true
    if sched.empty?
      runner.registerWarning("#{type} setpoint schedule not found for zone #{zone.name.get}")
      valid = false
    elsif sched.get.to_ScheduleRuleset.empty?
      runner.registerWarning("Schedule '#{sched.name}' is not a ScheduleRuleset, will not be adjusted")
      valid = false
    end
    valid
  end

  def mod_schedule(model, runner, tstat_sched, sched_zone_occ, type, setback_val, lim_value, opt_start,
                   opt_start_app_loop, opt_start_len)
    schedule_annual_profile = get_8760_values_from_schedule_ruleset(model, tstat_sched)
    sch_zone_occ_annual_profile = get_8760_values_from_schedule_ruleset(model, sched_zone_occ)
    schedule_annual_profile_updated = OpenStudio::DoubleVector.new
    schedule_annual_profile.each_with_index do |_val, idx| # Create new profile based on occupancy
      # Find maximum value of schedule for the particular week
      week_values = schedule_annual_profile.each_slice(168).to_a[(idx / 168).round]
      max_value = week_values.max
      min_value = week_values.min
      # skip time steps with optimum start if not changing current optimum start
      # Need at least two more timesteps in the profile to perform optimum start check
      # Final two timesteps of year will not be optimum start, anyway
      opt_start_pres = opt_start?(sch_zone_occ_annual_profile, schedule_annual_profile, min_value, max_value, idx) # skip current time step if currently in an optimum start and don't want to modify it
      next if (idx < schedule_annual_profile.size - 2) && opt_start == false && opt_start_pres == true

      if type == 'heating'
        if opt_start && opt_start_app_loop && sch_zone_occ_annual_profile[idx].zero? && hours_to_occ(runner, sch_zone_occ_annual_profile, idx) <= opt_start_len # handle optimum start if timestep is unoccupied and a few hours before occupancy
          hours = hours_to_occ(runner, sch_zone_occ_annual_profile, idx)
          delta_per_hour = setback_val.fdiv(opt_start_len + 1) # hours reflects time to occupancy
          schedule_annual_profile_updated[idx] =
            [max_value - setback_val + (delta_per_hour * (opt_start_len + 1 - hours)), lim_value].max
        else
          schedule_annual_profile_updated[idx] = if sch_zone_occ_annual_profile[idx].zero? # If unoccupied, apply setback
                                                   [max_value - setback_val, lim_value].max
                                                 else
                                                   max_value
                                                 end
        end
      elsif type == 'cooling'
        if opt_start && opt_start_app_loop && sch_zone_occ_annual_profile[idx].zero? && hours_to_occ(runner, sch_zone_occ_annual_profile, idx) <= opt_start_len # handle optimum start if timestep is unoccupied and a few hours before occupancy
          hours = hours_to_occ(runner, sch_zone_occ_annual_profile, idx)
          delta_per_hour = setback_val.fdiv(opt_start_len + 1)
          schedule_annual_profile_updated[idx] =
            [min_value + setback_val - (delta_per_hour * (opt_start_len + 1 - hours)), lim_value].min
        else
          schedule_annual_profile_updated[idx] = if sch_zone_occ_annual_profile[idx].zero? # If unoccupied, apply setback
                                                   [min_value + setback_val, lim_value].min
                                                 else
                                                   min_value
                                                 end
        end
      end
    end
    tstat_sch_limits = OpenStudio::Model::ScheduleTypeLimits.new(model)
    tstat_sch_limits.setUnitType('Temperature')
    tstat_sch_limits.setNumericType('Continuous')
    sch_new = make_ruleset_sched_from_8760(model, runner, schedule_annual_profile_updated,
                                           "#{tstat_sched.name} Modified Setpoints", tstat_sch_limits)
    # Handle behavior on last day of year--above method makes a schedule ruleset
    # that has a schedule with a specified day
    # of week for 12/31 that isn't intended
    # On leap years, need to correct separate rule made for 12/30 and 12/31
    model_year = model.getYearDescription.assumedYear
    dec_29_date = OpenStudio::Date.new(OpenStudio::MonthOfYear.new('December'), 29, model_year)
    dec_30_date = OpenStudio::Date.new(OpenStudio::MonthOfYear.new('December'), 30, model_year)
    dec_31_date = OpenStudio::Date.new(OpenStudio::MonthOfYear.new('December'), 31, model_year)
    for tstat_rule in sch_new.scheduleRules
      if tstat_rule.endDate.get == dec_30_date ||
         (tstat_rule.endDate.get == dec_29_date)
        tstat_rule.setEndDate(dec_31_date)
      end
      next unless ((tstat_rule.endDate.get == dec_31_date) &&
                 (tstat_rule.startDate.get == dec_31_date)) || ((tstat_rule.endDate.get == dec_31_date) && (tstat_rule.startDate.get == dec_30_date))

      tstat_rule.remove
    end
    sch_new
  end

  def has_setback(tstat_profiles_stats)
    has_setback = false
    for profile in tstat_profiles_stats[:profiles]
      sched_min = profile.values.min
      sched_max = profile.values.max
      has_setback = true if sched_max > sched_min
    end
    has_setback
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments) # Do **NOT** remove this line

    # use the built-in error checking
    return false unless runner.validateUserArguments(arguments(model), user_arguments)

    # assign the user inputs to variables
    clg_setback = runner.getIntegerArgumentValue('clg_setback', user_arguments)
    htg_setback = runner.getIntegerArgumentValue('htg_setback', user_arguments)
    opt_start = runner.getBoolArgumentValue('opt_start', user_arguments)
    opt_start_len = runner.getIntegerArgumentValue('opt_start_len', user_arguments)
    clg_max = runner.getIntegerArgumentValue('clg_max', user_arguments)
    htg_min = runner.getIntegerArgumentValue('htg_min', user_arguments)

    std = Standard.build('90.1-2013') # build standard

    # Space types that keep their thermostats, in the typical (all-level) space type vocabulary:
    # patient care, laboratories, data centers, unoccupied support spaces and guest rooms. A level-1
    # name covers every qualified variant; 'corridor - hospital' is the patient corridor alone.
    # Prototype space type names resolve to these through the prototype space type crosswalk. The
    # prototype list's 'Entry' (now 'lobby'), 'Toilet' (now every 'restroom') and 'BioHazard' (now
    # 'storage') are not carried over: the typical names cover far more than they did.
    space_types_no_setback = [
      'patient room',
      'laboratory',
      'exam/treatment',
      'corridor - hospital',
      'operating room',
      'emergency room',
      'datacenter/high ite',
      'datacenter/low ite',
      'electrical/mechanical',
      'guest room'
    ]

    # Convert setback and threshold values to C
    conv_factor = Rational(5, 9)
    clg_setback_c = clg_setback.to_f * conv_factor
    htg_setback_c = htg_setback.to_f * conv_factor
    htg_min_c = (htg_min - 32).to_f * conv_factor
    clg_max_c = (clg_max - 32).to_f * conv_factor
    cfm_per_m3s = 2118.8799727597
    opt_start_app_loop = opt_start # opt_start_app tracks whether or not optimum start is applicable for a given air loop
    zones_with_setbacks = []
    all_zones = []
    zones_modified = []
    zones_cons_occ = []

    model.getAirLoopHVACs.each do |air_loop_hvac| # iterate thru air loops
      # skip DOAS units; check sizing for all OA and for DOAS in name
      sizing_system = air_loop_hvac.sizingSystem
      if sizing_system.allOutdoorAirinCooling && sizing_system.allOutdoorAirinHeating && (air_loop_res?(air_loop_hvac) == false) && (air_loop_hvac.name.to_s.include?('DOAS') || air_loop_hvac.name.to_s.include?('doas'))
        next
      end

      # Determine if optimum start applicable (airflow > 10,000 cfm)
      if air_loop_hvac.designSupplyAirFlowRate.is_initialized
        des_sup_airflow_rate = air_loop_hvac.designSupplyAirFlowRate.get
        runner.registerInfo("design supply airflow rate #{des_sup_airflow_rate}")
      else
        runner.registerInfo('sizing summary: sizing run needed')
        return false if std.model_run_sizing_run(model, "#{Dir.pwd}/SR1") == false

        model.applySizingValues
        des_sup_airflow_rate = air_loop_hvac.designSupplyAirFlowRate.get
        runner.registerInfo("design supply airflow rate #{des_sup_airflow_rate}")
      end

      if des_sup_airflow_rate * cfm_per_m3s < 10_000 && opt_start == true # Set to false if doesn't qualify for optimum start
        opt_start_app_loop = false
      end
      zones = air_loop_hvac.thermalZones
      zones.sort.each do |thermal_zone|
        no_people_obj = false # flag for not having People object associated with it
        zone_space_types = []
        thermal_zone.spaces.each do |space| # check for space types this measure won't apply to
          zone_space_types << space.spaceType.get.name.to_s
        end

        skip_space_types = OpenstudioStandards::SpaceType.thermal_zone_serves_space_types?(thermal_zone, space_types_no_setback)

        no_people_obj = true if thermal_zone.numberOfPeople.zero?

        if skip_space_types
          next # go to the next zone if this zone has space types that are skipped for the setback
        end

        next unless thermal_zone.thermostatSetpointDualSetpoint.is_initialized

        zone_thermostat = thermal_zone.thermostatSetpointDualSetpoint.get
        htg_schedule = zone_thermostat.heatingSetpointTemperatureSchedule
        clg_schedule = zone_thermostat.coolingSetpointTemperatureSchedule
        # Confirm schedules are valid
        htg_valid = valid_tstat_schedule(htg_schedule, thermal_zone, 'heating')
        clg_valid = valid_tstat_schedule(clg_schedule, thermal_zone, 'cooling')
        if !htg_valid && !clg_valid
          next # skip to the next zone if no valid schedules
        elsif htg_valid
          htg_schedule = htg_schedule.get.to_ScheduleRuleset.get
        end

        all_zones << thermal_zone.name.to_s # Keep track of zones for later comparison to zones with setbacks

        clg_schedule = clg_schedule.get.to_ScheduleRuleset.get if clg_valid

        # check for validity later on too

        sch_zone_occ = OpenstudioStandards::ThermalZone.thermal_zones_get_occupancy_schedule(
          [thermal_zone], occupied_percentage_threshold: 0.05
        )
        sch_zone_occ_annual_profile = get_8760_values_from_schedule_ruleset(model, sch_zone_occ)

        if sch_zone_occ_annual_profile.min > 0 # zone is consistently occupied
          zones_cons_occ << thermal_zone.name.to_s
          next
        end

        runner.registerInfo("class of sched #{sch_zone_occ_annual_profile.class.name}")

        # Determine if setbacks present
        if htg_valid
          tstat_profiles_stats_htg = get_tstat_profiles_and_stats(htg_schedule)
          has_htg_setback = has_setback(tstat_profiles_stats_htg)
          runner.registerInfo("zone #{thermal_zone.name} setback status htg #{has_htg_setback}")
        end
        if clg_valid
          tstat_profiles_stats_clg = get_tstat_profiles_and_stats(clg_schedule)
          has_clg_setback = has_setback(tstat_profiles_stats_clg)
          runner.registerInfo("zone #{thermal_zone.name} setback status clg #{has_clg_setback}")
        end

        if has_htg_setback && has_clg_setback
          zones_with_setbacks << thermal_zone.name.to_s # Keep track of zones that already have setbacks
          next # skip zones that have setbacks for htg and clg already
        end

        # modify for htg vs cooling and threshold temps
        if htg_valid
          if !no_people_obj && !has_htg_setback # align thermostat schedules with occupancy if people object present
            clg_des_day = htg_schedule.summerDesignDaySchedule
            htg_des_day = htg_schedule.winterDesignDaySchedule
            new_htg_sched = mod_schedule(model, runner, htg_schedule, sch_zone_occ, 'heating', htg_setback_c, htg_min_c,
                                         opt_start, opt_start_app_loop, opt_start_len)
            # Keep design days the same as before
            new_htg_sched.setWinterDesignDaySchedule(htg_des_day)
            new_htg_sched.setSummerDesignDaySchedule(clg_des_day)
            zone_thermostat.setHeatingSchedule(new_htg_sched)
            zones_modified << thermal_zone.name.to_s
          elsif has_htg_setback # if no people object, but has existing setbacks, align new setbacks with that schedule
            runner.registerInfo("Heating setback already present for #{htg_schedule.name}")
          else
            runner.registerInfo("Heating schedule #{htg_schedule.name} has no associated people objects at the zone level nor existing setbacks, cannot be modified.")
          end
        end
        if clg_valid
          if !no_people_obj && !has_clg_setback # align thermostat schedules with occupancy if people object present
            clg_des_day = clg_schedule.summerDesignDaySchedule
            htg_des_day = clg_schedule.winterDesignDaySchedule
            new_clg_sched = mod_schedule(model, runner, clg_schedule, sch_zone_occ, 'cooling', clg_setback_c, clg_max_c,
                                         opt_start, opt_start_app_loop, opt_start_len)
            new_clg_sched.setWinterDesignDaySchedule(htg_des_day)
            new_clg_sched.setSummerDesignDaySchedule(clg_des_day)
            zone_thermostat.setCoolingSchedule(new_clg_sched)
            zones_modified << thermal_zone.name.to_s
          elsif has_clg_setback # if no people object, but has existing setbacks, align new setbacks with that schedule
            runner.registerInfo("Cooling setback already present for #{clg_schedule.name}")
          else
            runner.registerInfo("Cooling schedule #{clg_schedule.name} has no associated people objects at the zone level nor existing setbacks, cannot be modified.")
          end
        end
      end
    end
    if (zones_with_setbacks & all_zones == all_zones) || zones_modified.empty? || (zones_cons_occ & all_zones == all_zones) # See if the intersection of the two arrays is equal to the full zones array, or if there have been no zones modified
      runner.registerAsNotApplicable('Measure not applicable; all zones already have setbacks or have no people objects, or have no unoccupied periods.')
      return true
    end
    true
  end
end

# register the measure to be used by the application
UpgradeAddThermostatSetback.new.registerWithApplication
