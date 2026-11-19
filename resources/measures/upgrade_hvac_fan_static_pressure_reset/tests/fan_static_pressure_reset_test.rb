# insert your copyright here

require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'minitest/autorun'
require 'minitest/mock'
require 'fileutils'

require_relative '../measure'

class FanStaticPressureResetTest < Minitest::Test
  # return file paths to test models in test directory
  def models_for_tests
    paths = Dir.glob(File.join(__dir__, '../../../tests/models/*.osm'))
    paths.map { |path| File.expand_path(path) }
  end

  # return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(__dir__, '../../../tests/weather/*.epw'))
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
    "#{__dir__}/output/#{test_name}"
  end

  def model_input_path(osm_name)
    # return models_for_tests.select { |x| set[:model] == osm_name }
    File.join(__dir__, '../../../tests/models', osm_name)
  end

  def epw_input_path(epw_name)
    File.join(__dir__, '../../../tests/weather', epw_name)
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
  def set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false,
                                            model: nil, apply: true, expected_results: 'Success')
    start_dir = Dir.pwd
    assert(File.exist?(osm_path))
    assert(File.exist?(epw_path))
    ddy_path = "#{epw_path.gsub('.epw', '')}.ddy"

    # create run directory if it does not exist
    FileUtils.mkdir_p(run_dir(test_name))
    assert(File.exist?(run_dir(test_name)))

    # change into run directory for tests
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
          /Htg 99.6. Condns DB/, # Annual heating 99.6%
          /Clg .4. Condns WB=>MDB/, # Annual humidity (for cooling towers and evap coolers)
          /Clg .4. Condns DB=>MWB/, # Annual cooling
          /August .4. Condns DB=>MCWB/, # Monthly cooling DB=>MCWB (to handle solar-gain-driven cooling)
          /September .4. Condns DB=>MCWB/,
          /October .4. Condns DB=>MCWB/
        ]
        ddy_list.each do |ddy_name_regex|
          next unless d.name.get.to_s.match?(ddy_name_regex)

          runner.registerInfo("Adding object #{d.name}")

          # add the object to the existing model
          model.addObject(d.clone)
          break
        end
      end

      # assert
      assert_equal(false, model.getDesignDays.empty?)
    end

    if apply
      # run the measure
      puts "\nAPPLYING MEASURE..."
      measure.run(model, runner, argument_map)
      result = runner.result
      result.value.valueName
      assert_equal(expected_results, result.value.valueName)

      # Show the output
      show_output(result)
    end
    model.getOutputControlFiles.setOutputCSV(true)

    # Save model
    model.save(model_output_path(test_name), true)

    if run_model
      puts "\nRUNNING MODEL..."

      std = Standard.build('90.1-2013')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))

      # Check that the model ran successfully
      assert(File.exist?(sql_path(test_name)))
    end

    result
  ensure
    Dir.chdir(start_dir)
  end

  def test_restores_working_directory_when_copy_fails
    start_dir = Dir.pwd
    copy_failure = ->(*_args) { raise IOError, 'copy failed' }

    FileUtils.stub(:cp, copy_failure) do
      assert_raises(IOError) do
        set_weather_and_apply_measure_and_run(
          __method__, nil, nil,
          model_input_path('SP_reset_measure_Test.osm'),
          epw_input_path('CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw')
        )
      end
    end
    assert_equal(start_dir, Dir.pwd)
  ensure
    Dir.chdir(start_dir)
  end

  def test_confirm_fan_curve_change
    osm_name = 'SP_reset_measure_Test.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'

    test_name = 'confirm_fan_curve_change'

    puts "\n######\nTEST:#{test_name}\n######\n"

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    # Create an instance of the measure
    measure = FanStaticPressureReset.new

    # Load the model
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # run the measure
    result = set_weather_and_apply_measure_and_run(__method__, measure, argument_map, osm_path, epw_path,
                                                   run_model: false)
    assert_equal('Success', result.value.valueName)
    model = load_model(model_output_path(__method__))

    # Coefficients for fan curve emulating SP reset
    reset_coeff_1 = 0.040759894
    reset_coeff_2 = 0.08804497
    reset_coeff_3 = -0.07292612
    reset_coeff_4 = 0.943739823

    reset_arr = [reset_coeff_1, reset_coeff_2, reset_coeff_3, reset_coeff_4]

    vs_fans = model.getFanVariableVolumes

    vs_fans.each do |fan|
      fan = fan.to_FanVariableVolume.get
      coeff_1 = fan.fanPowerCoefficient1.get
      coeff_2 = fan.fanPowerCoefficient2.get
      coeff_3 = fan.fanPowerCoefficient3.get
      coeff_4 = fan.fanPowerCoefficient4.get
      fan_coeff_arr = [coeff_1, coeff_2, coeff_3, coeff_4]

      print(coeff_1)
      print(coeff_2)
      assert_equal(reset_arr, fan_coeff_arr, 'Fan coefficients do not match expected reset values')
    end
  end
end
