# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2021, Alliance for Sustainable Energy, LLC.
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

# Measure distributed under NREL Copyright terms, see LICENSE.md file.

# start the measure
class CondensingBoilers < OpenStudio::Measure::ModelMeasure
  require 'comstock-typical'

  # human readable name
  def name
    # Measure name should be the title case of the class name.
    'condensing_boilers'
  end

  # human readable description
  def description
    'This measure replaces an exising natural gas boiler with a condensing gas boiler.'
  end

  # human readable description of modeling approach
  def modeler_description
    'This measure replaces an exising natural gas boiler with a condensing gas boiler. The measure loops through existing boiler objects and increases the efficiency, lowers the water supply temperature, and modifies the performance curve to represent condensing boilers.'
  end

  ## USER ARGS ---------------------------------------------------------------------------------------------------------
  # define the arguments that the user will input
  def arguments(_model)
    OpenStudio::Measure::OSArgumentVector.new
  end
  ## END USER ARGS -----------------------------------------------------------------------------------------------------

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # report initial condition of model
    num_boilers = model.getBoilerHotWaters.size
    runner.registerInitialCondition("The building started with #{num_boilers} hot water boilers.")

    # check for existence of water heater boiler
    if model.getBoilerHotWaters.empty?
      runner.registerAsNotApplicable('No hot water boilers found in the model. Measure not applicable ')
      return true
    end

    # set new boiler supply temp to 140F to represent condensing boiler
    hw_setpoint_f = 180
    hw_setpoint_c = OpenStudio.convert(hw_setpoint_f, 'F', 'C').get

    # set delta T for hw loop to 22.2 C, which corresponds to 100 F return temp
    hw_delta_t_c = 22.2
    hw_return_temp_c = hw_setpoint_c - hw_delta_t_c

    # create new setpoint manager for new supply temp of 140F
    new_setpoint_sched = OpenStudio::Model::ScheduleConstant.new(model)
    new_setpoint_sched.setValue(hw_setpoint_c)
    new_setpoint_sched.setName('Condensing Boiler Heating Temperature Setpoint')

    # create biquadratic curve and set upper and lower limit
    condensing_boiler_curve = OpenStudio::Model::CurveBiquadratic.new(model)
    condensing_boiler_curve.setName('Condensing Boiler Biquadratic Curve')
    condensing_boiler_curve.setCoefficient1Constant(1.144514)
    condensing_boiler_curve.setCoefficient2x(-0.02399)
    condensing_boiler_curve.setCoefficient3xPOW2(-0.01156)
    condensing_boiler_curve.setCoefficient4y(-0.00439)
    condensing_boiler_curve.setCoefficient5yPOW2(0.000019)
    condensing_boiler_curve.setCoefficient6xTIMESY(0.000393)
    condensing_boiler_curve.setMinimumValueofy(OpenStudio.convert(90, 'F', 'C').get)
    condensing_boiler_curve.setMaximumValueofy(OpenStudio.convert(160, 'F', 'C').get)
    condensing_boiler_curve.setMinimumValueofx(0.05)
    condensing_boiler_curve.setMaximumValueofx(1.0)
    condensing_boiler_curve.setMaximumCurveOutput(1.032)

    sizing_systems = model.getSizingSystems
    sizing_systems.each do |sizing_system|
      # sizing_system.autosizeHeatingDesignCapacity
    end

    # set empty array for hot water coils

    boilers = model.getBoilerHotWaters
    boilers.each do |boiler|
      # get existing fuel type and efficiency
      existing_boiler_fuel_type = boiler.fuelType
      existing_boiler_efficiency = boiler.nominalThermalEfficiency
      existing_boiler_capacity = boiler.nominalCapacity
      existing_boiler_name = boiler.name

      runner.registerInfo("Existing boiler #{existing_boiler_name} has nominal efficiency #{existing_boiler_efficiency}, fuel type #{existing_boiler_fuel_type}, and nominal capacity #{existing_boiler_capacity} W.")

      # set efficiency to 0.95 to reflect condensing boiler
      boiler.setNominalThermalEfficiency(0.95)

      # set new performance curve
      boiler.setNormalizedBoilerEfficiencyCurve(condensing_boiler_curve)
      boiler.setEfficiencyCurveTemperatureEvaluationVariable('EnteringBoiler')
      boiler.setWaterOutletUpperTemperatureLimit(hw_setpoint_c)

      # autosize the boiler capacity. should not make a difference if running standalone measure, but could downsize if run with other upgrades.
      # boiler.autosizeDesignWaterFlowRate
      # boiler.autosizeNominalCapacity

      if existing_boiler_name.get.include?('Supplemental')
        # denotes boiler is a supplemental boiler located on a condenser loop. do not resize pump or reset loop temp.
        boiler.setName('Supplemental Condensing Boiler Thermal Eff 0.95')
      else
        # get plant loop and set new supply temp and setpoint manager to 140F
        boiler.inletModelObject.get.to_Node.get
        boiler.outletModelObject.get.to_Node.get
        htg_loop = boiler.plantLoop.get
        htg_loop_sizing = htg_loop.sizingPlant
        htg_loop_sizing.setDesignLoopExitTemperature(hw_setpoint_c)
        htg_loop_sizing.setLoopDesignTemperatureDifference(hw_delta_t_c)
        # htg_loop.autosizeMaximumLoopFlowRate
        # htg_loop.autocalculatePlantLoopVolume

        htg_loop.supplyOutletNode.setpointManagers.each(&:remove)

        # original method: set sp manager to constant 140F
        # spm.to_SetpointManagerScheduled.get.setSchedule(new_setpoint_sched)

        # create new OA reset setpoint manager with settings: hw temp 140f for air temp >50F, hw temp 180F for air temp <20F
        oa_reset_sp_mgr = OpenStudio::Model::SetpointManagerOutdoorAirReset.new(model)
        oa_reset_sp_mgr.setSetpointatOutdoorHighTemperature(OpenStudio.convert(140, 'F', 'C').get)
        oa_reset_sp_mgr.setOutdoorHighTemperature(OpenStudio.convert(50, 'F', 'C').get)
        oa_reset_sp_mgr.setSetpointatOutdoorLowTemperature(OpenStudio.convert(180, 'F', 'C').get)
        oa_reset_sp_mgr.setOutdoorLowTemperature(OpenStudio.convert(20, 'F', 'C').get)

        # add to supply outlet node
        oa_reset_sp_mgr.addToNode(htg_loop.supplyOutletNode)
        runner.registerInfo('Added outdoor air reset setpoint manager to hot water loop with 140F for ≤20F and 120F for ≥50F.')

        # autosize boiler supply pump
        htg_loop.supplyComponents.each do |sup_comp|
          next unless sup_comp.to_PumpVariableSpeed.is_initialized

          sup_comp.to_PumpVariableSpeed.get
          # runner.registerInfo('at pump')
          # pump.autosizeRatedFlowRate
          # pump.autosizeRatedPowerConsumption
        end

        boiler.setName('Main Condensing Boiler Thermal Eff 0.95')
      end
    end

    # re-autosize all supply fans on airloop
    model.getAirLoopHVACs.each do |air_loop|
      air_loop.supplyComponents.each do |sup_comp|
        if sup_comp.to_FanConstantVolume.is_initialized
          sup_comp.to_FanConstantVolume.get
          # const_vol_fan.autosizeMaximumFlowRate
        elsif sup_comp.to_FanVariableVolume.is_initialized
          sup_comp.to_FanVariableVolume.get
          # var_vol_fan.autosizeMaximumFlowRate
        end
      end
    end

    # re-autosize traditional hot water coils
    hw_coils = model.getCoilHeatingWaters
    hw_coils.each do |coil|
      # get hot water coils and reset inlet and outlet temps and autosize
      coil.setRatedInletWaterTemperature(hw_setpoint_c)
      coil.setRatedOutletWaterTemperature(hw_return_temp_c)
      # coil.setRatedInletAirTemperature(12.8) #set to 55F
      # coil.setRatedOutletAirTemperature(32.2) #set return air temp to 90F
      # coil.autosizeMaximumWaterFlowRate
      # coil.autosizeUFactorTimesAreaValue
      # coil.autosizeRatedCapacity
    end

    # also check for hot water baseboard coils
    baseboard_hw_coils = model.getCoilHeatingWaterBaseboards
    baseboard_hw_coils.each do |coil|
      # get hot water baseboard coils and  autosize
      # coil.autosizeMaximumWaterFlowRate
      # coil.autosizeUFactorTimesAreaValue
      # coil.autosizeHeatingDesignCapacity
    end

    # re-autosize zone air terminals and fan coil units to accommodate for new air flow rates
    thermal_zones = model.getThermalZones
    thermal_zones.each do |zone|
      zone.equipment.each do |equip|
        if equip.to_ZoneHVACFourPipeFanCoil.is_initialized
          zone_fan_coil = equip.to_ZoneHVACFourPipeFanCoil.get
          # zone_fan_coil.autosizeMaximumSupplyAirFlowRate
          # zone_fan_coil.autosizeMaximumHotWaterFlowRate
          if zone_fan_coil.supplyAirFan.to_FanOnOff.is_initialized
            zone_fan_coil.supplyAirFan.to_FanOnOff.get
            # fan.autosizeMaximumFlowRate
          end
        elsif equip.to_AirTerminalSingleDuctVAVReheat.is_initialized
          equip.to_AirTerminalSingleDuctVAVReheat.get
          # vav_terminal.autosizeMaximumAirFlowRate
          # vav_terminal.autosizeConstantMinimumAirFlowFraction
          # vav_terminal.autosizeFixedMinimumAirFlowRate
          # vav_terminal.autosizeMaximumHotWaterOrSteamFlowRate
        elsif equip.to_AirTerminalSingleDuctConstantVolumeNoReheat.is_initialized
          equip.to_AirTerminalSingleDuctConstantVolumeNoReheat.get
          # air_terminal.autosizeMaximumAirFlowRate
        end
      end
    end

    # Register final condition
    runner.registerFinalCondition("The building finished with #{num_boilers} condensing boilers.")
    true
  end
end

# register the measure to be used by the application
CondensingBoilers.new.registerWithApplication
