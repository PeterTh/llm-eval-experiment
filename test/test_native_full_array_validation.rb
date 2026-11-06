# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/native_full_array_validation'

class NativeFullArrayValidationTest < Minitest::Test
  Native = ValidationAudit::NativeFullArray
  Capture = ValidationAudit::FullArrayCapture

  def setup
    @root = Dir.mktmpdir('native-full-array-test-', '/tmp')
    @session = Native::Session.new
    @calls = []
    @actual_values = [1.0, 2.000001]
    @incomplete = false
    @reference = File.join(@root, 'reference')
    prepare_source(@reference)
  end

  def teardown
    @session.close
    FileUtils.remove_entry(@root)
    # An infrastructure-failure test deliberately leaves its workspace for
    # inspection; remove only that exact test-created path after assertions.
    if File.exist?(@session.workspace)
      LocalEvaluation::BuildSupport.remove_local_temporary_workspace!(@session.workspace, required_prefix: 'local-full-array-validation-')
    end
  end

  def prepare_source(directory)
    FileUtils.mkdir_p(File.join(directory, 'source/common'))
    FileUtils.mkdir_p(File.join(directory, 'source/black-scholes'))
    File.write(File.join(directory, 'source/common/hash.hpp'), 'fixture helper')
    File.write(File.join(directory, 'source/black-scholes/black-scholes.cpp'), 'fixture program')
    File.write(File.join(directory, 'black_scholes'), 'fixture executable')
    File.chmod(0o755, File.join(directory, 'black_scholes'))
  end

  def fake_capture(**args)
    @calls << args
    values = args.fetch(:backend) == 'sequential' ? [1.0, 2.0] : @actual_values
    local = File.join(args.fetch(:workspace), args.fetch(:phase), args.fetch(:id), 'rank-single')
    FileUtils.mkdir_p(local)
    bytes = values.pack('E*')
    path = File.join(local, 'array-0000.f64le')
    File.binwrite(path, bytes)
    object = { 'name' => 'OptionPrices', 'dtype' => 'f64le', 'elements' => 2, 'bytes' => bytes.bytesize,
      'sha256' => Digest::SHA256.hexdigest(bytes), 'fnv1a64' => Capture.fnv(bytes),
      'local_path' => path, 'rank' => 'rank-single' }
    stdout = "Validation: PASSED\n=== RESULTS ===\nName: OptionPrices\nElements: 2\n" \
      "Sample[0]: 1\nHash: #{object.fetch('fnv1a64')}\n=== END RESULTS ===\n"
    observation = { 'id' => args.fetch(:id), 'benchmark' => args.fetch(:benchmark), 'backend' => args.fetch(:backend),
      'args' => args.fetch(:args), 'objects' => [object], 'printed_objects' => Capture.output_objects(stdout),
      'errors' => @incomplete && args.fetch(:backend) != 'sequential' ? ['Cannot read memory'] : [],
      'observation_complete' => !(@incomplete && args.fetch(:backend) != 'sequential') }
    destination = File.join(args.fetch(:evidence), args.fetch(:phase), args.fetch(:id))
    ValidationAudit.save(File.join(destination, 'observation.json'), observation)
    Native::LOG_PARTS.each do |part|
      File.write(File.join(destination, "validation_#{part}.log"), part == 'stdout' ? stdout : "0\n")
    end
    observation
  end

  def check(id = 'black-scholes_fixture_omp_r1')
    directory = File.join(@root, id)
    prepare_source(directory)
    entry = Capture.stub(:capture, method(:fake_capture)) do
      @session.check(id: id, benchmark: 'black-scholes', backend: 'omp',
        executable: File.join(directory, 'black_scholes'), source_root: File.join(directory, 'source'),
        reference_executable: File.join(@reference, 'black_scholes'), reference_source_root: File.join(@reference, 'source'),
        output_dir: directory)
    end
    [entry, directory]
  end

  def test_definition_preserves_piloted_sizes_and_allocation
    assert_nil Native.definition('floydwarshall')
    LocalEvaluation::ShapeValidationCases::ARGUMENTS.each do |benchmark, args|
      next if benchmark == 'floydwarshall'
      definition = Native.definition(benchmark)
      assert_equal args, definition.fetch('args').drop(2)
      assert_equal 'validation', definition.fetch('topology')
      assert_equal 30, definition.fetch('timeout')
    end
  end

  def test_reference_is_reused_and_success_needs_no_bulk_array_copy
    entry, directory = check
    assert entry.fetch('passed')
    assert Native.cache_valid?(directory, entry, benchmark: 'black-scholes', id: 'black-scholes_fixture_omp_r1', passed: true)
    second, = check('black-scholes_fixture_omp_r2')
    assert second.fetch('passed')
    assert_equal 3, @calls.size
    assert_equal 1, @calls.count { |call| call.fetch(:backend) == 'sequential' }
    assert_empty Dir[File.join(directory, 'full-array/failure-arrays/*')]
    assert_equal 'fixture program', File.read(File.join(directory, 'source/black-scholes/black-scholes.cpp'))
    exported = Native.export_files(directory, entry, benchmark: 'black-scholes', id: 'black-scholes_fixture_omp_r1', passed: true)
    assert_equal %w[actual.json comparison.json receipt.json reference.json], exported.map(&:last)
    File.write(File.join(directory, 'full-array/actual.json'), '{}')
    refute Native.cache_valid?(directory, entry, benchmark: 'black-scholes', id: 'black-scholes_fixture_omp_r1', passed: true)
  end

  def test_failure_retains_complete_reference_and_actual_bytes
    @actual_values = [1.0, 25.5]
    entry, directory = check
    refute entry.fetch('passed')
    assert entry.fetch('sparse_comparison').first
    assert_equal 1, entry.fetch('arrays').first.fetch('mismatches')
    assert_equal 2, Dir[File.join(directory, 'full-array/failure-arrays/*.json')].size
    assert Native.cache_valid?(directory, entry, benchmark: 'black-scholes', id: 'black-scholes_fixture_omp_r1', passed: false)
    exported = Native.export_files(directory, entry, benchmark: 'black-scholes', id: 'black-scholes_fixture_omp_r1', passed: false)
    assert_equal 6, exported.size
    assert exported.all? { |_path, name| name.end_with?('.json') }
  end

  def test_observer_gap_remains_infrastructure_and_retains_review_evidence
    @incomplete = true
    assert_raises(LocalEvaluation::InfrastructureError) { check }
    id = 'black-scholes_fixture_omp_r1'
    directory = File.join(@root, id)
    error = JSON.parse(File.read(File.join(directory, 'full_array_infrastructure_error.json')))
    assert_nil error.fetch('scientific_verdict')
    assert_equal @session.workspace, error.fetch('local_workspace')
    assert File.file?(File.join(directory, 'full-array-incomplete/native-full-array', id, 'observation.json'))
    refute File.exist?(File.join(directory, 'full-array/receipt.json'))
    @session.close
    assert File.directory?(@session.workspace)
  end

  def test_successful_cache_is_bound_to_the_original_executable
    entry, directory = check
    File.write(File.join(directory, 'black_scholes'), 'different executable')
    refute Native.cache_valid?(directory, entry, benchmark: 'black-scholes', id: 'black-scholes_fixture_omp_r1', passed: true)
  end

  def test_reviewed_additive_observer_update_reuses_only_unaffected_methods
    old = Native::PRE_STREAMED_OPTIONS_METHOD
    assert Native.compatible_methods?(old, binary_sha256: 'unaffected')
    refute Native.compatible_methods?(old, binary_sha256: '82bcac98d064d0427fb90ffd229fc4a03796fa39fd329e38c40e9173366f1873')
    old.each_key do |name|
      refute Native.compatible_methods?(old.merge(name => 'unknown'), binary_sha256: 'unaffected')
    end
    assert Native.compatible_methods?(Native.methods, binary_sha256: '82bcac98d064d0427fb90ffd229fc4a03796fa39fd329e38c40e9173366f1873')
  end
end
