# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../tools/validation_audit/full_array_adapters'

class FullArrayAdaptersTest < Minitest::Test
  ADAPTER = ValidationAudit::FullArrayAdapters
  def binding(helper, binary = 'unlisted')
    { 'binary_sha256' => binary, 'source_files' => { 'common/results_output.hpp' => { 'sha256' => helper } } }
  end

  def test_canonical_symbols_do_not_accept_worker_clones
    symbol = ADAPTER::CANONICAL.keys.first
    result = ADAPTER.entries(binding(ADAPTER::CANONICAL_HELPER), [symbol, symbol + '._omp_fn.0'], args: [])
    assert_equal 1, result.size
    assert_equal 'vector', result.first.fetch('abi')
    assert_raises(RuntimeError) { ADAPTER.entries(binding(ADAPTER::CANONICAL_HELPER), [symbol + '.isra.0'], args: []) }
  end

  def test_reviewed_helpers_use_only_their_specific_abi
    ADAPTER::HELPERS.each do |helper, symbols|
      symbols.each do |symbol, abi|
        result = ADAPTER.entries(binding(helper), [symbol], args: [])
        assert_equal abi, result.first.fetch('abi')
      end
    end
    assert_raises(RuntimeError) { ADAPTER.entries(binding('unknown'), ADAPTER::CANONICAL.keys, args: []) }
  end

  def test_binary_specific_offsets_require_exact_binary_and_helper
    binary, spec = ADAPTER::BINARIES.first
    result = ADAPTER.entries(binding(ADAPTER::CANONICAL_HELPER, binary), ['main'], args: [])
    assert_equal spec.fetch('location'), result.first.fetch('location')
    assert_raises(RuntimeError) { ADAPTER.entries(binding('changed', binary), ['main'], args: []) }
    assert_raises(RuntimeError) { ADAPTER.entries(binding(ADAPTER::CANONICAL_HELPER, 'other'), ['main'], args: []) }
  end

  def test_streamed_grid_requires_the_inspected_shape
    binary, = ADAPTER::BINARIES.find { |_, spec| spec['assembly'] }
    args = %w[-v -r -x 65 -y 61 -z 67 -i 21]
    assert_equal 'frame_vector', ADAPTER.entries(binding(ADAPTER::CANONICAL_HELPER, binary), ['main'], args: args).first.fetch('abi')
    assert_raises(RuntimeError) { ADAPTER.entries(binding(ADAPTER::CANONICAL_HELPER, binary), ['main'], args: args.map { |a| a == '67' ? '68' : a }) }
  end

  def test_streamed_options_require_the_exact_binary_helper_and_shape
    binary, spec = ADAPTER::BINARIES.find { |_, value| value['assembly'] == 'black_scholes_contiguous_rank_blocks' }
    args = %w[-v -r -n 10003]
    result = ADAPTER.entries(binding(ADAPTER::CANONICAL_HELPER, binary), [spec.fetch('location')], args: args)
    assert_equal 'vector', result.first.fetch('abi')
    assert_equal 'OptionPricesBlock', result.first.fetch('name')
    assert_raises(RuntimeError) { ADAPTER.entries(binding(ADAPTER::CANONICAL_HELPER, binary), [], args: %w[-v -r -n 10000]) }
    assert_raises(RuntimeError) { ADAPTER.entries(binding('changed', binary), [], args: args) }
    assert_raises(RuntimeError) { ADAPTER.entries(binding(ADAPTER::CANONICAL_HELPER, 'other'), [spec.fetch('location')], args: args) }
  end
end
