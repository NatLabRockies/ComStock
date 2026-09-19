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

# start the measure
class UpgradeHvacPump < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    return 'upgrade_hvac_pump'
  end

  # human readable description
  def description
    return 'This measure evaluates the replacement of pumps with variable speed'\
           ' high-efficiency pumps in existing water-based systems for space heating and'\
           ' cooling, excluding domestic water heating. High-efficiency pumps considered'\
           ' in the measure refer to top-tier products currently available in the U.S.'\
           ' market as of July 2025. The nominal efficiencies of pump motors range from'\
           ' 91% to 96%, depending on the motor’s horsepower, compared to ComStock pumps,'\
           ' which typically range from 70% to 96%.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'Constant-speed pumps in existing buildings are replaced with variable-speed'\
           ' pumps featuring advanced part-load performance enabled by modern control strategies.'\
           ' Older variable-speed pumps are upgraded to newer models with advanced part-load'\
           ' efficiency through modern control technologies, such as dynamic static pressure'\
           ' reset. Applicable to pumps used for space heating and cooling: chiller system,'\
           ' boiler system, and district heating and cooling system.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # add outdoor air temperature reset for chilled water supply temperature
    chw_hw_oat_reset = OpenStudio::Measure::OSArgument.makeBoolArgument('chw_hw_oat_reset', true)
    chw_hw_oat_reset.setDisplayName('Add outdoor air temperature reset' \
    ' for chilled/hot water supply temperature?')
    chw_hw_oat_reset.setDefaultValue(false)
    args << chw_hw_oat_reset

    # add outdoor air temperature reset for condenser water temperature
    cw_oat_reset = OpenStudio::Measure::OSArgument.makeBoolArgument('cw_oat_reset', true)
    cw_oat_reset.setDisplayName('Add outdoor air temperature reset' \
    ' for condenser water temperature?')
    cw_oat_reset.setDefaultValue(false)
    args << cw_oat_reset

    # print out details?
    debug_verbose = OpenStudio::Measure::OSArgument.makeBoolArgument('debug_verbose', true)
    debug_verbose.setDisplayName('Print out detailed debugging logs' \
    ' if this parameter is true')
    debug_verbose.setDefaultValue(false)
    args << debug_verbose

    return args
  end

  # get pump specifications
  def self.pump_specifications(applicable_pumps, pumps, std)
    # initialize variables
    pump_motor_eff_weighted_sum = 0.0
    pump_motor_bhp_weighted_sum = 0.0
    pump_rated_flow_total = 0.0
    pump_var_part_load_curve_coeff1_weighted_sum = 0.0
    pump_var_part_load_curve_coeff2_weighted_sum = 0.0
    pump_var_part_load_curve_coeff3_weighted_sum = 0.0
    pump_var_part_load_curve_coeff4_weighted_sum = 0.0

    # get pump specs
    pumps.each do |pump|
      # check if this pump is used on chiller systems
      chw_cw_hw_pump = false
      plant_loop = pump.plantLoop.get
      plant_loop.supplyComponents.each do |sc|
        if sc.to_ChillerElectricEIR.is_initialized ||
           sc.to_BoilerHotWater.is_initialized ||
           sc.to_CoolingTowerSingleSpeed.is_initialized ||
           sc.to_CoolingTowerTwoSpeed.is_initialized ||
           sc.to_CoolingTowerVariableSpeed.is_initialized ||
           sc.to_DistrictCooling.is_initialized ||
           sc.to_DistrictHeating.is_initialized ||
           sc.to_PlantComponentTemperatureSource.is_initialized
          chw_cw_hw_pump = true
        end
      end

      next if chw_cw_hw_pump == false

      # add pump to applicable pump list
      applicable_pumps << pump

      # get rated flow
      rated_flow_m_3_per_s = 0
      if pump.ratedFlowRate.is_initialized
        rated_flow_m_3_per_s = pump.ratedFlowRate.get
      elsif pump.autosizedRatedFlowRate.is_initialized
        rated_flow_m_3_per_s = pump.autosizedRatedFlowRate.get
      else
        rated_flow_m_3_per_s = 0.0
      end

      # pump motor efficiency
      pump_motor_eff = pump.motorEfficiency

      # pump motor BHP
      pump_motor_bhp = std.pump_brake_horsepower(pump)

      # get partload curve coefficients from variable speed pump
      if pump.to_PumpVariableSpeed.is_initialized
        pump_var_part_load_curve_coeff1_weighted_sum +=
          pump.coefficient1ofthePartLoadPerformanceCurve * rated_flow_m_3_per_s
        pump_var_part_load_curve_coeff2_weighted_sum +=
          pump.coefficient2ofthePartLoadPerformanceCurve * rated_flow_m_3_per_s
        pump_var_part_load_curve_coeff3_weighted_sum +=
          pump.coefficient3ofthePartLoadPerformanceCurve * rated_flow_m_3_per_s
        pump_var_part_load_curve_coeff4_weighted_sum +=
          pump.coefficient4ofthePartLoadPerformanceCurve * rated_flow_m_3_per_s
      end

      # calc weighted sums
      pump_rated_flow_total += rated_flow_m_3_per_s
      pump_motor_eff_weighted_sum += pump_motor_eff * rated_flow_m_3_per_s
      pump_motor_bhp_weighted_sum += pump_motor_bhp * rated_flow_m_3_per_s
    end

    # calc weghted averages
    pump_motor_eff_weighted_average =
      if pump_rated_flow_total > 0.0
        pump_motor_eff_weighted_sum / pump_rated_flow_total
      else
        0.0
      end
    pump_motor_bhp_weighted_average =
      if pump_rated_flow_total > 0.0
        pump_motor_bhp_weighted_sum / pump_rated_flow_total
      else
        0.0
      end
    pump_var_part_load_curve_coeff1_weighted_avg =
      if pump_rated_flow_total > 0.0
        pump_var_part_load_curve_coeff1_weighted_sum / pump_rated_flow_total
      else
        0.0
      end
    pump_var_part_load_curve_coeff2_weighted_avg =
      if pump_rated_flow_total > 0.0
        pump_var_part_load_curve_coeff2_weighted_sum / pump_rated_flow_total
      else
        0.0
      end
    pump_var_part_load_curve_coeff3_weighted_avg =
      if pump_rated_flow_total > 0.0
        pump_var_part_load_curve_coeff3_weighted_sum / pump_rated_flow_total
      else
        0.0
      end
    pump_var_part_load_curve_coeff4_weighted_avg =
      if pump_rated_flow_total > 0.0
        pump_var_part_load_curve_coeff4_weighted_sum / pump_rated_flow_total
      else
        0.0
      end

    [
      applicable_pumps,
      pump_rated_flow_total,
      pump_motor_eff_weighted_average,
      pump_motor_bhp_weighted_average,
      pump_var_part_load_curve_coeff1_weighted_avg,
      pump_var_part_load_curve_coeff2_weighted_avg,
      pump_var_part_load_curve_coeff3_weighted_avg,
      pump_var_part_load_curve_coeff4_weighted_avg
    ]
  end

  # get motor efficiency from nominal power
  def self.estimate_motor_efficiency_pcnt(nominal_power_w)
    nominal_power_kw = nominal_power_w / 1000.0

    # Regression parameters from Python popt_fixed
    a = 1.64644705
    b = 92.25875553
    c = 50.22494607
    d = 0.00061996

    # Fixed breakpoint
    x0 = 5.0

    # Efficiency bounds (%)
    eff_min = 90.53
    eff_max = 95.95

    if nominal_power_kw <= 0
      raise ArgumentError, 'Nominal power must be greater than 0'
    end

    if nominal_power_kw < x0
      motor_efficiency_pcnt = (a * Math.log(nominal_power_kw)) + b
    else
      # Compute e to ensure continuity at x0
      left_val = (a * Math.log(x0)) + b
      right_val = c * (1 - Math.exp(-d * x0))
      e = left_val - right_val

      motor_efficiency_pcnt = (c * (1 - Math.exp(-d * nominal_power_kw))) + e
    end

    # Clip output to [90.53%, 95.95%]
    motor_efficiency_pcnt.clamp(eff_min, eff_max)
  end

  # get part-load fraction of full load power curve
  def self.curve_fraction_of_full_load_power(model)
    # Define coefficients for the cubic curve
    coeff_a = 0.0
    coeff_b = 0.0
    coeff_c = 0.1055
    coeff_d = 0.8945
    # Define a cubic curve with example coefficients
    curve = OpenStudio::Model::CurveCubic.new(model)
    curve.setName('Fraction of Full Load Power Curve')
    curve.setCoefficient1Constant(coeff_a) # y-intercept
    curve.setCoefficient2x(coeff_b) # linear term
    curve.setCoefficient3xPOW2(coeff_c) # quadratic term
    curve.setCoefficient4xPOW3(coeff_d) # cubic term
    curve.setMinimumValueofx(0.0)
    curve.setMaximumValueofx(1.0)
    curve.setMinimumCurveOutput(0.0)
    curve.setMaximumCurveOutput(1.0)
    return curve, coeff_a, coeff_b, coeff_c, coeff_d
  end

  # iteratively compute the design motor power based on flow, head, and pump efficiency.
  def self.compute_design_motor_power(flow_m3_per_s, head_pa, eta_pump = 0.75, tolerance = 0.001,
                                      max_iter = 50)
    raise ArgumentError, 'Flow must be > 0' if flow_m3_per_s <= 0
    raise ArgumentError, 'Head must be > 0' if head_pa <= 0

    # Initial guess: motor efficiency = 0.92 (92%)
    motor_eff = 0.92
    iter = 0
    p_design_w = nil

    loop do
      # Compute P_design based on current motor efficiency
      p_design_w = (flow_m3_per_s * head_pa) / (eta_pump * motor_eff)

      # Estimate motor efficiency from power
      motor_eff_pcnt = estimate_motor_efficiency_pcnt(p_design_w)
      new_motor_eff = motor_eff_pcnt / 100.0

      # Check for convergence
      break if (motor_eff - new_motor_eff).abs < tolerance

      motor_eff = new_motor_eff

      iter += 1
      break if iter >= max_iter
    end

    return p_design_w
  end

  # get control specifications
  def self.control_specifications(model)
    # initialize variables
    total_count_spm_chw_hw = 0.0
    total_count_spm_cw = 0.0
    fraction_chw_hw_oat_reset_enabled_sum = 0.0
    fraction_cw_oat_reset_enabled_sum = 0.0

    # get plant loops
    plant_loops = model.getPlantLoops

    # get pump specs
    plant_loops.each do |plant_loop|
      # get loop type
      sizing_plant = plant_loop.sizingPlant
      loop_type = sizing_plant.loopType

      # get setpoint managers
      spms = plant_loop.supplyOutletNode.setpointManagers

      case loop_type
      when 'Cooling'
        # get control specifications
        spms.each do |spm|
          total_count_spm_chw_hw += 1
          if spm.to_SetpointManagerOutdoorAirReset.is_initialized
            fraction_chw_hw_oat_reset_enabled_sum += 1
          end
        end
      when 'Condenser'
        # get control specifications
        spms.each do |spm|
          total_count_spm_cw += 1
          if spm.to_SetpointManagerFollowOutdoorAirTemperature.is_initialized
            fraction_cw_oat_reset_enabled_sum += 1
          end
        end
      when 'Heating'
        # get control specifications
        spms.each do |spm|
          total_count_spm_chw_hw += 1
          if spm.to_SetpointManagerOutdoorAirReset.is_initialized
            fraction_chw_hw_oat_reset_enabled_sum += 1
          end
        end
      end
    end

    # calculate fractions
    fraction_chw_hw_oat_reset_enabled = if total_count_spm_chw_hw > 0.0
                                          fraction_chw_hw_oat_reset_enabled_sum / total_count_spm_chw_hw
                                        else
                                          0.0
                                        end
    fraction_cw_oat_reset_enabled = if total_count_spm_cw > 0.0
                                      fraction_cw_oat_reset_enabled_sum / total_count_spm_cw
                                    else
                                      0.0
                                    end

    [fraction_chw_hw_oat_reset_enabled, fraction_cw_oat_reset_enabled]
  end

  # Applies the condenser water temperatures to the plant loop based on Appendix G.
  #
  # hard-coding this because of https://github.com/NREL/openstudio-standards/issues/1915
  # @param plant_loop [OpenStudio::Model::PlantLoop] plant loop
  # @return [Boolean] returns true if successful, false if not
  # rubocop:disable Naming/PredicateMethod
  def plant_loop_apply_prm_baseline_condenser_water_temperatures(runner, plant_loop)
    sizing_plant = plant_loop.sizingPlant
    loop_type = sizing_plant.loopType
    return true unless loop_type == 'Condenser'

    # Much of the thought in this section came from @jmarrec

    # Determine the design OATwb from the design days.
    # Per https://unmethours.com/question/16698/which-cooling-design-day-is-most-common-for-sizing-rooftop-units/
    # the WB=>MDB day is used to size cooling towers.
    summer_oat_wbs_f = []
    plant_loop.model.getDesignDays.sort.each do |dd|
      next unless dd.dayType == 'SummerDesignDay'
      next unless dd.name.get.to_s.include?('WB=>MDB')

      if plant_loop.model.version < OpenStudio::VersionString.new('3.3.0')
        if dd.humidityIndicatingType == 'Wetbulb'
          summer_oat_wb_c = dd.humidityIndicatingConditionsAtMaximumDryBulb
          summer_oat_wbs_f << OpenStudio.convert(summer_oat_wb_c, 'C', 'F').get
        else
          runner.registerInfo("For #{
            dd.name
          }, humidity is specified as #{
              dd.humidityIndicatingType
            }; cannot determine Twb.")
        end
      elsif dd.humidityConditionType == 'Wetbulb' &&
            dd.wetBulbOrDewPointAtMaximumDryBulb.is_initialized
        summer_oat_wbs_f << OpenStudio.convert(dd.wetBulbOrDewPointAtMaximumDryBulb.get, 'C',
                                               'F').get
      else
        runner.registerInfo("For #{
          dd.name
        }, humidity is specified as #{
            dd.humidityConditionType
          }; cannot determine Twb.")
      end
    end

    # Use the value from the design days or 78F, the CTI rating condition,
    # if no design day information is available.
    design_oat_wb_f = nil
    if summer_oat_wbs_f.empty?
      design_oat_wb_f = 78
      runner.registerInfo("For #{plant_loop.name}, no design day OATwb conditions "\
                          'were found. CTI rating condition of 78F OATwb' \
                          ' will be used for sizing cooling towers.')
    else
      # Take worst case condition
      design_oat_wb_f = summer_oat_wbs_f.max
      runner.registerInfo('The maximum design wet bulb temperature from the '\
                          "Summer Design Day WB=>MDB is #{design_oat_wb_f} F")
    end

    # There is an EnergyPlus model limitation that the design_oat_wb_f < 80F for cooling towers
    ep_max_design_oat_wb_f = 80
    if design_oat_wb_f > ep_max_design_oat_wb_f
      runner.registerInfo("For #{plant_loop.name}, reduced design OATwb from #{
        design_oat_wb_f.round(1)
      } F to E+ model max input of #{
          ep_max_design_oat_wb_f
        } F.")
      design_oat_wb_f = ep_max_design_oat_wb_f
    end

    # Determine the design CW temperature, approach, and range
    design_oat_wb_c = OpenStudio.convert(design_oat_wb_f, 'F', 'C').get
    leaving_cw_t_c, approach_k, range_k = plant_loop_prm_baseline_condenser_water_temperatures(
      runner,
      plant_loop,
      design_oat_wb_c
    )

    # Convert to IP units
    leaving_cw_t_f = OpenStudio.convert(leaving_cw_t_c, 'C', 'F').get
    approach_r = OpenStudio.convert(approach_k, 'K', 'R').get
    range_r = OpenStudio.convert(range_k, 'K', 'R').get

    # Report out design conditions
    runner.registerInfo("For #{plant_loop.name}, design OATwb = #{
      design_oat_wb_f.round(1)
    } F, approach = #{
        approach_r.round(1)
      } deltaF, range = #{
          range_r.round(1)
        } deltaF, leaving condenser water temperature = #{
            leaving_cw_t_f.round(1)
          } F.")

    # Set the CW sizing parameters
    sizing_plant.setDesignLoopExitTemperature(leaving_cw_t_c)
    sizing_plant.setLoopDesignTemperatureDifference(range_k)

    # Set Cooling Tower sizing parameters.
    # Only the variable speed cooling tower in E+ allows you to set the design temperatures.
    #
    # Per the documentation
    # http://bigladdersoftware.com/epx/docs/8-4/input-output-reference/group-condenser-equipment.html#field-design-u-factor-times-area-value
    # for CoolingTowerSingleSpeed and CoolingTowerTwoSpeed
    # E+ uses the following values during sizing:
    # 95F entering water temp
    # 95F OATdb
    # 78F OATwb
    # range = loop design delta-T aka range (specified above)
    plant_loop.supplyComponents.each do |sc|
      next unless sc.to_CoolingTowerVariableSpeed.is_initialized

      ct = sc.to_CoolingTowerVariableSpeed.get
      # E+ has a minimum limit of 68F (20C) for this field.
      # Check against limit before attempting to set value.
      eplus_design_oat_wb_c_lim = 20
      if design_oat_wb_c < eplus_design_oat_wb_c_lim
        runner.registerInfo("For #{plant_loop.name}, a design OATwb of 68F will be used for " \
                            'sizing the cooling towers because the actual design value is ' \
                            'below the limit EnergyPlus accepts for this input.')
        design_oat_wb_c = eplus_design_oat_wb_c_lim
      end
      ct.setDesignInletAirWetBulbTemperature(design_oat_wb_c)
      ct.setDesignApproachTemperature(approach_k)
      ct.setDesignRangeTemperature(range_k)
    end

    # Set the min and max CW temps
    # Typical design of min temp is really around 40F
    # (that's what basin heaters, when used, are sized for usually)
    min_temp_f = 34
    max_temp_f = 200
    min_temp_c = OpenStudio.convert(min_temp_f, 'F', 'C').get
    max_temp_c = OpenStudio.convert(max_temp_f, 'F', 'C').get
    plant_loop.setMinimumLoopTemperature(min_temp_c)
    plant_loop.setMaximumLoopTemperature(max_temp_c)

    # Cooling Tower operational controls
    # G3.1.3.11 - Tower shall be controlled to maintain a 70F LCnWT where weather permits,
    # floating up to leaving water at design conditions.
    float_down_to_f = 70
    float_down_to_c = OpenStudio.convert(float_down_to_f, 'F', 'C').get

    cw_t_stpt_manager = nil
    plant_loop.supplyOutletNode.setpointManagers.each do |spm|
      if spm.to_SetpointManagerFollowOutdoorAirTemperature.is_initialized &&
         spm.name.get.include?('Setpoint Manager Follow OATwb')
        cw_t_stpt_manager = spm.to_SetpointManagerFollowOutdoorAirTemperature.get
      end
    end
    if cw_t_stpt_manager.nil?
      cw_t_stpt_manager = OpenStudio::Model::SetpointManagerFollowOutdoorAirTemperature.new(plant_loop.model)
      cw_t_stpt_manager.addToNode(plant_loop.supplyOutletNode)
    end
    cw_t_stpt_manager.setName("#{plant_loop.name} Setpoint Manager Follow OATwb with #{
      approach_r.round(1)
    }F Approach")
    cw_t_stpt_manager.setReferenceTemperatureType('OutdoorAirWetBulb')
    # At low design OATwb, it is possible to calculate
    # a maximum temperature below the minimum.  In this case,
    # make the maximum and minimum the same.
    if leaving_cw_t_c < float_down_to_c
      runner.registerInfo("For #{plant_loop.name}, the maximum leaving temperature of #{
        leaving_cw_t_f.round(1)
      } F is below the minimum of #{
          float_down_to_f.round(1)
        } F.  The maximum will be set to the same value as the minimum.")
      leaving_cw_t_c = float_down_to_c
    end
    cw_t_stpt_manager.setMaximumSetpointTemperature(leaving_cw_t_c)
    cw_t_stpt_manager.setMinimumSetpointTemperature(float_down_to_c)
    cw_t_stpt_manager.setOffsetTemperatureDifference(approach_k)
    true
  end
  # rubocop:enable Naming/PredicateMethod

  # Determine the performance rating method specified
  # design condenser water temperature, approach, and range
  #
  # hard-coding this because of https://github.com/NREL/openstudio-standards/issues/1915
  # @param plant_loop [OpenStudio::Model::PlantLoop] the condenser water loop
  # @param design_oat_wb_c [Double] the design OA wetbulb temperature (C)
  # @return [Array<Double>] [leaving_cw_t_c, approach_k, range_k]
  def plant_loop_prm_baseline_condenser_water_temperatures(runner, plant_loop, design_oat_wb_c)
    design_oat_wb_f = OpenStudio.convert(design_oat_wb_c, 'C', 'F').get

    # G3.1.3.11 - CW supply temp shall be evaluated at 0.4% evaporative design OATwb
    # per the formulat approach_F = 25.72 - (0.24 * OATwb_F)
    # 55F <= OATwb <= 90F
    # Design range = 10F.
    range_r = 10

    # Limit the OATwb
    if design_oat_wb_f < 55
      design_oat_wb_f = 55
      runner.registerInfo("For #{
        plant_loop.name
      }, a design OATwb of 55F will"\
      ' be used for sizing the cooling towers because the'\
      ' actual design value is below the limit in G3.1.3.11.')
    elsif design_oat_wb_f > 90
      design_oat_wb_f = 90
      runner.registerInfo("For #{
        plant_loop.name
      }, a design OATwb of 90F will be used for sizing the"\
        ' cooling towers because the actual design value is'\
        ' above the limit in G3.1.3.11.')
    end

    # Calculate the approach
    approach_r = 25.72 - (0.24 * design_oat_wb_f)

    # Calculate the leaving CW temp
    leaving_cw_t_f = design_oat_wb_f + approach_r

    # Convert to SI units
    leaving_cw_t_c = OpenStudio.convert(leaving_cw_t_f, 'F', 'C').get
    approach_k = OpenStudio.convert(approach_r, 'R', 'K').get
    range_k = OpenStudio.convert(range_r, 'R', 'K').get

    [leaving_cw_t_c, approach_k, range_k]
  end

  # define what happens when the measure is run
  # rubocop:disable Naming/PredicateMethod
  def run(model, runner, user_arguments)
    super # Do **NOT** remove this line

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # read input arguments
    chw_hw_oat_reset = runner.getBoolArgumentValue('chw_hw_oat_reset', user_arguments)
    cw_oat_reset = runner.getBoolArgumentValue('cw_oat_reset', user_arguments)
    debug_verbose = runner.getBoolArgumentValue('debug_verbose', user_arguments)

    # build standard
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)

    # ------------------------------------------------
    # get pump specifications before upgrade
    # ------------------------------------------------
    applicable_pumps = []
    pumps_const_spd = model.getPumpConstantSpeeds
    pumps_var_spd = model.getPumpVariableSpeeds
    pump_specs_cst_spd_before = UpgradeHvacPump.pump_specifications(applicable_pumps,
                                                                    pumps_const_spd, std)
    applicable_pumps = pump_specs_cst_spd_before[0]
    pump_rated_flow_total_c = pump_specs_cst_spd_before[1]
    pump_motor_eff_weighted_average_c = pump_specs_cst_spd_before[2]
    pump_motor_bhp_weighted_average_c = pump_specs_cst_spd_before[3]
    count_cst_spd_pump = applicable_pumps.size
    msg_cst_spd_pump_i = "#{count_cst_spd_pump} constant speed pumps found with #{
      pump_rated_flow_total_c.round(6)
    } m3/s total flow, #{
        pump_motor_eff_weighted_average_c.round(3) * 100
      }% average motor efficiency, and #{
          pump_motor_bhp_weighted_average_c.round(6)
        } BHP."
    pump_specs_var_spd_before = UpgradeHvacPump.pump_specifications(applicable_pumps,
                                                                    pumps_var_spd, std)
    applicable_pumps = pump_specs_var_spd_before[0]
    pump_rated_flow_total_v = pump_specs_var_spd_before[1]
    pump_motor_eff_weighted_average_v = pump_specs_var_spd_before[2]
    pump_motor_bhp_weighted_average_v = pump_specs_var_spd_before[3]
    pump_var_part_load_curve_coeff1_weighted_avg = pump_specs_var_spd_before[4]
    pump_var_part_load_curve_coeff2_weighted_avg = pump_specs_var_spd_before[5]
    pump_var_part_load_curve_coeff3_weighted_avg = pump_specs_var_spd_before[6]
    pump_var_part_load_curve_coeff4_weighted_avg = pump_specs_var_spd_before[7]
    count_var_spd_pump = applicable_pumps.size - count_cst_spd_pump
    msg_var_spd_pump_i = "#{count_var_spd_pump} variable speed pumps found with #{
      pump_rated_flow_total_v.round(6)
    } m3/s total flow, #{
        pump_motor_eff_weighted_average_v.round(3) * 100
      }% average motor efficiency, and #{
          pump_motor_bhp_weighted_average_v.round(6)
        } BHP."
    if debug_verbose
      runner.registerInfo('### ------------------------------------------------------')
      runner.registerInfo('### pump specs before upgrade')
      runner.registerInfo("### pump_rated_flow_total_c = #{
        pump_rated_flow_total_c.round(6)
      }")
      runner.registerInfo("### pump_motor_eff_weighted_average_c = #{
        pump_motor_eff_weighted_average_c.round(2)
      }")
      runner.registerInfo("### pump_motor_bhp_weighted_average_c = #{
        pump_motor_bhp_weighted_average_c.round(6)
      }")
      runner.registerInfo("### pump_rated_flow_total_v = #{
        pump_rated_flow_total_v.round(6)
      }")
      runner.registerInfo("### pump_motor_eff_weighted_average_v = #{
        pump_motor_eff_weighted_average_v.round(2)
      }")
      runner.registerInfo("### pump_motor_bhp_weighted_average_v = #{
        pump_motor_bhp_weighted_average_v.round(6)
      }")
      runner.registerInfo("### pump_var_part_load_curve_coeff1_weighted_avg = #{
        pump_var_part_load_curve_coeff1_weighted_avg
      }")
      runner.registerInfo("### pump_var_part_load_curve_coeff2_weighted_avg = #{
        pump_var_part_load_curve_coeff2_weighted_avg
      }")
      runner.registerInfo("### pump_var_part_load_curve_coeff3_weighted_avg = #{
        pump_var_part_load_curve_coeff3_weighted_avg
      }")
      runner.registerInfo("### pump_var_part_load_curve_coeff4_weighted_avg = #{
        pump_var_part_load_curve_coeff4_weighted_avg}")
      runner.registerInfo("### total count of applicable pumps = #{applicable_pumps.size}")
      applicable_pumps.each do |applicable_pump|
        runner.registerInfo("### applicable pump name = #{applicable_pump.name}")
      end
      runner.registerInfo('### ------------------------------------------------------')
    end

    # ------------------------------------------------
    # applicability
    # ------------------------------------------------
    if applicable_pumps.empty?
      runner.registerAsNotApplicable('no eligible pumps are found in the model.')
      return true
    end

    # ------------------------------------------------
    # report initial condition
    # ------------------------------------------------
    msg_initial = "#{msg_cst_spd_pump_i} #{msg_var_spd_pump_i}"
    runner.registerInitialCondition(msg_initial)

    # ------------------------------------------------
    # pump upgrades
    # ------------------------------------------------
    applicability_power = false
    applicability_eff = false
    applicable_pumps.each do |old_pump|
      if debug_verbose
        runner.registerInfo("### replacing pump: #{old_pump.name}")
      end

      # Clone key parameters from the old pump
      pump_flow_rate_m_3_per_s = old_pump.ratedFlowRate.get
      pump_head_pa = old_pump.ratedPumpHead
      original_name = old_pump.name.get
      pump_name = "#{original_name.gsub('constant', 'variable').gsub('Constant',
                                                                     'Variable')}_upgrade"
      pump_power_w = old_pump.ratedPowerConsumption.get
      pump_motor_eff = old_pump.motorEfficiency

      if debug_verbose
        runner.registerInfo("--- existing spec: pump_flow_rate_m_3_per_s = #{
          pump_flow_rate_m_3_per_s
        } m3/s")
        runner.registerInfo("--- existing spec: pump_head_pa = #{pump_head_pa} Pa")
        runner.registerInfo("--- existing spec: pump_power_w = #{pump_power_w} W")
      end

      # Remove the old pump from the loop
      supply_inlet_node = old_pump.inletModelObject.get.to_Node.get
      supply_outlet_node = old_pump.outletModelObject.get.to_Node.get
      old_pump.remove

      if debug_verbose
        runner.registerInfo("--- existing spec: supply_inlet_node = #{supply_inlet_node.name}")
        runner.registerInfo("--- existing spec: supply_outlet_node = #{supply_outlet_node.name}")
      end

      # Create the new pump (choose type based on old pump)
      new_pump = OpenStudio::Model::PumpVariableSpeed.new(model)
      new_pump.setName(pump_name)
      new_pump.setRatedFlowRate(pump_flow_rate_m_3_per_s)
      new_pump.setRatedPumpHead(pump_head_pa)

      # Apply motor power
      pump_power_new_w = UpgradeHvacPump.compute_design_motor_power(pump_flow_rate_m_3_per_s,
                                                                    pump_head_pa)
      if pump_power_new_w > pump_power_w
        runner.registerInfo("--- new pump power (#{
          pump_power_new_w
        }) is worse than existing pump power (#{
            pump_power_w
          }). skipping power update.")
      else
        applicability_power = true
        new_pump.setRatedPowerConsumption(pump_power_new_w)
      end
      if debug_verbose
        runner.registerInfo("--- pump design power | old: #{pump_power_w.round(2)} W")
        runner.registerInfo("--- pump design power | new: #{pump_power_new_w.round(2)} W")
      end

      # Apply motor efficiency
      pump_motor_eff_new_pcnt = UpgradeHvacPump.estimate_motor_efficiency_pcnt(pump_power_new_w)
      pump_motor_eff_new = pump_motor_eff_new_pcnt / 100.0
      if pump_motor_eff > pump_motor_eff_new
        runner.registerInfo("--- new pump efficiency (#{
          pump_motor_eff_new
        }) is worse than existing pump efficiency (#{
            pump_motor_eff
          }). skipping efficiency update.")
      else
        applicability_eff = true
        new_pump.setMotorEfficiency(pump_motor_eff_new)
      end
      if debug_verbose
        runner.registerInfo("--- pump motor efficiency | old: #{pump_motor_eff.round(2)}")
        runner.registerInfo("--- pump motor efficiency | new: #{pump_motor_eff_new.round(2)}")
      end

      # Apply part-load performance for variable speed pump
      _, coeff_a, coeff_b, coeff_c, coeff_d = UpgradeHvacPump.curve_fraction_of_full_load_power(
        model
      )
      new_pump.setCoefficient1ofthePartLoadPerformanceCurve(coeff_a)
      new_pump.setCoefficient2ofthePartLoadPerformanceCurve(coeff_b)
      new_pump.setCoefficient3ofthePartLoadPerformanceCurve(coeff_c)
      new_pump.setCoefficient4ofthePartLoadPerformanceCurve(coeff_d)

      # TODO: once ComStock baseline gets updated with higher min flow fraction than zero,
      # make relevant updates for variable speed pumps via setDesignMinimumFlowRateFraction

      # Add new pump back to original node
      new_pump.addToNode(supply_inlet_node)

      if debug_verbose
        runner.registerInfo("--- replaced pump '#{
          old_pump.name
        }' with new pump '#{
            new_pump.name
          }'.")
      end
    end

    # ------------------------------------------------
    # applicability 2nd check
    # ------------------------------------------------
    if applicability_eff == false && applicability_power == false
      runner.registerAsNotApplicable(
        'existing pumps are all performing better than this measure ' \
        "implementation: applicability_eff = #{applicability_eff} | " \
        "applicability_power = #{applicability_power}"
      )
      return true
    end

    # ------------------------------------------------
    # control upgrades
    # ------------------------------------------------
    # Enable supply water temperature reset for chilled/hot water loops
    if chw_hw_oat_reset
      if debug_verbose
        runner.registerInfo('### enabling CHW/HW supply water temperature reset')
      end

      model.getPlantLoops.each do |plant_loop|
        unless plant_loop.name.get.downcase.include?('service water loop')
          if debug_verbose
            runner.registerInfo("--- updating plant loop for CHW/HW reset: '#{plant_loop.name}'")
          end
          std.plant_loop_enable_supply_water_temperature_reset(plant_loop)
        end
      end
    end

    # Apply condenser water temperature reset based on Appendix G
    if cw_oat_reset
      if debug_verbose
        runner.registerInfo('### applying condenser water temperature reset (CW)')
      end

      model.getPlantLoops.each do |plant_loop|
        unless plant_loop.name.get.downcase.include?('service water loop')
          if debug_verbose
            runner.registerInfo("--- updating plant loop for CW reset: '#{plant_loop.name}'")
          end
          plant_loop_apply_prm_baseline_condenser_water_temperatures(runner, plant_loop)
        end
      end
    end

    # ------------------------------------------------
    # get pump specifications after upgrade
    # ------------------------------------------------
    dummy = []
    pumps_const_spd = model.getPumpConstantSpeeds
    pumps_var_spd = model.getPumpVariableSpeeds
    pump_specs_cst_spd_after = UpgradeHvacPump.pump_specifications(dummy, pumps_const_spd, std)
    applicable_pumps = pump_specs_cst_spd_after[0]
    pump_rated_flow_total_c = pump_specs_cst_spd_after[1]
    pump_motor_eff_weighted_average_c = pump_specs_cst_spd_after[2]
    pump_motor_bhp_weighted_average_c = pump_specs_cst_spd_after[3]
    count_cst_spd_pump = applicable_pumps.size
    msg_cst_spd_pump_f = "#{count_cst_spd_pump} constant speed pumps updated with #{
      pump_rated_flow_total_c.round(6)
    } m3/s total flow, #{
        pump_motor_eff_weighted_average_c.round(3) * 100
      }% average motor efficiency, and #{
          pump_motor_bhp_weighted_average_c.round(6)
        } BHP."
    pump_specs_var_spd_after = UpgradeHvacPump.pump_specifications(dummy, pumps_var_spd, std)
    applicable_pumps = pump_specs_var_spd_after[0]
    pump_rated_flow_total_v = pump_specs_var_spd_after[1]
    pump_motor_eff_weighted_average_v = pump_specs_var_spd_after[2]
    pump_motor_bhp_weighted_average_v = pump_specs_var_spd_after[3]
    pump_var_part_load_curve_coeff1_weighted_avg = pump_specs_var_spd_after[4]
    pump_var_part_load_curve_coeff2_weighted_avg = pump_specs_var_spd_after[5]
    pump_var_part_load_curve_coeff3_weighted_avg = pump_specs_var_spd_after[6]
    pump_var_part_load_curve_coeff4_weighted_avg = pump_specs_var_spd_after[7]
    count_var_spd_pump = applicable_pumps.size - count_cst_spd_pump
    msg_var_spd_pump_f = "#{count_var_spd_pump} variable speed pumps updated with #{
      pump_rated_flow_total_v.round(6)
    } m3/s total flow, #{
        pump_motor_eff_weighted_average_v.round(3) * 100
      }% average motor efficiency, and #{
          pump_motor_bhp_weighted_average_v.round(6)
        } BHP."

    if debug_verbose
      runner.registerInfo('### ------------------------------------------------------')
      runner.registerInfo('### pump specs after upgrade')
      runner.registerInfo("### pump_rated_flow_total_c = #{
        pump_rated_flow_total_c.round(6)
      }")
      runner.registerInfo("### pump_motor_eff_weighted_average_c = #{
        pump_motor_eff_weighted_average_c.round(2)
      }")
      runner.registerInfo("### pump_motor_bhp_weighted_average_c = #{
        pump_motor_bhp_weighted_average_c.round(6)
      }")
      runner.registerInfo("### pump_rated_flow_total_v = #{
        pump_rated_flow_total_v.round(6)
      }")
      runner.registerInfo("### pump_motor_eff_weighted_average_v = #{
        pump_motor_eff_weighted_average_v.round(2)
      }")
      runner.registerInfo("### pump_motor_bhp_weighted_average_v = #{
        pump_motor_bhp_weighted_average_v.round(6)
      }")
      runner.registerInfo("### pump_var_part_load_curve_coeff1_weighted_avg = #{
        pump_var_part_load_curve_coeff1_weighted_avg
      }")
      runner.registerInfo("### pump_var_part_load_curve_coeff2_weighted_avg = #{
        pump_var_part_load_curve_coeff2_weighted_avg
      }")
      runner.registerInfo("### pump_var_part_load_curve_coeff3_weighted_avg = #{
        pump_var_part_load_curve_coeff3_weighted_avg
      }")
      runner.registerInfo("### pump_var_part_load_curve_coeff4_weighted_avg = #{
        pump_var_part_load_curve_coeff4_weighted_avg
      }")
      runner.registerInfo("### total count of applicable pumps = #{applicable_pumps.size}")
      runner.registerInfo('### ------------------------------------------------------')
    end

    # ------------------------------------------------
    # report final condition
    # ------------------------------------------------
    msg_final_condition = "#{msg_cst_spd_pump_f} #{msg_var_spd_pump_f}"
    runner.registerFinalCondition(msg_final_condition)

    return true
  end
  # rubocop:enable Naming/PredicateMethod
end

# register the measure to be used by the application
UpgradeHvacPump.new.registerWithApplication
