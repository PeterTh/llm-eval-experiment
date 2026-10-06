# frozen_string_literal: true

require "minitest/autorun"
require_relative "../tools/timing_audit/lib/qtclustering_boundary"
require_relative "../tools/timing_audit/lib/timing_fix"

class QtclusteringBoundaryTest < Minitest::Test
  def test_selection_includes_all_backends_and_benchmark_failures
    fixture do |args, ids|
      manifest = QtclusteringBoundary::Builder.new(**args).run
      root = args.fetch(:output_dir)
      records = TimingAudit.load_jsonl(File.join(root, "inventory.jsonl"))
      assert_equal ids.first(4).sort, records.map { |r| r.fetch("id") }.sort
      assert_equal %w[cuda hybrid mpi omp], records.map { |r| r.fetch("par_type") }.sort
      assert_equal 4, manifest.dig("selection", "records")
      assert_equal 1, records.count { |r| r.fetch("previous_benchmark_success") == false }
      assert_equal 1, TimingAudit.load_jsonl(File.join(root, "excluded.jsonl")).size
      assert records.all? { |r| r["overall_score"].nil? }
      repo = TimingAudit::SourceRepository.new(root: args[:source_root], commit: args[:source_commit])
      record = records.first
      prompt = File.read(File.join(root, "prompt-template.txt")) % {
        program_id: record["id"], benchmark: "qtclustering", par_type: record["par_type"],
        metric_label: "Clustering time", dossier: repo.dossier(record)
      }
      assert_includes prompt, 'printf("%d", 1)'
      refute_includes prompt, "__REFERENCE_CONTEXT__"
      assert_includes prompt, "squared distances"
      assert_includes prompt, "no MPI-reduction requirement"
      schema = JSON.parse(File.read(File.join(root, "result-schema.json")))
      assert schema.dig("properties", "evidence", "items", "properties", "lines", "pattern")
    end
  end

  def test_refuses_source_changed_since_evaluation
    fixture do |args, ids|
      path = File.join(args[:source_root], "batch", ids.first, "qtclustering", "qtclustering.cpp")
      File.write(path, "changed();\n")
      git(args[:source_root], "add", ".")
      git(args[:source_root], "commit", "-qm", "change")
      args[:source_commit] = git(args[:source_root], "rev-parse", "HEAD").strip
      error = assert_raises(RuntimeError) { QtclusteringBoundary::Builder.new(**args).run }
      assert_match(/Evaluated source changed/, error.message)
      refute File.exist?(args[:output_dir])
    end
  end

  def test_validation_only_selects_new_observations_without_repeating_release
    fixture do |args, ids|
      validation = native_validation(args, ids)
      args[:validation_runs] = [validation]
      args[:include_release] = false
      manifest = nil
      capture_io { manifest = QtclusteringBoundary::Builder.new(**args).run }
      records = TimingAudit.load_jsonl(File.join(args[:output_dir], "inventory.jsonl"))
      assert_equal ids.first(4).sort, records.map { |record| record.fetch("id") }.sort
      assert records.all? { |record| record.fetch("origin") == validation }
      refute manifest.dig("selection", "include_release")
      assert_equal({ validation => 4 }, manifest.dig("selection", "by_origin"))
      exclusions = TimingAudit.load_jsonl(File.join(args[:output_dir], "excluded.jsonl"))
      assert_equal [ids.last], exclusions.map { |record| record.fetch("program_id") }
      assert_equal [validation], exclusions.map { |record| record.fetch("origin") }
      evidence = TimingAudit.load_jsonl(File.join(args[:output_dir], "inputs.jsonl"))
      assert_includes evidence.map { |record| record.fetch("path") }, File.join(args[:release_root], "release/catalog.json")
      assert_includes evidence.map { |record| record.fetch("path") }, args[:benchmark_config]
    end
  end

  def test_validation_only_requires_a_validation_run
    fixture do |args, _ids|
      error = assert_raises(RuntimeError) do
        QtclusteringBoundary::Builder.new(**args, include_release: false)
      end
      assert_match(/requires a validation run/, error.message)
      refute File.exist?(args[:output_dir])
    end
  end

  def test_refuses_duplicate_rows_and_validation_disagreement
    %i[duplicate disagreement].each do |fault|
      fixture do |args, _|
        path = File.join(args[:release_root], "release/scored_results.csv")
        rows = CSV.read(path)
        fault == :duplicate ? rows << rows[1] : rows[1][4] = "4"
        File.write(path, CSV.generate { |out| rows.each { |r| out << r } })
        assert_raises(RuntimeError) { QtclusteringBoundary::Builder.new(**args).run }
        refute File.exist?(args[:output_dir])
      end
    end
  end

  def test_preserves_existing_output
    fixture do |args, _|
      FileUtils.mkdir_p(args[:output_dir])
      path = File.join(args[:output_dir], "keep.txt")
      File.write(path, "preserve")
      assert_raises(RuntimeError) { QtclusteringBoundary::Builder.new(**args).run }
      assert_equal "preserve", File.read(path)
    end
  end

  def test_rejects_inconsistent_stages
    valid = QtclusteringBoundary::STAGES.to_h { |k| [k, true] }
    assert QtclusteringBoundary.passed?(valid)
    refute QtclusteringBoundary.passed?(valid.merge("output_comparison" => false))
    assert_raises(RuntimeError) { QtclusteringBoundary.passed?(valid.merge("validation_build" => false)) }
    assert_raises(RuntimeError) { QtclusteringBoundary.passed?(valid.merge("output_comparison" => nil)) }
  end

  def test_blind_review_reuses_pilot_and_finalizer_retains_uncertainty
    fixture do |args, _|
      main = args.fetch(:output_dir)
      review = "#{main}-review"
      capture_io { QtclusteringBoundary::Builder.new(**args).run }
      records = TimingAudit.load_jsonl(File.join(main, "inventory.jsonl"))
      records.each { |r| fake_result(main, r, QtclusteringBoundary::PRIMARY_MODEL) }
      QtclusteringBoundary.prepare_review(main_root: main, output_dir: review)
      assert_equal File.read(File.join(main, "prompt-template.txt")), File.read(File.join(review, "prompt-template.txt"))
      assert_equal File.read(File.join(main, "trial-ids.txt")), File.read(File.join(review, "trial-ids.txt"))
      records.each { |r| fake_result(review, r, QtclusteringBoundary::ADJUDICATION_MODEL) }
      passed = nil
      capture_io { passed = QtclusteringBoundary.pilot_gate(main_root: main, review_root: review) }
      assert passed
      uncertain = records.first
      fake_result(review, uncertain, QtclusteringBoundary::ADJUDICATION_MODEL, verdict: "ambiguous")
      fake_result(review, records.last, QtclusteringBoundary::ADJUDICATION_MODEL, verdict: "invalid")
      capture_io { passed = QtclusteringBoundary.pilot_gate(main_root: main, review_root: review) }
      refute passed
      selection = QtclusteringBoundary.review_selection(main)
      assert_equal records.size, selection.size
      write(File.join(review, "adjudication-selection.jsonl"), TimingAudit.dump_jsonl(selection))
      capture_io { QtclusteringBoundary.finalize(main_root: main, review_root: review) }
      decisions = TimingAudit.load_jsonl(File.join(main, "final/decisions.jsonl"))
      row = decisions.find { |r| r.fetch("program_id") == uncertain.fetch("id") }
      assert_equal "ambiguous", row.fetch("final_verdict")
      assert_nil row.fetch("timing_fix_required")
      assert row.fetch("timing_review_required")
      assert_equal uncertain.fetch("id"), File.read(File.join(main, "final/review-ids.txt")).strip
      proposals = "#{main}-proposals"
      capture_io { TimingFix::InventoryBuilder.new(audit_root: main, output_dir: proposals).run }
      fixes = TimingAudit.load_jsonl(File.join(proposals, "inventory.jsonl"))
      assert_equal [records.last.fetch("id")], fixes.map { |r| r.fetch("id") }
      assert_equal %w[adjudication primary], fixes.first.fetch("review_findings").keys.sort
      assert_raises(RuntimeError) { QtclusteringBoundary.finalize(main_root: main, review_root: review) }
    end
  end

  def test_reviewer_model_and_frozen_artifacts_are_enforced
    fixture do |args, _|
      main = args.fetch(:output_dir)
      capture_io { QtclusteringBoundary::Builder.new(**args).run }
      record = TimingAudit.load_jsonl(File.join(main, "inventory.jsonl")).first
      fake_result(main, record, QtclusteringBoundary::ADJUDICATION_MODEL)
      assert_raises(RuntimeError) { QtclusteringBoundary.verify_results(main, [record.fetch("id")], QtclusteringBoundary::PRIMARY_MODEL) }
      fake_result(main, record, QtclusteringBoundary::PRIMARY_MODEL)
      assert QtclusteringBoundary.verify_results(main, [record.fetch("id")], QtclusteringBoundary::PRIMARY_MODEL)
      File.write(File.join(main, "reference-source.txt"), "changed")
      assert_raises(RuntimeError) { QtclusteringBoundary.verify_results(main, [record.fetch("id")], QtclusteringBoundary::PRIMARY_MODEL) }
    end
  end

  def test_maxloc_does_not_suppress_makespan_review
    Dir.mktmpdir do |root|
      path = File.join(root, "source.cpp")
      ["MPI_MAXLOC", "MPI_MAX"].each do |token|
        File.write(path, token)
        record = { "source_files" => [{ "path" => "source.cpp", "git_path" => "source.cpp", "sha256" => TimingAudit.sha256_bytes(token) }] }
        assert_equal token == "MPI_MAX", QtclusteringBoundary.explicit_mpi_max?(record, root)
        File.write(path, "changed")
        assert_raises(RuntimeError) { QtclusteringBoundary.explicit_mpi_max?(record, root) }
      end
    end
  end

  def test_correction_overlay_supersedes_same_source_decisions_and_adds_new_cases
    fixture do |args, _|
      main = args.fetch(:output_dir)
      capture_io { QtclusteringBoundary::Builder.new(**args).run }
      rows = TimingAudit.load_jsonl(File.join(main, "inventory.jsonl"))
      overlay = "#{main}-overlay"
      TimingAudit.derive_inventory(parent_root: main, output_dir: overlay,
        ids: rows.map { |r| r.fetch("id") }, provenance: {})
      write_resolved_audit(main, rows.first(2), [rows.first.fetch("id")])
      write_resolved_audit(overlay, rows, [rows.last.fetch("id")])
      proposals = "#{main}-combined"
      capture_io do
        TimingFix::InventoryBuilder.new(audit_root: main, overlay_roots: [overlay],
          source_root: args[:source_root], output_dir: proposals).run
      end
      selected = TimingAudit.load_jsonl(File.join(proposals, "inventory.jsonl"))
      assert_equal [rows.last.fetch("id")], selected.map { |r| r.fetch("id") }
      manifest = YAML.safe_load_file(File.join(proposals, "manifest.yaml"))
      assert_equal [2, 4], manifest.fetch("audit_sources").map { |r| r.fetch("records") }
      assert_equal args[:source_root], manifest.dig("generated_source", "root")
      rows.first["source_digest"] = "0" * 64
      write_resolved_audit(overlay, rows, [rows.last.fetch("id")])
      error = assert_raises(RuntimeError) do
        TimingFix::InventoryBuilder.new(audit_root: main, overlay_roots: [overlay], output_dir: "#{main}-bad").run
      end
      assert_match(/overlay source mismatch/, error.message)
      refute File.exist?("#{main}-bad")
    end
  end

  private

  def native_validation(args, ids)
    root = File.join(File.dirname(args[:output_dir]), "native-validation")
    runs = ids.to_h { |id| [id, LocalEvaluation.parse_run_id(id).merge("batch" => "batch")] }
    manifest = {
      "schema_version" => 1,
      "experiment_repository" => { "git" => true, "dirty" => false, "commit" => args[:source_commit] },
      "runs" => runs
    }
    path = File.join(root, "evaluation_manifest.yaml")
    LocalEvaluation.atomic_yaml_with_digest(path, manifest, immutable: true)
    results = ids.each_with_index.map do |id, index|
      info = runs.fetch(id)
      result = ValidationResult.new(info.fetch("benchmark"), info.fetch("model"), info.fetch("par_type"), info.fetch("run"))
      stages = QtclusteringBoundary::STAGES.to_h { |stage| [stage, index < 4] }
      stages.each { |stage, passed| result.public_send("#{stage}=", passed) }
      write(File.join(root, "validation", id, "validation_metadata.yaml"), YAML.dump(
        "id" => id, "manifest_sha256" => TimingAudit.sha256_file(path), "stages" => stages))
      result
    end
    write(File.join(root, "validation/all_validation_results.yaml"), YAML.dump(results))
    root
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def git(root, *args)
    TimingAudit.capture!("git", "-C", root, *args)
  end

  def fake_result(root, record, model, verdict: "valid")
    id = record.fetch("id")
    result = { "program_id" => id, "verdict" => verdict, "confidence" => "high",
      "issue_categories" => verdict == "valid" ? ["none"] : ["other"],
      "timed_region" => "Complete work", "start_synchronization" => "Joined", "stop_synchronization" => "Joined",
      "rank_aggregation" => "Not applicable", "reported_value" => "elapsed", "semantic_equivalence_basis" => "",
      "evidence" => [{ "path" => "qtclustering/qtclustering.cpp", "lines" => "1", "finding" => "Fixture" }],
      "timing_only_fix_possible" => verdict == "invalid", "minimal_fix" => verdict == "invalid" ? "Enclose complete computation." : "", "notes" => "" }
    bytes = JSON.pretty_generate(result) + "\n"
    write(File.join(root, "results", "#{id}.json"), bytes)
    attempt = File.join(root, "logs", id, "attempt-01")
    events = TimingAudit.dump_jsonl([{ "type" => "item.completed", "item" => { "type" => "agent_message", "text" => bytes } },
      { "type" => "turn.completed" }])
    write(File.join(attempt, "events.jsonl"), events)
    metadata = { "exit_code" => 0, "timed_out" => false, "source_digest" => record.fetch("source_digest"),
      "result_sha256" => TimingAudit.sha256_bytes(bytes), "events_sha256" => TimingAudit.sha256_bytes(events),
      "static_only_verified" => true, "model" => model, "reasoning_effort" => model == QtclusteringBoundary::PRIMARY_MODEL ? "high" : "xhigh" }
    write(File.join(attempt, "metadata.yaml"), YAML.dump(metadata))
  end

  def write_resolved_audit(root, rows, invalid_ids)
    write(File.join(root, "inventory.jsonl"), TimingAudit.dump_jsonl(rows))
    manifest_path = File.join(root, "manifest.yaml")
    manifest = YAML.safe_load_file(manifest_path)
    manifest["selection"]["records"] = rows.size
    manifest["artifacts"]["inventory_sha256"] = TimingAudit.sha256_file(File.join(root, "inventory.jsonl"))
    write(manifest_path, YAML.dump(manifest))
    decisions = rows.map do |row|
      id = row.fetch("id")
      verdict = invalid_ids.include?(id) ? "invalid" : "valid"
      fake_result(root, row, QtclusteringBoundary::PRIMARY_MODEL, verdict: verdict)
      { "program_id" => id, "source_digest" => row.fetch("source_digest"),
        "final_verdict" => verdict, "final_issue_categories" => verdict == "valid" ? ["none"] : ["other"] }
    end
    write(File.join(root, "final/decisions.jsonl"), TimingAudit.dump_jsonl(decisions))
    write(File.join(root, "final/correction-ids.txt"), invalid_ids.sort.join("\n") + "\n")
    write(File.join(root, "final/metadata.yaml"), YAML.dump("roots" => {
      "primary" => root, "priority_review" => nil, "adjudication" => nil }))
  end

  def fixture
    Dir.mktmpdir("qt-boundary-test-") do |root|
      source = File.join(root, "source")
      reference = File.join(root, "reference")
      release = File.join(root, "release")
      [source, reference].each do |repo|
        FileUtils.mkdir_p(repo)
        git(repo, "init", "-q")
        git(repo, "config", "user.email", "test@example.invalid")
        git(repo, "config", "user.name", "Test")
      end
      backends = %w[omp cuda mpi hybrid omp]
      ids = backends.each_with_index.map { |backend, i| "qtclustering_test_#{backend}_r#{i + 1}" }
      ids.each do |id|
        write(File.join(source, "batch", id, "qtclustering/qtclustering.cpp"), "int main() { return 0; }\n")
      end
      git(source, "add", ".")
      git(source, "commit", "-qm", "initial")
      commit = git(source, "rev-parse", "HEAD").strip
      write(File.join(reference, "qtclustering/qtclustering.cpp"), "printf(\"%d\", 1);\n")
      git(reference, "add", ".")
      git(reference, "commit", "-qm", "reference")
      reference_commit = git(reference, "rev-parse", "HEAD").strip
      validation = ids.each_with_index.map do |id, i|
        { "id" => id, "benchmark" => "qtclustering", "stages" => QtclusteringBoundary::STAGES.to_h { |key| [key, i < 4] } }
      end
      write(File.join(release, "validation.jsonl"), TimingAudit.dump_jsonl(validation))
      config = { "cells" => QtclusteringBoundary::BACKENDS.to_h { |backend| [backend, { "qtclustering" => { "args" => ["-n", "100"], "timeout_seconds" => 30 } }] } }
      config_path = File.join(release, "config.yaml")
      write(config_path, YAML.dump(config))
      write(File.join(release, "context.txt"), "Static platform facts\n")
      catalog = { "campaigns" => [{ "validation_records" => "validation.jsonl", "source_commit" => commit, "benchmark_config" => "config.yaml" }] }
      write(File.join(release, "release/catalog.json"), JSON.generate(catalog))
      csv = CSV.generate do |out|
        out << %w[benchmark model par_type run validation_status benchmark_success timing_fixed source_batch corrected_source_commit]
        ids.each_with_index { |_, i| out << ["qtclustering", "test", backends[i], i + 1, i < 4 ? 5 : 0, i != 1, false, "batch", nil] }
      end
      write(File.join(release, "release/scored_results.csv"), csv)
      yield({ release_root: release, validation_runs: [], source_root: source, source_commit: commit,
        reference_root: reference, reference_commit: reference_commit, benchmark_config: config_path,
        context_path: File.join(release, "context.txt"), output_dir: File.join(root, "audit") }, ids)
    end
  end
end
