# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

require 'erb'
require 'csv'
require 'tempfile'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'date'
require 'time'

# start the measure
class TimeseriesCSVExport < OpenStudio::Measure::ReportingMeasure
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
    'Timeseries CSV Export'
  end

  # human readable description
  def description
    'Exports all available hourly timeseries enduses to csv, and uses them for utility bill calculations.'
  end

  # human readable description of modeling approach
  def modeler_description
    'Exports all available hourly timeseries enduses to csv, and uses them for utility bill calculations.'
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

  def header_line_edits(line)
    new_line = line
    new_line = new_line.gsub('Timestep', '')
    new_line = new_line.gsub('TimeStep', '')
    new_line = new_line.gsub('timestep', '')
    new_line = new_line.gsub('Hourly', '')
    new_line = new_line.gsub('hourly', '')
    new_line = new_line.gsub('Daily', '')
    new_line = new_line.gsub('daily', '')
    new_line = new_line.gsub('Monthly', '')
    new_line = new_line.gsub('monthly', '')
    new_line = new_line.gsub('RunPeriod', '')
    new_line = new_line.gsub('runperiod', '')
    new_line = new_line.gsub('Date/Time', 'Time')
    new_line = new_line.gsub('Heating:Electricity [kWh]', 'electricity_heating_kwh')
    new_line = new_line.gsub('Heating:DistrictHeatingWater [kBtu]', 'districtheating_heating_kbtu')
    new_line = new_line.gsub('Heating:NaturalGas [kBtu]', 'gas_heating_kbtu')
    new_line = new_line.gsub('Heating:Propane [kBtu]', 'propane_heating_kbtu')
    new_line = new_line.gsub('Heating:FuelOilNo2 [kBtu]', 'fueloil_heating_kbtu')
    new_line = new_line.gsub('Cooling:Electricity [kWh]', 'electricity_cooling_kwh')
    new_line = new_line.gsub('Cooling:DistrictCooling [kBtu]', 'districtcooling_cooling_kbtu')
    new_line = new_line.gsub('Cooling:Water [gal]', 'cooling_gal')
    new_line = new_line.gsub('InteriorLights:Electricity [kWh]', 'electricity_interior_lighting_kwh')
    new_line = new_line.gsub('ExteriorLights:Electricity [kWh]', 'electricity_exterior_lighting_kwh')
    new_line = new_line.gsub('Elevators:InteriorEquipment:Electricity [kWh]',
                             'electricity_elevators_interior_equipment_kwh')
    new_line = new_line.gsub('InteriorEquipment:Electricity [kWh]', 'electricity_interior_equipment_kwh')
    new_line = new_line.gsub('InteriorEquipment:NaturalGas [kBtu]', 'gas_interior_equipment_kbtu')
    new_line = new_line.gsub('ExteriorEquipment:Electricity [kWh]', 'electricity_exterior_equipment_kwh')
    new_line = new_line.gsub('ExteriorEquipment:NaturalGas [kBtu]', 'gas_exterior_equipment_kbtu')
    new_line = new_line.gsub('ResPublicArea:InteriorEquipment:Electricity [kWh]',
                             'electricity_respublicarea_interior_equipment_kwh')
    new_line = new_line.gsub('ResPublicArea:InteriorLights:Electricity [kWh]',
                             'electricity_respublicarea_interior_lighting_kwh')
    new_line = new_line.gsub('Fans:Electricity [kWh]', 'electricity_fans_kwh')
    new_line = new_line.gsub('Pumps:Electricity [kWh]', 'electricity_pumps_kwh')
    new_line = new_line.gsub('Refrigeration:Electricity [kWh]', 'electricity_refrigeration_kwh')
    new_line = new_line.gsub('HeatRecovery:Electricity [kWh]', 'electricity_heat_recovery_kwh')
    new_line = new_line.gsub('HeatRejection:Electricity [kWh]', 'electricity_heat_rejection_kwh')
    new_line = new_line.gsub('HeatRejection:Water [gal]', 'heat_rejection_gal')
    new_line = new_line.gsub('Humidification:Electricity [kWh]', 'electricity_humidification_kwh')
    new_line = new_line.gsub('Generators:Electricity [kWh]', 'electricity_generators_kwh')
    new_line = new_line.gsub('ElectricityProduced:Facility [neg_kWh]', 'electricity_pv_kwh')
    new_line = new_line.gsub('WaterSystems:Electricity [kWh]', 'electricity_water_systems_kwh')
    new_line = new_line.gsub('WaterSystems:NaturalGas [kBtu]', 'gas_water_systems_kbtu')
    new_line = new_line.gsub('WaterSystems:DistrictHeatingWater [kBtu]', 'districtheating_water_systems_kbtu')
    new_line = new_line.gsub('WaterSystems:Propane [kBtu]', 'propane_water_systems_kbtu')
    new_line = new_line.gsub('WaterSystems:FuelOilNo2 [kBtu]', 'fueloil_water_systems_kbtu')
    new_line = new_line.gsub('WaterSystems:Water [gal]', 'water_systems_gal')
    new_line = new_line.gsub('Electricity:Facility [kWh]', 'total_site_electricity_kwh')
    new_line = new_line.gsub('ElectricityNet:Facility [kWh]', 'total_net_site_electricity_kwh')
    new_line = new_line.gsub('ElectricityPurchased:Facility [kWh]', 'total_purchased_site_electricity_kwh')
    new_line = new_line.gsub('DistrictCooling:Facility [kBtu]', 'total_site_districtcooling_kbtu')
    new_line = new_line.gsub('DistrictHeatingWater:Facility [kBtu]', 'total_site_districtheating_kbtu')
    new_line = new_line.gsub('NaturalGas:Facility [kBtu]', 'total_site_gas_kbtu')
    new_line = new_line.gsub('FuelOilNo2:Facility [kBtu]', 'total_site_fueloil_kbtu')
    new_line = new_line.gsub('Propane:Facility [kBtu]', 'total_site_propane_kbtu')
    new_line = new_line.gsub('Water:Facility [gal]', 'total_site_water_gal')
    new_line = new_line.gsub(':', ' ')
    new_line = new_line.gsub(' - ', '')
    new_line = new_line.gsub('#', '')
    new_line = new_line.gsub('[C]', '_c')
    new_line = new_line.gsub('[kgWater/kgDryAir]', '')
    new_line = new_line.gsub(' ', '_')
    new_line = new_line.gsub('__', '_')
    new_line = new_line.gsub('(', '')
    new_line = new_line.gsub(')', '')
    new_line = new_line.downcase
    new_line = new_line.gsub('ratio_', 'ratio')
    new_line.gsub('time', 'Time,TimeDST,TimeUTC')
  end

  def datetime_edits(line, year, utc_offset_hr_float, dst_start_datetime, dst_end_datetime)
    new_line = "#{year}-#{line.lstrip.gsub('/', '-')}"
    new_line = new_line.gsub('  ', ' ')
    dt = DateTime.parse(new_line.split(',')[0])
    dt_str = dt.strftime('%Y-%m-%d %H:%M:%S')

    # Create a TimeDST column
    dt_dst = if dst_start_datetime.nil? || dst_end_datetime.nil?
               dt
             elsif (dt >= dst_start_datetime) && (dt < dst_end_datetime)
               dt + (1.0 / 24.0)
             else
               dt
             end
    dt_dst_str = dt_dst.strftime('%Y-%m-%d %H:%M:%S')

    # Create a TimeUTC column
    # UTC offset is negative for US
    # Subtract negative to get from local time (E+) to UTC
    dt_utc = dt - (utc_offset_hr_float / 24.0)
    dt_utc_str = dt_utc.strftime('%Y-%m-%d %H:%M:%S')

    "#{dt_str},#{dt_dst_str},#{dt_utc_str}," + new_line.split(',')[1..].join(',')
  end

  def output_vars
    ['Zone Mean Air Temperature',
     'Zone Mean Air Humidity Ratio',
     'Fan Runtime Fraction']
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

  # return a vector of IdfObject's to request EnergyPlus objects needed by the run method
  def energyPlusOutputRequests(runner, user_arguments)
    super(runner, user_arguments)

    result = OpenStudio::IdfObjectVector.new

    reporting_frequency = runner.getStringArgumentValue('reporting_frequency', user_arguments)
    inc_output_variables = runner.getBoolArgumentValue('inc_output_variables', user_arguments)

    # Request the output for each end use/fuel type combination
    end_uses.each do |end_use|
      fuel_types.each do |fuel_type|
        variable_name = if end_use == 'Facility'
                          "#{fuel_type}:#{end_use}"
                        else
                          "#{end_use}:#{fuel_type}"
                        end
        result << OpenStudio::IdfObject.load("Output:Meter,#{variable_name},#{reporting_frequency};").get
      end
    end

    # Request the output for each end use subcategory/end use/fuel type combination
    end_use_subcats.each do |subcat|
      result << OpenStudio::IdfObject.load("Output:Meter,#{subcat},#{reporting_frequency};").get
    end

    # add outputs for PV
    # result << OpenStudio::IdfObject.load("Output:Meter,#{subcat},#{reporting_frequency};").get

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

    # Write the file that defines the unit conversions
    convert_txt_path = File.join(run_dir, 'convert.txt')
    File.open(convert_txt_path, 'w') do |f|
      # PV
      f.puts('!PV Negative Conversion')
      f.puts('conv,J,neg_kWh,-2.777778E-07,0')
      f.puts('vari,ElectricityProduced:Facility,J,neg_kWh')
      # electricity
      f.puts('!Electricity')
      f.puts('conv,J,kWh,2.777778E-07,0')
      f.puts('wild,elec,J,kWh')
      # natural gas
      f.puts('!Natural Gas')
      f.puts('conv,J,kBtu,9.484517E-07,0')
      f.puts('wild,gas,J,kBtu')
      # district cooling
      f.puts('!District Cooling')
      f.puts('conv,J,kBtu,9.484517E-07,0')
      f.puts('wild,districtcooling,J,kBtu')
      # district heating
      f.puts('!District Heating')
      f.puts('conv,J,kBtu,9.484517E-07,0')
      f.puts('wild,districtheating,J,kBtu')
      # propane
      f.puts('!Propane')
      f.puts('conv,J,kBtu,9.484517E-07,0')
      f.puts('wild,propane,J,kBtu')
      # fuel oil
      f.puts('!Fuel Oil')
      f.puts('conv,J,kBtu,9.484517E-07,0')
      f.puts('wild,fueloil,J,kBtu')
      # water
      f.puts('!Water')
      f.puts('conv,m3,gal,2.641720E+02,0')
    end

    # Write the RVI file, which defines the CSV columns requested
    rvi_path = File.join(run_dir, 'var_request.rvi')
    enduse_timeseries_name = 'enduse_timeseries.csv'
    File.open(rvi_path, 'w') do |f|
      f.puts('ip.eso') # convertESOMTR always uses this name
      f.puts(enduse_timeseries_name)

      # End Use/Fuel Type
      end_uses.each do |end_use|
        fuel_types.each do |fuel_type|
          variable_name = if end_use == 'Facility'
                            "#{fuel_type}:#{end_use}"
                          else
                            "#{end_use}:#{fuel_type}"
                          end
          f.puts(variable_name)
        end
      end

      # End Use Subcategories
      end_use_subcats.each do |subcat|
        f.puts(subcat)
      end

      # Optionally request timeseries
      if inc_output_variables
        output_vars.each do |output_var|
          f.puts(output_var)
        end
      end
      f.puts('0') # end-of-file marker
    end

    # Copy the necessary executables to the run directory
    start_time = Time.new
    resources_dir = File.absolute_path(File.join(__dir__, 'resources'))
    runner.registerInfo("resources_dir = #{resources_dir}")

    # Copy convertESOMTR
    convert_eso_hash = {
      windows: 'convertESOMTR.exe',
      linux: 'convertESOMTR',
      macosx: 'convertESOMTR.osx' # Made up extension to differentiate from linux
    }
    convert_eso_name = convert_eso_hash[os]
    orig_convert_eso_path = File.join(resources_dir, convert_eso_name)
    convert_eso_path = File.join(run_dir, convert_eso_name)
    FileUtils.cp(orig_convert_eso_path, convert_eso_path)
    if os == :linux
      runner.registerInfo("#{convert_eso_path} exists? #{File.exist?(convert_eso_path)}")
      runner.registerInfo("Before chmod +x, #{convert_eso_path} executable? #{File.executable?(convert_eso_path)}")
      FileUtils.chmod('+x', convert_eso_path)
      runner.registerInfo("After chmod +x, #{convert_eso_path} executable? #{File.executable?(convert_eso_path)}")
    end

    # Copy ReadVarsESO
    readvars_eso_hash = {
      windows: 'ReadVarsESO.exe',
      linux: 'ReadVarsESO',
      macosx: 'ReadVarsESO.osx' # Made up extension to differentiate from linux
    }
    readvars_eso_name = readvars_eso_hash[os]
    orig_readvars_eso_path = File.join(resources_dir, readvars_eso_name)
    readvars_eso_path = File.join(run_dir, readvars_eso_name)
    FileUtils.cp(orig_readvars_eso_path, readvars_eso_path)
    if os == :linux
      runner.registerInfo("#{convert_eso_path} exists? #{File.exist?(convert_eso_path)}")
      runner.registerInfo("Before chmod +x, #{convert_eso_path} executable? #{File.executable?(convert_eso_path)}")
      FileUtils.chmod('+x', readvars_eso_path)
      runner.registerInfo("After chmod +x, #{convert_eso_path} executable? #{File.executable?(convert_eso_path)}")
    end

    # Copy libraries (OSX only)
    if os == :macosx
      ['libgcc_s.1.dylib', 'libgfortran.5.dylib', 'libquadmath.0.dylib'].each do |dylib|
        FileUtils.cp(File.join(resources_dir, dylib), File.join(run_dir, dylib))
      end
    end
    end_time = Time.new
    runner.registerInfo("Copying executables took #{end_time - start_time} seconds")

    # Call convertESOMTR
    start_time = Time.new
    command = convert_eso_path.to_s
    stdout_str, stderr_str, status = Open3.capture3(command, chdir: run_dir)
    if status.success?
      runner.registerInfo("Successfully ran convertESOMTR: #{command}")
    else
      runner.registerError("Error running convertESOMTR: #{command}")
      runner.registerError("stdout: #{stdout_str}")
      runner.registerError("stderr: #{stderr_str}")
      return false
    end
    end_time = Time.new
    runner.registerInfo("Running convertESOMTR took #{end_time - start_time} seconds")

    # Call ReadVarsESO
    start_time = Time.new
    command = "#{readvars_eso_path} #{File.basename(rvi_path)} #{reporting_frequency} Unlimited FixHeader"
    stdout_str, stderr_str, status = Open3.capture3(command, chdir: run_dir)
    if status.success?
      runner.registerInfo("Successfully ran convertESOMTR: #{command}")
    else
      runner.registerError("Error running convertESOMTR: #{command}")
      runner.registerError("stdout: #{stdout_str}")
      runner.registerError("stderr: #{stderr_str}")
      return false
    end
    end_time = Time.new
    runner.registerInfo("Running ReadVarsESO took #{end_time - start_time} seconds")

    # Get the daylight savings dates to create DST timestamp column
    run_period_control_daylight_saving_time = nil
    model.getModelObjects.each do |model_object| # FIXME: getRunPeriodControlDaylightSavingTime creates the object with defaults
      obj_type = model_object.to_s.split(',')[0].gsub('OS:', '').gsub(':', '')
      next if obj_type != 'RunPeriodControlDaylightSavingTime'

      run_period_control_daylight_saving_time = model.getRunPeriodControlDaylightSavingTime
      break
    end
    unless run_period_control_daylight_saving_time.nil?
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

    # Read in enduse_timeseries.csv and convert datetime and headers
    # from https://stackoverflow.com/a/4174125
    filename = File.join(run_dir, 'enduse_timeseries.csv')
    tempdir = File.dirname(filename)
    tempprefix = File.basename(filename)
    tempprefix.prepend('.') unless RUBY_PLATFORM =~ /mswin|mingw|windows/
    tempfile =
      begin
        Tempfile.new(tempprefix, tempdir)
      rescue StandardError
        Tempfile.new(tempprefix)
      end
    f = File.open(filename, 'r').each_with_index do |line, i|
      if i == 0
        tempfile.puts header_line_edits(line)
      else
        tempfile.puts datetime_edits(line, year, utc_offset_hr_float, dst_start_datetime, dst_end_datetime)
      end
    end
    f.close
    tempfile.fdatasync unless RUBY_PLATFORM =~ /mswin|mingw|windows/
    tempfile.close
    unless RUBY_PLATFORM =~ /mswin|mingw|windows/
      stat = File.stat(filename)
      FileUtils.chown stat.uid, stat.gid, tempfile.path
      FileUtils.chmod stat.mode, tempfile.path
    end
    FileUtils.mv tempfile.path, filename

    true
  end
end

# register the measure to be used by the application
TimeseriesCSVExport.new.registerWithApplication
