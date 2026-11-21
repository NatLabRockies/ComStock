# Subprocess entry point for running one measure test file with console and JUnit
# output, allowing Rake to detect failed processes and missing test results.

abort 'Usage: measure_test_runner.rb TEST_FILE REPORT_DIRECTORY [DISCOVERY_FILE]' unless (2..3).cover?(ARGV.length)
test_file, report_dir, discovery_file = ARGV.shift(ARGV.length)
ENV['MINITEST_REPORTERS_REPORTS_DIR'] = report_dir

require_relative 'minitest_helper'

load test_file

if discovery_file
  Minitest.singleton_class.prepend(Module.new do
    define_method(:__run) do |reporter, options|
      count = Minitest::Runnable.runnables.sum { |suite| suite.runnable_methods.size }
      File.write(discovery_file, JSON.generate(count))
      super(reporter, options)
    end
  end)
end
