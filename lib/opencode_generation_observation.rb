# frozen_string_literal: true
require "time"
require_relative "opencode_harness"
require_relative "experiment_selection"
require_relative "opencode_generation_termination"
require_relative "generation_filesystem"

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
    termination = OpenCodeGenerationTermination.read(directory)
    paths = (%w[output.txt timing.txt instruction.txt process-status.txt] + OpenCodeHarness::EVIDENCE_FILES)
      .to_h { |name| [name, File.join(directory, name)] }
    if termination
      paths.delete("opencode-process.txt")
      paths[OpenCodeGenerationTermination::FILENAME] = File.join(directory, OpenCodeGenerationTermination::FILENAME)
    end
    paths.each { |name, path| raise Invalid, "Missing #{name}" unless File.file?(path) && !File.zero?(path) }
    evidence, session, process = %w[opencode-config.txt opencode-session.txt process-status.txt].map { |name| JSON.parse(File.read(paths.fetch(name))) }
    native_process = JSON.parse(File.read(paths.fetch("opencode-process.txt"))) unless termination
    raise Invalid, "Generation budget differs" unless [process, native_process].compact.all? { |record| record["timeout_seconds"] == timeout_seconds }
    unless termination
      raise Invalid, "OpenCode process status differs" unless %w[exit_status term_signal].all? { |key| process[key] == native_process[key] }
    end
    raise Invalid, "OpenCode version changed" unless evidence["version"] == version && evidence["binary_sha256"] == OpenCodeHarness::BINARY_SHA256
    raise Invalid, "Non-subscription access" unless evidence["auth_type"] == OpenCodeHarness.auth_type(model)
    raise Invalid, "Wrong OpenCode model or effort" unless evidence["model"] == model && evidence["reasoning_effort"] == effort
    output_policy = OpenCodeHarness.verify_output_token_policy!(evidence, model: model)
    expected = OpenCodeHarness.config(model: model, effort: effort)
    raise Invalid, "OpenCode requested settings changed" unless evidence["requested_config"] == expected
    OpenCodeHarness.verify_config!(evidence.fetch("resolved_config"), expected)
    tools = OpenCodeHarness.verify_agent!(evidence.fetch("build_agent"), model: model)
    raise Invalid, "OpenCode enabled tools differ" unless evidence["enabled_tools"] == tools
    resolved = evidence.fetch("resolved_model")
    OpenCodeHarness.verify_reasoning!(resolved, model: model, effort: effort)
    id = File.basename(directory)
    info = session.fetch("info")
    sid = info.fetch("id")
    raise Invalid, "Session identity differs" unless info["title"] == id && !info["parentID"] && File.basename(info.fetch("directory")) == id
    raise Invalid, "Session version differs" unless info["version"] == version
    filesystem = evidence["filesystem_isolation"]
    if filesystem
      begin
        GenerationFilesystem.verify_evidence!(filesystem, workspace: info.fetch("directory"))
      rescue RuntimeError => e
        raise Invalid, e.message
      end
    end
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
    events = File.readlines(paths.fetch("opencode-events.txt")).map { |line| JSON.parse(line) }
    event_steps = {}
    events.each do |row|
      event = row.fetch("event")
      next unless event["type"] == "message.part.updated" && event.dig("properties", "part", "type") == "step-finish"
      part = event.fetch("properties").fetch("part")
      previous = event_steps[part.fetch("id")]
      raise Invalid, "Conflicting native event accounting part" if previous && previous != part
      event_steps[part.fetch("id")] = part
    end
    raise Invalid, "Native events/session accounting differs" unless event_steps == steps
    raise Invalid, "Native transcript/session accounting differs" unless transcript_steps.all? { |key, part| steps[key] == part }
    # Stock `run --attach` can exit before printing its terminal step-finish
    # event. Its independently retained native event and session record must
    # agree; no counter is estimated and the original CLI transcript is untouched.
    omitted = steps.keys - transcript_steps.keys
    final_message = messages.last.fetch("info").fetch("id")
    terminal_reason = messages.last.dig("info", "finish")
    terminal_reasons = output_policy ? %w[stop length] : %w[stop]
    unless omitted.empty? || (omitted.size == 1 && steps[omitted.first]["messageID"] == final_message &&
      terminal_reasons.include?(steps[omitted.first]["reason"]) && steps[omitted.first]["reason"] == terminal_reason)
      raise Invalid, "Nonterminal accounting missing from CLI transcript"
    end
    if info["tokens"]
      raise Invalid, "Native session total disagrees with request counters" unless normalize_usage(info["tokens"]) == totals
    end
    backoff, retries = retry_backoff(events, sid, native_process, interrupted: !termination.nil?)
    raise Invalid, "Retry waits exceed duration" if backoff > duration
    report = { "id" => id, "model" => model, "reasoning_effort" => effort, "version" => version,
      "session_id" => sid, "tools" => tools, "tools_called" => calls.uniq.sort,
      "resolved_model" => resolved, "raw_total_seconds" => duration,
      "total_seconds" => (duration - backoff).round(6), "retry_count" => retries,
      "retry_backoff_seconds" => backoff, "usage_available" => !counts.empty?,
      "token_counts" => totals, "total_tokens" => totals.fetch("total_tokens"),
      "usage_source" => "opencode_native_step_finish",
      "cli_omitted_terminal_accounting_parts" => omitted.size,
      "sha256" => paths.transform_values { |path| Digest::SHA256.file(path).hexdigest } }
    report["output_token_policy"] = output_policy if output_policy
    report["filesystem_isolation"] = filesystem if filesystem
    if baseline
      %w[model reasoning_effort version tools resolved_model].each do |key|
        raise Invalid, "OpenCode #{key} differs from accepted preflight" unless report[key] == baseline.fetch(key)
      end
    end
    if termination
      raise Invalid, "Terminated session contains another terminal error" unless errors.empty?
      return report.merge("outcome" => "generation_model_terminated", "usage_complete" => false,
        "generation_failure_reason" => termination.fetch("reason"),
        "termination_record_sha256" => termination.fetch("termination_record_sha256"))
    end
    if [124, 137].include?(process["exit_status"]) && native_process.fetch("cli_wall_seconds") >= timeout_seconds - 2
      return report.merge("outcome" => "generation_timeout", "usage_complete" => false)
    end
    raise Invalid, "Generation process failed" unless process["exit_status"] == 0 && process["term_signal"].nil?
    raise Invalid, "Session contains a terminal error" unless errors.empty?
    last = messages.reverse.find { |message| message.dig("info", "role") == "assistant" }
    raise Invalid, "Missing terminal assistant turn" unless last && last.dig("info", "agent") == "build" && last.dig("info", "time", "completed")
    raise Invalid, "Missing exact token usage" if counts.empty? || totals.fetch("total_tokens").zero?
    if last.dig("info", "finish") == "length" && output_policy
      terminal_steps = steps.values.select { |part| part["messageID"] == last.dig("info", "id") }
      unless terminal_steps.size == 1 && terminal_steps.first["reason"] == "length" &&
        normalize_usage(terminal_steps.first.fetch("tokens"))["output_tokens"] == output_policy.fetch("max_output_tokens")
        raise Invalid, "Length termination differs from advertised output limit"
      end
      # A model exhausting its advertised allowance gets no automatic retry.
      return report.merge("outcome" => "generation_output_limit", "usage_complete" => true,
        "generation_failure_reason" => "advertised_output_limit_reached")
    end
    raise Invalid, "Missing terminal assistant turn" unless last.dig("info", "finish") == "stop"
    report.merge("outcome" => "completed", "usage_complete" => true)
  rescue KeyError, JSON::ParserError, ArgumentError, TypeError => e
    raise Invalid, e.message
  end

  def retry_backoff(events, sid, process, interrupted: false)
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
    raise Invalid, "Incomplete native status stream" unless statuses.first&.last&.fetch("type") == "busy" &&
      (interrupted || statuses.last&.last&.fetch("type") == "idle")
    raise Invalid, "Interrupted retry wait requires separate adjudication" if interrupted && statuses.last&.last&.fetch("type") == "retry"
    raise Invalid, "Native status stream out of order" unless statuses.map(&:first) == statuses.map(&:first).sort
    finish = Time.iso8601(process.fetch("generation_finished_at")).to_f * 1000 if process
    intervals = statuses.each_cons(2).filter_map do |(at, status), (next_at, _)|
      next unless status.fetch("type") == "retry"
      target = status.fetch("next")
      raise Invalid, "Invalid retry deadline" unless target.is_a?(Numeric) && target.finite?
      # Local SSE receipt timestamps differ from the scheduler by milliseconds;
      # never subtract beyond its explicit deadline, next event, or CLI exit.
      [0, [target, next_at, finish].compact.min - at].max / 1000.0
    end
    [intervals.sum.round(6), intervals.size]
  end
end
