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

def cambium_emissions_scenarios
  emissions_scenarios = [
    'AER_95DecarbBy2035',
    'AER_95DecarbBy2050',
    'AER_HighRECost',
    'AER_LowRECost',
    'AER_MidCase',
    'LRMER_95DecarbBy2035_15',
    'LRMER_95DecarbBy2035_30',
    'LRMER_95DecarbBy2035_15_2025start',
    'LRMER_95DecarbBy2035_25_2025start',
    'LRMER_95DecarbBy2050_15',
    'LRMER_95DecarbBy2050_30',
    'LRMER_HighRECost_15',
    'LRMER_HighRECost_30',
    'LRMER_LowRECost_15',
    'LRMER_LowRECost_30',
    'LRMER_LowRECost_15_2025start',
    'LRMER_LowRECost_25_2025start',
    'LRMER_MidCase_15',
    'LRMER_MidCase_30',
    'LRMER_MidCase_15_2025start',
    'LRMER_MidCase_25_2025start'
  ]
  return emissions_scenarios
end

def grid_regions
  grid_regions = [
    'AZNMc',
    'AKGD',
    'AKMS',
    'CAMXc',
    'ERCTc',
    'FRCCc',
    'HIMS',
    'HIOA',
    'MROEc',
    'MROWc',
    'NEWEc',
    'NWPPc',
    'NYSTc',
    'RFCEc',
    'RFCMc',
    'RFCWc',
    'RMPAc',
    'SPNOc',
    'SPSOc',
    'SRMVc',
    'SRMWc',
    'SRSOc',
    'SRTVc',
    'SRVCc'
  ]
  return grid_regions
end

### convert day of year to month-day date
def day_of_year_to_date(year, day_of_year)
  date = Date.new(year, 1, 1) + day_of_year - 1
  month = date.month
  day = date.day
  return month, day
end

### if year is leap year
def leap_year?(year)
  ((year % 4).zero? && !(year % 100).zero?) || (year % 400).zero?
end

### obtain oat profile from epw file
def read_epw(model, epw_path = nil)
  if epw_path.nil?
    # get EPWFile class from model
    raise 'Cannot find weather file from model using weatherFile class' unless model.weatherFile.is_initialized

    weatherfile = model.weatherFile.get
    raise 'Cannot find weather file from model using EPWFile class' unless weatherfile.file.is_initialized

    epw_file = weatherfile.file.get
  else
    puts("Override with given epw from #{epw_path}")
    epw_file = OpenStudio::EpwFile.new(epw_path)
  end
  field = 'DryBulbTemperature'
  weather_ts = epw_file.getTimeSeries(field)
  raise "FAIL, could not retrieve field: #{field} from #{epw_file}" unless weather_ts.is_initialized

  weather_ts = weather_ts.get
  # Put dateTimes into array
  times = []
  os_times = weather_ts.dateTimes
  for i in 0..(os_times.size - 1)
    times << os_times[i].toString
  end
  # Put values into array
  vals = []
  os_vals = weather_ts.values
  for i in 0..(os_vals.size - 1)
    vals << os_vals[i]
  end
  return vals
end

### create bins based on temperature profile and select sample days in bins
def create_binsamples(oat, option)
  if oat.size == 8784
    nd = 366
  else
    nd = 365
  end
  combbins = {
    'ext-hot' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'hot' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'mild' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'cool-mild' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'cool' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'cold' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] }
  }
  selectdays = {
    'ext-hot' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'hot' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'mild' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'cool-mild' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'cool' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'cold' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] }
  }
  (0..nd - 1).each do |d|
    oatmax = oat[(24 * d)..(24 * (d + 1)) - 1].max
    oatmaxind = oat[(24 * d)..(24 * (d + 1)) - 1].index(oat[(24 * d)..(24 * (d + 1)) - 1].max)
    if oatmax >= 32.0
      if (oatmaxind >= 9.0) && (oatmaxind <= 11.0)
        combbins['ext-hot']['morning'] << (d + 1)
      elsif (oatmaxind > 11.0) && (oatmaxind <= 14.0)
        combbins['ext-hot']['noon'] << (d + 1)
      elsif (oatmaxind > 14.0) && (oatmaxind <= 15.0)
        combbins['ext-hot']['afternoon'] << (d + 1)
      elsif (oatmaxind > 15.0) && (oatmaxind <= 17.0)
        combbins['ext-hot']['late-afternoon'] << (d + 1)
      elsif (oatmaxind > 17.0) && (oatmaxind <= 20.0)
        combbins['ext-hot']['evening'] << (d + 1)
      else
        combbins['ext-hot']['other'] << (d + 1)
      end
    elsif oatmax >= 30.0
      if (oatmaxind >= 9.0) && (oatmaxind <= 11.0)
        combbins['hot']['morning'] << (d + 1)
      elsif (oatmaxind > 11.0) && (oatmaxind <= 14.0)
        combbins['hot']['noon'] << (d + 1)
      elsif (oatmaxind > 14.0) && (oatmaxind <= 15.0)
        combbins['hot']['afternoon'] << (d + 1)
      elsif (oatmaxind > 15.0) && (oatmaxind <= 17.0)
        combbins['hot']['late-afternoon'] << (d + 1)
      elsif (oatmaxind > 17.0) && (oatmaxind <= 20.0)
        combbins['hot']['evening'] << (d + 1)
      else
        combbins['hot']['other'] << (d + 1)
      end
    elsif oatmax >= 26.0
      if (oatmaxind >= 9.0) && (oatmaxind <= 11.0)
        combbins['mild']['morning'] << (d + 1)
      elsif (oatmaxind > 11.0) && (oatmaxind <= 14.0)
        combbins['mild']['noon'] << (d + 1)
      elsif (oatmaxind > 14.0) && (oatmaxind <= 15.0)
        combbins['mild']['afternoon'] << (d + 1)
      elsif (oatmaxind > 15.0) && (oatmaxind <= 17.0)
        combbins['mild']['late-afternoon'] << (d + 1)
      elsif (oatmaxind > 17.0) && (oatmaxind <= 20.0)
        combbins['mild']['evening'] << (d + 1)
      else
        combbins['mild']['other'] << (d + 1)
      end
    elsif oatmax >= 20.0
      if (oatmaxind >= 9.0) && (oatmaxind <= 11.0)
        combbins['cool-mild']['morning'] << (d + 1)
      elsif (oatmaxind > 11.0) && (oatmaxind <= 14.0)
        combbins['cool-mild']['noon'] << (d + 1)
      elsif (oatmaxind > 14.0) && (oatmaxind <= 15.0)
        combbins['cool-mild']['afternoon'] << (d + 1)
      elsif (oatmaxind > 15.0) && (oatmaxind <= 17.0)
        combbins['cool-mild']['late-afternoon'] << (d + 1)
      elsif (oatmaxind > 17.0) && (oatmaxind <= 20.0)
        combbins['cool-mild']['evening'] << (d + 1)
      else
        combbins['cool-mild']['other'] << (d + 1)
      end
    elsif oatmax >= 15.0
      if (oatmaxind >= 9.0) && (oatmaxind <= 11.0)
        combbins['cool']['morning'] << (d + 1)
      elsif (oatmaxind > 11.0) && (oatmaxind <= 14.0)
        combbins['cool']['noon'] << (d + 1)
      elsif (oatmaxind > 14.0) && (oatmaxind <= 15.0)
        combbins['cool']['afternoon'] << (d + 1)
      elsif (oatmaxind > 15.0) && (oatmaxind <= 17.0)
        combbins['cool']['late-afternoon'] << (d + 1)
      elsif (oatmaxind > 17.0) && (oatmaxind <= 20.0)
        combbins['cool']['evening'] << (d + 1)
      else
        combbins['cool']['other'] << (d + 1)
      end
    else
      if (oatmaxind >= 9.0) && (oatmaxind <= 11.0)
        combbins['cold']['morning'] << (d + 1)
      elsif (oatmaxind > 11.0) && (oatmaxind <= 14.0)
        combbins['cold']['noon'] << (d + 1)
      elsif (oatmaxind > 14.0) && (oatmaxind <= 15.0)
        combbins['cold']['afternoon'] << (d + 1)
      elsif (oatmaxind > 15.0) && (oatmaxind <= 17.0)
        combbins['cold']['late-afternoon'] << (d + 1)
      elsif (oatmaxind > 17.0) && (oatmaxind <= 20.0)
        combbins['cold']['evening'] << (d + 1)
      else
        combbins['cold']['other'] << (d + 1)
      end
    end
  end
  ns = 0
  srand(42)
  max_doys = []
  combbins.keys.each do |key|
    combbins[key].keys.each do |keykey|
      if combbins[key][keykey].length > 14
        case option
        when 'random'
          selectdays[key][keykey] = combbins[key][keykey].sample(3)
        when 'sort'
          selectdays[key][keykey] = combbins[key][keykey].sort.take(3).to_a
        else
          raise 'Wrong sampling option'
        end
        ns += 3
      elsif combbins[key][keykey].length > 7
        case option
        when 'random'
          selectdays[key][keykey] = combbins[key][keykey].sample(2)
        when 'sort'
          selectdays[key][keykey] = combbins[key][keykey].sort.take(2).to_a
        else
          raise 'Wrong sampling option'
        end
        ns += 2
      elsif !combbins[key][keykey].empty?
        case option
        when 'random'
          selectdays[key][keykey] = combbins[key][keykey].sample(1)
        when 'sort'
          selectdays[key][keykey] = combbins[key][keykey].sort.take(1).to_a
        else
          raise 'Wrong sampling option'
        end
        ns += 1
      end
      if selectdays[key][keykey] != []
        max_doys << selectdays[key][keykey].max
      end
    end
  end
  max_doy = max_doys.max
  return combbins, selectdays, ns, max_doy
