#!/usr/bin/env ruby

require "optparse"
require_relative "lib/local_evaluation"

COMMANDS = %w[
  init amend-source-correction amend-pipeline preflight validate calibrate freeze-config benchmark aggregate
  prepare-scoring score status
].freeze

command = ARGV.shift
unless COMMANDS.include?(command)
  warn "Usage: ruby local_evaluation.rb COMMAND [options]"
  warn "Commands: #{COMMANDS.join(", ")}"
  exit 1
end

options = {
  benchmarks_root: File.expand_path("../benchmarks", __dir__),
  seed: File.expand_path("local_benchmark_seed.yml", __dir__),
  dry_run: false,
  retry_failed: false
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby local_evaluation.rb #{command} [options]"
  opts.on("--run-dir=PATH", "Combined local evaluation run directory") { |value| options[:run_dir] = File.expand_path(value) }
  opts.on("--experiments-root=PATH", "Root containing timestamped experiment batches") { |value| options[:experiments_root] = File.expand_path(value) }
  opts.on("--benchmarks-root=PATH", "Sequential benchmark repository") { |value| options[:benchmarks_root] = File.expand_path(value) }
  opts.on("--seed=PATH", "Calibration seed YAML") { |value| options[:seed] = File.expand_path(value) }
  opts.on("--config=PATH", "Frozen benchmark configuration") { |value| options[:config] = File.expand_path(value) }
  opts.on("--proposed=PATH", "Reviewed proposed benchmark configuration") { |value| options[:proposed] = File.expand_path(value) }
  opts.on("--thresholds=PATH", "Reviewed scoring threshold CSV") { |value| options[:thresholds] = File.expand_path(value) }
  opts.on("--reason=TEXT", "Scientific reason for a scoped pipeline amendment") { |value| options[:reason] = value }
  opts.on("--corrections=PATH", "Final timing-correction evidence directory") { |value| options[:corrections] = File.expand_path(value) }
  opts.on("--id=RUN_ID", "Operate on one exact run ID") { |value| options[:exact_id] = value }
  opts.on("--ids-file=PATH", "Operate on exact run IDs listed one per line") { |value| options[:ids_file] = File.expand_path(value) }
  opts.on("--filter=TEXT", "Operate on IDs containing TEXT") { |value| options[:filter] = value }
  opts.on("--dry-run", "Inspect selected work without running or writing phase outputs") { options[:dry_run] = true }
  opts.on("--retry-failed", "Explicitly rerun recorded failed validations or benchmarks") { options[:retry_failed] = true }
  opts.on("-h", "--help", "Show help") { puts opts; exit }
end
parser.parse!(ARGV)
abort "Unexpected arguments: #{ARGV.join(" ")}" unless ARGV.empty?
if options[:ids_file]
  abort "--ids-file cannot be combined with --id or --filter" if options[:exact_id] || options[:filter]
  unless %w[benchmark amend-pipeline].include?(command)
    abort "--ids-file is supported only by benchmark and amend-pipeline"
  end
  abort "ID list not found: #{options[:ids_file]}" unless File.file?(options[:ids_file])
  options[:selected_ids] = File.readlines(options[:ids_file], chomp: true).map(&:strip).reject(&:empty?)
  abort "ID list is empty: #{options[:ids_file]}" if options[:selected_ids].empty?
  abort "ID list contains duplicates: #{options[:ids_file]}" unless options[:selected_ids].uniq.size == options[:selected_ids].size
end

def require_option!(options, key)
  value = options[key]
  abort "Missing required option --#{key.to_s.tr("_", "-")}" unless value
  value
end

def with_lock(run_dir)
  lock = LocalEvaluation::RunLock.new(run_dir)
  yield
ensure
  lock&.close
end

def with_performance_lock
  lock = LocalEvaluation::HostPerformanceLock.new
  yield
ensure
  lock&.close
end

def verify_inputs!(run_dir, operation:, options:)
  LocalEvaluation::Manifest.new(run_dir).verify_input_revisions!(
    operation: operation, exact_id: options[:exact_id], filter: options[:filter],
    selected_ids: options[:selected_ids]
  )
end

begin
  case command
  when "init"
    run_dir = require_option!(options, :run_dir)
    experiments_root = require_option!(options, :experiments_root)
    if options[:dry_run]
      batches, runs = LocalEvaluation::Manifest.discover(experiments_root)
      source_errors = runs.count { |_id, info| info["source_error"] }
      puts "Init dry run: #{runs.size} unique runs across #{batches.size} batches; #{source_errors} source-layout errors"
    else
      FileUtils.mkdir_p(run_dir)
      with_lock(run_dir) do
        manifest = LocalEvaluation::Manifest.create(experiments_root: experiments_root, run_dir: run_dir,
                                                    benchmarks_root: options[:benchmarks_root])
        puts "Initialized #{run_dir} with #{manifest.runs.size} runs across #{manifest.data.fetch("batches").size} batches"
      end
    end
  when "amend-source-correction"
    run_dir = require_option!(options, :run_dir)
    correction_dir = require_option!(options, :corrections)
    reason = require_option!(options, :reason)
    with_lock(run_dir) do
      manifest = LocalEvaluation::Manifest.new(run_dir)
      amendment = LocalEvaluation::SourceCorrectionAmendment.create!(
        manifest: manifest, correction_dir: correction_dir, reason: reason, dry_run: options[:dry_run]
      )
      if options[:dry_run]
        puts YAML.dump(amendment)
      else
        puts "Wrote immutable source correction amendment #{amendment.path}"
      end
    end
  when "amend-pipeline"
    run_dir = require_option!(options, :run_dir)
    affected_ids = options[:selected_ids] || [require_option!(options, :exact_id)]
    reason = require_option!(options, :reason)
    with_lock(run_dir) do
      manifest = LocalEvaluation::Manifest.new(run_dir)
      amendment = LocalEvaluation::PipelineAmendment.create!(
        manifest: manifest, affected_ids: affected_ids, reason: reason, dry_run: options[:dry_run]
      )
      if options[:dry_run]
        puts YAML.dump(amendment)
      else
        puts "Wrote immutable scoped pipeline amendment #{amendment.path}"
      end
    end
  when "preflight"
    run_dir = require_option!(options, :run_dir)
    with_lock(run_dir) do
      with_performance_lock do
        manifest = LocalEvaluation::Manifest.new(run_dir)
        revision_report = manifest.verify_input_revisions!(operation: command,
                                                           exact_id: options[:exact_id], filter: options[:filter],
                                                           selected_ids: options[:selected_ids])
        report = LocalEvaluation::Resources.new.verify_topology!.merge(
          "checked_at" => Time.now.iso8601,
          "manifest_sha256" => LocalEvaluation.sha256_file(manifest.path),
          "input_revisions" => revision_report,
          "free_disk_bytes" => LocalEvaluation.ensure_disk_space!(run_dir)
        )
        if options[:dry_run]
          puts YAML.dump(report)
        else
          path = File.join(run_dir, "preflight.yaml")
          LocalEvaluation.atomic_yaml(path, report)
          puts "Preflight passed; wrote #{path}"
        end
      end
    end
  when "validate"
    run_dir = require_option!(options, :run_dir)
    with_lock(run_dir) do
      with_performance_lock do
        verify_inputs!(run_dir, operation: command, options: options)
        LocalEvaluation::ValidationPipeline.new(run_dir: run_dir, exact_id: options[:exact_id],
                                                filter: options[:filter], dry_run: options[:dry_run],
                                                retry_failed: options[:retry_failed]).run
      end
    end
  when "calibrate"
    run_dir = require_option!(options, :run_dir)
    with_lock(run_dir) do
      with_performance_lock do
        verify_inputs!(run_dir, operation: command, options: options)
        LocalEvaluation::Calibrator.new(run_dir: run_dir, seed_path: options[:seed],
                                       exact_id: options[:exact_id], filter: options[:filter],
                                       dry_run: options[:dry_run], retry_failed: options[:retry_failed]).run
      end
    end
  when "freeze-config"
    run_dir = require_option!(options, :run_dir)
    with_lock(run_dir) do
      verify_inputs!(run_dir, operation: command, options: options)
      LocalEvaluation::BenchmarkPipeline.freeze_config(run_dir: run_dir, proposed_path: options[:proposed],
                                                       dry_run: options[:dry_run])
    end
  when "benchmark"
    run_dir = require_option!(options, :run_dir)
    with_lock(run_dir) do
      with_performance_lock do
        verify_inputs!(run_dir, operation: command, options: options)
        LocalEvaluation::BenchmarkPipeline.new(run_dir: run_dir, config_path: options[:config],
                                               exact_id: options[:exact_id], filter: options[:filter],
                                               ids: options[:selected_ids],
                                               dry_run: options[:dry_run], retry_failed: options[:retry_failed]).run
      end
    end
  when "aggregate"
    run_dir = require_option!(options, :run_dir)
    with_lock(run_dir) do
      with_performance_lock do
        verify_inputs!(run_dir, operation: command, options: options)
        LocalEvaluation::AggregatePipeline.new(run_dir: run_dir, exact_id: options[:exact_id],
                                               filter: options[:filter], dry_run: options[:dry_run]).run
      end
    end
  when "prepare-scoring"
    run_dir = require_option!(options, :run_dir)
    with_lock(run_dir) do
      verify_inputs!(run_dir, operation: command, options: options)
      LocalEvaluation::ScoringPipeline.prepare(run_dir: run_dir, exact_id: options[:exact_id],
                                               filter: options[:filter], dry_run: options[:dry_run])
    end
  when "score"
    run_dir = require_option!(options, :run_dir)
    thresholds = require_option!(options, :thresholds)
    with_lock(run_dir) do
      verify_inputs!(run_dir, operation: command, options: options)
      LocalEvaluation::ScoringPipeline.score(run_dir: run_dir, thresholds_path: thresholds,
                                             exact_id: options[:exact_id], filter: options[:filter],
                                             dry_run: options[:dry_run])
    end
  when "status"
    LocalEvaluation::StatusReporter.new(require_option!(options, :run_dir)).run
  end
rescue Interrupt
  warn "Interrupted; completed per-run results are safely resumable."
  exit 130
rescue StandardError => e
  warn "#{e.class}: #{e.message}"
  warn e.backtrace.join("\n") if ENV["LOCAL_EVALUATION_DEBUG"] == "1"
  exit 1
end
