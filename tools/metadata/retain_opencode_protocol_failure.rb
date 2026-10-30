#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
require "digest"
require "fileutils"
require "tmpdir"
require "time"
require_relative "../../lib/opencode_generation_observation"

# Offline, explicit adjudication only. Never rewrite a transcript or restart a
# session; stage and verify the additional receipt before adding it to the result.
abort "usage: retain_opencode_protocol_failure.rb --approved-model-failure RESULT_DIRECTORY DECISION_JSON" unless
  ARGV.size == 3 && ARGV.first == "--approved-model-failure"
directory, decision_path = ARGV.drop(1).map { |path| File.realpath(path) }
decision = JSON.parse(File.read(decision_path))
id = File.basename(directory)
unless decision.values_at("id", "classification", "approved_by", "decision", "rerun_performed") ==
    [id, "model_protocol_failure", "user", "retain_original_without_restart", false]
  raise "Protocol failure was not explicitly adjudicated"
end
decision.fetch("original_files_sha256").each do |name, digest|
  path = File.expand_path(name, directory)
  unless path.start_with?(directory + "/") && !File.symlink?(path) && Digest::SHA256.file(path).hexdigest == digest
    raise "Original evidence changed: #{name}"
  end
end
name = OpenCodeGenerationTermination::FILENAME
raise "Termination record already exists" if File.exist?(File.join(directory, name))
session = JSON.parse(File.read(File.join(directory, "opencode-session.txt")))
last = session.fetch("messages").last.fetch("info")
receipt = { "schema_version" => 2, "run_id" => id, "session_id" => session.fetch("info").fetch("id"),
  "reason" => "model_protocol_failure", "approved_by" => "user", "decision" => "retain_original_without_restart",
  "recorded_at" => Time.now.utc.iso8601, "usage_complete" => false, "native_process_receipt_available" => true,
  "incident_sha256" => Digest::SHA256.file(decision_path).hexdigest,
  "terminal_message_id" => last.fetch("id"), "terminal_error" => last.fetch("error"),
  "protocol_tool_part_id" => decision.fetch("protocol_tool_part_id"),
  "metadata_sha256" => OpenCodeGenerationTermination::PROTOCOL_METADATA.to_h { |file| [file, Digest::SHA256.file(File.join(directory, file)).hexdigest] } }
content = JSON.pretty_generate(receipt) + "\n"
report = nil
Dir.mktmpdir("opencode-protocol-retention-", "/tmp") do |scratch|
  staged = File.join(scratch, id)
  FileUtils.mkdir(staged)
  OpenCodeGenerationTermination::PROTOCOL_METADATA.each { |file| FileUtils.cp(File.join(directory, file), staged) }
  File.write(File.join(staged, name), content, mode: "wx")
  evidence = JSON.parse(File.read(File.join(staged, "opencode-config.txt")))
  report = OpenCodeGenerationObservation.read(staged, model: evidence.fetch("model"),
    effort: evidence.fetch("reasoning_effort"), version: evidence.fetch("version"))
  raise "Wrong retained outcome" unless report.fetch("outcome") == "generation_model_terminated" &&
    report.fetch("generation_failure_reason") == "model_protocol_failure" && report.fetch("usage_complete") == false
  receipt.fetch("metadata_sha256").each do |file, digest|
    raise "Metadata changed during adjudication" unless Digest::SHA256.file(File.join(directory, file)).hexdigest == digest
  end
  File.write(File.join(directory, name), content, mode: "wx")
end
puts JSON.pretty_generate(report)
