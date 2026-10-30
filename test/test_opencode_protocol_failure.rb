# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "opencode_fixture"
require_relative "../lib/local_evaluation"
require_relative "../tools/generation_campaign"

class OpenCodeProtocolFailureTest < Minitest::Test
  include OpenCodeFixture

  def setup
    @tmp = Dir.mktmpdir("opencode-protocol-test-", "/tmp")
    @id = "matmul_beam-1.0-oc-medium_mpi_r3"
    @directory = File.join(@tmp, @id)
    opencode_fixture(@directory, model: "opencode-go/beam-free", advertised_output: true)
    @session["messages"].last["info"]["finish"] = "tool-calls"
    @session["messages"].last["parts"].first["reason"] = "tool-calls"
    @tool = { "id" => "part_bad_path", "messageID" => "msg_assistant", "sessionID" => @sid,
      "type" => "tool", "tool" => "read", "state" => { "status" => "error", "error" => "File not found" } }
    @session["messages"].last["parts"] << @tool
    @error = { "name" => "APIError", "data" => { "statusCode" => 400, "isRetryable" => false,
      "message" => "Upstream request failed: [prompt_rendering_failed] The request could not be rendered into a prompt for this model." } }
    header = @session["messages"].last["info"].merge("id" => "msg_error", "error" => @error)
    header.delete("finish")
    @session["messages"] << { "info" => header, "parts" => [] }
    @events << { "received_at_ms" => 19999, "event" => { "type" => "session.error",
      "properties" => { "sessionID" => @sid, "error" => @error } } }
    write_opencode_fixture(@directory)
    @emitted = Marshal.load(Marshal.dump(@tool))
    @emitted["state"]["input"] = { "filePath" => './matmul.cpp"><|end|><|start|> assistant to=bash<|channel|>analysis' }
    File.open(File.join(@directory, "output.txt"), "a") do |file|
      file.puts(JSON.generate({ "type" => "tool_use", "sessionID" => @sid, "part" => @emitted }))
    end
    @receipt = { "schema_version" => 2, "run_id" => @id, "session_id" => @sid,
      "reason" => "model_protocol_failure", "approved_by" => "user", "decision" => "retain_original_without_restart",
      "usage_complete" => false, "native_process_receipt_available" => true, "incident_sha256" => "a" * 64,
      "terminal_message_id" => "msg_error", "terminal_error" => @error, "protocol_tool_part_id" => @tool["id"] }
    approve
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def approve
    @receipt["metadata_sha256"] = OpenCodeGenerationTermination::PROTOCOL_METADATA.to_h do |name|
      [name, Digest::SHA256.file(File.join(@directory, name)).hexdigest]
    end
    File.write(File.join(@directory, OpenCodeGenerationTermination::FILENAME), JSON.generate(@receipt))
  end

  def read
    OpenCodeGenerationObservation.read(@directory, model: "opencode-go/beam-free", effort: "medium")
  end

  def test_approved_protocol_failure_retains_original_status_and_partial_exact_usage
    report = read
    assert_equal "generation_model_terminated", report.fetch("outcome")
    assert_equal "model_protocol_failure", report.fetch("generation_failure_reason")
    refute report.fetch("usage_complete")
    assert_equal 110, report.fetch("total_tokens")
    assert_equal 18, report.fetch("total_seconds")
    assert report.fetch("sha256").key?("opencode-process.txt")
    File.unlink(File.join(@directory, OpenCodeGenerationTermination::FILENAME))
    assert_raises(OpenCodeHarness::Invalid) { read }
  end

  def test_requires_explicit_approval_and_unchanged_metadata
    @receipt["approved_by"] = "automatic"
    approve
    assert_raises(OpenCodeHarness::Invalid) { read }
    @receipt["approved_by"] = "user"
    approve
    File.open(File.join(@directory, "output.txt"), "a") { |file| file.puts("changed") }
    assert_raises(OpenCodeHarness::Invalid) { read }
  end

  def test_cannot_admit_an_unrelated_provider_error_even_with_updated_hashes
    @error["data"]["statusCode"] = 429
    File.write(File.join(@directory, "opencode-session.txt"), JSON.generate(@session))
    approve
    assert_raises(OpenCodeHarness::Invalid) { read }
  end

  def test_requires_model_emitted_protocol_tokens_not_just_tool_output
    path = File.join(@directory, "output.txt")
    File.write(path, File.read(path).gsub("<|start|>", "ordinary filename"))
    approve
    assert_raises(OpenCodeHarness::Invalid) { read }
  end

  def test_requires_independent_native_error_and_tool_identity
    File.write(File.join(@directory, "opencode-events.txt"), File.readlines(File.join(@directory, "opencode-events.txt"))
      .reject { |line| JSON.parse(line).dig("event", "type") == "session.error" }.join)
    approve
    assert_raises(OpenCodeHarness::Invalid) { read }
  end

  def test_native_process_receipt_cannot_be_discarded
    @receipt["native_process_receipt_available"] = false
    approve
    assert_raises(OpenCodeHarness::Invalid) { read }
    @receipt["native_process_receipt_available"] = true
    @process["exit_status"] = 1
    File.write(File.join(@directory, "opencode-process.txt"), JSON.generate(@process))
    approve
    assert_raises(OpenCodeHarness::Invalid) { read }
  end

  def test_aggregation_does_not_invent_complete_cost_or_validation_failure
    pipeline = LocalEvaluation::AggregatePipeline.allocate
    pipeline.instance_variable_set(:@warnings, {})
    pipeline.define_singleton_method(:apply_diff_counts) { |*| nil }
    result = AggregateEvaluation.new("matmul", "beam-1.0-oc-medium", "mpi", 3)
    pipeline.send(:parse_agent_metadata, @id, { "source_path" => @directory }, result)
    assert_nil result.total_tokens
    refute result.token_usage_complete
    assert_equal 110, result.partial_token_counts.fetch("total_tokens")
    assert_equal "model_protocol_failure", result.generation_failure_reason
    assert_nil result.validation_status
  end

  def test_controller_never_relaunches_the_retained_attempt
    driver = GenerationCampaign.allocate
    driver.instance_variable_set(:@results, @tmp)
    driver.define_singleton_method(:check_stop!) { nil }
    report = read
    driver.define_singleton_method(:observation) { |*args, **kwargs| report }
    driver.define_singleton_method(:launch) { |*| raise "Must not retry a retained model failure" }
    assert_equal report, driver.execute_observation(@id)
  end

  def test_commit_preserves_both_the_adjudication_and_the_native_process_receipt
    git = lambda do |*args|
      output, status = Open3.capture2e("git", "-C", @tmp, *args)
      raise output unless status.success?
      output
    end
    git.call("init", "--quiet", "--initial-branch=claude")
    git.call("config", "user.name", "Campaign Test")
    git.call("config", "user.email", "campaign-test@example.invalid")
    File.write(File.join(@tmp, ".gitignore"), "*\n!*/\n!*.txt\n!.gitignore\n")
    git.call("add", ".gitignore")
    git.call("commit", "--quiet", "-m", "Fixture")
    batch = "20261025-170121"
    results = File.join(@tmp, batch)
    FileUtils.mkdir(results)
    FileUtils.mv(@directory, File.join(results, @id))
    driver = GenerationCampaign.allocate
    { root: @tmp, results: results, batch: batch, ids: [@id], harness: "opencode",
      manifest: { "source_branch" => "claude", "label" => "Fixture" } }.each do |key, value|
      driver.instance_variable_set("@#{key}", value)
    end
    driver.commit_outputs
    committed = git.call("ls-files", "--", batch).lines.map(&:strip)
    %w[generation-termination.txt opencode-process.txt].each { |name| assert_includes committed, "#{batch}/#{@id}/#{name}" }
  end
end
