require "minitest/autorun"
require "tmpdir"
require_relative "../lib/local_evaluation"

class LocalEvaluationStatusReporterTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("local-evaluation-status", "/tmp")
  end

  def teardown
    FileUtils.chmod_R(0o700, @tmp) if File.directory?(@tmp)
    FileUtils.remove_entry(@tmp) if File.directory?(@tmp)
  end

  def test_reports_complete_phase_state_and_cross_artifact_consistency
    id = "matmul_status-model_omp_r1"
    write_manifest(id)
    manifest_digest = LocalEvaluation.sha256_file(File.join(@tmp, "evaluation_manifest.yaml"))
    LocalEvaluation.atomic_yaml(File.join(@tmp, "preflight.yaml"), {
      "checked_at" => "2026-08-18T12:00:00+02:00",
      "manifest_sha256" => manifest_digest,
      "free_disk_bytes" => 64 * LocalEvaluation::GIBIBYTE
    })
    %w[validation benchmark].each do |phase|
      LocalEvaluation.atomic_yaml(File.join(@tmp, phase, "preflight.yaml"), { "checked_at" => "now" })
    end

    validation = ValidationResult.new("matmul", "status-model", "omp", 1)
    validation.basic_para = true
    validation.validation_build = true
    validation.validation_run = true
    validation.internal_validation = true
    validation.output_comparison = true
    LocalEvaluation.atomic_yaml(File.join(@tmp, "validation", "all_validation_results.yaml"), [validation])

    config_path = File.join(@tmp, "benchmark_config.yaml")
    LocalEvaluation.atomic_yaml(config_path, {
      "schema_version" => LocalEvaluation::SCHEMA_VERSION,
      "state" => "frozen",
      "validation_complete" => true,
      "cells" => complete_cells
    })
    config_digest = LocalEvaluation.sha256_file(config_path)
    LocalEvaluation.atomic_write("#{config_path}.sha256", "#{config_digest}\n")
    File.chmod(0o444, config_path)

    metrics = Array.new(BENCHMARK_COUNT) { |index| { "time" => index + 1.0 } }
    LocalEvaluation.atomic_yaml(File.join(@tmp, "benchmark", BENCHMARK_FULL_RESULTS_FN), id => [true, metrics])
    LocalEvaluation.atomic_yaml(File.join(@tmp, "benchmark", BENCHMARK_RESULTS_FN), id => true)
    LocalEvaluation.atomic_yaml(File.join(@tmp, "benchmark", "benchmark_run_metadata.yaml"), {
      "configuration_sha256" => config_digest
    })
    LocalEvaluation.atomic_yaml(File.join(@tmp, "benchmark", id, "benchmark_metadata.yaml"), {
      "configuration_sha256" => config_digest
    })

    aggregate = AggregateEvaluation.new("matmul", "status-model", "omp", 1)
    aggregate.validation_status = VS_FULLY_VALID
    aggregate.benchmark_success = true
    aggregate.benchmark_times = metrics.map { |entry| entry["time"] }
    aggregate.benchmark_median_time = 3.0
    aggregate_path = File.join(@tmp, "aggregate_results.yaml")
    LocalEvaluation.atomic_yaml(aggregate_path, id => aggregate)
    LocalEvaluation.atomic_write(File.join(@tmp, "aggregate_results.csv"), "header\n")
    LocalEvaluation.atomic_yaml(File.join(@tmp, "aggregate_metadata.yaml"), {
      "complete" => true,
      "warning_records" => 2,
      "refresh_scope" => "full",
      "aggregate_results_sha256" => LocalEvaluation.sha256_file(aggregate_path),
      "manifest_sha256" => manifest_digest,
      "validation_results_sha256" => LocalEvaluation.sha256_file(File.join(@tmp, "validation", "all_validation_results.yaml")),
      "benchmark_full_results_sha256" => LocalEvaluation.sha256_file(File.join(@tmp, "benchmark", BENCHMARK_FULL_RESULTS_FN)),
      "benchmark_config_sha256" => config_digest
    })
    LocalEvaluation.atomic_write(File.join(@tmp, "scored_results.selection-0123456789ab.csv"), "score\n")

    output = capture_io { LocalEvaluation::StatusReporter.new(@tmp).run }.first

    assert_includes output, "preflight: passed"
    assert_includes output, "manifest-matched"
    assert_includes output, "phase preflights: validation=passed; benchmark=passed"
    assert_includes output, "validation: 1/1 complete; 0 pending; 1 fully valid"
    assert_includes output, "comparison=1/1"
    assert_includes output, "calibration: frozen; 44/44 cells present; 44/44 resolved"
    assert_includes output, "resolved=33"
    assert_includes output, "wall_limited=11"
    assert_includes output, "digest sidecar=matches; read-only=true"
    assert_includes output, "benchmark: 1/1 fully-valid programs attempted; 0 pending; 1 successful; 0 failed"
    assert_includes output, "canonical=consistent; config digest matches frozen config; per-ID metadata issues=0"
    assert_includes output, "aggregate: 1/1 records; complete=true; missing=0; extra=0; CSV=present; warning records=2"
    assert_includes output, "aggregate freshness: scope=full; aggregate_results=matches; manifest=matches; pipeline_amendment=not-recorded; source_correction_amendment=not-recorded; validation=matches; benchmark_full=matches; benchmark_config=matches"
    assert_includes output, "selection-specific artifacts=1"

    aggregate.benchmark_median_time = 999.0
    LocalEvaluation.atomic_yaml(aggregate_path, id => aggregate)
    stale_output = capture_io { LocalEvaluation::StatusReporter.new(@tmp).run }.first
    assert_includes stale_output, "aggregate_results=MISMATCH"
  end

  def test_reports_partial_validation_calibration_and_benchmark_artifacts
    first = "matmul_status-one_omp_r1"
    second = "matmul_status-two_omp_r1"
    write_manifest(first, second)
    result = ValidationResult.new("matmul", "status-one", "omp", 1)
    result.basic_para = true
    LocalEvaluation.atomic_yaml(File.join(@tmp, "validation", "all_validation_results.yaml"), [result])
    LocalEvaluation.atomic_yaml(File.join(@tmp, "benchmark_config.proposed.yaml"), {
      "state" => "proposed",
      "validation_complete" => false,
      "cells" => { "omp" => { "matmul" => { "status" => "pending", "resolved" => false } } }
    })
    LocalEvaluation.atomic_yaml(File.join(@tmp, "benchmark", BENCHMARK_RESULTS_FN), first => false)

    output = capture_io { LocalEvaluation::StatusReporter.new(@tmp).run }.first

    assert_includes output, "preflight: not recorded"
    assert_includes output, "validation: 1/2 complete; 1 pending; 0 fully valid"
    assert_includes output, "parallelization=1/1"
    assert_includes output, "build=0/1"
    assert_includes output, "calibration: proposed; 1/44 cells present; 0/44 resolved"
    assert_includes output, "missing=43"
    assert_includes output, "pending=1"
    assert_includes output, "benchmark configuration: proposed (review and freeze required)"
    assert_includes output, "canonical=full results missing"
    assert_includes output, "aggregate: absent"
  end

  def test_unreadable_validation_state_is_reported_without_aborting_status
    id = "matmul_status-model_omp_r1"
    write_manifest(id)
    LocalEvaluation.atomic_write(File.join(@tmp, "validation", "all_validation_results.yaml"), "--- !invalid [\n")

    output = capture_io { LocalEvaluation::StatusReporter.new(@tmp).run }.first

    assert_includes output, "artifact warning:"
    assert_includes output, "all_validation_results.yaml is unreadable"
    assert_includes output, "validation: 0/1 complete; 1 pending; 0 fully valid"
  end

  def test_benchmark_failure_record_shapes_are_reported_as_canonical_or_legacy_valid
    id = "matmul_status-model_omp_r1"
    write_manifest(id)
    reporter = LocalEvaluation::StatusReporter.new(@tmp)

    assert reporter.send(:full_record_valid?, [false, {}])
    assert reporter.send(:full_record_valid?, [false, []])
    refute reporter.send(:full_record_valid?, [false, { "partial" => true }])
    refute reporter.send(:full_record_valid?, [true, {}])
    metrics = Array.new(BENCHMARK_COUNT) { { "time" => 1.0 } }
    assert reporter.send(:full_record_valid?, [true, metrics])
    zero_metrics = Array.new(BENCHMARK_COUNT) { { "time" => 0.0 } }
    refute reporter.send(:full_record_valid?, [true, zero_metrics])
  end

  private

  def write_manifest(*ids)
    runs = ids.to_h do |id|
      info = LocalEvaluation.parse_run_id(id)
      [id, info.merge("batch" => "20260101-000000", "source_path" => File.join(@tmp, "source", id))]
    end
    LocalEvaluation.atomic_yaml_with_digest(File.join(@tmp, "evaluation_manifest.yaml"), {
      "schema_version" => LocalEvaluation::SCHEMA_VERSION,
      "batches" => ["20260101-000000"],
      "run_count" => runs.size,
      "runs" => runs
    })
  end

  def complete_cells
    LocalEvaluation::PAR_TYPES.to_h do |par_type|
      [par_type, LocalEvaluation::BENCHMARKS.to_h do |benchmark|
        status = par_type == "omp" ? "wall_limited" : "resolved"
        [benchmark, { "status" => status, "resolved" => true }]
      end]
    end
  end
end
