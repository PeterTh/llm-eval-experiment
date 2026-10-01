# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/codex_usage"
require_relative "../lib/local_evaluation"

class CodexUsageTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("codex-usage-test-")
    @sid = "01234567-89ab-cdef-0123-456789abcdef"
    @transcript = File.join(@tmp, "output.txt")
    File.write(@transcript, "session id: #{@sid}\ntokens used\n30\n")
    @request = CodexUsage.transcript_request(batch: "batch", id: "run", path: @transcript)
    @usage = {"input_tokens" => 100, "cached_input_tokens" => 80, "output_tokens" => 10,
              "total_tokens" => 110, "reasoning_output_tokens" => 4, "cache_write_input_tokens" => 0}
    @events = [
      {type: "session_meta", payload: {id: @sid, cwd: "/evals/batch/run", cli_version: "0.159.0"}},
      {type: "event_msg", timestamp: "start", payload: {type: "task_started"}},
      {type: "event_msg", timestamp: "count", payload: {type: "token_count", info: {total_token_usage: @usage}}},
      {type: "event_msg", timestamp: "count-again", payload: {type: "token_count", info: {total_token_usage: @usage}}},
      {type: "token_usage_record", payload: {thread_token_usage: @usage}},
      {type: "event_msg", timestamp: "done", payload: {type: "task_complete"}}
    ]
    @session = File.join(@tmp, "rollout.jsonl")
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def recover
    File.write(@session, @events.map { |e| JSON.generate(e) + "\n" }.join)
    CodexUsage.recover(@request, @session, sessions_root: @tmp)
  end

  def test_uses_final_cumulative_count_once_and_retains_provenance
    record = recover
    assert_equal @usage, record.fetch("usage")
    assert_equal Digest::SHA256.file(@session).hexdigest, record.fetch("session_sha256")
    assert_equal "rollout.jsonl", record.fetch("session_path")
    assert_equal "count-again", record.fetch("token_count_timestamp")
    assert_equal 30, record.fetch("legacy_reported_tokens")
    assert_equal @usage, CodexUsage.verify_transcript!(record, id: "run", batch: "batch", path: @transcript)
  end

  def test_rejects_wrong_identity_and_incomplete_session
    @request["session_id"] = "wrong"
    assert_raises(CodexUsage::Invalid) { recover }
    @request["session_id"] = @sid
    @events.pop
    assert_raises(CodexUsage::Invalid) { recover }
  end

  def test_rejects_modified_transcript
    record = recover
    File.open(@transcript, "a") { |f| f.puts "changed" }
    assert_raises(CodexUsage::Invalid) { CodexUsage.verify_transcript!(record, id: "run", batch: "batch", path: @transcript) }
  end

  def test_rejects_invalid_counts_and_mismatching_usage_sources
    [{"total_tokens" => 109}, {"cached_input_tokens" => 101}, {"output_tokens" => -1},
     {"reasoning_output_tokens" => 11}, {"input_tokens" => 100.0}].each do |bad|
      assert_raises(CodexUsage::Invalid) { CodexUsage.validate_usage!(@usage.merge(bad)) }
    end
    @events[4][:payload][:thread_token_usage] = @usage.merge("total_tokens" => 111)
    assert_raises(CodexUsage::Invalid) { recover }
  end

  def test_rejects_legacy_count_mismatch
    @request["legacy_reported_tokens"] = 110
    assert_raises(CodexUsage::Invalid) { recover }
  end

  def test_duplicate_evidence_is_rejected
    record = recover
    path = File.join(@tmp, "evidence.jsonl")
    File.write(path, (JSON.generate(record) + "\n") * 2)
    assert_raises(CodexUsage::Invalid) { CodexUsage.load_records(path) }
  end

  def test_rejects_invalid_retained_identity_and_paths
    record = recover
    [{"session_cwd" => "/evals/other/run"}, {"session_cwd" => "/evals/batch/other"},
     {"session_id" => "wrong"}, {"session_path" => "/outside.jsonl"},
     {"session_path" => "../outside.jsonl"}].each do |bad|
      assert_raises(CodexUsage::Invalid) { CodexUsage.validate_record!(record.merge(bad)) }
    end
    assert_raises(CodexUsage::Invalid) { CodexUsage.validate_record!(nil) }
  end

  def test_aggregate_uses_bound_evidence_and_rejects_tampering
    pipeline = LocalEvaluation::AggregatePipeline.allocate
    pipeline.instance_variable_set(:@warnings, {})
    record = recover
    pipeline.instance_variable_set(:@codex_usage, {"run" => record})
    File.write(File.join(@tmp, "timing.txt"), "Duration: 2.5 seconds\n")
    result = AggregateEvaluation.new("matmul", "test", "omp", 1)
    info = {"batch" => "batch", "source_path" => @tmp}
    pipeline.send(:parse_agent_metadata, "run", info, result)
    assert_equal 100, result.input_tokens
    assert_equal 80, result.cached_tokens
    assert_equal 110, result.total_tokens
    assert_equal 4, result.reasoning_output_tokens
    assert_equal 30, result.legacy_reported_tokens
    assert_equal 2.5, result.total_time
    assert_raises(CodexUsage::Invalid) do
      pipeline.send(:parse_agent_metadata, "run", info.reject { |key, _| key == "batch" }, result)
    end
    File.open(@transcript, "a") { |f| f.puts "changed" }
    assert_raises(CodexUsage::Invalid) { pipeline.send(:parse_agent_metadata, "run", info, result) }
    File.rename(@transcript, "#{@transcript}.retained")
    assert_raises(CodexUsage::Invalid) { pipeline.send(:parse_agent_metadata, "run", info, result) }
  end
end
