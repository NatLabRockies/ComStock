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
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'json'
require 'fileutils'
require 'minitest/autorun'
require_relative '../measure'
require_relative '../../../../test/helpers/minitest_helper'

# only necessary to include here if annual simulation request and the measure doesn't require openstudio-standards
# require 'comstock-typical'

class HvacVrfHrDoasTest < Minitest::Test
  # return file paths to test models in test directory
  def models_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/models/*.osm'))
    paths.map { |path| File.expand_path(path) }
  end

  # return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/weather/*.epw'))
    paths.map { |path| File.expand_path(path) }
  end

  def load_model(osm_path)
    translator = OpenStudio::OSVersion::VersionTranslator.new
    model = translator.loadModel(OpenStudio::Path.new(osm_path))
    assert(!model.empty?)
    model.get
  end

  def run_dir(test_name)
    # always generate test output in specially named 'output' directory so result files are not made part of the measure
    "#{File.dirname(__FILE__)}/output/#{test_name}"
  end

  def model_output_path(test_name)
    "#{run_dir(test_name)}/#{test_name}.osm"
  end

  def sql_path(test_name)
    "#{run_dir(test_name)}/run/eplusout.sql"
  end

  def report_path(test_name)
    "#{run_dir(test_name)}/reports/eplustbl.html"
  end

  # applies the measure and then runs the model
  def apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false)
    assert(File.exist?(osm_path))
    assert(File.exist?(epw_path))

    # create run directory if it does not exist
    FileUtils.mkdir_p(run_dir(test_name))
    assert(File.exist?(run_dir(test_name)))

    # change into run directory for tests
    start_dir = Dir.pwd
    Dir.chdir run_dir(test_name)

    # remove prior runs if they exist
    FileUtils.rm_f(model_output_path(test_name))
    FileUtils.rm_f(report_path(test_name))

    # copy the osm and epw to the test directory
    new_osm_path = "#{run_dir(test_name)}/#{File.basename(osm_path)}"
    FileUtils.cp(osm_path, new_osm_path)
    new_epw_path = "#{run_dir(test_name)}/#{File.basename(epw_path)}"
    FileUtils.cp(epw_path, new_epw_path)
    # create an instance of a runner
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

    # load the test model
    model = load_model(new_osm_path)

    # set model weather file
    epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(new_epw_path))
    OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
    assert(model.weatherFile.is_initialized)

    # run the measure
    puts "\nAPPLYING MEASURE..."
    measure.run(model, runner, argument_map)
    result = runner.result
    result_success = result.value.valueName == 'Success'

    # show the output
    show_output(result)

    # save model
    model.save(model_output_path(test_name), true)

    if run_model && result_success
      puts "\nRUNNING MODEL..."

      std = Standard.build('90.1-2013')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))

      # check that the model ran successfully
      assert(File.exist?(sql_path(test_name)))
    end

    # change back directory
    Dir.chdir(start_dir)

    result
  end

  def test_number_of_arguments_and_argument_names
    # This test ensures that the current test is matched to the measure inputs
    test_name = 'test_number_of_arguments_and_argument_names'
    puts "\n######\nTEST:#{test_name}\n######\n"

    # Create an instance of the measure
    measure = HvacVrfHrDoas.new

    # Make an empty model
    model = OpenStudio::Model::Model.new

    # Get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(4, arguments.size)
    assert_equal('vrf_defrost_strategy', arguments[0].name)
    assert_equal('disable_defrost', arguments[1].name)
    assert_equal('upsizing_allowance_pct', arguments[2].name)
    assert_equal('apply_measure', arguments[3].name)
  end

  def data_point_ordering_check(lookup_table_in_hash)
    tables = lookup_table_in_hash[:tables][:curves][:table]

    tables.each do |table|
      next unless table[:form] == 'MultiVariableLookupTable'

      puts("--- checking table format: #{table[:name]}")

      # Extract and sort data_point keys numerically
      points = table.select { |k, _| k.to_s.match?(/^data_point\d+$/) }
                    .sort_by { |k, _| k.to_s.match(/\d+/)[0].to_i }
                    .map { |_, v| v.split(',').first(2).map(&:to_f) }

      # Now check if x2 varies first (should see repeated x1s for several rows)
      points.transpose

      # Build pairs and check how they vary
      points[0]
      x1_first_changes = 0
      x2_first_changes = 0

      points.each_cons(2) do |(x1a, x2a), (x1b, x2b)|
        if x1a != x1b && x2a == x2b
          x1_first_changes += 1
        elsif x1a == x1b && x2a != x2b
          x2_first_changes += 1
        end
      end

      # If x1 changes more frequently while x2 is stable, the ordering is wrong
      assert(x2_first_changes >= x1_first_changes, 'Invalid data point order: x1 varies before x2 in some cases')
    end
  end

  def test_table_lookup_format
    # This test ensures the format of lookup tables
    test_name = 'test_lookup_table_format'
    puts "\n######\nTEST:#{test_name}\n######\n"

    path_to_jsons = "#{__dir__}/../resources/*.json"
    json_files = Dir.glob(path_to_jsons)
    json_files.each do |file_path|
      content = File.read(file_path)
      hash = JSON.parse(content, symbolize_names: true)

      # Now `hash` is your Ruby hash from JSON
      # You can insert your test logic here
      assert(hash[:tables], "Missing :tables key in #{file_path}")

      # check lookup table format
      data_point_ordering_check(hash)
    rescue JSON::ParserError => e
      flunk "JSON parsing failed for #{file_path}: #{e.message}"
    end
  end

  # create an array of hashes with model name, weather, and expected result
  def models_to_test
    test_sets = []

    # test: warm weather
    test_sets << {
      model: 'Small_Office_2A',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'Success',
      lookup_table_test: {
        table_name: 'HCAPFT_Daikin_RELQ_100CR_120MBH',
        ind1: 16.111,
        ind2: -30.0,
        dep: 0.579
      }
    }
    # test: cold weather
    test_sets << {
      model: 'Small_Office_2A',
      weather: 'USA_AK_Fairbanks.Intl.AP.702610_TMY3',
      result: 'Success',
      lookup_table_test: {
        table_name: 'CCAPFT_Daikin_RELQ_100CR_120MBH',
        ind1: 13.889,
        ind2: -39.444,
        dep: 0.587
      }
    }
    # test: too many indoor units
    test_sets << {
      model: 'Outpatient_VAV_chiller_PFP_boxes',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'NA'
    }
    # test: floor area too large
    test_sets << {
      model: 'SecondarySchool_PTHP',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'NA'
    }
    # test: not applicable building type
    test_sets << {
      model: 'Quick_Service_Restaurant_CA',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'NA'
    }
    # test: not applicable building type
    test_sets << {
      model: 'Restaurant_5B',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'NA'
    }
    # test: not applicable hvac type
    test_sets << {
      model: 'Residential_AC_with_electric_baseboard_heat_3B',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'NA'
    }
    # test: not applicable hvac type
    test_sets << {
      model: 'LargeOffice_VAV_district_chw_hw',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'NA'
    }

    test_sets
  end

  def test_models
    test_name = 'test_models'
    puts "\n######\nTEST:#{test_name}\n######\n"

    models_to_test.each do |set|
      instance_test_name = set[:model]
      puts "instance test name: #{instance_test_name}"
      osm_path = models_for_tests.select { |x| set[:model] == File.basename(x, '.osm') }
      epw_path = epws_for_tests.select { |x| set[:weather] == File.basename(x, '.epw') }
      assert(!osm_path.empty?)
      assert(!epw_path.empty?)
      osm_path = osm_path[0]
      epw_path = epw_path[0]

      # create an instance of the measure
      measure = HvacVrfHrDoas.new

      # load the model; only used here for populating arguments
      model = load_model(osm_path)

      # set arguments here; will vary by measure
      arguments = measure.arguments(model)
      argument_map = OpenStudio::Measure::OSArgumentMap.new

      # set arguments: choice of economizer
      vrf_defrost_strategy = arguments[0].clone
      assert(vrf_defrost_strategy.setValue('reverse-cycle'))
      argument_map['vrf_defrost_strategy'] = vrf_defrost_strategy

      # set arguments: changeover temperature C
      disable_defrost = arguments[1].clone
      assert(disable_defrost.setValue(false))
      argument_map['disable_defrost'] = disable_defrost

      # set arguments: changeover temperature C
      upsizing_allowance_pct = arguments[2].clone
      assert(upsizing_allowance_pct.setValue(25.0))
      argument_map['upsizing_allowance_pct'] = upsizing_allowance_pct

      # set arguments: apply measure
      apply_measure = arguments[3].clone
      assert(apply_measure.setValue(true))
      argument_map['apply_measure'] = apply_measure

      # apply the measure to the model and optionally run the model
      result = apply_measure_and_run(instance_test_name, measure, argument_map, osm_path, epw_path, run_model: false)
      model = load_model(model_output_path(instance_test_name))

      # check the measure result; result values will equal Success, Fail, or Not Applicable (NA)
      # also check the amount of warnings, info, and error messages
      # use if or case statements to change expected assertion depending on model characteristics
      assert(result.value.valueName == set[:result])

      next unless set[:result] == 'Success'

      runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
      # Check if lookup table is available
      lookup_table_name = set[:lookup_table_test][:table_name]
      table_multivar_lookups = model.getTableLookups
      lookup_table = table_multivar_lookups.find { |table| table.name.to_s == lookup_table_name }
      refute_nil(lookup_table, "Cannot find table named #{lookup_table_name} from model.")

      # Compare table lookup value against hard-coded values
      dep_var_ref = set[:lookup_table_test][:dep]
      dep_var = HvacVrfHrDoas.get_dep_var_from_lookup_table_with_two_ind_var(runner, lookup_table,
                                                                             set[:lookup_table_test][:ind1], set[:lookup_table_test][:ind2])
      puts('### lookup table test')
      puts("--- lookup_table_name = #{lookup_table_name}")
      puts("--- input_var1 = #{set[:lookup_table_test][:ind1]} | input_var2 = #{set[:lookup_table_test][:ind2]}")
      puts("--- dep_var reference = #{dep_var_ref} | dep_var from model = #{dep_var}")
      assert_in_epsilon(dep_var_ref, dep_var, 0.01,
                        "Table lookup value test didn't pass: table name = #{lookup_table_name} | ind_var1 = #{set[:lookup_table_test][:ind1]} | ind_var2 = #{set[:lookup_table_test][:ind2]} | expected #{dep_var_ref} but got #{dep_var}")
    end
  end
end
