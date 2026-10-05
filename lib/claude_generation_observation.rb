# frozen_string_literal: true
require "json"
require "digest"
require_relative "experiment_selection"

# Read completed generation records only: never compile, execute, or grade the program.
module ClaudeGenerationObservation
  class Invalid < StandardError; end
  FORBIDDEN_TOOLS = %w[WebSearch WebFetch Agent Task Workflow CronCreate CronDelete CronList ScheduleWakeup RemoteTrigger].freeze
  COUNTERS = { "input_tokens" => "inputTokens", "output_tokens" => "outputTokens",
    "cache_read_input_tokens" => "cacheReadInputTokens", "cache_creation_input_tokens" => "cacheCreationInputTokens" }.freeze
  module_function

  def read(directory, model:, version:, timeout_seconds: 14400, baseline: nil)
    duration = ExperimentSelection.completed_duration(directory)
    raise Invalid, "Observation has no completion record" unless duration
    paths = %w[output.txt timing.txt instruction.txt process-status.txt].to_h { |name| [name, File.join(directory, name)] }
    paths.each { |name, path| raise Invalid, "Missing #{name}" unless File.file?(path) && !File.zero?(path) }
    process = JSON.parse(File.read(paths.fetch("process-status.txt")))
    raise Invalid, "Generation budget differs" unless process.fetch("timeout_seconds") == timeout_seconds
    init, result = nil, nil
    notification_seen, notification_result_pending = false, false
    assistant_models, calls, retries, seen = [], [], [], {}
    File.foreach(paths.fetch("output.txt")) do |line|
      event = JSON.parse(line) rescue next
      next unless event.is_a?(Hash)
      if event["type"] == "system" && event["subtype"] == "init"
        if init
          same = event.reject { |key, _| key == "uuid" } == init.reject { |key, _| key == "uuid" }
          raise Invalid, "Session initialization changed" unless same
          unless result && notification_seen && !notification_result_pending
            raise Invalid, "Repeated initialization without a completed-turn task notification"
          end
          notification_result_pending = true
        else
          init = event
        end
      elsif event["type"] == "system" && event["subtype"] == "task_notification"
        notification_seen = true if result && event["session_id"] == init&.fetch("session_id")
      elsif event["type"] == "result"
        if notification_result_pending
          verify_notification_continuation!(result, event, model: model, session: init.fetch("session_id"))
          notification_result_pending = false
        end
        result = event
        notification_seen = false
      elsif event["type"] == "assistant"
        observed = event.dig("message", "model")
        assistant_models << observed if observed && observed != "<synthetic>"
        Array(event.dig("message", "content")).each do |content|
          calls << content["name"] if content.is_a?(Hash) && content["type"] == "tool_use"
        end
      elsif event["type"] == "system" && event["subtype"] == "api_retry"
        retries << event
      end
    end
    raise Invalid, "Incomplete task-notification continuation" if notification_result_pending
    raise Invalid, "Missing session initialization" unless init
    raise Invalid, "Wrong generation model" unless init["model"] == model && (assistant_models.uniq - [model]).empty?
    raise Invalid, "Claude version changed" unless init["claude_code_version"] == version
    raise Invalid, "Permission mode changed" unless init["permissionMode"] == "bypassPermissions"
    raise Invalid, "Unexpected MCP servers" unless init.fetch("mcp_servers").empty?
    tools = init.fetch("tools").sort
    forbidden = (tools + calls).select { |name| FORBIDDEN_TOOLS.include?(name) || name.start_with?("mcp__") }
    raise Invalid, "Forbidden tools: #{forbidden.uniq.join(', ')}" unless forbidden.empty?
    plugins = init.fetch("plugins", []).map { |p| p.slice("name", "path", "source") }.sort_by { |p| p.fetch("name") }
    raise Invalid, "External plugin loaded" unless plugins.all? { |p| p["path"] == "builtin" && p["source"].to_s.end_with?("@builtin") }
    if baseline
      raise Invalid, "Available tools differ from accepted preflight" unless tools == baseline.fetch("tools")
      raise Invalid, "Built-in plugins differ from accepted preflight" unless plugins == baseline.fetch("plugins")
    end
    report = { "id" => File.basename(directory), "model" => model, "version" => version,
      "session_id" => init.fetch("session_id"), "tools" => tools, "plugins" => plugins,
      "tools_called" => calls.uniq.sort, "raw_total_seconds" => duration,
      "sha256" => paths.transform_values { |p| Digest::SHA256.file(p).hexdigest } }
    if result.nil? && [124, 137].include?(process["exit_status"]) && duration >= timeout_seconds - 2
      return report.merge("outcome" => "generation_timeout", "usage_available" => false)
    end
    raise Invalid, "Missing terminal result without a full-budget timeout" unless result
    raise Invalid, "Session identity differs" unless result["session_id"] == init["session_id"]
    raise Invalid, "Generation process failed" unless process["exit_status"] == 0 && process["term_signal"].nil?
    raise Invalid, "Terminal error requires investigation" unless result["is_error"] == false && result["subtype"] == "success"
    raise Invalid, "Quota termination requires retry" if result["rate_limits"].is_a?(Hash)
    raise Invalid, "Subagents were spawned" unless result.fetch("subagent_stats", {}).fetch("spawned", 0) == 0
    models = result.fetch("modelUsage")
    raise Invalid, "Additional or fallback model usage" unless models.keys == [model]
    usage = models.fetch(model)
    counts = COUNTERS.to_h do |normalized, key|
      value = usage.fetch(key)
      raise Invalid, "Invalid token counter #{key}" unless value.is_a?(Integer) && value >= 0
      [normalized, value]
    end
    raise Invalid, "Server-side web search was used" unless usage.fetch("webSearchRequests", 0) == 0
    server_tools = result.fetch("usage", {}).fetch("server_tool_use", {})
    raise Invalid, "Server-side web tool was used" unless server_tools.values.all? { |n| n == 0 }
    retry_ms = retries.select { |e| e["session_id"] == result["session_id"] }.filter_map do |event|
      next if event["uuid"] && seen[event["uuid"]]
      seen[event["uuid"]] = true if event["uuid"]
      delay = event.fetch("retry_delay_ms")
      raise Invalid, "Invalid retry delay" unless delay.is_a?(Integer) && delay >= 0
      delay
    end
    api_ms = result.fetch("duration_api_ms")
    raise Invalid, "Invalid API duration" unless api_ms.is_a?(Numeric) && api_ms.finite? && api_ms >= 0
    backoff = retry_ms.sum / 1000.0
    raise Invalid, "Retry duration exceeds elapsed time" unless backoff <= duration && backoff <= api_ms / 1000.0
    inclusive_input = counts.fetch("input_tokens") + counts.fetch("cache_read_input_tokens") + counts.fetch("cache_creation_input_tokens")
    report.merge("outcome" => "completed", "usage_available" => true, "token_counts" => counts,
      "inclusive_input_tokens" => inclusive_input, "total_tokens" => inclusive_input + counts.fetch("output_tokens"),
      "thinking_tokens" => usage["thinkingTokens"], "raw_api_seconds" => api_ms / 1000.0,
      "retry_count" => retry_ms.size, "retry_backoff_seconds" => backoff,
      "total_seconds" => (duration - backoff).round(6), "api_seconds" => (api_ms / 1000.0 - backoff).round(6),
      "reported_cost_usd" => result["total_cost_usd"])
  rescue KeyError, JSON::ParserError, ArgumentError => e
    raise Invalid, e.message
  end

  # Claude Code may re-emit init in the same process after a background shell
  # finishes, then emit another result. modelUsage and API time remain cumulative;
  # use the final totals once, never sum the result snapshots or take turn usage.
  def verify_notification_continuation!(previous, current, model:, session:)
    unless current.dig("origin", "kind") == "task-notification" && current.dig("origin", "producer") == "session-task"
      raise Invalid, "Repeated initialization is not a task-notification continuation"
    end
    [previous, current].each do |record|
      raise Invalid, "Continuation session changed" unless record["session_id"] == session
      raise Invalid, "Continuation contains a terminal error" unless record["subtype"] == "success" && record["is_error"] == false
      raise Invalid, "Continuation model changed" unless record.fetch("modelUsage").keys == [model]
      raise Invalid, "Continuation spawned subagents" unless record.fetch("subagent_stats", {}).fetch("spawned", 0) == 0
      raise Invalid, "Continuation used server-side web search" unless record.fetch("modelUsage").fetch(model).fetch("webSearchRequests", 0) == 0
      server_tools = record.fetch("usage", {}).fetch("server_tool_use", {})
      raise Invalid, "Continuation used server-side web tools" unless server_tools.values.all? { |n| n == 0 }
    end
    COUNTERS.each_value do |key|
      before = previous.fetch("modelUsage").fetch(model).fetch(key)
      after = current.fetch("modelUsage").fetch(model).fetch(key)
      unless before.is_a?(Integer) && before >= 0 && after.is_a?(Integer) && after >= before
        raise Invalid, "Continuation token counters are not cumulative: #{key}"
      end
    end
    before, after = [previous, current].map { |r| r.fetch("duration_api_ms") }
    unless [before, after].all? { |n| n.is_a?(Numeric) && n.finite? && n >= 0 } && after >= before
      raise Invalid, "Continuation API duration is not cumulative"
    end
  end
end
