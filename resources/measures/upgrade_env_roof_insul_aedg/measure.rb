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
class EnvRoofInsulAedg < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    return 'Roof Insulation AEDG'
  end

  # human readable description
  def description
    return 'Roof Insulation is defined as sky facing horizontal surfaces, or surfaces sloped within 60 degrees of sky facing horizontal'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'Determine the thickness of extruded polystyrene insulation required to meet the specified R-value, determined from the AEDG target assembly performance for each climate zone.  Find all the constructions used by roofs in the model, clone them, add a layer of insulation to the cloned constructions, and then assign the construction back to the roof.'
  end

  # define the arguments that the user will input for the model
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

    # set limit for minimum insulation in IP units -- this is used to limit input and for inferring insulation layer in construction
    min_exp_r_val_ip = 1.0

    # get climate zone to set target_r_val_ip
    climate_zone = OpenstudioStandards::Weather.model_get_climate_zone(model)

    # apply target R-value by climate zone
    if climate_zone.include?('ASHRAE 169-2013-1') || climate_zone.include?('CEC15')
      target_r_val_ip = 21
    elsif climate_zone.include?('ASHRAE 169-2013-2') || climate_zone.include?('ASHRAE 169-2013-3')
      target_r_val_ip = 26
    elsif climate_zone.include?('ASHRAE 169-2013-4') || climate_zone.include?('ASHRAE 169-2013-5') || climate_zone.include?('ASHRAE 169-2013-6') || climate_zone.include?('CEC16')
      target_r_val_ip = 33
    elsif climate_zone.include?('ASHRAE 169-2013-7') || climate_zone.include?('ASHRAE 169-2013-8')
      target_r_val_ip = 37
    else # all DEER climate zones except 15 and 16
      target_r_val_ip = 26
    end
    # Convert target_r_val_ip to si
    target_r_val_si = OpenStudio.convert(target_r_val_ip, 'ft^2*h*R/Btu', 'm^2*K/W').get

    runner.registerInfo("Target AEDG r-value for roof assemblies: #{target_r_val_ip}")

    # find existing roof assembly R-value
    # Find all roofs and get a list of their constructions
    roof_constructions = []
    model.getSurfaces.each do |surface|
      if surface.outsideBoundaryCondition == 'Outdoors' && surface.surfaceType == 'RoofCeiling' && surface.construction.is_initialized
        roof_constructions << surface.construction.get
      end
    end

    # create an array of roofs and find range of starting construction R-value (not just insulation layer)
    ext_surfs = []
    ext_surf_consts = []
    ext_surf_const_names = []
    roof_resist = []
    model.getSurfaces.each do |surface|
      next unless (surface.outsideBoundaryCondition == 'Outdoors') && (surface.surfaceType == 'RoofCeiling') # which are outdoor roofs

      ext_surfs << surface
      roof_const = surface.construction.get
      # only add construction if it hasn't been added yet
      ext_surf_consts << roof_const.to_Construction.get unless ext_surf_const_names.include?(roof_const.name.to_s)
      ext_surf_const_names << roof_const.name.to_s
      roof_resist << (1 / roof_const.thermalConductance.to_f)
    end

    # hashes to track constructions and materials made by the measure, to avoid duplicates
    consts_old_new = {}

    # used to get net area of new construction
    consts_new_old = {}
    matls_hash = {}

    # array and counter for new constructions that are made, used for reporting final condition
    final_consts = []

    # loop through all constructions and materials used on roofs, edit and clone
    ext_surf_consts.each do |ext_surf_const|
      matls_in_const = ext_surf_const.layers.map.with_index { |l, i| { 'name' => l.name.to_s, 'index' => i, 'nomass' => !l.to_MasslessOpaqueMaterial.empty?, 'r_val' => l.to_OpaqueMaterial.get.thermalResistance, 'matl' => l } }
      no_mass_matls = matls_in_const.select { |m| m['nomass'] == true }

      # measure will select the no-mass material with the highest R-value as the insulation layer -- if no no-mass materials are present, the measure will select the material with the highest R-value per inch
      if no_mass_matls.empty?
        r_val_per_thick_vals = matls_in_const.map { |m| m['r_val'] / m['mat'].thickness }
        max_matl_hash = matls_in_const.select { |m| m['index'] == r_val_per_thick_vals.index(r_val_per_thick_vals.max) }
        r_vals = matls_in_const.map { |m| m['r_val'] }
      else
        r_vals = no_mass_matls.map { |m| m['r_val'] }
        max_matl_hash = no_mass_matls.select { |m| m['r_val'] >= r_vals.max }
      end
      max_r_val_matl = max_matl_hash[0]['matl']
      max_r_val_matl_idx = max_matl_hash[0]['index']
      # check to make sure assumed insulation layer is between reasonable bounds
      if max_r_val_matl.to_OpaqueMaterial.get.thermalResistance <= OpenStudio.convert(min_exp_r_val_ip, 'ft^2*h*R/Btu', 'm^2*K/W').get
        runner.registerWarning("Construction '#{ext_surf_const.name}' does not appear to have an insulation layer and was not altered")
      elsif max_r_val_matl.to_OpaqueMaterial.get.thermalResistance >= target_r_val_si
        runner.registerInfo("The insulation layer of construction #{ext_surf_const.name} exceeds the requested R-value and was not altered")
      else

        # start new XPS material layer
        ins_layer_xps = OpenStudio::Model::StandardOpaqueMaterial.new(model)
        ins_layer_xps.setRoughness('MediumSmooth')
        ins_layer_xps.setConductivity(0.029)
        ins_layer_xps.setDensity(29.0)
        ins_layer_xps.setSpecificHeat(1210.0)
        ins_layer_xps.setSolarAbsorptance(0.7)
        ins_layer_xps.setVisibleAbsorptance(0.7)

        # need to calculate required insulation addition
        # clone the construction
        final_const = ext_surf_const.clone(model).to_Construction.get
        # get r-value
        final_const_r_si = 1 / final_const.thermalConductance.to_f
        final_const_r_ip = OpenStudio.convert(final_const_r_si, 'm^2*K/W', 'ft^2*h*R/Btu').get
        # determine required r-value of XPS insulation to bring roof up to target
        xps_target_r_val_si = target_r_val_si - final_const_r_si
        target_r_val_ip = OpenStudio.convert(target_r_val_si, 'm^2*K/W', 'ft^2*h*R/Btu').get
        xps_target_r_val_ip = OpenStudio.convert(xps_target_r_val_si, 'm^2*K/W', 'ft^2*h*R/Btu').get
        # Calculate the thickness required to meet the desired R-Value
        reqd_thickness_si = xps_target_r_val_si * ins_layer_xps.thermalConductivity
        reqd_thickness_ip = OpenStudio.convert(reqd_thickness_si, 'm', 'in').get
        # round to nearest half inch
        reqd_thickness_ip = (reqd_thickness_ip * 2).round / 2
        ins_layer_xps.setThickness(reqd_thickness_si)
        ins_layer_xps.thermalConductivity
        ins_layer_xps.setName("Expanded Polystyrene - Extruded - #{reqd_thickness_ip.round(1)} in.")
        runner.registerInfo("Construction #{ext_surf_const.name} starts with an R-value of #{final_const_r_ip.round(1)}. To achieve an R-Value of #{target_r_val_ip.round(1)}, this construction needs to add R-#{xps_target_r_val_ip.round(1)} of XPS insulation, which equates to #{reqd_thickness_ip} inches.")

        # insert new construction
        final_const.insertLayer(1, ins_layer_xps)
        final_const.setName("#{ext_surf_const.name} with Added Roof Insul")
        final_consts << final_const

        # push to hashes
        consts_old_new[ext_surf_const.name.to_s] = final_const
        # push the object to hash key v. name
        consts_new_old[final_const] = ext_surf_const

        # find already cloned insulation material and link to construction
        found_matl = false
        matls_hash.each do |orig, new|
          if max_r_val_matl.name.to_s == orig
            new_matl = new
            matls_hash[max_r_val_matl.name.to_s] = new_matl
            final_const.eraseLayer(max_r_val_matl_idx)
            final_const.insertLayer(max_r_val_matl_idx, new_matl)
            found_matl = true
          end
        end
      end
    end

    # register as not applicable if
    if final_consts.empty?
      runner.registerAsNotApplicable('No applicable roofs were found.')
      return true
    end

    # loop through construction sets used in the model
    default_const_sets = model.getDefaultConstructionSets
    default_const_sets.each do |default_const_set|
      if default_const_set.directUseCount > 0
        default_surf_const_set = default_const_set.defaultExteriorSurfaceConstructions
        if !default_surf_const_set.empty?
          start_const = default_surf_const_set.get.roofCeilingConstruction

          # creating new default construction set
          new_default_const_set = default_const_set.clone(model)
          new_default_const_set = new_default_const_set.to_DefaultConstructionSet.get
          new_default_const_set.setName("#{default_const_set.name} Added Roof Insul")

          # create new surface set and link to construction set
          new_default_surf_const_set = default_surf_const_set.get.clone(model)
          new_default_surf_const_set = new_default_surf_const_set.to_DefaultSurfaceConstructions.get
          new_default_surf_const_set.setName("#{default_surf_const_set.get.name} Added Roof Insul")
          new_default_const_set.setDefaultExteriorSurfaceConstructions(new_default_surf_const_set)

          # use the hash to find the proper construction and link to the new default surface construction set
          target_const = new_default_surf_const_set.roofCeilingConstruction
          if !target_const.empty?
            target_const = target_const.get.name.to_s
            found_const_flag = false
            consts_old_new.each do |orig, new|
              if target_const == orig
                final_const = new
                new_default_surf_const_set.setRoofCeilingConstruction(final_const)
                found_const_flag = true
              end
            end
            # this should never happen but is just an extra test in case something goes wrong with the measure code
            runner.registerWarning("Measure couldn't find the roof construction named '#{target_const}' assigned to any exterior surfaces") if found_const_flag == false
          end

          # swap all uses of the old construction set for the new
          const_set_srcs = default_const_set.sources
          const_set_srcs.each do |const_set_src|
            bldg_src = const_set_src.to_Building

            # if statement for each type of object that can use a DefaultConstructionSet
            if !bldg_src.empty?
              bldg_src = bldg_src.get
              bldg_src.setDefaultConstructionSet(new_default_const_set)
            end
            bldg_story_src = const_set_src.to_BuildingStory
            if !bldg_story_src.empty?
              bldg_story_src = bldg_story_src.get
              bldg_story_src.setDefaultConstructionSet(new_default_const_set)
            end
            space_type_src = const_set_src.to_SpaceType
            if !bldg_story_src.empty?
              bldg_story_src = bldg_story_src.get
              bldg_story_src.setDefaultConstructionSet(new_default_const_set)
            end
            space_src = const_set_src.to_Space
            if !space_src.empty?
              space_src = space_src.get
              space_src.setDefaultConstructionSet(new_default_const_set)
            end
          end
        end
      end
    end

    # link cloned and edited constructions for surfaces with hard assigned constructions
    ext_surfs.each do |ext_surf|
      if !ext_surf.isConstructionDefaulted && !ext_surf.construction.empty?
        # use the hash to find the proper construction and link to surface
        target_const = ext_surf.construction
        if !target_const.empty?
          target_const = target_const.get.name.to_s
          consts_old_new.each do |orig, new|
            if target_const == orig
              final_const = new
              ext_surf.setConstruction(final_const)
            end
          end
        end
      end
    end

    # nothing will be done if there are no exterior surfaces
    if ext_surfs.empty?
      runner.registerAsNotApplicable('The building has no roofs.')
      return true
    end

    # report strings for initial condition
    init_str = []
    ext_surf_consts.uniq.each do |ext_surf_const|
      # unit conversion of roof insulation from SI units (m2-K/W) to IP units (ft2-h-R/Btu)
      init_r_val_ip = OpenStudio.convert(1 / ext_surf_const.thermalConductance.to_f, 'm^2*K/W', 'ft^2*h*R/Btu').get
      init_str << "#{ext_surf_const.name} (R-#{format '%.1f', init_r_val_ip})"
    end

    # report strings for final condition, not all roof constructions, but only new ones made -- if roof didn't have insulation and was not altered we don't want to show it
    final_str = []
    area_changed_si = 0
    final_consts.uniq.each do |final_const|
      # unit conversion of roof insulation from SI units (M^2*K/W) to IP units (ft^2*h*R/Btu)
      final_r_val_ip = OpenStudio.convert(1.0 / final_const.thermalConductance.to_f, 'm^2*K/W', 'ft^2*h*R/Btu').get
      final_str << "#{final_const.name} (R-#{format '%.1f', final_r_val_ip})"
      area_changed_si += final_const.getNetArea
    end

    # add not applicable test if there were roof constructions but non of them were altered (already enough insulation or doesn't look like insulated roof)
    if area_changed_si == 0
      runner.registerAsNotApplicable('No roofs were altered')
      return true
    else
      # IP construction area for reporting
      area_changed_ip = OpenStudio.convert(area_changed_si, 'm^2', 'ft^2').get
    end

    # Report the initial condition
    runner.registerInitialCondition("The building had #{init_str.size} roof constructions: #{init_str.sort.join(', ')}")

    # Report the final condition
    runner.registerFinalCondition("The insulation for roofs was set to R-#{target_r_val_ip.round(1)} -- this was applied to #{area_changed_ip.round(2)} ft2 across #{final_str.size} roof constructions: #{final_str.sort.join(', ')}")
    runner.registerValue('env_roof_insul_roof_area_ft2', area_changed_ip.round(2), 'ft2')
    return true
  end
end

# register the measure to be used by the application
EnvRoofInsulAedg.new.registerWithApplication
