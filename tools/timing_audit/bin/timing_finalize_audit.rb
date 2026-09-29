#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "json"
require "optparse"
require "yaml"
require_relative "../lib/timing_audit"

module TimingFinalizeAudit
  MANUAL_SCOPE_OVERRIDES = {
    "qtclustering_qwen-3.6-27B-udq4_mpi_r2" => {
      "final_verdict" => "invalid",
      "final_issue_categories" => %w[missing_rank_aggregation rank_local_timing],
      "rationale" => "The timing defect is the unaggregated root-local duration. The separately reported bool/MPI_INT broadcast mismatch is outside the timing-only audit and correction scope."
    }
  }.freeze

  module_function

  def load_results(root)
    Dir[File.join(root, "results", "*.json")].to_h do |path|
      result = JSON.parse(File.read(path))
      [result.fetch("program_id"), result]
    end
  end

  def run(main_root:, priority_root:, adjudication_root:, supplemental_root: nil)
    main_root = File.realpath(main_root)
    priority_root = File.realpath(priority_root)
    adjudication_root = File.realpath(adjudication_root)
    records = TimingAudit.load_jsonl(File.join(main_root, "inventory.jsonl"))
    records_by_id = records.to_h { |record| [record.fetch("id"), record] }
    validator = TimingAudit::ResultValidator.new(records)
    primary = load_results(main_root)
    priority = load_results(priority_root)
    adjudication = load_results(adjudication_root)
    raise "Primary result ID mismatch" unless primary.keys.sort == records_by_id.keys.sort
    manifest = YAML.safe_load_file(File.join(main_root, "manifest.yaml"), aliases: false)
    validation_only = manifest.dig("selection", "basis") == "validation_only"
    priority_ids = TimingAudit.load_jsonl(File.join(priority_root, "priority-selection.jsonl")).map { |r| r.fetch("program_id") }
    raise "Independent review ID mismatch" unless priority.keys.sort == priority_ids.sort

    primary.each { |id, result| validator.validate!(result, expected_id: id) }
    priority.each { |id, result| validator.validate!(result, expected_id: id) }
    adjudication.each { |id, result| validator.validate!(result, expected_id: id) }

    disagreements = priority.keys.select do |id|
      TimingAudit.adjudication_required?(primary.fetch(id), priority.fetch(id), include_uncertain: validation_only)
    end.sort
    unless disagreements == adjudication.keys.sort
      raise "Adjudication IDs do not exactly match disagreements and unresolved uncertainty"
    end

    supplemental = {}
    supplemental_reasons = {}
    if supplemental_root
      supplemental_root = File.realpath(supplemental_root)
      supplemental_manifest = YAML.safe_load_file(File.join(supplemental_root, "manifest.yaml"), aliases: false)
      provenance = supplemental_manifest.fetch("supplemental_adjudication")
      raise "Supplemental parent manifest mismatch" unless provenance.fetch("parent_manifest_sha256") == TimingAudit.sha256_file(File.join(main_root, "manifest.yaml"))
      selection_path = File.join(supplemental_root, "supplemental-selection.jsonl")
      raise "Supplemental selection changed" unless provenance.fetch("selection_sha256") == TimingAudit.sha256_file(selection_path)
      selection = TimingAudit.load_jsonl(selection_path)
      supplemental_reasons = selection.to_h { |row| [row.fetch("program_id"), row.fetch("reason")] }
      supplemental = load_results(supplemental_root)
      raise "Supplemental result ID mismatch" unless selection.size == supplemental_reasons.size && supplemental.keys.sort == supplemental_reasons.keys.sort
      TimingAudit::AuditVerifier.new(supplemental_root, "full").run
      TimingAudit.load_jsonl(File.join(supplemental_root, "inventory.jsonl")).each do |record|
        raise "Supplemental source mismatch" unless record.fetch("source_digest") == records_by_id.fetch(record.fetch("id")).fetch("source_digest")
      end
      supplemental.each { |id, result| validator.validate!(result, expected_id: id) }
    end

    decisions = records.map do |record|
      id = record.fetch("id")
      first = primary.fetch(id)
      second = priority[id]
      third = adjudication[id]
      fourth = supplemental[id]
      chosen = fourth || third || first
      basis = if fourth
        "supplemental_sol_adjudication"
      elsif third
        "sol_adjudication"
      elsif second
        raise "Unadjudicated verdict disagreement for #{id}" unless first.fetch("verdict") == second.fetch("verdict")
        "independent_luna_agreement"
      else
        "primary_luna_review"
      end

      final_verdict = chosen.fetch("verdict")
      final_categories = chosen.fetch("issue_categories")
      manual = MANUAL_SCOPE_OVERRIDES[id]
      if manual
        raise "Manual scope override changes verdict unexpectedly" unless final_verdict == manual.fetch("final_verdict")
        final_categories = manual.fetch("final_issue_categories")
        basis = "#{basis}+manual_scope_clarification"
      end

      {
        "program_id" => id,
        "benchmark" => record.fetch("benchmark"),
        "model" => record.fetch("model"),
        "par_type" => record.fetch("par_type"),
        "run" => record.fetch("run"),
        "overall_score" => record.fetch("overall_score"),
        "benchmark_median_time_ms" => record.fetch("benchmark_median_time_ms"),
        "source_tree_oid" => record.fetch("source_tree_oid"),
        "source_digest" => record.fetch("source_digest"),
        "primary_verdict" => first.fetch("verdict"),
        "priority_verdict" => second&.fetch("verdict"),
        "adjudication_verdict" => third&.fetch("verdict"),
        "supplemental_verdict" => fourth&.fetch("verdict"),
        "supplemental_reason" => supplemental_reasons[id],
        "final_verdict" => final_verdict,
        "decision_basis" => basis,
        "final_issue_categories" => final_categories,
        "timing_fix_required" => final_verdict == "ambiguous" ? nil : final_verdict == "invalid",
        "timing_review_required" => final_verdict == "ambiguous",
        "final_confidence" => chosen.fetch("confidence"),
        "timing_only_fix_possible" => chosen.fetch("timing_only_fix_possible"),
        "minimal_fix" => chosen.fetch("minimal_fix"),
        "semantic_equivalence_basis" => chosen.fetch("semantic_equivalence_basis"),
        "notes" => chosen.fetch("notes"),
        "evidence" => chosen.fetch("evidence"),
        "manual_scope_rationale" => manual&.fetch("rationale")
      }
    end

    final_dir = File.join(main_root, "final")
    TimingAudit.atomic_write(File.join(final_dir, "decisions.jsonl"), TimingAudit.dump_jsonl(decisions))
    headers = decisions.first&.keys || %w[program_id final_verdict]
    csv = CSV.generate do |output|
      output << headers
      decisions.each do |entry|
        output << headers.map do |header|
          value = entry.fetch(header)
          value.is_a?(Array) ? (value.any? { |item| item.is_a?(Hash) } ? JSON.generate(value) : value.join(";")) : value
        end
      end
    end
    TimingAudit.atomic_write(File.join(final_dir, "decisions.csv"), csv)
    correction_ids = decisions.select { |entry| entry.fetch("timing_fix_required") }
                              .map { |entry| entry.fetch("program_id") }
    TimingAudit.atomic_write(File.join(final_dir, "correction-ids.txt"), correction_ids.join("\n") + "\n")
    TimingAudit.atomic_write(
      File.join(final_dir, "manual-scope-overrides.yaml"),
      YAML.dump(MANUAL_SCOPE_OVERRIDES.select { |id, _| records_by_id.key?(id) })
    )

    counts = decisions.group_by { |entry| entry.fetch("final_verdict") }.transform_values(&:size)
    metadata = {
      "created_at" => TimingAudit.utc_now,
      "records" => decisions.size,
      "final_verdict_counts" => TimingAudit::VERDICTS.to_h { |verdict| [verdict, counts.fetch(verdict, 0)] },
      "timing_fixes_required" => correction_ids.size,
      "roots" => {
        "primary" => main_root,
        "priority_review" => priority_root,
        "adjudication" => adjudication_root
      },
      "artifact_hashes" => {
        "primary_manifest_sha256" => TimingAudit.sha256_file(File.join(main_root, "manifest.yaml")),
        "primary_summary_sha256" => TimingAudit.sha256_file(File.join(main_root, "summary-full.csv")),
        "priority_manifest_sha256" => TimingAudit.sha256_file(File.join(priority_root, "manifest.yaml")),
        "priority_comparison_sha256" => TimingAudit.sha256_file(File.join(priority_root, "comparison.csv")),
        "adjudication_manifest_sha256" => TimingAudit.sha256_file(File.join(adjudication_root, "manifest.yaml")),
        "finalizer_sha256" => TimingAudit.sha256_file(File.expand_path(__FILE__))
      },
      "decision_policy" => {
        "primary" => validation_only ? "Luna high static review of all validation-passing MPI/hybrid programs" : "Luna high static review of all successful MPI/hybrid measurements",
        "priority" => validation_only ? "Independent Luna high review of all invalid, ambiguous, non-high-confidence, and semantic-equivalence cases" : "Independent Luna high review of score >= 9 invalids, nonstandard invalids, and semantic-equivalence controls",
        "disagreements" => "Blind Sol xhigh static adjudication of disagreements and selected unresolved uncertainty",
        "manual_scope" => "Remove only unrelated non-timing findings; never change the timing verdict",
        "ambiguous" => "Retain unresolved conditions; timing_fix_required is null and timing_review_required is true"
      }
    }
    if supplemental_root
      metadata["roots"]["supplemental_adjudication"] = supplemental_root
      metadata["artifact_hashes"]["supplemental_manifest_sha256"] = TimingAudit.sha256_file(File.join(supplemental_root, "manifest.yaml"))
      metadata["decision_policy"]["supplemental"] = "Explicitly selected blind Sol xhigh review after source-grounded final checks; retain all earlier verdicts and selection reasons"
    end
    TimingAudit.atomic_write(File.join(final_dir, "metadata.yaml"), YAML.dump(metadata))

    puts "Finalized #{decisions.size} decisions: #{TimingAudit::VERDICTS.map { |v| "#{v}=#{counts.fetch(v, 0)}" }.join(', ')}"
    puts "Timing corrections required: #{correction_ids.size}"
  end
end

if $PROGRAM_NAME == __FILE__
  options = { main_root: nil, priority_root: nil, adjudication_root: nil }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/timing_finalize_audit.rb --main=PATH --priority=PATH --adjudication=PATH"
    opts.on("--main=PATH") { |value| options[:main_root] = value }
    opts.on("--priority=PATH") { |value| options[:priority_root] = value }
    opts.on("--adjudication=PATH") { |value| options[:adjudication_root] = value }
    opts.on("--supplemental=PATH") { |value| options[:supplemental_root] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && options.values.all?
  TimingFinalizeAudit.run(**options)
end