end

### run simulation on selected day of year
def model_run_simulation_on_doy(model, doy, num_timesteps_in_hr, epw_path = nil, run_dir = "#{Dir.pwd}/Run")
  ### reference: https://github.com/NREL/openstudio-standards/blob/master/lib/openstudio-standards/utilities/simulation.rb#L187
  # Make the directory if it doesn't exist
  FileUtils.mkdir_p(run_dir)

  # Save the model to energyplus idf
  osm_name = 'in.osm'
  osw_name = 'in.osw'
  OpenStudio.logFree(OpenStudio::Debug, 'openstudio.model.Model', "Starting simulation here: #{run_dir}.")
  OpenStudio.logFree(OpenStudio::Info, 'openstudio.model.Model', "Started simulation #{run_dir} at #{Time.now.strftime('%T.%L')}")
  year = model.getYearDescription.calendarYear.to_i
  if doy == 1
    begin_month, begin_day = day_of_year_to_date(year, doy)
    end_month, end_day = day_of_year_to_date(year, doy + 1)
  else
    begin_month, begin_day = day_of_year_to_date(year, doy)
    end_month, end_day = day_of_year_to_date(year, doy)
  end
  # store original config
  begin_month_orig = model.getRunPeriod.getBeginMonth
  begin_day_orig = model.getRunPeriod.getBeginDayOfMonth
  end_month_orig = model.getRunPeriod.getEndMonth
  end_day_orig = model.getRunPeriod.getEndDayOfMonth
  num_timesteps_in_hr_orig = model.getTimestep.numberOfTimestepsPerHour
  zonesizing_orig = model.getSimulationControl.doZoneSizingCalculation
  syssizing_orig = model.getSimulationControl.doSystemSizingCalculation
  plantsizing_orig = model.getSimulationControl.doPlantSizingCalculation
  ### reference: SetRunPeriod measure on BCL
  model.getRunPeriod.setBeginMonth(begin_month)
  model.getRunPeriod.setBeginDayOfMonth(begin_day)
  model.getRunPeriod.setEndMonth(end_month)
  model.getRunPeriod.setEndDayOfMonth(end_day)
  if num_timesteps_in_hr != 4
    model.getTimestep.setNumberOfTimestepsPerHour(num_timesteps_in_hr)
  end
  model.getSimulationControl.setDoZoneSizingCalculation(false)
  model.getSimulationControl.setDoSystemSizingCalculation(false)
  model.getSimulationControl.setDoPlantSizingCalculation(false)
  osm_path = OpenStudio::Path.new("#{run_dir}/#{osm_name}")
  osw_path = OpenStudio::Path.new("#{run_dir}/#{osw_name}")
  model.save(osm_path, true)
  # Set up the simulation
  # Find the weather file
  if epw_path.nil?
    epw_path = model.weatherFile.get.path
    if epw_path.empty?
      return false
    end

    epw_path = epw_path.get
    puts epw_path
  end
  # close current sql file
  model.resetSqlFile
  # initialize OSW
  begin
    workflow = OpenStudio::WorkflowJSON.new
  rescue NameError
    raise 'Cannot run simulation with OSW approach'
  end
  sql_path = nil
  OpenStudio.logFree(OpenStudio::Debug, 'openstudio.model.Model', 'Running with OS 2.x WorkflowJSON.')
  # Copy the weather file to this directory
  epw_name = 'in.epw'
  begin
    FileUtils.copy(epw_path.to_s, "#{run_dir}/#{epw_name}")
  rescue StandardError
    OpenStudio.logFree(OpenStudio::Error, 'openstudio.model.Model', "Due to limitations on Windows file path lengths, this measure won't work unless your project is located in a directory whose filepath is less than 90 characters long, including slashes.")
    return false
  end
  workflow.setSeedFile(osm_name)
  workflow.setWeatherFile(epw_name)
  workflow.saveAs(File.absolute_path(osw_path.to_s))
  # 'touch' the weather file - for some odd reason this fixes the simulation not running issue we had on openstudio-server.
  # Removed for until further investigation completed.
  # FileUtils.touch("#{run_dir}/#{epw_name}")
  cli_path = OpenStudio.getOpenStudioCLI
  cmd = "\"#{cli_path}\" run -w \"#{osw_path}\""
  # Run the sizing run
  OpenstudioStandards.run_command(cmd)
  OpenStudio.logFree(OpenStudio::Info, 'openstudio.model.Model', "Finished simulation #{run_dir} at #{Time.now.strftime('%T.%L')}")
  # get sql
  sql_path = OpenStudio::Path.new("#{run_dir}/run/eplusout.sql")
  raise 'sql file not found.' unless File.exist?(sql_path.to_s)

  sql_file = OpenStudio::SqlFile.new(sql_path)

  # check available timeseries extraction options
  available_env_periods = sql_file.availableEnvPeriods.to_a
  available_time_series = sql_file.availableTimeSeries.to_a
  available_reporting_frequencies = []
  available_env_periods.each do |envperiod|
    sql_file.availableReportingFrequencies(envperiod).to_a.each do |repfreq|
      available_reporting_frequencies << repfreq
    end
  end
  raise "options for availableEnvPeriods are not just one: #{available_env_periods}" unless available_env_periods.size == 1

  envperiod = 'RUN PERIOD 1'
  raise "envperiod of #{envperiod} not included in available options: #{available_env_periods}" unless available_env_periods.include?(envperiod)

  timeseriesname = 'Electricity:Facility'
  raise "timeseriesname of #{timeseriesname} not included in available options: #{available_time_series}" unless available_time_series.include?(timeseriesname)

  reportingfrequency = 'Hourly' # 'Zone Timestep'
  unless available_reporting_frequencies.include?(reportingfrequency)
    reportingfrequency = 'Zone Timestep'
    raise "reportingfrequency of #{reportingfrequency} not included in available options: #{available_reporting_frequencies}" unless available_reporting_frequencies.include?(reportingfrequency)
  end
  electricity_results = sql_file.timeSeries(envperiod, reportingfrequency, timeseriesname)
  vals = []
  electricity_results.each do |electricity_result|
    elec_vals = electricity_result.values
    for i in 0..(elec_vals.size - 1)
      vals << elec_vals[i]
    end
  end
  # raise if vals is empty
  if vals.empty?
    puts('Hourly reporting frequency return empty data. Use Zone Timestep.')
    reportingfrequency = 'Zone Timestep'
    raise "reportingfrequency of #{reportingfrequency} not included in available options: #{available_reporting_frequencies}" unless available_reporting_frequencies.include?(reportingfrequency)

    electricity_results = sql_file.timeSeries(envperiod, reportingfrequency, timeseriesname)
    vals = []
    electricity_results.each do |electricity_result|
      elec_vals = electricity_result.values
      for i in 0..(elec_vals.size - 1)
        vals << elec_vals[i]
      end
    end
    if vals.empty?
      raise 'load profile for the sample run returned empty'
    end
  end
  # reset model config for upgrade run
  model.getRunPeriod.setBeginMonth(begin_month_orig)
  model.getRunPeriod.setBeginDayOfMonth(begin_day_orig)
  model.getRunPeriod.setEndMonth(end_month_orig)
  model.getRunPeriod.setEndDayOfMonth(end_day_orig)
  model.getTimestep.setNumberOfTimestepsPerHour(num_timesteps_in_hr_orig)
  model.getSimulationControl.setDoZoneSizingCalculation(zonesizing_orig)
  model.getSimulationControl.setDoSystemSizingCalculation(syssizing_orig)
  model.getSimulationControl.setDoPlantSizingCalculation(plantsizing_orig)
  return vals
