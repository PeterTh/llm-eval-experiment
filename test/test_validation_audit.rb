# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/export'
require_relative '../tools/validation_audit/shape_topology'

class ValidationAuditTest < Minitest::Test
  def test_stencil_case_moves_three_fixed_samples_into_interior
    args = ValidationAudit::Campaign::STENCIL.fetch('args')
    assert_equal LocalEvaluation::ExternalValidationCases::STENCIL_INTERIOR.fetch('args'), args
    x, y, z = %w[-x -y -z].map { |flag| Integer(args.fetch(args.index(flag) + 1)) }
    size = x * y * z
    points = [0, size / 4, size / 2, 3 * size / 4, size - 1].map { |i| [i % x, i / x % y, i / (x * y)] }
    assert_equal 3, points.count { |a, b, c| a.positive? && a < x - 1 && b.positive? && b < y - 1 && c.positive? && c < z - 1 }
    assert_equal 21, Integer(args.fetch(args.index('-i') + 1))
  end

  def test_archival_reuse_checks_exact_record_digest_and_path
    Dir.mktmpdir('validation-audit-test-', '/tmp') do |root|
      line = JSON.generate({ 'id' => 'fixture' }) + "\n"
      File.write(File.join(root, 'records.jsonl'), line)
      location = { 'path' => 'records.jsonl', 'line' => 1, 'line_sha256' => Digest::SHA256.hexdigest(line) }
      assert_equal 'fixture', ValidationAudit::Export.archive_record(root, location, {}).fetch('id')
      assert_raises(RuntimeError) { ValidationAudit::Export.archive_record(root, location.merge('line_sha256' => '0' * 64), {}) }
      assert_raises(RuntimeError) { ValidationAudit::Export.archive_record(root, location.merge('path' => '../records.jsonl'), {}) }
    end
  end

  def test_native_and_canonical_source_bindings_are_recognized
    assert_equal 'digest-a', ValidationAudit.archived_source_digest({ 'source_staging' => { 'content_sha256' => 'digest-a' } })
    assert_equal 'digest-b', ValidationAudit.archived_source_digest({ 'source' => { 'content_sha256' => 'digest-b' } })
    assert_nil ValidationAudit.archived_source_digest({})
  end

  def test_no_benchmark_pipeline_or_measurement_writer_is_invoked
    path = File.expand_path('../tools/validation_audit/runner.rb', __dir__)
    source = File.read(path)
    refute_match(/BenchmarkPipeline|BenchmarkMetrics|benchmark_metadata|benchmark_times/, source)
    assert_includes source, "'performance_measurement' => false"
  end

  def test_topology_suite_uses_adequate_nondivisible_mpi_domains
    %w[cahn-hilliard stencil3d].each do |benchmark|
      definition = ValidationAudit::ShapeTopologyCampaign.definition(benchmark, 'mpi')
      args = definition.fetch('args')
      assert_equal '257', args.fetch(args.index('-z') + 1)
      %w[-x -y -z].each { |flag| assert_operator Integer(args.fetch(args.index(flag) + 1)), :>, 128 }
      assert definition.fetch('id').end_with?('-v2')
      assert_equal 'measurement', definition.fetch('topology')
    end
    definition = ValidationAudit::ShapeTopologyCampaign.definition('unstructured', 'mpi')
    args = definition.fetch('args')
    assert_equal '257', args.fetch(args.index('-n') + 1)
    assert_equal 'integer_hash', ValidationAudit::ShapeTopologyCampaign.definition('floydwarshall', 'omp').fetch('comparison')
    assert_includes ValidationAudit::ShapeTopologyCampaign.definition('roomsim', 'cuda').fetch('args'), '-o'
  end

  def test_method_snapshot_is_immutable_and_omits_user_campaign_configuration
    Dir.mktmpdir('validation-method-test-', '/tmp') do |directory|
      first = ValidationAudit::MethodSnapshot.save(directory, 'fixture-pilot')
      assert_equal first, ValidationAudit::MethodSnapshot.save(directory, 'fixture-pilot')
      refute_includes first.fetch('files_sha256').keys, 'experiment.rb'
      File.write(File.join(directory, 'method/fixture-pilot/validation_helper.rb'), 'changed')
      assert_raises(RuntimeError) { ValidationAudit::MethodSnapshot.save(directory, 'fixture-pilot') }
      assert_raises(RuntimeError) { ValidationAudit::MethodSnapshot.save(directory, '../escape') }
    end
  end

  def test_integer_policy_invalidates_cached_success_but_not_prior_failure
    Dir.mktmpdir('validation-policy-test-', '/tmp') do |directory|
      id = 'floydwarshall_model_omp_r1'
      info = { 'benchmark' => 'floydwarshall', 'model' => 'model', 'par_type' => 'omp', 'run' => 1 }
      manifest = File.join(directory, 'manifest.yaml')
      File.write(manifest, 'fixture')
      pipeline = LocalEvaluation::ValidationPipeline.allocate
      pipeline.instance_variable_set(:@manifest, Struct.new(:path).new(manifest))
      pipeline.instance_variable_set(:@validation_dir, directory)
      result = ValidationResult.new('floydwarshall', 'model', 'omp', 1)
      target = File.join(directory, id)
      FileUtils.mkdir_p(File.join(target, 'source/floydwarshall'))
      %w[source/floydwarshall/CMakeLists.txt source_staging.yaml floydwarshall].each { |name| File.write(File.join(target, name), 'fixture') }
      File.chmod(0o755, File.join(target, 'floydwarshall'))
      File.write(File.join(target, VALIDATION_RESULT_FN), 'fixture')
      %w[cmake build validation_out].product(%w[command stdout stderr exitcode wall_time]).each do |stage, suffix|
        File.write(File.join(target, "#{stage}_#{suffix}.log"), "0\n")
      end
      stages = %w[basic_para validation_build validation_run internal_validation output_comparison]
      metadata = info.merge('id' => id, 'manifest_sha256' => ValidationAudit.sha(manifest), 'stages' => stages.to_h { |stage| [stage, false] })
      LocalEvaluation.atomic_yaml(File.join(target, 'validation_metadata.yaml'), metadata)
      assert pipeline.send(:validation_artifacts_intact?, id, info, result)
      stages.each { |stage| result.public_send("#{stage}=", true) }
      metadata['stages'].transform_values! { true }
      LocalEvaluation.atomic_yaml(File.join(target, 'validation_metadata.yaml'), metadata)
      refute pipeline.send(:validation_artifacts_intact?, id, info, result)
      metadata['comparison_policy'] = LocalEvaluation::ComparisonPolicy::FLOYD_INTEGER_HASH
      metadata['supplemental_validation'] = LocalEvaluation::ExternalValidationCases.cases_for('floydwarshall', 'omp').map do |definition|
        prefix = File.join(target, "validation_out_#{definition.fetch('id')}")
        %w[command stdout stderr exitcode wall_time].each { |suffix| File.write("#{prefix}_#{suffix}.log", "0\n") }
        { 'id' => definition.fetch('id'), 'args' => definition.fetch('args'), 'definition' => definition,
          'passed' => true, 'logs' => LocalEvaluation::ExternalValidationCases.log_digests(prefix) }
      end
      LocalEvaluation.atomic_yaml(File.join(target, 'validation_metadata.yaml'), metadata)
      assert pipeline.send(:validation_artifacts_intact?, id, info, result)
    end
  end
end
