require 'rake/testtask'
require 'parallel'
require 'rubocop/rake_task'
require 'rexml/document'
require 'json'

def run_measure_tests(file_list, summary: nil)
  reports_root = ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR', File.expand_path('test/reports'))
  runner = File.join(__dir__, 'test/helpers/measure_test_runner.rb')
  load_paths = $LOAD_PATH.join(File::PATH_SEPARATOR)

  # Wait for all subprocesses to finish before propagating a failure.
  results = Parallel.map(file_list, in_threads: Parallel.processor_count) do |file|
    process_failure = nil
    test_failures = []
    failed_count = 0
    skipped_count = 0
    passes = []
    discovered_count = nil
    reported_count = 0
    report_dir = File.expand_path(File.join(reports_root, file.sub(/\.rb\z/, '')))
    discovery_file = File.join(report_dir, 'discovered.json')
    FileUtils.mkdir_p(report_dir) if summary
    FileUtils.rm_f(Dir.glob(File.join(report_dir, 'TEST-*.xml')))
    FileUtils.rm_f(discovery_file) if summary

    puts "Running test #{file}"
    args = ['-I', load_paths, runner, File.expand_path(file), report_dir]
    args << discovery_file if summary
    ruby(*args, verbose: false) do |success, status|
      process_failure = status.exited? ? "exit #{status.exitstatus}" : status.to_s unless success
    end

    discovered_count = JSON.parse(File.read(discovery_file)) if summary && File.exist?(discovery_file)
    reports = Dir.glob(File.join(report_dir, 'TEST-*.xml'))
    test_cases = reports.flat_map { |report| REXML::Document.new(File.read(report)).get_elements('//testcase') }
    reported_count = test_cases.size
    if discovered_count && (!discovered_count.is_a?(Integer) || discovered_count.negative? || reported_count > discovered_count)
      discovered_count = nil
      reported_count = 0
      raise "JUnit results exceed or invalidate the discovered test count for #{file}"
    end
    test_cases.each do |test_case|
      name = "#{test_case.attributes['classname']}##{test_case.attributes['name']}"
      failures = test_case.get_elements('failure|error')
      if failures.empty?
        if test_case.get_elements('skipped').empty?
          passes << name if summary
        else
          skipped_count += 1
        end
      else
        failed_count += 1
        failures.each do |failure|
          attribute = failure.attributes.get_attribute('message')
          raw_message = attribute&.to_s
          message = raw_message&.slice(0, 1000)&.sub(/&[^;]*\z/, '')
          message = REXML::Text.unnormalize(message, failure.document.doctype) if message
          message = "#{message}... [truncated]" if raw_message && raw_message.length > 1000
          test_failures << "  #{name}: #{message}"
        end
      end
    end

    raise process_failure if process_failure
    if test_cases.empty?
      raise "No JUnit test cases were produced by #{file}"
    end
    raise "No valid test discovery count was produced by #{file}" if summary && discovered_count.nil?
    if summary && reported_count != discovered_count
      raise "JUnit reported #{reported_count} of #{discovered_count} discovered tests"
    end
    raise 'JUnit reports contain failures or errors' unless test_failures.empty?

    { file: file, passes: passes, failed_count: failed_count, skipped_count: skipped_count, discovered_count: discovered_count, reported_count: reported_count }
  rescue StandardError => e
    reason = [process_failure, e.message].compact.uniq.join('; ')
    message = "FAIL: #{file} (#{reason})"
    message += "\n#{test_failures.join("\n")}" unless test_failures.empty?
    { file: file, passes: passes, failed_count: failed_count, skipped_count: skipped_count, discovered_count: discovered_count, reported_count: reported_count, error: message }
  end

  if summary
    summary_results = results.reject do |result|
      File.expand_path(result[:file]).start_with?("#{File.expand_path('test')}#{File::SEPARATOR}")
    end
    summary_results.each do |result|
      summary[:passes][result[:file]] = result[:passes] unless result[:passes].empty?
      summary[:failed_count] += result[:failed_count]
      summary[:skipped_count] += result[:skipped_count]
      summary[:discovered_counts] << result[:discovered_count]
      summary[:reported_count] += result[:reported_count]
    end
    summary[:errors] = summary_results.filter_map { |result| result[:error] }
    summary[:completed] = true
  end
  errors = results.filter_map { |result| result[:error] }

  raise "Measure test failures (#{errors.length}):\n#{errors.join("\n")}" unless errors.empty?
end

