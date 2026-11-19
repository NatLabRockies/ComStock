abort 'Usage: measure_test_runner.rb TEST_FILE REPORT_DIRECTORY' unless ARGV.length == 2
test_file, report_dir = ARGV.shift(2)
ENV['MINITEST_REPORTERS_REPORTS_DIR'] = report_dir

require 'minitest/autorun'
require 'minitest/reporters'

Minitest::Reporters.use! [
  Minitest::Reporters::DefaultReporter.new,
  Minitest::Reporters::JUnitReporter.new(report_dir)
]

load test_file
