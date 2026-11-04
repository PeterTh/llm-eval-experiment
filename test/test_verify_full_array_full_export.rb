# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/verify_full_array_full_export'

class FullArrayFullVerificationTest < Minitest::Test
  Verify = ValidationAudit::FullArrayFullVerification
  Export = ValidationAudit::FullArrayFullExport
  Capture = ValidationAudit::FullArrayCapture

  def setup
    @root = Dir.mktmpdir('full-array-offline-test-', '/tmp')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def object(values, owner)
    bytes = values.pack('E*')
    directory = File.join(@root, owner, 'rank-single')
    FileUtils.mkdir_p(directory)
    path = File.join(directory, 'array-0000.f64le')
    File.binwrite(path, bytes)
    { 'name' => 'Distances', 'dtype' => 'f64le', 'elements' => values.size, 'bytes' => bytes.bytesize,
      'sha256' => Digest::SHA256.hexdigest(bytes), 'fnv1a64' => Capture.fnv(bytes),
      'file' => 'array-0000.f64le', 'local_path' => path, 'rank' => 'rank-single' }
  end

  def output(object)
    # Sparse fields intentionally remain equal while an unsampled scalar changes.
    "Validation: PASSED\n=== RESULTS ===\nName: Distances\nElements: #{object.fetch('elements')}\n" \
      "Sample[0]: 1\nHash: #{object.fetch('fnv1a64')}\n=== END RESULTS ===\n"
  end

  def fixture(failed: false)
    id = 'roomsim_fixture_omp_r1'
    left = object([1.0, 2.0], 'reference_roomsim')
    right = object([1.0, failed ? 25.5 : 2.00001], id)
    group = { 'benchmark' => 'roomsim', 'backend' => 'omp', 'args' => %w[-v -o -n 2] }
    source = { 'id' => id, 'benchmark' => 'roomsim', 'backend' => 'omp',
      'source_files' => { 'common/hash.hpp' => { 'sha256' => Capture::HASH_SHA } } }
    binding = { 'id' => id, 'source_files' => source.fetch('source_files'), 'binary_sha256' => 'b' * 64 }
    ref_obs = { 'id' => 'reference_roomsim', 'objects' => [left] }
    reference = { 'observation' => ref_obs, 'observation_sha256' => Export.json_digest(ref_obs), 'stdout' => output(left) }
    logs = { 'command' => 'fixture', 'stdout' => output(right), 'stderr' => '', 'exitcode' => '0', 'wall_time' => '1' }
    observation = { 'id' => id, 'benchmark' => 'roomsim', 'backend' => 'omp', 'args' => group.fetch('args'),
      'binary_sha256' => binding.fetch('binary_sha256'), 'binding_sha256' => Export.json_digest(binding),
      'execution' => { 'success' => true, 'exit_code' => 0, 'timed_out' => false, 'output_truncated' => false,
        'argv' => ['fixture', *group.fetch('args')] },
      'capture_reports' => [{ 'rank' => 'rank-single', 'errors' => [], 'exit_codes' => [0],
        'local_directory' => File.dirname(right.fetch('local_path')),
        'captures' => [right.reject { |key, _| %w[rank local_path fnv1a64].include?(key) }] }],
      'objects' => [right], 'captured_fragments' => [], 'printed_objects' => Capture.output_objects(logs.fetch('stdout')),
      'errors' => [], 'observation_complete' => true, 'stdout_sha256' => Digest::SHA256.hexdigest(logs.fetch('stdout')),
      'program_source_changes' => 0, 'executable_file_changes' => 0, 'benchmark_runs' => 0, 'method_sha256' => {} }
    array = Capture.compare_values([1.0, 2.0], [1.0, failed ? 25.5 : 2.00001], epsilon: 5.0).merge(
      'name' => 'Distances', 'reference_array_sha256' => left.fetch('sha256'), 'actual_array_sha256' => right.fetch('sha256'))
    comparison = { 'id' => id, 'source' => source, 'arrays' => [array], 'passed' => !failed,
      'observation_sha256' => Export.json_digest(observation), 'reference_observation_sha256' => reference.fetch('observation_sha256'),
      'sparse_comparison' => validate(reference.fetch('stdout'), logs.fetch('stdout'), 'roomsim'), 'benchmark_runs' => 0 }
    record = { 'id' => id, 'phase' => 'full-array-full', 'comparison' => comparison,
      'comparison_sha256' => Export.json_digest(comparison), 'observation' => observation,
      'binding' => Export.compact_binding(binding, source), 'logs' => logs,
      'log_sha256' => logs.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) } }
    if failed
      record['failure_arrays'] = { 'reference_roomsim' => { 'Distances' => ValidationAudit::FullArrayPilotExport.witness(left, @root) },
        id => { 'Distances' => ValidationAudit::FullArrayPilotExport.witness(right, @root) } }
    end
    [record, reference, group]
  end

  def resign(record)
    record.fetch('comparison')['observation_sha256'] = Export.json_digest(record.fetch('observation'))
    record['comparison_sha256'] = Export.json_digest(record.fetch('comparison'))
  end

  def test_passing_hash_difference_is_not_a_failure
    record, reference, group = fixture
    refute_equal reference.fetch('observation').fetch('objects').first.fetch('fnv1a64'), record.fetch('observation').fetch('objects').first.fetch('fnv1a64')
    assert Verify.verify_record!(record, reference, group, @root, expected_method: {})
    refute record.key?('failure_arrays')
  end

  def test_complete_failure_witness_reproduces_unsampled_error
    record, reference, group = fixture(failed: true)
    assert record.dig('comparison', 'sparse_comparison').first
    assert Verify.verify_record!(record, reference, group, @root)
    assert_equal 1, record.fetch('comparison').fetch('arrays').first.fetch('mismatches')
    path = File.join(@root, record.fetch('failure_arrays').fetch(record.fetch('id')).fetch('Distances'))
    bytes = JSON.parse(File.read(path))
    bytes['values_hex'] = [1.0, 2.0].pack('E*').unpack1('H*')
    File.write(path, JSON.generate(bytes))
    assert_raises(RuntimeError) { Verify.verify_record!(record, reference, group, @root) }
  end

  def test_observer_errors_and_wrong_rank_coverage_are_not_scientific_failures
    record, reference, group = fixture
    record.fetch('observation').fetch('capture_reports').first['errors'] = ['cannot read memory']
    resign(record)
    assert_raises(RuntimeError) { Verify.verify_record!(record, reference, group, @root) }
    record.fetch('observation').fetch('capture_reports').first['errors'] = []
    record.fetch('observation').fetch('capture_reports').first['rank'] = 'rank-0'
    resign(record)
    assert_raises(RuntimeError) { Verify.verify_record!(record, reference, group, @root) }
  end

  def test_method_and_tolerance_tampering_are_rejected_even_with_recomputed_metadata_hashes
    record, reference, group = fixture
    assert_raises(RuntimeError) { Verify.verify_record!(record, reference, group, @root, expected_method: { 'observer' => 'other' }) }
    record.fetch('comparison').fetch('arrays').first['absolute_tolerance'] = 50.0
    resign(record)
    assert_raises(RuntimeError) { Verify.verify_record!(record, reference, group, @root) }
  end

  def test_identity_source_and_capture_bindings_are_checked
    record, reference, group = fixture
    record.fetch('comparison').fetch('source').fetch('source_files')['extra'] = { 'sha256' => 'c' * 64 }
    resign(record)
    assert_raises(RuntimeError) { Verify.verify_record!(record, reference, group, @root) }
  end

  def test_witness_paths_cannot_escape_the_export
    assert_raises(RuntimeError) { Verify.witness(@root, '../elsewhere.json') }
    name = 'failure-arrays/' + 'a' * 64 + '.json'
    FileUtils.mkdir_p(File.dirname(File.join(@root, name)))
    File.symlink('/etc/hosts', File.join(@root, name))
    assert_raises(RuntimeError) { Verify.witness(@root, name) }
  end
end
