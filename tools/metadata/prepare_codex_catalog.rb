#!/usr/bin/env ruby
# frozen_string_literal: true
require "optparse"
require "etc"
require "tmpdir"
require_relative "../codex_observation"

options = { model: "gpt-6.1-terra", effort: "ultra", attempts: 3 }
OptionParser.new do |parser|
  parser.on("--binary=PATH") { |value| options[:binary] = File.realpath(value) }
  parser.on("--output=PATH") { |value| options[:output] = File.expand_path(value) }
  parser.on("--model=MODEL") { |value| options[:model] = value }
  parser.on("--effort=EFFORT") { |value| options[:effort] = value }
end.parse!
abort "Unexpected arguments" unless ARGV.empty?
abort "Run as the isolated llmtest account" unless Process.uid == Etc.getpwnam("llmtest").uid
destination = options.fetch(:output)
raise "Output already exists" if [destination, destination + ".receipt.json"].any? { |p| File.exist?(p) || File.symlink?(p) }
root = Dir.mktmpdir("codex-observation-catalog-", "/tmp")
workspace_root = File.join("/home/llmtest/evals", File.basename(root))
workspace = File.join(workspace_root, "catalog-probe")
FileUtils.mkdir_p(workspace)
spec = { "id" => "catalog-probe", "state" => File.join(root, "private"), "workspace" => workspace,
  "binary" => options.fetch(:binary), "model" => options.fetch(:model), "effort" => options.fetch(:effort),
  "instruction" => "unused: metadata preparation only", "flags" => ["--version"], "timeout_seconds" => 30, "environment" => {} }
spec_path = File.join(root, "spec.json")
File.write(spec_path, JSON.generate(spec))
runner = CodexObservationRunner.new(spec_path)
attempts = []
begin
  runner.prepare
  state = spec.fetch("state")
  prepared = JSON.parse(File.read(File.join(state, "prepared.json")))
  version = prepared.fetch("version")
  catalog_content = receipt = nil
  model_args = ["--model", options.fetch(:model), "-c", "model_reasoning_effort=#{options.fetch(:effort).to_json}"]
  flags = %w[--disable apps --disable plugins --disable multi_agent --disable multi_agent_v2]
  cache_path = File.join(state, "home/.codex/models_cache.json")
  options.fetch(:attempts).times do |index|
    started = Time.now
    begin
      response = CodexModelCatalog.list_models(runner.filesystem.command(*model_args, *flags, "app-server", "--stdio"))
      CodexModelCatalog.require_advertised!(response, model: options.fetch(:model), effort: options.fetch(:effort))
      catalog_content, receipt = CodexModelCatalog.from_cache(runner.read_regular(cache_path), version: version,
        model: options.fetch(:model), effort: options.fetch(:effort), not_before: started)
      attempts << { "attempt" => index + 1, "success" => true, "seconds" => Time.now - started }
      break
    rescue CodexModelCatalog::Invalid, Errno::ENOENT, RuntimeError => e
      attempts << { "attempt" => index + 1, "success" => false, "seconds" => Time.now - started, "error_class" => e.class.name }
      sleep(2 * (index + 1)) if index < options.fetch(:attempts) - 1
    end
  end
  raise "Native metadata preparation failed before inference: #{JSON.generate(attempts)}" unless catalog_content && receipt
  catalog_path = File.join(state, "model-catalog.json")
  File.write(catalog_path, catalog_content, perm: 0444)
  # A positive offline check must not accidentally succeed via the native cache.
  File.rename(cache_path, File.join(state, "fetched-cache-private.json"))
  isolated = GenerationFilesystem.new(workspace: workspace, state: state, binary: options.fetch(:binary),
    companions: { "codex-code-mode-host" => File.join(File.dirname(options.fetch(:binary)), "codex-code-mode-host") },
    read_only_state_files: ["model-catalog.json"])
  offline = isolated.prefix
  offline.insert(offline.size - 1, "--unshare-net")
  command = offline + [GenerationFilesystem::BINARY, *model_args, "-c", "model_catalog_json=#{CodexModelCatalog::MOUNT.to_json}",
    *flags, "app-server", "--stdio"]
  offline_result = CodexModelCatalog.list_models(command)
  advertised = CodexModelCatalog.require_advertised!(offline_result, model: options.fetch(:model), effort: options.fetch(:effort))
  raise "Offline check unexpectedly created a remote cache" if File.exist?(cache_path)
  # Missing catalog must stop initialization, not silently select fallback data.
  missing_command = offline + [GenerationFilesystem::BINARY, *model_args, "-c", 'model_catalog_json="/run/llm-eval/state/missing-catalog.json"',
    *flags, "app-server", "--stdio"]
  missing_rejected = false
  begin
    CodexModelCatalog.list_models(missing_command, timeout_seconds: 10)
  rescue CodexModelCatalog::Invalid
    missing_rejected = true
  end
  raise "Missing local catalog did not fail closed" unless missing_rejected
  probe_script = 'require "json"; begin; File.open(ARGV[0], "w") { |f| f.write("invalid") }; abort "catalog writable"; rescue Errno::EROFS, Errno::EACCES; puts JSON.generate({read_only: true}); end'
  output, error, status = Open3.capture3(*(offline + ["ruby", "-e", probe_script, CodexModelCatalog::MOUNT]))
  raise "Catalog was not read-only: #{error}" unless status.success? && JSON.parse(output).fetch("read_only")
  raise "Unexpected inference/session creation" unless Dir[File.join(state, "home/.codex/sessions/**/*.jsonl")].empty?
  runner.persist_refreshed_credentials!(prepared.fetch("auth_before_sha256"))
  receipt.merge!("preparation_attempts" => attempts, "offline_native_schema_check" => true,
    "native_cache_absent_during_offline_check" => true, "missing_catalog_rejected" => true,
    "read_only_mount_verified" => true, "model_list_entry" => advertised,
    "binary_sha256" => prepared.fetch("binary_sha256"),
    "collector_sha256" => Digest::SHA256.file(__FILE__).hexdigest,
    "catalog_helper_sha256" => Digest::SHA256.file(File.expand_path("../../lib/codex_model_catalog.rb", __dir__)).hexdigest)
  CodexModelCatalog.publish(destination, catalog_content)
  CodexModelCatalog.publish(destination + ".receipt.json", JSON.pretty_generate(receipt) + "\n")
  puts JSON.pretty_generate(receipt.except("model_list_entry"))
ensure
  # Both paths are allocated exclusively by this invocation, never existing data.
  FileUtils.remove_entry_secure(root)
  FileUtils.remove_entry_secure(workspace)
  Dir.rmdir(workspace_root)
end