desc 'Run measure tests'
namespace :unit_tests do
  filters = {
    reporting: ->(file) { file.include?('rb') },
    workflow: ->(file) { file.include?('rb') && !file.include?('upgrade') },
    upgrade: ->(file) { file.include?('rb') && file.include?('upgrade') }
  }
  run_group = lambda do |group, summary = nil|
    puts "Running all #{group} measure tests:"
    files = FileList.new(File.readlines("test/#{group}_measure_tests.txt", chomp: true))
    run_measure_tests(files.select(&filters.fetch(group)), summary: summary)
  end

  filters.each_key do |group|
    desc "Run #{group} measure tests"
    task :"#{group}_measure_tests" do
      run_group.call(group)
    end
  end

  desc 'Run all measure tests'
  task :all_tests do
    puts 'Running all measure tests:'
    step_summary = ENV.fetch('GITHUB_STEP_SUMMARY', nil)
    summaries = {}
    summary_errors = []
    errors = filters.keys.filter_map do |group|
      summaries[group] = { passes: {}, failed_count: 0, skipped_count: 0, discovered_counts: [], reported_count: 0, completed: false } if step_summary
      run_group.call(group, summaries[group])
      nil
    rescue StandardError => e
      if step_summary
        group_summary = summaries.fetch(group)
        if group_summary[:completed]
          group_errors = group_summary.fetch(:errors)
          unless group_errors.empty?
            summary_errors << "#{group}_measure_tests:\nMeasure test failures (#{group_errors.length}):\n#{group_errors.join("\n")}"
          end
        else
          summary_errors << "#{group}_measure_tests:\n#{e.message}"
        end
      end
      "#{group}_measure_tests:\n#{e.message}"
    end

    heading = "Measure test groups failed (#{errors.length})"
    details = errors.join("\n\n")
    if step_summary
      failed_count = summaries.values.sum { |summary| summary[:failed_count] }
      passed_count = summaries.values.sum { |summary| summary[:passes].values.sum(&:length) }
      skipped_count = summaries.values.sum { |summary| summary[:skipped_count] }
      counts = summaries.values.flat_map { |summary| summary[:discovered_counts] }
      total_count = counts.sum if summaries.values.all? { |summary| summary[:completed] } && counts.none?(&:nil?)
      reported_count = summaries.values.sum { |summary| summary[:reported_count] }
      unknown_count = total_count - failed_count - passed_count - skipped_count if total_count
      if total_count&.positive?
        percentages = lambda do |count|
          minimum = 100.0 * count / total_count
          if unknown_count.zero?
            format('%.2f%%', minimum)
          else
            format('%<minimum>.2f-%<maximum>.2f%%', minimum: minimum, maximum: 100.0 * (count + unknown_count) / total_count)
          end
        end
        failed_range = percentages.call(failed_count)
        passed_range = percentages.call(passed_count)
        skipped_range = percentages.call(skipped_count)
        unknown_percentage = format('%.2f%%', 100.0 * unknown_count / total_count)
      end
      File.open(step_summary, 'a') do |file|
        file.puts "Discovered tests: #{total_count || 'unavailable'}; JUnit results: #{reported_count}."
        if total_count&.positive?
          file.puts "Percentages are rounded; ranges include tests without classified outcomes as possible passes, failures, or skips.\n"
        else
          file.puts "Percentage ranges are unavailable when discovery is incomplete or no tests were discovered.\n"
        end
        file.puts "\n## Measure tests passed (#{passed_count}#{passed_range ? ", #{passed_range}" : ''})\n"
        summaries.each do |group, summary|
          next if summary[:passes].empty?

          file.puts "\n    #{group}_measure_tests:"
          summary[:passes].each do |test_file, passes|
            file.puts "    PASS: #{test_file}"
            passes.each { |test_name| file.puts "      #{test_name}" }
          end
        end
        file.puts "\n## Measure tests failed (#{failed_count}#{failed_range ? ", #{failed_range}" : ''})\n"
        unless summary_errors.empty?
          file.puts "### Measure test groups failed (#{summary_errors.length})\n\n#{summary_errors.join("\n\n").gsub(/^/, '    ')}\n"
        end
        file.puts "\n## Measure tests skipped (#{skipped_count}#{skipped_range ? ", #{skipped_range}" : ''})\n"
        file.puts "\n## Measure tests without classified outcomes (#{unknown_count || 'unavailable'}#{unknown_percentage ? ", #{unknown_percentage}" : ''})\n"
        file.puts "\n### Discovered tests without a confirmed pass, failure, or skip\n"
        file.puts "\nThis can happen when JUnit reports are missing, incomplete, or cannot be fully read. The count is unavailable if discovery is incomplete.\n"
      end
    end
    abort "#{heading}:\n#{details}" unless errors.empty?
  end
end

desc 'Check the code for style consistency'
RuboCop::RakeTask.new(:rubocop, [:autocorrect_all]) do |t, args|
  # Make a folder for the output
  out_dir = '.rubocop'
  FileUtils.mkdir_p(out_dir)
  # Output both XML (CheckStyle format) and HTML
  t.options = ["--out=#{out_dir}/rubocop-results.xml", '--format=h', "--out=#{out_dir}/rubocop-results.html", '--format=offenses', "--out=#{out_dir}/rubocop-summary.txt"]
  t.options << '--autocorrect-all' if args[:autocorrect_all] == 'true'
  t.requires = ['rubocop/formatter/checkstyle_formatter']
  t.formatters = ['RuboCop::Formatter::CheckstyleFormatter']
  # don't abort rake on failure
  t.fail_on_error = false
end

desc 'Show the rubocop output in a web browser'
task 'rubocop:show' => [:rubocop] do
  link = "#{__dir__}/.rubocop/rubocop-results.html"
  case RbConfig::CONFIG['host_os']
  when /mswin/, /mingw/, /cygwin/
    system "start #{link}"
  when /darwin/
    system "open #{link}"
  when /linux/, /bsd/
    system "xdg-open #{link}"
  end
end
