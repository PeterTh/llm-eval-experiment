# frozen_string_literal: true
require_relative 'spmv_full_review'

module ValidationAudit
  # Reuse the checked static-review packs and acceptance rules for a new native
  # validation batch, without pretending that it is already in the public release.
  # Preparation copies/inspects bound executables; it never builds or runs them.
  class SpmvNativeReview < SpmvFullReview
    INVENTORY = 'native-spmv-inventory.json'

    def self.eligible_ids(results)
      results.values.select { |result| result.benchmark == 'spmv' && result.output_comparison }
        .map(&:id_string).sort
    end

    def prepare_inventory(validation:)
      path = File.join(evidence, INVENTORY)
      raise 'Native SpMV inventory already exists' if File.exist?(path)
      manifest = LocalEvaluation::Manifest.new(validation)
      manifest.verify_input_revisions!
      pipeline = LocalEvaluation::ValidationPipeline.new(run_dir: validation)
      results = pipeline.send(:load_results)
      raise 'Native validation is incomplete' unless results.keys.sort == manifest.runs.keys.sort
      completion_path = File.join(validation, 'validation-completion-review.json')
      completion = ValidationAudit.read(completion_path)
      results_path = File.join(validation, 'validation/all_validation_results.yaml')
      unless completion.fetch('completed') == results.size && completion.fetch('infrastructure_errors').empty? &&
          completion.fetch('validation_results_sha256') == ValidationAudit.sha(results_path)
        raise 'Native validation completion differs'
      end
      ids = self.class.eligible_ids(results)
      rows = ids.map do |id|
        info = manifest.runs.fetch(id)
        raise "Native validation evidence changed: #{id}" unless
          pipeline.send(:validation_artifacts_intact?, id, info, results.fetch(id))
        directory = File.join(validation, 'validation', id)
        row = ValidationAudit.bind_source({ 'id' => id, 'benchmark' => 'spmv', 'backend' => info.fetch('par_type'),
          'source_path' => File.join(info.fetch('batch'), id), 'source_batch' => info.fetch('batch'),
          'source_commit' => manifest.data.dig('experiment_repository', 'commit'), 'timing_fixed' => false,
          'validation_record' => { 'run_dir' => File.realpath(validation),
            'metadata_sha256' => ValidationAudit.sha(File.join(directory, 'validation_metadata.yaml')) },
          'validation_stdout_sha256' => ValidationAudit.sha(File.join(directory, 'validation_out_stdout.log')) },
          repository: manifest.data.fetch('experiments_root'))
        files = NativeFullArray.source_files(File.join(directory, 'source'))
        raise 'Native source differs from Git objects' unless files == row.fetch('source_files').transform_values { |pin| pin.slice('sha256', 'bytes') }
        staging = LocalEvaluation.load_yaml(File.join(directory, 'source_staging.yaml'))
        raise 'Native staging digest differs' unless staging.fetch('content_sha256') == row.fetch('staged_source_sha256')
        source_binary = LocalEvaluation::BuildSupport.find_executable(directory, 'spmv')
        executable = File.join(workspace, 'executables', id, 'spmv')
        raise 'Executable destination already exists' if File.exist?(executable)
        FileUtils.mkdir_p(File.dirname(executable))
        FileUtils.cp(source_binary, executable, preserve: true)
        digest = ValidationAudit.sha(source_binary)
        raise 'Copied executable changed' unless ValidationAudit.sha(executable) == digest
        ValidationAudit.save(File.join(evidence, 'bindings', id + '.json'), {
          'id' => id, 'source_files' => row.fetch('source_files'), 'executable' => executable,
          'binary_sha256' => digest, 'native_validation_directory' => directory,
          'native_metadata_sha256' => ValidationAudit.sha(File.join(directory, 'validation_metadata.yaml')) })
        row
      end
      inventory = { 'schema_version' => 1, 'created_at' => Time.now.utc.iso8601,
        'validation_run' => File.realpath(validation), 'validation_manifest_sha256' => ValidationAudit.sha(manifest.path),
        'validation_results_sha256' => ValidationAudit.sha(results_path),
        'validation_completion_sha256' => ValidationAudit.sha(completion_path),
        'rows' => rows, 'scope' => 'Every successfully validated SpMV implementation in this native batch, before benchmarking.',
        'program_executions' => 0, 'compilation' => 0, 'benchmark_runs' => 0, 'program_changes' => 0 }
      ValidationAudit.save(path, inventory)
      ValidationAudit.save(File.join(root, 'authorization.json'), {
        'inventory_sha256' => ValidationAudit.sha(path), 'full_review_authorized' => true,
        'authority' => 'Established user policy: apply work-count validation to future batches; checked Luna-first pilot, at most three parallel Luna reviewers, only uncertain cases escalated to Sol-6.1.',
        'pilot_required_before_full_delegation' => true, 'maximum_parallel_luna_reviewers' => 3,
        'program_executions' => 0, 'compilation' => 0, 'benchmark_runs' => 0, 'program_changes' => 0 })
      inventory
    end

    def load_scope
      path = File.join(evidence, INVENTORY)
      authorization = ValidationAudit.read(File.join(root, 'authorization.json'))
      raise 'Native static review not authorized' unless authorization.fetch('full_review_authorized') == true &&
        authorization.fetch('inventory_sha256') == ValidationAudit.sha(path)
      inventory = ValidationAudit.read(path)
      validation = inventory.fetch('validation_run')
      { 'evaluation_manifest.yaml' => 'validation_manifest_sha256',
        'validation/all_validation_results.yaml' => 'validation_results_sha256',
        'validation-completion-review.json' => 'validation_completion_sha256' }.each do |relative, key|
        raise 'Native validation provenance changed' unless ValidationAudit.sha(File.join(validation, relative)) == inventory.fetch(key)
      end
      rows = inventory.fetch('rows')
      raise 'Invalid native SpMV selection' unless rows.all? { |row| row.fetch('benchmark') == 'spmv' } &&
        rows.map { |row| row.fetch('id') }.uniq.size == rows.size
      [rows, []] # Native pilots are accepted in the same per-ID registry and reused.
    end

    def verify
      rows, = load_scope
      coverage = status
      indexed = rows.to_h { |row| [row.fetch('id'), row] }
      hashes = Dir[File.join(root, 'reviews/*.json')].sort.to_h do |path|
        review = ValidationAudit.read(path)
        id = review.fetch('id')
        raise 'Review filename differs' unless File.basename(path) == id + '.json'
        pack_path = File.join(root, 'packs', id + '.json')
        pack = checked_pack(pack_path, indexed.fetch(id))
        raise 'Review pack changed' unless review.fetch('pack_sha256') == ValidationAudit.sha(pack_path)
        raise 'Invalid native review identity' unless review.fetch('schema_version') == 2 && !review.fetch('reviewer').strip.empty?
        raise 'Invalid review interval' unless Time.iso8601(review.fetch('review_finished_at')) >= Time.iso8601(review.fetch('review_started_at'))
        self.class.verify_static_activity(review)
        digest = review.fetch('review_input_sha256')
        raise 'Invalid review input digest' unless digest.match?(/\A[0-9a-f]{64}\z/)
        input = File.join(root, 'review-inputs', digest + '.json')
        raise 'Archived review input changed' unless ValidationAudit.sha(input) == digest
        self.class.verify_retained_review(pack, review)
        [id, ValidationAudit.sha(path)]
      end
      coverage.reject { |key, _| key == 'remaining_ids' }.merge('evidence_verified' => true,
        'review_sha256' => hashes, 'verified_at' => Time.now.utc.iso8601)
    end

    def finish
      report = verify
      raise 'Native SpMV review is incomplete' unless report.fetch('remaining').zero?
      report = report.merge('status' => 'complete', 'full_scope_accounted_for' => true,
        'new_failures' => [], 'compilation' => 0, 'program_changes' => 0,
        'inventory_sha256' => ValidationAudit.sha(File.join(evidence, INVENTORY)),
        'authorization_sha256' => ValidationAudit.sha(File.join(root, 'authorization.json')),
        'interpretation' => 'Static source/control-flow and bound native-validation executable inspection. Not a formal proof for all compilers/inputs. No program executions, recompilation, performance reruns or source corrections.')
      ValidationAudit.save(File.join(root, 'completion.json'), report)
      puts JSON.pretty_generate(report.reject { |key, _| key == 'review_sha256' })
      report
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: spmv_native_review.rb WORKSPACE EVIDENCE inventory|prepare|check|record|verify|status|finish [VALIDATION_RUN_OR_REVIEW]' unless (3..4).cover?(ARGV.size)
  tool = ValidationAudit::SpmvNativeReview.new(workspace: ARGV[0], evidence: ARGV[1])
  case ARGV[2]
  when 'inventory' then puts JSON.pretty_generate(tool.prepare_inventory(validation: ARGV.fetch(3)).reject { |key, _| key == 'rows' })
  when 'prepare' then tool.prepare
  when 'check' then puts JSON.pretty_generate(tool.check(ARGV.fetch(3)))
  when 'record' then tool.record(ARGV.fetch(3))
  when 'verify' then puts JSON.pretty_generate(tool.verify.reject { |key, _| key == 'review_sha256' })
  when 'status' then tool.status
  when 'finish' then tool.finish
  else raise 'Unknown native static-review action'
  end
end
