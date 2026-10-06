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
end
