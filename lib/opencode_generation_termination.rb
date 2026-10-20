# frozen_string_literal: true
require "json"
require "digest"
require_relative "opencode_harness"

# Explicit operator adjudication, never automatic acceptance of a crashed agent.
# Source, transcript, wrapper timing and exit status remain the original result.
module OpenCodeGenerationTermination
  FILENAME = "generation-termination.txt"
  METADATA = %w[output.txt timing.txt instruction.txt process-status.txt opencode-config.txt opencode-session.txt opencode-events.txt].freeze
  module_function

  def read(directory)
    path = File.join(directory, FILENAME)
    return nil unless File.file?(path)
    record = JSON.parse(File.read(path))
    unless record.fetch("schema_version") == 1 && record.fetch("reason") == "model_caused_termination" &&
        record.fetch("approved_by") == "user" && record.fetch("decision") == "retain_original_without_restart" &&
        record.fetch("run_id") == File.basename(directory) && record.fetch("usage_complete") == false &&
        record.fetch("native_process_receipt_available") == false
      raise OpenCodeHarness::Invalid, "Unsupported OpenCode termination adjudication"
    end
    %w[incident_sha256 native_export_sha256].each do |key|
      raise OpenCodeHarness::Invalid, "Missing termination evidence digest" unless record.fetch(key).match?(/\A[0-9a-f]{64}\z/)
    end
    hashes = record.fetch("metadata_sha256")
    raise OpenCodeHarness::Invalid, "Termination metadata scope differs" unless hashes.keys.sort == METADATA.sort
    hashes.each do |name, digest|
      target = File.join(directory, name)
      unless File.file?(target) && !File.symlink?(target) && Digest::SHA256.file(target).hexdigest == digest
        raise OpenCodeHarness::Invalid, "Termination metadata changed: #{name}"
      end
    end
    raise OpenCodeHarness::Invalid, "Unexpected recovered process receipt" if File.exist?(File.join(directory, "opencode-process.txt"))
    process = JSON.parse(File.read(File.join(directory, "process-status.txt")))
    unless process["exit_status"] == 143 && process["term_signal"].nil? && process["success"] == false
      raise OpenCodeHarness::Invalid, "Termination wrapper status differs"
    end
    session = JSON.parse(File.read(File.join(directory, "opencode-session.txt")))
    raise OpenCodeHarness::Invalid, "Termination session identity differs" unless session.dig("info", "id") == record.fetch("session_id")
    last = session.fetch("messages").last
    tool = last.fetch("parts").reverse.find { |part| part["type"] == "tool" }
    unless last.dig("info", "role") == "assistant" && !last.dig("info", "time", "completed") &&
        tool == record.fetch("termination_tool_part") && tool["tool"] == "bash" && tool.dig("state", "status") == "running" &&
        tool.dig("state", "input", "command").is_a?(String) && tool.dig("state", "input", "command").match?(/\bpkill\s+-f\s+/)
      raise OpenCodeHarness::Invalid, "Missing native self-termination command"
    end
    record.merge("termination_record_sha256" => Digest::SHA256.file(path).hexdigest)
  rescue KeyError, JSON::ParserError, ArgumentError, TypeError, NoMethodError => e
    raise OpenCodeHarness::Invalid, e.message
  end
end
