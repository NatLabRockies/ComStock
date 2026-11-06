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

require 'comstock-typical'
require 'json'

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

# start the measure
class UpgradeAddPvwatts < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    'upgrade_add_pvwatts'
  end

  # human readable description
  def description
    'Adds rooftop fixed solar photovolatic panels based on user-specified fraction of roof area covered.'
  end

  # human readable description of modeling approach
  def modeler_description
    'Uses PV Watts solar objects'
  end

  # returns the 'optimal' fixed PV array tilt based on latitude
  # from: https://doi.org/10.1016/j.solener.2018.04.030, Figure 1.
  #
  # @param latitude [Double] building site latitude (degrees)
  # @return [Array] array of [tilt, azimuth]
  def model_pv_optimal_fixed_position(latitude)
    # ensure float
    latitude = latitude.to_f
    if latitude > 0
      # northern hemisphere
      tilt = 1.3793 + (latitude * (1.2011 + (latitude * (-0.014404 + (latitude * 0.000080509)))))
      # from EnergyPlus I/O: An azimuth angle of 180◦ is for a south-facing array, and an azimuth angle of 0◦ is for anorth-facing array.
      azimuth = 180.0
    else
      # southern hemisphere - calculates negative tilt from negative latitude
      tilt = -0.41657 + (latitude * (1.4216 + (latitude * (0.024051 + (latitude * 0.00021828)))))
      tilt = abs(tilt)
      azimuth = 0.0
    end
    # To allow for rain to naturally clean panels, optimal tilt angles between −10 and +10° latitude
    # are usually limited to either −10° (for negative values) or +10° (for positive values)
    tilt = 10.0 if tilt.abs < 10.0
    [tilt, azimuth]
  end

  # creates a Generator:PVWatts
  # TODO modify for tracking systems
  def model_add_pvwatts_system(model,
                               name: 'PV System',
                               module_type: 'Premium',
                               array_type: 'FixedRoofMounted',
                               system_capacity_kw: nil,
                               system_losses: 0.14,
                               azimuth_angle: nil,
                               tilt_angle: nil)
    system_capacity_w = system_capacity_kw * 1000
    pvw_generator = OpenStudio::Model::GeneratorPVWatts.new(model, system_capacity_w)
    pvw_generator.setName(name)
    if ['Standard', 'Premium', 'ThinFilm'].include? module_type
      pvw_generator.setModuleType(module_type)
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.Model',
                         'Wrong module type entered for OpenStudio::Generator::PVWatts. Review Input.')
      return false
    end

    if ['FixedOpenRack', 'FixedRoofMounted', 'OneAxis', 'OneAxisBacktracking', 'TwoAxis'].include? array_type
      pvw_generator.setArrayType(array_type)
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.Model',
                         'Wrong array type entered for OpenStudio::Generator::PVWatts. Review Input.')
      return false
    end
    pvw_generator.setSystemLosses(system_losses)

    if tilt_angle.nil? && azimuth_angle.nil?
      # check if site is poulated
      latitude_defaulted = model.getSite.isLatitudeDefaulted
      if latitude_defaulted
        OpenStudio.logFree(OpenStudio::Debug, 'openstudio.standards.Model',
                           'No Site location found: Generator:PVWatts will be created with tilt of 25 degree tilt and 180 degree azimuth.')
        tilt = 25.0
        azimuth = 180.0
      else
        latitude = model.getSite.latitude
        # calcaulate optimal fixed tilt
        tilt, azimuth = model_pv_optimal_fixed_position(latitude)
      end
    end

    pvw_generator.setAzimuthAngle(azimuth)
    pvw_generator.setTiltAngle(tilt)

    pvw_generator
  end

  # creates an ElectricLoadCenter:Inverter:PVWatts
  def model_add_pvwatts_inverter(model,
                                 name: 'Default PV System Inverter',
                                 dc_to_ac_size_ratio: 1.10,
                                 inverter_efficiency: 0.96)
    pvw_inverter = OpenStudio::Model::ElectricLoadCenterInverterPVWatts.new(model)
    pvw_inverter.setName(name)
    pvw_inverter.setDCToACSizeRatio(dc_to_ac_size_ratio)
    pvw_inverter.setInverterEfficiency(inverter_efficiency)

    pvw_inverter
  end

  # load data respirces
  def load_standards_data()
    @standards_data = {}
    battery_data = JSON.parse(File.read(File.expand_path(File.dirname(__FILE__) + "/resources/deer_t24_2022.battery_storage_system.json")))
    @standards_data.merge!(battery_data)
    return true
  end

  def model_find_object(hash_of_objects, search_criteria)
    matching_objects = []
    hash_of_objects.each do |object|
      meets_all_search_criteria = true
      search_criteria.each do |key, value|
        # Dont check non-existent search criteria
        next unless object.key?(key)

        # Stop as soon as one of the search criteria is not met
        # 'Any' is a special key that matches anything
        unless object[key] == value || object[key] == 'Any'
          meets_all_search_criteria = false
          break
        end
      end

      # Skip objects that don't meet all search criteria
      next unless meets_all_search_criteria

      # If made it here, object matches all search criteria
      matching_objects << object
    end

    if matching_objects.size.zero?
      desired_object = nil
      OpenStudio.logFree(OpenStudio::Debug, 'openstudio.standards.Model', "Find objects search criteria returned no results. Search criteria: #{search_criteria}. Called from #{caller(0)[1]}")
    elsif matching_objects.size == 1
      desired_object = matching_objects[0]
    else
      desired_object = matching_objects[0]
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.Model', "Find object search criteria returned #{matching_objects.size} results, the first one will be returned. Called from #{caller(0)[1]} \n Search criteria: \n #{search_criteria}. All results: \n #{matching_objects.join("\n")}")
    end
    return desired_object
  end

  # this method returns battery capacity data from Title 24 2022 Table 140.10-B
  # @return [Hash] hash of battery capacity factor data
  def model_get_battery_capacity(building_type)
    # populate search hash
    search_criteria = {
      'building_type' => building_type,
    }
    # search battery storage table for energy capacity
    battery_capacity = model_find_object(@standards_data['battery_storage_system'], search_criteria)
    return battery_capacity
  end

  # creates ElectricLoadCenter:Storage:Simple, modeling a simple battery
  #
  # @param model [OpenStudio::Model::Model] OpenStudio model object
  # @param name [String] the name of the coil, or nil in which case it will be defaulted
  # @param schedule [String] name of the availability schedule, or [<OpenStudio::Model::Schedule>] Schedule object, or nil in which case default to always on
  # @param rated_inlet_water_temperature [Double] rated inlet water temperature in degrees Celsius, default is hot water loop design exit temperature
  # @return [OpenStudio::Model::ElectricLoadCenterStorageSimple] the battery
  def model_add_electric_storage_simple(model,
                                        name: 'Default Battery Storage',
                                        schedule: nil,
                                        discharge_eff: 0.9,
                                        charge_eff: 0.9,
                                        max_storage_capacity_kwh: nil,
                                        max_charge_power_kw: nil,
                                        max_discharge_power_kw: nil)

    battery = OpenStudio::Model::ElectricLoadCenterStorageSimple.new(model)
    battery.setName(name)

    # set battery availability schedule
    if schedule.nil?
      # default always on
      battery_schedule = model.alwaysOnDiscreteSchedule
    elsif schedule.class == String
      if schedule == 'alwaysOffDiscreteSchedule'
        battery_schedule = model.alwaysOffDiscreteSchedule
      else
        battery_schedule = model_add_schedule(model, schedule)
        if battery_schedule.nil?
          battery_schedule = model.alwaysOnDiscreteSchedule
        end
      end
    elsif !schedule.to_Schedule.empty?
      battery_schedule = schedule
    else
      battery_schedule = model.alwaysOnDiscreteSchedule
    end

    battery.setAvailabilitySchedule(battery_schedule)
    battery.setNominalDischargingEnergeticEfficiency(discharge_eff) unless discharge_eff.nil?
    battery.setNominalEnergeticEfficiencyforCharging(charge_eff) unless charge_eff.nil?
    battery.setMaximumPowerforDischarging(max_discharge_power_kw * 1000) unless max_discharge_power_kw.nil?
    battery.setMaximumPowerforCharging(max_charge_power_kw * 1000) unless max_charge_power_kw.nil?
    battery.setMaximumStorageCapacity(OpenStudio.convert(max_storage_capacity_kwh, 'kWh', 'J').get) unless max_storage_capacity_kwh.nil?

    return battery
  end

  # creates ElectricLoadCenter:Storage:Converter, modeling battery storage converter
  def model_add_electric_storage_converter(model,
                                           name: 'Storage Converter',
                                           simple_fixed_eff: 1.0)

    storage_converter = OpenStudio::Model::ElectricLoadCenterStorageConverter.new(model)
    storage_converter.setName(name)
    storage_converter.setSimpleFixedEfficiency(simple_fixed_eff)

    return storage_converter
  end

  # define the arguments that the user will input
  def arguments(_model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # the name of the space to add to the model
    pv_area_fraction = OpenStudio::Measure::OSArgument.makeDoubleArgument('pv_area_fraction', true)
    pv_area_fraction.setDisplayName('Fraction of roof area for PV')
    pv_area_fraction.setDescription('The fraction of roof area for PV installation.')
    pv_area_fraction.setDefaultValue(0.4)
    args << pv_area_fraction

    # the name of the space to add to the model
    incl_batt_storage = OpenStudio::Measure::OSArgument.makeBoolArgument('incl_batt_storage', true)
    incl_batt_storage.setDisplayName('Include Battery Storage?')
    incl_batt_storage.setDescription('Adds battery storage system per CEC guidlines.')
    incl_batt_storage.setDefaultValue(false)
    args << incl_batt_storage

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments) # Do **NOT** remove this line

    # use the built-in error checking
    return false unless runner.validateUserArguments(arguments(model), user_arguments)

    # assign the user inputs to variables
    pv_area_fraction = runner.getDoubleArgumentValue('pv_area_fraction', user_arguments)
    incl_batt_storage = runner.getBoolArgumentValue('incl_batt_storage', user_arguments)

    # build standard to use OS standards methods
    template = 'ComStock 90.1-2019'
    Standard.build(template)

    # get exterior roof area
    ext_roof_area_m2 = model.getBuilding.exteriorSurfaceArea - model.getBuilding.exteriorWallArea
    ext_roof_area_ft2 = OpenStudio.convert(ext_roof_area_m2, 'm^2', 'ft^2').get

    # calculate area of rooftop PV
    pv_area = ext_roof_area_m2 * pv_area_fraction
    pv_area_ft2 = OpenStudio.convert(pv_area, 'm^2', 'ft^2').get

    # report initial condition of model
    runner.registerInitialCondition("The building started with #{ext_roof_area_ft2.round(0)} ft^2 of roof area. The user specified #{(pv_area_fraction * 100).round(0)}% of the roof area to be covered with PV panels, which totals #{pv_area_ft2.round(0)} ft^2 of PV to be added.")

    # Get total system capacity
    panel_efficiency = 0.21 # associated with premium PV Watts panels
    total_system_capacity_kw = panel_efficiency * 1 * pv_area

    # create pv watts generator
    pv_generator = model_add_pvwatts_system(model,
                                            name: 'PV System',
                                            module_type: 'Premium',
                                            array_type: 'FixedRoofMounted',
                                            system_capacity_kw: total_system_capacity_kw,
                                            system_losses: 0.14,
                                            azimuth_angle: nil,
                                            tilt_angle: nil)

    # add pv watts inverter
    pv_inverter = model_add_pvwatts_inverter(model,
                                             name: 'Default PV System Inverter',
                                             dc_to_ac_size_ratio: 1.10,
                                             inverter_efficiency: 0.96)

    # add electric load center distribution
    electric_load_center_distribution = OpenStudio::Model::ElectricLoadCenterDistribution.new(model)
    electric_load_center_distribution.setName("PV Battery Load Center")
    electric_load_center_distribution.setInverter(pv_inverter)
    electric_load_center_distribution.setGeneratorOperationSchemeType('TrackElectrical')
    electric_load_center_distribution.setElectricalBussType('DirectCurrentWithInverter')
    electric_load_center_distribution.addGenerator(pv_generator)

    # get specs for output
    pv_system_capacity = pv_generator.dcSystemCapacity
    pv_module_type = pv_generator.moduleType
    pv_array_type = pv_generator.arrayType
    pv_system_losses = pv_generator.systemLosses
    pv_title_angle = pv_generator.tiltAngle
    pv_azimuth_angle = pv_generator.azimuthAngle

    # add battery storage per user input
    if incl_batt_storage

      # load battery data
      load_standards_data()

      # get building type to assign battery design parameters
      if model.getBuilding.standardsBuildingType.is_initialized
        building_type = model.getBuilding.standardsBuildingType.get
      else
        runner.registerError("Building type not found.")
        return true
      end

      pv_size_kw = pv_system_capacity / 1000
      battery_data =  model_get_battery_capacity(building_type)
      if battery_data.nil?
        runner.registerError("Battery storage parameters not found for building type '#{building_type}'. Please ensure this building type exists in the battery storage JSON.")
        return false
      end
      b_factor = battery_data["battery_storage_factor_b_energy_capacity"]

      # D factor is Rated single charge-discharge cycle AC to AC (round-trip) efficiency of the battery storage system
      # default value is 0.95 * 0.95 from CBECC Rule Batt:RoundTripEff
      # d_factor = 0.95 * 0.95
      # set by minimum prescriptive requirement of JA12.2.2.1(b)
      d_factor = 0.80
      battery_kwh = (pv_size_kw * b_factor) / (d_factor ** 0.5)

      # calculate battery power capacity per Equation 140.10-C
      c_factor = battery_data["battery_storage_factor_c_power_capacity"]
      battery_kw = (pv_size_kw * c_factor)
      OpenStudio::logFree(OpenStudio::Info, 'openstudio.standards.Model', "Creating a Battery Storage system with capacity of #{battery_kwh.round(2)} kWh and charge/discharge power of #{battery_kw.round(2)} kW.")
      battery = model_add_electric_storage_simple(model, max_storage_capacity_kwh: battery_kwh, max_charge_power_kw: battery_kw, max_discharge_power_kw: battery_kw)
      converter = model_add_electric_storage_converter(model)

      # PV required, no Storage required
      electric_load_center_distribution.setElectricalBussType('DirectCurrentWithInverterDCStorage')
      electric_load_center_distribution.setElectricalStorage(battery)
      electric_load_center_distribution.setStorageConverter(converter)
      electric_load_center_distribution.setMaximumStorageStateofChargeFraction(1)
      electric_load_center_distribution.setStorageOperationScheme('TrackFacilityElectricDemandStoreExcessOnSite')
      # get final conditions
      elcss = model.getElectricLoadCenterStorageSimples
      batt_size_kwh = elcss.map { |b| b.maximumStorageCapacity }.sum / 3.6e6 # convert to kWh from joules
      total_discharge_power_kw  = elcss.map { |b| b.maximumPowerforDischarging }.sum / 1000 # convert to kw from w
      total_charge_power_kw  = elcss.map { |b| b.maximumPowerforCharging }.sum / 1000 # convert to kw from W
    end

    if battery.nil?
      # report final condition of model with battery
      runner.registerFinalCondition("The building finished with " \
        "#{(pv_system_capacity / 1000).round(0)} kW of PV covering " \
        "#{pv_area_ft2.round(0)} ft² of roof area. The module type is " \
        "#{pv_module_type}, the array type is " \
        "#{pv_array_type}, the system losses are " \
        "#{pv_system_losses}, the tilt angle is " \
        "#{pv_title_angle.round(0)}°, and the azimuth angle is " \
        "#{pv_azimuth_angle.round(0)}°. The inverter has a DC to AC size ratio of " \
        "#{pv_inverter.dcToACSizeRatio} and an inverter efficiency of " \
        "#{(pv_inverter.inverterEfficiency * 100).round(0)}%.")
    else
      # report final condition of model with no battery
      runner.registerFinalCondition("The building finished with " \
        "#{(pv_system_capacity / 1000).round(0)} kW of PV covering " \
        "#{pv_area_ft2.round(0)} ft^2 of roof area. The module type is " \
        "#{pv_module_type}, the array type is " \
        "#{pv_array_type}, the system losses are " \
        "#{pv_system_losses}, the tilt angle is " \
        "#{pv_title_angle.round(0)}°, and the azimuth angle is " \
        "#{pv_azimuth_angle.round(0)}°. The inverter has a DC to AC size ratio of " \
        "#{pv_inverter.dcToACSizeRatio} and an inverter efficiency of " \
        "#{(pv_inverter.inverterEfficiency * 100).round(0)}%. For storage, the model has a total battery capacity of " \
        "#{batt_size_kwh.round(1)} kWh, a maximum discharging power of " \
        "#{total_discharge_power_kw.round(0)} kW, and a maximum charging power of " \
        "#{total_charge_power_kw.round(0)} kW.")
    end

    true
  end
end

# register the measure to be used by the application
UpgradeAddPvwatts.new.registerWithApplication
