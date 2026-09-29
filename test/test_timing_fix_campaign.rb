# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../tools/timing_audit/lib/timing_fix_adjudication"
require_relative "../tools/timing_audit/lib/timing_fix_finalize"
require_relative "../tools/timing_audit/bin/export_timing_corrections"

class TimingFixCampaignTest < Minitest::Test
  def test_trial_selection_does_not_require_benchmark_scores
    records = %w[mpi hybrid].map do |backend|
      { "id" => "example_#{backend}_r1", "benchmark" => "example", "par_type" => backend,
        "model" => "test", "overall_score" => nil,
        "final_decision" => { "final_issue_categories" => ["rank_local_timing"] } }
    end
    assert_equal records.map { |record| record.fetch("id") }.sort,
      TimingFix::TrialSelector.new(records, 16).select.sort
    assert_empty TimingFix::TrialSelector.new([], 4).select
  end

  def test_preparation_and_finalization_never_delete_existing_directories
    Dir.mktmpdir do |root|
      output = File.join(root, "keep")
      FileUtils.mkdir_p(output)
      sentinel = File.join(output, "sentinel.txt")
      File.write(sentinel, "user data")
      builders = [TimingFix::InventoryBuilder.new(audit_root: root, output_dir: output),
        TimingFixReview::InventoryBuilder.new(proposal_root: root, output_dir: output),
        TimingFixAdjudication::InventoryBuilder.new(review_root: root, output_dir: output)]
      builders.each do |builder|
        assert_raises(RuntimeError) { builder.run }
        assert_equal "user data", File.read(sentinel)
      end
      assert_raises(RuntimeError) do
        TimingFixFinalize.run(proposal_root: root, review_root: root, adjudication_root: root,
          source_root: root, corrected_commit: "a" * 40, output_dir: output)
      end
      assert_equal "user data", File.read(sentinel)
    end
  end

  def test_static_evidence_binds_response_source_and_events_and_preserves_attempts
    Dir.mktmpdir do |root|
      artifacts = TimingFixEvidence.bind(root, {})
      File.write(File.join(root, "manifest.yaml"), YAML.dump("artifacts" => artifacts))
      record = { "source_digest" => "a" * 64 }
      response = { "program_id" => "example", "status" => "proposed" }
      attempt = File.join(root, "logs/example/attempt-04")
      FileUtils.mkdir_p(attempt)
      events_path = File.join(attempt, "events.jsonl")
      File.write(events_path, TimingAudit.dump_jsonl([
        { "type" => "item.completed", "item" => { "type" => "error", "message" => "execution disabled" } },
        { "type" => "item.completed", "item" => { "type" => "agent_message", "text" => JSON.generate(response) } },
        { "type" => "turn.completed", "usage" => { "input_tokens" => 10 } }
      ]))
      stderr_path = File.join(attempt, "stderr.log")
      File.write(stderr_path, "")
      metadata = TimingFixEvidence.stream_metadata(events_path, stderr_path).merge(
        "source_digest" => record.fetch("source_digest"), "exit_code" => 0, "timed_out" => false,
        "result_sha256" => TimingAudit.sha256_bytes(JSON.pretty_generate(response) + "\n"))
      File.write(File.join(attempt, "metadata.yaml"), YAML.dump(metadata))
      assert TimingFixEvidence.verify_response!(root, "example", response, record)
      assert_equal 5, TimingFixEvidence.next_attempt(root, "example")
      assert_equal 10, metadata.dig("usage", "input_tokens")
      assert_equal ["execution disabled"], metadata.fetch("diagnostics")
      assert_raises(RuntimeError) { TimingFixEvidence.verify_response!(root, "example", response.merge("status" => "cannot_fix"), record) }
      assert_raises(RuntimeError) { TimingFixEvidence.verify_response!(root, "example", response, { "source_digest" => "b" * 64 }) }
      File.open(events_path, "a") { |file| file.puts(JSON.generate("type" => "item.started", "item" => { "type" => "command_execution" })) }
      assert_raises(RuntimeError) { TimingFixEvidence.verify_response!(root, "example", response, record) }
    end
  end

  def test_platform_context_is_literal_and_review_schema_matches_validator
    Dir.mktmpdir do |root|
      context = File.join(root, "context.txt")
      File.write(context, "C++ %ld output; one visible GPU per rank.")
      prompt = TimingFixEvidence.add_context(root, "Program: %{id}\n", context)
      assert_includes(prompt % { id: "example" }, "C++ %ld output")
      schema = JSON.parse(TimingFixEvidence.review_schema(File.expand_path("../tools/timing_audit/schemas/timing_fix_review_schema.json", __dir__)))
      assert_equal "^[1-9][0-9]*(-[1-9][0-9]*)?$", schema.dig("properties", "evidence", "items", "properties", "lines", "pattern")
    end
  end

  def test_export_registry_requires_both_pinned_website_links_and_matching_successful_revalidation
    result = ValidationResult.new("matmul", "test", "mpi", 1)
    TimingCorrectionExport::STAGES.each { |stage| result.public_send("#{stage}=", true) }
    id = result.id_string
    original = "a" * 40
    corrected = "b" * 40
    repository = "https://github.com/example/generated"
    prefix = "20260901-162328/#{id}"
    info = { "benchmark" => "matmul", "model" => "test", "par_type" => "mpi", "run" => 1, "batch" => "20260901-162328" }
    validation_manifest = Struct.new(:runs, :data).new({ id => info }, { "experiment_repository" => { "commit" => corrected } })
    manifest = { "record_count" => 1,
      "original_source" => { "commit" => original, "repository_url" => repository },
      "corrected_source" => { "commit" => corrected, "repository_url" => repository } }
    record = info.reject { |key, _| key == "batch" }.merge("program_id" => id, "source_prefix" => prefix,
      "timing_fixed" => true, "final_verdict" => "accept",
      "original_source" => { "commit" => original, "digest" => "c" * 64 },
      "corrected_source" => { "commit" => corrected, "digest" => "d" * 64 },
      "original_source_url" => "#{repository}/tree/#{original}/#{prefix}",
      "corrected_source_url" => "#{repository}/tree/#{corrected}/#{prefix}")
    check = ->(entry) { TimingCorrectionExport.validate_registry!(manifest, [entry], [id], validation_manifest, [result]) }
    assert check.call(record)
    assert_raises(RuntimeError) { check.call(record.merge("original_source_url" => record.fetch("corrected_source_url"))) }
    assert_raises(RuntimeError) { check.call(record.merge("timing_fixed" => false)) }
    assert_raises(RuntimeError) { check.call(record.merge("source_prefix" => "wrong-batch/#{id}")) }
    assert_raises(RuntimeError) { check.call(record.merge("model" => "wrong-model")) }
    result.output_comparison = false
    assert_raises(RuntimeError) { check.call(record) }
  end

  def test_omitted_proposal_snapshot_is_reconstructible_in_review_order
    Dir.mktmpdir do |root|
      proposals = { "one" => { "program_id" => "one", "edits" => [] },
                    "two" => { "program_id" => "two", "edits" => [] } }
      ids = %w[two one]
      snapshots = ids.map do |id|
        proposal = proposals.fetch(id)
        { "program_id" => id,
          "proposal_file_sha256" => TimingAudit.sha256_bytes(JSON.pretty_generate(proposal) + "\n"),
          "proposal" => proposal }
      end
      bytes = TimingAudit.dump_jsonl(snapshots)
      File.write(File.join(root, "inventory.jsonl"), TimingAudit.dump_jsonl(ids.map { |id| { "id" => id } }))
      File.write(File.join(root, "proposal-snapshot.jsonl"), bytes)
      File.write(File.join(root, "manifest.yaml"), YAML.dump("artifacts" => { "proposal_snapshot_sha256" => TimingAudit.sha256_bytes(bytes) }))
      assert TimingCorrectionExport.verify_snapshot_reconstruction!(root, proposals)
      assert_raises(RuntimeError) { TimingCorrectionExport.verify_snapshot_reconstruction!(root, proposals.merge("one" => { "program_id" => "one", "edits" => ["changed"] })) }
      File.write(File.join(root, "proposal-snapshot.jsonl"), "changed")
      assert_raises(RuntimeError) { TimingCorrectionExport.verify_snapshot_reconstruction!(root, proposals) }
    end
  end

  def test_numerical_comparison_ignores_timing_but_preserves_result_differences
    result = "=== RESULTS ===\nName: Example\nSum: 1.0\n=== END RESULTS ===\n"
    comparison = TimingCorrectionExport.compare_numerical_outputs("Time: 1ms\n" + result, "Time: 2ms\n" + result)
    assert comparison.fetch("numerical_results_identical")
    assert_equal comparison.fetch("original_numerical_results_sha256"), comparison.fetch("corrected_numerical_results_sha256")
    refute TimingCorrectionExport.compare_numerical_outputs(result, result.sub("1.0", "1.1")).fetch("numerical_results_identical")
    assert_raises(RuntimeError) { TimingCorrectionExport.compare_numerical_outputs(result, "missing results") }
  end
end
