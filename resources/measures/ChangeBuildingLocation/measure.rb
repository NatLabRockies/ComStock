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

# Authors : Nicholas Long, David Goldwasser
# Simple measure to load the EPW file and DDY file

# dependencies
require_relative 'resources/epw'
require_relative 'resources/os_lib_helper_methods'
require_relative 'resources/stat_file'

class ChangeBuildingLocation < OpenStudio::Measure::ModelMeasure
  # resource file modules
  include OsLib_HelperMethods

  # define the name that a user will see, this method may be deprecated as
  # the display name in PAT comes from the name field in measure.xml
  def name
    'ChangeBuildingLocation'
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

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    weather_file_name = OpenStudio::Measure::OSArgument.makeStringArgument('weather_file_name', true)
    weather_file_name.setDisplayName('Weather File Name')
    weather_file_name.setDescription('Name of the weather file to change to. This is the filename with the extension (e.g. NewWeather.epw). Optionally this can include the full file path, but for most use cases should just be file name.')
    args << weather_file_name

    year = OpenStudio::Measure::OSArgument.makeStringArgument('year', true)
    year.setDisplayName('Weather File Year')
    year.setDescription('Year of the weather file to use.')
    args << year

    # make choice argument for climate zone
    choices = OpenStudio::StringVector.new
    choices << 'Lookup From Stat File'
    choices << 'ASHRAE 169-2013-1A'
    choices << 'ASHRAE 169-2013-1B'
    choices << 'ASHRAE 169-2013-2A'
    choices << 'ASHRAE 169-2013-2B'
    choices << 'ASHRAE 169-2013-3A'
    choices << 'ASHRAE 169-2013-3B'
    choices << 'ASHRAE 169-2013-3C'
    choices << 'ASHRAE 169-2013-4A'
    choices << 'ASHRAE 169-2013-4B'
    choices << 'ASHRAE 169-2013-4C'
    choices << 'ASHRAE 169-2013-5A'
    choices << 'ASHRAE 169-2013-5B'
    choices << 'ASHRAE 169-2013-5C'
    choices << 'ASHRAE 169-2013-6A'
    choices << 'ASHRAE 169-2013-6B'
    choices << 'ASHRAE 169-2013-7A'
    choices << 'ASHRAE 169-2013-8A'
    choices << 'T24-CEC1'
    choices << 'T24-CEC2'
    choices << 'T24-CEC3'
    choices << 'T24-CEC4'
    choices << 'T24-CEC5'
    choices << 'T24-CEC6'
    choices << 'T24-CEC7'
    choices << 'T24-CEC8'
    choices << 'T24-CEC9'
    choices << 'T24-CEC10'
    choices << 'T24-CEC11'
    choices << 'T24-CEC12'
    choices << 'T24-CEC13'
    choices << 'T24-CEC14'
    choices << 'T24-CEC15'
    choices << 'T24-CEC16'
    climate_zone = OpenStudio::Measure::OSArgument.makeChoiceArgument('climate_zone', choices, true)
    climate_zone.setDisplayName('Climate Zone.')
    climate_zone.setDefaultValue('Lookup From Stat File')
    args << climate_zone

    # make an argument for the grid region
    grid_region_chs = OpenStudio::StringVector.new
    grid_regions.each { |grid_region| grid_region_chs << grid_region }
    grid_region = OpenStudio::Measure::OSArgument.makeChoiceArgument('grid_region', grid_region_chs, true)
    grid_region.setDisplayName('Grid Region')
    grid_region.setDescription('Cambium electric grid region, or eGrid region for Alaska and Hawaii')
    grid_region.setDefaultValue('RMPAc')
    args << grid_region

    # make argument for soil conductivity (used for ground source heat pump modeling)
    soil_conductivity = OpenStudio::Ruleset::OSArgument.makeDoubleArgument('soil_conductivity', true)
    soil_conductivity.setDisplayName('Soil Conductivity')
    soil_conductivity.setDefaultValue(1.5) # Default value, change as needed
    args << soil_conductivity

    return args
  end

  # Define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # assign the user inputs to variables
    args = OsLib_HelperMethods.createRunVariables(runner, model, user_arguments, arguments(model))
    if !args then return false end

    # create initial condition
    if model.getWeatherFile.city == ''
      runner.registerInitialCondition("No weather file is set. The model has #{model.getDesignDays.size} design day objects")
    else
      runner.registerInitialCondition("The initial weather file is #{model.getWeatherFile.city} and the model has #{model.getDesignDays.size} design day objects")
    end

    # set grid region
    model.getBuilding.additionalProperties.setFeature('grid_region', args['grid_region'])
    runner.registerInfo("Set '#{args['grid_region']}' as the grid_region in the building additional properties.")

    # find weather file, checking both the location specified in the osw
    # and the path used by ComStock meta-measure
    wf_name = args['weather_file_name'].gsub('YEAR', args['year'])
    comstock_weather_file = File.absolute_path(File.join(Dir.pwd, '../../../weather', wf_name))
    osw_weather_file = runner.workflow.findFile(wf_name)
    if File.file? comstock_weather_file
      weather_file = comstock_weather_file
    elsif osw_weather_file.is_initialized
      weather_file = osw_weather_file.get.to_s
    else
      runner.registerError("Did not find #{wf_name} in paths described in OSW file or in default ComStock workflow location of #{comstock_weather_file}.")
      return false
    end

    # Parse the EPW manually because OpenStudio can't handle multiyear weather files (or DATA PERIODS with YEARS)
    epw_file = OpenStudio::Weather::Epw.load(weather_file)

    weather_file = model.getWeatherFile
    weather_file.setCity(epw_file.city)
    weather_file.setStateProvinceRegion(epw_file.state)
    weather_file.setCountry(epw_file.country)
    weather_file.setDataSource(epw_file.data_type)
    weather_file.setWMONumber(epw_file.wmo.to_s)
    weather_file.setLatitude(epw_file.lat)
    weather_file.setLongitude(epw_file.lon)
    weather_file.setTimeZone(epw_file.gmt)
    weather_file.setElevation(epw_file.elevation)
    if model.version < OpenStudio::VersionString.new('3.0.0')
      weather_file.setString(10, "file:///#{epw_file.filename}")
    else
      weather_file.setString(10, epw_file.filename)
    end
    weather_name = "#{epw_file.city}_#{epw_file.state}_#{epw_file.country}"
    weather_lat = epw_file.lat
    weather_lon = epw_file.lon
    weather_time = epw_file.gmt
    weather_elev = epw_file.elevation

    # Add or update site data
    site = model.getSite
    site.setName(weather_name)
    site.setLatitude(weather_lat)
    site.setLongitude(weather_lon)
    site.setTimeZone(weather_time)
    site.setElevation(weather_elev)

    # set site terrain assumption for wind speed modifications for infiltration
    terrain = 'City' # default for now
    site.setTerrain(terrain)

    runner.registerInfo("city is #{epw_file.city}. State is #{epw_file.state}")

    # Add SiteWaterMainsTemperature -- via parsing of STAT file.
    stat_file = "#{File.join(File.dirname(epw_file.filename), File.basename(epw_file.filename, '.*'))}.stat"
    unless File.exist? stat_file
      runner.registerInfo 'Could not find STAT file by filename, looking in the directory'
      stat_files = Dir["#{File.dirname(epw_file.filename)}/*.stat"]
      if stat_files.size > 1
        runner.registerError('More than one stat file in the EPW directory')
        return false
      end
      if stat_files.empty?
        runner.registerError('Cound not find the stat file in the EPW directory')
        return false
      end

      runner.registerInfo "Using STAT file: #{stat_files.first}"
      stat_file = stat_files.first
    end
    unless stat_file
      runner.registerError 'Could not find stat file'
      return false
    end

    stat_model = EnergyPlus::StatFile.new(stat_file)
    water_temp = model.getSiteWaterMainsTemperature
    water_temp.setAnnualAverageOutdoorAirTemperature(stat_model.mean_dry_bulb)
    water_temp.setMaximumDifferenceInMonthlyAverageOutdoorAirTemperatures(stat_model.delta_dry_bulb)
    runner.registerInfo("mean dry bulb is #{stat_model.mean_dry_bulb}")

    # Remove all the Design Day objects that are in the file
    model.getObjectsByType('OS:SizingPeriod:DesignDay'.to_IddObjectType).each(&:remove)

    # find the ddy files
    ddy_file = "#{File.join(File.dirname(epw_file.filename), File.basename(epw_file.filename, '.*'))}.ddy"
    unless File.exist? ddy_file
      ddy_files = Dir["#{File.dirname(epw_file.filename)}/*.ddy"]
      if ddy_files.size > 1
        runner.registerError('More than one ddy file in the EPW directory')
        return false
      end
      if ddy_files.empty?
        runner.registerError('could not find the ddy file in the EPW directory')
        return false
      end

      ddy_file = ddy_files.first
    end

    unless ddy_file
      runner.registerError "Could not find DDY file for #{ddy_file}"
      return error
    end

    ddy_model = OpenStudio::EnergyPlus.loadAndTranslateIdf(ddy_file).get

    # Warn if no design days are present in the ddy file
    if ddy_model.getDesignDays.empty?
      runner.registerWarning('No design days were found in the ddy file.')
    end

    ddy_model.getDesignDays.sort.each do |d|
      # grab only the ones that matter
      ddy_list = [
        /Htg 99.6. Condns DB/, # Annual heating 99.6%
        /Clg .4. Condns WB=>MDB/, # Annual humidity (for cooling towers and evap coolers)
        /Clg .4. Condns DB=>MWB/, # Annual cooling
        /August .4. Condns DB=>MCWB/, # Monthly cooling DB=>MCWB (to handle solar-gain-driven cooling)
        /September .4. Condns DB=>MCWB/,
        /October .4. Condns DB=>MCWB/
      ]
      ddy_list.each do |ddy_name_regex|
        if d.name.get.to_s =~ ddy_name_regex
          runner.registerInfo("Adding object #{d.name}")

          # add the object to the existing model
          model.addObject(d.clone)
          break
        end
      end
    end

    # Warn if no design days were added
    if model.getDesignDays.empty?
      runner.registerWarning('No design days were added to the model.')
    end

    # Set climate zone
    climate_zones = model.getClimateZones
    if args['climate_zone'] == 'Lookup From Stat File'

      # get climate zone from stat file
      text = nil
      File.open(stat_file) do |f|
        text = f.read.force_encoding('iso-8859-1')
      end

      # Get Climate zone.
      # - Climate type "3B" (ASHRAE Standard 196-2013 Climate Zone)**
      # - Climate type "6A" (ASHRAE Standards 90.1-2004 and 90.2-2004 Climate Zone)**
      regex = /Climate type "(.*?)" \(ASHRAE Standards?(.*)\)\*\*/
      match_data = text.match(regex)
      if match_data.nil?
        runner.registerWarning("Can't find ASHRAE climate zone in stat file.")
      else
        args['climate_zone'] = match_data[1].to_s.strip
      end

    end
    # set climate zone
    climate_zones.clear
    if args['climate_zone'].include?('CEC')
      climate_zones.setClimateZone('CEC', args['climate_zone'].gsub('CEC T24-CEC', '').gsub('T24-CEC', ''))
      runner.registerInfo("Setting Climate Zone to #{climate_zones.getClimateZones('CEC').first.value}")
    else
      climate_zones.setClimateZone('ASHRAE', args['climate_zone'].gsub(/ASHRAE .*-.*-/, ''))
      runner.registerInfo("Setting Climate Zone to #{climate_zones.getClimateZones('ASHRAE').first.value}")
    end

    # set soil properties as building additional properties for ground source heat pump modeling
    soil_conductivity = runner.getDoubleArgumentValue('soil_conductivity', user_arguments)

    # get climate zone and set undisturbed ground temp (used for ground source heat pump modeling)
    climate_zone = runner.getStringArgumentValue('climate_zone', user_arguments)
    puts "climate zone = #{climate_zone}"

    undisturbed_ground_temps = {
      'ASHRAE 169-2013-1A' => 25.9,
      'ASHRAE 169-2013-2A' => 20.9,
      'ASHRAE 169-2013-2B' => 25.0,
      'T24-CEC15' => 25.0,
      'ASHRAE 169-2013-3A' => 17.9,
      'ASHRAE 169-2013-3B' => 19.7,
      'T24-CEC7' => 19.7,
      'T24-CEC8' => 19.7,
      'T24-CEC9' => 19.7,
      'T24-CEC10' => 19.7,
      'T24-CEC11' => 19.7,
      'T24-CEC12' => 19.7,
      'T24-CEC13' => 19.7,
      'T24-CEC14' => 19.7,
      'ASHRAE 169-2013-3C' => 17.0,
      'T24-CEC2' => 17.0,
      'T24-CEC3' => 17.0,
      'T24-CEC4' => 17.0,
      'T24-CEC5' => 17.0,
      'T24-CEC6' => 17.0,
      'ASHRAE 169-2013-4A' => 14.7,
      'ASHRAE 169-2013-4B' => 16.3,
      'T24-CEC1' => 16.3,
      'ASHRAE 169-2013-4C' => 13.3,
      'ASHRAE 169-2013-5A' => 11.5,
      'ASHRAE 169-2013-5B' => 12.9,
      'T24-CEC16' => 12.9,
      'ASHRAE 169-2013-6A' => 9.0,
      'ASHRAE 169-2013-6B' => 9.3,
      'ASHRAE 169-2013-7A' => 7.0,
      'ASHRAE 169-2013-7B' => 6.5,
      'ASHRAE 169-2013-7' => 5.4,
      'ASHRAE 169-2013-8A' => 2.3,
      'ASHRAE 169-2013-8' => 2.3
    }

    undisturbed_ground_temp = undisturbed_ground_temps[climate_zone] || runner.registerError('Climate zone not found.')

    # Add the values as additional properties to the building
    building = model.getBuilding
    building.additionalProperties.setFeature('Soil Conductivity', soil_conductivity)
    building.additionalProperties.setFeature('Undisturbed Ground Temperature', undisturbed_ground_temp)

    # Report that the measure was successful
    runner.registerInfo("Added soil conductivity #{soil_conductivity} Btu/hr-ft-F and undisturbed ground temperature #{undisturbed_ground_temp} degC as additional properties to the building.")

    return true

    # add final condition
    runner.registerFinalCondition("The final weather file is #{model.getWeatherFile.city} and the model has #{model.getDesignDays.size} design day objects.")

    true
  end
end

# This allows the measure to be use by the application
ChangeBuildingLocation.new.registerWithApplication
