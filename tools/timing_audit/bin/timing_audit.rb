#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/timing_audit"

command = ARGV.shift

case command
when "prepare"
  timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
  options = {
    release_root: TimingAudit::DEFAULT_RELEASE_ROOT,
    source_root: TimingAudit::DEFAULT_SOURCE_ROOT,
    output_dir: File.join(TimingAudit::DEFAULT_OUTPUT_ROOT, timestamp),
    trial_size: TimingAudit::DEFAULT_TRIAL_SIZE
  }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/timing_audit.rb prepare [options]"
    opts.on("--release-root=PATH", "Published local-evaluation artifact") { |value| options[:release_root] = value }
    opts.on("--source-root=PATH", "Pinned generated-source Git checkout") { |value| options[:source_root] = value }
    opts.on("--output=PATH", "New persistent audit directory") { |value| options[:output_dir] = value }
    opts.on("--trial-size=N", Integer, "Number of cases in the trial") { |value| options[:trial_size] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty?
  TimingAudit::InventoryBuilder.new(**options).run
when "run"
  options = {
    scope: nil,
    jobs: nil,
    model: TimingAudit::DEFAULT_MODEL,
    effort: TimingAudit::DEFAULT_EFFORT,
    timeout: TimingAudit::DEFAULT_TIMEOUT_SECONDS,
    retries: TimingAudit::DEFAULT_RETRIES,
    only_ids: []
  }
  output_dir = nil
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/timing_audit.rb run --output=PATH --scope=trial|full [options]"
    opts.on("--output=PATH", "Prepared persistent audit directory") { |value| output_dir = value }
    opts.on("--scope=SCOPE", %w[trial full], "Run the trial or full inventory") { |value| options[:scope] = value }
    opts.on("--jobs=N", Integer, "Maximum simultaneous Codex processes") { |value| options[:jobs] = value }
    opts.on("--model=MODEL", "Codex model") { |value| options[:model] = value }
    opts.on("--effort=EFFORT", "Model reasoning effort") { |value| options[:effort] = value }
    opts.on("--timeout=SECONDS", Integer, "Per-invocation timeout") { |value| options[:timeout] = value }
    opts.on("--retries=N", Integer, "Maximum attempts per record") { |value| options[:retries] = value }
    opts.on("--only=ID", "Run one selected ID (repeatable)") { |value| options[:only_ids] << value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && output_dir && options[:scope]
  options[:jobs] ||= options[:scope] == "trial" ? TimingAudit::DEFAULT_TRIAL_JOBS : TimingAudit::DEFAULT_FULL_JOBS
  TimingAudit::AuditRunner.new(output_dir: output_dir, **options).run
when "verify"
  output_dir = nil
  scope = nil
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/timing_audit.rb verify --output=PATH --scope=trial|full"
    opts.on("--output=PATH", "Prepared persistent audit directory") { |value| output_dir = value }
    opts.on("--scope=SCOPE", %w[trial full], "Verify the trial or full inventory") { |value| scope = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && output_dir && scope
  TimingAudit::AuditVerifier.new(output_dir, scope).run
else
  warn <<~USAGE
    Usage:
      ruby tools/timing_audit/bin/timing_audit.rb prepare [options]
      ruby tools/timing_audit/bin/timing_audit.rb run --output=PATH --scope=trial|full [options]
      ruby tools/timing_audit/bin/timing_audit.rb verify --output=PATH --scope=trial|full
  USAGE
  exit 1
end
