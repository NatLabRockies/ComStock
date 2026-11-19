require 'rake/testtask'
require 'minitest/reporters'
require 'parallel'
require 'rubocop/rake_task'
require 'rexml/document'

# generate the xml reports from tests.
Minitest::Reporters.use! [
  Minitest::Reporters::DefaultReporter.new,
  Minitest::Reporters::JUnitReporter.new('test/reports')
]

def run_measure_tests(file_list)
  reports_root = ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR', File.expand_path('test/reports'))
  runner = File.join(__dir__, 'test/helpers/measure_test_runner.rb')
  load_paths = $LOAD_PATH.join(File::PATH_SEPARATOR)

  # Wait for all subprocesses to finish before propagating a failure.
  errors = Parallel.map(file_list, in_threads: Parallel.processor_count) do |file|
    process_failure = nil
    test_failures = []
    report_dir = File.expand_path(File.join(reports_root, file.sub(/\.rb\z/, '')))
    FileUtils.rm_f(Dir.glob(File.join(report_dir, 'TEST-*.xml')))

    puts "Running test #{file}"
    ruby '-I', load_paths, runner, File.expand_path(file), report_dir, verbose: false do |success, status|
      process_failure = status.exited? ? "exit #{status.exitstatus}" : status.to_s unless success
    end

    reports = Dir.glob(File.join(report_dir, 'TEST-*.xml'))
    test_cases = reports.flat_map { |report| REXML::Document.new(File.read(report)).get_elements('//testcase') }
    test_failures = test_cases.flat_map do |test_case|
      test_case.get_elements('failure|error').map do |failure|
        "  #{test_case.attributes['classname']}##{test_case.attributes['name']}: #{failure.attributes['message']}"
      end
    end

    raise process_failure if process_failure
    if test_cases.empty?
      raise "No JUnit test cases were produced by #{file}"
    end
    raise 'JUnit reports contain failures or errors' unless test_failures.empty?

    nil
  rescue StandardError => e
    reason = [process_failure, e.message].compact.uniq.join('; ')
    message = "FAILED: #{file} (#{reason})"
    message += "\n#{test_failures.join("\n")}" unless test_failures.empty?
    warn message
    message
  end.compact

  raise "Measure test failures (#{errors.length}):\n#{errors.join("\n")}" unless errors.empty?
end

desc 'Run measure tests'
namespace :unit_tests do
  desc 'Run all measure tests'
  task all_tests: [:reporting_measure_tests, :workflow_measure_tests, :upgrade_measure_tests] do
    puts 'Running all measure tests:'
  end

  desc 'Run reporting measure tests'
  task :reporting_measure_tests do
    puts 'Running all reporting measure tests:'
    # load test files from file
    file_list = FileList.new(File.readlines('test/reporting_measure_tests.txt').map(&:chomp))
    file_list.select! { |item| item.include?('rb') }
    run_measure_tests(file_list)
  end

  desc 'Run workflow measure tests'
  task :workflow_measure_tests do
    puts 'Running all workflow measure tests:'
    # load test files from file
    file_list = FileList.new(File.readlines('test/workflow_measure_tests.txt').map(&:chomp))
    file_list.select! { |item| item.include?('rb') && !item.include?('upgrade') }
    run_measure_tests(file_list)
  end

  desc 'Run upgrade measure tests'
  task :upgrade_measure_tests do
    puts 'Running all upgrade measure tests:'
    # load test files from file
    file_list = FileList.new(File.readlines('test/upgrade_measure_tests.txt').map(&:chomp))
    file_list.select! { |item| item.include?('rb') && item.include?('upgrade') }
    run_measure_tests(file_list)
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
