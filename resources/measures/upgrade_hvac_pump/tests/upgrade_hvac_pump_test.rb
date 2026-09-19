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

require 'openstudio'
require 'openstudio/measure/ShowRunnerOutput'
require 'minitest/autorun'
require 'fileutils'
require 'comstock-typical'
require_relative '../measure'

class UpgradeHvacPumpTest < Minitest::Test
  def setup
    # Create a new empty OpenStudio model to pass into the method
    @model = OpenStudio::Model::Model.new
  end

  def test_evaluate_zero
    curve, = UpgradeHvacPump.curve_fraction_of_full_load_power(@model)
    result = curve.evaluate(0.0)
    assert_in_delta 0.0, result, 1e-6, 'Expected curve output at x=0 to be 0'
  end

  def test_evaluate_one
    curve, = UpgradeHvacPump.curve_fraction_of_full_load_power(@model)
    result = curve.evaluate(1.0)
    assert_in_delta 1.0, result, 1e-6, 'Expected curve output at x=1 to be 1'
  end

  def test_output_bounds_over_range
    # Test across input range 350W to 38800W
    (350..38800).step(500).each do |watts|
      eff = UpgradeHvacPump.estimate_motor_efficiency_pcnt(watts)
      assert eff >= 90.53, "Efficiency below lower bound for #{watts} W: #{eff}"
      assert eff <= 95.95, "Efficiency above upper bound for #{watts} W: #{eff}"
    end
  end

  def test_low_power_value
    eff = UpgradeHvacPump.estimate_motor_efficiency_pcnt(350)
    assert_in_delta 90.53, eff, 0.5, 'Expected efficiency close to lower bound'
  end

  def test_high_power_value
    eff = UpgradeHvacPump.estimate_motor_efficiency_pcnt(38800)
    assert_in_delta 95.95, eff, 0.5, 'Expected efficiency close to upper bound'
  end

  def test_exact_breakpoint
    eff = UpgradeHvacPump.estimate_motor_efficiency_pcnt(5000)
    assert eff.between?(90.53, 95.95), "Efficiency at breakpoint not within bounds: #{eff}"
  end

  def test_zero_input
    assert_raises(ArgumentError) do
      UpgradeHvacPump.estimate_motor_efficiency_pcnt(0)
    end
  end

  def test_input_below_range_clipped
    eff = UpgradeHvacPump.estimate_motor_efficiency_pcnt(100) # 0.1 kW
    assert_in_delta 90.53, eff, 1e-6, 'Expected output to be clipped at lower bound for 100W'
  end

  def test_input_above_range_clipped
    eff = UpgradeHvacPump.estimate_motor_efficiency_pcnt(50000) # 50 kW
    assert_in_delta 95.95, eff, 1e-6, 'Expected output to be clipped at upper bound for 50000W'
  end

  # supporting method: return file paths to test models in test directory
  def models_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/models/*.osm'))
    paths = paths.map { |path| File.expand_path(path) }
    return paths
  end

  # supporting method: return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/weather/*.epw'))
    paths = paths.map { |path| File.expand_path(path) }
    return paths
  end

  # supporting method: load model from osm path
  def load_model(osm_path)
    translator = OpenStudio::OSVersion::VersionTranslator.new
    model = translator.loadModel(OpenStudio::Path.new(osm_path))
    assert(!model.empty?)
    model.get
  end

  # supporting method: return model output path
  def model_output_path(test_name)
    "#{run_dir(test_name)}/#{test_name}.osm"
  end

  # supporting method: return run path
  def run_dir(test_name)
    # always generate test output in specially named 'output' directory so
    # result files are not made part of the measure
    "#{File.dirname(__FILE__)}/output/#{test_name}"
  end

  # supporting method: return results html path
  def report_path(test_name)
    "#{run_dir(test_name)}/reports/eplustbl.html"
  end

  # supporting method: get sql file path
  def sql_path(test_name)
    "#{run_dir(test_name)}/run/eplusout.sql"
  end

  # supporting method: apply measure to model and test,
  def apply_and_test_model(path, instance_test_name)
    # build standard
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)

    # create an instance of the measure
    measure = UpgradeHvacPump.new

    # create runner with empty OSW
    osw = OpenStudio::WorkflowJSON.new
    runner = OpenStudio::Measure::OSRunner.new(osw)

    # load the test model
    translator = OpenStudio::OSVersion::VersionTranslator.new
    # path = "#{File.dirname(__FILE__)}/example_model.osm"
    model = translator.loadModel(path)
    refute_empty(model)
    model = model.get

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      case arg.name
      when 'chw_hw_oat_reset'
        chw_hw_oat_reset = arguments[idx].clone
        chw_hw_oat_reset.setValue(true)
        argument_map[arg.name] = chw_hw_oat_reset
      when 'cw_oat_reset'
        cw_oat_reset = arguments[idx].clone
        cw_oat_reset.setValue(true)
        argument_map[arg.name] = cw_oat_reset
      when 'debug_verbose'
        debug_verbose = arguments[idx].clone
        debug_verbose.setValue(true)
        argument_map[arg.name] = debug_verbose
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # get pump specs before measure
    pumps_const_spd = model.getPumpConstantSpeeds
    pump_specs_cst_spd_before = UpgradeHvacPump.pump_specifications([], pumps_const_spd, std)
    pump_rated_flow_total_c_before = pump_specs_cst_spd_before[1]
    pump_motor_eff_weighted_average_c_before = pump_specs_cst_spd_before[2]
    pump_motor_bhp_weighted_average_c_before = pump_specs_cst_spd_before[3]
    pumps_var_spd = model.getPumpVariableSpeeds
    pump_specs_var_spd_before = UpgradeHvacPump.pump_specifications([], pumps_var_spd, std)
    pump_rated_flow_total_v_before = pump_specs_var_spd_before[1]
    pump_motor_eff_weighted_average_v_before = pump_specs_var_spd_before[2]
    pump_motor_bhp_weighted_average_v_before = pump_specs_var_spd_before[3]
    pump_var_part_load_curve_coeff1_weighted_avg_before = pump_specs_var_spd_before[4]
    pump_var_part_load_curve_coeff2_weighted_avg_before = pump_specs_var_spd_before[5]
    pump_var_part_load_curve_coeff3_weighted_avg_before = pump_specs_var_spd_before[6]
    pump_var_part_load_curve_coeff4_weighted_avg_before = pump_specs_var_spd_before[7]

    # get control specs for baseline
    fraction_chw_hw_oat_reset_enabled_b, fraction_cw_oat_reset_enabled_b =
      UpgradeHvacPump.control_specifications(model)

    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result

    # get pump specs after measure
    pumps_const_spd = model.getPumpConstantSpeeds
    pump_specs_cst_spd_after = UpgradeHvacPump.pump_specifications([], pumps_const_spd, std)
    pump_rated_flow_total_c_after = pump_specs_cst_spd_after[1]
    pump_motor_eff_weighted_average_c_after = pump_specs_cst_spd_after[2]
    pump_motor_bhp_weighted_average_c_after = pump_specs_cst_spd_after[3]
    pumps_var_spd = model.getPumpVariableSpeeds
    pump_specs_var_spd_after = UpgradeHvacPump.pump_specifications([], pumps_var_spd, std)
    pump_rated_flow_total_v_after = pump_specs_var_spd_after[1]
    pump_motor_eff_weighted_average_v_after = pump_specs_var_spd_after[2]
    pump_motor_bhp_weighted_average_v_after = pump_specs_var_spd_after[3]
    pump_var_part_load_curve_coeff1_weighted_avg_after = pump_specs_var_spd_after[4]
    pump_var_part_load_curve_coeff2_weighted_avg_after = pump_specs_var_spd_after[5]
    pump_var_part_load_curve_coeff3_weighted_avg_after = pump_specs_var_spd_after[6]
    pump_var_part_load_curve_coeff4_weighted_avg_after = pump_specs_var_spd_after[7]

    # get control specs for upgrade
    fraction_chw_hw_oat_reset_enabled_a, fraction_cw_oat_reset_enabled_a =
      UpgradeHvacPump.control_specifications(model)

    # show the output
    show_output(result)

    # assert that it ran correctly
    assert_equal('Success', result.value.valueName)

    refute_empty(result.stepInitialCondition)

    refute_empty(result.stepFinalCondition)

    # check chilled water system specs
    puts("### DEBUGGING: pump_motor_eff_weighted_average_c_before = #{
      pump_motor_eff_weighted_average_c_before
    } | pump_motor_eff_weighted_average_c_after = #{
        pump_motor_eff_weighted_average_c_after
      }")
    puts("### DEBUGGING: pump_motor_bhp_weighted_average_c_before = #{
      pump_motor_bhp_weighted_average_c_before
    } | pump_motor_bhp_weighted_average_c_after = #{
        pump_motor_bhp_weighted_average_c_after
      }")
    puts("### DEBUGGING: pump_motor_eff_weighted_average_v_before = #{
      pump_motor_eff_weighted_average_v_before
    } | pump_motor_eff_weighted_average_v_after = #{
        pump_motor_eff_weighted_average_v_after
      }")
    puts("### DEBUGGING: pump_motor_bhp_weighted_average_v_before = #{
      pump_motor_bhp_weighted_average_v_before
    } | pump_motor_bhp_weighted_average_v_after = #{
        pump_motor_bhp_weighted_average_v_after
      }")
    puts("### DEBUGGING: pump part load curve coeffi 1 = #{
      pump_var_part_load_curve_coeff1_weighted_avg_before
    } | coeff1_a = #{
        pump_var_part_load_curve_coeff1_weighted_avg_after
      }")
    puts("### DEBUGGING: pump part load curve coeffi 2 = #{
      pump_var_part_load_curve_coeff2_weighted_avg_before
    } | coeff2_a = #{pump_var_part_load_curve_coeff2_weighted_avg_after}")
    puts("### DEBUGGING: pump part load curve coeffi 3 = #{
      pump_var_part_load_curve_coeff3_weighted_avg_before
    } | coeff3_a = #{pump_var_part_load_curve_coeff3_weighted_avg_after}")
    puts("### DEBUGGING: pump part load curve coeffi 4 = #{
      pump_var_part_load_curve_coeff4_weighted_avg_before
    } | coeff4_a = #{pump_var_part_load_curve_coeff4_weighted_avg_after}")
    coefficient_set_different = false
    if (pump_var_part_load_curve_coeff1_weighted_avg_before !=
        pump_var_part_load_curve_coeff1_weighted_avg_after) ||
       (pump_var_part_load_curve_coeff2_weighted_avg_before !=
        pump_var_part_load_curve_coeff2_weighted_avg_after) ||
       (pump_var_part_load_curve_coeff3_weighted_avg_before !=
        pump_var_part_load_curve_coeff3_weighted_avg_after) ||
       (pump_var_part_load_curve_coeff4_weighted_avg_before !=
        pump_var_part_load_curve_coeff4_weighted_avg_after)
      coefficient_set_different = true
    end
    assert_equal(true, coefficient_set_different,
                 'Pump part load curve coefficients did not change as expected.')

    # check performance improvement
    if pump_motor_eff_weighted_average_v_after < pump_motor_eff_weighted_average_c_before
      assert(
        false,
        "Pump motor efficiency got worse compared to existing constant speed pump. Before: #{
          pump_motor_eff_weighted_average_c_before
        }, After: #{
            pump_motor_eff_weighted_average_c_after
          }"
      )
    end
    if pump_motor_eff_weighted_average_v_after < pump_motor_eff_weighted_average_v_before
      assert(
        false,
        "Pump motor efficiency got worse compared to existing variable speed pump. Before: #{
          pump_motor_eff_weighted_average_v_before
        }, After: #{pump_motor_eff_weighted_average_v_after}"
      )
    end

    # check control specs
    puts("### DEBUGGING: instance_test_name = #{instance_test_name}")
    puts("### DEBUGGING: fraction_chw_hw_oat_reset_enabled_b = #{
      fraction_chw_hw_oat_reset_enabled_b
    } | fraction_chw_hw_oat_reset_enabled_a = #{
        fraction_chw_hw_oat_reset_enabled_a
      }")
    puts("### DEBUGGING: fraction_cw_oat_reset_enabled_b = #{
      fraction_cw_oat_reset_enabled_b
    } | fraction_cw_oat_reset_enabled_a = #{
        fraction_cw_oat_reset_enabled_a
      }")
    refute_equal(fraction_chw_hw_oat_reset_enabled_b, fraction_chw_hw_oat_reset_enabled_a)
    if instance_test_name.include?('air_cooled') ||
       instance_test_name.include?('district') ||
       instance_test_name.include?('water_source') ||
       instance_test_name.include?('ground_source')
      assert_equal(fraction_cw_oat_reset_enabled_a, 0.0,
                   'Fraction CW OAT Reset Enabled A is not equal to 0.0')
    else
      assert_equal(fraction_cw_oat_reset_enabled_a, 1.0,
                   'Fraction CW OAT Reset Enabled A is not equal to 1.0')
    end

    # # save the model to test output directory
    # output_file_path = "#{File.dirname(__FILE__)}/output/#{instance_test_name}.osm"
    # model.save(output_file_path, true)
  end

  # test 1: check measure arguments
  def test_number_of_arguments_and_argument_names
    # create an instance of the measure
    measure = UpgradeHvacPump.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(3, arguments.size)
    assert_equal('chw_hw_oat_reset', arguments[0].name)
    assert_equal('cw_oat_reset', arguments[1].name)
    assert_equal('debug_verbose', arguments[2].name)
  end

  # test 2: check model without simulation
  def test_models_without_simulations
    # test models
    test_sets = []
    # test: 380_doas_with_fan_coil_air_cooled_chiller_with_boiler
    test_sets << {
      model: '380_doas_with_fan_coil_air_cooled_chiller_with_boiler',
      weather: 'NY_New_York_John_F_Ke_744860_16', # weather file does not matter with current tests
      result: 'Success'
    }
    # test: 380_doas_with_fan_coil_chiller_with_boiler
    test_sets << {
      model: '380_doas_with_fan_coil_chiller_with_boiler',
      weather: 'NY_New_York_John_F_Ke_744860_16', # weather file does not matter with current tests
      result: 'Success'
    }
    # test: 380_vav_air_cooled_chiller_with_gas_boiler_reheat
    test_sets << {
      model: '380_vav_air_cooled_chiller_with_gas_boiler_reheat',
      weather: 'NY_New_York_John_F_Ke_744860_16', # weather file does not matter with current tests
      result: 'Success'
    }
    # test: 380_vav_chiller_with_gas_boiler_reheat
    test_sets << {
      model: '380_vav_chiller_with_gas_boiler_reheat',
      weather: 'NY_New_York_John_F_Ke_744860_16', # weather file does not matter with current tests
      result: 'Success'
    }
    # test: 310_vav_district_chilled_water_with_district_hot_water_reheat
    test_sets << {
      model: '310_vav_district_chilled_water_with_district_hot_water_reheat',
      weather: 'NY_New_York_John_F_Ke_744860_16', # weather file does not matter with current tests
      result: 'Success'
    }
    # test: 310_doas_with_water_source_heat_pumps_with_ground_source_heat_pump
    test_sets << {
      model: '310_doas_with_water_source_heat_pumps_with_ground_source_heat_pump',
      weather: 'NY_New_York_John_F_Ke_744860_16', # weather file does not matter with current tests
      result: 'Success'
    }
    # test: 310_psz_ac_with_district_hot_water
    test_sets << {
      model: '310_psz_ac_with_district_hot_water',
      weather: 'NY_New_York_John_F_Ke_744860_16', # weather file does not matter with current tests
      result: 'Success'
    }
    # test: 310_doas_with_fan_coil_district_chilled_water_with_district_hot_water
    test_sets << {
      model: '310_doas_with_fan_coil_district_chilled_water_with_district_hot_water',
      weather: 'NY_New_York_John_F_Ke_744860_16', # weather file does not matter with current tests
      result: 'Success'
    }
    # test: 310_pvav_with_district_hot_water_reheat
    test_sets << {
      model: '310_pvav_with_district_hot_water_reheat',
      weather: 'NY_New_York_John_F_Ke_744860_16', # weather file does not matter with current tests
      result: 'Success'
    }
    # test: 310_doas_with_fan_coil_district_chilled_water_with_baseboard_electric
    test_sets << {
      model: '310_doas_with_fan_coil_district_chilled_water_with_baseboard_electric',
      weather: 'NY_New_York_John_F_Ke_744860_16', # weather file does not matter with current tests
      result: 'Success'
    }

    test_sets.each do |set|
      instance_test_name = set[:model]
      puts "instance test name: #{instance_test_name}"
      osm_path = models_for_tests.select { |x| set[:model] == File.basename(x, '.osm') }
      epw_path = epws_for_tests.select { |x| set[:weather] == File.basename(x, '.epw') }
      assert(!osm_path.empty?)
      assert(!epw_path.empty?)
      osm_path = osm_path[0]
      epw_path = epw_path[0]

      # apply measure to model
      apply_and_test_model(osm_path, instance_test_name)
    end
  end

  # # test 3: check model with simulation
  # def test_models_with_simulations
  #   # test models
  #   test_sets = []
  #   # test: 310_vav_chiller_with_gas_boiler_reheat
  #   test_sets << {
  #     model: '310_vav_chiller_with_gas_boiler_reheat',
  #     weather: 'G0101010',
  #     result: 'Success'
  #   }

  #   test_sets.each do |set|
  #     instance_test_name = set[:model]
  #     puts "instance test name: #{instance_test_name}"
  #     osm_path = models_for_tests.select { |x| set[:model] == File.basename(x, '.osm') }
  #     epw_path = epws_for_tests.select { |x| set[:weather] == File.basename(x, '.epw') }
  #     assert(!osm_path.empty?)
  #     assert(!epw_path.empty?)
  #     osm_path = osm_path[0]
  #     epw_path = epw_path[0]

  #     # apply measure to model
  #     result = apply_measure_and_run_simulations(osm_path, epw_path, instance_test_name)
  #   end
  # end

  # # supporting method: define measure and arguments and simulate models with and without measure
  # def apply_measure_and_run_simulations(osm_path, epw_path, test_name)
  #   # build standard
  #   template = 'ComStock 90.1-2019'
  #   std = Standard.build(template)

  #   # Create an instance of the measure
  #   measure = UpgradeHvacPump.new

  #   # Load the model; only used here for populating arguments
  #   model = load_model(osm_path)

  #   # get arguments
  #   arguments = measure.arguments(model)
  #   argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

  #   # populate specific argument for testing
  #   arguments.each_with_index do |arg, idx|
  #     temp_arg_var = arg.clone
  #     case arg.name
  #     when 'chw_hw_oat_reset'
  #       chw_hw_oat_reset = arguments[idx].clone
  #       chw_hw_oat_reset.setValue(true)
  #       argument_map[arg.name] = chw_hw_oat_reset
  #     when 'cw_oat_reset'
  #       cw_oat_reset = arguments[idx].clone
  #       cw_oat_reset.setValue(false)
  #       argument_map[arg.name] = cw_oat_reset
  #     when 'debug_verbose'
  #       debug_verbose = arguments[idx].clone
  #       debug_verbose.setValue(true)
  #       argument_map[arg.name] = debug_verbose
  #     else
  #       argument_map[arg.name] = temp_arg_var
  #     end
  #   end

  #   # Don't apply the measure to the model and run the model: baseline model
  #   result = set_weather_and_apply_measure_and_run(
  #     "#{test_name}_b", measure, argument_map,
  #     osm_path, epw_path, run_model: true, apply: false
  #   )
  #   model = load_model(model_output_path("#{test_name}_b"))

  #   # get pump specs for baseline
  #   pumps_const_spd = model.getPumpConstantSpeeds
  #   pump_specs_cst_spd_before = UpgradeHvacPump.pump_specifications([], pumps_const_spd, std)
  #   pump_rated_flow_total_c_before = pump_specs_cst_spd_before[1]
  #   pump_motor_eff_weighted_average_c_before = pump_specs_cst_spd_before[2]
  #   pump_motor_bhp_weighted_average_c_before = pump_specs_cst_spd_before[3]
  #   pumps_var_spd = model.getPumpVariableSpeeds
  #   pump_specs_var_spd_before = UpgradeHvacPump.pump_specifications([], pumps_var_spd, std)
  #   pump_rated_flow_total_v_before = pump_specs_var_spd_before[1]
  #   pump_motor_eff_weighted_average_v_before = pump_specs_var_spd_before[2]
  #   pump_motor_bhp_weighted_average_v_before = pump_specs_var_spd_before[3]
  #   pump_var_part_load_curve_coeff1_weighted_avg_before = pump_specs_var_spd_before[4]
  #   pump_var_part_load_curve_coeff2_weighted_avg_before = pump_specs_var_spd_before[5]
  #   pump_var_part_load_curve_coeff3_weighted_avg_before = pump_specs_var_spd_before[6]
  #   pump_var_part_load_curve_coeff4_weighted_avg_before = pump_specs_var_spd_before[7]

  #   # get control specs for baseline
  #   fraction_chw_hw_oat_reset_enabled_b, fraction_cw_oat_reset_enabled_b =
  #     UpgradeHvacPump.control_specifications(model)

  #   # Apply the measure to the model and run the model: upgrade model
  #   result = set_weather_and_apply_measure_and_run("#{test_name}_u", measure, argument_map,
  #                                                  osm_path, epw_path, run_model: true, apply: true)
  #   model = load_model(model_output_path("#{test_name}_u"))

  #   # get pump specs for upgrade
  #   pumps_const_spd = model.getPumpConstantSpeeds
  #   pump_specs_cst_spd_after = UpgradeHvacPump.pump_specifications([], pumps_const_spd, std)
  #   pump_rated_flow_total_c_after = pump_specs_cst_spd_after[1]
  #   pump_motor_eff_weighted_average_c_after = pump_specs_cst_spd_after[2]
  #   pump_motor_bhp_weighted_average_c_after = pump_specs_cst_spd_after[3]
  #   pumps_var_spd = model.getPumpVariableSpeeds
  #   pump_specs_var_spd_after = UpgradeHvacPump.pump_specifications([], pumps_var_spd, std)
  #   pump_rated_flow_total_v_after = pump_specs_var_spd_after[1]
  #   pump_motor_eff_weighted_average_v_after = pump_specs_var_spd_after[2]
  #   pump_motor_bhp_weighted_average_v_after = pump_specs_var_spd_after[3]
  #   pump_var_part_load_curve_coeff1_weighted_avg_after = pump_specs_var_spd_after[4]
  #   pump_var_part_load_curve_coeff2_weighted_avg_after = pump_specs_var_spd_after[5]
  #   pump_var_part_load_curve_coeff3_weighted_avg_after = pump_specs_var_spd_after[6]
  #   pump_var_part_load_curve_coeff4_weighted_avg_after = pump_specs_var_spd_after[7]

  #   # get control specs for upgrade
  #   fraction_chw_hw_oat_reset_enabled_a, fraction_cw_oat_reset_enabled_a =
  #     UpgradeHvacPump.control_specifications(model)

  #   # show the output
  #   show_output(result)

  #   # assert that it ran correctly
  #   assert_equal('Success', result.value.valueName)

  #   refute_empty(result.stepInitialCondition)

  #   refute_empty(result.stepFinalCondition)

  #   # check chilled water system specs
  #   puts("### DEBUGGING: pump_motor_eff_weighted_average_c_before = #{
  #     pump_motor_eff_weighted_average_c_before
  #   } | pump_motor_eff_weighted_average_c_after = #{
  #       pump_motor_eff_weighted_average_c_after
  #     }")
  #   puts("### DEBUGGING: pump_motor_bhp_weighted_average_c_before = #{
  #     pump_motor_bhp_weighted_average_c_before
  #   } | pump_motor_bhp_weighted_average_c_after = #{
  #       pump_motor_bhp_weighted_average_c_after
  #     }")
  #   puts("### DEBUGGING: pump_motor_eff_weighted_average_v_before = #{
  #     pump_motor_eff_weighted_average_v_before
  #   } | pump_motor_eff_weighted_average_v_after = #{
  #     pump_motor_eff_weighted_average_v_after
  #   }")
  #   puts("### DEBUGGING: pump_motor_bhp_weighted_average_v_before = #{
  #     pump_motor_bhp_weighted_average_v_before
  #   } | pump_motor_bhp_weighted_average_v_after = #{
  #       pump_motor_bhp_weighted_average_v_after
  #     }")
  #   puts("### DEBUGGING: pump part load curve coeffi 1 = #{
  #     pump_var_part_load_curve_coeff1_weighted_avg_before
  #   } | coeff1_a = #{
  #       pump_var_part_load_curve_coeff1_weighted_avg_after
  #     }")
  #   puts("### DEBUGGING: pump part load curve coeffi 2 = #{
  #     pump_var_part_load_curve_coeff2_weighted_avg_before
  #   } | coeff2_a = #{
  #       pump_var_part_load_curve_coeff2_weighted_avg_after
  #     }")
  #   puts("### DEBUGGING: pump part load curve coeffi 3 = #{
  #     pump_var_part_load_curve_coeff3_weighted_avg_before
  #   } | coeff3_a = #{
  #     pump_var_part_load_curve_coeff3_weighted_avg_after
  #   }")
  #   puts("### DEBUGGING: pump part load curve coeffi 4 = #{
  #     pump_var_part_load_curve_coeff4_weighted_avg_before
  #   } | coeff4_a = #{
  #     pump_var_part_load_curve_coeff4_weighted_avg_after
  #   }")
  #   coefficient_set_different = false
  #   if (pump_var_part_load_curve_coeff1_weighted_avg_before !=
  #       pump_var_part_load_curve_coeff1_weighted_avg_after) ||
  #      (pump_var_part_load_curve_coeff2_weighted_avg_before !=
  #       pump_var_part_load_curve_coeff2_weighted_avg_after) ||
  #      (pump_var_part_load_curve_coeff3_weighted_avg_before !=
  #       pump_var_part_load_curve_coeff3_weighted_avg_after) ||
  #      (pump_var_part_load_curve_coeff4_weighted_avg_before !=
  #       pump_var_part_load_curve_coeff4_weighted_avg_after)
  #     coefficient_set_different = true
  #   end
  #   assert_equal(true, coefficient_set_different)

  #   # # check control specs
  #   # puts("### DEBUGGING: fraction_chw_hw_oat_reset_enabled_b = #{
  #   #   fraction_chw_hw_oat_reset_enabled_b
  #   # } | fraction_chw_hw_oat_reset_enabled_a = #{
  #   #     fraction_chw_hw_oat_reset_enabled_a
  #   #   }")
  #   # puts("### DEBUGGING: fraction_cw_oat_reset_enabled_b = #{
  #   #   fraction_cw_oat_reset_enabled_b
  #   # } | fraction_cw_oat_reset_enabled_a = #{
  #   #     fraction_cw_oat_reset_enabled_a
  #   #   }")
  #   # refute_equal(fraction_chw_hw_oat_reset_enabled_b, fraction_chw_hw_oat_reset_enabled_a)
  #   # assert_equal(fraction_cw_oat_reset_enabled_a, 1.0)
  # end

  # # supporting method: set weather, apply/not-apply measure, run/not-run simulation
  # def set_weather_and_apply_measure_and_run(
  #   test_name, measure, argument_map, osm_path, epw_path,
  #   run_model: false, model: nil, apply: true, expected_results: 'Success'
  # )
  #   assert(File.exist?(osm_path))
  #   assert(File.exist?(epw_path))
  #   ddy_path = "#{epw_path.gsub('.epw', '')}.ddy"

  #   # create run directory if it does not exist
  #   FileUtils.mkdir_p(run_dir(test_name))
  #   assert(File.exist?(run_dir(test_name)))

  #   # change into run directory for tests
  #   start_dir = Dir.pwd
  #   Dir.chdir run_dir(test_name)

  #   # remove prior runs if they exist
  #   FileUtils.rm_f(model_output_path(test_name))
  #   FileUtils.rm_f(report_path(test_name))

  #   # copy the osm and epw to the test directory
  #   new_osm_path = "#{run_dir(test_name)}/#{File.basename(osm_path)}"
  #   FileUtils.cp(osm_path, new_osm_path)
  #   new_epw_path = "#{run_dir(test_name)}/#{File.basename(epw_path)}"
  #   FileUtils.cp(epw_path, new_epw_path)

  #   # create an instance of a runner
  #   runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)

  #   # load the test model
  #   model = load_model(new_osm_path) if model.nil?

  #   # set model weather file
  #   epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(new_epw_path))
  #   OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
  #   assert(model.weatherFile.is_initialized)

  #   # set design days
  #   if File.exist?(ddy_path)

  #     # remove all the Design Day objects that are in the file
  #     model.getObjectsByType('OS:SizingPeriod:DesignDay'.to_IddObjectType).each(&:remove)

  #     # load ddy
  #     ddy_model = OpenStudio::EnergyPlus.loadAndTranslateIdf(ddy_path).get

  #     ddy_model.getDesignDays.sort.each do |d|
  #       # grab only the ones that matter
  #       ddy_list = [
  #         /Htg 99.6. Condns DB/, # Annual heating 99.6%
  #         /Clg .4. Condns WB=>MDB/, # Annual humidity (for cooling towers and evap coolers)
  #         /Clg .4. Condns DB=>MWB/, # Annual cooling
  #         /August .4. Condns DB=>MCWB/, # Monthly cooling DB=>MCWB (for solar-gain-driven cooling)
  #         /September .4. Condns DB=>MCWB/,
  #         /October .4. Condns DB=>MCWB/
  #       ]
  #       ddy_list.each do |ddy_name_regex|
  #         if d.name.get.to_s.match?(ddy_name_regex)
  #           runner.registerInfo("Adding object #{d.name}")

  #           # add the object to the existing model
  #           model.addObject(d.clone)
  #           break
  #         end
  #       end
  #     end

  #     # assert
  #     assert_equal(false, model.getDesignDays.empty?)
  #   end

  #   # adding output variables (for debugging)
  #   out_vars = [
  #     'Site Outdoor Air Drybulb Temperature',
  #     'Pump Electricity Rate',
  #     'Pump Mass Flow Rate',
  #     'Pump Outlet Temperature',
  #     'Chiller Cycling Ratio',
  #     'Chiller Electricity Rate',
  #     'Chiller Evaporator Outlet Temperature',
  #     'Chiller COP',
  #     'Cooling Tower Fan Electricity Rate',
  #     'Cooling Tower Inlet Temperature',
  #     'Cooling Tower Outlet Temperature',
  #     'Cooling Tower Heat Transfer Rate',
  #     'Cooling Tower Mass Flow Rate',
  #     'Cooling Tower Fan Part Load Ratio',
  #     'Cooling Tower Air Flow Rate Ratio',
  #     'Cooling Tower Operating Cells Count',
  #     'Boiler Heating Rate',
  #     'Boiler Inlet Temperature',
  #     'Boiler Outlet Temperature',
  #     'Boiler Mass Flow Rate',
  #     'Boiler Part Load Ratio',
  #     'Boiler Efficiency',
  #     'Boiler NaturalGas Rate'
  #   ]
  #   out_vars.each do |out_var_name|
  #     ov = OpenStudio::Model::OutputVariable.new('ov', model)
  #     ov.setKeyValue('*')
  #     ov.setReportingFrequency('timestep')
  #     ov.setVariableName(out_var_name)
  #   end
  #   model.getOutputControlFiles.setOutputCSV(true)

  #   if apply
  #     # run the measure
  #     puts "\nAPPLYING MEASURE..."
  #     measure.run(model, runner, argument_map)
  #     result = runner.result
  #     result_success = result.value.valueName == 'Success'
  #     assert_equal(expected_results, result.value.valueName)

  #     # Show the output
  #     show_output(result)
  #   end

  #   # Save model
  #   model.save(model_output_path(test_name), true)

  #   if run_model
  #     puts "\nRUNNING MODEL..."

  #     std = Standard.build('90.1-2013')
  #     std.model_run_simulation_and_log_errors(model, run_dir(test_name))

  #     # Check that the model ran successfully
  #     assert(File.exist?(sql_path(test_name)))
  #   end

  #   # change back directory
  #   Dir.chdir(start_dir)

  #   result
  # end
end
