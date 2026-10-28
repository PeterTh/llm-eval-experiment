# frozen_string_literal: true
require_relative "experiment_selection"
require_relative "codex_usage"
require_relative "generation_filesystem"

# Inspect completed CLI metadata only. Exact session accounting is recovered at
# the preflight gate and after the whole campaign, never during agent tuning.
module CodexGenerationObservation
  class Invalid < StandardError; end
  module_function

  def read(directory, model:, effort:, version:, timeout_seconds: 14400, baseline: nil)
    duration = ExperimentSelection.completed_duration(directory)
    raise Invalid, "Observation has no completion record" unless duration
    paths = %w[output.txt timing.txt instruction.txt process-status.txt].to_h { |name| [name, File.join(directory, name)] }
    paths.each { |name, path| raise Invalid, "Missing #{name}" unless File.file?(path) && !File.zero?(path) }
    process = JSON.parse(File.read(paths.fetch("process-status.txt")))
    raise Invalid, "Generation budget differs" unless process.fetch("timeout_seconds") == timeout_seconds
    head = File.open(paths.fetch("output.txt"), "rb") { |file| file.read(8192).to_s }
    match = head.match(/^OpenAI Codex v([^\r\n]+)\r?\n--------\r?\n(.*?)\r?\n--------\r?\n/m)
    raise Invalid, "Missing Codex session header" unless match
    fields = match[2].lines.to_h { |line| line.strip.split(": ", 2) }
    expected = { "model" => model, "reasoning effort" => effort, "provider" => "openai",
      "approval" => "never", "sandbox" => "danger-full-access" }
    expected.each { |key, value| raise Invalid, "Codex #{key} differs" unless fields[key] == value }
    raise Invalid, "Codex version changed" unless match[1] == version
    id = File.basename(directory)
    batch = File.basename(File.dirname(directory))
    cwd = fields.fetch("workdir")
    raise Invalid, "Codex working directory differs" unless File.basename(cwd) == id && File.basename(File.dirname(cwd)) == batch
    session = fields.fetch("session id")
    raise Invalid, "Invalid Codex session ID" unless session.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/)
    report = { "id" => id, "model" => model, "reasoning_effort" => effort, "version" => version,
      "session_id" => session, "session_cwd" => cwd, "raw_total_seconds" => duration,
      "sha256" => paths.transform_values { |path| Digest::SHA256.file(path).hexdigest } }
    isolation_path = File.join(directory, "codex-filesystem.txt")
    if File.file?(isolation_path)
      isolation = JSON.parse(File.read(isolation_path))
      workspace = isolation.fetch("filesystem_isolation").fetch("workspace")
      unless workspace == cwd && workspace == "/home/llmtest/evals/#{batch}/#{id}"
        raise Invalid, "Isolated workspace identity differs"
      end
      begin
        GenerationFilesystem.verify_evidence!(isolation.fetch("filesystem_isolation"), workspace: workspace)
      rescue RuntimeError => e
        raise Invalid, e.message
      end
      unless isolation.values_at("model", "effort", "version", "timeout_seconds", "exit_status", "term_signal") ==
          [model, effort, version, timeout_seconds, process["exit_status"], process["term_signal"]]
        raise Invalid, "Isolated CLI identity/status differs"
      end
      raise Invalid, "Isolated session collection incomplete" unless isolation["session_archive_complete"] == true
      sessions = isolation.fetch("archived_sessions")
      unless sessions.is_a?(Array) && sessions.any? { |record| record["path"].to_s.end_with?("-#{session}.jsonl") && record["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) && record["bytes"].is_a?(Integer) && record["bytes"] > 0 }
        raise Invalid, "Current session was not archived"
      end
      report["filesystem_isolation"] = isolation.fetch("filesystem_isolation")
      report["archived_sessions"] = sessions
      report.fetch("sha256")["codex-filesystem.txt"] = Digest::SHA256.file(isolation_path).hexdigest
    end
    if baseline
      %w[model reasoning_effort version].each do |key|
        raise Invalid, "Codex #{key} differs from accepted preflight" unless report[key] == baseline.fetch(key)
      end
    end
    if [124, 137].include?(process["exit_status"]) && duration >= timeout_seconds - 2
      return report.merge("outcome" => "generation_timeout", "usage_available" => false)
    end
    raise Invalid, "Generation process failed" unless process["exit_status"] == 0 && process["term_signal"].nil?
    request = CodexUsage.transcript_request(batch: batch, id: id, path: paths.fetch("output.txt"))
    raise Invalid, "Codex session identity differs" unless request.fetch("session_id") == session
    report.merge("outcome" => "completed", "usage_available" => false, "exact_usage_pending" => true,
      "legacy_reported_tokens" => request.fetch("legacy_reported_tokens"), "total_seconds" => duration)
  rescue KeyError, JSON::ParserError, ArgumentError, CodexUsage::Invalid => e
    raise Invalid, e.message
  end
end
