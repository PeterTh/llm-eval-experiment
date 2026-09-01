require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/local_evaluation"

class RuntimeHardeningTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("local-evaluation-hardening-", "/tmp")
  end

  def teardown
    make_tree_writable(@tmp)
    FileUtils.remove_entry(@tmp) if File.directory?(@tmp)
  end

  def test_substring_filter_rejects_zero_matches
    write_manifest("matmul_model_omp_r1" => run_info)
    manifest = LocalEvaluation::Manifest.new(@tmp)
    error = assert_raises(RuntimeError) { manifest.filtered_runs(filter: "does-not-exist") }
    assert_match(/No run IDs contain filter/, error.message)
  end

  def test_source_staging_bounds_total_bytes_and_entry_count
    source_root = make_stage_source
    benchmark_dir = File.join(source_root, "matmul")
    with_replaced_constant(LocalEvaluation::BuildSupport, :MAX_STAGED_SOURCE_BYTES, 8) do
      File.binwrite(File.join(benchmark_dir, "large.cpp"), "x" * 9)
      error = assert_raises(RuntimeError) do
        LocalEvaluation::BuildSupport.stage_source(
          source_root: source_root, benchmark: "matmul", stage_root: File.join(@tmp, "byte-stage")
        )
      end
      assert_match(/exceeds 8 bytes/, error.message)
    end

    FileUtils.rm_f(File.join(benchmark_dir, "large.cpp"))
    with_replaced_constant(LocalEvaluation::BuildSupport, :MAX_STAGED_SOURCE_ENTRIES, 3) do
      3.times { |index| File.write(File.join(benchmark_dir, "entry#{index}.txt"), "x") }
      error = assert_raises(RuntimeError) do
        LocalEvaluation::BuildSupport.stage_source(
          source_root: source_root, benchmark: "matmul", stage_root: File.join(@tmp, "entry-stage")
        )
      end
      assert_match(/exceeds 3 entries/, error.message)
    end
  end

  def test_read_only_local_workspace_cleanup_is_bounded_and_complete
    workspace = Dir.mktmpdir("local-evaluation-timing-correction-", "/tmp")
    nested = File.join(workspace, "source", "bench")
    FileUtils.mkdir_p(nested)
    File.write(File.join(nested, "main.cpp"), "int main() {}\n")
    File.chmod(0o444, File.join(nested, "main.cpp"))
    File.chmod(0o555, nested)
    File.chmod(0o555, File.dirname(nested))

    assert LocalEvaluation::BuildSupport.remove_local_temporary_workspace!(
      workspace, required_prefix: "local-evaluation-timing-correction-"
    )
    refute File.exist?(workspace)
    error = assert_raises(LocalEvaluation::InfrastructureError) do
      LocalEvaluation::BuildSupport.remove_local_temporary_workspace!(
        @tmp, required_prefix: "local-evaluation-timing-correction-"
      )
    end
    assert_match(/Refusing/, error.message)
  end

  def test_validation_resume_requeues_missing_artifacts_and_executable
    id = "matmul_model_omp_r1"
    info = run_info
    write_manifest(id => info)
    pipeline = LocalEvaluation::ValidationPipeline.new(run_dir: @tmp, exact_id: id, dry_run: true)
    result = ValidationResult.new("matmul", "model", "omp", 1)
    result.basic_para = result.validation_build = true
    output_dir = File.join(@tmp, "validation", id)
    FileUtils.mkdir_p(File.join(output_dir, "source", "matmul"))
    File.write(File.join(output_dir, "source", "matmul", "CMakeLists.txt"), "project(test)\n")
    File.write(File.join(output_dir, "source_staging.yaml"), "--- {}\n")
    File.write(File.join(output_dir, VALIDATION_RESULT_FN), "Build PASSED\n")
    %w[cmake build].each { |prefix| write_command_artifacts(output_dir, prefix) }
    executable = File.join(output_dir, "matmul")
    File.write(executable, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, executable)
    write_validation_metadata(output_dir, id, info, result)

    assert pipeline.send(:completed?, id, info, result)
    FileUtils.rm_f(executable)
    refute pipeline.send(:completed?, id, info, result)
    File.write(executable, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, executable)
    FileUtils.rm_f(File.join(output_dir, "build_exitcode.log"))
    refute pipeline.send(:completed?, id, info, result)
  end

  def test_generated_executable_must_match_historical_build_root_layout
    build_dir = File.join(@tmp, "build")
    nested = File.join(build_dir, "bin", "matmul")
    FileUtils.mkdir_p(File.dirname(nested))
    File.write(nested, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, nested)

    error = assert_raises(RuntimeError) do
      LocalEvaluation::BuildSupport.find_executable(build_dir, "matmul")
    end
    assert_match(%r{not found at .*/build/matmul}, error.message)

    direct = File.join(build_dir, "matmul")
    File.write(direct, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, direct)
    assert_equal direct, LocalEvaluation::BuildSupport.find_executable(build_dir, "matmul")
  end

  def test_validation_global_results_reject_duplicate_and_unknown_ids
    id = "matmul_model_omp_r1"
    write_manifest(id => run_info)
    pipeline = LocalEvaluation::ValidationPipeline.new(run_dir: @tmp, exact_id: id, dry_run: true)
    result = ValidationResult.new("matmul", "model", "omp", 1)
    path = File.join(@tmp, "validation", "all_validation_results.yaml")
    LocalEvaluation.atomic_yaml(path, [result, result])
    assert_match(/duplicate run ID/, assert_raises(RuntimeError) { pipeline.send(:load_results) }.message)
    LocalEvaluation.atomic_yaml(path, [ValidationResult.new("matmul", "unknown", "omp", 1)])
    assert_match(/unknown run ID/, assert_raises(RuntimeError) { pipeline.send(:load_results) }.message)
  end

  def test_gpu_inventory_and_numa_topology_parsing
    resources = LocalEvaluation::Resources.new
    inventory = resources.send(:parse_gpu_inventory, "0, NVIDIA GeForce RTX 3090, 24576\n")
    assert_equal 0, inventory.first["index"]
    assert_equal 24_576, inventory.first["memory_mib"]
    topology = resources.send(:parse_gpu_topology, <<~TEXT)
      GPU0\tGPU1\tCPU Affinity\tNUMA Affinity\tGPU NUMA ID
      GPU0\t X \tSYS\t0-63,128-191\t0\t\tN/A
      GPU1\tSYS\t X \t64-127,192-255\t1\t\tN/A
    TEXT
    assert_equal 0, topology.fetch(0).fetch("numa_node")
    assert_equal 1, topology.fetch(1).fetch("numa_node")
    assert_equal "64-127,192-255", topology.fetch(1).fetch("cpu_affinity")
  end

  def test_process_runner_cleans_parallel_environment_and_pins_compilers
    prefix = File.join(@tmp, "clean-env")
    originals = %w[OMP_NUM_THREADS CUDA_VISIBLE_DEVICES CXXFLAGS].to_h { |key| [key, ENV[key]] }
    ENV["OMP_NUM_THREADS"] = "999"
    ENV["CUDA_VISIBLE_DEVICES"] = "3"
    ENV["CXXFLAGS"] = "-funexpected"
    code = 'require "json"; puts JSON.generate(ENV.select { |k, _| %w[OMP_NUM_THREADS CUDA_VISIBLE_DEVICES CXXFLAGS CC CXX].include?(k) })'
    result = LocalEvaluation::ProcessRunner.new.run(
      argv: [RbConfig.ruby, "-e", code], prefix: prefix, env: { "OMP_NUM_THREADS" => "8" }, timeout: 3
    )
    assert result.success
    observed = JSON.parse(File.read("#{prefix}_stdout.log"))
    assert_equal "8", observed["OMP_NUM_THREADS"]
    refute observed.key?("CUDA_VISIBLE_DEVICES")
    refute observed.key?("CXXFLAGS")
    assert_equal LocalEvaluation::C_COMPILER, observed["CC"]
    assert_equal LocalEvaluation::CXX_COMPILER, observed["CXX"]
  ensure
    originals&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def test_build_scope_records_cpu_network_and_filesystem_io_caps
    skip "user-systemd cgroup containment unavailable" unless LocalEvaluation::SystemdContainment.available?
    prefix = File.join(@tmp, "contained")
    result = LocalEvaluation::ProcessRunner.new.run(
      argv: ["/bin/true"], prefix: prefix, timeout: 3, limits: LocalEvaluation::ExecutionLimits::BUILD
    )
    assert result.success
    log = File.read("#{prefix}_command.log")
    assert_includes log, "allowed_cpus=0-15"
    assert_includes log, "cpu_quota_percent=1600"
    assert_includes log, "io_write_bandwidth_bytes_per_second=16777216"
    assert_match(%r{io_write_device: /dev/}, log)
    assert_includes log, "network_policy: deny external; allow localhost"
    assert_includes log, "IPAddressDeny\\=any"
    assert_includes log, "AllowedCPUs\\=0-15"
    assert_includes log, "IOWriteBandwidthMax\\="
  end

  def test_host_performance_lock_is_exclusive
    first = LocalEvaluation::HostPerformanceLock.new
    assert_raises(RuntimeError) { LocalEvaluation::HostPerformanceLock.new }
  ensure
    first&.close
  end

  private

  def run_info
    {
      "benchmark" => "matmul", "model" => "model", "par_type" => "omp", "run" => 1,
      "batch" => "20260101-000000", "source_path" => File.join(@tmp, "source"), "source_error" => nil
    }
  end

  def write_manifest(runs)
    LocalEvaluation.atomic_yaml_with_digest(File.join(@tmp, "evaluation_manifest.yaml"), {
      "schema_version" => LocalEvaluation::SCHEMA_VERSION, "batches" => ["20260101-000000"],
      "benchmarks_root" => File.join(@tmp, "benchmarks"), "runs" => runs
    })
  end

  def make_stage_source
    root = File.join(@tmp, "raw")
    directory = File.join(root, "matmul")
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "CMakeLists.txt"), "project(test)\n")
    root
  end

  def with_replaced_constant(owner, name, value)
    original = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name) if owner.const_defined?(name, false)
    owner.const_set(name, original)
  end

  def write_command_artifacts(directory, prefix)
    %w[command stdout stderr exitcode wall_time].each do |suffix|
      File.write(File.join(directory, "#{prefix}_#{suffix}.log"), suffix == "exitcode" ? "0" : "log\n")
    end
  end

  def write_validation_metadata(directory, id, info, result)
    LocalEvaluation.atomic_yaml(File.join(directory, "validation_metadata.yaml"), {
      "id" => id, "benchmark" => info.fetch("benchmark"), "model" => info.fetch("model"),
      "par_type" => info.fetch("par_type"), "run" => info.fetch("run"),
      "manifest_sha256" => LocalEvaluation.sha256_file(File.join(@tmp, "evaluation_manifest.yaml")),
      "stages" => {
        "basic_para" => !!result.basic_para, "validation_build" => !!result.validation_build,
        "validation_run" => !!result.validation_run, "internal_validation" => !!result.internal_validation,
        "output_comparison" => !!result.output_comparison
      }
    })
  end

  def make_tree_writable(root)
    return unless File.exist?(root)
    Find.find(root) do |path|
      next if File.symlink?(path)
      mode = File.stat(path).mode
      File.chmod(mode | (File.directory?(path) ? 0o700 : 0o600), path)
    rescue Errno::ENOENT
      nil
    end
  end
end
