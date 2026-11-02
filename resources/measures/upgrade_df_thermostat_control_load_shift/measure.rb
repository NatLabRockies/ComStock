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

# require all .rb files in resources folder
Dir["#{File.dirname(__FILE__)}/resources/*.rb"].sort.each { |file| require file }

require 'openstudio'
require 'date'
require 'comstock-typical'

# start the measure
class DfThermostatControlLoadShift < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    'demand flexibility - thermostat control load shift'
  end

  # human readable description
  def description
    'This measure implements demand flexibility measure on daily thermostat control with load shift strategy, by adjusting thermostat setpoints for pre-cooling and/or pre-heating corresponding to the pre-peak schedule based on daily peak load prediction.'
  end

  # human readable description of modeling approach
  def modeler_description
    'This measure performs load prediction based on options of full baseline run, bin-sample method and par year bin-sample method. Based on the predicted load profile the measure generates daily (pre-)peak schedule, and iterates through all applicable (electric) thermostats to adjust the pre-peak cooling or heating setpoints for pre-cooling or pre-heating.'
  end

  # define the arguments that the user will input
  def arguments(_model)
    args = OpenStudio::Measure::OSArgumentVector.new

    choices_obj = ['peak load', 'grid peak load', 'emissions', 'utility bill cost', 'operational cost']
    demand_flexibility_objective = OpenStudio::Ruleset::OSArgument.makeChoiceArgument('demand_flexibility_objective',
                                                                                      choices_obj, true)
    demand_flexibility_objective.setDisplayName('Objective of demand flexibility control (peak load, grid peak load, emissions, utility bill cost, operational cost)')
    demand_flexibility_objective.setDefaultValue('peak load')
    args << demand_flexibility_objective

    peak_len = OpenStudio::Measure::OSArgument.makeIntegerArgument('peak_len', true)
    peak_len.setDisplayName('Length of dispatch window (hour)')
    peak_len.setDefaultValue(4)
    args << peak_len

    prepeak_len = OpenStudio::Measure::OSArgument.makeIntegerArgument('prepeak_len', true)
    prepeak_len.setDisplayName('Length of pre-peak period before dispatch window (hour)')
    prepeak_len.setDefaultValue(2)
    args << prepeak_len

    sp_adjustment = OpenStudio::Measure::OSArgument.makeDoubleArgument('sp_adjustment', true)
    sp_adjustment.setDisplayName('Degrees C to Adjust Setpoint By')
    sp_adjustment.setDefaultValue(1.0)
    args << sp_adjustment

    num_timesteps_in_hr = OpenStudio::Measure::OSArgument.makeIntegerArgument('num_timesteps_in_hr', true)
    num_timesteps_in_hr.setDisplayName('Number/Count of timesteps in an hour for sample simulations')
    num_timesteps_in_hr.setDefaultValue(4)
    args << num_timesteps_in_hr

    choices = ['full baseline', 'bin sample', 'part year bin sample', 'fix', 'oat']
    load_prediction_method = OpenStudio::Ruleset::OSArgument.makeChoiceArgument('load_prediction_method', choices, true)
    load_prediction_method.setDisplayName('Method of load prediction (full baseline run, bin sample, part year bin sample, fixed schedule, outdoor air temperature-based)')
    load_prediction_method.setDefaultValue('full baseline')
    args << load_prediction_method

    choices_strate = ['max savings', 'start with peak', 'end with peak', 'center with peak']
    peak_window_strategy = OpenStudio::Ruleset::OSArgument.makeChoiceArgument('peak_window_strategy', choices_strate,
                                                                              true)
    peak_window_strategy.setDisplayName('Method of determining peak windows (max savings, start with peak, end with peak, center with peak)')
    peak_window_strategy.setDefaultValue('center with peak')
    args << peak_window_strategy

    args
  end

  def day_of_year(year, month, day)
    (Date.new(year, month, day) - Date.new(year, 1, 1)).to_i + 1
  end

  def temp_setp_adjust_hourly_based_on_sch(peak_sch, sp_adjustment)
    peak_sch.map { |a| sp_adjustment * a }
  end

  def get_interval_schedule_from_schedule_ruleset(model, schedule_ruleset, size)
    # https://github.com/NREL/openstudio-standards/blob/9e6bdf751baedfe73567f532007fefe6656f5abf/lib/openstudio-standards/standards/Standards.ScheduleRuleset.rb#L696
    # https://github.com/NREL/openstudio-standards/blob/8f948207d6af73165a2a8232559804b93d8e50c2/lib/openstudio-standards/schedules/information.rb#L338
    yd = model.getYearDescription
    start_date = yd.makeDate(1, 1)
    end_date = yd.makeDate(12, 31)
    values = [] # OpenStudio::Vector.new
    case size
    when 8760, 8784
      interval = OpenStudio::Time.new(1.0 / 24.0) # 1h interval
      num_timesteps_in_hr = 1
    when 35_040, 35_136
      interval = OpenStudio::Time.new(1.0 / 24.0 / 4.0) # 15min interval
      num_timesteps_in_hr = 4
    else
      raise 'Interval not supported'
    end
    num_timesteps = model.getTimestep.numberOfTimestepsPerHour
    day_schedules = schedule_ruleset.getDaySchedules(start_date, end_date)
    # # Make new array of day schedules for year
    # day_sched_array = []
    # day_schedules.each do |day_schedule|
    #   day_sched_array << day_schedule
    # end
    day_schedules.each do |day_schedule|
      if model.version.str < '3.8.0'
        current_hour = interval
        time_values = day_schedule.times
        num_times = time_values.size
        value_sum = 0
        value_count = 0
        time_values.each do |until_hr|
          if until_hr < current_hour
            # Add to tally for next hour average
            value_sum += day_schedule.getValue(until_hr).to_f
            value_count += 1
          elsif until_hr >= current_hour + interval
            # Loop through hours to catch current hour up to until_hr
            while current_hour <= until_hr
              values << day_schedule.getValue(until_hr).to_f
              current_hour += interval
            end
            if (current_hour - until_hr) < interval
              # This means until_hr is not an even hour break
              # i.e. there is a sub-hour time step
              # Increment the sum for averaging
              value_sum += day_schedule.getValue(until_hr).to_f
              value_count += 1
            end
          else
            # Add to tally for this hour average
            value_sum += day_schedule.getValue(until_hr).to_f
            value_count += 1
            # Calc hour average
            value_avg = if value_count.positive?
                          value_sum / value_count
                        else
                          0
                        end
            values << value_avg
            # setup for next hour
            value_sum = 0
            value_count = 0
            current_hour += interval
          end
        end
      else
        day_timeseries = day_schedule.timeSeries.values.to_a
        if num_timesteps == 4 && num_timesteps_in_hr == 1
          daily_intervals_values = day_timeseries.each_slice(4).map { |slice| slice.sum / slice.size.to_f }
        elsif num_timesteps == num_timesteps_in_hr
          daily_intervals_values = day_timeseries
        else
          raise 'Not supported time intervals'
        end
        values += daily_intervals_values
      end
    end
    values
  end

  def get_reference_schedule_from_schedule_ruleset(model, schedule_ruleset, size)
    yd = model.getYearDescription
    start_date = yd.makeDate(1, 1)
    end_date = yd.makeDate(12, 31)
    values = [] # OpenStudio::Vector.new
    case size
    when 8760, 8784
      interval = OpenStudio::Time.new(1.0 / 24.0) # 1h interval
      num_timesteps_in_hr = 1
    when 35_040, 35_136
      interval = OpenStudio::Time.new(1.0 / 24.0 / 4.0) # 15min interval
      num_timesteps_in_hr = 4
    else
      raise 'Interval not supported'
    end
    num_timesteps = model.getTimestep.numberOfTimestepsPerHour
    day_schedules = schedule_ruleset.getDaySchedules(start_date, end_date)
    # day_sched_array = []
    # day_schedules.each do |day_schedule|
    #   day_sched_array << day_schedule
    # end
    day_schedules.each do |day_schedule|
      if model.version.str < '3.8.0'
        current_hour = interval
        time_values = day_schedule.times
        num_times = time_values.size
        value_sum = 0
        value_count = 0
        time_values.each do |until_hr|
          if until_hr < current_hour
            # Add to tally for next hour average
            value_sum += day_schedule.getValue(until_hr).to_f
            value_count += 1
          elsif until_hr >= current_hour + interval
            # Loop through hours to catch current hour up to until_hr
            while current_hour <= until_hr
              values << day_schedule.getValue(until_hr).to_f
              current_hour += interval
            end
            if (current_hour - until_hr) < interval
              # This means until_hr is not an even hour break
              # i.e. there is a sub-hour time step
              # Increment the sum for averaging
              value_sum += day_schedule.getValue(until_hr).to_f
              value_count += 1
            end
          else
            # Add to tally for this hour average
            value_sum += day_schedule.getValue(until_hr).to_f
            value_count += 1
            # Calc hour average
            value_avg = if value_count.positive?
                          value_sum / value_count
                        else
                          0
                        end
            values << value_avg
            # setup for next hour
            value_sum = 0
            value_count = 0
            current_hour += interval
          end
        end
      else
        day_timeseries = day_schedule.timeSeries.values.to_a
        if num_timesteps == 4 && num_timesteps_in_hr == 1
          daily_intervals_values = day_timeseries.each_slice(4).map { |slice| slice.sum / slice.size.to_f }
        elsif num_timesteps == num_timesteps_in_hr
          daily_intervals_values = day_timeseries
        else
          raise 'Not supported time intervals'
        end
        values += daily_intervals_values
      end
    end
    designdays = model.getDesignDays
    designdays.each do |designday|
      month = designday.month
      day = designday.dayOfMonth
      daytype = designday.dayType
      doy = day_of_year(yd.calendarYear.to_i, month, day)
      case daytype
      when 'SummerDesignDay'
        day_schedule = schedule_ruleset.summerDesignDaySchedule
      when 'WinterDesignDay'
        day_schedule = schedule_ruleset.winterDesignDaySchedule
      else
        puts('Check designday for dayType')
        day_schedule = schedule_ruleset.defaultDaySchedule
      end
      vals = day_schedule.values
      val = if vals.length > 1
              vals.max
            else
              vals[0]
            end
      # replace sp values with design day sch on design days
      values[((doy - 1) * num_timesteps_in_hr * 24), (num_timesteps_in_hr * 24)] = [val] * (num_timesteps_in_hr * 24)
    end
    values
  end

  def assign_clgsch_to_thermostats(model, applicable_clg_thermostats, runner, clgsp_adjustment_values)
    clg_set_schs = {}
    nts = 0
    applicable_clg_thermostats.each do |thermostat|
      # setup new cooling setpoint schedule
      clg_set_sch = thermostat.coolingSetpointTemperatureSchedule
      heat_set_sch = thermostat.heatingSetpointTemperatureSchedule
      if !clg_set_sch.empty? || !heat_set_sch.empty?
        # clone of not already in hash
        if clg_set_schs.key?(clg_set_sch.get.name.to_s)
          # exist
          new_clg_set_sch = clg_set_schs[clg_set_sch.get.name.to_s]
        else
          # new
          schedule = clg_set_sch.get.clone(model)
          schedule = schedule.to_Schedule.get
          schedule_heat = heat_set_sch.get.clone(model)
          schedule_heat = schedule_heat.to_Schedule.get
          schedule_8760 = get_interval_schedule_from_schedule_ruleset(model, schedule.to_ScheduleRuleset.get,
                                                                      clgsp_adjustment_values.size)
          schedule_35040_heat = get_reference_schedule_from_schedule_ruleset(model, schedule_heat.to_ScheduleRuleset.get, clgsp_adjustment_values.size) # use hourly max instead of hourly average to avoid optimium start spikes
          # schedule_8760_heat_max = []
          # schedule_35040_heat.each_slice(4) do |hrval|
          #   schedule_8760_heat_max << hrval.max
          # end
          if schedule_8760.size == clgsp_adjustment_values.size
            nums = [schedule_8760, clgsp_adjustment_values]
          else
            msize = [schedule_8760.size, clgsp_adjustment_values.size].min
            nums = [schedule_8760.take(msize), clgsp_adjustment_values.take(msize)]
          end
          new_schedule_8760 = nums.transpose.map(&:sum)
          schedule_values = OpenStudio::Vector.new(new_schedule_8760.length, 0.0)
          # check reference htg sp sch in case clg sp lower than heat sp
          new_schedule_8760.each_with_index do |val, i|
            if val > schedule_35040_heat[i]
              schedule_values[i] = val
            else
              # if clg sp is lower, change it to middle line of original clg sp and the reference htg sp
              schedule_values[i] = (schedule_35040_heat[i] + schedule_8760[i]) / 2.0
            end
          end
          # make schedule
          case schedule_values.size
          when 35_040, 35_136
            interval_hr = OpenStudio::Time.new(0, 0, 15)
          when 8760, 8784
            interval_hr = OpenStudio::Time.new(0, 1, 0)
          else
            runner.registerError('Interval not supported')
            return false
          end
          start_date = OpenStudio::Date.new(OpenStudio::MonthOfYear.new(1), 1)
          timeseries = OpenStudio::TimeSeries.new(start_date, interval_hr, schedule_values, 'C')
          new_clg_set_sch = OpenStudio::Model::ScheduleInterval.fromTimeSeries(timeseries, model)
          if new_clg_set_sch.empty?
            runner.registerError('Unable to make schedule')
            return false
          end
          new_clg_set_sch = new_clg_set_sch.get
          new_clg_set_sch.setName("#{clg_set_sch.get.name} df_adjusted")
          ### add to the hash
          clg_set_schs[clg_set_sch.get.name.to_s] = new_clg_set_sch
        end
        # hook up clone to thermostat
        # puts("Setting new schedule #{new_clg_set_sch.name.to_s}")
        thermostat.setCoolingSetpointTemperatureSchedule(new_clg_set_sch)
        nts += 1
      else
        runner.registerWarning("Thermostat '#{thermostat.name}' doesn't have cooling and heating setpoint schedules")
      end
    end
    nts
  end

  def assign_heatsch_to_thermostats(model, applicable_htg_thermostats, runner, heatsp_adjustment_values)
    heat_set_schs = {}
    nts = 0
    # thermostats = model.getThermostatSetpointDualSetpoints
    applicable_htg_thermostats.each do |thermostat|
      # setup new cooling setpoint schedule
      heat_set_sch = thermostat.heatingSetpointTemperatureSchedule
      if heat_set_sch.empty?
        runner.registerWarning("Thermostat '#{thermostat.name}' doesn't have a cooling setpoint schedule")
      else
        # clone of not already in hash
        if heat_set_schs.key?(heat_set_sch.get.name.to_s)
          # exist
          new_heat_set_sch = heat_set_schs[heat_set_sch.get.name.to_s]
        else
          # new
          schedule = heat_set_sch.get.clone(model)
          schedule = schedule.to_Schedule.get
          schedule_8760 = get_interval_schedule_from_schedule_ruleset(model, schedule.to_ScheduleRuleset.get,
                                                                      heatsp_adjustment_values.size)
          if schedule_8760.size == heatsp_adjustment_values.size
            nums = [schedule_8760, heatsp_adjustment_values]
          else
            msize = [schedule_8760.size, heatsp_adjustment_values.size].min
            nums = [schedule_8760.take(msize), heatsp_adjustment_values.take(msize)]
          end
          new_schedule_8760 = nums.transpose.map(&:sum)
          schedule_values = OpenStudio::Vector.new(new_schedule_8760.length, 0.0)
          new_schedule_8760.each_with_index do |val, i|
            schedule_values[i] = val
          end
          # make a schedule
          interval_hr = OpenStudio::Time.new(0, 1, 0)
          start_date = OpenStudio::Date.new(OpenStudio::MonthOfYear.new(1), 1)
          timeseries = OpenStudio::TimeSeries.new(start_date, interval_hr, schedule_values, 'C')
          new_heat_set_sch = OpenStudio::Model::ScheduleInterval.fromTimeSeries(timeseries, model)
          if new_heat_set_sch.empty?
            runner.registerError('Unable to make schedule')
            return false
          end
          new_heat_set_sch = new_heat_set_sch.get
          new_heat_set_sch.setName("#{heat_set_sch.get.name} df_adjusted")
          ### add to the hash
          heat_set_schs[heat_set_sch.get.name.to_s] = new_heat_set_sch
        end
        # hook up clone to thermostat
        # puts("Setting new schedule #{new_heat_set_sch.name.to_s}")
        thermostat.setHeatingSetpointTemperatureSchedule(new_heat_set_sch)
        nts += 1
      end
    end
    nts
  end

  def isapplicable_buildingtype(model, runner, applicable_building_types)
    model_building_type = nil
    if model.getBuilding.additionalProperties.getFeatureAsString('building_type').is_initialized
      model_building_type = model.getBuilding.additionalProperties.getFeatureAsString('building_type').get
    elsif model.getBuilding.standardsBuildingType.is_initialized
      model_building_type = model.getBuilding.standardsBuildingType.get
    else
      runner.registerError('model.getBuilding.additionalProperties.building_type and model.getBuilding.standardsBuildingType are empty.')
      return false
    end
    puts("--- model_building_type = #{model_building_type}")
    if applicable_building_types.include?(model_building_type)
      puts("--- applicability passed for building type: #{model_building_type}")
      true
    else
      runner.registerAsNotApplicable("applicability not passed due to building type (office buildings): #{model_building_type}")
      false
    end
  end

  def applicable_thermostats(model)
    applicable_clg_thermostats = []
    applicable_htg_thermostats = []
    thermostats = model.getThermostatSetpointDualSetpoints
    thermostats.each do |thermostat|
      next unless thermostat.to_Thermostat.get.thermalZone.is_initialized

      thermalzone = thermostat.to_Thermostat.get.thermalZone.get
      clg_fueltypes = thermalzone.coolingFuelTypes.map(&:valueName).uniq
      htg_fueltypes = thermalzone.heatingFuelTypes.map(&:valueName).uniq
      # puts("### DEBUGGING: clg_fueltypes = #{clg_fueltypes}")
      # puts("### DEBUGGING: htg_fueltypes = #{htg_fueltypes}")
      applicable_clg_thermostats << thermostat if clg_fueltypes == ['Electricity']
      applicable_htg_thermostats << thermostat if htg_fueltypes == ['Electricity']
    end
    [applicable_clg_thermostats, applicable_htg_thermostats, thermostats.size]
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    ############################################
    # use the built-in error checking
    ############################################
    return false unless runner.validateUserArguments(arguments(model), user_arguments)

    ############################################
    # assign the user inputs to variables
    ############################################
    demand_flexibility_objective = runner.getStringArgumentValue('demand_flexibility_objective', user_arguments)
    peak_len = runner.getIntegerArgumentValue('peak_len', user_arguments)
    prepeak_len = runner.getIntegerArgumentValue('prepeak_len', user_arguments)
    sp_adjustment = runner.getDoubleArgumentValue('sp_adjustment', user_arguments)
    num_timesteps_in_hr = runner.getIntegerArgumentValue('num_timesteps_in_hr', user_arguments)
    load_prediction_method = runner.getStringArgumentValue('load_prediction_method', user_arguments)
    peak_window_strategy = runner.getStringArgumentValue('peak_window_strategy', user_arguments)

    ############################################
    # Applicability check
    ############################################
    puts('### ============================================================')
    puts('### Applicability check...')
    applicable_building_types = [
      # "Hotel",
      'SmallOffice',
      'small_office',
      'OfS',
      'MediumOffice',
      'medium_office',
      'LargeOffice',
      'large_office',
      'OfL',
      'Office',
      'Warehouse',
      'warehouse',
      'SUn',
      'PrimarySchool',
      'primary_school',
      'EPr',
      'SecondarySchool',
      'secondary_school',
      'ESe'
    ]
    return true unless isapplicable_buildingtype(model, runner, applicable_building_types)

    puts('--- building type applicability passed')
    applicable_clg_thermostats, applicable_htg_thermostats, nts = applicable_thermostats(model)
    if !applicable_clg_thermostats.empty? && !applicable_htg_thermostats.empty?
      puts('--- electric cooling and heating applicability passed')
    elsif !applicable_clg_thermostats.empty?
      puts('--- electric cooling applicability passed')
    elsif !applicable_htg_thermostats.empty?
      puts('--- electric heating applicability passed')
    else
      runner.registerAsNotApplicable('applicability not passed for electric cooling or heating')
      return true
    end
    runner.registerInitialCondition("The building initially has #{nts} thermostats, of which #{applicable_clg_thermostats.size} are associated with electric cooling and #{applicable_htg_thermostats.size} are associated with electric heating.")

    ############################################
    # Load prediction
    ############################################
    puts('### ============================================================')
    puts('### Reading weather file...')
    oat = read_epw(model)
    puts("--- oat.size = #{oat.size}")
    puts('### ============================================================')
    if demand_flexibility_objective == 'grid peak load'
      puts('### Reading Cambium load data for load prediction...')
      annual_load = load_prediction_from_grid_data(model)
      puts("--- annual_load.size = #{annual_load.size}")
    elsif load_prediction_method == 'full baseline'
      puts('### Running full baseline for load prediction...')
      annual_load = load_prediction_from_full_run(model, num_timesteps_in_hr)
      # puts("--- annual_load = #{annual_load}")
      puts("--- annual_load.size = #{annual_load.size}")
    elsif load_prediction_method.include?('bin sample')
      case load_prediction_method
      when 'bin sample'
        puts('### Creating bins...')
        bins, selectdays, ns, max_doy = create_binsamples(oat, 'random')
        # puts("--- bins = #{bins}")
        # puts("--- selectdays = #{selectdays}")
        # puts("--- ns = #{ns}")
        puts('### ============================================================')
        puts('### Running simulation on samples...')
        y_seed = run_samples(model, year, selectdays, num_timesteps_in_hr)
        # puts("--- y_seed = #{y_seed}")
      when 'part year bin sample'
        puts('### Creating bins...')
        bins, selectdays, ns, max_doy = create_binsamples(oat, 'sort')
        # puts("--- bins = #{bins}")
        # puts("--- selectdays = #{selectdays}")
        # puts("--- ns = #{ns}")
        puts('============================================================')
        puts('### Running simulation on part year samples...')
        y_seed = run_part_year_samples(model, max_doy, selectdays, num_timesteps_in_hr) # , epw_path=epw_path)
        # puts("--- y_seed = #{y_seed}")
      end
      puts('### ============================================================')
      puts('### Creating annual prediction...')
      annual_load = load_prediction_from_sample(model, y_seed, bins)
      # puts("--- annual_load = #{annual_load}")
      puts("--- annual_load.size = #{annual_load.size}")
    else
      puts('### No load prediction needed...')
    end

    ############################################
    # Generate peak schedule
    ############################################
    puts('### ============================================================')
    puts('### Creating peak schedule...')
    case demand_flexibility_objective
    when 'peak load'
      puts('### Creating peak schedule for peak load reduction...')
      case load_prediction_method
      when 'fix'
        puts('### Fixed schedule...')
        climate_zone = OpenstudioStandards::Weather.model_get_climate_zone(model)
        runner.registerInfo("climate zone = #{climate_zone}")
        if climate_zone.empty?
          runner.registerError('Unable to determine climate zone for model. Cannot apply fix option without climate zone information.')
        elsif climate_zone.include?('ASHRAE')
          cz = climate_zone.split('-')[-1]
        else
          runner.registerError('Unable to determine climate zone for model. Cannot apply fix option without ASHRAE climate zone information.')
        end
        puts "--- cz = #{cz}"
        prepeak_schedule, peak_schedule_htg = peak_schedule_generation_fix(cz, oat, rebound_len = 0, prepeak_len,
                                                                           season = 'all')
      when 'oat'
        puts('### OAT-based schedule...')
        prepeak_schedule, peak_schedule_htg = peak_schedule_generation_oat(oat, peak_len, peak_lag = 2, rebound_len,
                                                                           prepeak_len, season = 'all')
      else
        puts('### Predictive schedule...')
        prepeak_schedule = peak_schedule_generation(annual_load, oat, peak_len, num_timesteps_in_hr,
                                                    peak_window_strategy, rebound_len = 0, prepeak_len, season = 'all')
      end
    when 'grid peak load'
      puts('### Grid predictive schedule...')
      prepeak_schedule = peak_schedule_generation(annual_load, oat, peak_len, num_timesteps_in_hr = 1,
                                                  peak_window_strategy, rebound_len = 0, prepeak_len, season = 'all')
    else
      runner.registerError('Not supported objective.')
    end
    # puts("--- prepeak_schedule = #{prepeak_schedule}")
    puts("--- prepeak_schedule.size = #{prepeak_schedule.size}")

    ############################################
    # Update thermostat setpoint schedule
    ############################################
    puts('### ============================================================')
    nts_clg = 0
    nts_htg = 0
    unless applicable_clg_thermostats.empty?
      puts('### Creating cooling setpoint adjustment schedule...')
      clgsp_adjustment_values = temp_setp_adjust_hourly_based_on_sch(prepeak_schedule, sp_adjustment = -sp_adjustment)
      # puts("--- clgsp_adjustment_values = #{clgsp_adjustment_values}")
      puts("--- clgsp_adjustment_values.size = #{clgsp_adjustment_values.size}")
      puts('### Updating thermostat cooling setpoint schedule...')
      nts_clg = assign_clgsch_to_thermostats(model, applicable_clg_thermostats, runner, clgsp_adjustment_values)
    end
    ### Leave pre-heating & seasonal operation for future development
    # if applicable_htg_thermostats.size > 0
    #   puts("### Creating heating setpoint adjustment schedule...")
    #   heatsp_adjustment_values = temp_setp_adjust_hourly_based_on_sch(prepeak_schedule, sp_adjustment=sp_adjustment)
    #   puts("### Updating thermostat cooling setpoint schedule...")
    #   nts_htg = assign_heatsch_to_thermostats(model,applicable_htg_thermostats,runner,heatsp_adjustment_values)
    # end
    # puts("--- clgsp_adjustment_values = #{clgsp_adjustment_values}")
    # puts("--- heatsp_adjustment_values = #{heatsp_adjustment_values}")
    runner.registerFinalCondition("Updated #{nts_clg}/#{applicable_clg_thermostats.size} thermostat cooling setpoint schedules and #{nts_htg}/#{applicable_htg_thermostats.size} thermostat heating setpoint schedules to model, with #{sp_adjustment.abs} degree C offset for #{prepeak_len} hours of daily pre-cooling/pre-heating before #{peak_len}-hour peak window, using #{load_prediction_method} simulation for load prediction")
    true
  end
end

# register the measure to be used by the application
DfThermostatControlLoadShift.new.registerWithApplication
