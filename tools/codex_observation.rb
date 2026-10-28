#!/usr/bin/env ruby
# frozen_string_literal: true
require "fileutils"
require "json"
require "open3"
require "tempfile"
require "time"
require_relative "../lib/generation_filesystem"

# Trusted outer driver, matching the Claude/OpenCode filesystem boundary. The
# stock CLI keeps its prompt, tools and budget. Only fresh observation sessions
# are copied out, after the native process exits; exact accounting stays deferred
# until the preflight/campaign gate, never during another agent's tuning.
class CodexObservationRunner
  EVIDENCE = "codex-filesystem.txt"
  CREDENTIALS = "/home/llmtest/.codex/auth.json"
  CONFIG = "/home/llmtest/.codex/config.toml"
  SESSIONS = "/home/llmtest/.codex/sessions"

  def initialize(path)
    @spec = JSON.parse(File.read(path))
    @state, @workspace, @binary = @spec.values_at("state", "workspace", "binary")
    raise "Wrong observation ID" unless File.basename(@workspace) == @spec.fetch("id")
    @env = @spec.fetch("environment")
    raise "Unexpected Codex environment overrides" unless @env.empty?
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
    raise "Codex subscription authentication required" unless value["auth_mode"] == "chatgpt" && value["OPENAI_API_KEY"].to_s.empty?
    tokens = value.fetch("tokens")
    %w[id_token access_token refresh_token account_id].each do |key|
      raise "Missing subscription #{key}" unless tokens[key].is_a?(String) && !tokens[key].empty?
    end
    value
  end

  def self.isolated_config(raw, workspace:)
    # Carry over only the existing global model/effort/web-search settings. Old
    # project trust entries and UI state are not instructions and are not copied.
    # Fail closed if a new functional setting needs explicit compatibility review.
    sections = raw.lines.map(&:strip).select { |line| line.start_with?("[") }
    unless sections.all? { |line| line.match?(/\A\[projects\."[^"\n]+"\]\z/) || line.match?(/\A\[tui(?:\.[a-z_]+)?\]\z/) }
      raise "Unexpected Codex configuration section"
    end
    globals = raw.lines.take_while { |line| !line.strip.start_with?("[") }
      .map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
    keys = globals.map do |line|
      match = line.match(/\A(model|model_reasoning_effort|web_search)\s*=\s*"([a-zA-Z0-9.-]+)"\s*\z/)
      raise "Unexpected Codex global configuration" unless match
      [match[1], match[2]]
    end
    raise "Duplicate Codex global setting" unless keys.map(&:first).uniq.size == keys.size
    raise "Codex web search must remain disabled" unless keys.to_h["web_search"] == "disabled"
    raise "Unsafe trusted workspace" unless workspace.match?(%r{\A/home/llmtest/evals/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+\z})
    globals.join("\n") + "\n\n[projects.#{JSON.generate(workspace)}]\ntrust_level = \"trusted\"\n"
  end

  def isolated_credentials
    File.join(@state, "home/.codex/auth.json")
  end

  def prepare
    raise "Codex state already exists" if File.exist?(@state)
    %w[home/.codex tmp var-tmp].each { |name| FileUtils.mkdir_p(File.join(@state, name), mode: 0700) }
    probe = filesystem.verify!
    raw = read_regular(CREDENTIALS)
    self.class.validate_credentials!(raw)
    File.write(isolated_credentials, raw, perm: 0600)
    config = self.class.isolated_config(read_regular(CONFIG), workspace: @workspace)
    File.write(File.join(@state, "home/.codex/config.toml"), config, perm: 0600)
    out, err, status = Open3.capture3(@env, *filesystem.command("--version"))
    raise "Isolated Codex version check failed: #{err}" unless status.success?
    version = out.strip[/\Acodex-cli (\d+\.\d+\.\d+)\z/, 1]
    raise "Unexpected Codex version output" unless version
    write(File.join(@state, "prepared.json"), {
      "version" => version, "binary_sha256" => Digest::SHA256.file(@binary).hexdigest,
      "filesystem_isolation" => filesystem.evidence.merge("preflight" => probe),
      "flags" => @spec.fetch("flags"), "model" => @spec.fetch("model"), "effort" => @spec.fetch("effort"),
      "environment" => @env, "config_sha256" => Digest::SHA256.hexdigest(config),
      "auth_before_sha256" => Digest::SHA256.hexdigest(raw)
    })
    puts "Codex isolated filesystem verified (#{version}; no model request)."
  end

  def persist_refreshed_credentials!(before_sha)
    raw = read_regular(isolated_credentials)
    self.class.validate_credentials!(raw)
    return if Digest::SHA256.hexdigest(raw) == before_sha
    raise "Host credentials changed concurrently" unless Digest::SHA256.hexdigest(read_regular(CREDENTIALS)) == before_sha
    Tempfile.create([".auth-", ".json"], File.dirname(CREDENTIALS), mode: 0600) do |file|
      file.write(raw)
      file.flush
      file.fsync
      File.rename(file.path, CREDENTIALS)
    end
  end

  def archive_sessions!(destination: SESSIONS)
    source = File.join(@state, "home/.codex/sessions")
    return [] unless File.exist?(source)
    raise "Linked session root" unless File.directory?(source) && File.realpath(source) == source
    FileUtils.mkdir_p(destination, mode: 0700)
    raise "Linked archive root" unless File.directory?(destination) && File.realpath(destination) == destination
    # Inspect only this fresh state. Never glob or parse earlier host sessions.
    paths = Dir.glob(File.join(source, "**", "*"), File::FNM_DOTMATCH).reject { |path| %w[. ..].include?(File.basename(path)) }
    raise "Linked session entry" if paths.any? { |path| File.symlink?(path) || File.realpath(path) != path }
    paths.select { |path| File.file?(path) }.sort.map do |path|
      relative = path.delete_prefix(source + "/")
      unless relative.match?(%r{\A\d{4}/\d{2}/\d{2}/rollout-[a-zA-Z0-9_.:-]+-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\.jsonl\z})
        raise "Unexpected fresh Codex session path"
      end
      directory = destination
      relative.split("/")[0...-1].each do |part|
        directory = File.join(directory, part)
        Dir.mkdir(directory, 0700) unless File.exist?(directory)
        raise "Linked archive directory" unless File.directory?(directory) && File.realpath(directory) == directory
      end
      target = File.join(destination, relative)
      sha = Digest::SHA256.file(path).hexdigest
      if File.exist?(target) || File.symlink?(target)
        raise "Conflicting archived session" unless File.file?(target) && File.realpath(target) == target && Digest::SHA256.file(target).hexdigest == sha
      else
        Tempfile.create([".rollout-", ".tmp"], directory, mode: 0600) do |file|
          File.open(path, "rb") { |input| IO.copy_stream(input, file) }
          file.flush
          file.fsync
          raise "Session changed while archiving" unless Digest::SHA256.file(file.path).hexdigest == sha
          File.link(file.path, target) # Atomic publication; refuses an existing target.
        end
      end
      { "path" => relative, "sha256" => sha, "bytes" => File.size(path) }
    end
  end

  def run
    evidence = JSON.parse(read_regular(File.join(@state, "prepared.json")))
    auth_sha = evidence.delete("auth_before_sha256")
    raise "Prepared credentials changed" unless Digest::SHA256.hexdigest(read_regular(isolated_credentials)) == auth_sha
    raise "Prepared configuration changed" unless Digest::SHA256.file(File.join(@state, "home/.codex/config.toml")).hexdigest == evidence.fetch("config_sha256")
    raise "Codex executable changed" unless Digest::SHA256.file(@binary).hexdigest == evidence.fetch("binary_sha256")
    raise "Filesystem isolation changed" unless evidence.fetch("filesystem_isolation") == filesystem.evidence.merge("preflight" => filesystem.verify!)
    %w[flags model effort environment].each { |key| raise "Prepared #{key} changed" unless evidence.fetch(key) == @spec.fetch(key) }
    argv = filesystem.command("--model", @spec.fetch("model"), "-c", "model_reasoning_effort=#{@spec.fetch('effort').to_json}",
      *@spec.fetch("flags"), "exec", @spec.fetch("instruction"))
    started = Time.now
    child = Process.spawn(@env, "timeout", "--kill-after=30s", "#{@spec.fetch('timeout_seconds')}s", *argv,
      chdir: @workspace, in: File::NULL, out: $stdout, err: $stderr)
    _, status = Process.wait2(child)
    finished = Time.now
    # The private PID namespace is gone before writing trusted public evidence.
    evidence.merge!("exit_status" => status.exitstatus, "term_signal" => status.termsig,
      "timeout_seconds" => @spec.fetch("timeout_seconds"), "generation_started_at" => started.utc.iso8601(6),
      "generation_finished_at" => finished.utc.iso8601(6), "session_archive_complete" => false)
    path = File.join(@workspace, EVIDENCE)
    write(path, evidence, perm: 0644)
    evidence["archived_sessions"] = archive_sessions!
    persist_refreshed_credentials!(auth_sha)
    evidence["session_archive_complete"] = true
    write(path, evidence, perm: 0644)
    # Only the validated, freshly allocated state is removed. If collection
    # failed above, retain it for repair without another model invocation.
    FileUtils.remove_entry_secure(@state)
    status.exitstatus || 128 + status.termsig
  end
end

if $PROGRAM_NAME == __FILE__
  action, spec = ARGV
  abort "usage: codex_observation.rb prepare|run SPEC" unless %w[prepare run].include?(action) && spec
  runner = CodexObservationRunner.new(spec)
  action == "prepare" ? runner.prepare : exit(runner.run)
end
