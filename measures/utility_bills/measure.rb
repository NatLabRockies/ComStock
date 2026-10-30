# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

require 'csv'
require 'date'
require 'json'
require 'open3'

# start the measure
class UtilityBills < OpenStudio::Measure::ReportingMeasure
  def os
    @os ||= begin
      host_os = RbConfig::CONFIG['host_os']
      case host_os
      when /mswin|msys|mingw|cygwin|bccwin|wince|emc/
        :windows
      when /darwin|mac os/
        :macosx
      when /linux/
        :linux
      when /solaris|bsd/
        :unix
      else
        raise Error::WebDriverError, "unknown os: #{host_os.inspect}"
      end
    end
  end

  # human readable name
  def name
    return 'Utility Bills'
  end

  # human readable description
  def description
    return 'Calculates utility bills for the model based on location.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'Calculates utility bills using the PySAM API and commercial rates from the NREL Utility Rate Database or EIA data.'
  end

  # define the arguments that the user will input
  def arguments(model = nil)
    args = OpenStudio::Measure::OSArgumentVector.new

    return args
  end

  # return a vector of IdfObject's to request EnergyPlus objects needed by the run method
  def energyPlusOutputRequests(runner, user_arguments)
    super(runner, user_arguments)

    result = OpenStudio::IdfObjectVector.new

    # Request hourly data for fuel types with hourly bill calculations
    # result << OpenStudio::IdfObject.load("Output:Meter,Electricity:Facility,Hourly;").get
    result << OpenStudio::IdfObject.load("Output:Meter,ElectricityPurchased:Facility,Hourly;").get

    return result
  end

  # return filtered electricity utility rates
  def filter_datapoints_with_median_bounds(runner, rate_results, list_of_labels_to_remove, create_list)
    # initialize filtered electricity rate variable
    elec_bills = {}

    # report bill breakdowns: demand charge
    bills_sorted = rate_results.values.reject(&:zero?).sort

    rate_results.each do |rate_label, bill|
      # if there are no bills left after removing zeros, set to 0
      if bills_sorted.empty?
        elec_bills[rate_label] = 0
        next
      end

      # if the rate label is considered outlier from total bill stand point, don't include
      if list_of_labels_to_remove.include?(rate_label)
        next
      end

      # get median
      mid = bills_sorted.length / 2
      median_bill = bills_sorted.length.odd? ? bills_sorted[mid] : (bills_sorted[mid - 1] + bills_sorted[mid]) / 2.0

      # skip outliers
      if bill < 0.25 * median_bill
        if create_list
          list_of_labels_to_remove << rate_label
        end
        runner.registerInfo("Removing #{rate_label}, because bill #{bill} < 0.25 x median #{median_bill}")
        next
      elsif bill > 2.0 * median_bill
        if create_list
          list_of_labels_to_remove << rate_label
        end
        runner.registerInfo("Removing #{rate_label}, because bill #{bill} > 2.0 x median #{median_bill}")
        next
      end

      # include the bill result in bill result statistics
      elec_bills[rate_label] = bill
    end

    return elec_bills, list_of_labels_to_remove.uniq
  end

  # Year of the supply prices added to delivery-only tariffs. Bills are reported in 2022 dollars,
  # so supply is priced in 2022 and is not escalated like the tariffs' own charges.
  SUPPLY_YEAR = 2022

  # Load the supply (default service) prices for URDB tariffs that carry delivery charges only
  # (see resources/supply/README.md). Returns the tariffs, {[state, label] => supply class}, and
  # the prices, {[state, eiaid, class] => {min_kw:, max_kw:, usd_per_kwh: [12], usd_per_kw_month: [12]}}.
  def load_supply_resources
    supply_dir = File.join(File.dirname(__FILE__), 'resources', 'supply')
    tariffs = {}
    CSV.foreach(File.join(supply_dir, 'delivery_only_tariffs.csv'), headers: true) do |row|
      tariffs[[row['state'], row['label']]] = row['supply_class']
    end
    prices = {}
    CSV.foreach(File.join(supply_dir, 'supply_prices.csv'), headers: true) do |row|
      next unless row['year'].to_i == SUPPLY_YEAR

      key = [row['state'], row['eiaid'], row['supply_class']]
      cls = prices[key] ||= {
        min_kw: row['class_min_kw'].nil? ? nil : row['class_min_kw'].to_f,
        max_kw: row['class_max_kw'].nil? ? nil : row['class_max_kw'].to_f,
        usd_per_kwh: Array.new(12), usd_per_kw_month: Array.new(12, 0.0)
      }
      m = row['month'].to_i - 1
      cls[:usd_per_kwh][m] = row['supply_usd_per_kwh'].to_f
      cls[:usd_per_kw_month][m] = row['supply_usd_per_kw_month'].to_f unless row['supply_usd_per_kw_month'].nil?
    end
    # Only classes with a price in every month
    prices.select! { |_, cls| cls[:usd_per_kwh].none?(&:nil?) }
    return tariffs, prices
  end

  # Supply class for a building on a delivery-only tariff. The tariff's own class stands unless the
  # utility defines classes by demand: a building outside its class's kW bounds moves to the class
  # whose bounds contain its peak, and a building in an unbounded class moves to a class with a
  # lower kW limit above zero that its peak reaches (e.g. hourly-priced service from 100 kW).
  def supply_class_for(prices, state, eiaid, tariff_class, peak_kw)
    classes = prices.select { |key, _| key[0] == state && key[1] == eiaid }
    contains = ->(cls) { (cls[:min_kw].nil? || peak_kw >= cls[:min_kw]) && (cls[:max_kw].nil? || peak_kw < cls[:max_kw]) }
    bounded = classes.reject { |_, cls| cls[:min_kw].nil? && cls[:max_kw].nil? }
    own = classes[[state, eiaid, tariff_class]]
    return nil if own.nil? && classes.empty?

    if own && (own[:min_kw] || own[:max_kw])
      return tariff_class if contains.call(own)

      match = bounded.find { |_, cls| contains.call(cls) }
      return match.nil? ? tariff_class : match[0][2]
    end
    above = bounded.select { |_, cls| cls[:min_kw].to_f > 0 && contains.call(cls) }
    return above.max_by { |_, cls| cls[:min_kw] }[0][2] unless above.empty?

    return own ? tariff_class : nil
  end

  # return applicable utility rates statistics
  def get_utility_rates_statistics(runner, elec_bills)
    # Get bill values and sort
    elec_bill_total_values = elec_bills.values.compact.map(&:to_f).sort
    runner.registerInfo("Bills sorted: #{elec_bill_total_values}")

    # Catch when elec_bills is empty
    if elec_bill_total_values.empty?
      return [0, 'NA', 0, 'NA', 0, 'NA', 0, 'NA', 0, 0]
    end

    # Calculate basic stats
    min_total_bill = elec_bill_total_values.min
    max_total_bill = elec_bill_total_values.max
    mean_total_bill = (elec_bill_total_values.sum / elec_bill_total_values.size).round

    # Median calculation
    lo_i = (elec_bill_total_values.size - 1) / 2
    hi_i = elec_bill_total_values.size / 2
    median_total_bill_low = elec_bill_total_values[lo_i]
    median_total_bill_high = elec_bill_total_values[hi_i]
    if elec_bill_total_values.length.odd?
      median_bill = elec_bill_total_values[lo_i]
    else
      median_bill = ((median_total_bill_low + median_total_bill_high) / 2.0).round.to_i
    end
    n_bills = elec_bills.length

    # get relevant keys
    key_min = elec_bills.key(min_total_bill)
    key_max = elec_bills.key(max_total_bill)
    key_median_low = elec_bills.key(median_total_bill_low)
    key_median_high = elec_bills.key(median_total_bill_high)

    return [
      min_total_bill.round.to_i,
      key_min,
      max_total_bill.round.to_i,
      key_max,
      median_total_bill_low.round.to_i,
      key_median_low,
      median_total_bill_high.round.to_i,
      key_median_high,
      mean_total_bill.round.to_i,
      n_bills
    ]
  end

  # define what happens when the measure is run
  def run(runner, user_arguments)
    super(runner, user_arguments)

    # Get the last model and sql file
    model = runner.lastOpenStudioModel
    if model.empty?
      runner.registerError('Could not load last OpenStudio model, cannot apply measure.')
      return false
    end
    model = model.get

    sql = runner.lastEnergyPlusSqlFile
    if sql.empty?
      runner.registerError('Cannot find last sql file.')
      return false
    end
    sql = sql.get
    model.setSqlFile(sql)

    # Define run directory location
    run_dir_typical = File.absolute_path(File.join(Dir.pwd, 'run'))
    run_dir_comstock = File.absolute_path(File.join(Dir.pwd, '..'))
    if File.exist?(run_dir_typical)
      run_dir = run_dir_typical
    elsif File.exist?(run_dir_comstock)
      run_dir = run_dir_comstock
    else
      runner.registerError('Could not find directory with EnergyPlus output, cannot extract timeseries results')
      return false
    end

    # Determine the model year and start day of year
    rp = model.getRunPeriod
    year_object = model.getYearDescription
    if year_object.calendarYear.is_initialized
      year = year_object.calendarYear.get
      yr = year_object.calendarYear.get
      year_start_day = year_object.makeDate(rp.getBeginMonth, rp.getBeginDayOfMonth).dayOfWeek.valueName
      runner.registerInfo("Year set to #{yr}. Simulation start day of #{rp.getBeginMonth}/#{rp.getBeginDayOfMonth}/#{yr} is a #{year_start_day}.")
    else
      yr = year_object.assumedYear
      year_start_day = year_object.makeDate(rp.getBeginMonth, rp.getBeginDayOfMonth).dayOfWeek.valueName
      runner.registerInfo("Year not specified. OpenStudio assumed #{yr}. Simulation start day of #{rp.getBeginMonth}/#{rp.getBeginDayOfMonth}/#{yr} is a #{year_start_day}.")
    end

    # Get the weather file run period
    ann_env_pd = nil
    sql.availableEnvPeriods.each do |env_pd|
      env_type = sql.environmentType(env_pd)
      if env_type.is_initialized && (env_type.get == (OpenStudio::EnvironmentType.new('WeatherRunPeriod')))
        ann_env_pd = env_pd
      end
    end
    if ann_env_pd == false
      runner.registerError("Can't find a weather runperiod, make sure you ran an annual simulation, not just the design days.")
      return false
    end

    # Electricity Bill

    # Get hourly electricity timeseries
    # elec_ts = sql.timeSeries(ann_env_pd, 'Hourly', 'Electricity:Facility', '')
    elec_ts = sql.timeSeries(ann_env_pd, 'Hourly', 'ElectricityPurchased:Facility', '')
    if elec_ts.empty?
      runner.registerError('Could not get hourly electricity consumption, cannot calculate electricity bill')
      return false
    end
    elec_ts = elec_ts.get

    # PySAM 4.2.0 assumes that Jan 1 is a Monday per https://github.com/NREL/ssc/issues/195
    # Shift timeseries electricity data to match that assumption
    # so that the weekday/weekend rates apply to the correct energy consumption

    # Find the first Monday timestamp
    first_monday_i = nil
    elec_ts.dateTimes.each_with_index do |date_time, i|
      # runner.registerInfo("timestamp index: #{i}, #{date_time.date.dayOfWeek.valueName} ,#{date_time}")
      if date_time.date.dayOfWeek.valueName == 'Monday'
        # E+ timestamps are hour-ending, so a 00:00 timestamp represents 11-12pm the day prior
        if date_time.time.hours.zero?
          first_monday_i = i + 1
        else
          first_monday_i = i
        end
        runner.registerInfo("First monday timestamp index: #{first_monday_i}")
        break
      end
    end

    # Convert the timeseries vectors to Ruby arrays
    orig_dts = elec_ts.dateTimes.map { |dt| dt }
    orig_vals = []
    elec_ts.values.each { |val| orig_vals << val }

    # Shift values if necessary
    runner.registerInfo("Raw electric timeseries dates #{orig_dts[0]} to #{orig_dts[-1]}")
    if first_monday_i.zero?
      # No shift required
      shifted_dts = orig_dts
      shifted_vals = orig_vals
    else
      # First monday through the end of the year, then first few pre-Monday days
      runner.registerInfo('Shifting electric timeseries to Monday start for PySAM')
      shifted_dts = orig_dts[first_monday_i..] + orig_dts[0..first_monday_i - 1]
      shifted_vals = orig_vals[first_monday_i..] + orig_vals[0..first_monday_i - 1]
      runner.registerInfo("Shifted electric timeseries dates #{shifted_dts[0]} to #{shifted_dts[-1]}")
    end

    # Check that the size is the same
    unless shifted_vals.size == elec_ts.values.size
      runner.registerError("Error shifting values to Monday start, started with #{elec_ts.values.size}, ended with #{shifted_vals.size}")
      return false
    end

    # Check that the total energy is the same
    unless shifted_vals.sum == elec_ts.values.sum
      runner.registerError("Error shifting values to Monday start, started with #{elec_ts.values.sum}, ended with #{shifted_vals.sum}")
      return false
    end

    # Convert electricity to kWh
    hourly_electricity_kwh = shifted_vals.map do |val|
      OpenStudio.convert(val, 'J', 'kWh').get # hourly data
    end

    # Get min and peak demand for rates with qualifiers
    tot_elec_kwh = hourly_electricity_kwh.sum.round
    min_kw = hourly_electricity_kwh.min.round
    max_kw = hourly_electricity_kwh.max.round

    # Write the hourly kWh to CSV
    elec_csv_path = File.expand_path("#{run_dir}/electricity_hourly.csv")
    if !File.exist? elec_csv_path
      CSV.open(elec_csv_path, 'wb') do |csv|
        hourly_electricity_kwh.each do |kwh|
          csv << [kwh.round(3)]
        end
      end
    end

    # Get the sampling region
    sampling_region = model.getBuilding.additionalProperties.getFeatureAsString('sampling_region')
    if sampling_region.empty?
      runner.registerError('Cannot find sampling_region for building, cannot calculate electricity bills.')
      return false
    end
    sampling_region = sampling_region.get

    # load sampling region to tract map
    region_to_tract_map_path = File.join(File.dirname(__FILE__), 'resources', 'sampling_region_to_tracts.json')
    region_to_tract_map = JSON.parse(File.read(region_to_tract_map_path))

    potential_tracts = region_to_tract_map[sampling_region]
    runner.registerInfo("For sampling region #{sampling_region}, there are #{potential_tracts.size} potential tracts")

    state_fips_from_tract = ->(gisjoin) { gisjoin[1, 2] }

    potential_state_fips = potential_tracts.map { |tract| state_fips_from_tract.call(tract) }.uniq
    state_abbrev_to_fips = JSON.parse(File.read(File.join(File.dirname(__FILE__), 'resources', 'state_abbrev_to_fips.json')))
    potential_state_abbrevs = potential_state_fips.map { |f| state_abbrev_to_fips.key(f) }

    runner.registerInfo("For sampling region #{sampling_region}, potential states are #{potential_state_abbrevs}")

    # Load the tract to electric utility EIA ID mapping
    tract_to_elec_util_path = File.join(File.dirname(__FILE__), 'resources', 'tract_to_elec_util_v2.csv')
    tract_to_elec_util = {}
    CSV.foreach(tract_to_elec_util_path) do |row|
      tract_to_elec_util[row[0]] = row[1]
    end

    # Load the state each URDB rate file applies in, where known (see resources/build_elec_rate_states.py)
    elec_rate_states = {}
    CSV.foreach(File.join(File.dirname(__FILE__), 'resources', 'elec_rate_states.csv'), headers: true) do |row|
      elec_rate_states[row['label']] = row['state'] unless row['state'].nil? || row['state'].empty?
    end

    # Supply prices for tariffs that carry delivery charges only (retail choice states)
    delivery_only_tariffs, supply_prices = load_supply_resources

    # Look up the utility EIA IDs based on the potential census tracts for the sampling region
    state_eia_map = Hash.new { |h, k| h[k] = [] }
    elec_eia_ids = []
    potential_tracts.each do |tract|
      state_abbrev = state_abbrev_to_fips.key(state_fips_from_tract.call(tract))
      elec_util_id = tract_to_elec_util[tract]
      state_eia_map[state_abbrev] << elec_util_id unless state_eia_map[state_abbrev].include?(elec_util_id) || elec_util_id.nil?
    end

    # load files
    # Get the average annual electric rate increase from 2013 to 2022 to attempt to make rates more current
    elec_ann_incr_path = File.join(File.dirname(__FILE__), 'resources', 'eia_com_elec_avg_yrly_rate_increase.json')
    elec_ann_incr = JSON.parse(File.read(elec_ann_incr_path))

    # state average rate info
    # electricity
    elec_prices_path = File.join(File.dirname(__FILE__), 'resources', 'eia_com_elec_prices_dol_per_kwh_2022.json')
    elec_prices = JSON.parse(File.read(elec_prices_path))

    # natural gas
    tot_ng_kbtu = nil
    ng_prices = nil
    if sql.naturalGasTotalEndUses.is_initialized
      tot_ng_kbtu = OpenStudio.convert(sql.naturalGasTotalEndUses.get, 'GJ', 'kBtu').get
      if tot_ng_kbtu > 0
        prices_path = File.join(File.dirname(__FILE__), 'resources', 'eia_com_gas_prices_dol_per_kbtu_2022.json')
        ng_prices = JSON.parse(File.read(prices_path))
      end
    end

    # propane
    tot_propane_kbtu = nil
    propane_prices = nil
    if sql.propaneTotalEndUses.is_initialized
      tot_propane_kbtu = OpenStudio.convert(sql.propaneTotalEndUses.get, 'GJ', 'kBtu').get
      if tot_propane_kbtu > 0
        prices_path = File.join(File.dirname(__FILE__), 'resources', 'eia_res_propane_prices_dol_per_kbtu_2022.json')
        propane_prices = JSON.parse(File.read(prices_path))
      end
    end

    # fuel oil
    tot_fueloil_kbtu = nil
    fueloil_prices = nil
    if sql.fuelOilNo2TotalEndUses.is_initialized
      tot_fueloil_kbtu = OpenStudio.convert(sql.fuelOilNo2TotalEndUses.get, 'GJ', 'kBtu').get
      if tot_fueloil_kbtu > 0
        prices_path = File.join(File.dirname(__FILE__), 'resources', 'eia_res_fuel_oil_prices_dol_per_kbtu_2022.json')
        fueloil_prices = JSON.parse(File.read(prices_path))
      end
    end

    # concatenated output strings
    electricity_bill_results = ''
    state_avg_elec_results = ''
    state_avg_ng_results = ''
    state_avg_propane_results = ''
    state_avg_fueloil_results = ''


    state_eia_map.keys.each do |state_abbreviation|
      elec_eia_ids = state_eia_map[state_abbreviation]

      if elec_eia_ids.empty?
        runner.registerWarning("No EIA Utility IDs found for potential tracts in #{state_abbreviation}. Only state averages will be calculated.")
      end

      elec_eia_ids.each do |elec_eia_id|
        # Find all the electric rates for this utility
        all_rates = Dir.glob(File.join(File.dirname(__FILE__), "resources/elec_rates/#{elec_eia_id}/*.json"))
        # A utility serving several states keeps every state's tariffs in one folder. Keep the ones
        # assigned to this state and the ones assigned to no state; a building none of them applies
        # to gets the state-average bill below, like any building without an applicable rate. A state
        # with no rate file assigned to it keeps them all, as every state did before the assignments.
        unless all_rates.empty?
          state_rates = all_rates.select do |rate_path|
            rate_state = elec_rate_states[File.basename(rate_path, '.json')]
            rate_state.nil? || rate_state == state_abbreviation
          end
          if state_rates.empty?
            runner.registerWarning("None of the #{all_rates.size} URDB electric rates for EIA utility #{elec_eia_id} are assigned to #{state_abbreviation}; using all of them.")
          else
            if state_rates.size < all_rates.size
              runner.registerInfo("#{state_rates.size} of #{all_rates.size} URDB electric rates for EIA utility #{elec_eia_id} apply in #{state_abbreviation}.")
            end
            all_rates = state_rates
          end
        end
        if all_rates.empty?
          unless elec_eia_id.nil?
            runner.registerWarning("No URDB electric rates found for EIA utility #{elec_eia_id}, using EIA average electric price.")
            use_urdb_rates = false
          end
        else
          runner.registerInfo("Found #{all_rates.size} URDB electric rates for EIA utility #{elec_eia_id}.")
          use_urdb_rates = true
        end

        # Downselect to applicable rates based on kW and kWh limits
        applicable_rates = []
        all_rates.each_with_index do |rate_path, i|
          # Load the rate data
          rate = JSON.parse(File.read(rate_path))
          rate_name = rate['name']
          rate_id = rate['label']

          if rate.key?('peakkwcapacitymin') && (min_kw < (rate['peakkwcapacitymin']))
            runner.registerInfo("Rate #{rate_name} is not applicable because the building min demand of #{min_kw} kW is below minimum threshold of #{rate['peakkwcapacitymin']} kW.")
            next
          end

          if rate.key?('peakkwcapacitymax') && (max_kw > (rate['peakkwcapacitymax']))
            runner.registerInfo("Rate #{rate_name} is not applicable because the building max demand of #{max_kw} kW is above maximum threshold of #{rate['peakkwcapacitymax']} kW.")
            next
          end

          if rate.key?('peakkwhusagemin') && (tot_elec_kwh < (rate['peakkwhusagemin']))
            runner.registerInfo("Rate #{rate_name} is not applicable because the building annual energy #{tot_elec_kwh} kWh is below minimum threshold of #{rate['peakkwhusagemin']} kWh.")
            next
          end

          if rate.key?('peakkwhusagemax') && (tot_elec_kwh > (rate['peakkwhusagemax']))
            runner.registerInfo("Rate #{rate_name} is not applicable because the building annual energy #{tot_elec_kwh} kWh is above maximum threshold of #{rate['peakkwhusagemax']} kWh.")
            next
          end

          # Rate is applicable to this building
          runner.registerInfo("Rate #{rate_name} is applicable.")
          applicable_rates << File.expand_path(rate_path)
        end

        # Ensure at least one rate is applicable to this building
        if !all_rates.empty? && applicable_rates.empty?
          use_urdb_rates = false
          runner.registerWarning("No URDB electric rates were applicable to this building for utility #{elec_eia_id} in #{state_abbreviation}, using EIA average electric price.")
        end

        # Calculate bills using URDB rates
        if use_urdb_rates
          electricity_bill_results += '|' if electricity_bill_results.empty?
          electricity_bill_results += "#{elec_eia_id}:"

          # get annual percent increase for state
          state_elec_ann_incr = elec_ann_incr[state_abbreviation]

          # Calculate the bills for each applicable electric rate using the PySAM API via python
          rate_results_total = {}
          rate_results_demandcharge_flat = {}
          rate_results_demandcharge_tou = {}
          rate_results_energycharge = {}
          rate_results_fixedcharge = {}
          calc_elec_bill_py_path = File.join(File.dirname(__FILE__), 'resources', 'calc_elec_bill.py')
          applicable_rates.each_with_index do |rate_path, i|
            # Load the rate data
            rate = JSON.parse(File.read(rate_path))
            rate_name = rate['name']
            rate_label = rate['label']
            rate_start_date = rate['startdate']
            if rate_start_date
              rate_start_year = Time.at(rate_start_date).utc.to_datetime.to_date.year
            else
              rate_start_year = 2013
              runner.registerWarning("#{rate_name} listed no start date, assuming #{rate_start_year}")
            end

            # Call calc_elec_bill.py
            py = if os == :windows || os == :macosx
                   'python' # Assumes running buildstockbatch from a Conda shell
                 # 'conda run -n pysam python' # for local testing
                 elsif os == :linux
                   'python3.11' # Assumes running buildstockbatch from ComStock docker image
                 else
                   runner.registerError("Could not find python command for #{os}")
                   return false
                 end

            command = "#{py} #{calc_elec_bill_py_path} #{elec_csv_path} #{rate_path}"

            # A tariff with delivery charges only also pays the default service supply price
            supply_note = nil
            tariff_class = delivery_only_tariffs[[state_abbreviation, rate_label]]
            unless tariff_class.nil?
              supply_class = supply_class_for(supply_prices, state_abbreviation, elec_eia_id.to_s, tariff_class, max_kw)
              supply = supply_class.nil? ? nil : supply_prices[[state_abbreviation, elec_eia_id.to_s, supply_class]]
              if supply.nil?
                runner.registerWarning("#{rate_name} carries delivery charges only, but no #{SUPPLY_YEAR} supply prices were found for utility #{elec_eia_id} in #{state_abbreviation}; billing delivery only.")
              else
                command += " --supply-usd-per-kwh #{supply[:usd_per_kwh].join(',')} --supply-usd-per-kw-month #{supply[:usd_per_kw_month].join(',')}"
                supply_note = "#{supply_class} class #{SUPPLY_YEAR} supply"
              end
            end

            stdout_str, stderr_str, status = Open3.capture3(command)
            # Remove the warning string from the PySAM output if necessary.
            # The bills are typically reasonable despite this warning.
            rate_warn_a = 'Billing Demand Notice.'
            rate_warn_b = 'This rate includes billing demand adjustments and/or demand ratchets that may not be accurately reflected in the data downloaded from the URDB. Please check the information in the Description under Description and Applicability and review the rate sheet to be sure the billing demand inputs are correct.'
            stdout_str = stdout_str.gsub(rate_warn_a, '')
            stdout_str = stdout_str.gsub(rate_warn_b, '')
            stdout_str = stdout_str.strip
            if status.success?
              begin
                pysam_out = JSON.parse(stdout_str)
              rescue JSON::ParserError
                runner.registerError("Error running PySAM: #{command}")
                runner.registerError("stdout: #{stdout_str}")
                return false
              end
              # Adjust the rate for price increases using state averages
              pct_inc = ((2022 - rate_start_year) * state_elec_ann_incr).round(3)
              total_utility_bill_dollars_base_yr = pysam_out['total_utility_bill_dollars'].round.to_i
              utility_bill_dollars_base_yr_dc_flat = pysam_out['charge_wo_sys_dc_fixed'].round.to_f
              utility_bill_dollars_base_yr_dc_tou = pysam_out['charge_wo_sys_dc_tou'].round.to_f
              utility_bill_dollars_base_yr_ec = pysam_out['charge_wo_sys_ec'].round.to_f
              utility_bill_dollars_base_yr_fixed = pysam_out['charge_wo_sys_fixed_ym']
              total_utility_bill_dollars_2022 = (total_utility_bill_dollars_base_yr * (1.0 + pct_inc)).round.to_i
              utility_bill_dollars_base_yr_dc_flat = (utility_bill_dollars_base_yr_dc_flat * (1.0 + pct_inc)).round.to_i
              utility_bill_dollars_base_yr_dc_tou = (utility_bill_dollars_base_yr_dc_tou * (1.0 + pct_inc)).round.to_i
              utility_bill_dollars_base_yr_ec = (utility_bill_dollars_base_yr_ec * (1.0 + pct_inc)).round.to_i
              utility_bill_dollars_base_yr_fixed = (utility_bill_dollars_base_yr_fixed * (1.0 + pct_inc)).round.to_i

              # Supply is already in SUPPLY_YEAR (2022) dollars: add it after escalating the delivery charges
              unless supply_note.nil?
                supply_energy = pysam_out['supply_energy_charge_dollars'].to_f
                supply_demand = pysam_out['supply_demand_charge_dollars'].to_f
                total_utility_bill_dollars_2022 = (total_utility_bill_dollars_2022 + supply_energy + supply_demand).round.to_i
                utility_bill_dollars_base_yr_ec = (utility_bill_dollars_base_yr_ec + supply_energy).round.to_i
                utility_bill_dollars_base_yr_dc_flat = (utility_bill_dollars_base_yr_dc_flat + supply_demand).round.to_i
                runner.registerInfo("#{rate_name} carries delivery charges only: added #{supply_note}, $#{supply_energy.round} energy and $#{supply_demand.round} demand.")
              end

              rate_results_total[rate_label] = total_utility_bill_dollars_2022
              rate_results_demandcharge_flat[rate_label] = utility_bill_dollars_base_yr_dc_flat
              rate_results_demandcharge_tou[rate_label] = utility_bill_dollars_base_yr_dc_tou
              rate_results_energycharge[rate_label] = utility_bill_dollars_base_yr_ec
              rate_results_fixedcharge[rate_label] = utility_bill_dollars_base_yr_fixed
              runner.registerInfo("Bill for #{rate_name}: $#{total_utility_bill_dollars_2022}, adjusted from #{rate_start_year} to 2022 assuming #{pct_inc} increase.")
              runner.registerInfo("Bill for #{rate_name}: $#{utility_bill_dollars_base_yr_dc_flat}, adjusted from #{rate_start_year} to 2022 assuming #{pct_inc} increase.")
              runner.registerInfo("Bill for #{rate_name}: $#{utility_bill_dollars_base_yr_dc_tou}, adjusted from #{rate_start_year} to 2022 assuming #{pct_inc} increase.")
              runner.registerInfo("Bill for #{rate_name}: $#{utility_bill_dollars_base_yr_ec}, adjusted from #{rate_start_year} to 2022 assuming #{pct_inc} increase.")
              runner.registerInfo("Bill for #{rate_name}: $#{utility_bill_dollars_base_yr_fixed}, adjusted from #{rate_start_year} to 2022 assuming #{pct_inc} increase.")
            else
              runner.registerError("Error running PySAM: #{command}")
              runner.registerError("stdout: #{stdout_str}")
              runner.registerError("stderr: #{stderr_str}")
              return false
            end
          end

          # Filter reasonable rates
          elec_bills_total, list_of_labels_to_remove = filter_datapoints_with_median_bounds(runner, rate_results_total, [], true)
          elec_bills_demandcharge_flat, list_of_labels_to_remove = filter_datapoints_with_median_bounds(runner, rate_results_demandcharge_flat, list_of_labels_to_remove, false)
          elec_bills_demandcharge_tou, list_of_labels_to_remove = filter_datapoints_with_median_bounds(runner, rate_results_demandcharge_tou, list_of_labels_to_remove, false)
          elec_bills_energycharge, list_of_labels_to_remove = filter_datapoints_with_median_bounds(runner, rate_results_energycharge, list_of_labels_to_remove, false)
          elec_bills_fixedcharge, list_of_labels_to_remove = filter_datapoints_with_median_bounds(runner, rate_results_fixedcharge, list_of_labels_to_remove, false)

          # Report bill statistics across all applicable electric rates
          stats_total = get_utility_rates_statistics(runner, elec_bills_total)
          stats_demandcharge_flat = get_utility_rates_statistics(runner, elec_bills_demandcharge_flat)
          stats_demandcharge_tou = get_utility_rates_statistics(runner, elec_bills_demandcharge_tou)
          stats_energycharge = get_utility_rates_statistics(runner, elec_bills_energycharge)
          stats_fixedcharge = get_utility_rates_statistics(runner, elec_bills_fixedcharge)

          # Concatenate bill statistics in certain format. The state comes last: a utility serving
          # tracts in several states of the sampling region has one block per state.
          electricity_bill_results += stats_total[0..8].join(":") + ":"
          electricity_bill_results += stats_demandcharge_flat[0..8].join(":") + ":"
          electricity_bill_results += stats_demandcharge_tou[0..8].join(":") + ":"
          electricity_bill_results += stats_energycharge[0..8].join(":") + ":"
          electricity_bill_results += stats_fixedcharge[0..8].join(":") + ":"
          electricity_bill_results += "#{stats_total[9]}:#{state_abbreviation}|"
        end
      end

      # calculate state averages
      # Electricity bill
      state_avg_elec_results += '|' if state_avg_elec_results.empty?
      state_avg_elec_results += "#{state_abbreviation}:"
      elec_rate_dollars_per_kwh = elec_prices[state_abbreviation]
      total_elec_utility_bill_dollars = (tot_elec_kwh * elec_rate_dollars_per_kwh).round.to_i
      state_avg_elec_results += "#{total_elec_utility_bill_dollars}|"

      # Natural Gas Bill
      unless tot_ng_kbtu.zero?
        state_avg_ng_results += '|' if state_avg_ng_results.empty?
        state_avg_ng_results += "#{state_abbreviation}:"
        ng_dollars_per_kbtu = ng_prices[state_abbreviation]
        ng_bill_dollars = (tot_ng_kbtu * ng_dollars_per_kbtu).round.to_i
        state_avg_ng_results += "#{ng_bill_dollars}|"
      end

      # Propane Bill
      unless tot_propane_kbtu.zero?
        state_avg_propane_results += '|' if state_avg_propane_results.empty?
        state_avg_propane_results += "#{state_abbreviation}:"
        propane_dollars_per_kbtu = propane_prices[state_abbreviation]
        propane_bill_dollars = (tot_propane_kbtu * propane_dollars_per_kbtu).round.to_i
        state_avg_propane_results += "#{propane_bill_dollars}|"
      end

      # fuel oil bill
      unless tot_fueloil_kbtu.zero?
        state_avg_fueloil_results += '|' if state_avg_fueloil_results.empty?
        state_avg_fueloil_results += "#{state_abbreviation}:"
        fo_dollars_per_kbtu = fueloil_prices[state_abbreviation]
        fo_dollars = (tot_fueloil_kbtu * fo_dollars_per_kbtu).round.to_i
        state_avg_fueloil_results += "#{fo_dollars}|"
      end
    end

    runner.registerValue('electricity_utility_bill_results', "#{electricity_bill_results}")
    # Which version of the rate-file state assignments (resources/elec_rate_states.csv) billed this run
    runner.registerValue('electricity_rate_files_by_state', 'v1')
    # Which version of the supply prices for delivery-only tariffs (resources/supply/) billed this run
    runner.registerValue('electricity_supply_for_delivery_only_tariffs', 'v1')
    runner.registerValue('state_avg_electricity_cost_results', "#{state_avg_elec_results}")
    runner.registerValue('state_avg_naturalgas_cost_results', "#{state_avg_ng_results}")
    runner.registerValue('state_avg_propane_cost_results', "#{state_avg_propane_results}")
    runner.registerValue('state_avg_fueloil_cost_results', "#{state_avg_fueloil_results}")

    # District Heating Bills
    # TODO have not found any source of rates beyond data for individual utilities
    if sql.districtHeatingTotalEndUses.is_initialized
      tot_kbtu = OpenStudio.convert(sql.districtHeatingTotalEndUses.get, 'GJ', 'kBtu').get
      if tot_kbtu > 0
        runner.registerWarning('District heating utility bills are not yet calculated.')
      end
    end

    # District Cooling Bills
    # TODO have not found any source of rates beyond data for individual utilities
    if sql.districtCoolingTotalEndUses.is_initialized
      tot_kbtu = OpenStudio.convert(sql.districtCoolingTotalEndUses.get, 'GJ', 'kBtu').get
      if tot_kbtu > 0
        runner.registerWarning('District cooling utility bills are not yet calculated.')
      end
    end

    # Close the sql file
    sql.close

    return true
  end
end

# register the measure to be used by the application
UtilityBills.new.registerWithApplication
