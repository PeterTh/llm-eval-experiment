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

  def test_streamed_option_blocks_preserve_rank_order_and_reject_incomplete_data
    capture = ValidationAudit::FullArrayCapture
    Dir.mktmpdir('option-block-test-', '/tmp') do |directory|
      values = (0...10003).map(&:to_f)
      fragments = 4.times.map do |rank|
        count = 10003 / 4 + (rank < 10003 % 4 ? 1 : 0)
        offset = rank * (10003 / 4) + [rank, 10003 % 4].min
        bytes = values.slice(offset, count).pack('E*')
        path = File.join(directory, "rank-#{rank}.f64le")
        File.binwrite(path, bytes)
        { 'rank' => "rank-#{rank}", 'name' => 'OptionPricesBlock', 'dtype' => 'f64le',
          'elements' => count, 'sha256' => Digest::SHA256.hexdigest(bytes), 'local_path' => path }
      end
      assert_raises(RuntimeError) { capture.assemble_option_blocks(fragments.drop(1), directory) }
      assert_raises(RuntimeError) { capture.assemble_option_blocks(fragments.map { |f| f.merge('rank' => 'rank-0') }, directory) }
      assert_raises(RuntimeError) { capture.assemble_option_blocks(fragments.map { |f| f.merge('elements' => 2500) }, directory) }
      assert_raises(RuntimeError) { capture.assemble_option_blocks(fragments.map { |f| f.merge('sha256' => 'changed') }, directory) }
      object = capture.assemble_option_blocks(fragments.reverse, directory)
      assert_equal values.pack('E*'), File.binread(object.fetch('local_path'))
      assert_equal capture.fnv(values.pack('E*')), object.fetch('fnv1a64')
      assert_equal 10003, object.fetch('elements')
    end
  end

  def test_halo_slab_assembly_keeps_observed_global_faces_and_excludes_only_halos
    capture = ValidationAudit::FullArrayCapture
    Dir.mktmpdir('halo-slab-test-', '/tmp') do |directory|
      plane, nz = 65 * 61, 67
      values = (0...(plane * nz)).map { |index| index + 0.25 }
      fragments = 4.times.map do |rank|
        depth = nz / 4 + (rank < nz % 4 ? 1 : 0)
        offset = (rank * (nz / 4) + [rank, nz % 4].min) * plane
        bytes = (Array.new(plane, -1000.0) + values.slice(offset, depth * plane) + Array.new(plane, -2000.0)).pack('E*')
        path = File.join(directory, "rank-#{rank}.f64le")
        File.binwrite(path, bytes)
        { 'rank' => "rank-#{rank}", 'name' => 'GridSlabWithHalos', 'dtype' => 'f64le',
          'elements' => (depth + 2) * plane, 'sha256' => Digest::SHA256.hexdigest(bytes), 'local_path' => path }
      end
      assert_raises(RuntimeError) { capture.assemble_stencil_halo_slabs(fragments.drop(1), directory) }
      assert_raises(RuntimeError) { capture.assemble_stencil_halo_slabs(fragments.map { |f| f.merge('rank' => 'rank-0') }, directory) }
      assert_raises(RuntimeError) { capture.assemble_stencil_halo_slabs(fragments.map { |f| f.merge('elements' => 1) }, directory) }
      assert_raises(RuntimeError) { capture.assemble_stencil_halo_slabs(fragments.map { |f| f.merge('sha256' => 'changed') }, directory) }
      object = capture.assemble_stencil_halo_slabs(fragments.reverse, directory)
      assert_equal values.pack('E*'), File.binread(object.fetch('local_path'))
      assert_equal capture.fnv(values.pack('E*')), object.fetch('fnv1a64')
      assert_equal values.size, object.fetch('elements')
    end
  end
end
