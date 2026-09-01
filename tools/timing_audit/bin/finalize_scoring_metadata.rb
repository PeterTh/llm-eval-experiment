#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "optparse"
require "time"
require "yaml"

require_relative "../../../lib/local_evaluation"

class ScoringMetadataFinalizer
  def initialize(run_dir:, dry_run: false)
    @run_dir = File.expand_path(run_dir)
    @dry_run = dry_run
  end

  def run
    manifest = LocalEvaluation::Manifest.new(@run_dir)
    pipeline_amendment = LocalEvaluation::PipelineAmendment.load_chain(@run_dir, manifest: manifest).last
    source_correction = LocalEvaluation::SourceCorrectionAmendment.load(@run_dir, manifest: manifest)
    raise "source-correction amendment is required" unless source_correction

    aggregate_metadata_path = path("aggregate_metadata.yaml")
    aggregate_metadata = load_yaml(aggregate_metadata_path)
    verify_aggregate_metadata!(aggregate_metadata, manifest, pipeline_amendment, source_correction)

    review_path = path("local_scoring_threshold_review.yaml")
    review = load_yaml(review_path)
    raise "threshold review is not final" unless review.fetch("reviewed") == true
    verify_review_digests!(review, pipeline_amendment, source_correction)
    verify_thresholds_reviewed!

    rows = 0
    score_counts = Hash.new(0)
    CSV.foreach(path("scored_results.csv"), headers: true) do |row|
      score = Integer(row.fetch("overall_score"), 10)
      raise "overall score outside 0..10" unless (0..10).cover?(score)

      rows += 1
      score_counts[score] += 1
    end
    raise "scored record count does not match manifest" unless rows == manifest.runs.size

    metadata = {
      "schema_version" => 2,
      "canonical" => true,
      "generated_at" => Time.now.iso8601,
      "run_id" => File.basename(@run_dir),
      "pipeline_source_sha256" => pipeline_amendment.data.dig("amended_pipeline_source", "sha256"),
      "manifest_sha256" => LocalEvaluation.sha256_file(manifest.path),
      "pipeline_amendment_sha256" => pipeline_amendment.digest,
      "source_correction_amendment_sha256" => source_correction.digest,
      "benchmark_config_sha256" => sha256(path("benchmark_config.yaml")),
      "validation_results_sha256" => sha256(path("validation", "all_validation_results.yaml")),
      "benchmark_full_results_sha256" => sha256(path("benchmark", "benchmark_full_results.yaml")),
      "aggregate_metadata_sha256" => sha256(aggregate_metadata_path),
      "aggregate_results_sha256" => sha256(path("aggregate_results.yaml")),
      "distribution_sha256" => sha256(path("local_scoring_distributions.csv")),
      "thresholds_sha256" => sha256(path("local_scoring_thresholds.csv")),
      "threshold_review_sha256" => sha256(review_path),
      "scored_csv_sha256" => sha256(path("scored_results.csv")),
      "scored_yaml_sha256" => sha256(path("scored_results.yaml")),
      "record_count" => rows,
      "score_counts" => score_counts.sort.to_h,
      "thresholds_reviewed" => true,
      "timing_corrections" => source_correction.affected_ids.size
    }

    if @dry_run
      puts YAML.dump(metadata)
      return metadata
    end

    LocalEvaluation.atomic_yaml_with_digest(path("scoring_metadata.yaml"), metadata)
    puts "Wrote canonical scoring metadata for #{rows} records"
    metadata
  end

  private

  def verify_aggregate_metadata!(metadata, manifest, pipeline_amendment, source_correction)
    expected = {
      "manifest_sha256" => LocalEvaluation.sha256_file(manifest.path),
      "pipeline_amendment_sha256" => pipeline_amendment.digest,
      "source_correction_amendment_sha256" => source_correction.digest,
      "validation_results_sha256" => sha256(path("validation", "all_validation_results.yaml")),
      "benchmark_full_results_sha256" => sha256(path("benchmark", "benchmark_full_results.yaml")),
      "benchmark_config_sha256" => sha256(path("benchmark_config.yaml")),
      "aggregate_results_sha256" => sha256(path("aggregate_results.yaml"))
    }
    expected.each do |field, digest|
      raise "aggregate metadata #{field} is stale" unless metadata.fetch(field) == digest
    end
    raise "aggregate metadata is not a complete full rebuild" unless metadata.fetch("complete") == true && metadata.fetch("full_rebuild") == true
    raise "aggregate record count mismatch" unless metadata.fetch("record_count") == manifest.runs.size
  end

  def verify_review_digests!(review, pipeline_amendment, source_correction)
    expected = {
      "distribution_sha256" => path("local_scoring_distributions.csv"),
      "proposed_thresholds_sha256" => path("local_scoring_thresholds.proposed.csv"),
      "benchmark_full_results_sha256" => path("benchmark", "benchmark_full_results.yaml"),
      "aggregate_results_sha256" => path("aggregate_results.yaml"),
      "thresholds_sha256" => path("local_scoring_thresholds.csv")
    }
    expected.each do |field, source|
      raise "threshold review #{field} is stale" unless review.fetch(field) == sha256(source)
    end
    raise "threshold review pipeline amendment is stale" unless review.fetch("pipeline_amendment_sha256") == pipeline_amendment.digest
    unless review.fetch("source_correction_amendment_sha256") == source_correction.digest
      raise "threshold review source-correction amendment is stale"
    end
  end

  def verify_thresholds_reviewed!
    rows = CSV.read(path("local_scoring_thresholds.csv"), headers: true)
    raise "expected 44 reviewed scoring cells" unless rows.size == 44
    rows.each do |row|
      raise "unreviewed scoring threshold: #{row.fetch('bench')}/#{row.fetch('type')}" unless row.fetch("reviewed") == "true"
      values = %w[top great good].map { |field| Float(row.fetch(field)) }
      raise "unordered scoring thresholds" unless values[0] <= values[1] && values[1] <= values[2]
    end
  end

  def load_yaml(file)
    YAML.safe_load_file(file, permitted_classes: [Time, Symbol], aliases: true)
  end

  def sha256(file)
    Digest::SHA256.file(file).hexdigest
  end

  def path(*parts)
    File.join(@run_dir, *parts)
  end
end

if $PROGRAM_NAME == __FILE__
  options = { dry_run: false }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/finalize_scoring_metadata.rb --run-dir=PATH [--dry-run]"
    opts.on("--run-dir=PATH", "Completed and scored local-evaluation run") { |value| options[:run_dir] = value }
    opts.on("--dry-run", "Verify inputs and print metadata without writing") { options[:dry_run] = true }
  end
  parser.parse!
  abort parser.to_s unless options[:run_dir]
  ScoringMetadataFinalizer.new(**options).run
end
