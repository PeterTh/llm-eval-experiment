#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/timing_audit"
require_relative "../../../lib/local_evaluation"

# A validation-only batch is supplementary evidence, not a replacement for the
# canonical scored release. Export compact, reproducible evidence without builds,
# generated source copies, or repeated raw agent streams.
module ValidationAuditExport
  module_function

  def run(run_dir:, output_dir:, primary: nil, priority: nil, adjudication: nil, pilot_adjudication: nil, pilot_review: nil, supplemental: nil)
    run_dir = File.realpath(run_dir)
    output_dir = File.expand_path(output_dir)
    manifest = LocalEvaluation::Manifest.new(run_dir)
    results = LocalEvaluation.load_yaml(File.join(run_dir, "validation/all_validation_results.yaml"),
                                        permitted_classes: [ValidationResult])
    ids = results.map(&:id_string)
    raise "Validation results incomplete or duplicated" unless ids.sort == manifest.runs.keys.sort
    expected_manifest = TimingAudit.sha256_file(manifest.path)
    existing_manifest = File.join(output_dir, "provenance/evaluation_manifest.yaml")
    if File.file?(existing_manifest) && TimingAudit.sha256_file(existing_manifest) != expected_manifest
      raise "Refusing to replace an export from another manifest"
    end
    copy = lambda do |source, relative|
      TimingAudit.atomic_write(File.join(output_dir, relative), File.binread(source))
    end
    %w[evaluation_manifest.yaml evaluation_manifest.yaml.sha256 preflight.yaml].each do |name|
      copy.call(File.join(run_dir, name), "provenance/#{name}")
    end
    copy.call(File.join(run_dir, "campaign.md"), "provenance/campaign.md") if File.file?(File.join(run_dir, "campaign.md"))
    copy.call(File.join(run_dir, "validation/preflight.yaml"), "provenance/validation-preflight.yaml")
    copy.call(File.join(run_dir, "validation/all_validation_results.yaml"), "validation/all_validation_results.yaml")
    records = results.sort_by(&:id_string).map do |result|
      id = result.id_string
      info = manifest.runs.fetch(id)
      directory = File.join(run_dir, "validation", id)
      metadata = LocalEvaluation.load_yaml(File.join(directory, "validation_metadata.yaml"))
      raise "Validation manifest mismatch for #{id}" unless metadata["manifest_sha256"] == expected_manifest
      logs = Dir[File.join(directory, "{cmake,build,validation_out}_*.log")].sort.to_h do |path|
        [File.basename(path), TimingAudit.sha256_file(path)]
      end
      retained_logs = logs.keys.select do |name|
        name.start_with?("validation_out_") || !result.validation_build || name.end_with?("_command.log", "_wall_time.log", "_exitcode.log")
      end.to_h { |name| [name, File.read(File.join(directory, name))] }
      { "id" => id, "source_batch" => info.fetch("batch"), "source_commit" => manifest.data.dig("experiment_repository", "commit"),
        "metadata" => metadata, "result" => File.read(File.join(directory, "validation_result.txt")),
        "source_staging" => File.file?(File.join(directory, "source_staging.yaml")) ? LocalEvaluation.load_yaml(File.join(directory, "source_staging.yaml")) : nil,
        "log_sha256" => logs, "logs" => retained_logs }
    end
    TimingAudit.atomic_write(File.join(output_dir, "validation/records.jsonl"), TimingAudit.dump_jsonl(records))
    Dir[File.join(run_dir, "validation/reference", "*", "{*.log,reference_metadata.yaml}")].sort.each do |path|
      next unless File.file?(path)
      copy.call(path, "validation/references/#{File.basename(File.dirname(path))}/#{File.basename(path)}")
    end
    pipeline = manifest.data.fetch("pipeline_source")
    method_layout = {}
    pipeline.fetch("files").each do |relative, expected|
      path = File.join(pipeline.fetch("root"), relative)
      raise "Pipeline snapshot changed: #{relative}" unless TimingAudit.sha256_file(path) == expected
      copy.call(path, "method/validation/#{relative}")
      method_layout["method/validation/#{relative}"] = relative
    end
    audit_counts = {}
    { "primary" => primary, "priority" => priority, "adjudication" => adjudication, "supplemental" => supplemental,
      "pilot-adjudication" => pilot_adjudication, "pilot-review" => pilot_review }.each do |label, root|
      next unless root
      TimingAudit::AuditVerifier.new(root, "full").run
      selected = TimingAudit.load_jsonl(File.join(root, "inventory.jsonl"))
      audit_counts[label] = selected.size
      %w[manifest.yaml inventory.jsonl excluded.jsonl trial-ids.txt priority-selection.jsonl priority-ids.txt
         comparison.jsonl comparison.csv summary-full.csv summary-full.jsonl pilot-review.md review-guidance.txt platform-context.txt supplemental-selection.jsonl].each do |name|
        path = File.join(root, name)
        copy.call(path, "timing-audit/#{label}/#{name}") if File.file?(path)
      end
      %w[prompt-template.txt result-schema.json].each do |name|
        if primary && TimingAudit.sha256_file(File.join(root, name)) != TimingAudit.sha256_file(File.join(primary, name))
          copy.call(File.join(root, name), "timing-audit/#{label}/#{name}")
        end
      end
      decisions = selected.map { |record| JSON.parse(File.read(File.join(root, "results", "#{record.fetch('id')}.json"))) }
      TimingAudit.atomic_write(File.join(output_dir, "timing-audit/#{label}/results.jsonl"), TimingAudit.dump_jsonl(decisions))
      attempts = Dir[File.join(root, "logs", "*", "attempt-*", "metadata.yaml")].sort.map do |path|
        metadata = YAML.safe_load_file(path, aliases: false)
        events = TimingAudit.load_jsonl(File.join(File.dirname(path), "events.jsonl"))
        transport_errors = events.filter_map do |event|
          event["message"] if event["type"] == "error"
        end.uniq
        metadata["exported_transport_errors"] = transport_errors unless transport_errors.empty?
        if metadata["exit_code"] == 0 && !metadata.key?("result_sha256")
          begin
            message = events.reverse.find { |event| event["type"] == "item.completed" && event.dig("item", "type") == "agent_message" }
            response = JSON.parse(message.fetch("item").fetch("text"))
            TimingAudit::ResultValidator.new(selected).validate!(response, expected_id: metadata.fetch("program_id"))
          rescue StandardError => error
            metadata["exported_response_validation_error"] = error.message
          end
        end
        metadata
      end
      TimingAudit.atomic_write(File.join(output_dir, "timing-audit/#{label}/attempts.jsonl"), TimingAudit.dump_jsonl(attempts))
      Dir[File.join(root, "final", "*")].sort.each do |path|
        copy.call(path, "timing-audit/#{label}/final/#{File.basename(path)}") if File.file?(path)
      end
      Dir[File.join(root, "recovery", "*")].sort.each do |path|
        copy.call(path, "timing-audit/#{label}/recovery/#{File.basename(path)}") if File.file?(path)
      end
    end
    { "prompt-template.txt" => "prompts/timing_audit_prompt.txt",
      "result-schema.json" => "schemas/timing_audit_schema.json",
      "runner-snapshot.rb" => "lib/timing_audit.rb" }.each do |name, relative|
      source = primary ? File.join(primary, name) : File.expand_path("../#{relative}", __dir__)
      copy.call(source, "method/timing-audit/#{name}")
      method_layout["method/timing-audit/#{name}"] = "tools/timing_audit/#{relative}"
    end
    %w[timing_audit.rb timing_priority_review.rb timing_finalize_audit.rb export_validation_audit.rb].each do |name|
      copy.call(File.join(__dir__, name), "method/timing-audit/#{name}")
      method_layout["method/timing-audit/#{name}"] = "tools/timing_audit/bin/#{name}"
    end
    guidance_name = "timing_equivalence_review.txt"
    copy.call(File.expand_path("../prompts/#{guidance_name}", __dir__), "method/timing-audit/#{guidance_name}")
    method_layout["method/timing-audit/#{guidance_name}"] = "tools/timing_audit/prompts/#{guidance_name}"
    TimingAudit.atomic_write(File.join(output_dir, "method/layout.json"), JSON.pretty_generate(method_layout) + "\n")
    summary = { "schema_version" => 1, "exported_at" => TimingAudit.utc_now,
                "batches" => manifest.data.fetch("batches"), "source_commit" => manifest.data.dig("experiment_repository", "commit"),
                "validation_records" => results.size, "validation_passed" => results.count(&:output_comparison),
                "timing_audit_records" => audit_counts, "benchmarking_performed" => false,
                "by_backend" => results.group_by(&:par_type).transform_values { |group| { "total" => group.size, "passed" => group.count(&:output_comparison) } } }
    if primary && File.file?(File.join(primary, "final/metadata.yaml"))
      summary["timing_audit_final_verdicts"] = YAML.safe_load_file(File.join(primary, "final/metadata.yaml"), aliases: false).fetch("final_verdict_counts")
    end
    TimingAudit.atomic_write(File.join(output_dir, "summary.json"), JSON.pretty_generate(summary) + "\n")
    TimingAudit.atomic_write(File.join(output_dir, "README.md"), <<~README)
      # Supplementary validation and timing audit: #{summary.fetch("batches").join(", ")}

      This batch has validation and, when present, static timing-audit evidence only.
      It has not been benchmarked or scored and is not merged into the historical
      canonical dataset or its website's performance results.

      Generated-source commit: `#{summary.fetch("source_commit")}`.
      Validation: #{results.size} records, #{results.count(&:output_comparison)} passing all five stages.
      See `summary.json` for backend counts and completed audit stages.
      When finalized, the human-readable findings and proposed next steps are in
      [the audit report](timing-audit/primary/final/report.md), and machine-readable
      decisions in `timing-audit/primary/final/decisions.jsonl`. An ambiguous decision
      has `timing_review_required: true` and `timing_fix_required: null`, not a pass.

      `validation/records.jsonl` retains each result's metadata, staging provenance,
      exact execution output, commands, exit statuses, wall times, and source-log
      hashes. Successful compiler output is omitted; failure diagnostics remain.
      `timing-audit/` retains inventories, exclusions, source-grounded findings,
      independent reviews, adjudications, and compact attempt provenance.
      Original generated code, transcripts, binaries, and build trees are not copied.

      Every artifact is covered by `checksums.sha256`. Exact method files are under
      `method/`; `method/layout.json` maps their stored paths to the experiment-repo
      paths needed to reconstruct a runnable checkout. This avoids modifying frozen
      code merely to accommodate the artifact repository's flat snapshot layout.
    README
    files = Dir[File.join(output_dir, "**", "*")].select { |path| File.file?(path) && File.basename(path) != "checksums.sha256" }.sort
    checksums = files.map { |path| "#{TimingAudit.sha256_file(path)}  #{path.delete_prefix(output_dir + '/')}\n" }.join
    TimingAudit.atomic_write(File.join(output_dir, "checksums.sha256"), checksums)
    puts JSON.pretty_generate(summary.merge("files" => files.size, "bytes" => files.sum { |path| File.size(path) }))
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |opts|
    opts.on("--run-dir=PATH") { |value| options[:run_dir] = value }
    opts.on("--output=PATH") { |value| options[:output_dir] = value }
    opts.on("--primary=PATH") { |value| options[:primary] = value }
    opts.on("--priority=PATH") { |value| options[:priority] = value }
    opts.on("--adjudication=PATH") { |value| options[:adjudication] = value }
    opts.on("--supplemental=PATH") { |value| options[:supplemental] = value }
    opts.on("--pilot-adjudication=PATH") { |value| options[:pilot_adjudication] = value }
    opts.on("--pilot-review=PATH") { |value| options[:pilot_review] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && options[:run_dir] && options[:output_dir]
  ValidationAuditExport.run(**options)
end
