require "minitest/autorun"
require "tmpdir"
require_relative "../lib/local_evaluation"

class LocalEvaluationOutputIntegrityTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("local-evaluation-output-integrity", "/tmp")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.directory?(@tmp)
  end

  def test_local_agent_token_summary_is_parsed
    pipeline = metadata_pipeline
    result = parse_metadata(pipeline, "local", <<~OUTPUT)
      Changes   +89 -25
      Duration  6m 25s
      Tokens    ↑ 729.8k • ↓ 9.7k • 527.7k (cached)
    OUTPUT

    assert_equal 729_800.0, result.input_tokens
    assert_equal 9_700.0, result.output_tokens
    assert_equal 527_700.0, result.cached_tokens
    assert_equal 739_500.0, result.total_tokens
  end

  def test_copilot_multi_model_token_rows_are_summed
    pipeline = metadata_pipeline
    result = parse_metadata(pipeline, "copilot", <<~OUTPUT)
      API time spent: 1m 2.5s
      Total code changes: +8 -5
       gemini-3-pro-preview    1.1m in, 21.7k out, 884.6k cached
       claude-haiku-4.5        75.6k in, 2.3k out, 54.5k cached
       claude-sonnet-4.5       950.7k in, 9.8k out, 919.9k cached
    OUTPUT

    assert_equal 2_126_300.0, result.input_tokens
    assert_equal 33_800.0, result.output_tokens
    assert_equal 1_859_000.0, result.cached_tokens
    assert_equal 2_160_100.0, result.total_tokens
  end

  def test_missing_api_warning_is_present_and_idempotent
    pipeline = metadata_pipeline
    output = "Changes +14 -7\n[Usage] billed (input: 8301, output: 2722, cache_read: 57335)\n"

    2.times { parse_metadata(pipeline, "pi", output) }

    warnings = pipeline.instance_variable_get(:@warnings).fetch("pi")
    api_warnings = warnings.grep(/API/i)
    assert_equal 1, api_warnings.size
    assert_equal warnings.uniq, warnings
  end

  def test_dependency_scan_preserves_historical_whitelist_and_equivalence_classes
    source = File.join(@tmp, "dependencies")
    benchmark_dir = File.join(source, "matmul")
    FileUtils.mkdir_p(benchmark_dir)
    File.write(File.join(benchmark_dir, "CMakeLists.txt"), <<~CMAKE)
      add_executable(matmul matmul.cpp)
      target_link_libraries(matmul
        PRIVATE
        CUDA::cudart
        ${OpenMP_CXX_LIBRARIES}
        CUDA::cublas
        -lcublas
        CUDA::cusolver
        ${CUSTOM_ACCEL_LIBRARY}
        -lcustom
      )
    CMAKE

    pipeline = LocalEvaluation::AggregatePipeline.allocate
    pipeline.instance_variable_set(:@warnings, {})
    dependencies = pipeline.send(:dependencies_for, "dependency-test", {
      "source_path" => source,
      "benchmark" => "matmul"
    })

    assert_equal ["${CUSTOM_ACCEL_LIBRARY}", "-lcustom", "cublas", "cusolver"], dependencies
  end

  def test_filtered_scoring_uses_selection_outputs_without_touching_canonical_files
    fast_id = "matmul_model-fast_omp_r1"
    slow_id = "matmul_model-slow_omp_r1"
    write_manifest(fast_id, slow_id)
    write_aggregate(
      fast_id => aggregate_result("model-fast", 100.0),
      slow_id => aggregate_result("model-slow", 400.0)
    )

    canonical_distribution = File.join(@tmp, "local_scoring_distributions.csv")
    canonical_template = File.join(@tmp, "local_scoring_thresholds.proposed.csv")
    canonical_scored_csv = File.join(@tmp, "scored_results.csv")
    canonical_scored_yaml = File.join(@tmp, "scored_results.yaml")
    sentinels = {
      canonical_distribution => "full distribution\n",
      canonical_template => "full template\n",
      canonical_scored_csv => "full scores\n",
      canonical_scored_yaml => "full scores yaml\n"
    }
    sentinels.each { |path, content| File.write(path, content) }

    LocalEvaluation::ScoringPipeline.prepare(run_dir: @tmp, filter: "model-fast")

    thresholds = File.join(@tmp, "thresholds.csv")
    File.write(thresholds, <<~CSV)
      bench,type,top,great,good,reviewed
      matmul,omp,120,200,300,true
    CSV
    LocalEvaluation::ScoringPipeline.score(run_dir: @tmp, thresholds_path: thresholds,
                                            filter: "model-fast")

    sentinels.each { |path, content| assert_equal content, File.read(path) }
    assert_single_selection_file("local_scoring_distributions.selection-????????????.csv")
    assert_single_selection_file("local_scoring_thresholds.selection-????????????.proposed.csv")
    assert_single_selection_file("scored_results.selection-????????????.csv")
    assert_single_selection_file("scored_results.selection-????????????.yaml")
  end

  def test_scoring_readiness_requires_complete_aggregate_validation_and_benchmarks
    first_id = "matmul_model-one_omp_r1"
    second_id = "matmul_model-two_omp_r1"
    write_manifest(first_id, second_id)
    write_aggregate(first_id => aggregate_result("model-one", 100.0))

    error = assert_raises(RuntimeError) do
      LocalEvaluation::ScoringPipeline.prepare(run_dir: @tmp, dry_run: true)
    end
    assert_match(/aggregate|manifest|missing|complete/i, error.message)

    pending_validation = AggregateEvaluation.new("matmul", "model-two", "omp", 1)
    write_aggregate(
      first_id => aggregate_result("model-one", 100.0),
      second_id => pending_validation
    )
    error = assert_raises(RuntimeError) do
      LocalEvaluation::ScoringPipeline.prepare(run_dir: @tmp, dry_run: true)
    end
    assert_match(/validation|complete|pending/i, error.message)

    pending_benchmark = aggregate_result("model-two", nil, benchmark_success: nil)
    write_aggregate(
      first_id => aggregate_result("model-one", 100.0),
      second_id => pending_benchmark
    )
    error = assert_raises(RuntimeError) do
      LocalEvaluation::ScoringPipeline.prepare(run_dir: @tmp, dry_run: true)
    end
    assert_match(/benchmark|complete|pending/i, error.message)

    thresholds = File.join(@tmp, "thresholds.csv")
    File.write(thresholds, "bench,type,top,great,good,reviewed\nmatmul,omp,120,200,300,true\n")
    assert_raises(RuntimeError) do
      LocalEvaluation::ScoringPipeline.score(run_dir: @tmp, thresholds_path: thresholds, dry_run: true)
    end
  end

  def test_scoring_requires_reviewed_column_and_finite_thresholds
    id = "matmul_model_omp_r1"
    write_manifest(id)
    write_aggregate(id => aggregate_result("model", 100.0))
    thresholds = File.join(@tmp, "thresholds.csv")

    File.write(thresholds, "bench,type,top,great,good\nmatmul,omp,120,200,300\n")
    error = assert_raises(RuntimeError) do
      LocalEvaluation::ScoringPipeline.score(run_dir: @tmp, thresholds_path: thresholds, dry_run: true)
    end
    assert_match(/reviewed/i, error.message)

    %w[Infinity NaN].each do |non_finite|
      File.write(thresholds, <<~CSV)
        bench,type,top,great,good,reviewed
        matmul,omp,120,200,#{non_finite},true
      CSV
      error = assert_raises(RuntimeError) do
        LocalEvaluation::ScoringPipeline.score(run_dir: @tmp, thresholds_path: thresholds, dry_run: true)
      end
      assert_match(/finite|numeric/i, error.message)
    end
  end

  def test_scoring_rejects_zero_times
    zero_id = "matmul_model-zero_omp_r1"
    two_id = "matmul_model-two_omp_r1"
    four_id = "matmul_model-four_omp_r1"
    write_manifest(zero_id, two_id, four_id)
    write_aggregate(
      zero_id => aggregate_result("model-zero", 0.0),
      two_id => aggregate_result("model-two", 2.0),
      four_id => aggregate_result("model-four", 4.0)
    )

    error = assert_raises(RuntimeError) do
      LocalEvaluation::ScoringPipeline.prepare(run_dir: @tmp)
    end
    assert_match(/nonpositive or invalid benchmark time/, error.message)
    refute File.exist?(File.join(@tmp, "local_scoring_distributions.csv"))
  end

  def test_scoring_rejects_aggregate_after_benchmark_retry_changes_full_results
    id = "matmul_model-retried_omp_r1"
    write_manifest(id)
    benchmark_path = File.join(@tmp, "benchmark", BENCHMARK_FULL_RESULTS_FN)
    LocalEvaluation.atomic_yaml(benchmark_path, id => [true, [{ "time" => 100.0 }]])
    write_aggregate(id => aggregate_result("model-retried", 100.0))

    LocalEvaluation.atomic_yaml(benchmark_path, id => [true, [{ "time" => 75.0 }]])
    error = assert_raises(RuntimeError) do
      LocalEvaluation::ScoringPipeline.prepare(run_dir: @tmp, dry_run: true)
    end
    assert_match(/benchmark full results|stale|digest|rerun aggregate/i, error.message)
  end

  def test_scoring_rejects_tampered_aggregate_results
    id = "matmul_model-tampered_omp_r1"
    write_manifest(id)
    write_aggregate(id => aggregate_result("model-tampered", 100.0))

    LocalEvaluation.atomic_yaml(File.join(@tmp, "aggregate_results.yaml"),
                                id => aggregate_result("model-tampered", 1.0))
    error = assert_raises(RuntimeError) do
      LocalEvaluation::ScoringPipeline.prepare(run_dir: @tmp, dry_run: true)
    end
    assert_match(/aggregate results|tampered|digest/i, error.message)
  end

  def test_partial_refresh_refuses_canonical_scoring_but_allows_its_fresh_selection
    first_id = "matmul_model-first_omp_r1"
    second_id = "matmul_model-second_omp_r1"
    write_manifest(first_id, second_id)
    write_aggregate({
      first_id => aggregate_result("model-first", 100.0),
      second_id => aggregate_result("model-second", 200.0)
    }, refresh_scope: "partial", refreshed_ids: [first_id])

    error = assert_raises(RuntimeError) do
      LocalEvaluation::ScoringPipeline.prepare(run_dir: @tmp, dry_run: true)
    end
    assert_match(/full-corpus|full.*rebuild/i, error.message)

    LocalEvaluation::ScoringPipeline.prepare(run_dir: @tmp, exact_id: first_id, dry_run: true)
    error = assert_raises(RuntimeError) do
      LocalEvaluation::ScoringPipeline.prepare(run_dir: @tmp, exact_id: second_id, dry_run: true)
    end
    assert_match(/not refreshed|stale/i, error.message)
  end

  def test_diff_scan_bounds_huge_files_and_never_follows_symlinked_trees
    id = "matmul_model-pathological_omp_r1"
    benchmarks = File.join(@tmp, "benchmarks")
    original = File.join(benchmarks, "matmul")
    source = File.join(@tmp, "sources", id)
    generated = File.join(source, "matmul")
    outside = File.join(@tmp, "outside")
    [original, generated, outside].each { |path| FileUtils.mkdir_p(path) }
    File.write(File.join(original, "main.cpp"), "int main() { return 0; }\n")
    File.write(File.join(generated, "main.cpp"), "x" * (LocalEvaluation::AggregatePipeline::MAX_DIFF_FILE_BYTES + 1))
    File.write(File.join(outside, "unbounded.cpp"), "outside\n")
    File.symlink(outside, File.join(generated, "linked-tree"))

    write_manifest(id, benchmarks_root: benchmarks)
    pipeline = LocalEvaluation::AggregatePipeline.allocate
    pipeline.instance_variable_set(:@manifest, LocalEvaluation::Manifest.new(@tmp))
    pipeline.instance_variable_set(:@warnings, {})
    result = AggregateEvaluation.new("matmul", "model-pathological", "omp", 1)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pipeline.send(:apply_diff_counts, id, {
      "benchmark" => "matmul", "source_path" => source
    }, result)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_nil result.code_additions
    assert_nil result.code_deletions
    assert_operator elapsed, :<, 2.0
    assert_match(/cap|skipped/i, pipeline.instance_variable_get(:@warnings).fetch(id).join(" "))

    File.write(File.join(generated, "main.cpp"), "int main() { return 1; }\n")
    safe_result = AggregateEvaluation.new("matmul", "model-pathological", "omp", 1)
    pipeline.send(:apply_diff_counts, id, {
      "benchmark" => "matmul", "source_path" => source
    }, safe_result)
    assert_equal 1, safe_result.code_additions
    assert_equal 1, safe_result.code_deletions
    assert_match(/symlink/i, pipeline.instance_variable_get(:@warnings).fetch(id).join(" "))
  end

  def test_aggregate_records_full_and_partial_rebuild_input_and_output_digests
    first_id = "matmul_model-first_omp_r1"
    second_id = "matmul_model-second_omp_r1"
    benchmarks = File.join(@tmp, "benchmarks")
    FileUtils.mkdir_p(File.join(benchmarks, "matmul"))
    File.write(File.join(benchmarks, "matmul", "CMakeLists.txt"), "add_executable(matmul main.cpp)\n")
    write_manifest(first_id, second_id, benchmarks_root: benchmarks)

    validations = [first_id, second_id].map do |id|
      info = LocalEvaluation.parse_run_id(id)
      result = ValidationResult.new(info["benchmark"], info["model"], info["par_type"], info["run"])
      result.output_comparison = true
      source = File.join(@tmp, "sources", id)
      FileUtils.mkdir_p(File.join(source, "matmul"))
      File.write(File.join(source, "timing.txt"), "Duration: 1.0 seconds\n")
      File.write(File.join(source, "output.txt"), "Total code changes: +1 -0\ntokens used\n10\n")
      File.write(File.join(source, "matmul", "CMakeLists.txt"), "add_executable(matmul main.cpp)\n")
      result
    end
    validation_path = File.join(@tmp, "validation", "all_validation_results.yaml")
    LocalEvaluation.atomic_yaml(validation_path, validations)
    benchmark_path = File.join(@tmp, "benchmark", BENCHMARK_FULL_RESULTS_FN)
    LocalEvaluation.atomic_yaml(benchmark_path, {
      first_id => [true, Array.new(BENCHMARK_COUNT) { { "time" => 1.0 } }], second_id => [false, []]
    })
    config_path = File.join(@tmp, "benchmark_config.yaml")
    LocalEvaluation.atomic_yaml(config_path, "state" => "frozen")

    LocalEvaluation::AggregatePipeline.new(run_dir: @tmp).run
    aggregate_path = File.join(@tmp, "aggregate_results.yaml")
    metadata = LocalEvaluation.load_yaml(File.join(@tmp, "aggregate_metadata.yaml"))
    assert_equal "full", metadata["refresh_scope"]
    assert_equal true, metadata["full_rebuild"]
    assert_equal [first_id, second_id].sort, metadata["refreshed_ids"]
    assert_equal LocalEvaluation.sha256_file(File.join(@tmp, "evaluation_manifest.yaml")), metadata["manifest_sha256"]
    assert_equal LocalEvaluation.sha256_file(validation_path), metadata["validation_results_sha256"]
    assert_equal LocalEvaluation.sha256_file(benchmark_path), metadata["benchmark_full_results_sha256"]
    assert_equal LocalEvaluation.sha256_file(config_path), metadata["benchmark_config_sha256"]
    assert_equal LocalEvaluation.sha256_file(aggregate_path), metadata["aggregate_results_sha256"]

    LocalEvaluation::AggregatePipeline.new(run_dir: @tmp, exact_id: first_id).run
    partial = LocalEvaluation.load_yaml(File.join(@tmp, "aggregate_metadata.yaml"))
    assert_equal "partial", partial["refresh_scope"]
    assert_equal false, partial["full_rebuild"]
    assert_equal [first_id], partial["refreshed_ids"]
    assert_equal 2, partial["record_count"]
    refute_nil partial["base_aggregate_sha256"]
  end

  def test_aggregation_rejects_duplicate_validation_and_incomplete_benchmark_state
    id = "matmul_model_omp_r1"
    write_manifest(id)
    info = LocalEvaluation.parse_run_id(id)
    validation = ValidationResult.new(info["benchmark"], info["model"], info["par_type"], info["run"])
    validation.output_comparison = true
    validation_path = File.join(@tmp, "validation", "all_validation_results.yaml")
    LocalEvaluation.atomic_yaml(validation_path, [validation, validation])
    pipeline = LocalEvaluation::AggregatePipeline.new(run_dir: @tmp)
    assert_match(/duplicate run ID/, assert_raises(RuntimeError) { pipeline.send(:load_validation) }.message)

    LocalEvaluation.atomic_yaml(validation_path, [validation])
    benchmark_path = File.join(@tmp, "benchmark", BENCHMARK_FULL_RESULTS_FN)
    LocalEvaluation.atomic_yaml(benchmark_path, id => [true, Array.new(BENCHMARK_COUNT - 1) { { "time" => 1.0 } }])
    assert_match(/Malformed benchmark result/, assert_raises(RuntimeError) { pipeline.send(:load_benchmarks) }.message)

    LocalEvaluation.atomic_yaml(benchmark_path, id => [true, Array.new(BENCHMARK_COUNT) { { "time" => 0.0 } }])
    assert_match(/Malformed benchmark result/, assert_raises(RuntimeError) { pipeline.send(:load_benchmarks) }.message)
  end

  private

  def metadata_pipeline
    pipeline = LocalEvaluation::AggregatePipeline.allocate
    pipeline.instance_variable_set(:@warnings, {})
    pipeline
  end

  def parse_metadata(pipeline, id, output)
    source = File.join(@tmp, id)
    FileUtils.mkdir_p(source)
    File.write(File.join(source, "timing.txt"), "Duration: 10.25 seconds\n")
    File.write(File.join(source, "output.txt"), output)
    result = AggregateEvaluation.new("matmul", id, "omp", 1)
    pipeline.send(:parse_agent_metadata, id, { "source_path" => source }, result)
    result
  end

  def write_manifest(*ids, benchmarks_root: nil)
    runs = ids.to_h do |id|
      info = LocalEvaluation.parse_run_id(id)
      [id, info.merge(
        "batch" => "20260101-000000",
        "source_path" => File.join(@tmp, "sources", id)
      )]
    end
    LocalEvaluation.atomic_yaml_with_digest(File.join(@tmp, "evaluation_manifest.yaml"), {
      "schema_version" => LocalEvaluation::SCHEMA_VERSION,
      "batches" => ["20260101-000000"],
      "run_count" => runs.size,
      "benchmarks_root" => benchmarks_root || File.join(@tmp, "benchmarks"),
      "runs" => runs
    })
  end

  def write_aggregate(results = nil, refresh_scope: "full", refreshed_ids: nil, **keyword_results)
    results ||= keyword_results
    refreshed_ids ||= results.keys
    validation_path = File.join(@tmp, "validation", "all_validation_results.yaml")
    LocalEvaluation.atomic_yaml(validation_path, []) unless File.file?(validation_path)
    aggregate_path = File.join(@tmp, "aggregate_results.yaml")
    LocalEvaluation.atomic_yaml(aggregate_path, results)
    manifest_path = File.join(@tmp, "evaluation_manifest.yaml")
    benchmark_path = File.join(@tmp, "benchmark", BENCHMARK_FULL_RESULTS_FN)
    config_path = File.join(@tmp, "benchmark_config.yaml")
    LocalEvaluation.atomic_yaml(File.join(@tmp, "aggregate_metadata.yaml"), {
      "schema_version" => 1,
      "manifest_sha256" => LocalEvaluation.sha256_file(manifest_path),
      "pipeline_amendment_sha256" => nil,
      "source_correction_amendment_sha256" => nil,
      "validation_results_sha256" => LocalEvaluation.sha256_file(validation_path),
      "benchmark_full_results_sha256" => File.file?(benchmark_path) ? LocalEvaluation.sha256_file(benchmark_path) : nil,
      "benchmark_config_sha256" => File.file?(config_path) ? LocalEvaluation.sha256_file(config_path) : nil,
      "aggregate_results_sha256" => LocalEvaluation.sha256_file(aggregate_path),
      "refresh_scope" => refresh_scope,
      "full_rebuild" => refresh_scope == "full",
      "refreshed_ids" => refreshed_ids,
      "record_count" => results.size
    })
  end

  def aggregate_result(model, time, benchmark_success: true)
    result = AggregateEvaluation.new("matmul", model, "omp", 1)
    result.validation_status = VS_FULLY_VALID
    result.validation_err_string = ""
    result.non_whitelisted_dependencies = []
    result.benchmark_success = benchmark_success
    if benchmark_success
      result.benchmark_times = [time]
      result.benchmark_median_time = time
    end
    result
  end

  def assert_single_selection_file(pattern)
    matches = Dir[File.join(@tmp, pattern)]
    assert_equal 1, matches.size, "expected one selection output matching #{pattern}, got #{matches.inspect}"
    assert_match(/\.selection-[0-9a-f]{12}\./, File.basename(matches.first))
  end
end
