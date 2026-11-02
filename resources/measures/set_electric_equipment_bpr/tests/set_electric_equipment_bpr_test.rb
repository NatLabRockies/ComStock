# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'fileutils'
require 'minitest/autorun'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'comstock-typical'
require_relative '../measure'

class SetElectricEquipmentBPRTest < Minitest::Test
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
      reset_log
      measure.run(model, runner, argument_map)
      result = runner.result

      # log messages
      log_messages_to_file("#{run_dir(test_name)}/measure.log", false)
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

  def test_number_of_arguments_and_argument_names
    # this test ensures that the current test is matched to the measure inputs
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = SetElectricEquipmentBPR.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(4, arguments.size)
    assert_equal('modify_wkdy_bpr', arguments[0].name)
    assert_equal('wkdy_bpr', arguments[1].name)
    assert_equal('modify_wknd_bpr', arguments[2].name)
    assert_equal('wknd_bpr', arguments[3].name)
  end

  # create an array of hashes with model name, weather, and expected result
  def models_to_test
    test_sets = []

    test_sets << {
      model: 'Small_Office_2A',
      weather: 'MI_DETROIT_725375_12',
      result: 'NA'
    }

    test_sets << {
      model: 'Warehouse_5A',
      weather: 'MI_DETROIT_725375_12',
      result: 'Success',
      expected_hrly_vals: [[4, 0.0], [10, 1], [16, 1], [23, 0.0]],
      expected_hrly_vals2: [[4, 0.9], [10, 0.9], [16, 0.9], [23, 0.9]],
      equip_sch_name: 'Warehouse Bldg Equip BPR Adjusted'
    }

    test_sets << {
      model: 'Retail_7',
      weather: 'MI_DETROIT_725375_12',
      result: 'Success',
      expected_hrly_vals: [[2, 0.0], [10, 0.9], [17, 0.9], [23, 0.45]],
      expected_hrly_vals2: [[2, 0.81], [10, 0.9], [23, 0.855]],
      equip_sch_name: 'Retail Bldg Equip BPR Adjusted'
    }

    test_sets << {
      model: 'Full_Service_Restaurant_4A',
      weather: 'MI_DETROIT_725375_12',
      result: 'Success',
      expected_hrly_vals: [[4, 0.0], [6, 0.105], [11, 0.35], [23, 0.1575]],
      expected_hrly_vals2: [[4, 0.315], [8, 0.35], [11, 0.35], [23, 0.33075]],
      equip_sch_name: 'Full Service Restaurant Bldg Equip BPR Adjusted'
    }

    test_sets << {
      model: 'Restaurant_5B',
      weather: 'MI_DETROIT_725375_12',
      result: 'Success',
      expected_hrly_vals: [[4, 0.0], [6, 0.0], [11, 0.35], [23, 0.2125]],
      expected_hrly_vals2: [[4, 0.315], [8, 0.35], [11, 0.35], [23, 0.315]],
      equip_sch_name: 'FullServiceRestaurant Bldg Equip BPR Adjusted'
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
      measure = SetElectricEquipmentBPR.new

      # load the model; only used here for populating arguments
      model = load_model(osm_path)

      # set arguments here; will vary by measure
      arguments = measure.arguments(model)
      argument_map = OpenStudio::Measure::OSArgumentMap.new

      if set[:model] == 'Small_Office_2A'
        modify_wkdy_bpr = arguments[0].clone
        wkdy_bpr = arguments[1].clone
        modify_wknd_bpr = arguments[2].clone
        wknd_bpr = arguments[3].clone
        assert(modify_wkdy_bpr.setValue(false))
        assert(wkdy_bpr.setValue(0.0))
        assert(modify_wknd_bpr.setValue(false))
        assert(wknd_bpr.setValue(0.0))
        argument_map['modify_wkdy_bpr'] = modify_wkdy_bpr
        argument_map['wkdy_bpr'] = wkdy_bpr
        argument_map['modify_wknd_bpr'] = modify_wknd_bpr
        argument_map['wknd_bpr'] = wknd_bpr
        # apply the measure to the model and optionally run the model
        result = apply_measure_and_run(instance_test_name, measure, argument_map, osm_path, epw_path, run_model: false)
        # check the measure result; result values will equal Success, Fail, or Not Applicable
        assert(result.value.valueName == set[:result])
      else
        modify_wkdy_bpr = arguments[0].clone
        wkdy_bpr = arguments[1].clone
        modify_wknd_bpr = arguments[2].clone
        wknd_bpr = arguments[3].clone
        assert(modify_wkdy_bpr.setValue(true))
        assert(wkdy_bpr.setValue(0.0))
        assert(modify_wknd_bpr.setValue(true))
        assert(wknd_bpr.setValue(0.0))
        argument_map['modify_wkdy_bpr'] = modify_wkdy_bpr
        argument_map['wkdy_bpr'] = wkdy_bpr
        argument_map['modify_wknd_bpr'] = modify_wknd_bpr
        argument_map['wknd_bpr'] = wknd_bpr

        # apply the measure to the model and optionally run the model
        result = apply_measure_and_run(instance_test_name, measure, argument_map, osm_path, epw_path, run_model: false)

        # check the measure result; result values will equal Success, Fail, or Not Applicable
        # also check the amount of warnings, info, and error messages
        # use if or case statements to change expected assertion depending on model characteristics
        model = load_model(model_output_path(instance_test_name))
        model.getSpaceTypes.each do |space_type|
          space_type.electricEquipment.each do |equip|
            if equip.schedule.is_initialized
              equip_sch = equip.schedule.get
              case equip_sch.name.get.to_s
              when set[:equip_sch_name]
                equip_sch = equip_sch.to_ScheduleRuleset.get
                equip_sch.defaultDaySchedule.setInterpolatetoTimestep('No')
                expected_hrly_vals = set[:expected_hrly_vals]
                expected_hrly_vals.each do |hr, val|
                  time = OpenStudio::Time.new(0, hr)
                  assert_equal(val, equip_sch.defaultDaySchedule.getValue(time))
                end
              end
            end
          end
        end
        assert(result.value.valueName == set[:result])
      end

      # Test changes to the model inputs
      if !set[:model] == 'Small_Office_2A'
        modify_wkdy_bpr = arguments[0].clone
        wkdy_bpr = arguments[1].clone
        modify_wknd_bpr = arguments[2].clone
        wknd_bpr = arguments[3].clone
        assert(modify_wkdy_bpr.setValue(true))
        assert(wkdy_bpr.setValue(0.9))
        assert(modify_wknd_bpr.setValue(true))
        assert(wknd_bpr.setValue(0.9))
        argument_map['modify_wkdy_bpr'] = modify_wkdy_bpr
        argument_map['wkdy_bpr'] = wkdy_bpr
        argument_map['modify_wknd_bpr'] = modify_wknd_bpr
        argument_map['wknd_bpr'] = wknd_bpr
        # apply the measure to the model and optionally run the model
        result = apply_measure_and_run(instance_test_name, measure, argument_map, osm_path, epw_path, run_model: false)

        # check the measure result; result values will equal Success, Fail, or Not Applicable
        # also check the amount of warnings, info, and error messages
        # use if or case statements to change expected assertion depending on model characteristics
        model = load_model(model_output_path(instance_test_name))
        model.getSpaceTypes.each do |space_type|
          space_type.electricEquipment.each do |equip|
            if equip.schedule.is_initialized
              equip_sch = equip.schedule.get
              case equip_sch.name.get.to_s
              when set[:equip_sch_name]
                equip_sch = equip_sch.to_ScheduleRuleset.get
                equip_sch.defaultDaySchedule.setInterpolatetoTimestep('No')
                expected_hrly_vals = [
                  [2, 0.81],
                  [10, 0.9],
                  [23, 0.855]
                ]
                expected_hrly_vals.each do |hr, val|
                  time = OpenStudio::Time.new(0, hr)
                  assert_equal(val, equip_sch.defaultDaySchedule.getValue(time))
                end
              end
            end
          end
        end
        assert(result.value.valueName == set[:result])
      end
    end
  end
end
