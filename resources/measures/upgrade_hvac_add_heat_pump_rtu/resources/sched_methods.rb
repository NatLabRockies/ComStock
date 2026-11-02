# ComStock™, Copyright (c) 2020 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2020, Alliance for Sustainable Energy, LLC.
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

require 'openstudio'
require 'date'
require 'comstock-typical'

def get_tstat_profiles_and_stats(tstat_schedule)
  if tstat_schedule.to_ScheduleRuleset.empty?
    runner.registerWarning("Schedule '#{tstat_schedule.name.get}' is not a ScheduleRuleset, will not be adjusted")
    false
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
    { profiles: profiles, values: values, min: sch_min, max: sch_max, num_vals: num_vals }
  end
end

def get_8760_values_from_schedule_ruleset(model, schedule_ruleset)
  Standard.build('90.1-2013') # build openstudio standards
  yd = model.getYearDescription
  start_date = yd.makeDate(1, 1)
  end_date = yd.makeDate(12, 31)

  start_date.dayOfWeek.valueName

  values = OpenStudio::DoubleVector.new
  OpenStudio::Time.new(1.0)
  interval = OpenStudio::Time.new(1.0 / 24.0)
  day_schedules = schedule_ruleset.to_ScheduleRuleset.get.getDaySchedules(start_date, end_date)

  day_schedules.size

  # Get holiday schedule and append to end of values array
  day_schedule_holiday = nil
  schedule_ruleset.to_ScheduleRuleset.get.scheduleRules.each do |week_rule|
    # If a holiday day type is defined, then store the schedule object for the first occurrence
    # For now this is not implemented into the 8760 array
    # if week_rule.applyHoliday
    # day_schedule_holiday = week_rule.daySchedule
    # break
    # end
  end
  day_schedule_holiday = schedule_ruleset.to_ScheduleRuleset.get.defaultDaySchedule if day_schedule_holiday.nil?
  # Currently holidaySchedule is not working in SDK in ScheduleRuleset object
  # TODO: enable the following lines when holidaySchedule is available
  # if !schedule_ruleset.isHolidayScheduleDefaulted
  # day_schedule = schedule_ruleset.to_ScheduleRuleset.get.holidaySchedule
  # else
  # day_schedule = schedule_ruleset.to_ScheduleRuleset.get.defaultSchedule
  # end

  # Make new array of day schedules for year, and add holiday day schedule to end
  day_sched_array = []
  day_schedules.each do |day_schedule|
    day_sched_array << day_schedule
  end

  day_sched_array << day_schedule_holiday
  day_schedules.size

  day_sched_array.each do |day_schedule|
    current_hour = interval
    time_values = day_schedule.times
    time_values.size
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
        value_avg = if value_count > 0
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
  end

  values
end

