# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

require 'erb'
require 'json'

# start the measure
class LoadsSummary < OpenStudio::Measure::ReportingMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'loads_summary'
  end

  # human readable description
  def description
    return ''
  end

  # human readable description of modeling approach
  def modeler_description
    return ''
  end

  # define the arguments that the user will input
  def arguments(model = nil)
    args = OpenStudio::Measure::OSArgumentVector.new

    timeseries_output = OpenStudio::Measure::OSArgument.makeBoolArgument('timeseries_output', true)
    timeseries_output.setDisplayName('Output Timeseries')
    timeseries_output.setDescription('If true, the measure will output timeseries data for each component and mode.')
    timeseries_output.setDefaultValue(false)
    args << timeseries_output

    return args
  end

  # define the outputs that the measure will create
  def outputs
    outs = OpenStudio::Measure::OSOutputVector.new

    # this measure does not produce machine readable outputs with registerValue, return an empty list

    return outs
  end

  def components
    [
      'people_gain',
      'light_gain',
      'equip_gain',
      'ref_equip_gain',
      'win_sol',
      'ext_wall',
      'fnd_wall',
      'roof',
      'ext_flr',
      'gnd_flr',
      'win_cond',
      'door',
      'infil',
      'vent'
    ]
  end

  def modes
    [
      'htg',
      'clg',
      'flt'
    ]
  end

  def variables_names
    [
      'Zone Air Heat Balance System Air Transfer Rate',
      'Zone Air Heat Balance System Convective Heat Gain Rate',
      'Zone People Convective Heating Energy',
      'Zone People Radiant Heating Energy',
      'Zone Lights Convective Heating Energy',
      'Zone Lights Radiant Heating Energy',
      'Zone Electric Equipment Convective Heating Energy',
      'Zone Electric Equipment Radiant Heating Energy',
      'Zone Gas Equipment Convective Heating Energy',
      'Zone Gas Equipment Radiant Heating Energy',
      'Zone Hot Water Equipment Convective Heating Energy',
      'Zone Hot Water Equipment Radiant Heating Energy',
      'Zone Other Equipment Convective Heating Energy',
      'Zone Other Equipment Radiant Heating Energy',
      'Refrigeration Zone Case and Walk In Total Sensible Cooling Energy',
      'Enclosure Windows Total Transmitted Solar Radiation Energy',
      'Surface Window Inside Face Glazing Net Infrared Heat Transfer Rate',
      'Surface Window Inside Face Shade Net Infrared Heat Transfer Rate',
      'Surface Window Inside Face Gap between Shade and Glazing Zone Convection Heat Gain Rate',
      'Surface Inside Face Convection Heat Gain Energy',
      'Surface Inside Face Net Surface Thermal Radiation Heat Gain Energy',
      'Zone Infiltration Sensible Heat Gain Energy',
      'Zone Infiltration Sensible Heat Loss Energy',
      'Zone Mechanical Ventilation Heating Load Increase Energy',
      'Zone Mechanical Ventilation Heating Load Decrease Energy',
      'Zone Mechanical Ventilation Cooling Load Increase Energy',
      'Zone Mechanical Ventilation Cooling Load Decrease Energy',
      'Surface Inside Face Temperature',
      'Surface Inside Face Adjacent Air Temperature'
    ]
  end

  def get_surface_names_areas_by_bc_and_type(zone, boundary_conditions, type)
    surface_info = {}
    zone.spaces.each do |space|
      surfs = space.surfaces.select { |s| boundary_conditions.include? s.outsideBoundaryCondition and s.surfaceType == type }
      surfs.each do |surface|
        surface_info[surface.name.get] = surface.netArea
      end
    end
    surface_info
  end

  def get_subsurface_names_areas_by_type(zone, type)
    subsurface_info = {}
    zone.spaces.each do |space|
      space.surfaces.each do |surface|
        subsurfaces = surface.subSurfaces.select { |s| s.subSurfaceType.downcase.include? type }
        subsurfaces.each do |subsurface|
          subsurface_info[subsurface.name.get] = subsurface.netArea
        end
      end
    end
    subsurface_info
  end

  def get_internal_mass_names_areas(zone)
    internal_mass_info = {}
    zone.spaces.each do |space|
      space.internalMass.each do |internal_mass|
        if internal_mass.surfaceArea.is_initialized
          internal_mass_info[internal_mass.name.get] = internal_mass.surfaceArea.get
        elsif internal_mass.surfaceAreaPerFloorArea.is_initialized
          internal_mass_info[internal_mass.name.get] = internal_mass.surfaceAreaPerFloorArea.get * space.floorArea
        elsif internal_mass.surfaceAreaPerPerson.is_initialized
          internal_mass_info[internal_mass.name.get] = internal_mass.surfaceAreaPerPerson.get * space.numberOfPeople
        end
      end
    end
    internal_mass_info
  end

  def get_surface_info(model)
    surf_h = {}

    model.getThermalZones.sort.each do |zone|
      zone_name = zone.name.get
      surf_h[zone_name] = {}

      surf_h[zone_name]['ext_wall'] = get_surface_names_areas_by_bc_and_type(zone, ['Outdoors'], 'Wall')
      surf_h[zone_name]['fnd_wall'] = get_surface_names_areas_by_bc_and_type(zone, ['Ground', 'GroundFCfactorMethod', 'Foundation'], 'Wall')
      surf_h[zone_name]['roof'] = get_surface_names_areas_by_bc_and_type(zone, ['Outdoors'], 'RoofCeiling')
      surf_h[zone_name]['ext_flr'] = get_surface_names_areas_by_bc_and_type(zone, ['Outdoors'], 'Floor')
      surf_h[zone_name]['gnd_flr'] = get_surface_names_areas_by_bc_and_type(zone, ['Ground', 'GroundFCfactorMethod', 'Foundation'], 'Floor')
      surf_h[zone_name]['win'] = get_subsurface_names_areas_by_type(zone, 'window')
      surf_h[zone_name]['door'] = get_subsurface_names_areas_by_type(zone, 'door')
      surf_h[zone_name]['int_wall'] = get_surface_names_areas_by_bc_and_type(zone, ['Surface', 'Adiabatic'], 'Wall')
      surf_h[zone_name]['int_ceil'] = get_surface_names_areas_by_bc_and_type(zone, ['Surface', 'Adiabatic'], 'RoofCeiling')
      surf_h[zone_name]['int_flr'] = get_surface_names_areas_by_bc_and_type(zone, ['Surface', 'Adiabatic'], 'Floor')
      surf_h[zone_name]['int_mass'] = get_internal_mass_names_areas(zone)
    end

    return surf_h
  end

  # This method is called on all reporting measures immediately before the translation to E+ IDF
  # There is an implicit contract that this method should NOT be modifying your model in a way that would produce
  # different results, meaning it should only add or modify reporting-related elements
  # (eg: OutputTableSummaryReports, OutputControlFiles, etc)
  # If you mean to modify the model in a significant way, use a `ModelMeasure`
  # NOTE: this method will ONLY be called if you use the C++ CLI, not the `classic` (Ruby) one
  def modelOutputRequests(model, runner, user_arguments)
    timeseries_output = runner.getBoolArgumentValue('timeseries_output', user_arguments)

    # request advanced reporting for window heat gain components
    model.getOutputDiagnostics.addKey('DisplayAdvancedReportVariables')

    components.each do |component|
      modes.each do |mode|
        # python plugin variables
        py_var = OpenStudio::Model::PythonPluginVariable.new(model)
        py_var.setName("#{component}_#{mode}_glob")

        # python plugin output variables
        py_out_var = OpenStudio::Model::PythonPluginOutputVariable.new(py_var)
        py_out_var.setName("#{component}_#{mode}")
        py_out_var.setTypeofDatainVariable('Summed')
        py_out_var.setUpdateFrequency('ZoneTimestep')
        py_out_var.setUnits('J')


        # add a regular output variable that references it
        out_var = OpenStudio::Model::OutputVariable.new('PythonPlugin:OutputVariable', model)
        out_var.setKeyValue(py_out_var.nameString)
        if timeseries_output
          out_var.setReportingFrequency('Timestep')
        else
          out_var.setReportingFrequency('RunPeriod')
        end
      end
    end

    # add simulation output variables needed for the plugin
    variables_names.each do |var_name|
      out_var = OpenStudio::Model::OutputVariable.new(var_name, model)
      if timeseries_output
        out_var.setReportingFrequency('Timestep')
      else
        out_var.setReportingFrequency('RunPeriod')
      end
    end

    # read in the template
    rsrcs = "#{File.dirname(__FILE__)}/resources"

    # script_version = runner.getIntegerArgumentValue('script_version', user_arguments)
    # get surface information
    surf_h = get_surface_info(model)
    surf_h_json = JSON.pretty_generate(surf_h)
    temp_path = "#{rsrcs}/python_plugin.py.erb"

    template = ''
    File.open(temp_path, 'r') do |file|
      template = file.read
    end

    # configure template with variable values
    renderer = ERB.new(template)
    py_out = renderer.result(binding)

    # write the python plugin file to resources dir
    plugin_dir = File.join(Dir.pwd, 'python_EMS')
    FileUtils.mkdir_p(plugin_dir)
    plugin_path = File.join(plugin_dir, 'in.py')
    File.write(plugin_path, py_out)

    external_file = OpenStudio::Model::ExternalFile.getExternalFile(model, plugin_path)
    external_file = external_file.get

    # python plugin instance
    python_plugin_instance = OpenStudio::Model::PythonPluginInstance.new(external_file, 'LoadSummary')
    python_plugin_instance.setName('Load Summary')
    python_plugin_instance.setRunDuringWarmupDays(true)

    # python plugin search paths
    # TODO if we need external libraries

    return true
  end

  def get_timeseries_array(runner, sql, env_period, timestep, variable_name, key_value, num_timesteps, expected_units = nil, desired_units = nil)
    time_series_array = []
    time_series = sql.timeSeries(env_period, timestep, variable_name, key_value)
    if time_series.is_initialized # checks to see if time_series exists
      time_series = time_series.get
      # Check the units
      unless expected_units.nil?
        unless time_series.units == expected_units
          runner.registerError("Expected units of #{expected_units} but got #{time_series.units} for #{variable_name}")
        end

        # Convert the units if desired
        if !desired_units.nil? && time_series.units != desired_units
          begin
            conversion = OpenStudio.convert(1.0, time_series.units, desired_units).get
            time_series *= conversion
          rescue StandardError => e
            runner.registerError("Failed to convert units from #{time_series.units} to #{desired_units} for #{variable_name}: #{e.message}")
            return Array.new(num_timesteps, 0.0)
          end
        end
      end

      time_series_array = time_series.values.to_a
    else
      # Query is not valid.
      time_series_array = Array.new(num_timesteps, 0.0)
      runner.registerWarning("Timeseries query: '#{variable_name}' for '#{key_value}' at '#{timestep}' not found, returning array of zeros")
    end

    return time_series_array
  end

  def get_runperiod_variable_value(runner, sql, env_period, key_value, desired_units = nil)
    query = %(
    SELECT rvd.VariableValue
    FROM ReportVariableData AS rvd
    JOIN ReportVariableDataDictionary AS rvdd
      ON rvd.ReportVariableDataDictionaryIndex = rvdd.ReportVariableDataDictionaryIndex
    JOIN Time AS t
      ON rvd.TimeIndex = t.TimeIndex
    WHERE rvdd.KeyValue = '#{key_value}'
    AND rvdd.VariableName = 'PythonPlugin:OutputVariable'
    AND rvdd.ReportingFrequency = 'Run Period'
    AND t.IntervalType = 4;
    )

    result = sql.execAndReturnFirstDouble(query)
    if result.empty?
      runner.registerError("Cannot find run period variable value for #{key_value}")
      return false
    else
      result = result.get
    end

    return desired_units ? OpenStudio.convert(result, 'J', desired_units).get : result
  end

  # define what happens when the measure is run
  def run(runner, user_arguments)
    super(runner, user_arguments)

    # get the last model and sql file
    model = runner.lastOpenStudioModel
    if model.empty?
      runner.registerError('Cannot find last model.')
      return false
    end
    model = model.get

    # use the built-in error checking (need model)
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    timeseries_output = runner.getBoolArgumentValue('timeseries_output', user_arguments)

    # load sql file
    sql_file = runner.lastEnergyPlusSqlFile
    if sql_file.empty?
      runner.registerError('Cannot find last sql file.')
      return false
    end
    sql_file = sql_file.get
    model.setSqlFile(sql_file)

    # get the weather file run period (as opposed to design day run period)
    ann_env_pd = nil
    sql_file.availableEnvPeriods.each do |env_pd|
      env_type = sql_file.environmentType(env_pd)
      if env_type.is_initialized && (env_type.get == OpenStudio::EnvironmentType.new('WeatherRunPeriod'))
        ann_env_pd = env_pd
        break
      end
    end

    # Get the timestep length
    steps_per_hour = if model.getSimulationControl.timestep.is_initialized
                       model.getSimulationControl.timestep.get.numberOfTimestepsPerHour
                     else
                       6 # default OpenStudio timestep if none specified
                     end

    # Get the annual hours simulated
    hrs_sim = 0
    if sql_file.hoursSimulated.is_initialized
      hrs_sim = sql_file.hoursSimulated.get
    else
      runner.registerError('An annual simulation was not run. Cannot summarize annual heat transfer for Scout.')
      return false
    end

    # Determine the number of timesteps
    num_ts = hrs_sim * steps_per_hour

    # query the component outputs and register values
    components.each do |component|
      modes.each do |mode|
        if timeseries_output
          ts = get_timeseries_array(runner, sql_file, ann_env_pd, 'Zone Timestep', 'PythonPlugin:OutputVariable', "#{component}_#{mode}", num_ts, 'J', 'GJ')
          runner.registerValue("#{component}_#{mode}", ts.sum, 'GJ')
        else
          value = get_runperiod_variable_value(runner, sql_file, ann_env_pd, "#{component}_#{mode}", 'GJ')
          runner.registerValue("#{component}_#{mode}", value, 'GJ')
        end
      end
    end

    # close the sql file
    sql_file.close

    return true
  end
end

# register the measure to be used by the application
LoadsSummary.new.registerWithApplication
