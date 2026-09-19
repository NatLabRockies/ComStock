# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.


# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/
require 'comstock-typical'

# start the measure
class HvacDoasHpMinisplits < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    return "hvac_doas_hp_minisplits"
  end

  # human readable description
  def description
    return "TODO"
  end

  # human readable description of modeling approach
  def modeler_description
    return "TODO"
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # make argument for area maximum
    area_limit_sf = OpenStudio::Measure::OSArgument.makeDoubleArgument('area_limit_sf', true)
    area_limit_sf.setDefaultValue('20000')
    area_limit_sf.setDisplayName('Building Maximum Area for Applicability, SF')
    area_limit_sf.setDescription('Maximum building size for applicability of measure. Mini-split heat pumps are often only appropriate for small commerical applications, so it is recommended to keep this value under 20,000sf.')
    args << area_limit_sf

    # make list of backup heat options
    li_doas_heat_options = ["gas_furnace", "electric_resistance"]
    v_doas_heat_options = OpenStudio::StringVector.new
    li_doas_heat_options.each do |option|
      v_doas_heat_options << option
    end
    # add backup heat option arguments
    doas_htg_fuel = OpenStudio::Measure::OSArgument.makeChoiceArgument('doas_htg_fuel', v_doas_heat_options, true)
    doas_htg_fuel.setDisplayName('DOAS Heating Fuel Source')
    doas_htg_fuel.setDescription('Heating fuel source for DOAS, either gas furnace or electric resistance. DOAS will provide minimal preheating to provide reasonable nuetral air supplied to zone. The ERV/HRV will first try to accomodate this, with the heating coil addressing any additional load. Note that the zone heat pumps are still responsible for maintaining thermostat setpoints.')
    doas_htg_fuel.setDefaultValue("electric_resistance")
    args << doas_htg_fuel

    # add RTU oversizing factor for heating
    performance_oversizing_factor = OpenStudio::Measure::OSArgument.makeDoubleArgument('performance_oversizing_factor', true)
    performance_oversizing_factor.setDisplayName('Maximum Performance Oversizing Factor')
    performance_oversizing_factor.setDefaultValue(0.35)
    performance_oversizing_factor.setDescription('When heating design load exceeds cooling design load, the design cooling capacity of the unit will only be allowed to increase up to this factor to accomodate additional heating capacity. Oversizing the compressor beyond 25% can cause cooling cycling issues, even with variable speed compressors. Set this value to 10 if you do not want a limit placed on oversizing, noting that backup heat may still occur if the design temperature is below the compressor cutoff temperature of -15F.')
    args << performance_oversizing_factor

    return args
  end

  # define the outputs that the measure will create
  def outputs

    # outs = OpenStudio::Measure::OSOutputVector.new
    output_names = []

    result = OpenStudio::Measure::OSOutputVector.new
    output_names.each do |output|
      result << OpenStudio::Measure::OSOutput.makeDoubleOutput(output)
    end

    return result
  end

  #### Predefined functions
  # determine if the air loop is residential (checks to see if there is outdoor air system object)
  def air_loop_res?(air_loop_hvac)
    is_res_system = true
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_AirLoopHVAC_OutdoorAirSystem'
        is_res_system = false
      end
    end
    return is_res_system
  end

  # Determine if is evaporative cooler
  def air_loop_evaporative_cooler?(air_loop_hvac)
    is_evap = false
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_EvaporativeCooler_Direct_ResearchSpecial', 'OS_EvaporativeCooler_Indirect_ResearchSpecial', 'OS_EvaporativeFluidCooler_SingleSpeed', 'OS_EvaporativeFluidCooler_TwoSpeed'
        is_evap = true
      end
    end
    return is_evap
  end

  # Determine if the air loop is a unitary system
  # @return [Bool] Returns true if a unitary system is present, false if not.
  def air_loop_hvac_unitary_system?(air_loop_hvac)
    is_unitary_system = false
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_AirLoopHVAC_UnitarySystem', 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir', 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir_MultiSpeed', 'OS_AirLoopHVAC_UnitaryHeatCool_VAVChangeoverBypass'
        is_unitary_system = true
      end
    end
    return is_unitary_system
  end
  #### End predefined functions

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # assign the user inputs to variables
    # backup_ht_scheme = runner.getStringArgumentValue('backup_ht_scheme', user_arguments)
    area_limit_sf = runner.getDoubleArgumentValue('area_limit_sf', user_arguments)
    doas_htg_fuel = runner.getStringArgumentValue('doas_htg_fuel', user_arguments)
    performance_oversizing_factor = runner.getDoubleArgumentValue('performance_oversizing_factor', user_arguments)

    # convert area limit
    area_limit_m2 = OpenStudio.convert(area_limit_sf, 'ft^2', 'm^2').get

    # build standard to use OS standards methods
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)
    # get climate full string and classification (i.e. "5A")
    climate_zone = OpenstudioStandards::Weather.model_get_climate_zone(model)
    climate_zone_classification = climate_zone.split('-')[-1]


    # DOAS temperature supply settings - colder cooling discharge air for humid climates
    doas_dat_clg_c=nil
    doas_dat_htg_c=nil
    doas_type=nil
    doas_includes_clg=nil
    if ['1A', '2A', '3A', '4A', '5A', '6A', '7', '7A', '8', '8A'].any? { |word| (climate_zone_classification).include?(word) }
      doas_dat_clg_c = 12.7778
      doas_dat_htg_c = 19.4444
      doas_type = 'ERV'
      doas_includes_clg=true
    else
      doas_dat_clg_c = 15.5556
      doas_dat_htg_c = 19.4444
      doas_type = 'HRV'
      doas_includes_clg=false
    end

    # heat pump discharge air temperatures
    hp_dat_htg = 40.5556
    hp_dat_clg = 12.7778

    # get applicable psz hvac air loops
    selected_air_loops = []
    applicable_area_m2 = 0
    total_area_m2 = 0
    prim_ht_fuel_type = 'electric' # we assume electric unless we find a gas coil in any air loop
    model.getAirLoopHVACs.each do |air_loop_hvac|
      # skip units that are not single zone
      next if air_loop_hvac.thermalZones.length > 1

      # add area
      thermal_zone = air_loop_hvac.thermalZones[0]
      total_area_m2 += thermal_zone.floorArea * thermal_zone.multiplier
      # skip DOAS units; check sizing for all OA and for DOAS in name
      sizing_system = air_loop_hvac.sizingSystem
      next if sizing_system.allOutdoorAirinCooling && sizing_system.allOutdoorAirinHeating && (air_loop_res?(air_loop_hvac) == false) && (air_loop_hvac.name.to_s.include?("DOAS") || air_loop_hvac.name.to_s.include?("doas"))
      # skip if already heat pump RTU
      # loop throug air loop components to check for heat pump or water coils
      is_hp=false
      is_water_coil=false
      has_heating_coil=true
      air_loop_hvac.supplyComponents.each do |component|
        obj_type = component.iddObjectType.valueName.to_s
        # flag system if contains water coil; this will cause air loop to be skipped
        is_water_coil=true if ['Coil_Heating_Water', 'Coil_Cooling_Water'].any? { |word| (obj_type).include?(word) }
        # flag gas heating as true if gas coil is found in any airloop
        prim_ht_fuel_type= 'gas' if ['Gas', 'GAS', 'gas'].any? { |word| (obj_type).include?(word) }
        # check unitary systems for DX heating or water coils
        if  obj_type=='OS_AirLoopHVAC_UnitarySystem'
          unitary_sys = component.to_AirLoopHVACUnitarySystem.get

          # check if heating coil is DX or water-based; if so, flag the air loop to be skipped
          if unitary_sys.heatingCoil.is_initialized
            htg_coil = unitary_sys.heatingCoil.get.iddObjectType.valueName.to_s
            # check for DX heating coil
            if ['Heating_DX'].any? { |word| (htg_coil).include?(word) }
              is_hp=true
            # check for water heating coil
            elsif ['Water'].any? { |word| (htg_coil).include?(word) }
              is_water_coil=true
            # check for gas heating
            elsif ['Gas', 'GAS', 'gas'].any? { |word| (htg_coil).include?(word) }
              prim_ht_fuel_type='gas'
            end
          else
            runner.registerWarning("No heating coil was found for air loop: #{air_loop_hvac.name} - this equipment will be skipped.")
            has_heating_coil = false
          end
          # check if cooling coil is water-based
          if unitary_sys.coolingCoil.is_initialized
            clg_coil = unitary_sys.coolingCoil.get.iddObjectType.valueName.to_s
            # skip unless coil is water based
            next unless ['Water'].any? { |word| (clg_coil).include?(word) }
            is_water_coil=true
          end
        # flag as hp if air loop contains a heating dx coil
        elsif ['Heating_DX'].any? { |word| (obj_type).include?(word) }
          is_hp=true
        end
      end
      # also skip based on string match, or if dx heating component existed
      next if (is_hp==true) | (((air_loop_hvac.name.to_s.include?("HP")) || (air_loop_hvac.name.to_s.include?("hp")) || (air_loop_hvac.name.to_s.include?("heat pump")) || (air_loop_hvac.name.to_s.include?("Heat Pump"))))
      # skip data centers
      next if ['Data Center', 'DataCenter', 'data center', 'datacenter', 'DATACENTER', 'DATA CENTER'].any? { |word| (air_loop_hvac.name.get).include?(word) }
      # skip kitchens
      next if ['Kitchen', 'KITCHEN', 'Kitchen'].any? { |word| (air_loop_hvac.name.get).include?(word) }
      # skip VAV sysems
      next if ['VAV', 'PVAV'].any? { |word| (air_loop_hvac.name.get).include?(word) }
      # skip if residential system
      next if air_loop_res?(air_loop_hvac)
      # skip if system has no outdoor air, also indication of residential system
      next unless air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized
      # skip if evaporative cooling systems
      next if air_loop_evaporative_cooler?(air_loop_hvac)
      # skip if water heating or cooled system
      next if is_water_coil==true
      # skip if space is not heated and cooled
      next unless (OpenstudioStandards::ThermalZone.thermal_zone_heated?(air_loop_hvac.thermalZones[0])) && (OpenstudioStandards::ThermalZone.thermal_zone_cooled?(air_loop_hvac.thermalZones[0]))
      # next if no heating coil
      next if has_heating_coil == false
      # add applicable air loop to list
      selected_air_loops << air_loop_hvac
      # add area served by air loop
      thermal_zone = air_loop_hvac.thermalZones[0]
      applicable_area_m2 += thermal_zone.floorArea * thermal_zone.multiplier
    end

    # fraction of conditioned floorspace
    if total_area_m2 >0
      applicable_floorspace_frac = applicable_area_m2 / total_area_m2
    else
      applicable_floorspace_frac = 0
    end

    # convert total area
    total_area_ft2 = OpenStudio.convert(total_area_m2, 'm^2', 'ft^2').get

    # check if any air loops are applicable to measure
    if (selected_air_loops.empty?)
      runner.registerAsNotApplicable('No applicable air loops in model. No changes will be made.')
      return false
    elsif (applicable_area_m2 > area_limit_m2)
      runner.registerAsNotApplicable("Applicable building area of #{total_area_ft2.round()} exceeds user-defined maximum limit of #{area_limit_sf} square feet. Measure will not be applied.")
      return false
    end

    # report initial condition of model
    runner.registerInitialCondition("The building has #{selected_air_loops.size} applicable air loops that will be replaced with a DOAS-ERV/HRV and heat pump ductless minisplits, representing #{(applicable_floorspace_frac*100).round(2)}% of the building floor area.")


    thermal_zones = []
    # replace existing applicable air loops with new heat pump rtu air loops
    selected_air_loops.sort.each do |air_loop_hvac|

      # first update existing RTU to be DOAS

      # start with unitary systems
      if air_loop_hvac_unitary_system?(air_loop_hvac)

        # loop through air loop supply side components
        air_loop_hvac.supplyComponents.each do |component|

          # convert component to string name
          obj_type = component.iddObjectType.valueName.to_s

          # skip unless component is of relevant type
          next unless ['Fan', 'Unitary', 'Coil'].any? { |word| (obj_type).include?(word) }

          # remove any existing coils or fans
          if ['Fan', 'Coil'].any? { |word| (obj_type).include?(word) }
            model.removeObject(component.handle)
          end

          # get unitary system object
          if component.to_AirLoopHVACUnitarySystem.is_initialized

            # get unitary system object
            unitary_sys = component.to_AirLoopHVACUnitarySystem.get
            # get supply fan - will send error if not onoff, variable, or constant types
            # VAV fans will be replaced with CV fan
            fan_static_pressure = nil
            supply_fan = unitary_sys.supplyFan.get
            if supply_fan.to_FanConstantVolume.is_initialized
              supply_fan = supply_fan.to_FanConstantVolume.get
              fan_static_pressure = supply_fan.pressureRise
            elsif supply_fan.to_FanOnOff.is_initialized
              supply_fan = supply_fan.to_FanOnOff.get
              fan_static_pressure = supply_fan.pressureRise
            elsif supply_fan.to_FanVariableVolume.is_initialized
              # change VAV fan on to onoff for DOAS
              supply_fan = supply_fan.to_FanVariableVolume.get
              # get characteristics of original supply fan for setting new object
              fan_tot_eff = supply_fan.fanTotalEfficiency
              fan_mot_eff = supply_fan.motorEfficiency
              fan_static_pressure = supply_fan.pressureRise
              # make new constant volume (onoff) fan object with original settings
              new_fan = OpenStudio::Model::FanOnOff.new(model,
                                                        model.alwaysOnDiscreteSchedule)
              new_fan.setName("#{air_loop_hvac.name} Constant Volume DOAS Fan")
              new_fan.setFanTotalEfficiency(fan_tot_eff)
              new_fan.setMotorEfficiency(fan_mot_eff)
              new_fan.setPressureRise(fan_static_pressure)
              # set new fan to unitary object
              unitary_sys.setSupplyFan(new_fan)
              supply_fan = new_fan
            else
              runner.registerError("Supply fan type for #{air_loop_hvac.name} not supported.")
              return false
            end

            # delete unitary system
            unitary_sys.remove

            # air loop node
            supply_outlet_node = air_loop_hvac.supplyOutletNode

            # add new cooling coil
            clg_coil = std.create_coil_cooling_dx_single_speed(model,
                        air_loop_node: supply_outlet_node,
                        name: "#{air_loop_hvac.name} 1spd DX AC Clg Coil",
                        type: 'PSZ-AC')

            # add new electric heating coil
            htg_coil = std.create_coil_heating_electric(model,
                        air_loop_node: supply_outlet_node,
                        name: "#{air_loop_hvac.name} Electric Htg Coil")

            # add new fan
            fan = std.create_fan_constant_volume(model,
                        fan_name: "#{air_loop_hvac.name} Constant Volume Supply Fan",
                        pressure_rise: fan_static_pressure)
            fan.addToNode(supply_outlet_node) unless supply_outlet_node.nil?

            # set airloop name
            air_loop_hvac.setName("#{air_loop_hvac.name} DOAS Airloop")
            # change airloop to only cycle zone equipment
            air_loop_hvac.setNightCycleControlType('CycleOnAnyZoneFansOnly')

            # replace DOAS heating heating coil - fuel type based on user input
            if doas_htg_fuel == 'electric_resistance'
              # add new electric resistance heating element
              new_doas_htg_coil = OpenStudio::Model::CoilHeatingElectric.new(model, model.alwaysOnDiscreteSchedule)
              new_doas_htg_coil.setName("#{air_loop_hvac.name} DOAS Electric Heating Coil")
              new_doas_htg_coil.setEfficiency(1)
              unitary_sys.setHeatingCoil(new_doas_htg_coil)
            else
              new_doas_htg_coil = OpenStudio::Model::CoilHeatingGas.new(model, model.alwaysOnDiscreteSchedule)
              new_doas_htg_coil.setName("#{air_loop_hvac.name} DOAS Gas Heating Coil")
              new_doas_htg_coil.setGasBurnerEfficiency(0.80)
              unitary_sys.setHeatingCoil(new_doas_htg_coil)
            end
          end
        end

        # modify airloop sizing settings for DOAS operation
        air_loop_sizing = air_loop_hvac.sizingSystem
        air_loop_sizing.setTypeofLoadtoSizeOn('VentilationRequirement')
        air_loop_sizing.setCentralCoolingDesignSupplyAirTemperature(doas_dat_clg_c) # 67F
        air_loop_sizing.setCentralHeatingDesignSupplyAirTemperature(doas_dat_htg_c) # 52F as per ASHRAE DOAS design guide
        air_loop_sizing.setAllOutdoorAirinCooling(true)
        air_loop_sizing.setAllOutdoorAirinHeating(true)
        #air_loop_sizing.setMinimumSystemAirFlowRatio(1)
        air_loop_sizing.autosizeCoolingDesignCapacity() # for hardsized baseline
        air_loop_sizing.autosizeHeatingDesignCapacity() # for hardsized baseline
        air_loop_sizing.resetDesignOutdoorAirFlowRate() # for hardsized baseline
        air_loop_hvac.autosizeDesignSupplyAirFlowRate() # for hardsized baseline

        # modify zone sizing settings for DOAS operation
        zone_sizing = air_loop_hvac.thermalZones[0].sizingZone
        zone_sizing.setAccountforDedicatedOutdoorAirSystem(true)
        zone_sizing.setZoneCoolingDesignSupplyAirTemperatureInputMethod('SupplyAirTemperature')
        zone_sizing.setZoneCoolingDesignSupplyAirTemperature(hp_dat_clg)
        zone_sizing.setZoneHeatingDesignSupplyAirTemperatureInputMethod('SupplyAirTemperature')
        zone_sizing.setZoneHeatingDesignSupplyAirTemperature(hp_dat_htg)
        zone_sizing.setCoolingMinimumAirFlowFraction(1)
        zone_sizing.setDedicatedOutdoorAirSystemControlStrategy('NeutralSupplyAir')
        zone_sizing.setDedicatedOutdoorAirLowSetpointTemperatureforDesign(doas_dat_clg_c)
        zone_sizing.setDedicatedOutdoorAirHighSetpointTemperatureforDesign(doas_dat_htg_c)

        # create new outdoor air reset setpoint manager
        oar_stpt_manager = OpenStudio::Model::SetpointManagerOutdoorAirReset.new(model)
        oar_stpt_manager.setName("#{air_loop_hvac.name} DOAS Outdoor Air Reset Manager")
        oar_stpt_manager.addToNode(air_loop_hvac.supplyOutletNode)
        oar_stpt_manager.setControlVariable('Temperature')
        oar_stpt_manager.setOutdoorHighTemperature(21.1111)
        oar_stpt_manager.setOutdoorLowTemperature(15.5556)
        oar_stpt_manager.setSetpointatOutdoorHighTemperature(doas_dat_clg_c)
        oar_stpt_manager.setSetpointatOutdoorLowTemperature(doas_dat_htg_c)

        # get thermal zone
        thermal_zone = air_loop_hvac.thermalZones[0]

        # get old terminal box - ensure autosized flow rate
        if thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeNoReheat.is_initialized
          old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeNoReheat.get
          old_terminal.autosizeMaximumAirFlowRate()
        else
          runner.registerError("Terminal box type for air loop #{air_loop_hvac.name} not supported.")
          return false
        end

        # Energy recovery
        # add ERV or HRV, based on climate zone
        # check for ERV, and get components
        # ERV components will be removed and replaced if ERV flag was selected
        # If ERV flag was not selected, ERV equipment will remain in place as-is
        erv_components = []
        air_loop_hvac.oaComponents.each do |component|
            component_name = component.name.to_s
            next if component_name.include? "Node"
            if component_name.include? "ERV"
              erv_components << component
              erv_components = erv_components.uniq
            end
          end
        # # if there was not previosuly an ERV, add 0.5" (124.42 pascals) static to supply fan
        # new_fan.setPressureRise(fan_static_pressure + 124.42) if erv_components.empty?
        # remove existing ERV; these will be replaced with new ERV equipment
        erv_components.each(&:remove)
        # get oa system
        oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
        # add new HR system
        new_hr = OpenStudio::Model::HeatExchangerAirToAirSensibleAndLatent.new(model)
        # update parameters
        new_hr.addToNode(oa_system.outboardOANode.get)
        new_hr.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
        new_hr.setEconomizerLockout(true)
        new_hr.setFrostControlType('ExhaustOnly')
        new_hr.setThresholdTemperature(0) # 32F, from Daikin
        new_hr.setInitialDefrostTimeFraction(0.083) # 5 minutes every 60 minutes, from Daikin
        new_hr.setRateofDefrostTimeFractionIncrease(0.024) # from E+ recommended values
        new_hr.setName("#{air_loop_hvac.name} ERV")
        new_hr.setSupplyAirOutletTemperatureControl(true)
        # efficiencies and parameters based on recovery type
        if doas_type == 'HRV'
          # set efficiencies;
          new_hr.setHeatExchangerType('Plate')
          new_hr.setSensibleEffectivenessat100HeatingAirFlow(0.82)
          new_hr.setSensibleEffectivenessat75HeatingAirFlow(0.82)
          new_hr.setLatentEffectivenessat100HeatingAirFlow(0.001)
          new_hr.setLatentEffectivenessat75HeatingAirFlow(0.001)
          new_hr.setSensibleEffectivenessat100CoolingAirFlow(0.82)
          new_hr.setSensibleEffectivenessat75CoolingAirFlow(0.82)
          new_hr.setLatentEffectivenessat100CoolingAirFlow(0.001)
          new_hr.setLatentEffectivenessat75CoolingAirFlow(0.001)
        else
          # set efficiencies;
          # From p.96 of https://www.pnnl.gov/main/publications/external/technical_reports/PNNL-20405.pdf
          new_hr.setHeatExchangerType('Rotary')
          new_hr.setSupplyAirOutletTemperatureControl(true)
          new_hr.setSensibleEffectivenessat100HeatingAirFlow(0.78)
          new_hr.setSensibleEffectivenessat75HeatingAirFlow(0.78)
          new_hr.setLatentEffectivenessat100HeatingAirFlow(0.65)
          new_hr.setLatentEffectivenessat75HeatingAirFlow(0.65)
          new_hr.setSensibleEffectivenessat100CoolingAirFlow(0.78)
          new_hr.setSensibleEffectivenessat75CoolingAirFlow(0.78)
          new_hr.setLatentEffectivenessat100CoolingAirFlow(0.65)
          new_hr.setLatentEffectivenessat75CoolingAirFlow(0.65)
        end

        # modify outdoor air object for 100% outdoor air operation
        oa_controller= oa_system.getControllerOutdoorAir
        oa_controller.setMinimumFractionofOutdoorAirSchedule(model.alwaysOnDiscreteSchedule)
        oa_controller.resetMaximumFractionofOutdoorAirSchedule
        # remove economizer - not applicable with DOAS
        oa_controller.setEconomizerControlType('NoEconomizer')
        # remove demand control ventilation - not applicable with DOAS
        mech_vent = oa_controller.controllerMechanicalVentilation
        mech_vent.setDemandControlledVentilation(false)

        # add new unitary system to thermal zone
        # zone equipment set to sequence 2 as per EnergyPlus I/O:
        # For example, with a dedicated outdoor air system (DOAS), the air terminal for the
        # DOAS should be assigned Heating Sequence = 1 and Cooling Sequence = 1. Any other equipment should be
        # assigned sequence 2 or higher so that it will see the net load after the DOAS air is added to the zone.
        zone_unitary_hvac = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
        zone_unitary_hvac.setName("#{air_loop_hvac.name} Zone Mini Split Heat Pump")
        thermal_zones << thermal_zone
        zone_unitary_hvac.addToThermalZone(thermal_zone)
        thermal_zone.setCoolingPriority(zone_unitary_hvac.to_ModelObject.get, 1)
        thermal_zone.setHeatingPriority(zone_unitary_hvac.to_ModelObject.get, 1)

        # add base unitary system properties
        zone_unitary_hvac.setControlType('Load')
        zone_unitary_hvac.setControllingZoneorThermostatLocation(thermal_zone)
        zone_unitary_hvac.setDehumidificationControlType("None")
        zone_unitary_hvac.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)

        # add supply fan
        new_fan = OpenStudio::Model::FanVariableVolume.new(model, model.alwaysOnDiscreteSchedule)
        new_fan.setName("#{air_loop_hvac.name} VFD Fan")
        new_fan.setFanTotalEfficiency(0.75) # ResStock E+ file
        new_fan.setMotorEfficiency(1) # ResStock E+ file
        new_fan.setFanPowerCoefficient1(0.242469) # from Daikin Rebel E+ file
        new_fan.setFanPowerCoefficient2(-1.46455)
        new_fan.setFanPowerCoefficient3(4.496391)
        new_fan.setFanPowerCoefficient4(-3.6426)
        new_fan.setFanPowerCoefficient5(1.301203)
        new_fan.setFanPowerMinimumFlowRateInputMethod("Fraction")
        new_fan.setName("#{air_loop_hvac.name} Zone Mini Split Heat Pump Supply Fan")
        zone_unitary_hvac.setSupplyFan(new_fan)
        zone_unitary_hvac.setFanPlacement('BlowThrough')
        zone_unitary_hvac.setSupplyAirFanOperatingModeSchedule(model.alwaysOffDiscreteSchedule) # for cycling
        zone_unitary_hvac.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(0)

        # add cooling coil properties
        dmy_clg_coil = OpenStudio::Model::CoilCoolingDXSingleSpeed.new(model)
        zone_unitary_hvac.setCoolingCoil(dmy_clg_coil)
        zone_unitary_hvac.setUseDOASDXCoolingCoil(false)
        zone_unitary_hvac.setDOASDXCoolingCoilLeavingMinimumAirTemperature(7.5)
        zone_unitary_hvac.setLatentLoadControl('SensibleOnlyLoadControl')

        # add heating coil properties
        dmy_htg_coil = OpenStudio::Model::CoilHeatingElectric.new(model)
        dmy_htg_coil.setName("#{zone_unitary_hvac.name} Dummy Electric Htg Coil")
        zone_unitary_hvac.setHeatingCoil(dmy_htg_coil)
        zone_unitary_hvac.setDXHeatingCoilSizingRatio(1)
        zone_unitary_hvac.setMaximumSupplyAirTemperature(40.5556)

        # add supplementery heating coil properties
        supp_htg_coil = OpenStudio::Model::CoilHeatingElectric.new(model)
        supp_htg_coil.setName("#{zone_unitary_hvac.name} Electric Backup Htg Coil")
        zone_unitary_hvac.setSupplementalHeatingCoil(supp_htg_coil)
        zone_unitary_hvac.setMaximumOutdoorDryBulbTemperatureforSupplementalHeaterOperation(25)

        # remove air loop from model and list if OA is below threshold limit
        # this will be relevant for some very small zones or zones with no design OA
        # get design OA object
        space = thermal_zone.spaces[0]

        # get zone area
        fa = thermal_zone.floorArea * thermal_zone.multiplier

        # get zone volume
        vol = thermal_zone.airVolume * thermal_zone.multiplier

        # get zone design people
        num_people = thermal_zone.numberOfPeople * thermal_zone.multiplier

        dsn_oa_m3_per_s= 0
        if space.designSpecificationOutdoorAir.is_initialized
          dsn_spec_oa = space.designSpecificationOutdoorAir.get

          # add floor area component
          oa_area = dsn_spec_oa.outdoorAirFlowperFloorArea
          dsn_oa_m3_per_s = oa_area * fa

          # add per person component
          oa_person = dsn_spec_oa.outdoorAirFlowperPerson
          dsn_oa_m3_per_s += oa_person * num_people

          # add air change component
          oa_ach = dsn_spec_oa.outdoorAirFlowAirChangesperHour
          dsn_oa_m3_per_s += (oa_ach * vol) / 60
        end
        # delete air loop if less than minimum flow rate
        next unless dsn_oa_m3_per_s < 1.0000E-003
        runner.registerWarning("#{air_loop_hvac.name} has an outdoor air flow rate of #{dsn_oa_m3_per_s.round(3)} m3/s which is less than the required 0.001 m3/s. This DOAS will be deleted, but these zone equipment will remain.")
        selected_air_loops.delete(air_loop_hvac)
        air_loop_hvac.remove
      end
    end


    # perform sizing run to get sizing values
    if std.model_run_sizing_run(model, "#{Dir.pwd}/SR_HP") == false
      return false
    end

    # loop through airloops to set multispeed coil objects and other parameters that require sizing values
    selected_air_loops.sort.each do |air_loop_hvac|

      # set DOAS wheel power
      # get DOAS outdoor air flow rate; this will be used to set heat recovery wheel power
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      controller_oa = oa_system.getControllerOutdoorAir
      doas_oa_flow_m3_per_s = nil
      if controller_oa.minimumOutdoorAirFlowRate.is_initialized
        doas_oa_flow_m3_per_s = controller_oa.minimumOutdoorAirFlowRate.get
      elsif controller_oa.autosizedMinimumOutdoorAirFlowRate.is_initialized
        doas_oa_flow_m3_per_s = controller_oa.autosizedMinimumOutdoorAirFlowRate.get
      else
        runner.registerError("No outdoor air sizing information was found for #{controller_oa.name}, which is required for setting ERV wheel power consumption.")
        return false
      end

      # apply wheel power to DOAS HRV/ERV system using sized DOAS OA values
      erv_components = []
      air_loop_hvac.oaComponents.each do |component|
        component_name = component.name.to_s
        next if component_name.include? "Node"
        if ['ERV', 'HRV'].any? { |word| (component_name).include?(word) }
          new_hr = component.to_HeatExchangerAirToAirSensibleAndLatent.get
          # for HRV systems
          if doas_type == 'HRV'
            # add 0.5 inches total static pressure
            # From p.96 of https://www.pnnl.gov/main/publications/external/technical_reports/PNNL-20405.pdf
            default_fan_efficiency = 0.55
            power = (doas_oa_flow_m3_per_s * 62.21 / default_fan_efficiency) + (doas_oa_flow_m3_per_s * 0.9 * 62.21 / default_fan_efficiency)
            new_hr.setNominalElectricPower(power)
          else
            # add 0.65 inches static pressure to both supply and return
            # From p.96 of https://www.pnnl.gov/main/publications/external/technical_reports/PNNL-20405.pdf
            default_fan_efficiency = 0.55
            power = (doas_oa_flow_m3_per_s * 212.5 / default_fan_efficiency) + (doas_oa_flow_m3_per_s * 0.9 * 162.5 / default_fan_efficiency) + 50
            new_hr.setNominalElectricPower(power)
          end
        end
      end

      # set DOAS fan and DX cooling coil to code standards
      air_loop_hvac.supplyComponents.each do |component|
        if component.to_CoilCoolingDXSingleSpeed.is_initialized
          doas_clg_coil = component.to_CoilCoolingDXSingleSpeed.get
          std.coil_cooling_dx_single_speed_apply_efficiency_and_curves(doas_clg_coil, {})
        elsif component.to_FanOnOff.is_initialized
          doas_sf = component.to_FanOnOff.get
          std.prototype_fan_apply_prototype_fan_efficiency(doas_sf)
        elsif component.to_FanConstantVolume.is_initialized
          doas_sf = component.to_FanConstantVolume.get
          std.prototype_fan_apply_prototype_fan_efficiency(doas_sf)
        end
      end
    end

    # loop through thermal zones for zone equipment
    thermal_zones.each do |thermal_zone|
      # get zone unitary system in thermal zone equipment
      unitary_sys=nil
      # thermal_zone = air_loop_hvac.thermalZones[0]
      thermal_zone.equipment.each do |zone_equipment|
        # skip zone equipment that's not unitary HVAC system
        next unless zone_equipment.to_AirLoopHVACUnitarySystem.is_initialized
        unitary_sys = zone_equipment.to_AirLoopHVACUnitarySystem.get
      end

      # get design airflow of zone unitary system object
      dsn_clg_airflow=nil
      dsn_htg_airflow=nil
      # get cooling airflow
      if unitary_sys.autosizedSupplyAirFlowRateDuringCoolingOperation.is_initialized
        dsn_clg_airflow=unitary_sys.autosizedSupplyAirFlowRateDuringCoolingOperation.get
      elsif unitary_sys.supplyAirFlowRateDuringCoolingOperation.is_initialized
        dsn_clg_airflow=unitary_sys.supplyAirFlowRateDuringCoolingOperation.get
      else
        runner.registerError("Unitary system cooling airflow rates not found for #{unitary_sys}")
        return false
      end
      # get heating airflow
      if unitary_sys.autosizedSupplyAirFlowRateDuringHeatingOperation.is_initialized
        dsn_htg_airflow=unitary_sys.autosizedSupplyAirFlowRateDuringHeatingOperation.get
      elsif unitary_sys.supplyAirFlowRateDuringHeatingOperation.is_initialized
        dsn_htg_airflow=unitary_sys.supplyAirFlowRateDuringHeatingOperation.get
      else
        runner.registerError("Unitary system heating airflow rates not found for #{unitary_sys}")
        return false
      end

      # design airflow will be max of heating and cooling airflows
      dsn_airflow = [dsn_clg_airflow, dsn_htg_airflow].max()

      # get design cooling and heating load of zone unitary system; this will set multispeed coil stage parameters
      dsn_clg_load=nil
      dsn_htg_load=nil
      # for cooling
      dummy_clg_coil= unitary_sys.coolingCoil.get.to_CoilCoolingDXSingleSpeed.get
      if dummy_clg_coil.autosizedRatedTotalCoolingCapacity.is_initialized
        dsn_clg_load = dummy_clg_coil.autosizedRatedTotalCoolingCapacity.get
        model.removeObject(dummy_clg_coil.handle)
      elsif dummy_clg_coil.ratedTotalCoolingCapacity.is_initialized
        dsn_clg_load = dummy_clg_coil.dummy_clg_coil.ratedTotalCoolingCapacity.get
        model.removeObject(dummy_clg_coil.handle)
      else
        runner.registerError("Unitary system cooling capacity not found for cooling coil in #{unitary_sys.name}")
        return false
      end
      # for heating
      dummy_htg_coil= unitary_sys.heatingCoil.get.to_CoilHeatingElectric.get
      if dummy_htg_coil.autosizedNominalCapacity.is_initialized
        dsn_htg_load = dummy_htg_coil.autosizedNominalCapacity.get
        model.removeObject(dummy_htg_coil.handle)
      elsif dummy_htg_coil.nominalCapacity.is_initialized
        dsn_htg_load = dummy_htg_coil.nominalCapacity.get
        model.removeObject(dummy_htg_coil.handle)
      else
        runner.registerError("Unitary system heating capacity not found for cooling coil in #{unitary_sys.name}")
        return false
      end

      #################################### Start Sizing Logic

      # minimum temperature for compressor operation (-15F from mitsubishi 33 SEER unit)
      min_comp_lockout_temp = -26.1111

      # get heating design day temperatures into list
      li_design_days = model.getDesignDays
      li_htg_dsgn_day_temps = []
      # loop through list of design days, add heating temps
      li_design_days.sort.each do |dd|
        day_type = dd.dayType
        # add design day drybulb temperature if winter design day
        next unless day_type == 'WinterDesignDay'
        li_htg_dsgn_day_temps << dd.maximumDryBulbTemperature
      end
      # get coldest design day temp for manual sizing
      wntr_design_day_temp_c = li_htg_dsgn_day_temps.min()

      # set heat pump sizing temp based on user-input value and design day
      hp_sizing_temp_c=nil
      if wntr_design_day_temp_c < min_comp_lockout_temp
        hp_sizing_temp_c = min_comp_lockout_temp
        runner.registerInfo("For heat pump sizing, heating design day temperature is #{OpenStudio.convert(wntr_design_day_temp_c, 'C', 'F').get.round(0)}F while the minimum compressor lockout temperature of the heat pumps is #{OpenStudio.convert(min_comp_lockout_temp, 'C', 'F').get.round(0)}F. Since the design day temperature is lower than the compressor lockout temperature, the compressor lockout temperature will be used for sizing the heat pump. Backup electric resistance heating will accomodate the remaining load.")
      else
        hp_sizing_temp_c = wntr_design_day_temp_c
        runner.registerInfo("For heat pump sizing, heating design day temperature is #{OpenStudio.convert(wntr_design_day_temp_c, 'C', 'F').get.round(0)}F while the minimum compressor lockout temperature of the heat pumps is #{OpenStudio.convert(min_comp_lockout_temp, 'C', 'F').get.round(0)}F. The heating design day temperature is above the compressor lockout temperature, so the heat pump will be sized according to the design day temperature.")
      end

      # define airflow stages; values from ResStock 33 SEER mini split heat pump IDF
      airflow_stage1 = dsn_airflow * 0.53
      airflow_stage2 = dsn_airflow * 0.65
      airflow_stage3 = dsn_airflow * 0.76
      airflow_stage4 = dsn_airflow

      # determine heating load curve; y=mx+b
      # assumes 0 load at 60F (15.556 C)
      htg_load_slope = (0-dsn_htg_load) / (15.5556-wntr_design_day_temp_c)
      htg_load_intercept = dsn_htg_load - (htg_load_slope * wntr_design_day_temp_c)

      # calculate heat pump design load, derate factors, and required rated capacities (at stage 4) for different OA temperatures; assumes 75F interior temp (23.8889C)
      ia_temp_c = 23.8889
      # design - temperature determined by design days in specified weather file
      oa_temp_c = wntr_design_day_temp_c
      dns_htg_load_at_dsn_temp = dsn_htg_load
      hp_derate_factor_at_dsn = 1.09830653306452 + -0.010386676170938*ia_temp_c + 0*ia_temp_c**2 + 0.0145161290322581*oa_temp_c + 0*oa_temp_c**2 + 0*ia_temp_c*oa_temp_c
      req_rated_hp_cap_at_47f_to_meet_load_at_dsn = dns_htg_load_at_dsn_temp / hp_derate_factor_at_dsn
      # 0F
      oa_temp_c = -17.7778
      dns_htg_load_at_0f = htg_load_slope*(-17.7778) + htg_load_intercept
      hp_derate_factor_at_0f = 1.09830653306452 + -0.010386676170938*ia_temp_c + 0*ia_temp_c**2 + 0.0145161290322581*oa_temp_c + 0*oa_temp_c**2 + 0*ia_temp_c*oa_temp_c
      req_rated_hp_cap_at_47f_to_meet_load_at_0f = dns_htg_load_at_0f / hp_derate_factor_at_0f
      # 17F
      oa_temp_c = -8.33333
      dns_htg_load_at_17f = htg_load_slope*(-8.33333) + htg_load_intercept
      hp_derate_factor_at_17f = 1.09830653306452 + -0.010386676170938*ia_temp_c + 0*ia_temp_c**2 + 0.0145161290322581*oa_temp_c + 0*oa_temp_c**2 + 0*ia_temp_c*oa_temp_c
      req_rated_hp_cap_at_47f_to_meet_load_at_17f = dns_htg_load_at_17f / hp_derate_factor_at_17f
      # 47F - note that this is rated conditions, so "derate" factor is either 1 from the curve, or will be normlized to 1 by E+ during simulation
      oa_temp_c = 8.33333
      dns_htg_load_at_47f = htg_load_slope*(-8.33333) + htg_load_intercept
      hp_derate_factor_at_47f = 1
      req_rated_hp_cap_at_47f_to_meet_load_at_47f = dns_htg_load_at_47f / hp_derate_factor_at_47f
      # user-specified design
      oa_temp_c = hp_sizing_temp_c
      dns_htg_load_at_user_dsn_temp = htg_load_slope*hp_sizing_temp_c + htg_load_intercept
      hp_derate_factor_at_user_dsn = 1.09830653306452 + -0.010386676170938*ia_temp_c + 0*ia_temp_c**2 + 0.0145161290322581*oa_temp_c + 0*oa_temp_c**2 + 0*ia_temp_c*oa_temp_c
      req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn = dns_htg_load_at_user_dsn_temp / hp_derate_factor_at_user_dsn

      # determine heat pump system sizing based on user-specified sizing temperature and user-specified maximum upsizing limits
      # get maximum cooling capacity with user-specified upsizing
      max_cool_cap_w_upsize = dsn_clg_load * (performance_oversizing_factor+1)
      max_heat_cap_w_upsize = max_cool_cap_w_upsize

      # set derate factor to 0 if less than -13F (-25 C)
      if wntr_design_day_temp_c < -25
        hp_derate_factor_at_user_dsn = 0
      end

      # cooling capacity
      cool_cap_oversize_pct_actual=nil
      if req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn < dsn_clg_load
        cool_cap_oversize_pct_actual = 0
      else
        cool_cap_oversize_pct_actual = (((dsn_clg_load - req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn) / dsn_clg_load).abs() * 100).round(2)
      end

      # set heat pump heating and cooling capacities based on design loads, user-specified backup heating, and design oversizing.
      dx_rated_clg_cap_applied = nil
      dx_rated_htg_cap_applied = nil
      # If required heat pump size for heating is less than what is required for cooling, size to cooling
      if req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn <= dsn_clg_load
        # set rated heating capacity equal to upsized cooling capacity times the user-specified heating to cooling sizing ratio
        dx_rated_htg_cap_applied = dsn_clg_load
        # set rated cooling capacity
        dx_rated_clg_cap_applied = dsn_clg_load
        # print register
        runner.registerInfo("For air loop #{thermal_zone.name}:
                            Design Heating Load: #{OpenStudio.convert(dsn_htg_load, 'W', 'ton').get.round(1)} tons
                            Design Cooling Load: #{OpenStudio.convert(dsn_clg_load, 'W', 'ton').get.round(1)} tons
                            Heating to Cooling Load Ratio: #{(dsn_htg_load/dsn_clg_load).round(2)}
                            Weather File Design Day Temperature: #{OpenStudio.convert(wntr_design_day_temp_c, 'C', 'F').get.round(0)}F
                            Design Sizing Temperature Accounting for -15F Compressor Lockout: #{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F
                            Heat Pump Derate Factor at Design Sizing Temperature (#{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F): #{hp_derate_factor_at_user_dsn.round(2)}
                            Heat Pump Capacity at Rated Condition (47F) Required to Meet Load at Design Sizing Temperature: #{OpenStudio.convert(req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn, 'W', 'ton').get.round(1)} tons
                            Sizing % increase required to Meet Load at Design Sizing Temperature vs. Cooling Sizing Requirement: #{cool_cap_oversize_pct_actual}%
                            User-Defined Maximum Heat Pump Oversizing Limit: #{performance_oversizing_factor*100}%
                            Applied Heat Pump Sizing at Rated Conditions (47F): #{OpenStudio.convert(dx_rated_htg_cap_applied, 'W', 'ton').get.round(1)} tons
                            % of Design Heating Load Met at Design Sizing Temperature (#{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F) with Applied Sizing: #{(dx_rated_htg_cap_applied/req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn).round(2)*100}%
                            % of Design Heating Load Met at 0F with Applied Sizing: #{(dx_rated_htg_cap_applied/req_rated_hp_cap_at_47f_to_meet_load_at_0f).round(1)*100}%
                            % of Design Heating Load Met at 17F with Applied Sizing: #{(dx_rated_htg_cap_applied/req_rated_hp_cap_at_47f_to_meet_load_at_17f).round(1)*100}%
                            % of Design Heating Load Met at 47F with Applied Sizing: #{((dx_rated_htg_cap_applied/req_rated_hp_cap_at_47f_to_meet_load_at_47f)*100).round(1)}%
                            ")
      # If required heat pump size for heating is greater than design cooling load, but less than user-defined oversizing limit, size to required heating load
      elsif req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn <= max_heat_cap_w_upsize
        # set rated heating coil equal to desired sized value, which should be below the suer-input limit
        dx_rated_htg_cap_applied = req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn
        # set cooling capacity to appropriate ratio based on heating capacity needs
        cool_cap = req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn
        cool_cap_oversize_pct_actual = (((dsn_clg_load-cool_cap) / dsn_clg_load).abs() * 100).round(2)
        dx_rated_clg_cap_applied = cool_cap
        # print register
        runner.registerInfo("For air loop #{thermal_zone.name}:
                            Design Heating Load: #{OpenStudio.convert(dsn_htg_load, 'W', 'ton').get.round(1)} tons
                            Design Cooling Load: #{OpenStudio.convert(dsn_clg_load, 'W', 'ton').get.round(1)} tons
                            Heating to Cooling Load Ratio: #{(dsn_htg_load/dsn_clg_load).round(2)}
                            Weather File Design Day Temperature: #{OpenStudio.convert(wntr_design_day_temp_c, 'C', 'F').get.round(0)}F
                            Design Sizing Temperature Accounting for -15F Compressor Lockout: #{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F
                            Heat Pump Derate Factor at Design Sizing Temperature (#{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F): #{hp_derate_factor_at_user_dsn.round(2)}
                            Heat Pump Capacity at Rated Condition (47F) Required to Meet Load at Design Sizing Temperature: #{OpenStudio.convert(req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn, 'W', 'ton').get.round(1)} tons
                            Sizing % increase required to Meet Load at Design Sizing Temperature vs. Cooling Sizing Requirement: #{cool_cap_oversize_pct_actual}%
                            User-Defined Maximum Heat Pump Oversizing Limit: #{performance_oversizing_factor*100}%
                            Applied Heat Pump Sizing at Rated Conditions (47F): #{OpenStudio.convert(dx_rated_htg_cap_applied, 'W', 'ton').get.round(1)} tons
                            % of Design Heating Load Met at Design Sizing Temperature (#{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F) with Applied Sizing: #{(dx_rated_htg_cap_applied/req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn).round(2)*100}%
                            % of Design Heating Load Met at 0F with Applied Sizing: #{(dx_rated_htg_cap_applied/req_rated_hp_cap_at_47f_to_meet_load_at_0f).round(1)*100}%
                            % of Design Heating Load Met at 17F with Applied Sizing: #{(dx_rated_htg_cap_applied/req_rated_hp_cap_at_47f_to_meet_load_at_17f).round(1)*100}%
                            % of Design Heating Load Met at 47F with Applied Sizing: #{((dx_rated_htg_cap_applied/req_rated_hp_cap_at_47f_to_meet_load_at_47f)*100).round(1)}%
                            ")
      else
        # set rated heating capacity to maximum allowable based on cooling capacity maximum limit
        dx_rated_htg_cap_applied = max_cool_cap_w_upsize
        # set rated cooling capacity to maximum allowable based on oversizing limit
        dx_rated_clg_cap_applied = max_cool_cap_w_upsize
        # print register
        # runner.registerInfo("For air loop #{air_loop_hvac.name}:
        #   >>Heating Sizing Information: Total heating requirement at design conditions is #{OpenStudio.convert(req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn, 'W', 'ton').get.round(2)} tons. User-input HP heating design temperature is #{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F, which yields a HP capacity derate factor of #{hp_derate_factor_at_user_dsn.round(2)} from the performance curve and a resulting heating capacity of #{OpenStudio.convert((req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn * hp_derate_factor_at_user_dsn), 'W', 'ton').get.round(2)} tons at #{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F. For the heat pump to meet the design heating load of #{OpenStudio.convert(req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn, 'W', 'ton').get.round(2)} tons at the design temperature of #{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F, the rated heat pump size (at 47F) must be greater than #{OpenStudio.convert(req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn, 'W', 'ton').get.round(2)} tons.
        #   >>Cooling Sizing Information: Total cooling requirement is #{OpenStudio.convert(dsn_clg_load, 'W', 'ton').get.round(2)} tons.
        #   >>Sizing Limits: Increasing the HP total capacity to accomodate potential additional heating capacity is capped such that the resulting cooling capacity does not exceed the user-input oversizing factor of #{performance_oversizing_factor+1} times the required cooling load of #{OpenStudio.convert(dsn_clg_load, 'W', 'ton').get.round(2)} tons. Therefore, the cooling capacity cannot exceed #{OpenStudio.convert(dsn_clg_load * (performance_oversizing_factor+1), 'W', 'ton').get.round(2)} tons, the final hp heating capacity cannot exceed #{OpenStudio.convert(dsn_clg_load*(performance_oversizing_factor+1), 'W', 'ton').get.round(2)} tons.
        #   >>Sizing Results: To meet the design heating load of #{OpenStudio.convert((req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn), 'W', 'ton').get.round(2)} tons at#{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F, the compressor needs to be oversized by #{cool_cap_oversize_pct_actual}%, which is beyond the user-input maximum value of #{(performance_oversizing_factor*100).round(2)}%. Therefore, the unit will be sized to the user-input maximum allowable, which results in a rated cooling capacity of#{OpenStudio.convert(max_cool_cap_w_upsize, 'W', 'ton').get.round(2)} tons, a rated heating capacity (at 47F) of #{OpenStudio.convert((max_cool_cap_w_upsize), 'W', 'ton').get.round(2)} tons, and a heating capacity at design temperature(#{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F) of #{OpenStudio.convert(((max_cool_cap_w_upsize) * hp_derate_factor_at_user_dsn), 'W', 'ton').get.round(2)} tons, which is #{((((max_cool_cap_w_upsize) * hp_derate_factor_at_user_dsn) / (req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn))*100).round(2)}% of the design heating load at this temperature. For reference, the WEATHER FILE heating design day temperature of #{OpenStudio.convert(wntr_design_day_temp_c, 'C', 'F').get.round(0)}F yields a derate factor of#{hp_derate_factor_at_user_dsn.round(2)}, which results in a heating capacity of #{OpenStudio.convert((max_cool_cap_w_upsize * hp_derate_factor_at_user_dsn), 'W', 'ton').get.round(2)} tons at this temperature, which is #{(((max_cool_cap_w_upsize * hp_derate_factor_at_user_dsn) / req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn) * 100).round(2)}% of the design heating load at this temperature.")
        runner.registerInfo("For air loop #{thermal_zone.name}:
                            Design Heating Load: #{OpenStudio.convert(dsn_htg_load, 'W', 'ton').get.round(1)} tons
                            Design Cooling Load: #{OpenStudio.convert(dsn_clg_load, 'W', 'ton').get.round(1)} tons
                            Heating to Cooling Load Ratio: #{(dsn_htg_load/dsn_clg_load).round(2)}
                            Weather File Design Day Temperature: #{OpenStudio.convert(wntr_design_day_temp_c, 'C', 'F').get.round(0)}F
                            Design Sizing Temperature Accounting for -15F Compressor Lockout: #{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F
                            Heat Pump Derate Factor at Design Sizing Temperature (#{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F): #{hp_derate_factor_at_user_dsn.round(2)}
                            Heat Pump Capacity at Rated Condition (47F) Required to Meet Load at Design Sizing Temperature: #{OpenStudio.convert(req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn, 'W', 'ton').get.round(1)} tons
                            Sizing % increase required to Meet Load at Design Sizing Temperature vs. Cooling Sizing Requirement: #{cool_cap_oversize_pct_actual}%
                            User-Defined Maximum Heat Pump Oversizing Limit: #{performance_oversizing_factor*100}%
                            Applied Heat Pump Sizing at Rated Conditions (47F): #{OpenStudio.convert(dx_rated_htg_cap_applied, 'W', 'ton').get.round(1)} tons
                            % of Design Heating Load Met at Design Sizing Temperature (#{OpenStudio.convert(hp_sizing_temp_c, 'C', 'F').get.round(0)}F) with Applied Sizing: #{(dx_rated_htg_cap_applied/req_rated_hp_cap_at_user_dsn_to_meet_load_at_user_dsn).round(2)*100}%
                            % of Design Heating Load Met at 0F with Applied Sizing: #{(dx_rated_htg_cap_applied/req_rated_hp_cap_at_47f_to_meet_load_at_0f).round(1)*100}%
                            % of Design Heating Load Met at 17F with Applied Sizing: #{(dx_rated_htg_cap_applied/req_rated_hp_cap_at_47f_to_meet_load_at_17f).round(1)*100}%
                            % of Design Heating Load Met at 47F with Applied Sizing: #{((dx_rated_htg_cap_applied/req_rated_hp_cap_at_47f_to_meet_load_at_47f)*100).round(1)}%
                            ")
      end

      # define cooling stages; fractions from ResStock Reference file
      clg_stage1 = dx_rated_clg_cap_applied * 0.41
      clg_stage2 = dx_rated_clg_cap_applied * 0.56
      clg_stage3 = dx_rated_clg_cap_applied * 0.70
      clg_stage4 = dx_rated_clg_cap_applied

      # define heating stages
      htg_stage1 = dx_rated_htg_cap_applied * 0.33
      htg_stage2 = dx_rated_htg_cap_applied * 0.50
      htg_stage3 = dx_rated_htg_cap_applied * 0.67
      htg_stage4 = dx_rated_htg_cap_applied

      #################################### End Sizing Logic

      ################################### Cooling Performance Curves
      # define performance curves

      # Cooling Capacity Function of Temperature Curve - 1
      cool_cap_ft1 = OpenStudio::Model::CurveBiquadratic.new(model)
      cool_cap_ft1.setName("#{thermal_zone.name} cool_cap_ft1")
      cool_cap_ft1.setCoefficient1Constant(1.00899352190587)
      cool_cap_ft1.setCoefficient2x(0.006512749025457)
      cool_cap_ft1.setCoefficient3xPOW2(0)
      cool_cap_ft1.setCoefficient4y(0.003917565735935)
      cool_cap_ft1.setCoefficient5yPOW2(-0.000222646705889)
      cool_cap_ft1.setCoefficient6xTIMESY(0)
      cool_cap_ft1.setMinimumValueofx(-100)
      cool_cap_ft1.setMaximumValueofx(100)
      cool_cap_ft1.setMinimumValueofy(-100)
      cool_cap_ft1.setMaximumValueofy(100)
      # Heating Capacity Function of Temperature Curve - 2
      cool_cap_ft2 = OpenStudio::Model::CurveBiquadratic.new(model)
      cool_cap_ft2.setName("#{thermal_zone.name} cool_cap_ft2")
      cool_cap_ft2.setCoefficient1Constant(1.00899352190587)
      cool_cap_ft2.setCoefficient2x(0.006512749025457)
      cool_cap_ft2.setCoefficient3xPOW2(0)
      cool_cap_ft2.setCoefficient4y(0.003917565735935)
      cool_cap_ft2.setCoefficient5yPOW2(-0.000222646705889)
      cool_cap_ft2.setCoefficient6xTIMESY(0)
      cool_cap_ft2.setMinimumValueofx(-100)
      cool_cap_ft2.setMaximumValueofx(100)
      cool_cap_ft2.setMinimumValueofy(-100)
      cool_cap_ft2.setMaximumValueofy(100)
      # Heating Capacity Function of Temperature Curve - 3
      cool_cap_ft3 = OpenStudio::Model::CurveBiquadratic.new(model)
      cool_cap_ft3.setName("#{thermal_zone.name} cool_cap_ft3")
      cool_cap_ft3.setCoefficient1Constant(1.00899352190587)
      cool_cap_ft3.setCoefficient2x(0.006512749025457)
      cool_cap_ft3.setCoefficient3xPOW2(0)
      cool_cap_ft3.setCoefficient4y(0.003917565735935)
      cool_cap_ft3.setCoefficient5yPOW2(-0.000222646705889)
      cool_cap_ft3.setCoefficient6xTIMESY(0)
      cool_cap_ft3.setMinimumValueofx(-100)
      cool_cap_ft3.setMaximumValueofx(100)
      cool_cap_ft3.setMinimumValueofy(-100)
      cool_cap_ft3.setMaximumValueofy(100)
      # Heating Capacity Function of Temperature Curve - 4
      cool_cap_ft4 = OpenStudio::Model::CurveBiquadratic.new(model)
      cool_cap_ft4.setName("#{thermal_zone.name} cool_cap_ft4")
      cool_cap_ft4.setCoefficient1Constant(1.00899352190587)
      cool_cap_ft4.setCoefficient2x(0.006512749025457)
      cool_cap_ft4.setCoefficient3xPOW2(0)
      cool_cap_ft4.setCoefficient4y(0.003917565735935)
      cool_cap_ft4.setCoefficient5yPOW2(-0.000222646705889)
      cool_cap_ft4.setCoefficient6xTIMESY(0)
      cool_cap_ft4.setMinimumValueofx(-100)
      cool_cap_ft4.setMaximumValueofx(100)
      cool_cap_ft4.setMinimumValueofy(-100)
      cool_cap_ft4.setMaximumValueofy(100)

      # Heating Capacity Function of Flow Fraction Curve
      cool_cap_fff_all_stages = OpenStudio::Model::CurveQuadratic.new(model)
      cool_cap_fff_all_stages.setName("#{thermal_zone.name} cool_cap_fff_all_stages")
      cool_cap_fff_all_stages.setCoefficient1Constant(1)
      cool_cap_fff_all_stages.setCoefficient2x(0)
      cool_cap_fff_all_stages.setCoefficient3xPOW2(0)
      cool_cap_fff_all_stages.setMinimumValueofx(0)
      cool_cap_fff_all_stages.setMaximumValueofx(2)
      cool_cap_fff_all_stages.setMinimumCurveOutput(0)
      cool_cap_fff_all_stages.setMaximumCurveOutput(2)

      # Energy Input Ratio Function of Temperature Curve - 1
      cool_eir_ft1 = OpenStudio::Model::CurveBiquadratic.new(model)
      cool_eir_ft1.setName("#{thermal_zone.name} cool_eir_ft1")
      cool_eir_ft1.setCoefficient1Constant(0.429214441601141)
      cool_eir_ft1.setCoefficient2x(-0.003604841598515)
      cool_eir_ft1.setCoefficient3xPOW2(4.5783162727e-05)
      cool_eir_ft1.setCoefficient4y(0.026490875804937)
      cool_eir_ft1.setCoefficient5yPOW2(-0.000159212286878)
      cool_eir_ft1.setCoefficient6xTIMESY(-0.000159062656483)
      cool_eir_ft1.setMinimumValueofx(-100)
      cool_eir_ft1.setMaximumValueofx(100)
      cool_eir_ft1.setMinimumValueofy(-100)
      cool_eir_ft1.setMaximumValueofy(100)
      # Energy Input Ratio Function of Temperature Curve - 2
      cool_eir_ft2 = OpenStudio::Model::CurveBiquadratic.new(model)
      cool_eir_ft2.setName("#{thermal_zone.name} cool_eir_ft2")
      cool_eir_ft2.setCoefficient1Constant(0.429214441601141)
      cool_eir_ft2.setCoefficient2x(-0.003604841598515)
      cool_eir_ft2.setCoefficient3xPOW2(4.5783162727e-05)
      cool_eir_ft2.setCoefficient4y(0.026490875804937)
      cool_eir_ft2.setCoefficient5yPOW2(-0.000159212286878)
      cool_eir_ft2.setCoefficient6xTIMESY(-0.000159062656483)
      cool_eir_ft2.setMinimumValueofx(-100)
      cool_eir_ft2.setMaximumValueofx(100)
      cool_eir_ft2.setMinimumValueofy(-100)
      cool_eir_ft2.setMaximumValueofy(100)
      # Energy Input Ratio Function of Temperature Curve - 3
      cool_eir_ft3 = OpenStudio::Model::CurveBiquadratic.new(model)
      cool_eir_ft3.setName("#{thermal_zone.name} cool_eir_ft3")
      cool_eir_ft3.setCoefficient1Constant(0.429214441601141)
      cool_eir_ft3.setCoefficient2x(-0.003604841598515)
      cool_eir_ft3.setCoefficient3xPOW2(4.5783162727e-05)
      cool_eir_ft3.setCoefficient4y(0.026490875804937)
      cool_eir_ft3.setCoefficient5yPOW2(-0.000159212286878)
      cool_eir_ft3.setCoefficient6xTIMESY(-0.000159062656483)
      cool_eir_ft3.setMinimumValueofx(-100)
      cool_eir_ft3.setMaximumValueofx(100)
      cool_eir_ft3.setMinimumValueofy(-100)
      cool_eir_ft3.setMaximumValueofy(100)
      # Energy Input Ratio Function of Temperature Curve - 4
      cool_eir_ft4 = OpenStudio::Model::CurveBiquadratic.new(model)
      cool_eir_ft4.setName("#{thermal_zone.name} cool_eir_ft4")
      cool_eir_ft4.setCoefficient1Constant(0.429214441601141)
      cool_eir_ft4.setCoefficient2x(-0.003604841598515)
      cool_eir_ft4.setCoefficient3xPOW2(4.5783162727e-05)
      cool_eir_ft4.setCoefficient4y(0.026490875804937)
      cool_eir_ft4.setCoefficient5yPOW2(-0.000159212286878)
      cool_eir_ft4.setCoefficient6xTIMESY(-0.000159062656483)
      cool_eir_ft4.setMinimumValueofx(-100)
      cool_eir_ft4.setMaximumValueofx(100)
      cool_eir_ft4.setMinimumValueofy(-100)
      cool_eir_ft4.setMaximumValueofy(100)

      # Energy Input Ratio Function of Flow Fraction Curve
      cool_eir_fff_all_stages = OpenStudio::Model::CurveQuadratic.new(model)
      cool_eir_fff_all_stages.setName("#{thermal_zone.name} cool_eir_fff")
      cool_eir_fff_all_stages.setCoefficient1Constant(1)
      cool_eir_fff_all_stages.setCoefficient2x(0)
      cool_eir_fff_all_stages.setCoefficient3xPOW2(0)
      cool_eir_fff_all_stages.setMinimumValueofx(0)
      cool_eir_fff_all_stages.setMaximumValueofx(2)
      cool_eir_fff_all_stages.setMinimumCurveOutput(0)
      cool_eir_fff_all_stages.setMaximumCurveOutput(2)

      # Part Load Fraction Correlation Curve
      cool_plf_fplr_all_stages = OpenStudio::Model::CurveQuadratic.new(model)
      cool_plf_fplr_all_stages.setName("#{thermal_zone.name} cool_plf_fplr")
      cool_plf_fplr_all_stages.setCoefficient1Constant(0.75)
      cool_plf_fplr_all_stages.setCoefficient2x(0.25)
      cool_plf_fplr_all_stages.setCoefficient3xPOW2(0)
      cool_plf_fplr_all_stages.setMinimumValueofx(0)
      cool_plf_fplr_all_stages.setMaximumValueofx(1)
      cool_plf_fplr_all_stages.setMinimumCurveOutput(0.7)
      cool_plf_fplr_all_stages.setMaximumCurveOutput(1)

      # add new multispeed cooling coil
      new_dx_cooling_coil = OpenStudio::Model::CoilCoolingDXMultiSpeed.new(model)
      new_dx_cooling_coil.setName("#{thermal_zone.name} Heat Pump Cooling Coil")
      new_dx_cooling_coil.setCondenserType('AirCooled')
      new_dx_cooling_coil.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
      new_dx_cooling_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(-25)
      new_dx_cooling_coil.setApplyPartLoadFractiontoSpeedsGreaterthan1(false)
      new_dx_cooling_coil.setApplyLatentDegradationtoSpeedsGreaterthan1(false)
      new_dx_cooling_coil.setFuelType('Electricity')

      # add stage data
      # create stage 1
      new_dx_cooling_coil_speed1 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
      new_dx_cooling_coil_speed1.setGrossRatedTotalCoolingCapacity(clg_stage1)
      new_dx_cooling_coil_speed1.setGrossRatedSensibleHeatRatio(0.862559284540077)
      new_dx_cooling_coil_speed1.setGrossRatedCoolingCOP(11.4780478940814)
      new_dx_cooling_coil_speed1.setRatedAirFlowRate(airflow_stage1)
      new_dx_cooling_coil_speed1.setRatedEvaporatorFanPowerPerVolumeFlowRate(773.3)
      new_dx_cooling_coil_speed1.setTotalCoolingCapacityFunctionofTemperatureCurve(cool_cap_ft1)
      new_dx_cooling_coil_speed1.setTotalCoolingCapacityFunctionofFlowFractionCurve(cool_cap_fff_all_stages)
      new_dx_cooling_coil_speed1.setEnergyInputRatioFunctionofTemperatureCurve(cool_eir_ft1)
      new_dx_cooling_coil_speed1.setEnergyInputRatioFunctionofFlowFractionCurve (cool_eir_fff_all_stages)
      new_dx_cooling_coil_speed1.setPartLoadFractionCorrelationCurve(cool_plf_fplr_all_stages)
      new_dx_cooling_coil_speed1.setNominalTimeforCondensateRemovaltoBegin(1000)
      new_dx_cooling_coil_speed1.setRatioofInitialMoistureEvaporationRateandSteadyStateLatentCapacity(1.5)
      new_dx_cooling_coil_speed1.setLatentCapacityTimeConstant(45)
      new_dx_cooling_coil_speed1.setEvaporativeCondenserEffectiveness(0.9)
      new_dx_cooling_coil_speed1.autosizedEvaporativeCondenserAirFlowRate
      new_dx_cooling_coil_speed1.autosizedRatedEvaporativeCondenserPumpPowerConsumption
      new_dx_cooling_coil.addStage(new_dx_cooling_coil_speed1)

      # create stage 2
      new_dx_cooling_coil_speed2 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
      new_dx_cooling_coil_speed2.setGrossRatedTotalCoolingCapacity(clg_stage2)
      new_dx_cooling_coil_speed2.setGrossRatedSensibleHeatRatio(0.798701661239655)
      new_dx_cooling_coil_speed2.setGrossRatedCoolingCOP(9.90930781571145)
      new_dx_cooling_coil_speed2.setRatedAirFlowRate(airflow_stage2)
      new_dx_cooling_coil_speed2.setRatedEvaporatorFanPowerPerVolumeFlowRate(773.3)
      new_dx_cooling_coil_speed2.setTotalCoolingCapacityFunctionofTemperatureCurve(cool_cap_ft2)
      new_dx_cooling_coil_speed2.setTotalCoolingCapacityFunctionofFlowFractionCurve(cool_cap_fff_all_stages)
      new_dx_cooling_coil_speed2.setEnergyInputRatioFunctionofTemperatureCurve(cool_eir_ft2)
      new_dx_cooling_coil_speed2.setEnergyInputRatioFunctionofFlowFractionCurve (cool_eir_fff_all_stages)
      new_dx_cooling_coil_speed2.setPartLoadFractionCorrelationCurve(cool_plf_fplr_all_stages)
      new_dx_cooling_coil_speed2.setNominalTimeforCondensateRemovaltoBegin(1000)
      new_dx_cooling_coil_speed2.setRatioofInitialMoistureEvaporationRateandSteadyStateLatentCapacity(1.5)
      new_dx_cooling_coil_speed2.setLatentCapacityTimeConstant(45)
      new_dx_cooling_coil_speed2.setEvaporativeCondenserEffectiveness(0.9)
      new_dx_cooling_coil_speed2.autosizedEvaporativeCondenserAirFlowRate
      new_dx_cooling_coil_speed2.autosizedRatedEvaporativeCondenserPumpPowerConsumption
      new_dx_cooling_coil.addStage(new_dx_cooling_coil_speed2)

      # create stage 3
      new_dx_cooling_coil_speed3 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
      new_dx_cooling_coil_speed3.setGrossRatedTotalCoolingCapacity(clg_stage3)
      new_dx_cooling_coil_speed3.setGrossRatedSensibleHeatRatio(0.757094338262211)
      new_dx_cooling_coil_speed3.setGrossRatedCoolingCOP(8.28586766038408)
      new_dx_cooling_coil_speed3.setRatedAirFlowRate(airflow_stage3)
      new_dx_cooling_coil_speed3.setRatedEvaporatorFanPowerPerVolumeFlowRate(773.3)
      new_dx_cooling_coil_speed3.setTotalCoolingCapacityFunctionofTemperatureCurve(cool_cap_ft3)
      new_dx_cooling_coil_speed3.setTotalCoolingCapacityFunctionofFlowFractionCurve(cool_cap_fff_all_stages)
      new_dx_cooling_coil_speed3.setEnergyInputRatioFunctionofTemperatureCurve(cool_eir_ft3)
      new_dx_cooling_coil_speed3.setEnergyInputRatioFunctionofFlowFractionCurve (cool_eir_fff_all_stages)
      new_dx_cooling_coil_speed3.setPartLoadFractionCorrelationCurve(cool_plf_fplr_all_stages)
      new_dx_cooling_coil_speed3.setNominalTimeforCondensateRemovaltoBegin(1000)
      new_dx_cooling_coil_speed3.setRatioofInitialMoistureEvaporationRateandSteadyStateLatentCapacity(1.5)
      new_dx_cooling_coil_speed3.setLatentCapacityTimeConstant(45)
      new_dx_cooling_coil_speed3.setEvaporativeCondenserEffectiveness(0.9)
      new_dx_cooling_coil_speed3.autosizedEvaporativeCondenserAirFlowRate
      new_dx_cooling_coil_speed3.autosizedRatedEvaporativeCondenserPumpPowerConsumption
      new_dx_cooling_coil.addStage(new_dx_cooling_coil_speed3)
      # create stage 4
      new_dx_cooling_coil_speed4 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
      new_dx_cooling_coil_speed4.setGrossRatedTotalCoolingCapacity(clg_stage4)
      new_dx_cooling_coil_speed4.setGrossRatedSensibleHeatRatio(0.702551992573952)
      new_dx_cooling_coil_speed4.setGrossRatedCoolingCOP(6.08994923070552)
      new_dx_cooling_coil_speed4.setRatedAirFlowRate(airflow_stage4)
      new_dx_cooling_coil_speed4.setRatedEvaporatorFanPowerPerVolumeFlowRate(773.3)
      new_dx_cooling_coil_speed4.setTotalCoolingCapacityFunctionofTemperatureCurve(cool_cap_ft4)
      new_dx_cooling_coil_speed4.setTotalCoolingCapacityFunctionofFlowFractionCurve(cool_cap_fff_all_stages)
      new_dx_cooling_coil_speed4.setEnergyInputRatioFunctionofTemperatureCurve(cool_eir_ft4)
      new_dx_cooling_coil_speed4.setEnergyInputRatioFunctionofFlowFractionCurve (cool_eir_fff_all_stages)
      new_dx_cooling_coil_speed4.setPartLoadFractionCorrelationCurve(cool_plf_fplr_all_stages)
      new_dx_cooling_coil_speed4.setNominalTimeforCondensateRemovaltoBegin(1000)
      new_dx_cooling_coil_speed4.setRatioofInitialMoistureEvaporationRateandSteadyStateLatentCapacity(1.5)
      new_dx_cooling_coil_speed4.setLatentCapacityTimeConstant(45)
      new_dx_cooling_coil_speed4.setEvaporativeCondenserEffectiveness(0.9)
      new_dx_cooling_coil_speed4.autosizedEvaporativeCondenserAirFlowRate
      new_dx_cooling_coil_speed4.autosizedRatedEvaporativeCondenserPumpPowerConsumption
      new_dx_cooling_coil.addStage(new_dx_cooling_coil_speed4)
      ####################################### End Cooling Performance Curves

      ################################### Heating Performance Curves
      # define performance curves

      # Defrost Energy Input Ratio Function of Temperature Curve
      defrost_eir = OpenStudio::Model::CurveBiquadratic.new(model)
      defrost_eir.setName("#{thermal_zone.name} defrost_eir")
      defrost_eir.setCoefficient1Constant(0.1528)
      defrost_eir.setCoefficient2x(0)
      defrost_eir.setCoefficient3xPOW2(0)
      defrost_eir.setCoefficient4y(0)
      defrost_eir.setCoefficient5yPOW2(0)
      defrost_eir.setCoefficient6xTIMESY(0)
      defrost_eir.setMinimumValueofx(-100)
      defrost_eir.setMaximumValueofx(100)
      defrost_eir.setMinimumValueofy(-100)
      defrost_eir.setMaximumValueofy(100)

      # Heating Capacity Function of Temperature Curve - 1
      heat_cap_ft1 = OpenStudio::Model::CurveBiquadratic.new(model)
      heat_cap_ft1.setName("#{thermal_zone.name} heat_cap_ft1")
      heat_cap_ft1.setCoefficient1Constant(1.09830653306452)
      heat_cap_ft1.setCoefficient2x(-0.010386676170938)
      heat_cap_ft1.setCoefficient3xPOW2(0)
      heat_cap_ft1.setCoefficient4y(0.0145161290322581)
      heat_cap_ft1.setCoefficient5yPOW2(0)
      heat_cap_ft1.setCoefficient6xTIMESY(0)
      heat_cap_ft1.setMinimumValueofx(-100)
      heat_cap_ft1.setMaximumValueofx(100)
      heat_cap_ft1.setMinimumValueofy(-100)
      heat_cap_ft1.setMaximumValueofy(100)
      # Heating Capacity Function of Temperature Curve - 2
      heat_cap_ft2 = OpenStudio::Model::CurveBiquadratic.new(model)
      heat_cap_ft2.setName("#{thermal_zone.name} heat_cap_ft2")
      heat_cap_ft2.setCoefficient1Constant(1.09830653306452)
      heat_cap_ft2.setCoefficient2x(-0.010386676170938)
      heat_cap_ft2.setCoefficient3xPOW2(0)
      heat_cap_ft2.setCoefficient4y(0.0145161290322581)
      heat_cap_ft2.setCoefficient5yPOW2(0)
      heat_cap_ft2.setCoefficient6xTIMESY(0)
      heat_cap_ft2.setMinimumValueofx(-100)
      heat_cap_ft2.setMaximumValueofx(100)
      heat_cap_ft2.setMinimumValueofy(-100)
      heat_cap_ft2.setMaximumValueofy(100)
      # Heating Capacity Function of Temperature Curve - 3
      heat_cap_ft3 = OpenStudio::Model::CurveBiquadratic.new(model)
      heat_cap_ft3.setName("#{thermal_zone.name} heat_cap_ft3")
      heat_cap_ft3.setCoefficient1Constant(1.09830653306452)
      heat_cap_ft3.setCoefficient2x(-0.010386676170938)
      heat_cap_ft3.setCoefficient3xPOW2(0)
      heat_cap_ft3.setCoefficient4y(0.0145161290322581)
      heat_cap_ft3.setCoefficient5yPOW2(0)
      heat_cap_ft3.setCoefficient6xTIMESY(0)
      heat_cap_ft3.setMinimumValueofx(-100)
      heat_cap_ft3.setMaximumValueofx(100)
      heat_cap_ft3.setMinimumValueofy(-100)
      heat_cap_ft3.setMaximumValueofy(100)
      # Heating Capacity Function of Temperature Curve - 4
      heat_cap_ft4 = OpenStudio::Model::CurveBiquadratic.new(model)
      heat_cap_ft4.setName("#{thermal_zone.name} heat_cap_ft4")
      heat_cap_ft4.setCoefficient1Constant(1.09830653306452)
      heat_cap_ft4.setCoefficient2x(-0.010386676170938)
      heat_cap_ft4.setCoefficient3xPOW2(0)
      heat_cap_ft4.setCoefficient4y(0.0145161290322581)
      heat_cap_ft4.setCoefficient5yPOW2(0)
      heat_cap_ft4.setCoefficient6xTIMESY(0)
      heat_cap_ft4.setMinimumValueofx(-100)
      heat_cap_ft4.setMaximumValueofx(100)
      heat_cap_ft4.setMinimumValueofy(-100)
      heat_cap_ft4.setMaximumValueofy(100)

      # Heating Capacity Function of Flow Fraction Curve
      heat_cap_fff_all_stages = OpenStudio::Model::CurveQuadratic.new(model)
      heat_cap_fff_all_stages.setName("#{thermal_zone.name} heat_cap_fff_all_stages")
      heat_cap_fff_all_stages.setCoefficient1Constant(1)
      heat_cap_fff_all_stages.setCoefficient2x(0)
      heat_cap_fff_all_stages.setCoefficient3xPOW2(0)
      heat_cap_fff_all_stages.setMinimumValueofx(0)
      heat_cap_fff_all_stages.setMaximumValueofx(2)
      heat_cap_fff_all_stages.setMinimumCurveOutput(0)
      heat_cap_fff_all_stages.setMaximumCurveOutput(2)

      # Energy Input Ratio Function of Temperature Curve - 1
      heat_eir_ft1 = OpenStudio::Model::CurveBiquadratic.new(model)
      heat_eir_ft1.setName("#{thermal_zone.name} heat_eir_ft1")
      heat_eir_ft1.setCoefficient1Constant(0.966475472847719)
      heat_eir_ft1.setCoefficient2x(0.005914950101249)
      heat_eir_ft1.setCoefficient3xPOW2(0.000191201688297)
      heat_eir_ft1.setCoefficient4y(-0.012965668198361)
      heat_eir_ft1.setCoefficient5yPOW2(4.2253229429e-05)
      heat_eir_ft1.setCoefficient6xTIMESY(-0.000524002558712)
      heat_eir_ft1.setMinimumValueofx(-100)
      heat_eir_ft1.setMaximumValueofx(100)
      heat_eir_ft1.setMinimumValueofy(-100)
      heat_eir_ft1.setMaximumValueofy(100)
      # Energy Input Ratio Function of Temperature Curve - 2
      heat_eir_ft2 = OpenStudio::Model::CurveBiquadratic.new(model)
      heat_eir_ft2.setName("#{thermal_zone.name} heat_eir_ft2")
      heat_eir_ft2.setCoefficient1Constant(0.966475472847719)
      heat_eir_ft2.setCoefficient2x(0.005914950101249)
      heat_eir_ft2.setCoefficient3xPOW2(0.000191201688297)
      heat_eir_ft2.setCoefficient4y(-0.012965668198361)
      heat_eir_ft2.setCoefficient5yPOW2(4.2253229429e-05)
      heat_eir_ft2.setCoefficient6xTIMESY(-0.000524002558712)
      heat_eir_ft2.setMinimumValueofx(-100)
      heat_eir_ft2.setMaximumValueofx(100)
      heat_eir_ft2.setMinimumValueofy(-100)
      heat_eir_ft2.setMaximumValueofy(100)
      # Energy Input Ratio Function of Temperature Curve - 3
      heat_eir_ft3 = OpenStudio::Model::CurveBiquadratic.new(model)
      heat_eir_ft3.setName("#{thermal_zone.name} heat_eir_ft3")
      heat_eir_ft3.setCoefficient1Constant(0.966475472847719)
      heat_eir_ft3.setCoefficient2x(0.005914950101249)
      heat_eir_ft3.setCoefficient3xPOW2(0.000191201688297)
      heat_eir_ft3.setCoefficient4y(-0.012965668198361)
      heat_eir_ft3.setCoefficient5yPOW2(4.2253229429e-05)
      heat_eir_ft3.setCoefficient6xTIMESY(-0.000524002558712)
      heat_eir_ft3.setMinimumValueofx(-100)
      heat_eir_ft3.setMaximumValueofx(100)
      heat_eir_ft3.setMinimumValueofy(-100)
      heat_eir_ft3.setMaximumValueofy(100)
      # Energy Input Ratio Function of Temperature Curve - 4
      heat_eir_ft4 = OpenStudio::Model::CurveBiquadratic.new(model)
      heat_eir_ft4.setName("#{thermal_zone.name} heat_eir_ft4")
      heat_eir_ft4.setCoefficient1Constant(0.966475472847719)
      heat_eir_ft4.setCoefficient2x(0.005914950101249)
      heat_eir_ft4.setCoefficient3xPOW2(0.000191201688297)
      heat_eir_ft4.setCoefficient4y(-0.012965668198361)
      heat_eir_ft4.setCoefficient5yPOW2(4.2253229429e-05)
      heat_eir_ft4.setCoefficient6xTIMESY(-0.000524002558712)
      heat_eir_ft4.setMinimumValueofx(-100)
      heat_eir_ft4.setMaximumValueofx(100)
      heat_eir_ft4.setMinimumValueofy(-100)
      heat_eir_ft4.setMaximumValueofy(100)

      # Energy Input Ratio Function of Flow Fraction Curve
      heat_eir_fff_all_stages = OpenStudio::Model::CurveQuadratic.new(model)
      heat_eir_fff_all_stages.setName("#{thermal_zone.name} heat_eir_fff")
      heat_eir_fff_all_stages.setCoefficient1Constant(1)
      heat_eir_fff_all_stages.setCoefficient2x(0)
      heat_eir_fff_all_stages.setCoefficient3xPOW2(0)
      heat_eir_fff_all_stages.setMinimumValueofx(0)
      heat_eir_fff_all_stages.setMaximumValueofx(2)
      heat_eir_fff_all_stages.setMinimumCurveOutput(0)
      heat_eir_fff_all_stages.setMaximumCurveOutput(2)

      # Part Load Fraction Correlation Curve
      heat_plf_fplr_all_stages = OpenStudio::Model::CurveQuadratic.new(model)
      heat_plf_fplr_all_stages.setName("#{thermal_zone.name} heat_plf_fplr")
      heat_plf_fplr_all_stages.setCoefficient1Constant(0.6)
      heat_plf_fplr_all_stages.setCoefficient2x(0.4)
      heat_plf_fplr_all_stages.setCoefficient3xPOW2(0)
      heat_plf_fplr_all_stages.setMinimumValueofx(0)
      heat_plf_fplr_all_stages.setMaximumValueofx(1)
      heat_plf_fplr_all_stages.setMinimumCurveOutput(0.7)
      heat_plf_fplr_all_stages.setMaximumCurveOutput(1)

      # add new multispeed heating coil
      new_dx_heating_coil = OpenStudio::Model::CoilHeatingDXMultiSpeed.new(model)
      new_dx_heating_coil.setName("#{thermal_zone.name} Heat Pump Coil")
      new_dx_heating_coil.setMinimumOutdoorDryBulbTemperatureforCompressorOperation(-26.1111) # -15F is lowest default available, Mitsu unit
      new_dx_heating_coil.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
      new_dx_heating_coil.setDefrostEnergyInputRatioFunctionofTemperatureCurve(defrost_eir)
      new_dx_heating_coil.setMaximumOutdoorDryBulbTemperatureforDefrostOperation(4.444)
      new_dx_heating_coil.setDefrostStrategy('ReverseCycle')
      new_dx_heating_coil.setDefrostControl('OnDemand')
      new_dx_heating_coil.setDefrostTimePeriodFraction(0.058333)
      new_dx_heating_coil.setApplyPartLoadFractiontoSpeedsGreaterthan1(false)
      new_dx_heating_coil.setFuelType('Electricity')
      new_dx_heating_coil.setRegionnumberforCalculatingHSPF(4)

      # add stage data
      # create stage 1
      new_dx_heating_coil_speed1 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
      new_dx_heating_coil_speed1.setGrossRatedHeatingCapacity(htg_stage1)
      new_dx_heating_coil_speed1.setGrossRatedHeatingCOP(8.19679327210812)
      new_dx_heating_coil_speed1.setRatedAirFlowRate(airflow_stage1)
      new_dx_heating_coil_speed1.setRatedSupplyAirFanPowerPerVolumeFlowRate(773.3)
      new_dx_heating_coil_speed1.setHeatingCapacityFunctionofTemperatureCurve(heat_cap_ft1)
      new_dx_heating_coil_speed1.setHeatingCapacityFunctionofFlowFractionCurve(heat_cap_fff_all_stages)
      new_dx_heating_coil_speed1.setEnergyInputRatioFunctionofTemperatureCurve(heat_eir_ft1)
      new_dx_heating_coil_speed1.setEnergyInputRatioFunctionofFlowFractionCurve (heat_eir_fff_all_stages)
      new_dx_heating_coil_speed1.setPartLoadFractionCorrelationCurve(heat_plf_fplr_all_stages)
      new_dx_heating_coil.addStage(new_dx_heating_coil_speed1)
      # create stage 2
      new_dx_heating_coil_speed2 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
      new_dx_heating_coil_speed2.setGrossRatedHeatingCapacity(htg_stage2)
      new_dx_heating_coil_speed2.setGrossRatedHeatingCOP(6.52227368173976)
      new_dx_heating_coil_speed2.setRatedAirFlowRate(airflow_stage2)
      new_dx_heating_coil_speed2.setRatedSupplyAirFanPowerPerVolumeFlowRate(773.3)
      new_dx_heating_coil_speed2.setHeatingCapacityFunctionofTemperatureCurve(heat_cap_ft2)
      new_dx_heating_coil_speed2.setHeatingCapacityFunctionofFlowFractionCurve(heat_cap_fff_all_stages)
      new_dx_heating_coil_speed2.setEnergyInputRatioFunctionofTemperatureCurve(heat_eir_ft2)
      new_dx_heating_coil_speed2.setEnergyInputRatioFunctionofFlowFractionCurve (heat_eir_fff_all_stages)
      new_dx_heating_coil_speed2.setPartLoadFractionCorrelationCurve(heat_plf_fplr_all_stages)
      new_dx_heating_coil.addStage(new_dx_heating_coil_speed2)
      # create stage 3
      new_dx_heating_coil_speed3 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
      new_dx_heating_coil_speed3.setGrossRatedHeatingCapacity(htg_stage3)
      new_dx_heating_coil_speed3.setGrossRatedHeatingCOP(5.97879338773049)
      new_dx_heating_coil_speed3.setRatedAirFlowRate(airflow_stage3)
      new_dx_heating_coil_speed3.setRatedSupplyAirFanPowerPerVolumeFlowRate(773.3)
      new_dx_heating_coil_speed3.setHeatingCapacityFunctionofTemperatureCurve(heat_cap_ft3)
      new_dx_heating_coil_speed3.setHeatingCapacityFunctionofFlowFractionCurve(heat_cap_fff_all_stages)
      new_dx_heating_coil_speed3.setEnergyInputRatioFunctionofTemperatureCurve(heat_eir_ft3)
      new_dx_heating_coil_speed3.setEnergyInputRatioFunctionofFlowFractionCurve (heat_eir_fff_all_stages)
      new_dx_heating_coil_speed3.setPartLoadFractionCorrelationCurve(heat_plf_fplr_all_stages)
      new_dx_heating_coil.addStage(new_dx_heating_coil_speed3)
      # create stage 4
      new_dx_heating_coil_speed4 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
      new_dx_heating_coil_speed4.setGrossRatedHeatingCapacity(htg_stage4)
      new_dx_heating_coil_speed4.setGrossRatedHeatingCOP(5.44890502454945)
      new_dx_heating_coil_speed4.setRatedAirFlowRate(airflow_stage4)
      new_dx_heating_coil_speed4.setRatedSupplyAirFanPowerPerVolumeFlowRate(773.3)
      new_dx_heating_coil_speed4.setHeatingCapacityFunctionofTemperatureCurve(heat_cap_ft4)
      new_dx_heating_coil_speed4.setHeatingCapacityFunctionofFlowFractionCurve(heat_cap_fff_all_stages)
      new_dx_heating_coil_speed4.setEnergyInputRatioFunctionofTemperatureCurve(heat_eir_ft4)
      new_dx_heating_coil_speed4.setEnergyInputRatioFunctionofFlowFractionCurve (heat_eir_fff_all_stages)
      new_dx_heating_coil_speed4.setPartLoadFractionCorrelationCurve(heat_plf_fplr_all_stages)
      new_dx_heating_coil.addStage(new_dx_heating_coil_speed4)
      ####################################### End Heating Performance Curves

      # add new coils to unitary system object
      unitary_sys.setHeatingCoil(new_dx_heating_coil)
      unitary_sys.setCoolingCoil(new_dx_cooling_coil)
      # set backup heat to meet design heating load
      supp_htg_coil = unitary_sys.supplementalHeatingCoil.get.to_CoilHeatingElectric.get
      supp_htg_coil.setNominalCapacity(dsn_htg_load)
      supp_htg_coil.setEfficiency(1)

      # set other features
      unitary_sys.setDXHeatingCoilSizingRatio(1+performance_oversizing_factor)

      if model.version < OpenStudio::VersionString.new('3.7.0')
        # set cooling design flow rate
        unitary_sys.setSupplyAirFlowRateMethodDuringCoolingOperation('SupplyAirFlowRate')
        unitary_sys.setSupplyAirFlowRateDuringCoolingOperation(airflow_stage4)
        # set heating design flow rate
        unitary_sys.setSupplyAirFlowRateMethodDuringHeatingOperation('SupplyAirFlowRate')
        unitary_sys.setSupplyAirFlowRateDuringHeatingOperation(airflow_stage4)
        # set no load design flow rate
        unitary_sys.setSupplyAirFlowRateMethodWhenNoCoolingorHeatingisRequired('SupplyAirFlowRate')
        unitary_sys.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(airflow_stage1)
      else
         # set cooling design flow rate
        unitary_sys.autosizeSupplyAirFlowRateDuringCoolingOperation
        unitary_sys.setSupplyAirFlowRateDuringCoolingOperation(airflow_stage4)
        # set heating design flow rate
        unitary_sys.autosizeSupplyAirFlowRateDuringHeatingOperation
        unitary_sys.setSupplyAirFlowRateDuringHeatingOperation(airflow_stage4)
        # set no load design flow rate
        unitary_sys.autosizeSupplyAirFlowRateWhenNoCoolingorHeatingisRequired
        unitary_sys.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(airflow_stage1)
      end
    end
    return true
  end
end

# register the measure to be used by the application
HvacDoasHpMinisplits.new.registerWithApplication
