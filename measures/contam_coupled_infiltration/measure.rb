# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

require 'json'
require 'open3'
require 'fileutils'
require 'date'

# Couples a CONTAM multizone airflow model to the EnergyPlus run, or surveys the model
# for the CONTAM infiltration campaign without changing it.
#
# Every decision is made by osm2contam (`python -m osm2contam comstock-prepare`); this
# measure saves the model, calls it, and applies what it reports. In `coupled` mode that
# means replacing the model's infiltration with zero-flow objects an EnergyPlus
# PythonPlugin actuates from CONTAM every timestep, adding the ZoneMixing objects that
# carry CONTAM's interzone flows, setting the timestep, and loading the plugin.
#
# It is a ModelMeasure rather than a reporting measure's modelOutputRequests (the
# loads_summary pattern) because it changes results: that hook is for reporting only.
#
# Design: osm2contam docs/comstock-integration-plan.md, section 2.2.
class ContamCoupledInfiltration < OpenStudio::Measure::ModelMeasure
  MODES = ['off', 'attributes', 'coupled'].freeze

  def name
    return 'CONTAM Coupled Infiltration'
  end

  def description
    return 'Replaces the model infiltration with infiltration and interzone airflow computed by a CONTAM multizone model coupled to EnergyPlus every timestep, or surveys the model for the CONTAM infiltration campaign.'
  end

  def modeler_description
    return 'Calls osm2contam (python -m osm2contam comstock-prepare) on the model as built. ' \
           'coupled: removes every SpaceInfiltration object, adds one zero-flow SpaceInfiltrationDesignFlowRate per thermal zone ' \
           'and one zero-flow ZoneMixing per directed zone pair, named as osm2contam\'s coupling.json states, sets the timestep, ' \
           'and adds a PythonPluginInstance whose plugin drives ContamX through contamxpy and actuates those objects. ' \
           'attributes: computes the zone attributes and the building strata axes and registers them, changing nothing. ' \
           'The Python interpreter is OSM2CONTAM_PYTHON if set, else python (Windows) or python3.'
  end

  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    mode = OpenStudio::Measure::OSArgument.makeChoiceArgument('mode', MODES, true)
    mode.setDisplayName('Mode')
    mode.setDescription('off: do nothing. attributes: survey the model, change nothing. coupled: couple CONTAM to the EnergyPlus run.')
    mode.setDefaultValue('coupled')
    args << mode

    tph = OpenStudio::Measure::OSArgument.makeIntegerArgument('timesteps_per_hour', true)
    tph.setDisplayName('Timesteps per hour (coupled)')
    tph.setDescription('EnergyPlus timestep and CONTAM synchronization interval in coupled mode. 60 is a 60 s step, CONTAM\'s minimum. Ignored in attributes mode.')
    tph.setDefaultValue(60)
    args << tph

    assumptions = OpenStudio::Measure::OSArgument.makeStringArgument('assumptions', false)
    assumptions.setDisplayName('Assumptions file')
    assumptions.setDescription('osm2contam assumptions YAML. Blank for the bundled default.')
    assumptions.setDefaultValue('')
    args << assumptions

    leakage = OpenStudio::Measure::OSArgument.makeChoiceArgument('envelope_leakage', ['model', 'assumptions'], true)
    leakage.setDisplayName('Envelope leakage (coupled)')
    leakage.setDescription("model: CONTAM's envelope passes the model's own design infiltration at 4 Pa, which is the sampled airtightness as set_nist_infiltration_correlations applied it. assumptions: the assumptions file's per-area value.")
    leakage.setDefaultValue('model')
    args << leakage

    survey_days = OpenStudio::Measure::OSArgument.makeIntegerArgument('survey_run_days', true)
    survey_days.setDisplayName('Survey run period, days (attributes)')
    survey_days.setDescription('Attributes mode only: shorten the run period to this many days, since a survey needs the model, not an annual result. 0 leaves the run period alone. Exists because buildstock_local --measures_only is broken with custom gems.')
    survey_days.setDefaultValue(0)
    args << survey_days

    capacitance = OpenStudio::Measure::OSArgument.makeDoubleArgument('capacitance_multiplier', true)
    capacitance.setDisplayName('Zone capacitance multiplier (coupled)')
    capacitance.setDescription('ZoneCapacitanceMultiplier:ResearchSpecial temperature multiplier, for a coupling that rings. 0 leaves it unset.')
    capacitance.setDefaultValue(0.0)
    args << capacitance

    on_failure = OpenStudio::Measure::OSArgument.makeChoiceArgument('on_translation_failure', ['default', 'fail', 'skip'], true)
    on_failure.setDisplayName('On translation failure')
    on_failure.setDescription('fail: the datapoint fails. skip: leave the model unchanged and mark the measure not applicable. default: fail in coupled mode, where an uncoupled run would pass for a coupled one, skip otherwise.')
    on_failure.setDefaultValue('default')
    args << on_failure

    return args
  end

  def python_command
    configured = ENV['OSM2CONTAM_PYTHON']
    return configured if configured && !configured.empty?
    return Gem.win_platform? ? 'python' : 'python3'
  end

  def weather_file_path(model, runner)
    weather = model.getOptionalWeatherFile
    return nil unless weather.is_initialized && weather.get.path.is_initialized
    path = weather.get.path.get
    return path.to_s if File.exist?(path.to_s)
    found = runner.workflow.findFile(path)
    found = runner.workflow.findFile(File.basename(path.to_s)) unless found.is_initialized
    return found.is_initialized ? found.get.to_s : nil
  end

  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)
    return false unless runner.validateUserArguments(arguments(model), user_arguments)

    mode = runner.getStringArgumentValue('mode', user_arguments)
    runner.registerValue('mode', mode)
    if mode == 'off'
      runner.registerAsNotApplicable('mode is off')
      return true
    end
    on_failure = runner.getStringArgumentValue('on_translation_failure', user_arguments)
    on_failure = (mode == 'coupled' ? 'fail' : 'skip') if on_failure == 'default'

    work = File.expand_path(File.join(Dir.pwd, '..', 'osm2contam'))
    FileUtils.mkdir_p(work)
    osm = File.join(work, 'in.osm')
    model.save(OpenStudio::Path.new(osm), true)
    epw = weather_file_path(model, runner)
    return fail_or_skip(runner, on_failure, 'the model has no weather file that can be found') if epw.nil?

    tph = mode == 'coupled' ? runner.getIntegerArgumentValue('timesteps_per_hour', user_arguments) : model.getTimestep.numberOfTimestepsPerHour
    command = [python_command, '-m', 'osm2contam', 'comstock-prepare',
               '--osm', osm, '--epw', epw, '--out', work,
               '--mode', mode, '--timesteps-per-hour', tph.to_s,
               '--leakage', runner.getStringArgumentValue('envelope_leakage', user_arguments)]
    assumptions = runner.getOptionalStringArgumentValue('assumptions', user_arguments)
    command += ['--assumptions', assumptions.get] if assumptions.is_initialized && !assumptions.get.strip.empty?

    runner.registerInfo("Running: #{command.join(' ')}")
    begin
      stdout, stderr, status = Open3.capture3(*command)
    rescue SystemCallError => e
      return fail_or_skip(runner, on_failure, "could not start #{python_command}: #{e.message}. Set OSM2CONTAM_PYTHON to an interpreter with osm2contam installed.")
    end
    File.write(File.join(work, 'prepare.log'), "#{command.join(' ')}\n\n--- stdout\n#{stdout}\n--- stderr\n#{stderr}")
    unless status.success?
      reason = stderr.lines.grep(/error/i).last || stderr.lines.last(3).join
      return fail_or_skip(runner, on_failure, "osm2contam comstock-prepare failed: #{reason.strip}")
    end

    summary = JSON.parse(File.read(File.join(work, 'prepare.json')))
    register_summary(runner, summary)
    if mode == 'attributes'
      days = runner.getIntegerArgumentValue('survey_run_days', user_arguments)
      if days > 0
        # Everything the survey measures was read above, from the model as built; this
        # only spares the annual simulation nobody will read.
        run_period = model.getRunPeriod
        year = model.getYearDescription.assumedYear
        first = Date.new(year, run_period.getBeginMonth, run_period.getBeginDayOfMonth)
        last = first + (days - 1)
        run_period.setEndMonth(last.month)
        run_period.setEndDayOfMonth(last.day)
        runner.registerValue('survey_run_days', days)
        runner.registerFinalCondition("Surveyed #{summary['strata']['zones']} zones; run period cut to #{days} day(s) for the survey, the model is otherwise unchanged.")
        return true
      end
      runner.registerFinalCondition("Surveyed #{summary['strata']['zones']} zones; the model is unchanged.")
      return true
    end

    capacitance = runner.getDoubleArgumentValue('capacitance_multiplier', user_arguments)
    return apply_coupling(model, runner, summary, tph, capacitance)
  end

  def fail_or_skip(runner, on_failure, message)
    if on_failure == 'skip'
      runner.registerWarning(message)
      runner.registerValue('applicable', false)
      runner.registerAsNotApplicable("osm2contam could not prepare this model; it is unchanged. #{message}")
      return true
    end
    runner.registerError(message)
    return false
  end

  def register_summary(runner, summary)
    runner.registerValue('version', summary['osm2contam_version'])
    runner.registerValue('assumptions_sha', summary['assumptions_sha'])
    runner.registerValue('timesteps_per_hour', summary['timesteps_per_hour'])
    runner.registerValue('prepare_seconds', summary['seconds'].to_f)
    runner.registerValue('translation_warnings', summary['warnings'].size)
    summary['strata'].each do |key, value|
      runner.registerValue("strata_#{key}", value.is_a?(Numeric) ? value.to_f : value.to_s)
    end
    summary['warnings'].first(20).each { |w| runner.registerInfo("osm2contam: #{w}") }
  end

  # Make the model match coupling.json exactly. Every name is checked after it is set:
  # OpenStudio silently suffixes a duplicate, and the plugin finds its actuators by name,
  # so a renamed object would leave a zone uncoupled.
  def apply_coupling(model, runner, summary, tph, capacitance)
    coupling = summary['coupling']
    spec = JSON.parse(File.read(coupling['spec']))

    removed = 0
    [model.getSpaceInfiltrationDesignFlowRates, model.getSpaceInfiltrationEffectiveLeakageAreas].each do |objects|
      objects.each { |o| o.remove; removed += 1 }
    end
    if model.respond_to?(:getSpaceInfiltrationFlowCoefficients)
      model.getSpaceInfiltrationFlowCoefficients.each { |o| o.remove; removed += 1 }
    end
    runner.registerValue('nist_objects_removed', removed)

    always_on = model.alwaysOnContinuousSchedule
    spec['infiltration'].each do |zone_name, object_name|
      zone = model.getThermalZoneByName(zone_name)
      return error(runner, "no thermal zone named #{zone_name.inspect} for #{object_name.inspect}") unless zone.is_initialized
      space = zone.get.spaces.min_by(&:nameString)
      return error(runner, "thermal zone #{zone_name.inspect} has no spaces") if space.nil?
      infiltration = OpenStudio::Model::SpaceInfiltrationDesignFlowRate.new(model)
      return false unless named(runner, infiltration, object_name)
      infiltration.setSpace(space)
      infiltration.setSchedule(always_on)
      infiltration.setDesignFlowRate(0.0)
      # Constant term 1, the rest 0: EnergyPlus applies the actuated flow as it is,
      # with no weather correlation of its own. CONTAM has accounted for wind and stack.
      infiltration.setConstantTermCoefficient(1.0)
      infiltration.setTemperatureTermCoefficient(0.0)
      infiltration.setVelocityTermCoefficient(0.0)
      infiltration.setVelocitySquaredTermCoefficient(0.0)
    end

    spec['mixing'].each do |source_name, receiving_name, object_name|
      source = model.getThermalZoneByName(source_name)
      receiving = model.getThermalZoneByName(receiving_name)
      return error(runner, "no thermal zones for mixing #{object_name.inspect}") unless source.is_initialized && receiving.is_initialized
      mixing = OpenStudio::Model::ZoneMixing.new(receiving.get)
      return false unless named(runner, mixing, object_name)
      mixing.setSchedule(always_on)
      mixing.setDesignFlowRate(0.0)
      mixing.setSourceZone(source.get)
    end

    model.getTimestep.setNumberOfTimestepsPerHour(tph)
    if capacitance > 0
      multiplier = model.getZoneCapacitanceMultiplierResearchSpecial
      multiplier.setTemperatureCapacityMultiplier(capacitance)
      multiplier.setHumidityCapacityMultiplier(capacitance)
      multiplier.setCarbonDioxideCapacityMultiplier(capacitance)
    end

    external = OpenStudio::Model::ExternalFile.getExternalFile(model, coupling['shim'])
    return error(runner, "OpenStudio could not take #{coupling['shim']} as an external file") unless external.is_initialized
    plugin = OpenStudio::Model::PythonPluginInstance.new(external.get, coupling['plugin_class'])
    plugin.setName('osm2contam Coupler')
    # The plugin sees warmup and skips it itself, as the library host does.
    plugin.setRunDuringWarmupDays(true)

    # A plugin cannot request variables through the API; they must exist as outputs.
    spec['variables'].each do |variable_name, key|
      output = OpenStudio::Model::OutputVariable.new(variable_name, model)
      output.setKeyValue(key)
      output.setReportingFrequency('Hourly')
    end

    runner.registerValue('infiltration_objects', spec['infiltration'].size)
    runner.registerValue('mixing_objects', spec['mixing'].size)
    runner.registerValue('contam_zones', coupling['contam_zones'])
    runner.registerValue('contam_paths', coupling['paths'])
    runner.registerValue('air_systems_driven', coupling['air_systems'])
    runner.registerValue('expected_coupled_steps', coupling['expected_steps'])
    runner.registerFinalCondition(
      "Coupled to CONTAM: removed #{removed} infiltration objects, added #{spec['infiltration'].size} actuated infiltration " \
      "and #{spec['mixing'].size} mixing objects, timestep #{tph}/h, #{coupling['expected_steps']} coupled steps expected."
    )
    return true
  end

  def named(runner, object, name)
    object.setName(name)
    return true if object.nameString == name
    runner.registerError("OpenStudio renamed #{name.inspect} to #{object.nameString.inspect}; the plugin finds its actuators by name")
    return false
  end

  def error(runner, message)
    runner.registerError(message)
    return false
  end
end

ContamCoupledInfiltration.new.registerWithApplication
