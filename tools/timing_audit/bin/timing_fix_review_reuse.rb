#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/timing_fix_review"

module TimingFixReviewReuse
  module_function

  def run(source:, destination:, model:, effort:)
    source = File.realpath(source)
    destination = File.realpath(destination)
    raise "Cannot reuse into the same review" if source == destination
    manifests = [source, destination].map { |root| YAML.safe_load_file(File.join(root, "manifest.yaml"), aliases: false) }
    %w[prompt_template_sha256 result_schema_sha256 runner_sha256 static_evidence_sha256].each do |key|
      raise "Review method differs: #{key}" unless manifests[0].fetch("artifacts").fetch(key) == manifests[1].fetch("artifacts").fetch(key)
    end
    runners = [source, destination].map do |root|
      TimingFixReview::Runner.new(output_dir: root, scope: "full", jobs: 1, model: model, effort: effort)
    end
    records = [source, destination].map do |root|
      TimingAudit.load_jsonl(File.join(root, "inventory.jsonl")).to_h { |record| [record.fetch("id"), record] }
    end
    validator = TimingFixReview::ResultValidator.new(records[1].values)
    ids = records[0].keys.sort
    raise "Pilot IDs missing from destination" unless (ids - records[1].keys).empty?
    index_path = File.join(destination, "reused-reviews.json")
    raise "Reuse index already exists" if File.exist?(index_path)
    entries = ids.map do |id|
      raise "Review source/proposal metadata differs for #{id}" unless records[0].fetch(id) == records[1].fetch(id)
      prompts = runners.each_with_index.map { |runner, i| runner.send(:build_prompt, records[i].fetch(id)) }
      raise "Review prompt differs for #{id}" unless prompts[0] == prompts[1]
      source_result = File.join(source, "results", "#{id}.json")
      response = JSON.parse(File.read(source_result))
      validator.validate!(response, expected_id: id)
      TimingFixEvidence.verify_response!(source, id, response, records[0].fetch(id))
      digest = TimingAudit.sha256_bytes(JSON.pretty_generate(response) + "\n")
      attempts = Dir[File.join(source, "logs", id, "attempt-*", "metadata.yaml")].select do |path|
        metadata = YAML.safe_load_file(path, aliases: false)
        metadata["result_sha256"] == digest && metadata["model"] == model &&
          metadata["reasoning_effort"] == effort && metadata["exit_code"] == 0 &&
          !metadata["timed_out"] && metadata["static_only_verified"] == true &&
          metadata["prompt_sha256"] == TimingAudit.sha256_bytes(prompts[0])
      end
      raise "No matching model/prompt attempt for #{id}" if attempts.empty?
      paths = [source_result, *Dir[File.join(source, "logs", id, "**", "*")].select { |p| File.file?(p) }]
      files = paths.map do |path|
        raise "Symlink in review evidence" if File.symlink?(path)
        relative = path.delete_prefix(source + "/")
        target = File.join(destination, relative)
        sha = TimingAudit.sha256_file(path)
        raise "Conflicting existing evidence #{target}" if File.exist?(target) && TimingAudit.sha256_file(target) != sha
        [path, relative, sha]
      end
      { "program_id" => id, "files" => files }
    end
    # Validate all input evidence before any copy. Identical files make a partial
    # interrupted copy safely resumable without overwriting distinct attempts.
    entries.each do |entry|
      entry.fetch("files").each do |path, relative, _sha|
        TimingAudit.atomic_write(File.join(destination, relative), File.binread(path))
      end
      id = entry.fetch("program_id")
      response = JSON.parse(File.read(File.join(destination, "results", "#{id}.json")))
      TimingFixEvidence.verify_response!(destination, id, response, records[1].fetch(id))
    end
    TimingAudit.atomic_write(index_path, JSON.pretty_generate({
      "created_at" => TimingAudit.utc_now, "source_root" => source,
      "source_manifest_sha256" => TimingAudit.sha256_file(File.join(source, "manifest.yaml")),
      "destination_manifest_sha256" => TimingAudit.sha256_file(File.join(destination, "manifest.yaml")),
      "model" => model, "effort" => effort,
      "policy" => "Reuse only identical source/proposal, literal prompt, schema, runner and verified static response evidence",
      "records" => entries.map { |entry| { "program_id" => entry.fetch("program_id"),
        "copied_files_sha256" => entry.fetch("files").to_h { |_path, relative, sha| [relative, sha] } } }
    }) + "\n")
    puts "Reused #{entries.size} exact, independently verified pilot reviews"
  end
end

if $PROGRAM_NAME == __FILE__
  options = { model: "gpt-5.6-luna", effort: "high" }
  parser = OptionParser.new do |opts|
    opts.on("--source=PATH") { |v| options[:source] = v }
    opts.on("--destination=PATH") { |v| options[:destination] = v }
    opts.on("--model=MODEL") { |v| options[:model] = v }
    opts.on("--effort=EFFORT") { |v| options[:effort] = v }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && options[:source] && options[:destination]
  TimingFixReviewReuse.run(**options)
end
