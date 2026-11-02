# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'fileutils'
require 'minitest/autorun'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require_relative '../measure'

class SetRoofTemplateTest < Minitest::Test
  # return file paths to test models in test directory
  def models_for_tests
    paths = Dir.glob(File.join(__dir__, '../../../tests/models/*.osm'))
    paths = paths.map { |path| File.expand_path(path) }
    return paths
  end

  # return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(__dir__, '../../../tests/weather/*.epw'))
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
    return "#{__dir__}/output/#{test_name}"
  end

  def model_output_path(test_name)
    return "#{run_dir(test_name)}/out.osm"
  end

  def sql_path(test_name)
    return "#{run_dir(test_name)}/run/eplusout.sql"
  end

  def report_path(test_name)
    return "#{run_dir(test_name)}/reports/eplustbl.html"
  end

  # applies the measure and then runs the model
  def apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false)
    assert(File.exist?(osm_path))
    assert(File.exist?(epw_path))

    # remove prior runs if they exist
    FileUtils.rm_f(model_output_path(test_name))
    FileUtils.rm_f(sql_path(test_name))
    FileUtils.rm_f(report_path(test_name))

    # create run directory if it does not exist
    FileUtils.mkdir_p(run_dir(test_name))

    # create an instance of a runner with OSW
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

    # load the test model
    model = load_model(osm_path)

    # set model weather file
    epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(epw_path))
    OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
    assert(model.weatherFile.is_initialized)

    # temporarily change directory to the run directory and run the measure
    # only necessary for measures that do a sizing run
    start_dir = Dir.pwd
    begin
      Dir.chdir(run_dir(test_name))

      # run the measure
      puts "\nAPPLYING MEASURE..."
      measure.run(model, runner, argument_map)
      result = runner.result
    ensure
      Dir.chdir(start_dir)
    end

    # show the output
    show_output(result)

    # save model
    model.save(model_output_path(test_name), true)

    if run_model && (result.value.valueName == 'Success')
      puts "\nRUNNING MODEL..."

      std = Standard.build('ComStock DEER 2020')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))

      # check that the model ran successfully
      assert(File.exist?(sql_path(test_name)))
    end

    return result
  end

  # A small hotel's construction set carries an attic floor as its roof, and create_typical
  # hard-assigns an IEAD roof to the outdoor-facing roof surfaces instead. The measure used to
  # read the attic floor's WoodFramed type and ask the new template for a WoodFramed exterior
  # roof, which no template has; 16 small hotels in the 2026-09 100k run failed that way.
  def test_attic_floor_default_roof_is_replaced_on_the_hard_assigned_roof_surfaces
    puts "\n######\nTEST:#{__method__}\n######\n"
    model = OpenStudio::Model::Model.new
    model.getBuilding.setStandardsBuildingType('SmallHotel')
    polygon = OpenStudio::Point3dVector.new
    [[0.0, 0.0], [0.0, 10.0], [20.0, 10.0], [20.0, 0.0]].each { |x, y| polygon << OpenStudio::Point3d.new(x, y, 0.0) }
    space = OpenStudio::Model::Space.fromFloorPrint(polygon, 3.0, model).get
    roofs = space.surfaces.select { |s| s.surfaceType == 'RoofCeiling' }
    assert_equal(1, roofs.size)

    attic_floor = OpenStudio::Model::Construction.new(model)
    attic_floor.setName('Typical Wood Joist Attic Floor')
    attic_floor.insertLayer(0, OpenStudio::Model::MasslessOpaqueMaterial.new(model, 'Rough', 2.0))
    attic_floor.standardsInformation.setIntendedSurfaceType('AtticFloor')
    attic_floor.standardsInformation.setStandardsConstructionType('WoodFramed')
    old_roof = OpenStudio::Model::Construction.new(model)
    old_roof.setName('Old IEAD Roof')
    old_roof.insertLayer(0, OpenStudio::Model::MasslessOpaqueMaterial.new(model, 'Rough', 1.0))
    old_roof.standardsInformation.setIntendedSurfaceType('ExteriorRoof')
    old_roof.standardsInformation.setStandardsConstructionType('IEAD')
    roofs.first.setConstruction(old_roof)

    ext_consts = OpenStudio::Model::DefaultSurfaceConstructions.new(model)
    ext_consts.setRoofCeilingConstruction(attic_floor)
    const_set = OpenStudio::Model::DefaultConstructionSet.new(model)
    const_set.setDefaultExteriorSurfaceConstructions(ext_consts)
    model.getBuilding.setDefaultConstructionSet(const_set)

    measure = SetRoofTemplate.new
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)
    { 'as_constructed_template' => 'ComStock DOE Ref Pre-1980', 'template' => 'ComStock DOE Ref 1980-2004', 'climate_zone' => 'ASHRAE 169-2013-6A' }.each do |name, value|
      arg = arguments.find { |a| a.name == name }.clone
      assert(arg.setValue(value))
      argument_map[name] = arg
    end
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    measure.run(model, runner, argument_map)
    result = runner.result
    show_output(result)
    assert_equal('Success', result.value.valueName)

    new_roof = ext_consts.roofCeilingConstruction.get
    refute_equal(attic_floor.handle, new_roof.handle, 'the default set still points at the attic floor')
    assert_equal('ExteriorRoof', new_roof.standardsInformation.intendedSurfaceType.get)
    assert_equal('IEAD', new_roof.standardsInformation.standardsConstructionType.get)
    assert_equal(new_roof.handle, roofs.first.construction.get.handle, 'the hard-assigned roof surface did not get the new construction')
    refute_equal(old_roof.handle, roofs.first.construction.get.handle)
  end

  def test_number_of_arguments_and_argument_names
    # this test ensures that the current test is matched to the measure inputs
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = SetRoofTemplate.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(3, arguments.size)
    assert_equal('as_constructed_template', arguments[0].name)
    assert_equal('template', arguments[1].name)
    assert_equal('climate_zone', arguments[2].name)
  end

  # create an array of hashes with model name, weather, and expected result
  def models_to_test
    test_sets = []

    test_sets << {
      model: 'Small_Office_CEC8',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'NA',
      arg_hash: { 'as_constructed_template' => 'DOE Ref 1980-2004', 'template' => 'DOE Ref 1980-2004', 'climate_zone' => 'ASHRAE 169-2013-7A' }
    }

    test_sets << {
      model: 'Small_Office_CEC8',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16',
      result: 'Success',
      arg_hash: { 'as_constructed_template' => 'DOE Ref 1980-2004', 'template' => 'ComStock 90.1-2019', 'climate_zone' => 'ASHRAE 169-2013-7A' }
    }

    return test_sets
  end

  def test_models
    puts "\n######\nTEST:#{__method__}\n######\n"

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
      measure = SetRoofTemplate.new

      # load the model; only used here for populating arguments
      model = load_model(osm_path)

      # set arguments here; will vary by measure
      arguments = measure.arguments(model)
      argument_map = OpenStudio::Measure::OSArgumentMap.new

      # populate argument with specified hash value if specified
      arguments.each do |arg|
        temp_arg_var = arg.clone
        if !set[:arg_hash].nil? && set[:arg_hash].key?(arg.name)
          assert(temp_arg_var.setValue(set[:arg_hash][arg.name]))
        end
        argument_map[arg.name] = temp_arg_var
      end

      # apply the measure to the model and optionally run the model
      result = apply_measure_and_run(instance_test_name, measure, argument_map, osm_path, epw_path, run_model: false)

      # check the measure result; result values will equal Success, Fail, or Not Applicable
      # also check the amount of warnings, info, and error messages
      # use if or case statements to change expected assertion depending on model characteristics
      assert(result.value.valueName == set[:result])

      # to check that something changed in the model, load the model and the check the objects match expected new value
      model = load_model(model_output_path(instance_test_name))
    end
  end
end
