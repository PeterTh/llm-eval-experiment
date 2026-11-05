# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../tools/validation_audit/full_array_recovered_output_policy'

class FullArrayRecoveredOutputsTest < Minitest::Test
  POLICY = ValidationAudit::FullArrayRecoveredOutputPolicy
  def block
    "=== RESULTS ===\nName: ElementEnergy\nElements: 1089\nHash: 0123456789abcdef\n=== END RESULTS ===\n"
  end

  def test_primary_must_be_intact_even_when_later_duplicates_interleave
    assert_equal 1089, POLICY.primary(block + "=== RESULTS ===\n" + block).first.fetch('elements')
    assert_raises(RuntimeError) { POLICY.primary("=== RESULTS ===\n" + block) }
    assert_raises(RuntimeError) { POLICY.primary(block.sub('1089', '1088')) }
  end

  def logs
    { 'command' => "containment_unit: test.scope\n  output_limit_bytes=8388608\ncommand: mpirun --np 4 /tmp/#{POLICY::ID}/unstructured -v -r -n 33 -i 513\n",
      'stdout' => block, 'stderr' => '', 'exitcode' => '0', 'wall_time' => "1.234567\n" }
  end

  def test_execution_recovery_uses_only_retained_logs
    result = POLICY.execution(logs)
    assert result.fetch('success')
    assert_equal 1.234567, result.fetch('wall_seconds')
    assert_equal POLICY::ARGS, result.fetch('argv').last(6)
    assert_raises(RuntimeError) { POLICY.execution(logs.merge('exitcode' => '124')) }
    assert_raises(RuntimeError) { POLICY.execution(logs.merge('stderr' => 'unexpected error')) }
    assert_raises(RuntimeError) { POLICY.execution(logs.merge('stdout' => 'x' * (8 * 1024 * 1024))) }
    assert_raises(RuntimeError) { POLICY.execution(logs.merge('command' => logs['command'].sub('--np 4', '--np 3'))) }
  end
end
