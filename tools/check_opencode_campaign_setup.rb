#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
require "open3"
require "digest"
require "time"
require "shellwords"
require_relative "../lib/opencode_harness"
require_relative "../lib/generation_filesystem"

# Host-only, zero-inference setup evidence for an approved Go profile. Synthetic
# compilation uses the existing isolated probe; retain only selected catalog
# records, never credentials or whole model catalogs.
abort "usage: check_opencode_campaign_setup.rb PROFILE EXISTING_SETUP_DIRECTORY" unless ARGV.size == 2
name, destination = ARGV
profile = OpenCodeHarness.campaign_profile(name)
raise "Not an approved Go profile" unless profile["access"] == "opencode-go"
root = File.realpath(destination)
repo = File.expand_path("..", __dir__)
binary = "/home/llmtest/.local/share/opencode-eval/versions/#{OpenCodeHarness::VERSION}/opencode"
raise "Setup directory is not empty" unless Dir.empty?(root)
raise "Installed executable changed" unless Digest::SHA256.file(binary).hexdigest == OpenCodeHarness::BINARY_SHA256

def capture(*args, **options)
  out, err, status = Open3.capture3(*args, **options)
  raise "#{args.first} failed (#{status.exitstatus}): #{err.lines.first}" unless status.success?
  out
end

def logged(root, name, *args, **options)
  out, err, status = Open3.capture3(*args, **options)
  File.write(File.join(root, name), out + err)
  raise "#{name} failed; inspect its retained log" unless status.success?
  out
end

pids, status = Open3.capture2("pgrep", "-u", "llmtest")
raise "Evaluation account busy" unless status.exitstatus == 1 && pids.empty?
lock = File.open("/tmp/local-evaluation-#{Process.uid}-performance.lock", "a")
raise "Native evaluation is active" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
# The tests themselves exercise this same exclusion lock; release the initial
# idle check for these synthetic fixtures and reacquire before hardware probes.
lock.close
log = logged(root, "regression-tests.log", "ruby", "-Itest", "-e",
  'Dir["test/test_*.rb"].sort.each { |path| require_relative path }', chdir: repo)
counts = log.scan(/^(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips$/).last&.map(&:to_i)
raise "Regression tests incomplete" unless counts && counts.take(2).all?(&:positive?) && counts.drop(2) == [0, 0, 0]
lock = File.open("/tmp/local-evaluation-#{Process.uid}-performance.lock", "a")
raise "Native evaluation became active" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
args = ["ruby", File.join(repo, "tools/check_generation_filesystem.rb"), binary, name]
out = logged(root, "#{name}-isolation.log", "su", "-", "llmtest", "--shell=/bin/bash", "-c", Shellwords.join(args))
isolation = JSON.parse(out.lines.last)
raise "Probe scope differs" unless isolation["inferences_launched"] == 0 && isolation["model"] == profile.fetch("model") && isolation["effort"] == profile.fetch("reasoning_effort")
raise "Isolation policy differs" unless isolation.dig("filesystem_isolation", "policy") == GenerationFilesystem::POLICY
raise "Hardware check failed" unless isolation.fetch("cuda_probe") == "cuda=7" && isolation.fetch("hybrid_probe").lines.size == 2
args = ["ruby", File.join(repo, "tools/opencode_go_access.rb"), profile.fetch("model"), "/home/llmtest/.local/share/opencode-eval/go-access/data/opencode/auth.json"]
access = JSON.parse(logged(root, "#{name}-access.json", "su", "-", "llmtest", "--shell=/bin/bash", "-c", Shellwords.join(args)))
raise "Route unavailable" unless access["available"] && access["free_only"] == profile.fetch("free_only")
pids, status = Open3.capture2("pgrep", "-u", "llmtest")
raise "Probe left evaluation processes running" unless status.exitstatus == 1 && pids.empty?

id = profile.fetch("model").split("/", 2).last
catalog = JSON.parse(capture("curl", "--fail", "--silent", "--show-error", "--max-time", "30", "https://models.dev/api.json"))
go_catalog = JSON.parse(capture("curl", "--fail", "--silent", "--show-error", "--max-time", "30", "https://opencode.ai/inference/go/v1/models"))
go_model = go_catalog.fetch("data").find { |entry| entry["id"] == id }
raise "Published model unavailable" unless go_model
metadata = { "retrieved_at" => Time.now.utc.iso8601,
  "sources" => { "https://models.dev/api.json" => catalog.fetch("opencode-go").fetch("models").fetch(id),
    "https://opencode.ai/inference/go/v1/models" => go_model } }
File.write(File.join(root, "model-metadata.json"), JSON.pretty_generate(metadata) + "\n")
files = Dir[File.join(repo, "lib/**/*.{rb,json}"), File.join(repo, "tools/*.rb"), File.join(repo, "test/**/*.rb")].sort
receipt = { "checked_at" => Time.now.utc.iso8601, "inferences_launched" => 0,
  "source_commit" => capture("git", "-C", repo, "rev-parse", "HEAD").strip,
  "profiles" => { name => { "isolation" => isolation, "access" => access } },
  "tests" => %w[runs assertions failures errors skips].zip(counts).to_h,
  "files" => files.to_h { |path| [path.delete_prefix(repo + "/"), Digest::SHA256.file(path).hexdigest] },
  "notes" => ["Stock pinned OpenCode prompts and adapter, explicit #{profile.fetch('reasoning_effort')} reasoning, advertised output limit.",
    "No inference requests or billing changes; probe credentials removed with its isolated temporary state."] }
File.write(File.join(root, "setup-check.json"), JSON.pretty_generate(receipt) + "\n")
lock.close
puts JSON.pretty_generate(receipt.slice("checked_at", "tests", "inferences_launched", "notes"))
