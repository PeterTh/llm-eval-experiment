# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/shape_full'

class ValidationShapeFullTest < Minitest::Test
  def test_explicit_approval_is_bound_to_scope_and_forbids_measurements
    plan = { 'checks' => 8176 }
    approval = { 'source' => 'user', 'approved' => true, 'scope' => 'full-shape-topology-sweep',
      'plan_sha256' => 'plan', 'pilot_sha256' => 'pilot', 'planned_checks' => 8176,
      'benchmark_runs' => 0, 'statement' => 'Yes, launch this sweep' }
    ValidationAudit::FullShapeCampaign.check_authorization!(approval, 'plan', 'pilot', plan)
    { 'approved' => false, 'plan_sha256' => 'changed', 'pilot_sha256' => 'changed', 'planned_checks' => 8177,
      'benchmark_runs' => 1, 'statement' => '' }.each do |key, value|
      assert_raises(RuntimeError) do
        ValidationAudit::FullShapeCampaign.check_authorization!(approval.merge(key => value), 'plan', 'pilot', plan)
      end
    end
  end

  def test_only_the_piloted_definitions_are_selected
    definition = ValidationAudit::ShapeTopologyCampaign.definition('stencil3d', 'mpi')
    group = { 'definition' => definition, 'backend' => 'mpi' }
    assert_equal definition, ValidationAudit::FullShapeCampaign.expected_definition(group)
    assert_includes definition.fetch('args'), '129'
    fast = { 'id' => 'cholesky-large-tile-v1', 'benchmark' => 'cholesky', 'args' => %w[-v -r -n 1537], 'topology' => 'measurement', 'timeout' => 30 }
    assert_equal fast, ValidationAudit::FullShapeCampaign.expected_definition('definition' => fast, 'backend' => 'omp')
  end

  class FakeRunner
    attr_reader :calls
    def initialize(directory)
      @directory, @calls = directory, []
    end
    def with_host
      yield
    end
    def check(row, definition, reference:)
      @calls << [row.fetch('id'), definition.fetch('id')]
      result = row.slice('id', 'source_commit', 'source_path').merge('definition' => definition,
        'passed' => row.fetch('id') != 'fixture-a', 'comparison' => [row.fetch('id') != 'fixture-a', 'fixture comparison'],
        'checked_at' => Time.now.utc.iso8601, 'performance_measurement' => false)
      ValidationAudit.save(File.join(@directory, definition.fetch('id'), row.fetch('id'), 'result.json'), result)
      result
    end
  end

  def fixture(directory, cached_failure: false)
    a = { 'id' => 'fixture-a', 'source_commit' => 'a' * 40, 'source_path' => 'fixture/a' }
    b = { 'id' => 'fixture-b', 'source_commit' => 'b' * 40, 'source_path' => 'fixture/b' }
    first = { 'id' => 'first-case', 'benchmark' => 'stencil3d' }
    second = { 'id' => 'second-case', 'benchmark' => 'stencil3d' }
    groups = [ { 'definition' => first, 'backend' => 'omp', 'rows' => [a, b] },
      { 'definition' => second, 'backend' => 'omp', 'rows' => [a] } ]
    runner = FakeRunner.new(directory)
    cache = cached_failure ? runner.check(a, first, reference: '') : nil
    runner.calls.clear
    ValidationAudit.save(File.join(directory, ValidationAudit::FullShapeCampaign::APPROVAL_FILE), {})
    campaign = ValidationAudit::FullShapeCampaign.allocate
    campaign.instance_variable_set(:@evidence, directory)
    campaign.instance_variable_set(:@workspace, directory)
    campaign.instance_variable_set(:@runner, runner)
    campaign.define_singleton_method(:verify_inputs!) do
      @plan = { 'checks' => 3, 'unique_programs' => 2 }
      @plan_digest, @pilot_digest = 'plan', 'pilot'
      @groups = groups
      @pilot = { 'groups' => groups.map { |g| { 'case' => g.dig('definition', 'id'), 'backend' => 'omp', 'projected_full_seconds' => g.fetch('rows').size * 0.01 } } }
      @results = cache ? { 'first-case/fixture-a' => cache } : {}
      @failures = cache ? { 'fixture-a' => 'first-case/fixture-a' } : {}
      @skips, @references, @costs = {}, {}, {}
      true
    end
    campaign.define_singleton_method(:verify_result!) { |_row, _definition, _result| true }
    campaign.define_singleton_method(:reference_for) { |_definition| 'fixture reference' }
    [campaign, runner]
  end

  def run_fixture(campaign)
    ValidationAudit::MethodSnapshot.stub(:save, {}) do
      LocalEvaluation.stub(:ensure_disk_space!, true) { capture_io { campaign.run } }
    end
  end

  def test_new_failure_is_recorded_and_later_check_is_skipped_without_retry
    Dir.mktmpdir('shape-full-test-', '/tmp') do |directory|
      campaign, runner = fixture(directory)
      output, = run_fixture(campaign)
      assert_equal [['fixture-a', 'first-case'], ['fixture-b', 'first-case']], runner.calls
      assert_includes output, 'new_failure'
      assert File.file?(File.join(directory, 'shape-full-failure-events/fixture-a.json'))
      skip = ValidationAudit.read(File.join(directory, 'shape-full-skips/second-case/fixture-a.json'))
      assert_equal 'first-case/fixture-a', skip.fetch('failed_result_key')
      result = ValidationAudit.read(File.join(directory, 'shape-topology-full-completion.json'))
      assert_equal 3, result.fetch('accounted_checks')
      assert_equal 2, result.fetch('completed_checks')
      assert_equal 1, result.fetch('skipped_checks')
      assert_equal ['fixture-a'], result.fetch('failed_ids')
      assert_equal 0, result.fetch('benchmark_runs')
    end
  end

  def test_pilot_failure_is_reused_without_new_execution_or_duplicate_alert
    Dir.mktmpdir('shape-full-test-', '/tmp') do |directory|
      campaign, runner = fixture(directory, cached_failure: true)
      output, = run_fixture(campaign)
      assert_equal [['fixture-b', 'first-case']], runner.calls
      refute_includes output, 'new_failure'
      refute File.exist?(File.join(directory, 'shape-full-failure-events/fixture-a.json'))
      assert_equal 1, ValidationAudit.read(File.join(directory, 'shape-topology-full-completion.json')).fetch('new_checks_this_attempt')
    end
  end

  def test_classifies_the_persisted_record_not_an_in_memory_representation
    Dir.mktmpdir('shape-full-test-', '/tmp') do |directory|
      campaign, runner = fixture(directory)
      original = runner.method(:check)
      runner.define_singleton_method(:check) do |*args, **keywords|
        result = original.call(*args, **keywords)
        result.merge('passed' => true, 'execution' => { success: true })
      end
      run_fixture(campaign)
      report = ValidationAudit.read(File.join(directory, 'shape-topology-full-completion.json'))
      assert_equal ['fixture-a'], report.fetch('failed_ids')
      assert_equal 1, report.fetch('passed_checks')
      assert_equal 1, report.fetch('skipped_checks')
    end
  end

  def test_stop_guard_does_not_execute_a_program
    Dir.mktmpdir('shape-full-test-', '/tmp') do |directory|
      campaign, runner = fixture(directory)
      File.write(File.join(directory, 'STOP-shape-topology-full'), 'test')
      assert_match(/STOP guard/, assert_raises(RuntimeError) { run_fixture(campaign) }.message)
      assert_empty runner.calls
      assert_equal 'stopped', ValidationAudit.read(File.join(directory, 'shape-topology-full-state.json')).fetch('status')
      refute File.exist?(File.join(directory, 'shape-topology-full-completion.json'))
    end
  end

  def enable_parallel_fixture(campaign, directory)
    original = campaign.method(:verify_inputs!)
    policy = { 'groups' => {
      'first-case/omp' => { 'workers' => 2, 'measured_speedup' => 1.5 },
      'second-case/omp' => { 'workers' => 1, 'measured_speedup' => 1.0 }
    } }
    ValidationAudit.save(File.join(directory, ValidationAudit::ConcurrencyPolicy::FILE), policy)
    campaign.define_singleton_method(:verify_inputs!) do
      original.call
      @scheduling = policy
    end
  end

  def test_parallel_wave_keeps_failure_and_skips_later_case_without_retry
    Dir.mktmpdir('shape-full-test-', '/tmp') do |directory|
      campaign, runner = fixture(directory)
      enable_parallel_fixture(campaign, directory)
      run_fixture(campaign)
      assert_equal [['fixture-a', 'first-case'], ['fixture-b', 'first-case']], runner.calls.sort
      completion = ValidationAudit.read(File.join(directory, 'shape-topology-full-completion.json'))
      assert_equal [2, 1, 2], completion.values_at('completed_checks', 'skipped_checks', 'max_workers')
      finish = ValidationAudit.read(Dir[File.join(directory, 'shape-full-waves/*-finish.json')].first)
      assert_equal 2, finish.fetch('workers')
      assert_equal %w[fixture-a fixture-b], finish.fetch('result_sha256').keys.sort
      assert File.file?(File.join(directory, 'shape-full-failure-events/fixture-a.json'))
    end
  end

  def test_parallel_infrastructure_error_retains_other_workers_completed_result
    Dir.mktmpdir('shape-full-test-', '/tmp') do |directory|
      campaign, runner = fixture(directory)
      enable_parallel_fixture(campaign, directory)
      original = runner.method(:check)
      runner.define_singleton_method(:check) do |row, definition, **keywords|
        raise LocalEvaluation::InfrastructureError, 'fixture build failure' if row.fetch('id') == 'fixture-a'
        original.call(row, definition, **keywords)
      end
      assert_raises(LocalEvaluation::InfrastructureError) { run_fixture(campaign) }
      state = ValidationAudit.read(File.join(directory, 'shape-topology-full-state.json'))
      assert_equal 'stopped', state.fetch('status')
      assert_equal 1, state.fetch('completed_checks')
      assert_equal 1, state.fetch('passed_checks')
      assert_empty state.fetch('failed_ids')
      assert File.file?(File.join(directory, 'first-case/fixture-b/result.json'))
      refute File.file?(File.join(directory, 'shape-topology-full-completion.json'))
    end
  end
end
