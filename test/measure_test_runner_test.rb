# Regression tests for subprocess failures, fresh JUnit reports, readable failure
# summaries, and continuing through all test groups before reporting failure.

require_relative 'helpers/minitest_helper'
require 'open3'
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

  def with_test_groups
    names = ['all_tests', 'reporting_measure_tests', 'workflow_measure_tests', 'upgrade_measure_tests']
    original_tasks = names.map { |name| Rake::Task["unit_tests:#{name}"] }

    with_fixture do
      FileUtils.mkdir_p('test')
      ['reporting', 'workflow', 'upgrade'].each do |group|
        file = "#{group}_fixture_test.rb"
        File.write(file, passing_test)
        File.write("test/#{group}_measure_tests.txt", "#{file}\n")
      end

      Rake.with_application do
        namespace :unit_tests do
          original_tasks.each do |original|
            task original.name.split(':').last => original.prerequisites do
              original.execute
            end
          end
        end
        yield
      end
    end
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

  def test_helper_formats_direct_runs_without_creating_junit_reports
    with_fixture do
      helper = File.expand_path('helpers/minitest_helper.rb', __dir__)
      File.write('fixture_test.rb', passing_test.sub("require 'minitest/autorun'", "require #{helper.inspect}"))

      stdout, stderr, status = Open3.capture3(
        { 'MINITEST_REPORTERS_REPORTS_DIR' => nil, 'JENKINS_HOME' => nil },
        RbConfig.ruby, '-I', $LOAD_PATH.join(File::PATH_SEPARATOR), 'fixture_test.rb', '-n', 'test_passes'
      )

      assert(status.success?, stderr)
      assert_includes(stdout, 'FixtureTest')
      assert_match(/test_passes.*PASS/, stdout)
      assert_empty(Dir.glob('**/TEST-*.xml'))
    end
  end

  def test_runner_formats_results_and_preserves_per_file_junit_with_shared_helper
    with_fixture do
      helper = File.expand_path('helpers/minitest_helper.rb', __dir__)
      runner = File.expand_path('helpers/measure_test_runner.rb', __dir__)
      report_dir = File.join(ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR'), 'fixture_test')
      File.write('fixture_test.rb', "require #{helper.inspect}\n#{passing_test}")

      stdout, stderr, status = Open3.capture3(
        { 'JENKINS_HOME' => 'fixture-jenkins' },
        RbConfig.ruby, '-I', $LOAD_PATH.join(File::PATH_SEPARATOR),
        runner, File.expand_path('fixture_test.rb'), report_dir
      )

      assert(status.success?, stderr)
      assert_includes(stdout, 'FixtureTest')
      assert_match(/test_passes.*PASS/, stdout)
      reports = Dir.glob(File.join(report_dir, 'TEST-*.xml'))
      assert_equal(1, reports.size)
      assert_equal(1, REXML::Document.new(File.read(reports.first)).get_elements('//testcase').size)
    end
  end

  def test_failed_files_are_summarized_after_all_subprocesses_finish
    with_fixture do
      File.write('fixture_test.rb', "#{passing_test}\nMinitest.after_run { exit! 42 }\n")
      File.write('other_test.rb', "#{passing_test}\nMinitest.after_run { File.write('completed', 'done'); exit! 17 }\n")

      error = assert_raises(RuntimeError) { run_measure_tests(['fixture_test.rb', 'other_test.rb']) }

      assert_includes(error.message, 'Measure test failures (2):')
      assert_includes(error.message, 'FAILED: fixture_test.rb (exit 42)')
      assert_includes(error.message, 'FAILED: other_test.rb (exit 17)')
      refute_includes(error.message, $LOAD_PATH.join(File::PATH_SEPARATOR))
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

  def test_summary_names_failed_test_methods_and_messages
    with_fixture do
      File.write('fixture_test.rb', <<~RUBY)
        #{passing_test}
        class FixtureTest
          def test_failure
            flunk 'expected value missing'
          end

          def test_error
            raise 'missing input'
          end
        end
      RUBY

      error = assert_raises(RuntimeError) { run_measure_tests(['fixture_test.rb']) }

      assert_includes(error.message, 'FAILED: fixture_test.rb (exit 1)')
      assert_includes(error.message, 'FixtureTest#test_failure: expected value missing')
      assert_includes(error.message, 'FixtureTest#test_error: RuntimeError: missing input')
      refute_includes(error.message, 'FixtureTest#test_passes')
    end
  end

  def test_crash_without_report_keeps_file_and_exit_status
    with_fixture do
      File.write('fixture_test.rb', "exit! 42\n")

      error = assert_raises(RuntimeError) { run_measure_tests(['fixture_test.rb']) }

      assert_includes(error.message, 'FAILED: fixture_test.rb (exit 42)')
    end
  end

  def test_failure_report_is_not_hidden_by_successful_exit
    with_fixture do
      File.write('fixture_test.rb', <<~RUBY)
        #{passing_test}
        class FixtureTest
          def test_failure
            flunk 'expected failure'
          end
        end
        Minitest.after_run { exit! 0 }
      RUBY

      error = assert_raises(RuntimeError) { run_measure_tests(['fixture_test.rb']) }

      assert_includes(error.message, 'JUnit reports contain failures or errors')
      assert_includes(error.message, 'FixtureTest#test_failure: expected failure')
    end
  end

  def test_all_tests_continues_after_failures_and_prints_one_final_summary
    original_step_summary = ENV.fetch('GITHUB_STEP_SUMMARY', nil)
    with_test_groups do
      ENV['GITHUB_STEP_SUMMARY'] = File.expand_path('step-summary.md')
      File.write('reporting_fixture_test.rb', "exit! 42\n")
      File.write('upgrade_fixture_test.rb', passing_test.sub('assert true', "flunk 'expected upgrade failure'"))

      _, stderr = capture_io do
        error = assert_raises(SystemExit) { Rake::Task['unit_tests:all_tests'].invoke }
        assert_equal(1, error.status)
      end

      heading, details = stderr.split("\n", 2)
      assert_equal('Measure test groups failed (2):', heading)
      assert_includes(details, 'reporting_measure_tests:')
      assert_includes(details, 'reporting_fixture_test.rb (exit 42)')
      assert_includes(details, 'upgrade_measure_tests:')
      assert_includes(details, 'FixtureTest#test_passes: expected upgrade failure')
      assert_equal(2, details.scan(/^FAILED:/).size)
      assert_equal("## #{heading.delete_suffix(':')}\n\n#{details.chomp.gsub(/^/, '    ')}\n", File.read('step-summary.md'))
      reports = Dir.glob(File.join(ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR'), 'workflow_fixture_test', 'TEST-*.xml'))
      assert_equal(1, reports.size)
    end
  ensure
    ENV['GITHUB_STEP_SUMMARY'] = original_step_summary
  end

  def test_all_tests_succeeds_when_every_group_passes
    with_test_groups do
      Rake::Task['unit_tests:all_tests'].invoke

      reports = Dir.glob(File.join(ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR'), '*_fixture_test', 'TEST-*.xml'))
      assert_equal(3, reports.size)
    end
  end
end
