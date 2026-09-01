require "minitest/autorun"
require "tmpdir"
require_relative "../lib/local_evaluation"

class LocalCalibrationStateTest < Minitest::Test
  SEED_PATH = File.expand_path("../local_benchmark_seed.yml", __dir__)

  def setup
    @tmp = Dir.mktmpdir("local-calibration-state-test", "/tmp")
  end

  def teardown
    FileUtils.remove_entry(@tmp) if File.directory?(@tmp)
  end

  def test_zero_reported_time_can_be_wall_limited_without_infinite_scaling
    calibrator = LocalEvaluation::Calibrator.allocate
    calibrator.instance_variable_set(:@seed, { "target_seconds" => target_rules })

    assert_equal "wall_limited", calibrator.send(:calibration_decision, 0.0, 4.0)
    assert_nil calibrator.send(:calibration_decision, 0.0, 0.5)
    assert_equal 1.0, calibrator.send(:scaling_ratio, 0.0, 4.0)

    scale = { "argument" => "-n", "exponent" => 1.0, "alignment" => 128,
              "minimum" => 128, "maximum" => 8192 }
    assert_equal ["-n", "1024"],
                 calibrator.send(:scaled_args, ["-n", "1024"], scale, Float::INFINITY)
  end

  def test_calibration_result_always_uses_arguments_from_the_last_completed_probe
    definition = {
      "scale" => { "argument" => "-n", "exponent" => 1.0, "alignment" => 128,
                   "minimum" => 128, "maximum" => 8192 },
      "input_caps" => { "omp" => { "-n" => 8192 } },
      "args" => { "omp" => ["-n", "1024"] }
    }
    seed = {
      "target_seconds" => target_rules.merge("max_probes" => 2),
      "benchmarks" => { "matmul" => definition }
    }
    calibrator = LocalEvaluation::Calibrator.allocate
    calibrator.instance_variable_set(:@seed, seed)
    calibrator.instance_variable_set(:@rules, LocalEvaluation::SeedRules.new(seed))
    calibrator.instance_variable_set(:@validation_complete, true)
    seen_args = []
    calibrator.define_singleton_method(:monotonic_now) { 0.0 }
    calibrator.define_singleton_method(:pilot_ids) { |_par_type, _benchmark| ["pilot"] }
    calibrator.define_singleton_method(:run_probe) do |_par_type, _benchmark, _pilots, args, probe, _measurements, _deadline|
      seen_args << args.dup
      {
        "probe" => probe,
        "args" => args.dup,
        "pilot_median_seconds" => { "pilot" => 0.5 },
        "pilot_wall_median_seconds" => { "pilot" => 0.5 },
        "fastest_pilot_id" => "pilot",
        "fastest_median_seconds" => 0.5,
        "fastest_pilot_wall_median_seconds" => 0.5,
        "wall_seconds" => [0.5],
        "failed_pilots" => {},
        "budget_exhausted" => false
      }
    end

    _stdout, _stderr = capture_io do
      @calibration_result = calibrator.send(:calibrate_cell, "omp", "matmul", 1000.0)
    end

    assert_equal 2, seen_args.size
    refute_equal seen_args.first, seen_args.last
    assert_equal seen_args.last, @calibration_result.fetch("args")
    assert_equal @calibration_result.fetch("probes").last.fetch("args"),
                 @calibration_result.fetch("args")
    assert_equal ["-n", "6144"], @calibration_result.fetch("args")

    seen_args.clear
    _stdout, _stderr = capture_io do
      @reviewed_retry_result = calibrator.send(
        :calibrate_cell, "omp", "matmul", 1000.0, starting_args: ["-n", "2048"]
      )
    end
    assert_equal ["-n", "2048"], seen_args.first
    assert_equal ["-n", "8192"], @reviewed_retry_result.fetch("args")
  end

  def test_backend_specific_caps_are_validated_and_used_for_scaling
    seed = LocalEvaluation.load_yaml(SEED_PATH)
    rules = LocalEvaluation::SeedRules.new(seed)
    scale = seed.fetch("benchmarks").fetch("black-scholes").fetch("scale")
    calibrator = LocalEvaluation::Calibrator.allocate
    calibrator.instance_variable_set(:@rules, rules)

    assert_equal 150_000_000, rules.scale_maximum(scale, "cuda")
    assert_equal 200_000_000, rules.scale_maximum(scale, "omp")
    assert rules.validate_args!("cuda", "black-scholes", ["-n", "150000000"])
    error = assert_raises(RuntimeError) do
      rules.validate_args!("cuda", "black-scholes", ["-n", "200000000"])
    end
    assert_match(/safe cap 150000000/, error.message)

    assert_equal ["-n", "150000000"],
                 calibrator.send(:scaled_args, ["-n", "150000000"], scale, 10.0, "cuda")
    assert_equal ["-n", "200000000"],
                 calibrator.send(:scaled_args, ["-n", "150000000"], scale, 10.0, "omp")

    assert_equal 10_000_000, rules.scale_maximum(scale, "mpi")
    assert rules.validate_args!("mpi", "black-scholes", ["-n", "10000000"])
    assert_raises(RuntimeError) do
      rules.validate_args!("mpi", "black-scholes", ["-n", "11000000"])
    end
    assert rules.validate_args!("mpi", "matmul", ["-n", "6144"])
    assert_raises(RuntimeError) { rules.validate_args!("mpi", "matmul", ["-n", "6272"]) }
    assert rules.validate_args!("mpi", "cahn-hilliard", ["-x", "256", "-i", "100"])
    assert_raises(RuntimeError) do
      rules.validate_args!("mpi", "cahn-hilliard", ["-x", "512", "-i", "100"])
    end
    assert rules.validate_args!("mpi", "stencil3d", ["-x", "256", "-i", "100"])
    assert rules.validate_args!("mpi", "unstructured", ["-n", "2000", "-i", "50"])
    assert_raises(RuntimeError) do
      rules.validate_args!("mpi", "unstructured", ["-n", "2001", "-i", "50"])
    end
    assert rules.validate_args!("mpi", "spmv", ["-n", "40000", "-s", "40", "-i", "1000"])
    minimum_error = assert_raises(RuntimeError) do
      rules.validate_args!("mpi", "spmv", ["-n", "40000", "-s", "39", "-i", "1000"])
    end
    assert_match(/below the safe minimum 40/, minimum_error.message)
  end

  def test_seed_rules_require_the_exact_ordered_unique_flag_shape
    rules = LocalEvaluation::SeedRules.new(LocalEvaluation.load_yaml(SEED_PATH))
    valid = ["-n", "20000", "-s", "100"]
    assert rules.validate_args!("omp", "nbody", valid)

    [
      ["-s", "100", "-n", "20000"],
      ["-n", "20000", "-n", "100"],
      ["-n", "20000", "-s", "100", "-x", "1"],
      ["-n", "20000", "100", "-s"]
    ].each do |args|
      error = assert_raises(RuntimeError) { rules.validate_args!("omp", "nbody", args) }
      assert_match(/exactly these flags in order/, error.message)
    end
  end

  def test_real_calibration_snapshots_seed_and_resume_ignores_source_changes
    id = "matmul_model-a_omp_r1"
    info = run_info("matmul", "model-a", "omp")
    write_manifest(id => info)
    invalid = ValidationResult.new("matmul", "model-a", "omp", 1)
    write_validation([invalid])
    source = File.join(@tmp, "operator-seed.yaml")
    LocalEvaluation.atomic_write(source, File.binread(SEED_PATH))
    resources = Object.new
    resources.define_singleton_method(:verify_topology!) { {} }
    resources.define_singleton_method(:command) do |par_type:, executable:, args:, mode:|
      [{}, [executable, *args]]
    end

    dry = LocalEvaluation::Calibrator.new(run_dir: @tmp, seed_path: source, dry_run: true,
                                           resources: resources)
    capture_io { dry.run }
    snapshot_path = LocalEvaluation::CalibrationSeed.snapshot_path(@tmp)
    refute File.exist?(snapshot_path)
    refute File.exist?(File.join(@tmp, "benchmark_config.proposed.yaml"))

    real = LocalEvaluation::Calibrator.new(run_dir: @tmp, seed_path: source, resources: resources)
    capture_io { real.run }
    digest = LocalEvaluation.sha256_file(snapshot_path)
    assert_equal digest, File.read("#{snapshot_path}.sha256").strip
    assert_equal 0o444, File.stat(snapshot_path).mode & 0o777
    assert_equal 0o444, File.stat("#{snapshot_path}.sha256").mode & 0o777
    proposal = LocalEvaluation.load_yaml(File.join(@tmp, "benchmark_config.proposed.yaml"))
    assert_equal snapshot_path, proposal.fetch("seed_path")
    assert_equal digest, proposal.fetch("seed_sha256")

    changed = LocalEvaluation.load_yaml(source)
    changed.fetch("target_seconds")["target"] = 99.0
    LocalEvaluation.atomic_yaml(source, changed)
    FileUtils.mv(source, "#{source}.moved")
    resumed = LocalEvaluation::Calibrator.new(run_dir: @tmp, seed_path: source,
                                               resources: resources)
    assert_equal snapshot_path, resumed.instance_variable_get(:@seed_path)
    assert_equal 3.0, resumed.instance_variable_get(:@seed).fetch("target_seconds").fetch("target")

    # Simulate interruption after the snapshot rename but before its sidecar.
    FileUtils.rm_f("#{snapshot_path}.sha256")
    resumed.send(:activate_seed_snapshot!)
    assert_equal digest, File.read("#{snapshot_path}.sha256").strip
  end

  def test_filtered_calibration_loads_and_merges_the_existing_checkpoint
    matmul_id = "matmul_model-a_omp_r1"
    nbody_id = "nbody_model-b_cuda_r1"
    runs = {
      matmul_id => run_info("matmul", "model-a", "omp"),
      nbody_id => run_info("nbody", "model-b", "cuda")
    }
    write_manifest(runs)
    write_validation(runs.values.map { |info| valid_result(info) })

    first = new_calibrator(exact_id: matmul_id)
    assert_equal [["omp", "matmul"]], first.send(:selected_cells)
    proposal = first.send(:new_output)
    proposal.fetch("cells").fetch("omp").fetch("matmul").merge!(
      "status" => "wall_limited", "resolved" => true, "marker" => "keep-me"
    )
    first.send(:checkpoint, proposal)

    second = new_calibrator(filter: "model-b")
    assert_equal [["cuda", "nbody"]], second.send(:selected_cells)
    merged = second.send(:load_or_initialize_output)
    retained = merged.fetch("cells").fetch("omp").fetch("matmul")
    assert_equal "keep-me", retained.fetch("marker")
    assert_equal "wall_limited", retained.fetch("status")
    assert retained.fetch("resolved")

    dry_completed = new_calibrator(exact_id: matmul_id)
    dry_completed.instance_variable_set(:@dry_run, true)
    stdout, _stderr = capture_io { dry_completed.run }
    assert_match(/0 pending of 1 selected/, stdout)
    refute_match(/matmul\/omp: pilots=/, stdout)

    completed = new_calibrator(exact_id: matmul_id)
    resources = Object.new
    resources.define_singleton_method(:verify_topology!) { raise "completed calibration probed topology" }
    completed.instance_variable_set(:@resources, resources)
    stdout, _stderr = capture_io { completed.run }
    assert_match(/already completed/, stdout)
  end

  def test_incomplete_validation_is_not_converted_to_no_valid_programs_and_cannot_freeze
    valid_id = "matmul_model-a_omp_r1"
    pending_id = "nbody_model-b_cuda_r1"
    runs = {
      valid_id => run_info("matmul", "model-a", "omp"),
      pending_id => run_info("nbody", "model-b", "cuda")
    }
    write_manifest(runs)
    write_validation([valid_result(runs.fetch(valid_id))])
    calibrator = new_calibrator(exact_id: pending_id)

    cell = calibrator.send(:calibrate_cell, "cuda", "nbody",
                           Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10)
    assert_equal "validation_incomplete", cell.fetch("status")
    refute cell.fetch("resolved")

    proposal = calibrator.send(:new_output)
    proposal.fetch("cells").each_value do |benchmarks|
      benchmarks.each_value do |entry|
        entry.merge!("status" => "no_valid_programs", "resolved" => true)
      end
    end
    calibrator.send(:checkpoint, proposal)
    error = assert_raises(RuntimeError) do
      LocalEvaluation::BenchmarkPipeline.freeze_config(run_dir: @tmp, dry_run: true)
    end
    assert_match(/Validation is incomplete/, error.message)
    refute File.exist?(File.join(@tmp, "benchmark_config.yaml"))
  end

  def test_freeze_validates_bounds_is_immutable_and_detects_digest_changes
    info = run_info("matmul", "model-a", "omp")
    write_manifest("matmul_model-a_omp_r1" => info)
    write_validation([valid_result(info)])
    proposal = complete_proposal
    proposal.fetch("cells").fetch("omp").fetch("matmul")["timeout_seconds"] = 121
    proposal_path = File.join(@tmp, "benchmark_config.proposed.yaml")
    LocalEvaluation.atomic_yaml(proposal_path, proposal)

    error = assert_raises(RuntimeError) do
      LocalEvaluation::BenchmarkPipeline.freeze_config(run_dir: @tmp, dry_run: true)
    end
    assert_match(/Timeout must be between 30 and 120/, error.message)

    proposal.fetch("cells").fetch("omp").fetch("matmul")["timeout_seconds"] = 30
    LocalEvaluation.atomic_yaml(proposal_path, proposal)
    capture_io { LocalEvaluation::BenchmarkPipeline.freeze_config(run_dir: @tmp, dry_run: true) }
    refute File.exist?(File.join(@tmp, "benchmark_config.yaml"))
    # Simulate interruption after the sidecar-first write. The retry replaces the
    # orphan and commits the primary configuration.
    digest_path = File.join(@tmp, "benchmark_config.yaml.sha256")
    LocalEvaluation.atomic_write(digest_path, "#{'0' * 64}\n")
    capture_io { LocalEvaluation::BenchmarkPipeline.freeze_config(run_dir: @tmp) }

    config_path = File.join(@tmp, "benchmark_config.yaml")
    assert_equal 0o444, File.stat(config_path).mode & 0o777
    assert_equal LocalEvaluation.sha256_file(config_path), File.read(digest_path).strip

    # Simulate the legacy primary-first crash window. Dry-run must not mutate it;
    # a real retry may recover only because it exactly matches this proposal.
    FileUtils.rm_f(digest_path)
    capture_io { LocalEvaluation::BenchmarkPipeline.freeze_config(run_dir: @tmp, dry_run: true) }
    refute File.exist?(digest_path)
    stdout, _stderr = capture_io { LocalEvaluation::BenchmarkPipeline.freeze_config(run_dir: @tmp) }
    assert_match(/Recovered/, stdout)
    assert_equal LocalEvaluation.sha256_file(config_path), File.read(digest_path).strip

    config = LocalEvaluation::BenchmarkConfig.new(config_path)
    cached_digest = config.digest
    config.verify_unchanged!

    LocalEvaluation.atomic_write(digest_path, "#{'f' * 64}\n")
    assert_raises(LocalEvaluation::InfrastructureError) { config.verify_unchanged! }
    LocalEvaluation.atomic_write(digest_path, "#{cached_digest}\n")
    FileUtils.rm_f(digest_path)
    assert_raises(LocalEvaluation::InfrastructureError) { config.verify_unchanged! }
    LocalEvaluation.atomic_write(digest_path, "#{cached_digest}\n")

    overwrite_error = assert_raises(RuntimeError) do
      LocalEvaluation::BenchmarkPipeline.freeze_config(run_dir: @tmp)
    end
    assert_match(/already exists and is immutable/, overwrite_error.message)

    LocalEvaluation.atomic_write(config_path, File.read(config_path) + "\n# mutated\n")
    assert_equal cached_digest, config.digest
    assert_raises(LocalEvaluation::InfrastructureError) { config.verify_unchanged! }
  end

  def test_frozen_config_requires_a_digest_sidecar
    config_path = File.join(@tmp, "benchmark_config.yaml")
    LocalEvaluation.atomic_yaml(config_path, { "schema_version" => LocalEvaluation::SCHEMA_VERSION,
                                                "state" => "frozen" })
    error = assert_raises(RuntimeError) { LocalEvaluation::BenchmarkConfig.new(config_path) }
    assert_match(/digest sidecar not found/, error.message)
  end

  def test_full_results_are_the_canonical_resume_record_and_rebuild_boolean_results
    done_id = "matmul_model-a_omp_r1"
    pending_id = "matmul_model-b_omp_r1"
    failed_id = "matmul_model-c_omp_r1"
    runs = {
      done_id => run_info("matmul", "model-a", "omp"),
      pending_id => run_info("matmul", "model-b", "omp"),
      failed_id => run_info("matmul", "model-c", "omp")
    }
    write_manifest(runs)
    write_validation(runs.values.map { |info| valid_result(info) })
    config_path = File.join(@tmp, "benchmark_config.yaml")
    LocalEvaluation.atomic_yaml(config_path, complete_proposal.merge("state" => "frozen"))
    config_digest = LocalEvaluation.sha256_file(config_path)
    LocalEvaluation.atomic_write("#{config_path}.sha256", "#{config_digest}\n")

    benchmark_dir = File.join(@tmp, "benchmark")
    FileUtils.mkdir_p(benchmark_dir)
    full_path = File.join(benchmark_dir, BENCHMARK_FULL_RESULTS_FN)
    simple_path = File.join(benchmark_dir, BENCHMARK_RESULTS_FN)
    metrics = Array.new(BENCHMARK_COUNT) { |index| { "time" => 10.0 + index } }
    older_local = { done_id => [true, metrics], failed_id => [false, []] }
    canonical = { done_id => [true, metrics], failed_id => [false, {}] }
    LocalEvaluation.atomic_yaml(full_path, older_local)
    # Deliberately contradictory compatibility state: resume must ignore it.
    LocalEvaluation.atomic_yaml(simple_path, { pending_id => true })
    LocalEvaluation.atomic_yaml(File.join(benchmark_dir, "benchmark_run_metadata.yaml"), {
      "configuration_sha256" => config_digest,
      "invocations" => []
    })
    write_attempt_metadata(done_id, runs.fetch(done_id), config_digest,
                           success: true, metrics: metrics)
    write_attempt_metadata(failed_id, runs.fetch(failed_id), config_digest,
                           success: false, metrics: [],
                           executions: [attempt_execution("warmup", false, 0.25)])
    make_executable(File.join(@tmp, "validation", pending_id, "matmul"))

    pipeline = LocalEvaluation::BenchmarkPipeline.new(run_dir: @tmp, dry_run: true)
    stdout, _stderr = capture_io { pipeline.run }
    assert_match(/1 pending fully-valid programs/, stdout)
    assert_includes stdout, pending_id
    refute_includes stdout, done_id

    loaded = pipeline.send(:load_full_results)
    pipeline.send(:write_compatibility_results, loaded)
    assert_equal canonical, LocalEvaluation.load_yaml(full_path)
    assert_equal({ done_id => true, failed_id => false }, LocalEvaluation.load_yaml(simple_path))

    resources = Object.new
    resources.define_singleton_method(:verify_topology!) { raise "completed benchmark probed topology" }
    completed = LocalEvaluation::BenchmarkPipeline.new(run_dir: @tmp, exact_id: done_id,
                                                        resources: resources)
    stdout, _stderr = capture_io { completed.run }
    assert_match(/already have benchmark results/, stdout)

    contaminated = LocalEvaluation.load_yaml(full_path)
    contaminated["matmul_intruder_omp_r1"] = [false, {}]
    LocalEvaluation.atomic_yaml(full_path, contaminated)
    error = assert_raises(RuntimeError) { pipeline.send(:load_full_results) }
    assert_match(/absent from the evaluation manifest/, error.message)
  end

  def test_successful_retry_interrupted_before_canonical_commit_is_requeued
    id = "matmul_model-a_omp_r1"
    info = run_info("matmul", "model-a", "omp")
    write_manifest(id => info)
    write_validation([valid_result(info)])
    config_digest = install_frozen_config
    metrics = Array.new(BENCHMARK_COUNT) { |index| { "time" => 10.0 + index } }
    LocalEvaluation.atomic_yaml(File.join(@tmp, "benchmark", BENCHMARK_FULL_RESULTS_FN), {
      id => [false, {}]
    })
    # This is the exact retry crash window: finish_metadata committed a successful
    # attempt, but the canonical full-results update did not happen yet.
    write_attempt_metadata(id, info, config_digest, success: true, metrics: metrics)
    make_executable(File.join(@tmp, "validation", id, "matmul"))

    pipeline = LocalEvaluation::BenchmarkPipeline.new(run_dir: @tmp, dry_run: true)
    assert_empty pipeline.send(:load_full_results)
    stdout, stderr = capture_io { pipeline.run }
    assert_match(/1 pending fully-valid programs/, stdout)
    assert_includes stdout, id
    assert_match(/metadata success disagrees with the canonical result/, stderr)
  end

  def test_exact_id_resume_reconciles_only_the_selected_record
    selected_id = "matmul_model-a_omp_r1"
    unrelated_id = "matmul_model-b_omp_r1"
    runs = {
      selected_id => run_info("matmul", "model-a", "omp"),
      unrelated_id => run_info("matmul", "model-b", "omp")
    }
    write_manifest(runs)
    write_validation(runs.values.map { |info| valid_result(info) })
    config_digest = install_frozen_config
    LocalEvaluation.atomic_yaml(File.join(@tmp, "benchmark", BENCHMARK_FULL_RESULTS_FN), {
      selected_id => [false, {}], unrelated_id => [false, {}]
    })
    LocalEvaluation.atomic_yaml(File.join(@tmp, "benchmark", "benchmark_run_metadata.yaml"), {
      "configuration_sha256" => config_digest, "invocations" => []
    })

    metrics = Array.new(BENCHMARK_COUNT) { |index| { "time" => 10.0 + index } }
    write_attempt_metadata(selected_id, runs.fetch(selected_id), config_digest,
                           success: true, metrics: metrics)
    write_attempt_metadata(unrelated_id, runs.fetch(unrelated_id), config_digest,
                           success: false, metrics: [],
                           executions: [attempt_execution("warmup", nil, 0.25)])

    pipeline = LocalEvaluation::BenchmarkPipeline.new(run_dir: @tmp, exact_id: selected_id,
                                                       dry_run: true)
    loaded = nil
    _stdout, stderr = capture_io { loaded = pipeline.send(:load_full_results) }
    refute loaded.key?(selected_id)
    assert_equal [false, {}], loaded.fetch(unrelated_id)
    assert_match(/metadata success disagrees with the canonical result/, stderr)
    refute_match(/execution success is not boolean/, stderr)
  end

  def test_resume_reconciliation_checks_success_and_failure_attempt_structure
    id = "matmul_model-a_omp_r1"
    info = run_info("matmul", "model-a", "omp")
    write_manifest(id => info)
    write_validation([valid_result(info)])
    config_digest = install_frozen_config
    metrics = Array.new(BENCHMARK_COUNT) { |index| { "time" => 10.0 + index } }
    pipeline = LocalEvaluation::BenchmarkPipeline.new(run_dir: @tmp, dry_run: true)
    success_record = [true, metrics]

    write_attempt_metadata(id, info, config_digest, success: true, metrics: metrics)
    assert_nil pipeline.send(:benchmark_record_problem, id, success_record)

    write_attempt_metadata(id, info, config_digest, success: true, metrics: metrics,
                           args: ["-n", "4096"])
    assert_match(/arguments differ/, pipeline.send(:benchmark_record_problem, id, success_record))

    write_attempt_metadata(id, info, config_digest, success: true, metrics: metrics, timeout: 31)
    assert_match(/timeout differs/, pipeline.send(:benchmark_record_problem, id, success_record))

    write_attempt_metadata(id, info, "wrong-digest", success: true, metrics: metrics)
    assert_match(/configuration digest differs/, pipeline.send(:benchmark_record_problem, id, success_record))

    mismatched_metrics = metrics.map(&:dup)
    mismatched_metrics.last["time"] = 999.0
    write_attempt_metadata(id, info, config_digest, success: true, metrics: mismatched_metrics)
    assert_match(/metrics differ/, pipeline.send(:benchmark_record_problem, id, success_record))

    incomplete = [attempt_execution("warmup", true, 0.5)] +
                 4.times.map { |index| attempt_execution(index, true, 1.0 + index) }
    write_attempt_metadata(id, info, config_digest, success: true, metrics: metrics,
                           executions: incomplete)
    assert_match(/repetitions 0\.\.4/, pipeline.send(:benchmark_record_problem, id, success_record))

    failed_executions = [
      attempt_execution("warmup", true, 0.5),
      attempt_execution(0, true, 1.0),
      attempt_execution(1, false, 1.5)
    ]
    write_attempt_metadata(id, info, config_digest, success: false,
                           metrics: [{ "time" => 10.0 }], executions: failed_executions)
    assert_nil pipeline.send(:benchmark_record_problem, id, [false, {}])

    noncontiguous = [attempt_execution("warmup", true, 0.5),
                     attempt_execution(2, false, 1.0)]
    write_attempt_metadata(id, info, config_digest, success: false, metrics: [],
                           executions: noncontiguous)
    assert_match(/contiguous prefix/, pipeline.send(:benchmark_record_problem, id, [false, {}]))

    parse_failure = [attempt_execution("warmup", true, 0.5),
                     attempt_execution(0, true, 1.0)]
    write_attempt_metadata(id, info, config_digest, success: false, metrics: [],
                           executions: parse_failure)
    assert_match(/parse-error artifact/, pipeline.send(:benchmark_record_problem, id, [false, {}]))
    LocalEvaluation.atomic_write(File.join(@tmp, "benchmark", id, "benchmark_0_parse_error.log"),
                                 "unparseable output\n")
    assert_nil pipeline.send(:benchmark_record_problem, id, [false, {}])

    invalid = ValidationResult.new("matmul", "model-a", "omp", 1)
    pipeline.instance_variable_get(:@validation_results)[id] = invalid
    assert_match(/not fully valid/, pipeline.send(:benchmark_record_problem, id, [false, {}]))
  end

  def test_benchmark_metadata_separates_warmup_from_recorded_wall_times
    pipeline = LocalEvaluation::BenchmarkPipeline.allocate
    config = Object.new
    config.define_singleton_method(:digest) { "config-digest" }
    pipeline.instance_variable_set(:@config, config)
    output_dir = File.join(@tmp, "benchmark", "id")
    executions = [
      { "repetition" => "warmup", "wall_seconds" => 9.0 },
      { "repetition" => 0, "wall_seconds" => 1.0 },
      { "repetition" => 1, "wall_seconds" => 2.0 },
      { "repetition" => 2, "wall_seconds" => 3.0 },
      { "repetition" => 3, "wall_seconds" => 4.0 },
      { "repetition" => 4, "wall_seconds" => 5.0 }
    ]
    metrics = Array.new(BENCHMARK_COUNT) { { "time" => 1.0 } }

    result = pipeline.send(:finish_metadata, output_dir, { "benchmark" => "matmul" },
                           ["-n", "512"], 30, executions, true, metrics)
    assert_equal [true, metrics], result
    metadata = LocalEvaluation.load_yaml(File.join(output_dir, "benchmark_metadata.yaml"))
    assert_equal [1.0, 2.0, 3.0, 4.0, 5.0], metadata.fetch("wall_seconds")
    assert_equal 9.0, metadata.fetch("warmup_wall_seconds")
    assert_equal [9.0, 1.0, 2.0, 3.0, 4.0, 5.0], metadata.fetch("all_execution_wall_seconds")

    failed = pipeline.send(:finish_metadata, output_dir, { "benchmark" => "matmul" },
                           ["-n", "512"], 30, executions.first(2), false, [{ "time" => 1.0 }])
    assert_equal [false, {}], failed
  end

  private

  def target_rules
    {
      "minimum" => 2.0,
      "target" => 3.0,
      "maximum" => 5.0,
      "wall_minimum" => 2.0,
      "wall_target" => 3.0,
      "wall_maximum" => 8.0,
      "short_compute_ratio" => 0.25,
      "measurements" => 1,
      "max_probes" => 2,
      "probe_timeout_seconds" => 30,
      "cell_wall_budget_seconds" => 100,
      "phase_wall_budget_seconds" => 1000
    }
  end

  def run_info(benchmark, model, par_type, run = 1)
    {
      "benchmark" => benchmark,
      "model" => model,
      "par_type" => par_type,
      "run" => run,
      "batch" => "20260101-000000",
      "source_path" => File.join(@tmp, "source", benchmark, model, par_type)
    }
  end

  def write_manifest(runs)
    LocalEvaluation.atomic_yaml_with_digest(File.join(@tmp, "evaluation_manifest.yaml"), {
      "schema_version" => LocalEvaluation::SCHEMA_VERSION,
      "benchmarks_root" => File.join(@tmp, "benchmarks"),
      "runs" => runs
    })
  end

  def write_validation(results)
    LocalEvaluation.atomic_yaml(File.join(@tmp, "validation", "all_validation_results.yaml"), results)
  end

  def valid_result(info)
    result = ValidationResult.new(info.fetch("benchmark"), info.fetch("model"),
                                  info.fetch("par_type"), info.fetch("run"))
    result.basic_para = true
    result.validation_build = true
    result.validation_run = true
    result.internal_validation = true
    result.output_comparison = true
    result
  end

  def new_calibrator(exact_id: nil, filter: nil)
    LocalEvaluation::Calibrator.new(run_dir: @tmp, seed_path: SEED_PATH,
                                   exact_id: exact_id, filter: filter)
  end

  def complete_proposal
    seed_snapshot = LocalEvaluation::CalibrationSeed.materialize!(run_dir: @tmp,
                                                                   source_path: SEED_PATH)
    seed = seed_snapshot.data
    cells = LocalEvaluation::PAR_TYPES.to_h do |par_type|
      [par_type, LocalEvaluation::BENCHMARKS.to_h do |benchmark|
        args = seed.fetch("benchmarks").fetch(benchmark).fetch("args").fetch(par_type).map(&:to_s)
        [benchmark, { "status" => "resolved", "resolved" => true, "args" => args,
                      "timeout_seconds" => 30, "pilots" => [], "probes" => [] }]
      end]
    end
    manifest_path = File.join(@tmp, "evaluation_manifest.yaml")
    {
      "schema_version" => LocalEvaluation::SCHEMA_VERSION,
      "state" => "proposed",
      "seed_path" => seed_snapshot.path,
      "seed_sha256" => seed_snapshot.digest,
      "manifest_sha256" => LocalEvaluation.sha256_file(manifest_path),
      "validation_complete" => true,
      "validation_results_sha256" => LocalEvaluation.sha256_file(File.join(@tmp, "validation", "all_validation_results.yaml")),
      "cells" => cells
    }
  end

  def make_executable(path)
    LocalEvaluation.atomic_write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
  end

  def install_frozen_config
    config_path = File.join(@tmp, "benchmark_config.yaml")
    LocalEvaluation.atomic_yaml(config_path, complete_proposal.merge("state" => "frozen"))
    digest = LocalEvaluation.sha256_file(config_path)
    LocalEvaluation.atomic_write("#{config_path}.sha256", "#{digest}\n")
    digest
  end

  def attempt_execution(label, success, wall_seconds)
    { "repetition" => label, "success" => success, "wall_seconds" => wall_seconds }
  end

  def write_attempt_metadata(id, info, config_digest, success:, metrics:, executions: nil,
                             args: nil, timeout: nil)
    config = LocalEvaluation.load_yaml(File.join(@tmp, "benchmark_config.yaml"))
    cell = config.fetch("cells").fetch(info.fetch("par_type")).fetch(info.fetch("benchmark"))
    executions ||= [attempt_execution("warmup", true, 0.5)] +
                   BENCHMARK_COUNT.times.map { |index| attempt_execution(index, true, 1.0 + index) }
    measured_walls = executions.drop(1).map { |entry| entry.fetch("wall_seconds") }
    all_walls = executions.map { |entry| entry.fetch("wall_seconds") }
    LocalEvaluation.atomic_yaml(File.join(@tmp, "benchmark", id, "benchmark_metadata.yaml"), {
      "run" => info,
      "args" => args || cell.fetch("args").map(&:to_s),
      "timeout_seconds" => timeout || cell.fetch("timeout_seconds"),
      "configuration_sha256" => config_digest,
      "wall_seconds" => measured_walls,
      "warmup_wall_seconds" => all_walls.first,
      "all_execution_wall_seconds" => all_walls,
      "executions" => executions,
      "success" => success,
      "metrics" => metrics
    })
  end
end
