#!/usr/bin/env ruby
# frozen_string_literal: true
require "fileutils"
require "json"
require "open3"
require "tempfile"
require "time"
require_relative "../lib/generation_filesystem"

# Trusted outer driver; only the stock CLI and its descendants enter the mount
# allowlist. Preparation is outside the task clock. No prompts or tools change.
class ClaudeObservationRunner
  EVIDENCE = "claude-filesystem.txt"
  CREDENTIALS = "/home/llmtest/.claude/.credentials.json"
  CONFIG = "/home/llmtest/.claude.json"
  CONFIG_FILES = %w[settings.json policy-limits.json remote-settings.json].freeze

  def initialize(path)
    @spec = JSON.parse(File.read(path))
    @state, @workspace, @binary = @spec.values_at("state", "workspace", "binary")
    raise "Wrong observation ID" unless File.basename(@workspace) == @spec.fetch("id")
    @env = @spec.fetch("environment")
  end

  def filesystem
    @filesystem ||= GenerationFilesystem.new(workspace: @workspace, state: @state, binary: @binary)
  end

  def write(path, value, perm: 0600)
    File.open(path, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, perm) do |file|
      file.write(JSON.pretty_generate(value) + "\n")
    end
  end

  def read_regular(path)
    raise "Linked or nonregular configuration: #{path}" unless File.file?(path) && File.realpath(path) == path
    File.binread(path)
  end

  def self.validate_credentials!(raw)
    value = JSON.parse(raw)
    oauth = value.fetch("claudeAiOauth")
    %w[accessToken refreshToken].each do |key|
      raise "Missing OAuth #{key}" unless oauth[key].is_a?(String) && !oauth[key].empty?
    end
    raise "Invalid OAuth expiry" unless oauth["expiresAt"].is_a?(Numeric) && oauth["expiresAt"] > 0
    value
  end

  def isolated_credentials
    File.join(@state, "home/.claude/.credentials.json")
  end

  def prepare
    raise "Claude state already exists" if File.exist?(@state)
    %w[home/.claude tmp var-tmp].each { |name| FileUtils.mkdir_p(File.join(@state, name), mode: 0700) }
    probe = filesystem.verify!
    raw = read_regular(CREDENTIALS)
    self.class.validate_credentials!(raw)
    File.write(isolated_credentials, raw, perm: 0600)
    if File.file?(CONFIG)
      config = JSON.parse(read_regular(CONFIG))
      config["projects"] = {} # Same reset as eval_user_support; no project history.
      write(File.join(@state, "home/.claude.json"), config)
    end
    CONFIG_FILES.each do |name|
      original = File.join(File.dirname(CREDENTIALS), name)
      File.write(File.join(@state, "home/.claude", name), read_regular(original), perm: 0600) if File.exist?(original)
    end
    out, err, status = Open3.capture3(@env, *filesystem.command("--version"))
    raise "Isolated Claude version check failed: #{err}" unless status.success?
    version = out.strip[/\A(\d+\.\d+\.\d+) \(Claude Code\)\z/, 1]
    raise "Unexpected Claude version output" unless version
    write(File.join(@state, "prepared.json"), {
      "version" => version, "binary_sha256" => Digest::SHA256.file(@binary).hexdigest,
      "filesystem_isolation" => filesystem.evidence.merge("preflight" => probe),
      "flags" => @spec.fetch("flags"), "model" => @spec.fetch("model"), "effort" => @spec.fetch("effort"),
      "environment" => @env, "auth_before_sha256" => Digest::SHA256.hexdigest(raw)
    })
    puts "Claude isolated filesystem verified (#{version}; no model request)."
  end

  def persist_refreshed_credentials!(before_sha)
    raw = read_regular(isolated_credentials)
    self.class.validate_credentials!(raw)
    return if Digest::SHA256.hexdigest(raw) == before_sha
    raise "Host credentials changed concurrently" unless Digest::SHA256.hexdigest(read_regular(CREDENTIALS)) == before_sha
    Tempfile.create([".credentials-", ".json"], File.dirname(CREDENTIALS), mode: 0600) do |file|
      file.write(raw)
      file.flush
      file.fsync
      File.rename(file.path, CREDENTIALS)
    end
  end

  def run
    evidence = JSON.parse(read_regular(File.join(@state, "prepared.json")))
    auth_sha = evidence.delete("auth_before_sha256")
    raise "Prepared credentials changed" unless Digest::SHA256.hexdigest(read_regular(isolated_credentials)) == auth_sha
    raise "Claude executable changed" unless Digest::SHA256.file(@binary).hexdigest == evidence.fetch("binary_sha256")
    raise "Filesystem isolation changed" unless evidence.fetch("filesystem_isolation") == filesystem.evidence.merge("preflight" => filesystem.verify!)
    %w[flags model effort environment].each { |key| raise "Prepared #{key} changed" unless evidence.fetch(key) == @spec.fetch(key) }
    argv = filesystem.command(*@spec.fetch("flags"), "--model", @spec.fetch("model"),
      "--effort", @spec.fetch("effort"), @spec.fetch("instruction"))
    started = Time.now
    child = Process.spawn(@env, "timeout", "--kill-after=30s", "#{@spec.fetch('timeout_seconds')}s", *argv,
      chdir: @workspace, in: File::NULL, out: $stdout, err: $stderr)
    _, status = Process.wait2(child)
    finished = Time.now
    # The private PID namespace is gone before the outer driver writes evidence.
    evidence.merge!("exit_status" => status.exitstatus, "term_signal" => status.termsig,
      "timeout_seconds" => @spec.fetch("timeout_seconds"), "generation_started_at" => started.utc.iso8601(6),
      "generation_finished_at" => finished.utc.iso8601(6))
    write(File.join(@workspace, EVIDENCE), evidence, perm: 0644)
    persist_refreshed_credentials!(auth_sha)
    # Only this newly allocated observation's private state is removed. No
    # credentials, caches or binaries are copied into published output folders.
    FileUtils.remove_entry_secure(@state)
    status.exitstatus || 128 + status.termsig
  end
end

if $PROGRAM_NAME == __FILE__
  action, spec = ARGV
  abort "usage: claude_observation.rb prepare|run SPEC" unless %w[prepare run].include?(action) && spec
  runner = ClaudeObservationRunner.new(spec)
  action == "prepare" ? runner.prepare : exit(runner.run)
end
