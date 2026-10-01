#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/timing_fix_revision"

options = { jobs: 4, model: "gpt-6.1-sol", effort: "high" }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/timing_audit/bin/timing_fix_revision.rb --output=PATH --scope=trial|full --feedback=JSON"
  opts.on("--output=PATH") { |v| options[:output_dir] = v }
  opts.on("--scope=SCOPE", %w[trial full]) { |v| options[:scope] = v }
  opts.on("--feedback=PATH") { |v| options[:feedback_path] = v }
  opts.on("--jobs=N", Integer) { |v| options[:jobs] = v }
  opts.on("--model=MODEL") { |v| options[:model] = v }
  opts.on("--effort=EFFORT") { |v| options[:effort] = v }
end
parser.parse!(ARGV)
abort parser.to_s unless ARGV.empty? && %i[output_dir scope feedback_path].all? { |k| options[k] }
TimingFixRevision::Runner.new(**options).run
