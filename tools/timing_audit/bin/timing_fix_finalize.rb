#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/timing_fix_finalize"

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/timing_audit/bin/timing_fix_finalize.rb --proposals=PATH --review=PATH --adjudication=PATH --source=PATH --corrected-commit=SHA --output=PATH"
  opts.on("--proposals=PATH") { |value| options[:proposal_root] = File.expand_path(value) }
  opts.on("--review=PATH") { |value| options[:review_root] = File.expand_path(value) }
  opts.on("--adjudication=PATH") { |value| options[:adjudication_root] = File.expand_path(value) }
  opts.on("--source=PATH") { |value| options[:source_root] = File.expand_path(value) }
  opts.on("--corrected-commit=SHA") { |value| options[:corrected_commit] = value }
  opts.on("--output=PATH") { |value| options[:output_dir] = File.expand_path(value) }
end
parser.parse!(ARGV)
required = %i[proposal_root review_root adjudication_root source_root corrected_commit output_dir]
abort parser.to_s unless ARGV.empty? && required.all? { |key| options[key] }
TimingFixFinalize.run(**options)
