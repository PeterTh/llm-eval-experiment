# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../tools/validation_audit/full_array_hash_compatibility'

class FullArrayHashCompatibilityTest < Minitest::Test
  Adapter = ValidationAudit::FullArrayHashCompatibility

  def test_scoped_digest_guard_is_restored_on_success_and_failure
    assert_equal Adapter::BASE_SHA, ValidationAudit::FullArrayCapture::HASH_SHA
    Adapter.with_variant_guard { assert_equal Adapter::VARIANT_SHA, ValidationAudit::FullArrayCapture::HASH_SHA }
    assert_equal Adapter::BASE_SHA, ValidationAudit::FullArrayCapture::HASH_SHA
    assert_raises(RuntimeError) { Adapter.with_variant_guard { raise 'test failure' } }
    assert_equal Adapter::BASE_SHA, ValidationAudit::FullArrayCapture::HASH_SHA
  end

  def test_unreviewed_source_change_is_rejected
    assert_raises(RuntimeError) { Adapter.verify_sources!('unreviewed', 'unreviewed', '#include <mpi.h>') }
  end
end