end

### run simulation on all sample days of year
def run_samples(model, selectdays, num_timesteps_in_hr, epw_path = nil)
  y_seed = {
    'ext-hot' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'hot' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'mild' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'cool-mild' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'cool' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'cold' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] }
  }
  selectdays.keys.each do |key|
    selectdays[key].keys.each do |keykey|
      ns = selectdays[key][keykey].length.to_f
      selectdays[key][keykey].each do |doy|
        puts "Simulation on day of year: #{doy}"
        yd = model_run_simulation_on_doy(model, doy, num_timesteps_in_hr, epw_path)
        if yd.size > 24
          averages = []
          yd.each_slice(yd.size / 24) do |slice|
            average = slice.reduce(:+).to_f
            averages << average
          end
          yd = averages
        end
        if ns == 1
          y_seed[key][keykey] = yd
        elsif ns > 1
          if y_seed[key][keykey] == []
            y_seed[key][keykey] = yd.map { |a| a / ns }
          else
            y_seed[key][keykey] = yd.zip(y_seed[key][keykey]).map { |a, b| ((a / ns) + b) }
          end
        end
      end
    end
  end
  return y_seed
end

### run simulation on part of year
def model_run_simulation_on_part_of_year(model, max_doy, num_timesteps_in_hr, epw_path = nil, run_dir = "#{Dir.pwd}/Run")
  ### reference: https://github.com/NREL/openstudio-standards/blob/master/lib/openstudio-standards/utilities/simulation.rb#L187
  # Make the directory if it doesn't exist
  FileUtils.mkdir_p(run_dir)

  # Save the model to energyplus idf
  osm_name = 'in.osm'
  osw_name = 'in.osw'
  OpenStudio.logFree(OpenStudio::Debug, 'openstudio.model.Model', "Starting simulation here: #{run_dir}.")
  OpenStudio.logFree(OpenStudio::Info, 'openstudio.model.Model', "Started simulation #{run_dir} at #{Time.now.strftime('%T.%L')}")
  year = model.getYearDescription.calendarYear.to_i
  begin_month, begin_day = day_of_year_to_date(year, 1)
  end_month, end_day = day_of_year_to_date(year, max_doy)
  # store original config
  begin_month_orig = model.getRunPeriod.getBeginMonth
  begin_day_orig = model.getRunPeriod.getBeginDayOfMonth
  end_month_orig = model.getRunPeriod.getEndMonth
  end_day_orig = model.getRunPeriod.getEndDayOfMonth
  num_timesteps_in_hr_orig = model.getTimestep.numberOfTimestepsPerHour
  zonesizing_orig = model.getSimulationControl.doZoneSizingCalculation
  syssizing_orig = model.getSimulationControl.doSystemSizingCalculation
  plantsizing_orig = model.getSimulationControl.doPlantSizingCalculation
  ### reference: SetRunPeriod measure on BCL
  model.getRunPeriod.setBeginMonth(begin_month)
  model.getRunPeriod.setBeginDayOfMonth(begin_day)
  model.getRunPeriod.setEndMonth(end_month)
  model.getRunPeriod.setEndDayOfMonth(end_day)
  if num_timesteps_in_hr != 4
    model.getTimestep.setNumberOfTimestepsPerHour(num_timesteps_in_hr)
  end
  model.getSimulationControl.setDoZoneSizingCalculation(false)
  model.getSimulationControl.setDoSystemSizingCalculation(false)
  model.getSimulationControl.setDoPlantSizingCalculation(false)
  osm_path = OpenStudio::Path.new("#{run_dir}/#{osm_name}")
  osw_path = OpenStudio::Path.new("#{run_dir}/#{osw_name}")
  model.save(osm_path, true)
  # Set up the simulation
  # Find the weather file
  if epw_path.nil?
    epw_path = model.weatherFile.get.path
    if epw_path.empty?
      return false
    end

    epw_path = epw_path.get
  end
  # close current sql file
  model.resetSqlFile
  # initialize OSW
  begin
    workflow = OpenStudio::WorkflowJSON.new
  rescue NameError
    raise 'Cannot run simulation with OSW approach'
  end
  sql_path = nil
  OpenStudio.logFree(OpenStudio::Debug, 'openstudio.model.Model', 'Running with OS 2.x WorkflowJSON.')
  # Copy the weather file to this directory
  epw_name = 'in.epw'
  begin
    FileUtils.copy(epw_path.to_s, "#{run_dir}/#{epw_name}")
  rescue StandardError
    OpenStudio.logFree(OpenStudio::Error, 'openstudio.model.Model', "Due to limitations on Windows file path lengths, this measure won't work unless your project is located in a directory whose filepath is less than 90 characters long, including slashes.")
    return false
  end
  workflow.setSeedFile(osm_name)
  workflow.setWeatherFile(epw_name)
  workflow.saveAs(File.absolute_path(osw_path.to_s))
  # 'touch' the weather file - for some odd reason this fixes the simulation not running issue we had on openstudio-server.
  # Removed for until further investigation completed.
  # FileUtils.touch("#{run_dir}/#{epw_name}")
  cli_path = OpenStudio.getOpenStudioCLI
  cmd = "\"#{cli_path}\" run -w \"#{osw_path}\""
  puts cmd
  # Run the sizing run
  OpenstudioStandards.run_command(cmd)
  OpenStudio.logFree(OpenStudio::Info, 'openstudio.model.Model', "Finished simulation #{run_dir} at #{Time.now.strftime('%T.%L')}")
  # get sql
  sql_path = OpenStudio::Path.new("#{run_dir}/run/eplusout.sql")
  raise 'sql file not found.' unless File.exist?(sql_path.to_s)

  sql_file = OpenStudio::SqlFile.new(sql_path)

  # check available timeseries extraction options
  available_env_periods = sql_file.availableEnvPeriods.to_a
  available_time_series = sql_file.availableTimeSeries.to_a
  available_reporting_frequencies = []
  available_env_periods.each do |envperiod|
    sql_file.availableReportingFrequencies(envperiod).to_a.each do |repfreq|
      available_reporting_frequencies << repfreq
    end
  end
  raise "options for availableEnvPeriods are not just one: #{available_env_periods}" unless available_env_periods.size == 1

  envperiod = 'RUN PERIOD 1'
  raise "envperiod of #{envperiod} not included in available options: #{available_env_periods}" unless available_env_periods.include?(envperiod)

  timeseriesname = 'Electricity:Facility'
  raise "timeseriesname of #{timeseriesname} not included in available options: #{available_time_series}" unless available_time_series.include?(timeseriesname)

  reportingfrequency = 'Hourly' # 'Zone Timestep'
  unless available_reporting_frequencies.include?(reportingfrequency)
    puts('Hourly reporting frequency is not available. Use Zone Timestep.')
    reportingfrequency = 'Zone Timestep'
    raise "reportingfrequency of #{reportingfrequency} not included in available options: #{available_reporting_frequencies}" unless available_reporting_frequencies.include?(reportingfrequency)
  end
  electricity_results = sql_file.timeSeries(envperiod, reportingfrequency, timeseriesname)
  vals = []
  electricity_results.each do |electricity_result|
    elec_vals = electricity_result.values
    for i in 0..(elec_vals.size - 1)
      vals << elec_vals[i]
    end
  end
  # raise if vals is empty
  if vals.empty?
    puts('Hourly reporting frequency return empty data. Use Zone Timestep.')
    reportingfrequency = 'Zone Timestep'
    raise "reportingfrequency of #{reportingfrequency} not included in available options: #{available_reporting_frequencies}" unless available_reporting_frequencies.include?(reportingfrequency)

    electricity_results = sql_file.timeSeries(envperiod, reportingfrequency, timeseriesname)
    vals = []
    electricity_results.each do |electricity_result|
      elec_vals = electricity_result.values
      for i in 0..(elec_vals.size - 1)
        vals << elec_vals[i]
      end
    end
    if vals.empty?
      raise 'load profile for the sample run returned empty'
    end
  end
  # reset model config for upgrade run
  model.getRunPeriod.setBeginMonth(begin_month_orig)
  model.getRunPeriod.setBeginDayOfMonth(begin_day_orig)
  model.getRunPeriod.setEndMonth(end_month_orig)
  model.getRunPeriod.setEndDayOfMonth(end_day_orig)
  model.getTimestep.setNumberOfTimestepsPerHour(num_timesteps_in_hr_orig)
  model.getSimulationControl.setDoZoneSizingCalculation(zonesizing_orig)
  model.getSimulationControl.setDoSystemSizingCalculation(syssizing_orig)
  model.getSimulationControl.setDoPlantSizingCalculation(plantsizing_orig)
  return vals
