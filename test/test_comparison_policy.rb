# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../validation_helper'

class ComparisonPolicyTest < Minitest::Test
  def output(hash = '0998f1bc88b15e85')
    "Validation: PASSED\n=== RESULTS ===\nName: DistanceMatrix\nElements: 262144\nMin: 0\nMax: 10\nSample[0]: 0\nHash: #{hash}\n=== END RESULTS ===\n"
  end

  def test_exact_integer_hash_is_required_for_floyd_only
    assert validate(output, output, 'floydwarshall').first
    success, reason = validate(output, output('0998f1bc88b15e86'), 'floydwarshall')
    refute success
    assert_match(/Exact integer result mismatch/, reason)
    %w[stencil3d cahn-hilliard unstructured matmul nbody qtclustering roomsim spmv black-scholes cholesky].each do |benchmark|
      assert validate(output, output('0998f1bc88b15e86'), benchmark).first
    end
  end

  def test_missing_or_malformed_hash_is_not_a_pass
    refute validate(output, output('not-a-hash'), 'floydwarshall').first
    refute validate(output, output.sub(/^Hash:.*\n/, ''), 'floydwarshall').first
    refute LocalEvaluation::ComparisonPolicy.integer_hashes(output, output.sub('Hash:', 'Summary:')).first
  end

  def test_numeric_comparison_still_applies
    refute validate(output, output.sub('Max: 10', 'Max: 11'), 'floydwarshall').first
    refute validate(output, output.sub('Elements: 262144', 'Elements: 1'), 'floydwarshall').first
  end

  def test_known_wrong_reference_distance_is_rejected
    require 'json'
    path = File.join('/home/petert/llm-eval-local', 'analysis/notes/2026-11-03-winner-validity/evidence.json')
    skip 'Archived diagnostic unavailable' unless File.file?(path)
    counterexample = JSON.parse(File.read(path)).fetch('counterexamples').find { |c| c.fetch('benchmark') == 'floydwarshall' }
    original, wrong = counterexample.fetch('outputs').map { |o| o.dig('stdout', 'text') }
    refute validate(original, wrong, 'floydwarshall').first
  end
end
