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

class UpgradeHvacChillerTest < Minitest::Test
  # supporting method: return file paths to test models in test directory
  def models_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/models/*.osm'))
    paths.map { |path| File.expand_path(path) }
  end

  # supporting method: return file paths to epw files in test directory
  def epws_for_tests
    paths = Dir.glob(File.join(File.dirname(__FILE__), '../../../tests/weather/*.epw'))
    paths.map { |path| File.expand_path(path) }
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
    # always generate test output in specially named 'output' directory so result files are not made part of the measure
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
  def apply_and_test_model(path, _instance_test_name)
    # build standard
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)

    # create an instance of the measure
    measure = UpgradeHvacChiller.new

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

    # create hash of argument values.
    # If the argument has a default that you want to use, you don't need it in the hash
    args_hash = {}
    args_hash['space_name'] = 'New Space'
    # using defaults values from measure.rb for other arguments

    # populate argument with specified hash value if specified
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      case arg.name
      when 'debug_verbose'
        debug_verbose = arguments[idx].clone
        debug_verbose.setValue(true)
        argument_map[arg.name] = debug_verbose
      when 'chw_oat_reset'
        chw_oat_reset = arguments[idx].clone
        chw_oat_reset.setValue(true)
        argument_map[arg.name] = chw_oat_reset
      when 'cw_oat_reset'
        cw_oat_reset = arguments[idx].clone
        cw_oat_reset.setValue(true)
        argument_map[arg.name] = cw_oat_reset
      else
        argument_map[arg.name] = temp_arg_var
      end
    end

    # get chiller specs before measure
    chillers = model.getChillerElectricEIRs
    results_b = UpgradeHvacChiller.chiller_specifications(chillers)
    counts_chillers_acc_b = results_b[0]
    capacity_total_w_acc_b = results_b[1]
    cop_acc_b = results_b[2]
    counts_chillers_wcc_b = results_b[3]
    capacity_total_w_wcc_b = results_b[4]
    cop_wcc_b = results_b[5]
    curve_summary_b = results_b[6]

    # get pump specs before measure
    pumps_const_spd = model.getPumpConstantSpeeds
    pump_specs_cst_spd_before = UpgradeHvacChiller.pump_specifications([], pumps_const_spd, std)
    pump_specs_cst_spd_before[1]
    pump_motor_eff_weighted_average_c_before = pump_specs_cst_spd_before[2]
    pump_motor_bhp_weighted_average_c_before = pump_specs_cst_spd_before[3]
    pumps_var_spd = model.getPumpVariableSpeeds
    pump_specs_var_spd_before = UpgradeHvacChiller.pump_specifications([], pumps_var_spd, std)
    pump_specs_var_spd_before[1]
    pump_motor_eff_weighted_average_v_before = pump_specs_var_spd_before[2]
    pump_motor_bhp_weighted_average_v_before = pump_specs_var_spd_before[3]
    pump_var_part_load_curve_coeff1_weighted_avg_before = pump_specs_var_spd_before[4]
    pump_var_part_load_curve_coeff2_weighted_avg_before = pump_specs_var_spd_before[5]
    pump_var_part_load_curve_coeff3_weighted_avg_before = pump_specs_var_spd_before[6]
    pump_var_part_load_curve_coeff4_weighted_avg_before = pump_specs_var_spd_before[7]

    # get control specs before measure
    fraction_chw_oat_reset_enabled_b, fraction_cw_oat_reset_enabled_b = UpgradeHvacChiller.control_specifications(model)

    # run the measure
    measure.run(model, runner, argument_map)
    result = runner.result

    # get chiller specs after measure
    chillers = model.getChillerElectricEIRs
    results_a = UpgradeHvacChiller.chiller_specifications(chillers)
    counts_chillers_acc_a = results_a[0]
    capacity_total_w_acc_a = results_a[1]
    cop_acc_a = results_a[2]
    counts_chillers_wcc_a = results_a[3]
    capacity_total_w_wcc_a = results_a[4]
    cop_wcc_a = results_a[5]
    curve_summary_a = results_a[6]

    # get pump specs after measure
    pumps_const_spd = model.getPumpConstantSpeeds
    pump_specs_cst_spd_after = UpgradeHvacChiller.pump_specifications([], pumps_const_spd, std)
    pump_specs_cst_spd_after[1]
    pump_motor_eff_weighted_average_c_after = pump_specs_cst_spd_after[2]
    pump_motor_bhp_weighted_average_c_after = pump_specs_cst_spd_after[3]
    pumps_var_spd = model.getPumpVariableSpeeds
    pump_specs_var_spd_after = UpgradeHvacChiller.pump_specifications([], pumps_var_spd, std)
    pump_specs_var_spd_after[1]
    pump_motor_eff_weighted_average_v_after = pump_specs_var_spd_after[2]
    pump_motor_bhp_weighted_average_v_after = pump_specs_var_spd_after[3]
    pump_var_part_load_curve_coeff1_weighted_avg_after = pump_specs_var_spd_after[4]
    pump_var_part_load_curve_coeff2_weighted_avg_after = pump_specs_var_spd_after[5]
    pump_var_part_load_curve_coeff3_weighted_avg_after = pump_specs_var_spd_after[6]
    pump_var_part_load_curve_coeff4_weighted_avg_after = pump_specs_var_spd_after[7]

    # get control specs after measure
    fraction_chw_oat_reset_enabled_a, fraction_cw_oat_reset_enabled_a = UpgradeHvacChiller.control_specifications(model)

    # show the output
    show_output(result)

    # assert that it ran correctly
    assert_equal('Success', result.value.valueName)

    refute_empty(result.stepInitialCondition)

    refute_empty(result.stepFinalCondition)

    # check chilled water system specs
    puts("### DEBUGGING: counts_chillers_acc_b = #{counts_chillers_acc_b} | counts_chillers_acc_a = #{counts_chillers_acc_a}")
    puts("### DEBUGGING: capacity_total_w_acc_b = #{capacity_total_w_acc_b} | capacity_total_w_acc_a = #{capacity_total_w_acc_a}")
    puts("### DEBUGGING: cop_acc_b = #{cop_acc_b} | cop_acc_a = #{cop_acc_a}")
    puts("### DEBUGGING: counts_chillers_wcc_b = #{counts_chillers_wcc_b} | counts_chillers_wcc_a = #{counts_chillers_wcc_a}")
    puts("### DEBUGGING: capacity_total_w_wcc_b = #{capacity_total_w_wcc_b} | capacity_total_w_wcc_a = #{capacity_total_w_wcc_a}")
    puts("### DEBUGGING: cop_wcc_b = #{cop_wcc_b} | cop_wcc_a = #{cop_wcc_a}")
    puts("### DEBUGGING: pump_motor_eff_weighted_average_c_before = #{pump_motor_eff_weighted_average_c_before} | pump_motor_eff_weighted_average_c_after = #{pump_motor_eff_weighted_average_c_after}")
    puts("### DEBUGGING: pump_motor_bhp_weighted_average_c_before = #{pump_motor_bhp_weighted_average_c_before} | pump_motor_bhp_weighted_average_c_after = #{pump_motor_bhp_weighted_average_c_after}")
    puts("### DEBUGGING: pump_motor_eff_weighted_average_v_before = #{pump_motor_eff_weighted_average_v_before} | pump_motor_eff_weighted_average_v_after = #{pump_motor_eff_weighted_average_v_after}")
    puts("### DEBUGGING: pump_motor_bhp_weighted_average_v_before = #{pump_motor_bhp_weighted_average_v_before} | pump_motor_bhp_weighted_average_v_after = #{pump_motor_bhp_weighted_average_v_after}")
    puts("### DEBUGGING: pump part load curve coeffi 1 = #{pump_var_part_load_curve_coeff1_weighted_avg_before} | coeff1_a = #{pump_var_part_load_curve_coeff1_weighted_avg_after}")
    puts("### DEBUGGING: pump part load curve coeffi 2 = #{pump_var_part_load_curve_coeff2_weighted_avg_before} | coeff2_a = #{pump_var_part_load_curve_coeff2_weighted_avg_after}")
    puts("### DEBUGGING: pump part load curve coeffi 3 = #{pump_var_part_load_curve_coeff3_weighted_avg_before} | coeff3_a = #{pump_var_part_load_curve_coeff3_weighted_avg_after}")
    puts("### DEBUGGING: pump part load curve coeffi 4 = #{pump_var_part_load_curve_coeff4_weighted_avg_before} | coeff4_a = #{pump_var_part_load_curve_coeff4_weighted_avg_after}")
    coefficient_set_different = false
    if (pump_var_part_load_curve_coeff1_weighted_avg_before != pump_var_part_load_curve_coeff1_weighted_avg_after) ||
       (pump_var_part_load_curve_coeff2_weighted_avg_before != pump_var_part_load_curve_coeff2_weighted_avg_after) ||
       (pump_var_part_load_curve_coeff3_weighted_avg_before != pump_var_part_load_curve_coeff3_weighted_avg_after) ||
       (pump_var_part_load_curve_coeff4_weighted_avg_before != pump_var_part_load_curve_coeff4_weighted_avg_after)
      coefficient_set_different = true
    end

    assert_equal(counts_chillers_acc_b, counts_chillers_acc_a)
    assert_equal(capacity_total_w_acc_b, capacity_total_w_acc_a)
    if cop_acc_b != 0 && cop_acc_b <= 5.32 # this if statement was added because of this: https://github.com/NREL/openstudio-standards/issues/1904
      refute_equal(cop_acc_b, cop_acc_a)
    end
    assert_equal(counts_chillers_wcc_b, counts_chillers_wcc_a)
    assert_equal(capacity_total_w_wcc_b, capacity_total_w_wcc_a)
    refute_equal(cop_wcc_b, cop_wcc_a) unless cop_wcc_b == 0 # COP equal to zero means case when there is no WCC
    assert_equal(true, coefficient_set_different)

    # check curve name changes
    curve_summary_b.keys.each do |chiller_name|
      name_cap_f_t_b = curve_summary_b[chiller_name]['cap_f_t']
      name_eir_f_t_b = curve_summary_b[chiller_name]['eir_f_t']
      name_eir_f_plr_b = curve_summary_b[chiller_name]['eir_f_plr']
      name_cap_f_t_a = curve_summary_a[chiller_name]['cap_f_t']
      name_eir_f_t_a = curve_summary_a[chiller_name]['eir_f_t']
      name_eir_f_plr_a = curve_summary_a[chiller_name]['eir_f_plr']
      refute_equal(name_cap_f_t_b, name_cap_f_t_a)
      refute_equal(name_eir_f_t_b, name_eir_f_t_a)
      refute_equal(name_eir_f_plr_b, name_eir_f_plr_a)
    end

    # check control specs
    puts("### DEBUGGING: fraction_chw_oat_reset_enabled_b = #{fraction_chw_oat_reset_enabled_b} | fraction_chw_oat_reset_enabled_a = #{fraction_chw_oat_reset_enabled_a}")
    puts("### DEBUGGING: fraction_cw_oat_reset_enabled_b = #{fraction_cw_oat_reset_enabled_b} | fraction_cw_oat_reset_enabled_a = #{fraction_cw_oat_reset_enabled_a}")
    refute_equal(fraction_chw_oat_reset_enabled_b, fraction_chw_oat_reset_enabled_a)
    if counts_chillers_wcc_b == 0
      assert_equal(fraction_cw_oat_reset_enabled_a, 0.0)
    else
      assert_equal(fraction_cw_oat_reset_enabled_a, 1.0)
    end

    # # save the model to test output directory
    # output_file_path = "#{File.dirname(__FILE__)}/output/#{instance_test_name}.osm"
    # model.save(output_file_path, true)
  end

  # supporting method: hard-size model
  def _mimic_hardsize_model(model, test_dir)
    standard = Standard.build('ComStock DOE Ref Pre-1980')

    # Run a sizing run to determine equipment capacities and flow rates
    if standard.model_run_sizing_run(model, test_dir.to_s) == false
      puts('Sizing run for Hardsize model failed, cannot hard-size model.')
      return false
    end

    # APPLY
    model.applySizingValues

    # TODO: remove once this functionality is added to the OpenStudio C++ for hard sizing UnitarySystems
    model.getAirLoopHVACUnitarySystems.each do |unitary|
      if model.version < OpenStudio::VersionString.new('3.7.0')
        unitary.setSupplyAirFlowRateMethodDuringCoolingOperation('SupplyAirFlowRate')
        unitary.setSupplyAirFlowRateMethodDuringHeatingOperation('SupplyAirFlowRate')
      end
    end
    # TODO: remove once this functionality is added to the OpenStudio C++ for hard sizing Sizing:System
    model.getSizingSystems.each do |sizing_system|
      next if sizing_system.isDesignOutdoorAirFlowRateAutosized

      sizing_system.setSystemOutdoorAirMethod('ZoneSum')
    end

    model
  end

  # supporting method: set weather, apply/not-apply measure, run/not-run simulation
  def set_weather_and_apply_measure_and_run(test_name, measure, argument_map, osm_path, epw_path, run_model: false,
                                            model: nil, apply: true, expected_results: 'Success')
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

    # hardsize model
    model = _mimic_hardsize_model(model, "#{run_dir(test_name)}/SR")

    # adding output variables (for debugging)
    out_vars = [
      'Site Outdoor Air Drybulb Temperature',
      'Chiller Cycling Ratio',
      'Chiller Electricity Rate',
      'Chiller Evaporator Outlet Temperature',
      'Chiller COP',
      'Pump Electricity Rate',
      'Pump Mass Flow Rate',
      'Pump Outlet Temperature',
      'Cooling Tower Fan Electricity Rate',
      'Cooling Tower Inlet Temperature',
      'Cooling Tower Outlet Temperature',
      'Cooling Tower Heat Transfer Rate',
      'Cooling Tower Mass Flow Rate',
      'Cooling Tower Fan Part Load Ratio',
      'Cooling Tower Air Flow Rate Ratio',
      'Cooling Tower Operating Cells Count'
    ]
    out_vars.each do |out_var_name|
      ov = OpenStudio::Model::OutputVariable.new('ov', model)
      ov.setKeyValue('*')
      ov.setReportingFrequency('timestep')
      ov.setVariableName(out_var_name)
    end
    model.getOutputControlFiles.setOutputCSV(true)

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

    # Save model
    model.save(model_output_path(test_name), true)

    if run_model
      puts "\nRUNNING MODEL..."

      std = Standard.build('90.1-2013')
      std.model_run_simulation_and_log_errors(model, run_dir(test_name))

      # Check that the model ran successfully
      assert(File.exist?(sql_path(test_name)))
    end

    # change back directory
    Dir.chdir(start_dir)

    result
  end

  # supporting method: define measure and arguments and simulate models with and without measure
  def apply_measure_and_run_simulations(osm_path, epw_path, test_name)
    # build standard
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)

    # Create an instance of the measure
    measure = UpgradeHvacChiller.new

    # Load the model; only used here for populating arguments
    model = load_model(osm_path)

    # get arguments
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    # populate specific argument for testing
    arguments.each_with_index do |arg, idx|
      temp_arg_var = arg.clone
      case arg.name
      when 'upgrade_pump'
        upgrade_pump = arguments[idx].clone
        upgrade_pump.setValue(true)
        argument_map[arg.name] = upgrade_pump
      when 'chw_oat_reset'
        chw_oat_reset = arguments[idx].clone
        chw_oat_reset.setValue(true)
        argument_map[arg.name] = chw_oat_reset
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

    # Don't apply the measure to the model and run the model: baseline model
    set_weather_and_apply_measure_and_run("#{test_name}_b", measure, argument_map, osm_path, epw_path,
                                          run_model: true, apply: false)
    model = load_model(model_output_path("#{test_name}_b"))

    # get chiller specs for baseline
    chillers = model.getChillerElectricEIRs
    results_b = UpgradeHvacChiller.chiller_specifications(chillers)
    counts_chillers_acc_b = results_b[0]
    capacity_total_w_acc_b = results_b[1]
    cop_acc_b = results_b[2]
    counts_chillers_wcc_b = results_b[3]
    capacity_total_w_wcc_b = results_b[4]
    cop_wcc_b = results_b[5]
    curve_summary_b = results_b[6]

    # get pump specs for baseline
    pumps_const_spd = model.getPumpConstantSpeeds
    pump_specs_cst_spd_before = UpgradeHvacChiller.pump_specifications([], pumps_const_spd, std)
    pump_specs_cst_spd_before[1]
    pump_motor_eff_weighted_average_c_before = pump_specs_cst_spd_before[2]
    pump_motor_bhp_weighted_average_c_before = pump_specs_cst_spd_before[3]
    pumps_var_spd = model.getPumpVariableSpeeds
    pump_specs_var_spd_before = UpgradeHvacChiller.pump_specifications([], pumps_var_spd, std)
    pump_specs_var_spd_before[1]
    pump_motor_eff_weighted_average_v_before = pump_specs_var_spd_before[2]
    pump_motor_bhp_weighted_average_v_before = pump_specs_var_spd_before[3]
    pump_var_part_load_curve_coeff1_weighted_avg_before = pump_specs_var_spd_before[4]
    pump_var_part_load_curve_coeff2_weighted_avg_before = pump_specs_var_spd_before[5]
    pump_var_part_load_curve_coeff3_weighted_avg_before = pump_specs_var_spd_before[6]
    pump_var_part_load_curve_coeff4_weighted_avg_before = pump_specs_var_spd_before[7]

    # get control specs for baseline
    fraction_chw_oat_reset_enabled_b, fraction_cw_oat_reset_enabled_b = UpgradeHvacChiller.control_specifications(model)

    # Apply the measure to the model and run the model: upgrade model
    result = set_weather_and_apply_measure_and_run("#{test_name}_u", measure, argument_map, osm_path, epw_path,
                                                   run_model: true, apply: true)
    model = load_model(model_output_path("#{test_name}_u"))

    # get chiller specs for upgrade
    chillers = model.getChillerElectricEIRs
    results_a = UpgradeHvacChiller.chiller_specifications(chillers)
    counts_chillers_acc_a = results_a[0]
    capacity_total_w_acc_a = results_a[1]
    cop_acc_a = results_a[2]
    counts_chillers_wcc_a = results_a[3]
    capacity_total_w_wcc_a = results_a[4]
    cop_wcc_a = results_a[5]
    curve_summary_a = results_a[6]

    # get pump specs for upgrade
    pumps_const_spd = model.getPumpConstantSpeeds
    pump_specs_cst_spd_after = UpgradeHvacChiller.pump_specifications([], pumps_const_spd, std)
    pump_specs_cst_spd_after[1]
    pump_motor_eff_weighted_average_c_after = pump_specs_cst_spd_after[2]
    pump_motor_bhp_weighted_average_c_after = pump_specs_cst_spd_after[3]
    pumps_var_spd = model.getPumpVariableSpeeds
    pump_specs_var_spd_after = UpgradeHvacChiller.pump_specifications([], pumps_var_spd, std)
    pump_specs_var_spd_after[1]
    pump_motor_eff_weighted_average_v_after = pump_specs_var_spd_after[2]
    pump_motor_bhp_weighted_average_v_after = pump_specs_var_spd_after[3]
    pump_var_part_load_curve_coeff1_weighted_avg_after = pump_specs_var_spd_after[4]
    pump_var_part_load_curve_coeff2_weighted_avg_after = pump_specs_var_spd_after[5]
    pump_var_part_load_curve_coeff3_weighted_avg_after = pump_specs_var_spd_after[6]
    pump_var_part_load_curve_coeff4_weighted_avg_after = pump_specs_var_spd_after[7]

    # get control specs for upgrade
    fraction_chw_oat_reset_enabled_a, fraction_cw_oat_reset_enabled_a = UpgradeHvacChiller.control_specifications(model)

    # show the output
    show_output(result)

    # assert that it ran correctly
    assert_equal('Success', result.value.valueName)

    refute_empty(result.stepInitialCondition)

    refute_empty(result.stepFinalCondition)

    # check chilled water system specs
    puts("### DEBUGGING: counts_chillers_acc_b = #{counts_chillers_acc_b} | counts_chillers_acc_a = #{counts_chillers_acc_a}")
    puts("### DEBUGGING: capacity_total_w_acc_b = #{capacity_total_w_acc_b} | capacity_total_w_acc_a = #{capacity_total_w_acc_a}")
    puts("### DEBUGGING: cop_acc_b = #{cop_acc_b} | cop_acc_a = #{cop_acc_a}")
    puts("### DEBUGGING: counts_chillers_wcc_b = #{counts_chillers_wcc_b} | counts_chillers_wcc_a = #{counts_chillers_wcc_a}")
    puts("### DEBUGGING: capacity_total_w_wcc_b = #{capacity_total_w_wcc_b} | capacity_total_w_wcc_a = #{capacity_total_w_wcc_a}")
    puts("### DEBUGGING: cop_wcc_b = #{cop_wcc_b} | cop_wcc_a = #{cop_wcc_a}")
    puts("### DEBUGGING: pump_motor_eff_weighted_average_c_before = #{pump_motor_eff_weighted_average_c_before} | pump_motor_eff_weighted_average_c_after = #{pump_motor_eff_weighted_average_c_after}")
    puts("### DEBUGGING: pump_motor_bhp_weighted_average_c_before = #{pump_motor_bhp_weighted_average_c_before} | pump_motor_bhp_weighted_average_c_after = #{pump_motor_bhp_weighted_average_c_after}")
    puts("### DEBUGGING: pump_motor_eff_weighted_average_v_before = #{pump_motor_eff_weighted_average_v_before} | pump_motor_eff_weighted_average_v_after = #{pump_motor_eff_weighted_average_v_after}")
    puts("### DEBUGGING: pump_motor_bhp_weighted_average_v_before = #{pump_motor_bhp_weighted_average_v_before} | pump_motor_bhp_weighted_average_v_after = #{pump_motor_bhp_weighted_average_v_after}")
    puts("### DEBUGGING: pump part load curve coeffi 1 = #{pump_var_part_load_curve_coeff1_weighted_avg_before} | coeff1_a = #{pump_var_part_load_curve_coeff1_weighted_avg_after}")
    puts("### DEBUGGING: pump part load curve coeffi 2 = #{pump_var_part_load_curve_coeff2_weighted_avg_before} | coeff2_a = #{pump_var_part_load_curve_coeff2_weighted_avg_after}")
    puts("### DEBUGGING: pump part load curve coeffi 3 = #{pump_var_part_load_curve_coeff3_weighted_avg_before} | coeff3_a = #{pump_var_part_load_curve_coeff3_weighted_avg_after}")
    puts("### DEBUGGING: pump part load curve coeffi 4 = #{pump_var_part_load_curve_coeff4_weighted_avg_before} | coeff4_a = #{pump_var_part_load_curve_coeff4_weighted_avg_after}")
    coefficient_set_different = false
    if (pump_var_part_load_curve_coeff1_weighted_avg_before != pump_var_part_load_curve_coeff1_weighted_avg_after) ||
       (pump_var_part_load_curve_coeff2_weighted_avg_before != pump_var_part_load_curve_coeff2_weighted_avg_after) ||
       (pump_var_part_load_curve_coeff3_weighted_avg_before != pump_var_part_load_curve_coeff3_weighted_avg_after) ||
       (pump_var_part_load_curve_coeff4_weighted_avg_before != pump_var_part_load_curve_coeff4_weighted_avg_after)
      coefficient_set_different = true
    end

    assert_equal(counts_chillers_acc_b, counts_chillers_acc_a)
    assert_equal(capacity_total_w_acc_b, capacity_total_w_acc_a)
    if cop_acc_b != 0 && cop_acc_b <= 5.32 # this if statement was added because of this: https://github.com/NREL/openstudio-standards/issues/1904
      refute_equal(cop_acc_b, cop_acc_a)
    end
    assert_equal(counts_chillers_wcc_b, counts_chillers_wcc_a)
    assert_equal(capacity_total_w_wcc_b, capacity_total_w_wcc_a)
    refute_equal(cop_wcc_b, cop_wcc_a) unless cop_wcc_b == 0 # COP equal to zero means case when there is no WCC
    assert_equal(true, coefficient_set_different)

    # check curve name changes
    curve_summary_b.keys.each do |chiller_name|
      name_cap_f_t_b = curve_summary_b[chiller_name]['cap_f_t']
      name_eir_f_t_b = curve_summary_b[chiller_name]['eir_f_t']
      name_eir_f_plr_b = curve_summary_b[chiller_name]['eir_f_plr']
      name_cap_f_t_a = curve_summary_a[chiller_name]['cap_f_t']
      name_eir_f_t_a = curve_summary_a[chiller_name]['eir_f_t']
      name_eir_f_plr_a = curve_summary_a[chiller_name]['eir_f_plr']
      refute_equal(name_cap_f_t_b, name_cap_f_t_a)
      refute_equal(name_eir_f_t_b, name_eir_f_t_a)
      refute_equal(name_eir_f_plr_b, name_eir_f_plr_a)
    end

    # check control specs
    puts("### DEBUGGING: fraction_chw_oat_reset_enabled_b = #{fraction_chw_oat_reset_enabled_b} | fraction_chw_oat_reset_enabled_a = #{fraction_chw_oat_reset_enabled_a}")
    puts("### DEBUGGING: fraction_cw_oat_reset_enabled_b = #{fraction_cw_oat_reset_enabled_b} | fraction_cw_oat_reset_enabled_a = #{fraction_cw_oat_reset_enabled_a}")
    refute_equal(fraction_chw_oat_reset_enabled_b, fraction_chw_oat_reset_enabled_a)
    if counts_chillers_wcc_b == 0
      assert_equal(fraction_cw_oat_reset_enabled_a, 0.0)
    else
      assert_equal(fraction_cw_oat_reset_enabled_a, 1.0)
    end
  end

  # test 1: check measure arguments
  def test_number_of_arguments_and_argument_names
    # create an instance of the measure
    measure = UpgradeHvacChiller.new

    # make an empty model
    model = OpenStudio::Model::Model.new

    # get arguments and test that they are what we are expecting
    arguments = measure.arguments(model)
    assert_equal(4, arguments.size)
    assert_equal('upgrade_pump', arguments[0].name)
    assert_equal('chw_oat_reset', arguments[1].name)
    assert_equal('cw_oat_reset', arguments[2].name)
    assert_equal('debug_verbose', arguments[3].name)
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

    test_sets.each do |set|
      instance_test_name = set[:model]
      puts "instance test name: #{instance_test_name}"
      osm_path = models_for_tests.select { |x| set[:model] == File.basename(x, '.osm') }
      epw_path = epws_for_tests.select { |x| set[:weather] == File.basename(x, '.epw') }
      assert(!osm_path.empty?)
      assert(!epw_path.empty?)
      osm_path = osm_path[0]
      epw_path[0]

      # apply measure to model
      apply_and_test_model(osm_path, instance_test_name)
    end
  end

  # test 3: check model with simulation
  # this test is also used for single building model testing section in measure documentation
  def test_models_with_simulations
    # test models
    test_sets = []
    # test: 380_vav_chiller_with_gas_boiler_reheat
    test_sets << {
      model: '380_vav_chiller_with_gas_boiler_reheat',
      weather: 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16', # weather file does not matter with current tests
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
      apply_measure_and_run_simulations(osm_path, epw_path, instance_test_name)
    end
  end
end
