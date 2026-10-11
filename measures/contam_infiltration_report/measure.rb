# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

require 'json'
require 'open3'

# Reduces a CONTAM-coupled run (contam_coupled_infiltration in coupled mode) to the
# building values registered for results.csv, and to per-zone tables kept in the run
# directory for the infiltration regression.
#
# Every number is computed by osm2contam (`python -m osm2contam comstock-reduce`). A
# coupled run that failed or stopped short fails the datapoint here: an uncoupled or
# partial year must not reach the campaign looking like a result.
#
# Must be listed before run_directory_cleanup, which deletes eplusout.sql.
#
# Design: osm2contam docs/comstock-integration-plan.md, section 2.4.
class ContamInfiltrationReport < OpenStudio::Measure::ReportingMeasure
  # What EnergyPlus reports of the infiltration the plugin actuated, read back as a
  # check that the actuators took.
  OUTPUT_VARIABLES = ['Zone Infiltration Mass Flow Rate'].freeze

  def name
    return 'CONTAM Infiltration Report'
  end

  def description
    return 'Reports the infiltration a CONTAM-coupled run produced, per building and per zone.'
  end

  def modeler_description
    return 'Registers what contam_coupled_infiltration reported (strata, version, coupling counts), since buildstockbatch ' \
           'collects values only from reporting measures. In coupled mode, also calls osm2contam ' \
           '(python -m osm2contam comstock-reduce) on run/osm2contam and eplusout.sql, registers building values, and ' \
           'writes zones.csv and zone_hourly.csv.gz into run/osm2contam. ' \
           'Not applicable if contam_coupled_infiltration did not run. ' \
           'The Python interpreter is OSM2CONTAM_PYTHON if set, else python (Windows) or python3.'
  end

  def arguments(model = nil)
    return OpenStudio::Measure::OSArgumentVector.new
  end

  def energyPlusOutputRequests(runner, user_arguments)
    super(runner, user_arguments)
    return OUTPUT_VARIABLES.map do |variable|
      OpenStudio::IdfObject.load("Output:Variable,*,#{variable},Hourly;").get
    end
  end

  def python_command
    configured = ENV['OSM2CONTAM_PYTHON']
    return configured if configured && !configured.empty?
    return Gem.win_platform? ? 'python' : 'python3'
  end

  def run_directory
    [File.join(Dir.pwd, 'run'), File.join(Dir.pwd, '..')].each do |candidate|
      return File.expand_path(candidate) if File.directory?(File.join(candidate, 'osm2contam'))
    end
    return nil
  end

  def register_prepare(runner, prepare)
    runner.registerValue('mode', prepare['mode'])
    runner.registerValue('version', prepare['osm2contam_version'])
    runner.registerValue('assumptions_sha', prepare['assumptions_sha'])
    runner.registerValue('timesteps_per_hour', prepare['timesteps_per_hour'])
    runner.registerValue('prepare_seconds', prepare['seconds'].to_f)
    runner.registerValue('translation_warnings', prepare['warnings'].size)
    prepare['strata'].each do |key, value|
      runner.registerValue("strata_#{key}", value.is_a?(Numeric) ? value.to_f : value.to_s)
    end
    design = prepare['design_infiltration']
    runner.registerValue('design_infiltration_4pa_m3_s', design['total_m3_s'].to_f) if design
    leakage = prepare['leakage']
    if leakage
      runner.registerValue('envelope_leakage_source', leakage['source'].to_s)
      runner.registerValue('contam_leakage_flow_4pa_m3_s', leakage['contam_flow_4pa_m3_s'].to_f) if leakage['contam_flow_4pa_m3_s']
      runner.registerValue('envelope_leakage_ratio_to_default', leakage['ratio_to_default'].to_f) if leakage['ratio_to_default']
    end
    coupling = prepare['coupling']
    return if coupling.nil?
    runner.registerValue('contam_zones', coupling['contam_zones'])
    runner.registerValue('contam_paths', coupling['paths'])
    runner.registerValue('air_systems_driven', coupling['air_systems'])
    runner.registerValue('infiltration_objects', coupling['infiltration_objects'])
    runner.registerValue('mixing_objects', coupling['mixing_objects'])
  end

  def run(runner, user_arguments)
    super(runner, user_arguments)
    return false unless runner.validateUserArguments(arguments, user_arguments)

    run_dir = run_directory
    prepared = run_dir && File.join(run_dir, 'osm2contam')
    if prepared.nil? || !File.exist?(File.join(prepared, 'prepare.json'))
      runner.registerAsNotApplicable('contam_coupled_infiltration did not run on this model')
      return true
    end
    prepare = JSON.parse(File.read(File.join(prepared, 'prepare.json')))
    # buildstockbatch collects values only from reporting measures, so what the
    # ModelMeasure registered never reaches results.csv. Register it again from here.
    register_prepare(runner, prepare)
    mode = prepare['mode']
    unless mode == 'coupled'
      runner.registerFinalCondition("Surveyed #{prepare['strata']['zones']} zones (#{mode} mode); no coupled run to reduce.")
      return true
    end

    sql = runner.lastEnergyPlusSqlFile
    if sql.empty?
      runner.registerError('no EnergyPlus SQL file to read')
      return false
    end
    sql_path = sql.get.path.to_s
    sql.get.close

    command = [python_command, '-m', 'osm2contam', 'comstock-reduce', '--prepared', prepared, '--sql', sql_path]
    runner.registerInfo("Running: #{command.join(' ')}")
    begin
      stdout, stderr, status = Open3.capture3(*command)
    rescue SystemCallError => e
      runner.registerError("could not start #{python_command}: #{e.message}. Set OSM2CONTAM_PYTHON.")
      return false
    end
    File.write(File.join(prepared, 'reduce.log'), "#{command.join(' ')}\n\n--- stdout\n#{stdout}\n--- stderr\n#{stderr}")
    unless status.success?
      reason = stderr.lines.grep(/error/i).first || stderr.lines.last(3).join
      runner.registerError("osm2contam comstock-reduce failed: #{reason.strip}")
      return false
    end

    summary = JSON.parse(File.read(File.join(prepared, 'summary.json')))
    summary.each do |key, value|
      next if value.nil?
      if key == 'warnings'
        runner.registerValue('warnings', value.size)
        value.first(20).each { |w| runner.registerWarning("osm2contam: #{w}") }
      elsif value == true || value == false
        runner.registerValue(key, value)
      elsif value.is_a?(Numeric)
        runner.registerValue(key, value.to_f)
      else
        runner.registerValue(key, value.to_s)
      end
    end
    runner.registerFinalCondition(
      "Envelope infiltration #{format('%.4f', summary['envelope_ach_mean'])} ACH over #{summary['zones']} zones; " \
      "actuated ratio #{summary['eplus_actuated_ratio'].nil? ? 'n/a' : format('%.6f', summary['eplus_actuated_ratio'])}."
    )
    return true
  end
end

ContamInfiltrationReport.new.registerWithApplication
