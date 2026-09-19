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
class UpgradeHvacEnableIdealAirLoads < OpenStudio::Measure::ModelMeasure
  # define the name that a user will see, this method may be deprecated as
  # the display name in PAT comes from the name field in measure.xml
  def name
    return 'Upgrade HVAC Enable Ideal Air Loads'
  end

  # human readable description
  def description
    return 'Replaces all HVAC systems with conceptual ZoneHVACIdealLoadsAirSystems to model building thermal loads.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'All HVAC systems are removed and replaced with ZoneHVACIdealLoadsAirSystems objects. Outdoor ventilation air follows occupancy schedule, which may not align with the original HVAC ventilation schedule found in the baseline model. All thermostat schedules are held constant with baseline model. Energy from ZoneHVACIdealLoadsAirSystems is reported under district end uses, not necesarily aligning with the HVAC fuel type of the baseline model.'
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

    # check which zone already include ideal air loads
    existing_ideal_loads = model.getZoneHVACIdealLoadsAirSystems
    runner.registerInitialCondition("The model has #{existing_ideal_loads.size} ideal air loads objects.")

    # dummy standard to access methods in openstudio-standards
    std = Standard.build('90.1-2013')

    # remove existing HVAC
    runner.registerInfo('Removing existing HVAC systems from the model')
    std.remove_hvac(model)

    # add zone hvac ideal load air system objects
    conditioned_zones = []
    model.getThermalZones.each do |zone|
      next if zone.name.to_s.downcase.include?('plenum')
      next if !OpenstudioStandards::ThermalZone.thermal_zone_heated?(zone) && !OpenstudioStandards::ThermalZone.thermal_zone_cooled?(zone)

      conditioned_zones << zone
    end

    if conditioned_zones.empty?
      runner.registerAsNotApplicable('No conditioned thermal zones found in model. Ideal air loads are not applicable to this model.')
      return true
    end

    # modify design outdoor air object to follow occupancy; ComStock DSOA objects do not have schedules by default
    conditioned_zones.each do |zone|
      sch_ruleset = OpenstudioStandards::ThermalZone.thermal_zones_get_occupancy_schedule(thermal_zones = [zone],
                                                                                          occupied_percentage_threshold: 0.05)
      zone.spaces.each do |space|
        next unless space.designSpecificationOutdoorAir.is_initialized

        dsn_oa = space.designSpecificationOutdoorAir.get
        dsn_oa.setOutdoorAirFlowRateFractionSchedule(sch_ruleset)
      end
    end

    # add ideal air loads
    ideal_loads_objects = std.model_add_ideal_air_loads(model,
                                                        conditioned_zones,
                                                        hvac_op_sch: nil,
                                                        heat_avail_sch: nil,
                                                        cool_avail_sch: nil,
                                                        heat_limit_type: 'NoLimit',
                                                        cool_limit_type: 'NoLimit',
                                                        dehumid_limit_type: 'ConstantSensibleHeatRatio',
                                                        cool_sensible_heat_ratio: 0.75,
                                                        humid_ctrl_type: 'None',
                                                        include_outdoor_air: true,
                                                        enable_dcv: false,
                                                        econo_ctrl_mthd: 'NoEconomizer',
                                                        heat_recovery_type: 'None',
                                                        heat_recovery_sensible_eff: 0.7,
                                                        heat_recovery_latent_eff: 0.65,
                                                        add_output_meters: false)


    # remove any EMS objects tied to ground HX; these will fail model since HVAC has been removed
    # get all EMS objects in the model
    ems_objects = model.getEnergyManagementSystemSensors +
                  model.getEnergyManagementSystemActuators +
                  model.getEnergyManagementSystemPrograms +
                  model.getEnergyManagementSystemProgramCallingManagers +
                  model.getEnergyManagementSystemInternalVariables

    # Filter EMS objects that contain any of the strings in the list
    ems_string_to_remove = ['Ground_HX', 'VAV']
    ems_objects_to_remove = ems_objects.select do |ems_object|
      ems_string_to_remove.any? { |str| ems_object.name.to_s.include?(str) }
    end

    # Remove each matching EMS object from the model
    ems_objects_to_remove.each do |object_to_remove|
      # Remove the EMS object from the model
      runner.registerInfo('Removing unused GSHP objects from the model.')
      object_to_remove.remove
    end


    # validity checks
    if ideal_loads_objects.empty?
      runner.registerError('Failure in creating ideal loads objects.  See logs from [openstudio.model.Model]. Likely cause is an invalid schedule input or schedule removed from by another measure.')
      return false
    end

    # runner register final conditions of model
    runner.registerFinalCondition("The model has #{ideal_loads_objects.size} ideal air loads objects.")

    return true
  end
end

# this allows the measure to be use by the application
UpgradeHvacEnableIdealAirLoads.new.registerWithApplication
