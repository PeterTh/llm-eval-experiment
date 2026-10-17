#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
require "digest"
require "fileutils"
require "open3"
require "tmpdir"
require "time"
require "socket"
require_relative "../lib/experiment_selection"
require_relative "../lib/opencode_harness"

# Host-specific campaign preparation. It freezes only committed method sources,
# never changes the user's worktree, never launches an inference, and preserves
# the suspended Fable campaign. Launch preflight and generation separately.
def checked(*command)
  output, error, status = Open3.capture3(*command)
  raise "#{command.first} failed: #{error}" unless status.success?
  output
end

def archive(repository, destination)
  FileUtils.mkdir_p(destination)
  statuses = Open3.pipeline(["git", "-C", repository, "archive", "HEAD"], ["tar", "-xf", "-", "-C", destination])
  raise "Snapshot extraction failed" unless statuses.all?(&:success?)
end

def hashes(directory)
  Dir[File.join(directory, "**", "*"), File.join(directory, "**", ".*")].uniq.sort.select { |path| File.file?(path) }.to_h do |path|
    [path.delete_prefix(directory + "/"), Digest::SHA256.file(path).hexdigest]
  end
end

repo = File.expand_path("..", __dir__)
bench_repo = File.expand_path("../benchmarks", repo)
source_repo = File.join(Dir.home, "llm_para_experiments")
raise "Benchmark worktree not clean" unless checked("git", "-C", bench_repo, "status", "--porcelain").empty?
sequential_commit = checked("git", "-C", bench_repo, "rev-parse", "HEAD").strip
raise "Sequential baseline changed" unless sequential_commit == "2bc11aeac658a87b5cae25d03e0669f65d32922e"
raise "Staged source changes" unless checked("git", "-C", source_repo, "diff", "--cached", "--name-only").empty?
pids, status = Open3.capture2("pgrep", "-u", "llmtest")
raise "Evaluation account is busy: #{pids}" unless status.exitstatus == 1 && pids.empty?
binary = "/home/llmtest/.local/share/opencode-eval/versions/#{OpenCodeHarness::VERSION}/opencode"
raise "Installed executable changed" unless Digest::SHA256.file(binary).hexdigest == OpenCodeHarness::BINARY_SHA256
fable = File.join(Dir.home, "llm_para_campaigns/20261011-092100-fable51-medium")
pause_path = File.join(fable, "operator-pause-20261017.json")
pause = JSON.parse(File.read(pause_path))
raise "Fable is not fully paused" unless File.exist?(File.join(fable, "STOP")) && pause["state"] == "operator_paused" && pause["automatic_restart_enabled"] == false
preserved = pause.fetch("observation_sha256")
raise "Fable preserved scope differs" unless preserved.size == 95
preserved.each do |name, digest|
  raise "Paused Fable observation changed: #{name}" unless Digest::SHA256.file(File.join(fable, "observations", name)).hexdigest == digest
end
fable_manifest = JSON.parse(File.read(File.join(fable, "campaign.json")))
%w[generation_unit monitor_unit monitor_timer].each do |key|
  raise "Fable service is active" unless checked("systemctl", "--user", "show", fable_manifest.fetch(key), "-p", "ActiveState", "--value").strip == "inactive"
end
benchmarks = %w[black-scholes cahn-hilliard cholesky floydwarshall matmul nbody qtclustering roomsim spmv stencil3d unstructured]
backends = %w[omp cuda mpi hybrid]
profiles = { "gpt-6.1-sol-oc-medium" => { "model" => "openai/gpt-6.1-sol", "reasoning_effort" => "medium" } }
ids = ExperimentSelection.configurations(benchmarks: benchmarks, models: profiles.keys, backends: backends, repetitions: 5).map { |configuration| ExperimentSelection.id(configuration) }
preflights = %w[black-scholes_omp nbody_cuda floydwarshall_mpi qtclustering_hybrid].map do |pair|
  benchmark, backend = pair.split("_")
  "#{benchmark}_#{profiles.keys.first}_#{backend}_r1"
end
batch = Time.now.utc.strftime("%Y%m%d-%H%M%S")
campaign = File.join(Dir.home, "llm_para_campaigns/#{batch}-sol61-opencode-medium")
results = File.join(source_repo, batch)
raise "Campaign already exists" if File.exist?(campaign) || File.exist?(results) || File.exist?("/home/llmtest/evals/#{batch}")
runtime = Dir.mktmpdir("sol61-opencode-generation-", "/tmp")
FileUtils.chmod(0755, runtime)
FileUtils.mkdir_p(campaign, mode: 0700)
FileUtils.mkdir_p(results)
archive(repo, File.join(campaign, "method"))
FileUtils.cp_r(File.join(campaign, "method"), File.join(runtime, "experiment"))
archive(bench_repo, File.join(runtime, "benchmarks"))
FileUtils.cp_r(File.join(runtime, "benchmarks"), File.join(campaign, "sequential-input"))
FileUtils.cp(binary, File.join(runtime, "opencode"), preserve: true)
%w[run_opencode_campaign.rb monitor_generation_campaign.rb].each do |name|
  destination = name == "run_opencode_campaign.rb" ? "run.rb" : "monitor.rb"
  FileUtils.cp(File.join(campaign, "method/tools", name), File.join(runtime, destination))
  FileUtils.cp(File.join(runtime, destination), File.join(campaign, destination))
