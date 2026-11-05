# frozen_string_literal: true

module ValidationAudit
  # Pure, offline-checkable policy for this individually investigated abort.
  # Unknown nonzero exits and debugger failures are deliberately not accepted.
  module FullArrayExecutionReviewPolicy
    ID = 'spmv_gpt-4.1_mpi_r4'
    KIND = 'source-reviewed-program-execution-failure'
    ARGS = %w[-v -r -n 1025 -s 40 -i 67].freeze
    REASON = 'The unchanged program aborts in MPI_Gather with MPI_ERR_TRUNCATE: the last rank sends 257 doubles but the root expects 256 per rank. The same four-rank validation fails without the observer.'
    module_function

    def verify!(review, source, observation, logs)
      diagnostic = review.fetch('unwrapped_diagnostic')
      execution = diagnostic.fetch('execution')
      original = observation.fetch('execution')
      unless source.fetch('id') == ID && source.fetch('benchmark') == 'spmv' && source.fetch('backend') == 'mpi' &&
          source.fetch('source_files').fetch('spmv/spmv.cpp').fetch('sha256') == '443a4f6952c20506e9a7507871f90c3253e38abb4fe80de2ce3eab10a93ee5e0' &&
          source.fetch('source_files').fetch('spmv/spmv.cpp').fetch('git_blob') == '194fb71ae5e97a3915f3b1ff30d880e1a4baba0e' &&
          review.fetch('schema_version') == 1 && review.fetch('kind') == KIND && review.fetch('id') == ID &&
          review.fetch('reason') == REASON && !review.fetch('source_finding').strip.empty? &&
          review.fetch('source') == source.slice('id', 'benchmark', 'backend', 'source_commit', 'source_path', 'source_files') &&
          observation.fetch('id') == ID && observation.fetch('benchmark') == 'spmv' && observation.fetch('backend') == 'mpi' &&
          observation.fetch('args') == ARGS && observation.fetch('objects').empty? && observation.fetch('printed_objects').empty? &&
          !observation.fetch('observation_complete') &&
          observation.fetch('binary_sha256') == '9747152cf6f59684d2482f257ced52e11dac98e1b99fb265f2d462ed4c56721c' &&
          execution.fetch('binary_sha256') == observation.fetch('binary_sha256') &&
          [original, execution].all? { |run| !run.fetch('success') && run.fetch('exit_code') == 15 && !run.fetch('timed_out') && !run.fetch('output_truncated') && run.fetch('argv').last(ARGS.size) == ARGS } &&
          execution.fetch('argv')[0, 3] == ['mpirun', '--np', '4'] && original.fetch('argv')[0, 3] == ['mpirun', '--np', '4'] &&
          execution.fetch('argv').count { |arg| arg.end_with?('/spmv') } == 1 &&
          execution.fetch('argv').none? { |arg| arg.include?('full_array_rank') || arg.include?('gdb') } &&
          [logs, diagnostic.fetch('logs')].all? { |set| set.fetch('exitcode').strip == '15' && set.fetch('stderr').include?('MPI_Gather') && set.fetch('stderr').include?('MPI_ERR_TRUNCATE') && !set.fetch('stdout').include?('Validation: PASSED') && !set.fetch('stdout').include?('=== RESULTS ===') } &&
          diagnostic.fetch('log_sha256') == diagnostic.fetch('logs').transform_values { |bytes| Digest::SHA256.hexdigest(bytes) } &&
          review.fetch('original_log_sha256') == logs.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) } &&
          review.fetch('original_observation_sha256') == Digest::SHA256.hexdigest(JSON.pretty_generate(observation) + "\n") &&
          review.fetch('observed_program_runs') == 1 && review.fetch('diagnostic_program_runs') == 1 &&
          %w[benchmark_runs llm_invocations program_source_changes executable_file_changes].all? { |key| review.fetch(key).zero? && execution.fetch(key, 0).zero? }
        raise 'Execution failure is not the reviewed source-bound MPI truncation'
      end
      true
    end
  end
end
