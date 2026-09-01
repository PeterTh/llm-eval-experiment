#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "json"
require "optparse"
require "yaml"
require_relative "../lib/timing_audit"

module TimingPriorityReview
  module_function

  def selected_records(main_root)
    inventory = TimingAudit.load_jsonl(File.join(main_root, "inventory.jsonl"))
    inventory_by_id = inventory.to_h { |record| [record.fetch("id"), record] }
    CSV.read(File.join(main_root, "summary-full.csv"), headers: true).filter_map do |row|
      categories = row.fetch("issue_categories").split(";")
      reasons = []
      if row.fetch("verdict") == "invalid"
        reasons << "competitive_invalid" if row.fetch("overall_score").to_i >= 9
        standard_local = categories.include?("missing_rank_aggregation") &&
                         categories.include?("rank_local_timing")
        reasons << "nonstandard_invalid" unless standard_local
      elsif row.fetch("verdict") == "valid" &&
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
        "overall_score" => row.fetch("overall_score").to_i
      }
    end.sort_by { |record| record.fetch("program_id") }
  end

  def prepare(main_root:, output_dir:)
    main_root = File.realpath(main_root)
    raise "Output already exists: #{output_dir}" if File.exist?(output_dir)

    manifest = YAML.safe_load(File.read(File.join(main_root, "manifest.yaml")), aliases: false)
    generated = manifest.fetch("generated_source")
    TimingAudit::InventoryBuilder.new(
      release_root: manifest.fetch("release_root"),
      source_root: generated.fetch("root"),
      output_dir: output_dir,
      trial_size: TimingAudit::DEFAULT_TRIAL_SIZE
    ).run

    selection = selected_records(main_root)
    TimingAudit.atomic_write(
      File.join(output_dir, "priority-selection.jsonl"),
      TimingAudit.dump_jsonl(selection)
    )
    TimingAudit.atomic_write(
      File.join(output_dir, "priority-ids.txt"),
      selection.map { |record| record.fetch("program_id") }.join("\n") + "\n"
    )

    review_manifest_path = File.join(output_dir, "manifest.yaml")
    review_manifest = YAML.safe_load(File.read(review_manifest_path), aliases: false)
    review_manifest["independent_priority_review"] = {
      "parent_root" => main_root,
      "parent_manifest_sha256" => TimingAudit.sha256_file(File.join(main_root, "manifest.yaml")),
      "parent_summary_sha256" => TimingAudit.sha256_file(File.join(main_root, "summary-full.csv")),
      "selection" => {
        "competitive_invalid_minimum_score" => 9,
        "all_nonstandard_invalid" => true,
        "semantic_equivalence_valid_controls" => true,
        "records" => selection.size
      }
    }
    TimingAudit.atomic_write(review_manifest_path, YAML.dump(review_manifest))
    puts "Prepared independent priority review: #{selection.size} records"
  end

  def run(output_dir:, jobs:, retries: TimingAudit::DEFAULT_RETRIES)
    ids = File.readlines(File.join(output_dir, "priority-ids.txt"), chomp: true).reject(&:empty?)
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

    comparisons = selection.map do |selected|
      id = selected.fetch("program_id")
      first = JSON.parse(File.read(File.join(main_root, "results", "#{id}.json")))
      second = JSON.parse(File.read(File.join(review_root, "results", "#{id}.json")))
      validator.validate!(second, expected_id: id)
      {
        "program_id" => id,
        "reasons" => selected.fetch("reasons"),
        "overall_score" => selected.fetch("overall_score"),
        "first_verdict" => first.fetch("verdict"),
        "second_verdict" => second.fetch("verdict"),
        "verdict_agreement" => first.fetch("verdict") == second.fetch("verdict"),
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
    headers = comparisons.first.keys
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
end

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
else
  abort <<~USAGE
    Usage:
      ruby tools/timing_audit/bin/timing_priority_review.rb prepare --main=PATH --output=PATH
      ruby tools/timing_audit/bin/timing_priority_review.rb run --output=PATH [--jobs=N] [--retries=N]
      ruby tools/timing_audit/bin/timing_priority_review.rb compare --main=PATH --review=PATH
  USAGE
end
