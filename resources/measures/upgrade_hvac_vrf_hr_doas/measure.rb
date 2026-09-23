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

# dependencies
require 'comstock-typical'

# start the measure
class HvacVrfHrDoas < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    'hvac_vrf_hr_doas'
  end

  # human readable description
  def description
    'This model replaces the existing HVAC system with a VRF(HR) + DOAS system.'
  end

  # human readable description of modeling approach
  def modeler_description
    'This model replaces the existing HVAC system with a VRF(HR) + DOAS system.'
  end

  # define the arguments that the user will input
  def arguments(_model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # define defrosting strategy
    vrf_defrost_strategies = OpenStudio::StringVector.new
    vrf_defrost_strategies << 'reverse-cycle'
    vrf_defrost_strategies << 'resistive'
    vrf_defrost_strategy = OpenStudio::Measure::OSArgument.makeChoiceArgument('vrf_defrost_strategy',
                                                                              vrf_defrost_strategies, true)
    vrf_defrost_strategy.setDisplayName('Defrost strategy')
    vrf_defrost_strategy.setDefaultValue(vrf_defrost_strategies[0])
    args << vrf_defrost_strategy

    # disable defrosting mode?
    disable_defrost = OpenStudio::Measure::OSArgument.makeBoolArgument('disable_defrost', true)
    disable_defrost.setDisplayName('Disable defrost?')
    disable_defrost.setDescription('')
    disable_defrost.setDefaultValue(false)
    args << disable_defrost

    # upsizing allowance
    upsizing_allowance_pct = OpenStudio::Measure::OSArgument.makeDoubleArgument('upsizing_allowance_pct', true)
    upsizing_allowance_pct.setDisplayName('Upsizing allowance (in %) from cooling design load for heating dominant buildings')
    upsizing_allowance_pct.setDescription('25% upsizing allowance is the same as 125% from the original size. Setting this value to zero means not applying upsizing.')
    upsizing_allowance_pct.setDefaultValue(0.0)
    args << upsizing_allowance_pct

    # apply/not-apply measure
    apply_measure = OpenStudio::Measure::OSArgument.makeBoolArgument('apply_measure', true)
    apply_measure.setDisplayName('Apply measure?')
    apply_measure.setDescription('')
    apply_measure.setDefaultValue(true)
    args << apply_measure

    args
  end

  # --------------------------------------- #
  # supporting method
  # modified version (to read custom json) of same method in OS Standards
  # --------------------------------------- #
  def model_add_curve(model, curve_name, standards_data_curve, std)
    # First check model and return curve if it already exists
    existing_curves = []
    existing_curves += model.getCurveLinears
    existing_curves += model.getCurveCubics
    existing_curves += model.getCurveQuadratics
    existing_curves += model.getCurveBicubics
    existing_curves += model.getCurveBiquadratics
    existing_curves += model.getCurveQuadLinears
    existing_curves.sort.each do |curve|
      if curve.name.get.to_s == curve_name
        # OpenStudio.logFree(OpenStudio::Debug, 'openstudio.standards.Model', "Already added curve: #{curve_name}")
        return curve
      end
    end

    # OpenStudio::logFree(OpenStudio::Info, "openstudio.prototype.addCurve", "Adding curve '#{curve_name}' to the model.")

    # Find curve data
    data = std.model_find_object(standards_data_curve['tables']['curves'], 'name' => curve_name)
    if data.nil?
      # OpenStudio.logFree(OpenStudio::Warn, 'openstudio.Model.Model', "Could not find a curve called '#{curve_name}' in the standards.")
      return nil
    end

    # Make the correct type of curve
    case data['form']
    when 'Linear'
      curve = OpenStudio::Model::CurveLinear.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'])
      curve.setCoefficient2x(data['coeff_2'])
      curve.setMinimumValueofx(data['minimum_independent_variable_1']) if data['minimum_independent_variable_1']
      curve.setMaximumValueofx(data['maximum_independent_variable_1']) if data['maximum_independent_variable_1']
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
      end
      curve
    when 'Cubic'
      curve = OpenStudio::Model::CurveCubic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'])
      curve.setCoefficient2x(data['coeff_2'])
      curve.setCoefficient3xPOW2(data['coeff_3'])
      curve.setCoefficient4xPOW3(data['coeff_4'])
      curve.setMinimumValueofx(data['minimum_independent_variable_1']) if data['minimum_independent_variable_1']
      curve.setMaximumValueofx(data['maximum_independent_variable_1']) if data['maximum_independent_variable_1']
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
      end
      curve
    when 'Quadratic'
      curve = OpenStudio::Model::CurveQuadratic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'])
      curve.setCoefficient2x(data['coeff_2'])
      curve.setCoefficient3xPOW2(data['coeff_3'])
      curve.setMinimumValueofx(data['minimum_independent_variable_1']) if data['minimum_independent_variable_1']
      curve.setMaximumValueofx(data['maximum_independent_variable_1']) if data['maximum_independent_variable_1']
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
      end
      curve
    when 'BiCubic'
      curve = OpenStudio::Model::CurveBicubic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'])
      curve.setCoefficient2x(data['coeff_2'])
      curve.setCoefficient3xPOW2(data['coeff_3'])
      curve.setCoefficient4y(data['coeff_4'])
      curve.setCoefficient5yPOW2(data['coeff_5'])
      curve.setCoefficient6xTIMESY(data['coeff_6'])
      curve.setCoefficient7xPOW3(data['coeff_7'])
      curve.setCoefficient8yPOW3(data['coeff_8'])
      curve.setCoefficient9xPOW2TIMESY(data['coeff_9'])
      curve.setCoefficient10xTIMESYPOW2(data['coeff_10'])
      curve.setMinimumValueofx(data['minimum_independent_variable_1']) if data['minimum_independent_variable_1']
      curve.setMaximumValueofx(data['maximum_independent_variable_1']) if data['maximum_independent_variable_1']
      curve.setMinimumValueofy(data['minimum_independent_variable_2']) if data['minimum_independent_variable_2']
      curve.setMaximumValueofy(data['maximum_independent_variable_2']) if data['maximum_independent_variable_2']
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
      end
      curve
    when 'BiQuadratic'
      curve = OpenStudio::Model::CurveBiquadratic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'])
      curve.setCoefficient2x(data['coeff_2'])
      curve.setCoefficient3xPOW2(data['coeff_3'])
      curve.setCoefficient4y(data['coeff_4'])
      curve.setCoefficient5yPOW2(data['coeff_5'])
      curve.setCoefficient6xTIMESY(data['coeff_6'])
      curve.setMinimumValueofx(data['minimum_independent_variable_1']) if data['minimum_independent_variable_1']
      curve.setMaximumValueofx(data['maximum_independent_variable_1']) if data['maximum_independent_variable_1']
      curve.setMinimumValueofy(data['minimum_independent_variable_2']) if data['minimum_independent_variable_2']
      curve.setMaximumValueofy(data['maximum_independent_variable_2']) if data['maximum_independent_variable_2']
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
      end
      curve
    when 'BiLinear'
      curve = OpenStudio::Model::CurveBiquadratic.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'])
      curve.setCoefficient2x(data['coeff_2'])
      curve.setCoefficient4y(data['coeff_3'])
      curve.setMinimumValueofx(data['minimum_independent_variable_1']) if data['minimum_independent_variable_1']
      curve.setMaximumValueofx(data['maximum_independent_variable_1']) if data['maximum_independent_variable_1']
      curve.setMinimumValueofy(data['minimum_independent_variable_2']) if data['minimum_independent_variable_2']
      curve.setMaximumValueofy(data['maximum_independent_variable_2']) if data['maximum_independent_variable_2']
      if data['minimum_dependent_variable_output']
        curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
      end
      if data['maximum_dependent_variable_output']
        curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
      end
      curve
    when 'QuadLinear'
      curve = OpenStudio::Model::CurveQuadLinear.new(model)
      curve.setName(data['name'])
      curve.setCoefficient1Constant(data['coeff_1'])
      curve.setCoefficient2w(data['coeff_2'])
      curve.setCoefficient3x(data['coeff_3'])
      curve.setCoefficient4y(data['coeff_4'])
      curve.setCoefficient5z(data['coeff_5'])
      curve.setMinimumValueofw(data['minimum_independent_variable_w'])
      curve.setMaximumValueofw(data['maximum_independent_variable_w'])
      curve.setMinimumValueofx(data['minimum_independent_variable_x'])
      curve.setMaximumValueofx(data['maximum_independent_variable_x'])
      curve.setMinimumValueofy(data['minimum_independent_variable_y'])
      curve.setMaximumValueofy(data['maximum_independent_variable_y'])
      curve.setMinimumValueofz(data['minimum_independent_variable_z'])
      curve.setMaximumValueofz(data['maximum_independent_variable_z'])
      curve.setMinimumCurveOutput(data['minimum_dependent_variable_output'])
      curve.setMaximumCurveOutput(data['maximum_dependent_variable_output'])
      curve
    when 'TableLookup', 'LookupTable', 'TableMultiVariableLookup', 'MultiVariableLookupTable'
      num_ind_var = data['number_independent_variables'].to_i
      if model.version < OpenStudio::VersionString.new('3.7.0')
        # Use TableMultiVariableLookup object
        table = OpenStudio::Model::TableMultiVariableLookup.new(model, num_ind_var)
        table.setInterpolationMethod(data['interpolation_method'])
        table.setNumberofInterpolationPoints(data['number_of_interpolation_points'])
        table.setCurveType(data['curve_type'])
        table.setTableDataFormat('SingleLineIndependentVariableWithMatrix')
        table.setNormalizationReference(data['normalization_reference'].to_f)

        # set table limits
        table.setMinimumValueofX1(data['minimum_independent_variable_1'].to_f)
        table.setMaximumValueofX1(data['maximum_independent_variable_1'].to_f)
        table.setInputUnitTypeforX1(data['input_unit_type_x1'])
        if num_ind_var == 2
          table.setMinimumValueofX2(data['minimum_independent_variable_2'].to_f)
          table.setMaximumValueofX2(data['maximum_independent_variable_2'].to_f)
          table.setInputUnitTypeforX2(data['input_unit_type_x2'])
        end

        # add data points
        data_points = data.each.select { |key, _value| key.include? 'data_point' }
        data_points.each do |_key, value|
          if num_ind_var == 1
            table.addPoint(value.split(',')[0].to_f, value.split(',')[1].to_f)
          elsif num_ind_var == 2
            table.addPoint(value.split(',')[0].to_f, value.split(',')[1].to_f, value.split(',')[2].to_f)
          end
        end
      else
        # Use TableLookup Object
        table = OpenStudio::Model::TableLookup.new(model)
        table.setNormalizationDivisor(data['normalization_reference'].to_f)

        # sorting data in ascending order
        data_points = data.each.select { |key, _value| key.include? 'data_point' }
        data_points = data_points.sort_by { |item| item[1].split(',').map(&:to_f) }
        data_points.each do |_key, value|
          var_dep = value.split(',')[2].to_f
          table.addOutputValue(var_dep)
        end
        num_ind_var.times do |i|
          table_indvar = OpenStudio::Model::TableIndependentVariable.new(model)
          table_indvar.setName(data['name'] + "_ind_#{i + 1}")
          table_indvar.setInterpolationMethod(data['interpolation_method'])

          # set table limits
          table_indvar.setMinimumValue(data["minimum_independent_variable_#{i + 1}"].to_f)
          table_indvar.setMaximumValue(data["maximum_independent_variable_#{i + 1}"].to_f)
          table_indvar.setUnitType(data["input_unit_type_x#{i + 1}"].to_s)

          # add data points
          var_ind_unique = data_points.map { |_key, value| value.split(',')[i].to_f }.uniq
          var_ind_unique.each { |var_ind| table_indvar.addValue(var_ind) }
          table.addIndependentVariable(table_indvar)
        end
      end
      table.setName(data['name'])
      table.setOutputUnitType(data['output_unit_type'])
      table
    else
      # OpenStudio.logFree(OpenStudio::Error, 'openstudio.Model.Model', "#{curve_name}' has an invalid form: #{data['form']}', cannot create this curve.")
      nil
    end
  end

  # --------------------------------------- #
  # supporting method
  # --------------------------------------- #
  def get_tabular_data(_model, sql, report_name, report_for_string, table_name, row_name, column_name)
    result = OpenStudio::OptionalDouble.new
    var_val_query = "SELECT Value FROM TabularDataWithStrings WHERE ReportName = '#{report_name}' AND ReportForString = '#{report_for_string}' AND TableName = '#{table_name}' AND RowName = '#{row_name}' AND ColumnName = '#{column_name}'"
    val = sql.execAndReturnFirstDouble(var_val_query)
    if val.is_initialized
      result = OpenStudio::OptionalDouble.new(val.get)
    else
      puts("Cannot query: #{report_name} | #{report_for_string} | #{table_name} | #{row_name} | #{column_name}")
    end
    result
  end

  # --------------------------------------- #
  # supporting method
  # --------------------------------------- #
  # return dependent varible based on two independent variables from TableMultiVariableLookup
  # @param model [OpenStudio::Model::TableMultiVariableLookup] OpenStudio TableMultiVariableLookup object
  # @param ind_var_1 [Double] independent variable 1
  # @param ind_var_2 [Double] independent variable 2
  # @return [Double] dependent variable value
  def self.get_dep_var_from_lookup_table_with_two_ind_var(runner, lookup_table, input1, input2)
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

      interpolated_value
    else
      runner.registerError('TableLookup object does not have exactly two independent variables.')
      false
    end
  end

  # --------------------------------------- #
  # supporting method
  # extracting VRF object specifications from existing (fully populated) object
  # this is used to copy specs from (manufacturer provided) osc files
  # --------------------------------------- #
  def extract_curves_from_dummy_acvrf_object(model, name)
    # initialize performance map
    map_performance_data = {}

    # puts("*** extracting existing curves from dummy AirConditioner:VariableRefrigerantFlow object: #{name}")

    # getting dummy vrf object to extract curves
    model.getAirConditionerVariableRefrigerantFlows.each do |acvrf|
      acvrf_name = acvrf.name.to_s
      next unless acvrf_name == name

      # puts("*** found object: #{acvrf_name}")

      # cooling performance maps
      # puts("*** extracting performance maps for cooling")
      map_performance_data['curve_ccapft_boundary'] = if acvrf.coolingCapacityRatioBoundaryCurve.is_initialized
                                                        acvrf.coolingCapacityRatioBoundaryCurve.get
                                                      end
      if acvrf.coolingCapacityRatioModifierFunctionofLowTemperatureCurve.is_initialized
        map_performance_data['curve_low_ccapft'] = acvrf.coolingCapacityRatioModifierFunctionofLowTemperatureCurve.get
      else
        map_performance_data['curve_low_ccapft'] = nil
      end
      if acvrf.coolingCapacityRatioModifierFunctionofHighTemperatureCurve.is_initialized
        map_performance_data['curve_high_ccapft'] =
          acvrf.coolingCapacityRatioModifierFunctionofHighTemperatureCurve.get
      else
        map_performance_data['curve_high_ccapft'] = nil
      end
      map_performance_data['curve_ceirft_boundary'] = if acvrf.coolingEnergyInputRatioBoundaryCurve.is_initialized
                                                        acvrf.coolingEnergyInputRatioBoundaryCurve.get
                                                      end
      if acvrf.coolingEnergyInputRatioModifierFunctionofLowTemperatureCurve.is_initialized
        map_performance_data['curve_low_ceirft'] =
          acvrf.coolingEnergyInputRatioModifierFunctionofLowTemperatureCurve.get
      else
        map_performance_data['curve_low_ceirft'] = nil
      end
      if acvrf.coolingEnergyInputRatioModifierFunctionofHighTemperatureCurve.is_initialized
        map_performance_data['curve_high_ceirft'] =
          acvrf.coolingEnergyInputRatioModifierFunctionofHighTemperatureCurve.get
      else
        map_performance_data['curve_high_ceirft'] = nil
      end
      if acvrf.coolingEnergyInputRatioModifierFunctionofLowPartLoadRatioCurve.is_initialized
        map_performance_data['curve_low_ceirfplr'] =
          acvrf.coolingEnergyInputRatioModifierFunctionofLowPartLoadRatioCurve.get
      else
        map_performance_data['curve_low_ceirfplr'] = nil
      end
      if acvrf.coolingEnergyInputRatioModifierFunctionofHighPartLoadRatioCurve.is_initialized
        map_performance_data['curve_high_ceirfplr'] =
          acvrf.coolingEnergyInputRatioModifierFunctionofHighPartLoadRatioCurve.get
      else
        map_performance_data['curve_high_ceirfplr'] = nil
      end
      map_performance_data['curve_ccr'] = if acvrf.coolingCombinationRatioCorrectionFactorCurve.is_initialized
                                            acvrf.coolingCombinationRatioCorrectionFactorCurve.get
                                          end
      map_performance_data['curve_onoff_cplffplr'] = if acvrf.coolingPartLoadFractionCorrelationCurve.is_initialized
                                                       acvrf.coolingPartLoadFractionCorrelationCurve.get
                                                     end

      # heating performance maps
      # puts("*** extracting performance maps for heating")
      map_performance_data['curve_hcapft_boundary'] = if acvrf.heatingCapacityRatioBoundaryCurve.is_initialized
                                                        acvrf.heatingCapacityRatioBoundaryCurve.get
                                                      end
      if acvrf.heatingCapacityRatioModifierFunctionofLowTemperatureCurve.is_initialized
        map_performance_data['curve_low_hcapft'] = acvrf.heatingCapacityRatioModifierFunctionofLowTemperatureCurve.get
      else
        map_performance_data['curve_low_hcapft'] = nil
      end
      if acvrf.heatingCapacityRatioModifierFunctionofHighTemperatureCurve.is_initialized
        map_performance_data['curve_high_hcapft'] =
          acvrf.heatingCapacityRatioModifierFunctionofHighTemperatureCurve.get
      else
        map_performance_data['curve_high_hcapft'] = nil
      end
      map_performance_data['curve_heirft_boundary'] = if acvrf.heatingEnergyInputRatioBoundaryCurve.is_initialized
                                                        acvrf.heatingEnergyInputRatioBoundaryCurve.get
                                                      end
      if acvrf.heatingEnergyInputRatioModifierFunctionofLowTemperatureCurve.is_initialized
        map_performance_data['curve_low_heirft'] =
          acvrf.heatingEnergyInputRatioModifierFunctionofLowTemperatureCurve.get
      else
        map_performance_data['curve_low_heirft'] = nil
      end
      if acvrf.heatingEnergyInputRatioModifierFunctionofHighTemperatureCurve.is_initialized
        map_performance_data['curve_high_heirft'] =
          acvrf.heatingEnergyInputRatioModifierFunctionofHighTemperatureCurve.get
      else
        map_performance_data['curve_high_heirft'] = nil
      end
      if acvrf.heatingEnergyInputRatioModifierFunctionofLowPartLoadRatioCurve.is_initialized
        map_performance_data['curve_low_heirfplr'] =
          acvrf.heatingEnergyInputRatioModifierFunctionofLowPartLoadRatioCurve.get
      else
        map_performance_data['curve_low_heirfplr'] = nil
      end
      if acvrf.heatingEnergyInputRatioModifierFunctionofHighPartLoadRatioCurve.is_initialized
        map_performance_data['curve_high_heirfplr'] =
          acvrf.heatingEnergyInputRatioModifierFunctionofHighPartLoadRatioCurve.get
      else
        map_performance_data['curve_high_heirfplr'] = nil
      end
      map_performance_data['curve_hcr'] = if acvrf.heatingCombinationRatioCorrectionFactorCurve.is_initialized
                                            acvrf.heatingCombinationRatioCorrectionFactorCurve.get
                                          end
      map_performance_data['curve_onoff_hplffplr'] = if acvrf.heatingPartLoadFractionCorrelationCurve.is_initialized
                                                       acvrf.heatingPartLoadFractionCorrelationCurve.get
                                                     end
      if acvrf.defrostEnergyInputRatioModifierFunctionofTemperatureCurve.is_initialized
        map_performance_data['curve_defrost_heirft'] =
          acvrf.defrostEnergyInputRatioModifierFunctionofTemperatureCurve.get
      else
        map_performance_data['curve_defrost_heirft'] = nil
      end

      # other configurations to extract
      # puts("*** extracting other configurations")
      map_performance_data['heating_oa_temperature_type'] = acvrf.heatingPerformanceCurveOutdoorTemperatureType
      map_performance_data['min_hp_plr'] = acvrf.minimumHeatPumpPartLoadRatio
      map_performance_data['cooling_rated_cop'] = acvrf.grossRatedCoolingCOP
      map_performance_data['heating_rated_cop'] = acvrf.ratedHeatingCOP
      map_performance_data['num_compressors'] = acvrf.numberofCompressors
      map_performance_data['min_oa_temp_cooling'] = acvrf.minimumOutdoorTemperatureinCoolingMode
      map_performance_data['max_oa_temp_cooling'] = acvrf.maximumOutdoorTemperatureinCoolingMode
      map_performance_data['max_oa_temp_heating'] = acvrf.maximumOutdoorTemperatureinHeatingMode
      map_performance_data['min_oa_temp_heatrecovery'] = acvrf.minimumOutdoorTemperatureinHeatRecoveryMode
      map_performance_data['max_oa_temp_heatrecovery'] = acvrf.maximumOutdoorTemperatureinHeatRecoveryMode
      map_performance_data['initial_heatrecovery_cap_frac_cooling'] = acvrf.initialHeatRecoveryCoolingCapacityFraction
      map_performance_data['initial_heatrecovery_en_frac_cooling'] = acvrf.initialHeatRecoveryCoolingEnergyFraction
      map_performance_data['initial_heatrecovery_cap_frac_heating'] = acvrf.initialHeatRecoveryHeatingCapacityFraction
      map_performance_data['initial_heatrecovery_en_frac_heating'] = acvrf.initialHeatRecoveryHeatingEnergyFraction
      map_performance_data['initial_heatrecovery_cap_timeconstant_cooling'] =
        acvrf.heatRecoveryCoolingCapacityTimeConstant
      map_performance_data['initial_heatrecovery_en_timeconstant_cooling'] = acvrf.heatRecoveryCoolingEnergyTimeConstant
      map_performance_data['initial_heatrecovery_cap_timeconstant_heating'] =
        acvrf.heatRecoveryHeatingCapacityTimeConstant
      map_performance_data['initial_heatrecovery_en_timeconstant_heating'] = acvrf.heatRecoveryHeatingEnergyTimeConstant
      # map_performance_data["defrost_strategy"] = acvrf.defrostStrategy # unused for now
      # map_performance_data["defrost_control"] = acvrf.defrostControl # unused for now
    end
    map_performance_data
  end

  # --------------------------------------- #
  # supporting method
  # applying VRF object specifications
  # --------------------------------------- #
  def apply_vrf_performance_data(
    vrf_outdoor_unit,
    map_performance_data,
    _vrf_defrost_strategy,
    _disable_defrost
  )
    # puts("*** applying performance map to AirConditioner:VariableRefrigerantFlow object: #{vrf_outdoor_unit.name.to_s}")

    # cooling
    if map_performance_data['curve_ccapft_boundary'].nil?
      # puts("*** curve not applied because it is nill: curve_ccapft_boundary")
      vrf_outdoor_unit.resetCoolingCapacityRatioBoundaryCurve
    else
      # puts("*** curve applied: curve_ccapft_boundary")
      vrf_outdoor_unit.setCoolingCapacityRatioBoundaryCurve(map_performance_data['curve_ccapft_boundary'])
    end
    if map_performance_data['curve_low_ccapft'].nil?
      # puts("*** curve not applied because it is nill: curve_low_ccapft")
      vrf_outdoor_unit.resetCoolingCapacityRatioModifierFunctionofLowTemperatureCurve
    else
      # puts("*** curve applied: curve_low_ccapft")
      vrf_outdoor_unit.setCoolingCapacityRatioModifierFunctionofLowTemperatureCurve(map_performance_data['curve_low_ccapft'])
    end
    if map_performance_data['curve_high_ccapft'].nil?
      # puts("*** curve not applied because it is nill: curve_high_ccapft")
      vrf_outdoor_unit.resetCoolingCapacityRatioModifierFunctionofHighTemperatureCurve
    else
      # puts("*** curve applied: curve_high_ccapft")
      vrf_outdoor_unit.setCoolingCapacityRatioModifierFunctionofHighTemperatureCurve(map_performance_data['curve_high_ccapft'])
    end
    if map_performance_data['curve_ceirft_boundary'].nil?
      # puts("*** curve not applied because it is nill: curve_ceirft_boundary")
      vrf_outdoor_unit.resetCoolingEnergyInputRatioBoundaryCurve
    else
      # puts("*** curve applied: curve_ceirft_boundary")
      vrf_outdoor_unit.setCoolingEnergyInputRatioBoundaryCurve(map_performance_data['curve_ceirft_boundary'])
    end
    if map_performance_data['curve_low_ceirft'].nil?
      # puts("*** curve not applied because it is nill: curve_low_ceirft")
      vrf_outdoor_unit.resetCoolingEnergyInputRatioModifierFunctionofLowTemperatureCurve
    else
      # puts("*** curve applied: curve_low_ceirft")
      vrf_outdoor_unit.setCoolingEnergyInputRatioModifierFunctionofLowTemperatureCurve(map_performance_data['curve_low_ceirft'])
    end
    if map_performance_data['curve_high_ceirft'].nil?
      # puts("*** curve not applied because it is nill: curve_high_ceirft")
      vrf_outdoor_unit.resetCoolingEnergyInputRatioModifierFunctionofHighTemperatureCurve
    else
      # puts("*** curve applied: curve_high_ceirft")
      vrf_outdoor_unit.setCoolingEnergyInputRatioModifierFunctionofHighTemperatureCurve(map_performance_data['curve_high_ceirft'])
    end
    if map_performance_data['curve_low_ceirfplr'].nil?
      # puts("*** curve not applied because it is nill: curve_low_ceirfplr")
      vrf_outdoor_unit.resetCoolingEnergyInputRatioModifierFunctionofLowPartLoadRatioCurve
    else
      # puts("*** curve applied: curve_low_ceirfplr")
      vrf_outdoor_unit.setCoolingEnergyInputRatioModifierFunctionofLowPartLoadRatioCurve(map_performance_data['curve_low_ceirfplr'])
    end
    if map_performance_data['curve_high_ceirfplr'].nil?
      # puts("*** curve not applied because it is nill: curve_high_ceirfplr")
      vrf_outdoor_unit.resetCoolingEnergyInputRatioModifierFunctionofHighPartLoadRatioCurve
    else
      # puts("*** curve applied: curve_high_ceirfplr")
      vrf_outdoor_unit.setCoolingEnergyInputRatioModifierFunctionofHighPartLoadRatioCurve(map_performance_data['curve_high_ceirfplr'])
    end
    if map_performance_data['curve_ccr'].nil?
      # puts("*** curve not applied because it is nill: curve_ccr")
      vrf_outdoor_unit.resetCoolingCombinationRatioCorrectionFactorCurve
    else
      # puts("*** curve applied: curve_ccr")
      vrf_outdoor_unit.setCoolingCombinationRatioCorrectionFactorCurve(map_performance_data['curve_ccr'])
    end
    if map_performance_data['curve_onoff_cplffplr'].nil?
      # puts("*** curve not applied because it is nill: curve_onoff_cplffplr")
      vrf_outdoor_unit.resetCoolingPartLoadFractionCorrelationCurve
    else
      # puts("*** curve applied: curve_onoff_cplffplr")
      vrf_outdoor_unit.setCoolingPartLoadFractionCorrelationCurve(map_performance_data['curve_onoff_cplffplr'])
    end

    # heating
    if map_performance_data['curve_hcapft_boundary'].nil?
      # puts("*** curve not applied because it is nill: curve_hcapft_boundary")
      vrf_outdoor_unit.resetHeatingCapacityRatioBoundaryCurve
    else
      # puts("*** curve applied: curve_hcapft_boundary")
      vrf_outdoor_unit.setHeatingCapacityRatioBoundaryCurve(map_performance_data['curve_hcapft_boundary'])
    end
    if map_performance_data['curve_low_hcapft'].nil?
      # puts("*** curve not applied because it is nill: curve_low_hcapft")
      vrf_outdoor_unit.resetHeatingCapacityRatioModifierFunctionofLowTemperatureCurve
    else
      # puts("*** curve applied: curve_low_hcapft")
      vrf_outdoor_unit.setHeatingCapacityRatioModifierFunctionofLowTemperatureCurve(map_performance_data['curve_low_hcapft'])
    end
    if map_performance_data['curve_high_hcapft'].nil?
      # puts("*** curve not applied because it is nill: curve_high_hcapft")
      vrf_outdoor_unit.resetHeatingCapacityRatioModifierFunctionofHighTemperatureCurve
    else
      # puts("*** curve applied: curve_high_hcapft")
      vrf_outdoor_unit.setHeatingCapacityRatioModifierFunctionofHighTemperatureCurve(map_performance_data['curve_high_hcapft'])
    end
    if map_performance_data['curve_heirft_boundary'].nil?
      # puts("*** curve not applied because it is nill: curve_heirft_boundary")
      vrf_outdoor_unit.resetHeatingEnergyInputRatioBoundaryCurve
    else
      # puts("*** curve applied: curve_heirft_boundary")
      vrf_outdoor_unit.setHeatingEnergyInputRatioBoundaryCurve(map_performance_data['curve_heirft_boundary'])
    end
    if map_performance_data['curve_low_heirft'].nil?
      # puts("*** curve not applied because it is nill: curve_low_heirft")
      vrf_outdoor_unit.resetHeatingEnergyInputRatioModifierFunctionofLowTemperatureCurve
    else
      # puts("*** curve applied: curve_low_heirft")
      vrf_outdoor_unit.setHeatingEnergyInputRatioModifierFunctionofLowTemperatureCurve(map_performance_data['curve_low_heirft'])
    end
    if map_performance_data['curve_high_heirft'].nil?
      # puts("*** curve not applied because it is nill: curve_high_heirft")
      vrf_outdoor_unit.resetHeatingEnergyInputRatioModifierFunctionofHighTemperatureCurve
    else
      # puts("*** curve applied: curve_high_heirft")
      vrf_outdoor_unit.setHeatingEnergyInputRatioModifierFunctionofHighTemperatureCurve(map_performance_data['curve_high_heirft'])
    end
    if map_performance_data['curve_low_heirfplr'].nil?
      # puts("*** curve not applied because it is nill: curve_low_heirfplr")
      vrf_outdoor_unit.resetHeatingEnergyInputRatioModifierFunctionofLowPartLoadRatioCurve
    else
      # puts("*** curve applied: curve_low_heirfplr")
      vrf_outdoor_unit.setHeatingEnergyInputRatioModifierFunctionofLowPartLoadRatioCurve(map_performance_data['curve_low_heirfplr'])
    end
    if map_performance_data['curve_high_heirfplr'].nil?
      # puts("*** curve not applied because it is nill: curve_high_heirfplr")
      vrf_outdoor_unit.resetHeatingEnergyInputRatioModifierFunctionofHighPartLoadRatioCurve
    else
      # puts("*** curve applied: curve_high_heirfplr")
      vrf_outdoor_unit.setHeatingEnergyInputRatioModifierFunctionofHighPartLoadRatioCurve(map_performance_data['curve_high_heirfplr'])
    end
    if map_performance_data['curve_hcr'].nil?
      # puts("*** curve not applied because it is nill: curve_hcr")
      vrf_outdoor_unit.resetHeatingCombinationRatioCorrectionFactorCurve
    else
      # puts("*** curve applied: curve_hcr")
      vrf_outdoor_unit.setHeatingCombinationRatioCorrectionFactorCurve(map_performance_data['curve_hcr'])
    end
    if map_performance_data['curve_onoff_hplffplr'].nil?
      # puts("*** curve not applied because it is nill: curve_onoff_hplffplr")
      vrf_outdoor_unit.resetHeatingPartLoadFractionCorrelationCurve
    else
      # puts("*** curve applied: curve_onoff_hplffplr")
      vrf_outdoor_unit.setHeatingPartLoadFractionCorrelationCurve(map_performance_data['curve_onoff_hplffplr'])
    end
    if map_performance_data['curve_defrost_heirft'].nil?
      # puts("*** curve not applied because it is nill: curve_defrost_heirft")
      vrf_outdoor_unit.resetDefrostEnergyInputRatioModifierFunctionofTemperatureCurve
    else
      # puts("*** curve applied: curve_defrost_heirft")
      vrf_outdoor_unit.setDefrostEnergyInputRatioModifierFunctionofTemperatureCurve(map_performance_data['curve_defrost_heirft'])
    end

    # other configurations
    if map_performance_data['heating_oa_temperature_type'].nil?
      # puts("*** configuration not applied because it is nill: heating_oa_temperature_type")
    else
      # puts("*** configuration applied: heating_oa_temperature_type")
      vrf_outdoor_unit.setHeatingPerformanceCurveOutdoorTemperatureType(map_performance_data['heating_oa_temperature_type'])
    end
    if map_performance_data['min_hp_plr'].nil?
      # puts("*** configuration not applied because it is nill: min_hp_plr")
    else
      # puts("*** configuration applied: min_hp_plr")
      vrf_outdoor_unit.setMinimumHeatPumpPartLoadRatio(map_performance_data['min_hp_plr'])
    end
    if map_performance_data['heating_rated_cop'].nil?
      # puts("*** configuration not applied because it is nill: heating_rated_cop")
    else
      # puts("*** configuration applied: heating_rated_cop")
      vrf_outdoor_unit.setRatedHeatingCOP(map_performance_data['heating_rated_cop'])
    end
    if map_performance_data['cooling_rated_cop'].nil?
      # puts("*** configuration not applied because it is nill: cooling_rated_cop")
    else
      # puts("*** configuration applied: cooling_rated_cop")
      vrf_outdoor_unit.setGrossRatedCoolingCOP(map_performance_data['cooling_rated_cop'])
    end
    if map_performance_data['vrf_defrost_strategy'].nil?
      # puts("*** configuration not applied because it is nill: vrf_defrost_strategy")
    else
      # puts("*** configuration applied: vrf_defrost_strategy")
      vrf_outdoor_unit.setDefrostStrategy(map_performance_data['vrf_defrost_strategy'])
    end
    if map_performance_data['disable_defrost'] == true
      # puts("*** configuration applied: disabling defrost")
      vrf_outdoor_unit.setDefrostControl('timed')
      vrf_outdoor_unit.setDefrostTimePeriodFraction(0.0)
      vrf_outdoor_unit.setResistiveDefrostHeaterCapacity(0.0)
    end
    unless map_performance_data['min_oa_temp_cooling'].nil?
      vrf_outdoor_unit.setMinimumOutdoorTemperatureinCoolingMode(map_performance_data['min_oa_temp_cooling'])
    end
    unless map_performance_data['max_oa_temp_cooling'].nil?
      vrf_outdoor_unit.setMaximumOutdoorTemperatureinCoolingMode(map_performance_data['max_oa_temp_cooling'])
    end
    unless map_performance_data['max_oa_temp_heating'].nil?
      vrf_outdoor_unit.setMaximumOutdoorTemperatureinHeatingMode(map_performance_data['max_oa_temp_heating'])
    end
    unless map_performance_data['min_oa_temp_heatrecovery'].nil?
      vrf_outdoor_unit.setMinimumOutdoorTemperatureinHeatRecoveryMode(map_performance_data['min_oa_temp_heatrecovery'])
    end
    unless map_performance_data['max_oa_temp_heatrecovery'].nil?
      vrf_outdoor_unit.setMaximumOutdoorTemperatureinHeatRecoveryMode(map_performance_data['max_oa_temp_heatrecovery'])
    end
    unless map_performance_data['initial_heatrecovery_cap_frac_cooling'].nil?
      vrf_outdoor_unit.setInitialHeatRecoveryCoolingCapacityFraction(map_performance_data['initial_heatrecovery_cap_frac_cooling'])
    end
    unless map_performance_data['initial_heatrecovery_en_frac_cooling'].nil?
      vrf_outdoor_unit.setInitialHeatRecoveryCoolingEnergyFraction(map_performance_data['initial_heatrecovery_en_frac_cooling'])
    end
    unless map_performance_data['initial_heatrecovery_cap_frac_heating'].nil?
      vrf_outdoor_unit.setInitialHeatRecoveryHeatingCapacityFraction(map_performance_data['initial_heatrecovery_cap_frac_heating'])
    end
    unless map_performance_data['initial_heatrecovery_en_frac_heating'].nil?
      vrf_outdoor_unit.setInitialHeatRecoveryHeatingEnergyFraction(map_performance_data['initial_heatrecovery_en_frac_heating'])
    end
    unless map_performance_data['initial_heatrecovery_cap_timeconstant_cooling'].nil?
      vrf_outdoor_unit.setHeatRecoveryCoolingCapacityTimeConstant(map_performance_data['initial_heatrecovery_cap_timeconstant_cooling'])
    end
    unless map_performance_data['initial_heatrecovery_en_timeconstant_cooling'].nil?
      vrf_outdoor_unit.setHeatRecoveryCoolingEnergyTimeConstant(map_performance_data['initial_heatrecovery_en_timeconstant_cooling'])
    end
    unless map_performance_data['initial_heatrecovery_cap_timeconstant_heating'].nil?
      vrf_outdoor_unit.setHeatRecoveryHeatingCapacityTimeConstant(map_performance_data['initial_heatrecovery_cap_timeconstant_heating'])
    end
    return if map_performance_data['initial_heatrecovery_en_timeconstant_heating'].nil?

    vrf_outdoor_unit.setHeatRecoveryHeatingEnergyTimeConstant(map_performance_data['initial_heatrecovery_en_timeconstant_heating'])
  end

  # --------------------------------------- #
  # supporting method
  # check if air loop is evaporative cooler
  # --------------------------------------- #
  def air_loop_hvac_include_evaporative_cooler?(air_loop_hvac)
    air_loop_hvac.supplyComponents.each do |comp|
      return true if comp.to_EvaporativeCoolerDirectResearchSpecial.is_initialized
      return true if comp.to_EvaporativeCoolerIndirectResearchSpecial.is_initialized
    end
    false
  end

  # --------------------------------------- #
  # supporting method
  # check if air loop uses district energy
  # --------------------------------------- #
  def air_loop_hvac_served_by_district_energy?(air_loop_hvac)
    served_by_district_energy = false
    thermalzones = air_loop_hvac.thermalZones
    district_energy_types = []
    thermalzones.each do |thermalzone|
      zone_fuels = ''
      htg_fuels = thermalzone.heatingFuelTypes.map(&:valueName)
      if htg_fuels.include?('DistrictHeatingWater')
        zone_fuels = 'DistrictHeatingWater'
        district_energy_types << zone_fuels
      end
      clg_fuels = thermalzone.coolingFuelTypes.map(&:valueName)
      if clg_fuels.include?('DistrictCooling')
        zone_fuels += 'DistrictCooling'
        district_energy_types << zone_fuels
      end
    end
    served_by_district_energy = true unless district_energy_types.empty?
    served_by_district_energy
  end

  # --------------------------------------- #
  # supporting method
  # check if air loop is served by DOAS
  # --------------------------------------- #
  def air_loop_hvac_served_by_doas?(air_loop_hvac)
    is_doas = false
    sizing_system = air_loop_hvac.sizingSystem
    is_doas = true if sizing_system.allOutdoorAirinCooling && sizing_system.allOutdoorAirinHeating
    is_doas
  end

  # --------------------------------------- #
  # supporting method
  # Return hash of flags for whether storey is conditioned and average ceiling z-coordinates of building storeys.
  # reference: https://github.com/NREL/openstudio-standards/blob/12bbfabf3962af05b8c267c1da54b8e3a89217a0/lib/openstudio-standards/standards/necb/ECMS/hvac_systems.rb#L99
  # --------------------------------------- #
  def get_storey_avg_clg_zcoords(model)
    storey_avg_clg_zcoords = {}
    model.getBuildingStorys.each do |storey|
      storey_avg_clg_zcoords[storey] = []
      storey_cond = false
      total_area = 0.0
      sum = 0.0
      storey.spaces.each do |space|
        # Determine if any of the spaces/zones of the storey are conditioned? If yes then the floor is considered to be conditioned
        if space.thermalZone.is_initialized
          zone = space.thermalZone.get
          if zone.thermostat.is_initialized && zone.thermostat.get.to_ThermostatSetpointDualSetpoint.is_initialized && (zone.thermostat.get.to_ThermostatSetpointDualSetpoint.get.heatingSetpointTemperatureSchedule.is_initialized ||
                 zone.thermostat.get.to_ThermostatSetpointDualSetpoint.get.coolingSetpointTemperatureSchedule.is_initialized)
            storey_cond = true
          end
        end
        # Find average height of z-coordinates of ceiling/roof of floor
        space.surfaces.each do |surf|
          if surf.surfaceType.to_s.upcase == 'ROOFCEILING'
            sum += (surf.centroid.z.to_f + space.zOrigin.to_f) * surf.grossArea.to_f
            total_area += surf.grossArea.to_f
          end
        end
      end
      storey_avg_clg_zcoords[storey] << storey_cond
      storey_avg_clg_zcoords[storey] << (sum / total_area)
    end

    storey_avg_clg_zcoords
  end

  # --------------------------------------- #
  # supporting method
  # Return x,y,z coordinates of the centroid of the roof of the storey
  # reference: https://github.com/NREL/openstudio-standards/blob/12bbfabf3962af05b8c267c1da54b8e3a89217a0/lib/openstudio-standards/standards/necb/ECMS/hvac_systems.rb#L188
  # --------------------------------------- #
  def get_roof_centroid_coords(storey)
    sum_x = 0.0
    sum_y = 0.0
    sum_z = 0.0
    total_area = 0.0
    cent_x = nil
    cent_y = nil
    cent_z = nil
    storey.spaces.each do |space|
      roof_surfaces = space.surfaces.select do |surf|
        (surf.surfaceType.to_s.upcase == 'ROOFCEILING') && (surf.outsideBoundaryCondition.to_s.upcase == 'OUTDOORS')
      end
      roof_surfaces.each do |surf|
        sum_x += (surf.centroid.x.to_f + space.xOrigin.to_f) * surf.grossArea.to_f
        sum_y += (surf.centroid.y.to_f + space.yOrigin.to_f) * surf.grossArea.to_f
        sum_z += (surf.centroid.z.to_f + space.zOrigin.to_f) * surf.grossArea.to_f
        total_area += surf.grossArea.to_f
      end
    end
    if total_area > 0.0
      cent_x = sum_x / total_area
      cent_y = sum_y / total_area
      cent_z = sum_z / total_area
    else
      OpenStudio.logFree(OpenStudio::Info, 'openstudiostandards.get_roof_centroid_coords',
                         'Did not find a roof on the top floor!')
    end

    [cent_x, cent_y, cent_z]
  end

  # --------------------------------------- #
  # supporting method
  # Return x,y,z coordinates of space centroid
  # reference: https://github.com/NREL/openstudio-standards/blob/12bbfabf3962af05b8c267c1da54b8e3a89217a0/lib/openstudio-standards/standards/necb/ECMS/hvac_systems.rb#L168
  # --------------------------------------- #
  def get_space_centroid_coords(space)
    total_area = 0.0
    sum_x = 0.0
    sum_y = 0.0
    sum_z = 0.0
    space.surfaces.each do |surf|
      total_area += surf.grossArea.to_f
      sum_x += (surf.centroid.x.to_f + space.xOrigin.to_f) * surf.grossArea.to_f
      sum_y += (surf.centroid.y.to_f + space.yOrigin.to_f) * surf.grossArea.to_f
      sum_z += (surf.centroid.z.to_f + space.zOrigin.to_f) * surf.grossArea.to_f
    end
    space_centroid_x = sum_x / total_area
    space_centroid_y = sum_y / total_area
    space_centroid_z = sum_z / total_area

    [space_centroid_x, space_centroid_y, space_centroid_z]
  end

  # --------------------------------------- #
  # supporting method
  # Return x,y,z coordinates of exterior wall with largest area on the lowest floor
  # reference: https://github.com/NREL/openstudio-standards/blob/12bbfabf3962af05b8c267c1da54b8e3a89217a0/lib/openstudio-standards/standards/necb/ECMS/hvac_systems.rb#L136
  # --------------------------------------- #
  def get_lowest_floor_ext_wall_centroid_coords(storeys_clg_zcoords)
    ext_wall = nil
    ext_wall_x = nil
    ext_wall_y = nil
    ext_wall_z = nil
    storeys_clg_zcoords.keys.each do |storey|
      max_area = 0.0
      sorted_spaces = storey.spaces.sort_by { |space| space.name.to_s }
      sorted_spaces.each do |space|
        ext_walls = space.surfaces.select do |surf|
          (surf.surfaceType.to_s.upcase == 'WALL') && (surf.outsideBoundaryCondition.to_s.upcase == 'OUTDOORS')
        end
        ext_walls = ext_walls.sort_by { |wall| wall.grossArea.to_f }
        next if ext_walls.empty? && (ext_walls.last.grossArea.to_f > max_area)

        max_area = ext_walls.last.grossArea.to_f
        ext_wall_x = ext_walls.last.centroid.x.to_f + space.xOrigin.to_f
        ext_wall_y = ext_walls.last.centroid.y.to_f + space.yOrigin.to_f
        ext_wall_z = ext_walls.last.centroid.z.to_f + space.zOrigin.to_f
        ext_wall = ext_walls.last
      end
      break if ext_wall
    end
    unless ext_wall
      OpenStudio.logFree(OpenStudio::Info, 'openstudiostandards.get_lowest_floor_ext_wall_centroid_coords',
                         'Did not find an exteior wall in the building!')
    end

    [ext_wall_x, ext_wall_y, ext_wall_z]
  end

  # --------------------------------------- #
  # supporting method
  # Determine maximum equivalent and net vertical pipe runs for VRF model
  # reference: https://github.com/NREL/openstudio-standards/blob/12bbfabf3962af05b8c267c1da54b8e3a89217a0/lib/openstudio-standards/standards/necb/ECMS/hvac_systems.rb#L218
  # --------------------------------------- #
  def get_max_vrf_pipe_lengths(model, thermal_zones)
    # Get and sort floors average ceilings z-coordinates hash
    storeys_clg_zcoords = get_storey_avg_clg_zcoords(model)
    storeys_clg_zcoords = storeys_clg_zcoords.sort_by do |_key, value|
      value[1]
    end.to_h # sort storeys hash based on ceiling/roof z-coordinate
    if storeys_clg_zcoords.values.last[0]
      # If the top floor is conditioned, then assume the top floor is not an attic floor and place the VRF outdoor unit at the roof centroid
      location_cent_x, location_cent_y, location_cent_z = get_roof_centroid_coords(storeys_clg_zcoords.keys.last)
      # puts("--- VRF outdoor unit location: roof (vertical height from ground = #{location_cent_z} m)")
    else
      # If the top floor is not conditioned, then assume it's an attic floor. In this case place the VRF outdoor unit next to the centroid
      # of the exterior wall with the largest area on the lowest floor.
      location_cent_x, location_cent_y, location_cent_z = get_lowest_floor_ext_wall_centroid_coords(storeys_clg_zcoords)
      # puts("--- VRF outdoor unit location: outside in the lowest floor (vertical height from ground = #{location_cent_z} m)")
    end
    # Initialize distances
    max_equiv_distance = 0.0
    max_vert_distance = 0.0
    min_vert_distance = 0.0
    thermal_zones.each do |thermal_zone|
      thermal_zone.spaces.each do |space|
        # Is there a VRF terminal unit in the space/zone?
        vrf_term_units = []
        if space.thermalZone.is_initialized
          vrf_term_units = space.thermalZone.get.equipment.select do |eqpt|
            eqpt.to_ZoneHVACTerminalUnitVariableRefrigerantFlow.is_initialized
          end
        end
        next if vrf_term_units.empty?

        space_centroid_x, space_centroid_y, space_centroid_z = get_space_centroid_coords(space)
        # puts("--- VRF indoor unit location (#{space.name}): space_centroid_z = #{space_centroid_z} m")
        # Update max horizontal and vertical distances if needed
        equiv_distance = (location_cent_x.to_f - space_centroid_x.to_f).abs +
                         (location_cent_y.to_f - space_centroid_y.to_f).abs +
                         (location_cent_z.to_f - space_centroid_z.to_f).abs
        max_equiv_distance = equiv_distance if equiv_distance > max_equiv_distance
        pos_vert_distance = [space_centroid_z.to_f - location_cent_z.to_f, 0.0].max
        # puts("--- VRF indoor unit location (#{space.name}): pos_vert_distance = #{pos_vert_distance} m")
        max_vert_distance = pos_vert_distance if pos_vert_distance > max_vert_distance
        # puts("--- VRF indoor unit location (#{space.name}): max_vert_distance = #{max_vert_distance} m")
        neg_vert_distance = [space_centroid_z.to_f - location_cent_z.to_f, 0.0].min
        # puts("--- VRF indoor unit location (#{space.name}): neg_vert_distance = #{neg_vert_distance} m")
        min_vert_distance = neg_vert_distance if neg_vert_distance < min_vert_distance
        # puts("--- VRF indoor unit location (#{space.name}): min_vert_distance = #{min_vert_distance} m")
      end
    end
    max_net_vert_distance = max_vert_distance + min_vert_distance
    # puts("--- VRF outdoor unit location: max_net_vert_distance = #{max_net_vert_distance} m")
    [max_equiv_distance, max_net_vert_distance]
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    template = 'ComStock 90.1-2019'
    std = Standard.build(template)

    ######################################################
    # puts("### use the built-in error checking")
    ######################################################
    return false unless runner.validateUserArguments(arguments(model), user_arguments)

    ######################################################
    # puts('### obtain user inputs')
    ######################################################
    apply_measure = runner.getBoolArgumentValue('apply_measure', user_arguments)
    vrf_defrost_strategy = runner.getStringArgumentValue('vrf_defrost_strategy', user_arguments)
    disable_defrost = runner.getBoolArgumentValue('disable_defrost', user_arguments)
    upsizing_allowance_pct = runner.getDoubleArgumentValue('upsizing_allowance_pct', user_arguments)

    ######################################################
    # puts('### check input argument values')
    ######################################################
    runner.registerError('Upsizing allowance percentage cannot be a negative value.') if upsizing_allowance_pct < 0

    ######################################################
    # puts("### report initial condition of model")
    ######################################################
    runner.registerInitialCondition("The building started with #{model.getAirLoopHVACs.size} air loops and #{model.getPlantLoops.size} plant loops.")

    ######################################################
    # puts('### adding output variables (for debugging)')
    ######################################################
    # ov1 = OpenStudio::Model::OutputVariable.new('debugging_ov1', model)
    # ov1.setKeyValue('*')
    # ov1.setReportingFrequency('timestep')
    # ov1.setVariableName('VRF Heat Pump Cooling COP')

    # ov2 = OpenStudio::Model::OutputVariable.new('debugging_ov2', model)
    # ov2.setKeyValue('*')
    # ov2.setReportingFrequency('timestep')
    # ov2.setVariableName('VRF Heat Pump Heating COP')

    # ov3 = OpenStudio::Model::OutputVariable.new('debugging_ov3', model)
    # ov3.setKeyValue('*')
    # ov3.setReportingFrequency('timestep')
    # ov3.setVariableName('VRF Heat Pump COP')

    # ov4 = OpenStudio::Model::OutputVariable.new('debugging_ov4', model)
    # ov4.setKeyValue('*')
    # ov4.setReportingFrequency('timestep')
    # ov4.setVariableName('VRF Heat Pump Operating Mode')

    # ov5 = OpenStudio::Model::OutputVariable.new('debugging_ov5', model)
    # ov5.setKeyValue('*')
    # ov5.setReportingFrequency('timestep')
    # ov5.setVariableName('VRF Heat Pump Defrost Electricity Rate')

    # ov6 = OpenStudio::Model::OutputVariable.new('debugging_ov6', model)
    # ov6.setKeyValue('*')
    # ov6.setReportingFrequency('timestep')
    # ov6.setVariableName('VRF Heat Pump Heat Recovery Rate')

    # ov7 = OpenStudio::Model::OutputVariable.new("debugging_ov7",model)
    # ov7.setKeyValue("*")
    # ov7.setReportingFrequency("timestep")
    # ov7.setVariableName("Site Outdoor Air Drybulb Temperature")

    # ov8 = OpenStudio::Model::OutputVariable.new("debugging_ov8",model)
    # ov8.setKeyValue("*")
    # ov8.setReportingFrequency("timestep")
    # ov8.setVariableName("VRF Heat Pump Total Cooling Rate")

    # ov9 = OpenStudio::Model::OutputVariable.new("debugging_ov9",model)
    # ov9.setKeyValue("*")
    # ov9.setReportingFrequency("timestep")
    # ov9.setVariableName("VRF Heat Pump Total Heating Rate")

    # ov10 = OpenStudio::Model::OutputVariable.new("debugging_ov10",model)
    # ov10.setKeyValue("*")
    # ov10.setReportingFrequency("timestep")
    # ov10.setVariableName("VRF Heat Pump Part Load Ratio")

    # ov11 = OpenStudio::Model::OutputVariable.new("debugging_ov11",model)
    # ov11.setKeyValue("*")
    # ov11.setReportingFrequency("timestep")
    # ov11.setVariableName("VRF Heat Pump Terminal Unit Cooling Load Rate")

    # ov12 = OpenStudio::Model::OutputVariable.new("debugging_ov12",model)
    # ov12.setKeyValue("*")
    # ov12.setReportingFrequency("timestep")
    # ov12.setVariableName("VRF Heat Pump Terminal Unit Heating Load Rate")

    # ov13 = OpenStudio::Model::OutputVariable.new("debugging_ov13",model)
    # ov13.setKeyValue("*")
    # ov13.setReportingFrequency("timestep")
    # ov13.setVariableName("VRF Heat Pump Cooling Electricity Rate")

    # ov14 = OpenStudio::Model::OutputVariable.new("debugging_ov14",model)
    # ov14.setKeyValue("*")
    # ov14.setReportingFrequency("timestep")
    # ov14.setVariableName("VRF Heat Pump Heating Electricity Rate")

    # ov15 = OpenStudio::Model::OutputVariable.new("debugging_ov15",model)
    # ov15.setKeyValue("*")
    # ov15.setReportingFrequency("timestep")
    # ov15.setVariableName("VRF Heat Pump Cycling Ratio")

    # ov16 = OpenStudio::Model::OutputVariable.new("debugging_ov16",model)
    # ov16.setKeyValue("CEIRFT_Daikin_RELQ_100CR_120MBH")
    # ov16.setReportingFrequency("timestep")
    # ov16.setVariableName("Performance Curve Input Variable 1 Value")

    # ov17 = OpenStudio::Model::OutputVariable.new("debugging_ov17",model)
    # ov17.setKeyValue("CEIRFT_Daikin_RELQ_100CR_120MBH")
    # ov17.setReportingFrequency("timestep")
    # ov17.setVariableName("Performance Curve Input Variable 2 Value")

    # ov18 = OpenStudio::Model::OutputVariable.new("debugging_ov18",model)
    # ov18.setKeyValue("CEIRFT_Daikin_RELQ_100CR_120MBH")
    # ov18.setReportingFrequency("timestep")
    # ov18.setVariableName("Performance Curve Output Value")

    # ov16 = OpenStudio::Model::OutputVariable.new("debugging_ov16",model)
    # ov16.setKeyValue("CCAPFT_Daikin_RELQ_100CR_120MBH")
    # ov16.setReportingFrequency("timestep")
    # ov16.setVariableName("Performance Curve Input Variable 1 Value")

    # ov17 = OpenStudio::Model::OutputVariable.new("debugging_ov17",model)
    # ov17.setKeyValue("CCAPFT_Daikin_RELQ_100CR_120MBH")
    # ov17.setReportingFrequency("timestep")
    # ov17.setVariableName("Performance Curve Input Variable 2 Value")

    # ov18 = OpenStudio::Model::OutputVariable.new("debugging_ov18",model)
    # ov18.setKeyValue("CCAPFT_Daikin_RELQ_100CR_120MBH")
    # ov18.setReportingFrequency("timestep")
    # ov18.setVariableName("Performance Curve Output Value")

    # ov16 = OpenStudio::Model::OutputVariable.new("debugging_ov16",model)
    # ov16.setKeyValue("HEIRFT_Daikin_RELQ_100CR_120MBH")
    # ov16.setReportingFrequency("timestep")
    # ov16.setVariableName("Performance Curve Input Variable 1 Value")

    # ov17 = OpenStudio::Model::OutputVariable.new("debugging_ov17",model)
    # ov17.setKeyValue("HEIRFT_Daikin_RELQ_100CR_120MBH")
    # ov17.setReportingFrequency("timestep")
    # ov17.setVariableName("Performance Curve Input Variable 2 Value")

    # ov18 = OpenStudio::Model::OutputVariable.new("debugging_ov18",model)
    # ov18.setKeyValue("HEIRFT_Daikin_RELQ_100CR_120MBH")
    # ov18.setReportingFrequency("timestep")
    # ov18.setVariableName("Performance Curve Output Value")

    # ov16 = OpenStudio::Model::OutputVariable.new("debugging_ov16",model)
    # ov16.setKeyValue("HCAPFT_Daikin_RELQ_100CR_120MBH")
    # ov16.setReportingFrequency("timestep")
    # ov16.setVariableName("Performance Curve Input Variable 1 Value")

    # ov17 = OpenStudio::Model::OutputVariable.new("debugging_ov17",model)
    # ov17.setKeyValue("HCAPFT_Daikin_RELQ_100CR_120MBH")
    # ov17.setReportingFrequency("timestep")
    # ov17.setVariableName("Performance Curve Input Variable 2 Value")

    # ov18 = OpenStudio::Model::OutputVariable.new("debugging_ov18",model)
    # ov18.setKeyValue("HCAPFT_Daikin_RELQ_100CR_120MBH")
    # ov18.setReportingFrequency("timestep")
    # ov18.setVariableName("Performance Curve Output Value")

    # ov16 = OpenStudio::Model::OutputVariable.new("debugging_ov16",model)
    # ov16.setKeyValue("Curve Cubic 5")
    # ov16.setReportingFrequency("timestep")
    # ov16.setVariableName("Performance Curve Input Variable 1 Value")

    # ov18 = OpenStudio::Model::OutputVariable.new("debugging_ov18",model)
    # ov18.setKeyValue("Curve Cubic 5")
    # ov18.setReportingFrequency("timestep")
    # ov18.setVariableName("Performance Curve Output Value")

    # ov16 = OpenStudio::Model::OutputVariable.new("debugging_ov16",model)
    # ov16.setKeyValue("Curve Cubic 7")
    # ov16.setReportingFrequency("timestep")
    # ov16.setVariableName("Performance Curve Input Variable 1 Value")

    # ov18 = OpenStudio::Model::OutputVariable.new("debugging_ov18",model)
    # ov18.setKeyValue("Curve Cubic 7")
    # ov18.setReportingFrequency("timestep")
    # ov18.setVariableName("Performance Curve Output Value")

    # ov18 = OpenStudio::Model::OutputVariable.new("debugging_ov18",model)
    # ov18.setKeyValue("Curve Biquadratic 5")
    # ov18.setReportingFrequency("timestep")
    # ov18.setVariableName("Performance Curve Output Value")

    # ov18 = OpenStudio::Model::OutputVariable.new("debugging_ov18",model)
    # ov18.setKeyValue("*")
    # ov18.setReportingFrequency("timestep")
    # ov18.setVariableName("Zone VRF Air Terminal Total Heating Rate")

    # ov18 = OpenStudio::Model::OutputVariable.new("debugging_ov18",model)
    # ov18.setKeyValue("*")
    # ov18.setReportingFrequency("timestep")
    # ov18.setVariableName("Zone VRF Air Terminal Total Cooling Rate")

    # ov18 = OpenStudio::Model::OutputVariable.new("debugging_ov18",model)
    # ov18.setKeyValue("*")
    # ov18.setReportingFrequency("timestep")
    # ov18.setVariableName("VRF Heat Pump Runtime Fraction")

    ######################################################
    # puts('### applicability')
    ######################################################
    # applicability: don't apply measure if specified in input
    if apply_measure == false
      runner.registerAsNotApplicable('Measure is not applied based on user input.')
      return true
    end

    # applicability: building type that has large exhaust
    building_types_to_exclude = [
      # 'Rtl', # Retail - Single-Story Large
      # 'Rt3', # Retail - Multistory Large
      # 'RtS', # Retail - Small
      'RFF', # Restaurant - Fast-Food
      'RSD', # Restaurant - Sit-Down
      'Hsp', # Health/Medical - Hospital
      # 'RetailStandalone',
      # 'RetailStripmall',
      'QuickServiceRestaurant',
      'FullServiceRestaurant',
      'Hospital'
    ]
    building_types_to_exclude = building_types_to_exclude.map(&:downcase)
    model_building_type = nil
    if model.getBuilding.standardsBuildingType.is_initialized
      model_building_type = model.getBuilding.standardsBuildingType.get
    else
      runner.registerError('model.getBuilding.standardsBuildingType is empty.')
      return true
    end
    if building_types_to_exclude.include?(model_building_type.downcase)
      # puts("&&& applicability not passed due to building type (buildings with large exhaust): #{model_building_type}")
      runner.registerAsNotApplicable("applicability not passed due to building type (buildings with large exhaust): #{model_building_type}")
      return true
      # else puts("&&& applicability passed for building type: #{model_building_type}")
    end

    # applicability: floor area too large
    limit_floor_area_ft2 = 200_000
    total_area_m2 = model.building.get.floorArea.to_f
    total_area_ft2 = OpenStudio.convert(total_area_m2, 'm^2', 'ft^2').get
    if total_area_ft2 >= limit_floor_area_ft2
      # puts("&&& applicability not passed due to total floor area being too large: #{total_area_ft2.round(0)} sqft")
      runner.registerAsNotApplicable("applicability not passed due to total floor area being too large: #{total_area_ft2.round(0)} sqft")
      return true
      # else puts("&&& applicability passed for floor area: #{total_area_ft2.round(0)} sqft")
    end

    # applicability: HVAC type (RTUs and VAVs that do not leverage district heating/cooling)
    applicable_air_loops = []
    na_air_loops = []
    na_mz_thermal_zones = []
    applicability = []
    applicability_msgs = []
    applicability_msg = ''
    air_loop_hvacs = model.getAirLoopHVACs
    if air_loop_hvacs.empty?
      applicability_msg = 'this model does not have an air loop (so neither RTU nor VAV). so, skipping this model...'
      # puts("&&& #{applicability_msg}")
      applicability_msgs << applicability_msg
      applicability << false
      runner.registerAsNotApplicable(applicability_msg.to_s)
      return true
    else
      air_loop_hvacs.each do |air_loop_hvac|
        # puts("&&& this model has an air loop. checking air loop named #{air_loop_hvac.name}")

        # exclude if it is DOAS
        if air_loop_hvac_served_by_doas?(air_loop_hvac)
          # NOTE: is_doas as true seem to include not only DOAS but also residential AC based on testing with few samples
          applicability_msg = 'this air loop is either 100% outdoor air system or without outdoor air system. so, skipping this air loop system...'
          # puts("--- #{applicability_msg}")
          applicability_msgs << applicability_msg
          applicability << false
          na_air_loops << air_loop_hvac
          next
        end

        # exclude if it is evaporative cooler
        if air_loop_hvac_include_evaporative_cooler?(air_loop_hvac)
          applicability_msg = 'this air loop is an evaporative cooler. so, skipping this air loop system...'
          # puts("--- #{applicability_msg}")
          applicability_msgs << applicability_msg
          applicability << false
          na_air_loops << air_loop_hvac
          next
        end

        # Skip air loops that already have DX heating (heat pumps)
        dx_heating = false
        air_loop_hvac.supplyComponents.each do |component|
          # check main airloop for DX heating
          obj_type = component.iddObjectType.valueName.to_s
          if ['Heating_DX'].any? { |word| obj_type.include?(word) }
            dx_heating = true
          # check unitary systems for DX heating
          elsif obj_type == 'OS_AirLoopHVAC_UnitarySystem'
            unitary_sys = component.to_AirLoopHVACUnitarySystem.get
            if unitary_sys.heatingCoil.is_initialized
              htg_coil = unitary_sys.heatingCoil.get.iddObjectType.valueName.to_s
              # check for DX heating coil
              next unless ['Heating_DX'].any? { |word| htg_coil.include?(word) }

              dx_heating = true
            end
          end
        end
        if dx_heating == true
          applicability_msg = 'this air loop is already served by a heat pump. so, skipping this air loop system...'
          # puts("--- #{applicability_msg}")
          applicability_msgs << applicability_msg
          applicability << false
          na_air_loops << air_loop_hvac
          next
        end

        # exclude if it is leveraging district systems
        if air_loop_hvac_served_by_district_energy?(air_loop_hvac)
          applicability_msg = 'this air loop is using district energy. so, skipping this air loop system...'
          # puts("--- #{applicability_msg}")
          applicability_msgs << applicability_msg
          applicability << false
          na_air_loops << air_loop_hvac
          next
        end

        # exclude if residential system or no outdoor air
        unless air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized
          applicability_msg = 'this air loop uses a residential system with no outdoor air. so, skipping air loop system...'
          # puts("--- #{applicability_msg}")
          applicability_msgs << applicability_msg
          applicability << false
          na_air_loops << air_loop_hvac
          next
        end

        # check air loop thermal zones for applicability
        airloop_applicable_tz = []
        airloop_na_tz = []
        # air loops with non applicable thermal zones
        air_loop_hvac.thermalZones.sort.each do |tz|
          # skip food service zones
          if OpenstudioStandards::SpaceType.thermal_zone_serves_space_types?(tz, ['food preparation', 'dining'])
            airloop_na_tz << tz
          # skip non-conditioned thermal zones
          elsif !OpenstudioStandards::ThermalZone.thermal_zone_heated?(tz) && !OpenstudioStandards::ThermalZone.thermal_zone_cooled?(tz)
            airloop_na_tz << tz
          else
            airloop_applicable_tz << tz
          end
        end
        # skip airloop if no applicable thermal zones
        if airloop_applicable_tz.empty?
          applicability_msg = 'this air loop does not have any applicable thermal zones. so, skipping air loop system...'
          # puts("--- #{applicability_msg}")
          applicability_msgs << applicability_msg
          applicability << false
          na_air_loops << air_loop_hvac
          next
        end
        # find non applicable multizone thermal zones
        # these will need new single-zone system, so they need to be accounted for seperately
        if (air_loop_hvac.thermalZones.size > 1) & (!airloop_na_tz.empty?)
          # make sure multizone system is VAV
          if std.air_loop_hvac_multizone_vav_system?(air_loop_hvac) && std.air_loop_hvac_terminal_reheat?(air_loop_hvac)
            na_mz_thermal_zones += airloop_na_tz
          else
            applicability_msg = 'this air loop serves mutliple zones but neither RTU nor VAV/PVAV system. so, skipping this air loop system...'
            # puts("--- #{applicability_msg}")
            applicability_msgs << applicability_msg
            applicability << false
            na_air_loops << air_loop_hvac
            next
          end
        end

        # check applicability between RTU and VAV
        if air_loop_hvac.thermalZones.size == 1
          # RTU
          applicability_msg = 'this air loop represents RTU serving single zone and not using district energy systems'
          # puts("--- #{applicability_msg}")
          applicability_msgs << applicability_msg
          applicability << true
          applicable_air_loops << air_loop_hvac
        elsif std.air_loop_hvac_multizone_vav_system?(air_loop_hvac) && std.air_loop_hvac_terminal_reheat?(air_loop_hvac)
          # check for VAV
          applicability_msg = 'this air loop represents VAV system serving multiple zones and not using district energy systems'
          # puts("--- #{applicability_msg}")
          applicability_msgs << applicability_msg
          applicability << true
          applicable_air_loops << air_loop_hvac
        else
          applicability_msg = 'this air loop serves mutliple zones but neither RTU nor VAV/PVAV system. so, skipping this air loop system...'
          # puts("--- #{applicability_msg}")
          applicability_msgs << applicability_msg
          applicability << false
          na_air_loops << air_loop_hvac
          next
        end
      end
    end
    # check if building includes multiple types of HVAC systems
    if applicability_msgs.uniq.size == 1
      applicability_msg = applicability_msgs.uniq[0]
      runner.registerInfo("this building model includes single HVAC system type and the applicability result is as follows: #{applicability_msg}")
    else
      applicability_msg = 'this model includes multiple hvac system types'
      runner.registerInfo("this building model includes multiple types of HVAC systems and the applicability results are as follows: #{applicability_msgs}")
    end
    runner.registerValue('applicability_msg', applicability_msg)
    # determine final applicability
    if applicability.include?(true)
      runner.registerInfo('this building model is applicable for the upgrade')
    else
      runner.registerAsNotApplicable('this building model is not applicable for the upgrade')
      return true
    end

    # get applicable thermal zones from applicable air loops
    app_tz = []
    applicable_air_loops.each do |air_loop_hvac|
      air_loop_hvac.thermalZones.each do |tz|
        # skip nonapplicable thermal zones that are on applicable air loops
        next if na_mz_thermal_zones.include?(tz)

        app_tz << tz
      end
    end

    # reorganize applicable thermal zone for each floor
    applicable_thermalzone_per_floor = {}
    z_coord_all_floors = []
    # puts("&&& applicability: get z-coordinates for each floor")
    app_tz.each do |thermal_zone|
      thermal_zone.spaces.each do |space|
        bldgstory = space.buildingStory.get
        z_coord_all_floors << bldgstory.nominalZCoordinate.get
      end
    end
    z_coord_all_floors = z_coord_all_floors.uniq
    # puts("&&& applicability: initialize hash to store thermal zone per floor")
    z_coord_all_floors.each do |z_coord_floor|
      applicable_thermalzone_per_floor[z_coord_floor] = []
    end
    # puts("&&& applicability: add thermal zone in each floor to hash")
    app_tz.each do |thermal_zone|
      z_coords_space = []
      thermal_zone.spaces.each do |space|
        z_coord_space = space.buildingStory.get.nominalZCoordinate.get
        z_coords_space << z_coord_space
      end
      z_coords_space = z_coords_space.uniq
      if z_coords_space.size != 1
        runner.registerError("Thermal zone (#{thermal_zone.name}) includes spaces across different floors. Cannot keep outdoor unit per each floor.")
      end
      if applicable_thermalzone_per_floor.key?(z_coords_space[0])
        applicable_thermalzone_per_floor[z_coords_space[0]] << thermal_zone
      end
    end

    # applicability: number of indoor units per outdoor unit
    max_number_indoor_units_per_outdoor_unit = 41 # hardcoded based on manufacturer engineering manual
    max_indoor_unit_count_per_outdoor_unit = 0
    applicable_thermalzone_per_floor.each do |_z_coord, zones|
      # puts("checking number of thermal zones on each floor: z-coord = #{z_coord}")
      # puts("total number of thermal zones: #{zones.size} ")
      max_indoor_unit_count_per_outdoor_unit = zones.size if zones.size > max_indoor_unit_count_per_outdoor_unit
    end
    if max_indoor_unit_count_per_outdoor_unit <= max_number_indoor_units_per_outdoor_unit
      runner.registerInfo('this building model is applicable for the upgrade in terms of indoor unit counts')
    else
      runner.registerAsNotApplicable("this building model is not applicable because the number of indoor units exceeds #{max_number_indoor_units_per_outdoor_unit} per an outdoor unit")
      return true
    end

    # determine heating fuel type for non applicable thermal zones on applicable multizone systems
    # this will determine heating fuel of new system for the non applicable thermal zone
    htg_type = 'Electricity'
    unless na_mz_thermal_zones.empty?
      # loop through reheat types - if gas is found, assume new system to non applicable thermal zone uses gas. Otherwise, assume electric
      model.getAirTerminalSingleDuctVAVReheats.each do |terminal|
        reheat_coil = terminal.reheatCoil
        if reheat_coil.to_CoilHeatingWater.is_initialized
          htg_type = 'NaturalGas'
        elsif reheat_coil.to_CoilHeatingGas.is_initialized
          htg_type = 'NaturalGas'
        end
      end
      model.getAirTerminalSingleDuctParallelPIUReheats.each do |terminal|
        reheat_coil = terminal.reheatCoil
        if reheat_coil.to_CoilHeatingWater.is_initialized
          htg_type = 'NaturalGas'
        elsif reheat_coil.to_CoilHeatingGas.is_initialized
          htg_type = 'NaturalGas'
        end
      end
    end

    # Remove air aloops
    applicable_air_loops.each do |air_loop|
      # Don't remove airloops representing non-mechanically cooled systems
      if !air_loop.additionalProperties.hasFeature('non_mechanically_cooled')
        air_loop.remove
      else
        # Remove heating coil on
        air_loop.supplyComponents.each do |supply_comp|
          # Remove standalone heating coils
          if supply_comp.iddObjectType.valueName.to_s.include?('OS_Coil_Heating')
            supply_comp.remove
          # Remove heating coils wrapped in a unitary system
          elsif supply_comp.iddObjectType.valueName.to_s.include?('OS_AirLoopHVAC_UnitarySystem')
            unitary_system = supply_comp.to_AirLoopHVACUnitarySystem.get
            htg_coil = unitary_system.heatingCoil
            if htg_coil.is_initialized
              htg_coil = htg_coil.get
              unitary_system.resetCoolingCoil
              htg_coil.remove
            end
          end
        end
      end
    end
    # Zone equipment for applicable thermal zones or non-applicable mz thermal zones needing new equipment
    li_zones_to_remove_equipment = (app_tz + na_mz_thermal_zones)
    li_zones_to_remove_equipment.sort.each do |zone|
      zone.equipment.each do |zone_equipment|
        next if zone_equipment.to_FanZoneExhaust.is_initialized

        zone_equipment.remove unless zone.additionalProperties.hasFeature('non_mechanically_cooled')
      end
    end

    # Loop through heating coils; remove if no longer connected to anything (which will fail simulation)
    model.getCoilHeatingWaters.each do |coil|
      zones_served = []
      airloops_served = []
      if coil.airLoopHVAC.is_initialized
        air_loop = coil.airLoopHVAC.get
        airloops_served << air_loop
      elsif coil.containingHVACComponent.is_initialized
        containing_comp = coil.containingHVACComponent.get
        if containing_comp.airLoopHVAC.is_initialized
          air_loop = containing_comp.airLoopHVAC.get
          zones_served << air_loop.thermalZones
        end
      elsif coil.containingZoneHVACComponent.is_initialized
        zone_hvac = coil.containingZoneHVACComponent.get
        zones_served << zone_hvac.thermalZone.get if zone_hvac.thermalZone.is_initialized
      end
      # Delete the coil is not connected to anything
      next unless zones_served.empty? && airloops_served.empty?

      # remove
      coil.remove
    end

    # Loop through cooling coils; remove if no longer connected to air loops
    model.getCoilCoolingWaters.each do |coil|
      zones_served = []
      airloops_served = []
      if coil.airLoopHVAC.is_initialized
        air_loop = coil.airLoopHVAC.get
        airloops_served << air_loop
      elsif coil.containingHVACComponent.is_initialized
        containing_comp = coil.containingHVACComponent.get
        if containing_comp.airLoopHVAC.is_initialized
          air_loop = containing_comp.airLoopHVAC.get
          zones_served << air_loop.thermalZones
        end
      elsif coil.containingZoneHVACComponent.is_initialized
        zone_hvac = coil.containingZoneHVACComponent.get
        zones_served << zone_hvac.thermalZone.get if zone_hvac.thermalZone.is_initialized
      end

      # Delete the coil is not connected to anything
      next unless zones_served.empty? && airloops_served.empty?

      # remove
      coil.remove
    end

    # remove plant equipment (for loops that are no longer used)
    model.getPlantLoops.sort.each do |loop|
      # Don't remove service water heating loops
      next if std.plant_loop_swh_loop?(loop)
      # don't remove the plant loop if there are any non applicable airloops that still use plant loop
      next unless na_air_loops.empty?

      # check if there is any equipment still connected to this loop
      has_connected_equipment = false
      loop.components.each do |component|
        next unless component.iddObjectType.valueName.to_s.include?('Coil')

        has_connected_equipment = true
      end
      next unless has_connected_equipment == false

      # remove the plant loop if it is entirely unused
      loop.remove
    end

    ######################################################
    # puts("### add VRF DOAS")
    ######################################################
    applicable_thermalzone_per_floor.each do |_z_coord, thermal_zones|
      std.model_add_hvac_system(model, 'VRF', 'Electricity', nil, 'Electricity', thermal_zones,
                                zone_equipment_ventilation: false)
    end

    std.model_add_hvac_system(model, 'DOAS', 'Electricity', nil, 'Electricity', app_tz,
                              air_loop_heating_type: 'DX',
                              air_loop_cooling_type: 'DX')

    # add PSZ HVAC system to non applicable zones that were on applicable multizone airloops
    # heating fuel is determined earlier in code based on prevelance of gas reheat (hot water or furnace)
    unless na_mz_thermal_zones.empty?
      # add new systems
      runner.registerInfo("Non-applicable thermal zones were found on applicable multizone system being replace with measure. These thermal zones will recieved new seperate RTU system with #{htg_type} heating. The heating fuel type is assumed to be electricity unless natural gas reheat was found on VAV reheat system.")
      std.model_add_hvac_system(model, 'PSZ-AC', nil, htg_type, 'Electricity', na_mz_thermal_zones)
    end

    ######################################################
    # puts("### modify DOAS systems")
    ######################################################
    # get climate full string and classification (i.e. "5A")
    climate_zone = OpenstudioStandards::Weather.model_get_climate_zone(model)
    climate_zone_classification = climate_zone.split('-')[-1]

    # DOAS temperature supply settings - colder cooling discharge air for humid climates
    doas_dat_clg_c, doas_dat_htg_c, doas_type =
      if ['1A', '2A', '3A', '4A', '5A', '6A', '7', '7A', '8', '8A'].include?(climate_zone_classification)
        [12.7778, 19.4444, 'ERV']
      else
        [15.5556, 19.4444, 'HRV']
      end

    # add ERV/HRV and modify DOAS controls
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      # only modify new DOAS systems
      next unless ['doas', 'DOAS', 'Doas'].any? { |word| air_loop_hvac.name.to_s.include?(word) }

      # as a backup, skip non applicable airloops
      next if na_air_loops.member?(air_loop_hvac)

      # set 90% return air fraction to account for losses
      air_loop_hvac.setDesignReturnAirFlowFractionofSupplyAirFlow(0.9)

      # set availability schedule for DOAS
      # get schedule for DOAS and add system
      sch_ruleset = OpenstudioStandards::ThermalZone.thermal_zones_get_occupancy_schedule(air_loop_hvac.thermalZones,
                                                                                          occupied_percentage_threshold: 0.05)
      # set air loop availability controls and night cycle manager, after oa system added
      air_loop_hvac.setAvailabilitySchedule(sch_ruleset)
      air_loop_hvac.setNightCycleControlType('CycleOnAnyZoneFansOnly')

      # create new outdoor air reset setpoint manager
      oar_stpt_manager = OpenStudio::Model::SetpointManagerOutdoorAirReset.new(model)
      oar_stpt_manager.setName("#{air_loop_hvac.name} Outdoor Air Reset Manager")
      oar_stpt_manager.addToNode(air_loop_hvac.supplyOutletNode)
      oar_stpt_manager.setControlVariable('Temperature')
      oar_stpt_manager.setOutdoorHighTemperature(21.1111)
      oar_stpt_manager.setOutdoorLowTemperature(15.5556)
      oar_stpt_manager.setSetpointatOutdoorHighTemperature(doas_dat_clg_c)
      oar_stpt_manager.setSetpointatOutdoorLowTemperature(doas_dat_htg_c)

      # loop through thermal zones to set DOAS cooling temp
      # add electric backup coil to VRF zone terminal units
      air_loop_hvac.thermalZones.each do |thermal_zone|
        thermal_zone_sizing = thermal_zone.sizingZone
        thermal_zone_sizing.setDedicatedOutdoorAirLowSetpointTemperatureforDesign(doas_dat_clg_c)
        thermal_zone_sizing.setDedicatedOutdoorAirHighSetpointTemperatureforDesign(doas_dat_htg_c)
        # find vrf terminal units
        thermal_zone.equipment.each do |equip|
          next unless equip.to_ZoneHVACTerminalUnitVariableRefrigerantFlow.is_initialized

          vrf_terminal = equip.to_ZoneHVACTerminalUnitVariableRefrigerantFlow.get
          # create new electric heating coil
          htg_coil = OpenStudio::Model::CoilHeatingElectric.new(model)
          htg_coil.setName("#{vrf_terminal.name} Supplemental Electric Htg Coil")
          vrf_terminal.setSupplementalHeatingCoil(htg_coil)
          htg_coil.setEfficiency(1)
          htg_coil.autosizeNominalCapacity
          thermal_zone.setCoolingPriority(vrf_terminal.to_ModelObject.get, 1)
          thermal_zone.setHeatingPriority(vrf_terminal.to_ModelObject.get, 1)
        end
      end

      # align sizing system with DOAS cooling temp
      air_loop_hvac.sizingSystem.setCentralCoolingDesignSupplyAirTemperature(doas_dat_clg_c)
      air_loop_hvac.sizingSystem.setCentralHeatingDesignSupplyAirTemperature(doas_dat_htg_c)

      # remove any existing ERV
      air_loop_hvac.supplyComponents.each do |component|
        next unless component.to_HeatExchangerAirToAirSensibleAndLatent.is_initialized

        component.remove
      end

      # remove electric heat pump coil so only electric resistance heating coil remains
      # this is needed since constructor method does not have electric resistance heating only
      air_loop_hvac.supplyComponents.each do |component|
        next unless component.to_CoilHeatingDXSingleSpeed.is_initialized

        component.remove
      end

      # add ERV/HRV
      std.air_loop_hvac_apply_energy_recovery_ventilator(air_loop_hvac, climate_zone)
      # get ERV object
      erv = air_loop_hvac.oaComponents.find do |component|
        component_name = component.name.to_s
        component_name.include?('ERV') && !component_name.include?('Node')
      end
      runner.registerError("ERV not found for airloop #{air_loop_hvac.name}") if erv.nil?
      erv = erv.to_HeatExchangerAirToAirSensibleAndLatent.get
      # set defrost and other settings
      erv.setSupplyAirOutletTemperatureControl(true)
      erv.setFrostControlType('MinimumExhaustTemperature')
      erv.setThresholdTemperature(1.66667) # 35F, from E+ recommendation
      erv.setHeatExchangerType('Rotary') # rotary is used for fan power modulation when bypass is active. Only affects supply temp control with bypass.
      # apply wheel power to account for added static pressure due to ERV/HRV
      std.heat_exchanger_air_to_air_sensible_and_latent_apply_prototype_nominal_electric_power(erv)

      # Get the OA system
      oa_system = nil
      if air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized
        oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      else
        OpenStudio.logFree(OpenStudio::Info, 'openstudio.standards.AirLoopHVAC',
                           "For #{air_loop_hvac.name}, ERV not found.")
        return false
      end
      # Add a setpoint manager OA pretreat to control the ERV
      spm_oa_pretreat = OpenStudio::Model::SetpointManagerOutdoorAirPretreat.new(air_loop_hvac.model)
      spm_oa_pretreat.setMinimumSetpointTemperature(-99.0)
      spm_oa_pretreat.setMaximumSetpointTemperature(99.0)
      spm_oa_pretreat.setMinimumSetpointHumidityRatio(0.00001)
      spm_oa_pretreat.setMaximumSetpointHumidityRatio(1.0)
      # Reference setpoint node and mixed air stream node are outlet node of the OA system
      mixed_air_node = oa_system.mixedAirModelObject.get.to_Node.get
      spm_oa_pretreat.setReferenceSetpointNode(mixed_air_node)
      spm_oa_pretreat.setMixedAirStreamNode(mixed_air_node)
      # Outdoor air node is the outboard OA node of the OA system
      spm_oa_pretreat.setOutdoorAirStreamNode(oa_system.outboardOANode.get)
      # Return air node is the inlet node of the OA system
      return_air_node = oa_system.returnAirModelObject.get.to_Node.get
      spm_oa_pretreat.setReturnAirStreamNode(return_air_node)
      # Attach to the outlet of the ERV
      erv_outlet = erv.primaryAirOutletModelObject.get.to_Node.get
      spm_oa_pretreat.addToNode(erv_outlet)

      # set parameters for ERV
      if doas_type == 'ERV'
        # set efficiencies; assumed 90% airflow returned to unit
        erv.setSensibleEffectivenessat100HeatingAirFlow(0.75)
        erv.setSensibleEffectivenessat75HeatingAirFlow(0.78)
        erv.setLatentEffectivenessat100HeatingAirFlow(0.61)
        erv.setLatentEffectivenessat75HeatingAirFlow(0.68)
        erv.setSensibleEffectivenessat100CoolingAirFlow(0.75)
        erv.setSensibleEffectivenessat75CoolingAirFlow(0.78)
        erv.setLatentEffectivenessat100CoolingAirFlow(0.55)
        erv.setLatentEffectivenessat75CoolingAirFlow(0.60)
      # set parameters for HRV
      elsif doas_type == 'HRV'
        # set efficiencies; assumed 90% airflow returned to unit
        erv.setSensibleEffectivenessat100HeatingAirFlow(0.84)
        erv.setSensibleEffectivenessat75HeatingAirFlow(0.86)
        erv.setLatentEffectivenessat100HeatingAirFlow(0)
        erv.setLatentEffectivenessat75HeatingAirFlow(0)
        erv.setSensibleEffectivenessat100CoolingAirFlow(0.83)
        erv.setSensibleEffectivenessat75CoolingAirFlow(0.84)
        erv.setLatentEffectivenessat100CoolingAirFlow(0)
        erv.setLatentEffectivenessat75CoolingAirFlow(0)
      end
    end

    ######################################################
    # puts("### override VRF outdoor unit performance/configuration with customized data")
    ######################################################
    map_performance_data = {}
    vrf_outdoor_unit_name = 'DAIKINREYQ 72' # hard-coded
    model.getAirConditionerVariableRefrigerantFlows.each_with_index do |vrf_outdoor_unit, i|
      # ----------------------------------------------------
      # puts("&&& reconfigure specifications of outdoor unit based on customized data for #{vrf_outdoor_unit.name}")
      # ----------------------------------------------------
      if i == 0
        file_name = 'DAIKIN-REYQ 72 '

        # load data in osc format
        path_data = "#{File.dirname(__FILE__)}/resources/vrf performance curves/outdoor unit/Daikin-REYQ72T/files/#{file_name}.osc"
        new_object_path = OpenStudio::Path.new(path_data)
        new_object_file = OpenStudio::IdfFile.load(new_object_path)
        # puts("--- performance maps part 1: loading data source: #{path_data}")

        # get objects from osc
        if new_object_file.empty?
          runner.registerError("Unable to find the file #{file_name}.osc")
          return false
        else
          new_object_file = new_object_file.get
        end

        # translate osc to idf
        # puts("--- performance maps part 1: translating original data source (in osc) to idf")
        vt = OpenStudio::OSVersion::VersionTranslator.new
        component_objects = vt.loadComponent(OpenStudio::Path.new(new_object_path))

        # add individual idf object (related to curve) to model
        if component_objects.empty?
          runner.registerError("Cannot load new_object component '#{new_object_file}'")
          return false
        else
          objects = component_objects.get.modelObjects
          objects.each do |obj|
            objec_type = obj.iddObjectType.to_s
            unless (objec_type.include? 'OS_Curve') || (objec_type.include? 'OS_Table') || (objec_type.include? 'OS_AirConditioner_VariableRefrigerantFlow')
              next
            end

            # puts("--- performance maps part 1: adding individual idf object to model: #{obj.name} | #{objec_type}")
            component_object = obj.createComponent
            model.insertComponent(component_object)
          end
        end

        # extracting performance map from dummy vrf object
        # puts("--- performance maps part 1: extracting performance maps from the dummy object")
        map_performance_data = extract_curves_from_dummy_acvrf_object(model, vrf_outdoor_unit_name)

        # load data
        path_data_curve = "#{File.dirname(__FILE__)}/resources/performance_maps_Daikin_RELQ_100CR_120MBH.json"
        standards_data_curve = JSON.parse(File.read(path_data_curve))
        # puts("--- performance maps part 2: loading locally saved standards data: #{path_data_curve}")

        # load curves: cooling
        # puts("--- performance maps part 2: loading curves for cooling: single curve approach selected")
        map_performance_data['curve_low_ccapft'] =
          model_add_curve(model, 'CCAPFT_Daikin_RELQ_100CR_120MBH', standards_data_curve, std)
        map_performance_data['curve_low_ceirft'] =
          model_add_curve(model, 'CEIRFT_Daikin_RELQ_100CR_120MBH', standards_data_curve, std)
        map_performance_data['curve_ccapft_boundary'] = nil
        map_performance_data['curve_high_ccapft'] = nil
        map_performance_data['curve_ceirft_boundary'] = nil
        map_performance_data['curve_high_ceirft'] = nil
        map_performance_data['curve_high_ceirfplr'] = nil

        # load curves: heating
        # puts("--- performance maps part 2: loading curves for heating: single curve approach selected")
        map_performance_data['curve_low_hcapft'] =
          model_add_curve(model, 'HCAPFT_Daikin_RELQ_100CR_120MBH', standards_data_curve, std)
        map_performance_data['curve_low_heirft'] =
          model_add_curve(model, 'HEIRFT_Daikin_RELQ_100CR_120MBH', standards_data_curve, std)
        map_performance_data['curve_hcapft_boundary'] = nil
        map_performance_data['curve_high_hcapft'] = nil
        map_performance_data['curve_heirft_boundary'] = nil
        map_performance_data['curve_high_heirft'] = nil
        map_performance_data['curve_high_heirfplr'] = nil
      end

      # ----------------------------------------------------
      # puts("&&& configure additional/missed parameters")
      # ----------------------------------------------------
      vrf_outdoor_unit.setMinimumOutdoorTemperatureinHeatingMode(-30.0)
      vrf_outdoor_unit.setHeatPumpWasteHeatRecovery(true)
      vrf_outdoor_unit.setMasterThermostatPriorityControlType('LoadPriority')
      first_indoor_unit = vrf_outdoor_unit.terminals[0]
      zonehvaccomp = first_indoor_unit.to_ZoneHVACComponent.get # assuming all indoor units are on the same floor
      first_thermalzone = zonehvaccomp.thermalZone.get
      first_space = first_thermalzone.spaces[0]
      story = first_space.buildingStory.get
      z_coord = story.nominalZCoordinate.get
      thermal_zones = applicable_thermalzone_per_floor[z_coord]
      max_equiv_distance, max_net_vert_distance = get_max_vrf_pipe_lengths(model, thermal_zones)
      vrf_outdoor_unit.setEquivalentPipingLengthusedforPipingCorrectionFactorinCoolingMode(max_equiv_distance)
      vrf_outdoor_unit.setEquivalentPipingLengthusedforPipingCorrectionFactorinHeatingMode(max_equiv_distance)
      vrf_outdoor_unit.setVerticalHeightusedforPipingCorrectionFactor(max_net_vert_distance)
      # puts("--- additional outdoor unit configuration: outdoor unit serves the floor with z-coordinate of #{z_coord} m")
      # puts("--- additional outdoor unit configuration: max_equiv_distance = #{max_equiv_distance} m")
      # puts("--- additional outdoor unit configuration: max_net_vert_distance = #{max_net_vert_distance} m")

      # ----------------------------------------------------
      # puts("&&& apply performance map to VRF outdoor unit object for #{vrf_outdoor_unit.name}")
      # ----------------------------------------------------
      apply_vrf_performance_data(
        vrf_outdoor_unit,
        map_performance_data,
        vrf_defrost_strategy,
        disable_defrost
      )
    end

    ######################################################
    # puts("### clean dummy VRF outdoor unit object")
    ######################################################
    model.getAirConditionerVariableRefrigerantFlows.each do |obj|
      if obj.name.to_s == vrf_outdoor_unit_name
        # puts("&&& deleting dummy VRF object: #{obj.name}")
        obj.remove
      end
    end

    ######################################################
    # puts("### overriding other curves")
    ######################################################
    # modifying cooling EIR modifier curve (function of part-load ratio)")
    # curve derived from comparing PLR performance between Daikin data, Mitsubishi data, and Daikin spec sheet
    model.getAirConditionerVariableRefrigerantFlows.each do |obj|
      # puts("&&& overriding other curves: outdoor unit name = #{obj.name}")
      next unless obj.coolingEnergyInputRatioModifierFunctionofLowPartLoadRatioCurve.is_initialized

      curve = obj.coolingEnergyInputRatioModifierFunctionofLowPartLoadRatioCurve.get
      # puts("&&& overriding other curves: curve.name = #{curve.name}")
      if curve.to_CurveCubic.is_initialized
        cubic = curve.to_CurveCubic.get
        # puts("&&& overriding other curves: cubic (before) = #{cubic}")
        cubic.setCoefficient1Constant(0.431522)
        cubic.setCoefficient2x(-2.159775)
        cubic.setCoefficient3xPOW2(6.030002)
        cubic.setCoefficient4xPOW3(-3.301749)
        cubic.setMinimumValueofx(0.25)
        cubic.setMaximumValueofx(1.0)
        cubic.setMinimumCurveOutput(0.272542771)
        cubic.setMaximumCurveOutput(1.0)
        # puts("&&& overriding other curves: cubic (after) = #{cubic}")
      else
        runner.registerWarning('cooling EIR modifier (function of PLR) not overriden with Daikin Aurora data because the base curve is not a cubic curve.')
      end
    end

    ######################################################
    # puts("### regular sizing")
    ######################################################
    # run sizing
    std.model_apply_prm_sizing_parameters(model)
    if std.model_run_sizing_run(model, "#{Dir.pwd}/SR1") == false
      runner.registerError('Sizing run did not succeed, cannot apply HVAC efficiencies.')
      log_messages_to_runner(runner, true)
      return false
    end

    ######################################################
    # upsizing allowance
    ######################################################
    if upsizing_allowance_pct > 0.0

      # get sql (for extracting sizing information)
      sql = model.sqlFile
      if sql.empty?
        runner.registerError('Cannot find last sql file.')
        return false
      end
      sql = sql.get if sql.is_initialized

      # loop through each outdoor unit
      model.getAirConditionerVariableRefrigerantFlows.each do |ou|
        # puts("### ####################################")
        # puts("### OU name = #{ou.name}")
        capacity_outdoor_unit_new = 0
        ou.terminals.each do |iu|
          # get coil from indoor unit
          coil_cooling = iu.coolingCoil.get
          coil_heating = iu.heatingCoil.get
          if coil_cooling.to_CoilCoolingDXVariableRefrigerantFlow.is_initialized
            coil_cooling = coil_cooling.to_CoilCoolingDXVariableRefrigerantFlow.get
          else
            runner.registerError('cannot get CoilCoolingDXVariableRefrigerantFlow object')
          end
          if coil_heating.to_CoilHeatingDXVariableRefrigerantFlow.is_initialized
            coil_heating = coil_heating.to_CoilHeatingDXVariableRefrigerantFlow.get
          else
            runner.registerError('cannot get CoilHeatingDXVariableRefrigerantFlow object')
          end
          # puts("--- ------------------------------------")
          # puts("--- IU cooling coil name = #{coil_cooling.name}")
          row_name_cooling = coil_cooling.name.to_s.upcase
          row_name_heating = coil_heating.name.to_s.upcase

          # get design_cooling_load
          column_name = 'Zone Sensible Heat Gain at Ideal Loads Peak'
          design_cooling_load = get_tabular_data(model, sql, 'CoilSizingDetails', 'Entire Facility', 'Coils',
                                                 row_name_cooling, column_name).to_f
          # puts("--- #{coil_cooling.name} | design_cooling_load = #{design_cooling_load} W")

          # get design cooling temperature
          column_name = 'Outdoor Air Drybulb at Ideal Loads Peak'
          design_cooling_temp = get_tabular_data(model, sql, 'CoilSizingDetails', 'Entire Facility', 'Coils',
                                                 row_name_cooling, column_name).to_f
          # puts("--- #{coil_cooling.name} | design_cooling_temp = #{design_cooling_temp} C")

          # get design_heating_load
          column_name = 'Zone Sensible Heat Gain at Ideal Loads Peak'
          design_heating_load = get_tabular_data(model, sql, 'CoilSizingDetails', 'Entire Facility', 'Coils',
                                                 row_name_heating, column_name).to_f
          # puts("--- #{coil_cooling.name} | design_heating_load = #{design_heating_load} W")

          # get design heating temperature
          column_name = 'Outdoor Air Drybulb at Ideal Loads Peak'
          design_heating_temp = get_tabular_data(model, sql, 'CoilSizingDetails', 'Entire Facility', 'Coils',
                                                 row_name_heating, column_name).to_f
          # puts("--- #{coil_cooling.name} | design_heating_temp = #{design_heating_temp} C")

          # get capacity_original_rated
          column_name = 'Coil Final Gross Total Capacity'
          capacity_original_rated = get_tabular_data(model, sql, 'CoilSizingDetails', 'Entire Facility', 'Coils',
                                                     row_name_cooling, column_name).to_f
          # puts("--- #{coil_cooling.name} | capacity_original_rated = #{capacity_original_rated} W")

          # get capacity modifier curves
          capacity_modifier_curve_cooling = ou.coolingCapacityRatioModifierFunctionofLowTemperatureCurve.get
          capacity_modifier_curve_heating = ou.heatingCapacityRatioModifierFunctionofLowTemperatureCurve.get
          # puts("--- #{coil_cooling.name} | capacity_modifier_curve_cooling = #{capacity_modifier_curve_cooling.name}")
          # puts("--- #{coil_cooling.name} | capacity_modifier_curve_heating = #{capacity_modifier_curve_heating.name}")

          # get capacity modifier for cooling
          if capacity_modifier_curve_cooling.to_TableMultiVariableLookup.is_initialized
            capacity_modifier_curve_cooling = capacity_modifier_curve_cooling.to_TableMultiVariableLookup.get
            capacity_modifier_cooling = HvacVrfHrDoas.get_dep_var_from_lookup_table_with_two_ind_var(runner,
                                                                                                     capacity_modifier_curve_cooling, OpenStudio.convert(67.0, 'F', 'C').get, design_cooling_temp)
          else
            capacity_modifier_cooling = capacity_modifier_curve_cooling.evaluate(OpenStudio.convert(67.0, 'F', 'C').get,
                                                                                 design_cooling_temp)
          end
          # puts("--- #{coil_cooling.name} | capacity_modifier_cooling = #{capacity_modifier_cooling}")

          # get capacity modifier for heating
          if capacity_modifier_curve_cooling.to_TableMultiVariableLookup.is_initialized
            capacity_modifier_curve_heating = capacity_modifier_curve_heating.to_TableMultiVariableLookup.get
            capacity_modifier_heating = HvacVrfHrDoas.get_dep_var_from_lookup_table_with_two_ind_var(runner,
                                                                                                     capacity_modifier_curve_heating, OpenStudio.convert(70.0, 'F', 'C').get, design_heating_temp)
          else
            capacity_modifier_heating = capacity_modifier_curve_heating.evaluate(OpenStudio.convert(70.0, 'F', 'C').get,
                                                                                 design_heating_temp)
          end
          # puts("--- #{coil_cooling.name} | capacity_modifier_heating = #{capacity_modifier_heating}")

          # get rated capacities based on design loads
          rated_cooling_capacity_based_on_design_load = design_cooling_load / capacity_modifier_cooling
          rated_heating_capacity_based_on_design_load = design_heating_load / capacity_modifier_heating
          # puts("--- #{coil_cooling.name} | rated_cooling_capacity_based_on_design_load = #{rated_cooling_capacity_based_on_design_load} W")
          # puts("--- #{coil_cooling.name} | rated_heating_capacity_based_on_design_load = #{rated_heating_capacity_based_on_design_load} W")

          # skip upsizing if indoor unit is not expected as heating dominant
          if rated_heating_capacity_based_on_design_load <= rated_cooling_capacity_based_on_design_load
            # puts("--- #{coil_cooling.name} | this indoor unit is not expected as heating dominant, so skipping for upsizing.")
            capacity_outdoor_unit_new += capacity_original_rated
            next
          end

          # get design_air_flow_rate_m_3_per_sec
          column_name = 'Coil Air Volume Flow Rate at Ideal Loads Peak'
          design_air_flow_rate_m_3_per_sec = get_tabular_data(model, sql, 'CoilSizingDetails', 'Entire Facility',
                                                              'Coils', row_name_cooling, column_name).to_f
          # puts("--- #{coil_cooling.name} | design_air_flow_rate_m_3_per_sec = #{design_air_flow_rate_m_3_per_sec} m3/s")

          # get fan_heat_gain
          column_name = 'Supply Fan Air Heat Gain at Ideal Loads Peak'
          fan_heat_gain = get_tabular_data(model, sql, 'CoilSizingDetails', 'Entire Facility', 'Coils',
                                           row_name_cooling, column_name).to_f
          # puts("--- #{coil_cooling.name} | fan_heat_gain = #{fan_heat_gain} W")

          # get rated_capacity_modifier
          column_name = 'Coil Off-Rating Capacity Modifier at Ideal Loads Peak'
          rated_capacity_modifier = get_tabular_data(model, sql, 'CoilSizingDetails', 'Entire Facility', 'Coils',
                                                     row_name_cooling, column_name).to_f
          # puts("--- #{coil_cooling.name} | rated_capacity_modifier = #{rated_capacity_modifier}")

          # get capacity_upsized_rated
          capacity_upsized_rated = capacity_original_rated * (1 + (upsizing_allowance_pct / 100.0))
          # puts("--- #{coil_cooling.name} | capacity_upsized_rated = #{capacity_upsized_rated} W")

          # get design capacity from upsized rated capacity
          capacity_upsized_design = capacity_upsized_rated * rated_capacity_modifier
          # puts("--- #{coil_cooling.name} | capacity_upsized_design = #{capacity_upsized_design}")
          capacity_upsized_design_wo_fan_heat_gain = capacity_upsized_design - fan_heat_gain
          # puts("--- #{coil_cooling.name} | capacity_upsized_design_wo_fan_heat_gain = #{capacity_upsized_design_wo_fan_heat_gain}")

          # check design capacity against design heating load
          if capacity_upsized_design_wo_fan_heat_gain > design_heating_load
            capacity_final_design = design_heating_load
            # puts("--- #{coil_cooling.name} | upsized design load (#{capacity_upsized_design_wo_fan_heat_gain.round(0)} W) larger than actual design heating load (#{design_heating_load.round(0)} W)")
          else
            capacity_final_design = capacity_upsized_design_wo_fan_heat_gain
          end
          # puts("--- #{coil_cooling.name} | capacity_final_design = #{capacity_final_design}")

          # get final upsized rated capacity
          capacity_final_rated = capacity_final_design + fan_heat_gain
          capacity_final_rated /= rated_capacity_modifier
          if capacity_final_rated < capacity_original_rated
            # puts("--- #{coil_cooling.name} | recalculation of rated capacity (#{capacity_final_rated.round(0)} W) is less than original rated capacity (#{capacity_original_rated.round(0)} W)")
            capacity_final_rated = capacity_original_rated
          end
          # puts("--- #{coil_cooling.name} | capacity_final_rated = #{capacity_final_rated}")

          # get CFM/ton
          design_air_flow_rate_cfm = design_air_flow_rate_m_3_per_sec * 2118.88
          # puts("--- #{coil_cooling.name} | design_air_flow_rate_cfm = #{design_air_flow_rate_cfm} CFM")
          capacity_upsized_rated_ton = capacity_final_rated * 0.000284345
          # puts("--- #{coil_cooling.name} | capacity_upsized_rated_ton = #{capacity_upsized_rated_ton} ton")
          cfm_per_ton = design_air_flow_rate_cfm / capacity_upsized_rated_ton
          # puts("--- #{coil_cooling.name} | cfm_per_ton = #{cfm_per_ton}")

          # adjust indoor unit flow rate if CFM/ton is out of bound between 300 and 450 CFM/ton
          if cfm_per_ton < 300.0
            # puts("--- #{coil_cooling.name} | CFM/ton minimum limit violated. Adjusting air flow rate to match with minimum limit.")
            new_air_flow_rate_cfm = 300 * capacity_upsized_rated_ton
            # puts("--- #{coil_cooling.name} | indoor unit air flow adjusted match with minimum limit = #{new_air_flow_rate_cfm} CFM")
          elsif cfm_per_ton > 450
            # puts("--- #{coil_cooling.name} | CFM/ton maximum limit violated. Adjusting air flow rate to match with maximum limit.")
            new_air_flow_rate_cfm = 450 * capacity_upsized_rated_ton
            # puts("--- #{coil_cooling.name} | indoor unit air flow adjusted match with maximum limit = #{new_air_flow_rate_cfm} CFM")
          else
            new_air_flow_rate_cfm = design_air_flow_rate_cfm
          end
          new_air_flow_rate_m_3_per_s = new_air_flow_rate_cfm / 2118.88

          # override new specifications: rated air flow rate for cooling coil
          if coil_cooling.ratedAirFlowRate.is_initialized
            # puts("--- #{coil_cooling.name} | indoor unit cooling air flow rate before = #{coil_cooling.ratedAirFlowRate} m3/s")
          elsif coil_cooling.autosizedRatedAirFlowRate.is_initialized
            # puts("--- #{coil_cooling.name} | indoor unit cooling air flow rate before = #{coil_cooling.autosizedRatedAirFlowRate} m3/s")
          else
            runner.registerError('Cannot find rated air flow rate for cooling.')
          end
          coil_cooling.setRatedAirFlowRate(new_air_flow_rate_m_3_per_s)
          # puts("--- #{coil_cooling.name} | indoor unit cooling air flow rate after = #{coil_cooling.ratedAirFlowRate} m3/s")

          # override new specifications: rated air flow rate for heating coil
          if coil_heating.ratedAirFlowRate.is_initialized
            # puts("--- #{coil_heating.name} | indoor unit heating air flow rate before = #{coil_heating.ratedAirFlowRate} m3/s")
          elsif coil_heating.autosizedRatedAirFlowRate.is_initialized
            # puts("--- #{coil_heating.name} | indoor unit heating air flow rate before = #{coil_heating.autosizedRatedAirFlowRate} m3/s")
          else
            runner.registerError('Cannot find rated air flow rate for heating.')
          end
          coil_heating.setRatedAirFlowRate(new_air_flow_rate_m_3_per_s)
          # puts("--- #{coil_heating.name} | indoor unit heating air flow rate after = #{coil_heating.ratedAirFlowRate} m3/s")

          # override new specifications: rated capacity for cooling
          if coil_cooling.ratedTotalCoolingCapacity.is_initialized
            # puts("--- #{coil_cooling.name} | indoor unit cooling capacity before = #{coil_cooling.ratedTotalCoolingCapacity} W")
          elsif coil_cooling.autosizedRatedTotalCoolingCapacity.is_initialized
            # puts("--- #{coil_cooling.name} | indoor unit cooling capacity before = #{coil_cooling.autosizedRatedTotalCoolingCapacity} W")
          else
            runner.registerError('Cannot find rated capacity for cooling.')
          end
          coil_cooling.setRatedTotalCoolingCapacity(capacity_final_rated)
          # puts("--- #{coil_cooling.name} | indoor unit cooling capacity after = #{coil_cooling.ratedTotalCoolingCapacity} W")

          # override new specifications: rated capacity for heating
          if coil_heating.ratedTotalHeatingCapacity.is_initialized
            # puts("--- #{coil_heating.name} | indoor unit heating capacity before = #{coil_heating.ratedTotalHeatingCapacity} W")
          elsif coil_heating.autosizedRatedTotalHeatingCapacity.is_initialized
            # puts("--- #{coil_heating.name} | indoor unit heating capacity before = #{coil_heating.autosizedRatedTotalHeatingCapacity} W")
          else
            runner.registerError('Cannot find rated capacity for heating.')
          end
          coil_heating.setRatedTotalHeatingCapacity(capacity_final_rated)
          # puts("--- #{coil_heating.name} | indoor unit heating capacity after = #{coil_heating.ratedTotalHeatingCapacity} W")

          # add final indoor unit capacity for calculating outdoor unit capacity
          capacity_outdoor_unit_new += capacity_final_rated
        end

        # override outdoor unit capacity
        # puts("### ------------------------------------")
        runner.registerInfo("### #{ou.name} | outdoor unit cooling capacity before = #{ou.autosizedGrossRatedTotalCoolingCapacity} W")
        ou.setGrossRatedTotalCoolingCapacity(capacity_outdoor_unit_new)
        runner.registerInfo("### #{ou.name} | outdoor unit cooling capacity after = #{ou.grossRatedTotalCoolingCapacity} W")
        runner.registerInfo("### #{ou.name} | outdoor unit heating capacity before = #{ou.autosizedGrossRatedHeatingCapacity} W")
        ou.setGrossRatedHeatingCapacity(capacity_outdoor_unit_new)
        runner.registerInfo("### #{ou.name} | outdoor unit heating capacity after = #{ou.grossRatedHeatingCapacity} W")
      end
    else
      runner.registerInfo("upsizing allowance set to #{upsizing_allowance_pct}% so skipping upsizing.")
    end

    ######################################################
    # puts("### Update ERV/HRV wheel power and efficiencies based on sizing run")
    # ventacity system does not have enthalpy wheel
    # but wheel power can be used to model added pressure from HR
    # the added pressure should not be applied when in bypass mode
    # using the wheel to model the added power fro, the HRV/ERV pressure allows it to be bypassed
    ######################################################
    # add ERV/HRV and modify DOAS controls
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      next unless ['doas', 'DOAS', 'Doas'].any? { |word| air_loop_hvac.name.to_s.include?(word) }
      # as a backup, skip non applicable airloops
      next if na_air_loops.member?(air_loop_hvac)

      # get ERV object
      erv = air_loop_hvac.oaComponents.find do |component|
        component_name = component.name.to_s
        component_name.include?('ERV') && !component_name.include?('Node')
      end
      runner.registerError("ERV not found for airloop #{air_loop_hvac.name}") if erv.nil?
      erv = erv.to_HeatExchangerAirToAirSensibleAndLatent.get

      # get design outdoor air flow rate
      # this is used to estimate wheel "fan" power
      # loop through thermal zones
      doas_oa_flow_m3_per_s = 0
      air_loop_hvac.thermalZones.each do |thermal_zone|
        space = thermal_zone.spaces[0]
        # get zone area
        fa = thermal_zone.floorArea * thermal_zone.multiplier
        # get zone volume
        vol = thermal_zone.airVolume * thermal_zone.multiplier
        # get zone design people
        num_people = thermal_zone.numberOfPeople * thermal_zone.multiplier
        next unless space.designSpecificationOutdoorAir.is_initialized

        dsn_spec_oa = space.designSpecificationOutdoorAir.get
        # add floor area component
        oa_area = dsn_spec_oa.outdoorAirFlowperFloorArea
        doas_oa_flow_m3_per_s += oa_area * fa
        # add per person component
        oa_person = dsn_spec_oa.outdoorAirFlowperPerson
        doas_oa_flow_m3_per_s += oa_person * num_people
        # add air change component
        oa_ach = dsn_spec_oa.outdoorAirFlowAirChangesperHour
        doas_oa_flow_m3_per_s += (oa_ach * vol) / 60
      end

      # fan efficiency ranges from 40-60% (Energy Modeling Guide for Very High Efficiency DOAS Final Report)
      default_fan_efficiency = 0.55
      power = (doas_oa_flow_m3_per_s * 174.188 / default_fan_efficiency) + (doas_oa_flow_m3_per_s * 0.9 * 124.42 / default_fan_efficiency)
      erv.setNominalElectricPower(power)
      # set fan and cooling efficiencies with sizing run data
      air_loop_hvac.supplyComponents.each do |component|
        if component.to_CoilCoolingDXSingleSpeed.is_initialized
          doas_clg_coil = component.to_CoilCoolingDXSingleSpeed.get
          std.coil_cooling_dx_single_speed_apply_efficiency_and_curves(doas_clg_coil, {})
        elsif component.to_CoilCoolingDXTwoSpeed.is_initialized
          doas_clg_coil = component.to_CoilCoolingDXTwoSpeed.get
          std.coil_cooling_dx_two_speed_apply_efficiency_and_curves(doas_clg_coil, {})
        elsif component.to_FanOnOff.is_initialized
          doas_sf = component.to_FanOnOff.get
          std.prototype_fan_apply_prototype_fan_efficiency(doas_sf)
        elsif component.to_FanConstantVolume.is_initialized
          doas_sf = component.to_FanConstantVolume.get
          std.prototype_fan_apply_prototype_fan_efficiency(doas_sf)
        end
      end
    end

    #####################################################
    # puts("### update equipment efficiencies for non-applicable thermal zones getting new airloops")
    #####################################################
    model.getAirLoopHVACs.each do |air_loop_hvac|
      # determine applicability based on thermal zone
      # only non-applicable thermal zones that were broken off from multizone systems
      # should be included here
      thermal_zones = air_loop_hvac.thermalZones
      next unless thermal_zones.size == 1

      thermal_zone = thermal_zones[0]
      next unless na_mz_thermal_zones.include?(thermal_zone)

      # puts("air_loop_hvac: #{air_loop_hvac.name}")

      # # set availability schedule for DOAS
      # # get schedule for DOAS and add system
      # sch_ruleset = OpenstudioStandards::ThermalZone.thermal_zones_get_occupancy_schedule(thermal_zones=thermal_zones,
      #                                                       occupied_percentage_threshold:0.05)
      # # set air loop availability controls and night cycle manager, after oa system added
      # air_loop_hvac.setAvailabilitySchedule(sch_ruleset)
      # air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir.setMinimumOutdoorAirSchedule(sch_ruleset)
      # air_loop_hvac.setNightCycleControlType('CycleOnAny')

      # apply efficiencies
      runner.registerInfo("Applying standard efficiencies to new (Non applicable) airloop #{air_loop_hvac.name}")
      std.air_loop_hvac_apply_standard_controls(air_loop_hvac, climate_zone)
      # set fan and cooling efficiencies with sizing run data
      air_loop_hvac.supplyComponents.each do |component|
        if component.to_CoilCoolingDXSingleSpeed.is_initialized
          clg_coil = component.to_CoilCoolingDXSingleSpeed.get
          std.coil_cooling_dx_single_speed_apply_efficiency_and_curves(clg_coil, {})
        elsif component.to_CoilCoolingDXTwoSpeed.is_initialized
          clg_coil = component.to_CoilCoolingDXTwoSpeed.get
          std.coil_cooling_dx_two_speed_apply_efficiency_and_curves(clg_coil, {})
        elsif component.to_FanOnOff.is_initialized
          sf = component.to_FanOnOff.get
          std.prototype_fan_apply_prototype_fan_efficiency(sf)
        elsif component.to_FanConstantVolume.is_initialized
          sf = component.to_FanConstantVolume.get
          std.prototype_fan_apply_prototype_fan_efficiency(sf)
        elsif component.to_AirLoopHVACUnitarySystem.is_initialized
          # unitary systems
          unitary_sys = component.to_AirLoopHVACUnitarySystem.get
          if unitary_sys.coolingCoil.is_initialized
            clg_coil = unitary_sys.coolingCoil.get
            if clg_coil.to_CoilCoolingDXSingleSpeed.is_initialized
              clg_coil = clg_coil.to_CoilCoolingDXSingleSpeed.get
              std.coil_cooling_dx_single_speed_apply_efficiency_and_curves(clg_coil, {})
            elsif clg_coil.to_CoilCoolingDXTwoSpeed.is_initialized
              clg_coil = clg_coil.to_CoilCoolingDXTwoSpeed.get
              std.coil_cooling_dx_two_speed_apply_efficiency_and_curves(clg_coil, {})
            end
          elsif unitary_sys.supplyFan.is_initialized
            sf = unitary_sys.supplyFan.get
            if sf.to_FanOnOff.is_initialized
              sf = sf.to_FanOnOff.get
              std.prototype_fan_apply_prototype_fan_efficiency(sf)
            elsif sf.to_FanConstantVolume.is_initialized
              sf = sf.to_FanConstantVolume.get
              std.prototype_fan_apply_prototype_fan_efficiency(sf)
            end
          end
        end
      end
    end

    ######################################################
    # puts("### update COPs based on capacity sizing results")
    ######################################################
    total_cooling_capacity_w = 0
    total_heating_capacity_w = 0
    counts_vrf = model.getAirConditionerVariableRefrigerantFlows.size
    model.getAirConditionerVariableRefrigerantFlows.each do |vrf_outdoor_unit|
      # update cooling COP based on sized cooling capacity
      if vrf_outdoor_unit.ratedTotalCoolingCapacity.is_initialized
        cooling_capacity_w = vrf_outdoor_unit.ratedTotalCoolingCapacity.get
        total_cooling_capacity_w += vrf_outdoor_unit.ratedTotalCoolingCapacity.get
      elsif vrf_outdoor_unit.autosizedRatedTotalCoolingCapacity.is_initialized
        cooling_capacity_w = vrf_outdoor_unit.autosizedRatedTotalCoolingCapacity.get
        total_cooling_capacity_w += vrf_outdoor_unit.autosizedRatedTotalCoolingCapacity.get
      else
        runner.registerWarning("For #{vrf_outdoor_unit.name} capacity is not available, total cooling capacity of vrf system will be incorrect when applying standard.")
      end
      cop_cooling = ((-0.000022 * cooling_capacity_w.to_f) + 5.520555).round(3)
      cop_cooling = cop_cooling.clamp(3.974, 5.197)
      vrf_outdoor_unit.setGrossRatedCoolingCOP(cop_cooling)
      # puts("&&& VRF outdoor unit (#{vrf_outdoor_unit.name}): COP for cooling updated to #{cop_cooling} based on sized cooling capacity of #{cooling_capacity_w.round(0)}")

      # update heating COP based on sized heating capacity
      if vrf_outdoor_unit.ratedTotalHeatingCapacity.is_initialized
        heating_capacity_w = vrf_outdoor_unit.ratedTotalHeatingCapacity.get
        total_heating_capacity_w += vrf_outdoor_unit.ratedTotalHeatingCapacity.get
      elsif vrf_outdoor_unit.autosizedRatedTotalHeatingCapacity.is_initialized
        heating_capacity_w = vrf_outdoor_unit.autosizedRatedTotalHeatingCapacity.get
        total_heating_capacity_w += vrf_outdoor_unit.autosizedRatedTotalHeatingCapacity.get
      else
        runner.registerWarning("For #{vrf_outdoor_unit.name} capacity is not available, total heating capacity of vrf system will be incorrect when applying standard.")
      end
      cop_heating = ((-0.000009 * heating_capacity_w.to_f) + 4.829407).round(3)
      cop_heating = cop_heating.clamp(4.079, 4.655)
      vrf_outdoor_unit.setRatedHeatingCOP(cop_heating)
      # puts("&&& VRF outdoor unit (#{vrf_outdoor_unit.name}): COP for heating updated to #{cop_heating} based on sized heating capacity of #{heating_capacity_w.round(0)}")
    end

    ######################################################
    # puts("### report final condition of model")
    ######################################################
    total_cooling_capacity_btuh = OpenStudio.convert(total_cooling_capacity_w, 'W', 'Btu/hr').get
    total_cooling_capacity_tons = total_cooling_capacity_btuh / 12_000
    total_heating_capacity_btuh = OpenStudio.convert(total_heating_capacity_w, 'W', 'Btu/hr').get
    total_heating_capacity_mbh = total_heating_capacity_btuh / 1_000
    runner.registerFinalCondition("Added #{counts_vrf} VRF outdoor units to model serving #{app_tz.size} zones with #{total_cooling_capacity_tons.round(1)} tons of total cooling capacity and #{total_heating_capacity_mbh.round(1)} MBH of total heating capacity.")

    true
  end
end

# register the measure to be used by the application
HvacVrfHrDoas.new.registerWithApplication
