# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../tools/validation_audit/spmv_native_review'

class SpmvNativeReviewTest < Minitest::Test
  def test_selection_uses_native_validation_and_no_performance_filter
    results = [%w[spmv omp 1], %w[spmv mpi 2], %w[matmul omp 1]].map do |benchmark, backend, run|
      result = ValidationResult.new(benchmark, 'fixture', backend, run.to_i)
      result.output_comparison = !(benchmark == 'spmv' && backend == 'mpi')
      result
    end.to_h { |result| [result.id_string, result] }
    assert_equal ['spmv_fixture_omp_r1'], ValidationAudit::SpmvNativeReview.eligible_ids(results)
  end

  def test_native_scope_is_bound_to_manifest_results_completion_and_inventory
    Dir.mktmpdir('native-spmv-test-', '/tmp') do |directory|
      validation = File.join(directory, 'validation-run')
      evidence = File.join(directory, 'evidence')
      FileUtils.mkdir_p([evidence, File.join(validation, 'validation')])
      pins = { 'evaluation_manifest.yaml' => 'validation_manifest_sha256',
        'validation/all_validation_results.yaml' => 'validation_results_sha256',
        'validation-completion-review.json' => 'validation_completion_sha256' }
      inventory = { 'validation_run' => validation,
        'rows' => [{ 'id' => 'spmv_fixture_omp_r1', 'benchmark' => 'spmv' }] }
      pins.each do |relative, key|
        path = File.join(validation, relative)
        File.binwrite(path, relative)
        inventory[key] = ValidationAudit.sha(path)
      end
      path = File.join(evidence, ValidationAudit::SpmvNativeReview::INVENTORY)
      ValidationAudit.save(path, inventory)
      tool = ValidationAudit::SpmvNativeReview.new(workspace: directory, evidence: evidence)
      ValidationAudit.save(File.join(tool.root, 'authorization.json'), {
        'full_review_authorized' => true, 'inventory_sha256' => ValidationAudit.sha(path) })
      assert_equal [inventory.fetch('rows'), []], tool.load_scope
      pins.each_key do |relative|
        original = File.binread(File.join(validation, relative))
        File.binwrite(File.join(validation, relative), 'changed')
        assert_raises(RuntimeError) { tool.load_scope }
        File.binwrite(File.join(validation, relative), original)
      end
      File.binwrite(path, '{}')
      assert_raises(RuntimeError) { tool.load_scope }
    end
  end
end
