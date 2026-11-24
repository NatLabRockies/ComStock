# Regression tests for subprocess failures, fresh JUnit reports, readable failure
# summaries, and continuing through all test groups before reporting failure.

require_relative 'minitest_helper'
require 'open3'
require 'rake'
require 'tmpdir'

load File.expand_path('../../Rakefile', __dir__)

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
    names = ['measure_tests', 'helper_tests', 'reporting_measure_tests', 'workflow_measure_tests', 'upgrade_measure_tests']
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
      helper = File.expand_path('minitest_helper.rb', __dir__)
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
      helper = File.expand_path('minitest_helper.rb', __dir__)
      runner = File.expand_path('measure_test_runner.rb', __dir__)
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
      assert_includes(error.message, 'FAIL: fixture_test.rb (exit 42)')
      assert_includes(error.message, 'FAIL: other_test.rb (exit 17)')
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

      assert_includes(error.message, 'FAIL: fixture_test.rb (exit 1)')
      assert_includes(error.message, 'FixtureTest#test_failure: expected value missing')
      assert_includes(error.message, 'FixtureTest#test_error: RuntimeError: missing input')
      refute_includes(error.message, 'FixtureTest#test_passes')
    end
  end

  def test_crash_without_report_keeps_file_and_exit_status
    with_fixture do
      File.write('fixture_test.rb', "exit! 42\n")

      error = assert_raises(RuntimeError) { run_measure_tests(['fixture_test.rb']) }

      assert_includes(error.message, 'FAIL: fixture_test.rb (exit 42)')
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

  def test_measure_tests_continues_after_failures_and_prints_one_final_summary
    original_step_summary = ENV.fetch('GITHUB_STEP_SUMMARY', nil)
    with_test_groups do
      ENV['GITHUB_STEP_SUMMARY'] = File.expand_path('step-summary.md')
      File.write('reporting_fixture_test.rb', "exit! 42\n")
      File.write('upgrade_fixture_test.rb', <<~RUBY)
        #{passing_test}
        class FixtureTest
          def test_fails
            flunk 'expected upgrade failure'
          end

          def test_errors
            raise 'expected upgrade error'
          end

          def test_skipped
            skip 'not a pass'
          end
        end
      RUBY

      _, stderr = capture_io do
        error = assert_raises(SystemExit) { Rake::Task['unit_tests:measure_tests'].invoke }
        assert_equal(1, error.status)
      end

      heading, details = stderr.split("\n", 2)
      assert_equal('Measure test groups failed (2):', heading)
      assert_includes(details, 'reporting_measure_tests:')
      assert_includes(details, 'reporting_fixture_test.rb (exit 42)')
      assert_includes(details, 'upgrade_measure_tests:')
      assert_includes(details, 'FixtureTest#test_fails: expected upgrade failure')
      assert_equal(2, details.scan(/^FAIL:/).size)
      summary = File.read('step-summary.md')
      passed = summary.split("\n## Measure tests passed", 2).last.split("\n## Measure tests failed", 2).first
      assert_includes(summary, 'Discovered tests: unavailable; JUnit results: 5.')
      assert_includes(summary, 'Percentage ranges are unavailable')
      assert_includes(summary, '## Measure tests failed (2)')
      assert_includes(summary, '## Measure tests skipped (1)')
      assert_includes(summary, '## Measure tests without classified outcomes (unavailable)')
      failed_groups = details.chomp.split("\n\n").map do |group|
        group_name, group_details = group.split("\n", 2)
        "**#{group_name}**\n\n#{group_details.gsub(/^/, '    ')}"
      end
      assert_includes(summary, "### #{heading.delete_suffix(':')}\n\n#{failed_groups.join("\n\n")}")
      assert_equal([
                     '## Measure tests passed (2)',
                     '## Measure tests failed (2)',
                     '## Measure tests skipped (1)',
                     '## Measure tests without classified outcomes (unavailable)'
                   ], summary.lines.grep(/^## Measure tests /).map(&:strip))
      assert_equal(<<~SUMMARY.chomp, passed.strip)
        (2)

        **workflow_measure_tests:**

            PASS: workflow_fixture_test.rb
              FixtureTest#test_passes

        **upgrade_measure_tests:**

            PASS: upgrade_fixture_test.rb
              FixtureTest#test_passes
      SUMMARY
      reports = Dir.glob(File.join(ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR'), 'workflow_fixture_test', 'TEST-*.xml'))
      assert_equal(1, reports.size)
    end
  ensure
    ENV['GITHUB_STEP_SUMMARY'] = original_step_summary
  end

  def test_measure_tests_succeeds_when_every_group_passes
    original_step_summary = ENV.fetch('GITHUB_STEP_SUMMARY', nil)
    with_test_groups do
      ENV['GITHUB_STEP_SUMMARY'] = File.expand_path('step-summary.md')
      File.write('reporting_fixture_test.rb', <<~RUBY)
        #{passing_test}
        class FixtureTest
          def test_skipped
            skip 'not a pass'
          end
        end
      RUBY
      Rake::Task['unit_tests:measure_tests'].invoke

      summary = File.read('step-summary.md')
      assert_includes(summary, 'Discovered tests: 4; JUnit results: 4.')
      assert_includes(summary, '## Measure tests failed (0, 0.00%)')
      assert_includes(summary, '## Measure tests skipped (1, 25.00%)')
      assert_includes(summary, '## Measure tests without classified outcomes (0, 0.00%)')
      assert_includes(summary, '## Measure tests passed (3, 75.00%)')
      assert_equal(3, summary.scan(/^    PASS:/).size)
      refute_includes(summary, 'FAIL:')
      reports = Dir.glob(File.join(ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR'), '*_fixture_test', 'TEST-*.xml'))
      assert_equal(3, reports.size)
    end
  ensure
    ENV['GITHUB_STEP_SUMMARY'] = original_step_summary
  end

  def write_helper_fixture(body)
    FileUtils.mkdir_p('test/helpers')
    File.write('test/helpers/test_helper_fixture.rb', body)
  end

  def test_helper_tests_summarize_passes_and_failures
    original_step_summary = ENV.fetch('GITHUB_STEP_SUMMARY', nil)
    with_test_groups do
      ENV['GITHUB_STEP_SUMMARY'] = File.expand_path('step-summary.md')
      write_helper_fixture(<<~RUBY)
        #{passing_test}
        class FixtureTest
          def test_helper_failure
            flunk 'helper test failed'
          end
        end
      RUBY

      _, stderr = capture_io { assert_raises(SystemExit) { Rake::Task['unit_tests:helper_tests'].invoke } }
      assert_includes(stderr, 'Helper test failures (1):')
      assert_includes(stderr, 'FixtureTest#test_helper_failure: helper test failed')
      summary = File.read('step-summary.md')
      assert_includes(summary, '## Helper tests passed (1)')
      assert_includes(summary, "    PASS: test/helpers/test_helper_fixture.rb\n      FixtureTest#test_passes")
      assert_includes(summary, '## Helper tests failed (1)')
      assert_includes(summary, 'helper test failed')
      assert_includes(summary, '## Helper tests skipped (0)')
      refute_includes(summary, '## Measure tests')
    end
  ensure
    ENV['GITHUB_STEP_SUMMARY'] = original_step_summary
  end

  def test_helper_tests_report_crash_in_summary
    original_step_summary = ENV.fetch('GITHUB_STEP_SUMMARY', nil)
    with_test_groups do
      ENV['GITHUB_STEP_SUMMARY'] = File.expand_path('step-summary.md')
      write_helper_fixture("exit! 42\n")

      _, stderr = capture_io { assert_raises(SystemExit) { Rake::Task['unit_tests:helper_tests'].invoke } }
      assert_includes(stderr, 'test_helper_fixture.rb (exit 42')
      summary = File.read('step-summary.md')
      assert_includes(summary, '## Helper tests passed (0)')
      assert_includes(summary, 'test_helper_fixture.rb (exit 42')
    end
  ensure
    ENV['GITHUB_STEP_SUMMARY'] = original_step_summary
  end

  def test_helper_tests_succeed_when_every_test_passes
    original_step_summary = ENV.fetch('GITHUB_STEP_SUMMARY', nil)
    with_test_groups do
      ENV['GITHUB_STEP_SUMMARY'] = File.expand_path('step-summary.md')
      write_helper_fixture(passing_test)

      capture_io { Rake::Task['unit_tests:helper_tests'].invoke }
      summary = File.read('step-summary.md')
      assert_includes(summary, '## Helper tests passed (1)')
      assert_includes(summary, '## Helper tests failed (0)')
      refute_includes(summary, 'FAIL:')
    end
  ensure
    ENV['GITHUB_STEP_SUMMARY'] = original_step_summary
  end

  def test_summary_ranges_include_unreported_but_not_skipped_tests
    original_step_summary = ENV.fetch('GITHUB_STEP_SUMMARY', nil)
    with_test_groups do
      ENV['GITHUB_STEP_SUMMARY'] = File.expand_path('step-summary.md')
      File.write('reporting_fixture_test.rb', <<~RUBY)
        require 'minitest/autorun'
        class FixtureTest < Minitest::Test
          def test_crash
            exit! 42
          end

          def test_unknown
            assert true
          end
        end
      RUBY
      File.write('upgrade_fixture_test.rb', <<~RUBY)
        #{passing_test}
        class FixtureTest
          def test_failure
            flunk 'failure'
          end

          def test_error
            raise 'error'
          end

          def test_skipped
            skip 'skipped'
          end
        end
      RUBY
      capture_io { assert_raises(SystemExit) { Rake::Task['unit_tests:measure_tests'].invoke } }

      summary = File.read('step-summary.md')
      assert_includes(summary, 'Discovered tests: 7; JUnit results: 5.')
      assert_includes(summary, '## Measure tests failed (2, 28.57-57.14%)')
      assert_includes(summary, '## Measure tests passed (2, 28.57-57.14%)')
      assert_includes(summary, '## Measure tests skipped (1, 14.29-42.86%)')
      assert_includes(summary, '## Measure tests without classified outcomes (2, 28.57%)')
      assert_includes(summary, "### Discovered tests without a confirmed pass, failure, or skip\n")
      assert_includes(summary, 'JUnit reports are missing, incomplete, or cannot be fully read.')
      assert_includes(summary, 'The count is unavailable if discovery is incomplete.')
    end
  ensure
    ENV['GITHUB_STEP_SUMMARY'] = original_step_summary
  end

  def test_long_escaped_failure_message_does_not_hide_other_results
    original_step_summary = ENV.fetch('GITHUB_STEP_SUMMARY', nil)
    with_test_groups do
      ENV['GITHUB_STEP_SUMMARY'] = File.expand_path('step-summary.md')
      File.write('reporting_fixture_test.rb', <<~RUBY)
        #{passing_test}
        class FixtureTest
          def test_long_failure
            flunk '<&' * 11_000
          end
          def test_other_pass
            assert true
          end
        end
      RUBY

      capture_io { assert_raises(SystemExit) { Rake::Task['unit_tests:measure_tests'].invoke } }

      summary = File.read('step-summary.md')
      assert_includes(summary, 'Discovered tests: 5; JUnit results: 5.')
      assert_includes(summary, '## Measure tests failed (1, 20.00%)')
      assert_includes(summary, '## Measure tests passed (4, 80.00%)')
      assert_includes(summary, '## Measure tests without classified outcomes (0, 0.00%)')
      assert_includes(summary, 'FixtureTest#test_long_failure:')
      assert_includes(summary, '[truncated]')
    end
  ensure
    ENV['GITHUB_STEP_SUMMARY'] = original_step_summary
  end

  def test_unclassifiable_reported_case_is_counted_as_unknown
    original_step_summary = ENV.fetch('GITHUB_STEP_SUMMARY', nil)
    with_test_groups do
      ENV['GITHUB_STEP_SUMMARY'] = File.expand_path('step-summary.md')
      File.write('reporting_fixture_test.rb', <<~RUBY)
        #{passing_test}
        Minitest.after_run do
          report = Dir.glob(File.join(ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR'), 'TEST-*.xml')).first
          File.write(report, '<testsuite><testcase classname="' + ('&amp;' * 11_000) + '" name="test_passes"/></testsuite>')
        end
      RUBY

      capture_io { assert_raises(SystemExit) { Rake::Task['unit_tests:measure_tests'].invoke } }

      summary = File.read('step-summary.md')
      assert_includes(summary, 'Discovered tests: 3; JUnit results: 3.')
      assert_includes(summary, '## Measure tests failed (0, 0.00-33.33%)')
      assert_includes(summary, '## Measure tests passed (2, 66.67-100.00%)')
      assert_includes(summary, '## Measure tests without classified outcomes (1, 33.33%)')
      assert_includes(summary, 'entity expansion has grown too large')
    end
  ensure
    ENV['GITHUB_STEP_SUMMARY'] = original_step_summary
  end

  def test_incomplete_report_fails_even_when_process_succeeds
    original_step_summary = ENV.fetch('GITHUB_STEP_SUMMARY', nil)
    with_test_groups do
      ENV['GITHUB_STEP_SUMMARY'] = File.expand_path('step-summary.md')
      File.write('reporting_fixture_test.rb', <<~RUBY)
        #{passing_test}
        class FixtureTest
          def test_other_pass
            assert true
          end
        end
        Minitest.after_run do
          report = Dir.glob(File.join(ENV.fetch('MINITEST_REPORTERS_REPORTS_DIR'), 'TEST-*.xml')).first
          File.write(report, '<testsuite><testcase classname="FixtureTest" name="test_passes"/></testsuite>')
        end
      RUBY

      capture_io { assert_raises(SystemExit) { Rake::Task['unit_tests:measure_tests'].invoke } }

      summary = File.read('step-summary.md')
      assert_includes(summary, 'Discovered tests: 4; JUnit results: 3.')
      assert_includes(summary, 'JUnit reported 1 of 2 discovered tests')
      assert_includes(summary, '## Measure tests without classified outcomes (1, 25.00%)')
    end
  ensure
    ENV['GITHUB_STEP_SUMMARY'] = original_step_summary
  end
end
