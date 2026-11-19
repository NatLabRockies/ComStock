# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'fileutils'
require_relative '../../../../test/helpers/minitest_helper'
require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require_relative '../measure'

class CreateTypicalBuildingFromModelTest < Minitest::Test
  def run_dir(test_name)
    return "#{__dir__}/output/#{test_name}"
  end

  # method to apply arguments, run measure, and assert results (only populate args hash with non-default argument values)
  def apply_measure_to_model(test_name, args, model_name = nil, result_value = 'Success', warnings_count = 0, info_count = nil)
    # create run directory if it does not exist
    FileUtils.mkdir_p(run_dir(test_name))

    # load the test model
    translator = OpenStudio::OSVersion::VersionTranslator.new
    path = OpenStudio::Path.new("#{__dir__}/#{model_name}")
    model = translator.loadModel(path)
    assert(!model.empty?)
    model = model.get

    # set the weather file for the test model
    epw_file = OpenStudio::EpwFile.new("#{__dir__}/USA_TX_Houston-Bush.Intercontinental.AP.722430_TMY3.epw")
    OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file).get

    # Set the day of week for start day
    model.getYearDescription.setDayofWeekforStartDay('Thursday')

    # create an instance of the measure
    measure = CreateTypicalBuildingFromModel.new

    # create an instance of a runner
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each do |arg|
      temp_arg_var = arg.clone
      if args.key?(arg.name)
        assert(temp_arg_var.setValue(args[arg.name]))
      end
      argument_map[arg.name] = temp_arg_var
    end

    # temporarily change directory to the run directory and run the measure (because of sizing run)
    start_dir = Dir.pwd
    begin
      Dir.chdir(run_dir(test_name))

      # run the measure
      reset_log
      measure.run(model, runner, argument_map)
      result = runner.result
      log_file_path = "#{Dir.pwd}/openstudio-standards.log"
      log_messages_to_file(log_file_path, false)
    ensure
      Dir.chdir(start_dir)
    end

    # show the output
    puts "measure results for #{test_name}"
    show_output(result)

    # assert that it ran correctly
    result_value = 'Success' if result_value.nil?
    assert_equal(result_value, result.value.valueName)

    # check count of warning and info messages
    assert_equal(info_count, result.info.size) unless info_count.nil?
    assert_equal(warnings_count, result.warnings.size) unless warnings_count.nil?
    result.warnings.each { |w| runner.registerWarning(w.logMessage) }

    # if 'Fail' passed in make sure at least one error message (while not typical there may be more than one message)
    assert(result.errors.size >= 1) if result_value == 'Fail'

    # save the model to test output directory
    output_file_path = OpenStudio::Path.new("#{__dir__}/output/#{test_name}_out.osm")
    model.save(output_file_path, true)

    return model
  end

  def test_midrise_apartment
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), {}, 'MidriseApartment.osm', nil, nil)
  end

  def test_small_office
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), {}, 'SmallOffice.osm', nil, nil)
  end

  def test_grocery_store
    args = {}
    args['refrigeration_template'] = 'old'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'SuperMarket.osm', nil, nil)
  end

  def test_quick_service_restaurant_no_attic
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), {}, 'QuickServiceRestaurantNoAttic.osm', nil, nil)
  end

  def test_quick_service_restaurant_walls_unchanged
    args = {}
    args['wall_construction_type'] = 'WoodFramed'
    model = apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'QuickServiceRestaurantNoAttic.osm', nil, nil)

    # Check that the walls are still the default type, WoodFramed
    model.getSurfaces.sort.each do |surf|
      next unless surf.outsideBoundaryCondition == 'Outdoors'
      next unless surf.surfaceType == 'Wall'

      construction = surf.construction.get
      standards_info = construction.standardsInformation
      const_type = standards_info.standardsConstructionType.get
      assert(const_type == 'WoodFramed', "Expected WoodFramed, got #{const_type}")
    end
  end

  def test_quick_service_restaurant_walls_to_mass
    args = {}
    args['wall_construction_type'] = 'Mass'
    model = apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'QuickServiceRestaurantNoAttic.osm', nil, nil)

    # Check that the walls are the modified type, Mass
    model.getSurfaces.sort.each do |surf|
      next unless surf.outsideBoundaryCondition == 'Outdoors'
      next unless surf.surfaceType == 'Wall'

      construction = surf.construction.get
      standards_info = construction.standardsInformation
      const_type = standards_info.standardsConstructionType.get
      assert(const_type == 'Mass', "Expected Mass, got #{const_type}")
    end
  end

  # might be cleaner to update standards to not make ext light object with multipler of 0, but for now it does seem to run through E+ fine.
  def test_no_onsite_parking
    args = {}
    args['onsite_parking_fraction'] = 0.0
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'SmallOffice.osm', nil, nil)
  end

  def test_large_office
    args = {}
    args['add_elevators'] = false
    args['add_internal_mass'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'LargeOffice04.osm', nil, nil)
  end

  def test_small_office_no_extra_loads_with_pvav
    args = {}
    args['add_elevators'] = false
    args['add_internal_mass'] = false
    args['add_exhaust'] = false
    args['add_exterior_lights'] = false
    args['add_swh'] = false
    # args['system_type'] = "Packaged VAV Air Loop with Boiler"

    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'SmallOffice.osm', nil, nil)
  end

  # made this test for temp work around for night cycle mode
  def test_pfp_boxes
    args = {}
    args['system_type'] = 'VAV chiller with PFP boxes'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'SmallOffice.osm', nil, nil)
  end

  def test_wshp_fluid_cooler
    args = {}
    args['system_type'] = 'Water source heat pumps fluid cooler with boiler'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'SmallOffice.osm', nil, nil)
  end

  # DEER Prototypes
  def test_asm
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'asm.osm', nil, nil)
  end

  def test_ecc
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'ecc.osm', nil, nil)
  end

  def test_epr
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'epr.osm', nil, nil)
  end

  def test_erc
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'erc.osm', nil, nil)
  end

  def test_ese
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'ese.osm', nil, nil)
  end

  def test_eun
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'eun.osm', nil, nil)
  end

  def test_gro
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'gro.osm', nil, nil)
  end

  def test_hsp
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'hsp.osm', nil, nil)
  end

  def test_htl
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'htl.osm', nil, nil)
  end

  def test_mbt
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'mbt.osm', nil, nil)
  end

  def test_mfm
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'mfm.osm', nil, nil)
  end

  def test_mli
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'mli.osm', nil, nil)
  end

  def test_mtl
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'mtl.osm', nil, nil)
  end

  def test_nrs
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'nrs.osm', nil, nil)
  end

  def test_ofl
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'ofl.osm', nil, nil)
  end

  def test_ofs
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'ofs.osm', nil, nil)
  end

  def test_rff
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'rff.osm', nil, nil)
  end

  def test_rsd
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'rsd.osm', nil, nil)
  end

  def test_rt3
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'rt3.osm', nil, nil)
  end

  def test_rtl
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'rtl.osm', nil, nil)
  end

  def test_rts
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'rts.osm', nil, nil)
  end

  def test_scn
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'scn.osm', nil, nil)
  end

  def test_sun
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'sun.osm', nil, nil)
  end

  def test_wrf
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'wrf.osm', nil, nil)
  end

  # DEER Prototypes with Heat Pump SWH
  def test_asm_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'asm.osm', nil, nil)
  end

  def test_ecc_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'ecc.osm', nil, nil)
  end

  def test_epr_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'epr.osm', nil, nil)
  end

  def test_erc_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'erc.osm', nil, nil)
  end

  def test_ese_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'ese.osm', nil, nil)
  end

  def test_eun_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'eun.osm', nil, nil)
  end

  def test_gro_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'gro.osm', nil, nil)
  end

  def test_hsp_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'hsp.osm', nil, nil)
  end

  def test_htl_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'htl.osm', nil, nil)
  end

  def test_mbt_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'mbt.osm', nil, nil)
  end

  def test_mfm_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'mfm.osm', nil, nil)
  end

  def test_mli_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'mli.osm', nil, nil)
  end

  def test_mtl_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'mtl.osm', nil, nil)
  end

  def test_nrs_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'nrs.osm', nil, nil)
  end

  def test_ofl_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'ofl.osm', nil, nil)
  end

  def test_ofs_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'ofs.osm', nil, nil)
  end

  def test_rff_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'rff.osm', nil, nil)
  end

  def test_rsd_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'rsd.osm', nil, nil)
  end

  def test_rt3_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'rt3.osm', nil, nil)
  end

  def test_rtl_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'rtl.osm', nil, nil)
  end

  def test_rts_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'rts.osm', nil, nil)
  end

  def test_scn_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'scn.osm', nil, nil)
  end

  def test_sun_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'sun.osm', nil, nil)
  end

  def test_wrf_hpwh
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['swh_src'] = 'HeatPump'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'wrf.osm', nil, nil)
  end

  # DEER Prototypes with operating hour changes
  def test_asm_op_hrs
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['modify_wkdy_op_hrs'] = true
    args['wkdy_op_hrs_start_time'] = '9.25'
    args['wkdy_op_hrs_duration'] = '10.00'
    args['modify_wknd_op_hrs'] = true
    args['wknd_op_hrs_start_time'] = '8.00'
    args['wknd_op_hrs_duration'] = '10.00'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'asm.osm', nil, nil)
  end

  def test_ese_op_hrs
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['modify_wkdy_op_hrs'] = true
    args['wkdy_op_hrs_start_time'] = '9.25'
    args['wkdy_op_hrs_duration'] = '10.0'
    args['modify_wknd_op_hrs'] = true
    args['wknd_op_hrs_start_time'] = '8.00'
    args['wknd_op_hrs_duration'] = '10.0'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'ese.osm', nil, nil)
  end

  def test_ese_op_hrs_overnight
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['modify_wkdy_op_hrs'] = true
    args['wkdy_op_hrs_start_time'] = '12.50'
    args['wkdy_op_hrs_duration'] = '13.00'
    args['modify_wknd_op_hrs'] = true
    args['wknd_op_hrs_start_time'] = '8.00'
    args['wknd_op_hrs_duration'] = '6.00'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'ese.osm', nil, nil)
  end

  def test_eun_op_hrs
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['modify_wkdy_op_hrs'] = true
    args['wkdy_op_hrs_start_time'] = '9.25'
    args['wkdy_op_hrs_duration'] = '10.00'
    args['modify_wknd_op_hrs'] = true
    args['wknd_op_hrs_start_time'] = '8.00'
    args['wknd_op_hrs_duration'] = '10.00'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'eun.osm', nil, nil)
  end

  def test_ofl_op_hrs
    args = {}
    args['template'] = 'DEER Pre-1975'
    args['use_upstream_args'] = false
    args['modify_wkdy_op_hrs'] = true
    args['wkdy_op_hrs_start_time'] = '9.25'
    args['wkdy_op_hrs_duration'] = '10.00'
    args['modify_wknd_op_hrs'] = true
    args['wknd_op_hrs_start_time'] = '8.00'
    args['wknd_op_hrs_duration'] = '10.00'
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'ofl.osm', nil, nil)
  end

  # tests for doe models with unique climate zones (1, 7, 8)
  def test_small_office_1a_pre_1980
    args = {}
    args['template'] = 'ComStock DOE Ref Pre-1980'
    args['climate_zone'] = 'ASHRAE 169-2013-1A'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'SmallOffice.osm', nil, nil)
  end

  def test_small_office_7a_pre_1980
    args = {}
    args['template'] = 'ComStock DOE Ref Pre-1980'
    args['climate_zone'] = 'ASHRAE 169-2013-7A'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'SmallOffice.osm', nil, nil)
  end

  def test_small_office_8a_pre_1980
    args = {}
    args['template'] = 'ComStock DOE Ref Pre-1980'
    args['climate_zone'] = 'ASHRAE 169-2013-8A'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'SmallOffice.osm', nil, nil)
  end

  def test_small_office_2a_pre_1980
    args = {}
    args['template'] = 'ComStock DOE Ref Pre-1980'
    args['climate_zone'] = 'ASHRAE 169-2013-2A'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'SmallOffice.osm', nil, nil)
  end

  def test_small_office_1a_1980_2004
    args = {}
    args['template'] = 'ComStock DOE Ref 1980-2004'
    args['climate_zone'] = 'ASHRAE 169-2013-1A'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'SmallOffice.osm', nil, nil)
  end

  def test_small_office_7a_1980_2004
    args = {}
    args['template'] = 'ComStock DOE Ref 1980-2004'
    args['climate_zone'] = 'ASHRAE 169-2013-7A'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'SmallOffice.osm', nil, nil)
  end

  def test_small_office_8a_1980_2004
    args = {}
    args['template'] = 'ComStock DOE Ref 1980-2004'
    args['climate_zone'] = 'ASHRAE 169-2013-8A'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'SmallOffice.osm', nil, nil)
  end

  def test_small_office_2a_1980_2004
    args = {}
    args['template'] = 'ComStock DOE Ref 1980-2004'
    args['climate_zone'] = 'ASHRAE 169-2013-2A'
    args['use_upstream_args'] = false
    apply_measure_to_model(__method__.to_s.gsub('test_', ''), args, 'SmallOffice.osm', nil, nil)
  end
end
