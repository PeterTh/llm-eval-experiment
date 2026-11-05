# frozen_string_literal: true
require_relative 'full_array_execution_failure'
require_relative 'full_array_recovered_output_policy'

module ValidationAudit
  module FullArrayRecoveredOutputs
    POLICY = FullArrayRecoveredOutputPolicy
    module_function

    def comparison(campaign, directory, row)
      review_path = File.join(directory, 'recovered-output-review.json')
      review = ValidationAudit.read(review_path)
      observation_path = File.join(directory, 'observation.json')
      observation = ValidationAudit.read(observation_path)
      logs = FullArrayExecutionFailure.logs(directory)
      POLICY.verify!(review, row, observation, logs)
      %w[extension policy].zip(%w[full_array_recovered_outputs.rb full_array_recovered_output_policy.rb]).each do |prefix, name|
        raise 'Recovery method changed' unless review.fetch(prefix + '_method_sha256') == ValidationAudit.sha(File.join(__dir__, name))
      end
      binding_path = File.join(File.dirname(File.dirname(directory)), 'bindings', row.fetch('id') + '.json')
      binding = ValidationAudit.read(binding_path)
      raise 'Recovered source/binary binding differs' unless binding.fetch('source_files') == row.fetch('source_files') &&
        binding.fetch('binary_sha256') == observation.fetch('binary_sha256') && ValidationAudit.sha(binding_path) == observation.fetch('binding_sha256')
      observation.fetch('objects').each do |object|
        raise 'Recovered capture changed' unless ValidationAudit.sha(object.fetch('local_path')) == object.fetch('sha256')
      end
      reference, stdout, path = campaign.reference_for(row.fetch('benchmark'))
      normalized = observation.merge('objects' => review.fetch('selected_objects'), 'errors' => [], 'observation_complete' => true)
      result = FullArrayCapture.compare(reference, normalized)
      sparse = validate(stdout, logs.fetch('stdout'), row.fetch('benchmark'))
      result.merge('passed' => result.fetch('passed') && sparse.first, 'source' => row,
        'observation_sha256' => ValidationAudit.sha(observation_path), 'reference_observation_sha256' => ValidationAudit.sha(path),
        'sparse_comparison' => sparse, 'total_check_seconds' => observation.fetch('execution').fetch('wall_seconds'),
        'total_check_seconds_basis' => 'Rounded execution wall time only; original observation-processing duration was not saved.',
        'recovered_output_review_sha256' => ValidationAudit.sha(review_path))
    end

    def record(workspace:, evidence:)
      campaign = FullArrayFull.new(workspace: workspace, evidence: evidence)
      root = File.join(evidence, FullArrayFull::PHASE)
      plan_path = File.join(root, 'plan.json')
      plan = ValidationAudit.read(plan_path)
      raise 'Frozen runtime changed' unless campaign.method_files == plan.fetch('method_sha256')
      row = ValidationAudit.read(File.join(evidence, 'inventory-unstructured.json')).fetch('rows').find { |entry| entry.fetch('id') == POLICY::ID }
      directory = File.join(root, POLICY::ID)
      observation_path = File.join(directory, 'observation.json')
      raise 'Refusing to replace an observation' if File.exist?(observation_path)
      binding_path = File.join(evidence, 'bindings', POLICY::ID + '.json')
      binding = ValidationAudit.read(binding_path)
      raise 'Executable changed' unless ValidationAudit.sha(binding.fetch('executable')) == POLICY::BINARY_SHA
      local = File.join(workspace, FullArrayFull::PHASE, POLICY::ID)
      reports = Dir[File.join(local, 'rank-*', 'capture.json')].sort.map do |path|
        ValidationAudit.read(path).merge('rank' => File.basename(File.dirname(path)), 'local_directory' => File.dirname(path))
      end
      raise 'Incomplete raw captures' unless reports.map { |report| report.fetch('rank') } == %w[rank-0 rank-1 rank-2 rank-3] &&
        reports.all? { |report| report.fetch('errors').empty? && report.fetch('exit_codes') == [0] && report.fetch('captures').size == 1 }
      objects = reports.flat_map do |report|
        report.fetch('captures').map do |object|
          raise 'Unsafe raw capture' unless object.fetch('file') == 'array-0000.f64le'
          path = File.join(report.fetch('local_directory'), object.fetch('file'))
          bytes = File.binread(path)
          raise 'Raw capture changed' unless Digest::SHA256.hexdigest(bytes) == object.fetch('sha256') && bytes.bytesize == object.fetch('bytes')
          object.merge('local_path' => path, 'rank' => report.fetch('rank'), 'fnv1a64' => FullArrayCapture.fnv(bytes))
        end
      end
      logs = FullArrayExecutionFailure.logs(directory)
      observation = { 'id' => POLICY::ID, 'benchmark' => 'unstructured', 'backend' => 'hybrid', 'args' => POLICY::ARGS,
        'binding_sha256' => ValidationAudit.sha(binding_path), 'binary_sha256' => binding.fetch('binary_sha256'),
        'method_sha256' => FullArrayCapture.retain_method(evidence), 'execution' => POLICY.execution(logs),
        'capture_reports' => reports, 'objects' => objects, 'captured_fragments' => [],
        'observer_configuration' => ValidationAudit.read(File.join(local, 'observer-config.json')),
        'printed_objects' => POLICY.primary(logs.fetch('stdout')), 'printed_objects_scope' => 'Unchanged validator first result block only; later interleaved duplicates retained in stdout.',
        'errors' => ['Post-execution all-block parser raised: Malformed result object'], 'observation_complete' => false,
        'total_seconds' => nil, 'stdout_sha256' => Digest::SHA256.hexdigest(logs.fetch('stdout')),
        'checked_at' => Time.now.utc.iso8601, 'metadata_origin' => POLICY::KIND,
        'metadata_recovery' => 'Post-execution reconstruction from original command/exit/wall/stdout/stderr logs and four clean rank reports. Exit zero proves no timeout/signal; logs below recorded output cap prove no truncation. Wall time has saved six-decimal precision. Original total observation duration is unknown, not reconstructed.',
        'program_source_changes' => 0, 'executable_file_changes' => 0, 'benchmark_runs' => 0 }
      review = { 'schema_version' => 1, 'id' => POLICY::ID, 'kind' => POLICY::KIND,
        'source' => row.slice('id', 'benchmark', 'backend', 'source_commit', 'source_path', 'source_files'),
        'source_finding' => 'unstructured.cpp:166 MPI_Allgatherv replicates all final energies; 168-169 copies them to the world; 319-326 prints the complete vector on every rank. The first block is intact. Later duplicate blocks interleave, which exceeds the observer parser contract but is not a failure under the unchanged first-block validator. All four saved arrays are byte-identical; selection is independent of reference values.',
        'selected_objects' => [objects.first], 'captured_objects' => objects.size,
        'observation_sha256' => FullArrayOffline.json_digest(observation),
        'log_sha256' => logs.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) },
        'raw_capture_sha256' => Dir[File.join(local, 'rank-*', 'capture.json')].sort.to_h { |path| [File.basename(File.dirname(path)), ValidationAudit.sha(path)] },
        'raw_capture_reports' => Dir[File.join(local, 'rank-*', 'capture.json')].sort.to_h { |path| [File.basename(File.dirname(path)), File.read(path)] },
        'plan_sha256' => ValidationAudit.sha(plan_path), 'program_runs' => 0, 'benchmark_runs' => 0, 'llm_invocations' => 0,
        'program_source_changes' => 0, 'executable_file_changes' => 0, 'reviewed_at' => Time.now.utc.iso8601 }
      POLICY.verify!(review, row, observation, logs)
      %w[full_array_recovered_outputs.rb full_array_recovered_output_policy.rb].zip(%w[extension policy]).each do |name, prefix|
        digest = ValidationAudit.sha(File.join(__dir__, name))
        relative = File.join('observer-extensions', digest, name)
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(File.binread(File.join(__dir__, name))) }
        review[prefix + '_method'] = relative
        review[prefix + '_method_sha256'] = digest
      end
      ValidationAudit.save(observation_path, observation)
      ValidationAudit.save(File.join(directory, 'recovered-output-review.json'), review)
      result = comparison(campaign, directory, row)
      ValidationAudit.save(File.join(directory, 'comparison.json'), result)
      puts JSON.pretty_generate(result.reject { |key, _| key == 'source' })
    end

    module Extension
      def verify_saved(directory, row)
        return super unless File.file?(File.join(directory, 'recovered-output-review.json'))
        saved = ValidationAudit.read(File.join(directory, 'comparison.json'))
        raise 'Recovered comparison changed' unless saved == FullArrayRecoveredOutputs.comparison(self, directory, row)
        saved
      end
    end
  end
  FullArrayFull.prepend(FullArrayRecoveredOutputs::Extension)
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: full_array_recovered_outputs.rb WORKSPACE EVIDENCE run|review' unless ARGV.size == 3
  case ARGV[2]
  when 'review' then ValidationAudit::FullArrayRecoveredOutputs.record(workspace: ARGV[0], evidence: ARGV[1])
  when 'run' then ValidationAudit::FullArrayFull.new(workspace: ARGV[0], evidence: ARGV[1]).run
  else raise 'Unknown recovery action'
  end
end
