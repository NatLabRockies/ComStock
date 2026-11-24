# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

require 'openstudio'

# start the measure
class SimulationOutputReport < OpenStudio::Measure::ReportingMeasure
  # define the name that a user will see, this method may be deprecated as
  # the display name in PAT comes from the name field in measure.xml
  def name
    'Simulation Output Report'
  end

  def description
    'Reports simulation outputs of interest.'
  end

  # define the arguments that the user will input
  def arguments(model = nil)
    args = OpenStudio::Measure::OSArgumentVector.new
    # this measure does not require any user arguments, return an empty list
    return args
  end

  def outputs
    buildstock_outputs = ['total_site_energy_mbtu',
                          'total_site_electricity_kwh',
                          'total_site_natural_gas_therm',
                          'total_site_fuel_oil_mbtu',
                          'total_site_propane_mbtu',
                          'total_site_district_cooling_therm',
                          'total_site_district_heating_therm',
                          'total_site_other_fuel_mbtu',
                          'net_site_energy_mbtu', # Incorporates PV
                          'net_site_electricity_kwh', # Incorporates PV
                          'purchased_site_electricity_kwh', # Incorporates PV, but no negatives
                          'electricity_heating_kwh',
                          'electricity_cooling_kwh',
                          'electricity_interior_lighting_kwh',
                          'electricity_exterior_lighting_kwh',
                          'electricity_interior_equipment_kwh',
                          'electricity_fans_kwh',
                          'electricity_pumps_kwh',
                          'electricity_heat_rejection_kwh',
                          'electricity_humidification_kwh',
                          'electricity_heat_recovery_kwh',
                          'electricity_water_systems_kwh',
                          'electricity_refrigeration_kwh',
                          'electricity_generators_kwh',
                          'electricity_pv_kwh',
                          'natural_gas_heating_therm',
                          'natural_gas_cooling_therm',
                          'natural_gas_interior_equipment_therm',
                          'natural_gas_water_systems_therm',
                          'natural_gas_generators_therm',
                          'fuel_oil_heating_mbtu',
                          'fuel_oil_interior_equipment_mbtu',
                          'fuel_oil_water_systems_mbtu',
                          'fuel_oil_generators_mbtu',
                          'propane_heating_mbtu',
                          'propane_interior_equipment_mbtu',
                          'propane_water_systems_mbtu',
                          'propane_generators_mbtu',
                          'district_cooling_cooling_therm',
                          'district_heating_heating_therm',
                          'district_heating_water_systems_therm',
                          'other_fuel_heating_mbtu',
                          'other_fuel_interior_equipment_mbtu',
                          'other_fuel_water_systems_mbtu',
                          'other_fuel_generators_mbtu',
                          'hours_heating_setpoint_not_met',
                          'hours_cooling_setpoint_not_met',
                          'hvac_cooling_capacity_w',
                          'hvac_heating_capacity_w',
                          'upgrade_name',
                          'upgrade_cost_usd',
                          'weight']
    result = OpenStudio::Measure::OSOutputVector.new
    buildstock_outputs.each do |output|
      result << OpenStudio::Measure::OSOutput.makeDoubleOutput(output)
    end
    result
  end

  def get_value_from_runner_past_results(runner, key_lookup, measure_name, error_if_missing = true)
    key_lookup = OpenStudio.toUnderscoreCase(key_lookup)
    success_value = OpenStudio::StepResult.new('Success')
    runner.workflow.workflowSteps.each do |step|
      next if !step.result.is_initialized

      step_result = step.result.get
      next if !step_result.measureName.is_initialized
      next if step_result.measureName.get != measure_name
      next if step_result.value != success_value

      step_result.stepValues.each do |step_value|
        next if step_value.name != key_lookup

        return step_value.valueAsString
      end
    end
    if error_if_missing
      register_error("Could not find past value for '#{key_lookup}'.", runner)
    end
    return nil
  end

  def get_multi_measure_upgrade_applicability_from_runner_past_results(runner)
    applics = []
    success_value = OpenStudio::StepResult.new('Success')
    runner.workflow.workflowSteps.each do |step|
      next if !step.result.is_initialized

      step_result = step.result.get
      next if !step_result.measureName.is_initialized
      next if step_result.measureName.get != 'apply_upgrade'
      next if step_result.value != success_value

      step_result.stepValues.each do |step_value|
        next unless step_value.name.include?('_applicable')

        applics << { 'name' => step_value.name, 'applicable' => step_value.valueAsBoolean }
      end
    end

    return applics
  end

  # define what happens when the measure is run
  def run(runner, user_arguments)
    super(runner, user_arguments)

    # use the built-in error checking
    return false unless runner.validateUserArguments(arguments, user_arguments)

    # get the last model and sql file
    model = runner.lastOpenStudioModel
    if model.empty?
      runner.registerError('Cannot find last model.')
      return false
    end
    model = model.get

    sql_file = runner.lastEnergyPlusSqlFile
    if sql_file.empty?
      runner.registerError('Cannot find last sql file.')
      return false
    end
    sql_file = sql_file.get
    model.setSqlFile(sql_file)

    # set units
    total_site_units = 'MBtu'
    elec_site_units = 'kWh'
    gas_site_units = 'therm'
    district_cooling_site_units = 'therm'
    district_heating_site_units = 'therm'
    other_fuel_site_units = 'MBtu'

    # Get PV electricity produced
    # pv_query = "SELECT -1*Value FROM TabularDataWithStrings WHERE ReportName='AnnualBuildingUtilityPerformanceSummary' AND ReportForString='Entire Facility' AND TableName='Electric Loads Satisfied' AND RowName='Total On-Site Electric Sources' AND ColumnName='Electricity' AND Units='GJ'"
    pv_query = "SELECT -1*Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Electricity' AND RowName='ElectricityProduced:Facility' AND ColumnName='Electricity Annual Value' AND Units='GJ'"
    pv_val = sql_file.execAndReturnFirstDouble(pv_query)
    # purchased_electricity_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='AnnualBuildingUtilityPerformanceSummary' AND ReportForString='Entire Facility' AND TableName='Electric Loads Satisfied' AND RowName='Electricity Coming From Utility' AND ColumnName='Electricity' AND Units='GJ'"
    purchased_electricity_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnergyMeters' AND ReportForString='Entire Facility' AND TableName='Annual and Peak Values - Electricity' AND RowName='ElectricityPurchased:Facility' AND ColumnName='Electricity Annual Value' AND Units='GJ'"
    purchased_electricity = sql_file.execAndReturnFirstDouble(purchased_electricity_query)

    # TOTAL
    report_sim_output(runner, 'total_site_energy_mbtu', [sql_file.totalSiteEnergy], 'GJ', total_site_units)
    report_sim_output(runner, 'net_site_energy_mbtu', [sql_file.totalSiteEnergy, pv_val], 'GJ', total_site_units)

    # ELECTRICITY
    report_sim_output(runner, 'total_site_electricity_kwh', [sql_file.electricityTotalEndUses], 'GJ', elec_site_units)
    report_sim_output(runner, 'net_site_electricity_kwh', [sql_file.electricityTotalEndUses, pv_val], 'GJ', elec_site_units)
    report_sim_output(runner, 'purchased_site_electricity_kwh', [purchased_electricity], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_heating_kwh', [sql_file.electricityHeating], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_cooling_kwh', [sql_file.electricityCooling], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_interior_lighting_kwh', [sql_file.electricityInteriorLighting], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_exterior_lighting_kwh', [sql_file.electricityExteriorLighting], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_interior_equipment_kwh', [sql_file.electricityInteriorEquipment], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_fans_kwh', [sql_file.electricityFans], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_pumps_kwh', [sql_file.electricityPumps], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_heat_rejection_kwh', [sql_file.electricityHeatRejection], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_humidification_kwh', [sql_file.electricityHumidification], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_heat_recovery_kwh', [sql_file.electricityHeatRecovery], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_water_systems_kwh', [sql_file.electricityWaterSystems], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_refrigeration_kwh', [sql_file.electricityRefrigeration], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_generators_kwh', [sql_file.electricityGenerators], 'GJ', elec_site_units)
    report_sim_output(runner, 'electricity_pv_kwh', [pv_val], 'GJ', elec_site_units)

    # ELECTRICITY PEAK DEMAND
    annual_peak_electric_demand_k_query = "SELECT Value FROM tabulardatawithstrings WHERE ReportName='DemandEndUseComponentsSummary' and ReportForString='Entire Facility' and TableName='End Uses' and RowName= 'Total End Uses' and ColumnName='Electricity' and Units='W'"
    annual_peak_electric_demand_w = sql_file.execAndReturnFirstDouble(annual_peak_electric_demand_k_query)
    report_sim_output(runner, 'annual_peak_electric_demand_kw', [annual_peak_electric_demand_w], 'W', 'kW')

    # NATURAL GAS
    report_sim_output(runner, 'total_site_natural_gas_therm', [sql_file.naturalGasTotalEndUses], 'GJ', gas_site_units)
    report_sim_output(runner, 'natural_gas_heating_therm', [sql_file.naturalGasHeating], 'GJ', gas_site_units)
    report_sim_output(runner, 'natural_gas_cooling_therm', [sql_file.naturalGasCooling], 'GJ', gas_site_units)
    report_sim_output(runner, 'natural_gas_interior_equipment_therm', [sql_file.naturalGasInteriorEquipment], 'GJ', gas_site_units)
    report_sim_output(runner, 'natural_gas_water_systems_therm', [sql_file.naturalGasWaterSystems], 'GJ', gas_site_units)
    report_sim_output(runner, 'natural_gas_generators_therm', [sql_file.naturalGasGenerators], 'GJ', gas_site_units)

    # FUEL OIL NO2
    report_sim_output(runner, 'total_site_fuel_oil_mbtu', [sql_file.fuelOilNo2TotalEndUses], 'GJ', other_fuel_site_units)
    report_sim_output(runner, 'fuel_oil_heating_mbtu', [sql_file.fuelOilNo2Heating], 'GJ', other_fuel_site_units)
    report_sim_output(runner, 'fuel_oil_interior_equipment_mbtu', [sql_file.fuelOilNo2InteriorEquipment], 'GJ', other_fuel_site_units)
    report_sim_output(runner, 'fuel_oil_water_systems_mbtu', [sql_file.fuelOilNo2WaterSystems], 'GJ', other_fuel_site_units)
    report_sim_output(runner, 'fuel_oil_generators_mbtu', [sql_file.fuelOilNo2Generators], 'GJ', other_fuel_site_units)

    # PROPANE
    report_sim_output(runner, 'total_site_propane_mbtu', [sql_file.propaneTotalEndUses], 'GJ', other_fuel_site_units)
    report_sim_output(runner, 'propane_heating_mbtu', [sql_file.propaneHeating], 'GJ', other_fuel_site_units)
    report_sim_output(runner, 'propane_interior_equipment_mbtu', [sql_file.propaneInteriorEquipment], 'GJ', other_fuel_site_units)
    report_sim_output(runner, 'propane_water_systems_mbtu', [sql_file.propaneWaterSystems], 'GJ', other_fuel_site_units)
    report_sim_output(runner, 'propane_generators_mbtu', [sql_file.propaneGenerators], 'GJ', other_fuel_site_units)

    # DISTRICT COOLING
    report_sim_output(runner, 'total_site_district_cooling_therm', [sql_file.districtCoolingTotalEndUses], 'GJ', district_cooling_site_units)
    report_sim_output(runner, 'district_cooling_cooling_therm', [sql_file.districtCoolingCooling], 'GJ', district_cooling_site_units)

    # DISTRICT HEATING
    report_sim_output(runner, 'total_site_district_heating_therm', [sql_file.districtHeatingTotalEndUses], 'GJ', district_heating_site_units)
    report_sim_output(runner, 'district_heating_heating_therm', [sql_file.districtHeatingHeating], 'GJ', district_heating_site_units)
    report_sim_output(runner, 'district_heating_water_systems_therm', [sql_file.districtHeatingWaterSystems], 'GJ', district_heating_site_units)

    # OTHER FUELS (Gasoline, Diesel, Coal, Fuel Oil No1, Other Fuel 1, Other Fuel 2)
    report_sim_output(runner, 'total_site_other_fuel_mbtu', [sql_file.gasolineTotalEndUses, sql_file.dieselTotalEndUses, sql_file.coalTotalEndUses, sql_file.fuelOilNo1TotalEndUses, sql_file.otherFuel1TotalEndUses, sql_file.otherFuel2TotalEndUses], 'GJ', other_fuel_site_units)
    report_sim_output(runner, 'other_fuel_heating_mbtu', [sql_file.gasolineHeating, sql_file.dieselHeating, sql_file.coalHeating, sql_file.fuelOilNo1Heating, sql_file.otherFuel1Heating, sql_file.otherFuel2Heating], 'GJ', other_fuel_site_units)
    report_sim_output(runner, 'other_fuel_interior_equipment_mbtu', [sql_file.gasolineInteriorEquipment, sql_file.dieselInteriorEquipment, sql_file.coalInteriorEquipment, sql_file.fuelOilNo1InteriorEquipment, sql_file.otherFuel1InteriorEquipment, sql_file.otherFuel2InteriorEquipment], 'GJ', other_fuel_site_units)
    report_sim_output(runner, 'other_fuel_water_systems_mbtu', [sql_file.gasolineWaterSystems, sql_file.dieselWaterSystems, sql_file.coalWaterSystems, sql_file.fuelOilNo1WaterSystems, sql_file.otherFuel1WaterSystems, sql_file.otherFuel2WaterSystems], 'GJ', other_fuel_site_units)
    report_sim_output(runner, 'other_fuel_generators_mbtu', [sql_file.gasolineGenerators, sql_file.dieselGenerators, sql_file.coalGenerators, sql_file.fuelOilNo1Generators, sql_file.otherFuel1Generators, sql_file.otherFuel2Generators], 'GJ', other_fuel_site_units)

    # LOADS NOT MET
    report_sim_output(runner, 'hours_heating_setpoint_not_met', [sql_file.hoursHeatingSetpointNotMet], nil, nil)
    report_sim_output(runner, 'hours_cooling_setpoint_not_met', [sql_file.hoursCoolingSetpointNotMet], nil, nil)

    # HVAC CAPACITIES
    cooling_capacity_lkup = {
      'AirLoopHVAC:UnitarySystem': 'Design Size Nominal Cooling Capacity',
      'Coil:Cooling:DX:SingleSpeed': 'Design Size Gross Rated Total Cooling Capacity',
      'Coil:Cooling:DX:TwoSpeed': 'Design Size High Speed Gross Rated Total Cooling Capacity',
      'Coil:Cooling:Water': 'Design Size Design Coil Load'
    }
    # 'Chiller:Electric:EIR': 'Design Size Reference Capacity' <- this would double count VAVs but include fan coil
    # systems which are currently missing.

    cooling_capacity_w = 0.0
    cooling_capacity_lkup.each do |cooling_coil_type, capacity_field|
      cooling_capacity_query = "SELECT SUM(Value) FROM ComponentSizes WHERE CompType LIKE '#{cooling_coil_type}' AND Description LIKE '#{capacity_field}'"
      cooling_component_cap_w = sql_file.execAndReturnFirstDouble(cooling_capacity_query)
      cooling_capacity_w += cooling_component_cap_w.get if cooling_component_cap_w.is_initialized
    end
    runner.registerValue('hvac_cooling_capacity_w', cooling_capacity_w)
    runner.registerInfo("Registering #{cooling_capacity_w.round(2)} for hvac_cooling_capacity_w.")

    heating_capacity_lkup = {
      'Coil:Heating:DX:SingleSpeed': 'Design Size Gross Rated Heating Capacity',
      'AirLoopHVAC:UnitarySystem': 'Design Size Nominal Heating Capacity',
      'Coil:Heating:Electric': 'Design Size Nominal Capacity',
      'Coil:Heating:Fuel': 'Design Size Nominal Capacity',
      'Coil:Heating:Water': 'Design Size Rated Capacity',
      'ZONEHVAC:BASEBOARD:CONVECTIVE:ELECTRIC': 'Design Size Heating Design Capacity'
    }
    # 'Boiler:HotWater': 'Design Size Nominal Capacity' <- this would double count boiler how water systems with boxes
    #  but would include baseboard gas boiler radiators
    heating_capacity_w = 0.0
    heating_capacity_lkup.each do |heating_coil_type, capacity_field|
      heating_capacity_query = "SELECT SUM(Value) FROM ComponentSizes WHERE CompType LIKE '#{heating_coil_type}' AND Description LIKE '#{capacity_field}'"
      heating_component_cap_w = sql_file.execAndReturnFirstDouble(heating_capacity_query)
      heating_capacity_w += heating_component_cap_w.get if heating_component_cap_w.is_initialized
    end
    runner.registerValue('hvac_heating_capacity_w', heating_capacity_w)
    runner.registerInfo("Registering #{heating_capacity_w.round(2)} for hvac_heating_capacity_w.")

    # WEIGHT

    weight = get_value_from_runner_past_results(runner, 'weight', 'build_existing_model', false)
    unless weight.nil?
      runner.registerValue('weight', weight.to_f)
      runner.registerInfo("Registering #{weight} for weight.")
    end

    # UPGRADE NAME
    upgrade_name = get_value_from_runner_past_results(runner, 'upgrade_name', 'apply_upgrade', false)
    upgrade_name = '' if upgrade_name.nil?
    runner.registerValue('upgrade_name', upgrade_name)
    runner.registerInfo("Registering #{upgrade_name} for upgrade_name.")

    # MULTI-MEASURE UPGRADES
    measures_in_upgrade = get_multi_measure_upgrade_applicability_from_runner_past_results(runner)
    measures_in_upgrade.each do |measure_in_upgrade|
      runner.registerValue("apply_upgrade_#{measure_in_upgrade['name']}", measure_in_upgrade['applicable'])
    end

    # UPGRADE COSTS
    upgrade_cost_name = 'upgrade_cost_usd'

    # Get upgrade cost value/multiplier pairs from the upgrade measure
    cost_pairs = []
    for option_num in 1..200 # Sync with ApplyUpgrade measure
      for cost_num in 1..2 # Sync with ApplyUpgrade measure
        cost_value_result = get_value_from_runner_past_results(runner, "option_#{option_num}_cost_#{cost_num}_value_to_apply", 'apply_upgrade', false)
        next if cost_value_result.nil?

        cost_mult_type_result = get_value_from_runner_past_results(runner, "option_#{option_num}_cost_#{cost_num}_multiplier_to_apply", 'apply_upgrade', false)

        next if cost_mult_type_result.nil?

        cost_pairs << [cost_value_result.to_f, cost_mult_type_result]
      end
    end

    if cost_pairs.empty?
      runner.registerValue(upgrade_cost_name, '')
      runner.registerInfo("Registering (blank) for #{upgrade_cost_name}.")
      return true
    end

    # Obtain cost multiplier values from simulation results and calculate upgrade costs
    upgrade_cost = 0.0
    cost_pairs.each do |cost_value, cost_mult_type|
      cost_mult = 0.0

      if cost_mult_type == 'Fixed (1)'
        cost_mult = 1.0

      elsif cost_mult_type == 'Conditioned Floor Area (ft^2)'
        sql_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='AnnualBuildingUtilityPerformanceSummary' AND ReportForString='Entire Facility' AND TableName='Building Area' AND RowName='Net Conditioned Building Area' AND ColumnName='Area' AND Units='m2'"
        sql_result = sql_file.execAndReturnFirstDouble(sql_query)
        cost_mult = OpenStudio.convert(sql_result.get, 'm^2', 'ft^2').get

      elsif cost_mult_type == 'Conditioned Foundation Slab Area (ft^2)'
        # Surface area between conditioned space and ground
        floor_area = 0
        model.getSurfaces.each do |surface|
          next if surface.surfaceType.downcase != 'floor'
          next if surface.outsideBoundaryCondition.downcase != 'ground'
          next unless surface.adjacentSurface.is_initialized
          next unless surface.adjacentSurface.get.space.is_initialized

          adjacent_space = surface.adjacentSurface.get.space.get
          next unless Geometry.space_is_finished(adjacent_space)

          floor_area += surface.grossArea
        end
        cost_mult = OpenStudio.convert(floor_area, 'm^2', 'ft^2').get

      elsif cost_mult_type == 'Lighting Floor Area (ft^2)'
        # Get zone names where Lighting > 0
        sql_query = "SELECT RowName FROM TabularDataWithStrings WHERE ReportName='InputVerificationandResultsSummary' AND ReportForString='Entire Facility' AND TableName='Zone Summary' AND ColumnName='Lighting' AND Units='W/m2' AND CAST(Value AS DOUBLE)>0"
        sql_results = sql_file.execAndReturnVectorOfString(sql_query)
        if sql_results.is_initialized
          sql_results.get.each do |lighting_zone_name|
            # Get floor area for this zone
            sql_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='InputVerificationandResultsSummary' AND ReportForString='Entire Facility' AND TableName='Zone Summary' AND RowName='#{lighting_zone_name}' AND ColumnName='Area' AND Units='m2'"
            sql_result = sql_file.execAndReturnFirstDouble(sql_query)
            cost_mult += OpenStudio.convert(sql_result.get, 'm^2', 'ft^2').get
          end
        end

      elsif cost_mult_type == 'Above-Grade Conditioned Wall Area (ft^2)'
        sql_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='InputVerificationandResultsSummary' AND ReportForString='Entire Facility' AND TableName='Zone Summary' AND RowName='Conditioned Total' AND ColumnName='Above Ground Gross Wall Area' AND Units='m2'"
        sql_result = sql_file.execAndReturnFirstDouble(sql_query)
        cost_mult = OpenStudio.convert(sql_result.get, 'm^2', 'ft^2').get

      elsif cost_mult_type == 'Above-Grade Total Wall Area (ft^2)'
        sql_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='InputVerificationandResultsSummary' AND ReportForString='Entire Facility' AND TableName='Zone Summary' AND RowName='Total' AND ColumnName='Above Ground Gross Wall Area' AND Units='m2'"
        sql_result = sql_file.execAndReturnFirstDouble(sql_query)
        cost_mult = OpenStudio.convert(sql_result.get, 'm^2', 'ft^2').get

      elsif cost_mult_type == 'Below-Grade Conditioned Wall Area (ft^2)'
        sql_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='InputVerificationandResultsSummary' AND ReportForString='Entire Facility' AND TableName='Zone Summary' AND RowName='Conditioned Total' AND ColumnName='Underground Gross Wall Area' AND Units='m2'"
        sql_result = sql_file.execAndReturnFirstDouble(sql_query)
        cost_mult = OpenStudio.convert(sql_result.get, 'm^2', 'ft^2').get

      elsif cost_mult_type == 'Below-Grade Total Wall Area (ft^2)'
        sql_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='InputVerificationandResultsSummary' AND ReportForString='Entire Facility' AND TableName='Zone Summary' AND RowName='Total' AND ColumnName='Underground Gross Wall Area' AND Units='m2'"
        sql_result = sql_file.execAndReturnFirstDouble(sql_query)
        cost_mult = OpenStudio.convert(sql_result.get, 'm^2', 'ft^2').get

      elsif cost_mult_type == 'Window Area (ft^2)'
        sql_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='InputVerificationandResultsSummary' AND ReportForString='Entire Facility' AND TableName='Zone Summary' AND RowName='Total' AND ColumnName='Window Glass Area' AND Units='m2'"
        sql_result = sql_file.execAndReturnFirstDouble(sql_query)
        cost_mult = OpenStudio.convert(sql_result.get, 'm^2', 'ft^2').get

      elsif cost_mult_type == 'Roof Area (ft^2)'
        sql_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='InputVerificationandResultsSummary' AND ReportForString='Entire Facility' AND TableName='Skylight-Roof Ratio' AND RowName='Gross Roof Area' AND ColumnName='Total' AND Units='m2'"
        sql_result = sql_file.execAndReturnFirstDouble(sql_query)
        cost_mult = OpenStudio.convert(sql_result.get, 'm^2', 'ft^2').get

      elsif cost_mult_type == 'Door Area (ft^2)'
        sql_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EnvelopeSummary' AND ReportForString='Entire Facility' AND TableName='Exterior Door' AND ColumnName='Gross Area' AND Units='m2'"
        sql_results = sql_file.execAndReturnVectorOfDouble(sql_query)
        if sql_results.is_initialized
          sql_results.get.each do |sql_result_door|
            cost_mult += OpenStudio.convert(sql_result_door, 'm^2', 'ft^2').get
          end
        end

      elsif cost_mult_type == 'Water Heater Tank Size (gal)'
        sql_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName='EquipmentSummary' AND ReportForString='Entire Facility' AND TableName='Service Water Heating' AND ColumnName='Storage Volume' AND Units='m3'"
        sql_result = sql_file.execAndReturnFirstDouble(sql_query)
        cost_mult = OpenStudio.convert(sql_result.get, 'm^3', 'gal').get if sql_result.is_initialized

      elsif cost_mult_type == 'HVAC Cooling Capacity (kBtuh)'
        cost_mult = OpenStudio.convert(cooling_capacity_w.get, 'W', 'kBtu/h').get if cooling_capacity_w.is_initialized

      elsif cost_mult_type == 'HVAC Heating Capacity (kBtuh)'
        cost_mult = OpenStudio.convert(heating_capacity_w.get, 'W', 'kBtu/h').get if heating_capacity_w.is_initialized

      elsif cost_mult_type != ''
        runner.registerError("Unhandled cost multiplier: #{cost_mult_type}. Aborting...")
        return false

      end
      runner.registerInfo("Upgrade cost addition: $#{cost_value} x #{cost_mult} [#{cost_mult_type}].")
      upgrade_cost += cost_value * cost_mult
    end
    upgrade_cost_str = upgrade_cost.round(2).to_s
    runner.registerValue(upgrade_cost_name, upgrade_cost_str)
    runner.registerInfo("Registering #{upgrade_cost_str} for #{upgrade_cost_name}.")

    sql_file.close

    runner.registerFinalCondition('Report generated successfully.')

    true
  end
  # end the run method

  def report_sim_output(runner, name, vals, os_units, desired_units, percent_of_val = 1.0)
    total_val = 0.0
    vals.each do |val|
      next if val.empty?

      total_val += val.get * percent_of_val
    end
    val_in_units = if os_units.nil? || desired_units.nil? || os_units == desired_units
                     total_val
                   else
                     OpenStudio.convert(total_val, os_units, desired_units).get
                   end
    runner.registerValue(name, val_in_units)
    runner.registerInfo("Registering #{val_in_units.round(2)} for #{name}.")
  end
end

# this allows the measure to be use by the application
SimulationOutputReport.new.registerWithApplication
