# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

require 'csv'
require 'fileutils'
require 'date'
require 'time'

# start the measure
class TimeseriesCSVExport < OpenStudio::Measure::ReportingMeasure
  # Unit conversions applied to the raw SI values EnergyPlus writes to the native CSV.
  # These replace the conversion rules previously handed to convertESOMTR in convert.txt.
  def j_to_kwh
    2.777778E-07
  end

  def j_to_neg_kwh
    -2.777778E-07
  end

  def j_to_kbtu
    9.484517E-07
  end

  def m3_to_gal
    2.641720E+02
  end

  # human readable name
  def name
    'Timeseries CSV Export'
  end

  # human readable description
  def description
    'Exports all available hourly timeseries enduses to csv, and uses them for utility bill calculations.'
  end

  # human readable description of modeling approach
  def modeler_description
    'Requests the native EnergyPlus CSV output (OutputControl:Files) and reformats the resulting ' \
      'eplusmtr.csv and eplusout.csv into enduse_timeseries.csv, converting the raw SI values to ' \
      'kWh, kBtu, and gal and adding local, daylight savings, and UTC timestamp columns.'
  end

  def fuel_types
    ['Electricity',
     'ElectricityNet',
     'ElectricityPurchased',
     'ElectricityProduced',
     'NaturalGas',
     'DistrictCooling',
     'DistrictHeatingWater',
     'Water',
     'FuelOilNo2',
     'Propane']
  end

  def end_uses
    ['Heating',
     'Cooling',
     'InteriorLights',
     'ExteriorLights',
     'InteriorEquipment',
     'ExteriorEquipment',
     'Fans',
     'Pumps',
     'HeatRejection',
     'Humidification',
     'HeatRecovery',
     'WaterSystems',
     'Refrigeration',
     'Generators',
     'Facility']
  end

  def end_use_subcats
    ['ResPublicArea:InteriorEquipment:Electricity',
     'ResPublicArea:InteriorLights:Electricity',
     'Elevators:InteriorEquipment:Electricity']
  end

  def output_vars
    ['Zone Mean Air Temperature',
     'Zone Mean Air Humidity Ratio',
     'Fan Runtime Fraction']
  end

  # The meters this measure requests, in the order they are written to enduse_timeseries.csv
  def requested_meters
    meters = []
    end_uses.each do |end_use|
      fuel_types.each do |fuel_type|
        meters << if end_use == 'Facility'
                    "#{fuel_type}:#{end_use}"
                  else
                    "#{end_use}:#{fuel_type}"
                  end
      end
    end
    meters + end_use_subcats
  end

  # Column name and unit conversion for each meter with an explicitly defined name.
  # EnergyPlus reports energy meters in J and water meters in m3.
  # meter name => [column name, conversion factor]
  def meter_column_definitions
    {
      'Heating:Electricity' => ['electricity_heating_kwh', j_to_kwh],
      'Heating:DistrictHeatingWater' => ['districtheating_heating_kbtu', j_to_kbtu],
      'Heating:NaturalGas' => ['gas_heating_kbtu', j_to_kbtu],
      'Heating:Propane' => ['propane_heating_kbtu', j_to_kbtu],
      'Heating:FuelOilNo2' => ['fueloil_heating_kbtu', j_to_kbtu],
      'Cooling:Electricity' => ['electricity_cooling_kwh', j_to_kwh],
      'Cooling:DistrictCooling' => ['districtcooling_cooling_kbtu', j_to_kbtu],
      'Cooling:Water' => ['cooling_gal', m3_to_gal],
      'InteriorLights:Electricity' => ['electricity_interior_lighting_kwh', j_to_kwh],
      'ExteriorLights:Electricity' => ['electricity_exterior_lighting_kwh', j_to_kwh],
      'Elevators:InteriorEquipment:Electricity' => ['electricity_elevators_interior_equipment_kwh', j_to_kwh],
      'InteriorEquipment:Electricity' => ['electricity_interior_equipment_kwh', j_to_kwh],
      'InteriorEquipment:NaturalGas' => ['gas_interior_equipment_kbtu', j_to_kbtu],
      'ExteriorEquipment:Electricity' => ['electricity_exterior_equipment_kwh', j_to_kwh],
      'ExteriorEquipment:NaturalGas' => ['gas_exterior_equipment_kbtu', j_to_kbtu],
      'ResPublicArea:InteriorEquipment:Electricity' => ['electricity_respublicarea_interior_equipment_kwh', j_to_kwh],
      'ResPublicArea:InteriorLights:Electricity' => ['electricity_respublicarea_interior_lighting_kwh', j_to_kwh],
      'Fans:Electricity' => ['electricity_fans_kwh', j_to_kwh],
      'Pumps:Electricity' => ['electricity_pumps_kwh', j_to_kwh],
      'Refrigeration:Electricity' => ['electricity_refrigeration_kwh', j_to_kwh],
      'HeatRecovery:Electricity' => ['electricity_heat_recovery_kwh', j_to_kwh],
      'HeatRejection:Electricity' => ['electricity_heat_rejection_kwh', j_to_kwh],
      'HeatRejection:Water' => ['heat_rejection_gal', m3_to_gal],
      'Humidification:Electricity' => ['electricity_humidification_kwh', j_to_kwh],
      'Generators:Electricity' => ['electricity_generators_kwh', j_to_kwh],
      'ElectricityProduced:Facility' => ['electricity_pv_kwh', j_to_neg_kwh],
      'WaterSystems:Electricity' => ['electricity_water_systems_kwh', j_to_kwh],
      'WaterSystems:NaturalGas' => ['gas_water_systems_kbtu', j_to_kbtu],
      'WaterSystems:DistrictHeatingWater' => ['districtheating_water_systems_kbtu', j_to_kbtu],
      'WaterSystems:Propane' => ['propane_water_systems_kbtu', j_to_kbtu],
      'WaterSystems:FuelOilNo2' => ['fueloil_water_systems_kbtu', j_to_kbtu],
      'WaterSystems:Water' => ['water_systems_gal', m3_to_gal],
      'Electricity:Facility' => ['total_site_electricity_kwh', j_to_kwh],
      'ElectricityNet:Facility' => ['total_net_site_electricity_kwh', j_to_kwh],
      'ElectricityPurchased:Facility' => ['total_purchased_site_electricity_kwh', j_to_kwh],
      'DistrictCooling:Facility' => ['total_site_districtcooling_kbtu', j_to_kbtu],
      'DistrictHeatingWater:Facility' => ['total_site_districtheating_kbtu', j_to_kbtu],
      'NaturalGas:Facility' => ['total_site_gas_kbtu', j_to_kbtu],
      'FuelOilNo2:Facility' => ['total_site_fueloil_kbtu', j_to_kbtu],
      'Propane:Facility' => ['total_site_propane_kbtu', j_to_kbtu],
      'Water:Facility' => ['total_site_water_gal', m3_to_gal]
    }
  end

  # Conversion for a column with no explicitly defined name, mirroring the wildcard rules
  # that were applied by convertESOMTR.  Returns [converted units, conversion factor].
  def fallback_conversion(name, units)
    return ['gal', m3_to_gal] if units == 'm3'
    return [units, nil] unless units == 'J'
    return ['kWh', j_to_kwh] if name =~ /elec/i
    return ['kBtu', j_to_kbtu] if name =~ /gas|districtcooling|districtheating|propane|fueloil/i

    [units, nil]
  end

  # Column name for a variable or meter with no explicitly defined name.  Units are appended
  # the same way they are for the explicitly named columns, so 'CORE_ZN ZN:Zone Mean Air
  # Temperature' in C becomes 'core_zn_zn_zone_mean_air_temperature_c'.
  def fallback_column_name(name, units)
    new_name = name.gsub(':', ' ')
    new_name = new_name.gsub(' - ', '')
    new_name = new_name.gsub('#', '')
    new_name += " #{units}" unless units.empty? || units == 'kgWater/kgDryAir'
    new_name = new_name.gsub(' ', '_')
    new_name = new_name.gsub('__', '_')
    new_name = new_name.gsub('(', '')
    new_name = new_name.gsub(')', '')
    new_name.downcase
  end

  # Parse the header of a native EnergyPlus CSV.  Columns are written as
  # 'Meter Or Variable Name [Units](Frequency)', e.g. 'Heating:Electricity [J](TimeStep)'.
  # Returns an array of hashes describing each column after the leading Date/Time column.
  def parse_native_csv_header(header_line)
    columns = []
    CSV.parse_line(header_line.chomp).each_with_index do |field, index|
      next if index.zero? # Date/Time

      match = /\A(?<name>.*?)\s*\[(?<units>[^\]]*)\]\((?<frequency>[^)]*)\)\z/.match(field.to_s.strip)
      next if match.nil?

      columns << { name: match[:name], units: match[:units], frequency: match[:frequency], index: index }
    end
    columns
  end

  # Select the columns holding the requested meters at the requested reporting frequency,
  # in the order the meters were requested.  Other measures in the workflow request the same
  # meters at other frequencies, so the frequency must be part of the match.
  def select_meter_columns(columns, frequency)
    selected = []
    definitions = meter_column_definitions
    requested_meters.each do |meter|
      column = columns.find do |col|
        col[:frequency].casecmp?(frequency) && col[:name].casecmp?(meter)
      end
      next if column.nil?

      column_name, factor = definitions[meter]
      if column_name.nil?
        units, factor = fallback_conversion(column[:name], column[:units])
        column_name = fallback_column_name(column[:name], units)
      end
      selected << column.merge(column_name: column_name, factor: factor)
    end
    selected
  end

  # Select the columns holding the requested output variables at the requested reporting
  # frequency.  Variable columns are named 'KEY:Variable Name', with one column per key.
  def select_variable_columns(columns, frequency)
    selected = []
    output_vars.each do |output_var|
      columns.each do |col|
        next unless col[:frequency].casecmp?(frequency)
        next unless col[:name].downcase.end_with?(":#{output_var.downcase}")

        units, factor = fallback_conversion(col[:name], col[:units])
        selected << col.merge(column_name: fallback_column_name(col[:name], units), factor: factor)
      end
    end
    selected
  end

  # Yield [timestamp, values] for each row of a native EnergyPlus CSV that holds data for
  # the given columns.  Coarser reporting frequencies share the file with the finest one and
  # are only filled in at the end of their reporting period, so rows without data for the
  # requested columns are skipped.  EnergyPlus also omits trailing empty fields, which makes
  # the rows ragged.
  def each_native_csv_row(path, columns)
    return to_enum(:each_native_csv_row, path, columns) unless block_given?

    indices = columns.map { |col| col[:index] }
    File.foreach(path).with_index do |line, line_num|
      next if line_num.zero? # header

      fields = line.chomp.split(',', -1)
      values = indices.map { |index| fields[index].to_s.strip }
      next if values.all?(&:empty?)

      yield [fields[0].to_s, values]
    end
  end

  # Convert an EnergyPlus timestamp, e.g. ' 01/01  01:00:00', into local, daylight savings,
  # and UTC timestamp strings
  def timestamp_columns(timestamp, year, utc_offset_hr_float, dst_start_datetime, dst_end_datetime)
    dt = DateTime.parse("#{year}-#{timestamp.lstrip.gsub('/', '-')}".gsub('  ', ' '))

    # Create a TimeDST column
    dt_dst = if dst_start_datetime.nil? || dst_end_datetime.nil?
               dt
             elsif (dt >= dst_start_datetime) && (dt < dst_end_datetime)
               dt + (1.0 / 24.0)
             else
               dt
             end

    # Create a TimeUTC column
    # UTC offset is negative for US
    # Subtract negative to get from local time (E+) to UTC
    dt_utc = dt - (utc_offset_hr_float / 24.0)

    [dt.strftime('%Y-%m-%d %H:%M:%S'),
     dt_dst.strftime('%Y-%m-%d %H:%M:%S'),
     dt_utc.strftime('%Y-%m-%d %H:%M:%S')]
  end

  # define the arguments that the user will input
  def arguments(_model = nil)
    args = OpenStudio::Measure::OSArgumentVector.new

    # make an argument for the frequency
    reporting_frequency_chs = OpenStudio::StringVector.new
    reporting_frequency_chs << 'Timestep'
    reporting_frequency_chs << 'Hourly'
    reporting_frequency_chs << 'Daily'
    reporting_frequency_chs << 'Monthly'
    reporting_frequency_chs << 'RunPeriod'
    arg = OpenStudio::Measure::OSArgument.makeChoiceArgument('reporting_frequency', reporting_frequency_chs, true)
    arg.setDisplayName('Reporting Frequency')
    arg.setDefaultValue('Hourly')
    args << arg

    # make an argument for including optional output variables
    arg = OpenStudio::Measure::OSArgument.makeBoolArgument('inc_output_variables', true)
    arg.setDisplayName('Include Output Variables')
    arg.setDefaultValue(false)
    args << arg

    args
  end

  # This method is called on all reporting measures immediately before the translation to E+ IDF.
  # Request the native EnergyPlus CSV output, which is written during the simulation and replaces
  # the convertESOMTR and ReadVarsESO post-processing this measure used to run.
  # NOTE: this method will ONLY be called if you use the C++ CLI, not the `classic` (Ruby) one
  def modelOutputRequests(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # getOutputControlFiles returns the existing object if the model already has one.
    # OutputControl:Files is a unique object and EnergyPlus fails on duplicates.
    output_control_files = model.getOutputControlFiles
    output_control_files.setOutputCSV(true)
    runner.registerInfo('Requesting native EnergyPlus CSV output via OutputControl:Files')

    true
  end

  # return a vector of IdfObject's to request EnergyPlus objects needed by the run method
  def energyPlusOutputRequests(runner, user_arguments)
    super(runner, user_arguments)

    result = OpenStudio::IdfObjectVector.new

    reporting_frequency = runner.getStringArgumentValue('reporting_frequency', user_arguments)
    inc_output_variables = runner.getBoolArgumentValue('inc_output_variables', user_arguments)

    # Request the output for each end use/fuel type combination and end use subcategory
    requested_meters.each do |meter|
      result << OpenStudio::IdfObject.load("Output:Meter,#{meter},#{reporting_frequency};").get
    end

    # Request the output for each variable
    if inc_output_variables
      runner.registerInfo('Requesting Output Variables')
      output_vars.each do |output_var|
        result << OpenStudio::IdfObject.load("Output:Variable,*,#{output_var},#{reporting_frequency};").get
        runner.registerInfo("Requesting Output:Variable,#{output_var},#{reporting_frequency};")
      end
    end

    result
  end

  # define what happens when the measure is run
  def run(runner, user_arguments)
    super(runner, user_arguments)

    # use the built-in error checking
    return false unless runner.validateUserArguments(arguments, user_arguments)

    # Assign the user inputs to variables
    reporting_frequency = runner.getStringArgumentValue('reporting_frequency', user_arguments)
    inc_output_variables = runner.getBoolArgumentValue('inc_output_variables', user_arguments)

    # Define run directory location
    run_dir_typical = File.absolute_path(File.join(Dir.pwd, 'run'))
    run_dir_comstock = File.absolute_path(File.join(Dir.pwd, '..'))
    if File.exist?(run_dir_typical)
      run_dir = run_dir_typical
      runner.registerInfo("run_dir = #{run_dir}")
    elsif File.exist?(run_dir_comstock)
      run_dir = run_dir_comstock
      runner.registerInfo("run_dir = #{run_dir}")
    else
      runner.registerError('Could not find directory with EnergyPlus output, cannont extract timeseries results')
      return false
    end

    # EnergyPlus writes the meters to eplusmtr.csv and the output variables to eplusout.csv
    meter_csv_path = File.join(run_dir, 'eplusmtr.csv')
    variable_csv_path = File.join(run_dir, 'eplusout.csv')
    unless File.exist?(meter_csv_path)
      runner.registerError("Could not find #{meter_csv_path}. The native EnergyPlus CSV output is " \
                           'requested in modelOutputRequests, which is only called by the C++ CLI ' \
                           '(OpenStudio 3.10.0 or newer), not by the classic Ruby CLI.')
      return false
    end

    # Determine the model year
    model = runner.lastOpenStudioModel
    if model.empty?
      runner.registerError('Could not load last OpenStudio model, cannot apply measure.')
      return false
    end
    model = model.get
    year_object = model.getYearDescription
    year = if year_object.calendarYear.is_initialized
             year_object.calendarYear.get
           else
             2009
           end

    # Get the daylight savings dates to create DST timestamp column.
    # RunPeriodControl:DaylightSavingTime is optional, and model.getRunPeriodControlDaylightSavingTime
    # creates it with default dates, so only ask for it if the model already has one.
    dst_start_datetime = nil
    dst_end_datetime = nil
    dst_idd_type = OpenStudio::Model::RunPeriodControlDaylightSavingTime.iddObjectType
    unless model.getObjectsByType(dst_idd_type).empty?
      run_period_control_daylight_saving_time = model.getRunPeriodControlDaylightSavingTime
      dst_start_date = run_period_control_daylight_saving_time.startDate
      # DST starts at 2:00 AM standard time and it ends at 1:00 AM standard time.
      dst_start_datetime_os = OpenStudio::DateTime.new(dst_start_date, OpenStudio::Time.new(0, 2, 0, 0))
      dst_start_datetime = DateTime.parse(dst_start_datetime_os.to_s)
      dst_end_date = run_period_control_daylight_saving_time.endDate
      dst_end_datetime_os = OpenStudio::DateTime.new(dst_end_date, OpenStudio::Time.new(0, 1, 0, 0))
      dst_end_datetime = DateTime.parse(dst_end_datetime_os.to_s)
      runner.registerInfo("Daylight savings time from #{dst_start_datetime.strftime('%A %Y-%m-%d %H:%M:%S')} to #{dst_end_datetime.strftime('%A %Y-%m-%d %H:%M:%S')}")
      runner.registerValue('daylight_savings_start', dst_start_datetime.strftime('%A %Y-%m-%d %H:%M:%S'))
      runner.registerValue('daylight_savings_end', dst_end_datetime.strftime('%A %Y-%m-%d %H:%M:%S'))
    end

    # Get the timezone information to create UTC timestamp column
    utc_offset_hr_float = model.getSite.timeZone
    runner.registerInfo("Local time has UTC offset UTC#{utc_offset_hr_float}")
    runner.registerValue('utc_offset', "UTC#{utc_offset_hr_float}")

    # Find the requested meters in the native EnergyPlus CSV.  Meters with no data in the model
    # are not reported by EnergyPlus and are therefore not included in the export.
    start_time = Time.new
    meter_columns = select_meter_columns(parse_native_csv_header(File.open(meter_csv_path, &:readline)),
                                         reporting_frequency)
    if meter_columns.empty?
      runner.registerError("No #{reporting_frequency} meters found in #{meter_csv_path}, " \
                           'cannot extract timeseries results')
      return false
    end
    runner.registerInfo("Found #{meter_columns.size} #{reporting_frequency} meters in #{File.basename(meter_csv_path)}")

    # Find the requested output variables, which EnergyPlus writes to a separate file
    variable_columns = []
    if inc_output_variables
      if File.exist?(variable_csv_path)
        variable_columns = select_variable_columns(
          parse_native_csv_header(File.open(variable_csv_path, &:readline)), reporting_frequency
        )
        runner.registerInfo("Found #{variable_columns.size} #{reporting_frequency} output variables in #{File.basename(variable_csv_path)}")
      else
        runner.registerWarning("Could not find #{variable_csv_path}, output variables will not be exported")
      end
    end

    # Both files report on the same timestamps, so they can be read in lockstep
    variable_rows = variable_columns.empty? ? nil : each_native_csv_row(variable_csv_path, variable_columns)
    blank_variable_values = [nil] * variable_columns.size
    misaligned = false

    # Write the timeseries results
    enduse_timeseries_path = File.join(run_dir, 'enduse_timeseries.csv')
    rows_written = 0
    CSV.open(enduse_timeseries_path, 'w') do |csv|
      csv << ['Time', 'TimeDST', 'TimeUTC'] +
             meter_columns.map { |col| col[:column_name] } +
             variable_columns.map { |col| col[:column_name] }

      each_native_csv_row(meter_csv_path, meter_columns) do |timestamp, meter_values|
        variable_values = blank_variable_values
        unless variable_rows.nil? || misaligned
          begin
            variable_timestamp, variable_values = variable_rows.next
            if variable_timestamp != timestamp
              misaligned = true
              variable_values = blank_variable_values
            end
          rescue StopIteration
            misaligned = true
            variable_values = blank_variable_values
          end
        end

        values = (meter_columns + variable_columns).zip(meter_values + variable_values).map do |col, value|
          next nil if value.nil? || value.empty?
          next value if col[:factor].nil?

          value.to_f * col[:factor]
        end

        csv << timestamp_columns(timestamp, year, utc_offset_hr_float, dst_start_datetime, dst_end_datetime) + values
        rows_written += 1
      end
    end

    if misaligned
      runner.registerWarning("Timestamps in #{File.basename(variable_csv_path)} do not line up with " \
                             "#{File.basename(meter_csv_path)}, some output variables were not exported")
    end

    end_time = Time.new
    runner.registerInfo("Wrote #{rows_written} rows to #{enduse_timeseries_path} in #{end_time - start_time} seconds")

    true
  end
end

# register the measure to be used by the application
TimeseriesCSVExport.new.registerWithApplication
