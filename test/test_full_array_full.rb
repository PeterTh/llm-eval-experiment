# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../tools/validation_audit/full_array_full'

class FullArrayFullTest < Minitest::Test
  def approval
    { 'source' => 'user', 'approved' => true, 'scope' => 'full-array-correctness-sweep',
      'pilot_plan_sha256' => 'plan', 'pilot_completion_sha256' => 'pilot', 'population' => 6747,
      'benchmark_runs' => 0, 'llm_invocations' => 0, 'statement' => 'Go ahead.' }
  end

  def test_authorization_is_bound_to_scope_and_cost_type
    klass = ValidationAudit::FullArrayFull
    klass.check_authorization!(approval, 'plan', 'pilot', 6747)
    %w[source approved scope pilot_plan_sha256 pilot_completion_sha256 population benchmark_runs llm_invocations statement].each do |key|
      changed = approval.merge(key => (key == 'statement' ? '' : 'changed'))
      assert_raises(RuntimeError, key) { klass.check_authorization!(changed, 'plan', 'pilot', 6747) }
    end
  end

  def test_incomplete_nonreplica_observation_never_gets_a_verdict
    campaign = ValidationAudit::FullArrayFull.allocate
    observation = { 'observation_complete' => false, 'errors' => ['Observer-wrapped execution did not succeed'], 'objects' => [] }
    assert_raises(RuntimeError) { campaign.normalized_observation(observation, '') }
  end

  def test_complete_unique_capture_is_unchanged
    campaign = ValidationAudit::FullArrayFull.allocate
    observation = { 'observation_complete' => true, 'objects' => [{ 'name' => 'Values' }] }
    normalized, review = campaign.normalized_observation(observation, '')
    assert_same observation, normalized
    assert_nil review
  end
end
