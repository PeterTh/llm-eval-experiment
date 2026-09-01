#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "yaml"
require_relative "../lib/timing_fix_adjudication"

options = { output_dir: nil, attempt: 5, ids: [] }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/timing_audit/bin/timing_fix_adjudication_import.rb --output=PATH --id=ID [--id=ID ...]"
  opts.on("--output=PATH") { |value| options[:output_dir] = File.realpath(value) }
  opts.on("--attempt=N", Integer) { |value| options[:attempt] = value }
  opts.on("--id=ID") { |value| options[:ids] << value }
end
parser.parse!(ARGV)
abort parser.to_s unless ARGV.empty? && options[:output_dir] && !options[:ids].empty?

root = options.fetch(:output_dir)
records = TimingAudit.load_jsonl(File.join(root, "inventory.jsonl"))
validator = TimingFixAdjudication::ResultValidator.new(records)
header_path = TimingFixAdjudication::InventoryBuilder::MPI_HEADER
overrides = options.fetch(:ids).map do |id|
  event_path = File.join(root, "logs", id, format("attempt-%02d", options.fetch(:attempt)), "events.jsonl")
  events = File.foreach(event_path, chomp: true).map { |line| JSON.parse(line) }
  message = events.find { |event| event["type"] == "item.completed" && event.dig("item", "type") == "agent_message" }
  raise "Missing agent message for #{id}" unless message
  raw = JSON.parse(message.dig("item", "text"))
  raise "Raw program ID mismatch for #{id}" unless raw.fetch("program_id") == id
  external = raw.fetch("evidence").select { |entry| entry.fetch("path") == header_path }
  raise "Expected exactly one redundant MPI-header citation for #{id}" unless external.size == 1
  raise "Unexpected external line citation for #{id}" unless external.first.fetch("lines") == "1211-1212"
  corrected = Marshal.load(Marshal.dump(raw))
  corrected["evidence"].reject! { |entry| entry.fetch("path") == header_path }
  validator.validate!(corrected, expected_id: id)
  raw_bytes = JSON.pretty_generate(raw) + "\n"
  corrected_bytes = JSON.pretty_generate(corrected) + "\n"
  TimingAudit.atomic_write(File.join(root, "results", "#{id}.json"), corrected_bytes)
  {
    "program_id" => id,
    "reason" => "Removed one redundant pinned-MPI-header citation; evidence is restricted to corrected-program source and the same header fact remains in environment_evidence_assessment.",
    "scientific_effect" => "none",
    "changed_fields" => ["evidence"],
    "removed_evidence" => external,
    "raw_result_sha256" => Digest::SHA256.hexdigest(raw_bytes),
    "corrected_result_sha256" => Digest::SHA256.hexdigest(corrected_bytes),
    "source_event_log" => event_path.delete_prefix("#{root}/"),
    "source_event_log_sha256" => TimingAudit.sha256_file(event_path)
  }
end

payload = {
  "schema_version" => 1,
  "created_at" => TimingAudit.utc_now,
  "overrides" => overrides
}
TimingAudit.atomic_write(File.join(root, "manual-result-overrides.yaml"), YAML.dump(payload))
puts "Imported #{overrides.size} adjudications with evidence-only normalization"
