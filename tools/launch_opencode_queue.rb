#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
require "fileutils"
require "open3"
require "digest"
require "time"
require_relative "opencode_campaign_queue"

# Launch only a declared, prepared pair. The frozen controller owns generation;
# this wrapper creates provenance and a low-frequency status timer, not an agent.
abort "usage: launch_opencode_queue.rb PAID_CAMPAIGN FREE_CAMPAIGN SETUP_DIRECTORY" unless ARGV.size == 3
paths = ARGV.take(2).map { |path| File.realpath(path) }
setup = File.realpath(ARGV.last)
manifests = paths.map { |path| JSON.parse(File.read(File.join(path, "campaign.json"))) }
order = manifests.flat_map { |manifest| manifest.fetch("models").keys }
raise "Unapproved campaign pair" unless OpenCodeCampaignQueue::PROFILE_PAIRS.include?(order)
raise "Method revisions differ" unless manifests.map { |manifest| manifest.fetch("source_commit") }.uniq.size == 1
check = JSON.parse(File.read(File.join(setup, "setup-check.json")))
raise "Setup did not cover this pair" unless check.fetch("profiles").keys == order
raise "Setup used inference" unless check.fetch("inferences_launched").zero?
tests = File.read(File.join(setup, "regression-tests.log"))
counts = tests.scan(/^(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips$/).last&.map(&:to_i)
raise "Regression tests failed" unless counts && counts.take(2).all?(&:positive?) && counts.drop(2) == [0, 0, 0]

def checked(*args)
  out, err, status = Open3.capture3(*args)
  raise "#{args.first} failed: #{err}\n#{out}" unless status.success?
  out
end

pids, status = Open3.capture2("pgrep", "-u", "llmtest")
raise "Evaluation account is busy" unless status.exitstatus == 1 && pids.empty?
lock = File.open("/tmp/local-evaluation-#{Process.uid}-performance.lock", "a")
raise "Native evaluation is active" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
paths.zip(manifests, order).each do |path, manifest, profile|
  raise "Campaign stopped or already launched" if File.exist?(File.join(path, "STOP")) || File.exist?(File.join(path, "launch.json"))
  raise "Campaign access differs" unless manifest["opencode_access"] == "opencode-go" && manifest["go_balance_fallback_disabled"] == true
  raise "Scope or budget differs" unless manifest["expected_runs"] == 220 && manifest["per_run_timeout_seconds"] == 14400
  raise "Missing required filesystem isolation" unless manifest["generation_filesystem_policy"] == GenerationFilesystem::POLICY
  manifest.fetch("files").each do |relative, sha|
    raise "Frozen method changed: #{relative}" unless Digest::SHA256.file(File.join(manifest.fetch("working_directory"), relative)).hexdigest == sha
  end
  check.fetch("files").each do |relative, sha|
    raise "Setup method changed: #{relative}" unless manifest.fetch("files").fetch(relative) == sha
  end
  evidence = check.fetch("profiles").fetch(profile)
  raise "Isolation preflight differs" unless evidence.dig("isolation", "filesystem_isolation", "policy") == GenerationFilesystem::POLICY
  raise "Wrong preflight route" unless evidence.dig("isolation", "model") == manifest.fetch("models").fetch(profile).fetch("model")
  paused = manifest.fetch("paused_campaign").fetch("path")
  raise "Fable STOP missing" unless File.file?(File.join(paused, "STOP"))
  fable = JSON.parse(File.read(File.join(paused, "campaign.json")))
  %w[generation_unit monitor_unit monitor_timer].each do |key|
    raise "Fable unit active" unless checked("systemctl", "--user", "show", fable.fetch(key), "-p", "ActiveState", "--value").strip == "inactive"
  end
end
stamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
root = File.join(Dir.home, "llm_para_campaigns/#{stamp}-opencode-go-queue")
raise "Queue already exists" if File.exist?(root)
FileUtils.mkdir(root, mode: 0700)
unit = "llm-opencode-go-queue-#{stamp}.service"
monitor = "llm-opencode-go-queue-monitor-#{stamp}"
queue = { "created_at" => Time.now.utc.iso8601, "campaigns" => paths, "profiles" => order,
  "source_commit" => manifests.first.fetch("source_commit"), "generation_unit" => unit,
  "monitor_unit" => "#{monitor}.service", "monitor_timer" => "#{monitor}.timer",
  "monitor_note" => "Four-hour status timer records progress; it does not wake an assistant. Actively inspect the initial production pilots.",
  "schedule" => "First campaign, then the free campaign; yield early at a subscription-quota boundary and return to unfinished first-campaign work. All generation serial; no native evaluation overlaps it.",
  "go_balance_fallback_disabled" => true, "operator_confirmation" => "Use balance off, previously confirmed by the user; this campaign does not change billing settings.",
  "free_model_substitution_allowed" => false, "fable" => "Remains paused at 139/220; re-evaluate priority at its 2026-10-30T17:00Z weekly reset." }
File.write(File.join(root, "queue.json"), JSON.pretty_generate(queue) + "\n")
FileUtils.cp_r(setup, File.join(root, "setup"))
FileUtils.cp(__FILE__, File.join(root, "launch.rb"))
paths.zip(manifests).each do |path, manifest|
  FileUtils.cp(File.join(setup, "regression-tests.log"), File.join(path, "regression-tests.log"))
  FileUtils.cp(File.join(setup, "setup-check.json"), File.join(path, "setup-check.json"))
  manifest.merge!("queue_root" => root, "generation_unit" => unit, "monitor_unit" => "#{monitor}.service", "monitor_timer" => "#{monitor}.timer")
  File.write(File.join(path, "campaign.json"), JSON.pretty_generate(manifest) + "\n")
end
runner = File.join(manifests.first.fetch("working_directory"), "tools/opencode_campaign_queue.rb")
OpenCodeCampaignQueue.new(root)
lock.close
puts checked("systemd-run", "--user", "--unit=#{unit}", "--description=Serial OpenCode Go experiment generation",
  "--property=Type=exec", "--property=WorkingDirectory=#{manifests.first.fetch('working_directory')}",
  "--setenv=PATH=/home/petert/.local/bin:/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin",
  "--property=StandardOutput=append:#{root}/generation.log", "--property=StandardError=append:#{root}/generation.log",
  "/usr/bin/ruby", runner, "run", root)
receipt = { "launched_at" => Time.now.utc.iso8601, "unit" => unit, "queue_root" => root,
  "source_commit" => manifests.first.fetch("source_commit"), "launch_script_sha256" => Digest::SHA256.file(__FILE__).hexdigest,
  "tests" => %w[runs assertions failures errors skips].zip(counts).to_h }
File.write(File.join(root, "launch.json"), JSON.pretty_generate(receipt) + "\n")
paths.each { |path| File.write(File.join(path, "launch.json"), JSON.pretty_generate(receipt) + "\n") }
puts checked("systemd-run", "--user", "--unit=#{monitor}", "--description=Four-hour OpenCode Go experiment status",
  "--on-active=4h", "--on-unit-active=4h", "--timer-property=AccuracySec=1min", "--property=Type=oneshot",
  "--property=StandardOutput=append:#{root}/monitor.log", "--property=StandardError=append:#{root}/monitor.log",
  "/usr/bin/ruby", runner, "status", root)
puts JSON.pretty_generate(receipt)
