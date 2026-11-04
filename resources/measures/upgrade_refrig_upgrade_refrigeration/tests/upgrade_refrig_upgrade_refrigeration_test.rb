# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# dependencies
require 'openstudio'
require 'openstudio-standards'
require 'openstudio/measure/ShowRunnerOutput'
require 'fileutils'
require 'minitest/autorun'
require_relative '../measure'
require_relative '../../../../test/helpers/minitest_helper'

class UpgradeRefrigAdvancedRefrigerationTest < Minitest::Test
  def load_model(osm_path)
    translator = OpenStudio::OSVersion::VersionTranslator.new
    model = translator.loadModel(OpenStudio::Path.new(osm_path))
    assert(!model.empty?)
    model.get
  end

  def run_dir(test_name)
    # Always generate test output in a dedicated folder.
    File.join(__dir__, 'output', test_name.to_s)
  end

  def model_input_path(osm_name)
    File.join(File.dirname(__FILE__), '../../../tests/models', osm_name)
  end

  def epw_input_path(epw_name)
    File.join(File.dirname(__FILE__), '../../../tests/weather', epw_name)
  end

  def sql_refrigeration_electricity_gj(sql)
    end_use_query = <<~SQL
      SELECT Value
      FROM TabularDataWithStrings
      WHERE ReportName = 'AnnualBuildingUtilityPerformanceSummary'
        AND TableName = 'End Uses'
        AND RowName = 'Refrigeration'
        AND ColumnName = 'Electricity'
        AND Units = 'GJ'
    SQL

    val = sql.execAndReturnFirstDouble(end_use_query)
    return val.get if val.is_initialized

    meter_query = <<~SQL
      SELECT Value
      FROM TabularDataWithStrings
      WHERE ReportName = 'EnergyMeters'
        AND RowName = 'Refrigeration:Electricity'
        AND ColumnName = 'Electricity Annual Value'
        AND Units = 'GJ'
    SQL

    val = sql.execAndReturnFirstDouble(meter_query)
    assert(val.is_initialized, 'Unable to find refrigeration electricity in SQL output.')
    val.get
  end

  def refrigeration_model_metrics(model)
    case_count = model.getRefrigerationCases.size
    walkin_count = model.getRefrigerationWalkIns.size

    case_length_m = model.getRefrigerationCases.map(&:caseLength).sum
    walkin_floor_area_m2 = model.getRefrigerationWalkIns.map(&:insulatedFloorSurfaceArea).sum
    walkin_coil_capacity_w = model.getRefrigerationWalkIns.map(&:ratedCoilCoolingCapacity).sum

    {
      case_count: case_count,
      walkin_count: walkin_count,
      case_length_m: case_length_m,
      walkin_floor_area_m2: walkin_floor_area_m2,
      walkin_coil_capacity_w: walkin_coil_capacity_w
    }
  end

  def energy_metrics_from_sql(sql)
    total_site_j = sql.totalSiteEnergy
    assert(total_site_j.is_initialized, 'Total site energy was not available from SQL file.')

    {
      total_site_gj: OpenStudio.convert(total_site_j.get, 'J', 'GJ').get,
      refrigeration_electricity_gj: sql_refrigeration_electricity_gj(sql)
    }
  end

  def set_short_test_run_period(model)
    run_period = model.getRunPeriod
    run_period.setBeginMonth(1)
    run_period.setBeginDayOfMonth(1)
    run_period.setEndMonth(1)
    run_period.setEndDayOfMonth(14)
    run_period.setNumTimePeriodRepeats(1)
  end

  def run_model_and_get_sql(model, std, run_directory)
    assert(std.model_run_simulation_and_log_errors(model, run_directory), "Simulation failed in #{run_directory}.")
    assert(model.sqlFile.is_initialized, 'Model SQL file was not attached after simulation.')
    model.sqlFile.get
  end

  def test_number_of_arguments_and_argument_names
    measure = UpgradeRefrigeration.new
    model = OpenStudio::Model::Model.new

    arguments = measure.arguments(model)
    assert_equal(1, arguments.size)
    assert_equal('refrigeration_template', arguments[0].name)
  end

  def test_supermarket_refrigeration_performance_before_after
    test_name = __method__
    osm_name = 'Supermarket_5A.osm'
    epw_name = 'CA_LOS-ANGELES-DOWNTOWN-USC_722874S_16.epw'

    osm_path = model_input_path(osm_name)
    epw_path = epw_input_path(epw_name)

    assert(File.exist?(osm_path))
    assert(File.exist?(epw_path))

    FileUtils.mkdir_p(run_dir(test_name))

    model = load_model(osm_path)

    # Ensure the measure is applicable for this model.
    model.getBuilding.additionalProperties.setFeature('refrigeration_technology_level', 'old')

    epw_file = OpenStudio::EpwFile.new(OpenStudio::Path.new(epw_path))
    OpenStudio::Model::WeatherFile.setWeatherFile(model, epw_file)
    assert(model.weatherFile.is_initialized)

    set_short_test_run_period(model)

    before_model_metrics = refrigeration_model_metrics(model)

    assert(before_model_metrics[:case_count] > 0, 'Expected baseline model to include refrigeration cases.')
    assert(before_model_metrics[:walkin_count] > 0, 'Expected baseline model to include refrigeration walk-ins.')
    assert(before_model_metrics[:case_length_m] > 0.0, 'Expected baseline refrigeration case length to be positive.')
    assert(before_model_metrics[:walkin_floor_area_m2] > 0.0, 'Expected baseline walk-in floor area to be positive.')
    assert(before_model_metrics[:walkin_coil_capacity_w] > 0.0, 'Expected baseline walk-in cooling capacity to be positive.')

    std = Standard.build('90.1-2013')

    before_sql = run_model_and_get_sql(model, std, File.join(run_dir(test_name), 'before'))
    before_energy_metrics = energy_metrics_from_sql(before_sql)

    measure = UpgradeRefrigeration.new
    runner = OpenStudio::Measure::OSRunner.new(OpenStudio::WorkflowJSON.new)
    arguments = measure.arguments(model)
    argument_map = OpenStudio::Measure.convertOSArgumentVectorToMap(arguments)

    arguments.each do |arg|
      temp_arg = arg.clone
      if arg.name == 'refrigeration_template'
        assert(temp_arg.setValue('advanced'), 'Could not set refrigeration_template to advanced.')
      end
      argument_map[arg.name] = temp_arg
    end

    puts "\nAPPLYING MEASURE..."
    measure.run(model, runner, argument_map)
    result = runner.result
    show_output(result)

    assert_equal('Success', result.value.valueName)

    after_model_metrics = refrigeration_model_metrics(model)

    assert(after_model_metrics[:case_count] > 0, 'Expected upgraded model to include refrigeration cases.')
    assert(after_model_metrics[:walkin_count] > 0, 'Expected upgraded model to include refrigeration walk-ins.')
    assert(after_model_metrics[:case_length_m] > 0.0, 'Expected upgraded refrigeration case length to be positive.')
    assert(after_model_metrics[:walkin_floor_area_m2] > 0.0, 'Expected upgraded walk-in floor area to be positive.')
    assert(after_model_metrics[:walkin_coil_capacity_w] > 0.0, 'Expected upgraded walk-in cooling capacity to be positive.')

    # Keep service-level refrigeration scope similar before and after the upgrade.
    assert(after_model_metrics[:case_count] >= (before_model_metrics[:case_count] * 0.5).floor)
    assert(after_model_metrics[:walkin_count] >= (before_model_metrics[:walkin_count] * 0.5).floor)
    assert(after_model_metrics[:case_length_m] >= before_model_metrics[:case_length_m] * 0.5)
    assert(after_model_metrics[:walkin_floor_area_m2] >= before_model_metrics[:walkin_floor_area_m2] * 0.5)

    model.resetSqlFile
    after_sql = run_model_and_get_sql(model, std, File.join(run_dir(test_name), 'after'))
    after_energy_metrics = energy_metrics_from_sql(after_sql)

    assert(before_energy_metrics[:refrigeration_electricity_gj] > 0.0)
    assert(after_energy_metrics[:refrigeration_electricity_gj] > 0.0)
    assert(before_energy_metrics[:total_site_gj] > 0.0)
    assert(after_energy_metrics[:total_site_gj] > 0.0)

    # Advanced refrigeration should generally not increase refrigeration or whole-building energy use.
    assert_operator(after_energy_metrics[:refrigeration_electricity_gj], :<=,
                    before_energy_metrics[:refrigeration_electricity_gj] * 1.10)
    assert_operator(after_energy_metrics[:total_site_gj], :<=,
                    before_energy_metrics[:total_site_gj] * 1.10)

    model.save(File.join(run_dir(test_name), 'test_supermarket_refrigeration_performance_before_after.osm'), true)
  end
end
