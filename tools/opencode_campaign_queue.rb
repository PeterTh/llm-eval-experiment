#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
require "fileutils"
require "time"
require_relative "generation_campaign"

# Serial generation only. Each campaign retains its usual controller, gate,
# original-source commit and cleanup. No evaluation overlaps the next campaign.
class OpenCodeCampaignQueue
  PROFILES = %w[deepseek-v4.1-flash-oc-high minimax-m3.1-flash-oc-medium].freeze
  PROFILE_PAIRS = [PROFILES, %w[claude-haiku-5.5-oc-medium beam-1.0-oc-medium].freeze].freeze
  PROFILE_ORDERS = [*PROFILE_PAIRS, %w[glm-5.3-oc-high].freeze].freeze

  def initialize(root)
    @root = File.realpath(root)
    @queue = JSON.parse(File.read(File.join(@root, "queue.json")))
    @campaigns = @queue.fetch("campaigns").map do |path|
      path = File.realpath(path)
      [path, JSON.parse(File.read(File.join(path, "campaign.json")))]
    end
    order = @campaigns.map { |_, manifest| manifest.fetch("models").keys }.flatten
    raise "Queue scope differs" unless PROFILE_ORDERS.include?(order) && @campaigns.size == order.size
    raise "Queue method revisions differ" unless @campaigns.map { |_, manifest| manifest.fetch("source_commit") }.uniq.size == 1
    @campaigns.each do |_, manifest|
      raise "Not an approved Go campaign" unless manifest["harness"] == "opencode" && manifest["opencode_access"] == "opencode-go" && manifest["go_balance_fallback_disabled"] == true
      raise "Production scope differs" unless manifest["expected_runs"] == 220 && manifest["per_run_timeout_seconds"] == 14400
      manifest.fetch("models").each do |name, settings|
        raise "Queue model or effort differs" unless settings == OpenCodeHarness.campaign_profile(name).slice("model", "reasoning_effort")
      end
    end
  end

  def write(name, value)
    path = File.join(@root, name)
    tmp = "#{path}.#{Process.pid}.tmp"
    File.write(tmp, JSON.pretty_generate(value) + "\n")
    File.rename(tmp, path)
  end

  def run
    lock = File.open(File.join(@root, "queue.lock"), "a")
    locked = lock.flock(File::LOCK_EX | File::LOCK_NB)
    raise "Queue already running" unless locked
    host_lock = File.open("/tmp/local-evaluation-#{Process.uid}-performance.lock", "a")
    raise "Another native workload owns the host" unless host_lock.flock(File::LOCK_EX | File::LOCK_NB)
    # A single campaign releases the host at quota. In a declared pair, the
    # paid-quota campaign runs first and yields to the approved free offer.
    # Resume any remaining paid observations after the free campaign, waiting for
    # quota only once there is no free generation left to do.
    schedule = @campaigns.size == 1 ? @campaigns : [*@campaigns, @campaigns.first]
    schedule.each do |path, manifest|
      raise "Queue operator stop requested" if File.exist?(File.join(@root, "STOP"))
      next if completed?(path, manifest)
      write("progress.json", { "status" => "running", "active_campaign" => path, "checked_at" => Time.now.utc.iso8601 })
      free_pending = !completed?(*@campaigns.last)
      quota_mode = @campaigns.size == 1 || (path == @campaigns.first.first && free_pending) ? :yield : :wait
      begin
        run_campaign(path, manifest, quota_mode: quota_mode)
      rescue GenerationCampaign::QuotaPause => e
        raise unless quota_mode == :yield
        if @campaigns.size == 1
          write("quota-pause.json", { "paused_campaign" => path, "checked_at" => Time.now.utc.iso8601, "quota" => e.report })
          write("progress.json", { "status" => "quota_paused", "active_campaign" => path, "checked_at" => Time.now.utc.iso8601,
            "resume_not_before" => e.report.fetch("resume_not_before"), "note" => "Completed observations retained; host released; no alternate model or paid fallback." })
          puts "#{manifest.fetch('label')}: quota reached; preserving completed observations and releasing the host."
          return
        end
        write("quota-handoff.json", { "paused_campaign" => path, "next_campaign" => @campaigns.last.first,
          "checked_at" => Time.now.utc.iso8601, "quota" => e.report })
        puts "#{manifest.fetch('label')}: preserving completed observations at the quota boundary and switching to #{@campaigns.last.last.fetch('label')}."
      rescue GenerationCampaign::PriorityPause => e
        write("progress.json", { "status" => "priority_paused", "active_campaign" => path,
          "checked_at" => Time.now.utc.iso8601, "note" => e.message })
        puts e.message
        return
      end
    end
    write("progress.json", { "status" => "complete", "checked_at" => Time.now.utc.iso8601,
      "next_stage" => "Preserved original sources are ready for validation, timing review and scoped benchmarking; no evaluation overlapped generation." })
  rescue StandardError => e
    write("progress.json", { "status" => "needs_review", "error" => "#{e.class}: #{e.message}", "checked_at" => Time.now.utc.iso8601 }) if locked
    raise
  ensure
    host_lock&.close
    lock&.close
  end

  def completed?(path, manifest)
    file = File.join(path, "completion.json")
    return false unless File.file?(file)
    completion = JSON.parse(File.read(file))
    raise "Completion identity differs" unless completion["campaign_id"] == manifest["campaign_id"] && completion["observations"] == 220
    true
  end

  def run_campaign(path, manifest, quota_mode:)
    driver = GenerationCampaign.new(path, go_quota_mode: quota_mode, stop_files: [File.join(@root, "STOP")], yield_at: @queue["yield_at"])
    driver.ensure_account_idle!
    paused = manifest.fetch("paused_campaign").fetch("path")
    raise "Fable STOP guard absent" unless File.exist?(File.join(paused, "STOP"))
    driver.preflight unless File.file?(File.join(path, "preflight-gate.json"))
    review_preflight(path, manifest, driver)
    driver.run
  end

  def review_preflight(path, manifest, driver)
    driver.ensure_account_idle!
    gate = JSON.parse(File.read(File.join(path, "preflight-gate.json")))
    raise "Infrastructure preflight not accepted" unless gate.fetch("accepted")
    ids = manifest.fetch("preflight_ids")
    raise "Preflight scope differs" unless gate.fetch("preflights").map { |row| row.fetch("id") } == ids
    reports = ids.map do |id|
      report = driver.observation(id, baseline: gate.fetch("preflights").first)
      cleanup = JSON.parse(File.read(File.join(path, "cleanup", "#{id}.json")))
      raise "Preflight cleanup incomplete" unless cleanup.fetch("verified_empty") && cleanup.fetch("id") == id
      raise "Incomplete preflight usage" unless report.fetch("usage_complete") && report.fetch("outcome") == "completed"
      report
    end
    log = File.read(File.join(path, "regression-tests.log"))
    counts = log.scan(/^(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips$/).last&.map(&:to_i)
    raise "Regression tests did not pass" unless counts && counts.take(2).all?(&:positive?) && counts.drop(2) == [0, 0, 0]
    review = { "accepted" => true, "ids" => ids, "original_results_reused" => true,
      "criterion" => "Native harness identity, isolation, request accounting, production budget and cleanup only; no correctness/performance selection.",
      "source_commit" => manifest.fetch("source_commit"), "total_tokens" => reports.sum { |r| r.fetch("total_tokens") },
      "generation_seconds" => reports.sum { |r| r.fetch("total_seconds") },
      "tests" => %w[runs assertions failures errors skips].zip(counts).to_h }
    target = File.join(path, "preflight-review.json")
    raise "Preflight review changed" if File.exist?(target) && JSON.parse(File.read(target)) != review
    File.write(target, JSON.pretty_generate(review) + "\n") unless File.exist?(target)
    puts "Reviewed all four reusable production pilots for #{manifest.fetch('label')}; continuing generation."
  end

  def status
    campaigns = @campaigns.map do |path, manifest|
      read = ->(name) { File.file?(File.join(path, name)) ? JSON.parse(File.read(File.join(path, name))) : nil }
      progress = read.call("progress.json") || { "status" => "prepared", "completed" => 0 }
      progress.merge("path" => path, "label" => manifest.fetch("label"), "quota" => read.call("quota-latest.json"))
    end
    progress_file = File.join(@root, "progress.json")
    progress = File.file?(progress_file) ? JSON.parse(File.read(progress_file)) : { "status" => "prepared" }
    value = { "checked_at" => Time.now.utc.iso8601, "queue" => progress, "campaigns" => campaigns }
    if @queue["generation_unit"]
      output, result = Open3.capture2("systemctl", "--user", "show", @queue.fetch("generation_unit"),
        "-p", "ActiveState", "-p", "SubState", "-p", "ExecMainStatus")
      unit = result.success? ? output.lines.to_h { |line| line.strip.split("=", 2) } : {}
      value["unit"] = unit
      value["monitor_health"] = if %w[complete needs_review quota_paused priority_paused].include?(progress["status"])
        progress["status"]
      elsif unit["ActiveState"] == "active"
        "running"
      else
        "unexpected_stop"
      end
    end
    write("monitor-status.json", value)
    puts JSON.generate(value)
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  $stderr.sync = true
  command, root = ARGV
  abort "usage: opencode_campaign_queue.rb run|status QUEUE_ROOT" unless %w[run status].include?(command) && root
  OpenCodeCampaignQueue.new(root).public_send(command)
end
