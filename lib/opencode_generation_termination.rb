# frozen_string_literal: true
require "json"
require "digest"
require_relative "opencode_harness"

# Explicit operator adjudication, never automatic acceptance of a crashed agent.
# Source, transcript, wrapper timing and exit status remain the original result.
module OpenCodeGenerationTermination
  FILENAME = "generation-termination.txt"
  METADATA = %w[output.txt timing.txt instruction.txt process-status.txt opencode-config.txt opencode-session.txt opencode-events.txt].freeze
  PROTOCOL_METADATA = (METADATA + %w[opencode-process.txt]).freeze
  module_function

  def read(directory)
    path = File.join(directory, FILENAME)
    return nil unless File.file?(path)
    record = JSON.parse(File.read(path))
    protocol = record.fetch("schema_version") == 2 && record.fetch("reason") == "model_protocol_failure"
    legacy = record.fetch("schema_version") == 1 && record.fetch("reason") == "model_caused_termination"
    unless (protocol || legacy) && record.fetch("approved_by") == "user" &&
        record.fetch("decision") == "retain_original_without_restart" &&
        record.fetch("run_id") == File.basename(directory) && record.fetch("usage_complete") == false &&
        record.fetch("native_process_receipt_available") == protocol
      raise OpenCodeHarness::Invalid, "Unsupported OpenCode termination adjudication"
    end
    (protocol ? %w[incident_sha256] : %w[incident_sha256 native_export_sha256]).each do |key|
      raise OpenCodeHarness::Invalid, "Missing termination evidence digest" unless record.fetch(key).match?(/\A[0-9a-f]{64}\z/)
    end
    hashes = record.fetch("metadata_sha256")
    expected = protocol ? PROTOCOL_METADATA : METADATA
    raise OpenCodeHarness::Invalid, "Termination metadata scope differs" unless hashes.keys.sort == expected.sort
    hashes.each do |name, digest|
      target = File.join(directory, name)
      unless File.file?(target) && !File.symlink?(target) && Digest::SHA256.file(target).hexdigest == digest
        raise OpenCodeHarness::Invalid, "Termination metadata changed: #{name}"
      end
    end
    if protocol
      verify_protocol!(directory, record)
      return record.merge("termination_record_sha256" => Digest::SHA256.file(path).hexdigest)
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

  # This is an adjudicated observation, not a blanket exception for API errors.
  # Require the approved rendering rejection plus preceding model-emitted control
  # tokens in a failed tool argument, independently retained in CLI/native evidence.
  def verify_protocol!(directory, record)
    session = JSON.parse(File.read(File.join(directory, "opencode-session.txt")))
    sid = session.fetch("info").fetch("id")
    raise OpenCodeHarness::Invalid, "Protocol session identity differs" unless sid == record.fetch("session_id")
    messages = session.fetch("messages")
    last = messages.last
    header = last.fetch("info")
    error = record.fetch("terminal_error")
    unless header.values_at("id", "role", "agent", "providerID", "modelID", "variant") ==
        [record.fetch("terminal_message_id"), "assistant", "build", "opencode-go", "beam-free", "medium"] &&
        header.dig("time", "completed") && !header["finish"] && last.fetch("parts").empty? &&
        messages.filter_map { |message| message.dig("info", "error") } == [error] &&
        error.fetch("name") == "APIError" && error.dig("data", "statusCode") == 400 &&
        error.dig("data", "isRetryable") == false &&
        error.dig("data", "message") == "Upstream request failed: [prompt_rendering_failed] The request could not be rendered into a prompt for this model."
      raise OpenCodeHarness::Invalid, "Not the adjudicated Beam protocol rejection"
    end
    native = messages[0...-1].flat_map { |message| message.fetch("parts") }
      .select { |part| part["id"] == record.fetch("protocol_tool_part_id") }
    raise OpenCodeHarness::Invalid, "Missing native protocol tool part" unless native.size == 1
    part = native.first
    unless part["type"] == "tool" && %w[read edit].include?(part["tool"]) && part.dig("state", "status") == "error"
      raise OpenCodeHarness::Invalid, "Protocol trigger is not a failed model tool call"
    end
    emitted = File.foreach(File.join(directory, "output.txt")).filter_map do |line|
      event = JSON.parse(line) rescue next
      next unless event.is_a?(Hash) && event["type"] == "tool_use" && event["sessionID"] == sid
      candidate = event["part"]
      candidate if candidate.is_a?(Hash) && candidate["id"] == part.fetch("id")
    end.uniq
    raise OpenCodeHarness::Invalid, "Missing independent protocol tool arguments" unless emitted.size == 1
    emitted = emitted.first
    identity = %w[id sessionID messageID type tool]
    input = emitted.dig("state", "input")
    unless emitted.slice(*identity) == part.slice(*identity) &&
        emitted.fetch("state").slice("status", "error") == part.fetch("state").slice("status", "error") &&
        input.is_a?(Hash) && input["filePath"].is_a?(String) &&
        %w[<|end|><|start|> <|channel|>].all? { |marker| input["filePath"].include?(marker) }
      raise OpenCodeHarness::Invalid, "Model protocol-token evidence differs"
    end
    events = File.readlines(File.join(directory, "opencode-events.txt")).map { |line| JSON.parse(line).fetch("event") }
    errors = events.select { |event| event["type"] == "session.error" }.map { |event| event.fetch("properties") }.uniq
    unless errors == [{ "sessionID" => sid, "error" => error }]
      raise OpenCodeHarness::Invalid, "Native protocol error evidence differs"
    end
    %w[process-status.txt opencode-process.txt].each do |name|
      process = JSON.parse(File.read(File.join(directory, name)))
      unless process["exit_status"] == 0 && process["term_signal"].nil?
        raise OpenCodeHarness::Invalid, "Protocol failure process status differs"
      end
    end
  end
end
