# ComStock™, Copyright (c) 2023 Alliance for Sustainable Energy, LLC. All rights reserved.
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

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

require 'comstock-typical'

# start the measure
class SetEnvelopeToCurrentCode < OpenStudio::Measure::ModelMeasure

  # human readable name
  def name
    return 'Set Envelope to Current Code'
  end

  # human readable description
  def description
    return 'This measure updates the wall, roof, and windows to the corresponding ASHRAE 90.1 code in force by state.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'This measure updates the wall, roof, and windows to the corresponding ASHRAE 90.1 code in force by state. For walls and roof, the insulation R-value is reset to match the required R-value of the corresponding ASHARE 90.1 code in force in the state. For windows, the required U-value and SHGC are mapped to the closest window construction that meets code for the ASHRAE 90.1 code in force in the state.'
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

    # Get additional properties of the model. Used to look up state, climate zone, existing wall template, existing roof template, existing window construction. 
    addtl_props = model.getBuilding.additionalProperties

    # Get state and then lookup current_code_in_force using resource file
    current_code_in_force_by_state_lookup = File.join(File.dirname(__FILE__), 'resources', 'current_code_in_force_by_state_lookup.csv')
    current_code_in_force = ''

    if addtl_props.getFeatureAsString('state_name').is_initialized
      state_name = addtl_props.getFeatureAsString('state_name').get
      runner.registerInfo("State is: #{state_name}.")
      # Do lookup using state name
      CSV.foreach(current_code_in_force_by_state_lookup, headers: true) do |row|
        if row['state_name'] == state_name
          current_code_in_force = row['current_code_in_force']
          break
        end
      end

      if current_code_in_force
        runner.registerInfo("Current code in force for #{state_name} is: #{current_code_in_force}.")
      else
        runner.registerError("Current code in force not found for #{state_name}, cannot apply measure.")        
      end
    else
      runner.registerError("State not found, cannot lookup current code in force.")
      return false
    end

    # Make a standard that matches the current code in force
    standard = Standard.build("#{current_code_in_force}")

    # Check that a default construction set is defined
    bldg_def_const_set = model.getBuilding.defaultConstructionSet
    unless bldg_def_const_set.is_initialized
      runner.registerError('Model does not have a default construction set.')
      return false
    end
    bldg_def_const_set = bldg_def_const_set.get

    # Check that a default exterior construction set is defined
    ext_surf_consts = bldg_def_const_set.defaultExteriorSurfaceConstructions
    unless ext_surf_consts.is_initialized
      runner.registerError("Default construction set '#{bldg_def_const_set.name}' has no default exterior surface constructions.")
      return false
    end
    ext_surf_consts = ext_surf_consts.get

    # Create ranking of code templates so we can evaluate whether the existing template is better than the current code in force
    # Including DEER and 90.1 in the same list because a single model will never have a mix of CA and non-CA templates
    template_ranking = {
      'ComStock DEER Pre-1975' => 0,
      'ComStock DEER 1985' => 1,
      'ComStock DEER 1996' => 2,
      'ComStock DEER 2003' => 3,
      'ComStock DEER 2007' => 4,
      'ComStock DEER 2011' => 5,
      'ComStock DEER 2014' => 6,
      'ComStock DEER 2015' => 7,
      'ComStock DEER 2017' => 8,
      'ComStock DEER 2020' => 9,
      'ComStock DOE Ref Pre-1980' => 10,
      'ComStock DOE Ref 1980-2004' => 11,
      'ComStock 90.1-2004' => 12,
      'ComStock 90.1-2007' => 13,
      'ComStock 90.1-2010' => 14,
      'ComStock 90.1-2013' => 15,
      'ComStock 90.1-2016' => 16,
      'ComStock 90.1-2019' => 17
    }

    current_code_in_force_ranking = template_ranking[current_code_in_force]

    # Get climate zone
    if addtl_props.getFeatureAsString('climate_zone').is_initialized
      climate_zone = addtl_props.getFeatureAsString('climate_zone').get
      if climate_zone.include?('CEC')
        climate_zone = "CEC T24-#{climate_zone}"
      elsif climate_zone.include?('7') || climate_zone.include?('8')
        climate_zone = "ASHRAE 169-2013-#{climate_zone}A"
      else
        climate_zone = "ASHRAE 169-2013-#{climate_zone}"
      end
      puts "Climate zone is: #{climate_zone}."
    else
      runner.registerError("Climate zone not found. Cannot lookup window construction.")
    end

    ## WALLS ##
    # Look up existing wall template of model in additional properties
    if addtl_props.getFeatureAsString('energy_code_followed_during_last_walls_replacement').is_initialized
      existing_walls_template = addtl_props.getFeatureAsString('energy_code_followed_during_last_walls_replacement').get
      puts "Existing walls template is: #{existing_walls_template}."
      existing_walls_ranking = template_ranking[existing_walls_template]
    else
      puts "Existing walls template not found."
      # Assume worst wall insulation ranking and wall insulation will be upgraded. 
      existing_walls_ranking = 0
    end

    # Check if existing wall template is worse than current code in force. If so, then proceed with wall insulation upgrade. Otherwise, wall insulation will not be upgraded. 
    if existing_walls_ranking >= current_code_in_force_ranking
      runner.registerInfo('Existing wall insulation is already equivalent or better than the current code in force. Wall insulation will not be upgraded.')
    else 
      # Check that a default exterior wall is defined
      unless ext_surf_consts.wallConstruction.is_initialized
        runner.registerError("Default surface construction set #{ext_surf_consts.name} has no default exterior wall construction.")
        return false
      end
      old_construction = ext_surf_consts.wallConstruction.get
      standards_info = old_construction.standardsInformation

      # Get the old wall construction type
      if standards_info.standardsConstructionType.empty?
        old_wall_construction_type = 'Not defined'
      else
        old_wall_construction_type = standards_info.standardsConstructionType.get
      end

      # Get the building occupancy type
      if model.getBuilding.standardsBuildingType.is_initialized
        model_building_type = model.getBuilding.standardsBuildingType.get
      else
        model_building_type = ''
      end
      if ['SmallHotel', 'LargeHotel', 'MidriseApartment', 'HighriseApartment'].include?(model_building_type)
        occ_type = 'Residential'
      else
        occ_type = 'Nonresidential'
      end

      climate_zone_set = standard.model_find_climate_zone_set(model, climate_zone)

      new_wall_construction = standard.model_find_and_add_construction(model,
                                                                  climate_zone_set,
                                                                  'ExteriorWall',
                                                                  old_wall_construction_type,
                                                                  occ_type)
      #apply new construction to exterior wall surfaces
      model.getSurfaces.each do |surface|
        next unless surface.outsideBoundaryCondition == 'Outdoors' && surface.surfaceType == 'Wall'
        surface.setConstruction(new_wall_construction)
      end                                                            

      runner.registerInfo("Successfully applied wall construction #{new_wall_construction.name} to the model.")
    end

    ## ROOF ##
    # Look up existing roof template of model in additional properties
    if addtl_props.getFeatureAsString('energy_code_followed_during_last_roof_replacement').is_initialized
      existing_roof_template = addtl_props.getFeatureAsString('energy_code_followed_during_last_roof_replacement').get
      puts "Existing roof template is: #{existing_roof_template}."
      existing_roof_ranking = template_ranking[existing_roof_template]
    else
      puts "Existing roof template not found."
      # Assume worst roof insulation ranking and roof insulation will be upgraded. 
      existing_roof_ranking = 0
    end

    # Check if existing wall template is worse than current code in force. If so, then proceed with wall insulation upgrade. Otherwise, wall insulation will not be upgraded. 
    if existing_roof_ranking >= current_code_in_force_ranking
      runner.registerInfo('Existing roof insulation is already equivalent or better than the current code in force. Roof will not be replaced.')
    else
      # Check that a default exterior roof is defined
      unless ext_surf_consts.roofCeilingConstruction.is_initialized
        runner.registerError("Default surface construction set #{ext_surf_consts.name} has no default exterior roof construction.")
        return false
      end
      old_construction = ext_surf_consts.roofCeilingConstruction.get
      standards_info = old_construction.standardsInformation

      # Get the old roof construction type
      if standards_info.standardsConstructionType.empty?
        old_roof_construction_type = 'Not defined'
      else
        old_roof_construction_type = standards_info.standardsConstructionType.get
      end

      # Get the building occupancy type
      if model.getBuilding.standardsBuildingType.is_initialized
        model_building_type = model.getBuilding.standardsBuildingType.get
      else
        model_building_type = ''
      end
      if ['SmallHotel', 'LargeHotel', 'MidriseApartment', 'HighriseApartment'].include?(model_building_type)
        occ_type = 'Residential'
      else
        occ_type = 'Nonresidential'
      end
      climate_zone_set = standard.model_find_climate_zone_set(model, climate_zone)
      new_roof_construction = standard.model_find_and_add_construction(model,
                                                                  climate_zone_set,
                                                                  'ExteriorRoof',
                                                                  old_roof_construction_type,
                                                                  occ_type)
      #apply new construction to exterior roof surfaces
      model.getSurfaces.each do |surface|
        next unless surface.outsideBoundaryCondition == 'Outdoors' && surface.surfaceType == 'RoofCeiling'
        surface.setConstruction(new_roof_construction)
      end                                                              

      runner.registerInfo("Successfully applied roof construction #{new_roof_construction.name} to the model.")
    end

    ## WINDOWS ##
    # Create ranking of window construction (worst to best U-val) so we can evaluate whether the existing window is better than the current code in force
    # Some constructions have the same or nearly the same U-value so they are ranked the same. 
    # This avoids a scenario where you are replacing a window with U-value 0.559 with U-value 0.557, which is not realistic.
    window_ranking = {
      'Single - No LowE - Clear - Aluminum' => 0,
      'Single - No LowE - Clear - Wood' => 0,
      'Single - No LowE - Tinted/Reflective - Aluminum' => 1,
      'Single - No LowE - Tinted/Reflective - Wood' => 1,
      'Double - No LowE - Clear - Aluminum' => 2,
      'Double - No LowE - Tinted/Reflective - Aluminum' => 2,
      'Double - LowE - Clear - Aluminum' => 3,
      'Double - LowE - Tinted/Reflective - Aluminum' => 3,
      'Double - LowE - Clear - Thermally Broken Aluminum' => 4,
      'Double - LowE - Tinted/Reflective - Thermally Broken Aluminum' => 4,
      'Triple - LowE - Clear - Thermally Broken Aluminum' => 5,
      'Triple - LowE - Tinted/Reflective - Thermally Broken Aluminum' => 5
    }

    # Look up existing window construction in additional properties
    if addtl_props.getFeatureAsString('baseline_window_type').is_initialized
      existing_window_construction = addtl_props.getFeatureAsString('baseline_window_type').get
      puts "Existing window construction is: #{existing_window_construction}."
      existing_window_ranking = window_ranking[existing_window_construction]
    else
      puts "Existing window construction not found."
      # Assume worst window ranking and windows will be replaced. 
      existing_window_ranking = 0
    end

    # Get state and then lookup window construction that corresponds to climate zone and current_code_in_force using resource file
    window_construction_lookup = File.join(File.dirname(__FILE__), 'resources', 'window_construction_lookup.csv')
    current_code_window = ''
    u_val_ip = ''
    shgc = ''
    vlt = ''

    # Do lookup using climate zone and current code
    CSV.foreach(window_construction_lookup, headers: true) do |row|
      if row['climate_zone'] == climate_zone && row['current_code_in_force'] == current_code_in_force
        current_code_window = row['current_code_window']
        u_val_ip = row['u_val'].to_f
        shgc = row['shgc'].to_f
        vlt = row['vlt'].to_f
        break
      end
    end

    # convert u-value to SI units
    u_val_si = OpenStudio.convert(u_val_ip, 'Btu/ft^2*h*R', 'W/m^2*K').get

    current_code_window_ranking = window_ranking[current_code_window]

    if existing_window_ranking >= current_code_window_ranking
      runner.registerInfo('Existing window construction is already equivalent or better than the window construction associated with the current code in force. Windows will not be replaced.')
    else
      # get all fenestration surfaces
      sub_surfaces = []
      constructions = []

      model.getSubSurfaces.each do |sub_surface|
        next unless sub_surface.subSurfaceType.include?('Window')

        sub_surfaces << sub_surface
        constructions << sub_surface.construction.get
      end
      # make new simple glazing with new properties
      code_simple_glazing = OpenStudio::Model::SimpleGlazing.new(model)
      code_simple_glazing.setName("Simple Glazing #{current_code_window}")

      # set and register final condition
      code_simple_glazing.setUFactor(u_val_si)
      code_simple_glazing.setSolarHeatGainCoefficient(shgc)
      code_simple_glazing.setVisibleTransmittance(vlt)

      # create new construction with this new simple glazing layer
      new_construction = OpenStudio::Model::Construction.new(model)
      new_construction.setName("Code Compliant Window U-#{u_val_ip.round(2)} SHGC #{shgc.round(2)}")
      new_construction.insertLayer(0, code_simple_glazing)

      # register new window name condition
      runner.registerInfo("New code-compliant window #{code_simple_glazing.name.get} has #{u_val_si.round(2)} W/m2-K U-value , #{shgc.round(2)} SHGC, and #{vlt.round(2)} VLT.")

      # define total area changed
      area_changed_m2 = 0.0
      # loop over constructions and simple glazings
      constructions = model.getConstructions
      constructions.each do |construction|
        # loop over fenestration surfaces and add new construction
        sub_surfaces.each do |sub_surface|
          # assign new construction to fenestration surfaces and add total area changed if construction names match
          next unless sub_surface.construction.get.to_Construction.get.layers[0].name.get == construction.to_Construction.get.layers[0].name.get

          sub_surface.setConstruction(new_construction)
          area_changed_m2 += sub_surface.grossArea
        end
      end
      area_changed_ft2 = OpenStudio.convert(area_changed_m2, 'm^2', 'ft^2').get
      runner.registerInfo("Replaced #{area_changed_ft2} sqft of windows to window construction compliant with current code in force.")
    end

    # report final condition of model
    runner.registerFinalCondition("Upgraded model to follow the current wall, roof, and window code in the state.")

    return true
  end
end

# register the measure to be used by the application
SetEnvelopeToCurrentCode.new.registerWithApplication
