require 'minitest/autorun'
# minitest-reporters 1.4.x uses the legacy MiniTest constant.
require 'minitest/unit'
require 'minitest/reporters'
require 'minitest/reporters/spec_reporter'
require 'json'

reporters = [Minitest::Reporters::SpecReporter.new]
if ENV['MINITEST_REPORTERS_REPORTS_DIR'] || ENV['JENKINS_HOME']
  reporters << Minitest::Reporters::JUnitReporter.new
end
Minitest::Reporters.use! reporters
