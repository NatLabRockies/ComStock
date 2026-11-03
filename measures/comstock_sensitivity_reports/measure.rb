# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

require 'comstock-typical'
require 'erb'

# start the measure
class ComStockSensitivityReports < OpenStudio::Measure::ReportingMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'ComStock_Sensitivity_Reports'
  end

  # timestep for timeseries data processing
  def timeseries_timestep
    return 'Hourly'
  end

  # human readable description
  def description
    return 'In order to train the surrogate model for ComStock, we need to have more summary information about the
            building in the output csv.  Characteristics like whole-bldg avg. U-value for walls, roofs, windows, etc,
            whole-bldg LPD and EPD, avg. htg. eff/clg COP.  Mainly things that are not direct inputs to the model, but
            that are a byproduct of the other inputs.  Also, the focus should be on things that are common across
            building types, as opposed to very building-type-specific characteristics.'
  end

  # human readable description of modeling approach
  def modeler_description
    return "WARNING: This measure puts in output variables with reporting frequency 'RunPeriod'.
            Make sure 'Run Simulation for Sizing Periods' is set to 'false' in 'OS:SimulationControl'."
  end

  # define the arguments that the user will input
  def arguments(model = nil)
    args = OpenStudio::Measure::OSArgumentVector.new
    # this measure does not require any user arguments, return an empty list
    return args
  end

  # define the outputs that the measure will create
  def outputs
    outs = OpenStudio::Measure::OSOutputVector.new
    # this measure does not produce machine readable outputs with registerValue, return an empty list
    return outs
  end

  # helper method to access report variable data
  def sql_get_report_variable_data_double(runner, sql, object, variable_name)
    value = 0.0
    # See if object input is the actual object or just a string and handle appropriately
    if object.respond_to?('name')
      var_data_id_query = "SELECT ReportVariableDataDictionaryIndex FROM ReportVariableDataDictionary WHERE VariableName = '#{variable_name}' AND ReportingFrequency = 'Run Period' AND KeyValue = '#{object.name.get.to_s.upcase}'"
    else
      var_data_id_query = "SELECT ReportVariableDataDictionaryIndex FROM ReportVariableDataDictionary WHERE VariableName = '#{variable_name}' AND ReportingFrequency = 'Run Period' AND KeyValue = '#{object.upcase}'"
    end
    var_data_id = sql.execAndReturnFirstDouble(var_data_id_query)
    if var_data_id.is_initialized
      var_val_query = "SELECT VariableValue FROM ReportVariableData WHERE ReportVariableDataDictionaryIndex = '#{var_data_id.get}'"
      val = sql.execAndReturnFirstDouble(var_val_query)
      if val.is_initialized
        value = val.get
      elsif object.respond_to?('name')
        runner.registerWarning("'#{variable_name}' not available for #{object.iddObjectType} '#{object.name}'.")
      else
        runner.registerWarning("'#{variable_name}' not available for #{object}'.")
      end
    elsif object.respond_to?('name')
      runner.registerWarning("'#{variable_name}' not available for #{object.iddObjectType} '#{object.name}'.")
    else
      runner.registerWarning("'#{variable_name}' not available for #{object}'.")
    end
    return value
  end

  # return a vector of IdfObject's to request EnergyPlus objects needed by the run method
  # Warning: Do not change the name of this method to be snake_case. The method must be lowerCamelCase.
  def energyPlusOutputRequests(runner, user_arguments)
    super(runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments, user_arguments)
      return result
    end

    result = OpenStudio::IdfObjectVector.new
    result << OpenStudio::IdfObject.load('Output:Variable,*,Site Outdoor Air Drybulb Temperature,Hourly;').get

    # Get model
    model = runner.lastOpenStudioModel
    if model.empty?
      runner.registerError('Cannot find last model in energyPlusOutputRequests, cannot request outputs for HVAC equipment.')
      return result
    end
    model = model.get

    # Handle fuel output variables that changed in EnergyPlus version 9.4 (Openstudio version >= 3.1)
    elec = 'Electric'
    gas = 'Gas'
    fuel_oil = 'FuelOil#2'
    if model.version > OpenStudio::VersionString.new('3.0.1')
      elec = 'Electricity'
      gas = 'NaturalGas'
      fuel_oil = 'FuelOilNo2'
    end

    # request zone variables for the run period
    result << OpenStudio::IdfObject.load("Output:Variable,*,Zone Electric Equipment #{elec} Energy,RunPeriod;").get
    result << OpenStudio::IdfObject.load('Output:Variable,*,Zone People Occupant Count,RunPeriod;').get

    # request service water heating use
    result << OpenStudio::IdfObject.load('Output:Variable,*,Water Use Connections Hot Water Volume,RunPeriod;').get

    # request refrigeration defrost energy
    result << OpenStudio::IdfObject.load('Output:Variable,*,Refrigeration Case Defrost Electricity Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,Refrigeration Walk In Defrost Electricity Energy,RunPeriod;').get # J

    # request coil and fan energy use for HVAC equipment
    result << OpenStudio::IdfObject.load('Output:Variable,*,Cooling Tower Make Up Water Volume,RunPeriod;').get # m3
    result << OpenStudio::IdfObject.load('Output:Variable,*,Chiller COP,RunPeriod;').get
    result << OpenStudio::IdfObject.load('Output:Variable,*,Chiller Evaporator Cooling Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,Boiler Heating Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load("Output:Variable,*,Boiler #{elec} Energy,RunPeriod;").get # J
    result << OpenStudio::IdfObject.load("Output:Variable,*,Boiler #{gas} Energy,RunPeriod;").get # J
    result << OpenStudio::IdfObject.load("Output:Variable,*,Boiler #{fuel_oil} Energy,RunPeriod;").get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,Boiler Propane Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load("Output:Variable,*,Heat Pump #{elec} Energy,RunPeriod;").get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,Heat Pump Load Side Heat Transfer Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,Heat Pump Source Side Inlet Temperature,RunPeriod;').get # C
    result << OpenStudio::IdfObject.load('Output:Variable,*,Fluid Heat Exchanger Loop Supply Side Inlet Temperature,RunPeriod;').get # C
    result << OpenStudio::IdfObject.load('Output:Variable,*,Fluid Heat Exchanger Loop Supply Side Outlet Temperature,RunPeriod;').get # C
    result << OpenStudio::IdfObject.load('Output:Variable,*,Fluid Heat Exchanger Loop Demand Side Inlet Temperature,RunPeriod;').get # C
    result << OpenStudio::IdfObject.load('Output:Variable,*,Fluid Heat Exchanger Loop Demand Side Outlet Temperature,RunPeriod;').get # C
    result << OpenStudio::IdfObject.load('Output:Variable,*,Fluid Heat Exchanger Heat Transfer Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load("Output:Variable,*,Cooling Coil #{elec} Energy,RunPeriod;").get # J
    result << OpenStudio::IdfObject.load("Output:Variable,*,Heating Coil #{elec} Energy,RunPeriod;").get # J
    result << OpenStudio::IdfObject.load("Output:Variable,*,Heating Coil #{gas} Energy,RunPeriod;").get # J
    result << OpenStudio::IdfObject.load("Output:Variable,*,Heating Coil Defrost #{elec} Energy,RunPeriod;").get # J
    result << OpenStudio::IdfObject.load("Output:Variable,*,Heating Coil Crankcase Heater #{elec} Energy,RunPeriod;").get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,Heating Coil Heating Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,Cooling Coil Total Cooling Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,Zone VRF Air Terminal Total Heating Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,Zone VRF Air Terminal Total Cooling Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,VRF Heat Pump Cooling Electricity Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,VRF Heat Pump Heating Electricity Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,VRF Heat Pump Defrost Electricity Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,VRF Heat Pump Crankcase Heater Electricity Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,VRF Heat Pump Heat Recovery Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,Air System Outdoor Air Mass Flow Rate,RunPeriod;').get
    result << OpenStudio::IdfObject.load('Output:Variable,*,Air System Mixed Air Mass Flow Rate,RunPeriod;').get # kg/s
    result << OpenStudio::IdfObject.load("Output:Variable,*,Air System Mixed Air Mass Flow Rate,#{timeseries_timestep};").get # kg/s
    result << OpenStudio::IdfObject.load("Output:Variable,*,Water Heater #{elec} Energy,RunPeriod;").get # J
    result << OpenStudio::IdfObject.load("Output:Variable,*,Water Heater #{gas} Energy,RunPeriod;").get # J
    result << OpenStudio::IdfObject.load("Output:Variable,*,Water Heater #{fuel_oil} Energy,RunPeriod;").get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,Water Heater Propane Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,Water Heater Heating Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load('Output:Variable,*,Water Heater Unmet Demand Heat Transfer Energy,RunPeriod;').get # J
    result << OpenStudio::IdfObject.load("Output:Variable,*,Unitary System DX Coil Cycling Ratio,#{timeseries_timestep};").get # -
    result << OpenStudio::IdfObject.load("Output:Variable,*,Unitary System Cycling Ratio,#{timeseries_timestep};").get # -
    result << OpenStudio::IdfObject.load("Output:Variable,*,Unitary System Part Load Ratio,#{timeseries_timestep};").get # -
    result << OpenStudio::IdfObject.load("Output:Variable,*,Unitary System Total Cooling Rate,#{timeseries_timestep};").get # W
    result << OpenStudio::IdfObject.load("Output:Variable,*,Unitary System Total Heating Rate,#{timeseries_timestep};").get # W
    result << OpenStudio::IdfObject.load("Output:Variable,*,Unitary System Electricity Rate,#{timeseries_timestep};").get # W
    if model.version > OpenStudio::VersionString.new('3.3.0')
      result << OpenStudio::IdfObject.load('Output:Variable,*,Cooling Coil Total Water Heating Energy,RunPeriod;').get # J
      result << OpenStudio::IdfObject.load('Output:Variable,*,Cooling Coil Water Heating Electricity Energy,RunPeriod;').get # J
    else
      result << OpenStudio::IdfObject.load('Output:Variable,*,Heating Coil Total Water Heating Energy,RunPeriod;').get # J
      result << OpenStudio::IdfObject.load('Output:Variable,*,Heating Coil Water Heating Electricity Energy,RunPeriod;').get # J
    end

    # request zoneHVACComponents mixed air and outdoor air nodes mass flow rate
    model.getZoneHVACComponents.sort.each do |zone_hvac_component|
      # cast the zone_hvac_component down to its child object
      obj_type = zone_hvac_component.iddObjectType.valueName
      obj_type_name = obj_type.gsub('OS_', '').gsub('_', '')
      method_name = "to_#{obj_type_name}"
      if zone_hvac_component.respond_to?(method_name)
        actual_zone_hvac = zone_hvac_component.method(method_name).call
        if !actual_zone_hvac.empty?
          actual_zone_hvac = actual_zone_hvac.get
        end
      end

      next if actual_zone_hvac.airLoopHVAC.is_initialized || !actual_zone_hvac.respond_to?('supplyAirFan')

      base_obj_name = actual_zone_hvac.name.get
      outlet_node = actual_zone_hvac.outletNode.get
      result << OpenStudio::IdfObject.load("Output:Variable, #{outlet_node.name.get}, System Node Mass Flow Rate,RunPeriod;").get # kg/s
      if actual_zone_hvac.respond_to?('outdoorAirMixerName')
        result << OpenStudio::IdfObject.load("Output:Variable,#{base_obj_name} OA Node, System Node Mass Flow Rate,RunPeriod;").get # kg/s
      elsif actual_zone_hvac.respond_to?('vrfSystem')
        result << OpenStudio::IdfObject.load("Output:Variable,#{base_obj_name} Outdoor Air Node, System Node Mass Flow Rate,RunPeriod;").get # kg/s
      else
        next
      end
    end

    # result << OpenStudio::IdfObject.load("Output:Variable,*,Fan #{elec} Energy,RunPeriod;").get # J
    # result << OpenStudio::IdfObject.load("Output:Variable,*,Humidifier #{elec} Energy,RunPeriod;").get # J
    # result << OpenStudio::IdfObject.load("Output:Variable,*,Evaporative Cooler #{elec} Energy,RunPeriod;").get # J
    # result << OpenStudio::IdfObject.load('Output:Variable,*,Baseboard Hot Water Energy,RunPeriod;').get # J
    # result << OpenStudio::IdfObject.load("Output:Variable,*,Baseboard #{elec} Energy,RunPeriod;").get # J

    return result
  end

  # return dependent varible based on two independent variables from TableLookup
  # @param lookup_table [OpenStudio::Model::TableLookup] OpenStudio TableLookup object
  # @param input1 [Double] independent variable 1
  # @param input2 [Double] independent variable 2
  # @return [Double] dependent variable value
  def get_dep_var_from_lookup_table_with_two_ind_var(runner, lookup_table, input1, input2)
    if lookup_table.independentVariables.size == 2
      # Extract independent variable arrays
      ind_var_1 = lookup_table.independentVariables[0].values.to_a
      ind_var_2 = lookup_table.independentVariables[1].values.to_a
      dep_var = lookup_table.outputValues.to_a

      if ind_var_1.size * ind_var_2.size != dep_var.size
        runner.registerError("Table dimensions do not match output size for TableLookup object: #{lookup_table.name}")
        return false
      end

      # Clamp input1 to bounds
      if input1 < ind_var_1.first
        runner.registerWarning("input1 (#{input1}) below range, clamping to #{ind_var_1.first}")
        input1 = ind_var_1.first
      elsif input1 > ind_var_1.last
        runner.registerWarning("input1 (#{input1}) above range, clamping to #{ind_var_1.last}")
        input1 = ind_var_1.last
      end

      # Clamp input2 to bounds
      if input2 < ind_var_2.first
        runner.registerWarning("input2 (#{input2}) below range, clamping to #{ind_var_2.first}")
        input2 = ind_var_2.first
      elsif input2 > ind_var_2.last
        runner.registerWarning("input2 (#{input2}) above range, clamping to #{ind_var_2.last}")
        input2 = ind_var_2.last
      end

      # Find bounding indices for input1
      i1_upper = ind_var_1.index { |val| val >= input1 } || (ind_var_1.size - 1)
      i1_lower = [i1_upper - 1, 0].max

      # Find bounding indices for input2
      i2_upper = ind_var_2.index { |val| val >= input2 } || (ind_var_2.size - 1)
      i2_lower = [i2_upper - 1, 0].max

      x1 = ind_var_1[i1_lower]
      x2 = ind_var_1[i1_upper]
      y1 = ind_var_2[i2_lower]
      y2 = ind_var_2[i2_upper]

      # Get dependent variable values for bilinear interpolation
      v11 = dep_var[(i1_lower * ind_var_2.size) + i2_lower]  # (x1, y1)
      v12 = dep_var[(i1_lower * ind_var_2.size) + i2_upper]  # (x1, y2)
      v21 = dep_var[(i1_upper * ind_var_2.size) + i2_lower]  # (x2, y1)
      v22 = dep_var[(i1_upper * ind_var_2.size) + i2_upper]  # (x2, y2)

      # If exact match, return directly
      if input1 == x1 && input2 == y1
        return v11
      elsif input1 == x1 && input2 == y2
        return v12
      elsif input1 == x2 && input2 == y1
        return v21
      elsif input1 == x2 && input2 == y2
        return v22
      end

      # Handle edge cases where interpolation becomes linear
      dx = x2 - x1
      dy = y2 - y1
      return v11 if dx == 0 && dy == 0
      return v11 + ((v21 - v11) * (input1 - x1) / dx) if dy == 0
      return v11 + ((v12 - v11) * (input2 - y1) / dy) if dx == 0

      # Bilinear interpolation
      interpolated_value =
        (v11 * (x2 - input1) * (y2 - input2)) +
        (v21 * (input1 - x1) * (y2 - input2)) +
        (v12 * (x2 - input1) * (input2 - y1)) +
        (v22 * (input1 - x1) * (input2 - y1))

      interpolated_value /= (x2 - x1) * (y2 - y1)

      return interpolated_value
    else
      runner.registerError('TableLookup object does not have exactly two independent variables.')
      return false
    end
  end

  def convert_timeseries_to_list(timeseries)
    if timeseries.is_initialized
      ts_list = []
      vals = timeseries.get.values
      for i in 0..(vals.size - 1)
        ts_list << vals[i]
      end
    end
    return ts_list
  end

  def get_average_from_array(array)
    sum = array.sum
    count = array.size
    average = sum.to_f / count
    return average
  end

  def get_cooling_coil_curves(runner, coil)
    # initialize parameter
    capacity_w = 99999999999.0

    # get curve depending on coil type
    if coil.to_CoilCoolingDXSingleSpeed.is_initialized
      coil = coil.to_CoilCoolingDXSingleSpeed.get
      curve_plr_to_plf = coil.partLoadFractionCorrelationCurve
    elsif coil.to_CoilCoolingDXTwoSpeed.is_initialized
      coil = coil.to_CoilCoolingDXTwoSpeed.get
      curve_plr_to_plf = coil.partLoadFractionCorrelationCurve
    elsif coil.to_CoilCoolingDXMultiSpeed.is_initialized
      coil = coil.to_CoilCoolingDXMultiSpeed.get
      temp_capacity_w = 0.0
      coil.stages.each do |stage|
        if stage.grossRatedTotalCoolingCapacity.is_initialized
          temp_capacity_w = stage.grossRatedTotalCoolingCapacity.get
        elsif stage.autosizedGrossRatedTotalCoolingCapacity.is_initialized
          temp_capacity_w = stage.autosizedGrossRatedTotalCoolingCapacity.get
        else
          runner.registerWarning("Cooling coil capacity not available for coil stage '#{stage.name}'.")
        end
        temp_curve_plr_to_plf = stage.partLoadFractionCorrelationCurve
        curve_plr_to_plf = temp_curve_plr_to_plf if temp_capacity_w <= capacity_w
        capacity_w = temp_capacity_w if temp_capacity_w < capacity_w
      end
    else
      runner.registerWarning('Specified curve is only available for DX cooling coil types CoilCoolingDXSingleSpeed, CoilCoolingDXTwoSpeed, CoilCoolingDXMultiSpeed.')
    end

    return curve_plr_to_plf
  end

  def get_heating_coil_curves(runner, coil)
    # initialize parameter
    capacity_w = 99999999999.0

    # get curve depending on coil type
    if coil.to_CoilHeatingDXSingleSpeed.is_initialized
      coil = coil.to_CoilHeatingDXSingleSpeed.get
      curve_plr_to_plf = coil.partLoadFractionCorrelationCurve
    elsif coil.to_CoilHeatingDXMultiSpeed.is_initialized
      coil = coil.to_CoilHeatingDXMultiSpeed.get
      temp_capacity_w = 0.0
      coil.stages.each do |stage|
        if stage.grossRatedHeatingCapacity.is_initialized
          temp_capacity_w = stage.grossRatedHeatingCapacity.get
        elsif stage.autosizedGrossRatedHeatingCapacity.is_initialized
          temp_capacity_w = stage.autosizedGrossRatedHeatingCapacity.get
        else
          runner.registerWarning("Heating coil capacity not available for coil stage '#{stage.name}'.")
        end
        temp_curve_plr_to_plf = stage.partLoadFractionCorrelationCurve
        curve_plr_to_plf = temp_curve_plr_to_plf if temp_capacity_w <= capacity_w
        capacity_w = temp_capacity_w if temp_capacity_w < capacity_w
      end
    else
      runner.registerWarning('Specified curve is only available for DX heating coil types CoilHeatingDXSingleSpeed, CoilHeatingDXTwoSpeed, CoilHeatingDXMultiSpeed.')
    end

    return curve_plr_to_plf
  end

  def get_cooling_coil_capacity_and_cop(runner, model, coil)
    capacity_w = 0.0
    coil_design_cop = 0.0

    if coil.to_CoilCoolingDXSingleSpeed.is_initialized
      coil = coil.to_CoilCoolingDXSingleSpeed.get

      # capacity
      if coil.ratedTotalCoolingCapacity.is_initialized
        capacity_w = coil.ratedTotalCoolingCapacity.get
      elsif coil.autosizedRatedTotalCoolingCapacity.is_initialized
        capacity_w = coil.autosizedRatedTotalCoolingCapacity.get
      else
        runner.registerWarning("Cooling coil capacity not available for coil '#{coil.name}'.")
      end

      # cop
      if model.version > OpenStudio::VersionString.new('3.4.0')
        coil_design_cop = coil.ratedCOP
      else
        if coil.ratedCOP.is_initialized
          coil_design_cop = coil.ratedCOP.get
        else
          runner.registerWarning("'Rated COP' not available for DX coil '#{coil.name}'.")
        end
      end
    elsif coil.to_CoilCoolingDXTwoSpeed.is_initialized
      coil = coil.to_CoilCoolingDXTwoSpeed.get

      # capacity
      if coil.ratedHighSpeedTotalCoolingCapacity.is_initialized
        capacity_w = coil.ratedHighSpeedTotalCoolingCapacity.get
      elsif coil.autosizedRatedHighSpeedTotalCoolingCapacity.is_initialized
        capacity_w = coil.autosizedRatedHighSpeedTotalCoolingCapacity.get
      else
        runner.registerWarning("Cooling coil capacity not available for coil '#{coil.name}'.")
      end

      # cop, use high speed cop
      if model.version > OpenStudio::VersionString.new('3.4.0')
        coil_design_cop = coil.ratedHighSpeedCOP
      else
        if coil.ratedHighSpeedCOP.is_initialized
          coil_design_cop = coil.ratedHighSpeedCOP.get
        else
          runner.registerWarning("'Rated High Speed COP' not available for DX coil '#{coil.name}'.")
        end
      end
    elsif coil.to_CoilCoolingDXMultiSpeed.is_initialized
      coil = coil.to_CoilCoolingDXMultiSpeed.get

      # capacity and cop, use cop at highest capacity
      temp_capacity_w = 0.0
      coil.stages.each do |stage|
        if stage.grossRatedTotalCoolingCapacity.is_initialized
          temp_capacity_w = stage.grossRatedTotalCoolingCapacity.get
        elsif stage.autosizedGrossRatedTotalCoolingCapacity.is_initialized
          temp_capacity_w = stage.autosizedGrossRatedTotalCoolingCapacity.get
        else
          runner.registerWarning("Cooling coil capacity not available for coil stage '#{stage.name}'.")
        end

        # update cop if highest capacity
        temp_coil_design_cop = stage.grossRatedCoolingCOP
        coil_design_cop = temp_coil_design_cop if temp_capacity_w >= capacity_w

        # update if highest capacity
        capacity_w = temp_capacity_w if temp_capacity_w > capacity_w
      end
    elsif coil.to_CoilCoolingDXVariableSpeed.is_initialized
      coil = coil.to_CoilCoolingDXVariableSpeed.get

      # capacity and cop, use cop at highest capacity
      temp_capacity_w = 0.0
      coil.speeds.each do |speed|
        temp_capacity_w = speed.referenceUnitGrossRatedTotalCoolingCapacity

        # update cop if highest capacity
        temp_coil_design_cop = speed.referenceUnitGrossRatedCoolingCOP
        coil_design_cop = temp_coil_design_cop if temp_capacity_w >= capacity_w

        # update if highest capacity
        capacity_w = temp_capacity_w if temp_capacity_w > capacity_w
      end
    else
      runner.registerWarning('Design capacity is only available for DX cooling coil types CoilCoolingDXSingleSpeed, CoilCoolingDXTwoSpeed, CoilCoolingDXMultiSpeed, CoilCoolingDXVariableSpeed.')
    end

    return capacity_w, coil_design_cop
  end

  def get_heating_coil_capacity_and_cop(runner, model, coil)
    # get coil rated capacity and cop
    capacity_w = 0.0
    capacity_17F_w = 0.0
    capacity_5F_w = 0.0
    capacity_0F_w = 0.0
    coil_design_cop = 0.0
    coil_design_cop_17F = 0.0
    coil_design_cop_5F = 0.0
    coil_design_cop_0F = 0.0
    if coil.to_CoilHeatingDXSingleSpeed.is_initialized
      coil = coil.to_CoilHeatingDXSingleSpeed.get
      if coil.ratedTotalHeatingCapacity.is_initialized
        capacity_w = coil.ratedTotalHeatingCapacity.get
      elsif coil.autosizedRatedTotalHeatingCapacity.is_initialized
        capacity_w = coil.autosizedRatedTotalHeatingCapacity.get
      else
        runner.registerWarning("Heating coil capacity not available for coil '#{coil.name}'.")
      end

      # get rated capacity and capacity at lower temperatures
      cap_curve = coil.totalHeatingCapacityFunctionofTemperatureCurve
      if cap_curve.to_CurveCubic.is_initialized
        coil_cap_17F = cap_curve.evaluate(OpenStudio.convert(17.0, 'F', 'C').get)
        capacity_17F_w = capacity_w * coil_cap_17F
        coil_cap_5F =  cap_curve.evaluate(OpenStudio.convert(5.0, 'F', 'C').get)
        capacity_5F_w = capacity_w * coil_cap_5F
        coil_cap_0F = cap_curve.evaluate(OpenStudio.convert(0.0, 'F', 'C').get)
        capacity_0F_w = capacity_w * coil_cap_0F
      else
        runner.registerWarning("Heating coil capacity at lower temperatures not available for coil '#{coil.name}' with given curve.")
      end

      # get rated cop and cop at lower temperatures
      coil_design_cop = coil.ratedCOP
      eir_curve = coil.energyInputRatioFunctionofTemperatureCurve
      if eir_curve.to_CurveCubic.is_initialized
        coil_eir_17F = eir_curve.evaluate(OpenStudio.convert(17.0, 'F', 'C').get)
        coil_design_cop_17F = coil_design_cop / coil_eir_17F
        coil_eir_5F = eir_curve.evaluate(OpenStudio.convert(5.0, 'F', 'C').get)
        coil_design_cop_5F = coil_design_cop / coil_eir_5F
        coil_eir_0F = eir_curve.evaluate(OpenStudio.convert(0.0, 'F', 'C').get)
        coil_design_cop_0F = coil_design_cop / coil_eir_0F
      else
        runner.registerWarning("Coil COP at non-design temperatures not available for coil '#{coil.name}'.")
      end
    elsif coil.to_CoilHeatingDXMultiSpeed.is_initialized
      coil = coil.to_CoilHeatingDXMultiSpeed.get
      temp_capacity_w = 0.0
      coil.stages.each do |stage|
        if stage.grossRatedHeatingCapacity.is_initialized
          temp_capacity_w = stage.grossRatedHeatingCapacity.get
        elsif stage.autosizedGrossRatedHeatingCapacity.is_initialized
          temp_capacity_w = stage.autosizedGrossRatedHeatingCapacity.get
        else
          runner.registerWarning("Heating coil capacity not available for coil stage '#{stage.name}'.")
        end

        # get capacity and capacity at lower temperatures
        cap_curve = stage.heatingCapacityFunctionofTemperatureCurve
        if cap_curve.to_CurveCubic.is_initialized
          coil_cap_17F = cap_curve.evaluate(OpenStudio.convert(17.0, 'F', 'C').get)
          capacity_17F_w = capacity_w * coil_cap_17F if temp_capacity_w >= capacity_w
          coil_cap_5F =  cap_curve.evaluate(OpenStudio.convert(5.0, 'F', 'C').get)
          capacity_5F_w = capacity_w * coil_cap_5F if temp_capacity_w >= capacity_w
          coil_cap_0F = cap_curve.evaluate(OpenStudio.convert(0.0, 'F', 'C').get)
          capacity_0F_w = capacity_w * coil_cap_0F if temp_capacity_w >= capacity_w
        elsif cap_curve.to_CurveBiquadratic.is_initialized
          coil_cap_17F = cap_curve.evaluate(OpenStudio.convert(70.0, 'F', 'C').get, OpenStudio.convert(17.0, 'F', 'C').get)
          capacity_17F_w = capacity_w * coil_cap_17F if temp_capacity_w >= capacity_w
          coil_cap_5F =  cap_curve.evaluate(OpenStudio.convert(70.0, 'F', 'C').get, OpenStudio.convert(5.0, 'F', 'C').get)
          capacity_5F_w = capacity_w * coil_cap_5F if temp_capacity_w >= capacity_w
          coil_cap_0F = cap_curve.evaluate(OpenStudio.convert(70.0, 'F', 'C').get, OpenStudio.convert(0.0, 'F', 'C').get)
          capacity_0F_w = capacity_w * coil_cap_0F if temp_capacity_w >= capacity_w
        else
          runner.registerWarning("Heating coil capacity at lower temperatures not available for coil '#{coil.name}' with given curve.")
        end

        # get cop and cop at lower temperatures
        # pick cop at highest capacity
        temp_coil_design_cop = stage.grossRatedHeatingCOP
        coil_design_cop = temp_coil_design_cop if temp_capacity_w >= capacity_w
        eir_curve = stage.energyInputRatioFunctionofTemperatureCurve
        if eir_curve.to_CurveCubic.is_initialized
          coil_eir_17F = eir_curve.evaluate(OpenStudio.convert(17.0, 'F', 'C').get)
          coil_design_cop_17F = coil_design_cop / coil_eir_17F if temp_capacity_w >= capacity_w
          coil_eir_5F = eir_curve.evaluate(OpenStudio.convert(5.0, 'F', 'C').get)
          coil_design_cop_5F = coil_design_cop / coil_eir_5F if temp_capacity_w >= capacity_w
          coil_eir_0F = eir_curve.evaluate(OpenStudio.convert(0.0, 'F', 'C').get)
          coil_design_cop_0F = coil_design_cop / coil_eir_0F if temp_capacity_w >= capacity_w
        elsif cap_curve.to_CurveBiquadratic.is_initialized
          coil_eir_17F = eir_curve.evaluate(OpenStudio.convert(70.0, 'F', 'C').get, OpenStudio.convert(17.0, 'F', 'C').get)
          coil_design_cop_17F = coil_design_cop / coil_eir_17F if temp_capacity_w >= capacity_w
          coil_eir_5F = eir_curve.evaluate(OpenStudio.convert(70.0, 'F', 'C').get, OpenStudio.convert(5.0, 'F', 'C').get)
          coil_design_cop_5F = coil_design_cop / coil_eir_5F if temp_capacity_w >= capacity_w
          coil_eir_0F = eir_curve.evaluate(OpenStudio.convert(70.0, 'F', 'C').get, OpenStudio.convert(0.0, 'F', 'C').get)
          coil_design_cop_0F = coil_design_cop / coil_eir_0F if temp_capacity_w >= capacity_w
        else
          runner.registerWarning("Coil COP at non-design temperatures not available for coil '#{coil.name}'.")
        end

        # update if highest capacity
        capacity_w = temp_capacity_w if temp_capacity_w > capacity_w
      end
    elsif coil.to_CoilHeatingDXVariableSpeed.is_initialized
      coil = coil.to_CoilHeatingDXVariableSpeed.get
      coil.speeds.each do |speed|
        temp_capacity_w = speed.referenceUnitGrossRatedHeatingCapacity

        # get capacity and capacity at lower temperatures
        cap_curve = stage.heatingCapacityFunctionofTemperatureCurve
        if cap_curve.to_CurveCubic.is_initialized
          coil_cap_17F = cap_curve.evaluate(OpenStudio.convert(17.0, 'F', 'C').get)
          capacity_17F_w = capacity_w * coil_cap_17F if temp_capacity_w >= capacity_w
          coil_cap_5F =  cap_curve.evaluate(OpenStudio.convert(5.0, 'F', 'C').get)
          capacity_5F_w = capacity_w * coil_cap_5F if temp_capacity_w >= capacity_w
          coil_cap_0F = cap_curve.evaluate(OpenStudio.convert(0.0, 'F', 'C').get)
          capacity_0F_w = capacity_w * coil_cap_0F if temp_capacity_w >= capacity_w
        else
          runner.registerWarning("Heating coil capacity at lower temperatures not available for coil '#{coil.name}' with given curve.")
        end

        # get cop and cop at lower temperatures
        # pick cop at highest capacity
        temp_coil_design_cop = speed.referenceUnitGrossRatedHeatingCOP
        coil_design_cop = temp_coil_design_cop if temp_capacity_w >= capacity_w
        eir_curve = speed.energyInputRatioFunctionofTemperatureCurve
        if eir_curve.to_CurveCubic.is_initialized
          coil_eir_17F = eir_curve.evaluate(OpenStudio.convert(17.0, 'F', 'C').get)
          coil_design_cop_17F = coil_design_cop / coil_eir_17F if temp_capacity_w >= capacity_w
          coil_eir_5F = eir_curve.evaluate(OpenStudio.convert(5.0, 'F', 'C').get)
          coil_design_cop_5F = coil_design_cop / coil_eir_5F if temp_capacity_w >= capacity_w
          coil_eir_0F = eir_curve.evaluate(OpenStudio.convert(0.0, 'F', 'C').get)
          coil_design_cop_0F = coil_design_cop / coil_eir_0F if temp_capacity_w >= capacity_w
        else
          runner.registerWarning("Coil COP at non-design temperatures not available for coil '#{coil.name}'.")
        end

        # update if highest capacity
        capacity_w = temp_capacity_w if temp_capacity_w > capacity_w
      end
    else
      runner.registerWarning('Design COP and capacity for DX heating coil unavailable because of unrecognized coil type.')
    end

    return capacity_w, capacity_0F_w, capacity_5F_w, capacity_17F_w, coil_design_cop, coil_design_cop_0F, coil_design_cop_5F, coil_design_cop_17F
  end

  # define what happens when the measure is run
  def run(runner, user_arguments)
    super(runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments, user_arguments)
      return false
    end

    # get the last model and sql file
    model = runner.lastOpenStudioModel
    if model.empty?
      runner.registerError('Cannot find last model.')
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

    # get the weather file run period (as opposed to design day run period)
    ann_env_pd = nil
    sql.availableEnvPeriods.each do |env_pd|
      env_type = sql.environmentType(env_pd)
      if env_type.is_initialized && (env_type.get == (OpenStudio::EnvironmentType.new('WeatherRunPeriod')))
        ann_env_pd = env_pd
      end
    end

    if (ann_env_pd.nil?) || (ann_env_pd == false)
      runner.registerError('Cannot find a weather runperiod. Make sure you ran an annual simulation, not just the design days.')
      return false
    end

    # Handle output variables that changed from 'Electric' to 'Electricity' in EnergyPlus version 9.4 (Openstudio version 3.1)
    elec = 'Electric'
    gas = 'Gas'
    if model.version > OpenStudio::VersionString.new('3.0.1')
      elec = 'Electricity'
      gas = 'NaturalGas'
    end

    # build standard to access methods
    std = Standard.build('ComStock 90.1-2013')

    standard_air_density = 1.225 #kg/m3, using standard air density since need a single value

    # get building floor area properties
    total_building_area_m2 = 0.0
    var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'AnnualBuildingUtilityPerformanceSummary' AND ReportForString = 'Entire Facility' AND TableName = 'Building Area' AND RowName = 'Total Building Area' AND ColumnName = 'Area' AND Units = 'm2'"
    val = sql.execAndReturnFirstDouble(var_val_query)
    if val.is_initialized
      total_building_area_m2 = val.get
    else
      runner.registerWarning('Building floor area not available.')
    end

    # calculate exterior surface properties
    smallest_space_m2 = 9999.0
    num_surfaces = 0
    roof_absorptance_times_area = 0
    roof_ua_si = 0.0
    roof_area_m2 = 0.0
    exterior_wall_ua_si = 0.0
    exterior_wall_area_m2 = 0.0
    spaces = model.getSpaces
    spaces.sort.each do |space|
      floor_area_m2 = space.floorArea * space.multiplier
      smallest_space_m2 = floor_area_m2 if floor_area_m2 < smallest_space_m2
      space.surfaces.sort.each do |surface|
        num_surfaces += 1 * space.multiplier
        next if surface.outsideBoundaryCondition != 'Outdoors'

        if surface.surfaceType.to_s == 'RoofCeiling'
          surface_absorptance = surface.exteriorVisibleAbsorptance.is_initialized ? surface.exteriorVisibleAbsorptance.get : 0.0
          surface_u_value_si = surface.uFactor.is_initialized ? surface.uFactor.get : 0.0
          surface_area_m2 = surface.netArea * space.multiplier
          surface_ua_si = surface_u_value_si * surface_area_m2
          roof_absorptance_times_area += surface_absorptance * surface_area_m2
          roof_ua_si += surface_ua_si
          roof_area_m2 += surface_area_m2
        elsif surface.surfaceType.to_s == 'Wall'
          surface_u_value_si = surface.uFactor.is_initialized ? surface.uFactor.get : 0.0
          surface_area_m2 = surface.netArea * space.multiplier
          surface_ua_si = surface_u_value_si * surface_area_m2
          exterior_wall_ua_si += surface_ua_si
          exterior_wall_area_m2 += surface_area_m2
        end
      end
    end

    # total number of zones
    num_zones = 0
    zones = model.getThermalZones
    zones.each { |z| num_zones += z.multiplier }
    runner.registerValue('com_report_number_of_model_zones', zones.size)
    runner.registerValue('com_report_number_of_zones', num_zones)

    # total number of spaces
    num_spaces = 0
    spaces.each { |s| num_spaces += s.multiplier }
    runner.registerValue('com_report_number_of_model_spaces', spaces.size)
    runner.registerValue('com_report_number_of_spaces', num_spaces)

    # smallest space size
    runner.registerValue('com_report_smallest_space_m2', smallest_space_m2, 'm^2')

    # total number of surfaces
    runner.registerValue('com_report_number_of_surfaces', num_surfaces)

    # Average roof absorptance
    if roof_area_m2 > 0
      average_roof_absorptance = roof_absorptance_times_area / roof_area_m2
      runner.registerValue('com_report_average_roof_absorptance', average_roof_absorptance)
    else
      runner.registerWarning('Roof area is zero. Cannot calculate average absorptance.')
    end

    # Average roof U-value
    if roof_area_m2 > 0
      average_roof_u_value_si = roof_ua_si / roof_area_m2
      runner.registerValue('com_report_roof_area_m2', roof_area_m2, 'm^2')
      runner.registerValue('com_report_average_roof_u_value_si', average_roof_u_value_si)
    else
      runner.registerWarning('Roof area is zero. Cannot calculate average U-value.')
    end

    # Average wall U-value
    if exterior_wall_area_m2 > 0
      average_exterior_wall_u_value_si = exterior_wall_ua_si / exterior_wall_area_m2
      runner.registerValue('com_report_exterior_wall_area_m2', exterior_wall_area_m2, 'm^2')
      runner.registerValue('com_report_average_exterior_wall_u_value_si', average_exterior_wall_u_value_si, 'W/m^2*K')
    else
      runner.registerWarning('Exterior wall area is zero. Cannot calculate average U-value.')
    end

    # Average window area
    window_area_m2 = 0
    var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'EnvelopeSummary' AND ReportForString = 'Entire Facility' AND TableName = 'Exterior Fenestration' AND RowName = 'Total or Average' AND ColumnName = 'Area of Multiplied Openings' AND Units = 'm2'"
    val = sql.execAndReturnFirstDouble(var_val_query)
    if val.is_initialized
      window_area_m2 = val.get
      runner.registerValue('com_report_window_area_m2', window_area_m2, 'm^2')
    else
      runner.registerWarning('Overall window area not available.')
    end

    # Average window U-value
    var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'EnvelopeSummary' AND ReportForString = 'Entire Facility' AND TableName = 'Exterior Fenestration' AND RowName = 'Total or Average' AND ColumnName = 'Glass U-Factor' AND Units = 'W/m2-K'"
    val = sql.execAndReturnFirstDouble(var_val_query)
    if val.is_initialized
      window_u_value_si = val.get
      runner.registerValue('com_report_window_u_value_si', window_u_value_si, 'W/m^2*K')
    else
      runner.registerWarning('Overall average window U-value not available.')
    end

    # Average window SHGC
    var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'EnvelopeSummary' AND ReportForString = 'Entire Facility' AND TableName = 'Exterior Fenestration' AND RowName = 'Total or Average' AND ColumnName = 'Glass SHGC'"
    val = sql.execAndReturnFirstDouble(var_val_query)
    if val.is_initialized
      window_shgc = val.get
      runner.registerValue('com_report_window_shgc', window_shgc)
    else
      runner.registerWarning('Overall average window SHGC not available.')
    end

    # Average window VLT
    var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'EnvelopeSummary' AND ReportForString = 'Entire Facility' AND TableName = 'Exterior Fenestration' AND RowName = 'Total or Average' AND ColumnName = 'Glass Visible Transmittance'"
    val = sql.execAndReturnFirstDouble(var_val_query)
    if val.is_initialized
      window_vlt = val.get
      runner.registerValue('com_report_window_vlt', window_vlt)
    else
      runner.registerWarning('Overall average window VLT not available.')
    end

    # Building window to wall ratio
    var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'InputVerificationandResultsSummary' AND ReportForString = 'Entire Facility' AND TableName = 'Window-Wall Ratio' AND RowName = 'Gross Window-Wall Ratio' AND ColumnName = 'Total'"
    val = sql.execAndReturnFirstDouble(var_val_query)
    if val.is_initialized
      wwr = val.get / 100.0
      runner.registerValue('com_report_wwr', wwr)
    else
      runner.registerWarning('Overall window to wall ratio not available.')
    end

    # Interior mass surface area
    internal_mass_area_m2 = 0.0
    total_space_area_m2 = 0.0
    model.getInternalMasss.sort.each do |mass|
      space = mass.space.get
      space_area_m2 = space.floorArea * space.multiplier
      num_people = space.numberOfPeople * space.multiplier
      surface_area_m2 = mass.surfaceArea.is_initialized ? mass.surfaceArea.get : 0.0
      surface_area_per_floor_area_m2 = mass.surfaceAreaPerFloorArea.is_initialized ? mass.surfaceAreaPerFloorArea.get : 0.0
      surface_area_per_person_m2 = mass.surfaceAreaPerPerson.is_initialized ? mass.surfaceAreaPerPerson.get : 0.0
      internal_mass_area_m2 += surface_area_m2 + (surface_area_per_floor_area_m2 * space_area_m2) + (surface_area_per_person_m2 * num_people)
      total_space_area_m2 += space_area_m2
    end
    internal_mass_area_ratio = total_space_area_m2 > 0.0 ? internal_mass_area_m2 / total_space_area_m2 : 0.0
    runner.registerValue('com_report_internal_mass_area_ratio', internal_mass_area_ratio)

    # Daylight control space fraction
    weighted_daylight_control_area_m2 = 0.0
    total_zone_area_m2 = 0.0
    model.getThermalZones.sort.each do |zone|
      zone_area_m2 = zone.floorArea * zone.multiplier
      primary_fraction = zone.primaryDaylightingControl.is_initialized ? zone.fractionofZoneControlledbyPrimaryDaylightingControl : 0.0
      secondary_fraction = zone.secondaryDaylightingControl.is_initialized ? zone.fractionofZoneControlledbySecondaryDaylightingControl : 0.0
      total_fraction = [(primary_fraction + secondary_fraction), 1.0].min
      weighted_daylight_control_area_m2 += total_fraction * zone_area_m2
      total_zone_area_m2 += zone_area_m2
    end
    daylight_control_fraction = total_zone_area_m2 > 0.0 ? weighted_daylight_control_area_m2 / total_zone_area_m2 : 0.0
    runner.registerValue('com_report_daylight_control_fraction', daylight_control_fraction)

    # Exterior lighting power
    var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'LightingSummary' AND ReportForString = 'Entire Facility' AND TableName = 'Exterior Lighting' AND RowName = 'Exterior Lighting Total' AND ColumnName = 'Total Watts'"
    val = sql.execAndReturnFirstDouble(var_val_query)
    if val.is_initialized
      exterior_lighting_power_w = sql.execAndReturnFirstDouble(var_val_query).get
      runner.registerValue('com_report_exterior_lighting_power_w', exterior_lighting_power_w, 'W')
    else
      runner.registerWarning('Total exterior lighting power not available.')
    end

    # Elevator energy use
    elevator_energy_use_gj = 0.0
    var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'EnergyMeters' AND RowName = 'Elevators:InteriorEquipment:Electricity' AND ColumnName = 'Electricity Annual Value' AND Units = 'GJ'"
    val = sql.execAndReturnFirstDouble(var_val_query)
    if val.is_initialized
      elevator_energy_use_gj = val.get
    else
      runner.registerWarning('Annual elevator energy use not available.')
    end
    runner.registerValue('com_report_elevator_energy_use_gj', elevator_energy_use_gj, 'GJ')

    # Average interior lighting equivalent full load hours
    interior_lighting_total_power_w = 0
    var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'LightingSummary' AND ReportForString = 'Entire Facility' AND TableName = 'Interior Lighting' AND RowName = 'Interior Lighting Total' AND ColumnName = 'Total Power' AND Units = 'W'"
    val = sql.execAndReturnFirstDouble(var_val_query)
    if val.is_initialized
      interior_lighting_total_power_w = val.get
      # runner.registerValue('com_report_interior_lighting_total_power_w', interior_lighting_total_power_w, 'W')
    else
      runner.registerWarning('Interior lighting power not available.')
    end

    interior_lighting_consumption_gj = 0
    var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'LightingSummary' AND ReportForString = 'Entire Facility' AND TableName = 'Interior Lighting' AND RowName = 'Interior Lighting Total' AND ColumnName = 'Consumption' AND Units = 'GJ'"
    val = sql.execAndReturnFirstDouble(var_val_query)
    if val.is_initialized
      interior_lighting_consumption_gj = val.get
      # runner.registerValue('com_report_interior_lighting_consumption_gj', interior_lighting_consumption_gj, 'GJ')
    else
      runner.registerWarning('Interior lighting consumption not available.')
    end

    if interior_lighting_total_power_w > 0
      interior_lighting_eflh = (interior_lighting_consumption_gj * 1e9) / (interior_lighting_total_power_w * 3600.0)
      runner.registerValue('com_report_interior_lighting_eflh', interior_lighting_eflh, 'hr')
    else
      runner.registerWarning('Interior lighting power is not available; cannot calculate equivalent full load hours.')
    end

    # Average interior lighting power density
    if total_building_area_m2 > 0 && interior_lighting_total_power_w > 0
      interior_lighting_power_density_w_per_m2 = interior_lighting_total_power_w / total_building_area_m2
      runner.registerValue('com_report_interior_lighting_power_density_w_per_m2', interior_lighting_power_density_w_per_m2, 'W/m^2')
    else
      runner.registerWarning('Average interior lighting power density not available.')
    end

    # Interior electric equipment calculations
    total_zone_electric_equipment_area_m2 = 0.0
    total_zone_electric_equipment_power_w = 0.0
    total_zone_electric_equipment_energy_gj = 0
    model.getThermalZones.sort.each do |zone|
      # get design plug load power
      zone_electric_equipment_power_w = 0.0
      floor_area_m2 = 0.0
      space_type = OpenstudioStandards::ThermalZone.thermal_zone_get_space_type(zone)
      if space_type.is_initialized
        space_type = space_type.get
        floor_area_m2 = zone.floorArea * zone.multiplier
        num_people = zone.numberOfPeople * zone.multiplier
        equip_w = space_type.getElectricEquipmentDesignLevel(floor_area_m2, num_people)
        # equip_per_area_w and equip_per_person_w are not included in equip_w call
        # equip_per_area_w = space_type.getElectricEquipmentPowerPerFloorArea(floor_area_m2, num_people) * floor_area_m2
        # equip_per_person_w = num_people > 0.0 ? space_type.getElectricEquipmentPowerPerPerson(floor_area_m2, num_people) * num_people : 0.0
        zone_electric_equipment_power_w = equip_w # + equip_per_area_w + equip_per_person_w
      else
        runner.registerWarning("Unable to determine majority space type for zone '#{zone.name}'.")
      end

      # skip zones with no plug loads; this will skip zones with equipment defined only at space instance level
      next if zone_electric_equipment_power_w == 0.0

      total_zone_electric_equipment_area_m2 += floor_area_m2
      total_zone_electric_equipment_power_w += zone_electric_equipment_power_w

      # get zone electric equipment energy (may include kitchen or elevator equipment)
      zone_electric_equipment_energy_gj = 0.0
      var_data_id_query = "SELECT ReportVariableDataDictionaryIndex FROM ReportVariableDataDictionary WHERE VariableName = 'Zone Electric Equipment #{elec} Energy' AND ReportingFrequency = 'Run Period' AND KeyValue = '#{zone.name.get.to_s.upcase}'"
      var_data_id = sql.execAndReturnFirstDouble(var_data_id_query)
      if var_data_id.is_initialized
        var_val_query = "SELECT VariableValue FROM ReportVariableData WHERE ReportVariableDataDictionaryIndex = '#{var_data_id.get}'"
        val = sql.execAndReturnFirstDouble(var_val_query)
        if val.is_initialized
          zone_electric_equipment_energy_gj = val.get
        else
          runner.registerWarning("'Zone Electric Equipment #{elec} Energy' value not available for zone '#{zone.name}'.")
        end
      else
        runner.registerWarning("'Zone Electric Equipment #{elec} Energy' data index not available for zone '#{zone.name}'.  Trying to use meter data instead.")
        var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'EnergyMeters' AND RowName = 'InteriorEquipment:Electricity:Zone:#{zone.name.to_s.upcase}' AND ColumnName = 'Electricity Annual Value' AND Units = 'GJ'"
        val = sql.execAndReturnFirstDouble(var_val_query)
        if val.is_initialized
          zone_electric_equipment_energy_gj = val.get
        else
          runner.registerWarning("'Zone Electric Equipment #{elec} Energy' value not available for zone '#{zone.name}'.")
        end
      end
      total_zone_electric_equipment_energy_gj += zone_electric_equipment_energy_gj
    end

    # Whole building level plug load, minus elevators
    total_bldg_electric_equipment_energy_gj = 0
    var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'EnergyMeters' AND RowName = 'General:InteriorEquipment:Electricity' AND ColumnName = 'Electricity Annual Value' AND Units = 'GJ'"
    val = sql.execAndReturnFirstDouble(var_val_query)
    if val.is_initialized
      total_bldg_electric_equipment_energy_gj = val.get
    else
      runner.registerWarning("'General:InteriorEquipment:Electricity' value not available.")
    end

    # Average plug load power density
    interior_electric_equipment_power_density_w_per_m2 = total_zone_electric_equipment_area_m2 > 0.0 ? total_zone_electric_equipment_power_w / total_zone_electric_equipment_area_m2 : 0.0
    runner.registerValue('com_report_interior_electric_equipment_power_density_w_per_m2', interior_electric_equipment_power_density_w_per_m2, 'W/m^2')

    # Average plug load equivalent full load hours (EPD*area*8760 / annual energy use)
    if total_zone_electric_equipment_power_w > 0
      interior_electric_equipment_eflh = (total_bldg_electric_equipment_energy_gj * 1e9) / (total_zone_electric_equipment_power_w * 3600.0)
      runner.registerValue('com_report_interior_electric_equipment_eflh', interior_electric_equipment_eflh, 'hr')
      # runner.registerInfo("total_bldg_electric_equipment_energy_gj: #{total_bldg_electric_equipment_energy_gj}")
      # runner.registerInfo("total_zone_electric_equipment_energy_gj: #{total_zone_electric_equipment_energy_gj}")
      # runner.registerInfo("total_zone_electric_equipment_power_w: #{total_zone_electric_equipment_power_w}")
    else
      runner.registerWarning('Interior electric equipment power is not available; cannot calculate equivalent full load hours.')
    end

    # get PV capacity
    pv_capacity_w = 0
    model.getGeneratorPVWattss.sort.each do |pv_sys|
      # get PV system capacity
      pv_capacity_w += pv_sys.dcSystemCapacity / 1000
    end
    runner.registerValue('com_report_pv_system_size_kw', pv_capacity_w, 'kW')

    # get battery storage information
    battery_capacity_kwh = 0.0
    max_charge_kw = 0.0
    max_discharge_kw = 0.0
    model.getElectricLoadCenterStorageSimples.each do |batt|
      battery_capacity_kwh += batt.maximumStorageCapacity / 3.6e6  # J → kWh
      max_charge_kw += batt.maximumPowerforCharging / 1000.0       # W → kW
      max_discharge_kw += batt.maximumPowerforDischarging / 1000.0 # W → kW
    end
    runner.registerValue('com_report_battery_capacity_kwh', battery_capacity_kwh.round(2), 'kWh')
    runner.registerValue('com_report_battery_max_charge_kw', max_charge_kw.round(2), 'kW')
    runner.registerValue('com_report_battery_max_discharge_kw', max_discharge_kw.round(2), 'kW')

    # Occupant calculations
    total_zone_occupant_area_m2 = 0.0
    total_zone_design_ppl = 0.0
    total_zone_ppl_count = 0
    model.getThermalZones.sort.each do |zone|
      total_zone_occupant_area_m2 += zone.floorArea * zone.multiplier
      total_zone_design_ppl += zone.numberOfPeople * zone.multiplier
      zone_ppl_count = sql_get_report_variable_data_double(runner, sql, zone, 'Zone People Occupant Count')
      total_zone_ppl_count += zone_ppl_count * zone.multiplier
    end

    # Average occupant density
    occupant_density_ppl_per_m2 = total_zone_occupant_area_m2 > 0.0 ? total_zone_design_ppl / total_zone_occupant_area_m2 : 0.0
    runner.registerValue('com_report_occupant_density_ppl_per_m2', occupant_density_ppl_per_m2, '1/m^2')

    # Average occupant equivalent full load hours
    if total_zone_design_ppl > 0
      occupant_eflh = (total_zone_ppl_count / total_zone_design_ppl) * 8760.0
      runner.registerValue('com_report_occupant_eflh', occupant_eflh, 'hr')
    else
      runner.registerWarning('Zone occupancy is not available; cannot calculate equivalent full load hours.')
    end

    # Design outdoor air flow rate
    total_design_outdoor_air_flow_rate_m3_per_s = 0.0
    design_outdoor_air_flow_rate_area_m2 = 0.0
    model.getThermalZones.sort.each do |zone|
      zone.spaces.sort.each do |space|
        next unless space.designSpecificationOutdoorAir.is_initialized

        dsn_oa = space.designSpecificationOutdoorAir.get

        # get the space properties
        floor_area_m2 = space.floorArea * space.multiplier
        number_of_people = space.numberOfPeople * space.multiplier
        volume_m3 = space.volume * space.multiplier

        # get outdoor air values
        oa_for_people = number_of_people * dsn_oa.outdoorAirFlowperPerson
        oa_for_floor_area = floor_area_m2 * dsn_oa.outdoorAirFlowperFloorArea
        oa_rate = dsn_oa.outdoorAirFlowRate
        oa_for_volume = volume_m3 * dsn_oa.outdoorAirFlowAirChangesperHour / 3600.0

        # determine total outdoor air
        if dsn_oa.outdoorAirMethod == 'Maximum'
          tot_oa_m3_per_s = [oa_for_people, oa_for_floor_area, oa_rate, oa_for_volume].max
        else
          tot_oa_m3_per_s = oa_for_people + oa_for_floor_area + oa_rate + oa_for_volume
        end

        total_design_outdoor_air_flow_rate_m3_per_s += tot_oa_m3_per_s
        design_outdoor_air_flow_rate_area_m2 += floor_area_m2
      end
    end
    design_outdoor_air_flow_rate_m3_per_m2s = design_outdoor_air_flow_rate_area_m2 > 0.0 ? total_design_outdoor_air_flow_rate_m3_per_s / design_outdoor_air_flow_rate_area_m2 : 0.0
    runner.registerValue('com_report_design_outdoor_air_flow_rate_m3_per_m2s', design_outdoor_air_flow_rate_m3_per_m2s, 'm/s')

    # Air system outdoor air flow fraction
    # Air system fan properties
    air_system_total_oa_mass_flow_kg_s = 0.0
    air_system_total_mass_flow_kg_s = 0.0
    air_system_weighted_fan_power_minimum_flow_fraction = 0.0
    air_system_weighted_fan_static_pressure = 0.0
    air_system_weighted_fan_efficiency = 0.0
    air_system_total_vav_mass_flow_kg_s = 0.0
    air_system_total_des_flow_rate_m3_s = 0.0
    air_system_vav_avg_flow_ratio = -999
    des_flow_rate_m3_s = 0
    economizer_statistics = []
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      # check if unitary system
      if std.air_loop_hvac_unitary_system?(air_loop_hvac)
        runner.registerWarning("Air loop hvac '#{air_loop_hvac.name}' is a unitary system; fan properties recorded under zone hvac.")
      end

      # get Air System Outdoor Air Mass Flow Rate
      air_loop_oa_mass_flow_rate_kg_s = sql_get_report_variable_data_double(runner, sql, air_loop_hvac, 'Air System Outdoor Air Mass Flow Rate')

      # get Air System Outdoor Air Economizer Status
      air_loop_econ_status = sql_get_report_variable_data_double(runner, sql, air_loop_hvac, 'Air System Outdoor Air Economizer Status')

      # get Air System Mixed Air Mass Flow Rate
      air_loop_mass_flow_rate_kg_s = sql_get_report_variable_data_double(runner, sql, air_loop_hvac, 'Air System Mixed Air Mass Flow Rate')

      fan_minimum_flow_frac = 0.0
      fan_static_pressure = 0.0
      fan_efficiency = 0.0
      fan_var_vol = false
      supply_fan = air_loop_hvac.supplyFan
      if supply_fan.is_initialized
        supply_fan = supply_fan.get
        if supply_fan.to_FanOnOff.is_initialized
          supply_fan = supply_fan.to_FanOnOff.get
          fan_minimum_flow_frac = 1.0
          fan_static_pressure = supply_fan.pressureRise
          fan_efficiency = supply_fan.fanTotalEfficiency
        elsif supply_fan.to_FanConstantVolume.is_initialized
          supply_fan = supply_fan.to_FanConstantVolume.get
          fan_minimum_flow_frac = 1.0
          fan_static_pressure = supply_fan.pressureRise
          fan_efficiency = supply_fan.fanTotalEfficiency
        elsif supply_fan.to_FanVariableVolume.is_initialized
          fan_var_vol = true
          supply_fan = supply_fan.to_FanVariableVolume.get
          fan_minimum_flow_frac = supply_fan.fanPowerMinimumFlowFraction
          fan_static_pressure = supply_fan.pressureRise
          fan_efficiency = supply_fan.fanTotalEfficiency
          if supply_fan.autosizedMaximumFlowRate.is_initialized
            des_flow_rate_m3_s = supply_fan.autosizedMaximumFlowRate.get
          elsif supply_fan.maximumFlowRate.is_initialized
            des_flow_rate_m3_s = supply_fan.maximumFlowRate.get
          else
            des_flow_rate_m3_s = -999 # placeholder if value can't be accessed
          end
        else
          runner.registerWarning("Supply Fan type not recognized for air loop hvac '#{air_loop_hvac.name}'.")
        end
      else
        runner.registerWarning("Supply Fan not available for air loop hvac '#{air_loop_hvac.name}'.") unless std.air_loop_hvac_unitary_system?(air_loop_hvac)
      end

      # record economizer details
      if air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized
        oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
        controller_oa = oa_system.getControllerOutdoorAir
        economizer_type = controller_oa.getEconomizerControlType
      else
        economizer_type = 'NoEconomizer'
      end
      economizer_high_limit_temperature_c = nil
      economizer_high_limit_enthalpy_j_per_kg = nil
      case economizer_type
      when 'NoEconomizer'
      when 'FixedDryBulb', 'FixedEnthalpy', 'DifferentialDryBulb', 'DifferentialEnthalpy'
        if controller_oa.getEconomizerMaximumLimitDryBulbTemperature.is_initialized
          economizer_high_limit_temperature_c = controller_oa.getEconomizerMaximumLimitDryBulbTemperature.get
        end
        if controller_oa.getEconomizerMaximumLimitEnthalpy.is_initialized
          economizer_high_limit_enthalpy_j_per_kg = controller_oa.getEconomizerMaximumLimitEnthalpy.get
        end
      else
        runner.registerWarning("Economizer type '#{economizer_type}' not supported by output measure.")
      end

      # record economizer statistics
      unless economizer_type == 'NoEconomizer'
        economizer_statistics << {
          air_loop_mass_flow_rate_kg_s: air_loop_mass_flow_rate_kg_s,
          economizer_type: economizer_type,
          economizer_high_limit_temperature_c: economizer_high_limit_temperature_c,
          economizer_high_limit_enthalpy_j_per_kg: economizer_high_limit_enthalpy_j_per_kg
        }
      end

      # Get airflow time series for average flow rate
      ts_ahu_ma_flow_rate_kg_s = sql.timeSeries(ann_env_pd, timeseries_timestep, 'Air System Mixed Air Mass Flow Rate', air_loop_hvac.name.to_s.upcase)
      ts_ahu_ma_flow_rate_kg_s_list = convert_timeseries_to_list(ts_ahu_ma_flow_rate_kg_s)

      unless ts_ahu_ma_flow_rate_kg_s_list.nil?
        average_non_zero_loop_mass_flow_kg_s = ts_ahu_ma_flow_rate_kg_s_list.reject(&:zero?).sum.to_f / ts_ahu_ma_flow_rate_kg_s_list.reject(&:zero?).count
      else
        average_non_zero_loop_mass_flow_kg_s = 0.0
      end

      # Add to weighted
      air_system_total_mass_flow_kg_s += air_loop_mass_flow_rate_kg_s
      air_system_total_oa_mass_flow_kg_s += air_loop_oa_mass_flow_rate_kg_s
      air_system_weighted_fan_power_minimum_flow_fraction += fan_minimum_flow_frac * air_loop_mass_flow_rate_kg_s
      air_system_weighted_fan_static_pressure += fan_static_pressure * air_loop_mass_flow_rate_kg_s
      air_system_weighted_fan_efficiency += fan_efficiency * air_loop_mass_flow_rate_kg_s
      if fan_var_vol && average_non_zero_loop_mass_flow_kg_s > 0.0
        air_system_total_vav_mass_flow_kg_s += average_non_zero_loop_mass_flow_kg_s # Track VAV airflow separately for Static Pressure Reset measure
        air_system_total_des_flow_rate_m3_s += des_flow_rate_m3_s
      end
    end

    # Convert design flow rate from volumetric to mass flow
    air_system_total_des_flow_rate_kg_s = air_system_total_des_flow_rate_m3_s * standard_air_density

    average_outdoor_air_fraction = air_system_total_mass_flow_kg_s > 0.0 ? air_system_total_oa_mass_flow_kg_s / air_system_total_mass_flow_kg_s : 0.0
    runner.registerValue('com_report_air_system_average_outdoor_air_fraction', average_outdoor_air_fraction)
    air_system_fan_power_minimum_flow_fraction = air_system_total_mass_flow_kg_s > 0.0 ? air_system_weighted_fan_power_minimum_flow_fraction / air_system_total_mass_flow_kg_s : 0.0
    runner.registerValue('com_report_air_system_fan_power_minimum_flow_fraction', air_system_fan_power_minimum_flow_fraction)
    air_system_fan_static_pressure = air_system_total_mass_flow_kg_s > 0.0 ? air_system_weighted_fan_static_pressure / air_system_total_mass_flow_kg_s : 0.0
    runner.registerValue('com_report_air_system_fan_static_pressure', air_system_fan_static_pressure, 'Pa')
    air_system_fan_total_efficiency = air_system_total_mass_flow_kg_s > 0.0 ? air_system_weighted_fan_efficiency / air_system_total_mass_flow_kg_s : 0.0
    runner.registerValue('com_report_air_system_fan_total_efficiency', air_system_fan_total_efficiency)
    air_system_vav_avg_flow_ratio = air_system_total_des_flow_rate_kg_s > 0.0 ? air_system_total_vav_mass_flow_kg_s.to_f / air_system_total_des_flow_rate_kg_s.to_f : -999

    # calculate economizer variables
    if economizer_statistics.empty?
      runner.registerValue('com_report_hvac_economizer_control_type', 'NoEconomizer')
    else
      economizer_type_hash = economizer_statistics.group_by { |e| e[:economizer_type] }
      economizer_area_m2 = economizer_statistics.sum { |e| e[:air_loop_mass_flow_rate_kg_s] }
      economizer_type_areas = economizer_type_hash.map { |x, y| [x, y.inject(0) { |sum, i| sum + i[:air_loop_mass_flow_rate_kg_s] }] }
      largest_economizer_type = economizer_type_areas.max_by { |k, v| v }
      runner.registerInfo("'#{largest_economizer_type[0]}' serves #{largest_economizer_type[1].round(0)} m^2, the most floor area of any economizer type, out of #{economizer_area_m2.round(0)} m^2 served by economizers and #{total_building_area_m2.round(0)} m^2 total building area.")
      runner.registerValue('com_report_hvac_economizer_control_type', largest_economizer_type[0])
    end

    temperature_limited_hash = economizer_statistics.reject { |e| e[:economizer_high_limit_temperature_c].nil? }
    enthalpy_limited_hash = economizer_statistics.reject { |e| e[:economizer_high_limit_enthalpy_j_per_kg].nil? }
    if temperature_limited_hash.empty?
      weighted_economizer_high_limit_temperature_c = -999
    else
      weighted_economizer_high_limit_temperature_c = 0.0
      weighted_economizer_high_limit_temperature_c_flow_rate_kg_s = 0.0
      temperature_limited_hash.each do |e|
        weighted_economizer_high_limit_temperature_c_flow_rate_kg_s += e[:air_loop_mass_flow_rate_kg_s]
        weighted_economizer_high_limit_temperature_c += e[:economizer_high_limit_temperature_c] * e[:air_loop_mass_flow_rate_kg_s]
      end
      weighted_economizer_high_limit_temperature_c /= weighted_economizer_high_limit_temperature_c_flow_rate_kg_s
    end
    if enthalpy_limited_hash.empty?
      weighted_economizer_high_limit_enthalpy_j_per_kg = -999
    else
      weighted_economizer_high_limit_enthalpy_j_per_kg = 0.0
      weighted_economizer_high_limit_enthalpy_j_per_flow_rate_kg_s = 0.0
      enthalpy_limited_hash.each do |e|
        weighted_economizer_high_limit_enthalpy_j_per_flow_rate_kg_s += e[:air_loop_mass_flow_rate_kg_s]
        weighted_economizer_high_limit_enthalpy_j_per_kg += e[:economizer_high_limit_enthalpy_j_per_kg] * e[:air_loop_mass_flow_rate_kg_s]
      end
      weighted_economizer_high_limit_enthalpy_j_per_kg /= weighted_economizer_high_limit_enthalpy_j_per_flow_rate_kg_s
    end
    runner.registerValue('com_report_hvac_economizer_high_limit_temperature_c', weighted_economizer_high_limit_temperature_c)
    runner.registerValue('com_report_hvac_economizer_high_limit_enthalpy_j_per_kg', weighted_economizer_high_limit_enthalpy_j_per_kg)

    # Zone HVAC properties
    zone_hvac_total_mass_flow_kg_s = 0.0
    zone_hvac_total_oa_mass_flow_kg_s = 0.0
    zone_hvac_fan_total_air_flow_m3_per_s = 0.0
    zone_hvac_weighted_fan_power_minimum_flow_fraction = 0.0
    zone_hvac_weighted_fan_static_pressure = 0.0
    zone_hvac_weighted_fan_efficiency = 0.0
    model.getZoneHVACComponents.sort.each do |zone_hvac_component|
      # Convert this to the actual class type
      has_fan = true
      is_unitary = false
      if zone_hvac_component.to_AirLoopHVACUnitarySystem.is_initialized
        zone_hvac =  zone_hvac_component.to_AirLoopHVACUnitarySystem.get
        is_unitary = true
      elsif zone_hvac_component.to_ZoneHVACFourPipeFanCoil.is_initialized
        zone_hvac =  zone_hvac_component.to_ZoneHVACFourPipeFanCoil.get
      elsif zone_hvac_component.to_ZoneHVACUnitHeater.is_initialized
        zone_hvac =  zone_hvac_component.to_ZoneHVACUnitHeater.get
      elsif zone_hvac_component.to_ZoneHVACUnitVentilator.is_initialized
        zone_hvac =  zone_hvac_component.to_ZoneHVACUnitVentilator.get
      elsif zone_hvac_component.to_ZoneHVACPackagedTerminalAirConditioner.is_initialized
        zone_hvac =  zone_hvac_component.to_ZoneHVACPackagedTerminalAirConditioner.get
      elsif zone_hvac_component.to_ZoneHVACPackagedTerminalHeatPump.is_initialized
        zone_hvac =  zone_hvac_component.to_ZoneHVACPackagedTerminalHeatPump.get
      elsif zone_hvac_component.to_ZoneHVACTerminalUnitVariableRefrigerantFlow.is_initialized
        zone_hvac =  zone_hvac_component.to_ZoneHVACTerminalUnitVariableRefrigerantFlow.get
      elsif zone_hvac_component.to_ZoneHVACWaterToAirHeatPump.is_initialized
        zone_hvac =  zone_hvac_component.to_ZoneHVACWaterToAirHeatPump.get
      elsif zone_hvac_component.to_ZoneHVACEnergyRecoveryVentilator.is_initialized
        zone_hvac = zone_hvac_component.to_ZoneHVACEnergyRecoveryVentilator.get
      elsif zone_hvac_component.to_ZoneHVACBaseboardConvectiveElectric.is_initialized
        zone_hvac = zone_hvac_component.to_ZoneHVACBaseboardConvectiveElectric.get
        has_fan = false
      elsif zone_hvac_component.to_ZoneHVACBaseboardConvectiveWater.is_initialized
        zone_hvac = zone_hvac_component.to_ZoneHVACBaseboardConvectiveWater.get
        has_fan = false
      elsif zone_hvac_component.to_ZoneHVACBaseboardRadiantConvectiveElectric.is_initialized
        zone_hvac = zone_hvac_component.to_ZoneHVACBaseboardRadiantConvectiveElectric.get
        has_fan = false
      elsif zone_hvac_component.to_ZoneHVACBaseboardRadiantConvectiveWater.is_initialized
        zone_hvac = zone_hvac_component.to_ZoneHVACBaseboardRadiantConvectiveWater.get
        has_fan = false
      else
        runner.registerWarning("Zone HVAC equipment '#{zone_hvac_component.name}' type is not supported in this reporting measure.")
        next
      end

      # Get fan properties
      if has_fan
        if is_unitary
          if zone_hvac.supplyFan.get.to_FanOnOff.is_initialized
            supply_fan = zone_hvac.supplyFan.get.to_FanOnOff.get
            fan_minimum_flow_frac = 1.0
            fan_static_pressure = supply_fan.pressureRise
            fan_efficiency = supply_fan.fanTotalEfficiency
          elsif zone_hvac.supplyFan.get.to_FanConstantVolume.is_initialized
            supply_fan = zone_hvac.supplyFan.get.to_FanConstantVolume.get
            fan_minimum_flow_frac = 1.0
            fan_static_pressure = supply_fan.pressureRise
            fan_efficiency = supply_fan.fanTotalEfficiency
          elsif zone_hvac.supplyFan.get.to_FanVariableVolume.is_initialized
            supply_fan = zone_hvac.supplyFan.get.to_FanVariableVolume.get
            fan_minimum_flow_frac = supply_fan.fanPowerMinimumFlowFraction
            fan_static_pressure = supply_fan.pressureRise
            fan_efficiency = supply_fan.fanTotalEfficiency
          end
        else
          if zone_hvac.supplyAirFan.to_FanOnOff.is_initialized
            supply_fan = zone_hvac.supplyAirFan.to_FanOnOff.get
            fan_minimum_flow_frac = 1.0
            fan_static_pressure = supply_fan.pressureRise
            fan_efficiency = supply_fan.fanTotalEfficiency
          elsif zone_hvac.supplyAirFan.to_FanConstantVolume.is_initialized
            supply_fan = zone_hvac.supplyAirFan.to_FanConstantVolume.get
            fan_minimum_flow_frac = 1.0
            fan_static_pressure = supply_fan.pressureRise
            fan_efficiency = supply_fan.fanTotalEfficiency
          elsif zone_hvac.supplyAirFan.to_FanVariableVolume.is_initialized
            supply_fan = zone_hvac.supplyAirFan.to_FanVariableVolume.get
            fan_minimum_flow_frac = supply_fan.fanPowerMinimumFlowFraction
            fan_static_pressure = supply_fan.pressureRise
            fan_efficiency = supply_fan.fanTotalEfficiency
          end
        end

        # Get the maximum flow rate through the fan
        if supply_fan.autosizedMaximumFlowRate.is_initialized
          max_air_flow_rate_m3_per_s = supply_fan.autosizedMaximumFlowRate.get
        elsif supply_fan.maximumFlowRate.is_initialized
          max_air_flow_rate_m3_per_s = supply_fan.maximumFlowRate.get
        else
          runner.registerWarning("Zone HVAC equipment '#{zone_hvac_component.name}' fan '#{supply_fan.name}' flow rate is not initialized.")
          next
        end

        # add to weighted
        zone_hvac_fan_total_air_flow_m3_per_s += max_air_flow_rate_m3_per_s
        zone_hvac_weighted_fan_power_minimum_flow_fraction += fan_minimum_flow_frac * max_air_flow_rate_m3_per_s
        zone_hvac_weighted_fan_static_pressure += fan_static_pressure * max_air_flow_rate_m3_per_s
        zone_hvac_weighted_fan_efficiency += fan_efficiency * max_air_flow_rate_m3_per_s
      end

      # cast zone_hvac_component down to its child object
      obj_type = zone_hvac_component.iddObjectType.valueName
      obj_type_name = obj_type.gsub('OS_', '').gsub('_', '')
      method_name = "to_#{obj_type_name}"
      if zone_hvac_component.respond_to?(method_name)
        actual_zone_hvac = zone_hvac_component.method(method_name).call
        if !actual_zone_hvac.empty?
          actual_zone_hvac = actual_zone_hvac.get
        end
      end

      oa_node_exists = false
      next if actual_zone_hvac.airLoopHVAC.is_initialized || !actual_zone_hvac.respond_to?('supplyAirFan')

      base_obj_name = actual_zone_hvac.name.get
      outlet_node = actual_zone_hvac.outletNode.get
      zone_equip_mass_flow_rate_kg_s = sql_get_report_variable_data_double(runner, sql, outlet_node, 'System Node Mass Flow Rate')
      if actual_zone_hvac.respond_to?('outdoorAirMixerName')
        oa_node_exists = true
        oa_node = "#{base_obj_name} OA Node"
      elsif actual_zone_hvac.respond_to?('vrfSystem')
        oa_node_exists = true
        oa_node = "#{base_obj_name} Outdoor Air Node"
      end

      if oa_node_exists
        zone_equip_oa_mass_flow_rate_kg_s = sql_get_report_variable_data_double(runner, sql, oa_node, 'System Node Mass Flow Rate')
      else
        zone_equip_oa_mass_flow_rate_kg_s = 0.0
      end

      # add to weighted
      zone_hvac_total_mass_flow_kg_s += zone_equip_mass_flow_rate_kg_s
      zone_hvac_total_oa_mass_flow_kg_s += zone_equip_oa_mass_flow_rate_kg_s
    end

    runner.registerValue('com_report_zone_hvac_total_mass_flow_rate', zone_hvac_total_mass_flow_kg_s, 'kg/s')
    runner.registerValue('com_report_air_sys_vav_avg_flow_ratio', air_system_vav_avg_flow_ratio)
    runner.registerValue('com_report_zone_hvac_total_outdoor_air_mass_flow_rate', zone_hvac_total_oa_mass_flow_kg_s, 'kg/s')
    zone_hvac_average_outdoor_air_fraction = zone_hvac_total_mass_flow_kg_s > 0.0 ? zone_hvac_total_oa_mass_flow_kg_s / zone_hvac_total_mass_flow_kg_s : 0.0
    runner.registerValue('com_report_zone_hvac_average_outdoor_air_fraction', zone_hvac_average_outdoor_air_fraction)
    zone_hvac_fan_power_minimum_flow_fraction = zone_hvac_fan_total_air_flow_m3_per_s > 0.0 ? zone_hvac_weighted_fan_power_minimum_flow_fraction / zone_hvac_fan_total_air_flow_m3_per_s : 0.0
    runner.registerValue('com_report_zone_hvac_fan_power_minimum_flow_fraction', zone_hvac_fan_power_minimum_flow_fraction)
    zone_hvac_fan_static_pressure = zone_hvac_fan_total_air_flow_m3_per_s > 0.0 ? zone_hvac_weighted_fan_static_pressure / zone_hvac_fan_total_air_flow_m3_per_s : 0.0
    runner.registerValue('com_report_zone_hvac_fan_static_pressure', zone_hvac_fan_static_pressure, 'Pa')
    zone_hvac_fan_total_efficiency = zone_hvac_fan_total_air_flow_m3_per_s > 0.0 ? zone_hvac_weighted_fan_efficiency / zone_hvac_fan_total_air_flow_m3_per_s : 0.0
    runner.registerValue('com_report_zone_hvac_fan_total_efficiency', zone_hvac_fan_total_efficiency)
    total_building_avg_mass_flow_rate_kg_s = zone_hvac_total_mass_flow_kg_s + air_system_total_mass_flow_kg_s
    runner.registerValue('com_report_total_building_average_mass_flow_rate', total_building_avg_mass_flow_rate_kg_s, 'kg/s')
    total_building_avg_oa_mass_flow_rate_kg_s = zone_hvac_total_oa_mass_flow_kg_s + air_system_total_oa_mass_flow_kg_s
    runner.registerValue('com_report_total_building_average_oa_mass_flow_rate', total_building_avg_oa_mass_flow_rate_kg_s, 'kg/s')
    total_building_avg_oa_fraction = total_building_avg_oa_mass_flow_rate_kg_s / total_building_avg_mass_flow_rate_kg_s
    runner.registerValue('com_report_total_building_average_outdoor_air_fraction', total_building_avg_oa_fraction)

    # Collect pump specifications
    all_pumps = []

    # Helper method to classify plant loop type
    def system_type_for(pump)
      loop = pump.plantLoop
      return :unknown unless loop.is_initialized

      plant_loop = loop.get
      if plant_loop.supplyComponents.any? do |comp|
          comp.to_WaterHeaterMixed.is_initialized || comp.to_WaterHeaterStratified.is_initialized
        end
        :swh  # Service Water Heating
      else
        :hvac  # Space Heating/Cooling
      end
    end

    # Constant speed pumps
    model.getPumpConstantSpeeds.each do |pump|
      flow = pump.ratedFlowRate.is_initialized ? pump.ratedFlowRate.get : nil
      eff  = pump.motorEfficiency
      sys  = system_type_for(pump)

      all_pumps << {
        pump: pump,
        flow: flow,
        efficiency: eff,
        type: :constant,
        system: sys
      }
    end

    # Variable speed pumps
    model.getPumpVariableSpeeds.each do |pump|
      flow = pump.ratedFlowRate.is_initialized ? pump.ratedFlowRate.get : nil
      eff  = pump.motorEfficiency
      sys  = system_type_for(pump)

      all_pumps << {
        pump: pump,
        flow: flow,
        efficiency: eff,
        type: :variable,
        system: sys
      }
    end

    # Rated-flow-weighted motor efficiency (overall)
    total_flow = all_pumps.sum { |p| p[:flow].to_f }
    weighted_eff_sum = all_pumps.sum { |p| p[:flow].to_f * p[:efficiency] }

    avg_eff = total_flow.positive? ? weighted_eff_sum / total_flow : 0.0
    runner.registerValue('com_report_pump_flow_weighted_avg_motor_efficiency', avg_eff)

    # Rated-flow-weighted motor efficiency by type
    const_pumps = all_pumps.select { |p| p[:type] == :constant }
    var_pumps   = all_pumps.select { |p| p[:type] == :variable }

    const_flow = const_pumps.sum { |p| p[:flow].to_f }
    var_flow   = var_pumps.sum   { |p| p[:flow].to_f }

    const_eff_sum = const_pumps.sum { |p| p[:flow].to_f * p[:efficiency] }
    var_eff_sum   = var_pumps.sum   { |p| p[:flow].to_f * p[:efficiency] }

    avg_eff_const = const_flow.positive? ? const_eff_sum / const_flow : 0.0
    avg_eff_var   = var_flow.positive? ? var_eff_sum / var_flow : 0.0

    runner.registerValue(
      'com_report_pump_flow_weighted_avg_motor_efficiency_const_spd', avg_eff_const
    )
    runner.registerValue(
      'com_report_pump_flow_weighted_avg_motor_efficiency_var_spd', avg_eff_var
    )

    # Pump counts by system and type
    hvac_pumps = all_pumps.select { |p| p[:system] == :hvac }
    swh_pumps  = all_pumps.select { |p| p[:system] == :swh }

    hvac_const = hvac_pumps.count { |p| p[:type] == :constant }
    hvac_var   = hvac_pumps.count { |p| p[:type] == :variable }
    swh_const  = swh_pumps.count  { |p| p[:type] == :constant }
    swh_var    = swh_pumps.count  { |p| p[:type] == :variable }

    runner.registerValue('com_report_pump_count_hvac_const_spd', hvac_const)
    runner.registerValue('com_report_pump_count_hvac_var_spd',   hvac_var)
    runner.registerValue('com_report_pump_count_swh_const_spd',  swh_const)
    runner.registerValue('com_report_pump_count_swh_var_spd',    swh_var)

    # Total rated power
    total_const_pwr_w = model.getPumpConstantSpeeds.sum do |pump|
      pump.ratedPowerConsumption.is_initialized ? pump.ratedPowerConsumption.get : 0.0
    end

    total_var_pwr_w = model.getPumpVariableSpeeds.sum do |pump|
      pump.ratedPowerConsumption.is_initialized ? pump.ratedPowerConsumption.get : 0.0
    end

    runner.registerValue(
      'com_report_pump_total_constant_speed_pump_power_w', total_const_pwr_w, 'W'
    )
    runner.registerValue(
      'com_report_pump_total_variable_speed_pump_power_w', total_var_pwr_w, 'W'
    )

    # calculate building heating and cooling
    building_heated_zone_area_m2 = 0.0
    building_cooled_zone_area_m2 = 0.0
    building_zone_area_m2 = 0.0
    model.getThermalZones.sort.each do |zone|
      building_zone_area_m2 += zone.floorArea * zone.multiplier
      building_heated_zone_area_m2 += zone.floorArea * zone.multiplier if OpenstudioStandards::ThermalZone.thermal_zone_heated?(zone)
      building_cooled_zone_area_m2 += zone.floorArea * zone.multiplier if OpenstudioStandards::ThermalZone.thermal_zone_cooled?(zone)
    end

    # Fraction of building heated
    building_fraction_heated = building_heated_zone_area_m2 / building_zone_area_m2
    runner.registerValue('com_report_building_fraction_heated', building_fraction_heated)

    # Fraction of building cooled
    building_fraction_cooled = building_cooled_zone_area_m2 / building_zone_area_m2
    runner.registerValue('com_report_building_fraction_cooled', building_fraction_cooled)

    # Derive building-wide area weighted averages for heating and cooling minimum and maximum thermostat schedule values
    weighted_thermostat_heating_min_c = 0.0
    weighted_thermostat_heating_max_c = 0.0
    weighted_thermostat_heating_area_m2 = 0.0
    weighted_thermostat_cooling_min_c = 0.0
    weighted_thermostat_cooling_max_c = 0.0
    weighted_thermostat_cooling_area_m2 = 0.0
    zones_with_htg_setbacks = []
    zones_with_clg_setbacks = []
    zones_htg_tstats = [] # Zones with heating thermostats
    zones_clg_tstats = [] # Zones with cooling thermostats
    has_clg_setback_all_tstats = false
    has_htg_setback_all_tstats = false
    at_least_one_clg_setback = false # At least one zone with a cooling setback
    at_least_one_htg_setback = false # At least one zone with a heating setback

    model.getThermalZones.sort.each do |zone|
      next unless zone.thermostatSetpointDualSetpoint.is_initialized

      floor_area_m2 = zone.floorArea * zone.multiplier
      thermostat = zone.thermostatSetpointDualSetpoint.get
      if thermostat.heatingSetpointTemperatureSchedule.is_initialized
        thermostat_heating_schedule = thermostat.heatingSetpointTemperatureSchedule.get
        zones_htg_tstats << zone
        if thermostat_heating_schedule.to_ScheduleRuleset.is_initialized
          thermostat_heating_schedule = thermostat_heating_schedule.to_ScheduleRuleset.get
          htg_min_max = OpenstudioStandards::Schedules.schedule_ruleset_get_min_max(thermostat_heating_schedule)
          if htg_min_max['max'] > htg_min_max['min']
            zones_with_htg_setbacks << zone # Add to list of zones with setbacks
            at_least_one_htg_setback = true
          end
          weighted_thermostat_heating_min_c += htg_min_max['min'] * floor_area_m2
          weighted_thermostat_heating_max_c += htg_min_max['max'] * floor_area_m2
          weighted_thermostat_heating_area_m2 += floor_area_m2
        elsif thermostat_heating_schedule.to_ScheduleInterval.is_initialized
          thermostat_heating_schedule = thermostat_heating_schedule.to_ScheduleInterval.get
          ts = thermostat_heating_schedule.timeSeries
          interval_values_array = ts.values
          if interval_values_array.max > interval_values_array.min
            zones_with_htg_setbacks << zone # Add to list of zones with setbacks
            at_least_one_htg_setback = true
          end
          weighted_thermostat_heating_min_c += interval_values_array.min * floor_area_m2
          weighted_thermostat_heating_max_c += interval_values_array.max * floor_area_m2
          weighted_thermostat_heating_area_m2 += floor_area_m2
        end
        # next unless thermostat_heating_schedule.to_ScheduleRuleset.is_initialized
        # thermostat_heating_schedule = thermostat_heating_schedule.to_ScheduleRuleset.get
        # heat_min_max = OpenstudioStandards::Schedules.schedule_ruleset_get_min_max(thermostat_heating_schedule)
        # weighted_thermostat_heating_min_c += heat_min_max['min'] * floor_area_m2
        # weighted_thermostat_heating_max_c += heat_min_max['max'] * floor_area_m2
        # weighted_thermostat_heating_area_m2 += floor_area_m2
      end
      if thermostat.coolingSetpointTemperatureSchedule.is_initialized
        zones_clg_tstats << zone
        thermostat_cooling_schedule = thermostat.coolingSetpointTemperatureSchedule.get
        if thermostat_cooling_schedule.to_ScheduleRuleset.is_initialized
          thermostat_cooling_schedule = thermostat_cooling_schedule.to_ScheduleRuleset.get
          cool_min_max = OpenstudioStandards::Schedules.schedule_ruleset_get_min_max(thermostat_cooling_schedule)
          weighted_thermostat_cooling_min_c += cool_min_max['min'] * floor_area_m2
          weighted_thermostat_cooling_max_c += cool_min_max['max'] * floor_area_m2
          weighted_thermostat_cooling_area_m2 += floor_area_m2
          if cool_min_max['max'] > cool_min_max['min']
            zones_with_clg_setbacks << zone # Add to list of zones with setbacks
            at_least_one_clg_setback = true
          end
        elsif thermostat_cooling_schedule.to_ScheduleInterval.is_initialized
          thermostat_cooling_schedule = thermostat_cooling_schedule.to_ScheduleInterval.get
          ts = thermostat_cooling_schedule.timeSeries
          interval_values_array = ts.values
          if interval_values_array.max > interval_values_array.min
            zones_with_clg_setbacks << zone # Add to list of zones with setbacks
            at_least_one_clg_setback = true
          end
          weighted_thermostat_cooling_min_c += interval_values_array.min * floor_area_m2
          weighted_thermostat_cooling_max_c += interval_values_array.max * floor_area_m2
          weighted_thermostat_cooling_area_m2 += floor_area_m2
        end
      end
    end

    # Set setback variable reporting
    if zones_with_clg_setbacks & zones_clg_tstats == zones_clg_tstats
      has_clg_setback_all_tstats = true
    else
      has_clg_setback_all_tstats = false
    end

    if zones_with_htg_setbacks & zones_htg_tstats == zones_htg_tstats
      has_htg_setback_all_tstats = true
    else
      has_htg_setback_all_tstats = false
    end

    runner.registerValue('com_report_has_htg_setback_all_tstats', has_htg_setback_all_tstats)
    runner.registerValue('com_report_has_clg_setback_all_tstats', has_clg_setback_all_tstats)
    runner.registerValue('com_report_has_at_least_one_htg_setback', at_least_one_htg_setback)
    runner.registerValue('com_report_has_at_least_one_clg_setback', at_least_one_clg_setback)

    # Thermostat heating setpoint minimum and maximum
    if weighted_thermostat_heating_area_m2 > 0.0
      average_heating_setpoint_min_c = weighted_thermostat_heating_min_c / weighted_thermostat_heating_area_m2
      average_heating_setpoint_max_c = weighted_thermostat_heating_max_c / weighted_thermostat_heating_area_m2
      runner.registerValue('com_report_average_heating_setpoint_min_c', average_heating_setpoint_min_c, 'C')
      runner.registerValue('com_report_average_heating_setpoint_max_c', average_heating_setpoint_max_c, 'C')
    end

    # Thermostat cooling setpoint minimum and maximum
    if weighted_thermostat_cooling_area_m2 > 0.0
      average_cooling_setpoint_min_c = weighted_thermostat_cooling_min_c / weighted_thermostat_cooling_area_m2
      average_cooling_setpoint_max_c = weighted_thermostat_cooling_max_c / weighted_thermostat_cooling_area_m2
      runner.registerValue('com_report_average_cooling_setpoint_min_c', average_cooling_setpoint_min_c, 'C')
      runner.registerValue('com_report_average_cooling_setpoint_max_c', average_cooling_setpoint_max_c, 'C')
    end

    # calculate fraction of building area with different air loop features
    number_of_air_loops = 0.0
    number_of_air_loops_with_dcv = 0.0
    number_of_air_loops_with_economizer = 0.0
    number_of_air_loops_with_heat_recovery = 0.0
    building_area_with_dcv_m2 = 0.0
    building_area_with_economizer_m2 = 0.0
    building_area_with_heat_recovery_m2 = 0.0
    building_area_with_motorized_oa_damper_m2 = 0.0
    building_area_with_mz_vav_optimization_m2 = 0.0
    building_area_with_supply_air_temperature_reset_m2 = 0.0
    building_area_with_unoccupied_shutdown_m2 = 0.0
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      has_economizer = false
      has_dcv = false
      has_mz_vav_optimization = false
      has_supply_air_temp_reset = false
      has_unoccupied_shutdown = false
      has_motorized_oa_damper = false

      # fraction with heat recovery
      has_heat_recovery = std.air_loop_hvac_energy_recovery?(air_loop_hvac)

      # fraction with DCV and economizer
      if air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized
        oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
        controller_oa = oa_system.getControllerOutdoorAir
        economizer_type = controller_oa.getEconomizerControlType
        controller_oa = oa_system.getControllerOutdoorAir
        controller_mv = controller_oa.controllerMechanicalVentilation
        has_economizer = true unless economizer_type == 'NoEconomizer'
        has_dcv = true if controller_mv.demandControlledVentilation == true
        if controller_oa.minimumOutdoorAirSchedule.is_initialized
          min_oa_sch = controller_oa.minimumOutdoorAirSchedule.get
          has_motorized_oa_damper = true unless min_oa_sch == model.alwaysOnDiscreteSchedule
        end
        if std.air_loop_hvac_multizone_vav_system?(air_loop_hvac)
          oa_method = controller_mv.systemOutdoorAirMethod
          has_mz_vav_optimization = true if oa_method.include?('VentilationRateProcedure')
        end
      end

      # SAT reset
      oa_node = air_loop_hvac.supplyOutletNode
      oa_node.setpointManagers.each do |spm|
        if spm.to_SetpointManagerWarmest.is_initialized
          has_supply_air_temp_reset = true
        end
      end

      # unoccupied shutdown
      has_unoccupied_shutdown = true unless air_loop_hvac.availabilitySchedule == model.alwaysOnDiscreteSchedule

      # air loop area
      air_loop_area_m2 = 0.0
      air_loop_hvac.thermalZones.sort.each do |zone|
        air_loop_area_m2 += zone.floorArea * zone.multiplier
      end

      number_of_air_loops += 1.0
      number_of_air_loops_with_dcv += 1.0 if has_dcv
      number_of_air_loops_with_economizer += 1.0 if has_economizer
      number_of_air_loops_with_heat_recovery += 1.0 if has_heat_recovery
      building_area_with_dcv_m2 += air_loop_area_m2 if has_dcv
      building_area_with_economizer_m2 += air_loop_area_m2 if has_economizer
      building_area_with_heat_recovery_m2 += air_loop_area_m2 if has_heat_recovery
      building_area_with_motorized_oa_damper_m2 += air_loop_area_m2 if has_motorized_oa_damper
      building_area_with_mz_vav_optimization_m2 += air_loop_area_m2 if has_mz_vav_optimization
      building_area_with_supply_air_temperature_reset_m2 += air_loop_area_m2 if has_supply_air_temp_reset
      building_area_with_unoccupied_shutdown_m2 += air_loop_area_m2 if has_unoccupied_shutdown
    end
    building_area_fraction_with_dcv = building_area_with_dcv_m2 / building_zone_area_m2
    building_area_fraction_with_economizer = building_area_with_economizer_m2 / building_zone_area_m2
    building_area_fraction_with_heat_recovery = building_area_with_heat_recovery_m2 / building_zone_area_m2
    building_area_fraction_with_motorized_oa_damper = building_area_with_motorized_oa_damper_m2 / building_zone_area_m2
    building_area_fraction_with_mz_vav_optimization = building_area_with_mz_vav_optimization_m2 / building_zone_area_m2
    building_area_fraction_with_supply_air_temperature_reset = building_area_with_supply_air_temperature_reset_m2 / building_zone_area_m2
    building_area_fraction_with_unoccupied_shutdown = building_area_with_unoccupied_shutdown_m2 / building_zone_area_m2
    runner.registerValue('com_report_hvac_number_of_air_loops', number_of_air_loops)
    runner.registerValue('com_report_hvac_number_of_air_loops_with_dcv', number_of_air_loops_with_dcv)
    runner.registerValue('com_report_hvac_number_of_air_loops_with_economizer', number_of_air_loops_with_economizer)
    runner.registerValue('com_report_hvac_number_of_air_loops_with_heat_recovery', number_of_air_loops_with_heat_recovery)
    runner.registerValue('com_report_hvac_area_fraction_with_dcv', building_area_fraction_with_dcv)
    runner.registerValue('com_report_hvac_area_fraction_with_economizer', building_area_fraction_with_economizer)
    runner.registerValue('com_report_hvac_area_fraction_with_heat_recovery', building_area_fraction_with_heat_recovery)
    runner.registerValue('com_report_hvac_area_fraction_with_motorized_oa_damper', building_area_fraction_with_motorized_oa_damper)
    runner.registerValue('com_report_hvac_area_fraction_with_mz_vav_optimization', building_area_fraction_with_mz_vav_optimization)
    runner.registerValue('com_report_hvac_area_fraction_with_supply_air_temperature_reset', building_area_fraction_with_supply_air_temperature_reset)
    runner.registerValue('com_report_hvac_area_fraction_with_unoccupied_shutdown', building_area_fraction_with_unoccupied_shutdown)

    # VRF variables
    vrf_indoor_unit_count = 0.0
    vrf_outdoor_unit_count = 0.0
    total_vrf_area_m2 = 0.0
    weighted_vrf_num_compressors = 0.0
    weighted_vrf_length_m = 0.0
    weighted_vrf_height_m = 0.0
    vrf_total_indoor_unit_cooling_capacity_w = 0.0
    vrf_total_indoor_unit_heating_capacity_w = 0.0
    vrf_area_weighted_indoor_unit_cooling_capacity_w = 0.0
    vrf_area_weighted_indoor_unit_heating_capacity_w = 0.0
    vrf_total_outdoor_unit_cooling_capacity_w = 0.0
    vrf_total_outdoor_unit_heating_capacity_w = 0.0
    vrf_area_weighted_outdoor_unit_cooling_capacity_w = 0.0
    vrf_area_weighted_outdoor_unit_heating_capacity_w = 0.0
    vrf_total_cooling_load_j = 0.0
    vrf_total_heating_load_j = 0.0
    vrf_total_heat_recovery_j = 0.0
    vrf_total_cooling_electric_j = 0.0
    vrf_total_heating_electric_j = 0.0
    vrf_total_heating_total_input_energy_j = 0.0
    vrf_total_heating_defrost_energy_j = 0.0
    vrf_total_heating_supplemental_load_j = 0.0
    vrf_total_heating_supplemental_load_electric_j = 0.0
    vrf_total_heating_supplemental_load_gas_j = 0.0
    vrf_total_heating_supplemental_electric_j = 0.0
    vrf_total_heating_supplemental_gas_j = 0.0
    vrf_cooling_load_weighted_cop = 0.0
    vrf_heating_load_weighted_cop = 0.0
    vrf_heating_load_weighted_total_cop = 0.0
    vrf_cooling_load_weighted_design_cop = 0.0
    vrf_heating_load_weighted_design_cop = 0.0
    vrf_cooling_load_weighted_design_cop_35F = 0.0
    vrf_cooling_load_weighted_design_cop_60F = 0.0
    vrf_cooling_load_weighted_design_cop_85F = 0.0
    vrf_cooling_load_weighted_design_cop_110F = 0.0
    vrf_heating_load_weighted_design_cop_minus22F = 0.0
    vrf_heating_load_weighted_design_cop_0F = 0.0
    vrf_heating_load_weighted_design_cop_20F = 0.0
    vrf_heating_load_weighted_design_cop_40F = 0.0
    vrf_heating_largest_load_performance_curve_temperature_type = ''
    vrf_largest_heating_load_served_j = 0.0
    model.getAirConditionerVariableRefrigerantFlows.sort.each do |vrf|
      # area served
      vrf_area_m2 = 0.0
      vrf_cooling_load_j = 0.0
      vrf_heating_load_j = 0.0
      indoor_unit_cooling_capacity_w = 0.0
      indoor_unit_heating_capacity_w = 0.0
      vrf.terminals.each do |terminal|
        if terminal.thermalZone.is_initialized
          zone = terminal.thermalZone.get
          vrf_area_m2 += zone.floorArea * zone.multiplier
        end

        # get terminal cooling capacity
        cooling_coil = terminal.coolingCoil
        if cooling_coil.is_initialized
          cooling_coil = cooling_coil.get
          if cooling_coil.to_CoilCoolingDXVariableRefrigerantFlow.is_initialized
            cooling_coil = cooling_coil.to_CoilCoolingDXVariableRefrigerantFlow.get
            if cooling_coil.ratedTotalCoolingCapacity.is_initialized
              indoor_unit_cooling_capacity_w += cooling_coil.ratedTotalCoolingCapacity.get
            elsif cooling_coil.autosizedRatedTotalCoolingCapacity.is_initialized
              indoor_unit_cooling_capacity_w += cooling_coil.autosizedRatedTotalCoolingCapacity.get
            else
              runner.registerWarning("VRF terminal cooling capacity not available for vrf terminal '#{terminal.name}'.")
            end
          elsif cooling_coil.to_CoilCoolingDXVariableRefrigerantFlowFluidTemperatureControl.is_initialized
            cooling_coil = cooling_coil.to_CoilCoolingDXVariableRefrigerantFlowFluidTemperatureControl.get
            if cooling_coil.ratedTotalCoolingCapacity.is_initialized
              indoor_unit_cooling_capacity_w += cooling_coil.ratedTotalCoolingCapacity.get
            elsif cooling_coil.autosizedRatedTotalCoolingCapacity.is_initialized
              indoor_unit_cooling_capacity_w += cooling_coil.autosizedRatedTotalCoolingCapacity.get
            else
              runner.registerWarning("VRF terminal cooling capacity not available for vrf terminal '#{terminal.name}'.")
            end
          else
            runner.registerWarning("Zone VRF terminal '#{terminal.name}' cooling coil '#{cooling_coil.name}' type not recognized.")
          end
        end

        # get terminal heating capacity
        heating_coil = terminal.heatingCoil
        if heating_coil.is_initialized
          heating_coil = heating_coil.get
          if heating_coil.to_CoilHeatingDXVariableRefrigerantFlow.is_initialized
            heating_coil = heating_coil.to_CoilHeatingDXVariableRefrigerantFlow.get
            if heating_coil.ratedTotalHeatingCapacity.is_initialized
              indoor_unit_heating_capacity_w += heating_coil.ratedTotalHeatingCapacity.get
            elsif heating_coil.autosizedRatedTotalHeatingCapacity.is_initialized
              indoor_unit_heating_capacity_w += heating_coil.autosizedRatedTotalHeatingCapacity.get
            else
              runner.registerWarning("VRF terminal heating capacity not available for vrf terminal '#{terminal.name}'.")
            end
          elsif heating_coil.to_CoilHeatingDXVariableRefrigerantFlowFluidTemperatureControl.is_initialized
            heating_coil = heating_coil.to_CoilHeatingDXVariableRefrigerantFlowFluidTemperatureControl.get
            if heating_coil.ratedTotalHeatingCapacity.is_initialized
              indoor_unit_heating_capacity_w += heating_coil.ratedTotalHeatingCapacity.get
            elsif heating_coil.autosizedRatedTotalHeatingCapacity.is_initialized
              indoor_unit_heating_capacity_w += heating_coil.autosizedRatedTotalHeatingCapacity.get
            else
              runner.registerWarning("VRF terminal heating capacity not available for vrf terminal '#{terminal.name}'.")
            end
          else
            runner.registerWarning("Zone VRF terminal '#{terminal.name}' heating coil '#{heating_coil.name}' type not recognized.")
          end
        end

        # get terminal supplemental heating coil energy
        supplemental_coil_heating_energy_j = 0.0
        supplemental_electric_j = 0.0
        supplemental_gas_j = 0.0
        if terminal.supplementalHeatingCoil.is_initialized
          supplemental_coil = terminal.supplementalHeatingCoil.get

          # supplemental heating coil heating energy
          supplemental_coil_heating_energy_j = sql_get_report_variable_data_double(runner, sql, supplemental_coil, 'Heating Coil Heating Energy')

          # supplemental heating coil electric or gas energy
          if supplemental_coil.to_CoilHeatingElectric.is_initialized
            # supplemental load is sourced from electric
            vrf_total_heating_supplemental_load_electric_j += supplemental_coil_heating_energy_j

            supplemental_coil = supplemental_coil.to_CoilHeatingElectric.get
            supplemental_electric_j = sql_get_report_variable_data_double(runner, sql, supplemental_coil, "Heating Coil #{elec} Energy")

          elsif supplemental_coil.to_CoilHeatingGas.is_initialized
            # supplemental load is sourced from gas
            vrf_total_heating_supplemental_load_gas_j += supplemental_coil_heating_energy_j

            supplemental_coil = supplemental_coil.to_CoilHeatingGas.get
            supplemental_gas_j = sql_get_report_variable_data_double(runner, sql, supplemental_coil, "Heating Coil #{gas} Energy")
          else
            runner.registerWarning("Unrecognized coil type for vrf indoor unit supplemntal heating coil #{supplemental_coil.name}.")
          end

          vrf_total_heating_supplemental_load_j += supplemental_coil_heating_energy_j
          vrf_total_heating_supplemental_electric_j += supplemental_electric_j
          vrf_total_heating_supplemental_gas_j += supplemental_gas_j
        end

        # get Zone VRF Air Terminal Total Cooling Energy
        terminal_cooling_load_j = sql_get_report_variable_data_double(runner, sql, terminal, 'Zone VRF Air Terminal Total Cooling Energy')
        vrf_cooling_load_j += terminal_cooling_load_j

        # get Zone VRF Air Terminal Total Heating Energy
        terminal_heating_load_j = sql_get_report_variable_data_double(runner, sql, terminal, 'Zone VRF Air Terminal Total Heating Energy')
        vrf_heating_load_j += terminal_heating_load_j
      end
      total_vrf_area_m2 += vrf_area_m2
      vrf_total_indoor_unit_cooling_capacity_w += indoor_unit_cooling_capacity_w
      vrf_area_weighted_indoor_unit_cooling_capacity_w += indoor_unit_cooling_capacity_w * total_vrf_area_m2
      vrf_total_indoor_unit_heating_capacity_w += indoor_unit_heating_capacity_w
      vrf_area_weighted_indoor_unit_heating_capacity_w += indoor_unit_heating_capacity_w * total_vrf_area_m2

      # record equipment counts
      vrf_outdoor_unit_count += 1.0
      vrf_indoor_unit_count += vrf.terminals.size

      # record number of compressors and pipe lengths
      vrf_num_compressors = vrf.numberofCompressors
      vrf_length_m = vrf.equivalentPipingLengthusedforPipingCorrectionFactorinCoolingMode
      vrf_height_m = vrf.verticalHeightusedforPipingCorrectionFactor
      weighted_vrf_num_compressors += vrf_num_compressors * vrf_area_m2
      weighted_vrf_length_m += vrf_length_m * vrf_area_m2
      weighted_vrf_height_m += vrf_height_m * vrf_area_m2

      # get rated heating and cooling capacity
      outdoor_unit_cooling_capacity_w = 0.0
      if vrf.grossRatedTotalCoolingCapacity.is_initialized
        outdoor_unit_cooling_capacity_w = vrf.grossRatedTotalCoolingCapacity.get
      elsif vrf.autosizedGrossRatedTotalCoolingCapacity.is_initialized
        outdoor_unit_cooling_capacity_w = vrf.autosizedGrossRatedTotalCoolingCapacity.get
      else
        runner.registerWarning("VRF cooling capacity not available for vrf '#{vrf.name}'.")
      end
      vrf_total_outdoor_unit_cooling_capacity_w += outdoor_unit_cooling_capacity_w
      vrf_area_weighted_outdoor_unit_cooling_capacity_w += outdoor_unit_cooling_capacity_w * total_vrf_area_m2

      outdoor_unit_heating_capacity_w = 0.0
      if vrf.grossRatedHeatingCapacity.is_initialized
        outdoor_unit_heating_capacity_w = vrf.grossRatedHeatingCapacity.get
      elsif vrf.autosizedGrossRatedHeatingCapacity.is_initialized
        outdoor_unit_heating_capacity_w = vrf.autosizedGrossRatedHeatingCapacity.get
      else
        runner.registerWarning("VRF heating capacity not available for vrf '#{vrf.name}'.")
      end
      vrf_total_outdoor_unit_heating_capacity_w += outdoor_unit_heating_capacity_w
      vrf_area_weighted_outdoor_unit_heating_capacity_w += outdoor_unit_heating_capacity_w * total_vrf_area_m2

      # get VRF Heat Pump Cooling Electricity Energy
      vrf_cooling_electric_j = sql_get_report_variable_data_double(runner, sql, vrf, 'VRF Heat Pump Cooling Electricity Energy')

      # get VRF Heat Pump Heating Electricity Energy
      vrf_heating_electric_j = sql_get_report_variable_data_double(runner, sql, vrf, 'VRF Heat Pump Heating Electricity Energy')

      # get VRF Heat Pump Defrost Electricity Energy
      vrf_defrost_electric_j = sql_get_report_variable_data_double(runner, sql, vrf, 'VRF Heat Pump Defrost Electricity Energy')

      # get VRF Heat Pump Crankcase Heater Electricity Energy
      vrf_crankcase_electric_j = sql_get_report_variable_data_double(runner, sql, vrf, 'VRF Heat Pump Crankcase Heater Electricity Energy')

      # get VRF Heat Pump Heat Recovery Energy
      vrf_heat_recovery_j = sql_get_report_variable_data_double(runner, sql, vrf, 'VRF Heat Pump Heat Recovery Energy')

      # VRF design cops
      vrf_cooling_design_cop = vrf.grossRatedCoolingCOP
      vrf_heating_design_cop = vrf.ratedHeatingCOP

      # AHRI Standard 1230
      # Performance Rating of Variable Refrigerant Flow (VRF) Multi-split Air-conditioning and Heat Pump Equipment
      # Heating Indoor 70F DB / 60F WB, Outdoor 47F DB / 43F WB
      # Cooling Indoor 80F DB / 67F WB, Outdoor 95F DB / 75F WB
      heating_indoor_rating_drybulb_temperature_c = OpenStudio.convert(70.0, 'F', 'C').get
      cooling_indoor_rating_wetbulb_temperature_c = OpenStudio.convert(67.0, 'F', 'C').get

      # determine which cooling EIR curve to use
      cooling_boundary_temperature_c = 20.0
      if vrf.coolingEnergyInputRatioBoundaryCurve.is_initialized
        cooling_boundary_curve = vrf.coolingEnergyInputRatioBoundaryCurve.get
        cooling_boundary_temperature_c = cooling_boundary_curve.evaluate(cooling_boundary_temperature_c)
      elsif vrf.coolingEnergyInputRatioModifierFunctionofHighTemperatureCurve.is_initialized
        # high temperature curve exists, but boundary curve doesn't
        runner.registerWarning("Unable to find Cooling Energy Input Ratio Boundary Curve for VRF system '#{vrf.name}'. Defaulting to 20.0 degC.")
      else
        cooling_boundary_temperature_c = nil
      end

      cooling_eir_low_temp_curve = nil
      cooling_eir_high_temp_curve = nil
      if vrf.coolingEnergyInputRatioModifierFunctionofLowTemperatureCurve.is_initialized
        cooling_eir_low_temp_curve = vrf.coolingEnergyInputRatioModifierFunctionofLowTemperatureCurve.get
      end
      if vrf.coolingEnergyInputRatioModifierFunctionofHighTemperatureCurve.is_initialized
        cooling_eir_high_temp_curve = vrf.coolingEnergyInputRatioModifierFunctionofHighTemperatureCurve.get
      end

      vrf_cooling_design_cop_35F = 0.0
      vrf_cooling_design_cop_60F = 0.0
      vrf_cooling_design_cop_85F = 0.0
      vrf_cooling_design_cop_110F = 0.0
      # record design COPs at different cooling temperatures
      if cooling_eir_low_temp_curve.nil?
        runner.registerWarning("Unable to find Cooling Energy Input Ratio Low Temperature curve for VRF system '#{vrf.name}'. Unable to report design COPs at non-rated temperatures.")
      else
        if cooling_boundary_temperature_c.nil?
          runner.registerWarning("No boundary temperature defined for VRF system '#{vrf.name}', using Cooling Energy Input Ratio Low Temperature curve for VRF system for all temperatures.")
          # use low temperature curve
          cooling_eir_35F_curve = cooling_eir_low_temp_curve
          cooling_eir_60F_curve = cooling_eir_low_temp_curve
          cooling_eir_85F_curve = cooling_eir_low_temp_curve
          cooling_eir_110F_curve = cooling_eir_low_temp_curve
        else
          # use boundary curve to determine whether to use high or low temperature
          cooling_eir_35F_curve = OpenStudio.convert(35.0, 'F', 'C').get > cooling_boundary_temperature_c ? cooling_eir_high_temp_curve : cooling_eir_low_temp_curve
          cooling_eir_60F_curve = OpenStudio.convert(60.0, 'F', 'C').get > cooling_boundary_temperature_c ? cooling_eir_high_temp_curve : cooling_eir_low_temp_curve
          cooling_eir_85F_curve = OpenStudio.convert(85.0, 'F', 'C').get > cooling_boundary_temperature_c ? cooling_eir_high_temp_curve : cooling_eir_low_temp_curve
          cooling_eir_110F_curve = OpenStudio.convert(110.0, 'F', 'C').get > cooling_boundary_temperature_c ? cooling_eir_high_temp_curve : cooling_eir_low_temp_curve
        end
        if cooling_eir_35F_curve.to_TableLookup.is_initialized
          cooling_eir_35F_curve = cooling_eir_35F_curve.to_TableLookup.get
          eir_35F = get_dep_var_from_lookup_table_with_two_ind_var(runner, cooling_eir_35F_curve, cooling_indoor_rating_wetbulb_temperature_c, OpenStudio.convert(35.0, 'F', 'C').get)
          vrf_cooling_design_cop_35F = vrf_cooling_design_cop / eir_35F
        else
          vrf_cooling_design_cop_35F = vrf_cooling_design_cop / cooling_eir_35F_curve.evaluate(cooling_indoor_rating_wetbulb_temperature_c, OpenStudio.convert(35.0, 'F', 'C').get)
        end
        if cooling_eir_60F_curve.to_TableLookup.is_initialized
          cooling_eir_60F_curve = cooling_eir_60F_curve.to_TableLookup.get
          eir_60F = get_dep_var_from_lookup_table_with_two_ind_var(runner, cooling_eir_60F_curve, cooling_indoor_rating_wetbulb_temperature_c, OpenStudio.convert(60.0, 'F', 'C').get)
          vrf_cooling_design_cop_60F = vrf_cooling_design_cop / eir_60F
        else
          vrf_cooling_design_cop_60F = vrf_cooling_design_cop / cooling_eir_60F_curve.evaluate(cooling_indoor_rating_wetbulb_temperature_c, OpenStudio.convert(60.0, 'F', 'C').get)
        end
        if cooling_eir_85F_curve.to_TableLookup.is_initialized
          cooling_eir_85F_curve = cooling_eir_85F_curve.to_TableLookup.get
          eir_85F = get_dep_var_from_lookup_table_with_two_ind_var(runner, cooling_eir_85F_curve, cooling_indoor_rating_wetbulb_temperature_c, OpenStudio.convert(85.0, 'F', 'C').get)
          vrf_cooling_design_cop_85F = vrf_cooling_design_cop / eir_85F
        else
          vrf_cooling_design_cop_85F = vrf_cooling_design_cop / cooling_eir_85F_curve.evaluate(cooling_indoor_rating_wetbulb_temperature_c, OpenStudio.convert(85.0, 'F', 'C').get)
        end
        if cooling_eir_110F_curve.to_TableLookup.is_initialized
          cooling_eir_110F_curve = cooling_eir_110F_curve.to_TableLookup.get
          eir_110F = get_dep_var_from_lookup_table_with_two_ind_var(runner, cooling_eir_110F_curve, cooling_indoor_rating_wetbulb_temperature_c, OpenStudio.convert(110.0, 'F', 'C').get)
          vrf_cooling_design_cop_110F = vrf_cooling_design_cop / eir_110F
        else
          vrf_cooling_design_cop_110F = vrf_cooling_design_cop / cooling_eir_110F_curve.evaluate(cooling_indoor_rating_wetbulb_temperature_c, OpenStudio.convert(110.0, 'F', 'C').get)
        end
      end

      # determine which heating EIR curve to use
      heating_boundary_temperature_c = -10.0
      if vrf.heatingEnergyInputRatioBoundaryCurve.is_initialized
        heating_boundary_curve = vrf.heatingEnergyInputRatioBoundaryCurve.get
        heating_boundary_temperature_c = heating_boundary_curve.evaluate(heating_indoor_rating_drybulb_temperature_c)
      elsif vrf.heatingEnergyInputRatioModifierFunctionofHighTemperatureCurve.is_initialized
        # high temperature curve exists, but boundary curve doesn't
        runner.registerWarning("Unable to find Heating Energy Input Ratio Boundary Curve for VRF system '#{vrf.name}'. Defaulting to -10.0 degC.")
      else
        heating_boundary_temperature_c = nil
      end

      heating_eir_low_temp_curve = nil
      heating_eir_high_temp_curve = nil
      if vrf.heatingEnergyInputRatioModifierFunctionofLowTemperatureCurve.is_initialized
        heating_eir_low_temp_curve = vrf.heatingEnergyInputRatioModifierFunctionofLowTemperatureCurve.get
      end
      if vrf.heatingEnergyInputRatioModifierFunctionofHighTemperatureCurve.is_initialized
        heating_eir_high_temp_curve = vrf.heatingEnergyInputRatioModifierFunctionofHighTemperatureCurve.get
      end

      vrf_heating_design_cop_minus22F = 0.0
      vrf_heating_design_cop_0F = 0.0
      vrf_heating_design_cop_20F = 0.0
      vrf_heating_design_cop_40F = 0.0
      # record design COPs at different heating temperatures
      if heating_eir_low_temp_curve.nil?
        runner.registerWarning("Unable to find Heating Energy Input Ratio Low Temperature curve for VRF system '#{vrf.name}'. Unable to report design COPs at non-rated temperatures.")
      else
        if heating_boundary_temperature_c.nil?
          runner.registerWarning("No boundary temperature defined for VRF system '#{vrf.name}', using Heating Energy Input Ratio Low Temperature curve for VRF system for all temperatures.")
          # use low temperature curve
          heating_eir_minus22F_curve = heating_eir_low_temp_curve
          heating_eir_0F_curve = heating_eir_low_temp_curve
          heating_eir_20F_curve = heating_eir_low_temp_curve
          heating_eir_40F_curve = heating_eir_low_temp_curve
        else
          # use boundary curve to determine whether to use high or low temperature
          heating_eir_minus22F_curve = OpenStudio.convert(-22.0, 'F', 'C').get > heating_boundary_temperature_c ? heating_eir_high_temp_curve : heating_eir_low_temp_curve
          heating_eir_0F_curve = OpenStudio.convert(0.0, 'F', 'C').get > heating_boundary_temperature_c ? heating_eir_high_temp_curve : heating_eir_low_temp_curve
          heating_eir_20F_curve = OpenStudio.convert(20.0, 'F', 'C').get > heating_boundary_temperature_c ? heating_eir_high_temp_curve : heating_eir_low_temp_curve
          heating_eir_40F_curve = OpenStudio.convert(40.0, 'F', 'C').get > heating_boundary_temperature_c ? heating_eir_high_temp_curve : heating_eir_low_temp_curve
        end
        if heating_eir_minus22F_curve.to_TableLookup.is_initialized
          heating_eir_minus22F_curve = heating_eir_minus22F_curve.to_TableLookup.get
          eir_minus22F = get_dep_var_from_lookup_table_with_two_ind_var(runner, heating_eir_minus22F_curve, heating_indoor_rating_drybulb_temperature_c, OpenStudio.convert(-22.0, 'F', 'C').get)
          vrf_heating_design_cop_minus22F = vrf_heating_design_cop / eir_minus22F
        else
          vrf_heating_design_cop_minus22F = vrf_heating_design_cop / heating_eir_minus22F_curve.evaluate(heating_indoor_rating_drybulb_temperature_c, OpenStudio.convert(-22.0, 'F', 'C').get)
        end
        if heating_eir_0F_curve.to_TableLookup.is_initialized
          heating_eir_0F_curve = heating_eir_0F_curve.to_TableLookup.get
          eir_0F = get_dep_var_from_lookup_table_with_two_ind_var(runner, heating_eir_0F_curve, heating_indoor_rating_drybulb_temperature_c, OpenStudio.convert(0.0, 'F', 'C').get)
          vrf_heating_design_cop_0F = vrf_heating_design_cop / eir_0F
        else
          vrf_heating_design_cop_0F = vrf_heating_design_cop / heating_eir_0F_curve.evaluate(heating_indoor_rating_drybulb_temperature_c, OpenStudio.convert(0.0, 'F', 'C').get)
        end
        if heating_eir_20F_curve.to_TableLookup.is_initialized
          heating_eir_20F_curve = heating_eir_20F_curve.to_TableLookup.get
          eir_20F = get_dep_var_from_lookup_table_with_two_ind_var(runner, heating_eir_20F_curve, heating_indoor_rating_drybulb_temperature_c, OpenStudio.convert(20.0, 'F', 'C').get)
          vrf_heating_design_cop_20F = vrf_heating_design_cop / eir_20F
        else
          vrf_heating_design_cop_20F = vrf_heating_design_cop / heating_eir_20F_curve.evaluate(heating_indoor_rating_drybulb_temperature_c, OpenStudio.convert(20.0, 'F', 'C').get)
        end
        if heating_eir_40F_curve.to_TableLookup.is_initialized
          heating_eir_40F_curve = heating_eir_40F_curve.to_TableLookup.get
          eir_40F = get_dep_var_from_lookup_table_with_two_ind_var(runner, heating_eir_40F_curve, heating_indoor_rating_drybulb_temperature_c, OpenStudio.convert(40.0, 'F', 'C').get)
          vrf_heating_design_cop_40F = vrf_heating_design_cop / eir_40F
        else
          vrf_heating_design_cop_40F = vrf_heating_design_cop / heating_eir_40F_curve.evaluate(heating_indoor_rating_drybulb_temperature_c, OpenStudio.convert(40.0, 'F', 'C').get)
        end
      end
      vrf_heating_performance_curve_temperature_type = vrf.heatingPerformanceCurveOutdoorTemperatureType

      # calculate annual cops
      vrf_cooling_cop = vrf_cooling_electric_j > 0.0 ? vrf_cooling_load_j / vrf_cooling_electric_j : 0.0
      vrf_heating_cop = vrf_heating_electric_j > 0.0 ? vrf_heating_load_j / vrf_heating_electric_j : 0.0
      vrf_heating_total_input_energy_j = vrf_heating_electric_j + vrf_defrost_electric_j + vrf_crankcase_electric_j + vrf_total_heating_supplemental_electric_j + vrf_total_heating_supplemental_gas_j
      vrf_heating_total_cop = vrf_heating_total_input_energy_j > 0.0 ? vrf_heating_load_j / vrf_heating_total_input_energy_j : 0.0

      # record data
      vrf_total_cooling_load_j += vrf_cooling_load_j
      vrf_total_heating_load_j += vrf_heating_load_j
      vrf_total_heat_recovery_j += vrf_heat_recovery_j
      vrf_total_cooling_electric_j += vrf_cooling_electric_j
      vrf_total_heating_electric_j += vrf_heating_electric_j
      vrf_total_heating_defrost_energy_j += vrf_defrost_electric_j
      vrf_total_heating_total_input_energy_j += vrf_heating_total_input_energy_j
      vrf_cooling_load_weighted_cop += vrf_cooling_load_j * vrf_cooling_cop
      vrf_heating_load_weighted_cop += vrf_heating_load_j * vrf_heating_cop
      vrf_heating_load_weighted_total_cop += vrf_heating_load_j * vrf_heating_total_cop
      vrf_cooling_load_weighted_design_cop += vrf_cooling_load_j * vrf_cooling_design_cop
      vrf_heating_load_weighted_design_cop += vrf_heating_load_j * vrf_heating_design_cop
      vrf_cooling_load_weighted_design_cop_35F += vrf_cooling_load_j * vrf_cooling_design_cop_35F
      vrf_cooling_load_weighted_design_cop_60F += vrf_cooling_load_j * vrf_cooling_design_cop_60F
      vrf_cooling_load_weighted_design_cop_85F += vrf_cooling_load_j * vrf_cooling_design_cop_85F
      vrf_cooling_load_weighted_design_cop_110F += vrf_cooling_load_j * vrf_cooling_design_cop_110F
      vrf_heating_load_weighted_design_cop_minus22F += vrf_heating_load_j * vrf_heating_design_cop_minus22F
      vrf_heating_load_weighted_design_cop_0F += vrf_heating_load_j * vrf_heating_design_cop_0F
      vrf_heating_load_weighted_design_cop_20F += vrf_heating_load_j * vrf_heating_design_cop_20F
      vrf_heating_load_weighted_design_cop_40F += vrf_heating_load_j * vrf_heating_design_cop_40F
      if vrf_heating_load_j > vrf_largest_heating_load_served_j
        vrf_heating_largest_load_performance_curve_temperature_type = vrf_heating_performance_curve_temperature_type
        vrf_largest_heating_load_served_j = vrf_heating_load_j
      end
    end
    # report counts and line length statistics
    runner.registerValue('com_report_hvac_vrf_indoor_unit_count', vrf_indoor_unit_count)
    runner.registerValue('com_report_hvac_vrf_outdoor_unit_count', vrf_outdoor_unit_count)
    average_num_compressors = total_vrf_area_m2 > 0.0 ? weighted_vrf_num_compressors / total_vrf_area_m2 : 0.0
    runner.registerValue('com_report_hvac_vrf_area_average_num_compressors', average_num_compressors)
    average_line_length_m = total_vrf_area_m2 > 0.0 ? weighted_vrf_length_m / total_vrf_area_m2 : 0.0
    runner.registerValue('com_report_hvac_vrf_area_average_line_length_m', average_line_length_m)
    average_line_height_m = total_vrf_area_m2 > 0.0 ? weighted_vrf_height_m / total_vrf_area_m2 : 0.0
    runner.registerValue('com_report_hvac_vrf_area_average_line_height_m', average_line_height_m)

    # report indoor and outdoor unit equipment capacities
    runner.registerValue('com_report_hvac_vrf_total_indoor_unit_cooling_capacity_w', vrf_total_indoor_unit_cooling_capacity_w)
    runner.registerValue('com_report_hvac_vrf_total_indoor_unit_heating_capacity_w', vrf_total_indoor_unit_heating_capacity_w)
    average_indoor_unit_cooling_capacity_w = total_vrf_area_m2 > 0.0 ? vrf_area_weighted_indoor_unit_cooling_capacity_w / total_vrf_area_m2 : 0.0
    runner.registerValue('com_report_hvac_vrf_area_average_indoor_unit_cooling_capacity_w', average_indoor_unit_cooling_capacity_w)
    average_indoor_unit_heating_capacity_w = total_vrf_area_m2 > 0.0 ? vrf_area_weighted_indoor_unit_heating_capacity_w / total_vrf_area_m2 : 0.0
    runner.registerValue('com_report_hvac_vrf_area_average_indoor_unit_heating_capacity_w', average_indoor_unit_heating_capacity_w)
    runner.registerValue('com_report_hvac_vrf_total_outdoor_unit_cooling_capacity_w', vrf_total_outdoor_unit_cooling_capacity_w)
    runner.registerValue('com_report_hvac_vrf_total_outdoor_unit_heating_capacity_w', vrf_total_outdoor_unit_heating_capacity_w)
    average_outdoor_unit_cooling_capacity_w = total_vrf_area_m2 > 0.0 ? vrf_area_weighted_outdoor_unit_cooling_capacity_w / total_vrf_area_m2 : 0.0
    runner.registerValue('com_report_hvac_vrf_area_average_outdoor_unit_cooling_capacity_w', average_outdoor_unit_cooling_capacity_w)
    average_outdoor_unit_heating_capacity_w = total_vrf_area_m2 > 0.0 ? vrf_area_weighted_outdoor_unit_heating_capacity_w / total_vrf_area_m2 : 0.0
    runner.registerValue('com_report_hvac_vrf_area_average_outdoor_unit_heating_capacity_w', average_outdoor_unit_heating_capacity_w)

    # report out VRF loads
    runner.registerValue('com_report_hvac_vrf_total_cooling_load_j', vrf_total_cooling_load_j)
    runner.registerValue('com_report_hvac_vrf_total_heating_load_j', vrf_total_heating_load_j)
    runner.registerValue('com_report_hvac_vrf_total_heat_recovery_j', vrf_total_heat_recovery_j)

    # report out VRF COPs
    average_vrf_cooling_load_weighted_cop = vrf_total_cooling_load_j > 0.0 ? vrf_cooling_load_weighted_cop / vrf_total_cooling_load_j : 0.0
    runner.registerValue('com_report_hvac_vrf_cooling_average_cop', average_vrf_cooling_load_weighted_cop)
    average_vrf_heating_load_weighted_cop = vrf_total_heating_load_j > 0.0 ? vrf_heating_load_weighted_cop / vrf_total_heating_load_j : 0.0
    runner.registerValue('com_report_hvac_vrf_heating_average_cop', average_vrf_heating_load_weighted_cop)
    average_vrf_heating_load_weighted_total_cop = vrf_total_heating_load_j > 0.0 ? vrf_heating_load_weighted_total_cop / vrf_total_heating_load_j : 0.0
    runner.registerValue('com_report_hvac_vrf_heating_average_total_cop', average_vrf_heating_load_weighted_total_cop)
    average_vrf_cooling_load_weighted_design_cop = vrf_total_cooling_load_j > 0.0 ? vrf_cooling_load_weighted_design_cop / vrf_total_cooling_load_j : 0.0
    runner.registerValue('com_report_hvac_vrf_cooling_design_cop', average_vrf_cooling_load_weighted_design_cop)
    average_vrf_cooling_load_weighted_design_cop_35F = vrf_total_cooling_load_j > 0.0 ? vrf_cooling_load_weighted_design_cop_35F / vrf_total_cooling_load_j : 0.0
    runner.registerValue('com_report_hvac_vrf_cooling_design_cop_35_f', average_vrf_cooling_load_weighted_design_cop_35F)
    average_vrf_cooling_load_weighted_design_cop_60F = vrf_total_cooling_load_j > 0.0 ? vrf_cooling_load_weighted_design_cop_60F / vrf_total_cooling_load_j : 0.0
    runner.registerValue('com_report_hvac_vrf_cooling_design_cop_60_f', average_vrf_cooling_load_weighted_design_cop_60F)
    average_vrf_cooling_load_weighted_design_cop_85F = vrf_total_cooling_load_j > 0.0 ? vrf_cooling_load_weighted_design_cop_85F / vrf_total_cooling_load_j : 0.0
    runner.registerValue('com_report_hvac_vrf_cooling_design_cop_85_f', average_vrf_cooling_load_weighted_design_cop_85F)
    average_vrf_cooling_load_weighted_design_cop_110F = vrf_total_cooling_load_j > 0.0 ? vrf_cooling_load_weighted_design_cop_110F / vrf_total_cooling_load_j : 0.0
    runner.registerValue('com_report_hvac_vrf_cooling_design_cop_110_f', average_vrf_cooling_load_weighted_design_cop_110F)
    average_vrf_heating_load_weighted_design_cop = vrf_total_heating_load_j > 0.0 ? vrf_heating_load_weighted_design_cop / vrf_total_heating_load_j : 0.0
    runner.registerValue('com_report_hvac_vrf_heating_design_cop', average_vrf_heating_load_weighted_design_cop)
    average_vrf_heating_load_weighted_design_cop_minus22F = vrf_total_heating_load_j > 0.0 ? vrf_heating_load_weighted_design_cop_minus22F / vrf_total_heating_load_j : 0.0
    runner.registerValue('com_report_hvac_vrf_heating_design_cop_minus_22_f', average_vrf_heating_load_weighted_design_cop_minus22F)
    average_vrf_heating_load_weighted_design_cop_0F = vrf_total_heating_load_j > 0.0 ? vrf_heating_load_weighted_design_cop_0F / vrf_total_heating_load_j : 0.0
    runner.registerValue('com_report_hvac_vrf_heating_design_cop_0_f', average_vrf_heating_load_weighted_design_cop_0F)
    average_vrf_heating_load_weighted_design_cop_20F = vrf_total_heating_load_j > 0.0 ? vrf_heating_load_weighted_design_cop_20F / vrf_total_heating_load_j : 0.0
    runner.registerValue('com_report_hvac_vrf_heating_design_cop_20_f', average_vrf_heating_load_weighted_design_cop_20F)
    average_vrf_heating_load_weighted_design_cop_40F = vrf_total_heating_load_j > 0.0 ? vrf_heating_load_weighted_design_cop_40F / vrf_total_heating_load_j : 0.0
    runner.registerValue('com_report_hvac_vrf_heating_design_cop_40_f', average_vrf_heating_load_weighted_design_cop_40F)
    runner.registerValue('com_report_hvac_vrf_heating_performance_curve_temperature_type', vrf_heating_largest_load_performance_curve_temperature_type)

    # report out VRF fraction of heating load met by supplemental equipment
    vrf_fraction_heating_load_supplemental = 0.0
    if vrf_total_heating_load_j > 0.0
      vrf_fraction_heating_load_supplemental = (vrf_total_heating_supplemental_load_j / vrf_total_heating_load_j)
    end
    runner.registerValue('com_report_hvac_vrf_fraction_heating_load_supplemental', vrf_fraction_heating_load_supplemental)

    # report out DX supplemental heating load and electric
    runner.registerValue('com_report_hvac_vrf_total_heating_supplemental_load_j', vrf_total_heating_supplemental_load_j)
    runner.registerValue('com_report_hvac_vrf_total_heating_supplemental_load_electric_j', vrf_total_heating_supplemental_load_electric_j)
    runner.registerValue('com_report_hvac_vrf_total_heating_supplemental_load_gas_j', vrf_total_heating_supplemental_load_gas_j)
    runner.registerValue('com_report_hvac_vrf_total_heating_supplemental_electric_j', vrf_total_heating_supplemental_electric_j)
    runner.registerValue('com_report_hvac_vrf_total_heating_supplemental_gas_j', vrf_total_heating_supplemental_gas_j)

    # Cooling tower water use
    cooling_towers = model.getCoolingTowerSingleSpeeds.map { |c| c }
    model.getCoolingTowerTwoSpeeds.each { |c| cooling_towers << c }
    model.getCoolingTowerVariableSpeeds.each { |c| cooling_towers << c }
    cooling_tower_total_water_use_m3 = 0.0
    cooling_towers.sort.each do |cooling_tower|
      water_use_m3 = sql_get_report_variable_data_double(runner, sql, cooling_tower, 'Cooling Tower Make Up Water Volume')
      cooling_tower_total_water_use_m3 += water_use_m3
    end
    runner.registerValue('com_report_hvac_cooling_tower_water_use_m3', cooling_tower_total_water_use_m3)

    # Design and annual average chiller efficiency
    chiller_total_load_j = 0.0
    chiller_load_weighted_cop = 0.0
    chiller_load_weighted_design_cop = 0.0
    chiller_load_weighted_iplv_eer = 0.0
    chiller_total_capacity_w = 0.0
    chiller_count_0_to_75_tons = 0.0
    chiller_count_75_to_150_tons = 0.0
    chiller_count_150_to_300_tons = 0.0
    chiller_count_300_to_600_tons = 0.0
    chiller_count_600_plus_tons = 0.0
    chiller_acc_capacity_fraction_weighted_sum = 0.0
    chiller_wcc_capacity_fraction_weighted_sum = 0.0
    chiller_ecc_capacity_fraction_weighted_sum = 0.0
    model.getChillerElectricEIRs.sort.each do |chiller|
      # get chiller capacity
      if chiller.referenceCapacity.is_initialized
        capacity_w = chiller.referenceCapacity.get
      elsif chiller.autosizedReferenceCapacity.is_initialized
        capacity_w = chiller.autosizedReferenceCapacity.get
      else
        runner.registerWarning("Chiller capacity not available for chiller '#{chiller.name}'.")
        capacity_w = 0.0
      end
      chiller_total_capacity_w += capacity_w

      # log count of sizes
      capacity_tons = OpenStudio.convert(capacity_w, 'W', 'ton').get
      if capacity_tons < 75
        chiller_count_0_to_75_tons += 1
      elsif capacity_tons < 150
        chiller_count_75_to_150_tons += 1
      elsif capacity_tons < 300
        chiller_count_150_to_300_tons += 1
      elsif capacity_tons < 600
        chiller_count_300_to_600_tons += 1
      else # capacity is over 600 tons
        chiller_count_600_plus_tons += 1
      end

      # log condenser type fraction
      case chiller.condenserType
      when 'AirCooled'
        chiller_acc_capacity_fraction_weighted_sum += capacity_w
      when 'WaterCooled'
        chiller_wcc_capacity_fraction_weighted_sum += capacity_w
      when 'EvaporativelyCooled'
        chiller_ecc_capacity_fraction_weighted_sum += capacity_w
      else
        runner.registerError("Chiller condenser type not available for chiller '#{chiller.name}'.")
        return false
      end

      # get Chiller Evaporator Cooling Energy
      chiller_load_j = sql_get_report_variable_data_double(runner, sql, chiller, 'Chiller Evaporator Cooling Energy')

      # get chiller annual cop
      chiller_annual_cop = sql_get_report_variable_data_double(runner, sql, chiller, 'Chiller COP')

      # get chiller design cop
      chiller_design_cop = chiller.referenceCOP

      # get chiller IPLV
      var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'EquipmentSummary' AND ReportForString = 'Entire Facility' AND TableName = 'Central Plant' AND RowName = '#{chiller.name.to_s.upcase}' AND ColumnName = 'IPLV in IP Units' AND Units = 'Btu/W-h'"
      val = sql.execAndReturnFirstDouble(var_val_query)
      if val.is_initialized
        chiller_iplv_eer = val.get
      else
        chiller_iplv_eer = 0.0
        runner.registerWarning('Chiller IPLV EER not available.')
      end

      # add to weighted load cop
      chiller_total_load_j += chiller_load_j
      chiller_load_weighted_cop += chiller_load_j * chiller_annual_cop
      chiller_load_weighted_design_cop += chiller_load_j * chiller_design_cop
      chiller_load_weighted_iplv_eer += chiller_load_j * chiller_iplv_eer
    end
    average_chiller_cop = chiller_total_load_j > 0.0 ? chiller_load_weighted_cop / chiller_total_load_j : 0.0
    runner.registerValue('com_report_hvac_average_chiller_cop', average_chiller_cop)
    design_chiller_cop = chiller_total_load_j > 0.0 ? chiller_load_weighted_design_cop / chiller_total_load_j : 0.0
    runner.registerValue('com_report_hvac_design_chiller_cop', design_chiller_cop)
    chiller_total_capacity_tons = OpenStudio.convert(chiller_total_capacity_w, 'W', 'ton').get
    runner.registerValue('com_report_hvac_chiller_capacity_tons', chiller_total_capacity_tons)
    runner.registerValue('com_report_hvac_count_chillers_0_to_75_tons', chiller_count_0_to_75_tons)
    runner.registerValue('com_report_hvac_count_chillers_75_to_150_tons', chiller_count_75_to_150_tons)
    runner.registerValue('com_report_hvac_count_chillers_150_to_300_tons', chiller_count_150_to_300_tons)
    runner.registerValue('com_report_hvac_count_chillers_300_to_600_tons', chiller_count_300_to_600_tons)
    runner.registerValue('com_report_hvac_count_chillers_600_plus_tons', chiller_count_600_plus_tons)
    chiller_acc_capacity_fraction = chiller_total_capacity_w > 0.0 ? chiller_acc_capacity_fraction_weighted_sum / chiller_total_capacity_w : 0.0
    chiller_wcc_capacity_fraction = chiller_total_capacity_w > 0.0 ? chiller_wcc_capacity_fraction_weighted_sum / chiller_total_capacity_w : 0.0
    chiller_ecc_capacity_fraction = chiller_total_capacity_w > 0.0 ? chiller_ecc_capacity_fraction_weighted_sum / chiller_total_capacity_w : 0.0
    runner.registerValue('com_report_hvac_chiller_acc_capacity_fraction', chiller_acc_capacity_fraction)
    runner.registerValue('com_report_hvac_chiller_wcc_capacity_fraction', chiller_wcc_capacity_fraction)
    runner.registerValue('com_report_hvac_chiller_ecc_capacity_fraction', chiller_ecc_capacity_fraction)
    chiller_iplv_eer = chiller_total_load_j > 0.0 ? chiller_load_weighted_iplv_eer / chiller_total_load_j : 0.0
    runner.registerValue('com_report_hvac_chiller_iplv_eer', chiller_iplv_eer)

    # water to air heat pump cooling capacity, load, and efficiencies
    wa_hp_cooling_total_electric_j = 0.0
    wa_hp_cooling_total_load_j = 0.0
    wa_hp_cooling_load_weighted_cop = 0.0
    wa_hp_cooling_load_weighted_design_cop = 0.0
    wa_hp_cooling_total_capacity_w = 0.0
    model.getCoilCoolingWaterToAirHeatPumpEquationFits.sort.each do |coil|
      # get water to air heat pump cooling capacity and cop
      capacity_w = 0.0
      # capacity
      if coil.ratedTotalCoolingCapacity.is_initialized
        capacity_w = coil.ratedTotalCoolingCapacity.get
      elsif coil.autosizedRatedTotalCoolingCapacity.is_initialized
        capacity_w = coil.autosizedRatedTotalCoolingCapacity.get
      else
        runner.registerWarning("Cooling coil capacity not available for coil '#{coil.name}'.")
      end
      wa_hp_cooling_total_capacity_w += capacity_w

      coil_design_cop = coil.ratedCoolingCoefficientofPerformance

      # get Cooling Coil Total Cooling Energy
      coil_cooling_energy_j = sql_get_report_variable_data_double(runner, sql, coil, 'Cooling Coil Total Cooling Energy')

      # get Cooling Coil Electric Energy
      coil_electric_energy_j = sql_get_report_variable_data_double(runner, sql, coil, "Cooling Coil #{elec} Energy")

      # add to weighted load cop
      coil_annual_cop = coil_cooling_energy_j > 0.0 ? coil_cooling_energy_j / coil_electric_energy_j : 0
      wa_hp_cooling_total_electric_j += coil_electric_energy_j
      wa_hp_cooling_total_load_j += coil_cooling_energy_j
      wa_hp_cooling_load_weighted_cop += coil_cooling_energy_j * coil_annual_cop
      wa_hp_cooling_load_weighted_design_cop += coil_cooling_energy_j * coil_design_cop
    end
    runner.registerValue('com_report_hvac_water_air_heat_pump_cooling_total_capacity_w', wa_hp_cooling_total_capacity_w)
    average_water_air_hp_cooling_cop = wa_hp_cooling_total_load_j > 0.0 ? wa_hp_cooling_load_weighted_cop / wa_hp_cooling_total_load_j : 0.0
    runner.registerValue('com_report_hvac_water_air_heat_pump_cooling_average_cop', average_water_air_hp_cooling_cop)
    design_water_air_hp_cooling_cop = wa_hp_cooling_total_load_j > 0.0 ? wa_hp_cooling_load_weighted_design_cop / wa_hp_cooling_total_load_j : 0.0
    runner.registerValue('com_report_hvac_water_air_heat_pump_cooling_design_cop', design_water_air_hp_cooling_cop)

    # report out water to air heat pump cooling load and electricity
    runner.registerValue('com_report_hvac_water_air_heat_pump_cooling_total_electric_j', wa_hp_cooling_total_electric_j)
    runner.registerValue('com_report_hvac_water_air_heat_pump_cooling_total_load_j', wa_hp_cooling_total_load_j)

    # water to air heat pump heating capacity, load, and efficiencies
    wa_hp_heating_total_electric_j = 0.0
    wa_hp_heating_total_load_j = 0.0
    wa_hp_heating_load_weighted_cop = 0.0
    wa_hp_heating_load_weighted_design_cop = 0.0
    wa_hp_heating_total_capacity_w = 0.0
    model.getCoilHeatingWaterToAirHeatPumpEquationFits.sort.each do |coil|
      # get water to air heat pump heating capacity and cop
      capacity_w = 0.0
      # capacity
      if coil.ratedHeatingCapacity.is_initialized
        capacity_w = coil.ratedHeatingCapacity.get
      elsif coil.autosizedRatedHeatingCapacity.is_initialized
        capacity_w = coil.autosizedRatedHeatingCapacity.get
      else
        runner.registerWarning("Heating coil capacity not available for coil '#{coil.name}'.")
      end
      wa_hp_heating_total_capacity_w += capacity_w

      coil_design_cop = coil.ratedHeatingCoefficientofPerformance

      # get Heating Coil Heating Energy
      coil_heating_energy_j = sql_get_report_variable_data_double(runner, sql, coil, 'Heating Coil Heating Energy')

      # get Heating Coil Electric Energy
      coil_electric_energy_j = sql_get_report_variable_data_double(runner, sql, coil, "Heating Coil #{elec} Energy")

      # add to weighted load cop
      coil_annual_cop = coil_heating_energy_j > 0.0 ? coil_heating_energy_j / coil_electric_energy_j : 0
      wa_hp_heating_total_electric_j += coil_electric_energy_j
      wa_hp_heating_total_load_j += coil_heating_energy_j
      wa_hp_heating_load_weighted_cop += coil_heating_energy_j * coil_annual_cop
      wa_hp_heating_load_weighted_design_cop += coil_heating_energy_j * coil_design_cop
    end
    runner.registerValue('com_report_hvac_water_air_heat_pump_heating_total_capacity_w', wa_hp_heating_total_capacity_w)
    average_water_air_hp_heating_cop = wa_hp_heating_total_load_j > 0.0 ? wa_hp_heating_load_weighted_cop / wa_hp_heating_total_load_j : 0.0
    runner.registerValue('com_report_hvac_water_air_heat_pump_heating_average_cop', average_water_air_hp_heating_cop)
    design_water_air_hp_heating_cop = wa_hp_heating_total_load_j > 0.0 ? wa_hp_heating_load_weighted_design_cop / wa_hp_heating_total_load_j : 0.0
    runner.registerValue('com_report_hvac_water_air_heat_pump_heating_design_cop', design_water_air_hp_heating_cop)

    # report out water to air heat pump heating load and electricity
    runner.registerValue('com_report_hvac_water_air_heat_pump_heating_total_electric_j', wa_hp_heating_total_electric_j)
    runner.registerValue('com_report_hvac_water_air_heat_pump_heating_total_load_j', wa_hp_heating_total_load_j)

    # DX cooling coils capacity, load, and efficiencies
    dx_cooling_total_electric_j = 0.0
    dx_cooling_total_load_j = 0.0
    dx_cooling_0_to_30_kbtuh_total_load_j = 0.0
    dx_cooling_30_to_65_kbtuh_total_load_j = 0.0
    dx_cooling_65_to_135_kbtuh_total_load_j = 0.0
    dx_cooling_135_to_240_kbtuh_total_load_j = 0.0
    dx_cooling_240_to_760_kbtuh_total_load_j = 0.0
    dx_cooling_760_plus_kbtuh_total_load_j = 0.0
    dx_cooling_load_weighted_cop = 0.0
    dx_cooling_load_weighted_design_cop = 0.0
    dx_cooling_total_capacity_w = 0.0
    dx_cooling_count_0_to_30_kbtuh = 0.0
    dx_cooling_count_30_to_65_kbtuh = 0.0
    dx_cooling_count_65_to_135_kbtuh = 0.0
    dx_cooling_count_135_to_240_kbtuh = 0.0
    dx_cooling_count_240_to_760_kbtuh = 0.0
    dx_cooling_count_760_plus_kbtuh = 0.0
    dx_cooling_load_weighted_design_seer_0_to_30_kbtuh = 0.0
    dx_cooling_load_weighted_design_seer_30_to_65_kbtuh = 0.0
    dx_cooling_load_weighted_design_eer_65_to_135_kbtuh = 0.0
    dx_cooling_load_weighted_design_ieer_65_to_135_kbtuh = 0.0
    dx_cooling_load_weighted_design_eer_135_to_240_kbtuh = 0.0
    dx_cooling_load_weighted_design_ieer_135_to_240_kbtuh = 0.0
    dx_cooling_load_weighted_design_eer_240_to_760_kbtuh = 0.0
    dx_cooling_load_weighted_design_ieer_240_to_760_kbtuh = 0.0
    dx_cooling_load_weighted_design_eer_760_plus_kbtuh = 0.0
    dx_cooling_load_weighted_design_ieer_760_plus_kbtuh = 0.0
    dx_cooling_coils = model.getCoilCoolingDXSingleSpeeds.map { |c| c }
    model.getCoilCoolingDXTwoSpeeds.each { |c| dx_cooling_coils << c }
    model.getCoilCoolingDXMultiSpeeds.each { |c| dx_cooling_coils << c }
    model.getCoilCoolingDXVariableSpeeds.each { |c| dx_cooling_coils << c }
    dx_cooling_coils.sort.each do |coil|
      # get dx cooling capacity and cop
      capacity_w, coil_design_cop = get_cooling_coil_capacity_and_cop(runner, model, coil)
      dx_cooling_total_capacity_w += capacity_w

      # get DX Cooling Coil efficiency ratings
      coil_eer = 0.0
      var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'EquipmentSummary' AND ReportForString = 'Entire Facility' AND TableName = 'DX Cooling Coils' AND RowName = '#{coil.name.get.to_s.upcase}' AND ColumnName = 'EER'"
      val = sql.execAndReturnFirstDouble(var_val_query)
      if val.is_initialized
        coil_eer = val.get
      else
        runner.registerWarning("Coil 'EER' not available for DX cooling coil '#{coil.name}'.")
      end

      coil_seer_std = 0.0
      var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'EquipmentSummary' AND ReportForString = 'Entire Facility' AND TableName = 'DX Cooling Coils' AND RowName = '#{coil.name.get.to_s.upcase}' AND ColumnName = 'SEER Standard'"
      val = sql.execAndReturnFirstDouble(var_val_query)
      if val.is_initialized
        coil_seer_std = val.get
      else
        runner.registerWarning("Coil 'SEER Standard' not available for DX cooling coil '#{coil.name}'.")
      end

      coil_ieer = 0.0
      var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'EquipmentSummary' AND ReportForString = 'Entire Facility' AND TableName = 'DX Cooling Coils' AND RowName = '#{coil.name.get.to_s.upcase}' AND ColumnName = 'IEER'"
      val = sql.execAndReturnFirstDouble(var_val_query)
      if val.is_initialized
        coil_ieer = val.get
      else
        runner.registerWarning("Coil 'IEER' not available for DX cooling coil '#{coil.name}'.")
      end

      # get Cooling Coil Total Cooling Energy
      coil_cooling_energy_j = sql_get_report_variable_data_double(runner, sql, coil, 'Cooling Coil Total Cooling Energy')

      # get Cooling Coil Electric Energy
      coil_electric_energy_j = sql_get_report_variable_data_double(runner, sql, coil, "Cooling Coil #{elec} Energy")

      # add to weighted load cop
      coil_annual_cop = coil_cooling_energy_j > 0.0 ? coil_cooling_energy_j / coil_electric_energy_j : 0
      dx_cooling_total_electric_j += coil_electric_energy_j
      dx_cooling_total_load_j += coil_cooling_energy_j
      dx_cooling_load_weighted_cop += coil_cooling_energy_j * coil_annual_cop
      dx_cooling_load_weighted_design_cop += coil_cooling_energy_j * coil_design_cop

      # log count of sizes, load, and COPs by equipment size
      capacity_kbtuh = OpenStudio.convert(capacity_w, 'W', 'kBtu/h').get
      if capacity_kbtuh < 30
        dx_cooling_count_0_to_30_kbtuh += 1
        dx_cooling_0_to_30_kbtuh_total_load_j += coil_cooling_energy_j
        dx_cooling_load_weighted_design_seer_0_to_30_kbtuh += coil_cooling_energy_j * coil_seer_std
      elsif capacity_kbtuh < 65
        dx_cooling_count_30_to_65_kbtuh += 1
        dx_cooling_30_to_65_kbtuh_total_load_j += coil_cooling_energy_j
        dx_cooling_load_weighted_design_seer_30_to_65_kbtuh += coil_cooling_energy_j * coil_seer_std
      elsif capacity_kbtuh < 135
        dx_cooling_count_65_to_135_kbtuh += 1
        dx_cooling_65_to_135_kbtuh_total_load_j += coil_cooling_energy_j
        dx_cooling_load_weighted_design_eer_65_to_135_kbtuh += coil_cooling_energy_j * coil_eer
        dx_cooling_load_weighted_design_ieer_65_to_135_kbtuh += coil_cooling_energy_j * coil_ieer
      elsif capacity_kbtuh < 240
        dx_cooling_count_135_to_240_kbtuh += 1
        dx_cooling_135_to_240_kbtuh_total_load_j += coil_cooling_energy_j
        dx_cooling_load_weighted_design_eer_135_to_240_kbtuh += coil_cooling_energy_j * coil_eer
        dx_cooling_load_weighted_design_ieer_135_to_240_kbtuh += coil_cooling_energy_j * coil_ieer
      elsif capacity_kbtuh < 760
        dx_cooling_count_240_to_760_kbtuh += 1
        dx_cooling_240_to_760_kbtuh_total_load_j += coil_cooling_energy_j
        dx_cooling_load_weighted_design_eer_240_to_760_kbtuh += coil_cooling_energy_j * coil_eer
        dx_cooling_load_weighted_design_ieer_240_to_760_kbtuh += coil_cooling_energy_j * coil_ieer
      else # capacity is over 760 kbtuh
        dx_cooling_count_760_plus_kbtuh += 1
        dx_cooling_760_plus_kbtuh_total_load_j += coil_cooling_energy_j
        dx_cooling_load_weighted_design_eer_760_plus_kbtuh += coil_cooling_energy_j * coil_eer
        dx_cooling_load_weighted_design_ieer_760_plus_kbtuh += coil_cooling_energy_j * coil_ieer
      end

      # cooling coil info logging
      runner.registerInfo("Cooling coil '#{coil.name}' has design capacity #{capacity_w.round(2)} W, design cop #{coil_design_cop.round(2)}, and annual weighted cop #{coil_annual_cop.round(2)}.")
    end
    average_dx_cooling_cop = dx_cooling_total_load_j > 0.0 ? dx_cooling_load_weighted_cop / dx_cooling_total_load_j : 0.0
    runner.registerValue('com_report_hvac_dx_cooling_average_cop', average_dx_cooling_cop)
    design_dx_cooling_cop = dx_cooling_total_load_j > 0.0 ? dx_cooling_load_weighted_design_cop / dx_cooling_total_load_j : 0.0
    runner.registerValue('com_report_hvac_dx_cooling_design_cop', design_dx_cooling_cop)

    # report out DX cooling load and electricity
    runner.registerValue('com_report_hvac_dx_cooling_total_electric_j', dx_cooling_total_electric_j)
    runner.registerValue('com_report_hvac_dx_cooling_total_load_j', dx_cooling_total_load_j)

    # report out DX cooling SEERs, EERs, IEERs at each size category
    dx_cooling_design_seer_0_to_30_kbtuh = dx_cooling_0_to_30_kbtuh_total_load_j > 0.0 ? dx_cooling_load_weighted_design_seer_0_to_30_kbtuh / dx_cooling_0_to_30_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_cooling_design_seer_0_to_30_kbtuh', dx_cooling_design_seer_0_to_30_kbtuh)
    dx_cooling_design_seer_30_to_65_kbtuh = dx_cooling_30_to_65_kbtuh_total_load_j > 0.0 ? dx_cooling_load_weighted_design_seer_30_to_65_kbtuh / dx_cooling_30_to_65_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_cooling_design_seer_30_to_65_kbtuh', dx_cooling_design_seer_30_to_65_kbtuh)
    dx_cooling_design_eer_65_to_135_kbtuh = dx_cooling_65_to_135_kbtuh_total_load_j > 0.0 ? dx_cooling_load_weighted_design_eer_65_to_135_kbtuh / dx_cooling_65_to_135_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_cooling_design_eer_65_to_135_kbtuh', dx_cooling_design_eer_65_to_135_kbtuh)
    dx_cooling_design_ieer_65_to_135_kbtuh = dx_cooling_65_to_135_kbtuh_total_load_j > 0.0 ? dx_cooling_load_weighted_design_ieer_65_to_135_kbtuh / dx_cooling_65_to_135_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_cooling_design_ieer_65_to_135_kbtuh', dx_cooling_design_ieer_65_to_135_kbtuh)
    dx_cooling_design_eer_135_to_240_kbtuh = dx_cooling_135_to_240_kbtuh_total_load_j > 0.0 ? dx_cooling_load_weighted_design_eer_135_to_240_kbtuh / dx_cooling_135_to_240_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_cooling_design_eer_135_to_240_kbtuh', dx_cooling_design_eer_135_to_240_kbtuh)
    dx_cooling_design_ieer_135_to_240_kbtuh = dx_cooling_135_to_240_kbtuh_total_load_j > 0.0 ? dx_cooling_load_weighted_design_ieer_135_to_240_kbtuh / dx_cooling_135_to_240_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_cooling_design_ieer_135_to_240_kbtuh', dx_cooling_design_ieer_135_to_240_kbtuh)
    dx_cooling_design_eer_240_to_760_kbtuh = dx_cooling_240_to_760_kbtuh_total_load_j > 0.0 ? dx_cooling_load_weighted_design_eer_240_to_760_kbtuh / dx_cooling_240_to_760_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_cooling_design_eer_240_to_760_kbtuh', dx_cooling_design_eer_240_to_760_kbtuh)
    dx_cooling_design_ieer_240_to_760_kbtuh = dx_cooling_240_to_760_kbtuh_total_load_j > 0.0 ? dx_cooling_load_weighted_design_ieer_240_to_760_kbtuh / dx_cooling_240_to_760_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_cooling_design_ieer_240_to_760_kbtuh', dx_cooling_design_ieer_240_to_760_kbtuh)
    dx_cooling_design_eer_760_plus_kbtuh = dx_cooling_760_plus_kbtuh_total_load_j > 0.0 ? dx_cooling_load_weighted_design_eer_760_plus_kbtuh / dx_cooling_760_plus_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_cooling_design_eer_760_plus_kbtuh', dx_cooling_design_eer_760_plus_kbtuh)
    dx_cooling_design_ieer_760_plus_kbtuh = dx_cooling_760_plus_kbtuh_total_load_j > 0.0 ? dx_cooling_load_weighted_design_ieer_760_plus_kbtuh / dx_cooling_760_plus_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_cooling_design_ieer_760_plus_kbtuh', dx_cooling_design_ieer_760_plus_kbtuh)

    # report counts
    dx_cooling_total_capacity_tons = OpenStudio.convert(dx_cooling_total_capacity_w, 'W', 'ton').get
    runner.registerValue('com_report_hvac_dx_cooling_capacity_tons', dx_cooling_total_capacity_tons)
    runner.registerValue('com_report_hvac_count_dx_cooling_0_to_30_kbtuh', dx_cooling_count_0_to_30_kbtuh)
    runner.registerValue('com_report_hvac_count_dx_cooling_30_to_65_kbtuh', dx_cooling_count_30_to_65_kbtuh)
    runner.registerValue('com_report_hvac_count_dx_cooling_65_to_135_kbtuh', dx_cooling_count_65_to_135_kbtuh)
    runner.registerValue('com_report_hvac_count_dx_cooling_135_to_240_kbtuh', dx_cooling_count_135_to_240_kbtuh)
    runner.registerValue('com_report_hvac_count_dx_cooling_240_to_760_kbtuh', dx_cooling_count_240_to_760_kbtuh)
    runner.registerValue('com_report_hvac_count_dx_cooling_760_plus_kbtuh', dx_cooling_count_760_plus_kbtuh)

    # DX heating coil capacity, load, and efficiences, including supplemental coils
    dx_heating_total_load_j = 0.0
    dx_heating_total_dx_load_j = 0.0
    dx_heating_total_dx_electric_j = 0.0
    dx_heating_total_supplemental_load_j = 0.0
    dx_heating_total_supplemental_load_electric_j = 0.0
    dx_heating_total_supplemental_load_gas_j = 0.0
    dx_heating_total_supplemental_electric_j = 0.0
    dx_heating_total_supplemental_gas_j = 0.0
    dx_heating_total_crankcase_electric_j = 0.0
    dx_heating_defrost_energy_j = 0.0
    dx_heating_0_to_30_kbtuh_total_load_j = 0.0
    dx_heating_30_to_65_kbtuh_total_load_j = 0.0
    dx_heating_65_to_135_kbtuh_total_load_j = 0.0
    dx_heating_135_to_240_kbtuh_total_load_j = 0.0
    dx_heating_240_plus_kbtuh_total_load_j = 0.0
    dx_heating_load_weighted_cop = 0.0
    dx_heating_load_weighted_total_cop = 0.0
    dx_heating_load_weighted_design_cop = 0.0
    dx_heating_load_weighted_design_cop_17F = 0.0
    dx_heating_load_weighted_design_cop_5F = 0.0
    dx_heating_load_weighted_design_cop_0F = 0.0
    dx_heating_total_capacity_w = 0.0
    dx_heating_total_capacity_17F_w = 0.0
    dx_heating_total_capacity_5F_w = 0.0
    dx_heating_total_capacity_0F_w = 0.0
    dx_heating_total_supplemental_capacity_w = 0.0
    dx_heating_total_supplemental_capacity_electric_w = 0.0
    dx_heating_total_supplemental_capacity_gas_w = 0.0
    dx_heating_total_crankcase_capacity_w = 0.0
    dx_heating_capacity_weighted_min_temp_w_c = 0.0
    dx_heating_count_0_to_30_kbtuh = 0.0
    dx_heating_count_30_to_65_kbtuh = 0.0
    dx_heating_count_65_to_135_kbtuh = 0.0
    dx_heating_count_135_to_240_kbtuh = 0.0
    dx_heating_count_240_plus_kbtuh = 0.0
    dx_heating_load_weighted_design_hspf_0_to_30_kbtuh = 0.0
    dx_heating_load_weighted_design_hspf_30_to_65_kbtuh = 0.0
    dx_heating_load_weighted_design_cop_65_to_135_kbtuh = 0.0
    dx_heating_load_weighted_design_cop_135_to_240_kbtuh = 0.0
    dx_heating_load_weighted_design_cop_240_plus_kbtuh = 0.0
    dx_heating_coils = model.getCoilHeatingDXSingleSpeeds.map { |c| c }
    model.getCoilHeatingDXMultiSpeeds.each { |c| dx_heating_coils << c }
    model.getCoilHeatingDXVariableSpeeds.each { |c| dx_heating_coils << c }
    dx_heating_coils.sort.each do |coil|
      capacity_w, capacity_0F_w, capacity_5F_w, capacity_17F_w, coil_design_cop, coil_design_cop_0F, coil_design_cop_5F, coil_design_cop_17F = get_heating_coil_capacity_and_cop(runner, model, coil)
      dx_heating_total_capacity_w += capacity_w
      dx_heating_total_capacity_17F_w += capacity_17F_w
      dx_heating_total_capacity_5F_w += capacity_5F_w
      dx_heating_total_capacity_0F_w += capacity_0F_w

      # get minimum temperature
      minimum_temp_c = coil.minimumOutdoorDryBulbTemperatureforCompressorOperation
      dx_heating_capacity_weighted_min_temp_w_c += capacity_w * minimum_temp_c

      # get crankcase heater total capacity
      dx_heating_total_crankcase_capacity_w += coil.crankcaseHeaterCapacity

      # get supplemental heating coil
      supplemental_coil = nil
      if coil.airLoopHVAC.is_initialized
        air_loop_hvac = coil.airLoopHVAC.get
        # assume first electric or gas coil on supply loop is supplemental
        air_loop_hvac.supplyComponents.each do |component|
          if component.to_CoilHeatingElectric.is_initialized
            supplemental_coil = component.to_CoilHeatingElectric.get
          elsif component.to_CoilHeatingGas.is_initialized
            supplemental_coil = component.to_CoilHeatingGas.get
          end
        end
      elsif coil.containingHVACComponent.is_initialized
        containing_component = coil.containingHVACComponent.get
        if containing_component.to_AirLoopHVACUnitaryHeatPumpAirToAir.is_initialized
          ashp = containing_component.to_AirLoopHVACUnitaryHeatPumpAirToAir.get
          supplemental_coil = ashp.supplementalHeatingCoil
        elsif containing_component.to_AirLoopHVACUnitaryHeatPumpAirToAirMultiSpeed.is_initialized
          ashpm = containing_component.to_AirLoopHVACUnitaryHeatPumpAirToAirMultiSpeed.get
          supplemental_coil = ashpm.supplementalHeatingCoil
        elsif containing_component.to_AirLoopHVACUnitarySystem.is_initialized
          ashp = containing_component.to_AirLoopHVACUnitarySystem.get
          if ashp.supplementalHeatingCoil.is_initialized
            supplemental_coil = ashp.supplementalHeatingCoil.get
          end
        end
      elsif coil.containingZoneHVACComponent.is_initialized
        containing_component = coil.containingZoneHVACComponent.get
        if containing_component.to_ZoneHVACPackagedTerminalHeatPump.is_initialized
          pthp = containing_component.to_ZoneHVACPackagedTerminalHeatPump.get
          supplemental_coil = pthp.supplementalHeatingCoil
        end
      end

      # There is an OS issue preventing getting the AirLoopHVACUnitarySystem object from a CoilHeatingDXMultiSpeedMultispeed
      # For ComStock, if supplemental coil is still nil, look for it through the AirLoopHVACUnitarySystem object
      if supplemental_coil.nil?
        model.getAirLoopHVACUnitarySystems.each do |system|
          system_heating_coil = system.heatingCoil
          next unless system_heating_coil.is_initialized

          system_heating_coil = system_heating_coil.get
          next unless system_heating_coil.name.to_s == coil.name.to_s

          system_supplemental_coil = system.supplementalHeatingCoil
          next unless system_supplemental_coil.is_initialized

          supplemental_coil = system_supplemental_coil.get
        end
      end

      # get supplemental heating coil capacity
      supplemental_coil_type = nil
      supplemental_capacity_electric_w = 0.0
      supplemental_capacity_gas_w = 0.0
      if supplemental_coil.nil?
        runner.registerWarning("Unable to find supplemental coil paired with DX heating coil #{coil.name}.")
      elsif supplemental_coil.to_CoilHeatingElectric.is_initialized
        supplemental_coil_type = 'electric'
        elec_coil = supplemental_coil.to_CoilHeatingElectric.get
        if elec_coil.nominalCapacity.is_initialized
          supplemental_capacity_electric_w = elec_coil.nominalCapacity.get
        elsif elec_coil.autosizedNominalCapacity.is_initialized
          supplemental_capacity_electric_w = elec_coil.autosizedNominalCapacity.get
        else
          runner.registerWarning("Electric heating coil capacity not available for supplemental heating coil '#{elec_coil.name}'.")
        end
      elsif supplemental_coil.to_CoilHeatingGas.is_initialized
        supplemental_coil_type = 'gas'
        gas_coil = supplemental_coil.to_CoilHeatingGas.get
        if gas_coil.nominalCapacity.is_initialized
          supplemental_capacity_gas_w = gas_coil.nominalCapacity.get
        elsif gas_coil.autosizedNominalCapacity.is_initialized
          supplemental_capacity_gas_w = gas_coil.autosizedNominalCapacity.get
        else
          runner.registerWarning("Gas heating coil capacity not available for supplemental heating coil '#{gas_coil.name}'.")
        end
      else
        runner.registerWarning("Unsupported supplemental heating coil type for heating coil #{supplemental_coil.name}.")
      end
      dx_heating_total_supplemental_capacity_w += supplemental_capacity_electric_w + supplemental_capacity_gas_w
      dx_heating_total_supplemental_capacity_electric_w += supplemental_capacity_electric_w
      dx_heating_total_supplemental_capacity_gas_w += supplemental_capacity_gas_w

      # get supplemental heating coil energy
      supplemental_coil_heating_energy_j = 0.0
      supplemental_electric_j = 0.0
      supplemental_gas_j = 0.0
      unless supplemental_coil.nil?
        runner.registerInfo("'#{supplemental_coil.name}' is the supplemental heating coil for DX heating coil '#{coil.name}'")

        # supplemental heating coil heating energy
        supplemental_coil_heating_energy_j = sql_get_report_variable_data_double(runner, sql, supplemental_coil, 'Heating Coil Heating Energy')

        # supplemental heating coil electric or gas energy
        fuel = supplemental_coil_type == 'gas' ? gas : elec
        if supplemental_coil_type == 'electric'
          supplemental_electric_j = sql_get_report_variable_data_double(runner, sql, supplemental_coil, "Heating Coil #{fuel} Energy")
        elsif supplemental_coil_type == 'gas'
          supplemental_gas_j = sql_get_report_variable_data_double(runner, sql, supplemental_coil, "Heating Coil #{fuel} Energy")
        end
      end
      dx_heating_total_supplemental_load_j += supplemental_coil_heating_energy_j
      dx_heating_total_supplemental_load_electric_j += supplemental_coil_heating_energy_j if supplemental_coil_type == 'electric'
      dx_heating_total_supplemental_load_gas_j += supplemental_coil_heating_energy_j if supplemental_coil_type == 'gas'
      dx_heating_total_supplemental_electric_j += supplemental_electric_j
      dx_heating_total_supplemental_gas_j += supplemental_gas_j

      # get DX Heating Coil efficiency rating
      coil_hspf = 0.0
      var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = 'EquipmentSummary' AND ReportForString = 'Entire Facility' AND TableName = 'DX Heating Coils' AND RowName = '#{coil.name.get.to_s.upcase}' AND ColumnName = 'HSPF'"
      val = sql.execAndReturnFirstDouble(var_val_query)
      if val.is_initialized
        coil_hspf = val.get
      else
        runner.registerWarning("Coil 'HSPF' not available for DX heating coil '#{coil.name}'.")
      end

      # get Heating Coil Heating Energy
      coil_heating_energy_j = sql_get_report_variable_data_double(runner, sql, coil, 'Heating Coil Heating Energy')

      # get Heating Coil Electric Energy
      coil_electric_energy_j = sql_get_report_variable_data_double(runner, sql, coil, "Heating Coil #{elec} Energy")

      # get Heating Coil Defrost Electric Energy
      coil_defrost_electric_energy_j = sql_get_report_variable_data_double(runner, sql, coil, "Heating Coil Defrost #{elec} Energy")

      # get heating coil crankcase heater Electric Energy
      coil_crankcase_heater_electric_energy_j = sql_get_report_variable_data_double(runner, sql, coil, "Heating Coil Crankcase Heater #{elec} Energy")

      # add to weighted load cop
      total_heating_j = coil_heating_energy_j + supplemental_coil_heating_energy_j
      total_energy_input_j = coil_electric_energy_j + supplemental_electric_j + supplemental_gas_j + coil_defrost_electric_energy_j + coil_crankcase_heater_electric_energy_j
      coil_annual_cop = coil_heating_energy_j > 0.0 ? coil_heating_energy_j / coil_electric_energy_j : 0.0
      annual_total_cop = total_heating_j > 0.0 ? total_heating_j / total_energy_input_j : 0.0
      dx_heating_total_dx_electric_j += coil_electric_energy_j
      dx_heating_total_dx_load_j += coil_heating_energy_j
      dx_heating_total_load_j += total_heating_j
      dx_heating_defrost_energy_j += coil_defrost_electric_energy_j
      dx_heating_total_crankcase_electric_j += coil_crankcase_heater_electric_energy_j
      dx_heating_load_weighted_cop += coil_heating_energy_j * coil_annual_cop
      dx_heating_load_weighted_total_cop += total_heating_j * annual_total_cop
      dx_heating_load_weighted_design_cop += coil_heating_energy_j * coil_design_cop
      dx_heating_load_weighted_design_cop_17F += coil_heating_energy_j * coil_design_cop_17F
      dx_heating_load_weighted_design_cop_5F += coil_heating_energy_j * coil_design_cop_5F
      dx_heating_load_weighted_design_cop_0F += coil_heating_energy_j * coil_design_cop_0F

      # log count of sizes, load, and COPs by equipment size
      capacity_kbtuh = OpenStudio.convert(capacity_w, 'W', 'kBtu/h').get
      if capacity_kbtuh < 30
        dx_heating_count_0_to_30_kbtuh += 1
        dx_heating_0_to_30_kbtuh_total_load_j += coil_heating_energy_j
        dx_heating_load_weighted_design_hspf_0_to_30_kbtuh += coil_heating_energy_j * coil_hspf
      elsif capacity_kbtuh < 65
        dx_heating_count_30_to_65_kbtuh += 1
        dx_heating_30_to_65_kbtuh_total_load_j += coil_heating_energy_j
        dx_heating_load_weighted_design_hspf_30_to_65_kbtuh += coil_heating_energy_j * coil_hspf
      elsif capacity_kbtuh < 135
        dx_heating_count_65_to_135_kbtuh += 1
        dx_heating_65_to_135_kbtuh_total_load_j += coil_heating_energy_j
        dx_heating_load_weighted_design_cop_65_to_135_kbtuh += coil_heating_energy_j * coil_design_cop
      elsif capacity_kbtuh < 240
        dx_heating_count_135_to_240_kbtuh += 1
        dx_heating_135_to_240_kbtuh_total_load_j += coil_heating_energy_j
        dx_heating_load_weighted_design_cop_135_to_240_kbtuh += coil_heating_energy_j * coil_design_cop
      else # capacity is over 240 kbtuh
        dx_heating_count_240_plus_kbtuh += 1
        dx_heating_240_plus_kbtuh_total_load_j += coil_heating_energy_j
        dx_heating_load_weighted_design_cop_240_plus_kbtuh += coil_heating_energy_j * coil_design_cop
      end

      # heating coil info logging
      runner.registerInfo("Heating coil '#{coil.name}' has design capacity #{capacity_w.round(2)} W, design cop #{coil_design_cop.round(2)}, annual weighted cop #{coil_annual_cop.round(2)}, and minimum operating temperature is #{minimum_temp_c} C.")
    end
    # report out DX heating COPs
    average_dx_heating_total_cop = dx_heating_total_load_j > 0.0 ? dx_heating_load_weighted_total_cop / dx_heating_total_load_j : 0.0
    runner.registerValue('com_report_hvac_dx_heating_average_total_cop', average_dx_heating_total_cop)
    average_dx_heating_cop = dx_heating_total_dx_load_j > 0.0 ? dx_heating_load_weighted_cop / dx_heating_total_dx_load_j : 0.0
    runner.registerValue('com_report_hvac_dx_heating_average_cop', average_dx_heating_cop)
    dx_heating_design_cop = dx_heating_total_dx_load_j > 0.0 ? dx_heating_load_weighted_design_cop / dx_heating_total_dx_load_j : 0.0
    runner.registerValue('com_report_hvac_dx_heating_design_cop', dx_heating_design_cop)
    dx_heating_design_cop_17F = dx_heating_total_dx_load_j > 0.0 ? dx_heating_load_weighted_design_cop_17F / dx_heating_total_dx_load_j : 0.0
    runner.registerValue('com_report_hvac_dx_heating_design_cop_17f', dx_heating_design_cop_17F)
    dx_heating_design_cop_5F = dx_heating_total_dx_load_j > 0.0 ? dx_heating_load_weighted_design_cop_5F / dx_heating_total_dx_load_j : 0.0
    runner.registerValue('com_report_hvac_dx_heating_design_cop_5f', dx_heating_design_cop_5F)
    dx_heating_design_cop_0F = dx_heating_total_dx_load_j > 0.0 ? dx_heating_load_weighted_design_cop_0F / dx_heating_total_dx_load_j : 0.0
    runner.registerValue('com_report_hvac_dx_heating_design_cop_0f', dx_heating_design_cop_0F)

    # report out DX heating HSPFs and COPs at each size category
    dx_heating_design_hspf_0_to_30_kbtuh = dx_heating_0_to_30_kbtuh_total_load_j > 0.0 ? dx_heating_load_weighted_design_hspf_0_to_30_kbtuh / dx_heating_0_to_30_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_heating_design_hspf_0_to_30_kbtuh', dx_heating_design_hspf_0_to_30_kbtuh)
    dx_heating_design_hspf_30_to_65_kbtuh = dx_heating_30_to_65_kbtuh_total_load_j > 0.0 ? dx_heating_load_weighted_design_hspf_30_to_65_kbtuh / dx_heating_30_to_65_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_heating_design_hspf_30_to_65_kbtuh', dx_heating_design_hspf_30_to_65_kbtuh)
    dx_heating_design_cop_65_to_135_kbtuh = dx_heating_65_to_135_kbtuh_total_load_j > 0.0 ? dx_heating_load_weighted_design_cop_65_to_135_kbtuh / dx_heating_65_to_135_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_heating_design_cop_65_to_135_kbtuh', dx_heating_design_cop_65_to_135_kbtuh)
    dx_heating_design_cop_135_to_240_kbtuh = dx_heating_135_to_240_kbtuh_total_load_j > 0.0 ? dx_heating_load_weighted_design_cop_135_to_240_kbtuh / dx_heating_135_to_240_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_heating_design_cop_135_to_240_kbtuh', dx_heating_design_cop_135_to_240_kbtuh)
    dx_heating_design_cop_240_plus_kbtuh = dx_heating_240_plus_kbtuh_total_load_j > 0.0 ? dx_heating_load_weighted_design_cop_240_plus_kbtuh / dx_heating_240_plus_kbtuh_total_load_j : 0
    runner.registerValue('com_report_hvac_dx_heating_design_cop_240_plus_kbtuh', dx_heating_design_cop_240_plus_kbtuh)

    # report out minimum operating temperatures
    weighted_min_temp_c = dx_heating_total_capacity_w > 0.0 ? dx_heating_capacity_weighted_min_temp_w_c / dx_heating_total_capacity_w : 0.0
    # weighted_min_temp_c = OpenStudio.convert(weighted_min_temp_k, 'K', 'C').get
    runner.registerValue('com_report_hvac_dx_heating_average_minimum_operating_temperature_c', weighted_min_temp_c)

    # report out DX heating capacities
    dx_heating_total_capacity_kbtuh = OpenStudio.convert(dx_heating_total_capacity_w, 'W', 'kBtu/h').get
    runner.registerValue('com_report_hvac_dx_heating_capacity_kbtuh', dx_heating_total_capacity_kbtuh)
    dx_heating_total_capacity_17F_kbtuh = OpenStudio.convert(dx_heating_total_capacity_17F_w, 'W', 'kBtu/h').get
    runner.registerValue('com_report_hvac_dx_heating_capacity_17f_kbtuh', dx_heating_total_capacity_17F_kbtuh)
    dx_heating_total_capacity_5F_kbtuh = OpenStudio.convert(dx_heating_total_capacity_5F_w, 'W', 'kBtu/h').get
    runner.registerValue('com_report_hvac_dx_heating_capacity_5f_kbtuh', dx_heating_total_capacity_5F_kbtuh)
    dx_heating_total_capacity_0F_kbtuh = OpenStudio.convert(dx_heating_total_capacity_0F_w, 'W', 'kBtu/h').get
    runner.registerValue('com_report_hvac_dx_heating_capacity_0f_kbtuh', dx_heating_total_capacity_0F_kbtuh)
    runner.registerValue('com_report_hvac_count_dx_heating_0_to_30_kbtuh', dx_heating_count_0_to_30_kbtuh)
    runner.registerValue('com_report_hvac_count_dx_heating_30_to_65_kbtuh', dx_heating_count_30_to_65_kbtuh)
    runner.registerValue('com_report_hvac_count_dx_heating_65_to_135_kbtuh', dx_heating_count_65_to_135_kbtuh)
    runner.registerValue('com_report_hvac_count_dx_heating_135_to_240_kbtuh', dx_heating_count_135_to_240_kbtuh)
    runner.registerValue('com_report_hvac_count_dx_heating_240_plus_kbtuh', dx_heating_count_240_plus_kbtuh)

    # report out crankcase heater capacities
    dx_heating_total_crankcase_capacity_kbtuh = OpenStudio.convert(dx_heating_total_crankcase_capacity_w, 'W', 'kBtu/h').get
    runner.registerValue('com_report_hvac_dx_heating_crankcase_heater_capacity_kbtuh', dx_heating_total_crankcase_capacity_kbtuh)

    # report out DX heating load and electric
    runner.registerValue('com_report_hvac_dx_heating_total_dx_electric_j', dx_heating_total_dx_electric_j)
    runner.registerValue('com_report_hvac_dx_heating_total_dx_load_j', dx_heating_total_dx_load_j)
    runner.registerValue('com_report_hvac_dx_heating_total_load_j', dx_heating_total_load_j)

    # report out supplemental heating capacity
    dx_heating_total_supplemental_capacity_kbtuh = OpenStudio.convert(dx_heating_total_supplemental_capacity_w, 'W', 'kBtu/h').get
    runner.registerValue('com_report_hvac_dx_heating_supplemental_capacity_kbtuh', dx_heating_total_supplemental_capacity_kbtuh)
    dx_heating_total_supplemental_capacity_electric_kbtuh = OpenStudio.convert(dx_heating_total_supplemental_capacity_electric_w, 'W', 'kBtu/h').get
    runner.registerValue('com_report_hvac_dx_heating_supplemental_capacity_electric_kbtuh', dx_heating_total_supplemental_capacity_electric_kbtuh)
    dx_heating_total_supplemental_capacity_gas_kbtuh = OpenStudio.convert(dx_heating_total_supplemental_capacity_gas_w, 'W', 'kBtu/h').get
    runner.registerValue('com_report_hvac_dx_heating_supplemental_capacity_gas_kbtuh', dx_heating_total_supplemental_capacity_gas_kbtuh)

    # report out fraction of dx heating equipment load met by supplemental equipment
    dx_heating_fraction_heating_load_supplemental = 0.0
    if dx_heating_total_supplemental_load_j > 0.0
      dx_heating_fraction_heating_load_supplemental = (dx_heating_total_supplemental_load_j / (dx_heating_total_supplemental_load_j + dx_heating_total_dx_load_j))
    end
    runner.registerValue('com_report_hvac_dx_heating_fraction_heating_load_supplemental', dx_heating_fraction_heating_load_supplemental)

    # report out DX supplemental heating load and electric
    runner.registerValue('com_report_hvac_dx_heating_total_supplemental_load_j', dx_heating_total_supplemental_load_j)
    runner.registerValue('com_report_hvac_dx_heating_total_supplemental_load_electric_j', dx_heating_total_supplemental_load_electric_j)
    runner.registerValue('com_report_hvac_dx_heating_total_supplemental_load_gas_j', dx_heating_total_supplemental_load_gas_j)
    runner.registerValue('com_report_hvac_dx_heating_total_supplemental_electric_j', dx_heating_total_supplemental_electric_j)
    runner.registerValue('com_report_hvac_dx_heating_total_supplemental_gas_j', dx_heating_total_supplemental_gas_j)

    # fraction of DX heating associated electric that is supplemental
    dx_heating_fraction_electric_supplemental = 0.0
    if dx_heating_total_supplemental_load_electric_j > 0.0
      dx_heating_fraction_electric_supplemental = dx_heating_total_supplemental_load_electric_j / (dx_heating_total_supplemental_load_electric_j + dx_heating_defrost_energy_j + dx_heating_total_dx_electric_j)
    end
    runner.registerValue('com_report_hvac_dx_heating_fraction_electric_supplemental', dx_heating_fraction_electric_supplemental)

    # report out DX heating defrost energy and fraction of heating energy
    dx_heating_defrost_energy_kwh = OpenStudio.convert(dx_heating_defrost_energy_j, 'J', 'kWh').get
    runner.registerValue('com_report_hvac_dx_heating_defrost_energy_kwh', dx_heating_defrost_energy_kwh)
    dx_heating_ratio_defrost_to_heating_load = 0.0
    if dx_heating_defrost_energy_j > 0.0
      dx_heating_ratio_defrost_to_heating_load = (dx_heating_defrost_energy_j / (dx_heating_total_supplemental_load_j + dx_heating_total_dx_load_j))
    end
    runner.registerValue('com_report_hvac_dx_heating_ratio_defrost_to_heating_load', dx_heating_ratio_defrost_to_heating_load)

    # fraction of DX heating associated electric that is defrost
    dx_heating_fraction_electric_defrost = 0.0
    if dx_heating_defrost_energy_j > 0.0
      dx_heating_fraction_electric_defrost = dx_heating_defrost_energy_j / (dx_heating_total_supplemental_load_electric_j + dx_heating_defrost_energy_j + dx_heating_total_dx_electric_j)
    end
    runner.registerValue('com_report_hvac_dx_heating_fraction_electric_defrost', dx_heating_fraction_electric_defrost)

    # report out crankcase heater energy
    dx_heating_crankcase_heater_energy_kwh = OpenStudio.convert(dx_heating_total_crankcase_electric_j, 'J', 'kWh').get
    runner.registerValue('com_report_hvac_dx_heating_crankcase_heater_energy_kwh', dx_heating_crankcase_heater_energy_kwh)

    # cycling ratio for unitary system
    # initialize variables
    cycling_ratio_cooling_weighted_sum = 0.0
    cycling_ratio_heating_weighted_sum = 0.0
    cycling_excess_electricity_used_cooling_pcnt = 0.0
    cycling_excess_electricity_used_heating_pcnt = 0.0
    total_capacity_w_cooling = 0.0
    total_capacity_w_heating = 0.0
    # loop through airloophvac unitary systems
    model.getAirLoopHVACUnitarySystems.each do |airloopunisys|
      # initialize variables
      avg_cycling_ratio_cooling = 0.0
      avg_cycling_ratio_heating = 0.0
      capacity_w_cooling = 0.0
      capacity_w_heating = 0.0
      avg_excess_electricity_used_in_pcnt_c = 0.0
      avg_excess_electricity_used_in_pcnt_h = 0.0
      # get timeseries data from unitary system
      ts_cycling_ratio_multi_spd = sql.timeSeries(ann_env_pd, timeseries_timestep, 'Unitary System DX Coil Cycling Ratio', airloopunisys.name.to_s.upcase) # dimensionless
      ts_cycling_ratio_multi_spd = convert_timeseries_to_list(ts_cycling_ratio_multi_spd)
      ts_cycling_ratio_two_spd = sql.timeSeries(ann_env_pd, timeseries_timestep, 'Unitary System Cycling Ratio', airloopunisys.name.to_s.upcase) # dimensionless
      ts_cycling_ratio_two_spd = convert_timeseries_to_list(ts_cycling_ratio_two_spd)
      ts_part_load_ratio = sql.timeSeries(ann_env_pd, timeseries_timestep, 'Unitary System Part Load Ratio', airloopunisys.name.to_s.upcase) # dimensionless
      ts_part_load_ratio = convert_timeseries_to_list(ts_part_load_ratio)
      ts_tot_cooling_rate = sql.timeSeries(ann_env_pd, timeseries_timestep, 'Unitary System Total Cooling Rate', airloopunisys.name.to_s.upcase) # W
      ts_tot_cooling_rate = convert_timeseries_to_list(ts_tot_cooling_rate)
      ts_tot_heating_rate = sql.timeSeries(ann_env_pd, timeseries_timestep, 'Unitary System Total Heating Rate', airloopunisys.name.to_s.upcase) # W
      ts_tot_heating_rate = convert_timeseries_to_list(ts_tot_heating_rate)
      ts_tot_electricity_rate = sql.timeSeries(ann_env_pd, timeseries_timestep, 'Unitary System Electricity Rate', airloopunisys.name.to_s.upcase) # W
      ts_tot_electricity_rate = convert_timeseries_to_list(ts_tot_electricity_rate)

      if airloopunisys.coolingCoil.is_initialized
        # get coil object
        coil_cooling = airloopunisys.coolingCoil.get
        # get appropriate cycling ratio timeseries depending on coil type
        ts_cycling_ratio = nil
        if coil_cooling.to_CoilCoolingDXTwoSpeed.is_initialized
          ts_cycling_ratio = ts_cycling_ratio_two_spd
        elsif coil_cooling.to_CoilCoolingDXMultiSpeed.is_initialized
          ts_cycling_ratio = ts_cycling_ratio_multi_spd
        end
        # caculation on cooling side
        if !ts_cycling_ratio.nil? | ts_tot_cooling_rate.nil?
          # get coil capacity and cop
          capacity_w_cooling, = get_cooling_coil_capacity_and_cop(runner, model, coil_cooling)
          total_capacity_w_cooling += capacity_w_cooling
          # get part load fraction correlation curve
          curve_plr_to_plf_c = get_cooling_coil_curves(runner, coil_cooling)
          # filter cycling ratio when cooling and calculate average
          ts_cycling_ratio_filtered = ts_cycling_ratio.zip(ts_tot_cooling_rate).select do |_ai, bi|
            bi.positive?
          end.map(&:first)
          avg_cycling_ratio_cooling = get_average_from_array(ts_cycling_ratio_filtered)
          # filter part load ratio when cooling
          ts_part_load_ratio_filtered = ts_part_load_ratio.zip(ts_tot_cooling_rate).select do |_ai, bi|
            bi.positive?
          end.map(&:first)
          # filter electricity used (W) when cooling
          ts_tot_electricity_rate_filtered = ts_tot_electricity_rate.zip(ts_tot_cooling_rate).select do |_ai, bi|
            bi.positive?
          end.map(&:first)
          # get part load fraction from part load ratio
          ts_part_load_fraction_filtered = ts_part_load_ratio_filtered.map do |value|
            curve_plr_to_plf_c.evaluate(value)
          end
          # calculate excessive electricity used due to cycling
          ts_excess_electricity_rate_filtered = ts_tot_electricity_rate_filtered.zip(ts_part_load_fraction_filtered).map do |ai, bi|
            ai * (1 - bi)
          end
          # calculate excessive electricity used due to cycling in % and calculate average
          ts_excess_electricity_pcnt_filtered = ts_excess_electricity_rate_filtered.zip(ts_tot_electricity_rate_filtered).map do |ai, bi|
            ai / bi.to_f * 100
          end
          avg_excess_electricity_used_in_pcnt_c = get_average_from_array(ts_excess_electricity_pcnt_filtered)
        end
      end

      # caculation on heating side
      if airloopunisys.heatingCoil.is_initialized
        # get coil object
        coil_heating = airloopunisys.heatingCoil.get
        # get appropriate cycling ratio timeseries depending on coil type
        ts_cycling_ratio = nil
        if coil_heating.to_CoilHeatingDXMultiSpeed.is_initialized
          ts_cycling_ratio = ts_cycling_ratio_multi_spd
        end
        if !ts_cycling_ratio.nil? | ts_tot_heating_rate.nil?
          # get coil capacity and cop
          capacity_w_heating, = get_heating_coil_capacity_and_cop(runner, model, coil_heating)
          total_capacity_w_heating += capacity_w_heating
          # get part load fraction correlation curve
          curve_plr_to_plf_h = get_heating_coil_curves(runner, coil_heating)
          # filter cycling ratio when cooling and calculate average
          ts_cycling_ratio_filtered = ts_cycling_ratio.zip(ts_tot_heating_rate).select do |_ai, bi|
            bi.positive?
          end.map(&:first)
          avg_cycling_ratio_heating = get_average_from_array(ts_cycling_ratio_filtered)
          # filter part load ratio when cooling
          ts_part_load_ratio_filtered = ts_part_load_ratio.zip(ts_tot_heating_rate).select do |_ai, bi|
            bi.positive?
          end.map(&:first)
          # filter electricity used (W) when cooling
          ts_tot_electricity_rate_filtered = ts_tot_electricity_rate.zip(ts_tot_heating_rate).select do |_ai, bi|
            bi.positive?
          end.map(&:first)
          # get part load fraction from part load ratio
          ts_part_load_fraction_filtered = ts_part_load_ratio_filtered.map do |value|
            curve_plr_to_plf_h.evaluate(value)
          end
          # calculate excessive electricity used due to cycling
          ts_excess_electricity_rate_filtered = ts_tot_electricity_rate_filtered.zip(ts_part_load_fraction_filtered).map do |ai, bi|
            ai * (1 - bi)
          end
          # calculate excessive electricity used due to cycling in % and calculate average
          ts_excess_electricity_pcnt_filtered = ts_excess_electricity_rate_filtered.zip(ts_tot_electricity_rate_filtered).map do |ai, bi|
            ai / bi.to_f * 100
          end
          avg_excess_electricity_used_in_pcnt_h = get_average_from_array(ts_excess_electricity_pcnt_filtered)
        end
      end
      # calculate weighted sum
      cycling_ratio_cooling_weighted_sum += avg_cycling_ratio_cooling * capacity_w_cooling
      cycling_ratio_heating_weighted_sum += avg_cycling_ratio_heating * capacity_w_heating
      cycling_excess_electricity_used_cooling_pcnt += avg_excess_electricity_used_in_pcnt_c * capacity_w_cooling
      cycling_excess_electricity_used_heating_pcnt += avg_excess_electricity_used_in_pcnt_h * capacity_w_heating
    end
    # calculate weighted average
    com_report_unitary_sys_cycling_ratio_cooling = total_capacity_w_cooling > 0.0 ? cycling_ratio_cooling_weighted_sum / total_capacity_w_cooling : 0.0
    com_report_unitary_sys_cycling_ratio_heating = total_capacity_w_heating > 0.0 ? cycling_ratio_heating_weighted_sum / total_capacity_w_heating : 0.0
    com_report_unitary_sys_cycling_excess_electricity_cooling_pcnt = total_capacity_w_cooling > 0.0 ? cycling_excess_electricity_used_cooling_pcnt / total_capacity_w_cooling : 0.0
    com_report_unitary_sys_cycling_excess_electricity_heating_pcnt = total_capacity_w_heating > 0.0 ? cycling_excess_electricity_used_heating_pcnt / total_capacity_w_heating : 0.0
    runner.registerValue('com_report_unitary_sys_cycling_ratio_cooling', com_report_unitary_sys_cycling_ratio_cooling)
    runner.registerValue('com_report_unitary_sys_cycling_ratio_heating', com_report_unitary_sys_cycling_ratio_heating)
    runner.registerValue('com_report_unitary_sys_cycling_excess_electricity_cooling_pcnt',
                         com_report_unitary_sys_cycling_excess_electricity_cooling_pcnt)
    runner.registerValue('com_report_unitary_sys_cycling_excess_electricity_heating_pcnt',
                         com_report_unitary_sys_cycling_excess_electricity_heating_pcnt)

    # Get the outdoor air temp timeseries and calculate heating and cooling degree days
    # Per ISO 15927-6, "Accumulated hourly temperature differences shall be calculated according to 4.4 when hourly data are available. When hourly data are not available, the approximate method given in 4.5, based on the maximum and minimum temperatures each day, may be used."
    # Method 4.4 is used here, summing hour values over/under a threshold and then dividing by 24
    # Method 4.5 is commonly used elsewhere, averaging the minimum and maximum daily values, and differencing versus the threshold.

    # Get the outdoor air temp timeseries
    hours_below_minus_20_F = -999
    hours_below_0_F = -999
    hours_below_5_F = -999
    hours_below_17_F = -999
    hours_below_50_F = -999
    hours_above_65_F = -999
    hdd50f = -999
    hdd65f = -999
    cdd50f = -999
    cdd65f = -999
    oa_temps_f = nil
    oa_temps_ts = sql.timeSeries(ann_env_pd, 'Hourly', 'Site Outdoor Air Drybulb Temperature', 'Environment')
    if oa_temps_ts.is_initialized
      # Put values into array
      oa_temps_f = []
      vals = oa_temps_ts.get.values
      for i in 0..(vals.size - 1)
        oa_temps_f << OpenStudio.convert(vals[i], 'C', 'F').get
      end
      hours_below_minus_20_F = oa_temps_f.count { |val| val < -20.0 }
      hours_below_0_F = oa_temps_f.count { |val| val < 0.0 }
      hours_below_5_F = oa_temps_f.count { |val| val < 5.0 }
      hours_below_17_F = oa_temps_f.count { |val| val < 17.0 }
      hours_below_50_F = oa_temps_f.count { |val| val < 50.0 }
      hours_above_65_F = oa_temps_f.count { |val| val > 65.0 }
      hdd50f = oa_temps_f.sum { |val| val < 50.0 ? 50.0 - val : 0.0 }
      hdd50f /= 24.0
      hdd65f = oa_temps_f.sum { |val| val < 65.0 ? 65.0 - val : 0.0 }
      hdd65f /= 24.0
      cdd50f = oa_temps_f.sum { |val| val > 50.0 ? val - 50.0 : 0.0 }
      cdd50f /= 24.0
      cdd65f = oa_temps_f.sum { |val| val > 65.0 ? val - 65.0 : 0.0 }
      cdd65f /= 24.0
    else
      runner.registerWarning('Site Outdoor Air Drybulb Temperature could not be found, cannot calculate hours below x degF.')
    end
    runner.registerValue('com_report_hours_below_minus_20_f', hours_below_minus_20_F)
    runner.registerValue('com_report_hours_below_0_f', hours_below_0_F)
    runner.registerValue('com_report_hours_below_5_f', hours_below_5_F)
    runner.registerValue('com_report_hours_below_17_f', hours_below_17_F)
    runner.registerValue('com_report_hours_below_50_f', hours_below_50_F)
    runner.registerValue('com_report_hours_above_65_f', hours_above_65_F)
    runner.registerValue('com_report_hdd50f', hdd50f)
    runner.registerValue('com_report_hdd65f', hdd65f)
    runner.registerValue('com_report_cdd50f', cdd50f)
    runner.registerValue('com_report_cdd65f', cdd65f)

    # Boiler capacity, load, and efficiencies
    boiler_total_load_j = 0.0
    boiler_total_electric_j = 0.0
    boiler_total_gas_j = 0.0
    boiler_total_other_fuel_j = 0.0
    boiler_capacity_weighted_design_efficiency = 0.0
    boiler_load_weighted_design_efficiency = 0.0
    boiler_load_weighted_efficiency = 0.0
    boiler_total_capacity_w = 0.0
    boiler_count = 0.0
    boiler_count_0_to_300_kbtuh = 0.0
    boiler_count_300_to_2500_kbtuh = 0.0
    boiler_count_2500_plus_kbtuh = 0.0
    model.getBoilerHotWaters.sort.each do |boiler|
      boiler_fuel_type = boiler.fuelType

      # get boiler capacity
      capacity_w = 0.0
      if boiler.nominalCapacity.is_initialized
        capacity_w = boiler.nominalCapacity.get
      elsif boiler.autosizedNominalCapacity.is_initialized
        capacity_w = boiler.autosizedNominalCapacity.get
      else
        runner.registerWarning("Boiler capacity not available for boiler '#{boiler.name}'.")
      end
      boiler_design_efficiency = boiler.nominalThermalEfficiency
      boiler_total_capacity_w += capacity_w
      boiler_capacity_weighted_design_efficiency += capacity_w * boiler_design_efficiency

      # get Boiler Heating Energy
      boiler_heating_energy_j = sql_get_report_variable_data_double(runner, sql, boiler, 'Boiler Heating Energy')

      # boiler electric or gas energy
      boiler_gas_energy_j = 0.0
      boiler_electric_energy_j = 0.0
      boiler_other_fuel_energy_j = 0.0
      case boiler_fuel_type
      when 'Electricity', 'Electric'
        fuel = elec
        boiler_electric_energy_j = sql_get_report_variable_data_double(runner, sql, boiler, "Boiler #{fuel} Energy")
      when 'NaturalGas', 'Gas'
        fuel = gas
        boiler_gas_energy_j = sql_get_report_variable_data_double(runner, sql, boiler, "Boiler #{fuel} Energy")
      else
        fuel = boiler_fuel_type
        boiler_other_fuel_energy_j = sql_get_report_variable_data_double(runner, sql, boiler, "Boiler #{fuel} Energy")
      end

      # add to weighted load efficiency
      boiler_input_energy_j = boiler_gas_energy_j + boiler_electric_energy_j + boiler_other_fuel_energy_j
      boiler_annual_efficiency = boiler_input_energy_j > 0.0 ? boiler_heating_energy_j / boiler_input_energy_j : 0.0
      boiler_total_load_j += boiler_heating_energy_j
      boiler_total_electric_j += boiler_electric_energy_j
      boiler_total_gas_j += boiler_gas_energy_j
      boiler_total_other_fuel_j += boiler_other_fuel_energy_j
      boiler_load_weighted_efficiency += boiler_heating_energy_j * boiler_annual_efficiency
      boiler_load_weighted_design_efficiency += boiler_heating_energy_j * boiler_design_efficiency

      # log count of sizes
      boiler_count += 1
      capacity_kbtuh = OpenStudio.convert(capacity_w, 'W', 'kBtu/h').get
      if capacity_kbtuh < 300
        boiler_count_0_to_300_kbtuh += 1
      elsif capacity_kbtuh < 2500
        boiler_count_300_to_2500_kbtuh += 1
      else # capacity is over 2500 kbtuh
        boiler_count_2500_plus_kbtuh += 1
      end
    end
    average_boiler_capacity_weighted_design_efficiency = boiler_total_capacity_w > 0.0 ? boiler_capacity_weighted_design_efficiency / boiler_total_capacity_w : 0.0
    runner.registerValue('com_report_hvac_boiler_capacity_weighted_design_efficiency', average_boiler_capacity_weighted_design_efficiency)
    average_boiler_load_weighted_design_efficiency = boiler_total_load_j > 0.0 ? boiler_load_weighted_design_efficiency / boiler_total_load_j : 0.0
    runner.registerValue('com_report_hvac_boiler_load_weighted_design_efficiency', average_boiler_load_weighted_design_efficiency)
    average_boiler_efficiency = boiler_total_load_j > 0.0 ? boiler_load_weighted_efficiency / boiler_total_load_j : 0.0
    runner.registerValue('com_report_hvac_boiler_average_efficiency', average_boiler_efficiency)
    runner.registerValue('com_report_hvac_boiler_total_load_j', boiler_total_load_j)
    runner.registerValue('com_report_hvac_boiler_total_electric_j', boiler_total_electric_j)
    runner.registerValue('com_report_hvac_boiler_total_gas_j', boiler_total_gas_j)
    runner.registerValue('com_report_hvac_boiler_total_other_fuel_j', boiler_total_other_fuel_j)
    boiler_total_capacity_kbtuh = OpenStudio.convert(boiler_total_capacity_w, 'W', 'kBtu/h').get
    runner.registerValue('com_report_hvac_boiler_capacity_kbtuh', boiler_total_capacity_kbtuh)
    runner.registerValue('com_report_hvac_count_boilers', boiler_count)
    runner.registerValue('com_report_hvac_count_boilers_0_to_300_kbtuh', boiler_count_0_to_300_kbtuh)
    runner.registerValue('com_report_hvac_count_boilers_300_to_2500_kbtuh', boiler_count_300_to_2500_kbtuh)
    runner.registerValue('com_report_hvac_count_boilers_2500_plus_kbtuh', boiler_count_2500_plus_kbtuh)

    # Heat pump cooling capacity, load, and efficiencies
    heat_pump_cooling_total_load_j = 0.0
    heat_pump_cooling_total_electric_j = 0.0
    heat_pump_cooling_capacity_weighted_design_cop = 0.0
    heat_pump_cooling_load_weighted_design_cop = 0.0
    heat_pump_cooling_load_weighted_cop = 0.0
    heat_pump_cooling_total_capacity_w = 0.0
    heat_pump_cooling_count = 0.0
    heat_pump_cooling_load_weighted_source_inlet_temperature_c = 0.0
    model.getHeatPumpPlantLoopEIRCoolings.sort.each do |heat_pump|
      # get heat pump cooling capacity
      capacity_w = 0.0
      if heat_pump.referenceCapacity.is_initialized
        capacity_w = heat_pump.referenceCapacity.get
      elsif boiler.autosizedReferenceCapacity.is_initialized
        capacity_w = heat_pump.autosizedReferenceCapacity.get
      else
        runner.registerWarning("Capacity not available for HeatPumpPlantLoopEIRCooling '#{heat_pump.name}'.")
      end
      heat_pump_cooling_design_cop = heat_pump.referenceCoefficientofPerformance
      heat_pump_cooling_total_capacity_w += capacity_w
      heat_pump_cooling_capacity_weighted_design_cop += capacity_w * heat_pump_cooling_design_cop

      # get Heat Pump Load Side Heat Transfer Energy
      heat_pump_cooling_energy_j = sql_get_report_variable_data_double(runner, sql, heat_pump, 'Heat Pump Load Side Heat Transfer Energy')

      # get Heat Pump Electric Energy
      heat_pump_cooling_electric_energy_j = sql_get_report_variable_data_double(runner, sql, heat_pump, "Heat Pump #{elec} Energy")

      # get Heat Pump Source Side Inlet Temperature
      heat_pump_cooling_source_inlet_temperature_c = sql_get_report_variable_data_double(runner, sql, heat_pump, 'Heat Pump Source Side Inlet Temperature')

      # add to weighted load cop
      heat_pump_cooling_cooling_annual_cop = heat_pump_cooling_energy_j > 0.0 ? heat_pump_cooling_energy_j / heat_pump_cooling_electric_energy_j : 0
      heat_pump_cooling_total_load_j += heat_pump_cooling_energy_j
      heat_pump_cooling_total_electric_j += heat_pump_cooling_electric_energy_j
      heat_pump_cooling_load_weighted_cop += heat_pump_cooling_energy_j * heat_pump_cooling_cooling_annual_cop
      heat_pump_cooling_load_weighted_design_cop += heat_pump_cooling_energy_j * heat_pump_cooling_design_cop

      # add to weighted load temperature
      heat_pump_cooling_load_weighted_source_inlet_temperature_c += heat_pump_cooling_energy_j * heat_pump_cooling_source_inlet_temperature_c

      # log count of sizes
      heat_pump_cooling_count += 1
    end
    average_heat_pump_cooling_capacity_weighted_design_cop = heat_pump_cooling_total_capacity_w > 0.0 ? heat_pump_cooling_capacity_weighted_design_cop / heat_pump_cooling_total_capacity_w : 0.0
    runner.registerValue('com_report_hvac_water_water_heat_pump_cooling_capacity_weighted_design_cop', average_heat_pump_cooling_capacity_weighted_design_cop)
    average_heat_pump_cooling_load_weighted_design_cop = heat_pump_cooling_total_load_j > 0.0 ? heat_pump_cooling_load_weighted_design_cop / heat_pump_cooling_total_load_j : 0.0
    runner.registerValue('com_report_hvac_water_water_heat_pump_cooling_load_weighted_design_cop', average_heat_pump_cooling_load_weighted_design_cop)
    average_heat_pump_cooling_cop = heat_pump_cooling_total_load_j > 0.0 ? heat_pump_cooling_load_weighted_cop / heat_pump_cooling_total_load_j : 0.0
    runner.registerValue('com_report_hvac_water_water_heat_pump_cooling_average_cop', average_heat_pump_cooling_cop)
    runner.registerValue('com_report_hvac_water_water_heat_pump_cooling_total_load_j', heat_pump_cooling_total_load_j)
    runner.registerValue('com_report_hvac_water_water_heat_pump_cooling_total_electric_j', heat_pump_cooling_total_electric_j)
    heat_pump_cooling_total_capacity_kbtuh = OpenStudio.convert(heat_pump_cooling_total_capacity_w, 'W', 'kBtu/h').get
    runner.registerValue('com_report_hvac_water_water_heat_pump_cooling_capacity_kbtuh', heat_pump_cooling_total_capacity_kbtuh)
    runner.registerValue('com_report_hvac_count_water_water_heat_pumps_cooling', heat_pump_cooling_count)
    average_heat_pump_cooling_load_weighted_source_inlet_temperature_c = heat_pump_cooling_total_load_j > 0.0 ? heat_pump_cooling_load_weighted_source_inlet_temperature_c / heat_pump_cooling_total_load_j : -999
    runner.registerValue('com_report_hvac_water_water_heat_pump_cooling_load_weighted_source_inlet_temperature_c', average_heat_pump_cooling_load_weighted_source_inlet_temperature_c)

    # Heat pump heating capacity, load, and efficiencies
    heat_pump_heating_total_load_j = 0.0
    heat_pump_heating_total_electric_j = 0.0
    heat_pump_heating_capacity_weighted_design_cop = 0.0
    heat_pump_heating_load_weighted_design_cop = 0.0
    heat_pump_heating_load_weighted_cop = 0.0
    heat_pump_heating_total_capacity_w = 0.0
    heat_pump_heating_count = 0.0
    heat_pump_heating_count_0_to_300_kbtuh = 0.0
    heat_pump_heating_count_300_to_2500_kbtuh = 0.0
    heat_pump_heating_count_2500_plus_kbtuh = 0.0
    heat_pump_heating_load_weighted_source_inlet_temperature_c = 0.0
    model.getHeatPumpPlantLoopEIRHeatings.sort.each do |heat_pump|
      # get heat pump boiler capacity
      capacity_w = 0.0
      if heat_pump.referenceCapacity.is_initialized
        capacity_w = heat_pump.referenceCapacity.get
      elsif boiler.autosizedReferenceCapacity.is_initialized
        capacity_w = heat_pump.autosizedReferenceCapacity.get
      else
        runner.registerWarning("Capacity not available for HeatPumpPlantLoopEIRHeating '#{heat_pump.name}'.")
      end
      heat_pump_design_cop = heat_pump.referenceCoefficientofPerformance
      heat_pump_heating_total_capacity_w += capacity_w
      heat_pump_heating_capacity_weighted_design_cop += capacity_w * heat_pump_design_cop

      # get Heat Pump Load Side Heat Transfer Energy
      heat_pump_heating_energy_j = sql_get_report_variable_data_double(runner, sql, heat_pump, 'Heat Pump Load Side Heat Transfer Energy')

      # get Heat Pump Electric Energy
      heat_pump_electric_energy_j = sql_get_report_variable_data_double(runner, sql, heat_pump, "Heat Pump #{elec} Energy")

      # get Heat Pump Source Side Inlet Temperature
      heat_pump_heating_source_inlet_temperature_c = sql_get_report_variable_data_double(runner, sql, heat_pump, 'Heat Pump Source Side Inlet Temperature')

      # add to weighted load cop
      heat_pump_heating_annual_cop = heat_pump_heating_energy_j > 0.0 ? heat_pump_heating_energy_j / heat_pump_electric_energy_j : 0
      heat_pump_heating_total_load_j += heat_pump_heating_energy_j
      heat_pump_heating_total_electric_j += heat_pump_electric_energy_j
      heat_pump_heating_load_weighted_cop += heat_pump_heating_energy_j * heat_pump_heating_annual_cop
      heat_pump_heating_load_weighted_design_cop += heat_pump_heating_energy_j * heat_pump_design_cop

      # add to weighted load temperature
      heat_pump_heating_load_weighted_source_inlet_temperature_c += heat_pump_heating_energy_j * heat_pump_heating_source_inlet_temperature_c

      # log count of sizes
      heat_pump_heating_count += 1
      capacity_kbtuh = OpenStudio.convert(capacity_w, 'W', 'kBtu/h').get
      if capacity_kbtuh < 300
        heat_pump_heating_count_0_to_300_kbtuh += 1
      elsif capacity_kbtuh < 2500
        heat_pump_heating_count_300_to_2500_kbtuh += 1
      else # capacity is over 2500 kbtuh
        heat_pump_heating_count_2500_plus_kbtuh += 1
      end
    end
    average_heat_pump_heating_capacity_weighted_design_cop = heat_pump_heating_total_capacity_w > 0.0 ? heat_pump_heating_capacity_weighted_design_cop / heat_pump_heating_total_capacity_w : 0.0
    runner.registerValue('com_report_hvac_water_water_heat_pump_heating_capacity_weighted_design_cop', average_heat_pump_heating_capacity_weighted_design_cop)
    average_heat_pump_heating_load_weighted_design_cop = heat_pump_heating_total_load_j > 0.0 ? heat_pump_heating_load_weighted_design_cop / heat_pump_heating_total_load_j : 0.0
    runner.registerValue('com_report_hvac_water_water_heat_pump_heating_load_weighted_design_cop', average_heat_pump_heating_load_weighted_design_cop)
    average_heat_pump_cop = heat_pump_heating_total_load_j > 0.0 ? heat_pump_heating_load_weighted_cop / heat_pump_heating_total_load_j : 0.0
    runner.registerValue('com_report_hvac_water_water_heat_pump_heating_average_cop', average_heat_pump_cop)
    runner.registerValue('com_report_hvac_water_water_heat_pump_heating_total_load_j', heat_pump_heating_total_load_j)
    runner.registerValue('com_report_hvac_water_water_heat_pump_heating_total_electric_j', heat_pump_heating_total_electric_j)
    heat_pump_heating_total_capacity_kbtuh = OpenStudio.convert(heat_pump_heating_total_capacity_w, 'W', 'kBtu/h').get
    runner.registerValue('com_report_hvac_water_water_heat_pump_heating_capacity_kbtuh', heat_pump_heating_total_capacity_kbtuh)
    runner.registerValue('com_report_hvac_count_water_water_heat_pumps_heating', heat_pump_heating_count)
    runner.registerValue('com_report_hvac_count_water_water_heat_pumps_heating_0_to_300_kbtuh', heat_pump_heating_count_0_to_300_kbtuh)
    runner.registerValue('com_report_hvac_count_water_water_heat_pumps_heating_300_to_2500_kbtuh', heat_pump_heating_count_300_to_2500_kbtuh)
    runner.registerValue('com_report_hvac_count_water_water_heat_pumps_heating_2500_plus_kbtuh', heat_pump_heating_count_2500_plus_kbtuh)
    average_heat_pump_heating_load_weighted_source_inlet_temperature_c = heat_pump_heating_total_load_j > 0.0 ? heat_pump_heating_load_weighted_source_inlet_temperature_c / heat_pump_heating_total_load_j : -999
    runner.registerValue('com_report_hvac_water_water_heat_pump_heating_load_weighted_source_inlet_temperature_c', average_heat_pump_heating_load_weighted_source_inlet_temperature_c)

    # export temperature data for ground loop heat exchangers if present
    num_boreholes = 0.0
    total_borehole_depth_ft = 0.0
    total_ghx_design_flow_rate_ft3_per_min = 0.0
    heat_exchanger_total_energy_j = 0.0
    heat_exchanger_weighted_supply_inlet_temperature_c = 0.0
    heat_exchanger_weighted_supply_outlet_temperature_c = 0.0
    heat_exchanger_weighted_demand_inlet_temperature_c = 0.0
    heat_exchanger_weighted_demand_outlet_temperature_c = 0.0
    model.getPlantLoops.each do |plant_loop|
      is_ground_loop = false
      plant_loop.supplyComponents.each do |component|
        if component.to_GroundHeatExchangerVertical.is_initialized
          is_ground_loop = true
          ghx = component.to_GroundHeatExchangerVertical.get
          num_boreholes += ghx.numberofBoreHoles.is_initialized ? ghx.numberofBoreHoles.get : 0.0
          borehole_depth_m = ghx.boreHoleLength.is_initialized ? ghx.boreHoleLength.get : 0.0
          borehole_depth_ft = OpenStudio.convert(borehole_depth_m, 'm', 'ft').get
          total_borehole_depth_ft += borehole_depth_ft
          ghx_design_flow_rate_m3_per_s = ghx.designFlowRate.is_initialized ? ghx.designFlowRate.get : 0.0
          ghx_design_flow_rate_ft3_per_min = OpenStudio.convert(ghx_design_flow_rate_m3_per_s, 'm^3/s', 'ft^3/min').get
          total_ghx_design_flow_rate_ft3_per_min += ghx_design_flow_rate_ft3_per_min
        end
      end
      next unless is_ground_loop

      # get heat exchanger object
      heat_exchanger = nil
      plant_loop.demandComponents.each do |component|
        if component.to_HeatExchangerFluidToFluid.is_initialized
          heat_exchanger = component.to_HeatExchangerFluidToFluid.get
        end
      end
      next if heat_exchanger.nil?

      # get Fluid Heat Exchanger Heat Transfer Energy
      heat_exchanger_energy_j = sql_get_report_variable_data_double(runner, sql, heat_exchanger, 'Fluid Heat Exchanger Heat Transfer Energy')

      # get Fluid Heat Exchanger Loop Supply Side Inlet Temperature
      heat_exchanger_supply_inlet_temperature_c = sql_get_report_variable_data_double(runner, sql, heat_exchanger, 'Fluid Heat Exchanger Loop Supply Side Inlet Temperature')

      # get Fluid Heat Exchanger Loop Supply Side Outlet Temperature
      heat_exchanger_supply_outlet_temperature_c = sql_get_report_variable_data_double(runner, sql, heat_exchanger, 'Fluid Heat Exchanger Loop Supply Side Outlet Temperature')

      # get Fluid Heat Exchanger Loop Demand Side Inlet Temperature
      heat_exchanger_demand_inlet_temperature_c = sql_get_report_variable_data_double(runner, sql, heat_exchanger, 'Fluid Heat Exchanger Loop Demand Side Inlet Temperature')

      # get Fluid Heat Exchanger Loop Demand Side Outlet Temperature
      heat_exchanger_demand_outlet_temperature_c = sql_get_report_variable_data_double(runner, sql, heat_exchanger, 'Fluid Heat Exchanger Loop Demand Side Outlet Temperature')

      heat_exchanger_total_energy_j += heat_exchanger_energy_j
      heat_exchanger_weighted_supply_inlet_temperature_c += heat_exchanger_energy_j * heat_exchanger_supply_inlet_temperature_c
      heat_exchanger_weighted_supply_outlet_temperature_c += heat_exchanger_energy_j * heat_exchanger_supply_outlet_temperature_c
      heat_exchanger_weighted_demand_inlet_temperature_c += heat_exchanger_energy_j * heat_exchanger_demand_inlet_temperature_c
      heat_exchanger_weighted_demand_outlet_temperature_c += heat_exchanger_energy_j * heat_exchanger_demand_outlet_temperature_c
    end
    runner.registerValue('com_report_hvac_ghx_num_boreholes', num_boreholes)
    average_borehole_depth_ft = num_boreholes > 0.0 ? total_borehole_depth_ft.to_f : 0.0
    runner.registerValue('com_report_hvac_ghx_average_borehole_depth_ft', average_borehole_depth_ft)
    average_ghx_design_flow_rate_ft3_per_min = num_boreholes > 0.0 ? total_ghx_design_flow_rate_ft3_per_min / num_boreholes.to_f : 0.0
    runner.registerValue('com_report_hvac_average_ghx_design_flow_rate_ft3_per_min', average_ghx_design_flow_rate_ft3_per_min)
    runner.registerValue('com_report_hvac_fluid_heat_exchanger_total_transfer_energy_j', heat_exchanger_total_energy_j)
    average_heat_exchanger_weighted_supply_inlet_temperature_c = heat_exchanger_total_energy_j.zero? ? -999 : heat_exchanger_weighted_supply_inlet_temperature_c / heat_exchanger_total_energy_j
    runner.registerValue('com_report_hvac_fluid_heat_exchanger_weighted_supply_inlet_temperature_c', average_heat_exchanger_weighted_supply_inlet_temperature_c)
    average_heat_exchanger_weighted_supply_outlet_temperature_c = heat_exchanger_total_energy_j.zero? ? -999 : heat_exchanger_weighted_supply_outlet_temperature_c / heat_exchanger_total_energy_j
    runner.registerValue('com_report_hvac_fluid_heat_exchanger_weighted_supply_outlet_temperature_c', average_heat_exchanger_weighted_supply_outlet_temperature_c)
    average_heat_exchanger_weighted_demand_inlet_temperature_c = heat_exchanger_total_energy_j.zero? ? -999 : heat_exchanger_weighted_demand_inlet_temperature_c / heat_exchanger_total_energy_j
    runner.registerValue('com_report_hvac_fluid_heat_exchanger_weighted_demand_inlet_temperature_c', average_heat_exchanger_weighted_demand_inlet_temperature_c)
    average_heat_exchanger_weighted_demand_outlet_temperature_c = heat_exchanger_total_energy_j.zero? ? -999 : heat_exchanger_weighted_demand_outlet_temperature_c / heat_exchanger_total_energy_j
    runner.registerValue('com_report_hvac_fluid_heat_exchanger_weighted_demand_outlet_temperature_c', average_heat_exchanger_weighted_demand_outlet_temperature_c)

    # Hot water loop equipment proportion from different heating sources
    hot_water_loop_total_heating_j = boiler_total_load_j + heat_pump_heating_total_load_j
    hot_water_loop_boiler_fraction = hot_water_loop_total_heating_j > 0.0 ? boiler_total_load_j / hot_water_loop_total_heating_j : 0.0
    hot_water_loop_heat_pump_fraction = hot_water_loop_total_heating_j > 0.0 ? heat_pump_heating_total_load_j / hot_water_loop_total_heating_j : 0.0
    runner.registerValue('com_report_hvac_hot_water_loop_total_load_j', hot_water_loop_total_heating_j)
    runner.registerValue('com_report_hvac_hot_water_loop_boiler_fraction', hot_water_loop_boiler_fraction)
    runner.registerValue('com_report_hvac_hot_water_loop_heat_pump_fraction', hot_water_loop_heat_pump_fraction)

    # Average primary gas coil efficiency
    primary_gas_coil_capacity_weighted_efficiency = 0.0
    primary_gas_coil_total_capacity_w = 0.0
    primary_gas_count_0_to_30_kbtuh = 0.0
    primary_gas_count_30_to_65_kbtuh = 0.0
    primary_gas_count_65_to_135_kbtuh = 0.0
    primary_gas_count_135_to_240_kbtuh = 0.0
    primary_gas_count_240_plus_kbtuh = 0.0

    # Average supplemental gas coil efficiency
    supplemental_gas_coil_capacity_weighted_efficiency = 0.0
    supplemental_gas_coil_total_capacity_w = 0.0
    supplemental_gas_count_0_to_30_kbtuh = 0.0
    supplemental_gas_count_30_to_65_kbtuh = 0.0
    supplemental_gas_count_65_to_135_kbtuh = 0.0
    supplemental_gas_count_135_to_240_kbtuh = 0.0
    supplemental_gas_count_240_plus_kbtuh = 0.0

    # iterate through each model to get all of the gas coils and check if they are supplemental coils for Unitary HVAC Objects and count each seperately.
    model.getCoilHeatingGass.sort.each do |coil|
      # get gas coil capacity
      supplemental_capacity_w = 0.0

      # default coil type unless proven otherwise
      supplemental_coil = false

      # check if coil is contained by an unitary equipment and cast the hvac component to its child types
      if coil.containingHVACComponent.is_initialized
        hvac_comp = coil.containingHVACComponent.get
        obj_type = hvac_comp.iddObjectType.valueName
        obj_type_name = obj_type.gsub('OS_', '').gsub('_', '')
        method_name = "to_#{obj_type_name}"
        if hvac_comp.respond_to?(method_name)
          unitary_equip = hvac_comp.method(method_name).call
          if !unitary_equip.empty?
            unitary_equip = unitary_equip.get
          end
        end
      end

      # test if the coil is a supplemental coil on the unitary equipment
      if unitary_equip.respond_to?('supplementalHeatingCoil') && unitary_equip.supplementalHeatingCoil.is_initialized && unitary_equip.supplementalHeatingCoil.get == coil
        supplemental_coil = true
      end

      # get supplemental gas coil capacity
      if supplemental_coil
        if coil.nominalCapacity.is_initialized
          supplemental_capacity_w = coil.nominalCapacity.get
        elsif coil.autosizedNominalCapacity.is_initialized
          supplemental_capacity_w = coil.autosizedNominalCapacity.get
        else
          runner.registerWarning("Gas heating coil capacity not available for '#{coil.name}'.")
        end
        supplemental_gas_coil_total_capacity_w += supplemental_capacity_w
        supplemental_gas_coil_capacity_weighted_efficiency += supplemental_capacity_w * coil.gasBurnerEfficiency

        # log count of sizes
        supplemental_capacity_kbtuh = OpenStudio.convert(supplemental_capacity_w, 'W', 'kBtu/h').get
        if supplemental_capacity_kbtuh < 30
          supplemental_gas_count_0_to_30_kbtuh += 1
        elsif supplemental_capacity_kbtuh < 65
          supplemental_gas_count_30_to_65_kbtuh += 1
        elsif supplemental_capacity_kbtuh < 135
          supplemental_gas_count_65_to_135_kbtuh += 1
        elsif supplemental_capacity_kbtuh < 240
          supplemental_gas_count_135_to_240_kbtuh += 1
        else # capacity is over 240 kbtuh
          supplemental_gas_count_240_plus_kbtuh += 1
        end
      else

        # get primary gas coil capacity
        primary_capacity_w = 0.0
        if coil.nominalCapacity.is_initialized
          primary_capacity_w = coil.nominalCapacity.get
        elsif coil.autosizedNominalCapacity.is_initialized
          primary_capacity_w = coil.autosizedNominalCapacity.get
        else
          runner.registerWarning("Gas heating coil capacity not available for '#{coil.name}'.")
        end
        primary_gas_coil_total_capacity_w += primary_capacity_w
        primary_gas_coil_capacity_weighted_efficiency += primary_capacity_w * coil.gasBurnerEfficiency

        # log count of sizes
        primary_capacity_kbtuh = OpenStudio.convert(primary_capacity_w, 'W', 'kBtu/h').get
        if primary_capacity_kbtuh < 30
          primary_gas_count_0_to_30_kbtuh += 1
        elsif primary_capacity_kbtuh < 65
          primary_gas_count_30_to_65_kbtuh += 1
        elsif primary_capacity_kbtuh < 135
          primary_gas_count_65_to_135_kbtuh += 1
        elsif primary_capacity_kbtuh < 240
          primary_gas_count_135_to_240_kbtuh += 1
        else # capacity is over 240 kbtuh
          primary_gas_count_240_plus_kbtuh += 1
        end
      end
    end
    # report the primary gas coil counts, weight efficiency, and total capacity
    primary_capacity_weighted_gas_coil_efficiency = primary_gas_coil_total_capacity_w > 0.0 ? primary_gas_coil_capacity_weighted_efficiency / primary_gas_coil_total_capacity_w : 0.0
    primary_gas_coil_total_capacity_kbuth = OpenStudio.convert(primary_gas_coil_total_capacity_w, 'W', 'kBtu/h').get
    runner.registerValue('com_report_hvac_capacity_weighted_primary_gas_coil_efficiency', primary_capacity_weighted_gas_coil_efficiency)
    runner.registerValue('com_report_hvac_primary_gas_coil_capacity_kbtuh', primary_gas_coil_total_capacity_kbuth)
    runner.registerValue('com_report_hvac_count_primary_gas_coil_0_to_30_kbtuh', primary_gas_count_0_to_30_kbtuh)
    runner.registerValue('com_report_hvac_count_primary_gas_coil_30_to_65_kbtuh', primary_gas_count_30_to_65_kbtuh)
    runner.registerValue('com_report_hvac_count_primary_gas_coil_65_to_135_kbtuh', primary_gas_count_65_to_135_kbtuh)
    runner.registerValue('com_report_hvac_count_primary_gas_coil_135_to_240_kbtuh', primary_gas_count_135_to_240_kbtuh)
    runner.registerValue('com_report_hvac_count_primary_gas_coil_240_plus_kbtuh', primary_gas_count_240_plus_kbtuh)

    # report the supplemental gas coil counts, weight efficiency, and total capacity
    supplemental_capacity_weighted_gas_coil_efficiency = supplemental_gas_coil_total_capacity_w > 0.0 ? supplemental_gas_coil_capacity_weighted_efficiency / supplemental_gas_coil_total_capacity_w : 0.0
    supplemental_gas_coil_total_capacity_kbuth = OpenStudio.convert(supplemental_gas_coil_total_capacity_w, 'W', 'kBtu/h').get
    runner.registerValue('com_report_hvac_supplemental_capacity_weighted_gas_coil_efficiency', supplemental_capacity_weighted_gas_coil_efficiency)
    runner.registerValue('com_report_hvac_supplemental_gas_coil_capacity_kbtuh', supplemental_gas_coil_total_capacity_kbuth)
    runner.registerValue('com_report_hvac_count_supplemental_gas_coil_0_to_30_kbtuh', supplemental_gas_count_0_to_30_kbtuh)
    runner.registerValue('com_report_hvac_count_supplemental_gas_coil_30_to_65_kbtuh', supplemental_gas_count_30_to_65_kbtuh)
    runner.registerValue('com_report_hvac_count_supplemental_gas_coil_65_to_135_kbtuh', supplemental_gas_count_65_to_135_kbtuh)
    runner.registerValue('com_report_hvac_count_supplemental_gas_coil_135_to_240_kbtuh', supplemental_gas_count_135_to_240_kbtuh)
    runner.registerValue('com_report_hvac_count_supplemental_gas_coil_240_plus_kbtuh', supplemental_gas_count_240_plus_kbtuh)

    # Sum of heating and cooling equipment capacity
    cooling_equipment_capacity_tons = chiller_total_capacity_tons + dx_cooling_total_capacity_tons
    runner.registerValue('com_report_hvac_cooling_equipment_tons', cooling_equipment_capacity_tons)
    heating_equipment_capacity_kbtuh = dx_heating_total_capacity_kbtuh + boiler_total_capacity_kbtuh + heat_pump_heating_total_capacity_kbtuh + primary_gas_coil_total_capacity_kbuth + supplemental_gas_coil_total_capacity_kbuth
    runner.registerValue('com_report_hvac_heating_equipment_kbtuh', heating_equipment_capacity_kbtuh)

    # Service water heating hot water use
    total_annual_hot_water_m3 = 0
    model.getWaterUseConnectionss.sort.each do |water_use_connection|
      annual_hot_water_m3 = sql_get_report_variable_data_double(runner, sql, water_use_connection, 'Water Use Connections Hot Water Volume')
      total_annual_hot_water_m3 += annual_hot_water_m3
    end
    runner.registerValue('com_report_annual_hot_water_m3', total_annual_hot_water_m3, 'm^3')

    # Service water heating equipment
    heat_pump_water_heater_count = 0.0
    heat_pump_water_heater_0_to_40_gal_count = 0.0
    heat_pump_water_heater_40_to_65_gal_count = 0.0
    heat_pump_water_heater_65_to_90_gal_count = 0.0
    heat_pump_water_heater_90_plus_gal_count  = 0.0
    heat_pump_water_heater_total_volume_gal = 0.0
    heat_pump_water_heater_0_to_40_gal_total_volume_gal = 0.0
    heat_pump_water_heater_40_to_65_gal_total_volume_gal = 0.0
    heat_pump_water_heater_65_to_90_gal_total_volume_gal = 0.0
    heat_pump_water_heater_90_plus_gal_total_volume_gal = 0.0
    heat_pump_water_heater_capacity_w = 0.0
    heat_pump_water_heater_0_to_40_gal_capacity_w = 0.0
    heat_pump_water_heater_40_to_65_gal_capacity_w = 0.0
    heat_pump_water_heater_65_to_90_gal_capacity_w = 0.0
    heat_pump_water_heater_90_plus_capacity_w = 0.0
    heat_pump_water_heater_cop = 0.0
    heat_pump_water_heater_0_to_40_gal_cop = 0.0
    heat_pump_water_heater_40_to_65_gal_cop = 0.0
    heat_pump_water_heater_65_to_90_gal_cop = 0.0
    heat_pump_water_heater_90_plus_gal_cop  = 0.0
    water_heater_count = 0.0
    water_heater_0_to_40_gal_count = 0.0
    water_heater_40_to_65_gal_count = 0.0
    water_heater_65_to_90_gal_count = 0.0
    water_heater_90_plus_gal_count = 0.0
    water_heater_total_volume_gal = 0.0
    water_heater_0_to_40_gal_total_volume_gal = 0.0
    water_heater_40_to_65_gal_total_volume_gal = 0.0
    water_heater_65_to_90_gal_total_volume_gal = 0.0
    water_heater_90_plus_gal_total_volume_gal = 0.0
    heat_pump_water_heater_total_input_j = 0.0
    heat_pump_water_heater_0_to_40_gal_input_j = 0.0
    heat_pump_water_heater_40_to_65_gal_input_j = 0.0
    heat_pump_water_heater_65_to_90_gal_input_j = 0.0
    heat_pump_water_heater_90_plus_input_j = 0.0
    heat_pump_water_heater_heat_pump_output_j = 0.0
    heat_pump_water_heater_tank_output_j = 0.0
    heat_pump_water_heater_total_output_j = 0.0
    heat_pump_water_heater_0_to_40_gal_output_j = 0.0
    heat_pump_water_heater_40_to_65_gal_output_j = 0.0
    heat_pump_water_heater_65_to_90_gal_output_j = 0.0
    heat_pump_water_heater_90_plus_output_j = 0.0
    heat_pump_water_heater_total_electric_j = 0.0
    heat_pump_water_heater_heat_pump_electric_j = 0.0
    heat_pump_water_heater_backup_electric_j = 0.0
    heat_pump_water_heater_unmet_heat_transfer_demand_j = 0.0
    water_heater_electric_j = 0.0
    water_heater_gas_j = 0.0
    water_heater_other_fuel_j = 0.0
    booster_water_heater_electric_j = 0.0
    booster_water_heater_gas_j = 0.0
    water_heater_unmet_heat_transfer_demand_j = 0.0
    heat_pump_water_heater_tanks = []
    heat_pump_water_heaters = model.getWaterHeaterHeatPumps.map { |wh| wh }
    model.getWaterHeaterHeatPumpWrappedCondensers.each { |wh| heat_pump_water_heaters << wh }
    # loop through heat pump water heaters and report out variables
    heat_pump_water_heaters.sort.each do |hpwh|
      tank = hpwh.tank
      if tank.to_WaterHeaterMixed.is_initialized
        tank = tank.to_WaterHeaterMixed.get
      elsif tank.to_WaterHeaterStratified.is_initialized
        tank = tank.to_WaterHeaterStratified.get
      end
      heat_pump_water_heater_tanks << tank.name.to_s
      volume_m3 = tank.tankVolume.is_initialized ? tank.tankVolume.get : 0.0
      volume_gal = OpenStudio.convert(volume_m3, 'm^3', 'gal').get.round(3)

      # log heat pump water heater tank size
      heat_pump_water_heater_total_volume_gal += volume_gal
      heat_pump_water_heater_count += 1.0
      if volume_gal == 0.0
        runner.registerWarning("Heat pump water heater #{hpwh} has a zero gallon tank.")
      elsif  volume_gal < 40.0
        heat_pump_water_heater_0_to_40_gal_total_volume_gal += volume_gal
        heat_pump_water_heater_0_to_40_gal_count += 1.0
      elsif  volume_gal < 65.0
        heat_pump_water_heater_40_to_65_gal_total_volume_gal += volume_gal
        heat_pump_water_heater_40_to_65_gal_count += 1.0
      elsif volume_gal < 90.0
        heat_pump_water_heater_65_to_90_gal_total_volume_gal += volume_gal
        heat_pump_water_heater_65_to_90_gal_count += 1.0
      else # over 90 gallons
        heat_pump_water_heater_90_plus_gal_total_volume_gal += volume_gal
        heat_pump_water_heater_90_plus_gal_count += 1.0
      end

      # get backup element capacity
      backup_capacity_w = 0.0
      if tank.to_WaterHeaterMixed.is_initialized
        backup_capacity_w = tank.heaterMaximumCapacity.is_initialized ? tank.heaterMaximumCapacity.get : 0.0
      elsif tank.to_WaterHeaterStratified.is_initialized
        if tank.heaterPriorityControl.to_s.downcase == 'simultaneous'
          backup_capacity_w = tank.heater1Capacity.is_initialized ? tank.heater1Capacity.get : 0.0
          backup_capacity_w += tank.heater2Capacity
        else
          backup_capacity_w = tank.heater1Capacity.is_initialized ? tank.heater1Capacity.get : 0.0
        end
      end

      # get heat pump capacity
      heating_capacity_w = 0.0
      dx_coil = hpwh.dXCoil
      if dx_coil.to_CoilWaterHeatingAirToWaterHeatPump.is_initialized
        dx_coil = dx_coil.to_CoilWaterHeatingAirToWaterHeatPump.get
        heating_capacity_w = dx_coil.ratedHeatingCapacity
      elsif dx_coil.to_CoilWaterHeatingAirToWaterHeatPumpWrapped.is_initialized
        dx_coil = dx_coil.to_CoilWaterHeatingAirToWaterHeatPumpWrapped.get
        heating_capacity_w = dx_coil.ratedHeatingCapacity
      else
        runner.registerWarning("Unsupported coil type for coil #{dx_coil.name} for heat pump water heater #{hpwh.name}.")
      end

      # get backup Water Heater Heating Energy
      tank_heating_energy_j = sql_get_report_variable_data_double(runner, sql, tank, 'Water Heater Heating Energy')

      # get backup Water Heater Unmet Demand Heat Transfer Energy
      tank_unmet_demand_energy_j = sql_get_report_variable_data_double(runner, sql, tank, 'Water Heater Unmet Demand Heat Transfer Energy')

      # get Water Heater <Fuel Type> Energy
      tank_gas_energy_j = 0.0
      tank_electric_energy_j = 0.0
      tank_other_fuel_energy_j = 0.0
      tank_fuel_type = tank.heaterFuelType
      case tank_fuel_type
      when 'Electricity', 'Electric'
        fuel = elec
        tank_electric_energy_j = sql_get_report_variable_data_double(runner, sql, tank, "Water Heater #{fuel} Energy")
      when 'NaturalGas', 'Gas'
        fuel = gas
        tank_gas_energy_j = sql_get_report_variable_data_double(runner, sql, tank, "Water Heater #{fuel} Energy")
      else
        fuel = tank_fuel_type
        tank_other_fuel_energy_j = sql_get_report_variable_data_double(runner, sql, tank, "Water Heater #{fuel} Energy")
      end

      # get Heating/Cooling Coil Total Water Heating Energy
      if model.version > OpenStudio::VersionString.new('3.3.0')
        var_name = 'Cooling Coil Total Water Heating Energy'
      else
        var_name = 'Heating Coil Total Water Heating Energy'
      end
      hpwh_heating_energy_j = sql_get_report_variable_data_double(runner, sql, dx_coil, var_name)

      # get Heating/Cooling Coil Water Heating Electricity Energy
      if model.version > OpenStudio::VersionString.new('3.3.0')
        var_name = "Cooling Coil Water Heating #{elec} Energy"
      else
        var_name = "Heating Coil Water Heating #{elec} Energy"
      end
      hpwh_electric_energy_j = sql_get_report_variable_data_double(runner, sql, dx_coil, var_name)

      # calculate heat pump cop
      hpwh_total_output_energy_j = hpwh_heating_energy_j + tank_heating_energy_j
      hpwh_total_input_energy_j = hpwh_electric_energy_j + tank_electric_energy_j
      hpwh_cop = hpwh_total_input_energy_j > 0.0 ? hpwh_total_output_energy_j / hpwh_total_input_energy_j : 0.0

      # log heat pump water heater capacity and annual cop, weighted by tank size
      heat_pump_water_heater_capacity_w += heating_capacity_w * volume_gal
      heat_pump_water_heater_cop += hpwh_cop * hpwh_total_output_energy_j
      heat_pump_water_heater_total_output_j += hpwh_total_output_energy_j
      heat_pump_water_heater_total_input_j += hpwh_total_input_energy_j
      if volume_gal == 0.0
        runner.registerWarning("Heat pump water heater #{hpwh} has a zero gallon tank.")
      elsif  volume_gal < 40.0
        heat_pump_water_heater_0_to_40_gal_capacity_w = heating_capacity_w * volume_gal
        heat_pump_water_heater_0_to_40_gal_cop += hpwh_cop * hpwh_total_output_energy_j
        heat_pump_water_heater_0_to_40_gal_output_j += hpwh_total_output_energy_j
        heat_pump_water_heater_0_to_40_gal_input_j += hpwh_total_input_energy_j
      elsif  volume_gal < 65.0
        heat_pump_water_heater_40_to_65_gal_capacity_w += heating_capacity_w * volume_gal
        heat_pump_water_heater_40_to_65_gal_cop += hpwh_cop * hpwh_total_output_energy_j
        heat_pump_water_heater_40_to_65_gal_output_j += hpwh_total_output_energy_j
        heat_pump_water_heater_40_to_65_gal_input_j += hpwh_total_input_energy_j
      elsif volume_gal < 90.0
        heat_pump_water_heater_65_to_90_gal_capacity_w += heating_capacity_w * volume_gal
        heat_pump_water_heater_65_to_90_gal_cop += hpwh_cop * hpwh_total_output_energy_j
        heat_pump_water_heater_65_to_90_gal_output_j += hpwh_total_output_energy_j
        heat_pump_water_heater_65_to_90_gal_input_j += hpwh_total_input_energy_j
      else # over 90 gallons
        heat_pump_water_heater_90_plus_capacity_w += heating_capacity_w * volume_gal
        heat_pump_water_heater_90_plus_gal_cop += hpwh_cop * hpwh_total_output_energy_j
        heat_pump_water_heater_90_plus_output_j += hpwh_total_output_energy_j
        heat_pump_water_heater_90_plus_input_j += hpwh_total_input_energy_j
      end

      heat_pump_water_heater_heat_pump_output_j += hpwh_heating_energy_j
      heat_pump_water_heater_tank_output_j += tank_heating_energy_j
      heat_pump_water_heater_total_electric_j += hpwh_electric_energy_j + tank_electric_energy_j
      heat_pump_water_heater_heat_pump_electric_j += hpwh_electric_energy_j
      heat_pump_water_heater_backup_electric_j += tank_electric_energy_j
      heat_pump_water_heater_unmet_heat_transfer_demand_j += tank_unmet_demand_energy_j
    end

    # loop through non-heat pump water heaters, omitting those that are tanks for hpwh objects
    water_heaters = model.getWaterHeaterMixeds.map { |wh| wh }
    model.getWaterHeaterStratifieds.each { |wh| water_heaters << wh }
    water_heaters.sort.each do |wh|
      # skip tanks that are associated with heat pump water heaters
      next if heat_pump_water_heater_tanks.include? wh.name.to_s

      volume_m3 = wh.tankVolume.is_initialized ? wh.tankVolume.get : 0.0
      volume_gal = OpenStudio.convert(volume_m3, 'm^3', 'gal').get.round(3)

      # log water heater tank size
      water_heater_total_volume_gal += volume_gal
      water_heater_count += 1.0
      if volume_gal == 0.0
        runner.registerWarning("Water heater #{wh} has a zero gallon tank.")
      elsif volume_gal < 40.0
        water_heater_0_to_40_gal_total_volume_gal += volume_gal
        water_heater_0_to_40_gal_count += 1.0
      elsif volume_gal < 65.0
        water_heater_40_to_65_gal_total_volume_gal += volume_gal
        water_heater_40_to_65_gal_count += 1.0
      elsif volume_gal < 90.0
        water_heater_65_to_90_gal_total_volume_gal += volume_gal
        water_heater_65_to_90_gal_count += 1.0
      else # over 90 gallons
        water_heater_90_plus_gal_total_volume_gal += volume_gal
        water_heater_90_plus_gal_count += 1.0
      end

      # get Water Heater Unmet Demand Heat Transfer Energy
      wh_unmet_demand_energy_j = sql_get_report_variable_data_double(runner, sql, wh, 'Water Heater Unmet Demand Heat Transfer Energy')

      # get Water Heater <Fuel Type> Energy
      wh_gas_energy_j = 0.0
      wh_electric_energy_j = 0.0
      wh_other_fuel_energy_j = 0.0
      wh_fuel_type = wh.heaterFuelType
      case wh_fuel_type
      when 'Electricity', 'Electric'
        fuel = elec
        wh_electric_energy_j = sql_get_report_variable_data_double(runner, sql, wh, "Water Heater #{fuel} Energy")
      when 'NaturalGas', 'Gas'
        fuel = gas
        wh_gas_energy_j = sql_get_report_variable_data_double(runner, sql, wh, "Water Heater #{fuel} Energy")
      else
        fuel = wh_fuel_type
        wh_other_fuel_energy_j = sql_get_report_variable_data_double(runner, sql, wh, "Water Heater #{fuel} Energy")
      end

      is_booster = wh.name.get.to_s.downcase.include?('booster')

      water_heater_electric_j += wh_electric_energy_j
      water_heater_gas_j += wh_gas_energy_j
      water_heater_other_fuel_j += wh_other_fuel_energy_j
      booster_water_heater_electric_j += wh_electric_energy_j if is_booster
      booster_water_heater_gas_j += wh_gas_energy_j if is_booster
      water_heater_unmet_heat_transfer_demand_j += wh_unmet_demand_energy_j
    end
    # report out counts and volumes for heat pump water heaters
    runner.registerValue('com_report_shw_hp_water_heater_count', heat_pump_water_heater_count)
    runner.registerValue('com_report_shw_hp_water_heater_0_to_40_gal_count', heat_pump_water_heater_0_to_40_gal_count)
    runner.registerValue('com_report_shw_hp_water_heater_40_to_65_gal_count', heat_pump_water_heater_40_to_65_gal_count)
    runner.registerValue('com_report_shw_hp_water_heater_65_to_90_gal_count', heat_pump_water_heater_65_to_90_gal_count)
    runner.registerValue('com_report_shw_hp_water_heater_90_plus_gal_count', heat_pump_water_heater_90_plus_gal_count)
    runner.registerValue('com_report_shw_hp_water_heater_total_volume_gal', heat_pump_water_heater_total_volume_gal)
    runner.registerValue('com_report_shw_hp_water_heater_0_to_40_gal_total_volume_gal', heat_pump_water_heater_0_to_40_gal_total_volume_gal)
    runner.registerValue('com_report_shw_hp_water_heater_40_to_65_gal_total_volume_gal', heat_pump_water_heater_40_to_65_gal_total_volume_gal)
    runner.registerValue('com_report_shw_hp_water_heater_65_to_90_gal_total_volume_gal', heat_pump_water_heater_65_to_90_gal_total_volume_gal)
    runner.registerValue('com_report_shw_hp_water_heater_90_plus_gal_total_volume_gal', heat_pump_water_heater_90_plus_gal_total_volume_gal)

    # report out counts and volumes for non-heat pump water heaters
    runner.registerValue('com_report_shw_non_hp_water_heater_count', water_heater_count)
    runner.registerValue('com_report_shw_non_hp_water_heater_0_to_40_gal_count', water_heater_0_to_40_gal_count)
    runner.registerValue('com_report_shw_non_hp_water_heater_40_to_65_gal_count', water_heater_40_to_65_gal_count)
    runner.registerValue('com_report_shw_non_hp_water_heater_65_to_90_gal_count', water_heater_65_to_90_gal_count)
    runner.registerValue('com_report_shw_non_hp_water_heater_90_plus_gal_count', water_heater_90_plus_gal_count)
    runner.registerValue('com_report_shw_non_hp_water_heater_total_volume_gal', water_heater_total_volume_gal)
    runner.registerValue('com_report_shw_non_hp_water_heater_0_to_40_gal_total_volume_gal', water_heater_0_to_40_gal_total_volume_gal)
    runner.registerValue('com_report_shw_non_hp_water_heater_40_to_65_gal_total_volume_gal', water_heater_40_to_65_gal_total_volume_gal)
    runner.registerValue('com_report_shw_non_hp_water_heater_65_to_90_gal_total_volume_gal', water_heater_65_to_90_gal_total_volume_gal)
    runner.registerValue('com_report_shw_non_hp_water_heater_90_plus_gal_total_volume_gal', water_heater_90_plus_gal_total_volume_gal)

    # report out capacities for heat pump water heaters
    heat_pump_water_heater_capacity_w = heat_pump_water_heater_total_volume_gal > 0.0 ? heat_pump_water_heater_capacity_w / heat_pump_water_heater_total_volume_gal : 0.0
    heat_pump_water_heater_0_to_40_gal_capacity_w = heat_pump_water_heater_0_to_40_gal_total_volume_gal > 0.0 ? heat_pump_water_heater_0_to_40_gal_capacity_w / heat_pump_water_heater_0_to_40_gal_total_volume_gal : 0.0
    heat_pump_water_heater_40_to_65_gal_capacity_w = heat_pump_water_heater_40_to_65_gal_total_volume_gal > 0.0 ? heat_pump_water_heater_40_to_65_gal_capacity_w / heat_pump_water_heater_40_to_65_gal_total_volume_gal : 0.0
    heat_pump_water_heater_65_to_90_gal_capacity_w = heat_pump_water_heater_65_to_90_gal_total_volume_gal > 0.0 ? heat_pump_water_heater_65_to_90_gal_capacity_w / heat_pump_water_heater_65_to_90_gal_total_volume_gal : 0.0
    heat_pump_water_heater_90_plus_capacity_w = heat_pump_water_heater_90_plus_gal_total_volume_gal > 0.0 ? heat_pump_water_heater_90_plus_capacity_w / heat_pump_water_heater_90_plus_gal_total_volume_gal : 0.0
    runner.registerValue('com_report_shw_hp_water_heater_capacity_w', heat_pump_water_heater_capacity_w)
    runner.registerValue('com_report_shw_hp_water_heater_0_to_40_gal_capacity_w', heat_pump_water_heater_0_to_40_gal_capacity_w)
    runner.registerValue('com_report_shw_hp_water_heater_40_to_65_gal_capacity_w', heat_pump_water_heater_40_to_65_gal_capacity_w)
    runner.registerValue('com_report_shw_hp_water_heater_65_to_90_gal_capacity_w', heat_pump_water_heater_65_to_90_gal_capacity_w)
    runner.registerValue('com_report_shw_hp_water_heater_90_plus_capacity_w', heat_pump_water_heater_90_plus_capacity_w)

    # report out annual average cops for heat pump water heaters
    heat_pump_water_heater_cop = heat_pump_water_heater_total_input_j > 0.0 ? heat_pump_water_heater_total_output_j / heat_pump_water_heater_total_input_j : 0.0
    heat_pump_water_heater_0_to_40_gal_cop = heat_pump_water_heater_0_to_40_gal_input_j > 0.0 ? heat_pump_water_heater_0_to_40_gal_output_j / heat_pump_water_heater_0_to_40_gal_input_j : 0.0
    heat_pump_water_heater_40_to_65_gal_cop = heat_pump_water_heater_40_to_65_gal_input_j > 0.0 ? heat_pump_water_heater_40_to_65_gal_output_j / heat_pump_water_heater_40_to_65_gal_input_j : 0.0
    heat_pump_water_heater_65_to_90_gal_cop = heat_pump_water_heater_65_to_90_gal_input_j > 0.0 ? heat_pump_water_heater_65_to_90_gal_output_j / heat_pump_water_heater_65_to_90_gal_input_j : 0.0
    heat_pump_water_heater_90_plus_gal_cop = heat_pump_water_heater_90_plus_input_j > 0.0 ? heat_pump_water_heater_90_plus_output_j / heat_pump_water_heater_90_plus_input_j : 0.0
    runner.registerValue('com_report_shw_hp_water_heater_cop', heat_pump_water_heater_cop)
    runner.registerValue('com_report_shw_hp_water_heater_0_to_40_gal_cop', heat_pump_water_heater_0_to_40_gal_cop)
    runner.registerValue('com_report_shw_hp_water_heater_40_to_65_gal_cop', heat_pump_water_heater_40_to_65_gal_cop)
    runner.registerValue('com_report_shw_hp_water_heater_65_to_90_gal_cop', heat_pump_water_heater_65_to_90_gal_cop)
    runner.registerValue('com_report_shw_hp_water_heater_90_plus_gal_cop', heat_pump_water_heater_90_plus_gal_cop)

    # report out electric use for heat pump water heaters
    runner.registerValue('com_report_shw_hp_water_heater_total_output_j', heat_pump_water_heater_total_output_j)
    runner.registerValue('com_report_shw_hp_water_heater_heat_pump_output_j', heat_pump_water_heater_heat_pump_output_j)
    runner.registerValue('com_report_shw_hp_water_heater_tank_output_j', heat_pump_water_heater_tank_output_j)
    runner.registerValue('com_report_shw_hp_water_heater_total_electric_j', heat_pump_water_heater_total_electric_j)
    runner.registerValue('com_report_shw_hp_water_heater_heat_pump_electric_j', heat_pump_water_heater_heat_pump_electric_j)
    runner.registerValue('com_report_shw_hp_water_heater_backup_electric_j', heat_pump_water_heater_backup_electric_j)

    # report out electric and gas use for non-heat pump water heaters
    runner.registerValue('com_report_shw_non_hp_water_heater_electric_j', water_heater_electric_j)
    runner.registerValue('com_report_shw_non_hp_water_heater_gas_j', water_heater_gas_j)
    runner.registerValue('com_report_shw_non_hp_water_heater_other_fuel_j', water_heater_other_fuel_j)

    # report out electric and gas use for booster water heaters
    runner.registerValue('com_report_shw_booster_water_heater_electric_j', booster_water_heater_electric_j)
    runner.registerValue('com_report_shw_booster_water_heater_gas_j', booster_water_heater_gas_j)

    # report out weater heater unmet demand heat transfer
    runner.registerValue('com_report_shw_hp_water_heater_unmet_heat_transfer_demand_j', heat_pump_water_heater_unmet_heat_transfer_demand_j)
    runner.registerValue('com_report_shw_non_hp_water_heater_unmet_heat_transfer_demand_j', water_heater_unmet_heat_transfer_demand_j)

    # Refrigeration cases and walk-ins
    # Medium temperature: caseOperatingTemperature > -3C; Low temperature: <= -3C
    refrigeration_med_temp_case_count = 0.0
    refrigeration_med_temp_case_total_defrost_electric_j = 0.0
    refrigeration_low_temp_case_count = 0.0
    refrigeration_low_temp_case_total_defrost_electric_j = 0.0
    model.getRefrigerationCases.sort.each do |ref_case|
      defrost_electric_j = sql_get_report_variable_data_double(runner, sql, ref_case, 'Refrigeration Case Defrost Electricity Energy')
      if ref_case.caseOperatingTemperature > -3.0
        refrigeration_med_temp_case_count += 1.0
        refrigeration_med_temp_case_total_defrost_electric_j += defrost_electric_j
      else
        refrigeration_low_temp_case_count += 1.0
        refrigeration_low_temp_case_total_defrost_electric_j += defrost_electric_j
      end
    end
    runner.registerValue('com_report_refrigeration_med_temp_case_count', refrigeration_med_temp_case_count)
    runner.registerValue('com_report_refrigeration_med_temp_case_total_defrost_electric_j', refrigeration_med_temp_case_total_defrost_electric_j, 'J')
    runner.registerValue('com_report_refrigeration_low_temp_case_count', refrigeration_low_temp_case_count)
    runner.registerValue('com_report_refrigeration_low_temp_case_total_defrost_electric_j', refrigeration_low_temp_case_total_defrost_electric_j, 'J')

    refrigeration_med_temp_walk_in_count = 0.0
    refrigeration_med_temp_walk_in_total_defrost_electric_j = 0.0
    refrigeration_low_temp_walk_in_count = 0.0
    refrigeration_low_temp_walk_in_total_defrost_electric_j = 0.0
    model.getRefrigerationWalkIns.sort.each do |walk_in|
      defrost_electric_j = sql_get_report_variable_data_double(runner, sql, walk_in, 'Refrigeration Walk In Defrost Electricity Energy')
      if walk_in.operatingTemperature > -3.0
        refrigeration_med_temp_walk_in_count += 1.0
        refrigeration_med_temp_walk_in_total_defrost_electric_j += defrost_electric_j
      else
        refrigeration_low_temp_walk_in_count += 1.0
        refrigeration_low_temp_walk_in_total_defrost_electric_j += defrost_electric_j
      end
    end
    runner.registerValue('com_report_refrigeration_med_temp_walk_in_count', refrigeration_med_temp_walk_in_count)
    runner.registerValue('com_report_refrigeration_med_temp_walk_in_total_defrost_electric_j', refrigeration_med_temp_walk_in_total_defrost_electric_j, 'J')
    runner.registerValue('com_report_refrigeration_low_temp_walk_in_count', refrigeration_low_temp_walk_in_count)
    runner.registerValue('com_report_refrigeration_low_temp_walk_in_total_defrost_electric_j', refrigeration_low_temp_walk_in_total_defrost_electric_j, 'J')

    # Error and Warning count from eplusout.err file (sql does not have data)
    err_path = File.join(File.dirname(sql.path.to_s), 'eplusout.err')
    File.foreach(err_path).each do |line|
      next unless line.include?('EnergyPlus Completed Successfully')

      m = line.match(/.*EnergyPlus Completed Successfully-- (\d+) Warning; (\d+) Severe Errors/)
      if m
        runner.registerValue('com_report_num_warnings', m[1].to_i)
        runner.registerValue('com_report_num_errors', m[2].to_i)
      else
        runner.registerWarning('Could not determine number of warnings or errors from error file')
      end
      break
    end

    # close the sql file
    sql.close

    return true
  end
end

# register the measure to be used by the application
ComStockSensitivityReports.new.registerWithApplication
