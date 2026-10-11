#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/timing_fix_adjudication"
require_relative "export_validation_audit"

module TimingCorrectionExport
  STAGES = %w[basic_para validation_build validation_run internal_validation output_comparison].freeze
  module_function

  def validate_registry!(manifest, records, expected_ids, validation_manifest, validation_results)
    ids = records.map { |record| record.fetch("program_id") }
    raise "Correction ID mismatch" unless ids.uniq.size == ids.size && ids.sort == expected_ids.sort && manifest.fetch("record_count") == ids.size
    raise "Revalidation must cover exactly the corrected programs" unless validation_results.map(&:id_string).sort == ids.sort && validation_manifest.runs.keys.sort == ids.sort
    raise "Corrected validation has failures" unless validation_results.all? { |result| STAGES.all? { |stage| result.public_send(stage) == true } }
    original = manifest.fetch("original_source").fetch("commit")
    corrected = manifest.fetch("corrected_source").fetch("commit")
    raise "Correction commit is unchanged" if original == corrected
    raise "Revalidation used a different revision" unless validation_manifest.data.dig("experiment_repository", "commit") == corrected
    records.each do |record|
      raise "Correction was not accepted" unless record["timing_fixed"] == true && record["final_verdict"] == "accept"
      info = validation_manifest.runs.fetch(record.fetch("program_id"))
      raise "Correction identity differs from revalidation" unless %w[benchmark model par_type run].all? { |key| record.fetch(key) == info.fetch(key) }
      raise "Correction source prefix differs from revalidation" unless record.fetch("source_prefix") == "#{info.fetch('batch')}/#{record.fetch('program_id')}"
      %w[original corrected].each do |kind|
        source = record.fetch("#{kind}_source")
        expected_commit = kind == "original" ? original : corrected
        raise "Invalid #{kind} revision" unless source.fetch("commit") == expected_commit && expected_commit.match?(/\A[0-9a-f]{40}\z/)
        raise "Invalid #{kind} source digest" unless source.fetch("digest").match?(/\A[0-9a-f]{64}\z/)
        expected_url = "#{manifest.fetch("#{kind}_source").fetch("repository_url")}/tree/#{expected_commit}/#{record.fetch("source_prefix")}"
        raise "Invalid #{kind} website source link" unless record.fetch("#{kind}_source_url") == expected_url && expected_url.start_with?("https://github.com/")
      end
    end
    true
  end

  def checksum_tree(root)
    checksum_path = File.join(root, "checksums.sha256")
    paths = Dir[File.join(root, "**", "*")].select { |path| File.file?(path) && path != checksum_path }.sort
    TimingAudit.atomic_write(checksum_path, paths.map { |path| "#{TimingAudit.sha256_file(path)}  #{path.delete_prefix(root + '/')}\n" }.join)
  end

  def verify_snapshot_reconstruction!(root, proposals_by_id)
    inventory = TimingAudit.load_jsonl(File.join(root, "inventory.jsonl"))
    reconstructed = inventory.map do |record|
      id = record.fetch("id")
      proposal = proposals_by_id.fetch(id)
      { "program_id" => id,
        "proposal_file_sha256" => TimingAudit.sha256_bytes(JSON.pretty_generate(proposal) + "\n"),
        "proposal" => proposal }
    end
    expected = YAML.safe_load_file(File.join(root, "manifest.yaml"), aliases: false).fetch("artifacts").fetch("proposal_snapshot_sha256")
    raise "Omitted proposal snapshot cannot be reconstructed exactly" unless TimingAudit.sha256_bytes(TimingAudit.dump_jsonl(reconstructed)) == expected
    raise "Original proposal snapshot changed" unless TimingAudit.sha256_file(File.join(root, "proposal-snapshot.jsonl")) == expected
    true
  end

  def compare_numerical_outputs(original, corrected)
    blocks = [original, corrected].map { |stdout| stdout.scan(/=== RESULTS ===.*?=== END RESULTS ===/m) }
    raise "Missing numerical validation result block" if blocks.any?(&:empty?)
    { "numerical_results_identical" => blocks[0] == blocks[1],
      "original_numerical_results_sha256" => TimingAudit.sha256_bytes(JSON.generate(blocks[0])),
      "corrected_numerical_results_sha256" => TimingAudit.sha256_bytes(JSON.generate(blocks[1])) }
  end

  # A focused later audit can resolve an earlier decision without rewriting it.
  # Retain an ordered, digest-bound recipe instead of duplicating all decisions.
  def resolved_audit_selection(batch_dir, selection_path)
    base = File.realpath(batch_dir) + "/"
    selection_path = File.realpath(selection_path)
    raise "Audit selection must be retained in the batch" unless selection_path.start_with?(base)
    selection = JSON.parse(File.read(selection_path))
    raise "Unsupported audit selection" unless selection.fetch("schema_version") == 1
    inputs = selection.fetch("ordered_decisions")
    raise "Missing or duplicate audit inputs" if inputs.empty? || inputs.map { |entry| entry.fetch("path") }.uniq.size != inputs.size
    resolved = {}
    inputs.each do |input|
      relative = input.fetch("path")
      raise "Unsafe audit input" if relative.start_with?("/") || relative.split("/").include?("..")
      path = File.realpath(File.join(base, relative))
      raise "Audit input outside batch" unless path.start_with?(base)
      raise "Audit input changed" unless TimingAudit.sha256_file(path) == input.fetch("sha256")
      records = TimingAudit.load_jsonl(path)
      raise "Duplicate audit IDs" unless records.map { |record| record.fetch("program_id") }.uniq.size == records.size
      records.each do |record|
        id = record.fetch("program_id")
        if resolved[id]
          %w[benchmark model par_type run source_tree_oid source_digest].each do |key|
            raise "Audit overlay source differs for #{id}" unless record.fetch(key) == resolved.fetch(id).fetch(key)
          end
        end
        resolved[id] = record
      end
    end
    raise "Audit selection count differs" unless resolved.size == selection.fetch("record_count")
    counts = resolved.values.group_by { |record| record.fetch("final_verdict") }.transform_values(&:size)
    raise "Audit selection verdict counts differ" unless counts == selection.fetch("verdict_counts")
    resolved.each_value do |record|
      verdict = record.fetch("final_verdict")
      raise "Unresolved audit selection" unless %w[valid invalid].include?(verdict) && record.fetch("timing_review_required") == false
      raise "Audit selection flag differs" unless record.fetch("timing_fix_required") == (verdict == "invalid")
    end
    ids = resolved.values.select { |record| record.fetch("timing_fix_required") }.map { |record| record.fetch("program_id") }.sort
    raise "Audit correction selection differs" unless ids == selection.fetch("correction_ids")
    [selection, resolved, ids]
  end

  def run(batch_dir:, proposal_root:, review_root:, adjudication_root:, final_root:, validation_run:, original_source:, audit_selection: nil)
    batch_dir = File.realpath(batch_dir)
    final_root = File.realpath(final_root)
    output = File.join(batch_dir, "timing-corrections")
    manifest_path = File.join(final_root, "manifest.yaml")
    manifest = YAML.safe_load_file(manifest_path, aliases: false)
    records_path = File.join(final_root, "corrections.jsonl")
    ids_path = File.join(final_root, "correction-ids.txt")
    raise "Final correction records changed" unless manifest.dig("artifacts", "corrections_jsonl_sha256") == TimingAudit.sha256_file(records_path)
    raise "Final correction IDs changed" unless manifest.dig("artifacts", "correction_ids_sha256") == TimingAudit.sha256_file(ids_path)
    prior_manifest = File.join(output, "final/manifest.yaml")
    raise "Refusing to replace a different correction campaign" if File.file?(prior_manifest) && TimingAudit.sha256_file(prior_manifest) != TimingAudit.sha256_file(manifest_path)
    records = TimingAudit.load_jsonl(records_path)
    by_id = records.to_h { |record| [record.fetch("program_id"), record] }
    if audit_selection
      selection, decisions, audit_ids = resolved_audit_selection(batch_dir, audit_selection)
      raise "Audit selection source revision differs" unless selection.fetch("source_commit") == manifest.dig("original_source", "commit")
      records.each do |record|
        raise "Correction/audit source differs" unless record.dig("original_source", "digest") == decisions.fetch(record.fetch("program_id")).fetch("source_digest")
      end
    else
      audit_ids = File.readlines(File.join(batch_dir, "timing-audit/primary/final/correction-ids.txt"), chomp: true)
    end
    validation_manifest = LocalEvaluation::Manifest.new(validation_run)
    validation_results = LocalEvaluation.load_yaml(File.join(validation_run, "validation/all_validation_results.yaml"), permitted_classes: [ValidationResult])
    validate_registry!(manifest, records, audit_ids, validation_manifest, validation_results)
    raise "Final ID sidecar differs" unless File.readlines(ids_path, chomp: true).sort == audit_ids.sort
    TimingAudit::SourceRepository.new(root: original_source, commit: manifest.dig("original_source", "commit"))

    roots = { "proposals" => File.realpath(proposal_root), "postfix-review" => File.realpath(review_root), "adjudication" => File.realpath(adjudication_root) }
    stages = roots.to_h do |label, root|
      inventory = TimingAudit.load_jsonl(File.join(root, "inventory.jsonl"))
      directory = label == "proposals" ? "proposals" : "results"
      validator = case label
      when "proposals" then TimingFix::ProposalValidator.new(inventory, original_source)
      when "postfix-review" then TimingFixReview::ResultValidator.new(inventory)
      else TimingFixAdjudication::ResultValidator.new(inventory)
      end
      results = inventory.map do |record|
        id = record.fetch("id")
        path = File.join(root, directory, "#{id}.json")
        result = JSON.parse(File.read(path))
        validator.validate!(result, expected_id: id)
        TimingFixEvidence.verify_response!(root, id, result, record)
        registry_key = { "proposals" => "proposal", "postfix-review" => "postfix_review", "adjudication" => "adjudication" }.fetch(label)
        raise "Correction registry differs from #{label} evidence for #{id}" unless by_id.fetch(id).fetch(registry_key).fetch("sha256") == TimingAudit.sha256_file(path)
        if record.key?("corrected_source_digest")
          raise "Corrected source digest differs from review" unless record.fetch("corrected_source_digest") == by_id.fetch(id).dig("corrected_source", "digest")
        end
        result
      end
      raise "Incomplete #{label} inventory" if label != "adjudication" && results.map { |result| result.fetch("program_id") }.sort != audit_ids.sort
      [label, { root: root, results: results }]
    end
    expected_adjudications = stages.fetch("postfix-review").fetch(:results).select { |result| result.fetch("verdict") != "accept" || result.fetch("confidence") != "high" }.map { |result| result.fetch("program_id") }.sort
    raise "Disputed review coverage differs" unless stages.fetch("adjudication").fetch(:results).map { |result| result.fetch("program_id") }.sort == expected_adjudications
    raise "Unaccepted adjudication" unless stages.fetch("adjudication").fetch(:results).all? { |result| result.fetch("final_verdict") == "accept" }
    proposals_by_id = stages.fetch("proposals").fetch(:results).to_h { |result| [result.fetch("program_id"), result] }
    %w[postfix-review adjudication].each do |label|
      verify_snapshot_reconstruction!(stages.fetch(label).fetch(:root), proposals_by_id)
    end

    copy = lambda { |source, relative| TimingAudit.atomic_write(File.join(output, relative), File.binread(source)) }
    stages.each do |label, stage|
      root = stage.fetch(:root)
      %w[manifest.yaml inventory.jsonl trial-ids.txt prompt-template.txt proposal-schema.json result-schema.json
         runner-snapshot.rb static-evidence-snapshot.rb summary-trial.jsonl summary-full.jsonl summary-full.csv
         platform-context.txt environment-evidence.yaml campaign.md pilot-review.md].each do |name|
        path = File.join(root, name)
        copy.call(path, "#{label}/#{name}") if File.file?(path)
      end
      TimingAudit.atomic_write(File.join(output, label, "results.jsonl"), TimingAudit.dump_jsonl(stage.fetch(:results)))
      attempts = Dir[File.join(root, "logs/*/attempt-*/metadata.yaml")].sort.map { |path| YAML.safe_load_file(path, aliases: false) }
      TimingAudit.atomic_write(File.join(output, label, "attempts.jsonl"), TimingAudit.dump_jsonl(attempts))
    end
    # Exact proposals are stored once. Review manifests bind the original snapshot
    # digest; this small recipe reconstructs the omitted, otherwise duplicate file.
    TimingAudit.atomic_write(File.join(output, "proposal-snapshot-reconstruction.json"), JSON.pretty_generate({
      "source" => "proposals/results.jsonl", "entry" => { "program_id" => "proposal.program_id",
        "proposal_file_sha256" => "SHA256(JSON.pretty_generate(proposal) + newline)", "proposal" => "proposal" },
      "ordering" => "each review stage inventory order; TimingAudit.dump_jsonl(entries)" }) + "\n")
    %w[summary-trial.yaml summary-full.yaml].each do |name|
      path = File.join(proposal_root, "materialized", name)
      copy.call(path, "materialization/#{name}") if File.file?(path)
    end
    compiles = Dir[File.join(proposal_root, "compile/*/*/metadata.yaml")].sort.map do |path|
      record = YAML.safe_load_file(path, aliases: false)
      record["scope"] = File.basename(File.dirname(File.dirname(path)))
      record["log_sha256"] = Dir[File.join(File.dirname(path), "*.log")].sort.to_h { |log| [File.basename(log), TimingAudit.sha256_file(log)] }
      record["failure_logs"] = Dir[File.join(File.dirname(path), "*.log")].sort.to_h { |log| [File.basename(log), File.read(log)] } unless record["success"]
      record
    end
    TimingAudit.atomic_write(File.join(output, "materialization/compile-records.jsonl"), TimingAudit.dump_jsonl(compiles))
    Dir[File.join(final_root, "*")].sort.each { |path| copy.call(path, "final/#{File.basename(path)}") if File.file?(path) }

    ValidationAuditExport.run(run_dir: validation_run, output_dir: File.join(output, "revalidation"))
    original_validations = TimingAudit.load_jsonl(File.join(batch_dir, "validation/records.jsonl")).to_h { |record| [record.fetch("id"), record] }
    validation_comparisons = TimingAudit.load_jsonl(File.join(output, "revalidation/validation/records.jsonl")).map do |record|
      id = record.fetch("id")
      original = original_validations.fetch(id)
      raise "Original validation uses another revision" unless original.fetch("source_commit") == manifest.dig("original_source", "commit")
      { "program_id" => id }.merge(compare_numerical_outputs(
        original.fetch("logs").fetch("validation_out_stdout.log"),
        record.fetch("logs").fetch("validation_out_stdout.log")))
    end
    TimingAudit.atomic_write(File.join(output, "validation-comparison.jsonl"), TimingAudit.dump_jsonl(validation_comparisons))
    method_layout = {}
    method_root = File.expand_path("..", __dir__)
    %w[lib/timing_audit.rb lib/timing_fix.rb lib/timing_fix_evidence.rb lib/timing_fix_review.rb
       lib/timing_fix_adjudication.rb lib/timing_fix_materializer.rb lib/timing_fix_finalize.rb
       bin/timing_fix.rb bin/timing_fix_review.rb bin/timing_fix_adjudication.rb
       bin/timing_fix_materialize.rb bin/timing_fix_finalize.rb bin/export_timing_corrections.rb
       bin/export_validation_audit.rb prompts/timing_fix_prompt.txt prompts/timing_fix_review_prompt.txt
       prompts/timing_fix_adjudication_prompt.txt schemas/timing_fix_schema.json
       schemas/timing_fix_review_schema.json schemas/timing_fix_adjudication_schema.json].each do |relative|
      stored = "method/#{relative.tr('/', '-')}"
      copy.call(File.join(method_root, relative), stored)
      method_layout[stored] = "tools/timing_audit/#{relative}"
    end
    TimingAudit.atomic_write(File.join(output, "method/layout.json"), JSON.pretty_generate(method_layout) + "\n")
    summary = { "records" => records.size, "timing_fixed" => records.size,
      "original_source_commit" => manifest.dig("original_source", "commit"),
      "corrected_source_commit" => manifest.dig("corrected_source", "commit"),
      "revalidation_passed" => validation_results.size, "benchmarking_performed" => false,
      "numerical_results_identical" => validation_comparisons.count { |record| record.fetch("numerical_results_identical") },
      "numerical_results_differing_ids" => validation_comparisons.reject { |record| record.fetch("numerical_results_identical") }.map { |record| record.fetch("program_id") },
      "originals_preserved_in_git" => true, "correction_manifest_sha256" => TimingAudit.sha256_file(manifest_path) }
    if audit_selection
      summary["audit_selection"] = File.realpath(audit_selection).delete_prefix(batch_dir + "/")
      summary["audit_selection_sha256"] = TimingAudit.sha256_file(audit_selection)
    end
    TimingAudit.atomic_write(File.join(output, "summary.json"), JSON.pretty_generate(summary) + "\n")
    TimingAudit.atomic_write(File.join(output, "README.md"), <<~README)
      # Timing-only corrections: #{validation_manifest.data.fetch("batches").join(", ")}

      #{records.size} accepted corrections; all #{validation_results.size} corrected programs passed
      the unchanged five-stage validation. No performance benchmark was run.
      The original validation, audit findings and historical scored release remain intact.
      See [the correction report](final/report.md) and [registry](final/corrections.jsonl).

      Original source commit: `#{summary.fetch("original_source_commit")}`.
      Corrected source commit: `#{summary.fetch("corrected_source_commit")}`.
      Every registry entry uses the established `timing_fixed`, `original_source_url`,
      `corrected_source_url`, original/corrected commit/digest and issue-category fields.
      These join by `program_id` to future benchmark exports; the existing website
      already displays both commit-pinned source links for timing-corrected runs.
      This batch is not yet merged into website performance results. Publishing the
      corrected commit and integrating benchmark/scoring data remain separate steps.

      Exact proposals, independent decisions, compile outcomes, validation outputs,
      method snapshots and compact attempt metadata are retained. Raw agent streams,
      binaries, build trees, full generated sources and reproducible aggregate patches
      are omitted. `proposal-snapshot-reconstruction.json` describes reconstruction
      of omitted duplicate proposal snapshots; original manifests retain their hashes.
      `method/layout.json` maps stored snapshots to their experiment-repository paths.
      `validation-comparison.jsonl` additionally compares the exact numerical result
      blocks with the original validation, excluding timing and performance output.
      Byte identity is supplementary evidence, not a replacement for the unchanged
      numerical validation criteria.
    README
    parent_summary_path = File.join(batch_dir, "summary.json")
    parent_summary = JSON.parse(File.read(parent_summary_path))
    parent_summary["timing_corrections"] = summary
    TimingAudit.atomic_write(parent_summary_path, JSON.pretty_generate(parent_summary) + "\n")
    parent_readme_path = File.join(batch_dir, "README.md")
    parent_readme = File.read(parent_readme_path)
    unless parent_readme.include?("## Timing-only corrections")
      TimingAudit.atomic_write(parent_readme_path, parent_readme + "\n## Timing-only corrections\n\n#{records.size} programs now have accepted, revalidated timing-only corrections.\nBoth original and corrected Git revisions are retained in the\n[correction registry and report](timing-corrections/README.md).\nNo performance benchmarking has been performed.\n")
    end
    checksum_tree(output)
    checksum_tree(batch_dir)
    paths = Dir[File.join(output, "**", "*")].select { |path| File.file?(path) }
    puts JSON.pretty_generate(summary.merge("files" => paths.size, "bytes" => paths.sum { |path| File.size(path) }))
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |opts|
    opts.on("--batch-dir=PATH") { |value| options[:batch_dir] = value }
    opts.on("--proposals=PATH") { |value| options[:proposal_root] = value }
    opts.on("--review=PATH") { |value| options[:review_root] = value }
    opts.on("--adjudication=PATH") { |value| options[:adjudication_root] = value }
    opts.on("--final=PATH") { |value| options[:final_root] = value }
    opts.on("--validation-run=PATH") { |value| options[:validation_run] = value }
    opts.on("--original-source=PATH") { |value| options[:original_source] = value }
    opts.on("--audit-selection=PATH") { |value| options[:audit_selection] = value }
  end.parse!(ARGV)
  required = %i[batch_dir proposal_root review_root adjudication_root final_root validation_run original_source]
  abort "Missing correction export paths" unless ARGV.empty? && required.all? { |key| options[key] }
  TimingCorrectionExport.run(**options)
end
