# frozen_string_literal: true
require_relative 'full_array_full'

module ValidationAudit
  # Reviewed output disambiguation, added as an explicit launch-time extension.
  # The frozen capture, driver and numerical policy files are not edited.
  module FullArrayReviewedOutputs
    ID = 'roomsim_beam-1.0-oc-medium_hybrid_r5'
    KIND = 'first-printed-complete-result'
    module_function

    def ordered_objects(observation, stdout)
      raise 'Incomplete observation is not an output-selection issue' unless
        observation.fetch('observation_complete') && observation.fetch('errors').empty?
      printed = FullArrayCapture.output_objects(stdout)
      objects = observation.fetch('objects')
      key = ->(object) { object.slice('name', 'elements', 'fnv1a64') }
      unless printed == observation.fetch('printed_objects') && printed.size > 1 &&
          printed.map { |object| object.fetch('name') }.uniq.size == 1 &&
          printed.map { |object| object.fetch('elements') }.uniq.size == 1 &&
          objects.map(&key).tally == printed.tally
        raise 'Not multiple complete captures of the same printed result name'
      end
      objects.each do |object|
        bytes = File.binread(object.fetch('local_path'))
        unless bytes.bytesize == object.fetch('bytes') && Digest::SHA256.hexdigest(bytes) == object.fetch('sha256') &&
            FullArrayCapture.fnv(bytes) == object.fetch('fnv1a64')
          raise 'Reviewed capture bytes changed'
        end
      end
      printed.map do |entry|
        matches = objects.select { |object| key.call(object) == entry }
        unless matches.map { |object| object.slice('dtype', 'elements', 'bytes', 'sha256') }.uniq.size == 1
          raise 'Printed result does not uniquely identify captured bytes'
        end
        matches.first
      end
    end

    def comparisons(reference, observation, ordered)
      ordered.map do |object|
        { 'rank' => object.fetch('rank'), 'array_sha256' => object.fetch('sha256'),
          'comparison' => FullArrayCapture.compare(reference, observation.merge('objects' => [object])) }
      end
    end

    def load_review(evidence, observation, stdout)
      path = File.join(evidence, FullArrayFull::PHASE, observation.fetch('id'), 'primary-output-review.json')
      return nil unless File.file?(path)
      review = ValidationAudit.read(path)
      reference_path = File.join(evidence, 'full-array-pilot-01', 'reference_' + observation.fetch('benchmark'), 'observation.json')
      unless review.fetch('kind') == KIND && review.fetch('id') == observation.fetch('id') &&
          review.fetch('original_observation_sha256') == Digest::SHA256.hexdigest(JSON.pretty_generate(observation) + "\n") &&
          review.fetch('stdout_sha256') == Digest::SHA256.hexdigest(stdout) &&
          review.fetch('reference_observation_sha256') == ValidationAudit.sha(reference_path) &&
          review.fetch('extension_method_sha256') == ValidationAudit.sha(__FILE__) &&
          %w[program_runs benchmark_runs llm_invocations program_source_changes].all? { |key| review.fetch(key).zero? }
        raise 'Reviewed output selection binding differs'
      end
      ordered = ordered_objects(observation, stdout)
      replay = comparisons(ValidationAudit.read(reference_path), observation, ordered)
      # No picking a passing rank, and no new policy for mixed outcomes with a
      # passing primary output. This scoped review certifies an observed failure.
      unless review.fetch('selected_objects') == [ordered.first] && review.fetch('ordered_comparisons') == replay &&
          replay.first.dig('comparison', 'passed') == false
        raise 'Primary-output failure review does not reproduce'
      end
      [review, path]
    end

    def record_beam_review(workspace:, evidence:)
      campaign = FullArrayFull.new(workspace: workspace, evidence: evidence)
      root = File.join(evidence, FullArrayFull::PHASE)
      plan = ValidationAudit.read(File.join(root, 'plan.json'))
      raise 'Frozen runtime changed' unless campaign.method_files == plan.fetch('method_sha256')
      group = plan.fetch('groups').find { |entry| entry.fetch('full_ids').include?(ID) }
      raise 'Observation not in approved plan' unless group
      row = ValidationAudit.read(File.join(evidence, 'inventory-roomsim.json')).fetch('rows').find { |entry| entry.fetch('id') == ID }
      source = row.fetch('source_files').fetch('roomsim/roomsim.cpp')
      unless source.fetch('git_blob') == '503bc397f4526c54baf3ed44a5111ee8ea2c172d' &&
          source.fetch('sha256') == '8053fb6c27bf55cdf3ee8960f72a7dd059ab168aa2ec73647fd7af7c020bf3bb'
        raise 'Not the inspected shared-RNG implementation'
      end
      directory = File.join(root, ID)
      raise 'Refusing to replace a completed comparison' if File.exist?(File.join(directory, 'comparison.json'))
      observation_path = File.join(directory, 'observation.json')
      observation = ValidationAudit.read(observation_path)
      stdout = File.read(File.join(directory, 'validation_stdout.log'))
      ordered = ordered_objects(observation, stdout)
      reference, _text, reference_path = campaign.reference_for('roomsim')
      results = comparisons(reference, observation, ordered)
      raise 'The original primary output does not fail' unless results.first.dig('comparison', 'passed') == false
      method_digest = ValidationAudit.sha(__FILE__)
      method_relative = File.join('observer-extensions', method_digest, File.basename(__FILE__))
      method_path = File.join(root, method_relative)
      FileUtils.mkdir_p(File.dirname(method_path))
      File.open(method_path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(File.binread(__FILE__)) }
      review = { 'schema_version' => 1, 'kind' => KIND, 'id' => ID,
        'basis' => 'The unchanged validation helper reads the first complete RESULTS block. Its own printed FNV uniquely binds it to the first selected captured array. That primary result fails; no passing rank is substituted. All four rank arrays and comparisons remain retained.',
        'source_finding' => 'Existing shared-RNG data race: RandomGenerator rng(42) is outside the omp parallel for and is passed by mutable reference to computeKij (source lines 594-605; mutation at 398-402).',
        'source_commit' => row.fetch('source_commit'), 'source_path' => row.fetch('source_path'), 'source_file' => source,
        'original_observation_sha256' => ValidationAudit.sha(observation_path), 'stdout_sha256' => Digest::SHA256.hexdigest(stdout),
        'reference_observation_sha256' => ValidationAudit.sha(reference_path), 'selected_objects' => [ordered.first],
        'ordered_comparisons' => results, 'captured_objects' => ordered.size,
        'extension_method' => method_relative, 'extension_method_sha256' => method_digest,
        'plan_sha256' => ValidationAudit.sha(File.join(root, 'plan.json')), 'reviewed_at' => Time.now.utc.iso8601,
        'program_runs' => 0, 'benchmark_runs' => 0, 'llm_invocations' => 0, 'program_source_changes' => 0 }
      ValidationAudit.save(File.join(directory, 'primary-output-review.json'), review)
      comparison = campaign.check(row, group)
      raise 'Expected external-validation failure disappeared' unless comparison.fetch('passed') == false
      ValidationAudit.save(File.join(root, 'failure-events', ID + '.json'), { 'id' => ID, 'checked_at' => Time.now.utc.iso8601,
        'comparison' => comparison.fetch('arrays'), 'comparison_sha256' => ValidationAudit.sha(File.join(directory, 'comparison.json')),
        'benchmark_runs' => 0 })
      puts JSON.pretty_generate(comparison.reject { |key, _| key == 'source' })
    end

    module Extension
      def normalized_observation(observation, stdout)
        reviewed = @evidence && FullArrayReviewedOutputs.load_review(@evidence, observation, stdout)
        return super unless reviewed
        review, path = reviewed
        selected = review.fetch('selected_objects')
        reconciliation = { 'kind' => FullArrayReviewedOutputs::KIND, 'reason' => review.fetch('basis'),
          'selected_objects' => selected, 'captured_objects' => observation.fetch('objects').size,
          'primary_output_review_sha256' => ValidationAudit.sha(path),
          'extension_method_sha256' => review.fetch('extension_method_sha256') }
        [observation.merge('objects' => selected), reconciliation]
      end
    end
  end
  FullArrayFull.prepend(FullArrayReviewedOutputs::Extension)
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: full_array_reviewed_outputs.rb WORKSPACE EVIDENCE review-beam|run' unless ARGV.size == 3
  case ARGV[2]
  when 'review-beam' then ValidationAudit::FullArrayReviewedOutputs.record_beam_review(workspace: ARGV[0], evidence: ARGV[1])
  when 'run' then ValidationAudit::FullArrayFull.new(workspace: ARGV[0], evidence: ARGV[1]).run
  else raise 'Unknown reviewed-output action'
  end
end
