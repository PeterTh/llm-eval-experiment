#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/timing_fix_review"

command = ARGV.shift
case command
when "prepare"
  options = { proposal_root: nil, output_dir: nil }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/timing_fix_review.rb prepare --proposals=PATH --output=PATH"
    opts.on("--proposals=PATH") { |value| options[:proposal_root] = value }
    opts.on("--output=PATH") { |value| options[:output_dir] = File.expand_path(value) }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && options.values.all?
  TimingFixReview::InventoryBuilder.new(**options).run
when "run"
  output_dir = nil
  options = {
    scope: nil,
    jobs: nil,
    model: TimingFixReview::DEFAULT_MODEL,
    effort: TimingFixReview::DEFAULT_EFFORT,
    timeout: TimingFixReview::DEFAULT_TIMEOUT_SECONDS,
    retries: TimingFixReview::DEFAULT_RETRIES,
    only_ids: []
  }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/timing_fix_review.rb run --output=PATH --scope=trial|full [options]"
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
  options[:jobs] ||= options[:scope] == "trial" ? TimingFixReview::DEFAULT_TRIAL_JOBS : TimingFixReview::DEFAULT_FULL_JOBS
  TimingFixReview::Runner.new(output_dir: output_dir, **options).run
when "verify"
  output_dir = nil
  scope = nil
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/timing_audit/bin/timing_fix_review.rb verify --output=PATH --scope=trial|full"
    opts.on("--output=PATH") { |value| output_dir = File.expand_path(value) }
    opts.on("--scope=SCOPE", %w[trial full]) { |value| scope = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && output_dir && scope
  TimingFixReview::Verifier.new(output_dir, scope).run
else
  abort <<~USAGE
    Usage:
      ruby tools/timing_audit/bin/timing_fix_review.rb prepare --proposals=PATH --output=PATH
      ruby tools/timing_audit/bin/timing_fix_review.rb run --output=PATH --scope=trial|full [options]
      ruby tools/timing_audit/bin/timing_fix_review.rb verify --output=PATH --scope=trial|full
  USAGE
end