end

### run simulation on part of year and extract samples
def run_part_year_samples(model, max_doy, selectdays, num_timesteps_in_hr, epw_path = nil)
  y_seed = {
    'ext-hot' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'hot' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'mild' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'cool-mild' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'cool' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] },
    'cold' => { 'morning' => [], 'noon' => [], 'afternoon' => [], 'late-afternoon' => [], 'evening' => [], 'other' => [] }
  }
  puts "Simulation on part year until day: #{max_doy}"
  yd = model_run_simulation_on_part_of_year(model, max_doy, num_timesteps_in_hr, epw_path)
  if num_timesteps_in_hr != 1 # yd.size > 24*max_doy
    puts('Convert interval to hourly')
    sums = []
    yd.each_slice(yd.size / 24 / max_doy) do |slice|
      sum = slice.reduce(:+).to_f
      sums << sum
    end
    yd = sums
  end
  selectdays.keys.each do |key|
    selectdays[key].keys.each do |keykey|
      ns = selectdays[key][keykey].length.to_f
      selectdays[key][keykey].each do |doy|
        if ns == 1
          y_seed[key][keykey] = yd[((doy * 24) - 24)..((doy * 24) - 1)]
        elsif ns > 1
          if y_seed[key][keykey] == []
            y_seed[key][keykey] = yd[((doy * 24) - 24)..((doy * 24) - 1)].map { |a| a / ns }
          else
            y_seed[key][keykey] = yd[((doy * 24) - 24)..((doy * 24) - 1)].zip(y_seed[key][keykey]).map { |a, b| ((a / ns) + b) }
          end
        end
      end
    end
  end
  return y_seed
end

### populate load profile of samples to all days based on bins
def load_prediction_from_sample(model, y_seed, combbins)
  year = model.getYearDescription.calendarYear.to_i
  if leap_year?(year)
    nd = 366
  else
    nd = 365
  end
  annual_load = []
  (0..nd - 1).each do |d|
    combbins.each do |key, subbin|
      subbin.each do |keykey, bin|
        if bin.include?(d + 1)
          annual_load.concat(y_seed[key][keykey])
        end
      end
    end
  end
  return annual_load
end

