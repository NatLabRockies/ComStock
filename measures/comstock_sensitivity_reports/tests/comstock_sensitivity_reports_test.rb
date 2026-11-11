# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'fileutils'
require 'minitest/autorun'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'comstock-typical'
require 'json'
require_relative '../measure'

class ComStockSensitivityReportsTest < Minitest::Test
  def run_dir(test_name)
    # always generate test output in specially named 'output' directory so result files are not made part of the measure
    return "#{__dir__}/output/#{test_name}"
  end

  def model_output_path(test_name)
    return "#{run_dir(test_name)}/out.osm"
  end

  def workspace_path(test_name)
    return "#{run_dir(test_name)}/run/in.idf"
  end

  def sql_path(test_name)
    return "#{run_dir(test_name)}/run/eplusout.sql"
  end

  def report_path(test_name)
    return "#{run_dir(test_name)}/reports/eplustbl.html"
  end

  # setup_model: optional block applied to the test model before it is saved and simulated
  # @return [OpenStudio::Measure::OSResult] the measure result (truthy)
  def run_test(test_name, osm_path, epw_path, setup_model: nil)
    # create run directory if it does not exist
    FileUtils.mkdir_p(run_dir(test_name))
    assert(File.exist?(run_dir(test_name)))

    # change into run directory for tests
    start_dir = Dir.pwd
    begin
      Dir.chdir run_dir(test_name)

      # create an instance of the measure
      measure = ComStockSensitivityReports.new

      # create an instance of a runner
      runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

      # Load the input model to set up runner, this will happen automatically when measure is run in PAT or OpenStudio
      translator = OpenStudio::OSVersion::VersionTranslator.new
      model = translator.loadModel(osm_path)
      assert(model.is_initialized)
      model = model.get
      runner.setLastOpenStudioModel(model)

      # get arguments
      arguments = measure.arguments
      argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

      # get the energyplus output requests, this will be done automatically by OS App and PAT
      idf_output_requests = measure.energyPlusOutputRequests(runner, argument_map)

      # convert output requests to OSM for testing, OS App and PAT will add these to the E+ Idf
      workspace = OpenStudio::Workspace.new('Draft'.to_StrictnessLevel, 'EnergyPlus'.to_IddFileType)
      workspace.addObjects(idf_output_requests)
      rt = OpenStudio::EnergyPlus::ReverseTranslator.new
      request_model = rt.translateWorkspace(workspace)

      # load the test model and add output requests
      translator = OpenStudio::OSVersion::VersionTranslator.new
      model = translator.loadModel(OpenStudio::Path.new(osm_path))
      assert(!model.empty?)
      model = model.get
      model.addObjects(request_model.objects)
      setup_model&.call(model)
      model.save(model_output_path(test_name), true)

      # set model weather file
      assert(File.exist?(epw_path))
      epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(epw_path))
      OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
      assert(model.weatherFile.is_initialized)

      # run the simulation if necessary
      unless File.exist?(sql_path(test_name))
        puts "\nRUNNING ANNUAL RUN FOR #{test_name}..."

        std = Standard.build('90.1-2013')
        std.model_run_simulation_and_log_errors(model, run_dir(test_name))
      end
      assert(File.exist?(model_output_path(test_name)))
      assert(File.exist?(sql_path(test_name)))

      # set up runner, this will happen automatically when measure is run in PAT or OpenStudio
      runner.setLastOpenStudioModelPath(OpenStudio::Path.new(model_output_path(test_name)))
      runner.setLastEnergyPlusWorkspacePath(OpenStudio::Path.new(workspace_path(test_name)))
      runner.setLastEpwFilePath(epw_path)
      runner.setLastEnergyPlusSqlFilePath(OpenStudio::Path.new(sql_path(test_name)))

      # delete the output if it exists

      FileUtils.rm_f(report_path(test_name))

      assert(!File.exist?(report_path(test_name)))

      # run the measure
      puts "\nRUNNING MEASURE RUN FOR #{test_name}..."
      measure.run(runner, argument_map)
      result = runner.result
      show_output(result)

      # log result to file for comparisons
      values = result.stepValues.map(&:string)
      File.write("#{run_dir(test_name)}/output.txt", "[\n#{values.join(',').strip}\n]")

      assert_equal('Success', result.value.valueName)
    ensure
      # change back directory
      Dir.chdir(start_dir)
    end

    return result
  end

  def test_number_of_arguments_and_argument_names
    # this test ensures that the current test is matched to the measure inputs
    puts "\n######\nTEST:#{__method__}\n######\n"

    # create an instance of the measure
    measure = ComStockSensitivityReports.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments
    assert_equal(0, arguments.size)
  end

  def test_bldg25
    # retail_resforcedair
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0000025.osm"
    epw_path = "#{__dir__}/USA_MI_Detroit.City.725375_2012.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_bldg31
    # quick_service_restaurant_pthp
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0000031.osm"
    epw_path = "#{__dir__}/USA_OH_Toledo.Express.725360_2012.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_bldg43
    # warehouse_baseboardelec
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0000043.osm"
    epw_path = "#{__dir__}/USA_NV_Nellis.Afb.723865_2012.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_bldg45
    # stripmall_windowac
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0000045.osm"
    epw_path = "#{__dir__}/USA_TX_San.Marcos.Muni.722539_2012.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_bldg53
    # smallhotel_pszac
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0000053.osm"
    epw_path = "#{__dir__}/USA_MI_Cherry.Capital.726387_2012.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_bldg82
    # hospital_vav
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0000082.osm"
    epw_path = "#{__dir__}/USA_KY_Bowman.Fld.724235_2012.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_bldg03
    # smalloffice_pszac
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0000003.osm"
    epw_path = "#{__dir__}/FortCollins2016.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_bldg04
    # retail_pszacnoheat
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0000004.osm"
    epw_path = "#{__dir__}/FortCollins2016.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_fuel_oil_boiler
    # fuel_oil_boiler
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0000034.osm"
    epw_path = "#{__dir__}/USA_MD_Baltimore-Washington.Intl.AP.724060_TMY3.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_propane_boiler
    # propane_boiler
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0000090.osm"
    epw_path = "#{__dir__}/USA_NV_Nellis.Afb.723865_2012.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_vrf
    # vrf
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0146294.osm"
    epw_path = "#{__dir__}/USA_MD_Baltimore-Washington.Intl.AP.724060_TMY3.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_multispeed_heat_pump
    # multispeed_heat_pump
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/multispeed_hps.osm"
    epw_path = "#{__dir__}/USA_MI_Detroit.City.725375_2012.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_heat_pump_boiler_1
    # heat_pump_boiler_1
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/heat_pump_boiler_1.osm"
    epw_path = "#{__dir__}/USA_MN_Duluth.Intl.AP.727450_TMY.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_heat_pump_boiler_2
    # heat_pump_boiler_2
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/heat_pump_boiler_2.osm"
    epw_path = "#{__dir__}/USA_KY_Bowman.Fld.724235_2012.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_shw_hpwh
    # shw_hpwh
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/hpwh002.osm"
    epw_path = "#{__dir__}/USA_NV_Nellis.Afb.723865_2012.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_ghx_outputs
    # ground_heat_exchanger_outputs
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/ground_heat_exchanger.osm"
    epw_path = "#{__dir__}/USA_MI_Detroit.City.725375_2012.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_hp_rtu_gas_backup
    # hp_rtu_gas_backup
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/hp_rtu_gas_backup.osm"
    epw_path = "#{__dir__}/USA_AL_Mobile-Downtown.AP.722235_TMY3.epw"
    result = run_test(__method__, osm_path, epw_path)
    assert(result)

    # the model carries no counts from upgrade_hvac_add_heat_pump_rtu, so each is reported as 0
    values = result.stepValues.to_h { |v| [v.name, v.valueAsVariant.to_s] }
    HPRTU_COUNTS.each_key do |name|
      assert_equal('0', values["com_report_hvac_#{name}"], "#{name} should be reported as 0 when not stored on the building")
    end
  end

  # a propane backup coil is a CoilHeatingGas with fuel type Propane; its fuel must be counted in the total heating COP
  def test_hp_rtu_propane_backup
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/hp_rtu_gas_backup.osm"
    epw_path = "#{__dir__}/USA_MN_Duluth.Intl.AP.727450_TMY.epw"
    burner_efficiencies = []
    use_propane = lambda do |model|
      model.getCoilHeatingGass.each do |coil|
        assert(coil.setFuelType('Propane'), "could not set fuel type of '#{coil.name}' to Propane")
        burner_efficiencies << coil.gasBurnerEfficiency
      end
    end
    result = run_test(__method__, osm_path, epw_path, setup_model: use_propane)
    assert(result)
    refute_empty(burner_efficiencies, 'test model has no CoilHeatingGas to switch to propane')
    assert_equal(1, burner_efficiencies.uniq.size, 'test assumes all backup coils share one burner efficiency')

    values = result.stepValues.to_h { |v| [v.name, v.valueAsVariant.to_s.to_f] }
    backup_heat_j = values['com_report_hvac_dx_heating_total_supplemental_load_gas_j']
    backup_fuel_j = values['com_report_hvac_dx_heating_total_supplemental_gas_j']
    assert_operator(backup_heat_j, :>, 0.0, 'the propane backup should run in a Duluth winter')
    assert_operator(backup_fuel_j, :>, 0.0, 'propane burned by the backup coils is not counted')
    # fuel burned is about the heat delivered divided by the burner efficiency
    assert_in_delta(backup_heat_j / burner_efficiencies.first, backup_fuel_j, 0.05 * backup_fuel_j)
    # with the backup's fuel counted, the total COP must sit below the heat pump's own COP
    assert_operator(values['com_report_hvac_dx_heating_average_total_cop'], :<,
                    values['com_report_hvac_dx_heating_average_cop'])
  end

  # a fuel oil backup coil is a CoilHeatingGas with fuel type FuelOilNo2; its fuel must be counted in the total heating COP
  def test_hp_rtu_fuel_oil_backup
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/hp_rtu_gas_backup.osm"
    epw_path = "#{__dir__}/USA_MN_Duluth.Intl.AP.727450_TMY.epw"
    burner_efficiencies = []
    use_fuel_oil = lambda do |model|
      model.getCoilHeatingGass.each do |coil|
        assert(coil.setFuelType('FuelOilNo2'), "could not set fuel type of '#{coil.name}' to FuelOilNo2")
        burner_efficiencies << coil.gasBurnerEfficiency
      end
    end
    result = run_test(__method__, osm_path, epw_path, setup_model: use_fuel_oil)
    assert(result)
    refute_empty(burner_efficiencies, 'test model has no CoilHeatingGas to switch to fuel oil')
    assert_equal(1, burner_efficiencies.uniq.size, 'test assumes all backup coils share one burner efficiency')

    values = result.stepValues.to_h { |v| [v.name, v.valueAsVariant.to_s.to_f] }
    backup_heat_j = values['com_report_hvac_dx_heating_total_supplemental_load_gas_j']
    backup_fuel_j = values['com_report_hvac_dx_heating_total_supplemental_gas_j']
    assert_operator(backup_heat_j, :>, 0.0, 'the fuel oil backup should run in a Duluth winter')
    assert_operator(backup_fuel_j, :>, 0.0, 'fuel oil burned by the backup coils is not counted')
    # fuel burned is about the heat delivered divided by the burner efficiency
    assert_in_delta(backup_heat_j / burner_efficiencies.first, backup_fuel_j, 0.05 * backup_fuel_j)
    # with the backup's fuel counted, the total COP must sit below the heat pump's own COP
    assert_operator(values['com_report_hvac_dx_heating_average_total_cop'], :<,
                    values['com_report_hvac_dx_heating_average_cop'])
  end

  # the air loop counts upgrade_hvac_add_heat_pump_rtu stores on the building are reported as they are
  HPRTU_COUNTS = { 'hprtu_air_loops_replaced' => 5, 'hprtu_air_loops_outside_cfm_per_ton' => 4,
                   'hprtu_air_loops_outside_cfm_per_ton_min_oa' => 3, 'hprtu_air_loops_with_removed_stages' => 2,
                   'hprtu_air_loops_with_removed_stages_min_oa' => 1 }.freeze
  def test_hp_rtu_counts_reported
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/hp_rtu_gas_backup.osm"
    epw_path = "#{__dir__}/USA_AL_Mobile-Downtown.AP.722235_TMY3.epw"
    store_counts = lambda do |model|
      HPRTU_COUNTS.each { |name, count| model.getBuilding.additionalProperties.setFeature(name, count) }
    end
    result = run_test(__method__, osm_path, epw_path, setup_model: store_counts)
    assert(result)

    values = result.stepValues.to_h { |v| [v.name, v.valueAsVariant.to_s] }
    HPRTU_COUNTS.each do |name, count|
      assert_equal(count.to_s, values["com_report_hvac_#{name}"], "#{name} reported differently from the value on the building")
    end
  end

  def test_vrf_cold_climate
    # vrf_cold_climate
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/vrf_cold_climate.osm"
    epw_path = "#{__dir__}/USA_MN_Duluth.Intl.AP.727450_TMY.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_vrf_propane_backup
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/vrf_cold_climate.osm"
    epw_path = "#{__dir__}/USA_MN_Duluth.Intl.AP.727450_TMY.epw"
    burner_efficiencies = []
    use_propane_vrf_backups = lambda do |model|
      model.getThermalZones.each do |zone|
        zone.equipment.each do |equipment|
          next unless equipment.to_ZoneHVACTerminalUnitVariableRefrigerantFlow.is_initialized

          terminal = equipment.to_ZoneHVACTerminalUnitVariableRefrigerantFlow.get
          next unless terminal.supplementalHeatingCoil.is_initialized

          backup_coil = OpenStudio::Model::CoilHeatingGas.new(model)
          assert(backup_coil.setFuelType('Propane'), "could not set fuel type of '#{backup_coil.name}' to Propane")
          backup_coil.setGasBurnerEfficiency(0.8)
          backup_coil.autosizeNominalCapacity
          terminal.setSupplementalHeatingCoil(backup_coil)
          burner_efficiencies << backup_coil.gasBurnerEfficiency
        end
      end
    end
    result = run_test(__method__, osm_path, epw_path, setup_model: use_propane_vrf_backups)
    assert(result)
    refute_empty(burner_efficiencies, 'test model has no VRF supplemental coils to switch to propane')
    assert_equal(1, burner_efficiencies.uniq.size, 'test assumes all VRF backup coils share one burner efficiency')

    values = result.stepValues.to_h { |v| [v.name, v.valueAsVariant.to_s.to_f] }
    backup_heat_j = values['com_report_hvac_vrf_total_heating_supplemental_load_gas_j']
    backup_fuel_j = values['com_report_hvac_vrf_total_heating_supplemental_gas_j']
    assert_operator(backup_heat_j, :>, 0.0, 'the propane VRF backup should run in a Duluth winter')
    assert_operator(backup_fuel_j, :>, 0.0, 'propane burned by the VRF backup coils is not counted')
    assert_in_delta(backup_heat_j / burner_efficiencies.first, backup_fuel_j, 0.05 * backup_fuel_j)
    assert_operator(values['com_report_hvac_vrf_heating_average_total_cop'], :<,
                    values['com_report_hvac_vrf_heating_average_cop'])
  end

  def test_8172d17_0000008
    # 8172d17_0000008
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/8172d17_0000008.osm"
    epw_path = "#{__dir__}/USA_AL_Mobile-Downtown.AP.722235_TMY3.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_base_0000008
    # base_0000008
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/base_0000008.osm"
    epw_path = "#{__dir__}/USA_AL_Mobile-Downtown.AP.722235_TMY3.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_grocery_store
    # test_grocery_store
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/grocery.osm"
    epw_path = "#{__dir__}/USA_AL_Mobile-Downtown.AP.722235_TMY3.epw"
    assert(run_test(__method__, osm_path, epw_path))
  end

  def test_pump_spec
    # bldg0006100
    puts "\n######\nTEST:#{__method__}\n######\n"
    osm_path = "#{__dir__}/bldg0006100.osm"
    epw_path = "#{__dir__}/USA_AL_Mobile-Downtown.AP.722235_TMY3.epw"
    result = assert(run_test(__method__, osm_path, epw_path))

    output_txt = JSON.parse(File.read("#{run_dir(__method__)}/output.txt"))
    output_txt.each do |output_var|
      puts("### DEBUGGING: output_var = #{output_var['name']} | value = #{output_var['value']}")

      # check values with values from example model
      if output_var['name'] == 'com_report_pump_flow_weighted_avg_motor_efficiency'
        assert_in_delta(0.9086, output_var['value'].to_f, 0.01)
      end
      if output_var['name'] == 'com_report_pump_flow_weighted_avg_motor_efficiency_const_spd'
        assert_in_delta(0.8011, output_var['value'].to_f, 0.01)
      end
      if output_var['name'] == 'com_report_pump_flow_weighted_avg_motor_efficiency_var_spd'
        assert_in_delta(0.9260, output_var['value'].to_f, 0.01)
      end
      if output_var['name'] == 'com_report_pump_count_hvac_const_spd'
        assert_equal(0, output_var['value'])
      end
      if output_var['name'] == 'com_report_pump_count_hvac_var_spd'
        assert_equal(2, output_var['value'])
      end
      if output_var['name'] == 'com_report_pump_count_swh_const_spd'
        assert_equal(1, output_var['value'])
      end
      if output_var['name'] == 'com_report_pump_count_swh_var_spd'
        assert_equal(1, output_var['value'])
      end
    end
  end
end