def make_ruleset_sched_from_8760(model, _runner, values, sch_name, sch_type_limits)
  std = Standard.build('90.1-2013') # build openstudio standards
  # Build array of arrays: each top element is a week, each sub element is an hour of week
  all_week_values = []
  hr_of_yr = -1
  (0..51).each do |_iweek|
    week_values = []
    (0..167).each do |hr_of_wk|
      hr_of_yr += 1
      week_values[hr_of_wk] = values[hr_of_yr]
    end
    all_week_values << week_values
  end

  # Extra week for days 365 and 366 (if applicable) of year
  # since 52 weeks is 364 days
  hr_of_yr += 1
  last_hr = values.size - 1
  week_values = []
  hr_of_wk = -1
  (hr_of_yr..last_hr).each do |ihr_of_yr|
    hr_of_wk += 1
    week_values[hr_of_wk] = values[ihr_of_yr]
  end
  all_week_values << week_values

  # Build ruleset schedules for first week
  yd = model.getYearDescription
  start_date = yd.makeDate(1, 1)
  one_day = OpenStudio::Time.new(1.0)
  seven_days = OpenStudio::Time.new(7.0)
  end_date = start_date + seven_days - one_day

  # Create new ruleset schedule
  sch_ruleset = OpenStudio::Model::ScheduleRuleset.new(model)
  sch_ruleset.setName(sch_name)
  sch_ruleset.setScheduleTypeLimits(sch_type_limits)

  # Make week schedule for first week
  num_week_scheds = 1
  week_sch_name = "#{sch_name}_ws#{num_week_scheds}"
  week_1_rules = std.make_week_ruleset_sched_from_168(model, sch_ruleset, all_week_values[1], start_date, end_date,
                                                      week_sch_name)
  week_n_rules = week_1_rules
  iweek_previous_week_rule = 0
  all_week_rules = { iweek_previous_week_rule: week_1_rules }

  # temporary loop for debugging
  week_n_rules.each do |sch_rule|
    sch_rule.daySchedule
  end

  # For each subsequent week, check if it is same as previous
  # If same, then append to Schedule:Rule of previous week
  # If different, then create new Schedule:Rule
  (1..51).each do |iweek|
    is_a_match = true
    start_date = end_date + one_day
    end_date += seven_days
    (0..167).each do |ihr|
      if all_week_values[iweek][ihr] != all_week_values[iweek_previous_week_rule][ihr]
        is_a_match = false
        break
      end
    end
    if is_a_match
      all_week_rules[:iweek_previous_week_rule].each do |sch_rule|
        sch_rule.setEndDate(end_date)
      end
    else
      # Create a new week schedule for this week
      num_week_scheds += 1
      week_sch_name = sch_name + '_ws' + num_week_scheds.to_s
      week_n_rules = std.make_week_ruleset_sched_from_168(model, sch_ruleset, all_week_values[iweek], start_date,
                                                          end_date, week_sch_name)
      all_week_rules[:iweek_previous_week_rule] = week_n_rules
      # Set this week as the reference for subsequent weeks
      iweek_previous_week_rule = iweek
    end
  end

  # temporary loop for debugging
  week_n_rules.each do |sch_rule|
    sch_rule.daySchedule
  end

  # Need to handle week 52 with days 365 and 366
  # For each of these days, check if it matches a day from the previous week
  iweek = 52
  # First handle day 365
  end_date += one_day
  start_date = end_date
  match_was_found = false
  # week_n is the previous week
  week_n_rules.each do |sch_rule|
    day_rule = sch_rule.daySchedule
    is_match = true
    # Need a 24 hour array of values for the day rule
    ihr_start = 0
    day_values = []
    day_rule.times.each do |time|
      now_value = day_rule.getValue(time).to_f
      until_ihr = time.totalHours.to_i - 1
      (ihr_start..until_ihr).each do |_ihr|
        day_values << now_value
      end
    end
    (0..23).each do |ihr|
      next unless day_values[ihr] != all_week_values[iweek][ihr + ihr_start]

      # not matching for this day_rule
      is_match = false
      break
    end
    next unless is_match

    match_was_found = true
    # Extend the schedule period to include this day
    sch_rule.setEndDate(end_date)
    break
  end
  if match_was_found == false
    # Need to add a new rule
    day_of_week = start_date.dayOfWeek.valueName
    day_names = [day_of_week]
    day_sch_name = "#{sch_name}_Day_365"
    day_sch_values = []
    (0..23).each do |ihr|
      day_sch_values << all_week_values[iweek][ihr]
    end
    # sch_rule is a sub-component of the ScheduleRuleset
    sch_rule = OpenstudioStandards::Schedules.schedule_ruleset_add_rule(sch_ruleset, day_sch_values,
                                                                        start_date: start_date,
                                                                        end_date: end_date,
                                                                        day_names: day_names,
                                                                        rule_name: day_sch_name)
    week_n_rules = sch_rule
  end

  # Handle day 366, if leap year
  # Last day in this week is the holiday schedule
  # If there are three days in this week, then the second is day 366
  # if all_week_values[iweek].size == 24 * 3
  # ihr_start = 23
  # end_date += one_day
  # start_date = end_date
  # match_was_found = false
  # # week_n is the previous week
  # # which would be the week based on day 356, if that was its own week
  # #week_n_rules.each do |sch_rule|
  # day_rule = sch_rule.daySchedule
  # is_match = true
  # day_rule.times.each do |ihr|
  # if day_rule.getValue(ihr).to_f != all_week_values[iweek][ihr + ihr_start]
  # # not matching for this day_rule
  # is_match = false
  # break
  # end
  # end
  # if is_match
  # match_was_found = true
  # # Extend the schedule period to include this day
  # sch_rule.setEndDate(OpenStudio::Date.new(OpenStudio::MonthOfYear.new(end_date.month.to_i), end_date.day.to_i))
  # break
  # end
  # end
  # if match_was_found == false
  # # Need to add a new rule
  # # sch_rule is a sub-component of the ScheduleRuleset

  # day_of_week = start_date.dayOfWeek.valueName
  # day_names = [day_of_week]
  # day_sch_name = "#{sch_name}_Day_366"
  # day_sch_values = []
  # (0..23).each do |ihr|
  # day_sch_values << all_week_values[iweek][ihr]
  # end
  # sch_rule = OpenstudioStandards::Schedules.schedule_ruleset_add_rule(sch_ruleset, day_sch_values,
  # start_date: start_date,
  # end_date: end_date,
  # day_names: day_names,
  # rule_name: day_sch_name)
  # week_n_rules = sch_rule
  # end

  # # Last day in values array is the holiday schedule
  # # @todo add holiday schedule when implemented in OpenStudio SDK
  # end

  # Handle holiday
  # Create the schedules for the holiday
  # holiday_sch = OpenStudio::Model::ScheduleDay.new(model)
  # hr = (values.length() - 24)
  # holiday_sch.setName("#{sch_name} Holiday")
  # (0..23).each do |ihr|
  # #hr_of_yr = ihr_max + ihr
  # #next if values[hr_of_yr] == values[hr_of_yr + 1]
  # holiday_sch.addValue(OpenStudio::Time.new(0, ihr + 1, 0, 0), values[hr])
  # hr = hr + 1
  # end
  # sch_ruleset.setHolidaySchedule(holiday_sch)

  ##

  # Need to handle design days
  # Find schedule with the most operating hours in a day,
  # and apply that to both cooling and heating design days
  hr_of_yr = -1
  max_eflh = 0
  ihr_max = -1
  (0..364).each do |_iday|
    eflh = 0
    ihr_start = hr_of_yr + 1
    (0..23).each do |_ihr|
      hr_of_yr += 1
      eflh += 1 if values[hr_of_yr] > 0
    end
    next unless eflh > max_eflh

    max_eflh = eflh
    # store index to first hour of day with max on hours
    ihr_max = ihr_start
  end
  # Create the schedules for the design days
  day_sch = OpenStudio::Model::ScheduleDay.new(model)
  day_sch.setName("#{sch_name} Winter Design Day")
  (0..23).each do |ihr|
    hr_of_yr = ihr_max + ihr
    next if values[hr_of_yr] == values[hr_of_yr + 1]

    day_sch.addValue(OpenStudio::Time.new(0, ihr + 1, 0, 0), values[hr_of_yr])
  end
  sch_ruleset.setWinterDesignDaySchedule(day_sch)

  day_sch = OpenStudio::Model::ScheduleDay.new(model)
  day_sch.setName("#{sch_name} Summer Design Day")
  (0..23).each do |ihr|
    hr_of_yr = ihr_max + ihr
    next if values[hr_of_yr] == values[hr_of_yr + 1]

    day_sch.addValue(OpenStudio::Time.new(0, ihr + 1, 0, 0), values[hr_of_yr])
  end
  sch_ruleset.setSummerDesignDaySchedule(day_sch)

  sch_ruleset
end
