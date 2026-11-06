# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/codex_tree_requests'

class CodexTreeRequestsTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('tree-request-test-', '/tmp')
    @root = '01234567-89ab-cdef-0123-456789abcdef'
    @child = '01234567-89ab-cdef-0123-456789abcdea'
    @usage = { 'input_tokens' => 100, 'cached_input_tokens' => 80, 'output_tokens' => 10,
      'total_tokens' => 110, 'reasoning_output_tokens' => 4, 'cache_write_input_tokens' => 0 }
    @events = { @root => events(@root), @child => events(@child, parent: @root, ending: 'turn_aborted') }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def events(id, parent: nil, ending: 'task_complete')
    [
      ['session_meta', { 'id' => id, 'forked_from_id' => parent, 'cwd' => '/evals/batch/run', 'cli_version' => '0.160.1' }],
      ['turn_context', { 'model' => 'gpt-6.1-terra', 'effort' => 'ultra' }],
      ['event_msg', { 'type' => 'task_started' }],
      ['token_usage_record', { 'thread_id' => id, 'response_id' => 'response-' + id,
        'usage' => @usage.dup, 'thread_token_usage' => @usage.dup }],
      ['event_msg', { 'type' => 'token_count', 'info' => { 'total_token_usage' => @usage.dup,
        'last_token_usage' => @usage.dup, 'model_context_window' => 475000 } }],
      ['event_msg', { 'type' => ending }]
    ].map { |kind, payload| { 'type' => kind, 'timestamp' => '2026-11-06T00:00:00Z', 'payload' => payload } }
  end

  def record
    entries = @events.map do |id, rows|
      path = File.join(@directory, id + '.jsonl')
      File.binwrite(path, rows.map { |row| JSON.generate(row) + "\n" }.join)
      { 'path' => File.basename(path), 'sha256' => Digest::SHA256.file(path).hexdigest, 'bytes' => File.size(path) }
    end
    CodexTreeUsage.recover({ 'batch' => 'batch', 'run_id' => 'run', 'session_id' => @root,
      'legacy_reported_tokens' => 30, 'transcript_sha256' => 'a' * 64,
      'model' => 'gpt-6.1-terra', 'reasoning_effort' => 'ultra', 'archived_sessions' => entries }, sessions_root: @directory)
  end

  def test_recovers_tree_requests_and_preserves_uncertainty
    result = CodexTreeRequests.recover(record, sessions_root: @directory)
    assert_equal 220, result.fetch('total_usage').fetch('total_tokens')
    assert_equal 2, result.fetch('request_count')
    assert_equal 2, result.fetch('token_count_snapshots_verified')
    assert_equal [@root, @child], result.fetch('requests').map { |request| request.fetch('session_id') }
    assert result.fetch('interrupted_request_usage_uncertain')
    assert_equal [475000], result.fetch('model_context_windows')
  end

  def test_empty_interrupted_child_never_fabricates_a_request
    @events[@child].slice!(3, 2)
    result = CodexTreeRequests.recover(record, sessions_root: @directory)
    assert_equal 1, result.fetch('request_count')
    assert_equal 2, result.fetch('sessions').size
    assert result.fetch('interrupted_request_usage_uncertain')
  end

  def test_missing_optional_request_counter_is_not_assumed_zero
    @events[@child][3]['payload']['usage'].delete('cache_write_input_tokens')
    assert_raises(CodexUsage::Invalid) { CodexTreeRequests.recover(record, sessions_root: @directory) }
  end

  def test_independent_last_usage_must_match_a_real_request
    @events[@child][4]['payload']['info']['last_token_usage'] = CodexTreeUsage.zero
    assert_raises(CodexUsage::Invalid) { CodexTreeRequests.recover(record, sessions_root: @directory) }
  end

  def test_changed_file_or_symlink_is_rejected
    original = record
    path = File.join(@directory, @child + '.jsonl')
    File.open(path, 'a') { |file| file.write("\n") }
    assert_raises(CodexUsage::Invalid) { CodexTreeRequests.recover(original, sessions_root: @directory) }
    original = record
    File.rename(path, path + '.target')
    File.symlink(path + '.target', path)
    assert_raises(CodexUsage::Invalid) { CodexTreeRequests.recover(original, sessions_root: @directory) }
  end

  def test_unrelated_account_files_are_never_read
    original = record
    File.binwrite(File.join(@directory, 'unrelated.jsonl'), 'not JSON')
    assert_equal 2, CodexTreeRequests.recover(original, sessions_root: @directory).fetch('request_count')
  end
end
