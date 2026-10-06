#!/usr/bin/env ruby
# frozen_string_literal: true
require "fileutils"
require "open3"
require "time"
require "shellwords"
require_relative "../lib/claude_generation_observation"
require_relative "../lib/codex_generation_observation"
require_relative "../lib/generation_cleanup"

# Serial orchestration around experiment.rb, not a replacement generation harness.
# Checks run only between observations; no compilation, validation or performance runs.
class GenerationCampaign
  def initialize(root)
    @root = File.realpath(root)
    @manifest = JSON.parse(File.read(File.join(@root, "campaign.json")))
    @harness = @manifest.fetch("harness", "claude")
    raise "Unsupported generation harness" unless %w[claude codex].include?(@harness)
    @ids = File.readlines(File.join(@root, "run-ids.txt"), chomp: true)
    raise "Invalid campaign IDs" unless @ids.size == @manifest.fetch("expected_runs") && @ids.uniq == @ids && @ids.all? { |id| id.match?(/\A[a-zA-Z0-9_.-]+\z/) }
    @batch = @manifest.fetch("campaign_id")
    raise "Invalid campaign timestamp" unless @batch.match?(/\A\d{8}-\d{6}\z/)
    @results = @manifest.fetch("persistent_results")
    @preflight_ids = @manifest.fetch("preflight_ids") { [@manifest.fetch("preflight_id")] }
    unless !@preflight_ids.empty? && @preflight_ids.uniq == @preflight_ids && (@preflight_ids - @ids).empty?
      raise "Invalid preflight selection"
    end
    if @harness == "codex"
      models = @manifest.fetch("models")
      raise "Codex model scope differs" unless @ids.map { |id| id.split("_")[1] }.uniq.sort == models.keys.sort
      raise "Every Codex profile needs a preflight" unless @preflight_ids.map { |id| id.split("_")[1] }.uniq.sort == models.keys.sort
    end
    @observations = File.join(@root, "observations")
    FileUtils.mkdir_p(@observations)
    FileUtils.mkdir_p(File.join(@root, "cleanup"))
  end

  def json(name, value)
    target = File.join(@root, name)
    temporary = "#{target}.#{Process.pid}.tmp"
    File.write(temporary, JSON.pretty_generate(value) + "\n")
    File.rename(temporary, target)
  end

  def observation(id, baseline: nil)
    arguments = { timeout_seconds: @manifest.fetch("per_run_timeout_seconds"), baseline: baseline }
    report = if @harness == "codex"
      profile = @manifest.fetch("models").fetch(id.split("_")[1])
      CodexGenerationObservation.read(File.join(@results, id), **arguments, model: profile.fetch("model"),
        effort: profile.fetch("reasoning_effort"), version: @manifest.fetch("codex_version"))
    else
      ClaudeGenerationObservation.read(File.join(@results, id), **arguments, model: @manifest.fetch("invoked_model"),
        version: @manifest.fetch("claude_version"))
    end
    path = File.join(@observations, "#{id}.json")
    raise "Completed observation changed: #{id}" if File.file?(path) && JSON.parse(File.read(path)) != report
    json("observations/#{id}.json", report) unless File.file?(path)
    report
  end

  def gate
    reports = @preflight_ids.map { |id| observation(id) }
    raise "Preflight infrastructure incomplete" unless reports.all? { |report| report.fetch("outcome") == "completed" }
    recover_usage!(reports, prefix: "preflight-") if @harness == "codex"
    existing = File.join(@root, "preflight-gate.json")
    value = { "accepted" => true,
      "criterion" => "Harness identity, isolation, metadata and production budget only; generated-program correctness is not a selection criterion." }
    value.merge!(@harness == "codex" ? { "preflights" => reports } : { "preflight" => reports.first })
    raise "Preflight gate differs" if File.file?(existing) && JSON.parse(File.read(existing)) != value
    json("preflight-gate.json", value) unless File.file?(existing)
    reports.each { |report| puts "Preflight accepted: #{report.fetch('id')} (#{report.fetch('raw_total_seconds')}s)" }
  end

  def preflight
    lock = File.open(File.join(@root, "controller.lock"), "a")
    locked = lock.flock(File::LOCK_EX | File::LOCK_NB)
    raise "Another controller is active" unless locked
    @preflight_ids.each { |id| execute_observation(id, phase: "preflight") }
    gate
    snapshot("preflight_complete")
  rescue StandardError => e
    snapshot("needs_review", error: "#{e.class}: #{e.message}") if locked
    raise
  ensure
    lock&.close
  end

  def snapshot(status, active_id: nil, error: nil)
    reports = Dir[File.join(@observations, "*.json")].sort.map { |p| JSON.parse(File.read(p)) }
    value = { "campaign_id" => @batch, "checked_at" => Time.now.utc.iso8601, "status" => status,
      "expected" => @ids.size, "completed" => reports.size, "active_id" => active_id,
      "outcomes" => reports.group_by { |r| r.fetch("outcome") }.transform_values(&:size),
      "raw_generation_seconds" => reports.sum { |r| r.fetch("raw_total_seconds") },
      "retained_total_tokens" => reports.sum { |r| r.fetch("total_tokens", 0) }, "error" => error }
    json("progress.json", value)
    puts JSON.generate(value)
    value
  end

  def status
    progress = File.join(@root, "progress.json")
    value = File.file?(progress) ? JSON.parse(File.read(progress)) : { "status" => "prepared", "completed" => 0, "expected" => @ids.size }
    unit, result = Open3.capture2("systemctl", "--user", "show", @manifest.fetch("generation_unit"),
      "-p", "LoadState", "-p", "ActiveState", "-p", "SubState", "-p", "ExecMainStatus")
    unit_state = result.success? ? unit.lines.to_h { |line| line.strip.split("=", 2) } : {}
    health = if %w[complete needs_review preflight_complete].include?(value["status"])
      value["status"]
    elsif unit_state["ActiveState"] != "active"
      "unexpected_stop"
    else
      "running"
    end
    value = value.merge("observed_at" => Time.now.utc.iso8601, "monitor_health" => health, "unit" => unit_state)
    json("monitor-status.json", value)
    puts JSON.generate(value)
  end

  def run
    lock = File.open(File.join(@root, "controller.lock"), "a")
    locked = lock.flock(File::LOCK_EX | File::LOCK_NB)
    raise "Another controller is active" unless locked
    gate_data = JSON.parse(File.read(File.join(@root, "preflight-gate.json")))
    raise "Preflight not accepted" unless gate_data.fetch("accepted")
    baselines = @harness == "codex" ? gate_data.fetch("preflights") : [gate_data.fetch("preflight")]
    raise "Preflight scope differs" unless baselines.map { |r| r.fetch("id") }.sort == @preflight_ids.sort
    unexpected = Dir.children(@results) - @ids
    raise "Unexpected result directories: #{unexpected.join(', ')}" unless unexpected.empty?
    @ids.each do |id|
      baseline = baselines.find { |r| @harness == "claude" || r.fetch("id").split("_")[1] == id.split("_")[1] }
      raise "Missing preflight profile for #{id}" unless baseline
      execute_observation(id, baseline: baseline)
    end
    snapshot("generation_complete")
    recover_usage!(Dir[File.join(@observations, "*.json")].sort.map { |p| JSON.parse(File.read(p)) }) if @harness == "codex"
    commit_outputs
    snapshot("complete")
  rescue StandardError => e
    snapshot("needs_review", error: "#{e.class}: #{e.message}") if locked
    warn "Campaign stopped without repeating completed observations: #{e.message}"
    raise
  ensure
    lock&.close
  end

  def execute_observation(id, baseline: nil, phase: "running")
    raise "Operator stop requested" if File.exist?(File.join(@root, "STOP"))
    directory = File.join(@results, id)
    return observation(id, baseline: baseline) if File.file?(File.join(directory, "timing.txt"))
    raise "Incomplete canonical observation: #{id}" if File.exist?(directory)
    snapshot(phase, active_id: id)
    ensure_account_idle!
    ids_path = File.join(@root, "active-run-ids.txt")
    File.write(ids_path, "#{id}\n")
    command = ["/usr/bin/ruby", File.join(@manifest.fetch("runtime_root"), "run.rb"), "--production", "--run",
      "--continue=#{@batch}", "--run-ids=#{ids_path}"]
    puts "Launching #{id} at #{Time.now.utc.iso8601}"
    success = launch(command)
    cleanup_after_run!(id)
    raise "Harness exited unsuccessfully for #{id}" unless success
    observation(id, baseline: baseline)
    snapshot(phase)
  end

  def recover_usage!(reports, prefix: "")
    ensure_account_idle!
    completed = reports.select { |r| r.fetch("outcome") == "completed" }
    requests = completed.map do |report|
      id = report.fetch("id")
      CodexUsage.transcript_request(batch: @batch, id: id, path: File.join(@results, id, "output.txt"))
    end
    raise "Reused Codex session ID" unless requests.map { |r| r.fetch("session_id") }.uniq.size == requests.size
    reader = ["ruby", File.expand_path("metadata/recover_codex_usage.rb", __dir__), "--read-sessions",
      "--sessions=#{@manifest.fetch('codex_sessions_root')}"]
    stdout, stderr, status = read_session_usage(reader, requests)
    raise "Exact Codex accounting failed: #{stderr}" unless status.success?
    records = stdout.lines.map { |line| CodexUsage.validate_record!(JSON.parse(line)) }
    raise "Recovered usage scope differs" unless records.map { |r| r.fetch("run_id") } == completed.map { |r| r.fetch("id") }
    records.each do |record|
      raise "Recovered CLI version differs" unless record.fetch("cli_version") == @manifest.fetch("codex_version")
      CodexUsage.verify_transcript!(record, id: record.fetch("run_id"), batch: @batch,
        path: File.join(@results, record.fetch("run_id"), "output.txt"))
    end
    content = records.map { |r| JSON.generate(r) + "\n" }.join
    output = File.join(@root, "#{prefix}codex-usage.jsonl")
    raise "Exact usage evidence changed" if File.exist?(output) && File.binread(output) != content
    unless File.exist?(output)
      temporary = "#{output}.#{Process.pid}.tmp"
      File.write(temporary, content)
      File.rename(temporary, output)
    end
    json("#{prefix}usage-recovery.json", { "records" => records.size, "sha256" => Digest::SHA256.hexdigest(content),
      "total_tokens" => records.sum { |r| r.fetch("usage").fetch("total_tokens") },
      "unavailable" => reports.reject { |r| r.fetch("outcome") == "completed" }.map { |r| r.slice("id", "outcome") } })
  end

  def read_session_usage(reader, requests)
    Open3.capture3("su", "-", "llmtest", "--shell=/bin/bash", "-c", Shellwords.join(reader), stdin_data: JSON.generate(requests))
  end

  def ensure_account_idle!
    pids = GenerationCleanup.new.pids
    raise "llmtest is not idle (PIDs #{pids.join(', ')}); refusing launch" unless pids.empty?
  end

  def cleanup_after_run!(id)
    report = GenerationCleanup.new.verify!
    json("cleanup/#{id}.json", report.merge("id" => id, "checked_at" => Time.now.utc.iso8601))
    puts "Verified post-run cleanup for #{id}: #{JSON.generate(report)}" unless report.fetch("signal_attempts").empty?
  end

  def launch(command)
    system(*command)
  end

  def git(*arguments)
    output, status = Open3.capture2e("git", "-C", File.dirname(@results), *arguments)
    raise "Git #{arguments.first} failed: #{output}" unless status.success?
    output
  end

  def commit_outputs
    raise "Not on the expected generated-source branch" unless git("branch", "--show-current").strip == @manifest.fetch("source_branch", "claude")
    raise "Existing staged user changes; leave them untouched" unless git("diff", "--cached", "--name-only").empty?
    @ids.each do |id|
      # Never let git add collapse a program into a gitlink instead of retaining its code.
      raise "Nested repository requires preservation review: #{id}" unless Dir.glob(File.join(@results, id, "**/.git"), File::FNM_DOTMATCH).empty?
    end
    git("add", "--", @batch)
    staged = git("diff", "--cached", "--name-only", "-z").split("\0")
    raise "Staged paths outside this campaign" unless !staged.empty? && staged.all? { |p| p.start_with?("#{@batch}/") }
    entries = git("ls-files", "--stage", "--", @batch).lines
    raise "Gitlink or symlink in staged source" unless entries.all? { |line| line.start_with?("100644 ", "100755 ") }
    @ids.each do |id|
      required = %w[output.txt timing.txt instruction.txt process-status.txt]
      required << "usage.txt" if @harness == "claude"
      required.each do |name|
        raise "Required metadata ignored: #{id}/#{name}" unless staged.include?("#{@batch}/#{id}/#{name}")
      end
    end
    label = @manifest.fetch("label", "Opus 5.5 medium")
    git("commit", "--quiet", "-m", "Retain original #{label} outputs (#{@ids.size} production observations)")
    json("completion.json", { "completed_at" => Time.now.utc.iso8601, "campaign_id" => @batch,
      "observations" => @ids.size, "source_commit" => git("rev-parse", "HEAD").strip,
      "next_stage" => "Validation, timing review/correction, then established-size benchmarking. No evaluation was started by this controller." })
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  $stderr.sync = true
  command, root = ARGV
  abort "usage: generation_campaign.rb preflight|gate|run|status CAMPAIGN_ROOT" unless %w[preflight gate run status].include?(command) && root
  GenerationCampaign.new(root).public_send(command)
end
