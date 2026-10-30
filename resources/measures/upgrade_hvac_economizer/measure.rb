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
class HVACEconomizer < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'HVACEconomizer'
  end

  # human readable description
  def description
    return 'This measure enables air-side economizing in an air system if not already present.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'This measure enables dry-bulb or enthalpy-based air-side economizing depending on climate zone in the controller outdoor air object.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    return args
  end

  # check if air loop is evaporative cooler
  def air_loop_hvac_include_evaporative_cooler?(air_loop_hvac)
    air_loop_hvac.supplyComponents.each do |comp|
      return true if comp.to_EvaporativeCoolerDirectResearchSpecial.is_initialized
      return true if comp.to_EvaporativeCoolerIndirectResearchSpecial.is_initialized
    end
    false
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # ----------------------------------------------------
    # puts("### use the built-in error checking ")
    # ----------------------------------------------------
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # ----------------------------------------------------
    # puts("### applicability")
    # ----------------------------------------------------
    # check applicability
    no_outdoor_air_loops = 0
    doas_loops = 0
    existing_economizer_loops = 0
    selected_air_loops = []
    model.getAirLoopHVACs.each do |air_loop_hvac|
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem
      if oa_system.is_initialized
        oa_system = oa_system.get
      else
        no_outdoor_air_loops += 1
        runner.registerInfo("Air loop #{air_loop_hvac.name} does not have outdoor air and cannot economize.")
        next
      end

      sizing_system = air_loop_hvac.sizingSystem
      type_of_load = sizing_system.typeofLoadtoSizeOn
      if type_of_load == 'VentilationRequirement'
        doas_loops += 1
        runner.registerInfo("Air loop #{air_loop_hvac.name} is a DOAS system and cannot economize.")
        next
      end

      if air_loop_hvac_include_evaporative_cooler?(air_loop_hvac)
        runner.registerInfo("Air loop #{air_loop_hvac.name} is a evaporative cooler and cannot economize.")
        next
      end

      oa_controller = oa_system.getControllerOutdoorAir
      economizer_type = oa_controller.getEconomizerControlType
      if economizer_type == 'NoEconomizer'
        runner.registerInfo("Air loop #{air_loop_hvac.name} does not have an existing economizer.  This measure will add an economizer.")
        selected_air_loops << air_loop_hvac
      else
        existing_economizer_loops += 1
        runner.registerInfo("Air loop #{air_loop_hvac.name} has an existing #{economizer_type} economizer.")
      end
    end
    if selected_air_loops.empty?
      runner.registerAsNotApplicable('Model contains no air loops eligible for adding an outdoor air economizer.')
      return true
    end

    # ----------------------------------------------------
    # puts("### initialization")
    # ----------------------------------------------------
    runner.registerInitialCondition("Out of #{model.getAirLoopHVACs.size} air loops, #{no_outdoor_air_loops} do not have outdoor air, #{doas_loops} are DOAS systems, and #{existing_economizer_loops} have existing economizers, leaving #{selected_air_loops.size} eligible for an economizer.")

    # ----------------------------------------------------
    # puts("### implement economizers")
    # ----------------------------------------------------
    # build standard to access methods
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)

    # get climate zone
    climate_zone = OpenstudioStandards::Weather.model_get_climate_zone(model)
    runner.registerInfo("initial read of climate zone = #{climate_zone}")
    if climate_zone.empty?
      runner.registerError('Unable to determine climate zone for model. Cannot apply economizer without climate zone information.')
    end

    # check climate zone name validity
    # this happens to example model but maybe not during ComStock model creation?
    substring_count = climate_zone.scan(/ASHRAE 169-2013-/).length
    if substring_count > 1
      runner.registerInfo("climate zone name includes repeated substring of 'ASHRAE 169-2013-'")
      climate_zone = climate_zone.sub(/ASHRAE 169-2013-/, '')
      runner.registerInfo("revised climate zone name = #{climate_zone}")
    end

    # determine economizer type
    economizer_type = std.model_economizer_type(model, climate_zone)
    runner.registerInfo("economizer type for the climate zone = #{economizer_type}")

    # add economizer to selected airloops
    added_economizers = 0
    selected_air_loops.each do |air_loop_hvac|
      # get airLoopHVACOutdoorAirSystem
      oa_sys = air_loop_hvac.airLoopHVACOutdoorAirSystem
      if oa_sys.is_initialized
        oa_sys = oa_sys.get
      else
        OpenStudio.logFree(OpenStudio::Error, 'openstudio.prototype.Model', "#{air_loop.name} is requested to have an economizer, but it has no OA system.")
        next
      end

      # get controller:outdoorair
      oa_control = oa_sys.getControllerOutdoorAir
      # puts("--- adding economizer to controller:outdoorair = #{oa_control.name}")

      # change/check settings: control type
      # puts("--- economizer control type before: #{oa_control.getEconomizerControlType}")
      if oa_control.getEconomizerControlType != economizer_type
        oa_control.setEconomizerControlType(economizer_type)
      end
      # puts("--- economizer control type new: #{oa_control.getEconomizerControlType}")

      # get economizer limits
      limits = std.air_loop_hvac_economizer_limits(air_loop_hvac, climate_zone) # in IP unit
      # puts("--- economizer limits [db max|enthal max|dewpoint max] for the climate zone = #{limits}")

      # implement limits for each control type
      case economizer_type
      when 'FixedDryBulb'
        if oa_control.getEconomizerMaximumLimitDryBulbTemperature.is_initialized
          puts("--- economizer limit for #{economizer_type} before: #{oa_control.getEconomizerMaximumLimitDryBulbTemperature.get}")
        end
        drybulb_limit_c = OpenStudio.convert(limits[0], 'F', 'C').get
        oa_control.resetEconomizerMaximumLimitDryBulbTemperature
        oa_control.setEconomizerMaximumLimitDryBulbTemperature(drybulb_limit_c)
        # puts("--- economizer limit for #{economizer_type} new: #{oa_control.getEconomizerMaximumLimitDryBulbTemperature.get}")
      when 'FixedEnthalpy'
        if oa_control.getEconomizerMaximumLimitEnthalpy.is_initialized
          puts("--- economizer limit for #{economizer_type} before: #{oa_control.getEconomizerMaximumLimitEnthalpy.get}")
        end
        enthalpy_limit_j_per_kg = OpenStudio.convert(limits[1], 'Btu/lb', 'J/kg').get
        oa_control.resetEconomizerMaximumLimitEnthalpy
        oa_control.setEconomizerMaximumLimitEnthalpy(enthalpy_limit_j_per_kg)
        # puts("--- economizer limit for #{economizer_type} new: #{oa_control.getEconomizerMaximumLimitEnthalpy.get}")
      when 'FixedDewPointAndDryBulb'
        if oa_control.getEconomizerMaximumLimitDewpointTemperature.is_initialized
          puts("--- economizer limit for #{economizer_type} before: #{oa_control.getEconomizerMaximumLimitDewpointTemperature.get}")
        end
        drybulb_limit_f = 75
        dewpoint_limit_f = 55
        drybulb_limit_c = OpenStudio.convert(drybulb_limit_f, 'F', 'C').get
        dewpoint_limit_c = OpenStudio.convert(dewpoint_limit_f, 'F', 'C').get
        oa_control.resetEconomizerMaximumLimitDryBulbTemperature
        oa_control.resetEconomizerMaximumLimitDewpointTemperature
        oa_control.setEconomizerMaximumLimitDryBulbTemperature(drybulb_limit_c)
        oa_control.setEconomizerMaximumLimitDewpointTemperature(dewpoint_limit_c)
        # puts("--- economizer limit (max db T) for #{economizer_type} new: #{oa_control.getEconomizerMaximumLimitDryBulbTemperature.get}")
        # puts("--- economizer limit (max dp T) for #{economizer_type} new: #{oa_control.getEconomizerMaximumLimitDewpointTemperature.get}")
      end

      # change/check settings: lockout type
      # puts("--- economizer lockout type before: #{oa_control.getLockoutType}")
      if oa_control.getLockoutType != 'LockoutWithHeating'
        oa_control.setLockoutType('LockoutWithHeating') # integrated economizer
      end
      # puts("--- economizer lockout type new: #{oa_control.getLockoutType}")

      # calc statistics
      added_economizers += 1
    end

    # ----------------------------------------------------
    # puts("### implement EMS for economizing only when cooling")
    # ----------------------------------------------------
    # for ems output variables
    li_ems_clg_coil_rate = []
    li_ems_sens_econ_status = []
    li_ems_sens_min_flow = []
    li_ems_act_oa_flow = []
    li_ems_ref = []

    # loop through air loops
    selected_air_loops.each do |air_loop_hvac|
      # get OA system
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem
      if oa_system.is_initialized
        oa_system = oa_system.get
      end

      # get economizer from OA controller
      oa_controller = oa_system.getControllerOutdoorAir
      # oa_controller.setName(oa_controller.name.to_s.gsub("-", ""))
      economizer_type = oa_controller.getEconomizerControlType
      next unless economizer_type != 'NoEconomizer'

      # check zone exhaust fan availability
      zone_fan_exhaust_available = false
      zone_fan_exhaust_names = []
      air_loop_hvac.thermalZones.each do |tz|
        tz.equipment.each do |zone_equipment|
          if zone_equipment.to_FanZoneExhaust.is_initialized
            fanzoneexhaust = zone_equipment.to_FanZoneExhaust.get
            zone_fan_exhaust_available = true
            zone_fan_exhaust_names << fanzoneexhaust.name.to_s
          end
        end
      end

      # get main cooling coil from air loop
      # this is used to determine if there is a cooling load on the air loop
      clg_coil = nil
      air_loop_hvac.supplyComponents.each do |component|
        # Get the object type
        obj_type = component.iddObjectType.valueName.to_s
        case obj_type
        when 'OS_Coil_Cooling_DX_SingleSpeed'
          clg_coil = component.to_CoilCoolingDXSingleSpeed.get
        when 'OS_Coil_Cooling_DX_TwoSpeed'
          clg_coil = component.to_CoilCoolingDXTwoSpeed.get
        when 'OS_Coil_Cooling_DX_MultiSpeed'
          clg_coil = component.to_CoilCoolingDXMultiSpeed.get
        when 'OS_Coil_Cooling_DX_VariableSpeed'
          clg_coil = component.to_CoilCoolingDXVariableSpeed.get
        when 'OS_Coil_Cooling_Water'
          clg_coil = component.to_CoilCoolingWater.get
        when 'OS_Coil_Cooling_WaterToAirHeatPumpEquationFit'
          clg_coil = component.to_CoilCoolingWatertoAirHeatPumpEquationFit.get
        when 'OS_AirLoopHVAC_UnitarySystem'
          unitary_sys = component.to_AirLoopHVACUnitarySystem.get
          if unitary_sys.coolingCoil.is_initialized
            clg_coil = unitary_sys.coolingCoil.get
          end
        when 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir'
          unitary_sys = component.to_AirLoopHVACUnitaryHeatPumpAirToAir.get
          if unitary_sys.coolingCoil.is_initialized
            clg_coil = unitary_sys.coolingCoil.get
          end
        when 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir_MultiSpeed'
          unitary_sys = component.to_AirLoopHVACUnitaryHeatPumpAirToAirMultiSpeed.get
          if unitary_sys.coolingCoil.is_initialized
            clg_coil = unitary_sys.coolingCoil.get
          end
        when 'OS_AirLoopHVAC_UnitaryHeatCool_VAVChangeoverBypass'
          unitary_sys = component.to_AirLoopHVACUnitaryHeatCoolVAVChangeoverBypass.get
          if unitary_sys.coolingCoil.is_initialized
            clg_coil = unitary_sys.coolingCoil.get
          end
        end
      end

      # get minimum outdoor air flow rate
      # if the measure is applied on an autosized model, then this part will result in incorrect EMS application.
      min_oa_flow_m_3_per_sec = 0
      if oa_controller.autosizedMinimumOutdoorAirFlowRate.is_initialized
        min_oa_flow_m_3_per_sec = oa_controller.autosizedMinimumOutdoorAirFlowRate.get
      elsif oa_controller.minimumOutdoorAirFlowRate.is_initialized
        min_oa_flow_m_3_per_sec = oa_controller.minimumOutdoorAirFlowRate.get
      else
        runner.registerWarning("cannot get minimum outdoor air flow rate from #{oa_controller.name}. make sure to hardsize the model in order to get the correct sizing information.")
      end
      min_oa_flow_kg_per_sec = min_oa_flow_m_3_per_sec * 1.196621537 # TODO: is temperature dependency not considered for air density?
      runner.registerInfo("#{oa_controller.name}: minimum outdoor air flow rate extracted from the model = #{min_oa_flow_m_3_per_sec} m3/sec")
      runner.registerInfo("#{oa_controller.name}: minimum outdoor air flow rate extracted from the model = #{min_oa_flow_kg_per_sec} kg/sec")

      # get nighttime variability ventilation schedule
      min_oa_flow_sch_nighttime_variability = nil
      if oa_controller.minimumOutdoorAirSchedule.is_initialized
        min_oa_flow_sch_nighttime_variability = oa_controller.minimumOutdoorAirSchedule.get
        min_oa_flow_sch_nighttime_variability_name = min_oa_flow_sch_nighttime_variability.name.to_s
      else
        runner.registerError("cannot get minimum outdoor air schedule from #{oa_controller.name}")
      end

      # set sensor for zone cooling load from cooling coil cooling rate
      sens_clg_coil_rate = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Cooling Coil Total Cooling Rate')
      sens_clg_coil_rate.setName("sens_zn_clg_rate_#{OpenstudioStandards::HVAC.ems_friendly_name(air_loop_hvac.name.get.to_s)}")
      sens_clg_coil_rate.setKeyName(clg_coil.name.get)
      li_ems_clg_coil_rate << sens_clg_coil_rate

      # set sensor - Outdoor Air Controller Minimum Mass Flow Rate
      sens_min_oa_rate = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Air System Outdoor Air Mechanical Ventilation Requested Mass Flow Rate')
      sens_min_oa_rate.setName("sens_min_oa_flow_#{OpenstudioStandards::HVAC.ems_friendly_name(air_loop_hvac.name.get.to_s)}")
      sens_min_oa_rate.setKeyName(air_loop_hvac.name.get)
      li_ems_sens_min_flow << sens_min_oa_rate

      # set sensor - Air System Outdoor Air Economizer Status
      sens_econ_status = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Air System Outdoor Air Economizer Status')
      sens_econ_status.setName("sens_econ_status_#{OpenstudioStandards::HVAC.ems_friendly_name(air_loop_hvac.name.get.to_s)}")
      sens_econ_status.setKeyName(air_loop_hvac.name.get)
      li_ems_sens_econ_status << sens_econ_status

      # set sensor for zone cooling load from cooling coil cooling rate
      sens_nighttimevar = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Schedule Value')
      sens_nighttimevar.setName("sens_nighttimevar_#{OpenstudioStandards::HVAC.ems_friendly_name(air_loop_hvac.name.get.to_s)}")
      sens_nighttimevar.setKeyName(min_oa_flow_sch_nighttime_variability_name)
      li_ems_ref << sens_nighttimevar

      # set sensor for zone exhaust fan
      if zone_fan_exhaust_available
        zone_fan_exhaust_names.each_with_index do |zone_fan_exhaust_name, i|
          sens_zn_ex_fan = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Fan Electricity Rate')
          sens_zn_ex_fan.setName("sens_zn_ex_fan_#{OpenstudioStandards::HVAC.ems_friendly_name(zone_fan_exhaust_name)}")
          sens_zn_ex_fan.setKeyName(zone_fan_exhaust_name)
        end
      end

      # set global variable for debugging
      dummy_debugging = OpenStudio::Model::EnergyManagementSystemGlobalVariable.new(model, "dummy_debugging_#{OpenstudioStandards::HVAC.ems_friendly_name(air_loop_hvac.name.get.to_s)}")
      li_ems_ref << dummy_debugging

      #### Actuators #####
      # set actuator - oa controller air mass flow rate
      act_oa_flow = OpenStudio::Model::EnergyManagementSystemActuator.new(oa_controller,
                                                                          'Outdoor Air Controller',
                                                                          'Air Mass Flow Rate')
      act_oa_flow.setName("act_oa_flow_#{OpenstudioStandards::HVAC.ems_friendly_name(air_loop_hvac.name.get.to_s)}")

      li_ems_act_oa_flow << act_oa_flow

      #### Program #####
      # reset OA to min OA
      # economizer only when (1) economizing is favorable and (2) cooling load is present
      # when not economizing, if controlleroutdoorair min OA is higher than requested OA, then use controlleroutdoorair min OA
      # when not economizing, actuate to min OA only when nighttime var sch is non-zero
      # if there is any zone level exhaust fan, change "cooling load" variable to exhaust fan power
      # dummy_debugging parameter: 0 = ems not actuated | 1 = ems actuated (i.e., forced to minimum)
      prgrm_econ_override = model.getEnergyManagementSystemTrendVariableByName('econ_override')

      unless prgrm_econ_override.is_initialized
        prgrm_econ_override = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
        prgrm_econ_override.setName("#{OpenstudioStandards::HVAC.ems_friendly_name(air_loop_hvac.name.get.to_s)}_program")
        prgrm_econ_override.addLine("SET #{act_oa_flow.name} = #{act_oa_flow.name}")
        if zone_fan_exhaust_available
          cmd_ex_fan = ''
          zone_fan_exhaust_names.each_with_index do |zone_fan_exhaust_name, i|
            prgrm_econ_override.addLine("SET sens_zn_ex_fan_#{i.to_i} = sens_zn_ex_fan_#{OpenstudioStandards::HVAC.ems_friendly_name(zone_fan_exhaust_name)}")
            if i == 0
              cmd_ex_fan = "SET sens_load_ref = sens_zn_ex_fan_#{i.to_i}"
            else
              cmd_ex_fan += "|| sens_zn_ex_fan_#{i.to_i}"
            end
          end
          prgrm_econ_override.addLine(cmd_ex_fan)
        else
          prgrm_econ_override.addLine("SET sens_load_ref = #{sens_clg_coil_rate.name}")
        end
        prgrm_econ_override.addLine("SET sens_min_oa_rate = #{sens_min_oa_rate.name}")
        prgrm_econ_override.addLine("SET sens_econ_status = #{sens_econ_status.name}")
        prgrm_econ_override.addLine("SET sens_nighttimevar = #{sens_nighttimevar.name}")
        prgrm_econ_override.addLine("SET #{dummy_debugging.name} = #{dummy_debugging.name}")
        prgrm_econ_override.addLine('IF ((sens_econ_status > 0) && (sens_load_ref <= 0))')
        prgrm_econ_override.addLine("IF sens_min_oa_rate > #{min_oa_flow_kg_per_sec}")
        prgrm_econ_override.addLine("SET #{act_oa_flow.name} = sens_min_oa_rate * sens_nighttimevar")
        prgrm_econ_override.addLine('ELSE')
        prgrm_econ_override.addLine("SET #{act_oa_flow.name} = #{min_oa_flow_kg_per_sec} * sens_nighttimevar")
        prgrm_econ_override.addLine('ENDIF')
        prgrm_econ_override.addLine("SET #{dummy_debugging.name} = sens_nighttimevar")
        prgrm_econ_override.addLine('ELSE')
        prgrm_econ_override.addLine("SET #{act_oa_flow.name} = Null")
        prgrm_econ_override.addLine("SET #{dummy_debugging.name} = 0")
        prgrm_econ_override.addLine('ENDIF')
      end
      programs_at_beginning_of_timestep = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
      programs_at_beginning_of_timestep.setName("#{OpenstudioStandards::HVAC.ems_friendly_name(air_loop_hvac.name.get.to_s)}_Programs_At_Beginning_Of_Timestep")
      programs_at_beginning_of_timestep.setCallingPoint('InsideHVACSystemIterationLoop')
      programs_at_beginning_of_timestep.addProgram(prgrm_econ_override)
    end

    # # ----------------------------------------------------
    # # puts("### adding output variables (for debugging)")
    # # ----------------------------------------------------
    # out_vars = [
    #   'Air System Outdoor Air Economizer Status',
    #   'Air System Outdoor Air Flow Fraction',
    #   'Air System Outdoor Air Mass Flow Rate',
    #   'Site Outdoor Air Drybulb Temperature',
    #   'Cooling Coil Total Cooling Rate'
    # ]
    # out_vars.each do |out_var_name|
    #     ov = OpenStudio::Model::OutputVariable.new('ov', model)
    #     ov.setKeyValue('*')
    #     ov.setReportingFrequency('timestep')
    #     ov.setVariableName(out_var_name)
    # end

    # # create OutputEnergyManagementSystem object (a 'unique' object) and configure to allow EMS reporting
    # output_EMS = model.getOutputEnergyManagementSystem
    # output_EMS.setInternalVariableAvailabilityDictionaryReporting('Verbose')
    # output_EMS.setEMSRuntimeLanguageDebugOutputLevel('Verbose')
    # output_EMS.setActuatorAvailabilityDictionaryReporting('Verbose')

    # # make list of available EMS variables
    # ems_output_variable_list = []

    # # li_ems_sens_zn_clg_rate
    # li_ems_clg_coil_rate.each do |sensor|
    #   name = sensor.name
    #   ems_sens_clg_coil_rate = OpenStudio::Model::EnergyManagementSystemOutputVariable.new(model, sensor)
    #   ems_sens_clg_coil_rate.setUpdateFrequency('ZoneTimestep')
    #   ems_sens_clg_coil_rate.setName("#{name}_ems_outvar")
    #   ems_sens_clg_coil_rate.setUnits('W')
    #   ems_output_variable_list << ems_sens_clg_coil_rate.name.to_s
    # end

    # # li_ems_sens_econ_status
    # li_ems_sens_econ_status.each do |sensor|
    #   name = sensor.name
    #   ems_sens_econ_status = OpenStudio::Model::EnergyManagementSystemOutputVariable.new(model, sensor)
    #   ems_sens_econ_status.setUpdateFrequency('Timestep')
    #   ems_sens_econ_status.setName("#{name}_ems_outvar")
    #   # ems_sens_zn_clg_rate.setUnits('C')
    #   ems_output_variable_list << ems_sens_econ_status.name.to_s
    # end

    # # li_ems_sens_min_flow
    # li_ems_sens_min_flow.each do |sensor|
    #   name = sensor.name
    #   ems_sens_min_flow = OpenStudio::Model::EnergyManagementSystemOutputVariable.new(model, sensor)
    #   ems_sens_min_flow.setUpdateFrequency('Timestep')
    #   ems_sens_min_flow.setName("#{name}_ems_outvar")
    #   ems_sens_min_flow.setUnits('kg/s')
    #   ems_output_variable_list << ems_sens_min_flow.name.to_s
    # end

    # # li_ems_act_oa_flow
    # li_ems_act_oa_flow.each do |act|
    #   name = act.name
    #   ems_act_oa_flow = OpenStudio::Model::EnergyManagementSystemOutputVariable.new(model, act)
    #   ems_act_oa_flow.setUpdateFrequency('Timestep')
    #   ems_act_oa_flow.setName("#{name}_ems_outvar")
    #   ems_act_oa_flow.setUnits('kg/s')
    #   ems_output_variable_list << ems_act_oa_flow.name.to_s
    # end

    # # li_ems_ref
    # li_ems_ref.each do |act|
    #   name = act.name
    #   ems_act_oa_flow = OpenStudio::Model::EnergyManagementSystemOutputVariable.new(model, act)
    #   ems_act_oa_flow.setUpdateFrequency('Timestep')
    #   ems_act_oa_flow.setName("#{name}_ems_outvar")
    #   ems_output_variable_list << ems_act_oa_flow.name.to_s
    # end

    # # iterate list to call output variables
    # ems_output_variable_list.each do |variable|
    #   output = OpenStudio::Model::OutputVariable.new(variable,model)
    #   output.setKeyValue("*")
    #   output.setReportingFrequency('Timestep')
    # end

    # ----------------------------------------------------
    # puts("### report final condition")
    # ----------------------------------------------------
    # report final condition of model
    runner.registerFinalCondition("Added #{added_economizers} to the model.")

    return true
  end
end

# register the measure to be used by the application
HVACEconomizer.new.registerWithApplication
