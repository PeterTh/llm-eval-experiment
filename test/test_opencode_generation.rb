# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "opencode_fixture"
require_relative "../lib/local_evaluation"
require_relative "../tools/generation_campaign"
require_relative "../tools/opencode_observation"

class OpenCodeGenerationTest < Minitest::Test
  include OpenCodeFixture

  def setup
    @tmp = Dir.mktmpdir("opencode-test-", "/tmp")
    @id = "black-scholes_gpt-6.1-sol-oc-medium_omp_r1"
    @directory = File.join(@tmp, @id)
    opencode_fixture(@directory)
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def read
    OpenCodeGenerationObservation.read(@directory, model: "openai/gpt-6.1-sol", effort: "medium")
  end

  def test_exact_disjoint_counters_include_cache_and_reasoning_once
    report = read
    assert_equal "completed", report.fetch("outcome")
    assert_equal({ "input_tokens" => 100, "cached_input_tokens" => 80, "output_tokens" => 10,
      "reasoning_output_tokens" => 4, "cache_write_input_tokens" => 0, "total_tokens" => 110 }, report.fetch("token_counts"))
    assert_equal 20, report.fetch("raw_total_seconds")
    assert_equal 18, report.fetch("total_seconds")
    assert_equal 2, report.fetch("retry_backoff_seconds")
    assert_equal 1, report.fetch("retry_count")
  end

  def test_compaction_is_counted_but_no_other_model_or_agent_is_allowed
    compact = Marshal.load(Marshal.dump(@session.fetch("messages").last))
    compact["info"].merge!("id" => "msg_compact", "agent" => "compaction")
    compact["parts"].first.merge!("id" => "part_compact", "messageID" => "msg_compact")
    @session["messages"].insert(1, compact)
    write_opencode_fixture(@directory)
    assert_equal 220, read.fetch("total_tokens")
    compact["info"]["modelID"] = "gpt-other"
    write_opencode_fixture(@directory)
    assert_raises(OpenCodeGenerationObservation::Invalid) { read }
  end

  def test_repeated_transcript_delivery_is_not_repeated_usage
    path = File.join(@directory, "output.txt")
    original = File.read(path)
    File.open(path, "a") { |file| file.write(original) }
    assert_equal 110, read.fetch("total_tokens")
    bad = JSON.parse(original)
    bad["part"]["tokens"]["output"] += 1
    File.open(path, "a") { |file| file.puts(JSON.generate(bad)) }
    assert_raises(OpenCodeGenerationObservation::Invalid) { read }
  end

  def test_cli_terminal_accounting_omission_is_filled_by_matching_native_evidence
    File.write(File.join(@directory, "output.txt"), JSON.generate({ "type" => "text", "sessionID" => @sid }) + "\n")
    report = read
    assert_equal 110, report.fetch("total_tokens")
    assert_equal 1, report.fetch("cli_omitted_terminal_accounting_parts")
    @session["messages"].last["parts"].first["reason"] = "tool-calls"
    write_opencode_fixture(@directory)
    File.write(File.join(@directory, "output.txt"), "{}\n")
    assert_raises(OpenCodeGenerationObservation::Invalid) { read }
  end

  def test_missing_independent_native_accounting_is_rejected
    File.write(File.join(@directory, "opencode-events.txt"), @events.map { |row| JSON.generate(row) + "\n" }.join)
    assert_raises(OpenCodeGenerationObservation::Invalid) { read }
  end

  def test_inconsistent_total_and_negative_counts_are_rejected
    tokens = @session["messages"].last["parts"].first["tokens"]
    tokens["total"] = 109
    write_opencode_fixture(@directory)
    assert_raises(OpenCodeGenerationObservation::Invalid) { read }
    tokens.delete("total")
    assert_equal 110, OpenCodeGenerationObservation.normalize_usage(tokens).fetch("total_tokens")
    tokens["reasoning"] = -1
    assert_raises(OpenCodeGenerationObservation::Invalid) { OpenCodeGenerationObservation.normalize_usage(tokens) }
  end

  def test_policy_and_login_fail_closed
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeHarness.config(model: "anthropic/claude-sonnet-5-5", effort: "medium") }
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeHarness.config(model: "openai/gpt-other", effort: "medium") }
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeHarness.config(model: "openai/gpt-6-luna", effort: "high") }
    auth = File.join(@tmp, "auth.json")
    File.write(auth, JSON.generate({ "openai" => { "type" => "api", "key" => "not-a-real-key" } }))
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeHarness.credential(auth) }
    @evidence["build_agent"]["tools"]["task"] = true
    write_opencode_fixture(@directory)
    assert_raises(OpenCodeGenerationObservation::Invalid) { read }
  end

  def test_luna_profile_preserves_the_sol_policy_and_names_its_native_baseline
    profile = OpenCodeHarness.campaign_profile("gpt-6-luna-oc-medium")
    assert_equal "openai/gpt-6-luna", profile.fetch("model")
    assert_equal "medium", profile.fetch("reasoning_effort")
    assert_equal "20260929-135931", profile.fetch("native_batch")
    assert_equal "gpt-6-luna-medium", profile.fetch("native_profile")
    sol = OpenCodeHarness.config(model: "openai/gpt-6.1-sol", effort: "medium")
    luna = OpenCodeHarness.config(model: profile.fetch("model"), effort: profile.fetch("reasoning_effort"))
    assert_equal JSON.generate(sol).gsub("gpt-6.1-sol", "gpt-6-luna"), JSON.generate(luna)
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeHarness.campaign_profile("gpt-6-luna-medium") }
  end

  def test_luna_native_usage_and_aggregation_keep_the_requested_identity
    id = "black-scholes_gpt-6-luna-oc-medium_omp_r1"
    directory = File.join(@tmp, id)
    opencode_fixture(directory, model: "openai/gpt-6-luna")
    report = OpenCodeGenerationObservation.read(directory, model: "openai/gpt-6-luna", effort: "medium")
    assert_equal id, report.fetch("id")
    assert_equal "completed", report.fetch("outcome")
    assert_equal 110, report.fetch("total_tokens")
    assert_raises(OpenCodeGenerationObservation::Invalid) do
      OpenCodeGenerationObservation.read(directory, model: "openai/gpt-6.1-sol", effort: "medium")
    end
    pipeline = LocalEvaluation::AggregatePipeline.allocate
    pipeline.instance_variable_set(:@warnings, {})
    pipeline.define_singleton_method(:apply_diff_counts) { |*| nil }
    result = AggregateEvaluation.new("black-scholes", "gpt-6-luna-oc-medium", "omp", 1)
    pipeline.send(:parse_agent_metadata, id, { "source_path" => directory }, result)
    assert_equal 110, result.total_tokens
    assert_equal 18, result.total_time
    assert_equal "opencode_native_step_finish", result.token_usage_source
  end

  def test_server_inspection_uses_each_requested_model_and_rejects_fallbacks
    OpenCodeHarness::CAMPAIGN_PROFILES.each_value do |profile|
      model = profile.fetch("model")
      provider, model_id = model.split("/", 2)
      opencode_fixture(@directory, model: model, advertised_output: model.start_with?("opencode-go/"))
      runner = OpenCodeObservationRunner.allocate
      runner.instance_variable_set(:@spec, { "model" => model, "effort" => profile.fetch("reasoning_effort") })
      runner.instance_variable_set(:@expected, @evidence.fetch("requested_config"))
      runner.instance_variable_set(:@env, OpenCodeHarness.environment(@tmp, model: model))
      responses = {
        "/config" => @evidence.fetch("resolved_config"), "/agent" => [@evidence.fetch("build_agent")],
        "/experimental/tool?provider=#{provider}&model=#{model_id}" => @evidence.fetch("enabled_tools").map { |tool| { "id" => tool } },
        "/config/providers" => { "providers" => [{ "id" => provider, "models" => { model_id => @evidence.fetch("resolved_model") } }] },
        "/mcp" => {}, "/session" => []
      }
      runner.define_singleton_method(:get) { |path| responses.fetch(path) }
      assert_equal @evidence, runner.verify_server!(@evidence)
      models = responses.fetch("/config/providers").fetch("providers").first.fetch("models")
      models["gpt-other"] = models.fetch(model_id)
      error = assert_raises(RuntimeError) { runner.verify_server!(@evidence) }
      assert_equal "Additional or missing models", error.message
      models.delete("gpt-other")
      models.fetch(model_id)["options"]["reasoningEffort"] = "low"
      error = assert_raises(RuntimeError) { runner.verify_server!(@evidence) }
      assert_equal "Requested reasoning default differs", error.message
    end
  end

  def test_environment_does_not_inherit_provider_or_harness_overrides
    keys = %w[OPENAI_API_KEY ANTHROPIC_API_KEY OPENCODE_CONFIG_CONTENT OPENCODE_EXPERIMENTAL OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX HTTP_PROXY]
    before = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| ENV[key] = "test-only" }
    env = OpenCodeHarness.environment(@tmp)
    keys.each { |key| assert_nil env.fetch(key) }
    assert_equal "1", env.fetch("OPENCODE_PURE")
    refute env.key?("HOME")
    refute env.key?("CODEX_HOME") unless ENV.key?("CODEX_HOME")
  ensure
    before.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def test_advertised_go_limits_override_inherited_caps_but_leave_openai_unchanged
    key = OpenCodeHarness::OUTPUT_TOKEN_FLAG
    before = ENV[key]
    ENV[key] = "7"
    { "opencode-go/deepseek-v4.1-flash" => 384_000,
      "opencode-go/minimax-m3.1-flash-free" => 512_000 }.each do |model, limit|
      assert_equal limit.to_s, OpenCodeHarness.environment(@tmp, model: model).fetch(key)
      assert_equal limit, OpenCodeHarness.output_token_policy(model).fetch("max_output_tokens")
    end
    assert_nil OpenCodeHarness.environment(@tmp, model: "openai/gpt-6-luna").fetch(key)
    assert_nil OpenCodeHarness.output_token_policy("openai/gpt-6-luna")
  ensure
    ENV[key] = before
  end

  def test_new_go_policy_is_explicit_while_historical_reports_remain_unchanged
    model = "opencode-go/deepseek-v4.1-flash"
    opencode_fixture(@directory, model: model)
    baseline = OpenCodeGenerationObservation.read(@directory, model: model, effort: "high")
    refute baseline.key?("output_token_policy")
    opencode_fixture(@directory, model: model, advertised_output: true)
    report = OpenCodeGenerationObservation.read(@directory, model: model, effort: "high", baseline: baseline)
    assert_equal OpenCodeHarness.output_token_policy(model), report.fetch("output_token_policy")
    assert_equal "completed", report.fetch("outcome")
    @evidence["flags"] = OpenCodeHarness::FLAGS
    write_opencode_fixture(@directory)
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeGenerationObservation.read(@directory, model: model, effort: "high") }
    @evidence["flags"] = OpenCodeHarness.flags(model: model)
    @evidence["resolved_model"]["limit"]["output"] = 32_000
    write_opencode_fixture(@directory)
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeGenerationObservation.read(@directory, model: model, effort: "high") }
    @evidence.delete("output_token_policy")
    write_opencode_fixture(@directory)
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeGenerationObservation.read(@directory, model: model, effort: "high") }
  end

  def test_advertised_limit_exhaustion_is_retained_with_exact_usage_not_retried
    model = "opencode-go/deepseek-v4.1-flash"
    opencode_fixture(@directory, model: model, advertised_output: true)
    @session["messages"].last["info"]["finish"] = "length"
    part = @session["messages"].last["parts"].first
    part["reason"] = "length"
    part["tokens"].merge!("output" => 0, "reasoning" => 384_000, "total" => 384_100)
    write_opencode_fixture(@directory)
    File.write(File.join(@directory, "output.txt"), "{}\n")
    report = OpenCodeGenerationObservation.read(@directory, model: model, effort: "high")
    assert_equal "generation_output_limit", report.fetch("outcome")
    assert report.fetch("usage_complete")
    assert_equal 384_100, report.fetch("total_tokens")
    assert_equal 1, report.fetch("cli_omitted_terminal_accounting_parts")
    driver = GenerationCampaign.allocate
    driver.instance_variable_set(:@results, @tmp)
    driver.define_singleton_method(:check_stop!) { nil }
    driver.define_singleton_method(:observation) { |_id, baseline: nil| report }
    driver.define_singleton_method(:launch) { |*| raise "Must not retry an exhausted advertised allowance" }
    assert_equal report, driver.execute_observation(@id)
    part["tokens"].merge!("reasoning" => 32_000, "total" => 32_100)
    write_opencode_fixture(@directory)
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeGenerationObservation.read(@directory, model: model, effort: "high") }
  end

  def test_commit_preserves_approved_termination_evidence_without_inventing_a_process_receipt
    terminated_fixture
    git = ->(*args) do
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
    batch = "20261019-000000"
    results = File.join(@tmp, batch)
    FileUtils.mkdir_p(results)
    FileUtils.mv(@directory, File.join(results, @id))
    driver = GenerationCampaign.allocate
    { root: @tmp, results: results, batch: batch, ids: [@id], harness: "opencode",
      manifest: { "source_branch" => "claude", "label" => "Fixture" } }.each do |key, value|
      driver.instance_variable_set("@#{key}", value)
    end
    driver.commit_outputs
    committed = git.call("ls-files", "--", batch).lines.map(&:strip)
    assert_includes committed, "#{batch}/#{@id}/generation-termination.txt"
    refute_includes committed, "#{batch}/#{@id}/opencode-process.txt"
  end

  def test_full_budget_timeout_retains_partial_exact_usage
    opencode_fixture(@directory, timeout: true)
    report = read
    assert_equal "generation_timeout", report.fetch("outcome")
    refute report.fetch("usage_complete")
    assert_equal 110, report.fetch("total_tokens")
  end

  def terminated_fixture
    @session["messages"].last["info"]["finish"] = "tool-calls"
    @session["messages"].last["parts"].first["reason"] = "tool-calls"
    tool = { "id" => "part_kill", "messageID" => "msg_interrupted", "sessionID" => @sid, "type" => "tool", "tool" => "bash",
      "state" => { "status" => "running", "input" => { "command" => "pkill -f black-scholes || true" } } }
    header = @session["messages"].last["info"].merge("id" => "msg_interrupted", "time" => { "created" => 19000 })
    header.delete("finish")
    @session["messages"] << { "info" => header, "parts" => [tool] }
    @events.pop
    @process.merge!("exit_status" => 143, "success" => false)
    write_opencode_fixture(@directory)
    File.unlink(File.join(@directory, "opencode-process.txt"))
    receipt = { "schema_version" => 1, "run_id" => @id, "session_id" => @sid,
      "reason" => "model_caused_termination", "approved_by" => "user", "decision" => "retain_original_without_restart",
      "usage_complete" => false, "native_process_receipt_available" => false,
      "incident_sha256" => "a" * 64, "native_export_sha256" => "b" * 64, "termination_tool_part" => tool,
      "metadata_sha256" => OpenCodeGenerationTermination::METADATA.to_h { |name| [name, Digest::SHA256.file(File.join(@directory, name)).hexdigest] } }
    File.write(File.join(@directory, OpenCodeGenerationTermination::FILENAME), JSON.generate(receipt))
    receipt
  end

  def test_explicit_model_termination_is_retained_with_partial_usage
    terminated_fixture
    report = read
    assert_equal "generation_model_terminated", report.fetch("outcome")
    refute report.fetch("usage_complete")
    assert_equal 110, report.fetch("total_tokens")
    assert_equal 18, report.fetch("total_seconds")
    refute File.exist?(File.join(@directory, "opencode-process.txt"))
    File.unlink(File.join(@directory, OpenCodeGenerationTermination::FILENAME))
    assert_raises(OpenCodeGenerationObservation::Invalid) { read }
  end

  def test_termination_record_cannot_hide_changed_evidence_or_omit_approval
    receipt = terminated_fixture
    receipt["approved_by"] = "automatic"
    File.write(File.join(@directory, OpenCodeGenerationTermination::FILENAME), JSON.generate(receipt))
    assert_raises(OpenCodeGenerationObservation::Invalid) { read }
    receipt["approved_by"] = "user"
    File.write(File.join(@directory, OpenCodeGenerationTermination::FILENAME), JSON.generate(receipt))
    File.open(File.join(@directory, "output.txt"), "a") { |file| file.puts("changed") }
    assert_raises(OpenCodeGenerationObservation::Invalid) { read }
  end

  def test_partial_usage_is_not_exported_as_a_complete_cost_measurement
    terminated_fixture
    pipeline = LocalEvaluation::AggregatePipeline.allocate
    pipeline.instance_variable_set(:@warnings, {})
    pipeline.define_singleton_method(:apply_diff_counts) { |*| nil }
    result = AggregateEvaluation.new("black-scholes", "gpt-6.1-sol-oc-medium", "omp", 1)
    pipeline.send(:parse_agent_metadata, @id, { "source_path" => @directory }, result)
    assert_nil result.input_tokens
    assert_nil result.output_tokens
    assert_nil result.total_tokens
    refute result.token_usage_complete
    assert_equal 110, result.partial_token_counts.fetch("total_tokens")
    assert_equal "generation_model_terminated", result.generation_outcome
    assert_nil result.validation_status
    assert_equal 18, result.total_time
  end

  def test_controller_does_not_relaunch_an_adjudicated_model_termination
    terminated_fixture
    driver = GenerationCampaign.allocate
    driver.instance_variable_set(:@results, @tmp)
    driver.define_singleton_method(:check_stop!) { nil }
    directory = @directory
    driver.define_singleton_method(:observation) do |_id, baseline: nil|
      OpenCodeGenerationObservation.read(directory, model: "openai/gpt-6.1-sol", effort: "medium", baseline: baseline)
    end
    driver.define_singleton_method(:launch) { |*| raise "Must not relaunch the terminated observation" }
    assert_equal "generation_model_terminated", driver.execute_observation(@id).fetch("outcome")
  end

  def test_incomplete_native_event_stream_is_rejected
    @events.pop
    write_opencode_fixture(@directory)
    assert_raises(OpenCodeGenerationObservation::Invalid) { read }
  end

  def test_terminal_error_or_unfinished_turn_is_not_a_completed_observation
    @session["messages"].last["info"]["error"] = { "name" => "APIError" }
    write_opencode_fixture(@directory)
    assert_raises(OpenCodeGenerationObservation::Invalid) { read }
    @session["messages"].last["info"].delete("error")
    @session["messages"].last["info"]["finish"] = "tool-calls"
    write_opencode_fixture(@directory)
    assert_raises(OpenCodeGenerationObservation::Invalid) { read }
  end

  def test_aggregation_retains_usage_and_corrected_wall_time_without_invented_api_time
    pipeline = LocalEvaluation::AggregatePipeline.allocate
    pipeline.instance_variable_set(:@warnings, {})
    pipeline.define_singleton_method(:apply_diff_counts) { |*| nil }
    result = AggregateEvaluation.new("black-scholes", "gpt-6.1-sol-oc-medium", "omp", 1)
    pipeline.send(:parse_agent_metadata, @id, { "source_path" => @directory }, result)
    assert_equal 100, result.input_tokens
    assert_equal 10, result.output_tokens
    assert_equal 110, result.total_tokens
    assert_equal 4, result.reasoning_output_tokens
    assert_equal 18, result.total_time
    assert_equal 2, result.agent_retry_backoff_seconds
    assert_equal "opencode_native_step_finish", result.token_usage_source
    assert_nil result.api_time
    File.unlink(File.join(@directory, "opencode-session.txt"))
    assert_raises(OpenCodeGenerationObservation::Invalid) do
      pipeline.send(:parse_agent_metadata, @id, { "source_path" => @directory }, result)
    end
  end

  class SimulatedCampaign < GenerationCampaign
    include OpenCodeFixture
    attr_reader :launched, :committed
    def initialize(root)
      super
      @launched = []
    end
    def ensure_account_idle!; end
    def cleanup_after_run!(_id); end
    def launch(command)
      id = File.read(command.last.delete_prefix("--run-ids=")).strip
      @launched << id
      model = @manifest.fetch("models").fetch(id.split("_")[1]).fetch("model")
      opencode_fixture(File.join(@results, id), model: model)
      true
    end
    def commit_outputs
      @committed = true
    end
  end

  def test_controller_reuses_every_pilot_and_never_repeats_accepted_observations
    assert_controller_pilot_reuse("gpt-6.1-sol-oc-medium")
  end

  def test_luna_controller_reuses_every_pilot_and_never_repeats_accepted_observations
    assert_controller_pilot_reuse("gpt-6-luna-oc-medium")
  end

  def test_go_controller_reuses_every_pilot_and_never_repeats_accepted_observations
    assert_controller_pilot_reuse("deepseek-v4.1-flash-oc-high")
  end

  def test_go_credentials_are_isolated_and_no_openai_or_zen_fallback_is_accepted
    model = "opencode-go/deepseek-v4.1-flash"
    auth = File.join(@tmp, "go-auth.json")
    content = { "opencode-go" => { "type" => "api", "key" => "fixture-key" } }
    File.write(auth, JSON.generate(content), perm: 0600)
    assert_equal content, OpenCodeHarness.credential(auth, model: model)
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeHarness.credential(auth) }
    File.chmod(0644, auth)
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeHarness.credential(auth, model: model) }
    File.chmod(0600, auth)
    content["opencode"] = { "type" => "api", "key" => "fixture-zen-key" }
    File.write(auth, JSON.generate(content))
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeHarness.credential(auth, model: model) }
  end

  def test_go_profiles_preserve_policy_and_accept_native_edit_tools
    profile = OpenCodeHarness.campaign_profile("minimax-m3.1-flash-oc-medium")
    assert_equal true, profile.fetch("free_only")
    config = OpenCodeHarness.config(model: profile.fetch("model"), effort: "medium")
    assert_equal ["opencode-go"], config.fetch("enabled_providers")
    definition = config.dig("provider", "opencode-go", "models", "minimax-m3.1-flash-free")
    assert_equal 0, definition.dig("cost", "input")
    assert_equal "medium", definition.dig("options", "reasoningEffort")
    assert_equal "reasoning_content", definition.dig("interleaved", "field")
    opencode_fixture(@directory, model: profile.fetch("model"))
    report = OpenCodeGenerationObservation.read(@directory, model: profile.fetch("model"), effort: "medium")
    assert_equal "completed", report.fetch("outcome")
    assert_includes report.fetch("tools"), "edit"
    refute_includes report.fetch("tools"), "apply_patch"
    @evidence["auth_type"] = "openai-subscription-oauth"
    write_opencode_fixture(@directory)
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeGenerationObservation.read(@directory, model: profile.fetch("model"), effort: "medium") }
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeHarness.config(model: "opencode-go/deepseek-v4.1-flash", effort: "medium") }
    assert_raises(OpenCodeHarness::Invalid) { OpenCodeHarness.config(model: "opencode-go/minimax-m3.1-flash", effort: "medium") }
  end

  def assert_controller_pilot_reuse(profile_name)
    profile = OpenCodeHarness.campaign_profile(profile_name)
    ids = %w[black-scholes nbody floydwarshall qtclustering matmul].zip(%w[omp cuda mpi hybrid omp]).map do |benchmark, backend|
      "#{benchmark}_#{profile_name}_#{backend}_r1"
    end
    results = File.join(@tmp, "20261017-190000")
    FileUtils.mkdir_p(results)
    manifest = { "harness" => "opencode", "campaign_id" => "20261017-190000", "expected_runs" => ids.size,
      "persistent_results" => results, "runtime_root" => File.join(@tmp, "runtime"), "preflight_ids" => ids.take(4),
      "models" => { profile_name => profile.slice("model", "reasoning_effort") },
      "opencode_version" => OpenCodeHarness::VERSION, "per_run_timeout_seconds" => 14400 }
    File.write(File.join(@tmp, "campaign.json"), JSON.generate(manifest))
    File.write(File.join(@tmp, "run-ids.txt"), ids.join("\n") + "\n")
    campaign = SimulatedCampaign.new(@tmp)
    capture_io { campaign.preflight }
    assert_equal ids.take(4), campaign.launched
    refute campaign.committed
    capture_io { campaign.run }
    assert_equal ids, campaign.launched
    assert campaign.committed
    assert_equal 550, JSON.parse(File.read(File.join(@tmp, "progress.json"))).fetch("retained_total_tokens")
    capture_io { campaign.run }
    assert_equal ids, campaign.launched
  end
end
