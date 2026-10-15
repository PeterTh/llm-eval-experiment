require "json"
require "digest"
require "fileutils"

module ClaudeRecoveryFixture
  def write_recovered_observation(directory, model: "claude-sonnet-5-5", version: "2.1.296", batch: "20261014-212207")
    FileUtils.mkdir_p(directory)
    init = { "type" => "system", "subtype" => "init", "session_id" => "recovered-session", "model" => model,
      "claude_code_version" => version, "permissionMode" => "bypassPermissions", "mcp_servers" => [], "tools" => ["Bash"], "plugins" => [] }
    result = { "type" => "result", "session_id" => "recovered-session", "subtype" => "success", "is_error" => false,
      "terminal_reason" => "completed", "duration_ms" => 865229, "duration_api_ms" => 61451,
      "modelUsage" => { model => { "inputTokens" => 28, "outputTokens" => 7633, "cacheReadInputTokens" => 288686,
        "cacheCreationInputTokens" => 26226, "thinkingTokens" => 1717 } } }
    File.write(File.join(directory, "output.txt"), [init, result].map { |event| JSON.generate(event) + "\n" }.join)
    File.write(File.join(directory, "timing.txt"), "Start time: unavailable (generation wrapper terminated)\nEnd time: unavailable (generation wrapper terminated)\nDuration: 865.229 seconds\nGeneration time source: claude_result_duration_ms (recovered)\n")
    File.write(File.join(directory, "process-status.txt"), JSON.generate({ "exit_status" => nil, "term_signal" => nil,
      "success" => nil, "timeout_seconds" => 14400, "status_source" => "unavailable_controller_terminated" }))
    File.write(File.join(directory, "instruction.txt"), "unchanged production prompt")
    File.write(File.join(directory, "usage.txt"), "Result record: #{JSON.generate(result)}\n")
    record = { "schema_version" => 1, "reason" => "controller_oom", "approved_by" => "user", "decision" => "retain_completed_native_result",
      "run_id" => File.basename(directory), "campaign_id" => batch, "session_id" => "recovered-session", "model" => model, "version" => version,
      "incident_sha256" => "a" * 64, "duration_ms" => 865229, "generation_time_source" => "claude_result_duration_ms",
      "generation_time_recovered" => true, "wrapper_exit_status_available" => false,
      "wrapper_wall_time_seconds" => nil, "wrapper_start_time" => nil, "wrapper_end_time" => nil }
    write_recovery_record(directory, record)
    record
  end

  def write_recovery_record(directory, record)
    record["metadata_sha256"] = ClaudeGenerationRecovery::METADATA.to_h do |name|
      [name, Digest::SHA256.file(File.join(directory, name)).hexdigest]
    end
    File.write(File.join(directory, ClaudeGenerationRecovery::FILENAME), JSON.pretty_generate(record) + "\n")
  end
end
