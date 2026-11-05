# frozen_string_literal: true
require 'minitest/autorun'
require 'json'
require 'digest'
require_relative '../tools/validation_audit/full_array_execution_review_policy'

class FullArrayExecutionReviewTest < Minitest::Test
  Policy = ValidationAudit::FullArrayExecutionReviewPolicy

  def fixture
    source = { 'id' => Policy::ID, 'benchmark' => 'spmv', 'backend' => 'mpi', 'source_commit' => 'a' * 40,
      'source_path' => 'fixture/source', 'source_files' => { 'spmv/spmv.cpp' => {
        'sha256' => '443a4f6952c20506e9a7507871f90c3253e38abb4fe80de2ce3eab10a93ee5e0',
        'git_blob' => '194fb71ae5e97a3915f3b1ff30d880e1a4baba0e' } } }
    binary = '9747152cf6f59684d2482f257ced52e11dac98e1b99fb265f2d462ed4c56721c'
    execution = { 'success' => false, 'exit_code' => 15, 'timed_out' => false, 'output_truncated' => false,
      'binary_sha256' => binary, 'argv' => ['mpirun', '--np', '4', '/tmp/fixture/spmv', *Policy::ARGS] }
    observation = { 'id' => Policy::ID, 'benchmark' => 'spmv', 'backend' => 'mpi', 'args' => Policy::ARGS,
      'objects' => [], 'printed_objects' => [], 'observation_complete' => false, 'binary_sha256' => binary,
      'execution' => Marshal.load(Marshal.dump(execution)) }
    logs = { 'command' => 'fixture', 'stdout' => 'Computing SpMV', 'stderr' => 'MPI_Gather MPI_ERR_TRUNCATE', 'exitcode' => "15\n", 'wall_time' => '1.0' }
    digests = logs.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
    review = { 'schema_version' => 1, 'kind' => Policy::KIND, 'id' => Policy::ID, 'source' => source,
      'reason' => Policy::REASON, 'source_finding' => 'Inspected source has uneven counts in MPI_Gather.',
      'unwrapped_diagnostic' => { 'execution' => execution, 'logs' => logs, 'log_sha256' => digests },
      'original_log_sha256' => digests, 'original_observation_sha256' => Digest::SHA256.hexdigest(JSON.pretty_generate(observation) + "\n"),
      'observed_program_runs' => 1, 'diagnostic_program_runs' => 1, 'benchmark_runs' => 0, 'llm_invocations' => 0,
      'program_source_changes' => 0, 'executable_file_changes' => 0 }
    [review, source, observation, logs]
  end

  def test_accepts_only_the_individually_bound_source_and_reproduced_failure
    args = fixture
    assert Policy.verify!(*args)
    args[1]['id'] = 'spmv_other_mpi_r1'
    assert_raises(RuntimeError) { Policy.verify!(*args) }
  end

  def test_observer_failure_alone_is_not_a_program_failure
    [
      { 'success' => true, 'exit_code' => 0 }, { 'timed_out' => true },
      { 'argv' => ['mpirun', '--np', '4', '/tools/full_array_rank.rb', '/tmp/fixture/spmv', *Policy::ARGS] },
      { 'argv' => ['mpirun', '--np', '128', '/tmp/fixture/spmv', *Policy::ARGS] },
      { 'binary_sha256' => 'f' * 64 }, { 'program_source_changes' => 1 }
    ].each do |change|
      args = fixture
      args[0].fetch('unwrapped_diagnostic').fetch('execution').merge!(change)
      assert_raises(RuntimeError) { Policy.verify!(*args) }
    end
  end

  def test_log_and_original_observation_changes_are_rejected
    args = fixture
    args[3]['stderr'] = 'Unrelated infrastructure error'
    assert_raises(RuntimeError) { Policy.verify!(*args) }
    args = fixture
    args[2]['objects'] = [{ 'name' => 'invented' }]
    assert_raises(RuntimeError) { Policy.verify!(*args) }
  end
end
