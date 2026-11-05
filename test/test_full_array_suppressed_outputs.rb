# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/full_array_suppressed_outputs'

class FullArraySuppressedOutputsTest < Minitest::Test
  Review = ValidationAudit::FullArraySuppressedOutputs
  Capture = ValidationAudit::FullArrayCapture

  def with_observation
    Dir.mktmpdir('suppressed-output-test-', '/tmp') do |directory|
      objects = (0..3).map do |rank|
        bytes = Array.new(320) { |index| rank.zero? ? index.to_f : (index / 80 == rank ? index.to_f : 0.0) }.pack('E*')
        path = File.join(directory, "rank-#{rank}.f64le")
        File.binwrite(path, bytes)
        { 'name' => 'Distances', 'elements' => 320, 'bytes' => bytes.bytesize, 'dtype' => 'f64le',
          'local_path' => path, 'sha256' => Digest::SHA256.hexdigest(bytes), 'fnv1a64' => Capture.fnv(bytes), 'rank' => "rank-#{rank}" }
      end
      stdout = "=== RESULTS ===\nName: Distances\nElements: 320\nHash: #{objects.first.fetch('fnv1a64')}\n=== END RESULTS ===\n"
      observation = { 'id' => Review::ID, 'backend' => 'mpi', 'observation_complete' => false,
        'errors' => [ValidationAudit::FullArrayReconcile::CAPTURE_ERROR], 'objects' => objects,
        'execution' => { 'success' => true }, 'capture_reports' => objects.map { |_o| { 'errors' => [], 'exit_codes' => [0] } },
        'printed_objects' => Capture.output_objects(stdout) }
      yield observation, stdout
    end
  end

  def test_selects_only_the_uniquely_printed_root_gather
    with_observation do |observation, stdout|
      assert_equal observation.fetch('objects').first, Review.selected_object(observation, stdout)
      refute_equal 1, observation.fetch('objects').map { |object| object.fetch('sha256') }.uniq.size
    end
  end

  def test_does_not_choose_an_unprinted_replica_or_ignore_capture_damage
    with_observation do |observation, stdout|
      changed = stdout.sub(observation.fetch('objects').first.fetch('fnv1a64'), observation.fetch('objects')[1].fetch('fnv1a64'))
      observation['printed_objects'] = Capture.output_objects(changed)
      assert_raises(RuntimeError) { Review.selected_object(observation, changed) }
      observation['printed_objects'] = Capture.output_objects(stdout)
      File.binwrite(observation.fetch('objects').last.fetch('local_path'), 'damaged')
      assert_raises(RuntimeError) { Review.selected_object(observation, stdout) }
    end
  end

  def test_unknown_ids_and_real_capture_errors_still_stop
    with_observation do |observation, stdout|
      assert_raises(RuntimeError) { Review.selected_object(observation.merge('id' => 'unknown'), stdout) }
      observation.fetch('capture_reports').first['errors'] = ['cannot read memory']
      assert_raises(RuntimeError) { Review.selected_object(observation, stdout) }
    end
  end
end
