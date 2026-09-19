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
class HVACExhaustAirEnergyOrHeatRecovery < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    return 'HVAC Exhaust Air Energy or Heat Recovery'
  end

  # human readable description
  def description
    return 'Adds a heat recovery system to all air loops.  Does not replace or update efficiencies for exisiting heat recovery systems. Excludes food service building types.'
  end

  # human readable description of modeling approach
  def modeler_description
    return "Heat/energy recovery added based on climate zone. Energy recovery added to ASHRAE 'humid' climates, heat recovery added to all others. Effectivness is based on Ventacity system. Additional fan static pressure is added as wheel power to capture impact of bypass."
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # build standard to access methods
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)

    # applicability
    building_types_to_exclude = [
      # 'Rtl',
      # 'Rt3',
      # 'RtS',
      'RFF',
      'RSD',
      # 'RetailStandalone',
      # 'RetailStripmall',
      'QuickServiceRestaurant',
      'FullServiceRestaurant'
    ]
    thermal_zone_names_to_exclude = [
      'Kitchen',
      'kitchen',
      'KITCHEN',
      'Dining',
      'dining',
      'DINING'
    ]

    # check building-type applicability
    building_types_to_exclude = building_types_to_exclude.map(&:downcase)
    model_building_type = nil
    if model.getBuilding.standardsBuildingType.is_initialized
      model_building_type = model.getBuilding.standardsBuildingType.get
    else
      runner.registerError('Building type not found.')
      return true
    end
    if building_types_to_exclude.include?(model_building_type.downcase)
      runner.registerAsNotApplicable("Building type '#{model_building_type}' is not applicable to this measure.")
      return true
    end

    # check
    applicable_air_loops = []
    no_oa_air_loops = 0
    na_space_type_air_loops = 0
    hx_initial = 0
    run_sizing = false
    model.getAirLoopHVACs.each do |air_loop_hvac|
      # check for outdoor air
      oa_sys = air_loop_hvac.airLoopHVACOutdoorAirSystem
      no_oa_air_loops += 1 unless oa_sys.is_initialized
      next unless oa_sys.is_initialized

      # check to see if HX already exists
      has_hx = std.air_loop_hvac_energy_recovery?(air_loop_hvac)
      hx_initial += 1 if has_hx
      # check to see if airloop includes only non applicable thermal zones
      airloop_applicable_thermal_zones = []
      air_loop_hvac.thermalZones.each do |thermal_zone|
        if thermal_zone_names_to_exclude.none? { |word| thermal_zone.name.to_s.include?(word) }
          airloop_applicable_thermal_zones << thermal_zone
        end
      end
      (na_space_type_air_loops += 1) if airloop_applicable_thermal_zones.empty?
      next if airloop_applicable_thermal_zones.empty?
      # skip airloop if HX already exists
      next if has_hx

      # skip if evaporative cooling
      evap = false
      air_loop_hvac.supplyComponents.each do |comp|
        next unless comp.to_EvaporativeCoolerDirectResearchSpecial.is_initialized || comp.to_EvaporativeCoolerIndirectResearchSpecial.is_initialized

        evap = true
      end
      next if evap == true

      # add airloop to applicable list
      applicable_air_loops << air_loop_hvac
      # run sizing if any airloop does not have sizing data
      next if run_sizing

      oa_sys = oa_sys.get
      oa_controller = oa_sys.getControllerOutdoorAir
      unless oa_controller.maximumOutdoorAirFlowRate.is_initialized && oa_controller.autosizedMaximumOutdoorAirFlowRate.is_initialized
        run_sizing = true
        puts 'Performing sizing run....'
      end
    end

    # report initial condition of model
    runner.registerInitialCondition("The model started with #{model.getAirLoopHVACs.size} air loops, of which #{no_oa_air_loops} have no outdoor air, #{na_space_type_air_loops} have no applicable space types, and #{hx_initial} already have heat exchangers. #{applicable_air_loops.size} air loop(s) are applicable for adding an ERV/HRV.")

    if applicable_air_loops.empty?
      runner.registerAsNotApplicable('Model contains no air loops that have outdoor already but do not already contain a heat exchanger.')
      return true
    end

    if run_sizing
      runner.registerInfo('Air loop outdoor air flow rates not sized. Running sizing run.')
      if std.model_run_sizing_run(model, "#{Dir.pwd}/SizingRun") == false
        runner.registerError('Sizing run failed. See errors in sizing run directory or this measure')
        return false
      end
    end

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

    # apply ERVs to applicable air loops in model
    hx_added = 0
    hx_cfm_added = 0
    fan_power_added = 0
    air_loops_affected = 0
    applicable_air_loops.each do |air_loop_hvac|
      oa_sys = air_loop_hvac.airLoopHVACOutdoorAirSystem
      std.air_loop_hvac_apply_energy_recovery_ventilator(air_loop_hvac, climate_zone)
      hx_added += 1
      # set heat exchanger efficiency levels
      # get outdoor airflow (which is used for sizing)
      oa_sys = oa_sys.get
      oa_controller = oa_sys.getControllerOutdoorAir
      oa_sys_sizing = air_loop_hvac.sizingSystem
      oa_flow_m3_per_s = nil
      # get design outdoor air flow rate
      # this is used to estimate wheel "fan" power
      # loop through thermal zones
      oa_flow_m3_per_s = 0
      air_loop_hvac.thermalZones.each do |thermal_zone|
        space = thermal_zone.spaces[0]

        # get zone area
        fa = thermal_zone.floorArea * thermal_zone.multiplier

        # get zone volume
        vol = thermal_zone.airVolume * thermal_zone.multiplier

        # get zone design people
        num_people = thermal_zone.numberOfPeople * thermal_zone.multiplier

        if space.designSpecificationOutdoorAir.is_initialized
          dsn_spec_oa = space.designSpecificationOutdoorAir.get

          # add floor area component
          oa_area = dsn_spec_oa.outdoorAirFlowperFloorArea
          oa_flow_m3_per_s += oa_area * fa

          # add per person component
          oa_person = dsn_spec_oa.outdoorAirFlowperPerson
          oa_flow_m3_per_s += oa_person * num_people

          # add air change component
          oa_ach = dsn_spec_oa.outdoorAirFlowAirChangesperHour
          oa_flow_m3_per_s += (oa_ach * vol) / 60
        end
      end
      hx_cfm_added += OpenStudio.convert(oa_flow_m3_per_s, 'm^3/s', 'cfm').get

      # get HX object and set efficiency and controls
      oa_sys.oaComponents.each do |oa_comp|
        if oa_comp.to_HeatExchangerAirToAirSensibleAndLatent.is_initialized
          hx = oa_comp.to_HeatExchangerAirToAirSensibleAndLatent.get
          # set controls
          hx.setSupplyAirOutletTemperatureControl(true)
          hx.setFrostControlType('MinimumExhaustTemperature')
          hx.setThresholdTemperature(1.66667) # 35F, from E+ recommendation
          hx.setHeatExchangerType('Rotary') # rotary is used for fan power modulation when bypass is active. Only affects supply temp control with bypass.
          # add setpoint manager to control recovery
          # Add a setpoint manager OA pretreat to control the ERV
          spm_oa_pretreat = OpenStudio::Model::SetpointManagerOutdoorAirPretreat.new(air_loop_hvac.model)
          spm_oa_pretreat.setMinimumSetpointTemperature(-99.0)
          spm_oa_pretreat.setMaximumSetpointTemperature(99.0)
          spm_oa_pretreat.setMinimumSetpointHumidityRatio(0.00001)
          spm_oa_pretreat.setMaximumSetpointHumidityRatio(1.0)
          # Reference setpoint node and mixed air stream node are outlet node of the OA system
          mixed_air_node = oa_sys.mixedAirModelObject.get.to_Node.get
          spm_oa_pretreat.setReferenceSetpointNode(mixed_air_node)
          spm_oa_pretreat.setMixedAirStreamNode(mixed_air_node)
          # Outdoor air node is the outboard OA node of the OA system
          spm_oa_pretreat.setOutdoorAirStreamNode(oa_sys.outboardOANode.get)
          # Return air node is the inlet node of the OA system
          return_air_node = oa_sys.returnAirModelObject.get.to_Node.get
          spm_oa_pretreat.setReturnAirStreamNode(return_air_node)
          # Attach to the outlet of the HX
          hx_outlet = hx.primaryAirOutletModelObject.get.to_Node.get
          spm_oa_pretreat.addToNode(hx_outlet)

          case doas_type
          when 'ERV'
            # set parameters for ERV
            # set efficiencies; assumed 90% airflow returned to unit
            hx.setSensibleEffectivenessat100HeatingAirFlow(0.75 * 0.90)
            hx.setSensibleEffectivenessat75HeatingAirFlow(0.78 * 0.90)
            hx.setLatentEffectivenessat100HeatingAirFlow(0.61 * 0.90)
            hx.setLatentEffectivenessat75HeatingAirFlow(0.68 * 0.90)
            hx.setSensibleEffectivenessat100CoolingAirFlow(0.75 * 0.90)
            hx.setSensibleEffectivenessat75CoolingAirFlow(0.78 * 0.90)
            hx.setLatentEffectivenessat100CoolingAirFlow(0.55 * 0.90)
            hx.setLatentEffectivenessat75CoolingAirFlow(0.60 * 0.90)
          when 'HRV'
            # set parameters for HRV
            # set efficiencies; assumed 90% airflow returned to unit
            hx.setSensibleEffectivenessat100HeatingAirFlow(0.84 * 0.90)
            hx.setSensibleEffectivenessat75HeatingAirFlow(0.86 * 0.90)
            hx.setLatentEffectivenessat100HeatingAirFlow(0)
            hx.setLatentEffectivenessat75HeatingAirFlow(0)
            hx.setSensibleEffectivenessat100CoolingAirFlow(0.83 * 0.90)
            hx.setSensibleEffectivenessat75CoolingAirFlow(0.84 * 0.90)
            hx.setLatentEffectivenessat100CoolingAirFlow(0)
            hx.setLatentEffectivenessat75CoolingAirFlow(0)
          end

          # fan efficiency ranges from 40-60% (Energy Modeling Guide for Very High Efficiency DOAS Final Report)
          default_fan_efficiency = 0.55
          power = (oa_flow_m3_per_s * 174.188 / default_fan_efficiency) + ((oa_flow_m3_per_s * 0.9 * 124.42) / default_fan_efficiency)
          fan_power_added += power
          hx.setNominalElectricPower(power)
        end
      end
      air_loops_affected += 1
    end

    # report final condition of model
    runner.registerValue('hvac_number_of_loops_affected', air_loops_affected)
    runner.registerFinalCondition("Added #{hx_added} heat exchangers to air loops with #{hx_cfm_added.round(1)} total cfm and #{fan_power_added.round} watts added as rotary wheel power to account for added static pressure. The ASHRAE climate zone of the model is #{climate_zone_classification}, so an #{doas_type} is the recovery type added to applicable air loops.")

    return true
  end
end

# register the measure to be used by the application
HVACExhaustAirEnergyOrHeatRecovery.new.registerWithApplication
