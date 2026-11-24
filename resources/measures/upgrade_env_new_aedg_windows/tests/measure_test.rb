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

class EnvNewAedgWindowsTest < Minitest::Test
  # return file paths to test models in test directory
  def models_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/models/*.osm'))
    paths = paths.map { |path| File.expand_path(path) }
    return paths
  end

  # return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/weather/*.epw'))
    paths = paths.map { |path| File.expand_path(path) }
    return paths
  end

  def load_model(osm_path)
    translator = OpenStudio::OSVersion::VersionTranslator.new
    model = translator.loadModel(OpenStudio::Path.new(osm_path))
    assert(!model.empty?)
    model = model.get
    return model
  end

  def run_dir(test_name)
    # always generate test output in specially named 'output' directory so result files are not made part of the measure
    return "#{File.dirname(__FILE__)}/output/#{test_name}"
  end

  def model_input_path(osm_name)
    # return models_for_tests.select { |x| set[:model] == osm_name }
    return File.join(File.dirname(__FILE__), '../../../tests/models', osm_name)
  end

  def epw_input_path(epw_name)
    return File.join(File.dirname(__FILE__), '../../../tests/weather', epw_name)
  end

  def model_output_path(test_name)
    return "#{run_dir(test_name)}/#{test_name}.osm"
  end

  def sql_path(test_name)
    return "#{run_dir(test_name)}/run/eplusout.sql"
  end

  def report_path(test_name)
    return "#{run_dir(test_name)}/reports/eplustbl.html"
  end

  # applies the measure and then runs the model
  def apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false, model: nil)
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
    if model.nil?
      model = load_model(new_osm_path)
    end

    # set model weather file
    epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(new_epw_path))
    OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
    assert(model.weatherFile.is_initialized)

    # run the measure
    puts "\nAPPLYING MEASURE..."
    measure.run(model, runner, argument_map)
    result = runner.result
    result_success = result.value.valueName == 'Success'

    # Show the output
    show_output(result)

    # Save model
    model.save(model_output_path(test_name), true)

    if run_model && result_success
      puts "\nRUNNING MODEL..."

      std = Standard.build('90.1-2013')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))

      # Check that the model ran successfully
      assert(File.exist?(sql_path(test_name)))
    end

    # change back directory
    Dir.chdir(start_dir)

    return result
  end

  def test_number_of_arguments_and_argument_names
    # This test ensures that the current test is matched to the measure inputs
    # Create an instance of the measure
    measure = EnvNewAedgWindows.new

    # Make an empty model
    model = OpenStudio::Model::Model.new

    # Get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(0, arguments.size)
  end

  def test_r_value_cz_3a_single_pane
    osm_name = 'Small_Office_CEC8.osm'
    epw_name = 'USA_CA_Fullerton.Muni.AP.722976_TMY3.epw'

    # Test expectations for Single - No LowE - Clear - Wood in 3A
    # is to increase to U-0.37
    target_u_value_ip = 0.37

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = EnvNewAedgWindows.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure::OSArgumentMap.new

    # Check that the starting R-value is less than the target
    old_u_val_ip = 0
    old_ext_surf_material = nil
    model.getSubSurfaces.each do |sub_surface|
      next unless (sub_surface.outsideBoundaryCondition == 'Outdoors') && sub_surface.subSurfaceType.include?('Window')

      surf_const = sub_surface.construction.get.to_LayeredConstruction.get
      glazing_layer = surf_const.layers[0].to_SimpleGlazing.get
      old_u_val_si = glazing_layer.uFactor
      old_u_val_ip = OpenStudio.convert(old_u_val_si, 'W/m^2*K', 'Btu/ft^2*h*R').get

      break
    end
    assert(old_u_val_ip > target_u_value_ip)

    # Apply the measure to the model and optionally run the model
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false)

    model = load_model(model_output_path(__method__))
    model.getSubSurfaces.each do |sub_surface|
      next unless (sub_surface.outsideBoundaryCondition == 'Outdoors') && sub_surface.subSurfaceType.include?('Window')

      surf_const = sub_surface.construction.get.to_LayeredConstruction.get
      glazing_layer = surf_const.layers[0].to_SimpleGlazing.get
      new_u_val_si = glazing_layer.uFactor
      new_u_val_ip = OpenStudio.convert(new_u_val_si, 'W/m^2*K', 'Btu/ft^2*h*R').get

      # Check that original U-value was above (worse than) the target threshold
      assert(old_u_val_ip > new_u_val_ip)

      # Check that the new U-value matches the target
      tolerance = 0.01
      assert_in_delta(target_u_value_ip, new_u_val_ip, tolerance)

      break
    end
  end

  def test_r_value_cz_3a_double_pane
    osm_name = 'Quick_Service_Restaurant_Pre1980_3A.osm'
    epw_name = 'USA_CA_Fullerton.Muni.AP.722976_TMY3.epw'

    # Test expectations for Double - LowE - Clear - Aluminum in 3A
    # is to increase to U-0.50
    target_u_value_ip = 0.50

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = EnvNewAedgWindows.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure::OSArgumentMap.new

    # Check that the starting R-value is less than the target
    old_u_val_ip = 0
    old_ext_surf_material = nil
    model.getSubSurfaces.each do |sub_surface|
      next unless (sub_surface.outsideBoundaryCondition == 'Outdoors') && sub_surface.subSurfaceType.include?('Window')

      surf_const = sub_surface.construction.get.to_LayeredConstruction.get
      glazing_layer = surf_const.layers[0].to_SimpleGlazing.get
      old_u_val_si = glazing_layer.uFactor
      old_u_val_ip = OpenStudio.convert(old_u_val_si, 'W/m^2*K', 'Btu/ft^2*h*R').get

      break
    end
    assert(old_u_val_ip > target_u_value_ip)

    # Apply the measure to the model and optionally run the model
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false)

    model = load_model(model_output_path(__method__))
    model.getSubSurfaces.each do |sub_surface|
      next unless (sub_surface.outsideBoundaryCondition == 'Outdoors') && sub_surface.subSurfaceType.include?('Window')

      surf_const = sub_surface.construction.get.to_LayeredConstruction.get
      glazing_layer = surf_const.layers[0].to_SimpleGlazing.get
      new_u_val_si = glazing_layer.uFactor
      new_u_val_ip = OpenStudio.convert(new_u_val_si, 'W/m^2*K', 'Btu/ft^2*h*R').get

      # Check that original U-value was above (worse than) the target threshold
      assert(old_u_val_ip > new_u_val_ip)

      # Check that the new U-value matches the target
      tolerance = 0.01
      assert_in_delta(target_u_value_ip, new_u_val_ip, tolerance)

      break
    end
  end

  def test_r_value_cz_5a
    osm_name = 'SecondarySchool_Pre1980_5A.osm'
    epw_name = 'USA_CA_Fullerton.Muni.AP.722976_TMY3.epw'

    # Test expectations for Double - No LowE - Clear - Aluminum
    # is to increase to 0.61 in all climate zones
    target_u_value_ip = 0.61

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = EnvNewAedgWindows.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure::OSArgumentMap.new

    # Check that the starting R-value is less than the target
    old_u_val_ip = 0
    old_ext_surf_material = nil
    model.getSubSurfaces.each do |sub_surface|
      next unless (sub_surface.outsideBoundaryCondition == 'Outdoors') && sub_surface.subSurfaceType.include?('Window')

      surf_const = sub_surface.construction.get.to_LayeredConstruction.get
      glazing_layer = surf_const.layers[0].to_SimpleGlazing.get
      old_u_val_si = glazing_layer.uFactor
      old_u_val_ip = OpenStudio.convert(old_u_val_si, 'W/m^2*K', 'Btu/ft^2*h*R').get

      break
    end
    assert(old_u_val_ip > target_u_value_ip)

    # Apply the measure to the model and optionally run the model
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false)

    model = load_model(model_output_path(__method__))
    model.getSubSurfaces.each do |sub_surface|
      next unless (sub_surface.outsideBoundaryCondition == 'Outdoors') && sub_surface.subSurfaceType.include?('Window')

      surf_const = sub_surface.construction.get.to_LayeredConstruction.get
      glazing_layer = surf_const.layers[0].to_SimpleGlazing.get
      new_u_val_si = glazing_layer.uFactor
      new_u_val_ip = OpenStudio.convert(new_u_val_si, 'W/m^2*K', 'Btu/ft^2*h*R').get

      # Check that original U-value was above (worse than) the target threshold
      assert(old_u_val_ip > new_u_val_ip)

      # Check that the new U-value matches the target
      tolerance = 0.01
      assert_in_delta(target_u_value_ip, new_u_val_ip, tolerance)

      break
    end
  end

  def test_r_value_cz_8a_double_pane_thermally_broken
    osm_name = 'Stripmall_Pre1980_8A.osm'
    epw_name = 'USA_CA_Fullerton.Muni.AP.722976_TMY3.epw'

    # Test expectations for Double - No LowE - Clear - Aluminum
    # is to increase to U-0.44 in CZ 8
    target_u_value_ip = 0.44

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = EnvNewAedgWindows.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure::OSArgumentMap.new

    # Check that the starting R-value is less than the target
    old_u_val_ip = 0
    old_ext_surf_material = nil
    model.getSubSurfaces.each do |sub_surface|
      next unless (sub_surface.outsideBoundaryCondition == 'Outdoors') && sub_surface.subSurfaceType.include?('Window')

      surf_const = sub_surface.construction.get.to_LayeredConstruction.get
      glazing_layer = surf_const.layers[0].to_SimpleGlazing.get
      old_u_val_si = glazing_layer.uFactor
      old_u_val_ip = OpenStudio.convert(old_u_val_si, 'W/m^2*K', 'Btu/ft^2*h*R').get

      break
    end
    assert(old_u_val_ip > target_u_value_ip)

    # Apply the measure to the model and optionally run the model
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false)

    model = load_model(model_output_path(__method__))
    model.getSubSurfaces.each do |sub_surface|
      next unless (sub_surface.outsideBoundaryCondition == 'Outdoors') && sub_surface.subSurfaceType.include?('Window')

      surf_const = sub_surface.construction.get.to_LayeredConstruction.get
      glazing_layer = surf_const.layers[0].to_SimpleGlazing.get
      new_u_val_si = glazing_layer.uFactor
      new_u_val_ip = OpenStudio.convert(new_u_val_si, 'W/m^2*K', 'Btu/ft^2*h*R').get

      # Check that original U-value was above (worse than) the target threshold
      assert(old_u_val_ip > new_u_val_ip)

      # Check that the new U-value matches the target
      tolerance = 0.01
      assert_in_delta(target_u_value_ip, new_u_val_ip, tolerance)

      break
    end
  end

  def test_r_value_cz_cec16_double_pane_thermally_broken
    osm_name = 'Retail_DEERPre1975_CEC16.osm'
    epw_name = 'USA_CA_Fullerton.Muni.AP.722976_TMY3.epw'

    # Test expectations for Single - No LowE - Clear - Aluminum
    # is to increase to U-0.61 in all climate zones
    target_u_value_ip = 0.61

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = EnvNewAedgWindows.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure::OSArgumentMap.new

    # Check that the starting R-value is less than the target
    old_u_val_ip = 0
    old_ext_surf_material = nil
    model.getSubSurfaces.each do |sub_surface|
      next unless (sub_surface.outsideBoundaryCondition == 'Outdoors') && sub_surface.subSurfaceType.include?('Window')

      surf_const = sub_surface.construction.get.to_LayeredConstruction.get
      glazing_layer = surf_const.layers[0].to_SimpleGlazing.get
      old_u_val_si = glazing_layer.uFactor
      old_u_val_ip = OpenStudio.convert(old_u_val_si, 'W/m^2*K', 'Btu/ft^2*h*R').get

      break
    end
    assert(old_u_val_ip > target_u_value_ip)

    # Apply the measure to the model and optionally run the model
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false)

    model = load_model(model_output_path(__method__))
    model.getSubSurfaces.each do |sub_surface|
      next unless (sub_surface.outsideBoundaryCondition == 'Outdoors') && sub_surface.subSurfaceType.include?('Window')

      surf_const = sub_surface.construction.get.to_LayeredConstruction.get
      glazing_layer = surf_const.layers[0].to_SimpleGlazing.get
      new_u_val_si = glazing_layer.uFactor
      new_u_val_ip = OpenStudio.convert(new_u_val_si, 'W/m^2*K', 'Btu/ft^2*h*R').get

      # Check that original U-value was above (worse than) the target threshold
      assert(old_u_val_ip > new_u_val_ip)

      # Check that the new U-value matches the target
      # Set the tolerance higher for this test because the
      # Single - No LowE - Clear - Aluminum
      tolerance = 0.01
      assert_in_delta(target_u_value_ip, new_u_val_ip, tolerance)

      break
    end
  end

  def test_na_simple_glazing_name_not_recognized
    osm_name = 'Warehouse_5A.osm'
    epw_name = 'MI_DETROIT_725375_12.epw'

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = EnvNewAedgWindows.new

    # Load the model for populating arguments
    model = load_model(osm_path)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure::OSArgumentMap.new

    # Apply the measure to the model and optionally run the model
    result = apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path, run_model: false)

    # Should be NA because this is a warehouse with metal building walls
    assert_equal('NA', result.value.valueName)
  end
end
