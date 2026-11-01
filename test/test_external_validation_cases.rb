# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/local_evaluation"

class ExternalValidationCasesTest < Minitest::Test
  Cases = LocalEvaluation::ExternalValidationCases
  ManifestStub = Struct.new(:path, :data)

  def setup
    @tmp = Dir.mktmpdir("external-validation-test-", "/tmp")
    @manifest = ManifestStub.new(File.join(@tmp, "manifest.yaml"), { "benchmark_repository" => { "commit" => "a" * 40 } })
    File.write(@manifest.path, "fixture\n")
    @source = File.join(@tmp, "input/unstructured")
    FileUtils.mkdir_p(@source)
    File.write(File.join(@source, "unstructured.cpp"), "MPI_Init MPI_Finalize MPI_Comm_rank MPI_Comm_size\n")
    File.write(File.join(@source, "CMakeLists.txt"), "fixture\n")
    @calls = []
    @extra_output = output(1024)
    owner = self
    @runner = Object.new
    @runner.define_singleton_method(:run) { |**args| owner.fake_run(**args) }
    @resources = Object.new
    @resources.define_singleton_method(:command) { |**args| [{}, [args.fetch(:executable), *args.fetch(:args)]] }
    @pipeline = LocalEvaluation::ValidationPipeline.allocate
    @pipeline.instance_variable_set(:@manifest, @manifest)
    @pipeline.instance_variable_set(:@validation_dir, File.join(@tmp, "validation"))
    @pipeline.instance_variable_set(:@runner, @runner)
    @pipeline.instance_variable_set(:@resources, @resources)
    @pipeline.instance_variable_set(:@supplemental_references, { Cases::UNSTRUCTURED_BOUNDARY.fetch("id") => output(1024) })
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def output(elements, min: -4, hash: "same")
    "Validation: PASSED\n=== RESULTS ===\nName: ElementEnergy\nElements: #{elements}\nSum: 0\nMin: #{min}\nMax: 4\nHash: #{hash}\n=== END RESULTS ===\n"
  end

  def fake_run(**args)
    @calls << args
    prefix = args.fetch(:prefix)
    bytes = args.fetch(:argv).include?("512") ? @extra_output : output(65_536)
    FileUtils.mkdir_p(File.dirname(prefix))
    %w[command stdout stderr exitcode wall_time].each do |suffix|
      File.write("#{prefix}_#{suffix}.log", suffix == "stdout" ? bytes : "0\n")
    end
    LocalEvaluation::ProcessRunner::Result.new(success: true, exit_code: 0, timed_out: false, wall_seconds: 0.01,
      argv: args.fetch(:argv), output_truncated: false)
  end

  def validate_one
    id = "unstructured_model_mpi_r1"
    info = { "benchmark" => "unstructured", "model" => "model", "par_type" => "mpi", "run" => 1,
      "source_path" => File.dirname(@source) }
    build = lambda do |**args|
      FileUtils.mkdir_p(args.fetch(:build_dir))
      executable = File.join(args.fetch(:build_dir), "unstructured")
      File.write(executable, "fixture executable\n")
      File.chmod(0o755, executable)
      [true, nil]
    end
    LocalEvaluation::BuildSupport.stub(:stage_source, @source) do
      LocalEvaluation::BuildSupport.stub(:build, build) { @pipeline.send(:validate_one, id, info, output(65_536)) }
    end
  end

  def test_scope_keeps_original_sizes_and_other_backends
    assert_equal %w[-n 256 -i 20], LocalEvaluation::ValidationPipeline::VALIDATION_SIZES.fetch("unstructured")
    %w[mpi hybrid].each { |backend| assert_equal [Cases::UNSTRUCTURED_BOUNDARY], Cases.cases_for("unstructured", backend) }
    %w[omp cuda].each { |backend| assert_empty Cases.cases_for("unstructured", backend) }
    assert_empty Cases.cases_for("stencil3d", "mpi")
  end

  def test_numerical_failure_is_only_external_validation
    @extra_output = output(1024, min: -4.02)
    result = validate_one
    assert result.basic_para
    assert result.validation_build
    assert result.validation_run
    assert result.internal_validation
    refute result.output_comparison
    assert_match(/Output comparison FAILED \(unstructured-boundary-v1\)/, result.err_string)
    assert_equal 2, @calls.size
    extra = @calls.last
    assert extra.fetch(:chdir).start_with?("/tmp/local-external-validation-")
    refute File.exist?(extra.fetch(:chdir))
    assert_equal Cases::UNSTRUCTURED_BOUNDARY.fetch("args"), extra.fetch(:argv).drop(1)
    assert_equal "MPI_Init MPI_Finalize MPI_Comm_rank MPI_Comm_size\n", File.read(File.join(@source, "unstructured.cpp"))
  end

  def test_pass_binds_additional_logs_and_does_not_require_hash_match
    @extra_output = output(1024, hash: "different")
    assert validate_one.output_comparison
    metadata = LocalEvaluation.load_yaml(File.join(@tmp, "validation/unstructured_model_mpi_r1/validation_metadata.yaml"))
    item = metadata.fetch("supplemental_validation").fetch(0)
    assert item.fetch("passed")
    assert_equal 5, item.fetch("logs").size
    assert_equal Digest::SHA256.hexdigest(output(1024)), item.fetch("reference_sha256")
  end

  def test_reference_is_executed_once_and_reused_without_rebuilding
    directory = File.join(@tmp, "validation/reference/unstructured")
    FileUtils.mkdir_p(directory)
    executable = File.join(directory, "unstructured")
    File.write(executable, "fixture executable\n")
    File.chmod(0o755, executable)
    first = @pipeline.send(:supplemental_reference_output, Cases::UNSTRUCTURED_BOUNDARY)
    assert_equal output(1024), first
    assert_equal first, @pipeline.send(:supplemental_reference_output, Cases::UNSTRUCTURED_BOUNDARY)
    assert_equal 1, @calls.size
    assert_equal "", @calls.first.fetch(:env).fetch("CUDA_VISIBLE_DEVICES")
  end

  def test_external_case_failure_categories
    execution = LocalEvaluation::ProcessRunner::Result.new(success: false, exit_code: 124, timed_out: true)
    refute Cases.assess(output(1024), output(1024), execution).first
    execution.success = true
    refute Cases.assess(output(1024), "Validation: FAILED\n", execution).first
    refute Cases.assess(output(1024), output(1024).sub("Elements: 1024", "Elements: 512"), execution).first
  end

  def test_cached_success_requires_intact_supplemental_evidence
    result = validate_one
    id = result.id_string
    directory = File.join(@tmp, "validation", id)
    FileUtils.mkdir_p(File.join(directory, "source/unstructured"))
    File.write(File.join(directory, "source/unstructured/CMakeLists.txt"), "fixture")
    File.write(File.join(directory, "source_staging.yaml"), "fixture: true\n")
    %w[cmake build].product(%w[command stdout stderr exitcode wall_time]).each do |stage, suffix|
      File.write(File.join(directory, "#{stage}_#{suffix}.log"), "0\n")
    end
    info = { "benchmark" => "unstructured", "model" => "model", "par_type" => "mpi", "run" => 1 }
    assert @pipeline.send(:validation_artifacts_intact?, id, info, result)
    path = File.join(directory, "validation_out_unstructured-boundary-v1_stdout.log")
    File.write(path, "corrupted output")
    refute @pipeline.send(:validation_artifacts_intact?, id, info, result)
    File.write(path, @extra_output)
    metadata_path = File.join(directory, "validation_metadata.yaml")
    metadata = LocalEvaluation.load_yaml(metadata_path)
    metadata.delete("supplemental_validation")
    LocalEvaluation.atomic_yaml(metadata_path, metadata)
    refute @pipeline.send(:validation_artifacts_intact?, id, info, result)
  end
end
