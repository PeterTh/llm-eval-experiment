# frozen_string_literal: true
require 'optparse'
require_relative '../../lib/codex_tree_requests'

options = {}
OptionParser.new do |parser|
  parser.banner = 'Usage: recover_codex_tree_requests.rb --sessions=PATH < BOUND_RECORDS_JSON'
  parser.on('--sessions=PATH') { |value| options[:sessions] = File.expand_path(value) }
end.parse!
raise 'A session root and no positional arguments are required' unless options[:sessions] && ARGV.empty?
records = JSON.parse($stdin.read)
raise 'Expected a nonempty unique scoped record array' unless records.is_a?(Array) && !records.empty? &&
  records.map { |record| record.fetch('run_id') }.uniq.size == records.size
records.each do |record|
  puts JSON.generate(CodexTreeRequests.recover(record, sessions_root: options.fetch(:sessions)))
end
