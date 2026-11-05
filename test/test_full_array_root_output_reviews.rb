# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/full_array_root_output_reviews'

class FullArrayRootOutputReviewsTest < Minitest::Test
  Review = ValidationAudit::FullArrayRootOutputReviews
  Capture = ValidationAudit::FullArrayCapture

  def fixture
    source = { 'sha256' => 'a' * 64, 'git_blob' => 'b' * 40 }
    row = { 'id' => 'spmv_fixture_mpi_r1', 'benchmark' => 'spmv', 'backend' => 'mpi',
      'source_commit' => 'c' * 40, 'source_path' => '20261105-000000/spmv_fixture_mpi_r1', 'source_files' => { 'spmv/spmv.cpp' => source } }
    profile = row.reject { |key, _| key == 'source_files' }.merge('schema_version' => 1,
      'source_file_path' => 'spmv/spmv.cpp', 'source_file' => source, 'source_finding' => 'Fixture root gather and output suppression.',
      'printed_rank' => 'rank-0', 'captured_ranks' => %w[rank-0 rank-1 rank-2 rank-3], 'array_name' => 'OutputVector', 'elements' => 5)
    [row, profile]
  end

  def test_profile_cannot_apply_to_a_different_source_or_output_rank
    row, profile = fixture
    assert_nil Review.check_profile!(profile, row)
    assert_raises(RuntimeError) { Review.check_profile!(profile.merge('source_commit' => 'd' * 40), row) }
    assert_raises(RuntimeError) { Review.check_profile!(profile.merge('source_file' => {}), row) }
    assert_raises(RuntimeError) { Review.check_profile!(profile.merge('printed_rank' => 'rank-1'), row) }
  end

  def test_selection_is_source_and_output_driven_not_numerical
    _, profile = fixture
    Dir.mktmpdir('root-output-review-test-', '/tmp') do |directory|
      objects = (0..3).map do |rank|
        bytes = Array.new(5, rank.to_f).pack('E*')
        path = File.join(directory, "rank-#{rank}.f64le")
        File.binwrite(path, bytes)
        { 'rank' => "rank-#{rank}", 'name' => 'OutputVector', 'elements' => 5, 'bytes' => bytes.bytesize,
          'local_path' => path, 'sha256' => Digest::SHA256.hexdigest(bytes), 'fnv1a64' => Capture.fnv(bytes) }
      end
      stdout = "=== RESULTS ===\nName: OutputVector\nElements: 5\nHash: #{objects.first.fetch('fnv1a64')}\n=== END RESULTS ===\n"
      observation = { 'id' => profile.fetch('id'), 'backend' => 'mpi', 'observation_complete' => false,
        'errors' => [ValidationAudit::FullArrayReconcile::CAPTURE_ERROR], 'objects' => objects,
        'execution' => { 'success' => true }, 'capture_reports' => objects.map { |_o| { 'errors' => [], 'exit_codes' => [0] } },
        'printed_objects' => Capture.output_objects(stdout) }
      assert_equal objects.first, Review.select(profile, observation, stdout)
      wrong = stdout.sub(objects.first.fetch('fnv1a64'), objects.last.fetch('fnv1a64'))
      assert_raises(RuntimeError) { Review.select(profile, observation.merge('printed_objects' => Capture.output_objects(wrong)), wrong) }
      observation.fetch('objects').last['sha256'] = 'f' * 64
      assert_raises(RuntimeError) { Review.select(profile, observation, stdout) }
    end
  end
end
