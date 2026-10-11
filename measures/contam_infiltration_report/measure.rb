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
    return 'Calls osm2contam (python -m osm2contam comstock-reduce) on run/osm2contam and eplusout.sql. ' \
           'Registers building values; writes zones.csv and zone_hourly.csv.gz into run/osm2contam. ' \
           'Not applicable unless contam_coupled_infiltration ran in coupled mode. ' \
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

  def run(runner, user_arguments)
    super(runner, user_arguments)
    return false unless runner.validateUserArguments(arguments, user_arguments)

    run_dir = run_directory
    prepared = run_dir && File.join(run_dir, 'osm2contam')
    if prepared.nil? || !File.exist?(File.join(prepared, 'prepare.json'))
      runner.registerAsNotApplicable('contam_coupled_infiltration did not run on this model')
      return true
    end
    mode = JSON.parse(File.read(File.join(prepared, 'prepare.json')))['mode']
    unless mode == 'coupled'
      runner.registerAsNotApplicable("contam_coupled_infiltration ran in #{mode} mode; there is no coupled run to report")
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
