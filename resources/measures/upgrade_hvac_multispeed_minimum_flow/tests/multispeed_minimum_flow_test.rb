# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
######################################################################
#  Copyright (c) 2008-2013, Alliance for Sustainable Energy.
#  All rights reserved.
#
#  This library is free software you can redistribute it and/or
#  modify it under the terms of the GNU Lesser General Public
#  License as published by the Free Software Foundation either
#  version 2.1 of the License, or (at your option) any later version.
#
#  This library is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#  Lesser General Public License for more details.
#
#  You should have received a copy of the GNU Lesser General Public
#  License along with this library if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
######################################################################

require 'openstudio'
require 'openstudio/ruleset/ShowRunnerOutput'
require_relative '../../../../test/helpers/minitest_helper'
require_relative '../measure'
require 'minitest/autorun'

class MultispeedMinimumFlowTest < MiniTest::Unit::TestCase
  def test_multispeed_minimum_flow
    # create an instance of the measure
    measure = MultispeedMinimumFlow.new

    # create an instance of a runner with OSW
    runner = OpenStudio::Ruleset::OSRunner.new(OpenStudio::WorkflowJSON.new)

    # load the test model
    translator = OpenStudio::OSVersion::VersionTranslator.new
    path = OpenStudio::Path.new("#{File.dirname(__FILE__)}/in.osm")
    model = translator.loadModel(path)
    assert(!model.empty?)
    model = model.get

    # forward translate OSM file to IDF file
    ft = OpenStudio::EnergyPlus::ForwardTranslator.new
    workspace = ft.translateModel(model)

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments(workspace)
    argument_map = OpenStudio::Ruleset::OSArgumentMap.new

    measure.run(workspace, runner, argument_map)
    result = runner.result
    show_output(result)
    # assert(result.value.valueName == "Success")

    # save the workspace to output directory
    output_file_path = OpenStudio::Path.new("#{File.dirname(__FILE__)}/output/test_output.idf")
    workspace.save(output_file_path, true)
  end
end
