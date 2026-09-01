#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "time"

require_relative "../../../lib/local_evaluation"

class ScopedMeasurementRerun
  AMENDMENT = "scoped_measurement_rerun.yaml"
  COMPLETION = "scoped_measurement_rerun_completion.yaml"

  def initialize(run_dir:, ids:, reason: nil)
    @run_dir = File.expand_path(run_dir)
    @ids = ids.map(&:strip).reject(&:empty?).uniq.sort
    @reason = reason.to_s.strip
    raise "scoped measurement rerun needs at least one ID" if @ids.empty?
  end

  def prepare
    manifest = LocalEvaluation::Manifest.new(@run_dir)
    pipeline = LocalEvaluation::PipelineAmendment.load_chain(@run_dir, manifest: manifest).last
    correction = LocalEvaluation::SourceCorrectionAmendment.load(@run_dir, manifest: manifest)
    raise "source-correction amendment is required" unless correction
    unknown = @ids - manifest.runs.keys
    raise "IDs absent from manifest: #{unknown.join(', ')}" unless unknown.empty?
    outside = @ids - correction.affected_ids
    raise "IDs outside timing-correction scope: #{outside.join(', ')}" unless outside.empty?

    amendment_path = path(AMENDMENT)
    if File.file?(amendment_path)
      amendment = load_immutable(amendment_path)
      raise "existing scoped-rerun ID set differs" unless amendment.fetch("affected_run_ids") == @ids
    else
      raise "scoped measurement rerun reason must not be empty" if @reason.empty?
      raise "scoped measurement rerun already completed" if File.exist?(path(COMPLETION))
      full = load_yaml(full_results_path)
      simple = load_yaml(simple_results_path)
      records = @ids.to_h do |id|
        metadata_path = path("benchmark", id, "benchmark_metadata.yaml")
        raise "missing benchmark metadata for #{id}" unless File.file?(metadata_path)
        metadata = load_yaml(metadata_path)
        raise "refusing to supersede a failed benchmark: #{id}" unless metadata.fetch("success") == true
        raise "record is not a corrected timing measurement: #{id}" unless metadata.fetch("timing_fixed") == true
        raise "canonical full result missing: #{id}" unless full.key?(id)
        raise "canonical compatibility result missing: #{id}" unless simple.key?(id)
        [id, {
          "benchmark_metadata_sha256" => sha256(metadata_path),
          "success" => metadata.fetch("success"),
          "metrics" => metadata.fetch("metrics"),
          "wall_seconds" => metadata.fetch("wall_seconds")
        }]
      end
      amendment = {
        "schema_version" => 1,
        "created_at" => Time.now.iso8601,
        "reason" => @reason,
        "manifest_sha256" => LocalEvaluation.sha256_file(manifest.path),
        "pipeline_amendment_sha256" => pipeline.digest,
        "source_correction_amendment_sha256" => correction.digest,
        "affected_run_ids" => @ids,
        "prior_benchmark_full_results_sha256" => sha256(full_results_path),
        "prior_benchmark_results_sha256" => sha256(simple_results_path),
        "unaffected_records_sha256" => records_digest(full.reject { |id, _record| @ids.include?(id) }),
        "superseded_records" => records
      }
      LocalEvaluation.atomic_yaml_with_digest(amendment_path, amendment, immutable: true)
    end

    full = load_yaml(full_results_path)
    simple = load_yaml(simple_results_path)
    @ids.each do |id|
      output_dir = path("benchmark", id)
      LocalEvaluation::BuildSupport.archive_existing(output_dir, path("benchmark", "attempts", id)) if File.directory?(output_dir)
      full.delete(id)
      simple.delete(id)
    end
    LocalEvaluation.atomic_yaml(full_results_path, full.sort.to_h)
    LocalEvaluation.atomic_yaml(simple_results_path, simple.sort.to_h)
    puts "Prepared #{@ids.size} exact corrected IDs for a conservative scoped remeasurement"
  end

  def finalize
    amendment = load_immutable(path(AMENDMENT))
    raise "scoped-rerun ID set differs" unless amendment.fetch("affected_run_ids") == @ids
    completion_path = path(COMPLETION)
    if File.file?(completion_path)
      load_immutable(completion_path)
      puts "Scoped measurement rerun was already finalized"
      return
    end

    full = load_yaml(full_results_path)
    simple = load_yaml(simple_results_path)
    records = @ids.to_h do |id|
      metadata_path = path("benchmark", id, "benchmark_metadata.yaml")
      raise "scoped remeasurement is incomplete: #{id}" unless File.file?(metadata_path) && full.key?(id) && simple.key?(id)
      metadata = load_yaml(metadata_path)
      raise "remeasurement lost timing-correction provenance: #{id}" unless metadata.fetch("timing_fixed") == true
      raise "remeasurement metadata/result status mismatch: #{id}" unless metadata.fetch("success") == full.fetch(id).fetch(0)
      [id, {
        "benchmark_metadata_sha256" => sha256(metadata_path),
        "success" => metadata.fetch("success"),
        "metrics" => metadata.fetch("metrics"),
        "wall_seconds" => metadata.fetch("wall_seconds")
      }]
    end
    unaffected_digest = records_digest(full.reject { |id, _record| @ids.include?(id) })
    unless unaffected_digest == amendment.fetch("unaffected_records_sha256")
      raise "records outside the exact scoped remeasurement changed"
    end

    completion = {
      "schema_version" => 1,
      "completed_at" => Time.now.iso8601,
      "amendment_sha256" => sha256(path(AMENDMENT)),
      "affected_run_ids" => @ids,
      "benchmark_full_results_sha256" => sha256(full_results_path),
      "benchmark_results_sha256" => sha256(simple_results_path),
      "unaffected_records_sha256" => unaffected_digest,
      "unaffected_records_unchanged" => true,
      "records" => records
    }
    LocalEvaluation.atomic_yaml_with_digest(completion_path, completion, immutable: true)
    puts "Finalized #{@ids.size} exact corrected remeasurements; unrelated records are unchanged"
  end

  private

  def load_immutable(file)
    raise "missing immutable scoped-rerun file: #{file}" unless File.file?(file) && File.file?("#{file}.sha256")
    expected = File.read("#{file}.sha256", encoding: Encoding::UTF_8).strip
    raise "scoped-rerun sidecar mismatch: #{file}" unless expected == sha256(file)

    load_yaml(file)
  end

  def records_digest(records)
    normalized = records.sort.to_h.transform_values { |record| canonicalize(record) }
    Digest::SHA256.hexdigest(JSON.generate(normalized))
  end

  def canonicalize(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [key, canonicalize(value.fetch(key))] }
    when Array
      value.map { |element| canonicalize(element) }
    else
      value
    end
  end

  def load_yaml(file)
    YAML.safe_load_file(file, permitted_classes: [Time, Symbol], aliases: true)
  end

  def sha256(file)
    Digest::SHA256.file(file).hexdigest
  end

  def full_results_path
    path("benchmark", "benchmark_full_results.yaml")
  end

  def simple_results_path
    path("benchmark", "benchmark_results.yaml")
  end

  def path(*parts)
    File.join(@run_dir, *parts)
  end
end

if $PROGRAM_NAME == __FILE__
  operation = ARGV.shift
  abort "Usage: ruby tools/timing_audit/bin/scoped_measurement_rerun.rb prepare|finalize --run-dir=PATH --ids-file=PATH [--reason=TEXT]" unless %w[prepare finalize].include?(operation)
  options = {}
  parser = OptionParser.new do |opts|
    opts.on("--run-dir=PATH", "Completed local-evaluation run") { |value| options[:run_dir] = value }
    opts.on("--ids-file=PATH", "Exact affected IDs, one per line") { |value| options[:ids_file] = value }
    opts.on("--reason=TEXT", "Scientific reason for superseding the measurements") { |value| options[:reason] = value }
  end
  parser.parse!
  abort parser.to_s unless options[:run_dir] && options[:ids_file]
  ids = File.readlines(options.fetch(:ids_file), chomp: true)
  lock = LocalEvaluation::RunLock.new(options.fetch(:run_dir))
  begin
    runner = ScopedMeasurementRerun.new(run_dir: options.fetch(:run_dir), ids: ids, reason: options[:reason])
    operation == "prepare" ? runner.prepare : runner.finalize
  ensure
    lock.close
  end
end
