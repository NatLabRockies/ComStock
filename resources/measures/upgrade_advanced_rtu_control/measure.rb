# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

class AdvancedRTUControl < OpenStudio::Measure::ModelMeasure

require 'comstock-typical'
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'Advanced RTU Control'
  end

  # human readable description
  def description
    return 'This measure implements advanced RTU controls, including a variable-speed fan, with options for economizing and demand-controlled ventilation.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'This measure iterates through airloops, and, where applicable, replaces constant speed fans with variable speed fans, and replaces the existing zone terminal.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

	#economizer option
    add_econo = OpenStudio::Measure::OSArgument.makeBoolArgument('add_econo', true)
    add_econo.setDisplayName('Economizer to be added?')
    add_econo.setDescription('Add economizer (true) or not (false)')
    args << add_econo

	#dcv option
	add_dcv = OpenStudio::Measure::OSArgument.makeBoolArgument('add_dcv', true)
    add_dcv.setDisplayName('DCV to be added?')
    add_dcv.setDescription('Add DCV (true) or not (false)')
    args << add_dcv

    return args
  end

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

   #slightly modified from OS standards to adjust log messages
  def thermal_zone_outdoor_airflow_rate(thermal_zone)
    tot_oa_flow_rate = 0.0

    spaces = thermal_zone.spaces.sort

    sum_floor_area = 0.0
    sum_number_of_people = 0.0
    sum_volume = 0.0

    # Variables for merging outdoor air
    any_max_oa_method = false
    sum_oa_for_people = 0.0
    sum_oa_for_floor_area = 0.0
    sum_oa_rate = 0.0
    sum_oa_for_volume = 0.0

    # Find common variables for the new space
    spaces.each do |space|
      floor_area = space.floorArea * space.multiplier
      sum_floor_area += floor_area

      number_of_people = space.numberOfPeople * space.multiplier
      sum_number_of_people += number_of_people

      volume = space.volume * space.multiplier
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

    return tot_oa_flow_rate
  end

  def vav_terminals?(air_loop_hvac)
    air_loop_hvac.thermalZones.each do |thermal_zone| #iterate thru thermal zones and modify zone-level terminal units
	  thermal_zone.equipment.each do |equip|
	    if equip.to_AirTerminalSingleDuctVAVHeatAndCoolNoReheat.is_initialized
          return true
		elsif equip.to_AirTerminalSingleDuctVAVHeatAndCoolReheat.is_initialized
          return true
		elsif equip.to_AirTerminalSingleDuctVAVReheat.is_initialized
          return true
		elsif equip.to_AirTerminalSingleDuctVAVNoReheat.is_initialized
          return true
	    elsif equip.to_AirTerminalDualDuctVAV.is_initialized
	      return true
		elsif equip.to_AirTerminalDualDuctVAVOutdoorAir.is_initialized
		  return true
		else
		  next
		end
	    end
	end
	  return false #if no VAV terminals found on the air loop
  end
