# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "yaml"
require_relative "timing_audit"

module TimingFixFinalize
  SCHEMA_VERSION = 1

  module_function

  def run(proposal_root:, review_root:, adjudication_root:, source_root:, corrected_commit:, output_dir:)
    proposal_root = File.realpath(proposal_root)
    review_root = File.realpath(review_root)
    adjudication_root = File.realpath(adjudication_root)
    source_root = File.realpath(source_root)
    output_dir = File.expand_path(output_dir)
    raise "Output already exists: #{output_dir}" if File.exist?(output_dir)

    proposal_manifest_path = File.join(proposal_root, "manifest.yaml")
    review_manifest_path = File.join(review_root, "manifest.yaml")
    adjudication_manifest_path = File.join(adjudication_root, "manifest.yaml")
    proposal_manifest = load_yaml(proposal_manifest_path)
    review_manifest = load_yaml(review_manifest_path)
    adjudication_manifest = load_yaml(adjudication_manifest_path)
    original_commit = proposal_manifest.fetch("generated_source").fetch("commit")
    verify_evidence_chain!(proposal_root, proposal_manifest_path, review_manifest,
                           review_manifest_path, adjudication_manifest)
    verify_repository!(source_root, corrected_commit)
    repository_url = repository_https_url(source_root)

    proposal_records = records_by_id(File.join(proposal_root, "inventory.jsonl"), "id")
    review_records = records_by_id(File.join(review_root, "inventory.jsonl"), "id")
    review_summaries = records_by_id(File.join(review_root, "summary-full.jsonl"), "program_id")
    adjudication_summaries = records_by_id(
      File.join(adjudication_root, "summary-full.jsonl"), "program_id"
    )
    ids = proposal_records.keys.sort
    raise "Proposal and review inventories differ" unless ids == review_records.keys.sort
    raise "Review summary does not cover the correction inventory" unless ids == review_summaries.keys.sort

    corrections = ids.map do |id|
      build_record(
        id: id,
        proposal_root: proposal_root,
        review_root: review_root,
        adjudication_root: adjudication_root,
        source_root: source_root,
        original_commit: original_commit,
        corrected_commit: corrected_commit,
        repository_url: repository_url,
        proposal_record: proposal_records.fetch(id),
        review_record: review_records.fetch(id),
        review_summary: review_summaries.fetch(id),
        adjudication_summary: adjudication_summaries[id]
      )
    end

    expected_paths = corrections.flat_map { |record| record.fetch("changed_paths") }.uniq.sort
    actual_paths = git_capture(source_root, "diff", "--name-only", original_commit, corrected_commit, "--")
                   .lines(chomp: true).sort
    unless actual_paths == expected_paths
      missing = expected_paths - actual_paths
      extra = actual_paths - expected_paths
      raise "Corrected commit path set differs from proposals (missing=#{missing.inspect}, extra=#{extra.inspect})"
    end

    FileUtils.mkdir_p(output_dir)
    corrections_path = File.join(output_dir, "corrections.jsonl")
    ids_path = File.join(output_dir, "correction-ids.txt")
    TimingAudit.atomic_write(corrections_path, TimingAudit.dump_jsonl(corrections))
    TimingAudit.atomic_write(ids_path, ids.join("\n") + "\n")
    manifest = {
      "schema_version" => SCHEMA_VERSION,
      "created_at" => TimingAudit.utc_now,
      "contract" => "timing-only corrections for maximum completed per-rank duration or a semantically equivalent global makespan",
      "record_count" => corrections.size,
      "all_final_verdicts" => "accept",
      "original_source" => { "root" => source_root, "commit" => original_commit, "repository_url" => repository_url },
      "corrected_source" => { "root" => source_root, "commit" => corrected_commit, "repository_url" => repository_url },
      "corrected_commit_changed_paths" => actual_paths.size,
      "materialized_patch_sha256" => load_yaml(
        File.join(proposal_root, "materialized", "summary-full.yaml")
      ).fetch("patch_sha256"),
      "compile_validation" => load_yaml(
        File.join(proposal_root, "materialized", "summary-full.yaml")
      ).slice("records", "compiled", "compile_successes", "compile_failures"),
      "evidence" => {
        "proposal_manifest_sha256" => TimingAudit.sha256_file(proposal_manifest_path),
        "proposal_inventory_sha256" => TimingAudit.sha256_file(File.join(proposal_root, "inventory.jsonl")),
        "proposal_summary_sha256" => TimingAudit.sha256_file(File.join(proposal_root, "summary-full.jsonl")),
        "postfix_review_manifest_sha256" => TimingAudit.sha256_file(review_manifest_path),
        "postfix_review_inventory_sha256" => TimingAudit.sha256_file(File.join(review_root, "inventory.jsonl")),
        "postfix_review_summary_sha256" => TimingAudit.sha256_file(File.join(review_root, "summary-full.jsonl")),
        "adjudication_manifest_sha256" => TimingAudit.sha256_file(adjudication_manifest_path),
        "adjudication_summary_sha256" => TimingAudit.sha256_file(File.join(adjudication_root, "summary-full.jsonl"))
      },
      "artifacts" => {
        "corrections_jsonl_sha256" => TimingAudit.sha256_file(corrections_path),
        "correction_ids_sha256" => TimingAudit.sha256_file(ids_path)
      }
    }
    TimingAudit.atomic_write(File.join(output_dir, "manifest.yaml"), YAML.dump(manifest))
    puts "Finalized #{corrections.size} accepted timing-only corrections at #{corrected_commit}"
    manifest
  rescue Exception
    if defined?(output_dir) && File.directory?(output_dir) &&
       !File.exist?(File.join(output_dir, "manifest.yaml"))
      FileUtils.remove_entry_secure(output_dir)
    end
    raise
  end

  def build_record(id:, proposal_root:, review_root:, adjudication_root:, source_root:,
                   original_commit:, corrected_commit:, repository_url:, proposal_record:, review_record:,
                   review_summary:, adjudication_summary:)
    raise "Review inventory identity mismatch for #{id}" unless review_record.fetch("id") == id
    proposal_path = File.join(proposal_root, "proposals", "#{id}.json")
    review_path = File.join(review_root, "results", "#{id}.json")
    proposal = JSON.parse(File.read(proposal_path))
    review = JSON.parse(File.read(review_path))
    raise "Proposal is not materializable for #{id}" unless proposal.fetch("status") == "proposed"
    raise "Proposal identity mismatch for #{id}" unless proposal.fetch("program_id") == id
    raise "Review result identity mismatch for #{id}" unless review.fetch("program_id") == id
    raise "Review summary/result mismatch for #{id}" unless review_summary.fetch("verdict") == review.fetch("verdict")

    adjudication = nil
    decision_basis = "independent_postfix_review"
    if review.fetch("verdict") != "accept"
      raise "Missing adjudication for disputed correction #{id}" unless adjudication_summary
      adjudication_path = File.join(adjudication_root, "results", "#{id}.json")
      adjudication = JSON.parse(File.read(adjudication_path))
      unless adjudication.fetch("program_id") == id && adjudication.fetch("final_verdict") == "accept" &&
             adjudication_summary.fetch("final_verdict") == "accept"
        raise "Correction #{id} did not receive an accepting adjudication"
      end
      decision_basis = "postfix_adjudication"
    end
    raise "Unaccepted correction #{id}" unless review.fetch("verdict") == "accept" || adjudication

    source_prefix = proposal_record.fetch("source_prefix")
    changed_paths = proposal.fetch("edits").map do |edit|
      path = edit.fetch("path")
      unless review_record.fetch("corrected_source_files").any? { |file| file.fetch("path") == path }
        raise "Proposal edits an untracked dossier path for #{id}: #{path}"
      end
      File.join(source_prefix, path)
    end.uniq.sort
    raise "Correction has no changed paths for #{id}" if changed_paths.empty?

    corrected_digest = verify_corrected_source!(source_root, source_prefix, review_record)
    unless corrected_digest == review_record.fetch("corrected_source_digest") &&
           corrected_digest == review_summary.fetch("corrected_source_digest")
      raise "Corrected source digest mismatch for #{id}"
    end
    original_tree = git_capture(source_root, "rev-parse", "#{original_commit}:#{source_prefix}").strip
    unless original_tree == proposal_record.fetch("source_tree_oid")
      raise "Original source tree mismatch for #{id}"
    end
    corrected_tree = git_capture(source_root, "rev-parse", "#{corrected_commit}:#{source_prefix}").strip

    result = {
      "schema_version" => SCHEMA_VERSION,
      "program_id" => id,
      "benchmark" => proposal_record.fetch("benchmark"),
      "model" => proposal_record.fetch("model"),
      "par_type" => proposal_record.fetch("par_type"),
      "run" => proposal_record.fetch("run"),
      "source_batch" => proposal_record.fetch("source_batch"),
      "source_prefix" => source_prefix,
      "timing_fixed" => true,
      "original_source_url" => "#{repository_url}/tree/#{original_commit}/#{source_prefix}",
      "corrected_source_url" => "#{repository_url}/tree/#{corrected_commit}/#{source_prefix}",
      "original_issue_categories" => proposal_record.fetch("final_decision").fetch("final_issue_categories"),
      "changed_paths" => changed_paths,
      "original_source" => {
        "commit" => original_commit,
        "tree_oid" => original_tree,
        "digest" => proposal_record.fetch("source_digest")
      },
      "corrected_source" => {
        "commit" => corrected_commit,
        "tree_oid" => corrected_tree,
        "digest" => corrected_digest
      },
      "proposal" => {
        "sha256" => TimingAudit.sha256_file(proposal_path),
        "summary" => proposal.fetch("summary")
      },
      "postfix_review" => {
        "verdict" => review.fetch("verdict"),
        "sha256" => TimingAudit.sha256_file(review_path)
      },
      "final_verdict" => "accept",
      "decision_basis" => decision_basis
    }
    if adjudication
      result["adjudication"] = {
        "verdict" => adjudication.fetch("final_verdict"),
        "sha256" => TimingAudit.sha256_file(File.join(adjudication_root, "results", "#{id}.json"))
      }
    end
    result
  end

  def verify_corrected_source!(source_root, source_prefix, record)
    aggregate = Digest::SHA256.new
    record.fetch("corrected_source_files").each do |file|
      relative = file.fetch("path")
      path = File.join(source_root, source_prefix, relative)
      real = File.realpath(path)
      raise "Corrected source escapes repository: #{path}" unless real.start_with?("#{source_root}/")
      bytes = File.binread(real)
      raise "Corrected file hash mismatch: #{path}" unless TimingAudit.sha256_bytes(bytes) == file.fetch("sha256")
      aggregate << relative << "\0" << bytes << "\0"
    end
    aggregate.hexdigest
  end

  def verify_repository!(source_root, corrected_commit)
    raise "Corrected commit must be a full Git object ID" unless corrected_commit.match?(/\A[0-9a-f]{40}\z/)
    head = git_capture(source_root, "rev-parse", "HEAD").strip
    raise "Source repository HEAD is #{head}, expected #{corrected_commit}" unless head == corrected_commit
    status = git_capture(source_root, "status", "--porcelain=v1", "--untracked-files=all")
    raise "Source repository is not clean" unless status.empty?
  end

  def repository_https_url(source_root)
    remote = git_capture(source_root, "remote", "get-url", "origin").strip
    normalized = if (match = remote.match(/\Agit@github\.com:(?<path>.+?)(?:\.git)?\z/))
      "https://github.com/#{match[:path].sub(/\.git\z/, '')}"
    elsif (match = remote.match(%r{\Ahttps://github\.com/(?<path>.+?)(?:\.git)?\z}))
      "https://github.com/#{match[:path].sub(/\.git\z/, '')}"
    end
    raise "Generated-source origin is not a GitHub repository: #{remote.inspect}" unless normalized
    normalized
  end

  def verify_evidence_chain!(proposal_root, proposal_manifest_path, review_manifest,
                             review_manifest_path, adjudication_manifest)
    unless review_manifest.fetch("proposal_root") == proposal_root &&
           review_manifest.fetch("proposal_manifest_sha256") == TimingAudit.sha256_file(proposal_manifest_path)
      raise "Post-fix review is not bound to the proposal evidence"
    end
    unless adjudication_manifest.fetch("review_root") == File.dirname(review_manifest_path) &&
           adjudication_manifest.fetch("review_manifest_sha256") == TimingAudit.sha256_file(review_manifest_path)
      raise "Adjudication is not bound to the post-fix review evidence"
    end
  end

  def records_by_id(path, key)
    records = TimingAudit.load_jsonl(path)
    mapped = records.to_h { |record| [record.fetch(key), record] }
    raise "Duplicate #{key} values in #{path}" unless mapped.size == records.size
    mapped
  end

  def load_yaml(path)
    YAML.safe_load(File.read(path), aliases: false)
  end

  def git_capture(root, *args)
    stdout, stderr, status = Open3.capture3("git", "-C", root, *args)
    raise "Git command failed: #{stderr.strip}" unless status.success?
    stdout
  end
end
