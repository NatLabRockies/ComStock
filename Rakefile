require 'rake/testtask'
require 'minitest/reporters'
require 'parallel'
require 'rubocop/rake_task'

# generate the xml reports from tests.
Minitest::Reporters.use! [
  Minitest::Reporters::DefaultReporter.new,
  Minitest::Reporters::JUnitReporter.new('test/reports')
]

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
    file_list.select! { |item| item.include?('rb') && File.exist?(item) }
    Parallel.each(file_list, in_processes: Parallel.processor_count) do |file|
      puts "Running test #{file} in process #{Process.pid}"
      load file
      true
    rescue StandardError => e
      puts "Error in #{file}: #{e.message}"
      Minitest::Reporters.reporter.report_error(file, e)
      false
    end
  end

  desc 'Run workflow measure tests'
  task :workflow_measure_tests do
    puts 'Running all workflow measure tests:'
    # load test files from file
    file_list = FileList.new(File.readlines('test/workflow_measure_tests.txt').map(&:chomp))
    file_list.select! { |item| item.include?('rb') && !item.include?('upgrade') && File.exist?(item) }
    Parallel.each(file_list, in_processes: Parallel.processor_count) do |file|
      puts "Running test #{file} in process #{Process.pid}"
      load file
      true
    rescue StandardError => e
      puts "Error in #{file}: #{e.message}"
      Minitest::Reporters.reporter.report_error(file, e)
      false
    end
  end

  desc 'Run upgrade measure tests'
  task :upgrade_measure_tests do
    puts 'Running all upgrade measure tests:'
    # load test files from file
    file_list = FileList.new(File.readlines('test/upgrade_measure_tests.txt').map(&:chomp))
    file_list.select! { |item| item.include?('rb') && item.include?('upgrade') && File.exist?(item) }
    Parallel.each(file_list, in_processes: Parallel.processor_count) do |file|
      puts "Running test #{file} in process #{Process.pid}"
      load file
      true
    rescue StandardError => e
      puts "Error in #{file}: #{e.message}"
      Minitest::Reporters.reporter.report_error(file, e)
      false
    end
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
