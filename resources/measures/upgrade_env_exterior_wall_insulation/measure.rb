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
class ExteriorWallInsulation < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    return 'Exterior Wall Insulation'
  end

  # human readable description
  def description
    return 'Exterior wall insulation is, as the name suggests, attached to the exterior of the structural elements in the existing wall and covered by a cladding system. For purposes of this document, it refers to rigid or semi-rigid board insulation, not to spray-applied insulation.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'Determine the thickness of extruded polystyrene insulation required to meet the specified R-value, determined from the AEDG target assembly performance for each climate zone.  Find all the constructions used by exterior walls in the model, clone them, add a layer of insulation to the cloned constructions, and then assign the construction back to the wall.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # Use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # get climate zone to set target_r_val_ip
    climate_zone = OpenstudioStandards::Weather.model_get_climate_zone(model)

    # apply target R-value by climate zone
    if climate_zone.include?('ASHRAE 169-2013-1') || climate_zone.include?('ASHRAE 169-2013-2') || climate_zone.include?('CEC15')
      target_r_val_ip = 13.0
    elsif climate_zone.include?('ASHRAE 169-2013-3') || climate_zone.include?('ASHRAE 169-2013-4')
      target_r_val_ip = 16.0
    elsif climate_zone.include?('ASHRAE 169-2013-5') || climate_zone.include?('CEC16')
      target_r_val_ip = 19.0
    elsif climate_zone.include?('ASHRAE 169-2013-6') || climate_zone.include?('ASHRAE 169-2013-7')
      target_r_val_ip = 21.0
    elsif climate_zone.include?('ASHRAE 169-2013-8')
      target_r_val_ip = 29.0
    else # all DEER climate zones except 15 and 16
      target_r_val_ip = 16.0
    end
    # Convert target_r_val_ip to si
    target_r_val_si = OpenStudio.convert(target_r_val_ip, 'ft^2*h*R/Btu', 'm^2*K/W').get
    runner.registerInfo("Target R-Value for #{climate_zone} is R-#{target_r_val_ip} ft^2*h*R/Btu")

    # Extruded Polystyrene Material Properties
    # Material,
    # Expanded Polystyrene - Extruded - 1 in.,  ! Name
    # MediumSmooth,             ! Roughness
    # 0.0254,                   ! Thickness {m}
    # 0.029,                    ! Conductivity {W/m-K}
    # 29,                       ! Density {kg/m3}
    # 1210,                     ! Specific Heat {J/kg-K}
    # 0.9,                      ! Thermal Absorptance
    # 0.7,                      ! Solar Absorptance
    # 0.7;                      ! Visible Absorptance
    ins_layer_xps_ref = OpenStudio::Model::StandardOpaqueMaterial.new(model)
    ins_layer_xps_ref.setRoughness('MediumSmooth')
    ins_layer_xps_ref.setThickness(0.0254)
    ins_layer_xps_ref.setConductivity(0.029)
    ins_layer_xps_ref.setDensity(29.0)
    ins_layer_xps_ref.setSpecificHeat(1210.0)
    ins_layer_xps_ref.setThermalAbsorptance(0.9)
    ins_layer_xps_ref.setSolarAbsorptance(0.7)
    ins_layer_xps_ref.setVisibleAbsorptance(0.7)

    xps_r_si = 1.0 / ins_layer_xps_ref.thermalConductance.to_f
    xps_r_ip = OpenStudio.convert(xps_r_si, 'm^2*K/W', 'ft^2*h*R/Btu').get
    xps_thickness_m = ins_layer_xps_ref.thickness
    xps_thickness_in = OpenStudio.convert(xps_thickness_m, 'm', 'in').get
    xpr_r_ip_per_in = (xps_r_ip / xps_thickness_in).round(1)
    runner.registerInfo("Assuming Extruded Polystyrene (XPS) with an R-value of #{xpr_r_ip_per_in} ft^2*h*R/Btu per inch")

    # Find all exterior walls and get a list of their constructions
    wall_constructions = []
    model.getSurfaces.each do |surface|
      next unless (surface.outsideBoundaryCondition == 'Outdoors') && (surface.surfaceType == 'Wall')
      next if surface.construction.empty?

      wall_constructions << surface.construction.get
    end

    # For each exterior wall construction, make a clone
    # and add the insulation necessary to hit the target R-value.
    # For
    old_to_new_construction_map = {}
    wall_constructions.uniq.each do |wall_construction|
      # Get the construction type
      const_type = wall_construction.standardsInformation.standardsConstructionType
      if const_type.empty?
        runner.registerWarning("Could not determine the construction type for #{wall_construction.name}, cannot evaluate applicability of insulation, skpping this construction.")
        next
      end

      # Skip if the wall type is Metal Building, this measure is not applicable to metal buildings.
      if const_type.get == 'Metal Building'
        runner.registerInfo("For #{wall_construction.name}, construction type is Metal Building, cannot apply exterior insulation.")
        next
      end

      # Skip if the R-value already meets the target
      ext_wall_r_si = 1.0 / wall_construction.thermalConductance.to_f
      ext_wall_r_ip = OpenStudio.convert(ext_wall_r_si, 'm^2*K/W', 'ft^2*h*R/Btu').get
      runner.registerInfo("For #{wall_construction.name}, the existing assembly R-value (without air films) is #{ext_wall_r_ip.round(3)}.")
      if ext_wall_r_si >= target_r_val_si
        runner.registerInfo("For #{wall_construction.name}, the existing assembly R-value of #{ext_wall_r_ip.round(3)} meets or exceeds the target.")
        next
      end

      # Set xps target r-value as total target r-value minus existing r-value
      xps_target_r_val_si = target_r_val_si - ext_wall_r_si
      xps_target_r_val_ip = OpenStudio.convert(xps_target_r_val_si, 'm^2*K/W', 'ft^2*h*R/Btu').get

      # Calculate the thickness required to meet the desired R-Value
      reqd_thickness_si = xps_target_r_val_si * ins_layer_xps_ref.thermalConductivity
      reqd_thickness_ip = OpenStudio.convert(reqd_thickness_si, 'm', 'in').get
      runner.registerInfo("For #{wall_construction.name}, hitting the target R-Value exactly would require #{reqd_thickness_ip.round(3)} inches of insulation.")

      # Skip if the required insulation to be added is less than 0.5 inch thick
      if reqd_thickness_ip < 0.5
        runner.registerInfo("For #{wall_construction.name}, the insulation required to meet the target R-value is less than 0.5 inch thick, not applicable to these walls.")
        next
      end

      # Round to nearest inch
      rounded_thickness_ip = reqd_thickness_ip.round
      rounded_thickness_si = OpenStudio.convert(rounded_thickness_ip, 'in', 'm').get
      runner.registerInfo("The closest commonly available insulation product is #{rounded_thickness_ip} inches thick.")

      # Create the insulation layer
      ins_layer_xps = ins_layer_xps_ref.clone(model).to_StandardOpaqueMaterial.get
      ins_layer_xps.setThickness(rounded_thickness_si)
      ins_layer_xps_r_si = 1.0 / ins_layer_xps.thermalConductance.to_f
      ins_layer_xps_r_ip = OpenStudio.convert(ins_layer_xps_r_si, 'm^2*K/W', 'ft^2*h*R/Btu').get
      ins_layer_xps.setName("Extruded Polystyrene - #{rounded_thickness_ip.round(1)} in.")

      # Assume existing cladding is removed, insulation is installed, then same cladding material is re-installed on top
      wall_construction_plus_ins = wall_construction.clone(model).to_Construction.get
      wall_construction_plus_ins.insertLayer(1, ins_layer_xps)
      wall_construction_plus_ins.setInsulation(ins_layer_xps)
      wall_construction_plus_ins.setName("#{wall_construction.name} plus R-#{ins_layer_xps_r_ip.round(1)} XPS")
      old_to_new_construction_map[wall_construction] = wall_construction_plus_ins

      final_wall_r_si = 1.0 / wall_construction_plus_ins.thermalConductance.to_f
      final_wall_r_ip = OpenStudio.convert(final_wall_r_si, 'm^2*K/W', 'ft^2*h*R/Btu').get.round(1)
      runner.registerInfo("For #{wall_construction.name}, add #{ins_layer_xps.name} to achieve a total assembly R-Value of #{final_wall_r_ip}, close to the target of #{target_r_val_ip.round(1)}.")
      runner.registerInfo("Created #{wall_construction_plus_ins.name}.")
    end

    # This measure is not applicable if no walls need or can have insulation applied
    if old_to_new_construction_map.empty?
      runner.registerAsNotApplicable('Not Applicable - none of the walls need or can have exterior insulation applied.')
      return true
    end

    # Find all exterior walls and replace their old constructions with the
    # cloned constructions that include the insulation layer.
    area_of_insulation_added_si = 0
    model.getSurfaces.each do |surface|
      next unless (surface.outsideBoundaryCondition == 'Outdoors') && (surface.surfaceType == 'Wall')
      next if surface.construction.empty?

      wall_construction = surface.construction.get
      wall_construction_plus_ins = old_to_new_construction_map[wall_construction]
      surface.setConstruction(wall_construction_plus_ins)
      area_of_insulation_added_si += surface.netArea
    end

    # This measure is not applicable if there are no exterior walls
    if area_of_insulation_added_si.zero?
      runner.registerAsNotApplicable('Not Applicable - Model does not have any exterior walls to add exterior insulation to.')
      return true
    end

    # Convert affected area to ft^2 for reporting
    area_of_insulation_added_ip = OpenStudio.convert(area_of_insulation_added_si, 'm^2', 'ft^2').get

    # Report the initial condition
    runner.registerInitialCondition("The building has #{area_of_insulation_added_ip.round} ft2 of exterior walls that need and can have exterior insulation applied.")

    # Report the final condition
    runner.registerFinalCondition("Insulation has been applied to #{area_of_insulation_added_ip.round} ft2 of exterior walls.")
    runner.registerValue('env_exterior_wall_insulation_area_ft2', area_of_insulation_added_ip.round, 'ft2')
    return true
  end
end

# register the measure to be used by the application
ExteriorWallInsulation.new.registerWithApplication
