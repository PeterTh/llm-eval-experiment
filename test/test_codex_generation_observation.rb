# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/codex_generation_observation"

class CodexGenerationObservationTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("codex-observation-", "/tmp")
    @id = "black-scholes_gpt-6.1-sol-medium_omp_r1"
    @directory = File.join(@root, "20261006-120000", @id)
    FileUtils.mkdir_p(@directory)
    @header = { "workdir" => "/home/llmtest/evals/20261006-120000/#{@id}", "model" => "gpt-6.1-sol",
      "provider" => "openai", "approval" => "never", "sandbox" => "danger-full-access", "reasoning effort" => "medium",
      "reasoning summaries" => "none", "session id" => "01234567-89ab-cdef-0123-456789abcdef" }
    @version = "0.160.1"
    @terminal = "tokens used\n30\nDone.\n"
    @status = { "exit_status" => 0, "term_signal" => nil, "timeout_seconds" => 14400 }
    File.write(File.join(@directory, "instruction.txt"), "unchanged production prompt")
    File.write(File.join(@directory, "timing.txt"), "Duration: 12.34 seconds\n")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def read(**options)
    File.write(File.join(@directory, "process-status.txt"), JSON.generate(@status))
    File.write(File.join(@directory, "output.txt"), "Reading additional input from stdin...\nOpenAI Codex v#{@version}\n--------\n" +
      @header.map { |key, value| "#{key}: #{value}\n" }.join + "--------\nuser\nOriginal prompt\n#{@terminal}")
    CodexGenerationObservation.read(@directory, model: "gpt-6.1-sol", effort: "medium", version: "0.160.1", **options)
  end

  def test_completed_metadata_does_not_mislabel_terminal_count_as_exact_usage
    report = read
    assert_equal "completed", report.fetch("outcome")
    assert_equal 30, report.fetch("legacy_reported_tokens")
    assert_equal 12.34, report.fetch("total_seconds")
    assert_equal 4, report.fetch("sha256").size
    assert report.fetch("exact_usage_pending")
    refute report.fetch("usage_available")
    refute report.key?("total_tokens")
  end

  def test_wrong_model_effort_provider_permissions_and_version_fail
    %w[model provider approval sandbox reasoning\ effort].each do |key|
      previous = @header[key]
      @header[key] = "different"
      assert_raises(CodexGenerationObservation::Invalid) { read }
      @header[key] = previous
    end
    @version = "0.160.2"
    assert_raises(CodexGenerationObservation::Invalid) { read }
  end

  def test_wrong_identity_and_missing_terminal_counter_fail
    @header["workdir"] += "-other"
    assert_raises(CodexGenerationObservation::Invalid) { read }
    @header["workdir"].delete_suffix!("-other")
    @header["session id"] = "invalid"
    assert_raises(CodexGenerationObservation::Invalid) { read }
    @header["session id"] = "01234567-89ab-cdef-0123-456789abcdef"
    @terminal = "No terminal counters"
    assert_raises(CodexGenerationObservation::Invalid) { read }
  end

  def test_process_errors_and_budget_drift_fail
    @status["exit_status"] = 1
    assert_raises(CodexGenerationObservation::Invalid) { read }
    @status["exit_status"] = 0
    @status["timeout_seconds"] = 1800
    assert_raises(CodexGenerationObservation::Invalid) { read }
  end

  def test_genuine_timeout_retained_without_inventing_usage_or_requiring_success
    @status["exit_status"] = 124
    @terminal = ""
    assert_raises(CodexGenerationObservation::Invalid) { read }
    File.write(File.join(@directory, "timing.txt"), "Duration: 14400.25 seconds\n")
    report = read
    assert_equal "generation_timeout", report.fetch("outcome")
    refute report.fetch("usage_available")
    refute report.key?("total_tokens")
  end

  def test_baseline_profile_drift_fails
    baseline = read.merge("reasoning_effort" => "xhigh")
    assert_raises(CodexGenerationObservation::Invalid) { read(baseline: baseline) }
  end

  def isolation
    { "filesystem_isolation" => GenerationFilesystem.policy_details(@header.fetch("workdir")).merge(
        "implementation_sha256" => "a" * 64, "bubblewrap_sha256" => "b" * 64,
        "harness_companions" => { "codex-code-mode-host" => {
          "mount" => "/run/llm-eval/bin/codex-code-mode-host", "sha256" => "d" * 64 } },
        "preflight" => { "passed" => true, "operator_home_visible" => false, "other_observations_visible" => false }),
      "model" => "gpt-6.1-sol", "effort" => "medium", "version" => @version,
      "timeout_seconds" => 14400, "exit_status" => 0, "term_signal" => nil,
      "session_archive_complete" => true, "archived_sessions" => [{
        "path" => "2026/10/06/rollout-2026-10-06T12-00-00-#{@header.fetch('session id')}.jsonl",
        "sha256" => "c" * 64, "bytes" => 1234 }] }
  end

  def test_new_isolated_observation_requires_bound_evidence_and_archived_session
    path = File.join(@directory, "codex-filesystem.txt")
    File.write(path, JSON.generate(isolation))
    report = read
    assert_equal GenerationFilesystem::POLICY, report.dig("filesystem_isolation", "policy")
    assert_equal 5, report.fetch("sha256").size
    assert_equal isolation.fetch("archived_sessions"), report.fetch("archived_sessions")
    [{ "effort" => "low" }, { "session_archive_complete" => false }, { "archived_sessions" => [] },
      { "exit_status" => 1 }, { "model" => "different" }].each do |mutation|
      File.write(path, JSON.generate(isolation.merge(mutation)))
      assert_raises(CodexGenerationObservation::Invalid) { read }
    end
  end

  def test_isolation_policy_and_workspace_drift_fail
    path = File.join(@directory, "codex-filesystem.txt")
    %w[workspace private_proc private_home].each do |key|
      evidence = isolation
      evidence.fetch("filesystem_isolation")[key] = "wrong"
      File.write(path, JSON.generate(evidence))
      assert_raises(CodexGenerationObservation::Invalid) { read }
    end
  end

  def test_unavailable_tool_host_is_an_infrastructure_failure
    File.write(File.join(@directory, "codex-filesystem.txt"), JSON.generate(isolation))
    @terminal = "warning: Code Mode is unavailable because failed to spawn code-mode host\n" + @terminal
    error = assert_raises(CodexGenerationObservation::Invalid) { read }
    assert_includes error.message, "tool execution unavailable"
  end

  def test_missing_companion_pin_is_rejected
    evidence = isolation
    evidence.fetch("filesystem_isolation").delete("harness_companions")
    File.write(File.join(@directory, "codex-filesystem.txt"), JSON.generate(evidence))
    assert_raises(CodexGenerationObservation::Invalid) { read }
  end
end
