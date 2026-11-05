# frozen_string_literal: true
require_relative 'full_array_root_output_reviews'
require_relative 'full_array_execution_review_policy'

module ValidationAudit
  module FullArrayExecutionFailure
    POLICY = FullArrayExecutionReviewPolicy
    module_function

    def logs(directory, prefix = 'validation')
      %w[command stdout stderr exitcode wall_time].to_h { |part| [part, File.read(File.join(directory, prefix + '_' + part + '.log'))] }
    end

    def comparison(campaign, directory, row)
      review_path = File.join(directory, 'execution-failure-review.json')
      review = ValidationAudit.read(review_path)
      observation_path = File.join(directory, 'observation.json')
      observation = ValidationAudit.read(observation_path)
      binding_path = File.join(File.dirname(File.dirname(directory)), 'bindings', row.fetch('id') + '.json')
      binding = ValidationAudit.read(binding_path)
      raise 'Reviewed executable/source binding changed' unless binding.fetch('source_files') == row.fetch('source_files') &&
        binding.fetch('binary_sha256') == observation.fetch('binary_sha256') && ValidationAudit.sha(binding_path) == observation.fetch('binding_sha256')
      POLICY.verify!(review, row, observation, logs(directory))
      raise 'Execution review method changed' unless review.fetch('extension_method_sha256') == ValidationAudit.sha(__FILE__) &&
        review.fetch('policy_method_sha256') == ValidationAudit.sha(File.join(__dir__, 'full_array_execution_review_policy.rb'))
      reference, _, path = campaign.reference_for(row.fetch('benchmark'))
      raise 'Incomplete reference' unless reference.fetch('observation_complete')
      { 'id' => row.fetch('id'), 'arrays' => [], 'passed' => false,
        'failure_kind' => POLICY::KIND, 'policy' => 'Confirmed unchanged-program failure in the supplemental correctness execution; no complete array was produced.',
        'benchmark_runs' => 0, 'source' => row, 'observation_sha256' => ValidationAudit.sha(observation_path),
        'reference_observation_sha256' => ValidationAudit.sha(path), 'sparse_comparison' => [false, POLICY::REASON],
        'total_check_seconds' => observation.fetch('total_seconds') + review.fetch('unwrapped_diagnostic').fetch('execution').fetch('wall_seconds'),
        'execution_failure_review_sha256' => ValidationAudit.sha(review_path) }
    end

    def record(workspace:, evidence:)
      campaign = FullArrayFull.new(workspace: workspace, evidence: evidence)
      root = File.join(evidence, FullArrayFull::PHASE)
      plan_path = File.join(root, 'plan.json')
      plan = ValidationAudit.read(plan_path)
      raise 'Frozen runtime changed' unless campaign.method_files == plan.fetch('method_sha256')
      group = plan.fetch('groups').find { |entry| entry.fetch('full_ids').include?(POLICY::ID) }
      raise 'Not the approved four-rank workload' unless group && group.fetch('args') == POLICY::ARGS && group.fetch('backend') == 'mpi'
      row = ValidationAudit.read(File.join(evidence, 'inventory-spmv.json')).fetch('rows').find { |entry| entry.fetch('id') == POLICY::ID }
      directory = File.join(root, POLICY::ID)
      raise 'Comparison already exists' if File.exist?(File.join(directory, 'comparison.json'))
      observation_path = File.join(directory, 'observation.json')
      observation = ValidationAudit.read(observation_path)
      diagnostic_root = File.join(evidence, 'full-array-runtime-reviews', POLICY::ID)
      diagnostic_logs = logs(diagnostic_root, 'unwrapped')
      review = { 'schema_version' => 1, 'kind' => POLICY::KIND, 'id' => POLICY::ID,
        'reason' => POLICY::REASON,
        'source_finding' => 'spmv.cpp partitions 1025 rows as 256,256,256,257 (lines 232-236), then MPI_Gather uses rank-local local_rows as both sendcount and recvcount (lines 264-265). The sender/root type signatures differ for the final rank. The earlier 128-rank shape check completed, but does not make this mismatched collective valid.',
        'source' => row.slice('id', 'benchmark', 'backend', 'source_commit', 'source_path', 'source_files'),
        'original_observation_sha256' => ValidationAudit.sha(observation_path),
        'original_log_sha256' => logs(directory).transform_values { |bytes| Digest::SHA256.hexdigest(bytes) },
        'unwrapped_diagnostic' => { 'execution' => ValidationAudit.read(File.join(diagnostic_root, 'execution.json')),
          'logs' => diagnostic_logs, 'log_sha256' => diagnostic_logs.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) } },
        'earlier_shape_result' => ValidationAudit.read(File.join(evidence, 'spmv-shape-mpi128-v1', POLICY::ID, 'result.json')),
        'observed_program_runs' => 1, 'diagnostic_program_runs' => 1, 'benchmark_runs' => 0, 'llm_invocations' => 0,
        'program_source_changes' => 0, 'executable_file_changes' => 0, 'plan_sha256' => ValidationAudit.sha(plan_path),
        'reviewed_at' => Time.now.utc.iso8601 }
      POLICY.verify!(review, row, observation, logs(directory))
      %w[full_array_execution_failure.rb full_array_execution_review_policy.rb].zip(%w[extension policy]).each do |name, prefix|
        source = File.join(__dir__, name)
        digest = ValidationAudit.sha(source)
        relative = File.join('observer-extensions', digest, name)
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(File.binread(source)) }
        review[prefix + '_method'] = relative
        review[prefix + '_method_sha256'] = digest
      end
      ValidationAudit.save(File.join(directory, 'execution-failure-review.json'), review)
      result = comparison(campaign, directory, row)
      ValidationAudit.save(File.join(directory, 'comparison.json'), result)
      ValidationAudit.save(File.join(root, 'failure-events', POLICY::ID + '.json'),
        { 'id' => POLICY::ID, 'checked_at' => Time.now.utc.iso8601, 'comparison' => [], 'failure_kind' => POLICY::KIND,
          'comparison_sha256' => ValidationAudit.sha(File.join(directory, 'comparison.json')), 'benchmark_runs' => 0 })
      puts JSON.pretty_generate(result.reject { |key, _| key == 'source' })
    end

    module Extension
      def verify_saved(directory, row)
        return super unless File.file?(File.join(directory, 'execution-failure-review.json'))
        saved = ValidationAudit.read(File.join(directory, 'comparison.json'))
        expected = FullArrayExecutionFailure.comparison(self, directory, row)
        raise 'Reviewed execution failure changed' unless saved == expected
        saved
      end
    end
  end
  FullArrayFull.prepend(FullArrayExecutionFailure::Extension)
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: full_array_execution_failure.rb WORKSPACE EVIDENCE run|review' unless ARGV.size == 3
  case ARGV[2]
  when 'review' then ValidationAudit::FullArrayExecutionFailure.record(workspace: ARGV[0], evidence: ARGV[1])
  when 'run' then ValidationAudit::FullArrayFull.new(workspace: ARGV[0], evidence: ARGV[1]).run
  else raise 'Unknown execution-failure action'
  end
end
