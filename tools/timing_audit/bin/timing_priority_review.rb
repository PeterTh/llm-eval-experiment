#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "json"
require "optparse"
require "yaml"
require_relative "../lib/timing_audit"

module TimingPriorityReview
  module_function

  def add_platform_context(output_dir, context_path)
    return unless context_path
    context = File.read(context_path)
    path = File.join(output_dir, "manifest.yaml")
    manifest = YAML.safe_load_file(path, aliases: false)
    prompt_path = File.join(output_dir, "prompt-template.txt")
    prompt = File.read(prompt_path).sub("SOURCE DOSSIER\n", "STATIC TARGET-PLATFORM EVIDENCE\n\n#{context}\nSOURCE DOSSIER\n")
    TimingAudit.atomic_write(File.join(output_dir, "platform-context.txt"), context)
    TimingAudit.atomic_write(prompt_path, prompt)
    manifest["platform_context"] = { "sha256" => TimingAudit.sha256_bytes(context), "source" => File.expand_path(context_path) }
    manifest["artifacts"]["prompt_template_sha256"] = TimingAudit.sha256_bytes(prompt)
    TimingAudit.atomic_write(path, YAML.dump(manifest))
  end

  # A source-grounded final check may identify a missed platform assumption even
  # when earlier reviewers agreed. Preserve their results and freeze a separate,
  # explicitly selected blind adjudication rather than replacing any evidence.
  def prepare_supplemental(main_root:, output_dir:, selection_path:, context_path:)
    main_root = File.realpath(main_root)
    selection = TimingAudit.load_jsonl(selection_path)
    ids = selection.map { |row| row.fetch("program_id") }
    raise "Supplemental selection must be nonempty and unique" if ids.empty? || ids.uniq != ids
    raise "Supplemental selection requires reasons" unless selection.all? { |row| row["reason"].is_a?(String) && !row["reason"].strip.empty? }
    TimingAudit.derive_inventory(parent_root: main_root, output_dir: output_dir, ids: ids, provenance: {
      "supplemental_adjudication" => {
        "parent_root" => main_root,
        "parent_manifest_sha256" => TimingAudit.sha256_file(File.join(main_root, "manifest.yaml")),
        "selection_sha256" => TimingAudit.sha256_file(selection_path),
        "model" => "gpt-5.6-sol", "effort" => "xhigh", "records" => ids.size
      }
    })
    TimingAudit.atomic_write(File.join(output_dir, "supplemental-selection.jsonl"), File.read(selection_path))
    add_equivalence_review_guidance(output_dir)
    add_platform_context(output_dir, context_path)
    puts "Prepared #{ids.size} supplemental blind adjudications"
  end

  def add_equivalence_review_guidance(output_dir)
    path = File.join(output_dir, "manifest.yaml")
    manifest = YAML.safe_load_file(path, aliases: false)
    return unless manifest.dig("selection", "basis") == "validation_only"
    guidance = File.read(File.expand_path("../prompts/timing_equivalence_review.txt", __dir__))
    template_path = File.join(output_dir, "prompt-template.txt")
    template = File.read(template_path)
    marker = "SOURCE DOSSIER\n"
    raise "Missing source dossier marker" unless template.include?(marker)
    updated = template.sub(marker, "INDEPENDENT SEMANTIC-EQUIVALENCE CHECK\n\n#{guidance}\n#{marker}")
    manifest["review_guidance"] = {
      "reason" => "Pilot quality review: explicitly trace root-controlled work-start dependencies",
      "parent_prompt_sha256" => TimingAudit.sha256_bytes(template),
      "guidance_sha256" => TimingAudit.sha256_bytes(guidance)
    }
    TimingAudit.atomic_write(template_path, updated)
    TimingAudit.atomic_write(File.join(output_dir, "review-guidance.txt"), guidance)
    manifest["artifacts"]["prompt_template_sha256"] = TimingAudit.sha256_bytes(updated)
    # Match the existing validator's citation syntax at generation time, rather
    # than paying for retries when a model combines disjoint ranges in one entry.
    schema_path = File.join(output_dir, "result-schema.json")
    schema = JSON.parse(File.read(schema_path))
    schema.fetch("properties").fetch("evidence").fetch("items").fetch("properties").fetch("lines")["pattern"] = "^[1-9][0-9]*(-[1-9][0-9]*)?$"
    TimingAudit.atomic_write(schema_path, JSON.pretty_generate(schema) + "\n")
    manifest["artifacts"]["result_schema_sha256"] = TimingAudit.sha256_file(schema_path)
    TimingAudit.atomic_write(path, YAML.dump(manifest))
  end

  def selected_records(main_root)
    manifest = YAML.safe_load_file(File.join(main_root, "manifest.yaml"), aliases: false)
    validation_only = manifest.dig("selection", "basis") == "validation_only"
    inventory = TimingAudit.load_jsonl(File.join(main_root, "inventory.jsonl"))
    inventory_by_id = inventory.to_h { |record| [record.fetch("id"), record] }
    CSV.read(File.join(main_root, "summary-full.csv"), headers: true).filter_map do |row|
      categories = row.fetch("issue_categories").split(";")
      reasons = []
      if validation_only
        reasons << "invalid" if row.fetch("verdict") == "invalid"
        reasons << "ambiguous" if row.fetch("verdict") == "ambiguous"
        reasons << "not_high_confidence" if row.fetch("confidence") != "high"
      elsif row.fetch("verdict") == "invalid"
        reasons << "competitive_invalid" if row.fetch("overall_score").to_i >= 9
        standard_local = categories.include?("missing_rank_aggregation") &&
                         categories.include?("rank_local_timing")
        reasons << "nonstandard_invalid" unless standard_local
      end
      if row.fetch("verdict") == "valid" &&
            !inventory_by_id.fetch(row.fetch("program_id")).fetch("static_features").fetch("has_mpi_max")
        reasons << "semantic_equivalence_valid_control"
      end
      next if reasons.empty?

      {
        "program_id" => row.fetch("program_id"),
        "reasons" => reasons,
        "first_verdict" => row.fetch("verdict"),
        "first_confidence" => row.fetch("confidence"),
        "first_issue_categories" => categories,
        "overall_score" => row["overall_score"] && Integer(row["overall_score"])
      }
    end.sort_by { |record| record.fetch("program_id") }
  end

  def prepare(main_root:, output_dir:)
    main_root = File.realpath(main_root)
    raise "Output already exists: #{output_dir}" if File.exist?(output_dir)

    manifest = YAML.safe_load(File.read(File.join(main_root, "manifest.yaml")), aliases: false)
    selection = selected_records(main_root)
    validation_only = manifest.dig("selection", "basis") == "validation_only"
    policy = if validation_only
      { "all_invalid" => true, "all_ambiguous" => true, "all_non_high_confidence" => true,
        "semantic_equivalence_valid_controls" => true, "records" => selection.size }
    else
      { "competitive_invalid_minimum_score" => 9, "all_nonstandard_invalid" => true,
        "semantic_equivalence_valid_controls" => true, "records" => selection.size }
    end
    TimingAudit.derive_inventory(parent_root: main_root, output_dir: output_dir,
      ids: selection.map { |record| record.fetch("program_id") }, provenance: {
        "independent_priority_review" => {
          "parent_root" => main_root,
          "parent_manifest_sha256" => TimingAudit.sha256_file(File.join(main_root, "manifest.yaml")),
          "parent_summary_sha256" => TimingAudit.sha256_file(File.join(main_root, "summary-full.csv")),
          "selection" => policy
        }
      })
    add_equivalence_review_guidance(output_dir)
    TimingAudit.atomic_write(
      File.join(output_dir, "priority-selection.jsonl"),
      TimingAudit.dump_jsonl(selection)
    )
    TimingAudit.atomic_write(
      File.join(output_dir, "priority-ids.txt"),
      selection.map { |record| record.fetch("program_id") }.join("\n") + "\n"
    )

    puts "Prepared independent priority review: #{selection.size} records"
  end

  def run(output_dir:, jobs:, retries: TimingAudit::DEFAULT_RETRIES)
    ids = File.readlines(File.join(output_dir, "priority-ids.txt"), chomp: true).reject(&:empty?)
    return puts "No independent reviews required" if ids.empty?
    TimingAudit::AuditRunner.new(
      output_dir: output_dir,
      scope: "full",
      jobs: jobs,
      retries: retries,
      only_ids: ids
    ).run
  end

  def compare(main_root:, review_root:)
    main_root = File.realpath(main_root)
    review_root = File.realpath(review_root)
    selection = TimingAudit.load_jsonl(File.join(review_root, "priority-selection.jsonl"))
    review_inventory = TimingAudit.load_jsonl(File.join(review_root, "inventory.jsonl"))
    validator = TimingAudit::ResultValidator.new(review_inventory)
    manifest = YAML.safe_load_file(File.join(main_root, "manifest.yaml"), aliases: false)
    validation_only = manifest.dig("selection", "basis") == "validation_only"

    comparisons = selection.map do |selected|
      id = selected.fetch("program_id")
      first = JSON.parse(File.read(File.join(main_root, "results", "#{id}.json")))
      second = JSON.parse(File.read(File.join(review_root, "results", "#{id}.json")))
      validator.validate!(first, expected_id: id)
      validator.validate!(second, expected_id: id)
      {
        "program_id" => id,
        "reasons" => selected.fetch("reasons"),
        "overall_score" => selected.fetch("overall_score"),
        "first_verdict" => first.fetch("verdict"),
        "second_verdict" => second.fetch("verdict"),
        "verdict_agreement" => first.fetch("verdict") == second.fetch("verdict"),
        "adjudication_required" => TimingAudit.adjudication_required?(first, second, include_uncertain: validation_only),
        "first_confidence" => first.fetch("confidence"),
        "second_confidence" => second.fetch("confidence"),
        "first_issue_categories" => first.fetch("issue_categories"),
        "second_issue_categories" => second.fetch("issue_categories"),
        "first_timing_only_fix_possible" => first.fetch("timing_only_fix_possible"),
        "second_timing_only_fix_possible" => second.fetch("timing_only_fix_possible")
      }
    end

    TimingAudit.atomic_write(
      File.join(review_root, "comparison.jsonl"),
      TimingAudit.dump_jsonl(comparisons)
    )
    headers = comparisons.first&.keys || %w[program_id adjudication_required]
    csv = CSV.generate do |output|
      output << headers
      comparisons.each do |entry|
        output << headers.map do |header|
          value = entry.fetch(header)
          value.is_a?(Array) ? value.join(";") : value
        end
      end
    end
    TimingAudit.atomic_write(File.join(review_root, "comparison.csv"), csv)

    pairs = comparisons.group_by { |entry| [entry.fetch("first_verdict"), entry.fetch("second_verdict")] }
                       .transform_values(&:size)
    disagreements = comparisons.reject { |entry| entry.fetch("verdict_agreement") }
    puts "Compared #{comparisons.size} independent reviews"
    pairs.sort.each { |pair, count| puts "  #{pair.join(' -> ')}: #{count}" }
    puts "Verdict disagreements: #{disagreements.size}"
    disagreements.each { |entry| puts "  #{entry.fetch('program_id')}" }
  end

  def prepare_adjudication(main_root:, review_root:, output_dir:, context_path: nil)
    compare(main_root: main_root, review_root: review_root)
    comparison_path = File.join(review_root, "comparison.jsonl")
    ids = TimingAudit.load_jsonl(comparison_path).select { |row| row.fetch("adjudication_required") }
                     .map { |row| row.fetch("program_id") }.sort
    TimingAudit.derive_inventory(parent_root: main_root, output_dir: output_dir, ids: ids, provenance: {
      "blind_adjudication" => { "review_root" => File.realpath(review_root),
        "comparison_sha256" => TimingAudit.sha256_file(comparison_path),
        "model" => "gpt-5.6-sol", "effort" => "xhigh", "records" => ids.size }
    })
    add_equivalence_review_guidance(output_dir)
    add_platform_context(output_dir, context_path)
    puts "Prepared #{ids.size} blind adjudications"
  end
