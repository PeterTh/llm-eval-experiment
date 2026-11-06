# frozen_string_literal: true
require_relative 'codex_tree_usage'

# Post-generation request-level pricing evidence for native delegation. Only the
# already-bound session files are read, never a glob over account history.
module CodexTreeRequests
  module_function

  def counters(value)
    selected = value.slice(*CodexUsage::FIELDS)
    CodexUsage.validate_usage!(selected)
    raise CodexUsage::Invalid, 'Missing request counters; do not infer zero' unless selected.keys.sort == CodexUsage::FIELDS.sort
    selected
  end

  def signature(usage) = CodexUsage::FIELDS.map { |field| usage.fetch(field) }

  def recover(record, sessions_root:)
    CodexTreeUsage.validate_record!(record)
    directory = File.realpath(sessions_root)
    seen, requests, windows = {}, [], []
    snapshots_verified = 0
    sessions = record.fetch('sessions').map do |session|
      CodexTreeUsage.relative_path!(session.fetch('session_path'))
      path = File.join(directory, session.fetch('session_path'))
      raise CodexUsage::Invalid, 'Linked tree archive' unless File.realpath(path) == path
      digest, size = Digest::SHA256.new, 0
      totals = CodexTreeUsage.zero
      prefixes = { signature(totals) => [totals.dup] }
      snapshots, count, last_event, last_event_at, last_count_at = [], 0, nil, nil, nil
      models = []
      File.foreach(path).with_index do |line, index|
        digest.update(line)
        size += line.bytesize
        event = JSON.parse(line)
        payload = event.fetch('payload')
        if index.zero?
          expected = session.values_at('session_id', 'parent_session_id', 'session_cwd', 'cli_version')
          unless event.fetch('type') == 'session_meta' && payload.values_at('id', 'forked_from_id', 'cwd', 'cli_version') == expected
            raise CodexUsage::Invalid, 'Request archive identity differs'
          end
        end
        case event.fetch('type')
        when 'turn_context'
          models << payload.values_at('model', 'effort')
        when 'token_usage_record'
          raise CodexUsage::Invalid, 'Foreign thread request' unless payload.fetch('thread_id') == session.fetch('session_id')
          response = payload.fetch('response_id')
          raise CodexUsage::Invalid, 'Missing or repeated tree request' unless response.is_a?(String) && !response.empty? && !seen.key?(response)
          seen[response] = true
          usage = counters(payload.fetch('usage'))
          cumulative = counters(payload.fetch('thread_token_usage'))
          totals.each_key { |field| totals[field] += usage.fetch(field) }
          raise CodexUsage::Invalid, 'Request sum differs from cumulative counters' unless totals == cumulative
          (prefixes[signature(totals)] ||= []) << usage
          requests << { 'response_id_sha256' => Digest::SHA256.hexdigest(response),
            'session_id' => session.fetch('session_id'), 'timestamp' => event.fetch('timestamp'), 'usage' => usage }
          count += 1
        when 'event_msg'
          kind = payload['type']
          if CodexTreeUsage::TASK_EVENTS.include?(kind)
            last_event, last_event_at = kind, event.fetch('timestamp')
          end
          if kind == 'token_count' && payload['info']
            info = payload.fetch('info')
            snapshots << [counters(info.fetch('total_token_usage')), counters(info.fetch('last_token_usage'))]
            windows << info.fetch('model_context_window')
            last_count_at = event.fetch('timestamp')
          end
        end
      end
      raise CodexUsage::Invalid, 'Bound request archive changed' unless digest.hexdigest == session.fetch('session_sha256') && size == session.fetch('session_bytes')
      raise CodexUsage::Invalid, 'Request model or effort differs' unless models.all? { |pair| pair == session.values_at('model', 'reasoning_effort') } && (count.zero? || !models.empty?)
      raise CodexUsage::Invalid, 'Request totals differ from recorded session' unless count == session.fetch('request_count') && totals == session.fetch('usage')
      unless [last_event, last_event_at, last_count_at] == session.values_at('final_task_event', 'final_task_timestamp', 'token_count_timestamp')
        raise CodexUsage::Invalid, 'Session completion/counter metadata differs'
      end
      snapshots.each do |cumulative, last|
        raise CodexUsage::Invalid, 'Independent token-count stream differs' unless prefixes.fetch(signature(cumulative), []).include?(last)
      end
      raise CodexUsage::Invalid, 'Missing final token-count corroboration' if count.positive? && (snapshots.empty? || snapshots.last.first != totals)
      snapshots_verified += snapshots.size
      session.slice('session_id', 'parent_session_id', 'session_path', 'session_sha256', 'session_bytes',
        'request_count', 'final_task_event').merge('token_count_snapshots_verified' => snapshots.size)
    end
    total = CodexTreeUsage.sum(requests.map { |request| request.fetch('usage') })
    raise CodexUsage::Invalid, 'Whole-tree request totals differ' unless total == record.fetch('usage') && requests.size == record.fetch('request_count')
    raise CodexUsage::Invalid, 'Invalid native context metadata' unless windows.all? { |value| value.is_a?(Integer) && value.positive? }
    { 'schema_version' => 2, 'source' => 'codex_native_tree_request_usage',
      'batch' => record.fetch('batch'), 'run_id' => record.fetch('run_id'),
      'session_id' => record.fetch('session_id'), 'accounting_scope' => CodexTreeUsage::SCOPE,
      'final_record_sha256' => Digest::SHA256.hexdigest(JSON.generate(record)),
      'request_count' => requests.size, 'sessions' => sessions,
      'token_count_snapshots_verified' => snapshots_verified,
      'max_request_input_tokens' => requests.map { |request| request.fetch('usage').fetch('input_tokens') }.max,
      'model_context_windows' => windows.uniq.sort, 'total_usage' => total, 'requests' => requests,
      'interrupted_sessions' => record.fetch('interrupted_sessions'),
      'interrupted_request_usage_uncertain' => record.fetch('interrupted_request_usage_uncertain') }
  rescue KeyError, JSON::ParserError => error
    raise CodexUsage::Invalid, error.message
  end
end
