# frozen_string_literal: true
require_relative 'full_array_reviewed_outputs'

module ValidationAudit
  # A source-reviewed root gather with non-root stdout redirected to /dev/null.
  # Select the actual printed result, never an unprinted passing replica.
  module FullArraySuppressedOutputs
    ID = 'roomsim_claude-opus-5.5-cc-medium_mpi_r3'
    KIND = 'root-gather-with-suppressed-partial-captures'
    SOURCE_BLOB = '36bc5cd8aade4c247478542768cccb5926e950af'
    SOURCE_SHA = '95921633bbb73aba7e173bdad6c0a833f1c5407f925618e82b2051d73beb852a'
    module_function

    def selected_object(observation, stdout)
      unless observation.fetch('id') == ID && observation.fetch('backend') == 'mpi' &&
          observation.fetch('errors') == [FullArrayReconcile::CAPTURE_ERROR] && !observation.fetch('observation_complete') &&
          observation.fetch('execution').fetch('success') && observation.fetch('capture_reports').all? { |report| report.fetch('errors').empty? && report.fetch('exit_codes') == [0] }
        raise 'Not the reviewed suppressed-rank observation'
      end
      objects = observation.fetch('objects')
      printed = FullArrayCapture.output_objects(stdout)
      unless objects.map { |object| object.fetch('rank') }.sort == %w[rank-0 rank-1 rank-2 rank-3] &&
          printed == observation.fetch('printed_objects') && printed.size == 1 &&
          objects.all? { |object| object.fetch('name') == 'Distances' && object.fetch('elements') == 320 }
        raise 'Suppressed-rank capture/output coverage differs'
      end
      objects.each do |object|
        bytes = File.binread(object.fetch('local_path'))
        unless bytes.bytesize == object.fetch('bytes') && Digest::SHA256.hexdigest(bytes) == object.fetch('sha256') &&
            FullArrayCapture.fnv(bytes) == object.fetch('fnv1a64')
          raise 'Suppressed-rank capture bytes changed'
        end
      end
      matches = objects.select { |object| object.slice('name', 'elements', 'fnv1a64') == printed.first }
      raise 'Printed output does not uniquely identify rank zero' unless matches.size == 1 && matches.first.fetch('rank') == 'rank-0'
      matches.first
    end

    def load_review(evidence, observation, stdout)
      path = File.join(evidence, FullArrayFull::PHASE, observation.fetch('id'), 'suppressed-output-review.json')
      return nil unless File.file?(path)
      review = ValidationAudit.read(path)
      unless review.fetch('kind') == KIND && review.fetch('id') == ID &&
          review.fetch('source_file').fetch('git_blob') == SOURCE_BLOB && review.fetch('source_file').fetch('sha256') == SOURCE_SHA &&
          review.fetch('original_observation_sha256') == Digest::SHA256.hexdigest(JSON.pretty_generate(observation) + "\n") &&
          review.fetch('stdout_sha256') == Digest::SHA256.hexdigest(stdout) &&
          review.fetch('extension_method_sha256') == ValidationAudit.sha(__FILE__) &&
          %w[program_runs benchmark_runs llm_invocations program_source_changes].all? { |key| review.fetch(key).zero? }
        raise 'Suppressed-output review binding differs'
      end
      raise 'Suppressed-output selection changed' unless review.fetch('selected_objects') == [selected_object(observation, stdout)]
      [review, path]
    end

    def record_review(workspace:, evidence:)
      campaign = FullArrayFull.new(workspace: workspace, evidence: evidence)
      root = File.join(evidence, FullArrayFull::PHASE)
      plan = ValidationAudit.read(File.join(root, 'plan.json'))
      raise 'Frozen runtime changed' unless campaign.method_files == plan.fetch('method_sha256')
      group = plan.fetch('groups').find { |entry| entry.fetch('full_ids').include?(ID) }
      raise 'Observation not in approved plan' unless group
      row = ValidationAudit.read(File.join(evidence, 'inventory-roomsim.json')).fetch('rows').find { |entry| entry.fetch('id') == ID }
      source = row.fetch('source_files').fetch('roomsim/roomsim.cpp')
      unless source.fetch('git_blob') == SOURCE_BLOB && source.fetch('sha256') == SOURCE_SHA
        raise 'Not the inspected root-gather implementation'
      end
      directory = File.join(root, ID)
      raise 'Refusing to replace a completed comparison' if File.exist?(File.join(directory, 'comparison.json'))
      observation_path = File.join(directory, 'observation.json')
      observation = ValidationAudit.read(observation_path)
      stdout = File.read(File.join(directory, 'validation_stdout.log'))
      selected = selected_object(observation, stdout)
      method_digest = ValidationAudit.sha(__FILE__)
      relative = File.join('observer-extensions', method_digest, File.basename(__FILE__))
      method_path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(method_path))
      File.open(method_path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(File.binread(__FILE__)) }
      review = { 'schema_version' => 1, 'kind' => KIND, 'id' => ID,
        'basis' => 'Only the root gathered result is printed. Non-root partial arrays enter print_results but stdout has been redirected to /dev/null. Rank-zero selection follows the source output contract and the unique printed FNV, independently of the numerical verdict.',
        'source_finding' => 'MPI_Gatherv gathers distance slices to rank zero (1072-1083); main redirects non-root stdout to /dev/null (1212-1218); all ranks call print_results (1344-1348), but only root runs internal validation (1351-1358).',
        'source_commit' => row.fetch('source_commit'), 'source_path' => row.fetch('source_path'), 'source_file' => source,
        'original_observation_sha256' => ValidationAudit.sha(observation_path), 'stdout_sha256' => Digest::SHA256.hexdigest(stdout),
        'selected_objects' => [selected], 'captured_objects' => observation.fetch('objects').size,
        'suppressed_ranks' => %w[rank-1 rank-2 rank-3],
        'extension_method' => relative, 'extension_method_sha256' => method_digest,
        'plan_sha256' => ValidationAudit.sha(File.join(root, 'plan.json')), 'reviewed_at' => Time.now.utc.iso8601,
        'program_runs' => 0, 'benchmark_runs' => 0, 'llm_invocations' => 0, 'program_source_changes' => 0 }
      ValidationAudit.save(File.join(directory, 'suppressed-output-review.json'), review)
      comparison = campaign.check(row, group)
      puts JSON.pretty_generate(comparison.reject { |key, _| key == 'source' })
    end

    module Extension
      def normalized_observation(observation, stdout)
        reviewed = @evidence && FullArraySuppressedOutputs.load_review(@evidence, observation, stdout)
        return super unless reviewed
        review, path = reviewed
        selected = review.fetch('selected_objects')
        reconciliation = { 'kind' => FullArraySuppressedOutputs::KIND, 'reason' => review.fetch('basis'),
          'selected_objects' => selected, 'captured_objects' => observation.fetch('objects').size,
          'suppressed_output_review_sha256' => ValidationAudit.sha(path),
          'extension_method_sha256' => review.fetch('extension_method_sha256') }
        [observation.merge('objects' => selected, 'errors' => [], 'observation_complete' => true), reconciliation]
      end
    end
  end
  FullArrayFull.prepend(FullArraySuppressedOutputs::Extension)
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: full_array_suppressed_outputs.rb WORKSPACE EVIDENCE review|run' unless ARGV.size == 3
  case ARGV[2]
  when 'review' then ValidationAudit::FullArraySuppressedOutputs.record_review(workspace: ARGV[0], evidence: ARGV[1])
  when 'run' then ValidationAudit::FullArrayFull.new(workspace: ARGV[0], evidence: ARGV[1]).run
  else raise 'Unknown suppressed-output action'
  end
end
