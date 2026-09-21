# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

require 'comstock-typical'

# start the measure
class HardsizeModel < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'Hardsize Model'
  end

  # human readable description
  def description
    return 'Sets the HVAC capacities and flow rates in the model.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'Runs a sizing run and applies EnerygyPlus autosized values into the model.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # Daylight Savings Time
    apply_hardsize = OpenStudio::Measure::OSArgument.makeBoolArgument('apply_hardsize', true)
    apply_hardsize.setDisplayName('Hardsize model')
    apply_hardsize.setDescription('Set to true to hardsize model HVAC, set to false to leave model autosized')
    apply_hardsize.setDefaultValue(true)
    args << apply_hardsize

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # Assign the user inputs to variables
    apply_hardsize = runner.getBoolArgumentValue('apply_hardsize', user_arguments)

    unless apply_hardsize
      runner.registerAsNotApplicable("Leaving model autosized per argument: apply_hardsize = #{apply_hardsize}")
      return true
    end

    reset_log
    standard = Standard.build('ComStock DOE Ref Pre-1980') # Actual standard doesn't matter

    # Collect equipment capacities and flow rates that are hard-sized by OpenStudio-Standards.
    # These fields need to keep the hard-sized values and not be replaced with the
    # autosized values determined by EnergyPlus.
    # The eventual goal is to have OpenStudio-Standards rely entirely on EnergyPlus autosizing,
    # such that all of this code can be removed.

    # TODO: remove this after feature https://github.com/NREL/openstudio-standards/issues/1391 is implemented
    # Get the terminal minimum damper positions and preserve them after the hard-sizing
    # because damper position is hard-sized by openstudio-standards, not autosized
    # Min OA flow rate at these damper positions is also hard-sized.
    vav_damper_posits = {}
    vav_max_rht_fracs = {}
    model.getAirTerminalSingleDuctVAVReheats.each do |term|
      if (term.zoneMinimumAirFlowInputMethod == 'Constant') && !term.isConstantMinimumAirFlowFractionAutosized
        vav_damper_posits[term] = term.constantMinimumAirFlowFraction.get
      end
      unless term.isMaximumFlowFractionDuringReheatAutosized
        vav_max_rht_fracs[term] = term.maximumFlowFractionDuringReheat.get
      end
    end
    # EnergyPlus sizes a hot water reheat coil at the terminal's maximum reheat air flow but
    # loads it with the zone's heating design flow, so a reheat fraction below the zone's
    # heating-to-maximum flow ratio makes the coil UA impossible to size and the sizing run
    # fatal (NREL/EnergyPlus#11078). openstudio-standards sets the fraction from the first
    # sizing run's flows, but the template measures between that run and this one change the
    # loads: in the 2026-09 100k run two small offices and a warehouse tripled a zone's
    # heating load through envelope replacements and died here. Let EnergyPlus size the
    # fraction in this run, then set the final value from this run's flows below, never lower
    # than the dual-maximum value the terminal came in with.
    reverse_limit_terms = model.getAirTerminalSingleDuctVAVReheats.select do |term|
      term.damperHeatingAction == 'ReverseWithLimits' && term.reheatCoil.to_CoilHeatingWater.is_initialized
    end
    reverse_limit_terms.each do |term|
      term.autosizeMaximumFlowFractionDuringReheat
      term.autosizeMaximumFlowPerZoneFloorAreaDuringReheat
    end

    vav_max_htg_flows = {}
    vav_min_oas = {}
    model.getSizingSystems.each do |sizing_system|
      unless sizing_system.isCentralHeatingMaximumSystemAirFlowRatioAutosized
        vav_max_htg_flows[sizing_system] = sizing_system.centralHeatingMaximumSystemAirFlowRatio.get
      end
      unless sizing_system.isDesignOutdoorAirFlowRateAutosized
        vav_min_oas[sizing_system] = sizing_system.designOutdoorAirFlowRate.get
      end
    end

    # Run a sizing run to determine equipment capacities and flow rates
    if standard.model_run_sizing_run(model, "#{Dir.pwd}/hardsize_model_SR") == false
      runner.registerError('Sizing run for Hardsize model failed, cannot hard-size model.')
      puts('Sizing run for Hardsize model failed, cannot hard-size model.')
      return false
    end

    # Apply the capacities and flow rates from the sizing run to the model
    runner.registerInfo('Hard-sizing HVAC equipment to capacities and flows used to set efficiencies and controls.')
    model.applySizingValues

    # Reset some fields to the previously-collected hard-sized values
    model.getAirLoopHVACUnitarySystems.each do |unitary|
      if model.version < OpenStudio::VersionString.new('3.7.0')
        unitary.setSupplyAirFlowRateMethodDuringCoolingOperation('SupplyAirFlowRate')
        unitary.setSupplyAirFlowRateMethodDuringHeatingOperation('SupplyAirFlowRate')
      else
        unitary.applySizingValues
      end
    end

    # TODO: remove once this functionality is added to the OpenStudio C++ for hard sizing Sizing:System
    model.getSizingSystems.each do |sizing_system|
      next if sizing_system.isDesignOutdoorAirFlowRateAutosized

      sizing_system.setSystemOutdoorAirMethod('ZoneSum')
    end

    # Every OpenStudio outdoor air controller carries a Controller:MechanicalVentilation. Once the
    # minimum outdoor air flow above has been hard-sized to the sizing run's design value, a
    # ZoneSum controller with demand controlled ventilation off can never ask for more than
    # that fixed minimum, so it governs nothing - but EnergyPlus compares the two every
    # iteration and logs "Min OA fraction > Mechanical ventilation OA fraction" each time it
    # loses. In the leg D validation that one message was 58% of all annual warnings, 125
    # million occurrences, 415,000 per controller on a secondary school, and the buildings
    # carrying it were the slowest annual runs in the fleet.
    #
    # Turning the controller off through its availability schedule leaves the outdoor air
    # delivered identical - measured to 1e-13 over two weeks on a school and a medium office -
    # and removes the warning. Controllers with a zero or autosized minimum (the multizone
    # VAV path, and any loop with DCV enabled) rely on the mechanical ventilation controller
    # for their outdoor air and are left alone.
    mech_vent_off = 0
    model.getAirLoopHVACs.each do |air_loop|
      next unless air_loop.airLoopHVACOutdoorAirSystem.is_initialized

      controller_oa = air_loop.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
      next unless controller_oa.minimumOutdoorAirFlowRate.is_initialized
      next unless controller_oa.minimumOutdoorAirFlowRate.get > 0.0
      # a plain string in this SDK; an optional in older ones
      limit_type = controller_oa.getMinimumLimitType
      limit_type = limit_type.is_initialized ? limit_type.get : nil if limit_type.respond_to?(:is_initialized)
      next unless limit_type == 'FixedMinimum'

      controller_mv = controller_oa.controllerMechanicalVentilation
      next if controller_mv.demandControlledVentilation
      next unless controller_mv.systemOutdoorAirMethod == 'ZoneSum'

      controller_mv.setAvailabilitySchedule(model.alwaysOffDiscreteSchedule)
      mech_vent_off += 1
    end
    runner.registerInfo("Set the mechanical ventilation controller availability to always off on #{mech_vent_off} air loops whose hard-sized fixed minimum outdoor air already governs.")

    # TODO: remove once this functionality is added to the OpenStudio C++ for hard sizing
    model.getAirTerminalSingleDuctVAVReheats.each do |term|
      next unless term.damperHeatingAction == 'Normal'

      term.autosizeMaximumFlowFractionDuringReheat
      term.autosizeMaximumFlowPerZoneFloorAreaDuringReheat
    end

    # TODO: remove this after feature https://github.com/NREL/openstudio-standards/issues/1391 is implemented
    # Re-apply hardsized VAV damper positions
    model.getAirTerminalSingleDuctVAVReheats.each do |term|
      if vav_damper_posits.key?(term)
        term.setConstantMinimumAirFlowFraction(vav_damper_posits[term])
      end
      if vav_max_rht_fracs.key?(term)
        term.setMaximumFlowFractionDuringReheat(vav_max_rht_fracs[term])
      end
    end

    # Reheat fraction of the reverse-with-limits terminals from this sizing run's flows: the
    # larger of the value the terminal came in with (0.5 for a dual-maximum control) and the
    # zone heating design flow over the terminal maximum flow, so the coil the run just sized
    # can carry the zone's heating flow.
    zone_by_terminal = {}
    model.getThermalZones.each do |zone|
      next unless zone.airLoopHVACTerminal.is_initialized

      zone_by_terminal[zone.airLoopHVACTerminal.get.handle.to_s] = zone
    end
    reverse_limit_terms.each do |term|
      zone = zone_by_terminal[term.handle.to_s]
      next if zone.nil?

      standard.air_terminal_single_duct_vav_reheat_apply_dual_maximum_reheat_fraction(term, zone, vav_max_rht_fracs.fetch(term, 0.5))
    end

    return true
  end
end

# register the measure to be used by the application
HardsizeModel.new.registerWithApplication
