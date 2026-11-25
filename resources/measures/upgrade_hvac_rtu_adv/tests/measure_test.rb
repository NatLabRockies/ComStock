# frozen_string_literal: true

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
require 'fileutils'
require 'minitest/autorun'
require_relative '../measure'
require_relative '../../../../test/helpers/minitest_helper'
require 'json'

class UpgradeHvacRtuAdvTest < Minitest::Test
  def setup
    @runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
  end

  def test_get_capacity_category
    puts('### DEBUGGING: test_get_capacity_category')

    # test: zero input
    rated_capacity_w = 0
    label_curve, label_category = UpgradeHvacRtuAdv.get_capacity_category(@runner, rated_capacity_w)
    puts("--- DEBUGGING: label_curve = #{label_curve}, label_category = #{label_category}")
    assert_nil(label_curve)
    assert_nil(label_category)

    # test: small unit
    rated_capacity_w = 30000
    label_curve, label_category = UpgradeHvacRtuAdv.get_capacity_category(@runner, rated_capacity_w)
    puts("--- DEBUGGING: label_curve = #{label_curve}, label_category = #{label_category}")
    assert_equal('0_11', label_curve)
    assert_equal('small_unit', label_category)

    # test: medium unit
    rated_capacity_w = 60000
    label_curve, label_category = UpgradeHvacRtuAdv.get_capacity_category(@runner, rated_capacity_w)
    puts("--- DEBUGGING: label_curve = #{label_curve}, label_category = #{label_category}")
    assert_equal('11_20', label_curve)
    assert_equal('medium_unit', label_category)

    # test: large unit
    rated_capacity_w = 120000
    label_curve, label_category = UpgradeHvacRtuAdv.get_capacity_category(@runner, rated_capacity_w)
    puts("--- DEBUGGING: label_curve = #{label_curve}, label_category = #{label_category}")
    assert_equal('20_9999', label_curve)
    assert_equal('large_unit', label_category)
  end

  def test_get_stage_category
    puts('### DEBUGGING: test_get_stage_category')

    # test: zero input
    stage_number = 0
    label_stage = UpgradeHvacRtuAdv.get_stage_category(@runner, stage_number)
    puts("--- DEBUGGING: label_stage = #{label_stage}")
    assert_nil(label_stage)

    # test: 1
    stage_number = 1
    label_stage = UpgradeHvacRtuAdv.get_stage_category(@runner, stage_number)
    puts("--- DEBUGGING: label_stage = #{label_stage}")
    assert_equal('low_stage', label_stage)

    # test: 2
    stage_number = 2
    label_stage = UpgradeHvacRtuAdv.get_stage_category(@runner, stage_number)
    puts("--- DEBUGGING: label_stage = #{label_stage}")
    assert_equal('medium_stage', label_stage)

    # test: 3
    stage_number = 3
    label_stage = UpgradeHvacRtuAdv.get_stage_category(@runner, stage_number)
    puts("--- DEBUGGING: label_stage = #{label_stage}")
    assert_equal('high_stage', label_stage)

    # test: 4
    stage_number = 4
    label_stage = UpgradeHvacRtuAdv.get_stage_category(@runner, stage_number)
    puts("--- DEBUGGING: label_stage = #{label_stage}")
    assert_nil(label_stage)
  end

  # m3/s per W of 1 cfm/ton
  def m_3_per_s_per_w_per_cfm_per_ton
    OpenStudio.convert(OpenStudio.convert(1.0, 'cfm', 'm^3/s').get, 'W', 'ton').get
  end

  # A stage's rated sensible heat ratio is EnergyPlus' relation for autosized DX cooling coils: 0.676 at 300 cfm/ton,
  # 0.798 at 450 cfm/ton, linear between and held at those values outside.
  def test_stage_rated_shr
    puts('### DEBUGGING: test_stage_rated_shr')
    capacity_w = 10_000.0
    { 250 => 0.676, 300 => 0.676, 350 => 0.717, 400 => 0.758, 450 => 0.798, 600 => 0.798 }.each do |cfm_per_ton, expected|
      airflow_m_3_per_s = cfm_per_ton * m_3_per_s_per_w_per_cfm_per_ton * capacity_w
      shr = UpgradeHvacRtuAdv.stage_rated_shr(airflow_m_3_per_s, capacity_w)
      puts("--- DEBUGGING: #{cfm_per_ton} cfm/ton shr = #{shr}")
      assert_in_delta(expected, shr, 0.001, "SHR at #{cfm_per_ton} cfm/ton")
    end
  end

  # Cooling stage airflows and capacities. No stage may move less air than the unit's minimum airflow; a lower stage
  # that the minimum pushes above 450 cfm/ton gets more capacity, or is removed when that takes more than 65% of the
  # step to the next stage. The medium stage is always kept.
  # Each case: [rated cfm/ton, minimum airflow over the rated airflow] and, by stage, the expected
  # [airflow over the rated airflow, capacity over the rated capacity].
  def test_cooling_stage_flows_and_capacities
    puts('### DEBUGGING: test_cooling_stage_flows_and_capacities')
    measure = UpgradeHvacRtuAdv.new
    capacity_w = 35_000.0
    cases = {
      # the low stage runs at the minimum airflow (420 cfm/ton); nothing else changes
      [350.0, 0.40] => { 1 => [0.40, 0.333], 2 => [0.666, 0.666], 3 => [1.0, 1.0] },
      # the low stage at the minimum airflow would be at 480 cfm/ton: capacity raised to 450 cfm/ton
      [400.0, 0.40] => { 1 => [0.40, 0.40 * 400.0 / 450.0], 2 => [0.666, 0.666], 3 => [1.0, 1.0] },
      # minimum outdoor air of 0.65: low stage capacity raised, medium stage untouched
      [300.0, 0.65] => { 1 => [0.65, 0.65 * 300.0 / 450.0], 2 => [0.666, 0.666], 3 => [1.0, 1.0] },
      # minimum outdoor air of 0.90: the low stage would need 0.70 of the rated capacity and is removed; the medium
      # stage runs at the minimum airflow with its capacity raised to 450 cfm/ton
      [350.0, 0.90] => { 2 => [0.90, 0.90 * 350.0 / 450.0], 3 => [1.0, 1.0] },
      # all outdoor air: the medium stage takes the full allowance and stays above 450 cfm/ton
      [400.0, 1.0] => { 2 => [1.0, 0.666 + (0.334 * 0.65)], 3 => [1.0, 1.0] },
      # rated airflow below 300 cfm/ton: the medium stage's airflow is raised to 300 cfm/ton
      [250.0, 0.40] => { 1 => [0.40, 0.333], 2 => [0.666 * 300.0 / 250.0, 0.666], 3 => [1.0, 1.0] },
      # rated airflow above 450 cfm/ton: the medium stage's airflow is lowered to 450 cfm/ton, the low stage's
      # capacity is raised
      [500.0, 0.40] => { 1 => [0.40, 0.40 * 500.0 / 450.0], 2 => [0.666 * 450.0 / 500.0, 0.666], 3 => [1.0, 1.0] }
    }
    cases.each do |(rated_cfm_per_ton, min_ratio), expected|
      label = "#{rated_cfm_per_ton.round(0)} cfm/ton, minimum airflow #{min_ratio}"
      airflow = rated_cfm_per_ton * m_3_per_s_per_w_per_cfm_per_ton * capacity_w
      flows, caps = measure.cooling_stage_flows_and_capacities(capacity_w, airflow, min_ratio * airflow)
      puts("--- DEBUGGING: #{label}: flows #{flows.transform_values { |v| (v / airflow).round(4) }} caps #{caps.transform_values { |v| (v / capacity_w).round(4) }}")
      assert_equal(expected.keys.sort, caps.keys.sort, "#{label}: stages kept")
      assert_equal(caps.keys.sort, flows.keys.sort, "#{label}: airflow and capacity stages differ")
      expected.each do |stage, (flow_fraction, cap_fraction)|
        assert_in_delta(flow_fraction, flows[stage] / airflow, 1e-4, "#{label}: stage #{stage} airflow fraction")
        assert_in_delta(cap_fraction, caps[stage] / capacity_w, 1e-4, "#{label}: stage #{stage} capacity fraction")
        assert(flows[stage] >= (min_ratio * airflow) - 1e-9, "#{label}: stage #{stage} airflow is below the minimum airflow")
      end
      caps.keys.sort.each_cons(2) do |lower, higher|
        assert(flows[higher] >= flows[lower] - 1e-9, "#{label}: stage #{higher} moves less air than stage #{lower}")
        assert(caps[higher] > caps[lower], "#{label}: stage #{higher} has no more capacity than stage #{lower}")
      end
    end
  end

  def test_get_reference_cop_ratio
    puts('### DEBUGGING: test_get_reference_cop_ratio')

    # test: zero input
    stage_number = 0
    cop_ratio = UpgradeHvacRtuAdv.get_reference_cop_ratio(@runner, stage_number)
    puts("--- DEBUGGING: cop_ratio = #{cop_ratio}")
    assert_nil(cop_ratio)

    # test: 1
    stage_number = 1
    cop_ratio = UpgradeHvacRtuAdv.get_reference_cop_ratio(@runner, stage_number)
    puts("--- DEBUGGING: cop_ratio = #{cop_ratio}")
    assert_in_epsilon(1.130014, cop_ratio, 0.001)

    # test: 2
    stage_number = 2
    cop_ratio = UpgradeHvacRtuAdv.get_reference_cop_ratio(@runner, stage_number)
    puts("--- DEBUGGING: cop_ratio = #{cop_ratio}")
    assert_in_epsilon(1.096739, cop_ratio, 0.001)

    # test: 3
    stage_number = 3
    cop_ratio = UpgradeHvacRtuAdv.get_reference_cop_ratio(@runner, stage_number)
    puts("--- DEBUGGING: cop_ratio = #{cop_ratio}")
    assert_in_epsilon(1.0, cop_ratio, 0.001)

    # test: 4
    stage_number = 4
    cop_ratio = UpgradeHvacRtuAdv.get_reference_cop_ratio(@runner, stage_number)
    puts("--- DEBUGGING: cop_ratio = #{cop_ratio}")
    assert_nil(cop_ratio)
  end

  def test_get_rated_cfm_per_ton
    puts('### DEBUGGING: test_get_rated_cfm_per_ton')

    # test: zero input
    rated_capacity_w = 0
    cfm_per_ton = UpgradeHvacRtuAdv.get_rated_cfm_per_ton(@runner, rated_capacity_w)
    puts("--- DEBUGGING: cfm_per_ton = #{cfm_per_ton}")
    assert_nil(cfm_per_ton)

    # test: very small
    rated_capacity_w = 1
    cfm_per_ton = UpgradeHvacRtuAdv.get_rated_cfm_per_ton(@runner, rated_capacity_w)
    puts("--- DEBUGGING: cfm_per_ton = #{cfm_per_ton}")
    assert_in_epsilon(400, cfm_per_ton, 0.001)

    # test: small unit
    rated_capacity_w = 30000
    cfm_per_ton = UpgradeHvacRtuAdv.get_rated_cfm_per_ton(@runner, rated_capacity_w)
    puts("--- DEBUGGING: cfm_per_ton = #{cfm_per_ton}")
    assert_in_epsilon(365.844, cfm_per_ton, 0.001)

    # test: medium unit
    rated_capacity_w = 50000
    cfm_per_ton = UpgradeHvacRtuAdv.get_rated_cfm_per_ton(@runner, rated_capacity_w)
    puts("--- DEBUGGING: cfm_per_ton = #{cfm_per_ton}")
    assert_in_epsilon(354.9288, cfm_per_ton, 0.001)

    # test: large unit
    rated_capacity_w = 1000000
    cfm_per_ton = UpgradeHvacRtuAdv.get_rated_cfm_per_ton(@runner, rated_capacity_w)
    puts("--- DEBUGGING: cfm_per_ton = #{cfm_per_ton}")
    assert_in_epsilon(324, cfm_per_ton, 0.001)
  end

  def test_get_rated_cop_cooling_adv
    puts('### DEBUGGING: test_get_rated_cop_cooling_adv')

    # test: zero input
    rated_capacity_w = 0
    cop = UpgradeHvacRtuAdv.get_rated_cop_cooling_adv(@runner, rated_capacity_w)
    puts("--- DEBUGGING: cop = #{cop}")
    assert_nil(cop)

    # test: very small
    rated_capacity_w = 0.001
    cop = UpgradeHvacRtuAdv.get_rated_cop_cooling_adv(@runner, rated_capacity_w)
    puts("--- DEBUGGING: cop = #{cop}")
    assert_in_epsilon(4.26, cop, 0.001)

    # test: small unit
    rated_capacity_w = 30000
    cop = UpgradeHvacRtuAdv.get_rated_cop_cooling_adv(@runner, rated_capacity_w)
    puts("--- DEBUGGING: cop = #{cop}")
    assert_in_epsilon(4.177824, cop, 0.001)

    # test: medium unit
    rated_capacity_w = 50000
    cop = UpgradeHvacRtuAdv.get_rated_cop_cooling_adv(@runner, rated_capacity_w)
    puts("--- DEBUGGING: cop = #{cop}")
    assert_in_epsilon(3.95019, cop, 0.001)

    # test: large unit
    rated_capacity_w = 1000000
    cop = UpgradeHvacRtuAdv.get_rated_cop_cooling_adv(@runner, rated_capacity_w)
    puts("--- DEBUGGING: cop = #{cop}")
    assert_in_epsilon(3.62, cop, 0.001)
  end

  def load_model(osm_path)
    translator = OpenStudio::OSVersion::VersionTranslator.new
    model = translator.loadModel(OpenStudio::Path.new(osm_path))
    assert(!model.empty?)
    model.get
  end

  def run_dir(test_name)
    # always generate test output in specially named 'output' directory so
    # result files are not made part of the measure
    "#{File.dirname(__FILE__)}/output/#{test_name}"
  end

  def model_input_path(osm_name)
    File.join(File.dirname(__FILE__), "../../../tests/models/#{osm_name}")
  end

  def epw_input_path(epw_name)
    File.join(File.dirname(__FILE__), "../../../tests/weather/#{epw_name}")
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
  def set_weather_and_apply_measure_and_run(
    test_name,
    measure,
    argument_map,
    osm_path,
    epw_path,
    run_model: false,
    model: nil,
    apply: true,
    expected_results: 'Success'
  )
    assert(File.exist?(osm_path))
    assert(File.exist?(epw_path))
    ddy_path = "#{epw_path.gsub('.epw', '')}.ddy"

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

    # load the test model
    model = load_model(new_osm_path) if model.nil?

    # set model weather file
    epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(new_epw_path))
    OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
    assert(model.weatherFile.is_initialized)

    # set design days
    if File.exist?(ddy_path)

      # remove all the Design Day objects that are in the file
      model.getObjectsByType('OS:SizingPeriod:DesignDay'.to_IddObjectType).each(&:remove)

      # load ddy
      ddy_model = OpenStudio::EnergyPlus.loadAndTranslateIdf(ddy_path).get

      ddy_model.getDesignDays.sort.each do |d|
        # grab only the ones that matter
        ddy_list = [
          # Annual heating 99.6%
          /Htg 99.6. Condns DB/,
          # Annual humidity (for cooling towers and evap coolers)
          /Clg .4. Condns WB=>MDB/,
          # Annual cooling
          /Clg .4. Condns DB=>MWB/,
          # Monthly cooling DB=>MCWB (to handle solar-gain-driven cooling)
          /August .4. Condns DB=>MCWB/,
          /September .4. Condns DB=>MCWB/,
          /October .4. Condns DB=>MCWB/
        ]
        ddy_list.each do |ddy_name_regex|
          if d.name.get.to_s.match?(ddy_name_regex)
            @runner.registerInfo("Adding object #{d.name}")

            # add the object to the existing model
            model.addObject(d.clone)
            break
          end
        end
      end

      # assert
      assert_equal(false, model.getDesignDays.empty?)
    end

    if apply
      # run the measure
      puts "\nAPPLYING MEASURE..."
      measure.run(model, @runner, argument_map)
      result = @runner.result
      result_success = result.value.valueName == 'Success'
      assert_equal(expected_results, result.value.valueName)

      # Show the output
      show_output(result)
    end

    # adding output variables (for debugging)
    out_vars = [
      'Air System Mixed Air Mass Flow Rate',
      'Fan Air Mass Flow Rate',
      'Fan Electricity Rate',
      'Unitary System Predicted Sensible Load to Setpoint Heat Transfer Rate',
      'Cooling Coil Total Cooling Rate',
      'Cooling Coil Electricity Rate',
      'Cooling Coil Runtime Fraction',
      'Cooling Coil Upper Speed Level ',
      'Cooling Coil Neighboring Speed Levels Ratio',
      'Heating Coil Heating Rate',
      'Heating Coil Electricity Rate',
      'Heating Coil Runtime Fraction',
      'Unitary System DX Coil Cycling Ratio',
      'Unitary System DX Coil Speed Ratio',
      'Unitary System DX Coil Speed Level',
      'Unitary System Total Cooling Rate',
      'Unitary System Total Heating Rate',
      'Unitary System Electricity Rate',
      'HVAC System Solver Iteration Count',
      'Site Outdoor Air Drybulb Temperature',
      'Heating Coil Crankcase Heater Electricity Rate',
      'Heating Coil Defrost Electricity Rate',
      'System Node Temperature',
      'System Node Mass Flow Rate'
    ]
    out_vars.each do |out_var_name|
      ov = OpenStudio::Model::OutputVariable.new('ov', model)
      ov.setKeyValue('*')
      ov.setReportingFrequency('TimeStep')
      ov.setVariableName(out_var_name)
    end
    model.getOutputControlFiles.setOutputCSV(true)

    if run_model
      puts "\nRUNNING MODEL..."

      std = Standard.build('90.1-2013')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))

      # Check that the model ran successfully
      assert(File.exist?(sql_path(test_name)))
    end

    # Save model
    model.applySizingValues
    model.save(model_output_path(test_name), true)

    # change back directory
    Dir.chdir(start_dir)

    result
  end

  def test_number_of_arguments_and_argument_names
    # This test ensures that the current test is matched to the measure inputs
    test_name = 'test_number_of_arguments_and_argument_names'
    puts "\n######\nTEST:#{test_name}\n######\n"

    # Create an instance of the measure
    measure = UpgradeHvacRtuAdv.new

    # Make an empty model
    model = OpenStudio::Model::Model.new

    # Get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(3, arguments.size)
    assert_equal('hr', arguments[0].name)
    assert_equal('dcv', arguments[1].name)
    assert_equal('debug_verbose', arguments[2].name)
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
      x1s, x2s = points.transpose

      # Build pairs and check how they vary
      last_x1, last_x2 = points[0]
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
      assert(x2_first_changes >= x1_first_changes,
             'Invalid data point order: x1 varies before x2 in some cases')
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
      puts("### checking json file: #{file_path}")

      # Now `hash` is your Ruby hash from JSON
      # You can insert your test logic here
      assert(hash[:tables], "Missing :tables key in #{file_path}")

      # check lookup table format
      data_point_ordering_check(hash)
    rescue JSON::ParserError => e
      flunk "JSON parsing failed for #{file_path}: #{e.message}"
    end
  end

  def _mimic_hardsize_model(model, test_dir)
    standard = Standard.build('ComStock DOE Ref Pre-1980')

    # Run a sizing run to determine equipment capacities and flow rates
    if standard.model_run_sizing_run(model, test_dir.to_s) == false
      puts('Sizing run for Hardsize model failed, cannot hard-size model.')
      return false
    end

    # APPLY
    model.applySizingValues

    # TODO: remove once this functionality is added to
    # the OpenStudio C++ for hard sizing UnitarySystems
    model.getAirLoopHVACUnitarySystems.each do |unitary|
      if model.version < OpenStudio::VersionString.new('3.7.0')
        unitary.setSupplyAirFlowRateMethodDuringCoolingOperation('SupplyAirFlowRate')
        unitary.setSupplyAirFlowRateMethodDuringHeatingOperation('SupplyAirFlowRate')
      end
    end
    # TODO: remove once this functionality is added to
    # the OpenStudio C++ for hard sizing Sizing:System
    model.getSizingSystems.each do |sizing_system|
      next if sizing_system.isDesignOutdoorAirFlowRateAutosized

      sizing_system.setSystemOutdoorAirMethod('ZoneSum')
    end

    return model
  end

  # unitary systems this measure created; kitchens and data centers keep their original unit
  def adv_rtus(model)
    model.getAirLoopHVACUnitarySystems.sort.select { |us| us.name.to_s.include?('RTU SZ-VAV high-efficiency') }
  end

  # value of an OpenStudio optional, or nil when it is not set
  def optional_value(value)
    return value if value.is_a?(Numeric)

    value.is_initialized ? value.get : nil
  end

  # assert every advanced RTU's terminal passes at least the minimum outdoor air (OA) flow whenever the fan runs:
  # the terminal's maximum airflow is hard-sized to the loop design airflow, and its minimum airflow (zone minimum air
  # flow fraction x maximum) is at least the minimum OA flow and equals the unit's no-load airflow.
  # A terminal that asks for less air than the fan moves can leave the OA controller with no airflow, which closes
  # the outdoor air while the fan runs: see assert_oa_controller_sees_fan_airflow.
  # Call this on the model as the measure left it; a later sizing run hard-sizes the terminal maximum on its own.
  def assert_terminal_minimum_is_no_load_airflow(model, label)
    rtus = adv_rtus(model)
    refute_empty(rtus, "#{label}: no advanced RTUs to check")

    rtus.each do |us|
      air_loop_hvac = us.airLoopHVAC.get
      name = "#{label} #{air_loop_hvac.name}"
      controller_oa = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
      oa = optional_value(controller_oa.minimumOutdoorAirFlowRate) || optional_value(controller_oa.autosizedMinimumOutdoorAirFlowRate)
      design = optional_value(air_loop_hvac.designSupplyAirFlowRate) || optional_value(air_loop_hvac.autosizedDesignSupplyAirFlowRate)
      no_load = optional_value(us.supplyAirFlowRateWhenNoCoolingorHeatingisRequired)
      refute_nil(oa, "#{name}: no minimum OA flow")
      refute_nil(design, "#{name}: no design supply airflow")
      refute_nil(no_load, "#{name}: no no-load supply airflow")

      terminal = air_loop_hvac.demandComponents.map(&:to_AirTerminalSingleDuctVAVHeatAndCoolNoReheat).find(&:is_initialized)
      refute_nil(terminal, "#{name}: no VAV heat and cool terminal on the air loop")
      terminal_max = optional_value(terminal.get.maximumAirFlowRate)
      refute_nil(terminal_max, "#{name}: the terminal's maximum airflow is not hard-sized")
      assert_in_delta(design, terminal_max, design * 1e-6,
                      "#{name}: terminal maximum airflow #{terminal_max.round(4)} m3/s differs from the loop design airflow #{design.round(4)} m3/s")
      terminal_min = terminal.get.zoneMinimumAirFlowFraction * terminal_max
      assert(terminal_min >= oa * (1 - 1e-6),
             "#{name}: terminal minimum airflow #{terminal_min.round(4)} m3/s is below the minimum OA flow #{oa.round(4)} m3/s")
      assert_in_delta(no_load, terminal_min, no_load * 1e-6,
                      "#{name}: terminal minimum airflow #{terminal_min.round(4)} m3/s differs from the no-load airflow #{no_load.round(4)} m3/s")
    end
  end

  # assert the outdoor air controller of every advanced RTU air loop saw airflow whenever the supply fan ran, from the
  # Fan Air Mass Flow Rate and Air System Mixed Air Mass Flow Rate records of an annual run.
  # With a terminal minimum of 0 the terminal asks for no air while its zone has no load. In a model with no zone
  # exhaust fan, EnergyPlus then reports no mixed air flow and delivers no outdoor air in those timesteps, although
  # the fan runs at its no-load airflow. A model used with this check must not have a zone exhaust fan, or the check
  # passes whatever the terminal minimum is.
  def assert_oa_controller_sees_fan_airflow(model, test_name)
    sql = OpenStudio::SqlFile.new(OpenStudio::Path.new(sql_path(test_name)))
    series = lambda do |variable, key|
      'SELECT r.TimeIndex AS ti, r.Value AS v FROM ReportData r ' \
        'JOIN ReportDataDictionary d ON d.ReportDataDictionaryIndex = r.ReportDataDictionaryIndex ' \
        'JOIN Time t ON t.TimeIndex = r.TimeIndex ' \
        "WHERE d.Name = '#{variable}' AND d.KeyValue = '#{key.upcase.gsub("'", "''")}' AND t.WarmupFlag = 0 " \
        'AND t.EnvironmentPeriodIndex IN (SELECT EnvironmentPeriodIndex FROM EnvironmentPeriods WHERE EnvironmentType = 3)'
    end
    rtus = adv_rtus(model)
    refute_empty(rtus, "#{test_name}: no advanced RTUs to check")

    rtus.each do |us|
      air_loop_hvac = us.airLoopHVAC.get
      fan = series.call('Fan Air Mass Flow Rate', us.supplyFan.get.name.to_s)
      mixed = series.call('Air System Mixed Air Mass Flow Rate', air_loop_hvac.name.to_s)
      joined = "FROM (#{fan}) f JOIN (#{mixed}) m ON m.ti = f.ti"
      fan_records = sql.execAndReturnFirstInt("SELECT COUNT(*) #{joined} WHERE f.v > 0").get
      assert(fan_records.positive?, "#{test_name} #{air_loop_hvac.name}: no records with the supply fan running in the sql")

      # records where the controller saw no airflow while the fan ran, and the year's mixed air over the year's fan
      # airflow. The two flows need not match record by record: the terminal can sit at its minimum while the unit's
      # fan runs at a higher airflow, and the terminal minimum still carries the minimum outdoor air.
      no_air_records = sql.execAndReturnFirstInt("SELECT COUNT(*) #{joined} WHERE f.v > 0 AND m.v < 0.01 * f.v").get
      ratio = sql.execAndReturnFirstDouble("SELECT SUM(m.v) / SUM(f.v) #{joined}").get
      assert_equal(0, no_air_records,
                   "#{test_name} #{air_loop_hvac.name}: the outdoor air controller saw no airflow in #{no_air_records} of #{fan_records} records with the fan running")
      assert(ratio >= 0.9, "#{test_name} #{air_loop_hvac.name}: annual mixed air flow is #{ratio.round(3)} of the fan's airflow")
    end
  ensure
    sql&.close
  end

  # assert every advanced RTU has a UnitarySystemPerformance:Multispeed object whose no-load ratio gives the unit's
  # no-load airflow: EnergyPlus takes the no-load airflow of a unit with a multispeed coil as that ratio times the
  # cooling supply airflow and ignores the unit's own no-load airflow. Without the object OpenStudio writes one with a
  # blank ratio (EnergyPlus default 1), and the fan runs at full airflow whenever there is no load.
  # The stage ratios must be each cooling stage's rated airflow over the cooling supply airflow.
  # The cooling coil must be a multispeed coil: OpenStudio 3.10 writes an assigned performance object with one cooling
  # speed for a variable-speed coil, which stops EnergyPlus (the annual test would catch that).
  def assert_no_load_airflow_ratio(model, label)
    rtus = adv_rtus(model)
    refute_empty(rtus, "#{label}: no advanced RTUs to check")

    rtus.each do |us|
      name = "#{label} #{us.name}"
      no_load = optional_value(us.supplyAirFlowRateWhenNoCoolingorHeatingisRequired)
      clg_flow = optional_value(us.supplyAirFlowRateDuringCoolingOperation)
      refute_nil(no_load, "#{name}: no no-load supply airflow")
      refute_nil(clg_flow, "#{name}: no cooling supply airflow")
      assert(us.designSpecificationMultispeedObject.is_initialized, "#{name}: no multispeed performance object assigned")
      performance = us.designSpecificationMultispeedObject.get

      ratio = performance.noLoadSupplyAirflowRateRatio
      assert_in_delta(no_load, ratio * clg_flow, no_load * 1e-6,
                      "#{name}: no-load ratio #{ratio.round(4)} x cooling airflow #{clg_flow.round(4)} m3/s differs from the no-load airflow #{no_load.round(4)} m3/s")
      assert(ratio >= 0.40 - 1e-6, "#{name}: no-load ratio #{ratio.round(4)} is below the 0.40 minimum airflow")
      assert(ratio <= 1.0 + 1e-6, "#{name}: no-load ratio #{ratio.round(4)} exceeds 1.0")

      assert(us.coolingCoil.get.to_CoilCoolingDXMultiSpeed.is_initialized, "#{name}: the cooling coil is not a multispeed coil")
      stages = us.coolingCoil.get.to_CoilCoolingDXMultiSpeed.get.stages
      fields = performance.supplyAirflowRatioFields
      assert_equal(stages.size, fields.size, "#{name}: one airflow ratio field per cooling stage expected")
      stages.each_with_index do |stage, i|
        assert_in_delta(stage.ratedAirFlowRate.get / clg_flow, optional_value(fields[i].coolingRatio), 1e-6,
                        "#{name}: cooling stage #{i + 1} airflow ratio differs from its rated airflow over the cooling airflow")
        assert_in_delta(1.0, optional_value(fields[i].heatingRatio), 1e-6, "#{name}: heating airflow ratio #{i + 1} is not 1.0")
      end
    end
  end

  # assert every advanced RTU's supply fan sits at the no-load airflow while its zone has no load, from the records of
  # an annual run where the unit's predicted sensible load is zero and the fan runs. The measure is the mean fan
  # airflow in those records over the unit's design airflow, against the measure's minimum airflow ratio.
  # - The ratio is read from the fan's power minimum flow fraction: a model saved after a simulation carries the
  #   no-load airflow EnergyPlus used, not the one the measure set.
  # - The design airflow is turned into a mass flow with EnergyPlus' standard air density for the site elevation (dry
  #   air at 20 C and the standard pressure at that elevation). The year's highest fan airflow is no reference: a unit
  #   that idles at its minimum may never reach its design airflow.
  # Before the no-load ratio was set the fan ran at the design airflow in these records.
  def assert_fan_at_no_load_airflow_without_load(model, test_name)
    sql = OpenStudio::SqlFile.new(OpenStudio::Path.new(sql_path(test_name)))
    series = lambda do |variable, key|
      'SELECT r.TimeIndex AS ti, r.Value AS v FROM ReportData r ' \
        'JOIN ReportDataDictionary d ON d.ReportDataDictionaryIndex = r.ReportDataDictionaryIndex ' \
        'JOIN Time t ON t.TimeIndex = r.TimeIndex ' \
        "WHERE d.Name = '#{variable}' AND d.KeyValue = '#{key.upcase.gsub("'", "''")}' AND t.WarmupFlag = 0 " \
        'AND t.EnvironmentPeriodIndex IN (SELECT EnvironmentPeriodIndex FROM EnvironmentPeriods WHERE EnvironmentType = 3)'
    end
    rtus = adv_rtus(model)
    refute_empty(rtus, "#{test_name}: no advanced RTUs to check")
    assert(model.weatherFile.is_initialized, "#{test_name}: the model has no weather file to take the site elevation from")
    standard_pressure_pa = 101_325.0 * ((1.0 - (2.25577e-5 * model.weatherFile.get.elevation))**5.2559)
    standard_density_kg_per_m3 = standard_pressure_pa / (287.0 * 293.15)

    rtus.each do |us|
      name = "#{test_name} #{us.name}"
      fan = series.call('Fan Air Mass Flow Rate', us.supplyFan.get.name.to_s)
      load = series.call('Unitary System Predicted Sensible Load to Setpoint Heat Transfer Rate', us.name.to_s)
      joined = "FROM (#{fan}) f JOIN (#{load}) q ON q.ti = f.ti"
      no_load_records = sql.execAndReturnFirstInt("SELECT COUNT(*) #{joined} WHERE f.v > 0 AND q.v = 0").get
      assert(no_load_records > 100, "#{name}: only #{no_load_records} records with the fan running and no load; the check needs a model that idles")

      mean_no_load_kg_per_s = sql.execAndReturnFirstDouble("SELECT AVG(f.v) #{joined} WHERE f.v > 0 AND q.v = 0").get
      design_m3_per_s = [optional_value(us.supplyAirFlowRateDuringCoolingOperation), optional_value(us.supplyAirFlowRateDuringHeatingOperation)].max
      actual = mean_no_load_kg_per_s / (design_m3_per_s * standard_density_kg_per_m3)
      expected = optional_value(us.supplyFan.get.to_FanVariableVolume.get.fanPowerMinimumFlowFraction)
      assert_in_delta(expected, actual, 0.03,
                      "#{name}: with no load the fan averages #{actual.round(3)} of the design airflow, expected #{expected.round(3)}")
    end
  ensure
    sql&.close
  end

  # assert every advanced RTU's supply fan moves at least the unit's minimum airflow in the records of an annual run
  # where the unit is above its lowest cooling stage. The compressor then runs the whole record, so the fan's airflow
  # is a blend of two stage airflows whatever the fan mode. Before the stage airflows were raised to the unit's
  # minimum, the lowest stage ran at a third of the design airflow: a unit just above it moved less than its minimum
  # airflow and, with a high outdoor air share, less than its minimum outdoor air.
  # The minimum airflow ratio and the design mass flow are taken as in assert_fan_at_no_load_airflow_without_load.
  def assert_fan_at_least_minimum_airflow_while_cooling(model, test_name)
    sql = OpenStudio::SqlFile.new(OpenStudio::Path.new(sql_path(test_name)))
    series = lambda do |variable, key|
      'SELECT r.TimeIndex AS ti, r.Value AS v FROM ReportData r ' \
        'JOIN ReportDataDictionary d ON d.ReportDataDictionaryIndex = r.ReportDataDictionaryIndex ' \
        'JOIN Time t ON t.TimeIndex = r.TimeIndex ' \
        "WHERE d.Name = '#{variable}' AND d.KeyValue = '#{key.upcase.gsub("'", "''")}' AND t.WarmupFlag = 0 " \
        'AND t.EnvironmentPeriodIndex IN (SELECT EnvironmentPeriodIndex FROM EnvironmentPeriods WHERE EnvironmentType = 3)'
    end
    rtus = adv_rtus(model)
    refute_empty(rtus, "#{test_name}: no advanced RTUs to check")
    assert(model.weatherFile.is_initialized, "#{test_name}: the model has no weather file to take the site elevation from")
    standard_pressure_pa = 101_325.0 * ((1.0 - (2.25577e-5 * model.weatherFile.get.elevation))**5.2559)
    standard_density_kg_per_m3 = standard_pressure_pa / (287.0 * 293.15)

    rtus.each do |us|
      name = "#{test_name} #{us.name}"
      fan = series.call('Fan Air Mass Flow Rate', us.supplyFan.get.name.to_s)
      speed = series.call('Unitary System DX Coil Speed Level', us.name.to_s)
      joined = "FROM (#{fan}) f JOIN (#{speed}) s ON s.ti = f.ti"
      staged_records = sql.execAndReturnFirstInt("SELECT COUNT(*) #{joined} WHERE s.v >= 2").get
      assert(staged_records > 20, "#{name}: only #{staged_records} records above the lowest cooling stage; the check needs a model that cools")

      lowest_kg_per_s = sql.execAndReturnFirstDouble("SELECT MIN(f.v) #{joined} WHERE s.v >= 2").get
      design_m3_per_s = [optional_value(us.supplyAirFlowRateDuringCoolingOperation), optional_value(us.supplyAirFlowRateDuringHeatingOperation)].max
      actual = lowest_kg_per_s / (design_m3_per_s * standard_density_kg_per_m3)
      expected = optional_value(us.supplyFan.get.to_FanVariableVolume.get.fanPowerMinimumFlowFraction)
      assert(actual >= expected - 0.03,
             "#{name}: above the lowest cooling stage the fan moved as little as #{actual.round(3)} of the design airflow (lowest of #{staged_records} records), below the minimum of #{expected.round(3)}")
    end
  ensure
    sql&.close
  end

  def verify_adv_rtu(test_name, measure, argument_map, osm_path, epw_path)
    # set weather file but not apply measure
    result = set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path,
                                                   epw_path, run_model: false, apply: false)
    model = load_model(model_output_path(test_name))

    # hardsize model
    model = _mimic_hardsize_model(model, "#{run_dir(test_name)}/SR_before")

    # get initial gas heating coils
    li_gas_htg_coils_initial = model.getCoilHeatingGass

    # get initial number of applicable air loops
    li_unitary_sys_initial = model.getAirLoopHVACUnitarySystems

    # get initial unitary system schedules for outdoor air and general operation
    # these will be compared against applied HP-RTU system
    dict_oa_sched_min_initial = {}
    dict_min_oa_initial = {}
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      # get thermal zone for dictionary mapping
      thermal_zone = air_loop_hvac.thermalZones[0]

      # get OA schedule from OA controller
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      controller_oa = oa_system.getControllerOutdoorAir
      oa_schedule = controller_oa.minimumOutdoorAirSchedule.get
      dict_oa_sched_min_initial[thermal_zone.name.to_s] = oa_schedule

      # get min/max outdoor air flow rate
      min_oa = controller_oa.minimumOutdoorAirFlowRate.get
      max_oa = controller_oa.maximumOutdoorAirFlowRate.get
      dict_min_oa_initial[thermal_zone.name.to_s] = min_oa
    end

    # set weather file and apply measure
    result = set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path,
                                                   epw_path, run_model: false, apply: true)
    model = load_model(model_output_path(test_name))

    # the new terminals carry the unit's minimum airflow; checked before the sizing run below hard-sizes them
    assert_terminal_minimum_is_no_load_airflow(model, test_name)
    assert_no_load_airflow_ratio(model, test_name)
    # the cooling stages as the measure set them: applying the sizing run's values below replaces each stage's
    # airflow and capacity with EnergyPlus' own design sizes (equal steps of the highest stage)
    adv_rtus(model).each { |us| assert_cooling_stages_respect_minimum_airflow(us) }

    # hardsize model
    model = _mimic_hardsize_model(model, "#{run_dir(test_name)}/SR_after")

    # get list of final unitary systems
    li_unitary_sys_final = model.getAirLoopHVACUnitarySystems

    # assert same number of unitary systems as initial
    assert_equal(li_unitary_sys_initial.size, li_unitary_sys_final.size)

    # get final unitary system schedules for outdoor air and general operation
    # these will be compared against original system
    dict_oa_sched_min_final = {}
    dict_min_oa_final = {}
    dict_max_oa_final = {}
    model.getAirLoopHVACs.sort.each do |air_loop_hvac|
      # get thermal zone for dictionary mapping
      thermal_zone = air_loop_hvac.thermalZones[0]

      # get OA schedule from OA controller
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      controller_oa = oa_system.getControllerOutdoorAir
      oa_schedule = controller_oa.minimumOutdoorAirSchedule.get
      dict_oa_sched_min_final[thermal_zone.name.to_s] = oa_schedule

      # get min/max outdoor air flow rate
      min_oa = controller_oa.minimumOutdoorAirFlowRate.get
      max_oa = controller_oa.maximumOutdoorAirFlowRate.get
      dict_min_oa_final[thermal_zone.name.to_s] = min_oa
    end

    # assert outdoor air values match between initial and new system
    model.getThermalZones.sort.each do |thermal_zone|
      assert_equal(dict_oa_sched_min_initial[thermal_zone.name.to_s],
                   dict_oa_sched_min_final[thermal_zone.name.to_s])
      assert_in_epsilon(dict_min_oa_initial[thermal_zone.name.to_s].to_f,
                        dict_min_oa_final[thermal_zone.name.to_s].to_f, 0.001)
    end

    # assert characteristics of new unitary systems
    li_unitary_sys_final.sort.each do |system|
      puts("### CHECKING: airloophvacunitarysystem = #{system.name}")

      # skip for inapplicable (not upgraded) RTUs
      if system.name.to_s.downcase.include?('kitchen')
        puts('--- CHECKING: skipping for this RTU which was not'\
             ' upgraded due to space type (i.e., kitchen)')
        next
      end

      # skip for inapplicable (not upgraded) RTUs
      if system.name.to_s.downcase.include?('datacenter') ||
         system.name.to_s.downcase.include?('data center')
        puts('--- CHECKING: skipping for this RTU which was'\
             ' not upgraded due to space type (i.e., data center)')
        next
      end

      # assert new unitary systems all have variable speed fans
      puts('--- CHECKING: Expected supply fan to be variable volume')
      fan = system.supplyFan.get
      assert(fan.to_FanVariableVolume.is_initialized,
             'Expected supply fan to be variable volume')

      # assert supplemental heating coil availability
      puts('--- CHECKING: Expected supplemental heating coil to be available')
      sup_htg_coil_elec = system.supplementalHeatingCoil.get
      sup_htg_coil_elec_avail = sup_htg_coil_elec.to_CoilHeatingElectric.is_initialized
      sup_htg_coil_gas = system.supplementalHeatingCoil.get
      sup_htg_coil_gas_avail = sup_htg_coil_gas.to_CoilHeatingGas.is_initialized
      sup_htg_coil_avail = sup_htg_coil_elec_avail || sup_htg_coil_gas_avail
      assert(sup_htg_coil_avail, 'Expected supplemental heating coil to be available')

      # ***cooling***
      # assert new unitary systems all have multispeed DX cooling coils
      puts('--- CHECKING: Expected cooling coil to be multispeed')
      clg_coil = system.coolingCoil.get
      assert(clg_coil.to_CoilCoolingDXMultiSpeed.is_initialized,
             'Expected cooling coil to be multispeed')
      clg_coil = clg_coil.to_CoilCoolingDXMultiSpeed.get

      # assert multispeed cooling coil has 3 stages, or 2 where the unit's minimum airflow removes the low stage
      puts('--- CHECKING: Expected cooling coil to have 2 or 3 stages')
      stages = clg_coil.stages
      assert_includes([2, 3], stages.size, 'Expected cooling coil to have 2 or 3 stages')

      # assert the highest stage's flowrate matches design flow rate
      puts('--- CHECKING: Expected the highest stage flowrate to match design flow rate')
      clg_dsn_flowrate = system.supplyAirFlowRateDuringCoolingOperation
      assert_in_delta(clg_dsn_flowrate.to_f, stages.last.ratedAirFlowRate.get, 0.000001,
                      'Expected the highest stage flowrate to match design flow rate')
    end
    result
  end

  # assert an advanced RTU's cooling stages: no stage moves less air than the unit's minimum airflow (the lowest
  # stage ran at a third of the design airflow before, below the minimum outdoor air of units with a high outdoor air
  # share), airflow does not rise and capacity falls toward the lower stages, each stage's rated sensible heat ratio
  # follows its airflow per capacity, and a lower stage is outside 300 to 450 cfm/ton only where the medium stage has
  # taken its full capacity allowance (65% of the step to the high stage) and the unit's minimum airflow still holds
  # it above the limit. The high stage keeps the airflow per capacity of the coil it replaces.
  # The unit's minimum airflow is read as the fan's power minimum flow fraction times the cooling supply airflow.
  def assert_cooling_stages_respect_minimum_airflow(system)
    stages = system.coolingCoil.get.to_CoilCoolingDXMultiSpeed.get.stages
    clg_flow = optional_value(system.supplyAirFlowRateDuringCoolingOperation)
    min_ratio = optional_value(system.supplyFan.get.to_FanVariableVolume.get.fanPowerMinimumFlowFraction)
    refute_nil(clg_flow, "#{system.name}: no cooling supply airflow")
    refute_nil(min_ratio, "#{system.name}: no fan power minimum flow fraction")
    min_airflow = min_ratio * clg_flow

    stages.each_with_index do |stage, i|
      label = "#{system.name} cooling stage #{i + 1} of #{stages.size}"
      flow = stage.ratedAirFlowRate.get
      capacity = stage.grossRatedTotalCoolingCapacity.get
      cfm_per_ton = flow / capacity / m_3_per_s_per_w_per_cfm_per_ton
      puts("--- CHECKING: #{label}: #{(flow / clg_flow).round(3)} of the design airflow, #{cfm_per_ton.round(0)} cfm/ton, minimum airflow #{min_ratio.round(3)}")
      assert(flow >= min_airflow * (1 - 1e-6),
             "#{label}: airflow #{flow.round(4)} m3/s is below the unit's minimum airflow #{min_airflow.round(4)} m3/s")
      assert_in_delta(UpgradeHvacRtuAdv.stage_rated_shr(flow, capacity), stage.grossRatedSensibleHeatRatio.get, 1e-6,
                      "#{label}: rated sensible heat ratio does not follow its airflow per capacity")
      full_allowance = 0.666 + ((1.0 - 0.666) * 0.65)
      held_medium_stage = (i == stages.size - 2) && (capacity / stages.last.grossRatedTotalCoolingCapacity.get >= full_allowance - 1e-6)
      next if i == stages.size - 1 || held_medium_stage

      assert(cfm_per_ton.round(0) >= 300 && cfm_per_ton.round(0) <= 450, "#{label}: #{cfm_per_ton.round(0)} cfm/ton is outside 300 to 450")
    end
    stages.each_cons(2) do |lower, higher|
      assert(higher.ratedAirFlowRate.get >= lower.ratedAirFlowRate.get * (1 - 1e-9),
             "#{system.name}: a higher cooling stage moves less air than the stage below it")
      assert(higher.grossRatedTotalCoolingCapacity.get > lower.grossRatedTotalCoolingCapacity.get,
             "#{system.name}: a higher cooling stage has no more capacity than the stage below it")
    end
  end

  # check upgrade specs
  def test_310_psz_ac_with_gas_coil
    osm_name = '310_PSZ-AC with gas coil.osm'
    epw_name = 'G2001730.epw'

    test_name = 'test_310_psz_ac_with_gas_coil'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = UpgradeHvacRtuAdv.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'debug_verbose'
        debug_verbose = arguments[idx].clone
        debug_verbose.setValue(true)
        argument_map[arg.name] = debug_verbose
      else
        argument_map[arg.name] = temp_arg_var
      end
    end
    test_result = verify_adv_rtu(test_name, measure, argument_map, osm_path, epw_path)
  end

  # check upgrade specs
  def test_310_psz_ac_with_electric_coil
    osm_name = '310_PSZ-AC with electric coil.osm'
    epw_name = 'G2901890.epw'

    test_name = 'test_310_psz_ac_with_electric_coil'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = UpgradeHvacRtuAdv.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'debug_verbose'
        debug_verbose = arguments[idx].clone
        debug_verbose.setValue(true)
        argument_map[arg.name] = debug_verbose
      else
        argument_map[arg.name] = temp_arg_var
      end
    end
    test_result = verify_adv_rtu(test_name, measure, argument_map, osm_path, epw_path)
  end

  # check upgrade specs
  def test_310_psz_ac_with_district_hot_water
    osm_name = '310_PSZ-AC with district hot water.osm'
    epw_name = 'G5101530.epw'

    test_name = 'test_310_psz_ac_with_district_hot_water'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = UpgradeHvacRtuAdv.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'debug_verbose'
        debug_verbose = arguments[idx].clone
        debug_verbose.setValue(true)
        argument_map[arg.name] = debug_verbose
      else
        argument_map[arg.name] = temp_arg_var
      end
    end
    test_result = verify_adv_rtu(test_name, measure, argument_map, osm_path, epw_path)
  end

  # check upgrade specs
  def test_310_psz_ac_with_gas_boiler
    osm_name = '310_PSZ-AC with gas boiler.osm'
    epw_name = 'G1000030.epw'

    test_name = 'test_310_psz_ac_with_gas_boiler'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = UpgradeHvacRtuAdv.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'debug_verbose'
        debug_verbose = arguments[idx].clone
        debug_verbose.setValue(true)
        argument_map[arg.name] = debug_verbose
      else
        argument_map[arg.name] = temp_arg_var
      end
    end
    test_result = verify_adv_rtu(test_name, measure, argument_map, osm_path, epw_path)
  end

  # check partially applicable model
  def test_310_psz_ac_with_gas_coil_partial_upgrade
    osm_name = '310_PSZ-AC with gas coil.osm'
    epw_name = 'G2001730.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = UpgradeHvacRtuAdv.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      argument_map[arg.name] = temp_arg_var
    end

    # get initial number of applicable air loops
    li_unitary_sys_initial = model.getAirLoopHVACUnitarySystems

    # determine air loops with/without kitchens
    tz_kitchens = []
    kitchen_htg_coils = []
    tz_all_other = []
    nonkitchen_htg_coils = []
    model.getAirLoopHVACUnitarySystems.sort.each do |unitary_sys|
      # skip kitchen spaces
      thermal_zone_names_to_exclude = ['Kitchen', 'kitchen', 'KITCHEN']
      if thermal_zone_names_to_exclude.any? { |word| unitary_sys.name.to_s.include?(word) }
        tz_kitchens << unitary_sys

        # add kitchen heating coil to list
        kitchen_htg_coils << unitary_sys.heatingCoil.get

        next
      end

      # add non kitchen zone and heating coil to list
      tz_all_other << unitary_sys
      # add kitchen heating coil to list
      nonkitchen_htg_coils << unitary_sys.heatingCoil.get
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path,
                                                   epw_path, run_model: false, apply: true)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))

    # get heating coils from final model for kitchen and non kitchen spaces
    tz_kitchens_final = []
    kitchen_htg_coils_final = []
    tz_all_other_final = []
    nonkitchen_htg_coils_final = []
    model.getAirLoopHVACUnitarySystems.sort.each do |unitary_sys|
      # skip kitchen spaces
      thermal_zone_names_to_exclude = ['Kitchen', 'kitchen', 'KITCHEN']
      if thermal_zone_names_to_exclude.any? { |word| unitary_sys.name.to_s.include?(word) }
        tz_kitchens_final << unitary_sys

        # add kitchen heating coil to list
        kitchen_htg_coils_final << unitary_sys.heatingCoil.get

        next
      end

      # add non kitchen zone and heating coil to list
      tz_all_other_final << unitary_sys
      # add kitchen heating coil to list
      nonkitchen_htg_coils_final << unitary_sys.heatingCoil.get
    end

    # assert no changes to kitchen unitary systems
    assert_equal(tz_kitchens_final, tz_kitchens)

    # assert kitchen spaces still contain gas coils
    kitchen_htg_coils_final.each do |htg_coil|
      assert(htg_coil.to_CoilHeatingGas.is_initialized)
    end
  end

  # check inapplicable model
  def test_310_psz_hp
    # this makes sure measure registers an na for non applicable model
    osm_name = '310_PSZ-HP.osm'
    epw_name = 'G2000050.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = UpgradeHvacRtuAdv.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      argument_map[arg.name] = temp_arg_var
    end

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(
      __method__,
      measure,
      argument_map,
      osm_path,
      epw_path,
      run_model: false,
      apply: true,
      expected_results: 'NA'
    )
  end

  # check hr=false is not changing exisiting H/ERVs
  def test_380_full_service_restaurant_psz_gas_coil_single_erv_3a_erv_false
    # this makes sure measure registers an na for non applicable model
    osm_name = '370_strip_mall_psz_gas_some_erv_4a.osm'
    epw_name = 'G5101530.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = UpgradeHvacRtuAdv.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hr'
        hr = arguments[idx].clone
        hr.setValue(false)
        argument_map[arg.name] = hr
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # get baseline ERVs
    ervs_baseline = model.getHeatExchangerAirToAirSensibleAndLatents

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path,
                                                   epw_path, run_model: false, apply: true)
    model = load_model(model_output_path(__method__))

    # assert no difference in ERVs in upgrade model
    ervs_upgrade = model.getHeatExchangerAirToAirSensibleAndLatents
    assert_equal(ervs_baseline, ervs_upgrade, 'ERVs should not change when ERV argument is false')
  end

  # check hr=true is changing exisiting H/ERVs
  def test_380_full_service_restaurant_psz_gas_coil_single_erv_3a_erv_true
    # this makes sure measure registers an na for non applicable model
    osm_name = '370_strip_mall_psz_gas_some_erv_4a.osm'
    epw_name = 'G5101530.epw'

    puts "\n######\nTEST:#{osm_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = UpgradeHvacRtuAdv.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      if arg.name == 'hr'
        hr = arguments[idx].clone
        hr.setValue(true)
        argument_map[arg.name] = hr
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # get baseline ERVs
    ervs_baseline = model.getHeatExchangerAirToAirSensibleAndLatents

    # Apply the measure to the model and optionally run the model
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path,
                                                   epw_path, run_model: false, apply: true)
    model = load_model(model_output_path(__method__))

    # assert no difference in ERVs in upgrade model
    ervs_upgrade = model.getHeatExchangerAirToAirSensibleAndLatents
    refute_equal(ervs_baseline, ervs_upgrade, 'ERVs should change when ERV argument is true')
  end

  # # single building result examples
  # def test_single_building_result_examples
  #   osm_epw_pair = {
  #     '310_PSZ-AC with electric coil.osm' =>
  #       'G2901890.epw'
  #   }

  #   test_name = 'test_single_building_result_examples'

  #   puts "\n######\nTEST:#{test_name}\n######\n"

  #   osm_epw_pair.each_with_index do |(osm_name, epw_name), idx_run|
  #     osm_path = model_input_path(osm_name)
  #     epw_path = epw_input_path(epw_name)

  #     # Create an instance of the measure
  #     measure = UpgradeHvacRtuAdv.new

  #     # Load the model; only used here for populating arguments
  #     model = load_model(osm_path)

  #     # get arguments
  #     arguments = measure.arguments(model)
  #     argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

  #     # populate specific argument for testing
  #     arguments.each_with_index do |arg, idx|
  #       temp_arg_var = arg.clone
  #       case arg.name
  #       when 'hr'
  #         hr = arguments[idx].clone
  #         hr.setValue(false)
  #         argument_map[arg.name] = hr
  #       when 'dcv'
  #         dcv = arguments[idx].clone
  #         dcv.setValue(false)
  #         argument_map[arg.name] = dcv
  #       when 'debug_verbose'
  #         debug_verbose = arguments[idx].clone
  #         debug_verbose.setValue(true)
  #         argument_map[arg.name] = debug_verbose
  #       else
  #         argument_map[arg.name] = temp_arg_var
  #       end
  #     end

  #     # Don't apply the measure to the model and run the model
  #     result = set_weather_and_apply_measure_and_run(
  #       "#{test_name}_#{idx_run}_b",
  #       measure,
  #       argument_map,
  #       osm_path,
  #       epw_path,
  #       run_model: true,
  #       apply: false
  #     )
  #     model = load_model(model_output_path("#{test_name}_#{idx_run}_b"))

  #     # Apply the measure to the model and run the model
  #     result = set_weather_and_apply_measure_and_run(
  #       "#{test_name}_#{idx_run}_u",
  #       measure,
  #       argument_map,
  #       osm_path,
  #       epw_path,
  #       run_model: true,
  #       apply: true
  #     )
  #     model = load_model(model_output_path("#{test_name}_#{idx_run}_u"))
  #   end
  # end

  # ---------------------------------------------------------------------------
  # Fan representation and backup fuel. Both of these were defects measured on
  # this model before the fix; see upgrade_hvac_add_heat_pump_rtu/docs for the
  # matching work on the heat pump RTU measure.
  # ---------------------------------------------------------------------------

  # 90.1-2019 enclosed 4-pole nominal full-load motor efficiencies. A real total fan
  # efficiency must be an impeller efficiency times one of these.
  ASHRAE_MOTOR_EFFICIENCIES_ADV = [0.855, 0.865, 0.895, 0.917, 0.924, 0.93, 0.936,
                                   0.941, 0.95, 0.954, 0.958].freeze

  # The OpenStudio FanVariableVolume default. Seeing this as a FINAL total efficiency
  # means setFanTotalEfficiency was never reached.
  OPENSTUDIO_DEFAULT_FAN_TOTAL_EFF = 0.6045

  # The G*.epw files the rest of this suite references are excluded by .gitignore and
  # are absent from a fresh checkout, so those tests cannot run. This one uses weather
  # that is actually in the repo. It has to be a file whose .ddy carries design days
  # named the way set_weather_and_apply_measure_and_run's filter expects, or that helper
  # strips every design day and its own assertion fails - the NY TMY3 .ddy here contains
  # no design days at all. Los Angeles is the only in-repo option that qualifies without
  # being a climate extreme. Climate does not affect what these tests assert: fan
  # efficiency, part-load coefficients, flow floor and coil fuel are all climate
  # independent.
  def adv_fan_test_paths
    [model_input_path('370_strip_mall_psz_gas_some_erv_4a.osm'),
     epw_input_path('CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw')]
  end

  def adv_apply(test_name, model: nil)
    osm_path, epw_path = adv_fan_test_paths
    measure = UpgradeHvacRtuAdv.new
    src = model || load_model(osm_path)
    arguments = measure.arguments(src)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    wanted = { 'hr' => false, 'dcv' => false, 'debug_verbose' => false }
    arguments.each_with_index do |arg, idx|
      if wanted.key?(arg.name)
        cloned = arguments[idx].clone
        cloned.setValue(wanted[arg.name])
        argument_map[arg.name] = cloned
      else
        argument_map[arg.name] = arg.clone
      end
    end
    set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path,
                                          run_model: false, apply: true, model: src)
    load_model(model_output_path(test_name))
  end

  # Total efficiency must be a real impeller times a real motor, and the motor must
  # come from the 90.1 table rather than being inherited from the fan being replaced.
  #
  # Before the fix, setMotorEfficiency followed by fan_change_motor_efficiency was a
  # no-op - that helper derives the impeller from the fan's current total efficiency,
  # which was still the OpenStudio default - so all 48 supply fans on this model came
  # out at exactly 0.6045 regardless of size.
  def test_fan_efficiency_is_impeller_times_motor
    puts "\n######\nTEST:test_fan_efficiency_is_impeller_times_motor\n######\n"
    applied = adv_apply('test_adv_fan_efficiency')
    fans = applied.getFanVariableVolumes
    refute_empty(fans, 'no variable volume supply fans were created')

    fans.each do |fan|
      label = "adv rtu #{fan.name}"
      total = fan.fanEfficiency
      motor = fan.motorEfficiency

      refute_in_delta(OPENSTUDIO_DEFAULT_FAN_TOTAL_EFF, total, 1e-6,
                      "#{label}: total efficiency is still the OpenStudio default " \
                      "#{OPENSTUDIO_DEFAULT_FAN_TOTAL_EFF}; setFanTotalEfficiency was never reached")
      assert(ASHRAE_MOTOR_EFFICIENCIES_ADV.any? { |m| (m - motor).abs < 1e-6 },
             "#{label}: motor efficiency #{motor} is not a 90.1 table value")

      impeller = total / motor
      assert_in_delta(0.65, impeller, 1e-6,
                      "#{label}: implied impeller #{impeller.round(4)} is not the " \
                      'openstudio-standards 0.65')
    end
  end

  # An efficiency upgrade must not change what the building burns. CoilHeatingGas
  # covers natural gas, propane and fuel oil and defaults to NaturalGas, so a fuel oil
  # building previously came out of this measure with natural gas backup coils.
  def test_backup_coil_matches_original_fuel
    puts "\n######\nTEST:test_backup_coil_matches_original_fuel\n######\n"
    osm_path, = adv_fan_test_paths
    %w[FuelOilNo2 Propane NaturalGas].each do |fuel|
      model = load_model(osm_path)
      coils = model.getCoilHeatingGass
      refute_empty(coils, 'test model has no gas-type heating coils to relabel')
      coils.each { |c| c.setFuelType(fuel) }

      applied = adv_apply("test_adv_backup_fuel_#{fuel}", model: model)
      fuels = applied.getCoilHeatingGass.map(&:fuelType).uniq.sort
      refute_empty(fuels, "no gas-type coil survived for original fuel #{fuel}")
      assert_equal([fuel], fuels,
                   "original fuel #{fuel} produced coils burning #{fuels.join(', ')}; " \
                   'this measure must not switch fuels')
    end
  end

  # Static pressure belongs to the duct system, not the equipment, and the 90.1-2016
  # Appendix G Single Zone VAV curve is the sourced representation for this measure.
  # Guard both against drift, and keep the flow floor at or above the 0.40 it specifies.
  def test_fan_curve_and_pressure_are_unchanged
    puts "\n######\nTEST:test_fan_curve_and_pressure_are_unchanged\n######\n"
    applied = adv_apply('test_adv_fan_curve')
    fans = applied.getFanVariableVolumes
    refute_empty(fans)

    expected = UpgradeHvacRtuAdv::SINGLE_ZONE_VAV_FAN_POWER_COEFFICIENTS
    fans.each do |fan|
      label = "adv rtu #{fan.name}"
      actual = [fan.fanPowerCoefficient1, fan.fanPowerCoefficient2, fan.fanPowerCoefficient3,
                fan.fanPowerCoefficient4, fan.fanPowerCoefficient5].map do |c|
        c.is_a?(Numeric) ? c : (c.respond_to?(:is_initialized) && c.is_initialized ? c.get : 0.0)
      end
      expected.each_with_index do |exp, i|
        assert_in_delta(exp, actual[i], 1e-6, "#{label}: fan power coefficient #{i + 1} drifted")
      end
      # Both RTU measures must keep the same variable-speed representation.
      assert_equal([0.027827882, 0.026583195, -0.0870687, 1.03091975, 0.0], expected,
                   'the 90.1-2016 Appendix G Single Zone VAV coefficients have been changed')
      full = actual.each_with_index.sum { |c, i| c * (1.0**i) }
      assert_in_delta(1.0, full, 0.01,
                      "#{label}: part-load curve returns #{full.round(4)} at full flow, expected 1.0")

      min_flow = fan.fanPowerMinimumFlowFraction
      min_flow = min_flow.get if min_flow.respond_to?(:is_initialized) && min_flow.is_initialized
      assert(min_flow >= 0.40 - 1e-6,
             "#{label}: minimum flow fraction #{min_flow} is below the specified 0.40")
      assert(min_flow <= 1.0 + 1e-6, "#{label}: minimum flow fraction #{min_flow} exceeds 1.0")
      assert(fan.pressureRise > 0, "#{label}: static pressure was not carried over")
    end
  end

  # The new terminal's minimum airflow must be the unit's no-load airflow, and at least the minimum outdoor air.
  # Before the fix the terminal had no minimum (zone minimum air flow fraction 0) and an autosized maximum.
  def test_terminal_minimum_is_the_no_load_airflow
    puts "\n######\nTEST:test_terminal_minimum_is_the_no_load_airflow\n######\n"
    applied = adv_apply('test_adv_terminal_minimum')
    assert_terminal_minimum_is_no_load_airflow(applied, 'test_adv_terminal_minimum')
  end

  # The unit's no-load airflow must reach EnergyPlus through the multispeed performance object's no-load ratio.
  # Before the fix no object was assigned, OpenStudio wrote one with a blank ratio, and the fan ran at full airflow
  # whenever there was no load.
  def test_no_load_airflow_ratio_is_set
    puts "\n######\nTEST:test_no_load_airflow_ratio_is_set\n######\n"
    applied = adv_apply('test_adv_no_load_ratio')
    assert_no_load_airflow_ratio(applied, 'test_adv_no_load_ratio')
  end

  # The cooling part-load fraction curve of upgrade_hvac_add_heat_pump_rtu (cool_plf_plr1), read from each of its
  # performance files: [coefficient 1, coefficient 2, coefficient 3, minimum output], which must be the same in all.
  def heat_pump_rtu_cooling_plf_curve
    files = Dir[File.join(File.dirname(__FILE__), '../../upgrade_hvac_add_heat_pump_rtu/resources/*.json')]
    refute_empty(files, 'no performance files of upgrade_hvac_add_heat_pump_rtu found')
    curves = files.map do |file|
      tables = JSON.parse(File.read(file)).dig('tables', 'curves', 'table')
      curve = tables.find { |table| table['name'] == 'cool_plf_plr1' }
      refute_nil(curve, "#{File.basename(file)}: no cool_plf_plr1 curve")
      assert_equal('Quadratic', curve['form'], "#{File.basename(file)}: cool_plf_plr1 is not a quadratic curve")
      [curve['coeff_1'].to_f, curve['coeff_2'].to_f, curve['coeff_3'].to_f, curve['minimum_dependent_variable_output'].to_f]
    end
    assert_equal(1, curves.uniq.size, 'the performance files of upgrade_hvac_add_heat_pump_rtu differ in cool_plf_plr1')
    curves.first
  end

  # Cycling losses and latent degradation of the cooling coil.
  # The stages represent a variable-speed compressor, which modulates between two stages and cycles only below the
  # lowest one: the part-load fraction curve must not apply above the lowest stage. Applied there, it added 9% to the
  # coil's electricity in the records above the lowest stage of an annual test run.
  # Below the lowest stage the part-load fraction curve must be the one upgrade_hvac_add_heat_pump_rtu uses (0.75 +
  # 0.25 x part-load ratio, not below 0.7), one curve object for every unit. The fit of normalized power against
  # part-load ratio used before was held at 0.7 by EnergyPlus and charged 43% more electricity than the load fraction.
  # EnergyPlus' latent degradation model (moisture evaporating from the coil while the compressor is off and the fan
  # runs) must be off at every cooling stage, as it is for the coils of the units this one replaces and of
  # upgrade_hvac_add_heat_pump_rtu. EnergyPlus applies the model only when all four inputs are above 0; the stage
  # data's defaults are 0. Modeled for this unit alone it lowered the compressor's electricity by up to 5% in test
  # buildings and the moisture removed by 4% to 35%.
  def test_cycling_losses_below_the_lowest_stage_only_and_no_latent_degradation
    puts "\n######\nTEST:test_cycling_losses_below_the_lowest_stage_only_and_no_latent_degradation\n######\n"
    applied = adv_apply('test_adv_latent_inputs')
    rtus = adv_rtus(applied)
    refute_empty(rtus, 'no advanced RTUs to check')
    expected_plf = heat_pump_rtu_cooling_plf_curve
    assert_equal([0.75, 0.25, 0.0, 0.7], expected_plf, 'the heat pump RTU cooling part-load fraction curve changed')
    plf_curves = []
    rtus.each do |us|
      coil = us.coolingCoil.get.to_CoilCoolingDXMultiSpeed.get
      refute(coil.applyPartLoadFractiontoSpeedsGreaterthan1, "#{us.name}: cycling losses apply above the lowest stage")
      refute(coil.applyLatentDegradationtoSpeedsGreaterthan1, "#{us.name}: latent degradation applies above the lowest stage")
      coil.stages.each_with_index do |stage, i|
        label = "#{us.name} cooling stage #{i + 1}"
        plf = stage.partLoadFractionCorrelationCurve.to_CurveQuadratic
        assert(plf.is_initialized, "#{label}: the part-load fraction curve is not a quadratic curve")
        plf = plf.get
        plf_curves << plf.handle.to_s
        assert_in_delta(expected_plf[0], plf.coefficient1Constant, 1e-9, "#{label}: part-load fraction curve constant")
        assert_in_delta(expected_plf[1], plf.coefficient2x, 1e-9, "#{label}: part-load fraction curve slope")
        assert_in_delta(expected_plf[2], plf.coefficient3xPOW2, 1e-9, "#{label}: part-load fraction curve quadratic term")
        assert_in_delta(expected_plf[3], optional_value(plf.minimumCurveOutput), 1e-9, "#{label}: part-load fraction curve minimum output")
        assert_in_delta(1.0, plf.evaluate(1.0), 1e-9, "#{label}: part-load fraction at full load")
        assert_in_delta(0.0, stage.nominalTimeforCondensateRemovaltoBegin, 1e-9, "#{label}: nominal time for condensate removal to begin")
        assert_in_delta(0.0, stage.ratioofInitialMoistureEvaporationRateandSteadyStateLatentCapacity, 1e-9, "#{label}: initial moisture evaporation ratio")
        assert_in_delta(0.0, stage.maximumCyclingRate, 1e-9, "#{label}: maximum cycling rate")
        assert_in_delta(0.0, stage.latentCapacityTimeConstant, 1e-9, "#{label}: latent capacity time constant")
      end
    end
    assert_equal(1, plf_curves.uniq.size, 'the units do not share one part-load fraction curve')
    assert_equal(1, applied.getCurveQuadratics.count { |curve| curve.name.to_s == UpgradeHvacRtuAdv::COOLING_PLF_CURVE_NAME },
                 'the part-load fraction curve was created more than once')
    assert_empty(applied.getCurveLinears.select { |curve| curve.name.to_s.end_with?('_plr') },
                 'the normalized power fits are still created in the model')
  end

  # Every cooling stage of every unit must move at least the unit's minimum airflow, with its sensible heat ratio set
  # from its airflow per capacity (see assert_cooling_stages_respect_minimum_airflow).
  def test_cooling_stages_respect_minimum_airflow
    puts "\n######\nTEST:test_cooling_stages_respect_minimum_airflow\n######\n"
    applied = adv_apply('test_adv_stage_airflow')
    rtus = adv_rtus(applied)
    refute_empty(rtus, 'no advanced RTUs to check')
    rtus.each { |us| assert_cooling_stages_respect_minimum_airflow(us) }
  end

  # Annual simulation: the outdoor air controller must see airflow whenever the supply fan runs, and the fan must sit
  # at the no-load airflow while the zone has no load.
  # The model is one zone with no zone exhaust fan, which the outdoor air defect needs: a model with an exhaust fan
  # anywhere keeps its outdoor air whatever the terminal minimum is. The weather is the in-repo Los Angeles file, where
  # the zone spends much of the year with no load.
  def test_outdoor_air_controller_sees_fan_airflow
    test_name = 'test_adv_outdoor_air_delivered'
    puts "\n######\nTEST:#{test_name}\n######\n"
    osm_path = model_input_path('310_PSZ-AC with electric coil.osm')
    epw_path = epw_input_path('CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw')
    measure = UpgradeHvacRtuAdv.new
    model = load_model(osm_path)
    assert_empty(model.getFanZoneExhausts, 'this check needs a model with no zone exhaust fan')

    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    wanted = { 'hr' => false, 'dcv' => false, 'debug_verbose' => false }
    arguments.each do |arg|
      cloned = arg.clone
      cloned.setValue(wanted[arg.name]) if wanted.key?(arg.name)
      argument_map[arg.name] = cloned
    end
    set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path,
                                          run_model: true, apply: true)
    applied = load_model(model_output_path(test_name))
    assert_oa_controller_sees_fan_airflow(applied, test_name)
    assert_fan_at_no_load_airflow_without_load(applied, test_name)
    assert_fan_at_least_minimum_airflow_while_cooling(applied, test_name)
  end

  # Annual simulation of a unit whose minimum outdoor air is 90% of its design airflow. At that airflow the low stage
  # would be far above 450 cfm/ton, so it is removed and the unit has two stages, the lower one at the minimum
  # airflow. The outdoor air controller must see airflow whenever the fan runs and the fan must not drop below the
  # minimum airflow while the unit cools.
  def test_high_outdoor_air_unit_drops_the_low_stage
    test_name = 'test_adv_high_outdoor_air'
    puts "\n######\nTEST:#{test_name}\n######\n"
    osm_path = model_input_path('310_PSZ-AC with electric coil.osm')
    epw_path = epw_input_path('CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw')
    measure = UpgradeHvacRtuAdv.new
    model = load_model(osm_path)
    assert_empty(model.getFanZoneExhausts, 'this check needs a model with no zone exhaust fan')

    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    wanted = { 'hr' => false, 'dcv' => false, 'debug_verbose' => false }
    arguments.each do |arg|
      cloned = arg.clone
      cloned.setValue(wanted[arg.name]) if wanted.key?(arg.name)
      argument_map[arg.name] = cloned
    end

    # hard-size the model as the workflow does before an upgrade, then raise each unit's minimum outdoor air
    set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path,
                                          run_model: false, apply: false)
    model = _mimic_hardsize_model(load_model(model_output_path(test_name)), "#{run_dir(test_name)}/SR_before")
    model.getAirLoopHVACs.each do |air_loop_hvac|
      controller_oa = air_loop_hvac.airLoopHVACOutdoorAirSystem.get.getControllerOutdoorAir
      controller_oa.setMinimumOutdoorAirFlowRate(0.9 * air_loop_hvac.designSupplyAirFlowRate.get)
    end

    set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path,
                                          run_model: true, apply: true, model: model)
    # the model as it was simulated: the model saved after the run has each stage's airflow and capacity replaced by
    # EnergyPlus' own design sizes
    applied = load_model("#{run_dir(test_name)}/in.osm")
    rtus = adv_rtus(applied)
    refute_empty(rtus, "#{test_name}: no advanced RTUs to check")
    rtus.each do |us|
      stages = us.coolingCoil.get.to_CoilCoolingDXMultiSpeed.get.stages
      assert_equal(2, stages.size, "#{us.name}: the low stage was not removed at a minimum airflow of 0.9")
      assert_in_delta(0.9, optional_value(us.supplyFan.get.to_FanVariableVolume.get.fanPowerMinimumFlowFraction), 1e-3,
                      "#{us.name}: the unit's minimum airflow ratio is not the outdoor air share")
      assert_cooling_stages_respect_minimum_airflow(us)
    end
    assert_no_load_airflow_ratio(applied, test_name)
    assert_oa_controller_sees_fan_airflow(applied, test_name)
    assert_fan_at_least_minimum_airflow_while_cooling(applied, test_name)
  end
end
