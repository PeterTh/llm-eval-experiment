# frozen_string_literal: true
require_relative "../lib/opencode_generation_observation"
require "fileutils"

module OpenCodeFixture
  def opencode_fixture(directory, timeout: false, model: "openai/gpt-6.1-sol", advertised_output: false)
    FileUtils.mkdir_p(directory)
    effort = OpenCodeHarness::CAMPAIGN_PROFILES.values.find { |profile| profile["model"] == model }.fetch("reasoning_effort")
    provider, model_id = model.split("/", 2)
    config = OpenCodeHarness.config(model: model, effort: effort)
    tools = model.start_with?("opencode-go/") ? %w[bash edit glob grep invalid read skill todowrite write] : %w[apply_patch bash glob grep invalid read skill todowrite]
    agent = { "name" => "build", "native" => true, "tools" => tools.to_h { |tool| [tool, true] },
      "permission" => config.fetch("permission").map { |permission, action| { "permission" => permission, "pattern" => "*", "action" => action } } }
    @evidence = { "version" => OpenCodeHarness::VERSION, "binary_sha256" => OpenCodeHarness::BINARY_SHA256,
      "auth_type" => OpenCodeHarness.auth_type(model), "model" => model, "reasoning_effort" => effort,
      "flags" => OpenCodeHarness::FLAGS, "requested_config" => config, "resolved_config" => config,
      "build_agent" => agent, "enabled_tools" => tools,
      "resolved_model" => { "options" => OpenCodeHarness.reasoning_options(model, effort),
        "variants" => { effort => OpenCodeHarness.reasoning_options(model, effort) } } }
    @evidence["resolved_model"]["api"] = { "npm" => "@ai-sdk/anthropic" } if model == "opencode-go/claude-haiku-5-5"
    if OpenCodeHarness.output_token_policy(model)
      @evidence["resolved_model"]["limit"] = { "context" => 1_000_000, "output" => OpenCodeHarness::GO_OUTPUT_TOKEN_LIMITS.fetch(model) }
    end
    if advertised_output
      @evidence["output_token_policy"] = OpenCodeHarness.output_token_policy(model)
      @evidence["flags"] = OpenCodeHarness.flags(model: model)
    end
    @sid = "ses_test"
    @session = { "info" => { "id" => @sid, "version" => OpenCodeHarness::VERSION,
      "title" => File.basename(directory), "directory" => "/evals/#{File.basename(directory)}" }, "messages" => [
      { "info" => { "id" => "msg_user", "role" => "user", "sessionID" => @sid,
        "model" => { "providerID" => provider, "modelID" => model_id, "variant" => effort } }, "parts" => [] },
      { "info" => { "id" => "msg_assistant", "role" => "assistant", "sessionID" => @sid, "providerID" => provider,
        "modelID" => model_id, "variant" => effort, "agent" => "build", "finish" => "stop", "time" => { "completed" => 20000 } },
        "parts" => [{ "id" => "part_finish", "messageID" => "msg_assistant", "sessionID" => @sid, "type" => "step-finish", "reason" => "stop",
          "tokens" => { "input" => 20, "output" => 6, "reasoning" => 4, "cache" => { "read" => 80, "write" => 0 }, "total" => 110 } }] }
    ] }
    @process = { "exit_status" => timeout ? 124 : 0, "term_signal" => nil, "timeout_seconds" => 14400,
      "generation_finished_at" => "1970-01-01T00:00:20Z", "cli_wall_seconds" => timeout ? 14400.1 : 19 }
    @events = [[1000, { "type" => "busy" }], [2000, { "type" => "retry", "attempt" => 1, "next" => 4000 }],
      [4001, { "type" => "busy" }], [20000, { "type" => "idle" }]].map.with_index do |(at, status), index|
      { "received_at_ms" => at, "event" => { "id" => "event_#{index}", "type" => "session.status",
        "properties" => { "sessionID" => @sid, "status" => status } } }
    end
    File.write(File.join(directory, "instruction.txt"), "unchanged production prompt")
    File.write(File.join(directory, "timing.txt"), "Duration: #{timeout ? 14401 : 20} seconds\n")
    write_opencode_fixture(directory)
  end

  def write_opencode_fixture(directory)
    { "opencode-config.txt" => @evidence, "opencode-session.txt" => @session,
      "process-status.txt" => @process, "opencode-process.txt" => @process }.each do |name, value|
      File.write(File.join(directory, name), JSON.generate(value) + "\n")
    end
    parts = @session.fetch("messages").flat_map { |m| m.fetch("parts") }.select { |part| part["type"] == "step-finish" }
    accounting = parts.map { |part| { "received_at_ms" => 19999, "event" => { "type" => "message.part.updated", "properties" => { "part" => part } } } }
    File.write(File.join(directory, "opencode-events.txt"), (@events + accounting).map { |row| JSON.generate(row) + "\n" }.join)
    File.write(File.join(directory, "output.txt"), parts.map { |part| JSON.generate({ "type" => "step_finish", "sessionID" => @sid, "part" => part }) + "\n" }.join)
  end
end
