# frozen_string_literal: true

require "minitest/autorun"
require_relative "../tools/timing_audit/bin/export_benchmark_batch"

class BenchmarkBatchExportTest < Minitest::Test
  def metadata
    { "run" => { "benchmark" => "matmul", "model" => "test", "par_type" => "mpi", "run" => 1, "batch" => "batch" },
      "args" => ["-n", "6144"], "timeout_seconds" => 77, "configuration_sha256" => "a" * 64,
      "pipeline_amendment_sha256" => nil, "wall_seconds" => [], "warmup_wall_seconds" => 1.0,
      "all_execution_wall_seconds" => [1.0], "executions" => [{ "timed_out" => true }],
      "success" => false, "metrics" => [] }
  end

  def test_uncorrected_metadata_round_trips_exactly_without_null_optional_schema_field
    source = metadata
    exported = BenchmarkBatchExport.record("test", source, nil)
    refute exported.fetch("timing_fixed")
    assert_nil exported.fetch("timing_correction")
    refute exported.key?("pipeline_amendment_sha256")
    assert_equal YAML.dump(source), YAML.dump(BenchmarkBatchExport.native_metadata(exported, source.fetch("run"), source.keys))
  end

  def test_corrected_metadata_and_both_source_links_round_trip
    source = metadata.merge("timing_fixed" => true, "source_correction_amendment_sha256" => "b" * 64,
      "original_source_commit" => "c" * 40, "corrected_source_commit" => "d" * 40,
      "original_source_digest" => "e" * 64, "corrected_source_digest" => "f" * 64,
      "timing_fix_issue_categories" => ["rank_local_timing"], "timing_fix_changed_paths" => ["batch/test/a.cpp"],
      "build_success" => true, "build_error" => nil, "temporary_workspace" => "local /tmp; removed after attempt",
      "staged_source_content_sha256" => "1" * 64)
    correction = { "original_source_url" => "https://github.com/test/tree/original/batch/test", "corrected_source_url" => "https://github.com/test/tree/corrected/batch/test" }
    exported = BenchmarkBatchExport.record("test", source, correction)
    assert exported.fetch("timing_fixed")
    assert_equal correction.fetch("original_source_url"), exported.dig("timing_correction", "original_source", "url")
    assert_equal correction.fetch("corrected_source_url"), exported.dig("timing_correction", "corrected_source", "url")
    assert_equal YAML.dump(source), YAML.dump(BenchmarkBatchExport.native_metadata(exported, source.fetch("run"), source.keys))
    assert_raises(RuntimeError) { BenchmarkBatchExport.record("test", source, nil) }
  end

  def test_unknown_native_fields_are_not_silently_lost
    source = metadata.merge("new_field" => 123)
    exported = BenchmarkBatchExport.record("test", source, nil)
    assert_raises(RuntimeError) { BenchmarkBatchExport.native_metadata(exported, source.fetch("run"), source.keys) }
  end

  def test_failure_categories_preserve_crash_and_resource_causes_over_later_timeout
    assert_equal "timeout", BenchmarkBatchExport.failure_category(metadata, "Command timed out")
    assert_equal "program_crash", BenchmarkBatchExport.failure_category(metadata, "Segmentation fault\nCommand timed out")
    assert_equal "file_size_limit", BenchmarkBatchExport.failure_category(metadata, "File size limit exceeded")
    assert_nil BenchmarkBatchExport.failure_category(metadata.merge("success" => true), "")
  end

  def test_amended_pipeline_digest_round_trips
    source = metadata.merge("pipeline_amendment_sha256" => "a" * 64)
    exported = BenchmarkBatchExport.record("test", source, nil)
    assert_equal "a" * 64, exported.fetch("pipeline_amendment_sha256")
    assert_equal YAML.dump(source), YAML.dump(BenchmarkBatchExport.native_metadata(exported, source.fetch("run"), source.keys))
  end

  def test_scoped_refresh_guards_records_evidence_and_id_set
    before = { "affected" => { "success" => false }, "unrelated" => { "success" => true } }
    after = before.merge("affected" => { "success" => true })
    evidence = { "affected" => { "sha" => "old" }, "unrelated" => { "sha" => "same" } }
    changed = evidence.merge("affected" => { "sha" => "new" })
    assert_equal 1, BenchmarkBatchExport.verify_refresh_scope!(before, after, evidence, changed, ["affected"])
    assert_raises(RuntimeError) do
      BenchmarkBatchExport.verify_refresh_scope!(before, after.merge("unrelated" => {}), evidence, changed, ["affected"])
    end
    assert_raises(RuntimeError) do
      BenchmarkBatchExport.verify_refresh_scope!(before, after, evidence, changed.merge("unrelated" => {}), ["affected"])
    end
    assert_raises(RuntimeError) do
      BenchmarkBatchExport.verify_refresh_scope!(before, after.merge("extra" => {}), evidence, changed, ["affected"])
    end
    assert_raises(RuntimeError) do
      BenchmarkBatchExport.verify_refresh_scope!(before, after, evidence, changed, ["missing"])
    end
    assert_raises(RuntimeError) do
      BenchmarkBatchExport.verify_refresh_scope!(before, after, evidence, changed, ["affected", "affected"])
    end
  end

  def test_duplicate_exported_ids_are_rejected
    assert_raises(RuntimeError) { BenchmarkBatchExport.index_unique([{ "id" => "a" }, { "id" => "a" }]) }
    assert_equal ["a"], BenchmarkBatchExport.index_unique([{ "id" => "a" }]).keys
  end
end
