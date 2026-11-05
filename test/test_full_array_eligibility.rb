# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../tools/validation_audit/full_array_eligibility'

class FullArrayEligibilityTest < Minitest::Test
  Eligibility = ValidationAudit::FullArrayEligibility

  def groups
    %w[cuda hybrid mpi omp].map { |backend| { 'benchmark' => 'roomsim', 'backend' => backend, 'args' => %w[-v -n 320] } }
  end

  def record
    { 'id' => 'roomsim_fixture_omp_r1', 'comparison_sha256' => 'a' * 64, 'logs' => { 'stdout' => 'original output' },
      'comparison' => { 'passed' => false, 'source' => { 'id' => 'roomsim_fixture_omp_r1', 'benchmark' => 'roomsim',
        'source_commit' => 'b' * 40, 'source_path' => '20261105-000000/roomsim_fixture_omp_r1', 'validation_record' => {} },
        'sparse_comparison' => [true, 'matched summaries'],
        'arrays' => [{ 'name' => 'Distances', 'mismatches' => 1, 'elements' => 320,
          'absolute_tolerance' => 5.0, 'maximum_absolute_error' => 23.5 }] } }
  end

  def test_failure_is_presented_as_external_validation_with_bound_original_evidence
    definition = Eligibility.definition('roomsim', groups)
    location = Eligibility.location('/tmp/full-export', '/tmp/full-export/records/roomsim-omp-001.jsonl', 2, 'c' * 64)
    exclusion, evidence = Eligibility.rows(record, location, definition)
    assert_equal false, exclusion.dig('stages', 'output_comparison')
    assert exclusion.fetch('stages').reject { |key, _| key == 'output_comparison' }.values.all?
    assert_equal record.dig('comparison', 'source', 'source_commit'), evidence.dig('result', 'source_commit')
    assert_equal record.fetch('comparison_sha256'), evidence.dig('result', 'full_array_comparison_sha256')
    assert_equal location, evidence.dig('result', 'raw_evidence')
    assert_equal 'original output', evidence.dig('logs', 'stdout')
    assert_match(/1\/320.*tolerance 5.0/, exclusion.dig('result', 'comparison').last)
    assert_equal exclusion.fetch('result'), evidence.fetch('result')
    assert_equal 1, Eligibility.registry(definition, { 'stdout' => 'reference' }, [exclusion]).fetch('record_count')
  end

  def test_summary_only_failure_is_not_misdescribed_as_a_full_array_mismatch
    comparison = record.fetch('comparison')
    comparison.fetch('arrays').first['mismatches'] = 0
    comparison['sparse_comparison'] = [false, 'Sum mismatch']
    assert_equal 'Existing summary check: Sum mismatch', Eligibility.reason(comparison)
    comparison['sparse_comparison'] = [true, 'ok']
    assert_raises(RuntimeError) { Eligibility.reason(comparison) }
    comparison['passed'] = true
    assert_raises(RuntimeError) { Eligibility.reason(comparison) }
  end

  def test_case_and_evidence_location_must_be_unambiguous
    assert_raises(RuntimeError) { Eligibility.definition('roomsim', groups.drop(1)) }
    mixed = groups
    mixed.first['args'] = %w[-v -n 321]
    assert_raises(RuntimeError) { Eligibility.definition('roomsim', mixed) }
    assert_raises(RuntimeError) { Eligibility.location('/tmp/full', '/tmp/full-other/a', 1, 'a' * 64) }
    assert_raises(RuntimeError) { Eligibility.location('/tmp/full', '/tmp/full/../a', 1, 'a' * 64) }
    assert_raises(RuntimeError) { Eligibility.location('/tmp/full', '/tmp/full/a', 0, 'a' * 64) }
  end
end
