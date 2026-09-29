# frozen_string_literal: true

require "minitest/autorun"
require_relative "../tools/timing_audit/bin/benchmark_validation_batch"

class BenchmarkValidationBatchTest < Minitest::Test
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
end
