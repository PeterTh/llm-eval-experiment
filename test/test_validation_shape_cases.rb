# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../lib/local_evaluation/shape_validation_cases'
require_relative '../tools/validation_audit/shape_topology'

class ValidationShapeCasesTest < Minitest::Test
  Cases = LocalEvaluation::ShapeValidationCases
  def test_shared_definitions_exactly_match_every_piloted_stratum
    ValidationAudit::ShapeTopologyCampaign::ARGUMENTS.keys.product(Cases::BACKENDS).each do |benchmark, backend|
      assert_equal ValidationAudit::ShapeTopologyCampaign.definition(benchmark, backend), Cases.primary(benchmark, backend)
    end
    ValidationAudit::ShapeTopologyCampaign::FAST_PATHS.each do |benchmark, backend, label, args|
      definition = Cases.for_backend(benchmark, backend).last
      assert_equal "#{benchmark}-#{label}-v1", definition.fetch('id')
      assert_equal args, definition.fetch('args')
      assert_equal 'measurement', definition.fetch('topology')
    end
    assert_equal 25, Cases.definitions.size
  end

  def test_unknown_cases_are_not_silently_accepted
    assert_raises(KeyError) { Cases.primary('unknown', 'omp') }
    assert_raises(ArgumentError) { Cases.primary('matmul', 'unknown') }
    assert Cases.primary('matmul', 'omp').frozen?
    assert Cases.primary('matmul', 'omp').fetch('args').frozen?
  end

  def test_native_validation_includes_every_approved_case
    Cases::ARGUMENTS.keys.product(Cases::BACKENDS).each do |benchmark, backend|
      native = LocalEvaluation::ExternalValidationCases.cases_for(benchmark, backend)
      assert_equal Cases.for_backend(benchmark, backend), native.select { |definition| definition['topology'] == 'measurement' }
    end
  end
end
