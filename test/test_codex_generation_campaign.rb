# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../tools/generation_campaign"

class CodexGenerationCampaignTest < Minitest::Test
  class SimulatedCampaign < GenerationCampaign
    attr_accessor :produce, :busy
    attr_reader :launched, :recoveries, :committed

    def initialize(root)
      super
      @launched, @recoveries = [], []
    end

    def ensure_account_idle!
      raise "Account busy" if @busy
    end

    def cleanup_after_run!(_id); end

    def launch(command)
      id = File.read(command.last.delete_prefix("--run-ids=")).strip
      @launched << id
      @produce.call(id)
      true
    end

    def read_session_usage(reader, requests)
      @recoveries << { "launched" => @launched.size, "ids" => requests.map { |r| r.fetch("run_id") } }
      Open3.capture3(*reader, stdin_data: JSON.generate(requests))
    end

    def commit_outputs
      @committed = true
    end
  end

  def setup
    @root = Dir.mktmpdir("codex-campaign-", "/tmp")
    @batch = "20261006-120000"
    @profiles = %w[medium xhigh].to_h { |effort| ["gpt-6.1-sol-#{effort}", { "model" => "gpt-6.1-sol", "reasoning_effort" => effort }] }
    @ids = %w[black-scholes matmul].flat_map { |bench| @profiles.keys.map { |profile| "#{bench}_#{profile}_omp_r1" } }
    @results = File.join(@root, @batch)
    @sessions = File.join(@root, "sessions")
    FileUtils.mkdir_p([@results, @sessions])
    @manifest = { "harness" => "codex", "campaign_id" => @batch, "expected_runs" => @ids.size,
      "persistent_results" => @results, "runtime_root" => File.join(@root, "runtime"),
      "preflight_ids" => @ids.take(2), "models" => @profiles, "codex_version" => "0.160.1",
      "codex_sessions_root" => @sessions, "per_run_timeout_seconds" => 14400 }
    File.write(File.join(@root, "run-ids.txt"), @ids.join("\n") + "\n")
    write_manifest
    @campaign = SimulatedCampaign.new(@root)
    @campaign.produce = method(:record)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write_manifest
    File.write(File.join(@root, "campaign.json"), JSON.generate(@manifest))
  end

  def record(id, timeout: false)
    directory = File.join(@results, id)
    FileUtils.mkdir_p(directory)
    sid = "01234567-89ab-cdef-0123-#{format('%012d', @ids.index(id))}"
    effort = @profiles.fetch(id.split("_")[1]).fetch("reasoning_effort")
    cwd = "/home/llmtest/evals/#{@batch}/#{id}"
    header = "OpenAI Codex v0.160.1\n--------\nworkdir: #{cwd}\nmodel: gpt-6.1-sol\nprovider: openai\napproval: never\nsandbox: danger-full-access\nreasoning effort: #{effort}\nsession id: #{sid}\n--------\n"
    File.write(File.join(directory, "output.txt"), header + (timeout ? "" : "tokens used\n30\nDone\n"))
    File.write(File.join(directory, "timing.txt"), "Duration: #{timeout ? 14400.1 : 12.34} seconds\n")
    File.write(File.join(directory, "instruction.txt"), "unchanged production prompt")
    File.write(File.join(directory, "process-status.txt"), JSON.generate({ "exit_status" => timeout ? 124 : 0,
      "term_signal" => nil, "timeout_seconds" => 14400 }))
    usage = { "input_tokens" => 100, "cached_input_tokens" => 80, "output_tokens" => 10, "total_tokens" => 110 }
    events = [{ type: "session_meta", payload: { id: sid, cwd: cwd, cli_version: "0.160.1" } },
      { type: "event_msg", timestamp: "count", payload: { type: "token_count", info: { total_token_usage: usage } } },
      { type: "event_msg", timestamp: "done", payload: { type: timeout ? "task_aborted" : "task_complete" } }]
    File.write(File.join(@sessions, "rollout-2026-10-06T12-00-00-#{sid}.jsonl"), events.map { |e| JSON.generate(e) + "\n" }.join)
  end

  def test_two_reusable_preflights_and_final_recovery_never_scan_during_generation
    capture_io { @campaign.preflight }
    assert_equal @ids.take(2), @campaign.launched
    assert_equal [{ "launched" => 2, "ids" => @ids.take(2) }], @campaign.recoveries
    assert_equal 2, JSON.parse(File.read(File.join(@root, "preflight-usage-recovery.json"))).fetch("records")
    refute @campaign.committed
    capture_io { @campaign.run }
    assert_equal @ids, @campaign.launched
    assert_equal 2, @campaign.recoveries.size
    assert_equal 4, @campaign.recoveries.last.fetch("launched")
    assert_equal @ids.sort, @campaign.recoveries.last.fetch("ids")
    assert @campaign.committed
    receipt = JSON.parse(File.read(File.join(@root, "usage-recovery.json")))
    assert_equal 440, receipt.fetch("total_tokens")
    assert_empty receipt.fetch("unavailable")
    assert_equal 4, CodexUsage.load_records(File.join(@root, "codex-usage.jsonl")).size
    assert_equal "complete", JSON.parse(File.read(File.join(@root, "progress.json"))).fetch("status")
  end

  def test_missing_profile_preflight_fails_before_launch
    @manifest["preflight_ids"] = [@ids.first]
    write_manifest
    assert_raises(RuntimeError) { SimulatedCampaign.new(@root) }
    assert_empty @campaign.launched
  end

  def test_unaccepted_campaign_and_busy_account_do_not_launch
    capture_io { assert_raises(Errno::ENOENT) { @campaign.run } }
    assert_empty @campaign.launched
    @campaign.busy = true
    capture_io { assert_raises(RuntimeError) { @campaign.preflight } }
    assert_empty @campaign.launched
    assert_empty @campaign.recoveries
  end

  def test_recovery_failure_does_not_accept_preflight_or_replay_observations
    @campaign.define_singleton_method(:read_session_usage) { |_reader, _requests| raise "Session evidence missing" }
    capture_io { assert_raises(RuntimeError) { @campaign.preflight } }
    refute File.exist?(File.join(@root, "preflight-gate.json"))
    capture_io { assert_raises(RuntimeError) { @campaign.preflight } }
    assert_equal @ids.take(2), @campaign.launched
    refute @campaign.committed
  end

  def test_full_budget_timeout_retained_and_explicitly_excluded_from_exact_accounting
    capture_io { @campaign.preflight }
    @campaign.produce = ->(id) { record(id, timeout: id == @ids.last) }
    capture_io { @campaign.run }
    assert_equal @ids, @campaign.launched
    assert @campaign.committed
    receipt = JSON.parse(File.read(File.join(@root, "usage-recovery.json")))
    assert_equal 3, receipt.fetch("records")
    assert_equal [{ "id" => @ids.last, "outcome" => "generation_timeout" }], receipt.fetch("unavailable")
  end

  def test_final_recovery_failure_prevents_commit_but_retains_all_outputs
    capture_io { @campaign.preflight }
    @campaign.define_singleton_method(:read_session_usage) { |_reader, _requests| raise "Session evidence missing" }
    capture_io { assert_raises(RuntimeError) { @campaign.run } }
    assert_equal @ids, @campaign.launched
    refute @campaign.committed
    assert_equal @ids.sort, Dir.children(@results).sort
    assert_equal "needs_review", JSON.parse(File.read(File.join(@root, "progress.json"))).fetch("status")
  end
end