### run simulation on full year
def load_prediction_from_full_run(model, num_timesteps_in_hr, epw_path = nil, run_dir = "#{Dir.pwd}/Run")
  ### reference: https://github.com/NREL/openstudio-standards/blob/master/lib/openstudio-standards/utilities/simulation.rb#L187
  # Make the directory if it doesn't exist
  FileUtils.mkdir_p(run_dir)

  osm_name = 'in.osm'
  osw_name = 'in.osw'
  OpenStudio.logFree(OpenStudio::Debug, 'openstudio.model.Model', "Starting simulation here: #{run_dir}.")
  OpenStudio.logFree(OpenStudio::Info, 'openstudio.model.Model', "Started simulation #{run_dir} at #{Time.now.strftime('%T.%L')}")
  # store original config
  begin_month_orig = model.getRunPeriod.getBeginMonth
  begin_day_orig = model.getRunPeriod.getBeginDayOfMonth
  end_month_orig = model.getRunPeriod.getEndMonth
  end_day_orig = model.getRunPeriod.getEndDayOfMonth
  num_timesteps_in_hr_orig = model.getTimestep.numberOfTimestepsPerHour
  # zonesizing_orig = model.getSimulationControl.doZoneSizingCalculation
  # syssizing_orig = model.getSimulationControl.doSystemSizingCalculation
  # plantsizing_orig = model.getSimulationControl.doPlantSizingCalculation
  ### reference: SetRunPeriod measure on BCL
  model.getRunPeriod.setBeginMonth(1)
  model.getRunPeriod.setBeginDayOfMonth(1)
  model.getRunPeriod.setEndMonth(12)
  model.getRunPeriod.setEndDayOfMonth(31)
  if num_timesteps_in_hr != 4
    model.getTimestep.setNumberOfTimestepsPerHour(num_timesteps_in_hr)
  end
  # model.getSimulationControl.setDoZoneSizingCalculation(false)
  # model.getSimulationControl.setDoSystemSizingCalculation(false)
  # model.getSimulationControl.setDoPlantSizingCalculation(false)
  osm_path = OpenStudio::Path.new("#{run_dir}/#{osm_name}")
  osw_path = OpenStudio::Path.new("#{run_dir}/#{osw_name}")
  model.save(osm_path, true)
  # Set up the simulation
  # Find the weather file
  if epw_path.nil?
    epw_path = model.weatherFile.get.path
    if epw_path.empty?
      return false
    end

    epw_path = epw_path.get
  end
  # close current sql file
  model.resetSqlFile
  # initialize OSW
  begin
    workflow = OpenStudio::WorkflowJSON.new
  rescue NameError
    raise 'Cannot run simulation with OSW approach'
  end
  sql_path = nil
  OpenStudio.logFree(OpenStudio::Debug, 'openstudio.model.Model', 'Running with OS 2.x WorkflowJSON.')
  # Copy the weather file to this directory
  epw_name = 'in.epw'
  begin
    FileUtils.copy(epw_path.to_s, "#{run_dir}/#{epw_name}")
  rescue StandardError
    OpenStudio.logFree(OpenStudio::Error, 'openstudio.model.Model', "Due to limitations on Windows file path lengths, this measure won't work unless your project is located in a directory whose filepath is less than 90 characters long, including slashes.")
    return false
  end
  workflow.setSeedFile(osm_name)
  workflow.setWeatherFile(epw_name)
  workflow.saveAs(File.absolute_path(osw_path.to_s))
  # 'touch' the weather file - for some odd reason this fixes the simulation not running issue we had on openstudio-server.
  # Removed for until further investigation completed.
  # FileUtils.touch("#{run_dir}/#{epw_name}")
  cli_path = OpenStudio.getOpenStudioCLI
  cmd = "\"#{cli_path}\" run -w \"#{osw_path}\""
  puts cmd
  # Run the sizing run
  OpenstudioStandards.run_command(cmd)
  OpenStudio.logFree(OpenStudio::Info, 'openstudio.model.Model', "Finished simulation #{run_dir} at #{Time.now.strftime('%T.%L')}")
  # get sql
  sql_path = OpenStudio::Path.new("#{run_dir}/run/eplusout.sql")
  raise 'sql file not found.' unless File.exist?(sql_path.to_s)

  sql_file = OpenStudio::SqlFile.new(sql_path)

  # check available timeseries extraction options
  available_env_periods = sql_file.availableEnvPeriods.to_a
  available_time_series = sql_file.availableTimeSeries.to_a
  available_reporting_frequencies = []
  available_env_periods.each do |envperiod|
    sql_file.availableReportingFrequencies(envperiod).to_a.each do |repfreq|
      available_reporting_frequencies << repfreq
    end
  end
  raise "options for availableEnvPeriods are not just one: #{available_env_periods}" unless available_env_periods.size == 1

  envperiod = 'RUN PERIOD 1'
  raise "envperiod of #{envperiod} not included in available options: #{available_env_periods}" unless available_env_periods.include?(envperiod)

  timeseriesname = 'Electricity:Facility'
  raise "timeseriesname of #{timeseriesname} not included in available options: #{available_time_series}" unless available_time_series.include?(timeseriesname)

  reportingfrequency = 'Zone Timestep'
  unless available_reporting_frequencies.include?(reportingfrequency)
    puts('Zone Timestep reporting frequency is not available. Use Hourly.')
    reportingfrequency = 'Hourly'
    raise "reportingfrequency of #{reportingfrequency} not included in available options: #{available_reporting_frequencies}" unless available_reporting_frequencies.include?(reportingfrequency)
  end
  electricity_results = sql_file.timeSeries(envperiod, reportingfrequency, timeseriesname)
  vals = []
  electricity_results.each do |electricity_result|
    elec_vals = electricity_result.values
    for i in 0..(elec_vals.size - 1)
      vals << elec_vals[i]
    end
  end
  if vals.empty?
    raise 'load profile for the sample run returned empty'
  end

  # reportingfrequency = 'Hourly' #'Zone Timestep'
  # unless available_reporting_frequencies.include?(reportingfrequency)
  #   puts("Hourly reporting frequency is not available. Use Zone Timestep.")
  #   reportingfrequency = 'Zone Timestep'
  #   unless available_reporting_frequencies.include?(reportingfrequency)
  #     raise "reportingfrequency of #{reportingfrequency} not included in available options: #{available_reporting_frequencies}"
  #   end
  # end
  # electricity_results = sql_file.timeSeries(envperiod,reportingfrequency,timeseriesname)
  # vals = []
  # electricity_results.each do |electricity_result|
  #   elec_vals = electricity_result.values
  #   for i in 0..(elec_vals.size - 1)
  #     vals << elec_vals[i]
  #   end
  # end
  # # raise if vals is empty
  # if vals.empty?
  #   puts("Hourly reporting frequency return empty data. Use Zone Timestep.")
  #   reportingfrequency = 'Zone Timestep'
  #   unless available_reporting_frequencies.include?(reportingfrequency)
  #     raise "reportingfrequency of #{reportingfrequency} not included in available options: #{available_reporting_frequencies}"
  #   end
  #   electricity_results = sql_file.timeSeries(envperiod,reportingfrequency,timeseriesname)
  #   vals = []
  #   electricity_results.each do |electricity_result|
  #     elec_vals = electricity_result.values
  #     for i in 0..(elec_vals.size - 1)
  #       vals << elec_vals[i]
  #     end
  #   end
  #   if vals.empty?
  #     raise 'load profile for the sample run returned empty'
  #   end
  # end
  # if (reportingfrequency == 'Zone Timestep') && (vals.size != 8760 || vals.size != 8784)
  #   puts("Convert interval to hourly with size=#{vals.size}")
  #   sums = []
  #   vals.each_slice(num_timesteps_in_hr) do |slice|
  #     sum = slice.reduce(:+).to_f
  #     sums << sum
  #   end
  #   vals = sums
  # end
  # reset model config for upgrade run
  model.getRunPeriod.setBeginMonth(begin_month_orig)
  model.getRunPeriod.setBeginDayOfMonth(begin_day_orig)
  model.getRunPeriod.setEndMonth(end_month_orig)
  model.getRunPeriod.setEndDayOfMonth(end_day_orig)
  model.getTimestep.setNumberOfTimestepsPerHour(num_timesteps_in_hr_orig)
  # model.getSimulationControl.setDoZoneSizingCalculation(zonesizing_orig)
  # model.getSimulationControl.setDoSystemSizingCalculation(syssizing_orig)
  # model.getSimulationControl.setDoPlantSizingCalculation(plantsizing_orig)
  return vals
