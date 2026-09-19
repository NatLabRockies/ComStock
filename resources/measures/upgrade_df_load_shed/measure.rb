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
class DFLoadShed < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    'demand flexibility - thermostat and lighting control for load shedding'
  end

  # human readable description
  def description
    'This measure implements demand flexibility measure on daily thermostat and lighting control with load shed strategy, by adjusting thermostat setpoints (increasing the deadband) and/or Lighting Power Density (reflecting lighting dimming) corresponding to the peak schedule based on daily peak load prediction.'
  end

  # human readable description of modeling approach
  def modeler_description
    'This measure performs load prediction based on options of different methods or data sources. It generates daily peak schedule based on the load prediction, and then iterates through all applicable (electric) thermostats and/or lights to adjust the cooling and heating setpoints, as well as lighting dimming levels for daily peak window.'
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

    thermostat_control = OpenStudio::Measure::OSArgument.makeBoolArgument('thermostat_control', true)
    thermostat_control.setDisplayName('Enable thermostat control for demand flexibility load shedding?')
    thermostat_control.setDefaultValue(true)
    args << thermostat_control

    rebound_len = OpenStudio::Measure::OSArgument.makeIntegerArgument('rebound_len', true)
    rebound_len.setDisplayName('Length of rebound period after dispatch window (hour)')
    rebound_len.setDefaultValue(2)
    args << rebound_len

    sp_adjustment = OpenStudio::Measure::OSArgument.makeDoubleArgument('sp_adjustment', true)
    sp_adjustment.setDisplayName('Degrees C to Adjust Setpoint By')
    sp_adjustment.setDefaultValue(2.0)
    args << sp_adjustment

    lighting_control = OpenStudio::Measure::OSArgument.makeBoolArgument('lighting_control', true)
    lighting_control.setDisplayName('Enable lighting control for demand flexibility load shedding?')
    lighting_control.setDefaultValue(true)
    args << lighting_control

    light_adjustment_choices = ['absolute change', 'relative change']
    light_adjustment_method = OpenStudio::Ruleset::OSArgument.makeChoiceArgument('light_adjustment_method',
                                                                                 light_adjustment_choices, true)
    light_adjustment_method.setDisplayName('Method of lighting dimming (absolute change, relative change)')
    light_adjustment_method.setDescription('absolute change: percent change relative to fully ON lighting; relative change: percent change relative to current dimming level')
    light_adjustment_method.setDefaultValue('absolute change')
    args << light_adjustment_method

    light_adjustment = OpenStudio::Measure::OSArgument.makeDoubleArgument('light_adjustment', true)
    light_adjustment.setDisplayName('Percentage to decrease light dimming/LPD by (0-100)')
    light_adjustment.setDefaultValue(30.0)
    args << light_adjustment

    num_timesteps_in_hr = OpenStudio::Measure::OSArgument.makeIntegerArgument('num_timesteps_in_hr', true)
    num_timesteps_in_hr.setDisplayName('Number/Count of timesteps in an hour for sample simulations (will be fixed to 1 for grid peak load / emissions objective)')
    num_timesteps_in_hr.setDefaultValue(4)
    args << num_timesteps_in_hr

    choices = ['full baseline', 'bin sample', 'part year bin sample', 'fix', 'oat']
    load_prediction_method = OpenStudio::Ruleset::OSArgument.makeChoiceArgument('load_prediction_method', choices, true)
    load_prediction_method.setDisplayName('Method of load prediction or window determination reference')
    load_prediction_method.setDescription('Load prediction based on full baseline run, load prediction based on bin sample simulation, load prediction base on part year bin sample simulation, predetermined fixed schedule (no prediction), load peak prediction based on outdoor air temperature)')
    load_prediction_method.setDefaultValue('full baseline')
    args << load_prediction_method

    choices_strate = ['max savings', 'start with peak', 'end with peak', 'center with peak']
    peak_window_strategy = OpenStudio::Ruleset::OSArgument.makeChoiceArgument('peak_window_strategy', choices_strate,
                                                                              true)
    peak_window_strategy.setDisplayName('Peak windows determination strategy (max savings, start with peak, end with peak, center with peak)')
    peak_window_strategy.setDefaultValue('center with peak')
    args << peak_window_strategy

    choices_scenarios = %w[
      AER_95DecarbBy2035
      AER_95DecarbBy2050
      AER_HighRECost
      AER_LowRECost
      AER_MidCase
      LRMER_95DecarbBy2035_15
      LRMER_95DecarbBy2035_30
      LRMER_95DecarbBy2035_15_2025start
      LRMER_95DecarbBy2035_25_2025start
      LRMER_95DecarbBy2050_15
      LRMER_95DecarbBy2050_30
      LRMER_HighRECost_15
      LRMER_HighRECost_30
      LRMER_LowRECost_15
      LRMER_LowRECost_30
      LRMER_LowRECost_15_2025start
      LRMER_LowRECost_25_2025start
      LRMER_MidCase_15
      LRMER_MidCase_30
      LRMER_MidCase_15_2025start
      LRMER_MidCase_25_2025start
    ]
    cambium_scenario = OpenStudio::Ruleset::OSArgument.makeChoiceArgument('cambium_scenario', choices_scenarios, true)
    cambium_scenario.setDisplayName('Cambium scenario of emission factor')
    cambium_scenario.setDescription('For emission objective only')
    cambium_scenario.setDefaultValue('LRMER_MidCase_15')
    args << cambium_scenario

    pv = OpenStudio::Measure::OSArgument.makeBoolArgument('pv', true)
    pv.setDisplayName('Enable PV upgrade?')
    pv.setDescription('For upgrade package run.')
    pv.setDefaultValue(false)
    args << pv

    # apply_measure = OpenStudio::Measure::OSArgument.makeBoolArgument('apply_measure', true)
    # apply_measure.setDisplayName('Apply measure?')
    # apply_measure.setDescription('')
    # apply_measure.setDefaultValue(true)
    # args << apply_measure

    args
  end

  def temp_setp_adjust_hourly_based_on_sch(peak_sch, sp_adjustment)
    peak_sch.map { |a| sp_adjustment * a }
  end

  def light_adj_based_on_sch(peak_sch, light_adjustment)
    peak_sch.map { |a| light_adjustment / 100.0 * a }
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

  def assign_clgsch_to_thermostats(model, applicable_clg_thermostats, runner, clgsp_adjustment_values)
    yd = model.getYearDescription
    start_date = yd.makeDate(1, 1)
    clg_set_schs = {}
    nts = 0
    applicable_clg_thermostats.each do |thermostat|
      # setup new cooling setpoint schedule
      clg_set_sch = thermostat.coolingSetpointTemperatureSchedule
      if clg_set_sch.empty?
        runner.registerWarning("Thermostat '#{thermostat.name}' doesn't have a cooling setpoint schedule")
      else
        # clone of not already in hash
        if clg_set_schs.key?(clg_set_sch.get.name.to_s)
          # exist
          new_clg_set_sch = clg_set_schs[clg_set_sch.get.name.to_s]
        else
          # new
          schedule = clg_set_sch.get.clone(model)
          schedule = schedule.to_Schedule.get
          schedule_8760 = get_interval_schedule_from_schedule_ruleset(model, schedule.to_ScheduleRuleset.get,
                                                                      clgsp_adjustment_values.size)
          if schedule_8760.size == clgsp_adjustment_values.size
            nums = [schedule_8760, clgsp_adjustment_values]
          else
            msize = [schedule_8760.size, clgsp_adjustment_values.size].min
            nums = [schedule_8760.take(msize), clgsp_adjustment_values.take(msize)]
          end
          new_schedule_8760 = nums.transpose.map(&:sum)
          schedule_values = OpenStudio::Vector.new(new_schedule_8760.length, 0.0)
          new_schedule_8760.each_with_index do |val, i|
            schedule_values[i] = val
          end
          # make a schedule
          case schedule_values.size
          when 35_040, 35_136
            interval_hr = OpenStudio::Time.new(0, 0, 15)
          when 8760, 8784
            interval_hr = OpenStudio::Time.new(0, 1, 0)
          else
            runner.registerError('Interval not supported')
            return false
          end
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
      end
    end
    nts
  end

  def assign_heatsch_to_thermostats(model, applicable_htg_thermostats, runner, heatsp_adjustment_values)
    yd = model.getYearDescription
    start_date = yd.makeDate(1, 1)
    heat_set_schs = {}
    nts = 0
    # thermostats = model.getThermostatSetpointDualSetpoints
    applicable_htg_thermostats.each do |thermostat|
      # setup new cooling setpoint schedule
      heat_set_sch = thermostat.heatingSetpointTemperatureSchedule
      if heat_set_sch.empty?
        runner.registerWarning("Thermostat '#{thermostat.name}' doesn't have a heating setpoint schedule")
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
          case schedule_values.size
          when 35_040, 35_136
            interval_hr = OpenStudio::Time.new(0, 0, 15)
          when 8760, 8784
            interval_hr = OpenStudio::Time.new(0, 1, 0)
          else
            runner.registerError('Interval not supported')
            return false
          end
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

  def adjust_lighting_sch(model, runner, light_adjustment_method, light_adj_values)
    yd = model.getYearDescription
    start_date = yd.makeDate(1, 1)
    lights = model.getLightss
    # create a hash to map the old schedule name to the new schedule
    light_schedules = {}
    nl = 0
    nla = 0
    lights.each do |light|
      puts "light: #{light.name}"
      light_sch = light.schedule
      # puts "light_sch: #{light_sch}"
      if light_sch.empty?
        runner.registerWarning("#{light.name} doesn't have a schedule.")
      else
        if light_schedules.key?(light_sch.get.name.to_s)
          new_light_sch = light_schedules[light_sch.get.name.to_s]
        else
          schedule = light_sch.get.clone(model)
          schedule = schedule.to_Schedule.get
          # convert old sch to time series
          schedule_ts = get_interval_schedule_from_schedule_ruleset(model, schedule.to_ScheduleRuleset.get,
                                                                    light_adj_values.size)
          # puts("--- schedule_ts.size = #{schedule_ts.size}")
          case light_adjustment_method
          when 'absolute change'
            new_schedule_ts = schedule_ts.map.with_index do |val, ind|
              adjusted_val = val - light_adj_values[ind]
              if val < 0.05
                adjusted_val.clamp(val, 0.05)
              else
                adjusted_val.clamp(0.05, val)
              end
            end
          when 'relative change'
            new_schedule_ts = if schedule_ts.size <= light_adj_values.size
                                schedule_ts.map.with_index { |val, ind| val * (1.0 - light_adj_values[ind]) }
                              else
                                light_adj_values.map.with_index { |val, ind| (1.0 - val) * schedule_ts[ind] }
                              end
          else
            raise 'Not supported light adjustment method'
          end
          # puts("--- new_schedule_ts.size = #{new_schedule_ts.size}")
          schedule_values = OpenStudio::Vector.new(new_schedule_ts.length, 0.0)
          new_schedule_ts.each_with_index do |val, i|
            schedule_values[i] = val
          end
          # make a schedule
          case schedule_values.size
          when 35_040, 35_136
            interval_hr = OpenStudio::Time.new(0, 0, 15)
          when 8760, 8784
            interval_hr = OpenStudio::Time.new(0, 1, 0)
          else
            runner.registerError('Interval not supported')
            return false
          end
          timeseries = OpenStudio::TimeSeries.new(start_date, interval_hr, schedule_values, 'C')
          new_light_sch = OpenStudio::Model::ScheduleInterval.fromTimeSeries(timeseries, model)
          # puts("###DEBUG new_light_sch=#{new_light_sch.get}")
          if new_light_sch.empty?
            runner.registerError('Unable to make schedule')
            return false
          end
          new_light_sch = new_light_sch.get
          new_light_sch.setName("#{light_sch.get.name} df_adjusted")
          # add to the hash
          light_schedules[light_sch.get.name.to_s] = new_light_sch
        end
        light.setSchedule(new_light_sch)
        nla += 1
      end
      nl += 1
    end
    [nl, nla]
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
    super(model, runner, user_arguments) # Do **NOT** remove this line

    # use the built-in error checking
    return false unless runner.validateUserArguments(arguments(model), user_arguments)

    ############################################
    # assign the user inputs to variables
    ############################################
    demand_flexibility_objective = runner.getStringArgumentValue('demand_flexibility_objective', user_arguments)
    peak_len = runner.getIntegerArgumentValue('peak_len', user_arguments)
    thermostat_control = runner.getBoolArgumentValue('thermostat_control', user_arguments)
    rebound_len = runner.getIntegerArgumentValue('rebound_len', user_arguments)
    sp_adjustment = runner.getDoubleArgumentValue('sp_adjustment', user_arguments)
    lighting_control = runner.getBoolArgumentValue('lighting_control', user_arguments)
    light_adjustment_method = runner.getStringArgumentValue('light_adjustment_method', user_arguments)
    light_adjustment = runner.getDoubleArgumentValue('light_adjustment', user_arguments)
    num_timesteps_in_hr = runner.getIntegerArgumentValue('num_timesteps_in_hr', user_arguments)
    load_prediction_method = runner.getStringArgumentValue('load_prediction_method', user_arguments)
    peak_window_strategy = runner.getStringArgumentValue('peak_window_strategy', user_arguments)
    cambium_scenario = runner.getStringArgumentValue('cambium_scenario', user_arguments)
    pv = runner.getBoolArgumentValue('pv', user_arguments)
    # apply_measure = runner.getBoolArgumentValue('apply_measure', user_arguments)

    # # adding output variables (for debugging)
    # out_vars = [
    #   'Lights Electricity Energy',
    #   'Lights Electricity Rate',
    #   'Zone Lights Electricity Energy',
    #   'Zone Lights Electricity Rate',
    #   'Schedule Value'
    # ]
    # out_vars.each do |out_var_name|
    #     ov = OpenStudio::Model::OutputVariable.new('ov', model)
    #     ov.setKeyValue('*')
    #     ov.setReportingFrequency('timestep')
    #     ov.setVariableName(out_var_name)
    # end

    ############################################
    # Applicability check
    ############################################
    puts('### ============================================================')
    puts('### Applicability check...')
    if demand_flexibility_objective == 'grid peak load'
      grid_region = model.getBuilding.additionalProperties.getFeatureAsString('grid_region')
      raise 'Unable to find grid region in model building additional properties' unless grid_region.is_initialized

      grid_region = grid_region.get
      if %w[AKMS AKGD HIMS HIOA].include? grid_region
        runner.registerAsNotApplicable('applicability not passed for grid load data availability')
        return true
      else
        puts("--- grid load data applicability passed with grid region #{grid_region}")
      end
    end
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
    if isapplicable_buildingtype(model, runner, applicable_building_types)
      puts('--- building type applicability passed')
    else
      runner.registerAsNotApplicable('applicability not passed for building type')
      return true
    end

    if thermostat_control == true
      applicable_clg_thermostats, applicable_htg_thermostats, nts = applicable_thermostats(model)
      # puts(applicable_clg_thermostats.size)
      # puts(applicable_htg_thermostats.size)
      if !applicable_clg_thermostats.empty? && !applicable_htg_thermostats.empty?
        puts('--- electric cooling and heating applicability passed')
      elsif !applicable_clg_thermostats.empty?
        puts('--- electric cooling applicability passed')
      elsif !applicable_htg_thermostats.empty?
        puts('--- electric heating applicability passed')
      else
        runner.registerAsNotApplicable('applicability not passed for electric cooling and heating')
        return true
      end
    end

    # # applicability: don't apply measure if specified in input
    # if apply_measure == false
    #   runner.registerFinalCondition('Measure is not applied based on user input.')
    #   return true
    # end

    ############################################
    # Call PV upgrade measure based on user input
    ############################################
    condition_initial_pv = ''
    condition_final_pv = ''
    if pv == true
      puts('### ============================================================')
      puts('### Applying PV measure...')
      runner.registerInfo('Running PV measure....')
      results_pv, runner = call_pv(model, runner)
      condition_initial_pv = results_pv.stepInitialCondition.get
      condition_final_pv = results_pv.stepFinalCondition.get
    end

    ############################################
    # Register initial condition
    ############################################
    if thermostat_control == true
      condition_initial_tstat = "The building initially has #{nts} thermostats, of which #{applicable_clg_thermostats.size} are associated with electric cooling and #{applicable_htg_thermostats.size} are associated with electric heating."
    else
      condition_initial_tstat = 'Thermostat control for load shedding is not enabled.'
    end
    condition_initial_light = if lighting_control == true
                                'The building is applicable for the demand flexibility lighting control measure.'
                              else
                                'Lighting control for load shedding is not enabled.'
                              end
    condition_initial = [condition_initial_tstat, condition_initial_light,
                         condition_initial_pv].reject(&:empty?).join(' | ')
    runner.registerInitialCondition(condition_initial)

    ############################################
    # Load prediction
    ############################################
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
        y_seed = run_samples(model, selectdays, num_timesteps_in_hr)
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
    # Emissions prediction
    ############################################

    if demand_flexibility_objective == 'emissions'
      puts('### ============================================================')
      puts('### Predicting emissions...')
      egrid_co2e_kg_per_mwh, cambium_co2e_kg_per_mwh = read_emission_factors(model, scenario = cambium_scenario)
      hourly_emissions_kg = if cambium_co2e_kg_per_mwh == []
                              emissions_prediction(annual_load, factor = egrid_co2e_kg_per_mwh, num_timesteps_in_hr)
                            else
                              emissions_prediction(annual_load, factor = cambium_co2e_kg_per_mwh, num_timesteps_in_hr)
                            end
      puts("--- hourly_emissions_kg.size = #{hourly_emissions_kg.size}")
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
        # template = 'ComStock 90.1-2019'
        # std = Standard.build(template)
        # climate_zone = std.model_standards_climate_zone(model)
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
        peak_schedule, peak_schedule_htg = peak_schedule_generation_fix(cz, oat, rebound_len = 0, prepeak_len = 0,
                                                                        season = 'all')
      when 'oat'
        puts('### OAT-based schedule...')
        peak_schedule, peak_schedule_htg = peak_schedule_generation_oat(oat, peak_len, peak_lag = 2, rebound_len,
                                                                        prepeak_len = 0, season = 'all')
      else
        puts('### Predictive schedule...')
        peak_schedule = peak_schedule_generation(annual_load, oat, peak_len, num_timesteps_in_hr, peak_window_strategy,
                                                 rebound_len = 0, prepeak_len = 0, season = 'all')
      end
    when 'grid peak load'
      puts('### Grid predictive schedule...')
      peak_schedule = peak_schedule_generation(annual_load, oat, peak_len, num_timesteps_in_hr = 1,
                                               peak_window_strategy, rebound_len = 0, prepeak_len = 0, season = 'all')
    when 'emissions'
      puts('### Creating peak schedule for emissions reduction...')
      peak_schedule = peak_schedule_generation(hourly_emissions_kg, oat, peak_len, num_timesteps_in_hr = 1,
                                               peak_window_strategy, rebound_len = 0, prepeak_len = 0, season = 'all')
    else
      runner.registerError('Not supported objective.')
    end
    # puts("--- peak_schedule = #{peak_schedule}")
    puts("--- peak_schedule.size = #{peak_schedule.size}")

    ############################################
    # Update thermostat setpoint schedule
    ############################################
    if thermostat_control == true
      puts('### ============================================================')
      nts_clg = 0
      nts_htg = 0
      unless applicable_clg_thermostats.empty?
        puts('### Creating cooling setpoint adjustment schedule...')
        clgsp_adjustment_values = temp_setp_adjust_hourly_based_on_sch(peak_schedule, sp_adjustment)
        # puts("--- clgsp_adjustment_values = #{clgsp_adjustment_values}")
        puts("--- clgsp_adjustment_values.size = #{clgsp_adjustment_values.size}")
        puts('### Updating thermostat cooling setpoint schedule...')
        nts_clg = assign_clgsch_to_thermostats(model, applicable_clg_thermostats, runner, clgsp_adjustment_values)
      end
      unless applicable_htg_thermostats.empty?
        puts('### Creating heating setpoint adjustment schedule...')
        heatsp_adjustment_values = temp_setp_adjust_hourly_based_on_sch(peak_schedule, sp_adjustment = -sp_adjustment)
        # puts("--- heatsp_adjustment_values = #{heatsp_adjustment_values}")
        puts("--- heatsp_adjustment_values.size = #{heatsp_adjustment_values.size}")
        puts('### Updating thermostat cooling setpoint schedule...')
        nts_htg = assign_heatsch_to_thermostats(model, applicable_htg_thermostats, runner, heatsp_adjustment_values)
      end
      condition_final_tstat = "Updated #{nts_clg}/#{applicable_clg_thermostats.size} thermostat cooling setpoint schedules and #{nts_htg}/#{applicable_htg_thermostats.size} thermostat heating setpoint schedules to model, with #{sp_adjustment.abs} degree C setback for #{peak_len} hours of daily peak window and rebound in #{rebound_len} hours after peak, using #{load_prediction_method} simulation for load prediction."
    else
      condition_final_tstat = 'No thermostat setpoint schedule updated.'
    end

    ############################################
    # Update lighting schedule
    ############################################
    if lighting_control == true
      puts('### ============================================================')
      puts('### Creating lighting factor values...')
      light_adj_values = light_adj_based_on_sch(peak_schedule, light_adjustment)
      # puts("--- light_adj_values = #{light_adj_values}")
      puts("--- light_adj_values.size = #{light_adj_values.size}")
      puts('### Updating lighting schedule...')
      nl, nla = adjust_lighting_sch(model, runner, light_adjustment_method, light_adj_values)
      condition_final_light = "Updated #{nla}/#{nl} lighting schedules."
    else
      condition_final_light = 'No lighting schedule updated.'
    end

    ############################################
    # Register final condition
    ############################################
    condition_final = [condition_final_tstat, condition_final_light, condition_final_pv].reject(&:empty?).join(' | ')
    runner.registerFinalCondition(condition_final)
    true
  end
end

# register the measure to be used by the application
DFLoadShed.new.registerWithApplication
