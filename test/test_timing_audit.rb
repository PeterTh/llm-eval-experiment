# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../tools/timing_audit/lib/timing_audit"
require_relative "../lib/local_evaluation"
require_relative "../tools/timing_audit/bin/timing_priority_review"
require_relative "../tools/timing_audit/bin/timing_finalize_audit"
require_relative "../tools/timing_audit/bin/export_validation_audit"

class TimingAuditTest < Minitest::Test
  def test_inventory_uses_pinned_tracked_sources_and_filters_successful_parallel_records
    Dir.mktmpdir do |root|
      source_root = File.join(root, "generated")
      release_root = File.join(root, "release")
      output = File.join(root, "audit")
      FileUtils.mkdir_p(source_root)
      initialize_repository(source_root)

      id = "black-scholes_test_mpi_r1"
      prefix = File.join("batch", id)
      write(File.join(source_root, prefix, "instruction.txt"), "parallelize with MPI\n")
      write(File.join(source_root, prefix, "black-scholes", "CMakeLists.txt"), "add_executable(x main.cpp)\n")
      write(File.join(source_root, prefix, "black-scholes", "main.cpp"), <<~CPP)
        #include <mpi.h>
        int main() {
          double local = 1.0, maximum = 0.0;
          MPI_Reduce(&local, &maximum, 1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);
        }
      CPP
      write(File.join(source_root, prefix, "output.txt"), "must not enter dossier\n")
      commit_all(source_root)
      commit = git(source_root, "rev-parse", "HEAD").strip

      FileUtils.mkdir_p(File.join(release_root, "data", "provenance"))
      FileUtils.mkdir_p(File.join(release_root, "data", "scoring"))
      write(File.join(release_root, "data", "provenance", "repositories.yaml"), YAML.dump(
        "generated_programs" => {
          "repository" => "https://example.invalid/generated",
          "commit" => commit
        }
      ))
      headers = %w[
        benchmark model par_type run validation_status benchmark_success source_batch
        source_path benchmark_median_time overall_score benchmark_config_sha256
      ]
      csv = CSV.generate do |rows|
        rows << headers
        rows << ["black-scholes", "test", "mpi", 1, 5, true, "batch",
                 File.join(source_root, prefix), 2.5, 9, "a" * 64]
        rows << ["black-scholes", "test", "omp", 2, 5, true, "batch",
                 File.join(source_root, "batch", "ignored"), 2.5, 9, "a" * 64]
      end
      write(File.join(release_root, "data", "scoring", "scored_results.csv"), csv)

      TimingAudit::InventoryBuilder.new(
        release_root: release_root,
        source_root: source_root,
        output_dir: output,
        trial_size: 1
      ).run

      records = TimingAudit.load_jsonl(File.join(output, "inventory.jsonl"))
      assert_equal [id], records.map { |record| record.fetch("id") }
      record = records.first
      assert record.dig("static_features", "has_mpi_max")
      refute_includes record.fetch("source_files").map { |file| file.fetch("path") }, "output.txt"
      assert_equal commit, YAML.safe_load(File.read(File.join(output, "manifest.yaml"))).dig("generated_source", "commit")
    end
  end

  def test_result_validator_checks_semantics_and_evidence_ranges
    record = {
      "id" => "sample_mpi_r1",
      "source_files" => [{ "path" => "main.cpp", "lines" => 20 }]
    }
    validator = TimingAudit::ResultValidator.new([record])
    result = valid_result("sample_mpi_r1")
    assert validator.validate!(result, expected_id: "sample_mpi_r1")

    result["evidence"][0]["lines"] = "21"
    error = assert_raises(RuntimeError) { validator.validate!(result, expected_id: "sample_mpi_r1") }
    assert_match(/exceeds/, error.message)
  end

  def test_codex_command_is_read_only_ephemeral_and_not_unsandboxed
    argv = TimingAudit::CodexCommand.new(model: "gpt-5.6-luna", effort: "high").argv(
      schema_path: "/tmp/schema.json",
      output_path: "/tmp/result.json"
    )
    assert_equal %w[codex exec], argv.first(2)
    assert_includes argv, "gpt-5.6-luna"
    assert_includes argv, %(model_reasoning_effort="high")
    assert_includes argv, "read-only"
    assert_includes argv, "--ephemeral"
    assert_includes argv, 'web_search="disabled"'
    %w[shell_tool unified_exec hooks].each do |feature|
      assert argv.each_cons(2).any? { |pair| pair == ["--disable", feature] }, "#{feature} must be disabled"
    end
    refute_includes argv, "--dangerously-bypass-approvals-and-sandbox"
  end

  def test_validation_inventory_filters_complete_results_without_scores
    Dir.mktmpdir do |root|
      source, run_dir, results = validation_fixture(root)
      output = File.join(root, "audit")
      manifest = TimingAudit::InventoryBuilder.new(source_root: source, validation_run: run_dir,
        release_root: "/nonexistent/release-must-not-be-read", output_dir: output).run
      records = TimingAudit.load_jsonl(File.join(output, "inventory.jsonl"))
      assert_equal ["black-scholes_test_mpi_r1"], records.map { |r| r.fetch("id") }
      assert_nil records.first.fetch("overall_score")
      assert_nil records.first.fetch("benchmark_median_time_ms")
      assert_equal "validation_only", manifest.dig("selection", "basis")
      assert_equal 3, manifest.dig("selection", "validation_records")
      assert_nil manifest.dig("selection", "benchmark_success")
      excluded = TimingAudit.load_jsonl(File.join(output, "excluded.jsonl"))
      assert_equal %w[backend_out_of_scope validation_failed], excluded.map { |r| r.fetch("reason") }.sort
      assert_equal results.size, records.size + excluded.size
      assert_includes records.first.fetch("source_files").map { |r| r.fetch("path") }, "black-scholes/helper.inc"
      assert_equal [records.first.fetch("id")], TimingAudit::TrialSelector.new(records, 16).select
    end
  end

  def test_validation_inventory_refuses_pending_duplicate_and_inconsistent_results
    %i[pending duplicate inconsistent metadata].each do |fault|
      Dir.mktmpdir do |root|
        source, run_dir, results = validation_fixture(root)
        case fault
        when :pending then results.pop
        when :duplicate then results << results.first
        when :inconsistent then results.first.validation_build = false
        when :metadata
          path = File.join(run_dir, "validation", results.first.id_string, "validation_metadata.yaml")
          metadata = YAML.safe_load_file(path)
          metadata["manifest_sha256"] = "0" * 64
          write(path, YAML.dump(metadata))
        end
        write(File.join(run_dir, "validation/all_validation_results.yaml"), YAML.dump(results))
        assert_raises(RuntimeError, fault.to_s) do
          TimingAudit::InventoryBuilder.new(source_root: source, validation_run: run_dir,
            output_dir: File.join(root, "audit")).run
        end
        refute File.exist?(File.join(root, "audit"))
      end
    end
  end

  def test_preparation_never_removes_an_existing_directory
    Dir.mktmpdir do |root|
      output = File.join(root, "existing")
      write(File.join(output, "keep.txt"), "user data")
      builder = TimingAudit::InventoryBuilder.new(source_root: root, release_root: root, output_dir: output)
      assert_raises(RuntimeError) { builder.run }
      assert_equal "user data", File.read(File.join(output, "keep.txt"))
    end
  end

  def test_static_event_guard_rejects_tools_and_incomplete_turns
    Dir.mktmpdir do |root|
      path = File.join(root, "events.jsonl")
      write(path, TimingAudit.dump_jsonl([
        { "type" => "item.completed", "item" => { "type" => "error", "message" => "Code mode disabled" } },
        { "type" => "item.completed", "item" => { "type" => "agent_message", "text" => "{}" } },
        { "type" => "turn.completed" }
      ]))
      assert TimingAudit.verify_static_events!(path)
      %w[command_execution mcp_tool_call web_search file_change unknown_tool].each do |type|
        write(path, TimingAudit.dump_jsonl([{ "type" => "item.started", "item" => { "type" => type } }]))
        assert_raises(RuntimeError) { TimingAudit.verify_static_events!(path) }
      end
      write(path, "")
      assert_raises(RuntimeError) { TimingAudit.verify_static_events!(path) }
    end
  end

  def test_validation_review_policy_includes_all_flagged_cases_without_scores
    Dir.mktmpdir do |root|
      write(File.join(root, "manifest.yaml"), YAML.dump("selection" => { "basis" => "validation_only" }))
      examples = [
        ["invalid", "invalid", "high", true], ["ambiguous", "ambiguous", "high", true],
        ["uncertain", "valid", "medium", true], ["equivalent", "valid", "high", false],
        ["ordinary", "valid", "high", true]
      ]
      inventory = examples.map { |id, _, _, has_max| { "id" => id, "static_features" => { "has_mpi_max" => has_max } } }
      write(File.join(root, "inventory.jsonl"), TimingAudit.dump_jsonl(inventory))
      write(File.join(root, "summary-full.csv"), CSV.generate do |csv|
        csv << %w[program_id verdict confidence issue_categories overall_score]
        examples.each { |id, verdict, confidence, _| csv << [id, verdict, confidence, verdict == "valid" ? "none" : "rank_local_timing", nil] }
      end)
      selected = TimingPriorityReview.selected_records(root)
      assert_equal %w[ambiguous equivalent invalid uncertain], selected.map { |r| r.fetch("program_id") }
      assert selected.all? { |r| r.fetch("overall_score").nil? }
      first = valid_result("ordinary")
      second = first.merge("confidence" => "medium")
      refute TimingAudit.adjudication_required?(first, second)
      assert TimingAudit.adjudication_required?(first, second, include_uncertain: true)
    end
  end

  def test_validation_first_workflow_verifies_trial_reviews_and_finalizes
    Dir.mktmpdir do |root|
      source, run_dir, = validation_fixture(root)
      primary = File.join(root, "primary")
      priority = File.join(root, "priority")
      adjudication = File.join(root, "adjudication")
      TimingAudit::InventoryBuilder.new(source_root: source, validation_run: run_dir, output_dir: primary).run
      record = TimingAudit.load_jsonl(File.join(primary, "inventory.jsonl")).first
      result = valid_result(record.fetch("id"))
      result["evidence"] = [{ "path" => "black-scholes/main.cpp", "lines" => "1", "finding" => "maximum timer" }]
      result["confidence"] = "medium"
      write_audit_attempt(primary, record, result)
      assert TimingAudit::AuditVerifier.new(primary, "trial").run
      summary_path = File.join(primary, "summary-full.jsonl")
      write(summary_path, "frozen summary\n")
      assert TimingAudit::AuditVerifier.new(primary, "full").run(write_summary: false)
      assert_equal "frozen summary\n", File.read(summary_path)
      assert TimingAudit::AuditVerifier.new(primary, "full").run
      TimingPriorityReview.prepare(main_root: primary, output_dir: priority)
      assert_equal 1, TimingAudit.load_jsonl(File.join(priority, "inventory.jsonl")).size
      assert_includes File.read(File.join(priority, "prompt-template.txt")), "first required pivot/panel broadcast"
      priority_manifest = YAML.safe_load_file(File.join(priority, "manifest.yaml"), aliases: false)
      assert_equal TimingAudit.sha256_file(File.join(priority, "prompt-template.txt")), priority_manifest.dig("artifacts", "prompt_template_sha256")
      priority_schema = JSON.parse(File.read(File.join(priority, "result-schema.json")))
      assert_equal "^[1-9][0-9]*(-[1-9][0-9]*)?$", priority_schema.dig("properties", "evidence", "items", "properties", "lines", "pattern")
      assert_equal TimingAudit.sha256_file(File.join(priority, "result-schema.json")), priority_manifest.dig("artifacts", "result_schema_sha256")
      write_audit_attempt(priority, record, result)
      assert TimingAudit::AuditVerifier.new(priority, "full").run
      context_path = File.join(root, "platform-context.txt")
      write(context_path, "Compile-only target ABI proof: chrono milliseconds rep is long.\n")
      TimingPriorityReview.prepare_adjudication(main_root: primary, review_root: priority, output_dir: adjudication,
        context_path: context_path, model: "gpt-6.1-sol")
      assert_equal "gpt-6.1-sol", YAML.safe_load_file(File.join(adjudication, "manifest.yaml")).dig("blind_adjudication", "model")
      assert_equal 1, TimingAudit.load_jsonl(File.join(adjudication, "inventory.jsonl")).size
      assert_includes File.read(File.join(adjudication, "prompt-template.txt")), "Compile-only target ABI proof"
      assert_equal File.read(context_path), File.read(File.join(adjudication, "platform-context.txt"))
      assert_raises(RuntimeError) { TimingFinalizeAudit.run(main_root: primary, priority_root: priority, adjudication_root: adjudication) }
      write_audit_attempt(adjudication, record, result.merge("confidence" => "high"))
      assert TimingAudit::AuditVerifier.new(adjudication, "full").run
      TimingFinalizeAudit.run(main_root: primary, priority_root: priority, adjudication_root: adjudication)
      final = TimingAudit.load_jsonl(File.join(primary, "final/decisions.jsonl")).first
      assert_equal "sol_adjudication", final.fetch("decision_basis")
      assert_nil final.fetch("overall_score")
      refute final.fetch("timing_fix_required")
      assert_equal "high", final.fetch("final_confidence")
      write_audit_attempt(adjudication, record, result.merge("verdict" => "ambiguous", "confidence" => "high",
        "issue_categories" => ["rank_local_timing"], "minimal_fix" => "Resolve profile condition"))
      TimingFinalizeAudit.run(main_root: primary, priority_root: priority, adjudication_root: adjudication)
      uncertain = TimingAudit.load_jsonl(File.join(primary, "final/decisions.jsonl")).first
      assert_nil uncertain.fetch("timing_fix_required")
      assert uncertain.fetch("timing_review_required")
      write_audit_attempt(adjudication, record, result.merge("confidence" => "high"))
      supplemental = File.join(root, "supplemental")
      selection_path = File.join(root, "supplemental-selection.jsonl")
      write(selection_path, TimingAudit.dump_jsonl([{ "program_id" => record.fetch("id"), "reason" => "Verified target profile needs an additional check" }]))
      TimingPriorityReview.prepare_supplemental(main_root: primary, output_dir: supplemental,
        selection_path: selection_path, context_path: context_path, model: "gpt-6.1-sol")
      assert_equal "gpt-6.1-sol", YAML.safe_load_file(File.join(supplemental, "manifest.yaml")).dig("supplemental_adjudication", "model")
      refute_includes File.read(File.join(supplemental, "prompt-template.txt")), "Verified target profile needs an additional check"
      assert_raises(RuntimeError) do
        TimingFinalizeAudit.run(main_root: primary, priority_root: priority, adjudication_root: adjudication, supplemental_root: supplemental)
      end
      changed = result.merge("confidence" => "high", "verdict" => "invalid", "issue_categories" => ["rank_local_timing"],
        "timing_only_fix_possible" => true, "minimal_fix" => "Reduce complete local durations")
      write_audit_attempt(supplemental, record, changed)
      TimingFinalizeAudit.run(main_root: primary, priority_root: priority, adjudication_root: adjudication, supplemental_root: supplemental)
      updated = TimingAudit.load_jsonl(File.join(primary, "final/decisions.jsonl")).first
      assert_equal "supplemental_sol_adjudication", updated.fetch("decision_basis")
      assert_equal "valid", updated.fetch("adjudication_verdict")
      assert_equal "invalid", updated.fetch("final_verdict")
      assert updated.fetch("timing_fix_required")
      write(File.join(supplemental, "supplemental-selection.jsonl"), "{}\n")
      assert_raises(RuntimeError) do
        TimingFinalizeAudit.run(main_root: primary, priority_root: priority, adjudication_root: adjudication, supplemental_root: supplemental)
      end
      runner = TimingAudit::AuditRunner.new(output_dir: primary, scope: "full", jobs: 1)
      assert runner.send(:valid_existing_result?, record.fetch("id"))
      # A changed event stream must never be accepted on resume/verification.
      File.open(File.join(primary, "logs", record.fetch("id"), "attempt-01/events.jsonl"), "a") { |f| f.puts("{}") }
      assert_raises(RuntimeError) { TimingAudit::AuditVerifier.new(primary, "full").run }
      refute runner.send(:valid_existing_result?, record.fetch("id"))
      attempted = []
      runner.stub(:run_attempt, ->(_record, _prompt, attempt, _worker) { attempted << attempt }) do
        runner.send(:run_with_retries, record.fetch("id"), 1)
      end
      assert_equal [2], attempted, "resuming must preserve the earlier attempt directory"
    end
  end

  def test_compact_validation_export_excludes_builds_sources_and_transcripts
    Dir.mktmpdir do |root|
      _source, run_dir, results = validation_fixture(root)
      manifest_path = File.join(run_dir, "evaluation_manifest.yaml")
      manifest = YAML.safe_load_file(manifest_path)
      manifest["batches"] = ["20260901-162328"]
      manifest["pipeline_source"] = LocalEvaluation.pipeline_source_snapshot
      write(manifest_path, YAML.dump(manifest))
      digest = TimingAudit.sha256_file(manifest_path)
      write("#{manifest_path}.sha256", digest + "\n")
      %w[preflight.yaml validation/preflight.yaml].each { |name| write(File.join(run_dir, name), YAML.dump({})) }
      results.each do |result|
        directory = File.join(run_dir, "validation", result.id_string)
        path = File.join(directory, "validation_metadata.yaml")
        metadata = YAML.safe_load_file(path)
        metadata["manifest_sha256"] = digest
        write(path, YAML.dump(metadata))
        write(File.join(directory, "validation_result.txt"), result.output_comparison ? "PASS\n" : "FAIL\n")
        write(File.join(directory, "validation_out_stdout.log"), "Validation: PASSED\n")
        write(File.join(directory, "black_scholes"), "\x00binary")
        write(File.join(directory, "source/main.cpp"), "generated program")
        write(File.join(directory, "output.txt"), "raw transcript")
      end
      output = File.join(root, "export")
      ValidationAuditExport.run(run_dir: run_dir, output_dir: output)
      exported = TimingAudit.load_jsonl(File.join(output, "validation/records.jsonl"))
      assert_equal 3, exported.size
      summary = JSON.parse(File.read(File.join(output, "summary.json")))
      assert_equal 2, summary.fetch("validation_passed")
      refute summary.fetch("benchmarking_performed")
      paths = Dir[File.join(output, "**", "*")].map { |p| p.delete_prefix(output + "/") }
      refute paths.any? { |path| path.include?("source/main.cpp") || path.end_with?("black_scholes", "output.txt") }
      assert File.file?(File.join(output, "checksums.sha256"))
      assert File.file?(File.join(output, "method/validation/validation_helper.rb"))
      reconstructed = File.join(root, "restored-method")
      JSON.parse(File.read(File.join(output, "method/layout.json"))).each do |stored, original|
        write(File.join(reconstructed, original), File.binread(File.join(output, stored)))
      end
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby,
        File.join(reconstructed, "tools/timing_audit/bin/timing_audit.rb"))
      assert_equal 1, status.exitstatus
      assert_includes stderr, "Usage:"
      refute_includes stderr, "LoadError"
    end
  end

  private

  def write_audit_attempt(root, record, result)
    id = record.fetch("id")
    serialized = JSON.pretty_generate(result) + "\n"
    result_path = File.join(root, "results", "#{id}.json")
    events_path = File.join(root, "logs", id, "attempt-01/events.jsonl")
    write(result_path, serialized)
    write(events_path, TimingAudit.dump_jsonl([
      { "type" => "item.completed", "item" => { "type" => "agent_message", "text" => JSON.generate(result) } },
      { "type" => "turn.completed" }
    ]))
    write(File.join(File.dirname(events_path), "metadata.yaml"), YAML.dump(
      "program_id" => id, "exit_code" => 0, "timed_out" => false,
      "source_digest" => record.fetch("source_digest"), "result_sha256" => TimingAudit.sha256_file(result_path),
      "events_sha256" => TimingAudit.sha256_file(events_path)))
  end

  def validation_fixture(root)
    source = File.join(root, "generated")
    run_dir = File.join(root, "validation-run")
    FileUtils.mkdir_p(source)
    initialize_repository(source)
    runs = {}
    results = %w[mpi hybrid omp].map do |backend|
      result = ValidationResult.new("black-scholes", "test", backend, 1)
      %w[basic_para validation_build validation_run internal_validation output_comparison].each do |stage|
        result.public_send("#{stage}=", true)
      end
      result.output_comparison = false if backend == "hybrid"
      id = result.id_string
      prefix = File.join("20260901-162328", id)
      write(File.join(source, prefix, "black-scholes/main.cpp"), "// MPI_Wtime MPI_MAX\n")
      write(File.join(source, prefix, "black-scholes/helper.inc"), "// included source\n")
      runs[id] = { "benchmark" => "black-scholes", "model" => "test", "par_type" => backend, "run" => 1,
                   "batch" => "20260901-162328", "source_path" => File.join(source, prefix) }
      result
    end
    commit_all(source)
    git(source, "remote", "add", "origin", "https://example.invalid/generated")
    manifest = { "schema_version" => LocalEvaluation::SCHEMA_VERSION, "experiments_root" => source,
                 "runs" => runs, "experiment_repository" => LocalEvaluation.git_snapshot(source) }
    path = File.join(run_dir, "evaluation_manifest.yaml")
    write(path, YAML.dump(manifest))
    digest = TimingAudit.sha256_file(path)
    write("#{path}.sha256", digest + "\n")
    results.each do |result|
      info = runs.fetch(result.id_string)
      metadata = info.slice("benchmark", "model", "par_type", "run").merge(
        "id" => result.id_string, "manifest_sha256" => digest,
        "stages" => %w[basic_para validation_build validation_run internal_validation output_comparison].to_h { |stage| [stage, result.public_send(stage)] })
      write(File.join(run_dir, "validation", result.id_string, "validation_metadata.yaml"), YAML.dump(metadata))
    end
    write(File.join(run_dir, "validation/all_validation_results.yaml"), YAML.dump(results))
    [source, run_dir, results]
  end

  def valid_result(id)
    {
      "program_id" => id,
      "verdict" => "valid",
      "issue_categories" => ["none"],
      "confidence" => "high",
      "timed_region" => "local computation",
      "start_synchronization" => "barrier",
      "stop_synchronization" => "completed work",
      "rank_aggregation" => "maximum reduction",
      "reported_value" => "reduced maximum",
      "semantic_equivalence_basis" => "MPI_MAX",
      "evidence" => [{ "path" => "main.cpp", "lines" => "1-10", "finding" => "maximum is reported" }],
      "timing_only_fix_possible" => false,
      "minimal_fix" => "",
      "notes" => ""
    }
  end

  def initialize_repository(path)
    git(path, "init", "-q")
    git(path, "config", "user.name", "Timing Audit Test")
    git(path, "config", "user.email", "timing-audit@example.invalid")
  end

  def commit_all(path)
    git(path, "add", ".")
    git(path, "commit", "-q", "-m", "fixture")
  end

  def git(path, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", path, *arguments)
    raise stderr unless status.success?
    stdout
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
