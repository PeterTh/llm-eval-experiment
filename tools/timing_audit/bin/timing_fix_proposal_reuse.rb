#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/timing_fix"

module TimingFixProposalReuse
  module_function

  # Reconciled selection may omit former candidates; it must not change a single
  # retained task, literal prompt, method, response, or accepted attempt.
  def run(source:, destination:, model:, effort:)
    source, destination = [source, destination].map { |root| File.realpath(root) }
    raise "Cannot reuse into the same proposal root" if source == destination
    manifests = [source, destination].map { |root| YAML.safe_load_file(File.join(root, "manifest.yaml")) }
    %w[prompt_template_sha256 proposal_schema_sha256 runner_sha256 static_evidence_sha256].each do |key|
      raise "Proposal method differs: #{key}" unless manifests[0].fetch("artifacts").fetch(key) == manifests[1].fetch("artifacts").fetch(key)
    end
    records = [source, destination].map { |root| TimingAudit.load_jsonl(File.join(root, "inventory.jsonl")).to_h { |row| [row.fetch("id"), row] } }
    ids = records[1].keys.sort
    raise "Empty or unknown proposal reuse selection" if ids.empty? || !(ids - records[0].keys).empty?
    runners = [source, destination].map { |root| TimingFix::ProposalRunner.new(output_dir: root, scope: "full", jobs: 1, model: model, effort: effort) }
    validator = TimingFix::ProposalValidator.new(records[1].values, manifests[1].fetch("generated_source").fetch("root"))
    receipt_path = File.join(destination, "reused-proposals.json")
    raise "Proposal reuse already recorded" if File.exist?(receipt_path)
    entries = ids.map do |id|
      raise "Proposal source or decision changed: #{id}" unless records[0].fetch(id) == records[1].fetch(id)
      prompts = runners.each_with_index.map { |runner, index| runner.send(:build_prompt, records[index].fetch(id)) }
      raise "Proposal prompt changed: #{id}" unless prompts[0] == prompts[1]
      response_path = File.join(source, "proposals", "#{id}.json")
      response = JSON.parse(File.read(response_path))
      validator.validate!(response, expected_id: id)
      raise "Cannot reuse a non-materializable proposal: #{id}" unless response.fetch("status") == "proposed"
      TimingFixEvidence.verify_response!(source, id, response, records[0].fetch(id))
      response_sha = TimingAudit.sha256_file(response_path)
      matching = Dir[File.join(source, "logs", id, "attempt-*/metadata.yaml")].any? do |path|
        metadata = YAML.safe_load_file(path)
        metadata["result_sha256"] == response_sha && metadata.values_at("model", "reasoning_effort", "static_only_verified", "exit_code", "timed_out") == [model, effort, true, 0, false] &&
          metadata["prompt_sha256"] == TimingAudit.sha256_bytes(prompts[0])
      end
      raise "No exact accepted proposal attempt: #{id}" unless matching
      paths = [response_path, *Dir[File.join(source, "logs", id, "**", "*")].select { |path| File.file?(path) }]
      files = paths.to_h do |path|
        raise "Symlink in proposal evidence" if File.symlink?(path)
        relative = path.delete_prefix(source + "/")
        target = File.join(destination, relative)
        sha = TimingAudit.sha256_file(path)
        raise "Conflicting destination evidence: #{relative}" if File.exist?(target) && TimingAudit.sha256_file(target) != sha
        [relative, sha]
      end
      { "program_id" => id, "source_digest" => records[0].fetch(id).fetch("source_digest"),
        "prompt_sha256" => TimingAudit.sha256_bytes(prompts[0]), "copied_files_sha256" => files }
    end
    entries.each do |entry|
      entry.fetch("copied_files_sha256").each_key { |relative| TimingAudit.atomic_write(File.join(destination, relative), File.binread(File.join(source, relative))) }
      id = entry.fetch("program_id")
      TimingFixEvidence.verify_response!(destination, id, JSON.parse(File.read(File.join(destination, "proposals", "#{id}.json"))), records[1].fetch(id))
    end
    receipt = { "created_at" => TimingAudit.utc_now, "source_root" => source,
      "source_manifest_sha256" => TimingAudit.sha256_file(File.join(source, "manifest.yaml")),
      "destination_manifest_sha256" => TimingAudit.sha256_file(File.join(destination, "manifest.yaml")),
      "model" => model, "effort" => effort, "records" => entries, "new_model_requests" => 0,
      "policy" => "Reuse only exact source, decision, literal prompt, schema, runner, response and verified source-only attempts. Omitted source candidates remain preserved at the parent root." }
    TimingAudit.atomic_write(receipt_path, JSON.pretty_generate(receipt) + "\n")
    TimingFix::ProposalVerifier.new(destination, "full").run
    puts "Reused #{ids.size} exact proposals without new model requests"
    receipt
  end
end

if $PROGRAM_NAME == __FILE__
  options = { model: "gpt-6.1-sol", effort: "high" }
  parser = OptionParser.new do |opts|
    opts.on("--source=PATH") { |value| options[:source] = value }
    opts.on("--destination=PATH") { |value| options[:destination] = value }
    opts.on("--model=MODEL") { |value| options[:model] = value }
    opts.on("--effort=EFFORT") { |value| options[:effort] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && options[:source] && options[:destination]
  TimingFixProposalReuse.run(**options)
end
