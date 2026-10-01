# frozen_string_literal: true

require "minitest/autorun"
require_relative "../tools/timing_audit/lib/timing_fix_review"

class TimingFixReviewValidatorTest < Minitest::Test
  def setup
    @record = {
      "id" => "example_mpi_r1",
      "corrected_source_files" => [
        { "path" => "bench/main.cpp", "lines" => 20 }
      ]
    }
    @validator = TimingFixReview::ResultValidator.new([@record])
  end

  def test_accepts_valid_independent_review
    assert @validator.validate!(accepted_result, expected_id: "example_mpi_r1")
  end

  def test_rejects_accept_with_non_timing_issue
    result = accepted_result.merge("issue_categories" => ["non_timing_change"])
    assert_raises(RuntimeError) do
      @validator.validate!(result, expected_id: "example_mpi_r1")
    end
  end

  def test_rejects_corrected_source_citation_past_end
    result = accepted_result
    result["evidence"] = [{ "path" => "bench/main.cpp", "lines" => "19-21", "finding" => "bad range" }]
    assert_raises(RuntimeError) do
      @validator.validate!(result, expected_id: "example_mpi_r1")
    end
  end

  private

  def accepted_result
    {
      "program_id" => "example_mpi_r1",
      "verdict" => "accept",
      "issue_categories" => ["none"],
      "confidence" => "high",
      "timing_contract_satisfied" => true,
      "timing_only_scope_satisfied" => true,
      "device_completion" => "not_applicable",
      "timed_region" => "Complete local work is timed.",
      "rank_aggregation" => "Complete durations use MPI_MAX.",
      "collective_safety" => "All ranks call a type-compatible reduction.",
      "canonical_output" => "Rank zero reports the reduced maximum.",
      "scope_assessment" => "Only timing and derived performance output changed.",
      "evidence" => [
        { "path" => "bench/main.cpp", "lines" => "10-15", "finding" => "Timer and reduction." }
      ],
      "minimal_correction" => "",
      "notes" => ""
    }
  end
end

class TimingFixReviewInventoryTest < Minitest::Test
  def test_prepares_compiled_trial_without_full_proposals_or_summary
    with_proposals("trial") do |root, proposals, ids|
      manifest = nil
      output = File.join(root, "review")
      capture_io do
        manifest = TimingFixReview::InventoryBuilder.new(proposal_root: proposals, output_dir: output, scope: "trial").run
      end
      assert_equal "trial", manifest.fetch("proposal_scope")
      assert_equal 1, manifest.dig("selection", "records")
      assert_equal [ids.first], TimingAudit.load_jsonl(File.join(output, "inventory.jsonl")).map { |r| r.fetch("id") }
      assert_equal "trial", manifest.dig("compile_validation", "scope")
      refute File.exist?(File.join(proposals, "summary-full.jsonl"))
    end
  end

  def test_default_scope_requires_and_retains_all_compiled_proposals
    with_proposals("full") do |root, proposals, ids|
      manifest = nil
      capture_io do
        manifest = TimingFixReview::InventoryBuilder.new(proposal_root: proposals, output_dir: File.join(root, "review")).run
      end
      assert_equal "full", manifest.fetch("proposal_scope")
      assert_equal ids.size, manifest.dig("selection", "records")
      assert_equal [ids.first], manifest.dig("trial", "ids")
    end
  end

  def test_rejects_wrong_scope_failed_compile_and_invalid_trial_ids
    %i[scope compile duplicate unknown].each do |fault|
      with_proposals("trial") do |root, proposals, ids|
        summary_path = File.join(proposals, "materialized/summary-trial.yaml")
        summary = YAML.safe_load_file(summary_path)
        case fault
        when :scope then summary["scope"] = "full"
        when :compile then summary["compile_successes"] = 0
        when :duplicate then File.write(File.join(proposals, "trial-ids.txt"), ([ids.first] * 2).join("\n") + "\n")
        when :unknown then File.write(File.join(proposals, "trial-ids.txt"), "unknown\n")
        end
        File.write(summary_path, YAML.dump(summary))
        output = File.join(root, "review")
        assert_raises(RuntimeError) do
          TimingFixReview::InventoryBuilder.new(proposal_root: proposals, output_dir: output, scope: "trial").run
        end
        refute File.exist?(output)
      end
    end
  end

  private

  def with_proposals(scope)
    Dir.mktmpdir("timing-fix-review-test-") do |root|
      source = File.join(root, "source")
      proposals = File.join(root, "proposals")
      FileUtils.mkdir_p([source, File.join(proposals, "proposals"), File.join(proposals, "materialized")])
      ids = %w[example_mpi_r1 example_mpi_r2]
      original = "double elapsed = 0; // Computation time\n"
      records = ids.map do |id|
        prefix = "batch/#{id}"
        path = "bench/main.cpp"
        absolute = File.join(source, prefix, path)
        FileUtils.mkdir_p(File.dirname(absolute))
        File.write(absolute, original)
        { "id" => id, "source_prefix" => prefix, "metric_label" => "Computation time",
          "source_files" => [{ "path" => path, "git_path" => "#{prefix}/#{path}",
            "sha256" => TimingAudit.sha256_bytes(original), "lines" => 1 }] }
      end
      git = ->(*args) { TimingAudit.capture!("git", "-C", source, *args) }
      git.call("init", "-q")
      git.call("config", "user.email", "test@example.invalid")
      git.call("config", "user.name", "Test")
      git.call("add", ".")
      git.call("commit", "-qm", "fixture")
      File.write(File.join(proposals, "manifest.yaml"), YAML.dump("generated_source" => {
        "root" => source, "commit" => git.call("rev-parse", "HEAD").strip }))
      File.write(File.join(proposals, "inventory.jsonl"), TimingAudit.dump_jsonl(records))
      File.write(File.join(proposals, "trial-ids.txt"), ids.first + "\n")
      selected = scope == "trial" ? ids.first(1) : ids
      selected.each do |id|
        proposal = { "program_id" => id, "status" => "proposed", "summary" => "Timing-only fixture",
          "expected_timing_semantics" => "Completed elapsed time", "non_timing_changes" => [], "notes" => "",
          "edits" => [{ "path" => "bench/main.cpp", "old_text" => original,
            "new_text" => "double elapsed = 1; // Computation time\n", "rationale" => "Fixture" }] }
        File.write(File.join(proposals, "proposals", "#{id}.json"), JSON.generate(proposal))
      end
      File.write(File.join(proposals, "summary-#{scope}.jsonl"), "{}\n")
      patch = File.join(proposals, "materialized/timing-fixes-#{scope}.patch")
      File.write(patch, "test-patch\n")
      summary = { "scope" => scope, "records" => selected.size, "changed_paths" => selected.size,
        "compiled" => selected.size, "compile_successes" => selected.size, "compile_failures" => [],
        "patch_sha256" => TimingAudit.sha256_file(patch) }
      File.write(File.join(proposals, "materialized/summary-#{scope}.yaml"), YAML.dump(summary))
      yield root, proposals, ids
    end
  end
end