def no_DCV_zones?(air_loop_hvac)
	selected_air_loops = []
	# Space types this measure leaves alone, in the typical (all-level) space type vocabulary.
	# These are ventilation-driven or use no per-person ventilation rate. A level-1 name covers every
	# qualified variant ('food preparation' includes the school kitchens). Prototype space type names
	# ('Kitchen', 'PatRoom', 'IT_Room') resolve to the same names through the prototype space type
	# crosswalk, so this list reads both model vintages. The prototype list's 'Entry' (now 'lobby') and
	# 'BioHazard' (now 'storage') are not carried over: the typical names cover far more than they did.
	space_types_no_dcv = [
	  'food preparation',
	  'patient room',
	  'laboratory',
	  'exam/treatment',
	  'operating room',
	  'emergency room',
	  'physical therapy',
	  'datacenter/high ite',
	  'datacenter/low ite',
	  'corridor',
	  'electrical/mechanical',
	  'restroom',
	  'dining',
	  'locker room',
	  'stairwell'
	]

    oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem
    if oa_system.is_initialized
      oa_system = oa_system.get
      else
	    return true
    end

    # check if airloop is DOAS; skip if true
    sizing_system = air_loop_hvac.sizingSystem
    type_of_load = sizing_system.typeofLoadtoSizeOn
    if type_of_load == 'VentilationRequirement'
      return true
    end

    # Check for ERV. If the air loop has an ERV, air loop is not applicable for DCV measure.
    erv_components = []
    air_loop_hvac.oaComponents.each do |component|
      component_name = component.name.to_s
      next if component_name.include? "Node"
      if component_name.include? "ERV"
        erv_components << component
      end
    end
    if erv_components.any?
      return true
    end

    # check to see if airloop has existing DCV
    # TODO - if it does have DCV, check to see if all zones are getting DCV
    controller_oa = oa_system.getControllerOutdoorAir
    controller_mv = controller_oa.controllerMechanicalVentilation
    if controller_mv.demandControlledVentilation
      return true
    end

    # check to see if airloop has applicable space types
    # these space types are often ventilation driven, or generally do not use ventilation rates per person
    # exclude these space types: kitchens, laboratories, patient care rooms
    # TODO - add functionality to add DCV to multizone systems to applicable zones only
    space_no_dcv = 0
    space_dcv = 0
    air_loop_hvac.thermalZones.sort.each do |zone|
      zone.spaces.each do |space|
        if OpenstudioStandards::SpaceType.space_matches?(space, space_types_no_dcv)
          space_no_dcv += 1
        else
          space_dcv += 1
        end
      end
    end
    if space_no_dcv >= 1
      return true
    end
	return false
end

def air_loop_doas?(air_loop_hvac)
    is_doas = false
    sizing_system = air_loop_hvac.sizingSystem
    if sizing_system.allOutdoorAirinCooling && sizing_system.allOutdoorAirinHeating && (air_loop_res?(air_loop_hvac) == false) && (air_loop_hvac.name.to_s.include?("DOAS") || air_loop_hvac.name.to_s.include?("doas"))
      is_doas = true
    end
    return is_doas
end

  # define what happens when the measure is run
