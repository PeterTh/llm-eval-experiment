#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
require "digest"
require "time"

# Candidate discovery only. A path mention, directory listing, failed command,
# or output echo is NOT an automatic finding. Adjudication uses selected tool
# input/output spans, anchored to line numbers and hashes of the originals.
module GenerationAccessAudit
  MARKERS = {
    "operator_home" => %r{/home/petert(?:/|\b)},
    "retained_results" => /llm_para_(?:experiments|exp_backup|local_evaluation|validation|benchmark)|llm-eval-local|llm-eval-generated/,
    "historical_scratch" => %r{/tmp/[^\s"'`<>;]*(?:validation|evaluation|benchmark|generated|release|regression|review|audit|FOLLOWUP)[^\s"'`<>;]*},
    "foreign_profile" => /(?:claude-(?:opus|sonnet|haiku|fable)|gpt-[0-9]|deepseek-[rv][0-9]|qwen-[0-9]|gemini-[0-9])[A-Za-z0-9._-]*_(?:omp|mpi|hybrid|cuda)_r[1-5]/,
    "published_results" => %r{github\.com/PeterTh/(?:llm-eval|llm_para)|peterth\.github\.io/llm-eval},
    "historical_batch" => %r{(?:/|\b)202[0-9]{5}-[0-9]{6}/},
    "other_test_home" => %r{/home/llmtest/(?:evals|\.[^/\s]+)(?:/|\b)},
    "cross_solution_search" => %r{(?:find|ls)\s+(?:-[A-Za-z0-9]+\s+)*(?:/(?:home|tmp)/?(?=[\s"';]|$)|\.\./\.\./)}
  }.freeze
  module_function

  def scan(root)
    paths = Dir[File.join(root, "*/output.txt")].sort
    raise "No transcripts found" if paths.empty?
    records = paths.map do |path|
      id = File.basename(File.dirname(path))
      matches, malformed = [], []
      File.foreach(path).with_index(1) do |line, number|
        begin
          event = JSON.parse(line)
        rescue JSON::ParserError
          malformed << number
          next
        end
        part = event["part"] || {}
        state = part["state"] || {}
        input = (state["input"] || {}).values.map(&:to_s).join("\n")
        output = state["output"].to_s
        # The active ID/batch is expected in build output and is not foreign.
        current_workspace = "/home/llmtest/evals/#{File.basename(root)}/#{id}"
        current = /#{Regexp.escape(current_workspace)}|#{Regexp.escape(id)}/
        searched = (input + "\n" + output).gsub(current, "CURRENT_OBSERVATION")
        markers = MARKERS.filter_map { |name, pattern| name if searched.match?(pattern) }
        next if markers.empty? || event["type"] != "tool_use"
        matches << { "line" => number, "tool" => part["tool"], "markers" => markers,
          "input_markers" => MARKERS.filter_map { |name, pattern| name if input.gsub(current, "CURRENT_OBSERVATION").match?(pattern) },
          "status" => state["status"], "exit_code" => state.dig("metadata", "exit"),
          "input" => state["input"], "output_bytes" => output.bytesize,
          "output_sha256" => Digest::SHA256.hexdigest(output),
          "output_excerpt" => output.lines.select { |s| MARKERS.values.any? { |p| s.gsub(current, "CURRENT_OBSERVATION").match?(p) } }.first(8).map { |s| s[0, 400].chomp } }
      end
      { "id" => id, "transcript_sha256" => Digest::SHA256.file(path).hexdigest,
        "malformed_lines" => malformed, "candidate_events" => matches }
    end
    { "schema_version" => 1, "generated_at" => Time.now.utc.iso8601,
      "scope" => File.expand_path(root), "scanner_sha256" => Digest::SHA256.file(__FILE__).hexdigest,
      "method" => "Deterministic full-file marker scan; targeted tool-event review. Candidates are not findings.",
      "markers" => MARKERS.transform_values(&:source), "transcripts_scanned" => paths.size,
      "candidate_observations" => records.count { |r| !r.fetch("candidate_events").empty? }, "observations" => records }
  end
end

if $PROGRAM_NAME == __FILE__
  root, output = ARGV
  abort "usage: audit_generation_access.rb BATCH OUTPUT_JSON" unless root && output
  raise "Refusing to overwrite audit" if File.exist?(output)
  report = GenerationAccessAudit.scan(root)
  File.write(output, JSON.pretty_generate(report) + "\n")
  puts JSON.pretty_generate(report.slice("scope", "transcripts_scanned", "candidate_observations"))
end