end

if $PROGRAM_NAME == __FILE__
command = ARGV.shift
case command
when "prepare"
  options = { main_root: nil, output_dir: nil }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/timing_priority_review.rb prepare --main=PATH --output=PATH"
    opts.on("--main=PATH") { |value| options[:main_root] = value }
    opts.on("--output=PATH") { |value| options[:output_dir] = File.expand_path(value) }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && options.values.all?
  TimingPriorityReview.prepare(**options)
when "run"
  options = { output_dir: nil, jobs: 16, retries: TimingAudit::DEFAULT_RETRIES }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/timing_priority_review.rb run --output=PATH [options]"
    opts.on("--output=PATH") { |value| options[:output_dir] = File.expand_path(value) }
    opts.on("--jobs=N", Integer) { |value| options[:jobs] = value }
    opts.on("--retries=N", Integer) { |value| options[:retries] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && options[:output_dir]
  TimingPriorityReview.run(**options)
when "compare"
  options = { main_root: nil, review_root: nil }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/timing_priority_review.rb compare --main=PATH --review=PATH"
    opts.on("--main=PATH") { |value| options[:main_root] = value }
    opts.on("--review=PATH") { |value| options[:review_root] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && options.values.all?
  TimingPriorityReview.compare(**options)
when "prepare-adjudication"
  options = {}
  parser = OptionParser.new do |opts|
    opts.on("--main=PATH") { |value| options[:main_root] = value }
    opts.on("--review=PATH") { |value| options[:review_root] = value }
    opts.on("--output=PATH") { |value| options[:output_dir] = File.expand_path(value) }
    opts.on("--context=PATH") { |value| options[:context_path] = File.expand_path(value) }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && %i[main_root output_dir review_root].all? { |key| options[key] }
  TimingPriorityReview.prepare_adjudication(**options)
when "prepare-supplemental"
  options = {}
  parser = OptionParser.new do |opts|
    opts.on("--main=PATH") { |value| options[:main_root] = value }
    opts.on("--output=PATH") { |value| options[:output_dir] = File.expand_path(value) }
    opts.on("--selection=PATH") { |value| options[:selection_path] = File.expand_path(value) }
    opts.on("--context=PATH") { |value| options[:context_path] = File.expand_path(value) }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && %i[main_root output_dir selection_path context_path].all? { |key| options[key] }
  TimingPriorityReview.prepare_supplemental(**options)
else
  abort <<~USAGE
    Usage:
      ruby tools/timing_audit/bin/timing_priority_review.rb prepare --main=PATH --output=PATH
      ruby tools/timing_audit/bin/timing_priority_review.rb run --output=PATH [--jobs=N] [--retries=N]
      ruby tools/timing_audit/bin/timing_priority_review.rb compare --main=PATH --review=PATH
      ruby tools/timing_audit/bin/timing_priority_review.rb prepare-adjudication --main=PATH --review=PATH --output=PATH [--context=PATH]
      ruby tools/timing_audit/bin/timing_priority_review.rb prepare-supplemental --main=PATH --output=PATH --selection=PATH --context=PATH
  USAGE
end
end
