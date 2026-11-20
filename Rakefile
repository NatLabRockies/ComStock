require 'rake/testtask'
require 'parallel'
require 'rubocop/rake_task'
require 'rexml/document'

def run_measure_tests(file_list, summary: nil)
  reports_root = ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR', File.expand_path('test/reports'))
  runner = File.join(__dir__, 'test/helpers/measure_test_runner.rb')
  load_paths = $LOAD_PATH.join(File::PATH_SEPARATOR)

  # Wait for all subprocesses to finish before propagating a failure.
  results = Parallel.map(file_list, in_threads: Parallel.processor_count) do |file|
    process_failure = nil
    test_failures = []
    failed_count = 0
    passes = []
    report_dir = File.expand_path(File.join(reports_root, file.sub(/\.rb\z/, '')))
    FileUtils.rm_f(Dir.glob(File.join(report_dir, 'TEST-*.xml')))

    puts "Running test #{file}"
    ruby '-I', load_paths, runner, File.expand_path(file), report_dir, verbose: false do |success, status|
      process_failure = status.exited? ? "exit #{status.exitstatus}" : status.to_s unless success
    end

    reports = Dir.glob(File.join(report_dir, 'TEST-*.xml'))
    test_cases = reports.flat_map { |report| REXML::Document.new(File.read(report)).get_elements('//testcase') }
    test_cases.each do |test_case|
      name = "#{test_case.attributes['classname']}##{test_case.attributes['name']}"
      failures = test_case.get_elements('failure|error')
      if failures.empty?
        passes << name if summary && test_case.get_elements('skipped').empty?
      else
        failed_count += 1
        failures.each { |failure| test_failures << "  #{name}: #{failure.attributes['message']}" }
      end
    end

    raise process_failure if process_failure
    if test_cases.empty?
      raise "No JUnit test cases were produced by #{file}"
    end
    raise 'JUnit reports contain failures or errors' unless test_failures.empty?

    { file: file, passes: passes, failed_count: failed_count }
  rescue StandardError => e
    reason = [process_failure, e.message].compact.uniq.join('; ')
    message = "FAIL: #{file} (#{reason})"
    message += "\n#{test_failures.join("\n")}" unless test_failures.empty?
    { file: file, passes: passes, failed_count: failed_count, error: message }
  end

  if summary
    results.each do |result|
      summary[:passes][result[:file]] = result[:passes] unless result[:passes].empty?
      summary[:failed_count] += result[:failed_count]
    end
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
    errors = filters.keys.filter_map do |group|
      summaries[group] = { passes: {}, failed_count: 0 } if step_summary
      run_group.call(group, summaries[group])
      nil
    rescue StandardError => e
      "#{group}_measure_tests:\n#{e.message}"
    end

    heading = "Measure test groups failed (#{errors.length})"
    details = errors.join("\n\n")
    if step_summary
      failed_count = summaries.values.sum { |summary| summary[:failed_count] }
      passed_count = summaries.values.sum { |summary| summary[:passes].values.sum(&:length) }
      File.open(step_summary, 'a') do |file|
        file.puts "## Measure tests failed (#{failed_count})\n"
        unless errors.empty?
          file.puts "\nFile or group failures without a JUnit test result are listed below but not counted as failed tests.\n"
          file.puts "### #{heading}\n\n#{details.gsub(/^/, '    ')}\n"
        end
        file.puts "\n## Measure tests passed (#{passed_count})\n"
        summaries.each do |group, summary|
          next if summary[:passes].empty?

          file.puts "\n    #{group}_measure_tests:"
          summary[:passes].each do |test_file, passes|
            file.puts "    PASS: #{test_file}"
            passes.each { |test_name| file.puts "      #{test_name}" }
          end
        end
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
