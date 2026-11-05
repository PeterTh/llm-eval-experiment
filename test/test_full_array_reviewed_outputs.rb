# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/full_array_reviewed_outputs'

class FullArrayReviewedOutputsTest < Minitest::Test
  Review = ValidationAudit::FullArrayReviewedOutputs
  Capture = ValidationAudit::FullArrayCapture

  def fixture
    Dir.mktmpdir('primary-array-review-test-', '/tmp') do |directory|
      objects = [2.0, 25.5].each_with_index.map do |value, rank|
        bytes = [value].pack('E*')
        path = File.join(directory, rank.to_s)
        File.binwrite(path, bytes)
        { 'name' => 'Distances', 'elements' => 1, 'dtype' => 'f64le', 'bytes' => bytes.bytesize,
          'sha256' => Digest::SHA256.hexdigest(bytes), 'fnv1a64' => Capture.fnv(bytes), 'local_path' => path, 'rank' => "rank-#{rank}" }
      end
      stdout = objects.reverse.map do |object|
        "=== RESULTS ===\nName: Distances\nElements: 1\nHash: #{object.fetch('fnv1a64')}\n=== END RESULTS ===\n"
      end.join
      observation = { 'observation_complete' => true, 'errors' => [], 'objects' => objects,
        'printed_objects' => Capture.output_objects(stdout) }
      yield observation, stdout
    end
  end

  def test_primary_is_selected_by_printed_order_not_rank_or_passing_result
    fixture do |observation, stdout|
      ordered = Review.ordered_objects(observation, stdout)
      assert_equal %w[rank-1 rank-0], ordered.map { |object| object.fetch('rank') }
      assert_equal 25.5, File.binread(ordered.first.fetch('local_path')).unpack1('E')
      assert_equal 2, observation.fetch('objects').size
    end
  end

  def test_incomplete_observation_or_altered_bytes_are_rejected
    fixture do |observation, stdout|
      assert_raises(RuntimeError) { Review.ordered_objects(observation.merge('observation_complete' => false), stdout) }
      File.binwrite(observation.fetch('objects').first.fetch('local_path'), [3.0].pack('E*'))
      assert_raises(RuntimeError) { Review.ordered_objects(observation, stdout) }
    end
  end

  def test_missing_printed_replica_is_not_silently_ignored
    fixture do |observation, stdout|
      observation.fetch('objects').pop
      assert_raises(RuntimeError) { Review.ordered_objects(observation, stdout) }
    end
  end
end
