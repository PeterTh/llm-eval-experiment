#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "benchmark_validation_batch"
require_relative "export_timing_corrections"

module BenchmarkBatchExport
  LOG_PATTERN = /\A(?:benchmark_(?:warmup|\d+)|cmake|build)_(?:command|stdout|stderr|exitcode|wall_time|parse_error)\.log\z/
  BASE_FIELDS = %w[args timeout_seconds configuration_sha256 wall_seconds warmup_wall_seconds
                   all_execution_wall_seconds executions success metrics].freeze
  module_function

  def record(id, metadata, correction)
    info = metadata.fetch("run")
    fixed = metadata["timing_fixed"] == true
    raise "Correction registry/metadata disagreement for #{id}" unless fixed == !correction.nil?
    result = { "schema_version" => 2, "id" => id, "benchmark" => info.fetch("benchmark"),
      "model" => info.fetch("model"), "backend" => info.fetch("par_type"),
      "repetition" => info.fetch("run"), "batch" => info.fetch("batch"),
      "source_path" => "#{info.fetch('batch')}/#{id}" }
    BASE_FIELDS.each { |key| result[key] = metadata.fetch(key) }
    if metadata["pipeline_amendment_sha256"]
      result["pipeline_amendment_sha256"] = metadata.fetch("pipeline_amendment_sha256")
    end
    result["timing_fixed"] = fixed
    result["timing_correction"] = if fixed
      { "source_correction_amendment_sha256" => metadata.fetch("source_correction_amendment_sha256"),
        "issue_categories" => metadata.fetch("timing_fix_issue_categories"),
        "changed_paths" => metadata.fetch("timing_fix_changed_paths"),
        "original_source" => { "commit" => metadata.fetch("original_source_commit"),
          "digest" => metadata.fetch("original_source_digest"), "url" => correction.fetch("original_source_url") },
        "corrected_source" => { "commit" => metadata.fetch("corrected_source_commit"),
          "digest" => metadata.fetch("corrected_source_digest"), "url" => correction.fetch("corrected_source_url") },
        "build" => { "success" => metadata.fetch("build_success"), "error" => metadata["build_error"],
          "staged_source_content_sha256" => metadata.fetch("staged_source_content_sha256"),
          "temporary_workspace" => metadata.fetch("temporary_workspace") } }
    end
    result
  end

  # Preserve native metadata exactly without storing all its values a second time.
  # The evaluation manifest retains `run`; the evidence index retains key order.
  def native_metadata(record, info, key_order)
    data = { "run" => info, "pipeline_amendment_sha256" => record["pipeline_amendment_sha256"] }
    BASE_FIELDS.each { |key| data[key] = record.fetch(key) }
    if record.fetch("timing_fixed")
      correction = record.fetch("timing_correction")
      data.merge!("timing_fixed" => true,
        "source_correction_amendment_sha256" => correction.fetch("source_correction_amendment_sha256"),
        "timing_fix_issue_categories" => correction.fetch("issue_categories"),
        "timing_fix_changed_paths" => correction.fetch("changed_paths"),
        "build_success" => correction.dig("build", "success"), "build_error" => correction.dig("build", "error"),
        "temporary_workspace" => correction.dig("build", "temporary_workspace"),
        "staged_source_content_sha256" => correction.dig("build", "staged_source_content_sha256"))
      %w[original corrected].each do |kind|
        %w[commit digest].each { |field| data["#{kind}_source_#{field}"] = correction.dig("#{kind}_source", field) }
      end
    end
    raise "Native metadata field set changed" unless data.keys.sort == key_order.sort
    key_order.to_h { |key| [key, data.fetch(key)] }
  end

  def failure_category(metadata, stderr)
    return nil if metadata.fetch("success")
    return "file_size_limit" if stderr.match?(/File size limit exceeded/i)
    return "program_crash" if stderr.match?(/Segmentation fault|signal 11/i)
    return "timeout" if metadata.fetch("executions").any? { |execution| execution["timed_out"] }
    return "build_failure" if metadata["build_success"] == false
    "other_failure"
  end

  def index_unique(records)
    indexed = records.to_h { |entry| [entry.fetch("id"), entry] }
    raise "Duplicate record IDs" unless indexed.size == records.size
    indexed
  end

  def verify_refresh_scope!(before, after, before_evidence, after_evidence, affected_ids)
    raise "Refresh ID set differs" unless before.keys.sort == after.keys.sort &&
      before_evidence.keys.sort == before.keys.sort && after_evidence.keys.sort == after.keys.sort
    raise "Invalid refresh scope" unless !affected_ids.empty? && affected_ids == affected_ids.uniq.sort &&
      (affected_ids - before.keys).empty?
    unaffected = before.keys.sort - affected_ids
    unaffected.each do |id|
      raise "Unrelated exported record changed: #{id}" unless before.fetch(id) == after.fetch(id)
      raise "Unrelated native evidence changed: #{id}" unless before_evidence.fetch(id) == after_evidence.fetch(id)
    end
    unaffected.size
  end

  def load_immutable(path)
    raise "Missing or changed digest for #{path}" unless File.file?("#{path}.sha256") &&
      File.read("#{path}.sha256").strip == LocalEvaluation.sha256_file(path)
    LocalEvaluation.load_yaml(path)
  end

  # Refresh only a completed, explicitly scoped pipeline retry. Preserve the
  # initial export outside Git as a recovery checkpoint; retain only the three
  # superseded records and their failure evidence in the current export.
  def refresh(run_dir:, batch_dir:, retry_dir:, dry_run: false)
    run_dir, batch_dir, retry_dir = [run_dir, batch_dir, retry_dir].map { |path| File.realpath(path) }
    output = File.join(batch_dir, "benchmark")
    raise "Existing benchmark export required" unless File.directory?(output)
    raise "Retry evidence must be within this campaign" unless retry_dir.start_with?(File.join(run_dir, "benchmark-campaign") + "/")
    lock = LocalEvaluation::RunLock.new(run_dir)
    host_lock = LocalEvaluation::HostPerformanceLock.new
    campaign = BenchmarkValidationBatch.campaign_data(run_dir)
    manifest = LocalEvaluation::Manifest.new(run_dir)
    manifest.verify_input_revisions!(operation: "aggregate")
    retry_manifest = load_immutable(File.join(retry_dir, "manifest.yaml"))
    progress = LocalEvaluation.load_yaml(File.join(retry_dir, "progress.yaml"))
    raise "Scoped retry has not completed" unless progress.fetch("phase") == "complete"
    amendment = LocalEvaluation::PipelineAmendment.load_chain(run_dir, manifest: manifest).last
    raise "Retry does not bind the current amendment" unless amendment && amendment.digest == retry_manifest.fetch("pipeline_amendment_sha256")
    affected = retry_manifest.fetch("affected_run_ids")
    raise "Retry/amendment scope differs" unless affected == amendment.data.fetch("affected_run_ids")
    raise "Retry configuration differs" unless retry_manifest.fetch("configuration_sha256") == campaign.fetch("configuration_sha256")
    config = LocalEvaluation::BenchmarkConfig.new(File.join(run_dir, "benchmark_config.yaml"))
    baseline = LocalEvaluation::BenchmarkConfig.new(config.data.fetch("configuration_inheritance").fetch("path"))
    raise "Inherited settings changed" unless baseline.digest == campaign.fetch("baseline_configuration_sha256") &&
      config.data.fetch("cells") == baseline.data.fetch("cells") && config.data.fetch("target_seconds") == baseline.data.fetch("target_seconds")
    retry_manifest.fetch("artifacts").each do |name, digest|
      raise "Retry artifact changed: #{name}" unless LocalEvaluation.sha256_file(File.join(retry_dir, name)) == digest
    end
    guard_path = File.join(retry_dir, "unaffected-guard.yaml")
    raise "Unrelated-record guard changed" unless LocalEvaluation.sha256_file(guard_path) == retry_manifest.fetch("unaffected_guard_sha256")
    guard = load_immutable(guard_path)
    before = index_unique(Dir[File.join(output, "records/*/*.jsonl")].sort.flat_map { |path| TimingAudit.load_jsonl(path) })
    before_evidence = index_unique(TimingAudit.load_jsonl(File.join(output, "evidence-index.jsonl")))
    unaffected = before.keys.sort - affected
    raise "Unrelated native records changed" unless BenchmarkValidationBatch.verify_partition!(run_dir, unaffected) == guard
    full = BenchmarkValidationBatch.full_results(run_dir)
    raise "Completed corpus differs" unless full.keys.sort == before.keys.sort && full.size == campaign.fetch("valid_programs")
    BenchmarkValidationBatch.verify_partition!(run_dir, full.keys.sort)
    registry_path = File.join(batch_dir, "timing-corrections/final/corrections.jsonl")
    raise "Correction registry changed" unless LocalEvaluation.sha256_file(registry_path) == LocalEvaluation.sha256_file(File.join(run_dir, "source_correction_records.jsonl"))
    corrections = TimingAudit.load_jsonl(registry_path).to_h { |entry| [entry.fetch("program_id"), entry] }
    records, evidence, failures, new_logs = [], [], [], {}
    full.keys.sort.each do |id|
      directory = File.join(run_dir, "benchmark", id)
      metadata_path = File.join(directory, "benchmark_metadata.yaml")
      metadata = LocalEvaluation.load_yaml(metadata_path)
      exported = record(id, metadata, corrections[id])
      raise "Metadata reconstruction differs for #{id}" unless YAML.dump(native_metadata(exported, manifest.runs.fetch(id), metadata.keys)) == File.read(metadata_path)
      logs = Dir.children(directory).select { |name| LOG_PATTERN.match?(name) }.sort
      evidence << { "id" => id, "metadata_sha256" => LocalEvaluation.sha256_file(metadata_path),
        "metadata_key_order" => metadata.keys,
        "log_sha256" => logs.to_h { |name| [name, LocalEvaluation.sha256_file(File.join(directory, name))] } }
      unless metadata.fetch("success")
        stderr = logs.grep(/stderr/).map { |name| File.read(File.join(directory, name)) }.join("\n")
        failures << { "id" => id, "category" => failure_category(metadata, stderr), "timing_fixed" => exported.fetch("timing_fixed") }
        new_logs[id] = logs.to_h { |name| [name, File.join(directory, name)] } if affected.include?(id)
      end
      records << exported
    end
    verified = verify_refresh_scope!(before, index_unique(records), before_evidence, index_unique(evidence), affected)
    raise "Retry completion guard differs" unless verified == progress.fetch("unaffected_records_verified") && verified == retry_manifest.fetch("unaffected_count")
    archives = affected.to_h do |id|
      raise "Refusing to replace a successful measurement" unless before.fetch(id).fetch("success") == false
      expected = retry_manifest.fetch("superseded_metadata_sha256").fetch(id)
      raise "Prior exported metadata differs" unless before_evidence.fetch(id).fetch("metadata_sha256") == expected
      matches = Dir[File.join(run_dir, "benchmark/attempts", id, "*/benchmark_metadata.yaml")]
        .select { |path| LocalEvaluation.sha256_file(path) == expected }
      raise "Original attempt missing or duplicated: #{id}" unless matches.size == 1
      original = LocalEvaluation.load_yaml(matches.first)
      raise "Prior exported record differs" unless record(id, original, corrections[id]) == before.fetch(id)
      before_evidence.fetch(id).fetch("log_sha256").each do |name, digest|
        raise "Prior failure log differs: #{id}/#{name}" unless LocalEvaluation.sha256_file(File.join(output, "failures", id, name)) == digest
      end
      [id, File.basename(File.dirname(matches.first))]
    end
    invocations_path = File.join(run_dir, "benchmark/benchmark_run_metadata.yaml")
    invocations = LocalEvaluation.load_yaml(invocations_path).fetch("invocations")
    prior_invocations = retry_manifest.fetch("prior_invocations")
    raise "Previous invocations changed" unless invocations.first(prior_invocations.size) == prior_invocations
    new_invocations = invocations.drop(prior_invocations.size)
    raise "Unexpected retry invocations" unless new_invocations.sum { |entry| entry.fetch("pending") } == affected.size &&
      new_invocations.all? { |entry| entry.fetch("retry_failed") && entry.fetch("pipeline_amendment_sha256") == amendment.digest && entry.fetch("selected") == entry.fetch("pending") }
    summary = JSON.parse(File.read(File.join(output, "summary.json")))
    raise "Export already refreshed" unless summary.fetch("retries") == 0
    summary["initial_completed_at"] = summary.fetch("completed_at")
    summary["completed_at"] = progress.fetch("updated_at")
    summary["initial_unchanged_records_verified"] = summary.fetch("unchanged_records_verified")
    summary.merge!("successful" => records.count { |entry| entry.fetch("success") }, "failed" => failures.size,
      "failure_categories" => failures.group_by { |entry| entry.fetch("category") }.transform_values(&:size),
      "timing_fixed_successful" => records.count { |entry| entry.fetch("timing_fixed") && entry.fetch("success") },
      "unchanged_records_verified" => verified, "retries" => affected.size,
      "pipeline_amendment_sha256" => amendment.digest)
    { "by_model" => "model", "by_backend" => "backend" }.each do |key, field|
      summary[key] = records.group_by { |entry| entry.fetch(field) }.transform_values do |entries|
        { "records" => entries.size, "successful" => entries.count { |entry| entry.fetch("success") } }
      end
    end
    if dry_run
      puts JSON.pretty_generate(summary.merge("dry_run" => true))
      return
    end

    # Assemble on local /tmp; the final same-filesystem directory rename keeps
    # readers from seeing a mix of old and new canonical records.
    workspace = Dir.mktmpdir("benchmark-batch-refresh-", "/tmp")
    staged = File.join(workspace, "benchmark")
    FileUtils.cp_r(output, staged)
    affected.each do |id|
      destination = File.join(staged, "attempts", id, archives.fetch(id))
      FileUtils.mkdir_p(File.dirname(destination))
      File.rename(File.join(staged, "failures", id), destination)
      TimingAudit.atomic_write(File.join(destination, "record.json"), JSON.pretty_generate(before.fetch(id)) + "\n")
      TimingAudit.atomic_write(File.join(destination, "evidence.json"), JSON.pretty_generate(before_evidence.fetch(id)) + "\n")
    end
    records.group_by { |entry| [entry.fetch("benchmark"), entry.fetch("backend")] }.each do |(benchmark, backend), entries|
      TimingAudit.atomic_write(File.join(staged, "records", benchmark, "#{backend}.jsonl"), TimingAudit.dump_jsonl(entries))
    end
    %w[benchmark_full_results.yaml benchmark_results.yaml benchmark_run_metadata.yaml preflight.yaml].each do |name|
      TimingAudit.atomic_write(File.join(staged, name), File.binread(File.join(run_dir, "benchmark", name)))
    end
    new_logs.each do |id, logs|
      logs.each { |name, path| TimingAudit.atomic_write(File.join(staged, "failures", id, name), File.binread(path)) }
    end
    LocalEvaluation::PipelineAmendment.paths_for(run_dir).each do |path|
      [path, "#{path}.sha256"].each { |source| TimingAudit.atomic_write(File.join(staged, "provenance", File.basename(source)), File.binread(source)) }
    end
    relative_retry = retry_dir.delete_prefix(File.join(run_dir, "benchmark-campaign") + "/")
    Dir[File.join(retry_dir, "**", "*")].select { |path| File.file?(path) }.each do |path|
      TimingAudit.atomic_write(File.join(staged, "campaign", relative_retry, path.delete_prefix(retry_dir + "/")), File.binread(path))
    end
    TimingAudit.atomic_write(File.join(staged, "evidence-index.jsonl"), TimingAudit.dump_jsonl(evidence))
    TimingAudit.atomic_write(File.join(staged, "failures.jsonl"), TimingAudit.dump_jsonl(failures))
    TimingAudit.atomic_write(File.join(staged, "summary.json"), JSON.pretty_generate(summary) + "\n")
    TimingAudit.atomic_write(File.join(staged, "method/export_benchmark_batch.rb"), File.binread(__FILE__))
    reconstruction = JSON.parse(File.read(File.join(staged, "reconstruction.json")))
    reconstruction["pipeline"] = "../method/validation; for amended attempts overlay campaign/#{relative_retry}/support.rb at lib/local_evaluation/support.rb; hashes in provenance/#{File.basename(amendment.path)}"
    reconstruction["superseded_attempts"] = "attempts/<id>/<attempt>/record.json + evidence.json; use native_metadata as for current records"
    TimingAudit.atomic_write(File.join(staged, "reconstruction.json"), JSON.pretty_generate(reconstruction) + "\n")
    TimingCorrectionExport.checksum_tree(staged)
    publication = Dir.mktmpdir(".benchmark-publication-", batch_dir)
    FileUtils.cp_r(File.join(staged, "."), publication)
    backup = File.join(run_dir, "benchmark-export-history", "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{Process.pid}")
    FileUtils.mkdir_p(File.dirname(backup))
    raise "Publication/recovery directories must share a filesystem" unless File.stat(output).dev == File.stat(File.dirname(backup)).dev
    File.rename(output, backup)
    begin
      File.rename(publication, output)
    rescue Exception
      File.rename(backup, output)
      raise
    end
    TimingCorrectionExport.checksum_tree(batch_dir)
    puts JSON.pretty_generate(summary.merge("previous_export_checkpoint" => backup))
  ensure
    LocalEvaluation::BuildSupport.remove_local_temporary_workspace!(workspace, required_prefix: "benchmark-batch-refresh-") if workspace && File.exist?(workspace)
    host_lock&.close
    lock&.close
  end

  def run(run_dir:, batch_dir:, conditional_decisions:)
    run_dir = File.realpath(run_dir)
    batch_dir = File.realpath(batch_dir)
    output = File.join(batch_dir, "benchmark")
    raise "Benchmark export already exists" if File.exist?(output)
    lock = LocalEvaluation::RunLock.new(run_dir)
    host_lock = LocalEvaluation::HostPerformanceLock.new
    campaign = BenchmarkValidationBatch.campaign_data(run_dir)
    manifest = LocalEvaluation::Manifest.new(run_dir)
    manifest.verify_input_revisions!
    progress = LocalEvaluation.load_yaml(File.join(run_dir, "benchmark-campaign/progress.yaml"))
    raise "Campaign has not completed" unless progress["phase"] == "complete" && progress["unchanged_partition_verified"] == true
    ids = BenchmarkValidationBatch.load_results(run_dir).select { |r| BenchmarkValidationBatch.fully_valid?(r) }.map(&:id_string).sort
    results = BenchmarkValidationBatch.full_results(run_dir)
    raise "Final result set differs from valid programs" unless results.keys.sort == ids && ids.size == campaign.fetch("valid_programs")
    BenchmarkValidationBatch.verify_partition!(run_dir, ids)
    unchanged = File.readlines(File.join(run_dir, "benchmark-campaign/unchanged-ids.txt"), chomp: true)
    guard = LocalEvaluation.load_yaml(File.join(run_dir, "benchmark-campaign/unchanged-benchmarks-guard.yaml"))
    raise "Unchanged partition differs" unless BenchmarkValidationBatch.verify_partition!(run_dir, unchanged) == guard
    raise "Batch validation provenance differs" unless LocalEvaluation.sha256_file(File.join(batch_dir, "provenance/evaluation_manifest.yaml")) == campaign.fetch("manifest_sha256")
    correction_records = File.join(batch_dir, "timing-corrections/final/corrections.jsonl")
    raise "Exported correction registry differs" unless LocalEvaluation.sha256_file(correction_records) == LocalEvaluation.sha256_file(File.join(run_dir, "source_correction_records.jsonl"))
    corrections = TimingAudit.load_jsonl(correction_records).to_h { |r| [r.fetch("program_id"), r] }
    config = LocalEvaluation::BenchmarkConfig.new(File.join(run_dir, "benchmark_config.yaml"))
    baseline = LocalEvaluation::BenchmarkConfig.new(config.data.fetch("configuration_inheritance").fetch("path"))
    raise "Historical settings differ" unless config.data.fetch("cells") == baseline.data.fetch("cells") &&
      config.data.fetch("target_seconds") == baseline.data.fetch("target_seconds") && baseline.digest == campaign.fetch("baseline_configuration_sha256")
    decisions = TimingAudit.load_jsonl(conditional_decisions)
    conditional_ids = TimingAudit.load_jsonl(File.join(batch_dir, "timing-audit/primary/final/decisions.jsonl"))
      .select { |r| r["timing_review_required"] == true }.map { |r| r.fetch("program_id") }.sort
    raise "Conditional decisions do not cover remaining audit conditions" unless decisions.map { |r| r.fetch("program_id") }.sort == conditional_ids
    decisions.each do |decision|
      info = manifest.runs.fetch(decision.fetch("program_id"))
      raise "Conditional decision configuration differs" unless decision.fetch("configuration_sha256") == config.digest &&
        decision.fetch("args") == config.cell(info.fetch("par_type"), info.fetch("benchmark")).fetch("args").map(&:to_s) &&
        decision.fetch("resource_profile") == manifest.data.dig("resource_profiles", "benchmark", info.fetch("par_type")) &&
        decision.fetch("source_commit") == campaign.dig("original_source", "commit") && decision.fetch("valid_for_configuration") == true
    end
    records = []
    evidence = []
    failures = []
    files = {}
    ids.each do |id|
      directory = File.join(run_dir, "benchmark", id)
      path = File.join(directory, "benchmark_metadata.yaml")
      metadata = LocalEvaluation.load_yaml(path)
      exported = record(id, metadata, corrections[id])
      rebuilt = native_metadata(exported, manifest.runs.fetch(id), metadata.keys)
      raise "Native metadata cannot be reconstructed exactly for #{id}" unless YAML.dump(rebuilt) == File.read(path)
      logs = Dir.children(directory).select { |name| LOG_PATTERN.match?(name) }.sort
      evidence << { "id" => id, "metadata_sha256" => LocalEvaluation.sha256_file(path),
        "metadata_key_order" => metadata.keys,
        "log_sha256" => logs.to_h { |name| [name, LocalEvaluation.sha256_file(File.join(directory, name))] } }
      unless metadata.fetch("success")
        stderr = logs.grep(/stderr/).map { |name| File.read(File.join(directory, name)) }.join("\n")
        failures << { "id" => id, "category" => failure_category(metadata, stderr), "timing_fixed" => exported.fetch("timing_fixed") }
        logs.each { |name| files["failures/#{id}/#{name}"] = File.join(directory, name) }
      end
      records << exported
    end
    %w[benchmark_full_results.yaml benchmark_results.yaml benchmark_run_metadata.yaml preflight.yaml].each do |name|
      files[name] = File.join(run_dir, "benchmark", name)
    end
    %w[benchmark_config.yaml benchmark_config.yaml.sha256 benchmark_seed.yaml benchmark_seed.yaml.sha256
       source_correction_amendment.yaml source_correction_amendment.yaml.sha256
       source_correction_evidence_manifest.yaml source_correction_evidence_manifest.yaml.sha256
       source_correction_ids.txt source_correction_ids.txt.sha256].each { |name| files["provenance/#{name}"] = File.join(run_dir, name) }
    files["provenance/source_correction_records.jsonl.sha256"] = File.join(run_dir, "source_correction_records.jsonl.sha256")
    # Registry values already exist in timing-corrections/final; retain hashes and
    # a reconstruction map rather than copying the large registry again.
    campaign_root = File.join(run_dir, "benchmark-campaign")
    Dir[File.join(campaign_root, "**", "*")].select { |p| File.file?(p) }.each do |path|
      next if File.basename(path) == "corrections.jsonl"
      files["campaign/#{path.delete_prefix(campaign_root + '/')}"] = path
    end
    files["conditional-timing-decisions.jsonl"] = conditional_decisions
    files["method/export_benchmark_batch.rb"] = __FILE__
    summary = { "schema_version" => 1, "completed_at" => progress.fetch("updated_at"),
      "records" => records.size, "successful" => records.count { |r| r.fetch("success") },
      "failed" => failures.size, "failure_categories" => failures.group_by { |r| r.fetch("category") }.transform_values(&:size),
      "timing_fixed" => corrections.size, "timing_fixed_successful" => records.count { |r| r.fetch("timing_fixed") && r.fetch("success") },
      "unchanged_records_verified" => unchanged.size, "configuration_sha256" => config.digest,
      "inherited_configuration_sha256" => baseline.digest, "measurement_settings_unchanged" => true,
      "warmups" => 1, "measurements" => BENCHMARK_COUNT, "retries" => 0,
      "by_model" => records.group_by { |r| r.fetch("model") }.transform_values { |rs| { "records" => rs.size, "successful" => rs.count { |r| r.fetch("success") } } },
      "by_backend" => records.group_by { |r| r.fetch("backend") }.transform_values { |rs| { "records" => rs.size, "successful" => rs.count { |r| r.fetch("success") } } } }
    # All semantic checks precede any export writes.
    files.each { |relative, source| TimingAudit.atomic_write(File.join(output, relative), File.binread(source)) }
    records.group_by { |r| [r.fetch("benchmark"), r.fetch("backend")] }.each do |(benchmark, backend), values|
      TimingAudit.atomic_write(File.join(output, "records", benchmark, "#{backend}.jsonl"), TimingAudit.dump_jsonl(values))
    end
    TimingAudit.atomic_write(File.join(output, "evidence-index.jsonl"), TimingAudit.dump_jsonl(evidence))
    TimingAudit.atomic_write(File.join(output, "failures.jsonl"), TimingAudit.dump_jsonl(failures))
    TimingAudit.atomic_write(File.join(output, "summary.json"), JSON.pretty_generate(summary) + "\n")
    TimingAudit.atomic_write(File.join(output, "reconstruction.json"), JSON.pretty_generate({
      "native_metadata" => "BenchmarkBatchExport.native_metadata(record, evaluation_manifest.runs[id], evidence.metadata_key_order); YAML.dump reproduces the recorded metadata_sha256",
      "provenance/source_correction_records.jsonl" => "../timing-corrections/final/corrections.jsonl",
      "campaign/correction-evidence/corrections.jsonl" => "../timing-corrections/final/corrections.jsonl",
      "pipeline" => "../method/validation; identical to the frozen validation pipeline",
      "runner_source_path" => "tools/timing_audit/bin/benchmark_validation_batch.rb",
      "runner_snapshot" => "campaign/runner-snapshot.rb" }) + "\n")
    TimingCorrectionExport.checksum_tree(output)
    TimingCorrectionExport.checksum_tree(batch_dir)
    paths = Dir[File.join(output, "**", "*")].select { |p| File.file?(p) }
    puts JSON.pretty_generate(summary.merge("files" => paths.size, "bytes" => paths.sum { |p| File.size(p) }))
  ensure
    host_lock&.close
    lock&.close
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |opts|
    opts.on("--run-dir=PATH") { |value| options[:run_dir] = value }
    opts.on("--batch-dir=PATH") { |value| options[:batch_dir] = value }
    opts.on("--conditional-decisions=PATH") { |value| options[:conditional_decisions] = value }
    opts.on("--refresh-amended") { options[:refresh_amended] = true }
    opts.on("--retry-dir=PATH") { |value| options[:retry_dir] = value }
    opts.on("--dry-run") { options[:dry_run] = true }
  end.parse!(ARGV)
  if options.delete(:refresh_amended)
    abort "Refresh requires --run-dir, --batch-dir and --retry-dir" unless ARGV.empty? &&
      (options.keys - [:dry_run]).sort == %i[batch_dir retry_dir run_dir]
    BenchmarkBatchExport.refresh(**options)
  else
    abort "Specify --run-dir, --batch-dir and --conditional-decisions" unless ARGV.empty? && options.keys.sort == %i[batch_dir conditional_decisions run_dir]
    BenchmarkBatchExport.run(**options)
  end
end
