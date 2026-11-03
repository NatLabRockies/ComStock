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
class EnvNewAedgWindows < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    return 'env_new_aedg_windows'
  end

  # human readable description
  def description
    return 'Adds new window with properites (SHGC, U-value, and VLT) aligning with AEDG guidlines, varying by climate zone. Does not impact triple pan windows as their performance is already high.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'Adds new window with properites (SHGC, U-value, and VLT) aligning with AEDG guidlines, varying by climate zone. Does not impact triple pan windows as their performance is already high.'
  end

  # define the arguments that the user will input
  def arguments(model)
    # make an argument vector
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

    # create new construction hash
    # key = old const, value = new const
    new_construction_hash = {}

    # Find all exterior windows and get a list of their constructions
    constructions = []
    model.getSubSurfaces.each do |sub_surface|
      next unless (sub_surface.outsideBoundaryCondition == 'Outdoors') && sub_surface.subSurfaceType.include?('Window')
      next if sub_surface.construction.empty?

      constructions << sub_surface.construction.get
    end

    # check to make sure building has fenestration surfaces
    if constructions.empty?
      runner.registerAsNotApplicable('The building has no exterior windows.')
      return true
    end

    # build standard to use OS standards methods
    template = 'ComStock 90.1-2013'
    std = Standard.build(template)
    # get climate zone value
    climate_zone = OpenstudioStandards::Weather.model_get_climate_zone(model)
    runner.registerInfo("climate zone = #{climate_zone}")

    # For each window construction, make a clone
    # and add the secondary window by modifying the existing window properties.
    constructions.uniq.each do |construction|
      construction = construction.to_Construction
      if construction.empty?
        runner.registerInfo("Window construction #{construction.name} is not a layered construction, cannot modify.")
        next
      end
      construction = construction.get

      # Get the first glazing layer
      glazing_layer = construction.layers[0]

      # Check that this construction uses a SimpleGlazing material
      if glazing_layer.to_SimpleGlazing.empty?
        runner.registerInfo("Cannot modify #{construction}, it does not use the SimpleGlazing window modeling approach.")
        next
      end
      simple_glazing = glazing_layer.to_SimpleGlazing.get

      puts "Original Glazing: #{simple_glazing}"

      # Determine the appropriate changes to reflect the application of
      # a secondary window based on the existing window type.
      u_val_target = 0.0
      shgc_target = 0.0
      vlt_target = 0.0
      # assign variables for each climate zone
      # skip triple pane windows
      if simple_glazing.name.get.include?('Triple')
        runner.registerInfo("Simple glazing named #{simple_glazing.name} is not recognized, windows will not be modified.")
        next
      end
      # ASHRAE climate zones
      if climate_zone.include?('ASHRAE 169-2013-0')
        u_val_target = 2.73
        shgc_target = 0.21
        vlt_target = 0.23
      elsif climate_zone.include?('ASHRAE 169-2013-1')
        u_val_target = 2.73
        shgc_target = 0.22
        vlt_target = 0.24
      elsif climate_zone.include?('ASHRAE 169-2013-2') || climate_zone.include?('CEC15')
        u_val_target = 2.44
        shgc_target = 0.24
        vlt_target = 0.26
      elsif climate_zone.include?('ASHRAE 169-2013-3') || climate_zone.include?('CEC2') || climate_zone.include?('CEC3') || climate_zone.include?('CEC4') || climate_zone.include?('CEC5') || climate_zone.include?('CEC6') || climate_zone.include?('CEC7') || climate_zone.include?('CEC8') || climate_zone.include?('CEC9') || climate_zone.include?('EC10') || climate_zone.include?('CEC11') || climate_zone.include?('CEC12') || climate_zone.include?('CEC13') || climate_zone.include?('CEC14')
        u_val_target = 2.27
        shgc_target = 0.24
        vlt_target = 0.26
      elsif climate_zone.include?('ASHRAE 169-2013-4') || climate_zone.include?('CEC1')
        u_val_target = 1.93
        shgc_target = 0.34
        vlt_target = 0.37
      elsif climate_zone.include?('ASHRAE 169-2013-5') || climate_zone.include?('CEC16')
        u_val_target = 1.93
        shgc_target = 0.36
        vlt_target = 0.40
      elsif climate_zone.include?('ASHRAE 169-2013-6')
        u_val_target = 1.82
        shgc_target = 0.36
        vlt_target = 0.40
      elsif climate_zone.include?('ASHRAE 169-2013-7')
        u_val_target = 1.59
        shgc_target = 0.38
        vlt_target = 0.42
      elsif climate_zone.include?('ASHRAE 169-2013-8')
        u_val_target = 1.42
        shgc_target = 0.38
        vlt_target = 0.42
      else
        runner.registerError("Climate zone #{climate_zone} not currently supported by measure.")
        return false
      end

      # get old values
      old_simple_glazing_u = simple_glazing.uFactor
      old_simple_glazing_shgc = simple_glazing.solarHeatGainCoefficient
      if simple_glazing.visibleTransmittance.is_initialized
        old_simple_glazing_vlt = simple_glazing.visibleTransmittance.get
      else
        old_simple_glazing_vlt = old_simple_glazing_shgc # if vlt is blank, E+ uses shgc
      end

      # register initial condition
      runner.registerInfo("Existing window #{simple_glazing.name.get} has U-#{old_simple_glazing_u.round(2)} W/m2-K, #{old_simple_glazing_shgc} SHGC, and #{old_simple_glazing_vlt} VLT.")

      # calculate new values
      new_simple_glazing_u = u_val_target
      new_simple_glazing_shgc = shgc_target
      new_simple_glazing_vlt = vlt_target

      # check to make sure the new properties are better than the old before replacing
      if old_simple_glazing_u <= new_simple_glazing_u
        runner.registerWarning('Old simple glazing U-value is less than the proposed new simple glazing U-value. Consider revising measure arguments.')
      end

      # make new simple glazing with SHGC and VLT reductions
      new_simple_glazing = OpenStudio::Model::SimpleGlazing.new(model)
      new_simple_glazing.setName("#{climate_zone} AEDG Window")

      # set glazing properties
      new_simple_glazing.setVisibleTransmittance(new_simple_glazing_vlt)
      new_simple_glazing.setSolarHeatGainCoefficient(new_simple_glazing_shgc)
      new_simple_glazing.setUFactor(new_simple_glazing_u)

      # Get the values to use, ensuring that messages reflect applied values
      new_simple_glazing_u = new_simple_glazing.uFactor
      new_simple_glazing_shgc = new_simple_glazing.solarHeatGainCoefficient
      new_simple_glazing_vlt = new_simple_glazing.visibleTransmittance.get
      runner.registerInfo("New window #{new_simple_glazing.name.get} has U-#{new_simple_glazing_u.round(2)} W/m2-K, #{new_simple_glazing_shgc.round(2)} SHGC, and #{new_simple_glazing_vlt.round(2)} VLT.")

      # create new construction with this new simple glazing layer
      new_construction = OpenStudio::Model::Construction.new(model)
      new_construction.setName("#{climate_zone} AEDG Window Construction")
      new_construction.insertLayer(0, new_simple_glazing)

      # update hash
      new_construction_hash[construction] = new_construction
    end

    # Find all exterior windows and replace their old constructions with the
    # cloned constructions that include the secondary window insert.
    area_changed_m2 = 0.0
    model.getSubSurfaces.each do |sub_surface|
      next unless (sub_surface.outsideBoundaryCondition == 'Outdoors') && sub_surface.subSurfaceType.include?('Window')
      next if sub_surface.construction.empty?

      construction = sub_surface.construction.get
      # Skip sub-surfaces with no new construction prescribed
      next if new_construction_hash[construction].nil?

      sub_surface.setConstruction(new_construction_hash[construction])
      area_changed_m2 += sub_surface.grossArea
    end
    area_changed_ft2 = OpenStudio.convert(area_changed_m2, 'm^2', 'ft^2').get

    # Not applicable if no windows were affected
    if area_changed_ft2.zero?
      runner.registerAsNotApplicable('Not applicable, none of the window constructions could be modified to reflect secondary windows.')
      return true
    end

    # TODO: create area-weighted property change stats to use in this
    # applies when a building has more than one window construction.
    # runner.registerFinalCondition("Added secondary windows to #{area_changed_ft2.round(2)} ft2 of window that reduced U-value (W/m2-K) by #{u_val_reduct.round(2)*100}% , SHGC by #{shgc_reduct.round(2)*100}%, and VLT by #{vlt_reduct.round(2)*100}%.")
    runner.registerFinalCondition("Added secondary windows to #{area_changed_ft2.round(2)} ft2 of windows.")
    runner.registerValue('env_secondary_window_fen_area_ft2', area_changed_ft2.round(2), 'ft2')
    return true
  end
end

# register the measure to be used by the application
EnvNewAedgWindows.new.registerWithApplication
