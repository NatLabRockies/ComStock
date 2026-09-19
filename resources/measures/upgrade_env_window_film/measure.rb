# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2022, Alliance for Sustainable Energy, LLC.
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

# Measure distributed under NREL Copyright terms, see LICENSE.md file.

# dependencies
require 'comstock-typical'

# start the measure
class EnvWindowFilm < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # measure name should be the title case of the class name.
    return 'env_window_film'
  end

  # human readable description
  def description
    return 'Adds window film to ComStock\'s existing baseline windows. Applicability is coded inside of the measure for selecting appropriate windows for an window film upgrade.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'First gets all building detailed fenestration surfaces. Loops over all detailed fenestration surfaces and checks to see if the surface type is a window. If the surface type is a window then it gets the corresponding construction objects. A hard-coded map is used to update the window performances (U-factor, SHGC, VLT) in relevant construction objects by leveraging ComStock\'s glazing system name and climate zone number as keys.'
  end

  # define the arguments that the user will input
  def arguments(model)
    # make an argument vector
    args = OpenStudio::Measure::OSArgumentVector.new

    filmtypes = [
      "no film",
      "int. film / min. SHGC / min. VLT",
      "int. film / min. SHGC / min. U-factor / min. VLT",
      "ext. film / min. SHGC / min. VLT"
    ]

    ################################################################################
    # alternative for using input arguments
    #-------------------------------------------------------------------------------
    # filmtype_singlepane_cz1 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_singlepane_cz1', filmtypes, true)
    # filmtype_singlepane_cz1.setDisplayName('Select film type for single pane window on climate zone 1')
    # filmtype_singlepane_cz1.setDefaultValue('int. film / min. SHGC / min. U-factor / min. VLT')
    # args << filmtype_singlepane_cz1

    # filmtype_singlepane_cz2 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_singlepane_cz2', filmtypes, true)
    # filmtype_singlepane_cz2.setDisplayName('Select film type for single pane window on climate zone 2')
    # filmtype_singlepane_cz2.setDefaultValue('int. film / min. SHGC / min. U-factor / min. VLT')
    # args << filmtype_singlepane_cz2

    # filmtype_singlepane_cz3 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_singlepane_cz3', filmtypes, true)
    # filmtype_singlepane_cz3.setDisplayName('Select film type for single pane window on climate zone 3')
    # filmtype_singlepane_cz3.setDefaultValue('int. film / min. SHGC / min. U-factor / min. VLT')
    # args << filmtype_singlepane_cz3

    # filmtype_singlepane_cz4 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_singlepane_cz4', filmtypes, true)
    # filmtype_singlepane_cz4.setDisplayName('Select film type for single pane window on climate zone 4')
    # filmtype_singlepane_cz4.setDefaultValue('int. film / min. SHGC / min. U-factor / min. VLT')
    # args << filmtype_singlepane_cz4

    # filmtype_singlepane_cz5 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_singlepane_cz5', filmtypes, true)
    # filmtype_singlepane_cz5.setDisplayName('Select film type for single pane window on climate zone 5')
    # filmtype_singlepane_cz5.setDefaultValue('int. film / min. SHGC / min. U-factor / min. VLT')
    # args << filmtype_singlepane_cz5

    # filmtype_singlepane_cz6 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_singlepane_cz6', filmtypes, true)
    # filmtype_singlepane_cz6.setDisplayName('Select film type for single pane window on climate zone 6')
    # filmtype_singlepane_cz6.setDefaultValue('int. film / min. SHGC / min. U-factor / min. VLT')
    # args << filmtype_singlepane_cz6

    # filmtype_singlepane_cz7 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_singlepane_cz7', filmtypes, true)
    # filmtype_singlepane_cz7.setDisplayName('Select film type for single pane window on climate zone 7')
    # filmtype_singlepane_cz7.setDefaultValue('no film')
    # args << filmtype_singlepane_cz7

    # filmtype_singlepane_cz8 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_singlepane_cz8', filmtypes, true)
    # filmtype_singlepane_cz8.setDisplayName('Select film type for single pane window on climate zone 8')
    # filmtype_singlepane_cz8.setDefaultValue('no film')
    # args << filmtype_singlepane_cz8

    # filmtype_doublepane_cz1 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_doublepane_cz1', filmtypes, true)
    # filmtype_doublepane_cz1.setDisplayName('Select film type for double pane window on climate zone 1')
    # filmtype_doublepane_cz1.setDefaultValue('int. film / min. SHGC / min. U-factor / min. VLT')
    # args << filmtype_doublepane_cz1

    # filmtype_doublepane_cz2 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_doublepane_cz2', filmtypes, true)
    # filmtype_doublepane_cz2.setDisplayName('Select film type for double pane window on climate zone 2')
    # filmtype_doublepane_cz2.setDefaultValue('int. film / min. SHGC / min. U-factor / min. VLT')
    # args << filmtype_doublepane_cz2

    # filmtype_doublepane_cz3 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_doublepane_cz3', filmtypes, true)
    # filmtype_doublepane_cz3.setDisplayName('Select film type for double pane window on climate zone 3')
    # filmtype_doublepane_cz3.setDefaultValue('int. film / min. SHGC / min. U-factor / min. VLT')
    # args << filmtype_doublepane_cz3

    # filmtype_doublepane_cz4 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_doublepane_cz4', filmtypes, true)
    # filmtype_doublepane_cz4.setDisplayName('Select film type for double pane window on climate zone 4')
    # filmtype_doublepane_cz4.setDefaultValue('int. film / min. SHGC / min. U-factor / min. VLT')
    # args << filmtype_doublepane_cz4

    # filmtype_doublepane_cz5 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_doublepane_cz5', filmtypes, true)
    # filmtype_doublepane_cz5.setDisplayName('Select film type for double pane window on climate zone 5')
    # filmtype_doublepane_cz5.setDefaultValue('int. film / min. SHGC / min. U-factor / min. VLT')
    # args << filmtype_doublepane_cz5

    # filmtype_doublepane_cz6 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_doublepane_cz6', filmtypes, true)
    # filmtype_doublepane_cz6.setDisplayName('Select film type for double pane window on climate zone 6')
    # filmtype_doublepane_cz6.setDefaultValue('int. film / min. SHGC / min. U-factor / min. VLT')
    # args << filmtype_doublepane_cz6

    # filmtype_doublepane_cz7 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_doublepane_cz7', filmtypes, true)
    # filmtype_doublepane_cz7.setDisplayName('Select film type for double pane window on climate zone 7')
    # filmtype_doublepane_cz7.setDefaultValue('no film')
    # args << filmtype_doublepane_cz7

    # filmtype_doublepane_cz8 = OpenStudio::Measure::OSArgument.makeChoiceArgument('filmtype_doublepane_cz8', filmtypes, true)
    # filmtype_doublepane_cz8.setDisplayName('Select film type for double pane window on climate zone 8')
    # filmtype_doublepane_cz8.setDefaultValue('no film')
    # args << filmtype_doublepane_cz8

    # # create argument for removal of existing water heater tanks on selected loop
    # apply_measure = OpenStudio::Measure::OSArgument.makeBoolArgument('apply_measure', true)
    # apply_measure.setDisplayName('Apply measure?')
    # apply_measure.setDescription('')
    # apply_measure.setDefaultValue(true)
    # args << apply_measure

    # # create argument for add/don't-add output/meter variables
    # add_outputmetervar = OpenStudio::Measure::OSArgument.makeBoolArgument('add_outputmetervar', true)
    # add_outputmetervar.setDisplayName('Add output/meter variables?')
    # add_outputmetervar.setDescription('')
    # add_outputmetervar.setDefaultValue(false)
    # args << add_outputmetervar
    #-------------------------------------------------------------------------------

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    ################################################################
    puts '### initialization'
    ################################################################

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    ################################################################################
    # alternative for using input arguments
    #-------------------------------------------------------------------------------
    # filmtype_singlepane_cz1 = runner.getStringArgumentValue('filmtype_singlepane_cz1', user_arguments)
    # filmtype_singlepane_cz2 = runner.getStringArgumentValue('filmtype_singlepane_cz2', user_arguments)
    # filmtype_singlepane_cz3 = runner.getStringArgumentValue('filmtype_singlepane_cz3', user_arguments)
    # filmtype_singlepane_cz4 = runner.getStringArgumentValue('filmtype_singlepane_cz4', user_arguments)
    # filmtype_singlepane_cz5 = runner.getStringArgumentValue('filmtype_singlepane_cz5', user_arguments)
    # filmtype_singlepane_cz6 = runner.getStringArgumentValue('filmtype_singlepane_cz6', user_arguments)
    # filmtype_singlepane_cz7 = runner.getStringArgumentValue('filmtype_singlepane_cz7', user_arguments)
    # filmtype_singlepane_cz8 = runner.getStringArgumentValue('filmtype_singlepane_cz8', user_arguments)
    # filmtype_doublepane_cz1 = runner.getStringArgumentValue('filmtype_doublepane_cz1', user_arguments)
    # filmtype_doublepane_cz2 = runner.getStringArgumentValue('filmtype_doublepane_cz2', user_arguments)
    # filmtype_doublepane_cz3 = runner.getStringArgumentValue('filmtype_doublepane_cz3', user_arguments)
    # filmtype_doublepane_cz4 = runner.getStringArgumentValue('filmtype_doublepane_cz4', user_arguments)
    # filmtype_doublepane_cz5 = runner.getStringArgumentValue('filmtype_doublepane_cz5', user_arguments)
    # filmtype_doublepane_cz6 = runner.getStringArgumentValue('filmtype_doublepane_cz6', user_arguments)
    # filmtype_doublepane_cz7 = runner.getStringArgumentValue('filmtype_doublepane_cz7', user_arguments)
    # filmtype_doublepane_cz8 = runner.getStringArgumentValue('filmtype_doublepane_cz8', user_arguments)
    # apply_measure = runner.getBoolArgumentValue('apply_measure', user_arguments)
    # add_outputmetervar = runner.getBoolArgumentValue('add_outputmetervar', user_arguments)
    #-------------------------------------------------------------------------------

    # assign window film type to each ASHRAE climate zone number (i.e., 1-7)
    ################################################################################
    # alternative for using input arguments
    #-------------------------------------------------------------------------------
    # filmtypes_singlepane = [
    #   filmtype_singlepane_cz1,
    #   filmtype_singlepane_cz2,
    #   filmtype_singlepane_cz3,
    #   filmtype_singlepane_cz4,
    #   filmtype_singlepane_cz5,
    #   filmtype_singlepane_cz6,
    #   filmtype_singlepane_cz7,
    #   filmtype_singlepane_cz8
    # ]
    # filmtypes_doublepane = [
    #   filmtype_doublepane_cz1,
    #   filmtype_doublepane_cz2,
    #   filmtype_doublepane_cz3,
    #   filmtype_doublepane_cz4,
    #   filmtype_doublepane_cz5,
    #   filmtype_doublepane_cz6,
    #   filmtype_doublepane_cz7,
    #   filmtype_doublepane_cz8
    # ]
    #-------------------------------------------------------------------------------
    filmtypes_singlepane = [
      "int. film / min. SHGC / min. U-factor / min. VLT",
      "int. film / min. SHGC / min. U-factor / min. VLT",
      "int. film / min. SHGC / min. U-factor / min. VLT",
      "int. film / min. SHGC / min. U-factor / min. VLT",
      "int. film / min. SHGC / min. U-factor / min. VLT",
      "int. film / min. SHGC / min. U-factor / min. VLT",
      "int. film / min. SHGC / min. U-factor / min. VLT",
      "int. film / min. SHGC / min. U-factor / min. VLT"
    ]
    filmtypes_doublepane = [
      "ext. film / min. SHGC / min. VLT",
      "ext. film / min. SHGC / min. VLT",
      "ext. film / min. SHGC / min. VLT",
      "ext. film / min. SHGC / min. VLT",
      "ext. film / min. SHGC / min. VLT",
      "ext. film / min. SHGC / min. VLT",
      "no film",
      "no film"
    ]
    #-------------------------------------------------------------------------------

    # create hash: map_input_arg[window pane type][climate zone number] = window film type (user input)
    map_input_arg = {}
    [filmtypes_singlepane, filmtypes_doublepane].zip(["Single","Double"]).each do |filmtypes, label|
      map_input_arg[label] = {}
      filmtypes.each_with_index do |filmtype,i|
        map_input_arg[label][i+1] = filmtype.to_s
      end
    end

    # create hash: map_cec_to_iecc[CEC climate zone #] = ASHRAE climate zone #
    """
    # reference map
    CEC1 - 4B
    CEC2 - 3C
    CEC3 - 3C
    CEC4 - 3C
    CEC5 - 3C
    CEC6 - 3C
    CEC7 - 3B
    CEC8 - 3B
    CEC9 - 3B
    CEC10 - 3B
    CEC11 - 3B
    CEC12 - 3B
    CEC13 - 3B
    CEC15 - 2B
    CEC16 - 5B
    """
    map_cec_to_iecc = {
      1=>4,
      2=>3,
      3=>3,
      4=>3,
      5=>3,
      6=>3,
      7=>3,
      8=>3,
      9=>3,
      10=>3,
      11=>3,
      12=>3,
      13=>3,
      14=>3,
      15=>2,
      16=>5
    }

    ################################################################
    puts '### define existing product specification map'
    ################################################################

    # set hash:  map_window[comstock glazing name][window film type (user input)] = [U-factor(SI), SHGC, VLT]
    map_window = {
      "Simple Glazing Single - No LowE - Clear - Aluminum"=> {
        "panetype"=> "Single",
        "int. film / min. SHGC / min. VLT"=> [
          6.619,
          0.239,
          0.101
        ],
        "int. film / min. SHGC / min. U-factor / min. VLT"=> [
          5.502,
          0.248,
          0.17
        ],
        "ext. film / min. SHGC / min. VLT"=> [
          6.678,
          0.332,
          0.174
        ]
      },
      "Simple Glazing Single - No LowE - Tinted/Reflective - Aluminum"=> {
        "panetype"=> "Single",
        "int. film / min. SHGC / min. VLT"=> [
          6.618,
          0.283,
          0.059
        ],
        "int. film / min. SHGC / min. U-factor / min. VLT"=> [
          5.502,
          0.259,
          0.1
        ],
        "ext. film / min. SHGC / min. VLT"=> [
          6.677,
          0.3,
          0.105
        ]
      },
      "Simple Glazing Single - No LowE - Clear - Wood"=> {
        "panetype"=> "Single",
        "int. film / min. SHGC / min. VLT"=> [
          5.102,
          0.199,
          0.097
        ],
        "int. film / min. SHGC / min. U-factor / min. VLT"=> [
          4.031,
          0.208,
          0.163
        ],
        "ext. film / min. SHGC / min. VLT"=> [
          5.159,
          0.289,
          0.167
        ]
      },
      "Simple Glazing Single - No LowE - Tinted/Reflective - Wood"=> {
        "panetype"=> "Single",
        "int. film / min. SHGC / min. VLT"=> [
          5.101,
          0.242,
          0.057
        ],
        "int. film / min. SHGC / min. U-factor / min. VLT"=> [
          4.031,
          0.219,
          0.096
        ],
        "ext. film / min. SHGC / min. VLT"=> [
          5.158,
          0.258,
          0.101
        ]
      },
      "Simple Glazing Double - No LowE - Clear - Aluminum"=> {
        "panetype"=> "Double",
        "int. film / min. SHGC / min. VLT"=> [
          4.22,
          0.33,
          0.093
        ],
        "int. film / min. SHGC / min. U-factor / min. VLT"=> [
          3.889,
          0.324,
          0.157
        ],
        "ext. film / min. SHGC / min. VLT"=> [
          4.236,
          0.246,
          0.154
        ]
      },
      "Simple Glazing Double - No LowE - Tinted/Reflective - Aluminum"=> {
        "panetype"=> "Double",
        "int. film / min. SHGC / min. VLT"=> [
          4.237,
          0.27,
          0.056
        ],
        "int. film / min. SHGC / min. U-factor / min. VLT"=> [
          3.901,
          0.26,
          0.094
        ],
        "ext. film / min. SHGC / min. VLT"=> [
          4.253,
          0.214,
          0.095
        ]
      },
      "Simple Glazing Double - LowE - Clear - Aluminum"=> {
        "panetype"=> "Double",
        "int. film / min. SHGC / min. VLT"=> [
          3.168,
          0.237,
          0.081
        ],
        "int. film / min. SHGC / min. U-factor / min. VLT"=> [
          3.039,
          0.242,
          0.136
        ],
        "ext. film / min. SHGC / min. VLT"=> [
          3.173,
          0.154,
          0.136
        ]
      },
      "Simple Glazing Double - LowE - Clear - Thermally Broken Aluminum"=> {
        "panetype"=> "Double",
        "int. film / min. SHGC / min. VLT"=> [
          2.826,
          0.229,
          0.081
        ],
        "int. film / min. SHGC / min. U-factor / min. VLT"=> [
          2.697,
          0.233,
          0.136
        ],
        "ext. film / min. SHGC / min. VLT"=> [
          2.832,
          0.146,
          0.136
        ]
      },
      "Simple Glazing Double - LowE - Tinted/Reflective - Aluminum"=> {
        "panetype"=> "Double",
        "int. film / min. SHGC / min. VLT"=> [
          3.153,
          0.185,
          0.048
        ],
        "int. film / min. SHGC / min. U-factor / min. VLT"=> [
          3.027,
          0.185,
          0.081
        ],
        "ext. film / min. SHGC / min. VLT"=> [
          3.159,
          0.129,
          0.083
        ]
      },
      "Simple Glazing Double - LowE - Tinted/Reflective - Thermally Broken Aluminum"=> {
        "panetype"=> "Double",
        "int. film / min. SHGC / min. VLT"=> [
          2.812,
          0.176,
          0.048
        ],
        "int. film / min. SHGC / min. U-factor / min. VLT"=> [
          2.685,
          0.177,
          0.081
        ],
        "ext. film / min. SHGC / min. VLT"=> [
          2.817,
          0.121,
          0.083
        ]
      }
    }

    ################################################################
    puts '### get constructions including windows'
    ################################################################

    # get all construction objects that includes window
    sub_surfaces = []
    constructions = []
    model.getSubSurfaces.each do |sub_surface|
      next unless sub_surface.subSurfaceType.include?('Window')
      sub_surfaces << sub_surface
      constructions << sub_surface.construction.get
      puts "--- add window to the list: #{sub_surface.name} | #{sub_surface.construction.get.to_Construction.get.layers[0].name}"
    end
    constructions = constructions.uniq

    ################################################################
    puts '### check initial applicability'
    ################################################################

    # check to make sure building has fenestration surfaces
    # put AsNotApplicable for triple pane window
    if sub_surfaces.empty?
      runner.registerAsNotApplicable('The building has no windows.')
      return true
    else
      runner.registerInitialCondition("Found #{sub_surfaces.length()} sub-surfaces that include window")
    end

    ################################################################
    puts '### initialize window performance replacement'
    ################################################################

    # initialize hash for old construction name - new construction name
    new_construction_hash = {}

    # build standard to use OS standards methods
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)

    # get climate zone
    climate_zone = OpenstudioStandards::Weather.model_get_climate_zone(model)
    puts "--- climate_zone = #{climate_zone}"
    if climate_zone.empty?
      runner.registerError('Unable to determine climate zone for model. Cannot apply window film without climate zone information.')
    else
      if climate_zone.include?("CEC")
        climate_zone_num_ca = climate_zone.split("CEC")[-1]
        puts "--- climate_zone_num_ca = #{climate_zone_num_ca}"
        climate_zone_num_iecc = map_cec_to_iecc[climate_zone_num_ca.to_i].to_i
        puts "--- climate_zone_num_iecc = #{climate_zone_num_iecc}"
      elsif climate_zone.include?("ASHRAE")
        climate_zone_num_iecc = climate_zone.split("-")[-1][0].to_i
        puts "--- climate_zone_num_iecc = #{climate_zone_num_iecc}"
      else
        runner.registerError('Unable to determine climate zone for model. Cannot apply window film without climate zone information.')
      end
    end

    # get all simple glazing system window materials
    simple_glazings = model.getSimpleGlazings

    # initialize summary statistics
    pct_us = []
    pct_shgcs = []
    pct_vlts = []
    area_changed_m2 = 0

    ################################################################
    puts '### replace performance on relevant windows'
    ################################################################

    # replace window performances in baseline windows
    constructions.each do |construction|

      # don't apply measure if specified in input
      # break if apply_measure == false

      simple_glazings.each do |simple_glazing|

        simple_glazing_name = simple_glazing.name.get
        construction_name = construction.name.get

        puts "--- ----------------------------------------------------------------------"
        puts "--- construction = #{construction_name}"
        puts "--- simple_glazing = #{simple_glazing_name}"

        # check availability of simple glazing system name in filtered construction
        if not construction.to_Construction.get.layers[0].name.get == simple_glazing_name
          puts "--- simple glazing object name (#{simple_glazing_name}) not available in construction in interest. skipping.."
          next
        end
        puts "--- found matching simple glazing name (#{simple_glazing_name}) from construction in interest"

        # check availablility of glazing system name in the map
        if map_window.key?(simple_glazing_name) == false
          puts "--- simple glazing object name (#{simple_glazing_name}) not available in performance map. skipping.."
          next
        end
        puts "--- found values in the map with key \"#{simple_glazing_name}\""

        # check availability of values for the climate zone in the map
        if map_window[simple_glazing_name][climate_zone_num_iecc] == []
          puts "--- values for climate zone #{climate_zone_num_iecc} not available in performance map. skipping.."
          next
        end
        puts "--- found values in the map with climate zone #{climate_zone_num_iecc}"

        # get old values
        puts "--- get existing window properties"
        old_simple_glazing_u = simple_glazing.uFactor
        old_simple_glazing_shgc = simple_glazing.solarHeatGainCoefficient
        if simple_glazing.visibleTransmittance.is_initialized
          old_simple_glazing_vlt = simple_glazing.visibleTransmittance.get
        else
          old_simple_glazing_vlt = old_simple_glazing_shgc # if vlt is blank, E+ uses shgc
        end

        # get correct pane type based on comstock glazing name
        # TODO: maybe there's a more elegant way than this
        panetype = simple_glazing_name.split(" - ")[0].split("Simple Glazing ")[1]
        puts "--- pane type based on glazing system name = #{panetype}"

        # get new values
        # map_input_arg[window pane type][climate zone number] = window film type (user input)
        # map_window[comstock glazing name][window film type (user input)] = [U-factor(SI), SHGC, VLT]
        filmtype = map_input_arg[panetype][climate_zone_num_iecc]
        if filmtype == "no film"
          puts "--- film type is not selected for this pane type and climate zone. skipping.."
          next
        end
        puts "--- film option type based on pane type and climate zone = #{filmtype}"
        new_simple_glazing_u = map_window[simple_glazing_name][filmtype][0]
        new_simple_glazing_shgc = map_window[simple_glazing_name][filmtype][1]
        new_simple_glazing_vlt = map_window[simple_glazing_name][filmtype][2]

        # calculate relative differences
        puts "--- calculate performance changes for reporting"
        pct_u = ((new_simple_glazing_u-old_simple_glazing_u)/old_simple_glazing_u*100).round() # negative number meaning improvement
        pct_us << pct_u
        pct_shgc = ((new_simple_glazing_shgc-old_simple_glazing_shgc)/old_simple_glazing_shgc*100).round() # negative number meaning improvement
        pct_shgcs << pct_shgc
        pct_vlt = ((new_simple_glazing_vlt-old_simple_glazing_vlt)/old_simple_glazing_vlt*100).round()
        pct_vlts << pct_vlt

        # check if construction has been made
        if new_construction_hash.key?(construction)
          new_construction = new_construction_hash[construction]
          puts "--- apply previously created construction (#{new_construction.name.get})"
        else
          # make new simple glazing with SHGC and VLT reductions
          new_simple_glazing = OpenStudio::Model::SimpleGlazing.new(model)
          new_simple_glazing.setName("#{simple_glazing_name} with film")

          # set and register final conditions
          new_simple_glazing.setUFactor(new_simple_glazing_u)
          new_simple_glazing.setSolarHeatGainCoefficient(new_simple_glazing_shgc)
          new_simple_glazing.setVisibleTransmittance(new_simple_glazing_vlt)

          # report
          runner.registerInfo("Creating new simple glazing system (#{new_simple_glazing.name.get}) with window film")

          # create new construction with this new simple glazing layer
          new_construction = OpenStudio::Model::Construction.new(model)
          new_construction.setName("#{construction_name} with film")
          new_construction.insertLayer(0, new_simple_glazing)

          # report
          runner.registerInfo("Creating new construction (#{new_construction.name.get}) with new simple glazing system")

          # update hash
          new_construction_hash[construction] = new_construction
          puts "--- create simple glazing system (#{new_simple_glazing.name.get}) for this construction"


        end

        # loop over fenestration surfaces and add new construction
        sub_surfaces.each do |sub_surface|
          puts "--- assigning new construction with the new glazing system to the surface (#{sub_surface.name.get}) with (exterior) windows"
          # assign new construction to fenestration surfaces and add total area changed if construction names match
          next unless sub_surface.construction.get.to_Construction.get.layers[0].name.get == construction.to_Construction.get.layers[0].name.get
          sub_surface.setConstruction(new_construction)
          area_changed_m2 += sub_surface.grossArea
          # report
          runner.registerInfo("Applying new construction (#{new_construction.name.get}) to #{sub_surface.name.get}")
        end
      end
    end

    # ################################################################
    # puts '### set output/meter variables'
    # ################################################################

    # if add_outputmetervar == true
    #   # create list of new output variables
    #   ovar_names = [
    #     'Surface Window System Solar Transmittance',
    #     'Surface Window System Solar Reflectance',
    #     'Surface Window System Solar Absorptance'
    #   ]

    #   # create new output variable objects
    #   ovars = []
    #   ovar_names.each do |name|
    #     ovars << OpenStudio::Model::OutputVariable.new(name, model)
    #   end

    #   # set variable reporting frequency for newly created output variables
    #   ovars.each do |var|
    #     var.setReportingFrequency('TimeStep')
    #   end

    #   # create list of new meter variables
    #   mvar_names = [
    #     'General:Cooling:Electricity',
    #     'General:Heating:Electricity',
    #     'General:Heating:NaturalGas',
    #     'General:InteriorLights:Electricity'
    #   ]

    #   # create new output variable objects
    #   mvars = []
    #   mvar_names.each do |name|
    #     meter = OpenStudio::Model::OutputMeter.new(model)
    #     meter.setSpecificEndUse("General")
    #     meter.setName(name)
    #     mvars << meter
    #   end

    #   # set variable reporting frequency for newly created output variables
    #   mvars.each do |var|
    #     var.setReportingFrequency('TimeStep')
    #   end

    #   # register info for output variables
    #   runner.registerInfo("#{ovars.size} output variables and #{mvars.size} meter variables are added to the model.")
    # end

    ################################################################
    puts '### check measure applicability'
    ################################################################

    if area_changed_m2 != 0
      runner.registerInfo("U-factor changes (in %) on each window by adding window film = #{pct_us}")
      runner.registerInfo("SHGC changes (in %) on each window by adding window film = #{pct_shgcs}")
      runner.registerInfo("VLT changes (in %) on each window by adding window film = #{pct_vlts}")
    else area_changed_m2 == 0
      runner.registerAsNotApplicable("No changes in U-factor/SHGC/VLT since window film is not added.")
      return true
    end

    ################################################################
    puts '### finalization'
    ################################################################

    # register value
    pct_u_avg = pct_us.sum(0.0) / pct_us.size
    pct_shgc_avg = pct_shgcs.sum(0.0) / pct_shgcs.size
    pct_vlt_avg = pct_vlts.sum(0.0) / pct_vlts.size
    runner.registerValue('pct_u_avg', pct_u_avg.round(3), '%')
    runner.registerValue('pct_shgc_avg', pct_shgc_avg.round(3), '%')
    runner.registerValue('pct_vlt_avg', pct_vlt_avg.round(3), '%')

    puts "--- pct_u_avg = #{pct_u_avg}"
    puts "--- pct_shgc_avg = #{pct_shgc_avg}"
    puts "--- pct_vlt_avg = #{pct_vlt_avg}"

    area_changed_ft2 = OpenStudio.convert(area_changed_m2, 'm^2', 'ft^2').get
    if area_changed_ft2 != 0
      runner.registerFinalCondition("Added window film to a total of #{area_changed_ft2.round(2)} ft2 that changed U-factor by #{pct_u_avg}%, SHGC by #{pct_shgc_avg}%, and VLT by #{pct_vlt_avg}%.")
    else
      runner.registerFinalCondition("Window film is not added.")
    end
    runner.registerValue('env_window_film_fen_area_ft2', area_changed_ft2.round(2), 'ft2')

    return true

  end
end

# register the measure to be used by the application
EnvWindowFilm.new.registerWithApplication
