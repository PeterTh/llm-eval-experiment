#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../../../lib/local_evaluation"
require_relative "../lib/timing_audit"

# Sequencing/provenance only. Measurement, builds, resource limits, resume checks
# and source-correction authorization remain in the existing local pipeline.
module BenchmarkValidationBatch
  STAGES = %w[basic_para validation_build validation_run internal_validation output_comparison].freeze
  FAILURE_CLASSIFICATIONS = %w[pre_existing_correctness_failure pre_existing_output_contract_failure].freeze
  module_function

  def load_results(run_dir)
    LocalEvaluation.load_yaml(File.join(run_dir, "validation/all_validation_results.yaml"), permitted_classes: [ValidationResult])
  end

  def fully_valid?(result)
    STAGES.all? { |stage| result.public_send(stage) == true }
  end

  # Timing-only acceptance is not numerical acceptance. A confirmed pre-existing
  # correctness or output-contract defect may supersede an earlier pass, but never
  # silently: require an explicit disposition for exactly the failed reruns.
  # Raw original and corrected validation evidence remains untouched.
  def approved_failures(path, corrected_manifest:, corrected_results:, original_commit:, corrected_commit:)
    failed = corrected_results.reject { |result| fully_valid?(result) }.to_h { |result| [result.id_string, result] }
    return {} if path.nil? && failed.empty?
    raise "Corrected revalidation has unresolved failures: #{failed.keys.sort.join(', ')}" if path.nil?

    data = JSON.parse(File.read(path))
    unless data.fetch("schema_version") == 1 && data.fetch("original_source_commit") == original_commit &&
           data.fetch("corrected_source_commit") == corrected_commit &&
           data.fetch("corrected_validation_manifest_sha256") == LocalEvaluation.sha256_file(corrected_manifest.path)
      raise "Validation failure dispositions have different source or validation provenance"
    end
    entries = data.fetch("records")
    ids = entries.map { |entry| entry.fetch("program_id") }
    unless !ids.empty? && ids == ids.uniq.sort && ids == failed.keys.sort
      raise "Validation failure dispositions must cover exactly the failed corrected programs"
    end
    entries.each do |entry|
      id = entry.fetch("program_id")
      result = failed.fetch(id)
      stages = STAGES.to_h { |stage| [stage, result.public_send(stage) == true] }
      unless entry.fetch("decision") == "fail_validation" &&
             FAILURE_CLASSIFICATIONS.include?(entry.fetch("classification")) &&
             entry.fetch("failed_stage") == STAGES.find { |stage| !stages.fetch(stage) } &&
             !entry.fetch("reason").strip.empty? &&
             entry.dig("authorization", "source") == "user" &&
             !entry.fetch("authorization").fetch("statement").strip.empty?
        raise "Invalid validation failure disposition for #{id}"
      end
      directory = File.join(File.dirname(corrected_manifest.path), "validation", id)
      metadata_path = File.join(directory, "validation_metadata.yaml")
      metadata = LocalEvaluation.load_yaml(metadata_path)
      unless metadata.fetch("id") == id && metadata.fetch("stages") == stages &&
             metadata.fetch("manifest_sha256") == LocalEvaluation.sha256_file(corrected_manifest.path)
        raise "Failed validation metadata differs for #{id}"
      end
      { "metadata_sha256" => metadata_path,
        "stdout_sha256" => File.join(directory, "validation_out_stdout.log") }.each do |key, evidence_path|
        raise "Failed validation evidence changed for #{id}" unless entry.fetch("validation_evidence").fetch(key) == LocalEvaluation.sha256_file(evidence_path)
      end
      review = entry.fetch("static_review")
      unless !review.fetch("model").strip.empty? && review.fetch("sha256") == LocalEvaluation.sha256_file(review.fetch("path"))
        raise "Static failure adjudication changed for #{id}"
      end
    end
    entries.to_h { |entry| [entry.fetch("program_id"), entry] }
  end

  def eligible_partition(original_valid_ids, correction_ids, excluded_ids)
    unless (correction_ids - original_valid_ids).empty? && (excluded_ids - correction_ids).empty?
      raise "Invalid corrected/excluded benchmark partition"
    end
    valid = (original_valid_ids - excluded_ids).sort
    corrected = (correction_ids - excluded_ids).sort
    { valid: valid, corrected: corrected, unchanged: valid - corrected }
  end

  def canary_ids(unchanged_ids, model)
    LocalEvaluation::PAR_TYPES.map do |backend|
      pattern = /\Ablack-scholes_#{Regexp.escape(model)}_#{backend}_r([1-9]\d*)\z/
      candidates = unchanged_ids.filter_map do |id|
        match = pattern.match(id)
        [match[1].to_i, id] if match
      end
      selected = candidates.min_by(&:first)
      raise "No unchanged valid black-scholes canary for #{model}/#{backend}" unless selected
      selected.last
    end
  end

  def inherited_config(baseline, manifest_sha:, validation_sha:, count:, seed_path:, baseline_path:, baseline_sha:)
    config = Marshal.load(Marshal.dump(baseline))
    config.delete("frozen_at")
    config.delete("proposed_sha256")
    config.merge!("state" => "proposed", "generated_at" => Time.now.iso8601,
      "updated_at" => Time.now.iso8601, "manifest_sha256" => manifest_sha,
      "validation_results_sha256" => validation_sha, "validation_complete" => true,
      "manifest_run_count" => count, "validation_result_count" => count, "seed_path" => seed_path,
      "configuration_inheritance" => { "path" => baseline_path, "sha256" => baseline_sha,
        "policy" => "All 44 cells, arguments, iteration counts, timeouts and target settings inherited unchanged; no recalibration." })
    config
  end

  def rebound_evidence(evidence, root:, original_path:, original_sha:)
    rebound = Marshal.load(Marshal.dump(evidence))
    %w[original_source corrected_source].each { |kind| rebound.fetch(kind)["root"] = root }
    rebound["execution_root_binding"] = {
      "accepted_manifest_path" => original_path, "accepted_manifest_sha256" => original_sha,
      "accepted_original_root" => evidence.dig("original_source", "root"), "execution_root" => root,
      "policy" => "Only checkout locations rebound; source commits, source digests, review evidence and correction records unchanged."
    }
    rebound
  end

  def prepare(run_dir:, baseline_config:, corrections:, corrected_validation:, original_backup:, canary_model:,
              validation_failures: nil)
    run_dir = File.realpath(run_dir)
    campaign = File.join(run_dir, "benchmark-campaign")
    raise "Campaign already exists" if File.exist?(campaign)
    run_lock = LocalEvaluation::RunLock.new(run_dir)
    host_lock = LocalEvaluation::HostPerformanceLock.new
    manifest = LocalEvaluation::Manifest.new(run_dir)
    original = manifest.data.fetch("experiment_repository")
    TimingAudit::SourceRepository.new(root: original_backup, commit: original.fetch("commit"))
    baseline = LocalEvaluation::BenchmarkConfig.new(baseline_config)
    raise "Baseline configuration is not frozen" unless baseline.frozen?
    baseline.validate_cells!
    results = load_results(run_dir)
    raise "Original validation is incomplete" unless results.map(&:id_string).sort == manifest.runs.keys.sort
    valid_ids = results.select { |result| fully_valid?(result) }.map(&:id_string).sort
    originally_valid_count = valid_ids.size
    manifest.verify_input_revisions!(operation: "benchmark", selected_ids: valid_ids)
    evidence_path = File.join(corrections, "manifest.yaml")
    evidence = LocalEvaluation.load_yaml(evidence_path)
    ids_path = File.join(corrections, "correction-ids.txt")
    records_path = File.join(corrections, "corrections.jsonl")
    all_correction_ids = File.readlines(ids_path, chomp: true).reject(&:empty?)
    records = TimingAudit.load_jsonl(records_path)
    LocalEvaluation::SourceCorrectionAmendment.send(:validate_external_evidence!, evidence, records, all_correction_ids, records_path, ids_path)
    correction_scope = (all_correction_ids - manifest.runs.keys).empty? ? "exact" : "manifest"
    raise "Corrections have another original revision" unless evidence.dig("original_source", "commit") == original.fetch("commit")
    ids = LocalEvaluation::SourceCorrectionAmendment.send(:validate_scoped_records!, records,
      all_correction_ids, manifest, original.fetch("commit"), evidence.dig("corrected_source", "commit"), scope: correction_scope)
    raise "Corrections include nonpassing original programs" unless (ids - valid_ids).empty?
    corrected_manifest = LocalEvaluation::Manifest.new(corrected_validation)
    corrected_manifest.verify_input_revisions!
    corrected_results = load_results(corrected_validation)
    unless corrected_manifest.runs.keys.sort == all_correction_ids && corrected_results.map(&:id_string).sort == all_correction_ids &&
           corrected_manifest.data.dig("experiment_repository", "commit") == evidence.dig("corrected_source", "commit")
      raise "Corrected revalidation does not cover the accepted corrections"
    end
    failures = approved_failures(validation_failures, corrected_manifest: corrected_manifest,
      corrected_results: corrected_results, original_commit: original.fetch("commit"),
      corrected_commit: evidence.dig("corrected_source", "commit"))
    excluded_ids = (failures.keys & manifest.runs.keys).sort
    partition = eligible_partition(valid_ids, ids, excluded_ids)
    valid_ids, ids, original_only = partition.values_at(:valid, :corrected, :unchanged)
    corrected_root = corrected_manifest.data.fetch("experiment_repository").fetch("path")
    LocalEvaluation::SourceCorrectionAmendment.send(:verify_record_trees!, records, corrected_root,
      original.fetch("commit"), evidence.dig("corrected_source", "commit"))
    changed_paths = LocalEvaluation::SourceCorrectionAmendment.send(:git_changed_paths, corrected_root,
      original.fetch("commit"), evidence.dig("corrected_source", "commit"))
    raise "Shared correction commit includes unreviewed paths" unless changed_paths == records.flat_map { |record| record.fetch("changed_paths") }.uniq.sort
    %w[resource_profiles benchmark_repository].each do |key|
      raise "Revalidation changed #{key}" unless corrected_manifest.data.fetch(key) == manifest.data.fetch(key)
    end
    # The original manifest can have an explicit, verified provenance-only
    # pipeline amendment before revalidation. Compare the effective pipeline,
    # not the historical snapshot that the immutable manifest rightly retains.
    effective_pipeline = LocalEvaluation.pipeline_source_snapshot(manifest.data.fetch("pipeline_source").fetch("root"))
    raise "Revalidation changed the effective pipeline" unless corrected_manifest.data.fetch("pipeline_source") == effective_pipeline
    original_only.each do |id|
      LocalEvaluation::BuildSupport.find_executable(File.join(run_dir, "validation", id), manifest.runs.fetch(id).fetch("benchmark"))
    end
    canaries = canary_ids(original_only, canary_model)
    raise "Canaries must all be unchanged valid programs" unless (canaries - original_only).empty?
    FileUtils.mkdir_p(campaign)
    seed = LocalEvaluation::CalibrationSeed.materialize!(run_dir: run_dir, source_path: baseline.data.fetch("seed_path"))
    raise "Seed differs from baseline" unless seed.digest == baseline.data.fetch("seed_sha256")
    proposed = inherited_config(baseline.data, manifest_sha: LocalEvaluation.sha256_file(manifest.path),
      validation_sha: LocalEvaluation.sha256_file(File.join(run_dir, "validation/all_validation_results.yaml")),
      count: results.size, seed_path: seed.path, baseline_path: baseline.path, baseline_sha: baseline.digest)
    LocalEvaluation.atomic_yaml(File.join(run_dir, "benchmark_config.proposed.yaml"), proposed)
    LocalEvaluation::BenchmarkPipeline.freeze_config(run_dir: run_dir)
    frozen = LocalEvaluation::BenchmarkConfig.new(File.join(run_dir, "benchmark_config.yaml"))
    raise "Inherited measurement settings changed" unless frozen.data.fetch("cells") == baseline.data.fetch("cells") &&
      frozen.data.fetch("target_seconds") == baseline.data.fetch("target_seconds")
    { "unchanged-ids.txt" => original_only, "corrected-ids.txt" => ids, "canary-ids.txt" => canaries,
      "excluded-validation-ids.txt" => excluded_ids }.each do |name, list|
      LocalEvaluation.atomic_write(File.join(campaign, name), list.join("\n") + "\n", mode: 0o444)
    end
    if validation_failures
      LocalEvaluation.atomic_write(File.join(campaign, "validation-failures.json"), File.binread(validation_failures), mode: 0o444)
    end
    derived = File.join(campaign, "correction-evidence")
    %w[corrections.jsonl correction-ids.txt].each do |name|
      LocalEvaluation.atomic_write(File.join(derived, name), File.binread(File.join(corrections, name)), mode: 0o444)
    end
    bound = rebound_evidence(evidence, root: original.fetch("path"), original_path: evidence_path,
      original_sha: LocalEvaluation.sha256_file(evidence_path))
    LocalEvaluation.atomic_yaml_with_digest(File.join(derived, "manifest.yaml"), bound, immutable: true)
    LocalEvaluation.atomic_write(File.join(campaign, "runner-snapshot.rb"), File.binread(__FILE__), mode: 0o444)
    artifacts = %w[unchanged-ids.txt corrected-ids.txt canary-ids.txt excluded-validation-ids.txt correction-evidence/manifest.yaml
                   correction-evidence/corrections.jsonl correction-evidence/correction-ids.txt runner-snapshot.rb]
    artifacts << "validation-failures.json" if validation_failures
    data = { "schema_version" => 1, "created_at" => Time.now.iso8601, "run_dir" => run_dir,
      "manifest_sha256" => LocalEvaluation.sha256_file(manifest.path),
      "configuration_sha256" => frozen.digest, "baseline_configuration_sha256" => baseline.digest,
      "original_source" => original, "corrected_source_commit" => evidence.dig("corrected_source", "commit"),
      "correction_scope" => correction_scope,
      "shared_commit_corrections" => all_correction_ids.size,
      "original_source_backup" => File.realpath(original_backup),
      "corrected_validation" => { "run_dir" => File.realpath(corrected_validation),
        "manifest_sha256" => LocalEvaluation.sha256_file(corrected_manifest.path),
        "results_sha256" => LocalEvaluation.sha256_file(File.join(corrected_validation, "validation/all_validation_results.yaml")) },
      "valid_programs" => valid_ids.size, "unchanged_programs" => original_only.size, "corrected_programs" => ids.size,
      "originally_valid_programs" => originally_valid_count, "excluded_validation_programs" => excluded_ids.size,
      "excluded_validation_ids" => excluded_ids,
      "validation_policy" => "Original validation is immutable; explicitly adjudicated failed revalidations supersede earlier passes for eligibility and final validation totals, never as benchmark failures.",
      "warmups" => 1, "measurements" => BENCHMARK_COUNT,
      "artifacts" => artifacts.to_h { |name| [name, LocalEvaluation.sha256_file(File.join(campaign, name))] } }
    LocalEvaluation.atomic_yaml_with_digest(File.join(campaign, "manifest.yaml"), data, immutable: true)
    puts "Prepared #{valid_ids.size} programs: #{original_only.size} unchanged, #{ids.size} corrected, #{excluded_ids.size} excluded after failed revalidation; no validation or calibration repeated"
    data
  ensure
    host_lock&.close
    run_lock&.close
  end

  def campaign_data(run_dir)
    root = File.join(run_dir, "benchmark-campaign")
    path = File.join(root, "manifest.yaml")
    raise "Campaign manifest changed" unless LocalEvaluation.sha256_file(path) == File.read("#{path}.sha256").strip
    data = LocalEvaluation.load_yaml(path)
    raise "Campaign runner changed" unless LocalEvaluation.sha256_file(__FILE__) == data.fetch("artifacts").fetch("runner-snapshot.rb")
    data.fetch("artifacts").each do |relative, digest|
      raise "Campaign artifact changed: #{relative}" unless LocalEvaluation.sha256_file(File.join(root, relative)) == digest
    end
    raise "Run manifest changed" unless LocalEvaluation.sha256_file(File.join(run_dir, "evaluation_manifest.yaml")) == data.fetch("manifest_sha256")
    raise "Configuration changed" unless LocalEvaluation::BenchmarkConfig.new(File.join(run_dir, "benchmark_config.yaml")).digest == data.fetch("configuration_sha256")
    if data.fetch("artifacts").key?("validation-failures.json")
      corrected = data.fetch("corrected_validation")
      corrected_root = corrected.fetch("run_dir")
      corrected_manifest = LocalEvaluation::Manifest.new(corrected_root)
      unless corrected.fetch("manifest_sha256") == LocalEvaluation.sha256_file(corrected_manifest.path) &&
             corrected.fetch("results_sha256") == LocalEvaluation.sha256_file(File.join(corrected_root, "validation/all_validation_results.yaml"))
        raise "Adjudicated revalidation evidence changed"
      end
      failures = approved_failures(File.join(root, "validation-failures.json"),
        corrected_manifest: corrected_manifest, corrected_results: load_results(corrected_root),
        original_commit: data.dig("original_source", "commit"), corrected_commit: data.fetch("corrected_source_commit"))
      excluded = (failures.keys & LocalEvaluation::Manifest.new(run_dir).runs.keys).sort
      unless excluded == data.fetch("excluded_validation_ids") && excluded.size == data.fetch("excluded_validation_programs")
        raise "Adjudicated benchmark exclusions changed"
      end
    end
    data
  end

  def full_results(run_dir)
    path = File.join(run_dir, "benchmark", BENCHMARK_FULL_RESULTS_FN)
    File.file?(path) ? LocalEvaluation.load_yaml(path) : {}
  end

  def verify_partition!(run_dir, ids)
    results = full_results(run_dir)
    pipeline = LocalEvaluation::BenchmarkPipeline.new(run_dir: run_dir, ids: ids)
    ids.each do |id|
      raise "Missing completed benchmark #{id}" unless results.key?(id)
      problem = pipeline.send(:benchmark_record_problem, id, results.fetch(id))
      raise "Inconsistent benchmark #{id}: #{problem}" if problem
    end
    { "count" => ids.size,
      "records_sha256" => Digest::SHA256.hexdigest(JSON.generate(ids.sort.to_h { |id| [id, results.fetch(id)] })),
      "metadata_sha256" => ids.sort.to_h { |id| [id, LocalEvaluation.sha256_file(File.join(run_dir, "benchmark", id, "benchmark_metadata.yaml"))] } }
  end

  def checkpoint(campaign, phase, extra = {})
    LocalEvaluation.atomic_yaml(File.join(campaign, "progress.yaml"),
      { "updated_at" => Time.now.iso8601, "pid" => Process.pid, "phase" => phase }.merge(extra))
  end

  def run(run_dir:)
    run_dir = File.realpath(run_dir)
    data = campaign_data(run_dir)
    campaign = File.join(run_dir, "benchmark-campaign")
    original_ids = File.readlines(File.join(campaign, "unchanged-ids.txt"), chomp: true)
    corrected_ids = File.readlines(File.join(campaign, "corrected-ids.txt"), chomp: true)
    canary_ids = File.readlines(File.join(campaign, "canary-ids.txt"), chomp: true)
    run_lock = LocalEvaluation::RunLock.new(run_dir)
    host_lock = LocalEvaluation::HostPerformanceLock.new
    manifest = LocalEvaluation::Manifest.new(run_dir)
    raise "Canary measurements have not all passed" unless canary_ids.all? { |id| full_results(run_dir)[id]&.first == true }
    verify_partition!(run_dir, canary_ids)
    source = data.fetch("original_source").fetch("path")
    head = TimingAudit.capture!("git", "-C", source, "rev-parse", "HEAD").strip
    unless head == data.fetch("corrected_source_commit")
      raise "Unexpected original checkout revision" unless head == data.dig("original_source", "commit")
      phase = "unchanged"
      checkpoint(campaign, phase)
      manifest.verify_input_revisions!(operation: "benchmark", selected_ids: original_ids)
      LocalEvaluation::BenchmarkPipeline.new(run_dir: run_dir, ids: original_ids).run
    end
    guard = verify_partition!(run_dir, original_ids)
    guard_path = File.join(campaign, "unchanged-benchmarks-guard.yaml")
    if File.file?(guard_path)
      raise "Previously completed unchanged benchmarks changed" unless LocalEvaluation.load_yaml(guard_path) == guard
    else
      LocalEvaluation.atomic_yaml_with_digest(guard_path, guard, immutable: true)
    end
    phase = "source-transition"
    checkpoint(campaign, phase)
    TimingAudit::SourceRepository.new(root: data.fetch("original_source_backup"), commit: data.dig("original_source", "commit"))
    unless head == data.fetch("corrected_source_commit")
      TimingAudit::SourceRepository.new(root: source, commit: data.dig("original_source", "commit"))
      TimingAudit.capture!("git", "-C", source, "merge", "--ff-only", "--quiet", data.fetch("corrected_source_commit"))
    end
    unless File.file?(LocalEvaluation::SourceCorrectionAmendment.path_for(run_dir))
      LocalEvaluation::SourceCorrectionAmendment.create!(manifest: manifest,
        correction_dir: File.join(campaign, "correction-evidence"),
        scope: data.fetch("correction_scope", "exact"),
        reason: "Benchmark the accepted and revalidated timing-only corrections after completing the unchanged valid programs; retain all existing measurements and inherited settings.")
    end
    phase = "corrected"
    checkpoint(campaign, phase)
    manifest.verify_input_revisions!(operation: "benchmark", selected_ids: corrected_ids)
    LocalEvaluation::BenchmarkPipeline.new(run_dir: run_dir, ids: corrected_ids).run
    verify_partition!(run_dir, corrected_ids)
    raise "Unchanged benchmark partition changed" unless verify_partition!(run_dir, original_ids) == guard
    results = full_results(run_dir)
    raise "Final benchmark set differs" unless results.keys.sort == (original_ids + corrected_ids).sort
    phase = "complete"
    checkpoint(campaign, phase, "completed" => results.size,
      "successful" => results.count { |_id, record| record.first == true },
      "failed_ids" => results.filter_map { |id, record| id unless record.first == true },
      "unchanged_partition_verified" => true)
    puts "Completed #{results.size} benchmarks; unchanged partition verified"
  rescue Exception => error
    checkpoint(campaign, "stopped", "stopped_phase" => phase, "error" => "#{error.class}: #{error.message}") if phase
    raise
  ensure
    host_lock&.close
    run_lock&.close
  end

  def status(run_dir:)
    data = campaign_data(run_dir)
    progress = File.join(run_dir, "benchmark-campaign/progress.yaml")
    results = full_results(run_dir)
    puts YAML.dump({ "recorded_progress" => File.file?(progress) ? LocalEvaluation.load_yaml(progress) : nil,
      "expected" => data.fetch("valid_programs"), "completed" => results.size,
      "successful" => results.count { |_id, record| record.first == true },
      "failed_ids" => results.filter_map { |id, record| id unless record.first == true } })
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  command = ARGV.shift
  options = {}
  OptionParser.new do |opts|
    opts.on("--run-dir=PATH") { |v| options[:run_dir] = File.expand_path(v) }
    opts.on("--baseline-config=PATH") { |v| options[:baseline_config] = File.expand_path(v) }
    opts.on("--corrections=PATH") { |v| options[:corrections] = File.expand_path(v) }
    opts.on("--corrected-validation=PATH") { |v| options[:corrected_validation] = File.expand_path(v) }
    opts.on("--original-backup=PATH") { |v| options[:original_backup] = File.expand_path(v) }
    opts.on("--canary-model=MODEL") { |v| options[:canary_model] = v }
    opts.on("--validation-failures=PATH", "Explicit user-approved correctness/output-contract failure dispositions") { |v| options[:validation_failures] = File.expand_path(v) }
  end.parse!
  required = command == "prepare" ? %i[run_dir baseline_config corrections corrected_validation original_backup canary_model] : %i[run_dir]
  abort "Usage: benchmark_validation_batch.rb prepare|run|status --run-dir=PATH [preparation options]" unless
    %w[prepare run status].include?(command) && ARGV.empty? &&
    (options.keys - (command == "prepare" ? [:validation_failures] : [])).sort == required.sort
  BenchmarkValidationBatch.public_send(command, **options)
end