end
[runtime, campaign].each { |path| File.write(File.join(path, "campaign.path"), campaign + "\n") }
File.write(File.join(campaign, "run-ids.txt"), ids.join("\n") + "\n")
File.write(File.join(campaign, "preflight-ids.txt"), preflights.join("\n") + "\n")
manifest = { "schema_version" => 1, "campaign_id" => batch, "prepared_at" => Time.now.utc.iso8601,
  "phase" => "production_preflight", "host" => Socket.gethostname, "label" => "Sol 6.1 OpenCode medium",
  "source_repository" => "https://github.com/PeterTh/llm-eval-experiment", "source_commit" => checked("git", "-C", repo, "rev-parse", "HEAD").strip,
  "source_note" => "Committed method snapshot only; unrelated worktree edits are not selected or copied.",
  "files" => hashes(File.join(runtime, "experiment")), "benchmark_files" => hashes(File.join(runtime, "benchmarks")),
  "sequential_source_repository" => "https://github.com/PeterTh/llm-eval-benchmarks", "sequential_source_commit" => sequential_commit,
  "harness" => "opencode", "opencode_version" => OpenCodeHarness::VERSION,
  "opencode_tag_commit" => "e3c4eb242585dcd77be1a867391b7c25fd47ce52", "opencode_binary" => File.join(runtime, "opencode"),
  "opencode_binary_sha256" => OpenCodeHarness::BINARY_SHA256,
  "opencode_release_archive_sha256" => "13a8fb2978302071b86f9d7e00da9c8895f9cd846978379c3bdc6a5333536c9b",
  "opencode_auth_file" => "/home/llmtest/.local/share/opencode-eval/access/data/opencode/auth.json",
  "authentication" => "OpenCode built-in ChatGPT Pro/Plus OAuth; no API-key, credit or fallback provider enabled by this campaign",
  "models" => profiles, "benchmarks" => benchmarks, "backends" => backends, "repetitions" => 5,
  "expected_runs" => ids.size, "per_run_timeout_seconds" => 14400, "preflight_ids" => preflights,
  "workspace" => "/home/llmtest/evals/#{batch}", "persistent_results" => results, "runtime_root" => runtime,
  "working_directory" => File.join(runtime, "experiment"), "source_branch" => checked("git", "-C", source_repo, "branch", "--show-current").strip,
  "initial_generated_source_commit" => checked("git", "-C", source_repo, "rev-parse", "HEAD").strip,
  "preflight_unit" => "llm-sol61-oc-preflight-#{batch}.service", "generation_unit" => "llm-sol61-oc-generation-#{batch}.service",
  "monitor_unit" => "llm-sol61-oc-monitor-#{batch}.service", "monitor_timer" => "llm-sol61-oc-monitor-#{batch}.timer",
  "paused_campaign" => { "path" => fable, "pause_receipt_sha256" => Digest::SHA256.file(pause_path).hexdigest,
    "resume_not_before" => pause.fetch("next_weekly_reset"), "verified_preserved_observations" => preserved.size,
    "constraint" => "Fable remains fully suspended; campaigns never run concurrently under llmtest." },
  "comparison" => { "native_sol_batch" => "20261006-204623", "native_sol_profile" => "gpt-6.1-sol-medium",
    "native_sonnet_batch" => "20261014-212207", "native_sonnet_profile" => "claude-sonnet-5.5-cc-medium",
    "deferred_profile" => "claude-sonnet-5.5-oc-medium",
    "deferral_reason" => "No confirmed supported subscription-only Anthropic route in pinned OpenCode; no API billing, identity spoofing or Claude Code loop substitution.",
    "interpretation" => "Historical native baselines with the same sequential input and budget; model aliases are not immutable snapshots. Stock OpenCode model-specific prompts/adapters are retained; not a pure model-only causal comparison." },
  "retention" => "Local NVMe runtime and workspaces; persistent source, transcripts and compact metadata under home. No binaries, dependency trees, raw session databases or credentials in Git.",
  "reuse" => "All four predeclared production preflights count toward 220 observations regardless of generated-program correctness.",
  "monitoring" => "Serial admission/cleanup checks between observations, approximately four-hour monitoring after preflight.",
  "accounting" => "Exact native per-request step-finish usage includes compaction; input includes cache, output includes reasoning. Observed scheduled retry waits are excluded from elapsed time; API-only time is unavailable.",
  "next_stages" => ["Commit original generated sources", "Established validation", "Luna/high static timing review of successful MPI/hybrid and all-backend QT; Sol 6.1 adjudication only when uncertain", "Single timing-only correction commit and affected validation", "Established-size scoped benchmarking with hourly checks", "New winner reviews, pricing, package and website integration"] }
File.write(File.join(campaign, "campaign.json"), JSON.pretty_generate(manifest) + "\n")
dry = checked("ruby", File.join(runtime, "run.rb"), "--production", "--continue=#{batch}")
File.write(File.join(campaign, "production-dry-run.txt"), dry)
raise "Dry-run scope differs" unless dry.include?("Total number of experiments to run: 220") && ids.all? { |id| dry.include?(id) }
raise "Model, effort or budget differs" unless dry.include?("--model openai/gpt-6.1-sol --variant medium") && dry.include?("Per-run wall clock limit: 240 minutes")
pilot = checked("ruby", File.join(runtime, "run.rb"), "--production", "--continue=#{batch}", "--run-ids=#{campaign}/preflight-ids.txt")
File.write(File.join(campaign, "preflight-dry-run.txt"), pilot)
raise "Pilot scope differs" unless pilot.include?("Total number of experiments to run: 4")
puts JSON.pretty_generate(manifest.slice("campaign_id", "expected_runs", "preflight_ids", "opencode_version", "source_commit", "persistent_results", "runtime_root", "generation_unit"))
puts "Campaign: #{campaign}"
