# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../tools/validation_audit/full_array_capture'

class FullArrayCaptureTest < Minitest::Test
  def test_all_blocks_are_parsed_not_only_the_first
    output = "=== RESULTS ===\nName: First\nElements: 2\nHash: 0000000000000001\n=== END RESULTS ===\n" \
      "=== RESULTS ===\nName: Second\nElements: 0\n=== END RESULTS ===\n"
    result = ValidationAudit::FullArrayCapture.output_objects(output)
    assert_equal %w[First Second], result.map { |o| o.fetch('name') }
    assert_equal [2, 0], result.map { |o| o.fetch('elements') }
    assert_nil result.last.fetch('fnv1a64')
    assert_raises(RuntimeError) { ValidationAudit::FullArrayCapture.output_objects(output.sub('0000000000000001', 'invalid')) }
  end

  def test_full_array_detects_sparse_sample_preserving_swap
    reference = (0...100).map(&:to_f)
    actual = reference.dup
    actual[11], actual[12] = actual[12], actual[11]
    assert_equal reference.sum, actual.sum
    assert_equal [0, 25, 50, 75, 99].map { |i| reference[i] }, [0, 25, 50, 75, 99].map { |i| actual[i] }
    result = ValidationAudit::FullArrayCapture.compare_values(reference, actual, epsilon: 1e-5)
    assert_equal 2, result.fetch('mismatches')
    assert_equal [11, 12], result.fetch('examples').map { |x| x.fetch('index') }
  end

  def test_tolerance_and_nonfinite_values
    check = ValidationAudit::FullArrayCapture
    assert_equal 0, check.compare_values([1.0], [1.000001], epsilon: 1e-5).fetch('mismatches')
    assert_equal 1, check.compare_values([1.0], [1.001], epsilon: 1e-5).fetch('mismatches')
    assert_equal 1, check.compare_values([1.0], [Float::NAN], epsilon: 1e-5).fetch('mismatches')
    assert_equal 0, check.compare_values([100.0], [104.0], epsilon: 5).fetch('mismatches')
    assert_raises(RuntimeError) { check.compare_values([Float::INFINITY], [Float::INFINITY], epsilon: 1e-5) }
    assert_raises(RuntimeError) { check.compare_values([0.0], [], epsilon: 1e-5) }
  end

  def test_fnv_matches_known_byte_vector
    assert_equal 'cbf29ce484222325', ValidationAudit::FullArrayCapture.fnv('')
    assert_equal 'a430d84680aabd0b', ValidationAudit::FullArrayCapture.fnv('hello')
  end
end
