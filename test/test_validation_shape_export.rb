# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/export_shape_full'

class ValidationShapeExportTest < Minitest::Test
  Exporter = ValidationAudit::ShapeFullExport

  def row(id)
    { 'id' => id, 'source_commit' => 'a' * 40, 'source_path' => "fixture/#{id}",
      'source_files' => { 'main.cpp' => { 'sha256' => 'b' * 64 } },
      'validation_record' => { 'path' => 'fixture/records.jsonl', 'line' => 1 } }
  end

  def result(source, definition, passed)
    source.slice('id', 'source_commit', 'source_path').merge('definition' => definition,
      'passed' => passed, 'binary_sha256' => 'c' * 64, 'performance_measurement' => false)
  end

  def test_compact_plan_reconstructs_original_bytes_and_detects_conflicting_sources
    first, second = row('fixture-a'), row('fixture-b')
    plan = { 'scope' => 'fixture', 'groups' => [
      { 'definition' => { 'id' => 'first' }, 'rows' => [first, second], 'backend' => 'omp' },
      { 'definition' => { 'id' => 'second' }, 'rows' => [first], 'backend' => 'omp' }
    ], 'checks' => 3 }
    compact = Exporter.compact_plan(plan)
    assert_equal %w[definition row_ids backend], compact.fetch('groups').first.keys
    assert_equal %w[fixture-a fixture-b], compact.fetch('groups').first.fetch('row_ids')
    records = [first, second, first].map { |source| { 'id' => source.fetch('id'), 'source' => source } }
    assert_equal JSON.pretty_generate(plan), JSON.pretty_generate(Exporter.expand_plan(compact, records))
    assert_raises(KeyError) { Exporter.expand_plan(compact, records.first(1)) }
    records.last['source'] = first.merge('source_commit' => 'd' * 40)
    assert_match(/differs across cases/, assert_raises(RuntimeError) { Exporter.expand_plan(compact, records) }.message)
  end

  def test_build_binding_is_source_and_executable_exact_without_repeated_source_map
    source = row('fixture-a')
    binding = source.slice('id', 'source_files').merge('binary_sha256' => 'c' * 64, 'reused_cache' => { 'directory' => '/tmp/fixture' })
    ValidationAudit::ShapePilotExport.stub(:binding_with_logs, binding) do
      compact = Exporter.compact_binding('/tmp/fixture', source, result(source, {}, true))
      refute compact.key?('source_files')
      assert_equal Digest::SHA256.hexdigest(JSON.generate(source.fetch('source_files'))), compact.fetch('source_files_sha256')
      assert_raises(RuntimeError) { Exporter.compact_binding('/tmp/fixture', source, { 'binary_sha256' => 'e' * 64 }) }
    end
    binding['source_files'] = {}
    ValidationAudit::ShapePilotExport.stub(:binding_with_logs, binding) do
      assert_raises(RuntimeError) { Exporter.compact_binding('/tmp/fixture', source, result(source, {}, true)) }
    end
  end

  def test_case_export_keeps_passes_failures_and_skips_but_only_excludes_failed_execution
    Dir.mktmpdir('shape-export-test-', '/tmp') do |directory|
      definition = { 'id' => 'fixture-case', 'benchmark' => 'fixture' }
      sources = %w[fixture-a fixture-b fixture-c].map { |id| row(id) }
      records = sources.first(2).each_with_index.map do |source, i|
        verdict = result(source, definition, i.zero?)
        { 'id' => source.fetch('id'), 'source' => source, 'result' => verdict,
          'result_sha256' => Digest::SHA256.hexdigest(JSON.pretty_generate(verdict) + "\n"),
          'logs' => { 'stdout' => "fixture #{i}\n" } }
      end
      records << { 'id' => sources.last.fetch('id'), 'source' => sources.last,
        'skipped' => { 'failed_result_key' => 'earlier/fixture-c' } }
      sources.first(2).each do |source|
        ValidationAudit.save(File.join(directory, 'bindings', "#{source.fetch('id')}.json"),
          source.slice('id', 'source_files').merge('binary_sha256' => 'c' * 64, 'reused_cache' => { 'directory' => '/tmp/fixture' }))
      end
      destination = File.join(directory, 'export')
      receipt = Exporter.write_case(evidence: directory, destination: destination, definition: definition, records: records,
        reference: { 'stdout' => 'fixture reference', 'stdout_sha256' => 'f' * 64 },
        authorization: { 'source' => 'user', 'statement' => 'Yes, launch this sweep' })
      assert_equal [3, 2, 1, 1, 0], receipt.values_at('records', 'executed', 'skipped', 'failed', 'benchmark_runs')
      registry = ValidationAudit.read(File.join(destination, 'exclusions.json'))
      assert_equal ['fixture-b'], registry.fetch('records').map { |r| r.fetch('id') }
      assert_equal false, registry.fetch('records').first.fetch('stages').fetch('output_comparison')
      assert_equal 2, ValidationAudit.read(File.join(destination, 'build-bindings.json')).size
      receipt.fetch('files_sha256').each do |relative, digest|
        assert_equal digest, ValidationAudit.sha(File.join(destination, relative))
      end
      assert_equal File.read(File.join(destination, 'records.jsonl')).lines.size, records.size
      assert_raises(RuntimeError) do
        Exporter.write_case(evidence: directory, destination: destination, definition: definition, records: records,
          reference: {}, authorization: {})
      end
    end
  end

  def test_skipped_record_requires_the_same_implementation_and_an_intact_failed_basis
    Dir.mktmpdir('shape-export-test-', '/tmp') do |directory|
      source, definition = row('fixture-a'), { 'id' => 'later' }
      basis_path = File.join(directory, 'earlier/fixture-a/result.json')
      ValidationAudit.save(basis_path, result(source, { 'id' => 'earlier' }, false))
      skip_path = File.join(directory, 'shape-full-skips/later/fixture-a.json')
      skip = source.slice('id', 'source_commit').merge('failed_result_key' => 'earlier/fixture-a',
        'failed_result_sha256' => ValidationAudit.sha(basis_path))
      ValidationAudit.save(skip_path, skip)
      verifier = Object.new
      verifier.define_singleton_method(:result_key) { |r, d| "#{d.fetch('id')}/#{r.fetch('id')}" }
      exported = Exporter.record(directory, source, definition, verifier)
      refute exported.key?('result')
      assert_equal skip, exported.fetch('skipped')
      assert_equal ValidationAudit.sha(skip_path), exported.fetch('skipped_sha256')
      File.write(basis_path, JSON.pretty_generate(result(source, { 'id' => 'earlier' }, true)) + "\n")
      assert_match(/failure basis differs/, assert_raises(RuntimeError) { Exporter.record(directory, source, definition, verifier) }.message)
    end
  end
end
