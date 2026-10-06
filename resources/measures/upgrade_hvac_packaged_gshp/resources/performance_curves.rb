# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
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

module MakePerformanceCurves
  # method to convert csv value to float
  def convert_to_float(value)
    # check if value is empty
    if value.to_s.empty?
      # value is empty; return nil
      nil
    elsif value.to_f != value
      # elsif not value.to_f.to_s.include? value.to_s
      # value is not a number; return nil
      nil
    else
      # value is a number; convert to float
      value.to_f
    end
  end

  def read_performance_curve_data(data_path, runner)
    if data_path.empty?
      runner.registerError("Invalid path (#{data_path}) for performance curve data")
      return false
    else
      csv_data = CSV.read(data_path, converters: :numeric)
      column_data = csv_data.transpose
      curve_data = {}
      # CoilCoolingWaterToAirHeatPumpEquationFit and CoilHeatingWaterToAirHeatPumpEquationFit
      curve_data['db_data'] = []
      curve_data['wb_data'] = []
      curve_data['ewt_data'] = []
      curve_data['vdot_air_data'] = []
      curve_data['vdot_water_data'] = []
      curve_data['tot_clg_cap_data'] = []
      curve_data['sen_clg_cap_data'] = []
      curve_data['clg_pow_data'] = []
      curve_data['htg_cap_data'] = []
      curve_data['htg_pow_data'] = []
      # CoilCoolingWaterToAirHeatPumpEquationFit and CoilHeatingWaterToAirHeatPumpEquationFit
      curve_data['load_lwt_data'] = []
      curve_data['source_ewt_data'] = []
      curve_data['plant_clg_cap_data'] = []
      curve_data['plant_clg_eir_data'] = []
      curve_data['plant_htg_cap_data'] = []
      curve_data['plant_htg_eir_data'] = []

      # loop through data columns to fill arrays
      for i in 0..(column_data.length - 1)
        # collect db_data
        if column_data[i][0].to_s == 'Tdb [K]'
          for j in 1..(column_data[i].length - 1)
            curve_data['db_data'] << convert_to_float(column_data[i][j])
            end
        end
        # collect wb_data
        if column_data[i][0].to_s == 'Twb [K]'
          for j in 1..(column_data[i].length - 1)
            curve_data['wb_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect ewt_data
        if column_data[i][0].to_s == 'Twat [K]'
          for j in 1..(column_data[i].length - 1)
            curve_data['ewt_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect vdot_air_data
        if column_data[i][0].to_s == 'Vdot air [m3/s]'
          for j in 1..(column_data[i].length - 1)
            curve_data['vdot_air_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect vdot_water_data
        if column_data[i][0].to_s == 'Vdot water [m3/s]'
          for j in 1..(column_data[i].length - 1)
            curve_data['vdot_water_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect tot_clg_cap_data
        if column_data[i][0].to_s == 'Tot Clg Cap [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['tot_clg_cap_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect sen_clg_cap_data
        if column_data[i][0].to_s == 'Sen Clg Cap [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['sen_clg_cap_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect clg_pow_data
        if column_data[i][0].to_s == 'Clg Pow [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['clg_pow_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect htg_cap_data
        if column_data[i][0].to_s == 'Htg Cap [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['htg_cap_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect htg_pow_data
        if column_data[i][0].to_s == 'Htg Pow [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['htg_pow_data'] << convert_to_float(column_data[i][j])
          end
        end

        # collect load_lwt_data
        if column_data[i][0].to_s == 'Load LWT [C]'
          for j in 1..(column_data[i].length - 1)
            curve_data['load_lwt_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect source_ewt_data
        if column_data[i][0].to_s == 'Source EWT [C]'
          for j in 1..(column_data[i].length - 1)
            curve_data['source_ewt_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect plant_clg_cap_data
        if column_data[i][0].to_s == 'Clg Cap [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['plant_clg_cap_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect plant_clg_eir_data
        if column_data[i][0].to_s == 'Clg EIR'
          for j in 1..(column_data[i].length - 1)
            curve_data['plant_clg_eir_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect plant_htg_cap_data
        if column_data[i][0].to_s == 'Htg Cap [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['plant_htg_cap_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect plant_htg_eir_data
        next unless column_data[i][0].to_s == 'Htg EIR'

        for j in 1..(column_data[i].length - 1)
          curve_data['plant_htg_eir_data'] << convert_to_float(column_data[i][j])
        end
      end
    end
    curve_data
  end

  def create_table_independent_variable(model, name, values, interp_method, extrap_method, unit_type, runner)
    valid_interp_methods = ['Linear', 'Cubic']
    valid_extrap_methods = ['Linear', 'Constant']
    valid_unit_types = ['Dimensionless', 'Temperature', 'VolumetricFlow', 'MassFlow', 'Distance Power']
    table_ind_var = OpenStudio::Model::TableIndependentVariable.new(model)
    table_ind_var.setName(name.to_s)
    if valid_interp_methods.include? interp_method
      table_ind_var.setInterpolationMethod(interp_method)
    else
      runner.registerError("Invalid interpolation method (#{interp_method}) for table independent variable")
      return false
    end

    if valid_extrap_methods.include? extrap_method
      table_ind_var.setExtrapolationMethod(extrap_method)
    else
      runner.registerError("Invalid extrapolation method (#{extrap_method}) for table independent variable")
      return false
    end

    # table_ind_var.setMinimumValue(values.min)
    # table_ind_var.setMaximumValue(values.max)
    if valid_unit_types.include? unit_type
      table_ind_var.setUnitType(unit_type)
    else
      runner.registerError("Invalid unit type (#{unit_type}) for table independent variable")
      return false
    end

    table_ind_var.setValues(values)
    table_ind_var
  end

  def create_table_lookup(model, name, hvac_system_type, curve_type, divisor, path, rated_air_flow_rate,
                          rated_water_flow_rate, runner)
    # create curve lookup
    data = read_performance_curve_data(path, runner)

    if ['packaged_gshp', 'console_gshp'].include?(hvac_system_type)
      # EnergyPlus looks these tables up at (T + 273.15) / 283.15 and at flow / rated flow (Engineering Reference,
      # single speed equation-fit model), so the axes are built as those ratios from the Kelvin and m3/s data
      t_ref_k = 283.15
      # get wb data values
      if ['sen_clg_cap', 'tot_clg_cap', 'clg_pow'].include?(curve_type) && data['wb_data'].empty?
        runner.registerError("No WB temp performance curve data at path (#{path})")
        return false
      end
      wb_values = data['wb_data'].uniq.sort.map { |t| t / t_ref_k }
      # get db data values if relevant
      if ['sen_clg_cap', 'htg_cap', 'htg_pow'].include?(curve_type)
        if data['db_data'].empty?
          runner.registerError("No DB temp performance curve data at path (#{path})")
          return false
        end
        db_values = data['db_data'].uniq.sort.map { |t| t / t_ref_k }
      end
      # get ewt data values
      if data['ewt_data'].empty?
        runner.registerError("No EWT performance curve data at path (#{path})")
        return false
      end
      ewt_values = data['ewt_data'].uniq.sort.map { |t| t / t_ref_k }
      # get air flow data values
      if data['vdot_air_data'].empty?
        runner.registerError("No air flow rate performance curve data at path (#{path})")
        return false
      end
      vdot_air_values = data['vdot_air_data'].uniq.sort.map { |v| v / rated_air_flow_rate }
      # get water flow data values
      if data['vdot_water_data'].empty?
        runner.registerError("No water flow rate performance curve data at path (#{path})")
        return false
      end
      vdot_water_values = data['vdot_water_data'].uniq.sort.map { |v| v / rated_water_flow_rate }
      # data length check
      case curve_type
      when 'sen_clg_cap'
        if data['sen_clg_cap_data'].empty?
          runner.registerError("No sensible cooling capacity performance curve data at path (#{path})")
          return false
        else
          unless data['sen_clg_cap_data'].length == (db_values.length * wb_values.length * ewt_values.length * vdot_air_values.length * vdot_water_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      when 'tot_clg_cap'
        if data['tot_clg_cap_data'].empty?
          runner.registerError("No total cooling capacity performance curve data at path (#{path})")
          return false
        else
          unless data['tot_clg_cap_data'].length == (wb_values.length * ewt_values.length * vdot_air_values.length * vdot_water_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      when 'clg_pow'
        if data['clg_pow_data'].empty?
          runner.registerError("No cooling power performance curve data at path (#{path})")
          return false
        else
          unless data['clg_pow_data'].length == (wb_values.length * ewt_values.length * vdot_air_values.length * vdot_water_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      when 'htg_cap'
        if data['htg_cap_data'].empty?
          runner.registerError("No heating capacity performance curve data at path (#{path})")
          return false
        else
          unless data['htg_cap_data'].length == (db_values.length * ewt_values.length * vdot_air_values.length * vdot_water_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      when 'htg_pow'
        if data['htg_pow_data'].empty?
          runner.registerError("No heating power performance curve data at path (#{path})")
          return false
        else
          unless data['htg_pow_data'].length == (db_values.length * ewt_values.length * vdot_air_values.length * vdot_water_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      else
        runner.registerError("Unexpected curve type (#{curve_type}) for lookup table creation")
        return false
      end

      # create independent variable objects
      table_independent_variables = []
      if ['sen_clg_cap', 'htg_cap', 'htg_pow'].include?(curve_type)
        table_independent_variables << create_table_independent_variable(model, "#{curve_type}_db_var", db_values,
                                                                         'Cubic', 'Constant', 'Dimensionless', runner)
      end

      if ['sen_clg_cap', 'tot_clg_cap', 'clg_pow'].include?(curve_type)
        table_independent_variables << create_table_independent_variable(model, "#{curve_type}_wb_var", wb_values,
                                                                         'Cubic', 'Constant', 'Dimensionless', runner)
      end

      table_independent_variables << create_table_independent_variable(model, "#{curve_type}_ewt_var", ewt_values,
                                                                       'Cubic', 'Constant', 'Dimensionless', runner)
      table_independent_variables << create_table_independent_variable(model, "#{curve_type}_vdot_air_var",
                                                                       vdot_air_values, 'Cubic', 'Constant', 'Dimensionless', runner)
      table_independent_variables << create_table_independent_variable(model, "#{curve_type}_vdot_water_var",
                                                                       vdot_water_values, 'Cubic', 'Constant', 'Dimensionless', runner)

      # create lookup table
      table_lookup = OpenStudio::Model::TableLookup.new(model)
      table_lookup.setName(name.to_s)
      table_lookup.setNormalizationMethod('DivisorOnly')
      table_lookup.setNormalizationDivisor(divisor)
      case curve_type
      when 'sen_clg_cap'
        table_lookup.setOutputUnitType('Capacity')
        table_lookup.setOutputValues(data['sen_clg_cap_data'])
      when 'tot_clg_cap'
        table_lookup.setOutputUnitType('Capacity')
        table_lookup.setOutputValues(data['tot_clg_cap_data'])
      when 'clg_pow'
        table_lookup.setOutputUnitType('Power')
        table_lookup.setOutputValues(data['clg_pow_data'])
      when 'htg_cap'
        table_lookup.setOutputUnitType('Capacity')
        table_lookup.setOutputValues(data['htg_cap_data'])
      when 'htg_pow'
        table_lookup.setOutputUnitType('Power')
        table_lookup.setOutputValues(data['htg_pow_data'])
      else
        runner.registerError("Unexpected curve type (#{curve_type}) for lookup table creation")
        return false
      end
    elsif hvac_system_type == 'hydronic_gshp'
      # get load lwt data values
      if data['load_lwt_data'].empty?
        runner.registerError("No load LWT performance curve data at path (#{path})")
        return false
      end
      load_lwt_values = data['load_lwt_data'].uniq.sort
      # get source ewt data values
      if data['source_ewt_data'].empty?
        runner.registerError("No source EWT performance curve data at path (#{path})")
        return false
      end
      source_ewt_values = data['source_ewt_data'].uniq.sort
      # data length
      case curve_type
      when 'clg_cap'
        if data['plant_clg_cap_data'].empty?
          runner.registerError("No cooling capacity performance curve data at path (#{path})")
          return false
        else
          unless data['plant_clg_cap_data'].length == (load_lwt_values.length * source_ewt_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      when 'clg_eir'
        if data['plant_clg_eir_data'].empty?
          runner.registerError("No cooling eir performance curve data at path (#{path})")
          return false
        else
          unless data['plant_clg_eir_data'].length == (load_lwt_values.length * source_ewt_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      when 'htg_cap'
        if data['plant_htg_cap_data'].empty?
          runner.registerError("No heating capacity performance curve data at path (#{path})")
          return false
        else
          unless data['plant_htg_cap_data'].length == (load_lwt_values.length * source_ewt_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      when 'htg_eir'
        if data['plant_htg_eir_data'].empty?
          runner.registerError("No heating eir performance curve data at path (#{path})")
          return false
        else
          unless data['plant_htg_eir_data'].length == (load_lwt_values.length * source_ewt_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      else
        runner.registerError("Unexpected curve type (#{curve_type}) for lookup table creation")
        return false
      end

      # create independent variable objects
      table_independent_variables = []
      table_independent_variables << create_table_independent_variable(model, "#{curve_type}_load_lwt", load_lwt_values,
                                                                       'Cubic', 'Constant', 'Temperature', runner)
      table_independent_variables << create_table_independent_variable(model, "#{curve_type}_source_ewt",
                                                                       source_ewt_values, 'Cubic', 'Constant', 'Temperature', runner)

      # create lookup table
      table_lookup = OpenStudio::Model::TableLookup.new(model)
      table_lookup.setName(name.to_s)
      table_lookup.setNormalizationMethod('DivisorOnly')
      table_lookup.setNormalizationDivisor(divisor)
      case curve_type
      when 'clg_cap'
        table_lookup.setOutputUnitType('Capacity')
        table_lookup.setOutputValues(data['plant_clg_cap_data'])
      when 'clg_eir'
        table_lookup.setOutputUnitType('Dimensionless')
        table_lookup.setOutputValues(data['plant_clg_eir_data'])
      when 'htg_cap'
        table_lookup.setOutputUnitType('Capacity')
        table_lookup.setOutputValues(data['plant_htg_cap_data'])
      when 'htg_eir'
        table_lookup.setOutputUnitType('Dimensionless')
        table_lookup.setOutputValues(data['plant_htg_eir_data'])
      else
        runner.registerError("Unexpected curve type (#{curve_type}) for lookup table creation")
        return false
      end
    end

    table_independent_variables.each do |var|
      table_lookup.addIndependentVariable(var)
    end
    table_lookup
  end

  # add lookup table performance data to relevant HVAC objects
  def add_lookup_performance_data(model, hvac_object, hvac_system_type, data_set_name, runner)
    supported_hvac_system_types = ['hydronic_gshp', 'packaged_gshp', 'console_gshp']
    available_data_sets = {}
    available_data_sets['hydronic_gshp'] = ['Carrier_30WG_90kW', 'Carrier_61WG_Glycol_90kW']
    available_data_sets['packaged_gshp'] = ['Trane_10_ton_GWSC120E']
    available_data_sets['console_gshp'] = ['Trane_3_ton_GWSC036H']
    # input checks
    unless supported_hvac_system_types.include? hvac_system_type
      runner.registerError("HVAC system type #{hvac_system_type} not supported by add_lookup_performance_data method")
      return false
    end
    if available_data_sets[hvac_system_type].nil?
      runner.registerError("There are no lookup table performance data sets for HVAC system type #{hvac_system_type}")
      return false
    else
      unless available_data_sets[hvac_system_type].include? data_set_name
        runner.registerError("#{data_set_name} is not a valid lookup table performance data set for HVAC system type #{hvac_system_type}")
        return false
      end
    end

    # collect relevant info based on data set input
    case data_set_name
    when 'Trane_10_ton_GWSC120E'
      valid_object_types = ['OS_Coil_Cooling_WaterToAirHeatPump_EquationFit', 'OS_Coil_Heating_WaterToAirHeatPump_EquationFit']
      # check hvac object
      hvac_object_type = hvac_object.iddObjectType.valueName.to_s
      unless valid_object_types.include? hvac_object_type
        runner.registerError("Unexpected object type (#{hvac_object_type}) for lookup table performance data set #{data_set_name}")
        return false
      end
      # basic data set info
      # 80.6 DB, 66.2 WB, 75 EWT cooling
      # 68 DB, 59 WB heating, 32 EWT heating
      # 30 gpm, 4000 cfm
      # EWT 75
      rated_total_cooling_capacity_watts = 124.4 * 0.29307107017222 * 1000
      rated_sensible_cooling_capacity_watts = 100.9 * 0.29307107017222 * 1000
      rated_cooling_power_watts = 6.16 * 1000
      rated_heating_capacity_watts = 92.1 * 0.29307107017222 * 1000
      rated_heating_power_watts = 6.44 * 1000
      rated_air_flow_rate = 4000 / 2118.88
      rated_water_flow_rate = 30 / 15_850.323
      rated_db_clg = (80.6 - 32) / 1.8
      rated_db_htg = (68 - 32) / 1.8
      rated_wb_clg = (66.2 - 32) / 1.8
      rated_ewt_clg = (75 - 32) / 1.8
      rated_ewt_htg = (32 - 32) / 1.8

    when 'Trane_3_ton_GWSC036H'
      valid_object_types = ['OS_Coil_Cooling_WaterToAirHeatPump_EquationFit', 'OS_Coil_Heating_WaterToAirHeatPump_EquationFit']
      # check hvac object
      hvac_object_type = hvac_object.iddObjectType.valueName.to_s
      unless valid_object_types.include? hvac_object_type
        runner.registerError("Unexpected object type (#{hvac_object_type}) for lookup table performance data set #{data_set_name}")
        return false
      end
      # basic data set info
      # 80.6 DB, 66.2 WB cooling
      # 68 DB, 59 WB heating
      # 9 gpm, 1200 cfm
      # EWT 75
      rated_total_cooling_capacity_watts = 45.9 * 0.29307107017222 * 1000
      rated_sensible_cooling_capacity_watts = 35.6 * 0.29307107017222 * 1000
      rated_cooling_power_watts = 2.22 * 1000
      rated_heating_capacity_watts = 31.3 * 0.29307107017222 * 1000
      rated_heating_power_watts = 2.43 * 1000
      rated_air_flow_rate = 1200 / 2118.88
      rated_water_flow_rate = 9 / 15_850.323
      rated_ewt_clg = (75 - 32) / 1.8
      rated_ewt_htg = (32 - 32) / 1.8

    when 'Carrier_30WG_90kW'
      valid_object_types = ['OS_HeatPump_PlantLoop_EIR_Cooling']
      # check hvac object
      hvac_object_type = hvac_object.iddObjectType.valueName.to_s
      unless valid_object_types.include? hvac_object_type
        runner.registerError("Unexpected object type (#{hvac_object_type}) for lookup table performance data set #{data_set_name}")
        return false
      end
      # basic data set info
      rated_cooling_capacity_watts = 94.1 * 1000
      rated_cooling_eir = 0.21505 # 5K delta # 5k delta (same delta t and same working fluid, so same flow rate)

    when 'Carrier_61WG_Glycol_90kW'
      valid_object_types = ['OS_HeatPump_PlantLoop_EIR_Heating']
      # check hvac object
      hvac_object_type = hvac_object.iddObjectType.valueName.to_s
      unless valid_object_types.include? hvac_object_type
        runner.registerError("Unexpected object type (#{hvac_object_type}) for lookup table performance data set #{data_set_name}")
        return false
      end
      # basic data set info
      rated_heating_capacity_watts = 86.7 * 1000
      rated_heating_eir = 0.23419 # J/kgK # J/kgK at 0 C # K # K # m3/s # kg/m3 # kg/m3



    else
      runner.registerError("#{data_set_name} is not supported by add_lookup_performance_data method")
      return false
    end

    case hvac_object_type
    when 'OS_Coil_Cooling_WaterToAirHeatPump_EquationFit'
      # read in csv data
      total_cooling_capacity_data_path = "#{File.dirname(__FILE__)}/#{data_set_name}_tot_clg_cap.csv"
      sensible_cooling_capacity_data_path = "#{File.dirname(__FILE__)}/#{data_set_name}_sen_clg_cap.csv"
      cooling_power_data_path = "#{File.dirname(__FILE__)}/#{data_set_name}_clg_pow.csv"
      # create lookup tables and supporting objects
      table_lookup_tot_clg_cap = create_table_lookup(model, 'table_lookup_tot_clg_cap', 'packaged_gshp', 'tot_clg_cap',
                                                     rated_total_cooling_capacity_watts, total_cooling_capacity_data_path, rated_air_flow_rate, rated_water_flow_rate, runner)
      table_lookup_sen_clg_cap = create_table_lookup(model, 'table_lookup_sen_clg_cap', 'packaged_gshp', 'sen_clg_cap',
                                                     rated_sensible_cooling_capacity_watts, sensible_cooling_capacity_data_path, rated_air_flow_rate, rated_water_flow_rate, runner)
      table_lookup_clg_pow = create_table_lookup(model, 'table_lookup_clg_pow', 'packaged_gshp', 'clg_pow',
                                                 rated_cooling_power_watts, cooling_power_data_path, rated_air_flow_rate, rated_water_flow_rate, runner)
      # assign lookup tables
      hvac_object.setTotalCoolingCapacityCurve(table_lookup_tot_clg_cap)
      hvac_object.setSensibleCoolingCapacityCurve(table_lookup_sen_clg_cap)
      hvac_object.setCoolingPowerConsumptionCurve(table_lookup_clg_pow)
      # set coil inputs
      hvac_object.setRatedCoolingCoefficientofPerformance(rated_total_cooling_capacity_watts / rated_cooling_power_watts)
      hvac_object.setRatedEnteringWaterTemperature(rated_ewt_clg)
      hvac_object.setRatedEnteringAirDryBulbTemperature(rated_db_clg)
      hvac_object.setRatedEnteringAirWetBulbTemperature(rated_wb_clg)

    when 'OS_Coil_Heating_WaterToAirHeatPump_EquationFit'
      # read in csv data
      heating_capacity_data_path = "#{File.dirname(__FILE__)}/#{data_set_name}_htg_cap.csv"
      heating_power_data_path = "#{File.dirname(__FILE__)}/#{data_set_name}_htg_pow.csv"
      # create lookup tables and supporting objects
      table_lookup_htg_cap = create_table_lookup(model, 'table_lookup_htg_cap', 'packaged_gshp', 'htg_cap',
                                                 rated_heating_capacity_watts, heating_capacity_data_path, rated_air_flow_rate, rated_water_flow_rate, runner)
      table_lookup_htg_pow = create_table_lookup(model, 'table_lookup_htg_pow', 'packaged_gshp', 'htg_pow',
                                                 rated_heating_power_watts, heating_power_data_path, rated_air_flow_rate, rated_water_flow_rate, runner)
      # assign lookup tables
      hvac_object.setHeatingCapacityCurve(table_lookup_htg_cap)
      hvac_object.setHeatingPowerConsumptionCurve(table_lookup_htg_pow)
      # set coil inputs
      hvac_object.setRatedHeatingCoefficientofPerformance(rated_heating_capacity_watts / rated_heating_power_watts)
      hvac_object.setRatedEnteringWaterTemperature(rated_ewt_htg)
      hvac_object.setRatedEnteringAirDryBulbTemperature(rated_db_htg)

    when 'OS_HeatPump_PlantLoop_EIR_Cooling'
      # read in csv data
      cooling_data_path = "#{File.dirname(__FILE__)}/#{data_set_name}_clg.csv"
      # create lookup tables and supporting objects
      table_lookup_clg_cap = create_table_lookup(model, 'table_lookup_clg_cap', 'hydronic_gshp', 'clg_cap',
                                                 rated_cooling_capacity_watts, cooling_data_path, nil, nil, runner)
      table_lookup_clg_eir = create_table_lookup(model, 'table_lookup_clg_eir', 'hydronic_gshp', 'clg_eir',
                                                 rated_cooling_eir, cooling_data_path, nil, nil, runner)
      # assign lookup tables
      hvac_object.setCapacityModifierFunctionofTemperatureCurve(table_lookup_clg_cap)
      hvac_object.setElectricInputtoOutputRatioModifierFunctionofTemperatureCurve(table_lookup_clg_eir)
      # set coil inputs
      hvac_object.setReferenceCoefficientofPerformance(1 / rated_cooling_eir)

    when 'OS_HeatPump_PlantLoop_EIR_Heating'
      # read in csv data
      heating_data_path = "#{File.dirname(__FILE__)}/#{data_set_name}_htg.csv"
      # create lookup tables and supporting objects
      table_lookup_htg_cap = create_table_lookup(model, 'table_lookup_htg_cap', 'hydronic_gshp', 'htg_cap',
                                                 rated_heating_capacity_watts, heating_data_path, nil, nil, runner)
      table_lookup_htg_eir = create_table_lookup(model, 'table_lookup_htg_eir', 'hydronic_gshp', 'htg_eir',
                                                 rated_heating_eir, heating_data_path, nil, nil, runner)
      # assign lookup tables
      hvac_object.setCapacityModifierFunctionofTemperatureCurve(table_lookup_htg_cap)
      hvac_object.setElectricInputtoOutputRatioModifierFunctionofTemperatureCurve(table_lookup_htg_eir)
      # set coil inputs
      hvac_object.setReferenceCoefficientofPerformance(1 / rated_heating_eir)

    else
      runner.registerError("Unexpected object type (#{hvac_object_type}) for lookup table performance data set #{data_set_name}")
      return false
    end
    true
  end
end
