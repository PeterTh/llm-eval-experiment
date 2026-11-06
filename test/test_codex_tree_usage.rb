# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../lib/codex_tree_usage"
require_relative "../lib/local_evaluation"

class CodexTreeUsageTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("codex-tree-test-", "/tmp")
    @root = "01234567-89ab-cdef-0123-456789abcdef"
    @child = "01234567-89ab-cdef-0123-456789abcdea"
    @usage = { "input_tokens" => 100, "cached_input_tokens" => 80, "output_tokens" => 10,
      "total_tokens" => 110, "reasoning_output_tokens" => 4, "cache_write_input_tokens" => 0 }
    File.write(File.join(@tmp, "output.txt"), "session id: #{@root}\ntokens used\n30\n")
    @request = CodexUsage.transcript_request(batch: "batch", id: "run", path: File.join(@tmp, "output.txt")).merge(
      "model" => "gpt-6.1-terra", "reasoning_effort" => "ultra", "expected_context_window" => 475000,
      "accounting_scope" => CodexTreeUsage::SCOPE)
    @events = { @root => events(@root), @child => events(@child, parent: @root, ending: "turn_aborted") }
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def events(sid, parent: nil, ending: "task_complete")
    [{ "type" => "session_meta", "payload" => { "id" => sid, "forked_from_id" => parent,
       "cwd" => "/evals/batch/run", "cli_version" => "0.160.1" } },
     { "type" => "turn_context", "payload" => { "model" => "gpt-6.1-terra", "effort" => "ultra" } },
     { "type" => "event_msg", "timestamp" => "start", "payload" => { "type" => "task_started" } },
     { "type" => "token_usage_record", "payload" => { "thread_id" => sid, "response_id" => "response-#{sid}",
       "usage" => @usage, "thread_token_usage" => @usage } },
     { "type" => "event_msg", "timestamp" => "count", "payload" => { "type" => "token_count", "info" => {
       "total_token_usage" => @usage, "model_context_window" => 475000 } } },
     { "type" => "event_msg", "timestamp" => "end", "payload" => { "type" => ending } }]
  end

  def write_archives
    @request["archived_sessions"] = @events.map do |sid, events|
      path = File.join(@tmp, "#{sid}.jsonl")
      File.write(path, events.map { |event| JSON.generate(event) + "\n" }.join)
      { "path" => File.basename(path), "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path) }
    end
  end

  def recover
    write_archives
    CodexTreeUsage.recover(@request, sessions_root: @tmp)
  end

  def test_counts_root_and_child_once_and_preserves_interruption_uncertainty
    record = recover
    assert_equal 220, record.fetch("usage").fetch("total_tokens")
    assert_equal 110, record.fetch("root_usage").fetch("total_tokens")
    assert_equal 30, record.fetch("legacy_reported_tokens")
    assert_equal 2, record.fetch("request_count")
    assert_equal [@child], record.fetch("interrupted_sessions")
    assert record.fetch("interrupted_request_usage_uncertain")
    assert_equal record.fetch("usage"), CodexUsage.verify_transcript!(record, id: "run", batch: "batch", path: File.join(@tmp, "output.txt"))
    assert_equal record, CodexUsage.validate_record!(record)
  end

  def test_fully_completed_tree_has_no_uncertainty
    @events[@child].last["payload"]["type"] = "task_complete"
    refute recover.fetch("interrupted_request_usage_uncertain")
  end

  def test_zero_record_interrupted_child_is_retained_not_assumed_complete
    @events[@child].slice!(3, 2)
    record = recover
    assert_equal 110, record.fetch("usage").fetch("total_tokens")
    assert_equal 0, record.fetch("sessions").last.fetch("request_count")
    assert record.fetch("interrupted_request_usage_uncertain")
  end

  def test_rejects_unowned_request_counters
    @events[@child][3]["payload"]["thread_id"] = @root
    assert_raises(CodexUsage::Invalid) { recover }
  end

  def test_rejects_duplicate_request_identity
    @events[@child][3]["payload"]["response_id"] = "response-#{@root}"
    assert_raises(CodexUsage::Invalid) { recover }
  end

  def test_rejects_disconnected_or_cyclic_tree
    @events[@child][0]["payload"]["forked_from_id"] = @child
    assert_raises(CodexUsage::Invalid) { recover }
    @events[@child][0]["payload"]["forked_from_id"] = nil
    assert_raises(CodexUsage::Invalid) { recover }
  end

  def test_rejects_wrong_model_effort_version_or_context
    @events[@child][1]["payload"]["effort"] = "medium"
    assert_raises(CodexUsage::Invalid) { recover }
    @events[@child] = events(@child, parent: @root)
    @events[@child][0]["payload"]["cli_version"] = "other"
    assert_raises(CodexUsage::Invalid) { recover }
    @events[@child] = events(@child, parent: @root)
    @events[@child][4]["payload"]["info"]["model_context_window"] = 258400
    assert_raises(CodexUsage::Invalid) { recover }
  end

  def test_rejects_counter_disagreement_and_incomplete_root
    @events[@child][3]["payload"]["thread_token_usage"] = @usage.transform_values { |v| v * 2 }
    assert_raises(CodexUsage::Invalid) { recover }
    @events[@child] = events(@child, parent: @root)
    @events[@root].last["payload"]["type"] = "turn_aborted"
    assert_raises(CodexUsage::Invalid) { recover }
  end

  def test_bound_archive_tampering_paths_and_omissions_are_rejected
    write_archives
    @request["archived_sessions"].last["sha256"] = "a" * 64
    assert_raises(CodexUsage::Invalid) { CodexTreeUsage.recover(@request, sessions_root: @tmp) }
    write_archives
    @request["archived_sessions"].last["path"] = "../outside"
    assert_raises(CodexUsage::Invalid) { CodexTreeUsage.recover(@request, sessions_root: @tmp) }
    write_archives
    @request["archived_sessions"].shift
    assert_raises(CodexUsage::Invalid) { CodexTreeUsage.recover(@request, sessions_root: @tmp) }
  end

  def test_record_tampering_is_rejected
    record = recover
    %w[interrupted_request_usage_uncertain request_count root_usage usage session_path].each do |key|
      assert_raises(CodexUsage::Invalid) { CodexUsage.validate_record!(record.merge(key => nil)) }
    end
  end

  def test_native_reader_uses_bound_files_and_emits_compatible_schema
    write_archives
    # Unrelated malformed files must never be parsed.
    File.write(File.join(@tmp, "unrelated.jsonl"), "invalid")
    stdout, stderr, status = Open3.capture3("ruby", File.expand_path("../tools/metadata/recover_codex_usage.rb", __dir__),
      "--read-sessions", "--sessions=#{@tmp}", stdin_data: JSON.generate([@request]))
    assert status.success?, stderr
    assert_equal 220, CodexUsage.validate_record!(JSON.parse(stdout)).fetch("usage").fetch("total_tokens")
  end

  def test_aggregation_keeps_recorded_tree_totals_and_uncertainty
    record = recover
    pipeline = LocalEvaluation::AggregatePipeline.allocate
    pipeline.instance_variable_set(:@warnings, {})
    pipeline.instance_variable_set(:@codex_usage, { "run" => record })
    File.write(File.join(@tmp, "timing.txt"), "Duration: 2.5 seconds\n")
    result = AggregateEvaluation.new("matmul", "test", "omp", 1)
    pipeline.send(:parse_agent_metadata, "run", { "batch" => "batch", "source_path" => @tmp }, result)
    assert_equal 220, result.total_tokens
    assert_equal 160, result.cached_tokens
    assert_equal CodexTreeUsage::SOURCE, result.token_usage_source
    refute result.token_usage_complete
    assert_equal record.fetch("usage"), result.partial_token_counts
  end

  def test_tree_parser_is_bound_into_the_evaluation_pipeline_snapshot
    repository = File.expand_path("..", __dir__)
    snapshot = LocalEvaluation.pipeline_source_snapshot(repository)
    assert_equal Digest::SHA256.file(File.join(repository, "lib/codex_tree_usage.rb")).hexdigest,
      snapshot.fetch("files").fetch("lib/codex_tree_usage.rb")
  end
end
