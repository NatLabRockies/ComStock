# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'minitest/autorun'
require_relative '../measure'
require_relative '../../../../test/helpers/minitest_helper'
require 'fileutils'

class HvacDoasHpMinisplitsTest < Minitest::Test
  # def setup
  # end

  # def teardown
  # end

  def test_number_of_arguments_and_argument_names
    # create an instance of the measure
    measure = HvacDoasHpMinisplits.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(3, arguments.size)
    assert_equal('area_limit_sf', arguments[0].name)
    assert_equal('doas_htg_fuel', arguments[1].name)
    assert_equal('performance_oversizing_factor', arguments[2].name)
  end
end