end

### read cambium/egrid emission factors
def read_emission_factors(model, scenario, year = 2021)
  lbm_to_kg = OpenStudio.convert(1.0, 'lb_m', 'kg').get
  # set cambium and egrid regions
  grid_region = model.getBuilding.additionalProperties.getFeatureAsString('grid_region')
  raise 'Unable to find grid region in model building additional properties' unless grid_region.is_initialized

  grid_region = grid_region.get
  puts("Using grid region #{grid_region} from model building additional properties.")
  if ['AKMS', 'AKGD', 'HIMS', 'HIOA'].include? grid_region
    cambium_grid_region = nil
    egrid_region = grid_region
    puts("Grid region '#{grid_region}' is not available in Cambium.  Using eGrid factors only for electricty related emissions.")
  else
    cambium_grid_region = grid_region
    egrid_region = grid_region.chop
  end
  # read egrid factors
  egrid_subregion_emissions_factors_csv = "#{File.dirname(__FILE__)}/egrid/egrid_subregion_emissions_factors.csv"
  if !File.file?(egrid_subregion_emissions_factors_csv)
    raise "Unable to find file: #{egrid_subregion_emissions_factors_csv}"
  end

  egrid_subregion_lkp = CSV.table(egrid_subregion_emissions_factors_csv)
  egrid_subregion_hsh = egrid_subregion_lkp.map(&:to_hash)
  egrid_subregion_hsh = egrid_subregion_hsh.select { |r| (r[:subregion] == egrid_region) }
  if egrid_subregion_hsh.empty?
    raise "Unable to find eGRID data for subregion: #{egrid_region}"
  end

  if [2018, 2019, 2020, 2021].include?(year)
    egrid_co2e_kg_per_mwh = egrid_subregion_hsh[0][:"#{year}"] * lbm_to_kg
  elsif year == 'average'
    egrid_co2e_kg_per_mwh = (egrid_subregion_hsh[0][:"2018"] + egrid_subregion_hsh[0][:"2019"] + egrid_subregion_hsh[0][:"2020"] + egrid_subregion_hsh[0][:"2021"]) / 4.0 * lbm_to_kg
  else
    raise "Unable to find eGRID data for year: #{year}"
  end
  # read cambium factors
  cambium_co2e_kg_per_mwh = []
  if !cambium_grid_region.nil?
    if scenario.include? 'AER'
      scenario_lookup = "#{scenario}_1"
    else
      scenario_lookup = scenario
    end
    emissions_csv = "#{File.dirname(__FILE__)}/cambium/#{scenario_lookup}/#{cambium_grid_region}.csv"
    if !File.file?(emissions_csv)
      raise "Unable to find file: #{emissions_csv}"
    end

    cambium_co2e_kg_per_mwh = CSV.read(emissions_csv, converters: :float).flatten
  end
  return egrid_co2e_kg_per_mwh, cambium_co2e_kg_per_mwh
end

### emissions prediction based on emission factors and load prediction
def emissions_prediction(load, factor, num_timesteps_in_hr)
  j_to_mwh = OpenStudio.convert(1.0, 'J', 'MWh').get
  # convert to hourly load
  if num_timesteps_in_hr > 1
    hourly_load = []
    load.each_slice(num_timesteps_in_hr) do |slice|
      sum = slice.reduce(:+).to_f
      hourly_load << sum
    end
  end
  # convert load from J to mwh
  hourly_load_mwh = []
  hourly_load.each { |val| hourly_load_mwh << (val * j_to_mwh) }
  # calculate emissions
  case factor
  when Array
    # cambium factor
    unless hourly_load_mwh.size == factor.size
      raise 'Unable to calculate emissions for run periods not of length 8760 or 8784' unless hourly_load_mwh.size == 8784

      # leap year, copy Feb 28 data for Feb 29
      factor = factor[0..1415] + factor[1392..1415] + factor[1416..8759]
    end
    hourly_emissions_kg = hourly_load_mwh.zip(factor).map { |n, f| n * f }
  when Numeric
    # egrid factor
    hourly_emissions_kg = hourly_load_mwh.map { |n| n * factor }
  else
    raise 'Bad emission factors'
  end
  return hourly_emissions_kg
end

### load prediction based on grid load data
def load_prediction_from_grid_data(model, scenario = 'Load_MidCase_2035')
  grid_region = model.getBuilding.additionalProperties.getFeatureAsString('grid_region')
  raise 'Unable to find grid region in model building additional properties' unless grid_region.is_initialized

  grid_region = grid_region.get
  puts("Using grid region #{grid_region} from model building additional properties.")
  # if ['AKMS', 'AKGD', 'HIMS', 'HIOA'].include? grid_region
  #   cambium_grid_region = nil
  #   egrid_region = grid_region
  #   puts("Grid region '#{grid_region}' is not available in Cambium.  Using eGrid factors only for electricty related emissions.")
  # else
  #   cambium_grid_region = grid_region
  #   egrid_region = grid_region.chop
  # end
  load_csv = "#{File.dirname(__FILE__)}/cambium/#{scenario}/#{grid_region}.csv"
  if !File.file?(load_csv)
    raise "Unable to find file: #{load_csv}"
  end

  net_load_mwh = CSV.read(load_csv, converters: :float).flatten
  return net_load_mwh
end

def round_down(number)
  number.floor
end

