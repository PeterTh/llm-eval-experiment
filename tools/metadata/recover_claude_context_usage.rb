#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "open3"
require "fileutils"
require "time"
require_relative "../../lib/claude_context_usage"

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: recover_claude_context_usage.rb --sources=REPO --batch=ID --commit=SHA --campaign=PATH --output=PATH"
  %w[sources batch commit campaign output].each { |name| opts.on("--#{name}=VALUE") { |value| options[name] = value } }
end
parser.parse!(ARGV)
abort parser.to_s unless ARGV.empty? && %w[sources batch commit campaign output].all? { |key| options[key] }
raise "Invalid source commit" unless options.fetch("commit").match?(/\A[0-9a-f]{40}\z/)
raise "Invalid batch ID" unless options.fetch("batch").match?(/\A\d{8}-\d{6}\z/)
output = File.expand_path(options.fetch("output"))
raise "Output already exists" if File.exist?(output)
observations = Dir[File.join(options.fetch("campaign"), "observations/*.json")].sort.map { |path| JSON.parse(File.read(path)) }
raise "Missing generation observations" if observations.empty?
records = observations.map do |observation|
  id = observation.fetch("id")
  raise "Unsafe observation ID" unless id.match?(/\A[a-zA-Z0-9_.-]+\z/)
  path = File.join(options.fetch("sources"), options.fetch("batch"), id)
  record = ClaudeContextUsage.read(path, version: observation.fetch("version"))
  raise "Retained observation differs" unless record.fetch("native_token_counts") == observation.fetch("token_counts") &&
    record.fetch("transcript_sha256") == observation.fetch("sha256").fetch("output.txt") &&
    record.fetch("session_id") == observation.fetch("session_id")
  blob, err, status = Open3.capture3("git", "-C", options.fetch("sources"), "show",
    "#{options.fetch('commit')}:#{options.fetch('batch')}/#{id}/output.txt")
  raise "Cannot read pinned transcript: #{err}" unless status.success?
  raise "Transcript differs from original Git revision" unless Digest::SHA256.hexdigest(blob) == record.fetch("transcript_sha256")
  record.merge("source_batch" => options.fetch("batch"), "source_commit" => options.fetch("commit"))
end
bytes = records.map { |record| JSON.generate(record) + "\n" }.join
method_root = File.expand_path("../..", __dir__)
method_names = %w[tools/metadata/recover_claude_context_usage.rb lib/claude_context_usage.rb
  lib/claude_generation_observation.rb lib/experiment_selection.rb]
receipt = {
  "schema_version" => 1, "created_at" => Time.now.utc.iso8601,
  "batch" => options.fetch("batch"), "source_commit" => options.fetch("commit"),
  "records" => records.size, "requests" => records.sum { |r| r.fetch("requests") },
  "records_with_long_context" => records.count { |r| r.dig("bands", "long", "requests").positive? },
  "long_context_requests" => records.sum { |r| r.dig("bands", "long", "requests") },
  "native_list_cost_nanodollars" => records.sum { |r| r.fetch("native_list_cost_nanodollars") },
  "cache_write_surcharge_nanodollars" => records.sum { |r| r.fetch("cache_write_surcharge_nanodollars") },
  "comparison_cost_nanodollars" => records.sum { |r| r.fetch("comparison_cost_nanodollars") },
  "output_band_evidence" => records.map { |r| r.fetch("output_band_evidence") }.tally,
  "usage_sha256" => Digest::SHA256.hexdigest(bytes), "usage_bytes" => bytes.bytesize,
  "rates_nanodollars_per_token" => { "short" => ClaudeContextUsage::SHORT_RATES, "long" => ClaudeContextUsage::LONG_RATES },
  "method_files" => method_names.to_h { |name| [name, Digest::SHA256.file(File.join(method_root, name)).hexdigest] },
  "verification" => "All request input/TTL counters reconcile with native totals and original Git transcripts; output-band splits satisfy integer, range, streamed lower-bound and list-price checks."
}
FileUtils.mkdir_p(output)
File.write(File.join(output, "usage.jsonl"), bytes)
File.write(File.join(output, "recovery.json"), JSON.pretty_generate(receipt) + "\n")
method_names.each do |name|
  destination = File.join(output, "method", name)
  FileUtils.mkdir_p(File.dirname(destination))
  FileUtils.cp(File.join(method_root, name), destination)
end
puts JSON.pretty_generate(receipt)
