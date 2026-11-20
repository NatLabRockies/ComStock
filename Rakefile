require 'rake/testtask'
require 'parallel'
require 'rubocop/rake_task'
require 'rexml/document'

def run_measure_tests(file_list, passed_tests: nil)
  reports_root = ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR', File.expand_path('test/reports'))
  runner = File.join(__dir__, 'test/helpers/measure_test_runner.rb')
  load_paths = $LOAD_PATH.join(File::PATH_SEPARATOR)

  # Wait for all subprocesses to finish before propagating a failure.
  results = Parallel.map(file_list, in_threads: Parallel.processor_count) do |file|
    process_failure = nil
    test_failures = []
    passes = []
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
    if passed_tests
      passes = test_cases.filter_map do |test_case|
        next unless test_case.get_elements('failure|error|skipped').empty?

        "PASS: #{test_case.attributes['classname']}##{test_case.attributes['name']} (#{file})"
      end
    end

    raise process_failure if process_failure
    if test_cases.empty?
      raise "No JUnit test cases were produced by #{file}"
    end
    raise 'JUnit reports contain failures or errors' unless test_failures.empty?

    [nil, passes]
  rescue StandardError => e
    reason = [process_failure, e.message].compact.uniq.join('; ')
    message = "FAIL: #{file} (#{reason})"
    message += "\n#{test_failures.join("\n")}" unless test_failures.empty?
    [message, passes]
  end

  passed_tests&.concat(results.flat_map(&:last))
  errors = results.filter_map(&:first)

  raise "Measure test failures (#{errors.length}):\n#{errors.join("\n")}" unless errors.empty?
end

desc 'Run measure tests'
namespace :unit_tests do
  filters = {
    reporting: ->(file) { file.include?('rb') },
    workflow: ->(file) { file.include?('rb') && !file.include?('upgrade') },
    upgrade: ->(file) { file.include?('rb') && file.include?('upgrade') }
  }
  run_group = lambda do |group, passed_tests = nil|
    puts "Running all #{group} measure tests:"
    files = FileList.new(File.readlines("test/#{group}_measure_tests.txt", chomp: true))
    run_measure_tests(files.select(&filters.fetch(group)), passed_tests: passed_tests)
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
    passed_tests = [] if step_summary
    errors = filters.keys.filter_map do |group|
      run_group.call(group, passed_tests)
      nil
    rescue StandardError => e
      "#{group}_measure_tests:\n#{e.message}"
    end

    heading = "Measure test groups failed (#{errors.length})"
    details = errors.join("\n\n")
    if step_summary
      File.open(step_summary, 'a') do |file|
        file.puts "## #{heading}\n\n#{details.gsub(/^/, '    ')}\n" unless errors.empty?
        file.puts "## Measure tests passed (#{passed_tests.length})\n"
        passed_tests.each { |result| file.puts "    #{result}" }
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
