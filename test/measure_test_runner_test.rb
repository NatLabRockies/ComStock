require 'minitest/autorun'
require 'rake'
require 'tmpdir'

load File.expand_path('../Rakefile', __dir__)

class MeasureTestRunnerTest < Minitest::Test
  include Rake::DSL

  def with_fixture(&block)
    original_reports_dir = ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR', nil)
    Dir.mktmpdir('comstock-test-runner-') do |dir|
      ENV['MINITEST_REPORTERS_REPORTS_DIR'] = File.join(dir, 'reports')
      Dir.chdir(dir, &block)
    end
  ensure
    ENV['MINITEST_REPORTERS_REPORTS_DIR'] = original_reports_dir
  end

  def passing_test
    <<~RUBY
      require 'minitest/autorun'
      class FixtureTest < Minitest::Test
        def test_passes
          assert true
        end
      end
    RUBY
  end

  def test_successful_file_produces_its_own_report
    with_fixture do
      File.write('fixture_test.rb', passing_test)

      run_measure_tests(['fixture_test.rb'])

      reports = Dir.glob(File.join(ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR'), 'fixture_test', 'TEST-*.xml'))
      assert_equal(1, reports.size)
      assert_equal(1, REXML::Document.new(File.read(reports.first)).get_elements('//testcase').size)
    end
  end

  def test_nonzero_exit_fails_even_after_passing_report_is_written
    with_fixture do
      File.write('fixture_test.rb', "#{passing_test}\nMinitest.after_run { exit! 42 }\n")
      File.write('other_test.rb', "#{passing_test}\nMinitest.after_run { File.write('completed', 'done') }\n")

      error = assert_raises(RuntimeError) { run_measure_tests(['fixture_test.rb', 'other_test.rb']) }

      assert_match('status (42)', error.message)
      refute_empty(Dir.glob(File.join(ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR'), 'fixture_test', 'TEST-*.xml')))
      assert(File.exist?('completed'))
    end
  end

  def test_exit_without_report_cannot_reuse_stale_results
    with_fixture do
      File.write('fixture_test.rb', passing_test)
      run_measure_tests(['fixture_test.rb'])
      File.write('fixture_test.rb', "exit! 0\n")

      error = assert_raises(RuntimeError) { run_measure_tests(['fixture_test.rb']) }

      assert_match('No JUnit test cases', error.message)
      assert_empty(Dir.glob(File.join(ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR'), 'fixture_test', 'TEST-*.xml')))
    end
  end
end
