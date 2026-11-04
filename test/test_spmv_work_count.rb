# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/spmv_work_count'

class SpmvWorkCountTest < Minitest::Test
  def row(id, backend, bytes)
    { 'id' => id, 'backend' => backend, 'source_files' => {
      'spmv/spmv.cpp' => { 'bytes' => bytes }, 'spmv/CMakeLists.txt' => { 'bytes' => 999_999 }
    } }
  end

  def test_pilot_selects_winner_median_and_largest_per_backend_deterministically
    rows = %w[mpi omp].flat_map { |backend| (1..5).map { |n| row("#{backend}-#{n}", backend, n * 10) } }
    selected = ValidationAudit::SpmvWorkCount.select_pilot(rows.reverse, %w[mpi-1 omp-3])
    assert_equal %w[mpi-1 mpi-3 mpi-5 omp-3 omp-5], selected.map { |r| r.fetch('id') }
    assert_raises(RuntimeError) { ValidationAudit::SpmvWorkCount.select_pilot(rows, ['mpi-1']) }
  end

  def test_estimate_counts_review_not_fast_preparation_and_applies_five_hour_gate
    estimate = ValidationAudit::SpmvWorkCount.review_estimate(started_at: '2026-11-04T07:11:19Z',
      finished_at: '2026-11-04T07:20:15Z', reviewed: 12, population: 722)
    assert_equal 536, estimate.fetch('review_seconds')
    assert_equal 710, estimate.fetch('remaining_implementations')
    assert_in_delta 8.809259, estimate.fetch('projected_remaining_review_hours'), 0.000001
    assert estimate.fetch('approval_required')
    assert_raises(RuntimeError) do
      ValidationAudit::SpmvWorkCount.review_estimate(started_at: '2026-11-04T07:20:15Z',
        finished_at: '2026-11-04T07:11:19Z', reviewed: 12, population: 722)
    end
  end

  def test_evidence_is_digest_bound_and_excerpts_are_bounded
    Dir.mktmpdir('spmv-review-test-', '/tmp') do |directory|
      source = File.join(directory, 'spmv.cpp')
      dump = File.join(directory, 'host-assembly.txt')
      File.write(source, "line one\nline two\n")
      File.write(dump, "instruction one\ninstruction two\n")
      pack = { 'source' => { 'id' => 'fixture', 'source_files' => {
        'spmv.cpp' => { 'sha256' => ValidationAudit.sha(source), 'git_blob' => 'blob' }
      } }, 'local_directory' => directory, 'binary_sha256' => 'binary', 'binding_sha256' => 'binding',
        'inspections' => { 'host-assembly.txt' => { 'sha256' => ValidationAudit.sha(dump), 'command' => ['objdump', 'fixture'] } } }
      review = { 'id' => 'fixture', 'finding' => 'no_work_count_omission_identified',
        'source_evidence' => [{ 'file' => 'spmv.cpp', 'ranges' => [[1, 2]] }],
        'compiled_evidence' => [{ 'file' => 'host-assembly.txt', 'ranges' => [[2, 2]] }] }
      result = ValidationAudit::SpmvWorkCount.reviewed_pack(pack, review)
      refute result.fetch('source_evidence').first.key?('text')
      assert_equal "instruction two\n", result.dig('compiled_evidence', 0, 'excerpts', 0, 'text')
      assert_raises(RuntimeError) { ValidationAudit::SpmvWorkCount.line_excerpts(source, [[0, 1]]) }
      assert_raises(RuntimeError) { ValidationAudit::SpmvWorkCount.line_excerpts(source, [[1, 3]]) }
      File.write(dump, 'modified')
      assert_raises(RuntimeError) { ValidationAudit::SpmvWorkCount.reviewed_pack(pack, review) }
    end
  end

  def test_inspection_does_not_run_generated_programs
    source = File.read(File.expand_path('../tools/validation_audit/spmv_work_count.rb', __dir__))
    assert_includes source, "capture(['objdump'"
    assert_includes source, "capture(['cuobjdump'"
    refute_match(/BenchmarkPipeline|benchmark_times|Runner\.new/, source)
  end
end
