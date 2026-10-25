# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/opencode_go"
require_relative "../tools/opencode_campaign_queue"

class OpenCodeGoTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("go-access-test-", "/tmp")
    @auth = File.join(@tmp, "auth.json")
    File.write(@auth, JSON.generate({ "opencode-go" => { "type" => "api", "key" => "fixture-only" } }), perm: 0600)
    @usage = %w[rolling weekly monthly].to_h { |name| [name, { "status" => "ok", "percent" => 0, "resetsAt" => "2026-10-20T00:00:00Z" }] }
    @models = %w[deepseek-v4.1-flash minimax-m3.1-flash-free claude-haiku-5-5 beam-free].map { |id| { "id" => id } }
    @requester = ->(path) { path.end_with?("/usage") ? { "usage" => @usage } : { "data" => @models } }
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def check(model = "opencode-go/deepseek-v4.1-flash")
    OpenCodeGo.check(auth_file: @auth, model: model, requester: @requester, now: Time.utc(2026, 10, 19))
  end

  def test_low_quota_allows_paid_model_without_exposing_key
    result = check
    assert result.fetch("allowed")
    refute_includes JSON.generate(result), "fixture-only"
    assert_equal %w[rolling weekly monthly], result.fetch("usage").keys
  end

  def test_each_window_can_pause_before_the_limit
    @usage.each_key do |name|
      @usage[name]["percent"] = 95
      report = check
      refute report.fetch("allowed")
      assert_equal [name], report.fetch("blocked_windows")
      assert_equal "2026-10-20T00:01:00Z", report.fetch("resume_not_before")
      @usage[name]["percent"] = 0
    end
    @usage["weekly"]["status"] = "rate-limited"
    refute check.fetch("allowed")
  end

  def test_free_model_remains_usable_when_paid_quota_is_exhausted
    @usage.each_value { |window| window.merge!("status" => "rate-limited", "percent" => 100) }
    result = check("opencode-go/minimax-m3.1-flash-free")
    assert result.fetch("allowed")
    assert result.fetch("free_only")
    assert_empty result.fetch("blocked_windows")
  end

  def test_missing_free_offer_never_falls_back_to_a_paid_model
    @models = [{ "id" => "minimax-m3.1-flash" }]
    assert_raises(OpenCodeGo::Invalid) { check("opencode-go/minimax-m3.1-flash-free") }
  end

  def test_haiku_obeys_quota_while_beam_is_free_only
    @usage["weekly"]["percent"] = 95
    refute check("opencode-go/claude-haiku-5-5").fetch("allowed")
    assert check("opencode-go/beam-free").fetch("allowed")
    @models.reject! { |m| m["id"] == "beam-free" }
    assert_raises(OpenCodeGo::Invalid) { check("opencode-go/beam-free") }
  end

  def test_bad_or_incomplete_usage_fails_closed
    @usage["monthly"]["percent"] = Float::NAN
    assert_raises(OpenCodeGo::Invalid) { check }
    @usage.delete("monthly")
    assert_raises(OpenCodeGo::Invalid) { check }
  end

  class QuotaOnlyCampaign < GenerationCampaign
    attr_accessor :access_report
    def ensure_account_idle!; end
    def go_access(_model) = @access_report
    def launch(_command) = raise("Quota-blocked observation must not launch")
  end

  def quota_campaign(stop_files: [])
    id = "black-scholes_deepseek-v4.1-flash-oc-high_omp_r1"
    manifest = { "harness" => "opencode", "campaign_id" => "20261019-000000", "expected_runs" => 1,
      "persistent_results" => File.join(@tmp, "results"), "preflight_ids" => [id],
      "models" => { "deepseek-v4.1-flash-oc-high" => { "model" => "opencode-go/deepseek-v4.1-flash" } },
      "opencode_access" => "opencode-go", "go_balance_fallback_disabled" => true }
    FileUtils.mkdir_p(manifest.fetch("persistent_results"))
    File.write(File.join(@tmp, "campaign.json"), JSON.generate(manifest))
    File.write(File.join(@tmp, "run-ids.txt"), id + "\n")
    QuotaOnlyCampaign.new(@tmp, go_quota_mode: :yield, stop_files: stop_files)
  end

  def test_controller_quota_yield_is_not_an_infrastructure_failure_and_creates_no_observation
    driver = quota_campaign
    @usage["weekly"]["percent"] = 95
    driver.access_report = check
    capture_io { assert_raises(GenerationCampaign::QuotaPause) { driver.preflight } }
    assert_equal "quota_wait", JSON.parse(File.read(File.join(@tmp, "progress.json"))).fetch("status")
    assert_empty Dir.children(File.join(@tmp, "results"))
    assert_empty Dir.children(File.join(@tmp, "observations"))
  end

  def test_queue_stop_is_respected_by_the_campaign_between_observations
    stop = File.join(@tmp, "queue-STOP")
    driver = quota_campaign(stop_files: [stop])
    File.write(stop, "operator stop")
    capture_io { assert_raises(RuntimeError) { driver.preflight } }
    assert_empty Dir.children(File.join(@tmp, "results"))
  end

  class SimulatedQueue < OpenCodeCampaignQueue
    attr_reader :launched
    attr_accessor :fail_first, :pause_first
    def initialize(root)
      super
      @launched = []
    end
    def run_campaign(path, manifest, quota_mode:)
      @launched << manifest.fetch("models").keys.first
      raise "infrastructure failure" if @fail_first
      if @pause_first && @launched.size == 1
        raise "Expected quota yield" unless quota_mode == :yield
        raise GenerationCampaign::QuotaPause, { "resume_not_before" => "2026-10-20T00:01:00Z" }
      end
      raise "Unexpected quota mode" if @launched.size == 3 && quota_mode != :wait
      File.write(File.join(path, "completion.json"), JSON.generate({ "campaign_id" => manifest.fetch("campaign_id"), "observations" => 220 }))
    end
  end

  def make_queue(profiles = OpenCodeCampaignQueue::PROFILES)
    paths = profiles.map.with_index do |profile, index|
      path = File.join(@tmp, "campaign-#{index}")
      FileUtils.mkdir_p(path)
      approved = OpenCodeHarness.campaign_profile(profile)
      manifest = { "models" => { profile => approved.slice("model", "reasoning_effort") }, "label" => approved.fetch("label"), "source_commit" => "same-frozen-commit", "harness" => "opencode",
        "opencode_access" => "opencode-go", "go_balance_fallback_disabled" => true,
        "expected_runs" => 220, "per_run_timeout_seconds" => 14400, "campaign_id" => "batch-#{index}" }
      File.write(File.join(path, "campaign.json"), JSON.generate(manifest))
      path
    end
    File.write(File.join(@tmp, "queue.json"), JSON.generate({ "campaigns" => paths }))
    SimulatedQueue.new(@tmp)
  end

  def test_queue_runs_deepseek_then_minimax_and_does_not_repeat_completed_campaigns
    queue = make_queue
    queue.run
    assert_equal OpenCodeCampaignQueue::PROFILES, queue.launched
    queue.run
    assert_equal OpenCodeCampaignQueue::PROFILES, queue.launched
  end

  def test_queue_stops_on_anomaly_before_launching_the_second_campaign
    queue = make_queue
    queue.fail_first = true
    assert_raises(RuntimeError) { queue.run }
    assert_equal [OpenCodeCampaignQueue::PROFILES.first], queue.launched
    assert_equal "needs_review", JSON.parse(File.read(File.join(@tmp, "progress.json"))).fetch("status")
  end

  def test_quota_boundary_switches_to_free_offer_then_resumes_deepseek
    queue = make_queue
    queue.pause_first = true
    queue.run
    assert_equal [*OpenCodeCampaignQueue::PROFILES, OpenCodeCampaignQueue::PROFILES.first], queue.launched
    assert File.file?(File.join(@tmp, "quota-handoff.json"))
    assert_equal "complete", JSON.parse(File.read(File.join(@tmp, "progress.json"))).fetch("status")
    queue.run
    assert_equal 3, queue.launched.size
  end

  def test_queue_stop_prevents_any_new_campaign
    queue = make_queue
    File.write(File.join(@tmp, "STOP"), "operator pause")
    assert_raises(RuntimeError) { queue.run }
    assert_empty queue.launched
  end

  def test_queue_does_not_overlap_native_evaluation
    queue = make_queue
    lock = File.open("/tmp/local-evaluation-#{Process.uid}-performance.lock", "a")
    assert lock.flock(File::LOCK_EX | File::LOCK_NB)
    assert_raises(RuntimeError) { queue.run }
    assert_empty queue.launched
  ensure
    lock&.close
  end

  def test_haiku_beam_queue_switches_and_reuses_completed_campaigns
    order = %w[claude-haiku-5.5-oc-medium beam-1.0-oc-medium]
    queue = make_queue(order)
    queue.pause_first = true
    queue.run
    assert_equal [*order, order.first], queue.launched
    queue.run
    assert_equal 3, queue.launched.size
  end

  def test_queue_rejects_unapproved_pairs_and_substitution
    assert_raises(RuntimeError) { make_queue(%w[claude-haiku-5.5-oc-medium minimax-m3.1-flash-oc-medium]) }
    make_queue(%w[claude-haiku-5.5-oc-medium beam-1.0-oc-medium])
    path = File.join(@tmp, "campaign-1/campaign.json")
    manifest = JSON.parse(File.read(path))
    manifest["models"].values.first["model"] = "opencode-go/beam-paid"
    File.write(path, JSON.generate(manifest))
    assert_raises(RuntimeError) { OpenCodeCampaignQueue.new(@tmp) }
  end
end
