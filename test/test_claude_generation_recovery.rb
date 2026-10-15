require "minitest/autorun"
require "tmpdir"
require_relative "../lib/claude_generation_observation"
require_relative "../lib/local_evaluation"
require_relative "support/claude_recovery_fixture"

class ClaudeGenerationRecoveryTest < Minitest::Test
  include ClaudeRecoveryFixture

  def setup
    @root = Dir.mktmpdir("claude-generation-recovery-", "/tmp")
    @id = "qtclustering_claude-sonnet-5.5-cc-medium_omp_r2"
    @directory = File.join(@root, @id)
    @record = write_recovered_observation(@directory)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def observation
    ClaudeGenerationObservation.read(@directory, model: "claude-sonnet-5-5", version: "2.1.296")
  end

  def test_recovery_retains_exact_native_duration_usage_and_unknown_wrapper_status
    report = observation
    assert_equal "completed", report.fetch("outcome")
    assert_equal 865.229, report.fetch("raw_total_seconds")
    assert_equal 865.229, report.fetch("total_seconds")
    assert_equal 61.451, report.fetch("api_seconds")
    assert_equal 322573, report.fetch("total_tokens")
    assert_equal true, report.fetch("generation_time_recovered")
    assert_equal false, report.fetch("wrapper_exit_status_available")
    assert_equal "claude_result_duration_ms", report.fetch("generation_time_source")
    assert_equal Digest::SHA256.file(File.join(@directory, "generation-recovery.txt")).hexdigest,
      report.fetch("generation_recovery_sha256")
    assert_nil JSON.parse(File.read(File.join(@directory, "process-status.txt"))).fetch("exit_status")
  end

  def test_no_receipt_cannot_admit_missing_process_status_or_unlabeled_recovery
    File.unlink(File.join(@directory, "generation-recovery.txt"))
    assert_raises(ClaudeGenerationObservation::Invalid) { observation }
    File.write(File.join(@directory, "timing.txt"), "Duration: 865.229 seconds\n")
    assert_raises(ClaudeGenerationObservation::Invalid) { observation }
  end

  def test_every_metadata_file_is_bound_to_receipt
    ClaudeGenerationRecovery::METADATA.each do |name|
      path = File.join(@directory, name)
      original = File.binread(path)
      File.write(path, original + "changed\n")
      assert_raises(ClaudeGenerationObservation::Invalid, name) { observation }
      File.write(path, original)
    end
  end

  def test_identity_approval_and_duration_cannot_drift
    { "run_id" => "another-run", "session_id" => "another-session", "approved_by" => "inferred",
      "model" => "another-model", "version" => "another-version", "duration_ms" => 865230,
      "wrapper_wall_time_seconds" => 865.229, "wrapper_exit_status_available" => true,
      "generation_time_recovered" => false }.each do |key, value|
      changed = @record.merge(key => value)
      write_recovery_record(@directory, changed)
      assert_raises(ClaudeGenerationObservation::Invalid, key) { observation }
    end
  end

  def test_native_error_extra_sessions_and_timeout_are_not_recovered
    path = File.join(@directory, "output.txt")
    original = File.readlines(path).map { |line| JSON.parse(line) }
    variants = [
      [original.first, original.last.merge("is_error" => true)],
      [original.first, original.last.merge("duration_ms" => 14400001)],
      original + [original.last],
      [original.first, original.first, original.last],
      [original.first]
    ]
    variants.each do |events|
      File.write(path, events.map { |event| JSON.generate(event) + "\n" }.join)
      write_recovery_record(@directory, @record)
      assert_raises(ClaudeGenerationObservation::Invalid) { observation }
    end
  end

  def test_receipt_cannot_invent_exit_status_or_wrapper_timestamps
    process_path = File.join(@directory, "process-status.txt")
    process = JSON.parse(File.read(process_path))
    File.write(process_path, JSON.generate(process.merge("exit_status" => 0)))
    write_recovery_record(@directory, @record)
    assert_raises(ClaudeGenerationObservation::Invalid) { observation }
    File.write(process_path, JSON.generate(process))
    timing_path = File.join(@directory, "timing.txt")
    File.write(timing_path, File.read(timing_path).sub("Start time: unavailable (generation wrapper terminated)", "Start time: 2026-10-14T23:59:26Z"))
    write_recovery_record(@directory, @record)
    assert_raises(ClaudeGenerationObservation::Invalid) { observation }
  end

  def aggregate
    pipeline = LocalEvaluation::AggregatePipeline.allocate
    pipeline.instance_variable_set(:@warnings, {})
    pipeline.instance_variable_set(:@run_dir, @root)
    pipeline.define_singleton_method(:apply_diff_counts) { |*_args| }
    result = AggregateEvaluation.new("qtclustering", "claude-sonnet-5.5-cc-medium", "omp", 2)
    pipeline.send(:parse_agent_metadata, @id, { "source_path" => @directory, "batch" => @record.fetch("campaign_id") }, result)
    [pipeline, result]
  end

  def test_aggregate_scoring_and_serialization_keep_recovery_labels
    pipeline, result = aggregate
    assert_equal 865.229, result.total_time
    assert_equal 322573, result.total_tokens
    pipeline.send(:write_outputs, @id => result)
    csv = CSV.read(File.join(@root, "aggregate_results.csv"), headers: true).first
    scored = LocalEvaluation::ScoringPipeline::AGGREGATE_HEADERS.zip(
      LocalEvaluation::ScoringPipeline.send(:aggregate_row, result)).to_h
    %w[generation_time_source generation_time_recovered wrapper_exit_status_available generation_recovery_sha256].each do |field|
      assert_equal result.public_send(field).to_s, csv[field]
      assert_equal result.public_send(field), scored[field]
    end
    saved = LocalEvaluation.load_yaml(File.join(@root, "aggregate_results.yaml"), permitted_classes: [AggregateEvaluation])
    assert_equal true, saved.fetch(@id).generation_time_recovered
  end

  def test_aggregate_fails_closed_if_recovery_evidence_is_missing_or_altered
    @record["campaign_id"] = "wrong-batch"
    assert_raises(ClaudeGenerationRecovery::Invalid) { aggregate }
    @record["campaign_id"] = "20261014-212207"
    File.unlink(File.join(@directory, "generation-recovery.txt"))
    assert_raises(ClaudeGenerationRecovery::Invalid) { aggregate }
  end

  def test_later_timing_only_source_correction_does_not_change_generation_evidence
    FileUtils.mkdir_p(File.join(@directory, "qtclustering"))
    File.write(File.join(@directory, "qtclustering/qtclustering.cpp"), "// a later timing-only correction\n")
    assert observation.fetch("generation_time_recovered")
    assert aggregate.last.generation_time_recovered
  end
end
