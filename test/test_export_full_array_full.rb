# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/export_full_array_full'

class FullArrayFullExportTest < Minitest::Test
  Export = ValidationAudit::FullArrayFullExport

  def test_compact_binding_preserves_exact_original_receipt
    source = { 'source_files' => { 'common/hash.hpp' => { 'sha256' => 'a' * 64 } } }
    binding = { 'id' => 'fixture', 'source_files' => source.fetch('source_files'), 'binary_sha256' => 'b' * 64 }
    compact = Export.compact_binding(binding, source)
    refute compact.key?('source_files')
    assert_equal binding, Export.expand_binding(compact, source)
    assert_equal Export.json_digest(binding), Export.json_digest(Export.expand_binding(compact, source))
    assert_raises(RuntimeError) { Export.compact_binding(binding, { 'source_files' => {} }) }
    assert_raises(RuntimeError) { Export.expand_binding(compact.merge('source_files' => {}), source) }
    assert_raises(RuntimeError) { Export.compact_binding(binding.merge('source_files_from_comparison' => true), source) }
  end

  def test_completion_requires_exact_complete_scope_and_zero_model_or_benchmark_runs
    plan = { 'groups' => [{ 'full_ids' => %w[a b] }], 'reused' => { 'a' => {} }, 'population' => 2,
      'new_checks' => 1, 'benchmark_runs' => 0, 'llm_invocations' => 0, 'program_source_changes' => 0 }
    completion = { 'status' => 'complete', 'full_scope_accounted_for' => true, 'plan_sha256' => 'digest',
      'population' => 2, 'completed_checks' => 2, 'reused_checks' => 1, 'failed_ids' => ['a'],
      'passed_checks' => 1, 'benchmark_runs' => 0, 'llm_invocations' => 0 }
    assert_equal %w[a b], Export.check_completion!(plan, completion, 'digest')
    [{ 'status' => 'running' }, { 'completed_checks' => 1 }, { 'plan_sha256' => 'other' },
     { 'failed_ids' => %w[a a] }, { 'failed_ids' => ['c'] }, { 'passed_checks' => 2 },
     { 'reused_checks' => 0 }, { 'llm_invocations' => 1 }, { 'benchmark_runs' => 1 }].each do |change|
      assert_raises(RuntimeError) { Export.check_completion!(plan, completion.merge(change), 'digest') }
    end
    assert_raises(RuntimeError) { Export.check_completion!(plan.merge('new_checks' => 2), completion, 'digest') }
  end

  def test_shards_are_bounded_lossless_and_never_overwritten
    Dir.mktmpdir('full-array-export-test-', '/tmp') do |directory|
      records = (1..5).map { |i| { 'id' => i, 'text' => "line one\nline two" } }
      shards = Export.write_shards(directory, 'records/matmul-mpi', records, limit: 90)
      assert_equal 3, shards.size
      assert shards.all? { |s| s.fetch('bytes') <= 90 }
      actual = shards.flat_map do |shard|
        path = File.join(directory, shard.fetch('path'))
        assert_equal shard.fetch('sha256'), ValidationAudit.sha(path)
        File.readlines(path).map { |line| JSON.parse(line) }
      end
      assert_equal records, actual
      assert_equal 5, shards.sum { |s| s.fetch('records') }
      assert_raises(RuntimeError) { Export.write_shards(directory, 'records/matmul-mpi', records) }
      assert_raises(RuntimeError) { Export.write_shards(directory, '../outside', records) }
      assert_raises(RuntimeError) { Export.write_shards(directory, 'records/matmul-omp', records, limit: 10) }
      refute File.exist?(File.join(directory, 'records/matmul-omp-001.jsonl'))
    end
  end
end
