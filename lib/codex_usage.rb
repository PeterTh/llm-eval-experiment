# frozen_string_literal: true

require "json"
require "digest"

# Compact, provenance-bound usage evidence; never retains prompts or credentials.
module CodexUsage
  class Invalid < StandardError; end
  REQUIRED = %w[input_tokens cached_input_tokens output_tokens total_tokens].freeze
  OPTIONAL = %w[reasoning_output_tokens cache_write_input_tokens].freeze
  FIELDS = (REQUIRED + OPTIONAL).freeze
  SOURCE = "codex_rollout_final_cumulative"
  module_function

  def validate_usage!(usage)
    raise Invalid, "missing token counters" unless usage.is_a?(Hash)
    raise Invalid, "incomplete token counters" unless (REQUIRED - usage.keys).empty?
    usage.each do |key, value|
      raise Invalid, "invalid #{key}" unless FIELDS.include?(key) && value.is_a?(Integer) && value >= 0
    end
    raise Invalid, "token total mismatch" unless usage["total_tokens"] == usage["input_tokens"] + usage["output_tokens"]
    raise Invalid, "cached input exceeds input" if usage["cached_input_tokens"] > usage["input_tokens"]
    raise Invalid, "reasoning exceeds output" if usage.fetch("reasoning_output_tokens", 0) > usage["output_tokens"]
    raise Invalid, "cache writes exceed input" if usage.fetch("cache_write_input_tokens", 0) > usage["input_tokens"]
    usage
  end

  def validate_record!(record)
    raise Invalid, "unsupported usage record" unless record.is_a?(Hash) && record["schema_version"] == 1 && record["source"] == SOURCE
    %w[batch run_id session_id cli_version session_path session_cwd token_count_timestamp task_completed_at].each do |field|
      raise Invalid, "missing #{field}" unless record[field].is_a?(String) && !record[field].empty?
    end
    unless record["session_id"].match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/)
      raise Invalid, "invalid session ID"
    end
    unless File.basename(record["session_cwd"]) == record["run_id"] &&
           File.basename(File.dirname(record["session_cwd"])) == record["batch"]
      raise Invalid, "session working directory differs from batch/run"
    end
    session_path = record["session_path"]
    if session_path.start_with?("/") || session_path.split("/").any? { |part| ["", ".", ".."].include?(part) }
      raise Invalid, "session path must be relative to the sessions directory"
    end
    %w[transcript_sha256 session_sha256].each do |field|
      raise Invalid, "invalid #{field}" unless record[field].is_a?(String) && record[field].match?(/\A[0-9a-f]{64}\z/)
    end
    usage = validate_usage!(record["usage"])
    legacy = record["legacy_reported_tokens"]
    unless legacy.is_a?(Integer) && legacy >= 0 && legacy == usage["total_tokens"] - usage["cached_input_tokens"]
      raise Invalid, "terminal count disagrees with recovered usage"
    end
    record
  end

  def load_records(path)
    records = {}
    File.foreach(path) do |line|
      record = validate_record!(JSON.parse(line))
      id = record.fetch("run_id")
      raise Invalid, "duplicate usage ID #{id}" if records.key?(id)
      records[id] = record
    end
    raise Invalid, "empty usage evidence" if records.empty?
    records
  end

  def transcript_request(batch:, id:, path:)
    head, tail = File.open(path, "rb") do |file|
      first = file.read(8192)
      file.seek([file.size - 65536, 0].max)
      [first.to_s, file.read]
    end
    sid = head[/^session id: ([0-9a-f-]+)\s*$/, 1]
    printed = tail.scan(/^tokens used\s*\n\s*([\d,]+)\s*$/i).last&.first
    raise Invalid, "missing Codex identity/terminal usage for #{id}" unless sid && printed
    { "batch" => batch, "run_id" => id, "session_id" => sid,
      "legacy_reported_tokens" => printed.delete(",").to_i,
      "transcript_sha256" => Digest::SHA256.file(path).hexdigest }
  end

  def recover(request, path, sessions_root:)
    digest = Digest::SHA256.new
    meta = nil
    counter = nil
    completed = nil
    final_task_event = nil
    last_thread_usage = nil
    File.foreach(path).with_index(1) do |line, number|
      digest.update(line)
      event = JSON.parse(line)
      payload = event["payload"]
      raise Invalid, "non-object rollout event at #{number}" unless payload.is_a?(Hash)
      if number == 1
        raise Invalid, "rollout lacks leading session_meta" unless event["type"] == "session_meta"
        meta = payload
        unless meta["id"] == request.fetch("session_id") &&
               File.basename(meta.fetch("cwd")) == request.fetch("run_id") &&
               File.basename(File.dirname(meta.fetch("cwd"))) == request.fetch("batch")
          raise Invalid, "session identity mismatch for #{request.fetch('run_id')}"
        end
      end
      if event["type"] == "event_msg"
        type = payload["type"]
        if type == "token_count" && payload.dig("info", "total_token_usage")
          counter = [event["timestamp"], payload.fetch("info").fetch("total_token_usage").slice(*FIELDS)]
        end
        final_task_event = type if %w[task_started task_complete task_aborted turn_aborted task_failed].include?(type)
        completed = event["timestamp"] if type == "task_complete"
      elsif event["type"] == "token_usage_record" && payload["thread_token_usage"]
        last_thread_usage = payload.fetch("thread_token_usage").slice(*FIELDS)
      end
    end
    raise Invalid, "session did not complete" unless completed && final_task_event == "task_complete"
    raise Invalid, "session has no cumulative usage" unless counter
    usage = validate_usage!(counter[1])
    if last_thread_usage && last_thread_usage != usage
      raise Invalid, "cumulative usage sources disagree"
    end
    record = request.merge(
      "schema_version" => 1, "source" => SOURCE, "usage" => usage,
      "cli_version" => meta.fetch("cli_version"), "session_cwd" => meta.fetch("cwd"),
      "session_path" => path.delete_prefix(File.expand_path(sessions_root) + "/"),
      "session_sha256" => digest.hexdigest, "token_count_timestamp" => counter[0],
      "task_completed_at" => completed
    )
    validate_record!(record)
  end

  def verify_transcript!(record, id:, batch:, path:)
    validate_record!(record)
    request = transcript_request(batch: batch, id: id, path: path)
    request.each do |key, value|
      raise Invalid, "usage/transcript #{key} mismatch for #{id}" unless record[key] == value
    end
    record.fetch("usage")
  end
end
