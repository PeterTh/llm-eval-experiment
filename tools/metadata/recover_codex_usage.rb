#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "open3"
require "shellwords"
require "fileutils"
require "tempfile"
require_relative "../../lib/codex_usage"

options = { sessions: "/home/llmtest/.codex/sessions" }
OptionParser.new do |parser|
  parser.on("--batch=PATH") { |v| options[:batch] = File.expand_path(v) }
  parser.on("--sessions=PATH") { |v| options[:sessions] = File.expand_path(v) }
  parser.on("--session-user=USER") { |v| options[:user] = v }
  parser.on("--output=PATH") { |v| options[:output] = File.expand_path(v) }
  parser.on("--expected=COUNT", Integer) { |v| options[:expected] = v }
  parser.on("--read-sessions") { options[:reader] = true }
end.parse!
abort "Unexpected arguments" unless ARGV.empty?

if options[:reader]
  requests = JSON.parse(STDIN.read)
  paths = Dir.glob(File.join(options[:sessions], "**", "*.jsonl")).group_by do |path|
    File.basename(path)[/([0-9a-f]{8}-[0-9a-f-]{27})\.jsonl\z/, 1]
  end
  requests.each do |request|
    matches = paths.fetch(request.fetch("session_id"), [])
    raise CodexUsage::Invalid, "missing/ambiguous session #{request.fetch('session_id')}" unless matches.size == 1
    puts JSON.generate(CodexUsage.recover(request, matches.first, sessions_root: options[:sessions]))
  end
  exit
end

batch = options.fetch(:batch)
output = options.fetch(:output)
ids = Dir.glob(File.join(batch, "*", "timing.txt")).map { |p| File.basename(File.dirname(p)) }.sort
raise "Empty batch" if ids.empty?
raise "Unexpected run count #{ids.size}" if options[:expected] && ids.size != options[:expected]
requests = ids.map do |id|
  CodexUsage.transcript_request(batch: File.basename(batch), id: id, path: File.join(batch, id, "output.txt"))
end
raise "Reused session ID" unless requests.map { |r| r.fetch("session_id") }.uniq.size == requests.size
reader = ["ruby", File.expand_path(__FILE__), "--read-sessions", "--sessions=#{options[:sessions]}"]
command = options[:user] ? ["su", "-", options[:user], "--shell=/bin/bash", "-c", Shellwords.join(reader)] : reader
stdout, stderr, status = Open3.capture3(*command, stdin_data: JSON.generate(requests))
raise "Session recovery failed: #{stderr}" unless status.success?
records = stdout.lines.map { |line| CodexUsage.validate_record!(JSON.parse(line)) }
raise "Recovered IDs differ" unless records.map { |r| r.fetch("run_id") } == ids
records.each do |record|
  CodexUsage.verify_transcript!(record, id: record.fetch("run_id"), batch: File.basename(batch),
                               path: File.join(batch, record.fetch("run_id"), "output.txt"))
end
content = records.map { |r| JSON.generate(r) + "\n" }.join
# Never replace different evidence implicitly, and never leave a partial export.
if File.exist?(output)
  raise "Refusing to overwrite different evidence: #{output}" unless File.binread(output) == content
else
  FileUtils.mkdir_p(File.dirname(output))
  Tempfile.create([".codex-usage-", ".jsonl"], File.dirname(output)) do |file|
    file.write(content)
    file.flush
    file.fsync
    file.chmod(0o444)
    File.link(file.path, output) # Atomic publication, fails if the target appeared meanwhile.
  end
end
puts JSON.generate(records: records.size, output: output, bytes: content.bytesize,
                   sha256: Digest::SHA256.hexdigest(content))
