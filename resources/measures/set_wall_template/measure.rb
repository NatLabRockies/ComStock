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

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

# start the measure
class SetWallTemplate < OpenStudio::Measure::ModelMeasure
  require 'comstock-typical'

  # human readable name
  def name
    return 'Set Wall Template'
  end

  # human readable description
  def description
    return 'Change the wall components to make their properties match the selected template.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'Change the wall components to make their properties match the selected template using the OpenStudio Standards methods.  Will replace the existing properties where present.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # Templates
    templates = [
      'DEER Pre-1975',
      'DEER 1985',
      'DEER 1996',
      'DEER 2003',
      'DEER 2007',
      'DEER 2011',
      'DEER 2014',
      'DEER 2015',
      'DEER 2017',
      'ComStock DEER Pre-1975',
      'ComStock DEER 1985',
      'ComStock DEER 1996',
      'ComStock DEER 2003',
      'ComStock DEER 2007',
      'ComStock DEER 2011',
      'ComStock DEER 2014',
      'ComStock DEER 2015',
      'ComStock DEER 2017',
      'ComStock DEER 2020',
      'DOE Ref Pre-1980',
      'DOE Ref 1980-2004',
      '90.1-2004',
      '90.1-2007',
      '90.1-2010',
      '90.1-2013',
      '90.1-2016',
      '90.1-2019',
      'ComStock DOE Ref Pre-1980',
      'ComStock DOE Ref 1980-2004',
      'ComStock 90.1-2004',
      'ComStock 90.1-2007',
      'ComStock 90.1-2010',
      'ComStock 90.1-2013',
      'ComStock 90.1-2016',
      'ComStock 90.1-2019'
    ]

    # Climate Zones
    climate_zones = [
      'ASHRAE 169-2013-1A',
      'ASHRAE 169-2013-1B',
      'ASHRAE 169-2013-2A',
      'ASHRAE 169-2013-2B',
      'ASHRAE 169-2013-3A',
      'ASHRAE 169-2013-3B',
      'ASHRAE 169-2013-3C',
      'ASHRAE 169-2013-4A',
      'ASHRAE 169-2013-4B',
      'ASHRAE 169-2013-4C',
      'ASHRAE 169-2013-5A',
      'ASHRAE 169-2013-5B',
      'ASHRAE 169-2013-5C',
      'ASHRAE 169-2013-6A',
      'ASHRAE 169-2013-6B',
      'ASHRAE 169-2013-7A',
      'ASHRAE 169-2013-8A',
      'CEC T24-CEC1',
      'CEC T24-CEC2',
      'CEC T24-CEC3',
      'CEC T24-CEC4',
      'CEC T24-CEC5',
      'CEC T24-CEC6',
      'CEC T24-CEC7',
      'CEC T24-CEC8',
      'CEC T24-CEC9',
      'CEC T24-CEC10',
      'CEC T24-CEC11',
      'CEC T24-CEC12',
      'CEC T24-CEC13',
      'CEC T24-CEC14',
      'CEC T24-CEC15',
      'CEC T24-CEC16'
    ]

    # Make an argument for the as-built template
    template_chs = OpenStudio::StringVector.new
    templates.each do |template|
      template_chs << template
    end
    as_constructed_template = OpenStudio::Measure::OSArgument.makeChoiceArgument('as_constructed_template', template_chs, true)
    as_constructed_template.setDisplayName('As Constructed Template')
    as_constructed_template.setDescription('Template that represents the year the building was first constructed.')
    as_constructed_template.setDefaultValue('ComStock DOE Ref 1980-2004')
    args << as_constructed_template

    # Make an argument for the template
    template = OpenStudio::Measure::OSArgument.makeChoiceArgument('template', template_chs, true)
    template.setDisplayName('Template')
    as_constructed_template.setDescription('Template to apply.')
    template.setDefaultValue('ComStock DOE Ref 1980-2004')
    args << template

    # Make an argument for the climate zone
    climate_zone_chs = OpenStudio::StringVector.new
    climate_zones.each do |climate_zone|
      climate_zone_chs << climate_zone
    end
    climate_zone = OpenStudio::Measure::OSArgument.makeChoiceArgument('climate_zone', climate_zone_chs, true)
    climate_zone.setDisplayName('Climate Zone')
    climate_zone.setDefaultValue('ASHRAE 169-2013-2B')
    args << climate_zone

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # Assign the user inputs to variables that can be accessed across the measure
    as_constructed_template = runner.getStringArgumentValue('as_constructed_template', user_arguments)
    template = runner.getStringArgumentValue('template', user_arguments)
    climate_zone = runner.getStringArgumentValue('climate_zone', user_arguments)

    # set additional properties for building
    props = model.getBuilding.additionalProperties
    props.setFeature('wall_as_constructed_template', as_constructed_template.to_s)
    props.setFeature('wall_template', template.to_s)

    # Not applicable if the selected template matches the as-constructed template
    if template == as_constructed_template
      runner.registerAsNotApplicable("The building walls are already at the #{template} level, no changes will be made.")
      return true
    end

    # Make a standard
    reset_log
    standard = Standard.build(template.to_s)

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
    new_construction = standard.model_find_and_add_construction(model,
                                                                climate_zone_set,
                                                                'ExteriorWall',
                                                                old_wall_construction_type,
                                                                occ_type)
    ext_surf_consts.setWallConstruction(new_construction)

    log_messages_to_runner(runner, debug = false)
    reset_log

    return true
  end
end

# register the measure to be used by the application
SetWallTemplate.new.registerWithApplication
