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
class AddConsoleGSHP < OpenStudio::Measure::ModelMeasure
  # resource file modules
  include MakePerformanceCurves

  # human readable name
  def name
    # Measure name should be the title case of the class name.
    'add_console_gshp'
  end

  # human readable description
  def description
    'Measure replaces existing packaged terminal air conditioner system types with water-to-air heat pumps served by a ground heat exchanger.'
  end

  # human readable description of modeling approach
  def modeler_description
    'This measure will work on packaged terminal systems as well as other non-ducted systems such as baseboards or unit heaters.'
  end

  # determine if the air loop is residential (checks to see if there is outdoor air system object)
  # measure will be applicable to residential AC/residential furnace systems
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
  # measure will be applicable to buildings with direct evap coolers
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

    args
  end

  # Define the main method that will be called by the OpenStudio application
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    walls = runner.getBoolArgumentValue('walls', user_arguments)
    roof = runner.getBoolArgumentValue('roof', user_arguments)
    windows = runner.getBoolArgumentValue('windows', user_arguments)
    lighting = runner.getBoolArgumentValue('lighting', user_arguments)

    # build standard to use OS standards methods
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)
    # get climate zone value
    OpenstudioStandards::Weather.model_get_climate_zone(model)
    Standard.build('90.1-2019') # to reflect new motors

    # check if GroundHeatExchanger:Vertical is present (for package runs)
    if !model.getObjectsByType(OpenStudio::Model::GroundHeatExchangerVertical.iddObjectType).empty?
      runner.registerAsNotApplicable('Model already contains a GroundHeatExchanger:Vertical, upgrade is not applicable.')
      return true
    end

    # measure will be applicable to some system types that have air loops; need to narrow down to these system types
    selected_air_loops = []
    equip_to_delete = []
    ptacs = []
    pthps = []
    baseboards = []
    unit_heaters = []
    unconditioned_zones = []
    zones_to_skip = []
    all_air_loops = model.getAirLoopHVACs

    # #apply sizing run to get fan autosizing. confirm if this is necessary for comstock.
    if model.sqlFile.empty?
      # runner.registerInfo('Model had no sizing values--running size run')
      if std.model_run_sizing_run(model, "#{Dir.pwd}/advanced_rtu_control") == false
        runner.registerError('Sizing run for Hardsize model failed, cannot hard-size model.')
        return false
      end
      model.applySizingValues
    end


    # if a thermal zone started out with no equipment (aka it is unconditioned), skip this zone
    model.getThermalZones.each do |thermal_zone|
      if thermal_zone.equipment.empty?
        unconditioned_zones << thermal_zone.name.get
      # if original zone is typically conditioned with baseboards or unit heaters (as opposed to primary system), maintain zone equipment in this space
      elsif ['Bulk', 'Entry', 'WarehouseUnCond'].any? { |word| thermal_zone.name.get.include?(word) }
        zones_to_skip << thermal_zone.name.get
      end
    end

    if (zones_to_skip.size + unconditioned_zones.size) == model.getThermalZones.size
      runner.registerAsNotApplicable('Entire building is made up of non-applicable space types. Measure is not applicable.')
      return true
    end

    zone_fan_data = {}

    if all_air_loops.empty?
      runner.registerInfo('Model does not have any air loops. Get list of PTAC, PTHP, Unit Heater, or Baseboard Electric equipment to delete.')

      # check for zone equipment to delete
      model.getThermalZones.each do |thermal_zone|
        thermal_zone.equipment.each do |equip|
          if equip.to_ZoneHVACPackagedTerminalAirConditioner.is_initialized
            # check for PTAC units and add to array of zone equipment to delete
            ptacs << equip.to_ZoneHVACPackagedTerminalAirConditioner.get
            equip_to_delete << equip.to_ZoneHVACPackagedTerminalAirConditioner.get
            ptac_unit = equip.to_ZoneHVACPackagedTerminalAirConditioner.get
            sup_fan = ptac_unit.supplyAirFan
            next unless sup_fan.to_FanOnOff.is_initialized

            sup_fan = sup_fan.to_FanOnOff.get
            pressure_rise = sup_fan.pressureRise
            zone_fan_data[thermal_zone.name.to_s] = {}
            zone_fan_data[thermal_zone.name.to_s]['pressure_rise'] = pressure_rise
            std.fan_motor_horsepower(sup_fan) # based on existing fan
            motor_bhp = std.fan_brake_horsepower(sup_fan)
            fan_motor_eff = std.fan_standard_minimum_motor_efficiency_and_size(sup_fan, motor_bhp)[0]
            zone_fan_data[thermal_zone.name.to_s]['fan_motor_eff'] = fan_motor_eff
            fan_eff = std.fan_baseline_impeller_efficiency(sup_fan)
            zone_fan_data[thermal_zone.name.to_s]['fan_eff'] = fan_eff
          elsif equip.to_ZoneHVACPackagedTerminalHeatPump.is_initialized
            # check for PTHP units and add to array of zone equipment to delete
            pthps << equip.to_ZoneHVACPackagedTerminalHeatPump.get
            equip_to_delete << equip.to_ZoneHVACPackagedTerminalHeatPump.get
            pthp_unit = equip.to_ZoneHVACPackagedTerminalHeatPump.get
            sup_fan = pthp_unit.supplyAirFan
            next unless sup_fan.to_FanOnOff.is_initialized

            sup_fan = sup_fan.to_FanOnOff.get
            pressure_rise = sup_fan.pressureRise
            zone_fan_data[thermal_zone.name.to_s] = {}
            zone_fan_data[thermal_zone.name.to_s]['pressure_rise'] = pressure_rise
            std.fan_motor_horsepower(sup_fan) # based on existing fan
            motor_bhp = std.fan_brake_horsepower(sup_fan)
            fan_motor_eff = std.fan_standard_minimum_motor_efficiency_and_size(sup_fan, motor_bhp)[0]
            zone_fan_data[thermal_zone.name.to_s]['fan_motor_eff'] = fan_motor_eff
            fan_eff = std.fan_baseline_impeller_efficiency(sup_fan)
            zone_fan_data[thermal_zone.name.to_s]['fan_eff'] = fan_eff
          end
        end
      end

      # check for baseboard electric and add to array of zone equipment to delete
      # if there are PTACs or PTHPs in the building, skips zones with baseboards
      model.getThermalZones.each do |thermal_zone|
        thermal_zone.equipment.each do |equip|
          next unless equip.to_ZoneHVACBaseboardConvectiveElectric.is_initialized

          if !ptacs.empty? || !pthps.empty?
            zones_to_skip << thermal_zone.name.get
          else
            baseboards << equip.to_ZoneHVACBaseboardConvectiveElectric.get
            equip_to_delete << equip.to_ZoneHVACBaseboardConvectiveElectric.get
          end
        end
      end

      # check for gas unit heaters and add to array of zone equipment to delete
      # if there are PTACs or PTHPs in the building, skips zones with unit heaters
      model.getThermalZones.each do |thermal_zone|
        thermal_zone.equipment.each do |equip|
          next unless equip.to_ZoneHVACUnitHeater.is_initialized

          if !ptacs.empty? || !pthps.empty?
            zones_to_skip << thermal_zone.name.get
          else
            unit_heaters << equip.to_ZoneHVACUnitHeater.get
            equip_to_delete << equip.to_ZoneHVACUnitHeater.get
          end
        end
      end
    end

    # loop through all air loops and look for residential systems and direct evap coolers
    # then remove any zone equipment associated with existing system
    all_air_loops.each do |air_loop_hvac|
      # check if residential system
      if air_loop_res?(air_loop_hvac)
        selected_air_loops << air_loop_hvac
        thermal_zone = air_loop_hvac.thermalZones[0]
        thermal_zone.equipment.each do |equip|
          equip_to_delete << equip
        end
        runner.registerInfo('Model has residential HVAC system, measure will be applied.')
      # check if evaporative cooling systems
      elsif air_loop_evaporative_cooler?(air_loop_hvac)
        runner.registerAsNotApplicable('Model has direct evaporative coolers; measure is not applicable.')
        return true
      elsif air_loop_hvac_unitary_system?(air_loop_hvac)
        runner.registerAsNotApplicable('Model has unitary systems; measure is not applicable.')
        return true
      end
    end

    # check for PTAC with gas boiler and remove baseboard water from zones
    if !ptacs.empty?
      model.getThermalZones.each do |thermal_zone|
        thermal_zone.equipment.each do |equip|
          next unless equip.to_ZoneHVACBaseboardConvectiveWater.is_initialized

          baseboards << equip.to_ZoneHVACBaseboardConvectiveWater.get
          equip_to_delete << equip.to_ZoneHVACBaseboardConvectiveWater.get
        end
      end
    end

    # delete equipment from original loop
    equip_to_delete.each(&:remove)



    # get plant loops and remove
    # only relevant for direct evap coolers with baseboard gas boiler
    plant_loops = model.getPlantLoops
    if !plant_loops.empty?
      plant_loops.each do |plant_loop|
        # do not delete service water heating loops
        next if ['Service'].any? { |word| plant_loop.name.get.include?(word) }

        plant_loop.remove
        runner.registerInfo("Removed existing plant loop #{plant_loop.name}.")
      end
    end

    # register as not applicable if not
    if pthps.empty? && ptacs.empty? && baseboards.empty? && unit_heaters.empty? && selected_air_loops.empty?
      runner.registerAsNotApplicable('HVAC system in model is not compatible with console GSHP upgrade.')
      return true
    end

    # initialize variables for reporting

    # after finished checking for non applicable models, run envelope measures as package if user arguments are true
    # run wall insulation measure if user argument is true
    if walls == true
      runner.registerInfo('Running Wall Insulation measure....')
      results_walls, runner = call_walls(model, runner)
      results_walls.stepInitialCondition.get if results_walls.stepInitialCondition.is_initialized
      results_walls.stepFinalCondition.get if results_walls.stepFinalCondition.is_initialized
    end

    # run roof insulation measure if user argument is true
    if roof == true
      runner.registerInfo('Running Roof Insulation measure....')
      results_roof, runner = call_roof(model, runner)
      results_roof.stepInitialCondition.get if results_roof.stepInitialCondition.is_initialized
      results_roof.stepFinalCondition.get if results_roof.stepFinalCondition.is_initialized
    end

    # run new windows measure if user argument is true
    if windows == true
      runner.registerInfo('Running New Windows measure....')
      results_windows, runner = call_windows(model, runner)
      results_windows.stepInitialCondition.get if results_windows.stepInitialCondition.is_initialized
      results_windows.stepFinalCondition.get if results_windows.stepFinalCondition.is_initialized
    end

    # run lighting measure if user argument is true
    if lighting == true
      runner.registerInfo('Running LED Lighting measure....')
      results_lighting, runner = call_lighting(model, runner)
      results_lighting.stepInitialCondition.get if results_lighting.stepInitialCondition.is_initialized
      results_lighting.stepFinalCondition.get if results_lighting.stepFinalCondition.is_initialized
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
    condenser_pump.setPumpControlType('Intermittent')
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
    ground_loop_sizing.setDesignLoopExitTemperature(18.33) # does this need to change to ~140F?

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

    # Loop through air loops, plant loops, and thermal zones and remove old equipment
    selected_air_loops.each(&:remove)

    # Loop through each thermal zone and remove old PTAC/PTHP and replace it with a water-to-air ground source heat pump
    model.getThermalZones.each do |thermal_zone|
      # skip if it has baseboards in baseline
      next if zones_to_skip.include? thermal_zone.name.get
      next if unconditioned_zones.include? thermal_zone.name.get

      OpenStudio.logFree(OpenStudio::Info, 'openstudio.Model.Model',
                         "Adding water-to-air heat pump for #{thermal_zone.name}.")

      # create new air loop for unitary system
      air_loop_hvac = OpenStudio::Model::AirLoopHVAC.new(model)
      air_loop_hvac.setName("#{thermal_zone.name} Air Loop")
      air_loop_hvac.sizingSystem

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

      # set always on schedule; this will be used in other object definitions
      always_on = model.alwaysOnDiscreteSchedule

      # using 10 ton units for packaged unit performance data
      # using 1 ton units for console
      # add new single speed cooling coil
      new_cooling_coil = OpenStudio::Model::CoilCoolingWaterToAirHeatPumpEquationFit.new(model)
      new_cooling_coil.setName("#{thermal_zone.name} Heat Pump Cooling Coil")
      # new_cooling_coil.setRatedCoolingCoefficientofPerformance(3.4)
      # new_cooling_coil.setTotalCoolingCapacityCoefficient1(-4.30266987344639)
      # new_cooling_coil.setTotalCoolingCapacityCoefficient2(7.18536990534372)
      # new_cooling_coil.setTotalCoolingCapacityCoefficient3(-2.23946714486189)
      # new_cooling_coil.setTotalCoolingCapacityCoefficient4(0.139995928440879)
      # new_cooling_coil.setTotalCoolingCapacityCoefficient5(0.102660179888915)
      # new_cooling_coil.setSensibleCoolingCapacityCoefficient1(6.0019444814887)
      # new_cooling_coil.setSensibleCoolingCapacityCoefficient2(22.6300677244073)
      # new_cooling_coil.setSensibleCoolingCapacityCoefficient3(-26.7960783730934)
      # new_cooling_coil.setSensibleCoolingCapacityCoefficient4(-1.72374720346819)
      # new_cooling_coil.setSensibleCoolingCapacityCoefficient5(0.490644802367817)
      # new_cooling_coil.setSensibleCoolingCapacityCoefficient6(0.0693119353468141)
      # new_cooling_coil.setCoolingPowerConsumptionCoefficient1(-5.67775976415698)
      # new_cooling_coil.setCoolingPowerConsumptionCoefficient2(0.438988156976704)
      # new_cooling_coil.setCoolingPowerConsumptionCoefficient3(5.845277342193)
      # new_cooling_coil.setCoolingPowerConsumptionCoefficient4(0.141605667000125)
      # new_cooling_coil.setCoolingPowerConsumptionCoefficient5(-0.168727936032429)
      condenser_loop.addDemandBranchForComponent(new_cooling_coil)

      # add new single speed heating coil
      new_heating_coil = OpenStudio::Model::CoilHeatingWaterToAirHeatPumpEquationFit.new(model)
      new_heating_coil.setName("#{thermal_zone.name} Heat Pump Heating Coil")
      # new_heating_coil.setRatedHeatingCoefficientofPerformance(4.2)
      # new_heating_coil.setHeatingCapacityCoefficient1(0.237847462869254)
      # new_heating_coil.setHeatingCapacityCoefficient2(-3.35823796081626)
      # new_heating_coil.setHeatingCapacityCoefficient3(3.80640467406376)
      # new_heating_coil.setHeatingCapacityCoefficient4(0.179200417311554)
      # new_heating_coil.setHeatingCapacityCoefficient5(0.12860719846082)
      # new_heating_coil.setHeatingPowerConsumptionCoefficient1(-3.79175529243238)
      # new_heating_coil.setHeatingPowerConsumptionCoefficient2(3.38799239505527)
      # new_heating_coil.setHeatingPowerConsumptionCoefficient3(1.5022612076303)
      # new_heating_coil.setHeatingPowerConsumptionCoefficient4(-0.177653510577989)
      # new_heating_coil.setHeatingPowerConsumptionCoefficient5(-0.103079864171839)
      condenser_loop.addDemandBranchForComponent(new_heating_coil)

      # Create a new water-to-air ground source heat pump system
      unitary_system = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
      unitary_system.setControlType('Setpoint')
      unitary_system.setCoolingCoil(new_cooling_coil)
      unitary_system.setHeatingCoil(new_heating_coil)
      unitary_system.setControllingZoneorThermostatLocation(thermal_zone)
      # add supply fan
      # check for existing fan data
      if zone_fan_data.key?(thermal_zone.name.to_s) # [thermal_zone.name.to_s].exists?
        fan = OpenStudio::Model::FanConstantVolume.new(model)
        fan.setName("#{thermal_zone.name} Fan")
        fan.setMotorEfficiency(zone_fan_data[thermal_zone.name.to_s]['fan_motor_eff']) # Setting assuming similar size to previous fan, but new and subject to current standards
        fan_eff = 0.55 # since console unit fans would be considered small, set efficiency based on small fan
        fan.setFanEfficiency(fan_eff)
        fan.setFanTotalEfficiency(fan_eff * zone_fan_data[thermal_zone.name.to_s]['fan_motor_eff'])
        # Set pressure rise based on previous fan, assuming similar pressure drops to before
        fan.setPressureRise(zone_fan_data[thermal_zone.name.to_s]['pressure_rise'])
      else # case where there was not a fan present previously
        fan = OpenStudio::Model::FanConstantVolume.new(model)
        fan.setName("#{thermal_zone.name} Fan")
        # autosize other attributes for now, and then set fan and motor efficiencies based on sizing

      end
      unitary_system.setSupplyFan(fan)
      unitary_system.setFanPlacement('DrawThrough')
      if model.version < OpenStudio::VersionString.new('3.7.0')
        unitary_system.setSupplyAirFlowRateMethodDuringCoolingOperation('SupplyAirFlowRate')
        unitary_system.setSupplyAirFlowRateMethodDuringHeatingOperation('SupplyAirFlowRate')
        unitary_system.setSupplyAirFlowRateMethodWhenNoCoolingorHeatingisRequired('SupplyAirFlowRate')
      else
        unitary_system.autosizeSupplyAirFlowRateDuringCoolingOperation
        unitary_system.autosizeSupplyAirFlowRateDuringHeatingOperation
        unitary_system.autosizeSupplyAirFlowRateWhenNoCoolingorHeatingisRequired
      end
      unitary_system.setSupplyAirFanOperatingModeSchedule(model.alwaysOnDiscreteSchedule)
      unitary_system.setMaximumOutdoorDryBulbTemperatureforSupplementalHeaterOperation(OpenStudio.convert(40.0, 'F',
                                                                                                          'C').get)
      unitary_system.setName("#{thermal_zone.name} Unitary HP")
      unitary_system.setMaximumSupplyAirTemperature(40.0)
      unitary_system.addToNode(air_loop_hvac.supplyOutletNode)

      # create a diffuser and attach the zone/diffuser pair to the air loop
      diffuser = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
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

    # delete equipment from original loop
    # equip_to_delete.each(&:remove)

    # for zones that got skipped, check if there are already baseboards. if not, add them.
    model.getThermalZones.each do |thermal_zone|
      if unconditioned_zones.include? thermal_zone.name.get
        runner.registerInfo("Thermal zone #{thermal_zone.name} was unconditioned in the baseline, and will not receive a packaged GHP.")
      elsif zones_to_skip.include? thermal_zone.name.get
        # if thermal_zone.equipment.empty? || thermal_zone.equipment.none? { |equip| equip.iddObjectType == OpenStudio::Model::ZoneHVACBaseboardConvectiveElectric.iddObjectType }
        if thermal_zone.equipment.empty?
          runner.registerInfo("Thermal zone #{thermal_zone.name} will not receive a packaged GHP and will receive electric baseboards instead.")
          baseboard = OpenStudio::Model::ZoneHVACBaseboardConvectiveElectric.new(model)
          baseboard.setName("#{thermal_zone.name} Electric Baseboard")
          baseboard.setEfficiency(1.0)
          baseboard.autosizeNominalCapacity
          baseboard.setAvailabilitySchedule(model.alwaysOnDiscreteSchedule)
          baseboard.addToThermalZone(thermal_zone)
        end
      end
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
          add_lookup_performance_data(model, coil, 'console_gshp', 'Trane_3_ton_GWSC036H', heating_air_flow,
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
          add_lookup_performance_data(model, coil, 'console_gshp', 'Trane_3_ton_GWSC036H', cooling_air_flow,
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
        if unitary_sys.supplyFan.get.to_FanConstantVolume.is_initialized
          fan = unitary_sys.supplyFan.get.to_FanConstantVolume.get
          # air flow
          if fan.maximumFlowRate.is_initialized
            fan.maximumFlowRate.get
            if zone_fan_data.empty? # case where no fan present previously, need to set efficiencies based on sizing
              std.fan_motor_horsepower(fan)
              motor_bhp = std.fan_brake_horsepower(fan)
              fan_motor_eff = std.fan_standard_minimum_motor_efficiency_and_size(fan, motor_bhp)[0]
              fan.setMotorEfficiency(fan_motor_eff)
              fan_eff = 0.55 # based on "small fan" status
              fan.setFanEfficiency(fan_eff)
              fan.setFanTotalEfficiency(fan_eff * fan_motor_eff)
              # Set pressure rise based on assumption in OS standards for PTACs, a similar unit style
              fan.setPressureRise(330.96) # setting to same value as PTACs in prototype, in PA

            end
          else
            runner.registerError("Unable to retrieve maximum air flow for fan (#{fan.name})")
            return false
          end
        else
          runner.registerError("Expecting fan of type FanConstantVolume for (#{unitary_sys.name})")
          return false
        end
      else
        runner.registerError("Could not find fan for unitary system (#{unitary_sys.name})")
        return false
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
    # ghedesigner_run_dir = "C:/Users/mprapros/Desktop/ghedesigner"
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
    require 'open3'
    require 'etc'
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
    soil_volumetric_heat_capacity_j_per_m3_k = OpenStudio.convert(soil_volumetric_heat_capacity_kj_per_m3_k,
                                                                  'kJ/m^3*K', 'J/m^3*K').get

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

    runner.registerFinalCondition('Replaced existing HVAC system with console water-to-air ground source heat pumps.')
    true
  end
end

# register the measure to be used by the application
AddConsoleGSHP.new.registerWithApplication