### determine daily peak window based on daily load profile
def find_daily_peak_window(daily_load, peak_len, num_timesteps_in_hr, peak_window_strategy)
  maxload_ind = daily_load.index(daily_load.max)
  # maxload = daily_load.max
  case peak_window_strategy
  when 'max savings'
    # peak_sum = (0...peak_len).map { |i| load[maxload_ind - i, peak_len].sum }
    peak_sum = (0..(peak_len * num_timesteps_in_hr) - 1).map do |i|
      daily_load[(maxload_ind - i)..(maxload_ind - i + (peak_len * num_timesteps_in_hr) - 1)].sum
    end
    peak_ind = maxload_ind - peak_sum.index(peak_sum.max)
  when 'start with peak'
    if maxload_ind >= 1
      peak_ind = maxload_ind - 1
    else
      peak_ind = maxload_ind
    end
  when 'end with peak'
    if maxload_ind >= (peak_len * num_timesteps_in_hr) - 1
      peak_ind = maxload_ind - (peak_len * num_timesteps_in_hr) + 1
    else
      peak_ind = 0
    end
  when 'center with peak'
    if maxload_ind >= round_down(peak_len * num_timesteps_in_hr / 2.0)
      peak_ind = maxload_ind - round_down(peak_len * num_timesteps_in_hr / 2.0)
    else
      peak_ind = 0
    end
  else
    raise 'Not supported peak window strategy'
  end
  return peak_ind
end

def seasons
  return {
    'winter' => [-1e9, 55],
    'summer' => [70, 1e9],
    'shoulder' => [55, 70],
    'nonwinter' => [55, 1e9],
    'all' => [-1e9, 1e9]
  }
end

### Generate peak schedule for whole year with rebound option ########################### NEED TO JUSTIFY PUTTING REBOUND OPTION HERE OR IN INDIVIDUAL DF MEASURES
def peak_schedule_generation(annual_load, oat, peak_len, num_timesteps_in_hr, peak_window_strategy, rebound_len = 0, prepeak_len = 0, season = 'all')
  case annual_load.size
  when 8784, 35136
    nd = 366
  when 8760, 35040
    nd = 365
  else
    raise 'annual load profile not hourly or 15min'
  end
  peak_schedule = Array.new(annual_load.size, 0)
  temperature_range = seasons[season]
  (0..nd - 1).each do |d|
    range_start = d * 24 * num_timesteps_in_hr
    range_end = ((d + 1) * 24 * num_timesteps_in_hr) - 1
    temps = oat[d * 24..(d * 24) + 23]
    avg_temp = temps.inject { |sum, el| sum + el }.to_f / temps.size
    if (avg_temp > temperature_range[0]) && (avg_temp < temperature_range[1])
      peak_ind = find_daily_peak_window(annual_load[range_start..range_end], peak_len, num_timesteps_in_hr, peak_window_strategy)
      # peak and rebound schedule
      if prepeak_len == 0
        peak_schedule[(range_start + peak_ind)..(range_start + peak_ind + (peak_len * num_timesteps_in_hr) - 1)] = Array.new(peak_len * num_timesteps_in_hr, 1)
        if rebound_len > 0
          range_rebound_start = range_start + peak_ind + (peak_len * num_timesteps_in_hr) - 1
          range_rebound_end = range_start + peak_ind + ((peak_len + rebound_len) * num_timesteps_in_hr)
          peak_schedule[range_rebound_start..range_rebound_end] = (0..(rebound_len * num_timesteps_in_hr) + 1).map { |i| 1.0 - (i.to_f / ((rebound_len * num_timesteps_in_hr) + 1)) }
        end
      # prepeak schedule
      else
        if peak_ind >= prepeak_len
          peak_schedule[(range_start + peak_ind - (prepeak_len * num_timesteps_in_hr))..(range_start + peak_ind - 1)] = Array.new(prepeak_len * num_timesteps_in_hr, 1)
        else
          peak_schedule[range_start..(range_start + peak_ind - 1)] = Array.new(peak_ind, 1)
        end
      end
    end
  end
  peak_schedule.each_index do |i|
    peak_schedule[i] = 0 if peak_schedule[i].nil?
  end
  if peak_schedule.size < annual_load.size
    peak_schedule.fill(0, peak_schedule.size..annual_load.size - 1)
  else
    peak_schedule = peak_schedule.take(annual_load.size)
  end
  return peak_schedule
end

def peak_window_fix_based_on_climate_zone
  return {
    '2A' => {
      'wint_start' => 18,
      'wint_end' => 21,
      'wint_peak' => 20,
      'sum_start' => 17,
      'sum_end' => 20,
      'sum_peak' => 19
    },
    '2B' => {
      'wint_start' => 18,
      'wint_end' => 21,
      'wint_peak' => 19,
      'sum_start' => 16,
      'sum_end' => 19,
      'sum_peak' => 17
    },
    '3A' => {
      'wint_start' => 17,
      'wint_end' => 20,
      'wint_peak' => 19,
      'sum_start' => 18,
      'sum_end' => 21,
      'sum_peak' => 19
    },
    '3B' => {
      'wint_start' => 18,
      'wint_end' => 21,
      'wint_peak' => 20,
      'sum_start' => 17,
      'sum_end' => 20,
      'sum_peak' => 19
    },
    '3C' => {
      'wint_start' => 17,
      'wint_end' => 20,
      'wint_peak' => 19,
      'sum_start' => 18,
      'sum_end' => 21,
      'sum_peak' => 21
    },
    '4A' => {
      'wint_start' => 17,
      'wint_end' => 20,
      'wint_peak' => 18,
      'sum_start' => 13,
      'sum_end' => 16,
      'sum_peak' => 14
    },
    '4B' => {
      'wint_start' => 18,
      'wint_end' => 21,
      'wint_peak' => 19,
      'sum_start' => 16,
      'sum_end' => 19,
      'sum_peak' => 17
    },
    '4C' => {
      'wint_start' => 17,
      'wint_end' => 20,
      'wint_peak' => 18,
      'sum_start' => 16,
      'sum_end' => 19,
      'sum_peak' => 17
    },
    '5A' => {
      'wint_start' => 17,
      'wint_end' => 20,
      'wint_peak' => 19,
      'sum_start' => 17,
      'sum_end' => 20,
      'sum_peak' => 18
    },
    '5B' => {
      'wint_start' => 17,
      'wint_end' => 20,
      'wint_peak' => 19,
      'sum_start' => 16,
      'sum_end' => 19,
      'sum_peak' => 17
    },
    '5C' => {
      'wint_start' => 17,
      'wint_end' => 20,
      'wint_peak' => 18,
      'sum_start' => 16,
      'sum_end' => 19,
      'sum_peak' => 17
    },
    '6A' => {
      'wint_start' => 17,
      'wint_end' => 20,
      'wint_peak' => 19,
      'sum_start' => 15,
      'sum_end' => 18,
      'sum_peak' => 17
    },
    '6B' => {
      'wint_start' => 17,
      'wint_end' => 20,
      'wint_peak' => 18,
      'sum_start' => 16,
      'sum_end' => 19,
      'sum_peak' => 17
    },
    '7' => {
      'wint_start' => 17,
      'wint_end' => 20,
      'wint_peak' => 19,
      'sum_start' => 15,
      'sum_end' => 18,
      'sum_peak' => 17
    }
  }
end

