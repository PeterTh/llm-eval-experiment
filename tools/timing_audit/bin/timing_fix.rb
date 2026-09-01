#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/timing_fix"

command = ARGV.shift
case command
when "prepare"
  options = { audit_root: nil, output_dir: nil, trial_size: TimingFix::DEFAULT_TRIAL_SIZE }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/timing_fix.rb prepare --audit=PATH --output=PATH [options]"
    opts.on("--audit=PATH") { |value| options[:audit_root] = value }
    opts.on("--output=PATH") { |value| options[:output_dir] = File.expand_path(value) }
    opts.on("--trial-size=N", Integer) { |value| options[:trial_size] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && options[:audit_root] && options[:output_dir]
  TimingFix::InventoryBuilder.new(**options).run
when "run"
  output_dir = nil
  options = {
    scope: nil,
    jobs: nil,
    model: TimingFix::DEFAULT_MODEL,
    effort: TimingFix::DEFAULT_EFFORT,
    timeout: TimingFix::DEFAULT_TIMEOUT_SECONDS,
    retries: TimingFix::DEFAULT_RETRIES,
    only_ids: []
  }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/timing_fix.rb run --output=PATH --scope=trial|full [options]"
    opts.on("--output=PATH") { |value| output_dir = File.expand_path(value) }
    opts.on("--scope=SCOPE", %w[trial full]) { |value| options[:scope] = value }
    opts.on("--jobs=N", Integer) { |value| options[:jobs] = value }
    opts.on("--model=MODEL") { |value| options[:model] = value }
    opts.on("--effort=EFFORT") { |value| options[:effort] = value }
    opts.on("--timeout=SECONDS", Integer) { |value| options[:timeout] = value }
    opts.on("--retries=N", Integer) { |value| options[:retries] = value }
    opts.on("--only=ID") { |value| options[:only_ids] << value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && output_dir && options[:scope]
  options[:jobs] ||= options[:scope] == "trial" ? TimingFix::DEFAULT_TRIAL_JOBS : TimingFix::DEFAULT_FULL_JOBS
  TimingFix::ProposalRunner.new(output_dir: output_dir, **options).run
when "verify"
  output_dir = nil
  scope = nil
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/timing_fix.rb verify --output=PATH --scope=trial|full"
    opts.on("--output=PATH") { |value| output_dir = File.expand_path(value) }
    opts.on("--scope=SCOPE", %w[trial full]) { |value| scope = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && output_dir && scope
  TimingFix::ProposalVerifier.new(output_dir, scope).run
else
  abort <<~USAGE
    Usage:
      ruby tools/timing_audit/bin/timing_fix.rb prepare --audit=PATH --output=PATH [--trial-size=N]
      ruby tools/timing_audit/bin/timing_fix.rb run --output=PATH --scope=trial|full [options]
      ruby tools/timing_audit/bin/timing_fix.rb verify --output=PATH --scope=trial|full
  USAGE
end
