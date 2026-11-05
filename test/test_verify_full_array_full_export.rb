# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/export_full_array_full'
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

  def test_hash_adapter_preserves_the_recorded_runtime_configuration_name
    record, = fixture
    record['id'] = 'black-scholes_qwen-3.6-27B-udq4_hybrid_r2'
    source = record.fetch('comparison').fetch('source')
    source['source_commit'] = 'd' * 40
    helper = { 'sha256' => '59016cf476cc217af79d9271396b24fd4167cf045f0231107590b0155849fe8e',
      'git_blob' => 'ad6b15ea7a7e60c44e77d0600c46475c9c4941dd' }
    source.fetch('source_files')['common/hash.hpp'] = helper
    method_path = 'observer-adapters/fixture.rb'
    FileUtils.mkdir_p(File.join(@root, 'observer-adapters'))
    File.write(File.join(@root, method_path), '# fixture method')
    adapter = { 'schema_version' => 1, 'id' => record.fetch('id'), 'kind' => 'redundant-mpi-header-hash-helper',
      'adapter_method' => method_path, 'adapter_method_sha256' => ValidationAudit.sha(File.join(@root, method_path)),
      'base_helper_sha256' => Capture::HASH_SHA, 'base_helper_git_blob' => '42ad06602e366caf62be9789dcae2d52fd0c2845',
      'accepted_helper_sha256' => helper.fetch('sha256'), 'accepted_helper_git_blob' => helper.fetch('git_blob'),
      'source_commit' => source.fetch('source_commit'), 'source_files' => source.fetch('source_files'),
      'effective_configuration' => { 'FullArrayCapture::HASH_SHA' => helper.fetch('sha256') },
      'observation_sha256' => record.fetch('comparison').fetch('observation_sha256'),
      'observation_complete' => true, 'program_executions' => 1 }
    %w[frozen_method_files_changed program_source_changes executable_file_changes benchmark_runs llm_invocations].each { |key| adapter[key] = 0 }
    record['observation_adapter'] = adapter
    record['observation_adapter_sha256'] = Export.json_digest(adapter)
    assert_nil Verify.verify_helper!(record, @root)
    adapter['effective_configuration'] = { 'FullArrayOffline::HASH_SHA' => helper.fetch('sha256') }
    record['observation_adapter_sha256'] = Export.json_digest(adapter)
    assert_raises(RuntimeError) { Verify.verify_helper!(record, @root) }
  end

  def root_review_fixture
    record, reference, group = fixture
    group['backend'] = 'mpi'
    source = record.fetch('comparison').fetch('source')
    source.merge!('backend' => 'mpi', 'source_commit' => 'c' * 40, 'source_path' => 'fixture/source')
    source.fetch('source_files')['roomsim/roomsim.cpp'] = { 'sha256' => 'd' * 64, 'git_blob' => 'e' * 40 }
    observation = record.fetch('observation')
    objects = [observation.fetch('objects').first, *(1..3).map { |i| object([0.0, i.to_f], "partial-#{i}") }]
    objects.each_with_index { |obj, i| obj['rank'] = "rank-#{i}" }
    observation.merge!('backend' => 'mpi', 'objects' => objects, 'observation_complete' => false,
      'errors' => ['Captured arrays do not match all printed result objects'])
    observation['capture_reports'] = objects.map do |obj|
      { 'rank' => obj.fetch('rank'), 'errors' => [], 'exit_codes' => [0],
        'local_directory' => File.dirname(obj.fetch('local_path')),
        'captures' => [obj.reject { |key, _| %w[rank local_path fnv1a64].include?(key) }] }
    end
    observation['binding_sha256'] = Export.json_digest(Export.expand_binding(record.fetch('binding'), source))
    profile = source.slice('id', 'benchmark', 'backend', 'source_commit', 'source_path').merge(
      'schema_version' => 1, 'source_file_path' => 'roomsim/roomsim.cpp',
      'source_file' => source.fetch('source_files').fetch('roomsim/roomsim.cpp'),
      'source_finding' => 'Fixture gathers to root and suppresses non-root stdout.',
      'printed_rank' => 'rank-0', 'captured_ranks' => %w[rank-0 rank-1 rank-2 rank-3],
      'array_name' => 'Distances', 'elements' => 2)
    path = 'observer-extensions/root-review.rb'
    FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
    File.write(File.join(@root, path), '# source-bound review fixture')
    review = { 'schema_version' => 1, 'kind' => ValidationAudit::FullArrayOffline::ROOT_OUTPUT_KIND,
      'id' => record.fetch('id'), 'profile' => profile, 'profile_sha256' => Export.json_digest(profile),
      'original_observation_sha256' => Export.json_digest(observation), 'stdout_sha256' => observation.fetch('stdout_sha256'),
      'selected_objects' => [objects.first], 'captured_objects' => 4,
      'extension_method' => path, 'extension_method_sha256' => ValidationAudit.sha(File.join(@root, path)) }
    %w[program_runs benchmark_runs llm_invocations program_source_changes].each { |key| review[key] = 0 }
    record['root_output_review'] = review
    record['root_output_review_sha256'] = Export.json_digest(review)
    record['capture_reconciliation'] = review.slice('kind', 'selected_objects', 'captured_objects', 'extension_method_sha256')
      .merge('root_output_review_sha256' => record.fetch('root_output_review_sha256'))
    record.fetch('comparison')['observation_reconciliation_sha256'] = Export.json_digest(record.fetch('capture_reconciliation'))
    record['reviewed_replica_arrays'] = objects.to_h { |obj| [obj.fetch('sha256'), ValidationAudit::FullArrayPilotExport.witness(obj, @root)] }
    record['review_reference_arrays'] = reference.fetch('observation').fetch('objects').to_h do |obj|
      [obj.fetch('name'), ValidationAudit::FullArrayPilotExport.witness(obj, @root)]
    end
    resign(record)
    [record, reference, group]
  end

  def test_source_bound_root_review_replays_all_captures_and_only_compares_printed_root
    record, reference, group = root_review_fixture
    assert Verify.verify_record!(record, reference, group, @root)
    record.fetch('root_output_review').fetch('profile')['elements'] = 3
    assert_raises(RuntimeError) { Verify.verify_root_review!(record, reference, @root) }
  end

  def test_unprinted_capture_is_retained_and_checked
    record, reference, group = root_review_fixture
    partial = record.fetch('observation').fetch('objects').last
    path = File.join(@root, record.fetch('reviewed_replica_arrays').fetch(partial.fetch('sha256')))
    data = JSON.parse(File.read(path))
    data['values_hex'] = [1.0, 2.0].pack('E*').unpack1('H*')
    File.write(path, JSON.generate(data))
    assert_raises(RuntimeError) { Verify.verify_record!(record, reference, group, @root) }
  end
end
