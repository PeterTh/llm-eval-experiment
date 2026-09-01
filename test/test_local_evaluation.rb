require "minitest/autorun"
require "tmpdir"
require_relative "../lib/local_evaluation"

class LocalEvaluationTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("local-evaluation-test", "/tmp")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.directory?(@tmp)
  end

  def test_run_id_parses_from_known_benchmark_and_right_hand_suffix
    info = LocalEvaluation.parse_run_id("black-scholes_model_with.parts-xhigh_hybrid_r12")
    assert_equal "black-scholes", info["benchmark"]
    assert_equal "model_with.parts-xhigh", info["model"]
    assert_equal "hybrid", info["par_type"]
    assert_equal 12, info["run"]
    assert_raises(ArgumentError) { LocalEvaluation.parse_run_id("not-an-id") }
  end

  def test_manifest_discovers_runs_and_rejects_duplicates
    experiments = File.join(@tmp, "experiments")
    benchmarks = File.join(@tmp, "benchmarks")
    make_source(experiments, "20260101-000000", "matmul_model_omp_r1", "matmul")
    FileUtils.mkdir_p(File.join(benchmarks, "matmul"))
    manifest = LocalEvaluation::Manifest.create(experiments_root: experiments,
                                                run_dir: File.join(@tmp, "run"),
                                                benchmarks_root: benchmarks)
    assert_equal 1, manifest.runs.size
    assert_equal "20260101-000000", manifest.runs.values.first["batch"]
    manifest_sidecar = "#{manifest.path}.sha256"
    assert_equal LocalEvaluation.sha256_file(manifest.path), File.read(manifest_sidecar).strip
    assert_equal 0, File.stat(manifest.path).mode & 0o222
    assert_equal 0, File.stat(manifest_sidecar).mode & 0o222

    make_source(experiments, "20260102-000000", "matmul_model_omp_r1", "matmul")
    error = assert_raises(RuntimeError) do
      LocalEvaluation::Manifest.create(experiments_root: experiments,
                                       run_dir: File.join(@tmp, "duplicate-run"),
                                       benchmarks_root: benchmarks)
    end
    assert_match(/Duplicate run ID/, error.message)
  end

  def test_manifest_refuses_missing_malformed_and_mismatched_digest_sidecars
    path = File.join(@tmp, "evaluation_manifest.yaml")
    LocalEvaluation.atomic_yaml(path, { "schema_version" => LocalEvaluation::SCHEMA_VERSION, "runs" => {} })

    error = assert_raises(RuntimeError) { LocalEvaluation::Manifest.new(@tmp) }
    assert_match(/digest sidecar is missing/, error.message)

    LocalEvaluation.atomic_write("#{path}.sha256", "not-a-digest\n")
    error = assert_raises(RuntimeError) { LocalEvaluation::Manifest.new(@tmp) }
    assert_match(/digest sidecar is malformed/, error.message)

    LocalEvaluation.atomic_write("#{path}.sha256", "#{'0' * 64}\n")
    error = assert_raises(RuntimeError) { LocalEvaluation::Manifest.new(@tmp) }
    assert_match(/digest mismatch/, error.message)
  end

  def test_manifest_init_safely_replaces_an_orphan_sidecar_from_an_interrupted_init
    experiments = File.join(@tmp, "experiments")
    benchmarks = File.join(@tmp, "benchmarks")
    run_dir = File.join(@tmp, "run")
    make_source(experiments, "20260101-000000", "matmul_model_omp_r1", "matmul")
    FileUtils.mkdir_p(File.join(benchmarks, "matmul"))
    FileUtils.mkdir_p(run_dir)
    sidecar = File.join(run_dir, "evaluation_manifest.yaml.sha256")
    LocalEvaluation.atomic_write(sidecar, "#{'f' * 64}\n", mode: 0o444)

    manifest = LocalEvaluation::Manifest.create(experiments_root: experiments, run_dir: run_dir,
                                                benchmarks_root: benchmarks)
    assert_equal LocalEvaluation.sha256_file(manifest.path), File.read(sidecar).strip
    assert_equal 1, manifest.runs.size
  end

  def test_pipeline_amendment_authorizes_only_named_benchmark_and_full_downstream_rebuilds
    id = "matmul_model_omp_r1"
    other_id = "matmul_other_omp_r1"
    original = {
      "root" => @tmp,
      "sha256" => "a" * 64,
      "files" => { "pipeline.rb" => "b" * 64 }
    }
    amended_digest = Digest::SHA256.hexdigest("pipeline.rb\0#{'d' * 64}\0")
    amended = {
      "root" => @tmp,
      "sha256" => amended_digest,
      "files" => { "pipeline.rb" => "d" * 64 }
    }
    manifest_path = File.join(@tmp, "evaluation_manifest.yaml")
    LocalEvaluation.atomic_yaml_with_digest(manifest_path, {
      "schema_version" => LocalEvaluation::SCHEMA_VERSION,
      "runs" => { id => {}, other_id => {} },
      "pipeline_source" => original
    })
    manifest = LocalEvaluation::Manifest.new(@tmp)
    amendment_path = LocalEvaluation::PipelineAmendment.path_for(@tmp)
    LocalEvaluation.atomic_yaml_with_digest(amendment_path, {
      "schema_version" => LocalEvaluation::SCHEMA_VERSION,
      "created_at" => Time.now.iso8601,
      "manifest_sha256" => LocalEvaluation.sha256_file(manifest_path),
      "reason" => "Reject a newly discovered invalid timing and rerun only its record.",
      "affected_run_ids" => [id],
      "authorized_operations" => LocalEvaluation::PipelineAmendment::AUTHORIZED_OPERATIONS,
      "original_pipeline_source_sha256" => original["sha256"],
      "amended_pipeline_source" => amended,
      "changed_files" => {
        "pipeline.rb" => { "before_sha256" => "b" * 64, "after_sha256" => "d" * 64 }
      }
    })
    amendment = LocalEvaluation::PipelineAmendment.new(amendment_path, manifest: manifest)

    assert amendment.verify!(manifest: manifest, current_pipeline: amended, operation: "benchmark",
                             exact_id: id, filter: nil)
    assert amendment.verify!(manifest: manifest, current_pipeline: amended, operation: "benchmark",
                             exact_id: nil, filter: nil, selected_ids: [id])
    assert amendment.verify!(manifest: manifest, current_pipeline: amended, operation: "aggregate",
                             exact_id: nil, filter: nil)
    assert_raises(LocalEvaluation::InfrastructureError) do
      amendment.verify!(manifest: manifest, current_pipeline: amended, operation: "benchmark",
                        exact_id: other_id, filter: nil)
    end
    assert_raises(LocalEvaluation::InfrastructureError) do
      amendment.verify!(manifest: manifest, current_pipeline: amended, operation: "aggregate",
                        exact_id: id, filter: nil)
    end
    assert_raises(LocalEvaluation::InfrastructureError) do
      amendment.verify!(manifest: manifest, current_pipeline: amended, operation: "validate",
                        exact_id: id, filter: nil)
    end
  end

  def test_process_runner_logs_success_and_timeout
    runner = LocalEvaluation::ProcessRunner.new
    prefix = File.join(@tmp, "success")
    result = runner.run(argv: [RbConfig.ruby, "-e", "puts :ok"], prefix: prefix, timeout: 2)
    assert result.success
    assert_equal "ok\n", File.read("#{prefix}_stdout.log")
    assert_equal "0", File.read("#{prefix}_exitcode.log")

    timeout_prefix = File.join(@tmp, "timeout")
    result = runner.run(argv: [RbConfig.ruby, "-e", "sleep 5"], prefix: timeout_prefix, timeout: 0.1)
    refute result.success
    assert result.timed_out
    assert_equal 124, result.exit_code
  end

  def test_process_runner_records_signaled_exit_as_boolean_failure
    runner = LocalEvaluation::ProcessRunner.new
    result = runner.run(
      argv: [RbConfig.ruby, "-e", "Process.kill('KILL', Process.pid)"],
      prefix: File.join(@tmp, "signaled"), timeout: 2
    )

    assert_equal false, result.success
    assert_equal 137, result.exit_code
    assert_equal 9, result.term_signal
  end

  def test_atomic_write_replaces_complete_file
    path = File.join(@tmp, "state.yaml")
    LocalEvaluation.atomic_write(path, "old")
    LocalEvaluation.atomic_write(path, "new")
    assert_equal "new", File.read(path)
    assert_empty Dir["#{path}.tmp-*"]
  end

  def test_resource_profiles_pin_expected_physical_resources
    resources = LocalEvaluation::Resources.new(wrapper_path: "/wrapper.rb")
    omp_env, omp_command = resources.command(par_type: "omp", executable: "/program", args: ["-n", "1"], mode: :benchmark)
    assert_equal "128", omp_env["OMP_NUM_THREADS"]
    assert_includes omp_command, "--physcpubind=0-127"
    assert_includes omp_command, "--interleave=0,1"

    mpi_env, mpi_command = resources.command(par_type: "mpi", executable: "/program", args: [], mode: :benchmark)
    assert_equal "", mpi_env["CUDA_VISIBLE_DEVICES"]
    assert_includes mpi_command, "128"
    assert_includes mpi_command, "ppr:64:socket:PE=1"

    hybrid_env, hybrid_command = resources.command(par_type: "hybrid", executable: "/program", args: [], mode: :benchmark)
    assert_equal "0,1,2,3", hybrid_env["CUDA_VISIBLE_DEVICES"]
    assert_equal "32", hybrid_env["OMP_NUM_THREADS"]
    assert_includes hybrid_command, "ppr:2:socket:PE=32"
    assert_includes hybrid_command, "/wrapper.rb"
  end

  def test_hybrid_wrapper_exposes_one_gpu_per_local_rank
    prefix = File.join(@tmp, "gpu-wrapper")
    env = { "CUDA_VISIBLE_DEVICES" => "0,1,2,3", "OMPI_COMM_WORLD_LOCAL_RANK" => "2" }
    result = LocalEvaluation::ProcessRunner.new.run(
      argv: [RbConfig.ruby, File.expand_path("../local_gpu_rank_wrapper.rb", __dir__),
             RbConfig.ruby, "-e", "puts ENV.fetch(\"CUDA_VISIBLE_DEVICES\")"],
      env: env, prefix: prefix, timeout: 2
    )
    assert result.success
    assert_equal "2\n", File.read("#{prefix}_stdout.log")
  end

  def test_parallelization_detection_recognizes_cuda_runtime_api_and_compute_libraries
    source_root = File.join(@tmp, "source")
    source_dir = File.join(source_root, "matmul")
    FileUtils.mkdir_p(source_dir)
    source_path = File.join(source_dir, "matmul.cpp")

    [
      "#include <cuda_runtime_api.h>\n",
      "#include <cublas_v2.h>\n",
      "#include <cusolverDn.h>\n",
      "#include <cusparse.h>\n",
      "#include <thrust/device_vector.h>\nvoid f() { thrust::device_vector<int> values; }\n",
      "#include <cub/cub.cuh>\nvoid f() { cub::DeviceReduce::Sum(nullptr, 0, nullptr, nullptr, 0); }\n"
    ].each do |source|
      File.write(source_path, source)
      assert_equal [PAR_CUDA], parallelization_detection(source_root, "matmul"), source
    end
  end

  def test_parallelization_detection_does_not_match_cuda_named_host_helpers
    source_root = File.join(@tmp, "source")
    source_dir = File.join(source_root, "matmul")
    FileUtils.mkdir_p(source_dir)
    File.write(File.join(source_dir, "matmul.cpp"), <<~CPP)
      void cudaCheck() {}
      void cublasCheck() {}
      void device_vector_fallback() {}
    CPP

    assert_empty parallelization_detection(source_root, "matmul")
  end

  def test_benchmark_metric_parsing_and_fallback_units
    metrics = LocalEvaluation::BenchmarkMetrics.parse("matmul", "Computation time: 123.5 ms\nPerformance: 7.5 GFLOPS\n")
    assert_equal 123.5, metrics["time"]
    assert_equal 7.5, metrics["throughput"]
    fallback = LocalEvaluation::BenchmarkMetrics.parse("matmul", "Computation time: 2500 us\n")
    assert_equal 2.5, fallback["time"]
    seconds = LocalEvaluation::BenchmarkMetrics.parse("matmul", "Computation time: 1.25 s\n")
    assert_equal 1_250.0, seconds["time"]
    assert_equal 2.5, LocalEvaluation::BenchmarkMetrics.median([3.0, 2.0])

    error = assert_raises(RuntimeError) do
      LocalEvaluation::BenchmarkMetrics.parse("spmv", "Computation time: 0.000 ms\n")
    end
    assert_match(/finite positive milliseconds/, error.message)
  end

  def test_benchmark_metric_parser_prefers_one_explicit_max_across_ranks
    output = <<~OUTPUT
      Rank 0: Computation time: 101 ms
      Rank 1: Computation time: 107 ms
      Computation time (max across ranks): 0.125 s
      Performance: 7.5 GFLOPS
    OUTPUT

    metrics = LocalEvaluation::BenchmarkMetrics.parse("matmul", output)
    assert_equal 125.0, metrics["time"]
    assert_equal 7.5, metrics["throughput"]

    suffix = LocalEvaluation::BenchmarkMetrics.parse("matmul", <<~OUTPUT)
      Rank 0: Computation time: 90 ms
      Rank 1: Computation time: 95 ms
      Computation time: 0.1 s (max across ranks)
    OUTPUT
    assert_equal 100.0, suffix["time"]
  end

  def test_benchmark_metric_parser_rejects_ambiguous_rank_timings_without_maximum
    error = assert_raises(RuntimeError) do
      LocalEvaluation::BenchmarkMetrics.parse("matmul", <<~OUTPUT)
        Rank 0: Computation time: 101 ms
        Rank 1: Computation time: 107 ms
      OUTPUT
    end
    assert_match(/ambiguous.*2 primary timings/i, error.message)

    error = assert_raises(RuntimeError) do
      LocalEvaluation::BenchmarkMetrics.parse("matmul", "Computation time: 1000 us\nComputation time: 2 s\n")
    end
    assert_match(/ambiguous.*alternate-unit/i, error.message)

    error = assert_raises(RuntimeError) do
      LocalEvaluation::BenchmarkMetrics.parse("matmul", "Computation time: 10 ms\nComputation time: 0.02 s\n")
    end
    assert_match(/ambiguous.*primary\/alternate-unit/i, error.message)
  end

  def test_benchmark_metric_parser_rejects_multiple_max_across_ranks_timings
    error = assert_raises(RuntimeError) do
      LocalEvaluation::BenchmarkMetrics.parse("matmul", <<~OUTPUT)
        Computation time (max rank): 101 ms
        Computation time (max across ranks): 107 ms
      OUTPUT
    end
    assert_match(/ambiguous.*2 max-across-ranks/i, error.message)
  end

  def test_calibration_scaling_respects_exponent_alignment_and_caps
    calibrator = LocalEvaluation::Calibrator.allocate
    scale = { "argument" => "-n", "exponent" => 3.0, "alignment" => 128,
              "minimum" => 512, "maximum" => 8192 }
    grown = calibrator.send(:scaled_args, ["-n", "1024"], scale, 8.0)
    assert_equal ["-n", "2048"], grown
    capped = calibrator.send(:scaled_args, ["-n", "8192"], scale, 100.0)
    assert_equal ["-n", "8192"], capped
  end

  def test_freeze_config_requires_complete_reviewed_cells
    manifest_path = File.join(@tmp, "evaluation_manifest.yaml")
    LocalEvaluation.atomic_yaml_with_digest(manifest_path, {
      "schema_version" => 1, "batches" => [], "runs" => {}, "benchmarks_root" => @tmp
    })
    validation_path = File.join(@tmp, "validation", "all_validation_results.yaml")
    LocalEvaluation.atomic_yaml(validation_path, [])
    seed_source_path = File.expand_path("../local_benchmark_seed.yml", __dir__)
    seed_snapshot = LocalEvaluation::CalibrationSeed.materialize!(run_dir: @tmp,
                                                                   source_path: seed_source_path)
    seed_path = seed_snapshot.path
    seed = seed_snapshot.data
    cells = LocalEvaluation::PAR_TYPES.to_h do |par_type|
      [par_type, LocalEvaluation::BENCHMARKS.to_h do |benchmark|
        [benchmark, { "resolved" => true, "status" => "resolved",
                      "args" => seed.fetch("benchmarks").fetch(benchmark).fetch("args").fetch(par_type).map(&:to_s),
                      "timeout_seconds" => 30 }]
      end]
    end
    cells["omp"]["matmul"]["resolved"] = false
    proposed = File.join(@tmp, "proposed.yaml")
    base = { "schema_version" => 1, "state" => "proposed", "cells" => cells,
             "manifest_sha256" => LocalEvaluation.sha256_file(manifest_path),
             "validation_complete" => true, "seed_path" => seed_path,
             "seed_sha256" => seed_snapshot.digest,
             "validation_results_sha256" => LocalEvaluation.sha256_file(validation_path) }
    LocalEvaluation.atomic_yaml(proposed, base)
    assert_raises(RuntimeError) do
      LocalEvaluation::BenchmarkPipeline.freeze_config(run_dir: @tmp, proposed_path: proposed)
    end
    cells["omp"]["matmul"]["resolved"] = true
    LocalEvaluation.atomic_yaml(proposed, base)
    LocalEvaluation::BenchmarkPipeline.freeze_config(run_dir: @tmp, proposed_path: proposed)
    frozen = LocalEvaluation.load_yaml(File.join(@tmp, "benchmark_config.yaml"))
    assert_equal "frozen", frozen["state"]
  end

  def test_agent_metadata_parses_copilot_pi_and_codex_formats
    pipeline = LocalEvaluation::AggregatePipeline.allocate
    pipeline.instance_variable_set(:@warnings, {})

    copilot = aggregate_metadata(pipeline, "copilot", <<~OUT)
      API time spent: 1m 2.5s
      Total code changes: +8 -5
       model-name 379.8k in, 4.1k out, 350.8k cached
    OUT
    assert_equal 62.5, copilot.api_time
    assert_equal 379_800.0, copilot.input_tokens
    assert_equal 383_900.0, copilot.total_tokens

    pi = aggregate_metadata(pipeline, "pi", "Changes +14 -7\n[Usage] billed (input: 8301, output: 2722, cache_read: 57335)\n")
    assert_equal 8_301.0, pi.input_tokens
    assert_equal 11_023.0, pi.total_tokens

    codex = aggregate_metadata(pipeline, "codex", "Total code changes: +3 -2\ntokens used\n49,867\n")
    assert_equal 49_867.0, codex.total_tokens
    assert_nil codex.input_tokens
  end

  def test_scoring_requires_reviewed_ordered_thresholds_and_scores_fastest
    fast = aggregate_result("model-fast", 100.0)
    slow = aggregate_result("model-slow", 400.0)
    id_fast = "matmul_model-fast_omp_r1"
    id_slow = "matmul_model-slow_omp_r1"
    LocalEvaluation.atomic_yaml_with_digest(File.join(@tmp, "evaluation_manifest.yaml"), {
      "schema_version" => 1, "batches" => ["test"], "benchmarks_root" => @tmp,
      "runs" => { id_fast => {}, id_slow => {} }
    })
    write_scoring_aggregate(id_fast => fast, id_slow => slow)
    threshold_path = File.join(@tmp, "thresholds.csv")
    File.write(threshold_path, "bench,type,top,great,good,reviewed\nmatmul,omp,120,200,300,true\n")

    LocalEvaluation::ScoringPipeline.score(run_dir: @tmp, thresholds_path: threshold_path)
    scored = LocalEvaluation.load_yaml(File.join(@tmp, "scored_results.yaml"), permitted_classes: [AggregateEvaluation])
    assert_equal 10, scored[id_fast].overall_score
    assert_equal 6, scored[id_slow].overall_score

    File.write(threshold_path, "bench,type,top,great,good,reviewed\nmatmul,omp,300,200,100,true\n")
    assert_raises(RuntimeError) do
      LocalEvaluation::ScoringPipeline.score(run_dir: @tmp, thresholds_path: threshold_path, dry_run: true)
    end
  end

  def test_output_comparison_preserves_historical_numeric_tolerance
    reference = "=== RESULTS ===\nName: Value\nElements: 1\nSum: 1.000000\nHash: aa\n=== END RESULTS ==="
    close = "=== RESULTS ===\nName: Value\nElements: 1\nSum: 1.000001\nHash: bb\n=== END RESULTS ==="
    far = "=== RESULTS ===\nName: Value\nElements: 1\nSum: 1.1\nHash: bb\n=== END RESULTS ==="
    assert validate(reference, close, "matmul")[0]
    refute validate(reference, far, "matmul")[0]
  end

  private

  def make_source(root, batch, id, benchmark)
    directory = File.join(root, batch, id, benchmark)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "CMakeLists.txt"), "add_executable(#{benchmark} main.cpp)\n")
  end

  def aggregate_metadata(pipeline, id, output)
    source = File.join(@tmp, id)
    FileUtils.mkdir_p(source)
    File.write(File.join(source, "timing.txt"), "Duration: 10.25 seconds\n")
    File.write(File.join(source, "output.txt"), output)
    result = AggregateEvaluation.new("matmul", id, "omp", 1)
    pipeline.send(:parse_agent_metadata, id, { "source_path" => source }, result)
    assert_equal 10.25, result.total_time
    result
  end

  def aggregate_result(model, time)
    result = AggregateEvaluation.new("matmul", model, "omp", 1)
    result.validation_status = 5
    result.validation_err_string = ""
    result.non_whitelisted_dependencies = []
    result.benchmark_success = true
    result.benchmark_times = [time]
    result.benchmark_median_time = time
    result
  end

  def write_scoring_aggregate(results)
    validation_path = File.join(@tmp, "validation", "all_validation_results.yaml")
    LocalEvaluation.atomic_yaml(validation_path, [])
    aggregate_path = File.join(@tmp, "aggregate_results.yaml")
    LocalEvaluation.atomic_yaml(aggregate_path, results)
    LocalEvaluation.atomic_yaml(File.join(@tmp, "aggregate_metadata.yaml"), {
      "schema_version" => 1,
      "manifest_sha256" => LocalEvaluation.sha256_file(File.join(@tmp, "evaluation_manifest.yaml")),
      "pipeline_amendment_sha256" => nil,
      "source_correction_amendment_sha256" => nil,
      "validation_results_sha256" => LocalEvaluation.sha256_file(validation_path),
      "benchmark_full_results_sha256" => nil,
      "benchmark_config_sha256" => nil,
      "aggregate_results_sha256" => LocalEvaluation.sha256_file(aggregate_path),
      "refresh_scope" => "full",
      "full_rebuild" => true,
      "refreshed_ids" => results.keys,
      "record_count" => results.size
    })
  end
end