def map_cec_to_iecc
  return {
    1 => '4B',
    2 => '3C',
    3 => '3C',
    4 => '3C',
    5 => '3C',
    6 => '3C',
    7 => '3B',
    8 => '3B',
    9 => '3B',
    10 => '3B',
    11 => '3B',
    12 => '3B',
    13 => '3B',
    14 => '3B',
    15 => '2B',
    16 => '5B'
  }
end

### Generate fixed peak schedules (cooling and heating respectively) for whole year with rebound option
def peak_schedule_generation_fix(climatezone, oat, rebound_len = 0, prepeak_len = 0, season = 'all')
  case oat.size
  when 8784
    nd = 366
  when 8760
    nd = 365
  else
    raise 'annual load profile not hourly'
  end
  peak_schedule_clg = Array.new(nd * 24, 0)
  peak_schedule_htg = Array.new(nd * 24, 0)
  temperature_range = seasons[season]
  peak_start_clg = peak_window_fix_based_on_climate_zone[climatezone]['sum_start'] - 1
  peak_end_clg = peak_window_fix_based_on_climate_zone[climatezone]['sum_end'] - 1
  peak_start_htg = peak_window_fix_based_on_climate_zone[climatezone]['wint_start'] - 1
  peak_end_htg = peak_window_fix_based_on_climate_zone[climatezone]['wint_end'] - 1
  (0..nd - 1).each do |d|
    range_start = d * 24
    range_end = (d * 24) + 23
    temps = oat[range_start..range_end]
    avg_temp = temps.inject { |sum, el| sum + el }.to_f / temps.size
    if (avg_temp > temperature_range[0]) && (avg_temp < temperature_range[1])
      # peak and rebound schedule
      if prepeak_len == 0
        peak_schedule_clg[(range_start + peak_start_clg)..(range_start + peak_end_clg)] = Array.new(peak_end_clg - peak_start_clg + 1, 1)
        peak_schedule_htg[(range_start + peak_start_htg)..(range_start + peak_end_htg)] = Array.new(peak_end_htg - peak_start_htg + 1, 1)
        if rebound_len > 0
          range_rebound_start_clg = range_start + peak_end_clg
          range_rebound_end_clg = range_start + peak_end_clg + 1 + rebound_len
          peak_schedule_clg[range_rebound_start_clg..range_rebound_end_clg] = (0..rebound_len + 1).map { |i| 1.0 - (i.to_f / (rebound_len + 1)) }
          range_rebound_start_htg = range_start + peak_end_htg
          range_rebound_end_htg = range_start + peak_end_htg + 1 + rebound_len
          peak_schedule_htg[range_rebound_start_htg..range_rebound_end_htg] = (0..rebound_len + 1).map { |i| 1.0 - (i.to_f / (rebound_len + 1)) }
        end
      # prepeak schedule
      else
        if peak_start_clg >= prepeak_len
          peak_schedule_clg[(range_start + peak_start_clg - prepeak_len)..(range_start + peak_start_clg - 1)] = Array.new(prepeak_len, 1)
        else
          peak_schedule_clg[range_start..(range_start + peak_start_clg - 1)] = Array.new(peak_start_clg, 1)
        end
        if peak_start_htg >= prepeak_len
          peak_schedule_htg[(range_start + peak_start_htg - prepeak_len)..(range_start + peak_start_htg - 1)] = Array.new(prepeak_len, 1)
        else
          peak_schedule_htg[range_start..(range_start + peak_start_htg - 1)] = Array.new(peak_start_htg, 1)
        end
      end
    end
  end
  peak_schedule_clg = peak_schedule_clg.take(nd * 24)
  peak_schedule_htg = peak_schedule_htg.take(nd * 24)
  return peak_schedule_clg, peak_schedule_htg
end

### determine daily peak window based on daily temperature profile
def find_daily_peak_window_based_on_oat(daily_temp, peak_len, peak_lag)
  tmp = daily_temp.each_cons(peak_len).map(&:sum)
  peak_ind_clg = tmp.index(tmp.max) + peak_lag
  peak_ind_htg = tmp.index(tmp.min) + peak_lag
  return peak_ind_clg, peak_ind_htg
end

### Generate peak schedule for whole year with rebound option based on temperature
def peak_schedule_generation_oat(oat, peak_len, peak_lag, rebound_len = 0, prepeak_len = 0, season = 'all')
  case oat.size
  when 8784
    nd = 366
  when 8760
    nd = 365
  else
    raise 'annual load profile not hourly'
  end
  peak_schedule_clg = Array.new(nd * 24, 0)
  peak_schedule_htg = Array.new(nd * 24, 0)
  temperature_range = seasons[season]
  (0..nd - 1).each do |d|
    range_start = d * 24
    range_end = (d * 24) + 23
    temps = oat[range_start..range_end]
    avg_temp = temps.inject { |sum, el| sum + el }.to_f / temps.size
    if (avg_temp > temperature_range[0]) && (avg_temp < temperature_range[1])
      peak_start_clg, peak_start_htg = find_daily_peak_window_based_on_oat(oat[range_start..range_end], peak_len, peak_lag)
      peak_end_clg = peak_start_clg + peak_len - 1
      peak_end_htg = peak_start_htg + peak_len - 1
      # peak and rebound schedule
      if prepeak_len == 0
        peak_schedule_clg[(range_start + peak_start_clg)..(range_start + peak_end_clg)] = Array.new(peak_len, 1)
        peak_schedule_htg[(range_start + peak_start_htg)..(range_start + peak_end_htg)] = Array.new(peak_len, 1)
        if rebound_len > 0
          range_rebound_start_clg = range_start + peak_end_clg
          range_rebound_end_clg = range_start + peak_end_clg + 1 + rebound_len
          peak_schedule_clg[range_rebound_start_clg..range_rebound_end_clg] = (0..rebound_len + 1).map { |i| 1.0 - (i.to_f / (rebound_len + 1)) }
          range_rebound_start_htg = range_start + peak_end_htg
          range_rebound_end_htg = range_start + peak_end_htg + 1 + rebound_len
          peak_schedule_htg[range_rebound_start_htg..range_rebound_end_htg] = (0..rebound_len + 1).map { |i| 1.0 - (i.to_f / (rebound_len + 1)) }
        end
      # prepeak schedule
      else
        if peak_start_clg >= prepeak_len
          peak_schedule_clg[(range_start + peak_start_clg - prepeak_len)..(range_start + peak_start_clg - 1)] = Array.new(prepeak_len, 1)
        else
          peak_schedule_clg[range_start..(range_start + peak_start_clg - 1)] = Array.new(peak_start_clg, 1)
        end
        if peak_start_htg >= prepeak_len
          peak_schedule_htg[(range_start + peak_start_htg - prepeak_len)..(range_start + peak_start_htg - 1)] = Array.new(prepeak_len, 1)
        else
          peak_schedule_htg[range_start..(range_start + peak_start_htg - 1)] = Array.new(peak_start_htg, 1)
        end
      end
    end
  end
  peak_schedule_clg = peak_schedule_clg.take(nd * 24)
  peak_schedule_htg = peak_schedule_htg.take(nd * 24)
  return peak_schedule_clg, peak_schedule_htg
end
