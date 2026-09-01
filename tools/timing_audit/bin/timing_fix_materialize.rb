#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/timing_fix_materializer"

options = { output_dir: nil, scope: nil, jobs: 4 }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/timing_audit/bin/timing_fix_materialize.rb --output=PATH --scope=trial|full [--jobs=N]"
  opts.on("--output=PATH") { |value| options[:output_dir] = File.expand_path(value) }
  opts.on("--scope=SCOPE", %w[trial full]) { |value| options[:scope] = value }
  opts.on("--jobs=N", Integer) { |value| options[:jobs] = value }
end
parser.parse!(ARGV)
abort parser.to_s unless ARGV.empty? && options[:output_dir] && options[:scope]
TimingFixMaterializer.run(**options)
