# frozen_string_literal: true

require "minitest/autorun"
require_relative "../tools/timing_audit/bin/benchmark_validation_batch"

class BenchmarkValidationBatchTest < Minitest::Test
  def test_canaries_preserve_first_repetition_when_it_is_eligible
    ids = LocalEvaluation::PAR_TYPES.flat_map { |backend|
      [2, 1].map { |run| "black-scholes_test_#{backend}_r#{run}" }
    }
    assert_equal LocalEvaluation::PAR_TYPES.map { |backend| "black-scholes_test_#{backend}_r1" },
      BenchmarkValidationBatch.canary_ids(ids, "test")
  end

  def test_canaries_select_first_unchanged_valid_repetition_per_backend
    ids = LocalEvaluation::PAR_TYPES.map { |backend| "black-scholes_test_#{backend}_r1" }
    ids.delete("black-scholes_test_hybrid_r1")
    ids.concat(%w[black-scholes_test_hybrid_r10 black-scholes_test_hybrid_r3
      black-scholes_another_hybrid_r1 matmul_test_hybrid_r1])
    selected = BenchmarkValidationBatch.canary_ids(ids.reverse, "test")
    assert_includes selected, "black-scholes_test_hybrid_r3"
    assert_equal 4, selected.size
    assert_equal 4, selected.uniq.size
    refute_includes selected, "black-scholes_test_hybrid_r1"
  end

  def test_canaries_cannot_fall_back_to_another_model_or_benchmark
    ids = LocalEvaluation::PAR_TYPES.map { |backend| "black-scholes_test_#{backend}_r1" }
    ids.delete("black-scholes_test_hybrid_r1")
    ids.concat(%w[black-scholes_another_hybrid_r1 matmul_test_hybrid_r1])
    assert_raises(RuntimeError) { BenchmarkValidationBatch.canary_ids(ids, "test") }
  end

  def test_inheritance_changes_only_binding_and_not_measurement_settings
    original = { "state" => "frozen", "frozen_at" => "old", "proposed_sha256" => "old",
      "cells" => { "hybrid" => { "floydwarshall" => { "args" => ["-n", "10240"], "timeout_seconds" => 47 } } },
      "target_seconds" => { "measurements" => 3 }, "seed_sha256" => "seed" }
    inherited = BenchmarkValidationBatch.inherited_config(original,
      manifest_sha: "manifest", validation_sha: "validation", count: 660, seed_path: "/new/seed",
      baseline_path: "/old/config", baseline_sha: "baseline")
    assert_equal original.fetch("cells"), inherited.fetch("cells")
    assert_equal original.fetch("target_seconds"), inherited.fetch("target_seconds")
    assert_equal "seed", inherited.fetch("seed_sha256")
    assert_equal "manifest", inherited.fetch("manifest_sha256")
    assert_equal "validation", inherited.fetch("validation_results_sha256")
    assert_equal "proposed", inherited.fetch("state")
    refute inherited.key?("frozen_at")
    refute inherited.key?("proposed_sha256")
    assert_equal "frozen", original.fetch("state")
    inherited["cells"]["hybrid"]["floydwarshall"]["args"] << "changed"
    assert_equal ["-n", "10240"], original.dig("cells", "hybrid", "floydwarshall", "args")
  end

  def test_source_root_rebinding_preserves_accepted_evidence_and_records
    evidence = { "original_source" => { "root" => "/home/generated", "commit" => "original" },
      "corrected_source" => { "root" => "/home/generated", "commit" => "corrected" },
      "artifacts" => { "corrections_jsonl_sha256" => "records", "correction_ids_sha256" => "ids" },
      "evidence" => { "review_sha256" => "review" }, "compile_validation" => { "records" => 174 } }
    rebound = BenchmarkValidationBatch.rebound_evidence(evidence, root: "/tmp/execution",
      original_path: "/home/final/manifest.yaml", original_sha: "original-manifest")
    assert_equal "/tmp/execution", rebound.dig("original_source", "root")
    assert_equal "/tmp/execution", rebound.dig("corrected_source", "root")
    assert_equal "original", rebound.dig("original_source", "commit")
    assert_equal "corrected", rebound.dig("corrected_source", "commit")
    assert_equal evidence.fetch("artifacts"), rebound.fetch("artifacts")
    assert_equal evidence.fetch("evidence"), rebound.fetch("evidence")
    assert_equal evidence.fetch("compile_validation"), rebound.fetch("compile_validation")
    assert_equal "/home/generated", evidence.dig("original_source", "root")
    assert_equal "original-manifest", rebound.dig("execution_root_binding", "accepted_manifest_sha256")
  end

  def test_eligibility_requires_every_validation_stage
    result = ValidationResult.new("matmul", "test", "mpi", 1)
    BenchmarkValidationBatch::STAGES.each { |stage| result.public_send("#{stage}=", true) }
    assert BenchmarkValidationBatch.fully_valid?(result)
    result.validation_build = false
    refute BenchmarkValidationBatch.fully_valid?(result)
  end

  def test_unresolved_revalidation_failure_blocks_benchmark_preparation
    with_failure_evidence do |_root, _path, _data, options|
      assert_raises(RuntimeError) { BenchmarkValidationBatch.approved_failures(nil, **options) }
    end
  end

  def test_explicit_failure_is_retained_and_excluded_without_changing_results
    with_failure_evidence do |_root, path, _data, options|
      before = Marshal.dump(options.fetch(:corrected_results))
      failures = BenchmarkValidationBatch.approved_failures(path, **options)
      assert_equal ["nbody_test_hybrid_r1"], failures.keys
      assert_equal before, Marshal.dump(options.fetch(:corrected_results))
      ids = %w[matmul_test_mpi_r1 nbody_test_hybrid_r1 roomsim_test_omp_r1]
      partition = BenchmarkValidationBatch.eligible_partition(ids, ids.take(2), failures.keys)
      assert_equal %w[matmul_test_mpi_r1 roomsim_test_omp_r1], partition.fetch(:valid)
      assert_equal ["matmul_test_mpi_r1"], partition.fetch(:corrected)
      assert_equal ["roomsim_test_omp_r1"], partition.fetch(:unchanged)
    end
  end

  def test_disposition_cannot_hide_an_additional_failure_or_exclude_a_passing_program
    with_failure_evidence do |_root, path, _data, options|
      passing = options.fetch(:corrected_results).first
      passing.output_comparison = false
      assert_raises(RuntimeError) { BenchmarkValidationBatch.approved_failures(path, **options) }
      passing.output_comparison = true
      options.fetch(:corrected_results).last.output_comparison = true
      assert_raises(RuntimeError) { BenchmarkValidationBatch.approved_failures(path, **options) }
    end
  end

  def test_disposition_binds_validation_source_and_review_evidence
    with_failure_evidence do |root, path, data, options|
      original = File.binread(path)
      data["corrected_source_commit"] = "another-commit"
      File.write(path, JSON.generate(data))
      assert_raises(RuntimeError) { BenchmarkValidationBatch.approved_failures(path, **options) }
      File.write(path, original)
      File.write(File.join(root, "review.json"), "changed")
      assert_raises(RuntimeError) { BenchmarkValidationBatch.approved_failures(path, **options) }
    end
  end

  def test_disposition_requires_user_resolution_and_matching_failure_stage
    with_failure_evidence do |_root, path, data, options|
      data.fetch("records").first.fetch("authorization")["source"] = "automatic_retry"
      File.write(path, JSON.generate(data))
      assert_raises(RuntimeError) { BenchmarkValidationBatch.approved_failures(path, **options) }
      data.fetch("records").first.fetch("authorization")["source"] = "user"
      data.fetch("records").first["failed_stage"] = "validation_build"
      File.write(path, JSON.generate(data))
      assert_raises(RuntimeError) { BenchmarkValidationBatch.approved_failures(path, **options) }
    end
  end

  def test_failed_validation_evidence_cannot_change_after_disposition
    with_failure_evidence do |root, path, _data, options|
      File.write(File.join(root, "validation/nbody_test_hybrid_r1/validation_out_stdout.log"), "changed")
      assert_raises(RuntimeError) { BenchmarkValidationBatch.approved_failures(path, **options) }
    end
  end

  def test_output_contract_failure_is_distinct_and_still_requires_explicit_resolution
    with_failure_evidence do |_root, path, data, options|
      entry = data.fetch("records").first
      entry["classification"] = "pre_existing_output_contract_failure"
      entry["reason"] = "Uncoordinated MPI output breaks the required result format; no numerical error established"
      entry.fetch("authorization")["statement"] = "Retain the output-contract validation failure without parser or source changes"
      File.write(path, JSON.generate(data))
      failures = BenchmarkValidationBatch.approved_failures(path, **options)
      assert_equal "pre_existing_output_contract_failure", failures.values.first.fetch("classification")
      refute BenchmarkValidationBatch.fully_valid?(options.fetch(:corrected_results).last)
      entry["classification"] = "ignore_output_and_assume_valid"
      File.write(path, JSON.generate(data))
      assert_raises(RuntimeError) { BenchmarkValidationBatch.approved_failures(path, **options) }
    end
  end

  def test_unchanged_or_originally_invalid_programs_cannot_enter_exclusion_partition
    assert_raises(RuntimeError) { BenchmarkValidationBatch.eligible_partition(%w[a b], %w[a], %w[b]) }
    assert_raises(RuntimeError) { BenchmarkValidationBatch.eligible_partition(%w[a], %w[a b], %w[b]) }
  end

  private

  def with_failure_evidence
    Dir.mktmpdir("benchmark-failure-disposition-", "/tmp") do |root|
      manifest_path = File.join(root, "evaluation_manifest.yaml")
      File.write(manifest_path, "immutable manifest\n")
      manifest = Struct.new(:path).new(manifest_path)
      passing = ValidationResult.new("matmul", "test", "mpi", 1)
      failing = ValidationResult.new("nbody", "test", "hybrid", 1)
      [passing, failing].each do |result|
        BenchmarkValidationBatch::STAGES.each { |stage| result.public_send("#{stage}=", true) }
      end
      failing.output_comparison = false
      directory = File.join(root, "validation", failing.id_string)
      FileUtils.mkdir_p(directory)
      metadata_path = File.join(directory, "validation_metadata.yaml")
      File.write(metadata_path, YAML.dump({ "id" => failing.id_string,
        "manifest_sha256" => LocalEvaluation.sha256_file(manifest_path),
        "stages" => BenchmarkValidationBatch::STAGES.to_h { |stage| [stage, failing.public_send(stage)] } }))
      stdout_path = File.join(directory, "validation_out_stdout.log")
      File.write(stdout_path, "wrong numerical result\n")
      review_path = File.join(root, "review.json")
      File.write(review_path, JSON.generate({ "pre_existing_race" => true }))
      data = { "schema_version" => 1, "original_source_commit" => "original", "corrected_source_commit" => "corrected",
        "corrected_validation_manifest_sha256" => LocalEvaluation.sha256_file(manifest_path),
        "records" => [{ "program_id" => failing.id_string, "decision" => "fail_validation",
          "classification" => "pre_existing_correctness_failure", "failed_stage" => "output_comparison",
          "reason" => "Unchanged unsynchronized in-place CUDA kernel",
          "authorization" => { "source" => "user", "statement" => "Count as failing validation" },
          "validation_evidence" => { "metadata_sha256" => LocalEvaluation.sha256_file(metadata_path),
            "stdout_sha256" => LocalEvaluation.sha256_file(stdout_path) },
          "static_review" => { "model" => "gpt-6.1-sol", "path" => review_path,
            "sha256" => LocalEvaluation.sha256_file(review_path) } }] }
      path = File.join(root, "failures.json")
      File.write(path, JSON.generate(data))
      yield root, path, data, { corrected_manifest: manifest, corrected_results: [passing, failing],
        original_commit: "original", corrected_commit: "corrected" }
    end
  end
end
