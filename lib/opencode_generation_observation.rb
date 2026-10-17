# frozen_string_literal: true
require "time"
require_relative "opencode_harness"
require_relative "experiment_selection"

# Static admission and exact accounting from native per-request step-finish
# counters, including compaction. Never run or grade the generated program here.
module OpenCodeGenerationObservation
  Invalid = OpenCodeHarness::Invalid
  module_function

  def count(value, name)
    raise Invalid, "Invalid OpenCode token counter: #{name}" unless value.is_a?(Integer) && value >= 0
    value
  end

  def normalize_usage(tokens)
    input = count(tokens.fetch("input"), "input")
    visible = count(tokens.fetch("output"), "output")
    reasoning = count(tokens.fetch("reasoning"), "reasoning")
    cached = count(tokens.fetch("cache").fetch("read"), "cache.read")
    written = count(tokens.fetch("cache").fetch("write"), "cache.write")
    inclusive_input, inclusive_output = input + cached + written, visible + reasoning
    total = inclusive_input + inclusive_output
    # Some providers omit total; preserve the exact disjoint counters in either
    # case, but reject contradictory totals instead of silently estimating.
    raise Invalid, "OpenCode token total disagrees" if tokens.key?("total") && count(tokens["total"], "total") != total
    { "input_tokens" => inclusive_input, "cached_input_tokens" => cached,
      "cache_write_input_tokens" => written, "output_tokens" => inclusive_output,
      "reasoning_output_tokens" => reasoning, "total_tokens" => total }
  end

  def read(directory, model:, effort:, version: OpenCodeHarness::VERSION, timeout_seconds: 14400, baseline: nil)
    duration = ExperimentSelection.completed_duration(directory)
    raise Invalid, "Observation has no completion record" unless duration
    paths = (%w[output.txt timing.txt instruction.txt process-status.txt] + OpenCodeHarness::EVIDENCE_FILES)
      .to_h { |name| [name, File.join(directory, name)] }
    paths.each { |name, path| raise Invalid, "Missing #{name}" unless File.file?(path) && !File.zero?(path) }
    evidence, session, process = %w[opencode-config.txt opencode-session.txt process-status.txt].map { |name| JSON.parse(File.read(paths.fetch(name))) }
    native_process = JSON.parse(File.read(paths.fetch("opencode-process.txt")))
    raise Invalid, "Generation budget differs" unless [process, native_process].all? { |record| record["timeout_seconds"] == timeout_seconds }
    raise Invalid, "OpenCode process status differs" unless %w[exit_status term_signal].all? { |key| process[key] == native_process[key] }
    raise Invalid, "OpenCode version changed" unless evidence["version"] == version && evidence["binary_sha256"] == OpenCodeHarness::BINARY_SHA256
    raise Invalid, "Non-subscription access" unless evidence["auth_type"] == "openai-subscription-oauth"
    raise Invalid, "Wrong OpenCode model or effort" unless evidence["model"] == model && evidence["reasoning_effort"] == effort
    raise Invalid, "OpenCode isolation flags differ" unless evidence["flags"] == OpenCodeHarness::FLAGS
    expected = OpenCodeHarness.config(model: model, effort: effort)
    raise Invalid, "OpenCode requested settings changed" unless evidence["requested_config"] == expected
    OpenCodeHarness.verify_config!(evidence.fetch("resolved_config"), expected)
    tools = OpenCodeHarness.verify_agent!(evidence.fetch("build_agent"))
    raise Invalid, "OpenCode enabled tools differ" unless evidence["enabled_tools"] == tools
    resolved = evidence.fetch("resolved_model")
    raise Invalid, "OpenCode medium reasoning was not resolved" unless resolved.dig("options", "reasoningEffort") == effort && resolved.dig("variants", effort, "reasoningEffort") == effort
    id = File.basename(directory)
    info = session.fetch("info")
    sid = info.fetch("id")
    raise Invalid, "Session identity differs" unless info["title"] == id && !info["parentID"] && File.basename(info.fetch("directory")) == id
    raise Invalid, "Session version differs" unless info["version"] == version
    provider_id, model_id = model.split("/", 2)
    steps, calls, errors = {}, [], []
    messages = session.fetch("messages")
    raise Invalid, "No session messages" if messages.empty?
    raise Invalid, "Duplicate native message" unless messages.map { |m| m.fetch("info").fetch("id") }.uniq.size == messages.size
    messages.each do |message|
      header = message.fetch("info")
      raise Invalid, "Message belongs to another session" unless header["sessionID"] == sid
      if header["role"] == "assistant"
        unless header["providerID"] == provider_id && header["modelID"] == model_id && header["variant"] == effort
          raise Invalid, "Additional model or effort in session"
        end
        raise Invalid, "Unexpected agent" unless %w[build compaction].include?(header["agent"])
        errors << header["error"] if header["error"]
      elsif header["role"] == "user"
        raise Invalid, "Wrong user model/effort" unless header["model"] == { "providerID" => provider_id, "modelID" => model_id, "variant" => effort }
      else
        raise Invalid, "Unknown message role"
      end
      message.fetch("parts").each do |part|
        raise Invalid, "Part identity differs" unless part["sessionID"] == sid && part["messageID"] == header["id"]
        if part["type"] == "step-finish"
          raise Invalid, "Repeated native accounting part" if steps.key?(part.fetch("id"))
          steps[part.fetch("id")] = part
        elsif part["type"] == "tool"
          calls << part.fetch("tool")
        elsif part["type"] == "subtask"
          raise Invalid, "Subagent task found"
        end
      end
    end
    raise Invalid, "Forbidden tool called: #{calls - tools}" unless (calls - tools).empty?
    counts = steps.values.map { |part| normalize_usage(part.fetch("tokens")) }
    totals = normalize_usage({ "input" => 0, "output" => 0, "reasoning" => 0, "cache" => { "read" => 0, "write" => 0 } })
    counts.each { |value| value.each { |key, amount| totals[key] += amount } }
    # Cross-check the independent native CLI transcript; repeated delivery of
    # the same part is harmless, but conflicting duplicates are not.
    transcript_steps = {}
    File.foreach(paths.fetch("output.txt")) do |line|
      event = JSON.parse(line) rescue next
      next unless event.is_a?(Hash) && event["sessionID"]
      raise Invalid, "Transcript session differs" unless event["sessionID"] == sid
      next unless event["type"] == "step_finish"
      part = event.fetch("part")
      previous = transcript_steps[part.fetch("id")]
      raise Invalid, "Conflicting transcript accounting part" if previous && previous != part
      transcript_steps[part.fetch("id")] = part
    end
    raise Invalid, "Native transcript/session accounting differs" unless transcript_steps == steps
    events = File.readlines(paths.fetch("opencode-events.txt")).map { |line| JSON.parse(line) }
    backoff, retries = retry_backoff(events, sid, native_process)
    raise Invalid, "Retry waits exceed duration" if backoff > duration
    report = { "id" => id, "model" => model, "reasoning_effort" => effort, "version" => version,
      "session_id" => sid, "tools" => tools, "tools_called" => calls.uniq.sort,
      "resolved_model" => resolved, "raw_total_seconds" => duration,
      "total_seconds" => (duration - backoff).round(6), "retry_count" => retries,
      "retry_backoff_seconds" => backoff, "usage_available" => !counts.empty?,
      "token_counts" => totals, "total_tokens" => totals.fetch("total_tokens"),
      "usage_source" => "opencode_native_step_finish",
      "sha256" => paths.transform_values { |path| Digest::SHA256.file(path).hexdigest } }
    if baseline
      %w[model reasoning_effort version tools resolved_model].each do |key|
        raise Invalid, "OpenCode #{key} differs from accepted preflight" unless report[key] == baseline.fetch(key)
      end
    end
    if [124, 137].include?(process["exit_status"]) && native_process.fetch("cli_wall_seconds") >= timeout_seconds - 2
      return report.merge("outcome" => "generation_timeout", "usage_complete" => false)
    end
    raise Invalid, "Generation process failed" unless process["exit_status"] == 0 && process["term_signal"].nil?
    raise Invalid, "Session contains a terminal error" unless errors.empty?
    last = messages.reverse.find { |message| message.dig("info", "role") == "assistant" }
    raise Invalid, "Missing terminal assistant turn" unless last && last.dig("info", "agent") == "build" && last.dig("info", "finish") == "stop" && last.dig("info", "time", "completed")
    raise Invalid, "Missing exact token usage" if counts.empty? || totals.fetch("total_tokens").zero?
    report.merge("outcome" => "completed", "usage_complete" => true)
  rescue KeyError, JSON::ParserError, ArgumentError, TypeError => e
    raise Invalid, e.message
  end

  def retry_backoff(events, sid, process)
    statuses, seen = [], {}
    events.each do |row|
      event = row.fetch("event")
      next if event["id"] && seen[event["id"]]
      seen[event["id"]] = true if event["id"]
      if event["type"] == "session.created"
        raise Invalid, "Unexpected additional session" unless event.dig("properties", "info", "id") == sid && !event.dig("properties", "info", "parentID")
      end
      next unless event["type"] == "session.status"
      raise Invalid, "Status for unexpected session" unless event.dig("properties", "sessionID") == sid
      statuses << [row.fetch("received_at_ms"), event.dig("properties", "status")]
    end
    raise Invalid, "Incomplete native status stream" unless statuses.first&.last&.fetch("type") == "busy" && statuses.last&.last&.fetch("type") == "idle"
    raise Invalid, "Native status stream out of order" unless statuses.map(&:first) == statuses.map(&:first).sort
    finish = Time.iso8601(process.fetch("generation_finished_at")).to_f * 1000
    intervals = statuses.each_cons(2).filter_map do |(at, status), (next_at, _)|
      next unless status.fetch("type") == "retry"
      target = status.fetch("next")
      raise Invalid, "Invalid retry deadline" unless target.is_a?(Numeric) && target.finite?
      # Local SSE receipt timestamps differ from the scheduler by milliseconds;
      # never subtract beyond its explicit deadline, next event, or CLI exit.
      [0, [target, next_at, finish].min - at].max / 1000.0
    end
    [intervals.sum.round(6), intervals.size]
  end
end
