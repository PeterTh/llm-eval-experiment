require "minitest/autorun"
require "tmpdir"
require_relative "../lib/claude_generation_observation"

class ClaudeGenerationObservationTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("claude-observation-", "/tmp")
    @model = "claude-opus-5-5"
    @init = { "type" => "system", "subtype" => "init", "session_id" => "session", "model" => @model,
      "claude_code_version" => "2.1.287", "permissionMode" => "bypassPermissions", "mcp_servers" => [], "tools" => ["Bash", "Read"], "plugins" => [] }
    @result = { "type" => "result", "session_id" => "session", "subtype" => "success", "is_error" => false, "duration_api_ms" => 10000,
      "modelUsage" => { @model => { "inputTokens" => 10, "outputTokens" => 20, "cacheReadInputTokens" => 30, "cacheCreationInputTokens" => 40, "thinkingTokens" => 5 } } }
    @status = { "exit_status" => 0, "term_signal" => nil, "timeout_seconds" => 14400 }
    @events = [@init, @result]
    File.write(File.join(@directory, "instruction.txt"), "original prompt")
    File.write(File.join(@directory, "timing.txt"), "Duration: 12.34 seconds\n")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def read(**options)
    File.write(File.join(@directory, "process-status.txt"), JSON.generate(@status))
    File.write(File.join(@directory, "output.txt"), @events.map { |e| JSON.generate(e) + "\n" }.join)
    ClaudeGenerationObservation.read(@directory, model: @model, version: "2.1.287", **options)
  end

  def test_exact_usage_includes_cache_creation_and_does_not_add_thinking_twice
    report = read
    assert_equal "completed", report.fetch("outcome")
    assert_equal 80, report.fetch("inclusive_input_tokens")
    assert_equal 100, report.fetch("total_tokens")
    assert_equal 5, report.fetch("thinking_tokens")
    assert_equal 4, report.fetch("sha256").size
    # The checker does not demand that the generated program changed or passes validation.
  end

  def test_model_fallback_and_auxiliary_usage_are_not_mislabeled
    @result.fetch("modelUsage")["other"] = @result.fetch("modelUsage").fetch(@model)
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
    @result.fetch("modelUsage").delete("other")
    @events.insert(1, { "type" => "assistant", "message" => { "model" => "other" } })
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
  end

  def test_forbidden_tools_and_external_plugins_fail
    @init["tools"] << "Agent"
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
    @init["tools"].delete("Agent")
    @init["plugins"] << { "name" => "custom", "path" => "/a/plugin", "source" => "custom@installed" }
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
  end

  def test_capability_drift_requires_review
    baseline = read
    @init["tools"] << "NewTool"
    assert_raises(ClaudeGenerationObservation::Invalid) { read(baseline: baseline) }
  end

  def test_completed_retry_backoff_deduplicates_same_session_events
    retry_event = { "type" => "system", "subtype" => "api_retry", "session_id" => "session", "uuid" => "retry1", "retry_delay_ms" => 1500 }
    @events.insert(1, retry_event, retry_event, retry_event.merge("session_id" => "other", "uuid" => "other", "retry_delay_ms" => 100000))
    report = read
    assert_equal 1, report.fetch("retry_count")
    assert_equal 10.84, report.fetch("total_seconds")
    assert_equal 8.5, report.fetch("api_seconds")
    assert_equal "Duration: 12.34 seconds\n", File.read(File.join(@directory, "timing.txt"))
  end

  def test_genuine_full_budget_timeout_is_retained_not_retried
    @events.pop
    @status["exit_status"] = 124
    File.write(File.join(@directory, "timing.txt"), "Duration: 14400.15 seconds\n")
    assert_equal "generation_timeout", read.fetch("outcome")
    File.write(File.join(@directory, "timing.txt"), "Duration: 1.00 seconds\n")
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
  end

  def test_terminal_error_and_invalid_counters_are_not_admitted
    @result["is_error"] = true
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
    @result["is_error"] = false
    @result["modelUsage"][@model]["inputTokens"] = -1
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
  end

  def notification_continuation
    first_result = JSON.parse(JSON.generate(@result))
    @result["origin"] = { "kind" => "task-notification", "producer" => "session-task" }
    @result["duration_api_ms"] += 400
    @result["modelUsage"][@model]["outputTokens"] += 7
    @result["usage"] = { "output_tokens" => 7 } # Per-turn usage is not the cumulative total.
    repeated_init = JSON.parse(JSON.generate(@init)).merge("uuid" => "new-event-uuid")
    notification = { "type" => "system", "subtype" => "task_notification", "session_id" => "session", "task_id" => "background-shell" }
    @events = [@init, first_result, notification, repeated_init, @result]
  end

  def test_same_session_background_notification_uses_final_cumulative_totals_once
    notification_continuation
    report = read
    assert_equal "completed", report.fetch("outcome")
    assert_equal 107, report.fetch("total_tokens")
    assert_equal 27, report.fetch("token_counts").fetch("output_tokens")
    assert_equal 10.4, report.fetch("api_seconds")
    assert_equal 12.34, report.fetch("total_seconds")
  end

  def test_repeated_initialization_still_rejects_identity_or_capability_changes
    %w[session_id model cwd tools].each do |key|
      @events = [@init, @result]
      notification_continuation
      @events[3][key] = key == "tools" ? ["Bash", "Read", "NewTool"] : "changed"
      assert_raises(ClaudeGenerationObservation::Invalid) { read }
    end
  end

  def test_repeated_initialization_requires_same_session_notification_and_origin
    notification_continuation
    @events[2]["session_id"] = "other-session"
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
    @events[2]["session_id"] = "session"
    @result.delete("origin")
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
    @events.delete_at(2)
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
  end

  def test_continuation_cannot_reset_counters_or_hide_a_previous_terminal_error
    notification_continuation
    @result["modelUsage"][@model]["outputTokens"] = 7
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
    @result["modelUsage"][@model]["outputTokens"] = 27
    @result["duration_api_ms"] = 400
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
    @result["duration_api_ms"] = 10400
    @events[1]["is_error"] = true
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
  end

  def test_notification_continuation_requires_its_own_terminal_record
    notification_continuation
    @events.pop
    assert_raises(ClaudeGenerationObservation::Invalid) { read }
  end
end
