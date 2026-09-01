#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "yaml"
require_relative "../../../lib/local_evaluation"

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/timing_audit/bin/timing_rerun_status.rb --run-dir=PATH [--baseline-full-results=PATH]"
  opts.on("--run-dir=PATH") { |value| options[:run_dir] = File.expand_path(value) }
  opts.on("--baseline-full-results=PATH") { |value| options[:baseline] = File.expand_path(value) }
end.parse!
abort "--run-dir is required" unless options[:run_dir]

run_dir = options.fetch(:run_dir)
manifest = LocalEvaluation::Manifest.new(run_dir)
correction = LocalEvaluation::SourceCorrectionAmendment.load(run_dir, manifest: manifest)
abort "Source correction amendment not found" unless correction
pipeline = LocalEvaluation::PipelineAmendment.load_chain(run_dir, manifest: manifest).last
abort "Pipeline amendment not found" unless pipeline
full_path = File.join(run_dir, "benchmark", BENCHMARK_FULL_RESULTS_FN)
full = File.file?(full_path) ? (LocalEvaluation.load_yaml(full_path) || {}) : {}

states = Hash.new { |hash, key| hash[key] = [] }
correction.affected_ids.each do |id|
  canonical = full[id]
  metadata_path = File.join(run_dir, "benchmark", id, "benchmark_metadata.yaml")
  metadata = File.file?(metadata_path) ? LocalEvaluation.load_yaml(metadata_path) : nil
  if !canonical
    states["pending"] << id
  elsif metadata.is_a?(Hash) && metadata["timing_fixed"] != true
    states["not_yet_rerun"] << id
  elsif !metadata.is_a?(Hash) ||
        metadata["source_correction_amendment_sha256"] != correction.digest ||
        metadata["pipeline_amendment_sha256"] != pipeline.digest ||
        metadata["success"] != canonical[0]
    states["stale_or_inconsistent"] << id
  elsif canonical[0] == true
    states["successful"] << id
  elsif canonical == [false, {}]
    states["failed"] << id
  else
    states["malformed"] << id
  end
end

unaffected_ids = full.keys - correction.affected_ids
unaffected = unaffected_ids.sort.to_h { |id| [id, full.fetch(id)] }
report = {
  "checked_at" => Time.now.iso8601,
  "correction_records" => correction.affected_ids.size,
  "completed" => states["successful"].size + states["failed"].size,
  "successful" => states["successful"].size,
  "failed" => states["failed"].size,
  "not_yet_rerun" => states["not_yet_rerun"].size,
  "pending" => states["pending"].size,
  "stale_or_inconsistent" => states["stale_or_inconsistent"].size,
  "malformed" => states["malformed"].size,
  "canonical_records_present" => full.size,
  "pipeline_amendment_sha256" => pipeline.digest,
  "source_correction_amendment_sha256" => correction.digest,
  "unaffected_records_present" => unaffected.size,
  "unaffected_records_sha256" => Digest::SHA256.hexdigest(JSON.generate(unaffected)),
  "local_temporary_workspaces" => Dir.glob("/tmp/local-evaluation-timing-correction-*").sort
}

if options[:baseline]
  baseline = LocalEvaluation.load_yaml(options.fetch(:baseline)) || {}
  baseline_unaffected = (baseline.keys - correction.affected_ids).sort.to_h { |id| [id, baseline.fetch(id)] }
  report["baseline_full_results"] = options.fetch(:baseline)
  report["baseline_unaffected_records"] = baseline_unaffected.size
  report["unaffected_matches_baseline"] = unaffected == baseline_unaffected
  report["baseline_unaffected_records_sha256"] = Digest::SHA256.hexdigest(JSON.generate(baseline_unaffected))
end

problems = %w[failed stale_or_inconsistent malformed].flat_map do |state|
  states[state].first(10).map { |id| { "state" => state, "id" => id } }
end
report["first_problems"] = problems unless problems.empty?
puts YAML.dump(report)
