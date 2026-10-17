#!/usr/bin/env ruby
# frozen_string_literal: true
require "fileutils"
require "open3"
require "net/http"
require "securerandom"
require "time"
require "timeout"
require_relative "../lib/opencode_harness"

# Runs as llmtest. A fresh loopback-only stock OpenCode server plus `run --attach`
# allows a read-only native event subscriber to retain retry waits (which `run
# --format json` omits). No plugin, prompt modification, or replacement agent loop.
class OpenCodeObservationRunner
  def initialize(spec_path)
    @spec = JSON.parse(File.read(spec_path))
    @state = @spec.fetch("state")
    @workspace = @spec.fetch("workspace")
    @binary = @spec.fetch("binary")
    @env = OpenCodeHarness.environment(@state)
    @expected = OpenCodeHarness.config(model: @spec.fetch("model"), effort: @spec.fetch("effort"))
    raise "OpenCode executable changed" unless Digest::SHA256.file(@binary).hexdigest == OpenCodeHarness::BINARY_SHA256
  end

  def write(path, value)
    File.write(path, JSON.pretty_generate(value) + "\n")
  end

  def capture(*args)
    output, error, status = Open3.capture3(@env, @binary, *args, chdir: @workspace)
    raise "OpenCode #{args.first} failed: #{error}" unless status.success?
    output
  end

  def prepare(authenticate: true)
    raise "OpenCode state already exists" if File.exist?(@state)
    FileUtils.mkdir_p(@state, mode: 0700)
    %w[data/opencode config/opencode cache state home managed tmp].each { |path| FileUtils.mkdir_p(File.join(@state, path), mode: 0700) }
    if authenticate
      auth = OpenCodeHarness.credential(@spec.fetch("auth_file"))
      File.write(File.join(@state, "data/opencode/auth.json"), JSON.generate(auth), mode: "w", perm: 0600)
    end
    write(File.join(@state, "config/opencode/opencode.json"), @expected)
    version = capture("--version").strip
    raise "OpenCode version differs" unless version == OpenCodeHarness::VERSION
    resolved = JSON.parse(capture("debug", "config"))
    agent = JSON.parse(capture("debug", "agent", "build"))
    OpenCodeHarness.verify_config!(resolved, @expected)
    enabled = OpenCodeHarness.verify_agent!(agent)
    write(File.join(@state, "prepared.json"), {
      "version" => version, "binary_sha256" => OpenCodeHarness::BINARY_SHA256,
      "auth_type" => authenticate ? "openai-subscription-oauth" : "none-inspection-only", "model" => @spec.fetch("model"),
      "reasoning_effort" => @spec.fetch("effort"), "flags" => OpenCodeHarness::FLAGS,
      "requested_config" => @expected, "resolved_config" => resolved,
      "build_agent" => agent, "enabled_tools" => enabled,
      "catalog" => "bundled in the pinned executable; network refresh disabled",
      "title_policy" => "explicit observation ID, no title-generation request",
      "transport" => "stock serve on authenticated loopback + stock run --attach; read-only event capture" })
    puts "OpenCode isolated configuration verified (#{version}; #{enabled.join(', ')})."
  end

  def inspect
    prepare(authenticate: false)
  end

  def http
    client = Net::HTTP.new("127.0.0.1", @port, nil)
    client.open_timeout = 5
    client.read_timeout = 30
    client
  end

  def request(path, method: Net::HTTP::Get)
    uri = URI(path)
    query = URI.decode_www_form(uri.query.to_s)
    uri.query = URI.encode_www_form(query + [["directory", @workspace]])
    message = method.new(uri.to_s)
    message.basic_auth("opencode", @password)
    message
  end

  def get(path, method: Net::HTTP::Get)
    response = http.request(request(path, method: method))
    raise "OpenCode local API #{path}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  end

  def start_server
    @password = SecureRandom.hex(32)
    @env["OPENCODE_SERVER_PASSWORD"] = @password
    @server_log = File.open(File.join(@state, "server.log"), "w")
    @server_pid = Process.spawn(@env, @binary, "serve", "--hostname", "127.0.0.1", "--port", "0",
      chdir: @workspace, out: @server_log, err: @server_log)
    Timeout.timeout(30) do
      loop do
        match = File.read(@server_log.path).match(/server listening on http:\/\/127\.0\.0\.1:(\d+)/)
        if match
          @port = match[1].to_i
          break if get("/global/health")["healthy"]
        end
        raise "OpenCode server exited" if Process.waitpid(@server_pid, Process::WNOHANG)
        sleep 0.1
      end
    end
  end

  def start_events
    ready = Queue.new
    @event_error = nil
    @events = File.open(File.join(@state, "opencode-events.txt"), "w")
    @events.sync = true
    @event_thread = Thread.new do
      http.start do |client|
        client.request(request("/event")) do |response|
          raise "Native event stream refused: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
          ready << true
          buffer = +""
          response.read_body do |chunk|
            buffer << chunk
            while (separator = buffer.match(/\r?\n\r?\n/))
              frame = buffer.slice!(0, separator.end(0))
              data = frame.lines.filter_map { |line| line.delete_prefix("data:").strip if line.start_with?("data:") }.join("\n")
              next if data.empty?
              event = JSON.parse(data)
              accounting = event["type"] == "message.part.updated" && event.dig("properties", "part", "type") == "step-finish"
              next unless accounting || %w[session.created session.status session.error].include?(event["type"])
              @events.puts(JSON.generate({ "received_at_ms" => (Time.now.to_f * 1000).round, "event" => event }))
            end
          end
        end
      end
      raise "Native event stream ended early" unless @closing
    rescue StandardError => e
      @event_error = "#{e.class}: #{e.message}" unless @closing
      ready << false
    end
    raise "Native event stream did not start" unless Timeout.timeout(10) { ready.pop }
  end

  def run
    evidence = JSON.parse(File.read(File.join(@state, "prepared.json")))
    raise "Subscription authentication was not prepared" unless evidence.fetch("auth_type") == "openai-subscription-oauth"
    OpenCodeHarness.credential(File.join(@state, "data/opencode/auth.json"))
    start_server
    actual = get("/config")
    OpenCodeHarness.verify_config!(actual, @expected)
    agent = get("/agent").find { |entry| entry["name"] == "build" }
    raise "Missing native build agent" unless agent
    registry = get("/experimental/tool?provider=openai&model=gpt-6.1-sol").map { |entry| entry.fetch("id") }
    agent["tools"] = registry.to_h do |tool|
      permission = %w[edit write apply_patch].include?(tool) ? "edit" : tool
      rule = agent.fetch("permission").reverse.find { |item| [permission, "*"].include?(item["permission"]) }
      [tool, !(rule && rule["pattern"] == "*" && rule["action"] == "deny")]
    end
    enabled = OpenCodeHarness.verify_agent!(agent)
    raise "Server tools differ from isolated preflight" unless enabled == evidence.fetch("enabled_tools")
    providers = get("/config/providers").fetch("providers")
    raise "Unexpected enabled provider" unless providers.map { |provider| provider.fetch("id") } == ["openai"]
    models = providers.first.fetch("models")
    raise "Additional or missing models" unless models.keys == ["gpt-6.1-sol"]
    model = models.fetch("gpt-6.1-sol")
    raise "Medium reasoning is unavailable" unless model.dig("variants", "medium", "reasoningEffort") == "medium"
    raise "Medium reasoning default differs" unless model.dig("options", "reasoningEffort") == "medium"
    raise "Unexpected MCP servers" unless get("/mcp").empty?
    raise "Session isolation failed" unless get("/session").empty?
    evidence.merge!("resolved_config" => actual, "resolved_model" => model, "build_agent" => agent)
    write(File.join(@state, "opencode-config.txt"), evidence)
    start_events
    argv = [@binary, "run", "--attach", "http://127.0.0.1:#{@port}", "--dir", @workspace,
      "--format", "json", "--thinking", "--auto", "--agent", "build", "--model", @spec.fetch("model"),
      "--variant", @spec.fetch("effort"), "--title", @spec.fetch("id"), @spec.fetch("instruction")]
    started = Time.now
    child = Process.spawn(@env, "timeout", "--kill-after=30s", "#{@spec.fetch('timeout_seconds')}s", *argv,
      chdir: @workspace, in: File::NULL, out: $stdout, err: $stderr)
    _, status = Process.wait2(child)
    finished = Time.now
    receipt = { "exit_status" => status.exitstatus, "term_signal" => status.termsig,
      "timeout_seconds" => @spec.fetch("timeout_seconds"), "generation_started_at" => started.utc.iso8601(6),
      "generation_finished_at" => finished.utc.iso8601(6), "cli_wall_seconds" => finished - started }
    # Keep this receipt even if later evidence collection fails. It is not a
    # success marker: admission also verifies session completion and all metadata.
    write(File.join(@workspace, "opencode-process.txt"), receipt)
    sessions = get("/session")
    raise "Expected one isolated session" unless sessions.size == 1 && !sessions.first["parentID"]
    sid = sessions.first.fetch("id")
    if [124, 137].include?(status.exitstatus)
      get("/session/#{sid}/abort", method: Net::HTTP::Post)
    end
    messages = get("/session/#{sid}/message")
    write(File.join(@workspace, "opencode-session.txt"), OpenCodeHarness.session_projection(sessions.first, messages))
    # An SSE event can be queued just after the HTTP prompt response completes.
    Timeout.timeout(5) do
      loop do
        raise @event_error if @event_error
        idle = File.foreach(@events.path).any? do |line|
          item = JSON.parse(line).fetch("event")
          item.dig("properties", "sessionID") == sid && item.dig("properties", "status", "type") == "idle"
        end
        break if idle
        sleep 0.05
      end
    end
    @collected = true
    status.exitstatus || 128 + status.termsig
  ensure
    @closing = true
    @event_thread&.kill
    @event_thread&.join
    @events&.close
    if @server_pid
      Process.kill("TERM", @server_pid) rescue Errno::ESRCH
      begin
        Timeout.timeout(2) { Process.wait(@server_pid) }
      rescue Timeout::Error
        Process.kill("KILL", @server_pid) rescue Errno::ESRCH
        Process.wait(@server_pid) rescue Errno::ECHILD
      rescue Errno::ECHILD
        nil
      end
    end
    @server_log&.close
    # Publish audit bookkeeping only after the agent/server have stopped, just
    # like instruction/timing records in the native harnesses. During generation
    # the workspace contains only the sequential input and ordinary output log.
    %w[opencode-config.txt opencode-events.txt].each do |name|
      source = File.join(@state, name)
      FileUtils.cp(source, File.join(@workspace, name)) if File.file?(source)
    end
    # Refreshes remain private, outside every generated-source/evidence folder.
    auth_path = File.join(@state, "data/opencode/auth.json")
    if File.file?(auth_path)
      auth = OpenCodeHarness.credential(auth_path)
      File.write(@spec.fetch("auth_file"), JSON.generate(auth), mode: "w", perm: 0600)
    end
    # All retained metadata is now in the observation, credentials are back in
    # their private store, and the server is stopped. Do not archive a database
    # and node_modules again for every observation. Failed collections stay put.
    if @collected && @state.match?(%r{\A/tmp/opencode-observation-[^/]+/private\z}) && !File.symlink?(@state)
      FileUtils.remove_entry_secure(@state)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  $stderr.sync = true
  command, spec = ARGV
  abort "usage: opencode_observation.rb inspect|prepare|run SPEC" unless %w[inspect prepare run].include?(command) && spec
  value = OpenCodeObservationRunner.new(spec).public_send(command)
  exit(value) if command == "run"
end
