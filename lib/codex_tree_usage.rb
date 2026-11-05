# frozen_string_literal: true
require_relative "codex_usage"

# Native multi-agent accounting, recovered only after the isolated process tree
# exits. Read the observation's bound archives, not the account's session history.
module CodexTreeUsage
  SOURCE = "codex_rollout_unique_thread_requests"
  SCOPE = "parent_and_descendants"
  TASK_EVENTS = %w[task_started task_complete task_aborted turn_aborted task_failed].freeze
  UUID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/
  module_function

  def zero
    CodexUsage::FIELDS.to_h { |field| [field, 0] }
  end

  def normalized(usage)
    CodexUsage.validate_usage!(usage)
    zero.merge(usage)
  end

  def sum(usages)
    usages.each_with_object(zero) { |usage, total| normalized(usage).each { |key, value| total[key] += value } }
  end

  def relative_path!(path)
    unless path.is_a?(String) && !path.empty? && !path.start_with?("/") &&
        path.split("/").none? { |part| ["", ".", ".."].include?(part) }
      raise CodexUsage::Invalid, "Unsafe tree archive path"
    end
  end

  def validate_record!(record)
    raise CodexUsage::Invalid, "Unsupported tree usage record" unless record["source"] == SOURCE && record["accounting_scope"] == SCOPE
    # Preserve the terminal count's meaning: it describes the root, not the tree.
    CodexUsage.validate_record!(record.merge("schema_version" => 1, "source" => CodexUsage::SOURCE,
      "usage" => record.fetch("root_usage")))
    sessions = record.fetch("sessions")
    raise CodexUsage::Invalid, "Missing tree sessions" unless sessions.is_a?(Array) && !sessions.empty?
    ids = sessions.map { |s| s.fetch("session_id") }
    paths = sessions.map { |s| s.fetch("session_path") }
    unless ids.uniq == ids && paths.uniq == paths && ids.all? { |id| id.is_a?(String) && id.match?(UUID) }
      raise CodexUsage::Invalid, "Duplicate/invalid tree session"
    end
    root = sessions.find { |s| s["session_id"] == record["session_id"] }
    raise CodexUsage::Invalid, "Missing tree root" unless root && root["parent_session_id"].nil? && root["final_task_event"] == "task_complete"
    %w[session_path session_sha256 session_cwd cli_version token_count_timestamp].each do |field|
      raise CodexUsage::Invalid, "Tree root #{field} differs" unless root[field] == record[field]
    end
    raise CodexUsage::Invalid, "Root counters differ" unless root["usage"] == record["root_usage"] && root["final_task_timestamp"] == record["task_completed_at"]
    sessions.each do |s|
      relative_path!(s.fetch("session_path"))
      raise CodexUsage::Invalid, "Invalid archive fingerprint" unless s["session_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) && s["session_bytes"].is_a?(Integer) && s["session_bytes"] > 0
      raise CodexUsage::Invalid, "Invalid request count" unless s["request_count"].is_a?(Integer) && s["request_count"] >= 0
      raise CodexUsage::Invalid, "Session identity differs" unless s.values_at("model", "reasoning_effort", "cli_version", "session_cwd") == record.values_at("model", "reasoning_effort", "cli_version", "session_cwd")
      raise CodexUsage::Invalid, "Missing model identity" unless [s["model"], s["reasoning_effort"]].all? { |v| v.is_a?(String) && !v.empty? }
      normalized(s.fetch("usage"))
      # Every branch must reach this root, without missing parents or cycles.
      node, seen = s, []
      until node["session_id"] == root["session_id"]
        raise CodexUsage::Invalid, "Cyclic tree" if seen.include?(node["session_id"])
        seen << node["session_id"]
        node = sessions.find { |parent| parent["session_id"] == node["parent_session_id"] }
        raise CodexUsage::Invalid, "Disconnected tree" unless node
      end
    end
    interrupted = sessions.reject { |s| s["final_task_event"] == "task_complete" }.map { |s| s["session_id"] }
    unless record["interrupted_sessions"] == interrupted && record["interrupted_request_usage_uncertain"] == !interrupted.empty?
      raise CodexUsage::Invalid, "Missing interruption uncertainty"
    end
    raise CodexUsage::Invalid, "Tree counters differ" unless record["usage"] == sum(sessions.map { |s| s.fetch("usage") })
    raise CodexUsage::Invalid, "Tree request count differs" unless record["request_count"] == sessions.sum { |s| s.fetch("request_count") }
    record
  rescue KeyError => e
    raise CodexUsage::Invalid, e.message
  end

  def recover(request, sessions_root:)
    entries = request.fetch("archived_sessions")
    raise CodexUsage::Invalid, "No bound tree archives" unless entries.is_a?(Array) && !entries.empty?
    root_dir = File.realpath(sessions_root)
    responses = {}
    sessions = entries.map do |entry|
      relative_path!(entry.fetch("path"))
      path = File.join(root_dir, entry.fetch("path"))
      raise CodexUsage::Invalid, "Linked tree archive" unless File.realpath(path) == path
      digest = Digest::SHA256.new
      bytes = 0
      meta, counter, thread_usage, task = nil
      model_contexts, contexts = [], []
      usage, requests = zero, 0
      File.foreach(path).with_index do |line, index|
        digest.update(line)
        bytes += line.bytesize
        event = JSON.parse(line)
        payload = event.fetch("payload")
        if index.zero?
          raise CodexUsage::Invalid, "Missing leading session metadata" unless event["type"] == "session_meta"
          meta = payload
        end
        case event["type"]
        when "turn_context"
          model_contexts << payload.values_at("model", "effort")
        when "token_usage_record"
          raise CodexUsage::Invalid, "Inherited/foreign request counters" unless payload.fetch("thread_id") == meta.fetch("id")
          response = payload.fetch("response_id")
          raise CodexUsage::Invalid, "Repeated/missing request identity" unless response.is_a?(String) && !response.empty? && !responses.key?(response)
          responses[response] = meta.fetch("id")
          normalized(payload.fetch("usage")).each { |key, value| usage[key] += value }
          thread_usage = normalized(payload.fetch("thread_token_usage"))
          requests += 1
        when "event_msg"
          type = payload["type"]
          task = [type, event["timestamp"]] if TASK_EVENTS.include?(type)
          if type == "token_count" && payload["info"]
            info = payload.fetch("info")
            counter = [event.fetch("timestamp"), normalized(info.fetch("total_token_usage"))]
            contexts << info["model_context_window"]
          end
        end
      end
      raise CodexUsage::Invalid, "Bound archive changed" unless digest.hexdigest == entry.fetch("sha256") && bytes == entry.fetch("bytes")
      expected = request.values_at("model", "reasoning_effort")
      raise CodexUsage::Invalid, "Model/effort differs in tree" unless model_contexts.all? { |pair| pair == expected } && (requests.zero? || !model_contexts.empty?)
      if request["expected_context_window"] && contexts.any? { |v| v != request["expected_context_window"] }
        raise CodexUsage::Invalid, "Model context metadata differs in tree"
      end
      if requests > 0
        raise CodexUsage::Invalid, "Request and cumulative counters disagree" unless counter && counter[1] == usage && thread_usage == usage
      elsif (counter && counter[1] != zero) || task&.first == "task_complete"
        raise CodexUsage::Invalid, "Unexplained session counters"
      end
      { "session_id" => meta.fetch("id"), "parent_session_id" => meta["forked_from_id"],
        "session_cwd" => meta.fetch("cwd"), "cli_version" => meta.fetch("cli_version"),
        "session_path" => entry.fetch("path"), "session_sha256" => digest.hexdigest, "session_bytes" => bytes,
        "model" => expected[0], "reasoning_effort" => expected[1], "request_count" => requests,
        "usage" => usage, "token_count_timestamp" => counter&.first,
        "final_task_event" => task&.first, "final_task_timestamp" => task&.last }
    end
    root = sessions.find { |s| s.fetch("session_id") == request.fetch("session_id") }
    raise CodexUsage::Invalid, "Root not archived" unless root
    record = request.reject { |key, _| %w[archived_sessions expected_context_window].include?(key) }.merge(
      "schema_version" => 2, "source" => SOURCE, "accounting_scope" => SCOPE,
      "sessions" => sessions, "usage" => sum(sessions.map { |s| s.fetch("usage") }),
      "root_usage" => root.fetch("usage"), "request_count" => sessions.sum { |s| s.fetch("request_count") },
      "task_completed_at" => root.fetch("final_task_timestamp"))
    %w[session_path session_sha256 session_cwd cli_version token_count_timestamp].each { |key| record[key] = root.fetch(key) }
    record["interrupted_sessions"] = sessions.reject { |s| s["final_task_event"] == "task_complete" }.map { |s| s.fetch("session_id") }
    record["interrupted_request_usage_uncertain"] = !record.fetch("interrupted_sessions").empty?
    validate_record!(record)
  rescue KeyError, JSON::ParserError => e
    raise CodexUsage::Invalid, e.message
  end
end
