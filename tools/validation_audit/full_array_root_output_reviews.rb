# frozen_string_literal: true
require_relative 'full_array_suppressed_outputs'

module ValidationAudit
  # Explicit, source-bound profiles for root gathers whose non-root printers
  # write to a suppressed stream. New profiles require individual source review;
  # there is no automatic selection based on which rank happens to pass.
  module FullArrayRootOutputReviews
    KIND = 'source-reviewed-root-output'
    module_function

    def check_profile!(profile, row)
      unless profile.fetch('schema_version') == 1 && %w[id benchmark backend source_commit source_path].all? { |key| profile.fetch(key) == row.fetch(key) } &&
          %w[mpi hybrid].include?(profile.fetch('backend')) && profile.fetch('printed_rank') == 'rank-0' &&
          profile.fetch('captured_ranks') == %w[rank-0 rank-1 rank-2 rank-3] &&
          profile.fetch('source_file') == row.fetch('source_files').fetch(profile.fetch('source_file_path')) &&
          profile.fetch('elements').is_a?(Integer) && profile.fetch('elements').positive? &&
          !profile.fetch('array_name').empty? && !profile.fetch('source_finding').strip.empty?
        raise 'Root-output profile does not match the inspected source'
      end
    end

    def select(profile, observation, stdout)
      unless observation.fetch('id') == profile.fetch('id') && observation.fetch('backend') == profile.fetch('backend') &&
          observation.fetch('errors') == [FullArrayReconcile::CAPTURE_ERROR] && !observation.fetch('observation_complete') &&
          observation.fetch('execution').fetch('success') && observation.fetch('capture_reports').all? { |report| report.fetch('errors').empty? && report.fetch('exit_codes') == [0] }
        raise 'Not an isolated root-output correspondence problem'
      end
      objects = observation.fetch('objects')
      printed = FullArrayCapture.output_objects(stdout)
      unless objects.map { |object| object.fetch('rank') }.sort == profile.fetch('captured_ranks') &&
          printed == observation.fetch('printed_objects') && printed.size == 1 &&
          objects.all? { |object| object.fetch('name') == profile.fetch('array_name') && object.fetch('elements') == profile.fetch('elements') }
        raise 'Root-output capture/printed coverage differs'
      end
      objects.each do |object|
        bytes = File.binread(object.fetch('local_path'))
        unless bytes.bytesize == object.fetch('bytes') && Digest::SHA256.hexdigest(bytes) == object.fetch('sha256') &&
            FullArrayCapture.fnv(bytes) == object.fetch('fnv1a64')
          raise 'Root-output capture bytes changed'
        end
      end
      matches = objects.select { |object| object.slice('name', 'elements', 'fnv1a64') == printed.first }
      unless matches.size == 1 && matches.first.fetch('rank') == profile.fetch('printed_rank')
        raise 'Printed output does not uniquely identify the source-declared output rank'
      end
      matches.first
    end

    def load_review(evidence, observation, stdout)
      path = File.join(evidence, FullArrayFull::PHASE, observation.fetch('id'), 'root-output-review.json')
      return nil unless File.file?(path)
      review = ValidationAudit.read(path)
      profile = review.fetch('profile')
      binding = ValidationAudit.read(File.join(evidence, 'bindings', observation.fetch('id') + '.json'))
      unless review.fetch('kind') == KIND && review.fetch('id') == observation.fetch('id') &&
          review.fetch('profile_sha256') == Digest::SHA256.hexdigest(JSON.pretty_generate(profile) + "\n") &&
          profile.fetch('source_file') == binding.fetch('source_files').fetch(profile.fetch('source_file_path')) &&
          review.fetch('original_observation_sha256') == Digest::SHA256.hexdigest(JSON.pretty_generate(observation) + "\n") &&
          review.fetch('stdout_sha256') == Digest::SHA256.hexdigest(stdout) &&
          review.fetch('extension_method_sha256') == ValidationAudit.sha(__FILE__) &&
          %w[program_runs benchmark_runs llm_invocations program_source_changes].all? { |key| review.fetch(key).zero? }
        raise 'Root-output review binding differs'
      end
      raise 'Root-output selection changed' unless review.fetch('selected_objects') == [select(profile, observation, stdout)]
      [review, path]
    end

    def record_review(workspace:, evidence:, profile_path:)
      profile = ValidationAudit.read(profile_path)
      id = profile.fetch('id')
      campaign = FullArrayFull.new(workspace: workspace, evidence: evidence)
      root = File.join(evidence, FullArrayFull::PHASE)
      plan = ValidationAudit.read(File.join(root, 'plan.json'))
      raise 'Frozen runtime changed' unless campaign.method_files == plan.fetch('method_sha256')
      group = plan.fetch('groups').find { |entry| entry.fetch('full_ids').include?(id) }
      raise 'Observation not in approved plan' unless group
      row = ValidationAudit.read(File.join(evidence, "inventory-#{group.fetch('benchmark')}.json")).fetch('rows').find { |entry| entry.fetch('id') == id }
      check_profile!(profile, row)
      directory = File.join(root, id)
      raise 'Refusing to replace a completed comparison' if File.exist?(File.join(directory, 'comparison.json'))
      observation_path = File.join(directory, 'observation.json')
      observation = ValidationAudit.read(observation_path)
      stdout = File.read(File.join(directory, 'validation_stdout.log'))
      selected = select(profile, observation, stdout)
      digest = ValidationAudit.sha(__FILE__)
      relative = File.join('observer-extensions', digest, File.basename(__FILE__))
      method_path = File.join(root, relative)
      if File.exist?(method_path)
        raise 'Retained root-output method changed' unless ValidationAudit.sha(method_path) == digest
      else
        FileUtils.mkdir_p(File.dirname(method_path))
        File.open(method_path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(File.binread(__FILE__)) }
      end
      review = { 'schema_version' => 1, 'kind' => KIND, 'id' => id, 'profile' => profile,
        'profile_sha256' => Digest::SHA256.hexdigest(JSON.pretty_generate(profile) + "\n"),
        'basis' => 'The individually reviewed source gathers its complete result to rank zero and suppresses non-root output. The unique printed FNV identifies that captured root array independently of its numerical verdict. Unprinted partial arrays remain retained.',
        'original_observation_sha256' => ValidationAudit.sha(observation_path), 'stdout_sha256' => Digest::SHA256.hexdigest(stdout),
        'selected_objects' => [selected], 'captured_objects' => observation.fetch('objects').size,
        'extension_method' => relative, 'extension_method_sha256' => digest,
        'plan_sha256' => ValidationAudit.sha(File.join(root, 'plan.json')), 'reviewed_at' => Time.now.utc.iso8601,
        'program_runs' => 0, 'benchmark_runs' => 0, 'llm_invocations' => 0, 'program_source_changes' => 0 }
      ValidationAudit.save(File.join(directory, 'root-output-review.json'), review)
      comparison = campaign.check(row, group)
      unless comparison.fetch('passed')
        ValidationAudit.save(File.join(root, 'failure-events', id + '.json'), { 'id' => id, 'checked_at' => Time.now.utc.iso8601,
          'comparison' => comparison.fetch('arrays'), 'comparison_sha256' => ValidationAudit.sha(File.join(directory, 'comparison.json')), 'benchmark_runs' => 0 })
      end
      puts JSON.pretty_generate(comparison.reject { |key, _| key == 'source' })
    end

    module Extension
      def normalized_observation(observation, stdout)
        reviewed = @evidence && FullArrayRootOutputReviews.load_review(@evidence, observation, stdout)
        return super unless reviewed
        review, path = reviewed
        selected = review.fetch('selected_objects')
        reconciliation = { 'kind' => FullArrayRootOutputReviews::KIND, 'reason' => review.fetch('basis'),
          'selected_objects' => selected, 'captured_objects' => observation.fetch('objects').size,
          'root_output_review_sha256' => ValidationAudit.sha(path), 'extension_method_sha256' => review.fetch('extension_method_sha256') }
        [observation.merge('objects' => selected, 'errors' => [], 'observation_complete' => true), reconciliation]
      end
    end
  end
  FullArrayFull.prepend(FullArrayRootOutputReviews::Extension)
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: full_array_root_output_reviews.rb WORKSPACE EVIDENCE run|review [PROFILE_JSON]' unless (3..4).cover?(ARGV.size)
  case ARGV[2]
  when 'review' then ValidationAudit::FullArrayRootOutputReviews.record_review(workspace: ARGV[0], evidence: ARGV[1], profile_path: ARGV.fetch(3))
  when 'run' then ValidationAudit::FullArrayFull.new(workspace: ARGV[0], evidence: ARGV[1]).run
  else raise 'Unknown root-output action'
  end
end