def run(model, runner, user_arguments)
    super(model, runner, user_arguments)  # Do **NOT** remove this line

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end
	#read in arguments
	add_econo = runner.getBoolArgumentValue('add_econo', user_arguments)
	add_dcv = runner.getBoolArgumentValue('add_dcv', user_arguments)


	#set airflow design ratio
	min_flow = 0.4 	#Based on Catalyst

	min_flow_fraction = 0.67 #30% power for non-inverter driven motors, this is applied to flow, so roughly 30% power with cubic fan curve

	#Setting up OS standards
	standard = Standard.build('90.1-2013')
	standard_new_motor = Standard.build('90.1-2019') #to reflect new motors

	#Set up for economizer implementation for checking applicability
    no_outdoor_air_loops = 0
    doas_loops = 0
    existing_economizer_loops = 0
    selected_air_loops = []
	added_economizers = 0

  if model.sqlFile.empty?
	  #runner.registerInfo('Model had no sizing values--running size run')
	  if standard.model_run_sizing_run(model, "#{Dir.pwd}/advanced_rtu_control") == false
		  runner.registerError('Sizing run for Hardsize model failed, cannot hard-size model.')
		  return false
     end
	 model.applySizingValues
  end

	if add_econo #if adding economizing, set high level params
	  # build standard to access methods
	  template = 'ComStock 90.1-2019'
	  std = Standard.build(template)
	  # get climate zone
	  climate_zone = OpenstudioStandards::Weather.model_get_climate_zone(model)
	  #runner.registerInfo("initial read of climate zone = #{climate_zone}")
	  if climate_zone.empty?
	    runner.registerError('Unable to determine climate zone for model. Cannot apply economizer without climate zone information.')
	  end
	  # check climate zone name validity
	  # this happens to example model but maybe not during ComStock model creation?
	  substring_count = climate_zone.scan(/ASHRAE 169-2013-/).length
	  if substring_count > 1
	    #runner.registerInfo("climate zone name includes repeated substring of 'ASHRAE 169-2013-'")
		climate_zone = climate_zone.sub(/ASHRAE 169-2013-/, '')
		#runner.registerInfo("revised climate zone name = #{climate_zone}")
	  end
	  # determine economizer type
	   economizer_type = std.model_economizer_type(model, climate_zone)
	   #runner.registerInfo("economizer type for the climate zone = #{economizer_type}")
	end

	#Identify suitable loops for applying the measure
	overall_sel_air_loops =[]

	model.getAirLoopHVACs.sort.each do |air_loop_hvac|
	  next if ((air_loop_hvac.thermalZones.length() > 1) || air_loop_res?(air_loop_hvac) || air_loop_evaporative_cooler?(air_loop_hvac)|| (air_loop_hvac.name.to_s.include?("DOAS")) || (air_loop_hvac.name.to_s.include?("doas"))) || air_loop_doas?(air_loop_hvac)
	  #skip based on residential being in name, or if a DOAS
	  sizing_system = air_loop_hvac.sizingSystem
	  next if ((air_loop_hvac.name.to_s.include?("residential")) || (air_loop_hvac.name.to_s.include?("Residential")) || (sizing_system.allOutdoorAirinCooling && sizing_system.allOutdoorAirinHeating))
	  #skip VAV systems
	  next if ['VAV', 'PVAV'].any? { |word| (air_loop_hvac.name.get).include?(word) } || vav_terminals?(air_loop_hvac)
	  next if !(air_loop_hvac_unitary_system?(air_loop_hvac)) #select unitary systems only
	  overall_sel_air_loops << air_loop_hvac
	end

	#register na if no applicable air loops
	if overall_sel_air_loops.length() == 0
	  runner.registerAsNotApplicable('No applicable air loops found in model')
	end


	overall_sel_air_loops.sort.each do |air_loop_hvac| #iterating thru air loops in the model to identify ones suitable for VAV conversion
	  #set control type
	  air_loop_hvac.supplyComponents.sort.each do |component|#identifying unitary systems
	    obj_type = component.iddObjectType.valueName.to_s
	    case obj_type
        when 'OS_AirLoopHVAC_UnitarySystem'
		  component = component.to_AirLoopHVACUnitarySystem.get
		  component.setControlType('SingleZoneVAV')
		  #Set overall flow rates for air loop
		  if air_loop_hvac.autosizedDesignSupplyAirFlowRate.is_initialized #change supply air flow design parameters to match VAV conversion
		    des_supply_airflow = air_loop_hvac.autosizedDesignSupplyAirFlowRate.get #handle autosized
			component.setSupplyAirFlowRateDuringCoolingOperation(des_supply_airflow) #Set the same as before
			component.setSupplyAirFlowRateDuringHeatingOperation(des_supply_airflow) #Set same as before
			component.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(min_flow*des_supply_airflow) #Set min based on limit after retrofit
		  elsif air_loop_hvac.designSupplyAirFlowRate.is_initialized #handle hard-sized
		    des_supply_airflow = air_loop_hvac.designSupplyAirFlowRate.get
			component.setSupplyAirFlowRateDuringCoolingOperation(des_supply_airflow)
			component.setSupplyAirFlowRateDuringHeatingOperation(des_supply_airflow)
			component.setSupplyAirFlowRateWhenNoCoolingorHeatingisRequired(min_flow*des_supply_airflow)
		  end
		  sup_fan = component.supplyFan
		  if sup_fan.is_initialized #Replace constant speed with variable speed fan objects
		    sup_fan = sup_fan.get
			#handle fan on off objects; replace FanOnOff with FanVariableVolume
            if sup_fan.to_FanOnOff.is_initialized
			  sup_fan = sup_fan.to_FanOnOff.get
			  pressure_rise = sup_fan.pressureRise()
			  motor_hp = standard.fan_motor_horsepower(sup_fan)
			  fan_eff = standard.fan_baseline_impeller_efficiency(sup_fan)
			  if sup_fan.autosizedMaximumFlowRate.is_initialized
			    fan_flow = sup_fan.autosizedMaximumFlowRate.get
			  elsif sup_fan.maximumFlowRate.is_initialized
			    fan_flow = sup_fan.maximumFlowRate.get
			  end
			  #ASHRAE 90.1 2019 version of the standard to reflect motor replacement
			  fan_motor_eff = standard_new_motor.fan_standard_minimum_motor_efficiency_and_size(sup_fan, motor_hp)[0] #calculate fan motor eff per Standards
			end
			#handle constant speed fan objects; replace FanConstantVolume with FanVariableVolume
			if sup_fan.to_FanConstantVolume.is_initialized
			  sup_fan = sup_fan.to_FanConstantVolume.get
			  pressure_rise = sup_fan.pressureRise()
			  motor_hp = standard.fan_motor_horsepower(sup_fan)
			  fan_eff = standard.fan_baseline_impeller_efficiency(sup_fan)
			  if sup_fan.autosizedMaximumFlowRate.is_initialized
			    fan_flow = sup_fan.autosizedMaximumFlowRate.get
			  elsif sup_fan.maximumFlowRate.is_initialized
			    fan_flow = sup_fan.maximumFlowRate.get
			  end
			  #ASHRAE 90.1 2019 version of the standard to reflect motor replacement
			  fan_motor_eff = standard_new_motor.fan_standard_minimum_motor_efficiency_and_size(sup_fan, motor_hp)[0] #calculate fan motor eff per Standards
			end
			#create new VS fan
			fan = OpenStudio::Model::FanVariableVolume.new(model)
			fan.setName("#{air_loop_hvac.name} Fan")
			fan.setFanPowerMinimumFlowRateInputMethod("Fraction")
			fan.setPressureRise(pressure_rise)#keep it the same as the existing fan, since the balance of systems is the same
			fan.setMotorEfficiency(fan_motor_eff)
			fan.setMaximumFlowRate(fan_flow) #keep it the same as the existing fan, since the fan itself will be the same
			fan.setFanTotalEfficiency(fan_motor_eff * fan_eff)
			#set fan curve coefficients
			standard.fan_variable_volume_set_control_type(fan, 'Single Zone VAV Fan ')
			fan.setFanPowerMinimumFlowFraction(min_flow_fraction) #resetting minimum flow fraction to be appropriate for retrofit as opposed to 10% in method above
			#Add it to the unitary sys
			component.setSupplyFan(fan)
		  end
		end
	  end
	  air_loop_hvac.thermalZones.each do |thermal_zone| #iterate thru thermal zones and modify zone-level terminal units
	    min_oa_flow_rate_cont = 0
        #See if a minimum OA flow rate is already set
	    if air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized
		  oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
		  controller_oa = oa_system.getControllerOutdoorAir
		    if controller_oa.autosizedMinimumOutdoorAirFlowRate.is_initialized
			  min_oa_flow_rate_cont = controller_oa.autosizedMinimumOutdoorAirFlowRate.get
		    elsif controller_oa.minimumOutdoorAirFlowRate.is_initialized
		      min_oa_flow_rate_cont = controller_oa.minimumOutdoorAirFlowRate.get
			end
		end
		#if min OA flow rate is 0, or if it isn't set, calculate it
		if min_oa_flow_rate_cont == 0
		    min_oa_flow_rate = thermal_zone_outdoor_airflow_rate(thermal_zone)
		elsif
		   min_oa_flow_rate = min_oa_flow_rate_cont
		end
		thermal_zone.equipment.each do |equip|
		  if equip.to_AirTerminalSingleDuctConstantVolumeNoReheat.is_initialized
		    term = equip.to_AirTerminalSingleDuctConstantVolumeNoReheat.get
			new_term = OpenStudio::Model::AirTerminalSingleDuctVAVHeatAndCoolNoReheat.new(model) #create new terminal unit
			if term.autosizedMaximumAirFlowRate.is_initialized
			  des_airflow_rate = term.autosizedMaximumAirFlowRate.get
			  new_term.setMaximumAirFlowRate(des_airflow_rate) #same as before
			  #set minimum based on max of 40% of max flow, or min ventilation level req'd
			  new_term.setZoneMinimumAirFlowFraction([min_flow, min_oa_flow_rate/des_airflow_rate].max)
			elsif term.maximumAirFlowRate.is_initialized
			  des_airflow_rate = term.maximumAirFlowRate.get
			  new_term.setMaximumAirFlowRate(des_airflow_rate) #same as before
			  #set minimum based on max of 40% of max flow, or min ventilation level req'd
			  new_term.setZoneMinimumAirFlowFraction([min_flow, min_oa_flow_rate/des_airflow_rate].max)
		    end
			air_loop_hvac.removeBranchForZone(thermal_zone)
			air_loop_hvac.addBranchForZone(thermal_zone, new_term)
		  end
		end
	  end
	end
	#handle DCV in appropriate air loops, after screening out those that aren't suitable
	if add_dcv
	  overall_sel_air_loops.sort.each do |air_loop_hvac|
	  unless(no_DCV_zones?(air_loop_hvac))
	    oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
		controller_oa = oa_system.getControllerOutdoorAir
		controller_mv = controller_oa.controllerMechanicalVentilation
		controller_mv.setDemandControlledVentilation(true)
		air_loop_hvac.thermalZones.each do |thermal_zone|
		#Set design OA object attributes
		thermal_zone.spaces.each do |space|
			dsn_oa = space.designSpecificationOutdoorAir
			next if dsn_oa.empty?
			dsn_oa = dsn_oa.get
			# set design specification outdoor air objects to sum
			dsn_oa.setOutdoorAirMethod('Sum')
			# Get the space properties
			floor_area = space.floorArea * space.multiplier
			number_of_people = space.numberOfPeople * space.multiplier
			people_per_m2 = space.peoplePerFloorArea

			# Sum up the total OA from all sources
			oa_for_people_per_m2 = people_per_m2 * dsn_oa.outdoorAirFlowperPerson
			oa_for_floor_area_per_m2 = dsn_oa.outdoorAirFlowperFloorArea
			tot_oa_per_m2 = oa_for_people_per_m2 + oa_for_floor_area_per_m2
			tot_oa_cfm_per_ft2 = OpenStudio.convert(OpenStudio.convert(tot_oa_per_m2, 'm^3/s', 'cfm').get, '1/m^2', '1/ft^2').get
			tot_oa_cfm = floor_area * tot_oa_cfm_per_ft2

			# if both per-area and per-person are present, does not need to be modified
			if !dsn_oa.outdoorAirFlowperPerson.zero? && !dsn_oa.outdoorAirFlowperFloorArea.zero?
			next

			# if both are zero, skip space
			elsif dsn_oa.outdoorAirFlowperPerson.zero? && dsn_oa.outdoorAirFlowperFloorArea.zero?
			#runner.registerInfo("Space '#{space.name}' has 0 outdoor air per-person and per-area rates. DCV may be still be applied to this air loop, but it will not function on this space.")
			next

			# if per-person or per-area values are zero, set to 10 cfm / person and allocate the rest to per-area
			elsif dsn_oa.outdoorAirFlowperPerson.zero? || dsn_oa.outdoorAirFlowperFloorArea.zero?

			if dsn_oa.outdoorAirFlowperPerson.zero?
				#runner.registerInfo("Space '#{space.name}' per-person outdoor air rate is 0. Using a minimum of 10 cfm / person and assigning the remaining space outdoor air requirement to per-area.")
			elsif dsn_oa.outdoorAirFlowperFloorArea.zero?
				#runner.registerInfo("Space '#{space.name}' per-area outdoor air rate is 0. Using a minimum of 10 cfm / person and assigning the remaining space outdoor air requirement to per-area.")
			end

			# default ventilation is 10 cfm / person
			per_person_ventilation_rate = OpenStudio.convert(10, 'ft^3/min', 'm^3/s').get

			# assign remaining oa to per-area
			new_oa_for_people_per_m2 = people_per_m2 * per_person_ventilation_rate
			new_oa_for_people_cfm_per_f2 = OpenStudio.convert(OpenStudio.convert(new_oa_for_people_per_m2, 'm^3/s', 'cfm').get, '1/m^2', '1/ft^2').get
			new_oa_for_people_cfm = number_of_people * new_oa_for_people_cfm_per_f2
			remaining_oa_per_m2 = tot_oa_per_m2 - new_oa_for_people_per_m2
			if remaining_oa_per_m2 <= 0
				#runner.registerInfo("Space '#{space.name}' has #{number_of_people.round(1)} people which corresponds to a ventilation minimum requirement of #{new_oa_for_people_cfm.round(0)} cfm at 10 cfm / person, but total zone outdoor air is only #{tot_oa_cfm.round(0)} cfm. Setting all outdoor air as per-person.")
				per_person_ventilation_rate = tot_oa_per_m2 / people_per_m2
				dsn_oa.setOutdoorAirFlowperFloorArea(0.0)
			else
				oa_per_area_per_m2 = remaining_oa_per_m2
				dsn_oa.setOutdoorAirFlowperFloorArea(oa_per_area_per_m2)
			end
			dsn_oa.setOutdoorAirFlowperPerson(per_person_ventilation_rate)
			end
		end
		end
        standard.air_loop_hvac_enable_demand_control_ventilation(air_loop_hvac, '')
	  end
	  end
	end
	if add_econo #handle economizing if implementing it
	  overall_sel_air_loops.sort.each do |air_loop_hvac|
	    oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem
		if oa_system.is_initialized
		  oa_system = oa_system.get
		else
		  #runner.registerInfo("Air loop #{air_loop_hvac.name} does not have outdoor air and cannot economize.")
		  next
		end
		sizing_system = air_loop_hvac.sizingSystem
		type_of_load = sizing_system.typeofLoadtoSizeOn
		if type_of_load == 'VentilationRequirement'
			#runner.registerInfo("Air loop #{air_loop_hvac.name} is a DOAS system and cannot economize.")
			next
		end
		oa_controller = oa_system.getControllerOutdoorAir
		current_economizer_type = oa_controller.getEconomizerControlType
		if current_economizer_type == 'NoEconomizer'
			#runner.registerInfo("Air loop #{air_loop_hvac.name} does not have an existing economizer.  This measure will add an economizer.")
			selected_air_loops << air_loop_hvac
		else
			#runner.registerInfo("Air loop #{air_loop_hvac.name} has an existing #{current_economizer_type} economizer.")
			next
		end
		# get airLoopHVACOutdoorAirSystem
		oa_sys = air_loop_hvac.airLoopHVACOutdoorAirSystem
		if oa_sys.is_initialized
			oa_sys = oa_sys.get
		else
			OpenStudio.logFree(OpenStudio::Error, 'openstudio.prototype.Model', "#{air_loop.name} is required to have an economizer, but it has no OA system.")
			next
		end
		# get controller:outdoorair
		oa_control = oa_sys.getControllerOutdoorAir
		oa_control.setEconomizerControlType(economizer_type)
		if oa_control.getEconomizerControlType != economizer_type
			##runner.registerInfo("--- adding economizer to air loop hvac = #{air_loop_hvac.name}")
			oa_control.setEconomizerControlType(economizer_type)
		end
		# get economizer limits
		limits = std.air_loop_hvac_economizer_limits(air_loop_hvac, climate_zone) # in IP unit
		# #runner.registerInfo("--- economizer limits [db max|enthal max|dewpoint max] for the climate zone = #{limits}")
			# implement limits for each control type
		case economizer_type
		when 'FixedDryBulb'
		if oa_control.getEconomizerMaximumLimitDryBulbTemperature.is_initialized
			##runner.registerInfo("--- economizer limit for #{economizer_type} before: #{oa_control.getEconomizerMaximumLimitDryBulbTemperature.get}")
		end
		drybulb_limit_c = OpenStudio.convert(limits[0], 'F', 'C').get
		oa_control.resetEconomizerMaximumLimitDryBulbTemperature
		oa_control.setEconomizerMaximumLimitDryBulbTemperature(drybulb_limit_c)
		# #runner.registerInfo("--- economizer limit for #{economizer_type} new: #{oa_control.getEconomizerMaximumLimitDryBulbTemperature.get}")
		when 'FixedEnthalpy'
		if oa_control.getEconomizerMaximumLimitEnthalpy.is_initialized
			##runner.registerInfo("--- economizer limit for #{economizer_type} before: #{oa_control.getEconomizerMaximumLimitEnthalpy.get}")
		end
		enthalpy_limit_j_per_kg = OpenStudio.convert(limits[1], 'Btu/lb', 'J/kg').get
		oa_control.resetEconomizerMaximumLimitEnthalpy
		oa_control.setEconomizerMaximumLimitEnthalpy(enthalpy_limit_j_per_kg)
		# #runner.registerInfo("--- economizer limit for #{economizer_type} new: #{oa_control.getEconomizerMaximumLimitEnthalpy.get}")
		when 'FixedDewPointAndDryBulb'
		if oa_control.getEconomizerMaximumLimitDewpointTemperature.is_initialized
			##runner.registerInfo("--- economizer limit for #{economizer_type} before: #{oa_control.getEconomizerMaximumLimitDewpointTemperature.get}")
		end
		drybulb_limit_f = 75
		dewpoint_limit_f = 55
		drybulb_limit_c = OpenStudio.convert(drybulb_limit_f, 'F', 'C').get
		dewpoint_limit_c = OpenStudio.convert(dewpoint_limit_f, 'F', 'C').get
		oa_control.resetEconomizerMaximumLimitDryBulbTemperature
		oa_control.resetEconomizerMaximumLimitDewpointTemperature
		oa_control.setEconomizerMaximumLimitDryBulbTemperature(drybulb_limit_c)
		oa_control.setEconomizerMaximumLimitDewpointTemperature(dewpoint_limit_c)
		# #runner.registerInfo("--- economizer limit (max db T) for #{economizer_type} new: #{oa_control.getEconomizerMaximumLimitDryBulbTemperature.get}")
		# #runner.registerInfo("--- economizer limit (max dp T) for #{economizer_type} new: #{oa_control.getEconomizerMaximumLimitDewpointTemperature.get}")
		end
		# change/check settings: lockout type
		# #runner.registerInfo("--- economizer lockout type before: #{oa_control.getLockoutType}")
		if oa_control.getLockoutType != "LockoutWithHeating"
		oa_control.setLockoutType("LockoutWithHeating") # integrated economizer
		end
		# #runner.registerInfo("--- economizer lockout type new: #{oa_control.getLockoutType}")

		# calc statistics
		added_economizers += 1
		end
	end

	if selected_air_loops.size.zero? && add_econo
			#runner.registerInfo('Model contains no air loops eligible for adding an outdoor air economizer.')
	end
	#deal with economizer controls
	if add_econo
	  # #runner.registerInfo("### implement EMS for economizing only when cooling")
	  # ----------------------------------------------------
	  # for ems output variables
	  li_ems_clg_coil_rate = []
	  li_ems_sens_econ_status = []
	  li_ems_sens_min_flow = []
	  li_ems_act_oa_flow = []

	  # loop through air loops
	  overall_sel_air_loops.each do |air_loop_hvac|

	  # get OA system
	  oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem
	  if oa_system.is_initialized
		oa_system = oa_system.get
	  else
		#runner.registerInfo("Air loop #{air_loop_hvac.name} does not have outdoor air and cannot economize.")
		next
	  end

	  # get economizer from OA controller
	  oa_controller = oa_system.getControllerOutdoorAir
	  # oa_controller.setName(oa_controller.name.to_s.gsub("-", ""))
	  economizer_type = oa_controller.getEconomizerControlType
	  next unless economizer_type != 'NoEconomizer'

	  # get zones
	  zone = air_loop_hvac.thermalZones[0]
	  # zone.setName(zone.name.to_s.gsub("-", ""))

	  # get main cooling coil from air loop
	  # this is used to determine if there is a cooling load on the air loop
	  clg_coil=nil
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
		  unitary_sys = component.to_AirLoopHVACUnitaryHeatPumpAirToAirMultiSpeed.get
		  if unitary_sys.coolingCoil.is_initialized
			clg_coil = unitary_sys.coolingCoil.get
		  end
		end
	  end

	  # set sensor for zone cooling load from cooling coil cooling rate
	  sens_clg_coil_rate = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Cooling Coil Total Cooling Rate')
	  sens_clg_coil_rate.setName("sens_zn_clg_rate_#{OpenstudioStandards::HVAC.ems_friendly_name(zone.name.get.to_s)}")
	  sens_clg_coil_rate.setKeyName("#{clg_coil.name.get}")
	  # EMS variables are added to lists for export
	  li_ems_clg_coil_rate << sens_clg_coil_rate

	  # set sensor - Outdoor Air Controller Minimum Mass Flow Rate
	  # TODO need to confirm if this variable is reliable
	  sens_min_oa_rate = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Air System Outdoor Air Mechanical Ventilation Requested Mass Flow Rate')
	  sens_min_oa_rate.setName("sens_min_oa_flow_#{OpenstudioStandards::HVAC.ems_friendly_name(oa_controller.name.get.to_s)}")
	  sens_min_oa_rate.setKeyName("#{air_loop_hvac.name.get}")

	  li_ems_sens_min_flow << sens_min_oa_rate

	  # set sensor - Air System Outdoor Air Economizer Status
	  sens_econ_status = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Air System Outdoor Air Economizer Status')
	  sens_econ_status.setName("sens_econ_status_#{OpenstudioStandards::HVAC.ems_friendly_name(oa_controller.name.get.to_s)}")
	  sens_econ_status.setKeyName("#{air_loop_hvac.name.get}")
	  li_ems_sens_econ_status << sens_econ_status

	  #### Actuators #####
	  # set actuator - oa controller air mass flow rate
	  act_oa_flow = OpenStudio::Model::EnergyManagementSystemActuator.new(oa_controller,'Outdoor Air Controller', 'Air Mass Flow Rate')
	  act_oa_flow.setName("act_oa_flow_#{OpenstudioStandards::HVAC.ems_friendly_name(air_loop_hvac.name.get.to_s)}")
	  li_ems_act_oa_flow << act_oa_flow

	  #### Program #####
	  # reset OA to min OA if there is a call for economizer but no cooling load
	  prgrm_econ_override = model.getEnergyManagementSystemTrendVariableByName('econ_override')
	  unless prgrm_econ_override.is_initialized
	    prgrm_econ_override = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
		prgrm_econ_override.setName("#{OpenstudioStandards::HVAC.ems_friendly_name(air_loop_hvac.name.get.to_s)}_program")
		prgrm_econ_override_body = <<-EMS
		SET #{act_oa_flow.name} = #{act_oa_flow.name},
		SET sens_zn_clg_rate = #{sens_clg_coil_rate.name},
		SET sens_min_oa_rate = #{sens_min_oa_rate.name},
		SET sens_econ_status = #{sens_econ_status.name},
		IF ((sens_econ_status > 0) && (sens_zn_clg_rate <= 0)),
		SET #{act_oa_flow.name} = sens_min_oa_rate,
		ELSE,
		SET #{act_oa_flow.name} = Null,
		ENDIF
		EMS
		prgrm_econ_override.setBody(prgrm_econ_override_body)
	  end
	  programs_at_beginning_of_timestep = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
	  programs_at_beginning_of_timestep.setName("#{OpenstudioStandards::HVAC.ems_friendly_name(air_loop_hvac.name.get.to_s)}_Programs_At_Beginning_Of_Timestep")
	  programs_at_beginning_of_timestep.setCallingPoint('InsideHVACSystemIterationLoop')
	  programs_at_beginning_of_timestep.addProgram(prgrm_econ_override)
	  end
    end
 return true
end
end
# register the measure to be used by the application
AdvancedRTUControl.new.registerWithApplication
