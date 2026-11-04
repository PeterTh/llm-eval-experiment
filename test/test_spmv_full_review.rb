# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/spmv_full_review'

class SpmvFullReviewTest < Minitest::Test
  def test_device_absence_is_not_a_scientific_failure_or_a_successful_cuda_dump
    text, metadata = ValidationAudit::SpmvFullReview.inspection_output('',
      "cuobjdump info : File 'fixture' does not contain device code\n", 1, optional_device: true)
    assert_includes text, 'does not contain device code'
    assert_equal false, metadata.fetch('available')
    assert_equal 1, metadata.fetch('exit_code')
    assert_raises(RuntimeError) do
      ValidationAudit::SpmvFullReview.inspection_output('', 'cannot open file', 1, optional_device: true)
    end
    assert_raises(RuntimeError) do
      ValidationAudit::SpmvFullReview.inspection_output('', 'does not contain device code', 1)
    end
    assert_equal ['assembly', { 'available' => true, 'exit_code' => 0 }],
      ValidationAudit::SpmvFullReview.inspection_output('assembly', '', 0)
  end

  def test_preparation_and_progress_do_not_assign_verdicts_or_run_programs
    source = File.read(File.expand_path('../tools/validation_audit/spmv_full_review.rb', __dir__))
    assert_includes source, "['objdump', '-d'"
    assert_includes source, "['cuobjdump', \"--dump-#{'#{format}'}\""
    assert_includes source, "raise 'Full static review not authorized'"
    assert_includes source, "raise 'Do not overwrite reusable pilot'"
    assert_includes source, 'SpmvWorkCount.reviewed_pack(pack, review)'
    refute_match(/BenchmarkPipeline|benchmark_times|Runner\.new/, source)
  end

  def test_missing_authorization_is_not_treated_as_permission
    Dir.mktmpdir('spmv-full-review-test-', '/tmp') do |directory|
      review = ValidationAudit::SpmvFullReview.new(workspace: directory, evidence: directory)
      assert_raises(Errno::ENOENT) { review.load_scope }
    end
  end

  def with_retained_review
    Dir.mktmpdir('spmv-retained-review-test-', '/tmp') do |directory|
      File.write(File.join(directory, 'source.cpp'), "for (int i = 0; i < iterations; ++i) { compute(); }\n")
      File.write(File.join(directory, 'host-assembly.txt'), "call compute\njne iteration\n")
      pack = {
        'source' => { 'id' => 'spmv_fixture_omp_r1', 'source_path' => 'fixture',
          'source_commit' => 'a' * 40, 'staged_source_sha256' => 'b' * 64,
          'source_files' => { 'source.cpp' => { 'sha256' => ValidationAudit.sha(File.join(directory, 'source.cpp')),
            'git_blob' => 'c' * 40 } } },
        'local_directory' => directory, 'binary_sha256' => 'd' * 64, 'binding_sha256' => 'e' * 64,
        'inspections' => { 'host-assembly.txt' => {
          'sha256' => ValidationAudit.sha(File.join(directory, 'host-assembly.txt')),
          'command' => ['objdump', '-d', 'fixture'] } }
      }
      input = { 'id' => 'spmv_fixture_omp_r1', 'finding' => 'no_work_count_omission_identified',
        'summary' => 'Synthetic evidence-verification fixture, not a scientific verdict.',
        'source_evidence' => [{ 'file' => 'source.cpp', 'ranges' => [[1, 1]], 'claim' => 'Iteration call.' }],
        'compiled_evidence' => [{ 'file' => 'host-assembly.txt', 'ranges' => [[1, 2]], 'claim' => 'Call and backedge.' }] }
      yield pack, ValidationAudit::SpmvWorkCount.reviewed_pack(pack, input)
    end
  end

  def test_retained_evidence_is_checked_against_its_bound_files
    with_retained_review do |pack, review|
      assert ValidationAudit::SpmvFullReview.verify_retained_review(pack, review)
      review['compiled_evidence'][0]['excerpts'][0]['text'] = "invented instruction\n"
      error = assert_raises(RuntimeError) { ValidationAudit::SpmvFullReview.verify_retained_review(pack, review) }
      assert_equal 'Retained compiled excerpt differs', error.message
    end
  end

  def test_changed_source_or_dump_cannot_validate_retained_evidence
    with_retained_review do |pack, review|
      File.write(File.join(pack.fetch('local_directory'), 'source.cpp'), "changed source\n")
      assert_raises(RuntimeError) { ValidationAudit::SpmvFullReview.verify_retained_review(pack, review) }
    end
    with_retained_review do |pack, review|
      File.write(File.join(pack.fetch('local_directory'), 'host-assembly.txt'), "changed dump\n")
      assert_raises(RuntimeError) { ValidationAudit::SpmvFullReview.verify_retained_review(pack, review) }
    end
  end

  def test_unresolved_findings_and_missing_evidence_are_not_completion
    with_retained_review do |pack, original|
      [{ 'finding' => 'uncertain' }, { 'summary' => ' ' }, { 'source_evidence' => [] },
       { 'compiled_evidence' => [] }, { 'binary_sha256' => 'wrong' }, { 'source' => {} }].each do |change|
        assert_raises(RuntimeError) { ValidationAudit::SpmvFullReview.verify_retained_review(pack, original.merge(change)) }
      end
    end
    Dir.mktmpdir('spmv-incomplete-test-', '/tmp') do |directory|
      review = ValidationAudit::SpmvFullReview.new(workspace: directory, evidence: directory)
      review.stub(:verify, { 'remaining' => 1 }) do
        assert_raises(RuntimeError) { review.finish }
      end
      refute File.exist?(File.join(directory, 'spmv-work-count-full/completion.json'))
    end
  end

  def test_proposal_check_preserves_uncertainty_and_record_refuses_it
    with_retained_review do |pack, retained|
      directory = pack.fetch('local_directory')
      proposed = retained.merge('finding' => 'uncertain',
        'compiled_evidence' => [{ 'file' => 'host-assembly.txt', 'ranges' => [[1, 2]], 'claim' => 'Needs adjudication.' }])
      manual = { 'reviewer' => 'test inspector', 'review_started_at' => '2026-11-04T10:00:00Z',
        'review_finished_at' => '2026-11-04T10:01:00Z', 'reviews' => [proposed] }
      path = File.join(directory, 'proposal.json')
      File.write(path, JSON.generate(manual))
      review = ValidationAudit::SpmvFullReview.new(workspace: directory, evidence: directory)
      review.stub(:load_scope, [[pack.fetch('source')], []]) do
        review.stub(:checked_pack, pack) do
          result = review.check(path)
          assert_equal 'proposal_bindings_verified_not_a_scientific_verdict', result.fetch('status')
          assert_equal({ 'uncertain' => 1 }, result.fetch('findings'))
          assert_equal [proposed.fetch('id')], result.fetch('uncertain_ids')
          assert_raises(RuntimeError) { review.record(path) }
          refute Dir.exist?(File.join(directory, 'spmv-work-count-full/reviews'))
          manual['reviews'] << proposed
          File.write(path, JSON.generate(manual))
          assert_raises(RuntimeError) { review.check(path) }
        end
      end
    end
  end

  def test_delegated_review_requires_zero_activity_and_primary_acceptance
    with_retained_review do |pack, retained|
      directory = pack.fetch('local_directory')
      proposed = retained.merge('compiled_evidence' => [
        { 'file' => 'host-assembly.txt', 'ranges' => [[1, 2]], 'claim' => 'Call and loop.' }])
      manual = { 'reviewer' => 'test inspector', 'reviewer_model' => 'test model',
        'review_started_at' => '2026-11-04T10:00:00Z', 'review_finished_at' => '2026-11-04T10:01:00Z',
        'reviews' => [proposed], 'program_executions' => 0, 'compilation' => 0,
        'program_changes' => 0, 'benchmark_runs' => 0 }
      path = File.join(directory, 'proposal.json')
      review = ValidationAudit::SpmvFullReview.new(workspace: directory, evidence: directory)
      review.stub(:load_scope, [[pack.fetch('source')], []]) do
        review.stub(:checked_pack, pack) do
          File.write(path, JSON.generate(manual))
          assert_equal 1, review.check(path).fetch('reviews')
          error = assert_raises(RuntimeError) { review.record(path) }
          assert_equal 'Delegated review requires primary quality acceptance', error.message
          %w[program_executions compilation program_changes benchmark_runs].each do |key|
            File.write(path, JSON.generate(manual.merge(key => 1)))
            assert_raises(RuntimeError) { review.check(path) }
            File.write(path, JSON.generate(manual.reject { |name, _| name == key }))
            assert_raises(RuntimeError) { review.check(path) }
          end
          refute Dir.exist?(File.join(directory, 'spmv-work-count-full/reviews'))
        end
      end
    end
  end

  def test_retained_static_activity_checks_compilation_and_missing_counters
    fields = %w[program_executions compilation benchmark_runs program_changes]
    activity = fields.to_h { |key| [key, 0] }
    assert ValidationAudit::SpmvFullReview.verify_static_activity(activity)
    fields.each do |key|
      assert_raises(RuntimeError) { ValidationAudit::SpmvFullReview.verify_static_activity(activity.merge(key => 1)) }
      assert_raises(RuntimeError) { ValidationAudit::SpmvFullReview.verify_static_activity(activity.reject { |name, _| name == key }) }
    end
  end

  def test_exact_review_inputs_are_retained_once_and_never_overwritten
    Dir.mktmpdir('spmv-input-archive-test-', '/tmp') do |directory|
      review = ValidationAudit::SpmvFullReview.new(workspace: directory, evidence: directory)
      input = File.join(directory, 'input.json')
      bytes = "{\"fixture\": true}\n"
      File.binwrite(input, bytes)
      digest = review.retain_review_input(input)
      assert_equal Digest::SHA256.hexdigest(bytes), digest
      archived = File.join(review.root, 'review-inputs', digest + '.json')
      assert_equal bytes, File.binread(archived)
      assert_equal digest, review.retain_review_input(input)
      assert_equal 1, Dir.glob(File.join(review.root, 'review-inputs', '*.json')).size
      File.binwrite(archived, 'changed')
      assert_raises(RuntimeError) { review.retain_review_input(input) }
      assert_equal 'changed', File.binread(archived)
    end
  end

  def test_legacy_schema_preserves_only_the_known_missing_compilation_counter
    activity = { 'program_executions' => 0, 'benchmark_runs' => 0, 'program_changes' => 0 }
    assert ValidationAudit::SpmvFullReview.verify_static_activity(activity, legacy_schema: true)
    assert_raises(RuntimeError) { ValidationAudit::SpmvFullReview.verify_static_activity(activity) }
    assert_raises(RuntimeError) do
      ValidationAudit::SpmvFullReview.verify_static_activity(activity.merge('compilation' => 1), legacy_schema: true)
    end
    activity.each_key do |key|
      assert_raises(RuntimeError) do
        ValidationAudit::SpmvFullReview.verify_static_activity(activity.reject { |name, _| name == key }, legacy_schema: true)
      end
    end
  end
end
