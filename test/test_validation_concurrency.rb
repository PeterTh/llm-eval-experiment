# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../tools/validation_audit/concurrency_pilot'
require_relative '../tools/validation_audit/concurrency_policy'

class ValidationConcurrencyTest < Minitest::Test
  def test_wave_is_bounded_and_preserves_input_order
    assert_raises(ArgumentError) { ValidationAudit::ParallelBatch.run([]) {} }
    assert_raises(ArgumentError) { ValidationAudit::ParallelBatch.run([1] * 5) {} }
    gate = Queue.new
    values = ValidationAudit::ParallelBatch.run([3, 2, 1, 0]) do |job, _index|
      gate << job
      Thread.pass until gate.size == 4
      job * 2
    end
    assert_equal [6, 4, 2, 0], values
  end

  def test_wave_drains_other_workers_before_propagating_error
    reached = Queue.new
    assert_raises(RuntimeError) do
      ValidationAudit::ParallelBatch.run([0, 1]) do |job, _index|
        raise 'fixture error' if job.zero?
        Thread.pass
        reached << 'other worker finished'
      end
    end
    assert_equal 'other worker finished', reached.pop(true)
  end

  def test_only_primary_cpu_checks_are_parallel_eligible
    ValidationAudit::ShapeTopologyCampaign::ARGUMENTS.each_key do |benchmark|
      %w[cuda hybrid mpi omp].each do |backend|
        group = { 'definition' => ValidationAudit::ShapeTopologyCampaign.definition(benchmark, backend), 'backend' => backend }
        assert_equal %w[mpi omp].include?(backend), ValidationAudit::ConcurrencyPilot.eligible?(group)
      end
    end
    large = { 'definition' => { 'id' => 'stencil3d-large-streaming-v1', 'benchmark' => 'stencil3d' }, 'backend' => 'omp' }
    refute ValidationAudit::ConcurrencyPilot.eligible?(large)
  end

  def test_resource_snapshot_is_read_only_and_has_pressure_counters
    snapshot = ValidationAudit::ConcurrencyPilot.resource_snapshot
    assert_operator snapshot.fetch('available_bytes'), :>, 0
    assert_operator snapshot.fetch('total_bytes'), :>=, snapshot.fetch('available_bytes')
    assert_includes snapshot.fetch('pressure_microseconds').keys, 'full'
  end

  def report(width, seconds, max_execution: seconds)
    { 'seconds_per_check' => seconds / width, 'all_passed' => true, 'resources_ok' => true,
      'records' => Array.new(width) { { 'execution' => { 'wall_seconds' => max_execution } } } }
  end

  def test_selection_requires_useful_gain_and_timeout_headroom
    policy = ValidationAudit::ConcurrencyPolicy
    assert_equal 1, policy.choose({ 1 => report(1, 10.0), 2 => report(2, 19.8) }).fetch('workers')
    assert_equal 2, policy.choose({ 1 => report(1, 12.0), 2 => report(2, 19.0) }).fetch('workers')
    assert_equal 2, policy.choose({ 1 => report(1, 12.0), 2 => report(2, 19.0), 4 => report(4, 28.0) }).fetch('workers')
    assert_equal 4, policy.choose({ 1 => report(1, 12.0), 2 => report(2, 19.0), 4 => report(4, 21.0) }).fetch('workers')
    assert_equal 1, policy.choose({ 1 => report(1, 12.0), 2 => report(2, 10.0).merge('resources_ok' => false) }).fetch('workers')
  end

  def test_selection_prefers_fewer_workers_when_rates_are_close
    assert_equal 2, ValidationAudit::ConcurrencyPolicy.choose(
      { 1 => report(1, 4.0), 2 => report(2, 4.0), 4 => report(4, 7.5) }).fetch('workers')
  end
end
