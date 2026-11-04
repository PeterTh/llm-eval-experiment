# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/export_spmv_full'

class SpmvFullExportTest < Minitest::Test
  def completion
    { 'status' => 'complete', 'full_scope_accounted_for' => true, 'remaining' => 0,
      'evidence_verified' => true, 'new_failures' => [], 'program_changes' => 0,
      'population' => 2, 'reused_pilot_reviews' => 1, 'new_reviews' => 1,
      'review_sha256' => { 'spmv_fixture_omp_r1' => 'a' * 64 },
      'legacy_records_without_compilation_counter' => 0,
      'program_executions' => 0, 'benchmark_runs' => 0 }
  end

  def test_complete_verified_review_is_required
    good = completion
    ValidationAudit::SpmvFullExport.check_completion!(good, good)
    [{ 'status' => 'running' }, { 'remaining' => 1 }, { 'full_scope_accounted_for' => false },
     { 'new_failures' => ['unadjudicated'] }, { 'program_changes' => 1 },
     { 'review_sha256' => {} }, { 'evidence_verified' => false }, { 'benchmark_runs' => 1 },
     { 'legacy_records_without_compilation_counter' => 1 }].each do |change|
      assert_raises(RuntimeError) { ValidationAudit::SpmvFullExport.check_completion!(good.merge(change), good) }
    end
    assert_raises(RuntimeError) do
      ValidationAudit::SpmvFullExport.check_completion!(good, good.merge('evidence_verified' => false))
    end
  end

  def test_export_preserves_exact_json_bytes_and_excludes_unselected_artifacts
    Dir.mktmpdir('spmv-export-test-', '/tmp') do |directory|
      source = File.join(directory, 'accepted.json')
      bytes = "{\"accepted\": true}\n"
      File.binwrite(source, bytes)
      File.binwrite(File.join(directory, 'binary'), "\x7fELF")
      destination = File.join(directory, 'export')
      receipt = ValidationAudit::SpmvFullExport.write_bundle(destination: destination,
        sources: { 'reviews/fixture.json' => source }, summary: { 'population' => 1 }, method: { 'fixture' => true })
      assert_equal bytes, File.binread(File.join(destination, 'reviews/fixture.json'))
      assert_equal Digest::SHA256.hexdigest(bytes), receipt.dig('files_sha256', 'reviews/fixture.json')
      assert_equal 2, receipt.fetch('files_sha256').size
      assert_equal 0, receipt.fetch('binaries')
      refute File.exist?(File.join(destination, 'binary'))
      assert_equal Dir.glob(File.join(destination, '**', '*.json')).reject { |p| File.basename(p) == 'export.json' }.sum { |p| File.size(p) },
        receipt.fetch('retained_bytes_excluding_receipt')
      assert_raises(RuntimeError) do
        ValidationAudit::SpmvFullExport.write_bundle(destination: destination, sources: {}, summary: {}, method: {})
      end
      assert_equal bytes, File.binread(File.join(destination, 'reviews/fixture.json'))
    end
  end

  def test_unsafe_paths_symlinks_and_non_json_fail_before_writing
    Dir.mktmpdir('spmv-export-safety-test-', '/tmp') do |directory|
      source = File.join(directory, 'source.json')
      File.write(source, '{}')
      link = File.join(directory, 'link.json')
      File.symlink(source, link)
      destination = File.join(directory, 'export')
      %w[../outside.json /absolute.json a/../b.json a//b.json binary export.json method-files.json].each do |name|
        assert_raises(RuntimeError) do
          ValidationAudit::SpmvFullExport.write_bundle(destination: destination,
            sources: { name => source }, summary: {}, method: {})
        end
        refute File.exist?(destination)
      end
      assert_raises(RuntimeError) do
        ValidationAudit::SpmvFullExport.write_bundle(destination: destination,
          sources: { 'link.json' => link }, summary: {}, method: {})
      end
      File.write(source, 'not JSON')
      assert_raises(JSON::ParserError) do
        ValidationAudit::SpmvFullExport.write_bundle(destination: destination,
          sources: { 'source.json' => source }, summary: {}, method: {})
      end
      refute File.exist?(destination)
    end
  end
end
