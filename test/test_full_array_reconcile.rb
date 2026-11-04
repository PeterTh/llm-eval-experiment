# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/full_array_reconcile'

class FullArrayReconcileTest < Minitest::Test
  def fixture
    Dir.mktmpdir('full-array-reconcile-') do |directory|
      bytes = [1.0, 2.0].pack('E*')
      path = File.join(directory, 'values')
      File.binwrite(path, bytes)
      object = { 'name' => 'Values', 'elements' => 2, 'dtype' => 'f64le', 'bytes' => bytes.bytesize,
        'sha256' => Digest::SHA256.hexdigest(bytes), 'fnv1a64' => ValidationAudit::FullArrayCapture.fnv(bytes), 'local_path' => path }
      output = "=== RESULTS ===\nName: Values\nElements: 2\nHash: #{object.fetch('fnv1a64')}\n=== END RESULTS ===\n"
      observation = { 'errors' => [ValidationAudit::FullArrayReconcile::CAPTURE_ERROR], 'observation_complete' => false,
        'printed_objects' => ValidationAudit::FullArrayCapture.output_objects(output),
        'objects' => [object.merge('rank' => 'rank-0'), object.merge('rank' => 'rank-1')] }
      yield observation, output
    end
  end

  def test_byte_identical_suppressed_replicas_are_unambiguous
    fixture do |observation, output|
      selected = ValidationAudit::FullArrayReconcile.select_identical_replicas(observation, output)
      assert_equal 1, selected.size
      assert_equal 'rank-0', selected.first.fetch('rank')
      assert_equal 2, observation.fetch('objects').size
      refute observation.fetch('observation_complete')
    end
  end

  def test_other_capture_errors_are_not_waived
    fixture do |observation, output|
      observation['errors'] << 'Abnormal inferior exit'
      assert_raises(RuntimeError) { ValidationAudit::FullArrayReconcile.select_identical_replicas(observation, output) }
    end
  end

  def test_identical_printed_replicas_preserve_the_output_contract
    fixture do |observation, output|
      output *= 2
      observation['printed_objects'] = ValidationAudit::FullArrayCapture.output_objects(output)
      observation['errors'] = []
      observation['observation_complete'] = true
      selected = ValidationAudit::FullArrayReconcile.select_identical_replicas(observation, output)
      assert_equal 1, selected.size
      assert_equal 2, observation.fetch('printed_objects').size
      observation['objects'].pop
      assert_raises(RuntimeError) { ValidationAudit::FullArrayReconcile.select_identical_replicas(observation, output) }
    end
  end

  def test_same_hash_with_different_data_type_is_not_accepted
    fixture do |observation, output|
      observation.fetch('objects').last['dtype'] = 'i32le'
      assert_raises(RuntimeError) { ValidationAudit::FullArrayReconcile.select_identical_replicas(observation, output) }
    end
  end

  def test_changed_bytes_or_unmatched_name_are_not_accepted
    fixture do |observation, output|
      observation.fetch('objects').last['sha256'] = 'changed'
      assert_raises(RuntimeError) { ValidationAudit::FullArrayReconcile.select_identical_replicas(observation, output) }
    end
    fixture do |observation, output|
      observation.fetch('objects').last['name'] = 'Other'
      assert_raises(RuntimeError) { ValidationAudit::FullArrayReconcile.select_identical_replicas(observation, output) }
    end
  end
end
