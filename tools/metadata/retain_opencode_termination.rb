#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
require "digest"
require "fileutils"
require "tmpdir"
require "time"
require_relative "../../lib/opencode_generation_observation"

# Offline only: recover already-retained native metadata, never restart a model.
abort "usage: retain_opencode_termination.rb --approved-model-failure RESULT_DIRECTORY INCIDENT_DIRECTORY" unless ARGV.size == 3 && ARGV.first == "--approved-model-failure"
directory, incident_directory = ARGV.drop(1).map { |path| File.realpath(path) }
id = File.basename(directory)
incident_path = File.join(incident_directory, "incident.json")
incident = JSON.parse(File.read(incident_path))
raise "Incident identity/classification differs" unless incident.fetch("id") == id && incident.fetch("classification") == "model_caused_termination" && incident.fetch("rerun_performed") == false
incident.fetch("original_files_sha256").each do |name, digest|
  raise "Unexpected original metadata path" unless %w[output.txt instruction.txt timing.txt process-status.txt].include?(name)
  raise "Original metadata changed: #{name}" unless Digest::SHA256.file(File.join(directory, name)).hexdigest == digest
end
native_path = File.join(incident_directory, "native-session-rows.json")
names = %w[opencode-config.txt opencode-events.txt native-session-rows.json]
names.each do |name|
  raise "Native evidence changed: #{name}" unless Digest::SHA256.file(File.join(incident_directory, name)).hexdigest == incident.fetch("retained_artifacts_sha256").fetch(name)
end
rows = JSON.parse(File.read(native_path))
raise "Expected exactly one isolated native session" unless rows.fetch("session").size == 1
row = rows.fetch("session").first
sid = row.fetch("id")
info = row.slice("id", "title", "directory", "version", "cost").merge(
  "parentID" => row.fetch("parent_id"),
  "time" => { "created" => row.fetch("time_created"), "updated" => row.fetch("time_updated") },
  "tokens" => { "input" => row.fetch("tokens_input"), "output" => row.fetch("tokens_output"),
    "reasoning" => row.fetch("tokens_reasoning"),
    "cache" => { "read" => row.fetch("tokens_cache_read"), "write" => row.fetch("tokens_cache_write") } })
parts = rows.fetch("part").sort_by { |part| [part.fetch("time_created"), part.fetch("id")] }.map do |part|
  raise "Foreign native part" unless part.fetch("session_id") == sid
  JSON.parse(part.fetch("data")).merge("id" => part.fetch("id"), "messageID" => part.fetch("message_id"), "sessionID" => sid)
end
messages = rows.fetch("message").sort_by { |message| [message.fetch("time_created"), message.fetch("id")] }.map do |message|
  raise "Foreign native message" unless message.fetch("session_id") == sid
  header = JSON.parse(message.fetch("data")).merge("id" => message.fetch("id"), "sessionID" => sid)
  { "info" => header, "parts" => parts.select { |part| part.fetch("messageID") == message.fetch("id") } }
end
raise "Unmatched native parts" unless messages.sum { |message| message.fetch("parts").size } == parts.size
terminal_tool = messages.last.fetch("parts").reverse.find { |part| part["type"] == "tool" }
session = OpenCodeHarness.session_projection(info, messages)
# The final interrupted command was never emitted by the CLI, so preserve its
# native input as well as its lifecycle metadata in this exceptional projection.
session.fetch("messages").last.fetch("parts").map! { |part| part["id"] == terminal_tool.fetch("id") ? terminal_tool : part }
artifacts = %w[opencode-config.txt opencode-events.txt].to_h { |name| [name, File.binread(File.join(incident_directory, name))] }
artifacts["opencode-session.txt"] = JSON.pretty_generate(session) + "\n"
receipt_name = OpenCodeGenerationTermination::FILENAME
raise "Termination metadata already exists" if (artifacts.keys + [receipt_name, "opencode-process.txt"]).any? { |name| File.exist?(File.join(directory, name)) }
report = nil
Dir.mktmpdir("opencode-termination-recovery-", "/tmp") do |scratch|
  staged = File.join(scratch, id)
  FileUtils.mkdir(staged)
  %w[output.txt instruction.txt timing.txt process-status.txt].each { |name| FileUtils.cp(File.join(directory, name), staged) }
  artifacts.each { |name, content| File.write(File.join(staged, name), content) }
  receipt = { "schema_version" => 1, "run_id" => id, "session_id" => sid,
    "reason" => "model_caused_termination", "approved_by" => "user", "decision" => "retain_original_without_restart",
    "recorded_at" => Time.now.utc.iso8601, "usage_complete" => false, "native_process_receipt_available" => false,
    "metadata_source" => "read_only_native_database_export", "termination_tool_part" => terminal_tool,
    "incident_sha256" => Digest::SHA256.file(incident_path).hexdigest,
    "native_export_sha256" => Digest::SHA256.file(native_path).hexdigest,
    "metadata_sha256" => OpenCodeGenerationTermination::METADATA.to_h { |name| [name, Digest::SHA256.file(File.join(staged, name)).hexdigest] } }
  artifacts[receipt_name] = JSON.pretty_generate(receipt) + "\n"
  File.write(File.join(staged, receipt_name), artifacts.fetch(receipt_name))
  evidence = JSON.parse(artifacts.fetch("opencode-config.txt"))
  report = OpenCodeGenerationObservation.read(staged, model: evidence.fetch("model"), effort: evidence.fetch("reasoning_effort"), version: evidence.fetch("version"))
  artifacts.each_key { |name| FileUtils.cp(File.join(staged, name), directory) }
end
puts JSON.pretty_generate(report)
