#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/qtclustering_boundary"

command = ARGV.shift
case command
when "prepare"
  options = { validation_runs: [], trial_size: 16 }
  parser = OptionParser.new do |opts|
    %w[release-root source-root source-commit reference-root reference-commit benchmark-config context-path output-dir].each do |name|
      opts.on("--#{name}=VALUE") { |value| options[name.tr("-", "_").to_sym] = value }
    end
    opts.on("--validation-run=PATH") { |value| options[:validation_runs] << value }
    opts.on("--validation-only", "Select only the supplied validation runs; use the release for configuration context") { options[:include_release] = false }
    opts.on("--trial-size=N", Integer) { |value| options[:trial_size] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty?
  QtclusteringBoundary::Builder.new(**options).run
when "review", "pilot-gate", "finalize"
  options = {}
  parser = OptionParser.new do |opts|
    opts.on("--main=PATH") { |v| options[:main_root] = v }
    opts.on("--review=PATH") { |v| options[command == "review" ? :output_dir : :review_root] = v }
    if command == "review"
      opts.on("--scope=SCOPE", %w[trial full]) { |v| options[:scope] = v }
      opts.on("--jobs=N", Integer) { |v| options[:jobs] = v }
    end
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty?
  case command
  when "review" then QtclusteringBoundary.run_review(**options)
  when "pilot-gate" then exit(QtclusteringBoundary.pilot_gate(**options) ? 0 : 1)
  when "finalize" then QtclusteringBoundary.finalize(**options)
  end
else
  abort "Usage: qtclustering_boundary.rb prepare|review|pilot-gate|finalize [options]"
end
