#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
require "digest"
$stdout.sync = true
$stderr.sync = true
campaign = File.read(File.join(__dir__, "campaign.path")).strip
manifest = JSON.parse(File.read(File.join(campaign, "campaign.json")))
runtime = manifest.fetch("working_directory")
manifest.fetch("files").each do |relative, digest|
  raise "Launch snapshot changed: #{relative}" unless Digest::SHA256.file(File.join(runtime, relative)).hexdigest == digest
end
manifest.fetch("benchmark_files").each do |relative, digest|
  raise "Sequential input changed: #{relative}" unless Digest::SHA256.file(File.join(manifest.fetch("runtime_root"), "benchmarks", relative)).hexdigest == digest
end
binary = manifest.fetch("opencode_binary")
raise "OpenCode executable changed" unless Digest::SHA256.file(binary).hexdigest == manifest.fetch("opencode_binary_sha256")
raise "Production budget required" unless ARGV.include?("--production") && !ARGV.include?("--smoke")
raise "Campaign identity differs" unless ARGV.include?("--continue=#{manifest.fetch('campaign_id')}")
ENV["LLM_EVAL_HARNESS"] = "opencode"
ENV["LLM_EVAL_MODELS"] = manifest.fetch("models").keys.join(",")
ENV["LLM_EVAL_OPENCODE_BINARY"] = binary
ENV["LLM_EVAL_OPENCODE_AUTH_FILE"] = manifest.fetch("opencode_auth_file")
Dir.chdir(runtime)
load File.join(runtime, "experiment.rb")
