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
require 'csv'

# require all .rb files in resources folder
Dir["#{File.dirname(__FILE__)}/resources/*.rb"].sort.each { |file| require file }

# start the measure
class AddPackagedGSHP < OpenStudio::Measure::ModelMeasure
  # resource file modules
  include MakePerformanceCurves

  # human readable name
  def name
    # Measure name should be the title case of the class name.
    'add_packaged_gshp'
  end

  # human readable description
  def description
    'Measure replaces existing packaged single-zone RTU system types with ground source heat pump RTUs.'
  end

  # human readable description of modeling approach
  def modeler_description
    'Modeler has option to set backup heat source, prevelence of heat pump oversizing, heat pump oversizing limit, and addition of energy recovery. This measure will work on unitary PSZ systems as well as single-zone, constant air volume air loop PSZ systems.'
  end

  # Define the name and description that will appear in the OpenStudio application
  def name
    'add_packaged_gshp'
  end

  def description
    'This measure replaces packaged single zone systems with a packaged water-to-air ground source heat pump system.'
  end

  def modeler_description
    'This measure identifies all packaged single zone systems in the model and replaces them with a packaged water-to-air ground source heat pump system.'
  end

  # Define the arguments that the user will input
  def arguments(_model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # add options for envelope and lighting measures for measure packages
    # add wall insulation option
    walls = OpenStudio::Measure::OSArgument.makeBoolArgument('walls', true)
    walls.setDisplayName('Upgrade Wall Insulation?')
    walls.setDefaultValue(false)
    args << walls

    # add roof insulation option
    roof = OpenStudio::Measure::OSArgument.makeBoolArgument('roof', true)
    roof.setDisplayName('Upgrade Roof Insulation?')
    roof.setDefaultValue(false)
    args << roof

    # add new windows option
    windows = OpenStudio::Measure::OSArgument.makeBoolArgument('windows', true)
    windows.setDisplayName('Upgrade to New Windows?')
    windows.setDefaultValue(false)
    args << windows

    # add LED lighting option
    lighting = OpenStudio::Measure::OSArgument.makeBoolArgument('lighting', true)
    lighting.setDisplayName('Upgrade to LED Lighting?')
    lighting.setDefaultValue(false)
    args << lighting

    # add options for efficiency measures to be combined with GHP
    # add dcv option
    dcv = OpenStudio::Measure::OSArgument.makeBoolArgument('dcv', true)
    dcv.setDisplayName('Add Demand Control Ventilation?')
    dcv.setDefaultValue(true)
    args << dcv

    # add economizer option
    econ = OpenStudio::Measure::OSArgument.makeBoolArgument('econ', true)
    econ.setDisplayName('Add Economizer?')
    econ.setDefaultValue(true)
    args << econ

    args
  end

  #### Predefined functions
  def thermal_zone_outdoor_airflow_rate(thermal_zone)
    tot_oa_flow_rate = 0.0

    spaces = thermal_zone.spaces.sort

    sum_floor_area = 0.0
    sum_number_of_people = 0.0
    sum_volume = 0.0

    # Variables for merging outdoor air
    sum_oa_for_people = 0.0
    sum_oa_for_floor_area = 0.0
    sum_oa_rate = 0.0
    sum_oa_for_volume = 0.0

    # Find common variables for the new space
    spaces.each do |space|
      floor_area = space.floorArea
      sum_floor_area += floor_area

      number_of_people = space.numberOfPeople
      sum_number_of_people += number_of_people

      volume = space.volume
      sum_volume += volume

      dsn_oa = space.designSpecificationOutdoorAir
      next if dsn_oa.empty?

      dsn_oa = dsn_oa.get

      # compute outdoor air rates in case we need them
      oa_for_people = number_of_people * dsn_oa.outdoorAirFlowperPerson
      oa_for_floor_area = floor_area * dsn_oa.outdoorAirFlowperFloorArea
      oa_rate = dsn_oa.outdoorAirFlowRate
      oa_for_volume = volume * dsn_oa.outdoorAirFlowAirChangesperHour / 3600

      # First check if this space uses the Maximum method and other spaces do not
      if dsn_oa.outdoorAirMethod == 'Maximum'
        sum_oa_rate += [oa_for_people, oa_for_floor_area, oa_rate, oa_for_volume].max
      elsif dsn_oa.outdoorAirMethod == 'Sum'
        sum_oa_for_people += oa_for_people
        sum_oa_for_floor_area += oa_for_floor_area
        sum_oa_rate += oa_rate
        sum_oa_for_volume += oa_for_volume
      end
    end

    tot_oa_flow_rate += sum_oa_for_people
    tot_oa_flow_rate += sum_oa_for_floor_area
    tot_oa_flow_rate += sum_oa_rate
    tot_oa_flow_rate += sum_oa_for_volume

    tot_oa_flow_rate
  end

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
    is_res_system
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
    is_evap
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
    is_unitary_system
  end

  # check if air loop uses district energy
  def air_loop_hvac_served_by_district_energy?(air_loop_hvac)
    served_by_district_energy = false
    thermalzones = air_loop_hvac.thermalZones
    district_energy_types = []
    thermalzones.each do |thermalzone|
      zone_fuels = ''
      htg_fuels = thermalzone.heatingFuelTypes.map(&:valueName)
      if htg_fuels.include?('DistrictHeating')
        zone_fuels = 'DistrictHeating'
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

  # Define the main method that will be called by the OpenStudio application
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # build standard to use OS standards methods
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)
    # get climate zone value
    OpenstudioStandards::Weather.model_get_climate_zone(model)

    # assign user inputs to variables
    dcv = runner.getBoolArgumentValue('dcv', user_arguments)
    econ = runner.getBoolArgumentValue('econ', user_arguments)
    walls = runner.getBoolArgumentValue('walls', user_arguments)
    roof = runner.getBoolArgumentValue('roof', user_arguments)
    windows = runner.getBoolArgumentValue('windows', user_arguments)
    lighting = runner.getBoolArgumentValue('lighting', user_arguments)

    # check if GroundHeatExchanger:Vertical is present (for package runs)
    if !model.getObjectsByType(OpenStudio::Model::GroundHeatExchangerVertical.iddObjectType).empty?
      runner.registerAsNotApplicable('Model already contains a GroundHeatExchanger:Vertical, upgrade is not applicable.')
      return true
    end

    # check if model has airloops, if not register not applicable
    all_air_loops = model.getAirLoopHVACs
    if all_air_loops.empty?
      runner.registerAsNotApplicable('Model has no air loops, meaning existing HVAC system is not PSZ, PVAV, or VAV and measure is not applicable.')
      return true
    end

    # check if any air loops are served by district energy, if so register not applicable
    all_air_loops.each do |air_loop_hvac|
      if air_loop_hvac_served_by_district_energy?(air_loop_hvac)
        runner.registerAsNotApplicable('Existing building served by district energy, measure is not applicable.')
        return true
      end
    end

    # make list of zone equipment to delete
    equip_to_delete = []
    # if zone has baseboard electric (typically small, storage style space types), skip this zone and do not add GHP here
    zones_to_skip = []
    unconditioned_zones = []
    # check for baseboard electric and add to array of zone equipment to delete
    model.getThermalZones.each do |thermal_zone|
      # if original zone has no equipment (unconditioned), skip this zone entirely
      if thermal_zone.equipment.empty?
        unconditioned_zones << thermal_zone.name.get
      # if original zone is typically conditioned with baseboards (as opposed to an RTU), maintain this
      elsif ['Bulk', 'Entry'].any? { |word| thermal_zone.name.get.include?(word) }
        zones_to_skip << thermal_zone.name.get
      end

      # delete old zone equipment except if its a baseboard or unit heater
      thermal_zone.equipment.each do |equip|
        # dont delete diffusers from PSZs, these will be reused
        next if equip.to_AirTerminalSingleDuctConstantVolumeNoReheat.is_initialized

        if equip.to_ZoneHVACBaseboardConvectiveElectric.is_initialized
          zones_to_skip << thermal_zone.name.get
        elsif equip.to_ZoneHVACUnitHeater.is_initialized
          zones_to_skip << thermal_zone.name.get
        else
          equip_to_delete << equip
        end
      end
    end

    # get applicable psz hvac air loops
    psz_air_loops = []
    pvav_air_loops = []
    all_air_loops.each do |air_loop_hvac|
      # skip units that are not single zone
      if air_loop_hvac.thermalZones.length == 1

        # skip DOAS units; check sizing for all OA and for DOAS in name
        sizing_system = air_loop_hvac.sizingSystem
        if sizing_system.allOutdoorAirinCooling && sizing_system.allOutdoorAirinHeating && (air_loop_res?(air_loop_hvac) == false) && (air_loop_hvac.name.to_s.include?('DOAS') || air_loop_hvac.name.to_s.include?('doas'))
          next
        end

        # skip if residential system
        next if air_loop_res?(air_loop_hvac)
        # skip if system has no outdoor air, also indication of residential system
        next unless air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized
        # skip if evaporative cooling systems
        next if air_loop_evaporative_cooler?(air_loop_hvac)

        # look for PVAV and VAV systems (some might only have 1 zone per air loop)
        if ['PVAV'].any? { |word| air_loop_hvac.name.get.include?(word) }
          air_loop_hvac.supplyComponents.each do |component|
            # filter out VAV with PFP boxes, which are labeled as PVAV systems but are actually VAV
            if component.to_CoilCoolingWater.is_initialized
              runner.registerAsNotApplicable('Air loop has a chilled water coil, indicating that it is a VAV chiller with PFP boxes system. Measure is not applicable.')
              return true
            end
          end
          runner.registerInfo("pvav air loop #{air_loop_hvac.name}")
          runner.registerInfo('Model has a PVAV system, measure will be applicable.')
          pvav_air_loops << air_loop_hvac
        elsif ['VAV'].any? { |word| air_loop_hvac.name.get.include?(word) }
          runner.registerAsNotApplicable('Model has VAV system, measure is not applicable.')
          return true
        else
          # add applicable air loop to list
          psz_air_loops << air_loop_hvac
        end
        # add area served by air loop
      elsif air_loop_hvac.thermalZones.length > 1
        # look for PVAV and VAV systems
        if ['PVAV'].any? { |word| air_loop_hvac.name.get.include?(word) }
          air_loop_hvac.supplyComponents.each do |component|
            # filter out VAV with PFP boxes, which are labeled as PVAV systems but are actually VAV
            if component.to_CoilCoolingWater.is_initialized
              runner.registerAsNotApplicable('Air loop has a chilled water coil, indicating that it is a VAV chiller with PFP boxes system. Measure is not applicable.')
              return true
            end
          end
          runner.registerInfo('Model has a PVAV system, measure will be applicable.')
          runner.registerInfo("pvav air loop #{air_loop_hvac.name}")
          pvav_air_loops << air_loop_hvac
        elsif ['VAV'].any? { |word| air_loop_hvac.name.get.include?(word) }
          runner.registerAsNotApplicable('Model has VAV system, measure is not applicable.')
          return true
        end
      end
    end

    # check if there are any packaged single zone systems in the model
    if psz_air_loops.empty? && pvav_air_loops.empty?
      runner.registerAsNotApplicable('Model has no applicable air loops, measure is not applicable.')
      return true
    end

    # initialize variables for reporting
    condition_final_walls = ''
    condition_final_roof = ''
    condition_final_windows = ''
    condition_final_lighting = ''

    # after finished checking for non applicable models, run envelope measures as package if user arguments are true
    # run wall insulation measure if user argument is true
    if walls == true
      runner.registerInfo('Running Wall Insulation measure....')
      results_walls, runner = call_walls(model, runner)
      results_walls.stepInitialCondition.get if results_walls.stepInitialCondition.is_initialized
      condition_final_walls = results_walls.stepFinalCondition.get if results_walls.stepFinalCondition.is_initialized
    end

    # run roof insulation measure if user argument is true
    if roof == true
      runner.registerInfo('Running Roof Insulation measure....')
      results_roof, runner = call_roof(model, runner)
      results_roof.stepInitialCondition.get if results_roof.stepInitialCondition.is_initialized
      condition_final_roof = results_roof.stepFinalCondition.get if results_roof.stepFinalCondition.is_initialized
    end

    # run new windows measure if user argument is true
    if windows == true
      runner.registerInfo('Running New Windows measure....')
      results_windows, runner = call_windows(model, runner)
      results_windows.stepInitialCondition.get if results_windows.stepInitialCondition.is_initialized
      if results_windows.stepFinalCondition.is_initialized
        condition_final_windows = results_windows.stepFinalCondition.get
      end
    end

    # run lighting measure if user argument is true
    if lighting == true
      runner.registerInfo('Running LED Lighting measure....')
      results_lighting, runner = call_lighting(model, runner)
      results_lighting.stepInitialCondition.get if results_lighting.stepInitialCondition.is_initialized
      if results_lighting.stepFinalCondition.is_initialized
        condition_final_lighting = results_lighting.stepFinalCondition.get
      end
    end

    # remove existing plant loops from model
    plant_loops = model.getPlantLoops
    if plant_loops.size >> 0
      plant_loops.each do |plant_loop|
        # do not delete service water heating loops
        next if ['Service'].any? { |word| plant_loop.name.get.include?(word) }

        runner.registerInfo("Removed existing plant loop #{plant_loop.name}.")
        plant_loop.remove
      end
    end

    cond_loop_setpoint_c = 18.3 # 65F
    preheat_coil_min_temp = 10.0 # 50F

    # add condenser loop to connect heat pumps loops with ground loop
    condenser_loop = OpenStudio::Model::PlantLoop.new(model)
    runner.registerInfo('Condenser Loop added.')
    condenser_loop.setName('Condenser Loop')
    condenser_loop.setMaximumLoopTemperature(100.0)
    condenser_loop.setMinimumLoopTemperature(10.0)
    condenser_loop.setLoadDistributionScheme('SequentialLoad')
    condenser_loop_sizing = condenser_loop.sizingPlant
    condenser_loop_sizing.setLoopType('Condenser')
    condenser_loop_sizing.setDesignLoopExitTemperature(cond_loop_setpoint_c)

    # Create a scheduled setpoint manager
    # TODO determine if a schedule that follows the monthly ground temperature
    # would result in significantly different loads
    condenser_high_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
    condenser_high_temp_sch.setName('Condenser Loop High Temp Schedule')
    condenser_high_temp_sch.setValue(29.44) # C
    condenser_low_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
    condenser_low_temp_sch.setName('Condenser Loop Low Temp Schedule')
    condenser_low_temp_sch.setValue(4.44) # C
    condenser_setpoint_manager = OpenStudio::Model::SetpointManagerScheduledDualSetpoint.new(model)
    condenser_setpoint_manager.setName('Condenser Loop Setpoint Manager')
    condenser_setpoint_manager.setHighSetpointSchedule(condenser_high_temp_sch)
    condenser_setpoint_manager.setLowSetpointSchedule(condenser_low_temp_sch)
    condenser_setpoint_manager.addToNode(condenser_loop.supplyOutletNode)

    # Create and add a pump to the loop
    condenser_pump = OpenStudio::Model::PumpVariableSpeed.new(model)
    condenser_pump.setName('Condenser loop circulation pump')
    condenser_pump.setPumpControlType('Continuous')
    condenser_pump.setRatedPumpHead(44_834.7) # 15 ft for primary pump for a primary-secondary system based on Appendix G; does this need to change?
    condenser_pump.addToNode(condenser_loop.supplyInletNode)

    # Create new loop connecting heat pump and ground heat exchanger.
    # Initially, a PlantLoop:TemperatureSource object will be used.
    # After a GHEDesigner simulation is run the PlantLoop:TemperatureSource
    # object will be replaced with a vertical ground heat exchanger
    # with borehole properties and G-functions per the GHEDesigner output.
    ground_loop = OpenStudio::Model::PlantLoop.new(model)
    runner.registerInfo('Ground Loop added.')
    ground_loop.setName('Ground Loop')
    ground_loop.setMaximumLoopTemperature(100.0)
    ground_loop.setMinimumLoopTemperature(10.0)
    ground_loop.setLoadDistributionScheme('SequentialLoad')
    ground_loop_sizing = ground_loop.sizingPlant
    ground_loop_sizing.setLoopType('Condenser') # is this right?
    ground_loop_sizing.setDesignLoopExitTemperature(18.33)

    # set fluid as 20% propyleneglycol
    ground_loop.setGlycolConcentration(20)
    ground_loop.setFluidType('PropyleneGlycol')

    # add water to water heat exchanger
    fluid_fluid_heat_exchanger = OpenStudio::Model::HeatExchangerFluidToFluid.new(model)
    fluid_fluid_heat_exchanger.setName('HX for heat pump')
    fluid_fluid_heat_exchanger.setHeatExchangeModelType('Ideal')
    fluid_fluid_heat_exchanger.setControlType('UncontrolledOn')
    fluid_fluid_heat_exchanger.setHeatTransferMeteringEndUseType('LoopToLoop')
    ground_loop.addDemandBranchForComponent(fluid_fluid_heat_exchanger)
    condenser_loop.addSupplyBranchForComponent(fluid_fluid_heat_exchanger)

    # Create and add a pump to the loop
    ground_pump = OpenStudio::Model::PumpConstantSpeed.new(model)
    ground_pump.setName('Ground loop circulation pump')
    ground_pump.setPumpControlType('Continuous')
    ground_pump.setRatedPumpHead(44_834.7) # 15 ft for primary pump for a primary-secondary system based on Appendix G; does this need to change?
    ground_pump.addToNode(ground_loop.supplyInletNode)

    # Create a scheduled setpoint manager
    # TODO determine if a schedule that follows the monthly ground temperature
    # would result in significantly different loads
    ground_high_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
    ground_high_temp_sch.setName('Ground Loop High Temp Schedule')
    ground_high_temp_sch.setValue(24.0) # C
    ground_low_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
    ground_low_temp_sch.setName('Ground Loop Low Temp Schedule')
    ground_low_temp_sch.setValue(12.78) # C
    ground_setpoint_manager = OpenStudio::Model::SetpointManagerScheduledDualSetpoint.new(model)
    ground_setpoint_manager.setName('Ground Loop Setpoint Manager')
    ground_setpoint_manager.setHighSetpointSchedule(ground_high_temp_sch)
    ground_setpoint_manager.setLowSetpointSchedule(ground_low_temp_sch)
    ground_setpoint_manager.addToNode(ground_loop.supplyOutletNode)

    # Create and add a PlantComponent:TemperatureSource object to supply side of ground loop
    ground_temp_source = OpenStudio::Model::PlantComponentTemperatureSource.new(model)
    ground_temp_source.setName('Ground Loop Temperature Source (Ground Heat Exchanger Placeholder)')
    ground_temp_source.autosizeDesignVolumeFlowRate
    ground_temp_source.setTemperatureSpecificationType('Constant')
    ground_temp_source.setSourceTemperature(12.78)

    # Add temp source to the supply side of the ground loop
    ground_loop.addSupplyBranchForComponent(ground_temp_source)

    # get necessary schedules, etc. from unitary system object
    # initialize variables before loop
    unitary_availability_sched = 'tmp'
    control_zone = 'tmp'
    dehumid_type = 'tmp'
    supply_fan_op_sched = 'tmp'
    supply_fan_avail_sched = 'tmp'
    fan_tot_eff = 0.63
    fan_mot_eff = 0.29
    fan_static_pressure = 50.0

    min_flow = 0.66 # based on airflow turndown for Trane GWS 10-ton unit
    zone_data = {} # create a hash to store zone level hvac data

    # Get ventilation rates for PVAV systems
    pvav_air_loops.each do |pvav_air_loop|
      pvav_air_loop.thermalZones
      # get the air loop HVAC availability schedule
      hvac_operation_sched = pvav_air_loop.availabilitySchedule
      if hvac_operation_sched.to_ScheduleConstant.is_initialized
        hvac_operation_sched = hvac_operation_sched.to_ScheduleConstant.get
      elsif hvac_operation_sched.to_ScheduleRuleset.is_initialized
        hvac_operation_sched = hvac_operation_sched.to_ScheduleRuleset.get
      else
        runner.registerError("Air loop availability schedule for #{air_loop_hvac.name} not supported.")
        return false
      end
      prev_pressure_rise = 0
      if pvav_air_loop.supplyFan.is_initialized
        fan = pvav_air_loop.supplyFan.get
        runner.registerInfo("fan #{fan}")
        if fan.to_FanVariableVolume.is_initialized
          fan = fan.to_FanVariableVolume.get
          prev_pressure_rise = fan.pressureRise
        end
      end

      pvav_air_loop.thermalZones.each do |thermal_zone|
        zone_data[thermal_zone.name.to_s] = {} # creating as a placeholder
        zone_data["#{thermal_zone.name} schedule"] = hvac_operation_sched # save operation schedule from main air loop for use later
        pfp_box = false

        zone_data[thermal_zone.name.to_s]['prev_pressure_rise'] = prev_pressure_rise if prev_pressure_rise > 0

        zone_oa_flow = thermal_zone_outdoor_airflow_rate(thermal_zone)
        zone_data["#{thermal_zone.name} zone_oa_flow"] = zone_oa_flow
        runner.registerInfo("zone oa flow for #{thermal_zone.name} zone #{zone_oa_flow}")
        if thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeReheat.is_initialized
          old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeReheat.get
        elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeNoReheat.is_initialized
          old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeNoReheat.get
        elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVHeatAndCoolNoReheat.is_initialized
          old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVHeatAndCoolNoReheat.get
        elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVHeatAndCoolReheat.is_initialized
          old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVHeatAndCoolReheat.get
        elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVNoReheat.is_initialized
          old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVNoReheat.get
        elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVReheat.is_initialized
          old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVReheat.get
        elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctParallelPIUReheat.is_initialized
          old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctParallelPIUReheat.get
          pfp_box = true
        else
          runner.registerError("Terminal box type for air loop #{air_loop_hvac.name} not supported.")
          return false
        end
        # get design oa flow rate for previous terminal box to set min oa ratio
        old_terminal_sa_flow_m3_per_s = nil
        if !pfp_box
          if old_terminal.maximumAirFlowRate.is_initialized
            old_terminal_sa_flow_m3_per_s = old_terminal.maximumAirFlowRate.get
          elsif old_terminal.isMaximumAirFlowRateAutosized
            old_terminal_sa_flow_m3_per_s = old_terminal.autosizedMaximumAirFlowRate.get
          else
            runner.registerError("No sizing data available for air loop #{air_loop_hvac.name} zone terminal box.")
          end
        elsif pfp_box
          if old_terminal.maximumPrimaryAirFlowRate.is_initialized
            old_terminal_sa_flow_m3_per_s = old_terminal.maximumPrimaryAirFlowRate.get
          elsif old_terminal.isMaximumPrimaryAirFlowRateAutosized
            old_terminal_sa_flow_m3_per_s = old_terminal.autosizedMaximumPrimaryAirFlowRate.get
          else
            runner.registerError("No sizing data available for air loop #{air_loop_hvac.name} zone terminal box.")
          end
        end

        zone_data["#{thermal_zone.name} min_oa_flow_ratio"] = zone_oa_flow / old_terminal_sa_flow_m3_per_s
        zone_data["#{thermal_zone.name} old_term_sa_flow_m3_per_s"] = old_terminal_sa_flow_m3_per_s
      end
    end

    # Loop through each packaged single zone system and replace it with a water-to-air ground source heat pump system
    psz_air_loops.each do |air_loop_hvac|
      pfp_box = false
      thermal_zone = air_loop_hvac.thermalZones[0]
      # get OA system data for use later
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      oa_system.getControllerOutdoorAir

      # get old terminal box
      if thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeReheat.is_initialized
        old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeReheat.get
      elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeNoReheat.is_initialized
        old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctConstantVolumeNoReheat.get
      elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVHeatAndCoolNoReheat.is_initialized
        old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVHeatAndCoolNoReheat.get
      elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVHeatAndCoolReheat.is_initialized
        old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVHeatAndCoolReheat.get
      elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVNoReheat.is_initialized
        old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVNoReheat.get
      elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVReheat.is_initialized
        old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctVAVReheat.get
      elsif thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctParallelPIUReheat.is_initialized
        old_terminal = thermal_zone.airLoopHVACTerminal.get.to_AirTerminalSingleDuctParallelPIUReheat.get
      else
        runner.registerError("Terminal box type for air loop #{air_loop_hvac.name} not supported.")
        return false
      end

      # get design outdoor air flow rate
      # loop through thermal zones
      oa_flow_m3_per_s = thermal_zone_outdoor_airflow_rate(thermal_zone)

      # get design supply air flow rate
      old_terminal_sa_flow_m3_per_s = nil
      if !pfp_box
        if old_terminal.maximumAirFlowRate.is_initialized
          old_terminal_sa_flow_m3_per_s = old_terminal.maximumAirFlowRate.get
        elsif old_terminal.isMaximumAirFlowRateAutosized
          old_terminal_sa_flow_m3_per_s = old_terminal.autosizedMaximumAirFlowRate.get
        else
          runner.registerError("No sizing data available for air loop #{air_loop_hvac.name} zone terminal box.")
        end
      elsif pfp_box
        if old_terminal.maximumPrimaryAirFlowRate.is_initialized
          old_terminal_sa_flow_m3_per_s = old_terminal.maximumPrimaryAirFlowRate.get
        elsif old_terminal.isMaximumPrimaryAirFlowRateAutosized
          old_terminal_sa_flow_m3_per_s = old_terminal.autosizedMaximumPrimaryAirFlowRate.get
        else
          runner.registerError("No sizing data available for air loop #{air_loop_hvac.name} zone terminal box.")
        end
      end

      # define minimum flow rate needed to maintain ventilation
      zone_data["#{thermal_zone.name} zone_oa_flow"] = oa_flow_m3_per_s
      min_oa_flow_ratio = (oa_flow_m3_per_s / old_terminal_sa_flow_m3_per_s)
      zone_data["#{thermal_zone.name} min_oa_flow_ratio"] = min_oa_flow_ratio
      runner.registerInfo("zone #{thermal_zone.name}" + "old term sa flow #{old_terminal_sa_flow_m3_per_s}")
      runner.registerInfo("zone #{thermal_zone.name}" + "oa flow  #{oa_flow_m3_per_s}")
      runner.registerInfo("zone #{thermal_zone.name}" + "min airflow ratio #{min_oa_flow_ratio}")
      zone_data["#{thermal_zone.name} old_term_sa_flow_m3_per_s"] = old_terminal_sa_flow_m3_per_s

      # get the air loop HVAC availability schedule and save it
      hvac_operation_sched = air_loop_hvac.availabilitySchedule
      if hvac_operation_sched.to_ScheduleConstant.is_initialized
        hvac_operation_sched = hvac_operation_sched.to_ScheduleConstant.get
      elsif hvac_operation_sched.to_ScheduleRuleset.is_initialized
        hvac_operation_sched = hvac_operation_sched.to_ScheduleRuleset.get
      else
        runner.registerError("Air loop availability schedule for #{air_loop_hvac.name} not supported.")
        return false
      end
      zone_data["#{thermal_zone.name} schedule"] = hvac_operation_sched

      # for unitary systems
      if air_loop_hvac_unitary_system?(air_loop_hvac)

        # loop through each relevant component.
        # store information needed as variable
        # remove the existing equipment
        air_loop_hvac.supplyComponents.each do |component|
          # convert component to string name
          obj_type = component.iddObjectType.valueName.to_s
          # skip unless component is of relevant type
          next unless ['Fan', 'Unitary', 'Coil'].any? { |word| obj_type.include?(word) }

          # make list of equipment to delete
          equip_to_delete << component

          # get information specifically from unitary system object
          next unless ['Unitary'].any? do |word|
                        obj_type.include?(word)
                      end
          # TODO: There are more unitary systems types we are not including here

          # get unitary system
          unitary_sys = component.to_AirLoopHVACUnitarySystem.get
          # get availability schedule
          unitary_availability_sched = unitary_sys.availabilitySchedule.get
          # get control zone
          control_zone = unitary_sys.controllingZoneorThermostatLocation.get
          # get dehumidification control type
          dehumid_type = unitary_sys.dehumidificationControlType
          # get supply fan operation schedule
          supply_fan_op_sched = unitary_sys.supplyAirFanOperatingModeSchedule.get
          # get supply fan availability schedule
          supply_fan = unitary_sys.supplyFan.get
          # convert supply fan to appropriate object to access methods
          if supply_fan.to_FanConstantVolume.is_initialized
            supply_fan = supply_fan.to_FanConstantVolume.get
          elsif supply_fan.to_FanOnOff.is_initialized
            supply_fan = supply_fan.to_FanOnOff.get
          elsif supply_fan.to_FanVariableVolume.is_initialized
            supply_fan = supply_fan.to_FanVariableVolume.get
          else
            runner.registerError("Supply fan type for #{air_loop_hvac.name} not supported.")
            return false
          end
          # Get attributes from exisitng supply fan
          pressure_rise = supply_fan.pressureRise
          zone_data[thermal_zone.name.to_s] = {}
          zone_data[thermal_zone.name.to_s]['pressure_rise'] = pressure_rise
          std.fan_motor_horsepower(supply_fan) # based on existing fan
          motor_bhp = std.fan_brake_horsepower(supply_fan)
          fan_motor_eff = std.fan_standard_minimum_motor_efficiency_and_size(supply_fan, motor_bhp)[0]
          zone_data[thermal_zone.name.to_s]['fan_motor_eff'] = fan_motor_eff
          fan_eff = std.fan_baseline_impeller_efficiency(supply_fan)
          zone_data[thermal_zone.name.to_s]['fan_eff'] = fan_eff

          # get the availability schedule
          supply_fan_avail_sched = supply_fan.availabilitySchedule
          if supply_fan_avail_sched.to_ScheduleConstant.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          elsif supply_fan_avail_sched.to_ScheduleRuleset.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          else
            runner.registerError("Supply fan availability schedule type for #{supply_fan.name} not supported.")
            return false
          end
          # TODO: figure out if fan and coils should be hardsized or autosized; if autosized, can probably delete this section of code
          # get supply fan motor efficiency
          fan_tot_eff = supply_fan.fanTotalEfficiency
          # get supply motor efficiency
          fan_mot_eff = supply_fan.motorEfficiency
          # get supply fan static pressure
          fan_static_pressure = supply_fan.pressureRise
        end

      # get non-unitary system objects.
      else
        # loop through components
        air_loop_hvac.supplyComponents.each do |component|
          # convert component to string name
          obj_type = component.iddObjectType.valueName.to_s
          # skip unless component is of relevant type
          next unless ['Fan', 'Unitary', 'Coil'].any? { |word| obj_type.include?(word) }

          # make list of equipment to delete
          equip_to_delete << component

          # check for fan
          next unless ['Fan'].any? { |word| obj_type.include?(word) }

          supply_fan = component
          if supply_fan.to_FanConstantVolume.is_initialized
            supply_fan = supply_fan.to_FanConstantVolume.get
          elsif supply_fan.to_FanOnOff.is_initialized
            supply_fan = supply_fan.to_FanOnOff.get
          elsif supply_fan.to_FanVariableVolume.is_initialized
            supply_fan = supply_fan.to_FanVariableVolume.get
          else
            runner.registerError("Supply fan type for #{air_loop_hvac.name} not supported.")
            return false
          end
          # get the availability schedule
          supply_fan_avail_sched = supply_fan.availabilitySchedule
          if supply_fan_avail_sched.to_ScheduleConstant.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          elsif supply_fan_avail_sched.to_ScheduleRuleset.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          else
            runner.registerError("Supply fan availability schedule type for #{supply_fan.name} not supported.")
            return false
          end
          # get supply fan motor efficiency
          fan_tot_eff = supply_fan.fanTotalEfficiency
          # get supply motor efficiency
          fan_mot_eff = supply_fan.motorEfficiency
          # get supply fan static pressure
          fan_static_pressure = supply_fan.pressureRise
          # set unitary supply fan operating schedule equal to system schedule for non-unitary systems
          supply_fan_op_sched = hvac_operation_sched
          # set dehumidification type
          dehumid_type = 'None'
          # set control zone to the thermal zone. This will be used in new unitary system object
          control_zone = air_loop_hvac.thermalZones[0]
          # set unitary availability schedule to be always on. This will be used in new unitary system object.
          # unitary_availability_sched = model.alwaysOnDiscreteSchedule ##AA no longer needed since setting schedule based on previous air loop's schedule
        end
      end

      # # Get the min OA flow rate from the OA; this is used below
      # oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      # controller_oa = oa_system.getControllerOutdoorAir
      # oa_flow_m3_per_s = nil
      # if controller_oa.minimumOutdoorAirFlowRate.is_initialized
      # 	oa_flow_m3_per_s = controller_oa.minimumOutdoorAirFlowRate.get
      # elsif controller_oa.autosizedMinimumOutdoorAirFlowRate.is_initialized
      # 	oa_flow_m3_per_s = controller_oa.autosizedMinimumOutdoorAirFlowRate.get
      # else
      # 	runner.registerError("No outdoor air sizing information was found for #{controller_oa.name}, which is required for setting ERV wheel power consumption.")
      # 	return false
      # end
    end

    equip_to_delete.each(&:remove)

    # remove old PVAV air loops; this must be done after removing zone equipment or it will cause segmentation fault
    pvav_air_loops.each(&:remove)

    # also remove any EMS objects tied to PVAV air loops that are being removed
    # Get all EMS objects in the model
    ems_objects = model.getEnergyManagementSystemSensors.to_a + model.getEnergyManagementSystemActuators.to_a + model.getEnergyManagementSystemPrograms.to_a + model.getEnergyManagementSystemProgramCallingManagers.to_a + model.getEnergyManagementSystemInternalVariables.to_a

    # Filter EMS objects that contain "pvav"
    ems_objects_to_remove = ems_objects.select { |ems_object| ems_object.name.to_s.include?('PVAV') }

    # Remove each matching EMS object from the model
    ems_objects_to_remove.each do |object_to_remove|
      # Remove the EMS object from the model
      runner.registerInfo('Removing unused PVAV EMS objects from the model.')
      object_to_remove.remove
    end

    # loop through thermal zones and add
    model.getThermalZones.each do |thermal_zone|
      # skip if zone has baseboards and should not get a GHP
      next if zones_to_skip.include? thermal_zone.name.get
      next if unconditioned_zones.include? thermal_zone.name.get

      # set always on schedule; this will be used in other object definitions
      always_on = model.alwaysOnDiscreteSchedule
      supply_fan_avail_sched = model.alwaysOnDiscreteSchedule # Needed due to the coil's requirement for consistent airflow
      fan_location = 'DrawThrough'

      if thermal_zone.airLoopHVAC.is_initialized
        air_loop_hvac = thermal_zone.airLoopHVAC.get
        air_loop_hvac.setAvailabilitySchedule(zone_data["#{thermal_zone.name} schedule"])
        runner.registerInfo('setting schedule')
      else
        # create new air loop for unitary system
        air_loop_hvac = OpenStudio::Model::AirLoopHVAC.new(model)
        air_loop_hvac.setName("#{thermal_zone.name} Air Loop")
        air_loop_hvac.sizingSystem
        # Set schedule based on that zone's previous schedule
        air_loop_hvac.setAvailabilitySchedule(zone_data["#{thermal_zone.name} schedule"])

        # zone sizing
        # adjusted zone design temperatures for ptac
        dsgn_temps = std.standard_design_sizing_temperatures
        dsgn_temps['zn_htg_dsgn_sup_air_temp_f'] = 122.0
        dsgn_temps['zn_htg_dsgn_sup_air_temp_c'] =
          OpenStudio.convert(dsgn_temps['zn_htg_dsgn_sup_air_temp_f'], 'F', 'C').get
        dsgn_temps['zn_clg_dsgn_sup_air_temp_f'] = 57.0
        dsgn_temps['zn_clg_dsgn_sup_air_temp_c'] =
          OpenStudio.convert(dsgn_temps['zn_clg_dsgn_sup_air_temp_f'], 'F', 'C').get
        sizing_zone = thermal_zone.sizingZone
        sizing_zone.setZoneCoolingDesignSupplyAirTemperature(dsgn_temps['zn_clg_dsgn_sup_air_temp_c'])
        sizing_zone.setZoneHeatingDesignSupplyAirTemperature(dsgn_temps['zn_htg_dsgn_sup_air_temp_c'])
        sizing_zone.setZoneCoolingDesignSupplyAirHumidityRatio(0.008)
        sizing_zone.setZoneHeatingDesignSupplyAirHumidityRatio(0.008)

        # to account for turndown limitations and ventilation requirements
        min_fan_flow_ratio = if zone_data["#{thermal_zone.name} min_oa_flow_ratio"].nil?
                               min_flow
                             else
                               [zone_data["#{thermal_zone.name} min_oa_flow_ratio"], min_flow].max
                             end

        # create a diffuser and attach the zone/diffuser pair to the air loop
        diffuser = OpenStudio::Model::AirTerminalSingleDuctVAVHeatAndCoolNoReheat.new(model)
        diffuser.autosizeMaximumAirFlowRate # autosize maximum airflow rate
        diffuser.setZoneMinimumAirFlowFraction(min_fan_flow_ratio)
        diffuser.setName("#{air_loop_hvac.name} Diffuser")
        air_loop_hvac.multiAddBranchForZone(thermal_zone, diffuser.to_HVACComponent.get)

        # make outdoor air fraction for constant 15%
        pct_oa = OpenStudio::Model::ScheduleConstant.new(model)
        pct_oa.setName('Outdoor Air Fraction 15%')
        pct_oa.setValue(0.15)

        # add the OA system
        oa_controller = OpenStudio::Model::ControllerOutdoorAir.new(model)
        oa_controller.setName("#{air_loop_hvac.name} OA System Controller")
        oa_controller.setMinimumOutdoorAirSchedule(always_on)
        oa_controller.autosizeMinimumOutdoorAirFlowRate
        oa_controller.resetEconomizerMinimumLimitDryBulbTemperature
        oa_controller.setMinimumFractionofOutdoorAirSchedule(pct_oa)
        oa_system = OpenStudio::Model::AirLoopHVACOutdoorAirSystem.new(model, oa_controller)
        oa_system.setName("#{air_loop_hvac.name} OA System")
        oa_system.addToNode(air_loop_hvac.supplyInletNode)
      end

      # add new single speed cooling coil
      new_cooling_coil = OpenStudio::Model::CoilCoolingWaterToAirHeatPumpEquationFit.new(model)
      new_cooling_coil.setName("#{air_loop_hvac.name} Heat Pump Cooling Coil")

      new_cooling_coil.setRatedCoolingCoefficientofPerformance(3.4)
      condenser_loop.addDemandBranchForComponent(new_cooling_coil)

      # add new single speed heating coil
      new_heating_coil = OpenStudio::Model::CoilHeatingWaterToAirHeatPumpEquationFit.new(model)
      new_heating_coil.setName("#{air_loop_hvac.name} Heat Pump Heating Coil")

      new_heating_coil.setRatedHeatingCoefficientofPerformance(4.2)
      condenser_loop.addDemandBranchForComponent(new_heating_coil)

      # add supply fan
      fan = OpenStudio::Model::FanVariableVolume.new(model)
      fan.setName("#{air_loop_hvac.name} Fan")
      # set pressure rise based on previous fan, since assuming distribution system characteristics remain basically the same
      # check for a similar fan in the baseline to set these parameters based on--otherwise, will do so after sizing
      unless zone_data[thermal_zone.name.to_s]['pressure_rise'].nil?
        fan.setPressureRise(zone_data[thermal_zone.name.to_s]['pressure_rise'])
        # Set fan motor eff and fan total eff based on current standards applied to previous fan sizing, assuming sizing will be similar and new fan being installed
        fan.setFanTotalEfficiency(zone_data[thermal_zone.name.to_s]['fan_eff'] * zone_data[thermal_zone.name.to_s]['fan_motor_eff'])
        fan.setMotorEfficiency(zone_data[thermal_zone.name.to_s]['fan_motor_eff'])
      end
      # to account for turndown limitations and ventilation requirements
      min_fan_flow_ratio = if zone_data["#{thermal_zone.name} min_oa_flow_ratio"].nil?
                             min_flow
                           else
                             [zone_data["#{thermal_zone.name} min_oa_flow_ratio"], min_flow].max
                           end
      fan.setFanPowerMinimumFlowRateInputMethod('Fraction')
      fan.setFanPowerMinimumFlowFraction(min_fan_flow_ratio) # need to add check for ventilation
      # set fan curve coefficients
      std.fan_variable_volume_set_control_type(fan, 'Single Zone VAV Fan ')
      zone_data["#{thermal_zone.name} min_fan_flow_ratio"] = min_fan_flow_ratio


      # Create a new water-to-air ground source heat pump system
      unitary_system = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
      unitary_system.setControlType('Load')
      unitary_system.setControllingZoneorThermostatLocation(thermal_zone)
      unitary_system.setCoolingCoil(new_cooling_coil)
      unitary_system.setHeatingCoil(new_heating_coil)
      unitary_system.setControllingZoneorThermostatLocation(thermal_zone)
      unitary_system.setSupplyFan(fan)
      unitary_system.setFanPlacement(fan_location)
      unitary_system.setSupplyAirFanOperatingModeSchedule(model.alwaysOnDiscreteSchedule) # #needs to be set this way for the water-to-air heat pump coils
      unitary_system.setMaximumOutdoorDryBulbTemperatureforSupplementalHeaterOperation(OpenStudio.convert(40.0, 'F',
                                                                                                          'C').get)
      unitary_system.setName("#{air_loop_hvac.name} Unitary HP")
      unitary_system.setMaximumSupplyAirTemperature(40.0)
      if model.version < OpenStudio::VersionString.new('3.7.0')
        unitary_system.setSupplyAirFlowRateMethodDuringCoolingOperation('SupplyAirFlowRate')
        unitary_system.setSupplyAirFlowRateMethodDuringHeatingOperation('SupplyAirFlowRate')
        unitary_system.setSupplyAirFlowRateMethodWhenNoCoolingorHeatingisRequired('SupplyAirFlowRate')
      else
        unitary_system.autosizeSupplyAirFlowRateDuringCoolingOperation
        unitary_system.autosizeSupplyAirFlowRateDuringHeatingOperation
      end
      unitary_system.setSupplyAirFlowRateMethodWhenNoCoolingorHeatingisRequired('SupplyAirFlowRate')

      unitary_system.addToNode(air_loop_hvac.supplyOutletNode)

      # create a scheduled setpoint manager
      hp_setpoint_manager = OpenStudio::Model::SetpointManagerSingleZoneReheat.new(model)
      hp_setpoint_manager.setName('HP Supply Temp Setpoint Manager')
      hp_setpoint_manager.setMinimumSupplyAirTemperature(12.78)
      hp_setpoint_manager.setMaximumSupplyAirTemperature(50.0)
      hp_setpoint_manager.addToNode(air_loop_hvac.supplyOutletNode)

      # add electric preheat coil to OA system to temper ventilation air
      preheat_coil = OpenStudio::Model::CoilHeatingElectric.new(model)
      preheat_coil.setName('Electric Preheat Coil')
      preheat_coil.setEfficiency(0.95)

      # get inlet node of unitary system to place preheat coil
      preheat_coil_location = unitary_system.airInletModelObject.get.to_Node.get
      preheat_coil.addToNode(preheat_coil_location)

      # Create a scheduled setpoint manager
      # would result in significantly different loads
      preheat_coil_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
      preheat_coil_temp_sch.setName('Preheat Coil Temp Schedule')
      preheat_coil_temp_sch.setValue(preheat_coil_min_temp)
      preheat_coil_setpoint_manager = OpenStudio::Model::SetpointManagerScheduled.new(model, preheat_coil_temp_sch)
      preheat_coil_setpoint_manager.setControlVariable('Temperature')
      preheat_coil_setpoint_manager.setName('OA Preheat Coil Setpoint Manager')

      # get outlet node of preheat coil to place setpoint manager
      preheat_sm_location = preheat_coil.outletModelObject.get.to_Node.get
      preheat_coil_setpoint_manager.addToNode(preheat_sm_location)
    end

    # for zones that got skipped, check if there are already baseboards. if not, add them.
    model.getThermalZones.each do |thermal_zone|
      if unconditioned_zones.include? thermal_zone.name.get
        runner.registerInfo("Thermal zone #{thermal_zone} was unconditioned in the baseline, and will not receive a packaged GHP.")
      elsif zones_to_skip.include? thermal_zone.name.get
        if thermal_zone.equipment.empty?
          baseboard = OpenStudio::Model::ZoneHVACBaseboardConvectiveElectric.new(model)
          baseboard.setName("#{thermal_zone.name} Electric Baseboard")
          baseboard.setEfficiency(1.0)
          baseboard.autosizeNominalCapacity
          baseboard.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
          baseboard.addToThermalZone(thermal_zone)
        end
      end
    end

    # set initial and final conditions for reporting

    # add dcv to air loop if dcv arg is true
    if dcv == true
      runner.registerInfo('Running DCV measure....')
      results_dcv, runner = call_dcv(model, runner)
      results_dcv.stepInitialCondition.get if results_dcv.stepInitialCondition.is_initialized
      results_dcv.stepFinalCondition.get if results_dcv.stepFinalCondition.is_initialized
    end

    # add economizer if economizer arg is true
    if econ == true
      runner.registerInfo('Running Economizer measure....')
      results_econ, runner = call_econ(model, runner)
      results_econ.stepInitialCondition.get if results_econ.stepInitialCondition.is_initialized
      results_econ.stepFinalCondition.get if results_econ.stepFinalCondition.is_initialized
    end

    # do sizing run to get coil capacities to scale coil performance data
    if std.model_run_sizing_run(model, "#{Dir.pwd}/coil_curving_scaling_SR") == false
      runner.registerError('Sizing run to scale coil performance data failed, cannot hard-size model.')
      # puts("Sizing run to scale coil performance data failed, cannot hard-size model.")
      # puts("directory: #{Dir.pwd}/CoilCurveScalingSR")
      return false
    end

    # apply sizing values
    model.applySizingValues

    # scale coil performance data and assign lookup tables
    model.getAirLoopHVACUnitarySystems.each do |unitary_sys|
      # puts "*************************************"
      # puts "*************************************"
      # puts "Assigning performance curve data for unitary system (#{unitary_sys.name})"
      # get cooling coil
      # get heating coil
      # get fan
      heating_air_flow = 0
      heating_water_flow = 0
      cooling_air_flow = 0
      cooling_water_flow = 0

      # set maximum supply air temperature back to 40C because sizing may have changed it
      unitary_sys.setMaximumSupplyAirTemperature(40.0)

      # heating coil
      if unitary_sys.heatingCoil.is_initialized
        if unitary_sys.heatingCoil.get.to_CoilHeatingWaterToAirHeatPumpEquationFit.is_initialized
          coil = unitary_sys.heatingCoil.get.to_CoilHeatingWaterToAirHeatPumpEquationFit.get
          # capacity
          if coil.ratedHeatingCapacity.is_initialized
            coil.ratedHeatingCapacity.get
          else
            runner.registerError("Unable to retrieve reference capacity for coil (#{coil.name})")
            return false
          end
          # air flow
          if coil.ratedAirFlowRate.is_initialized
            heating_air_flow = coil.ratedAirFlowRate.get
          else
            runner.registerError("Unable to retrieve reference air flow for coil (#{coil.name})")
            return false
          end
          # water flow
          if coil.ratedWaterFlowRate.is_initialized
            heating_water_flow = coil.ratedWaterFlowRate.get
          else
            runner.registerError("Unable to retrieve reference water flow for coil (#{coil.name})")
            return false
          end
          # add performance data
          add_lookup_performance_data(model, coil, 'packaged_gshp', 'Trane_10_ton_GWSC120E', heating_air_flow,
                                      heating_water_flow, runner)
        else
          runner.registerError("Expecting heating coil of type CoilHeatingWaterToAirHeatPumpEquationFits for (#{unitary_sys.name})")
          return false
        end
      else
        runner.registerError("Could not find heating coil for unitary system (#{unitary_sys.name})")
        return false
      end

      # cooling coil
      if unitary_sys.coolingCoil.is_initialized
        if unitary_sys.coolingCoil.get.to_CoilCoolingWaterToAirHeatPumpEquationFit.is_initialized
          coil = unitary_sys.coolingCoil.get.to_CoilCoolingWaterToAirHeatPumpEquationFit.get
          # capacity
          if coil.ratedTotalCoolingCapacity.is_initialized
            coil.ratedTotalCoolingCapacity.get
          else
            runner.registerError("Unable to retrieve reference capacity for coil (#{coil.name})")
            return false
          end
          # air flow
          if coil.ratedAirFlowRate.is_initialized
            cooling_air_flow = coil.ratedAirFlowRate.get
          else
            runner.registerError("Unable to retrieve reference air flow for coil (#{coil.name})")
            return false
          end
          # water flow
          if coil.ratedWaterFlowRate.is_initialized
            cooling_water_flow = coil.ratedWaterFlowRate.get
          else
            runner.registerError("Unable to retrieve reference water flow for coil (#{coil.name})")
            return false
          end
          # add performance data
          add_lookup_performance_data(model, coil, 'packaged_gshp', 'Trane_10_ton_GWSC120E', cooling_air_flow,
                                      cooling_water_flow, runner)
        else
          runner.registerError("Expecting cooling coil of type CoilCoolingWaterToAirHeatPumpEquationFits for (#{unitary_sys.name})")
          return false
        end
      else
        runner.registerError("Could not find cooling coil for unitary system (#{unitary_sys.name})")
        return false
      end

      # fan
      if unitary_sys.supplyFan.is_initialized
        if unitary_sys.supplyFan.get.to_FanVariableVolume.is_initialized
          fan = unitary_sys.supplyFan.get.to_FanVariableVolume.get
          air_loop = unitary_sys.airLoopHVAC.get
          thermal_zone = air_loop.thermalZones[0] # single zone system
          if zone_data[thermal_zone.name.to_s]['pressure_rise'].nil? # set fan parameters if haven't been already set due to not having a comparable fan in the baseline
            std.fan_motor_horsepower(fan)
            motor_bhp = std.fan_brake_horsepower(fan)
            fan_motor_eff = std.fan_standard_minimum_motor_efficiency_and_size(fan, motor_bhp)[0]
            fan_eff = std.fan_baseline_impeller_efficiency(fan)
            fan.setMotorEfficiency(fan_motor_eff)
            fan.setFanTotalEfficiency(fan_motor_eff * fan_eff)
            fan.setPressureRise(622.1) # pressure rise in pascals for Packaged_RTU_SZ_AC_CAV_Fan object
            # adjust pressure rise if needed
            allowable_fan_bhp = std.air_loop_hvac_allowable_system_brake_horsepower(air_loop) # need to make sure type is named appropriately
            allowable_power_w = allowable_fan_bhp * 746 / fan.motorEfficiency
            std.fan_adjust_pressure_rise_to_meet_fan_power(fan, allowable_power_w)
            new_pressure_rise = fan.pressureRise
            unless zone_data[thermal_zone.name.to_s]['prev_pressure_rise'].nil? # cap at previous fan pressure rise in PVAV systems
              fan.setPressureRise([new_pressure_rise, zone_data[thermal_zone.name.to_s]['prev_pressure_rise']].min)
            end
          end
          # air flow
          if fan.maximumFlowRate.is_initialized
            fan.maximumFlowRate.get
          else
            runner.registerError("Unable to retrieve maximum air flow for fan (#{fan.name})")
            return false
          end
        else
          runner.registerError("Expecting fan of type FanVariableVolume for (#{unitary_sys.name})")
          return false
        end
      else
        runner.registerError("Could not find fan for unitary system (#{unitary_sys.name})")
        return false
      end
      next unless unitary_sys.airLoopHVAC.is_initialized

      air_loop_hvac = unitary_sys.airLoopHVAC
      thermal_zone = air_loop_hvac.get.thermalZones[0]
      # Set airflow for operation when neither hearing or cooling required based on the maximum of the ratio of the required ventilation airflow, or the fan minimum turndown
      if zone_data["#{thermal_zone.name} zone_oa_flow"].nil?
        runner.registerInfo("zone #{thermal_zone.name} autosizing airflow for vent only")
        unitary_sys.autosizeSupplyAirFlowRateWhenNoCoolingorHeatingisRequired
      else
        if unitary_sys.autosizedSupplyAirFlowRateDuringCoolingOperation.is_initialized
          design_airflow_rate = unitary_sys.autosizedSupplyAirFlowRateDuringCoolingOperation.get
          min_fan_turndown_airflow = min_flow * design_airflow_rate
          min_system_flow = [min_fan_turndown_airflow, zone_data["#{thermal_zone.name} zone_oa_flow"]].max
          unitary_sys.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(min_system_flow)
          runner.registerInfo("zone name for oa  #{thermal_zone.name}")
          runner.registerInfo("min zone oa flow  #{zone_data["#{thermal_zone.name} zone_oa_flow"]}")
          runner.registerInfo("min_fan_turndown_airflow #{min_fan_turndown_airflow}")
          runner.registerInfo("min system flow #{min_system_flow}")
        elsif unitary_sys.supplyAirFlowRateDuringCoolingOperation.is_initialized
          design_airflow_rate = unitary_sys.autosizedSupplyAirFlowRateDuringCoolingOperation.get
          min_fan_turndown_airflow = min_flow * design_airflow_rate
          min_system_flow = [min_fan_turndown_airflow, zone_data["#{thermal_zone.name} zone_oa_flow"]].max
          unitary_sys.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(governing_min_ratio * design_airflow_rate)
          runner.registerInfo("min system flow #{min_system_flow}")
        else
          unitary_sys.autosizeSupplyAirFlowRateWhenNoCoolingorHeatingisRequired
          runner.registerInfo("zone #{thermal_zone.name} autosizing airflow for vent only")
        end
      end
    end
    # add output variable for GHEDesigner
    reporting_frequency = 'Hourly'
    output_variable = OpenStudio::Model::OutputVariable.new('Plant Temperature Source Component Heat Transfer Rate', model)
    output_variable.setReportingFrequency(reporting_frequency)
    runner.registerInfo("Adding output variable for 'Plant Temperature Source Component Heat Transfer Rate' reporting at the hourly timestep.")

    # retrieve or perform annual run to get hourly thermal loads
    ann_loads_run_dir = "#{Dir.pwd}/AnnualGHELoadsRun"
    ann_loads_sql_path = "#{ann_loads_run_dir}/run/eplusout.sql"
    if File.exist?(ann_loads_sql_path)
      runner.registerInfo('Reloading sql file from previous run.')
      sql_path = OpenStudio::Path.new(ann_loads_sql_path)
      sql = OpenStudio::SqlFile.new(sql_path)
      model.setSqlFile(sql)
    else
      runner.registerInfo('Running an annual simulation to determine thermal loads for ground heat exchanger.')
      if std.model_run_simulation_and_log_errors(model, ann_loads_run_dir) == false
        runner.registerError('Sizing run failed. See errors in sizing run directory or this measure')
        return false
      end
    end

    # get timeseries output variable values
    # check for sql file
    if model.sqlFile.empty?
      runner.registerError('Model did not have an sql file; cannot get loads for ground heat exchanger.')
      return false
    end
    sql = model.sqlFile.get

    # get weather file run period (as opposed to design day run period)
    ann_env_pd = nil
    sql.availableEnvPeriods.each do |env_pd|
      env_type = sql.environmentType(env_pd)
      if env_type.is_initialized && (env_type.get == OpenStudio::EnvironmentType.new('WeatherRunPeriod'))
        ann_env_pd = env_pd
      end
    end

    # add timeseries ground loads to array
    ground_loads_ts = sql.timeSeries(ann_env_pd, 'Hourly', 'Plant Temperature Source Component Heat Transfer Rate',
                                     'GROUND LOOP TEMPERATURE SOURCE (GROUND HEAT EXCHANGER PLACEHOLDER)')
    if ground_loads_ts.is_initialized
      ground_loads = []
      vals = ground_loads_ts.get.values
      for i in 0..(vals.size - 1)
        ground_loads << vals[i]
      end
    end

    # Make directory for GHEDesigner simulation
    ghedesigner_run_dir = "#{Dir.pwd}/GHEDesigner"
    FileUtils.mkdir_p(ghedesigner_run_dir)

    # Make json input file for GHEDesigner
    borefield_defaults_json_path = "#{File.dirname(__FILE__)}/resources/borefield_defaults.json"
    borefield_defaults = JSON.parse(File.read(borefield_defaults_json_path))

    # get soil properties from building additional properties and set them in json file
    building = model.getBuilding
    soil_conductivity = building.additionalProperties.getFeatureAsDouble('Soil Conductivity')
    undisturbed_ground_temp = building.additionalProperties.getFeatureAsDouble('Undisturbed Ground Temperature')
    # only overwrite the default from the json file if a value was found in building additional properties
    if !soil_conductivity.empty?
      borefield_defaults['soil']['conductivity'] = soil_conductivity.to_f.round(2)
    end
    if !undisturbed_ground_temp.empty?
      borefield_defaults['soil']['undisturbed_temp'] = undisturbed_ground_temp.to_f.round(2)
    end

    borefield_defaults['loads'] = {}
    borefield_defaults['loads']['ground_loads'] = ground_loads
    ghe_in_path = "#{ghedesigner_run_dir}/ghedesigner_input.json"
    File.write(ghe_in_path, JSON.pretty_generate(borefield_defaults))
    runner.registerInfo('GHEDesigner input JSON file created.')

    # Make system call to run GHEDesigner
    start_time = Time.new
    # TODO: remove conda activate andrew
    # require 'open3'
    # require 'etc'
    # command = "C:/Users/#{Etc.getlogin}/Anaconda3/Scripts/activate.bat && conda activate #{envname} && ghedesigner #{ghe_in_path} #{ghedesigner_run_dir}"
    # command = "conda activate base && ghedesigner '#{ghe_in_path}' '#{ghedesigner_run_dir}'"
    command = "ghedesigner #{ghe_in_path} #{ghedesigner_run_dir}"
    _, _, status = Open3.capture3(command, chdir: ghedesigner_run_dir)
    if status.success?
      runner.registerInfo("Successfully ran ghedesigner: #{command}")
    else
      # runner.registerError("Error running ghedesigner: #{command}")
      # runner.registerError("stdout: #{stdout_str}")
      # runner.registerError("stderr: #{stderr_str}")
      # return false
      runner.registerAsNotApplicable("Error running ghedesigner: #{command}. Measure will be logged as not applicable.")
      return true
    end
    end_time = Time.new
    runner.registerInfo("Running GHEDesigner took #{end_time - start_time} seconds")

    # Get some information from borefield inputs
    pipe_thermal_conductivity_w_per_m_k = borefield_defaults['pipe']['conductivity']

    # Read GHEDesigner simulation summary file
    # Check unit strings for all numeric values in case GHEDesigner changes units
    sim_summary = JSON.parse(File.read("#{ghedesigner_run_dir}/SimulationSummary.json"))
    ghe_sys = sim_summary['ghe_system']

    number_of_boreholes = ghe_sys['number_of_boreholes']
    runner.registerInfo("Number of boreholes = #{number_of_boreholes}")

    throw 'Unexpected units' unless ghe_sys['fluid_mass_flow_rate_per_borehole']['units'] == 'kg/s'
    fluid_mass_flow_rate_per_borehole_kg_per_s = ghe_sys['fluid_mass_flow_rate_per_borehole']['value']

    throw 'Unexpected units' unless ghe_sys['fluid_density']['units'] == 'kg/m3'
    fluid_density_kg_per_m3 = ghe_sys['fluid_density']['value']
    fluid_vol_flow_rate_per_borehole_m3_per_s = fluid_mass_flow_rate_per_borehole_kg_per_s / fluid_density_kg_per_m3
    fluid_vol_flow_rate_sum_all_boreholes_m3_per_s = fluid_vol_flow_rate_per_borehole_m3_per_s * number_of_boreholes

    throw 'Unexpected units' unless ghe_sys['active_borehole_length']['units'] == 'm'
    active_borehole_length_m = ghe_sys['active_borehole_length']['value']

    throw 'Unexpected units' unless ghe_sys['soil_thermal_conductivity']['units'] == 'W/m-K'
    soil_thermal_conductivity_w_per_m_k = ghe_sys['soil_thermal_conductivity']['value']

    throw 'Unexpected units' unless ghe_sys['soil_volumetric_heat_capacity']['units'] == 'kJ/m3-K'
    soil_volumetric_heat_capacity_kj_per_m3_k = ghe_sys['soil_volumetric_heat_capacity']['value']
    soil_volumetric_heat_capacity_j_per_m3_k = OpenStudio.convert(soil_volumetric_heat_capacity_kj_per_m3_k, 'kJ/m^3*K',
                                                                  'J/m^3*K').get

    throw 'Unexpected units' unless ghe_sys['soil_undisturbed_ground_temp']['units'] == 'C'
    soil_undisturbed_ground_temp_c = ghe_sys['soil_undisturbed_ground_temp']['value']

    # TODO: remove W/mK once https://github.com/BETSRG/GHEDesigner/issues/76 is fixed
    throw 'Unexpected units' unless ['W/mK', 'W/m-K'].include?(ghe_sys['grout_thermal_conductivity']['units'])
    grout_thermal_conductivity_w_per_m_k = ghe_sys['grout_thermal_conductivity']['value']

    throw 'Unexpected units' unless ghe_sys['pipe_geometry']['pipe_outer_diameter']['units'] == 'm'
    pipe_outer_diameter_m = ghe_sys['pipe_geometry']['pipe_outer_diameter']['value']
    throw 'Unexpected units' unless ghe_sys['pipe_geometry']['pipe_inner_diameter']['units'] == 'm'
    pipe_inner_diameter_m = ghe_sys['pipe_geometry']['pipe_inner_diameter']['value']
    pipe_thickness_m = (pipe_outer_diameter_m - pipe_inner_diameter_m) / 2.0

    throw 'Unexpected units' unless ghe_sys['shank_spacing']['units'] == 'm'
    u_tube_shank_spacing_m = ghe_sys['shank_spacing']['value']

    # Create ground heat exchanger and set properties based on GHEDesigner simulation
    ghx = OpenStudio::Model::GroundHeatExchangerVertical.new(model)
    ghx.setDesignFlowRate(fluid_vol_flow_rate_sum_all_boreholes_m3_per_s) # total for borefield m^3/s
    ghx.setNumberofBoreHoles(number_of_boreholes)
    ghx.setBoreHoleLength(active_borehole_length_m) # Depth of 1 borehole
    ghx.setGroundThermalConductivity(soil_thermal_conductivity_w_per_m_k) # W/m-K
    ghx.setGroundThermalHeatCapacity(soil_volumetric_heat_capacity_j_per_m3_k) # J/m3-K
    ghx.setGroundTemperature(soil_undisturbed_ground_temp_c) # C
    ghx.setGroutThermalConductivity(grout_thermal_conductivity_w_per_m_k) # W/m-K
    ghx.setPipeThermalConductivity(pipe_thermal_conductivity_w_per_m_k) # W/m-K
    ghx.setPipeOutDiameter(pipe_outer_diameter_m) # m
    ghx.setUTubeDistance(u_tube_shank_spacing_m) # m
    ghx.setPipeThickness(pipe_thickness_m) # m
    # ghx.setMaximumLengthofSimulation() # TODO
    # ghx.setGFunctionReferenceRatio() # TODO check with Matt Mitchel if this is necessary

    # G function
    ghx.removeAllGFunctions # Rempve the default gfunction inputs
    gfunc_data = CSV.read("#{ghedesigner_run_dir}/Gfunction.csv", headers: true)
    gfunc_data.each do |r|
      ghx.addGFunction(r['ln(t/ts)'].to_f, r['H:79.59'].to_f) # addGFunction(double gFunctionLN, double gFunctionGValue)
    end

    # Replace temperature source with ground heat exchanger
    ground_loop.addSupplyBranchForComponent(ghx)
    ground_loop.removeSupplyBranchWithComponent(ground_temp_source)
    runner.registerInfo("Replaced temporary ground temperature source with vertical ground heat exchanger #{ghx}.")

    # report final condition
    condition_final_ghp = "Replaced #{psz_air_loops.size} packaged single zone RTUs  and #{pvav_air_loops.size} PVAVs with packaged water-to-air ground source heat pumps."
    condition_final = [condition_final_ghp, condition_final_walls, condition_final_roof, condition_final_windows,
                       condition_final_lighting].reject(&:empty?).join(' | ')
    runner.registerFinalCondition(condition_final)
    true
  end
end

# register the measure to be used by the application
AddPackagedGSHP.new.registerWithApplication
