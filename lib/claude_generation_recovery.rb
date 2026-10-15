# frozen_string_literal: true
require "json"
require "digest"
require_relative "experiment_selection"

# Explicit, operator-approved recovery of a completed native Claude session whose
# outer generation wrapper died. Never infer an exit status or a wrapper duration.
module ClaudeGenerationRecovery
  class Invalid < StandardError; end
  FILENAME = "generation-recovery.txt"
  TIME_SOURCE = "claude_result_duration_ms"
  METADATA = %w[output.txt timing.txt instruction.txt process-status.txt usage.txt].freeze
  module_function

  def read(directory, id: File.basename(directory), batch: nil)
    path = File.join(directory, FILENAME)
    timing = File.join(directory, "timing.txt")
    unless File.file?(path)
      if File.file?(timing) && File.read(timing).include?("Generation time source:")
        raise Invalid, "Recovered generation time is missing its evidence record"
      end
      return nil
    end

    record = JSON.parse(File.read(path))
    raise Invalid, "Unsupported generation recovery" unless record.fetch("schema_version") == 1 &&
      record.fetch("reason") == "controller_oom" && record.fetch("approved_by") == "user" &&
      record.fetch("decision") == "retain_completed_native_result"
    raise Invalid, "Recovery run identity differs" unless record.fetch("run_id") == id
    raise Invalid, "Recovery batch identity differs" if batch && record.fetch("campaign_id") != batch
    raise Invalid, "Missing incident evidence digest" unless record.fetch("incident_sha256").match?(/\A[0-9a-f]{64}\z/)
    raise Invalid, "Recovery time source differs" unless record.fetch("generation_time_source") == TIME_SOURCE &&
      record.fetch("generation_time_recovered") == true && record.fetch("wrapper_exit_status_available") == false &&
      record.fetch("wrapper_wall_time_seconds").nil? && record.fetch("wrapper_start_time").nil? && record.fetch("wrapper_end_time").nil?

    hashes = record.fetch("metadata_sha256")
    raise Invalid, "Recovery metadata scope differs" unless hashes.keys.sort == METADATA.sort
    hashes.each do |name, expected|
      target = File.join(directory, name)
      raise Invalid, "Recovery metadata changed: #{name}" unless File.file?(target) && !File.symlink?(target) &&
        Digest::SHA256.file(target).hexdigest == expected
    end
    process = JSON.parse(File.read(File.join(directory, "process-status.txt")))
    raise Invalid, "Recovered wrapper status must remain unknown" unless
      %w[exit_status term_signal success].all? { |key| process.fetch(key).nil? } &&
      process.fetch("status_source") == "unavailable_controller_terminated"

    initializations, results, last_event = [], [], nil
    File.foreach(File.join(directory, "output.txt")) do |line|
      event = JSON.parse(line) rescue next
      next unless event.is_a?(Hash)
      last_event = event
      initializations << event if event["type"] == "system" && event["subtype"] == "init"
      results << event if event["type"] == "result"
    end
    raise Invalid, "Recovery requires one completed native session" unless initializations.size == 1 && results.size == 1 && last_event == results.first
    init, result = initializations.first, results.first
    raise Invalid, "Recovery session differs" unless [init, result].all? { |event| event["session_id"] == record.fetch("session_id") }
    raise Invalid, "Recovery model or CLI differs" unless init["model"] == record.fetch("model") &&
      init["claude_code_version"] == record.fetch("version") && result.fetch("modelUsage").keys == [record.fetch("model")]
    raise Invalid, "Recovery requires a successful native result" unless result["is_error"] == false && result["subtype"] == "success" &&
      result["terminal_reason"] == "completed" && result["rate_limits"].nil?
    milliseconds = result.fetch("duration_ms")
    raise Invalid, "Invalid recovered native duration" unless milliseconds.is_a?(Integer) && milliseconds > 0 &&
      milliseconds <= process.fetch("timeout_seconds") * 1000 && milliseconds == record.fetch("duration_ms")
    raise Invalid, "Recovered duration differs from timing.txt" unless ExperimentSelection.completed_duration(directory) == milliseconds / 1000.0
    text = File.read(timing)
    raise Invalid, "Recovered duration is not labeled" unless text.lines.map(&:chomp).include?("Generation time source: #{TIME_SOURCE} (recovered)")
    %w[Start End].each do |label|
      raise Invalid, "Wrapper timestamps must remain unknown" unless text.match?(/^#{label} time: unavailable \(generation wrapper terminated\)$/)
    end
    record.merge("generation_recovery_sha256" => Digest::SHA256.file(path).hexdigest)
  rescue KeyError, JSON::ParserError, ArgumentError, TypeError, NoMethodError => e
    raise Invalid, e.message
  end

  def summary(record)
    record.slice("generation_time_source", "generation_time_recovered", "wrapper_exit_status_available", "generation_recovery_sha256")
  end
end
