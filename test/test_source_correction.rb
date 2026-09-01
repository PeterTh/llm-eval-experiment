# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/local_evaluation"

class SourceCorrectionAmendmentTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("source-correction-test-", "/tmp")
    @source = File.join(@tmp, "source")
    @run_dir = File.join(@tmp, "run")
    @evidence = File.join(@tmp, "evidence")
    @id = "matmul_model_mpi_r1"
    @prefix = "20260101-000000/#{@id}"
    source_file = File.join(@source, @prefix, "matmul", "main.cpp")
    FileUtils.mkdir_p(File.dirname(source_file))
    File.write(source_file, "double local_time = 1.0;\n")
    git("init", "-q")
    git("config", "user.email", "test@example.invalid")
    git("config", "user.name", "Test")
    git("add", "--all")
    git("commit", "-q", "-m", "original")
    @original_commit = git("rev-parse", "HEAD").strip

    original_snapshot = LocalEvaluation.git_snapshot(@source)
    FileUtils.mkdir_p(@run_dir)
    @manifest_path = File.join(@run_dir, "evaluation_manifest.yaml")
    info = {
      "benchmark" => "matmul", "model" => "model", "par_type" => "mpi", "run" => 1,
      "batch" => "20260101-000000", "source_path" => File.join(@source, @prefix), "source_error" => nil
    }
    LocalEvaluation.atomic_yaml_with_digest(@manifest_path, {
      "schema_version" => LocalEvaluation::SCHEMA_VERSION,
      "experiment_repository" => original_snapshot,
      "runs" => { @id => info }
    })

    File.write(source_file, "double max_rank_time = 1.0;\n")
    git("add", "--all")
    git("commit", "-q", "-m", "timing fix")
    @corrected_commit = git("rev-parse", "HEAD").strip
    @corrected_tree = git("rev-parse", "HEAD:#{@prefix}").strip
    write_evidence
  end

  def teardown
    make_writable(@tmp)
    FileUtils.remove_entry(@tmp) if File.directory?(@tmp)
  end

  def test_creates_immutable_amendment_and_authorizes_only_explicit_corrected_ids
    manifest = LocalEvaluation::Manifest.new(@run_dir)
    amendment = LocalEvaluation::SourceCorrectionAmendment.create!(
      manifest: manifest, correction_dir: @evidence, reason: "Correct invalid rank-local timing."
    )

    assert_equal [@id], amendment.affected_ids
    assert_equal @corrected_commit, amendment.record_for(@id).dig("corrected_source", "commit")
    assert_equal 0, File.stat(amendment.path).mode & 0o222
    assert amendment.verify!(manifest: manifest, operation: "benchmark", exact_id: nil,
                             filter: nil, selected_ids: [@id])
    assert amendment.verify!(manifest: manifest, operation: "aggregate", exact_id: nil,
                             filter: nil, selected_ids: nil)
    assert_raises(LocalEvaluation::InfrastructureError) do
      amendment.verify!(manifest: manifest, operation: "benchmark", exact_id: nil,
                        filter: nil, selected_ids: ["matmul_other_mpi_r1"])
    end
    assert_raises(LocalEvaluation::InfrastructureError) do
      amendment.verify!(manifest: manifest, operation: "aggregate", exact_id: @id,
                        filter: nil, selected_ids: nil)
    end
    assert_raises(LocalEvaluation::InfrastructureError) do
      amendment.verify!(manifest: manifest, operation: "validate", exact_id: @id,
                        filter: nil, selected_ids: nil)
    end
  end

  def test_manifest_id_list_selection_is_exact_and_complete
    manifest = LocalEvaluation::Manifest.new(@run_dir)
    assert_equal [@id], manifest.filtered_runs(ids: [@id]).keys
    error = assert_raises(RuntimeError) { manifest.filtered_runs(ids: [@id, "missing_mpi_r1"]) }
    assert_match(/not present/, error.message)
    assert_raises(RuntimeError) { manifest.filtered_runs(exact_id: @id, ids: [@id]) }
  end

  private

  def write_evidence
    FileUtils.mkdir_p(@evidence)
    changed_path = File.join(@prefix, "matmul", "main.cpp")
    record = {
      "schema_version" => 1,
      "program_id" => @id,
      "benchmark" => "matmul",
      "model" => "model",
      "par_type" => "mpi",
      "run" => 1,
      "source_batch" => "20260101-000000",
      "source_prefix" => @prefix,
      "timing_fixed" => true,
      "original_source_url" => "https://github.com/example/generated/tree/#{@original_commit}/#{@prefix}",
      "corrected_source_url" => "https://github.com/example/generated/tree/#{@corrected_commit}/#{@prefix}",
      "original_issue_categories" => ["rank_local_timing"],
      "changed_paths" => [changed_path],
      "original_source" => { "commit" => @original_commit, "tree_oid" => "old", "digest" => "a" * 64 },
      "corrected_source" => { "commit" => @corrected_commit, "tree_oid" => @corrected_tree, "digest" => "b" * 64 },
      "proposal" => { "sha256" => "c" * 64, "summary" => "Use MPI_MAX." },
      "postfix_review" => { "verdict" => "accept", "sha256" => "d" * 64 },
      "final_verdict" => "accept",
      "decision_basis" => "independent_postfix_review"
    }
    records_path = File.join(@evidence, "corrections.jsonl")
    ids_path = File.join(@evidence, "correction-ids.txt")
    LocalEvaluation.atomic_write(records_path, JSON.generate(record) + "\n")
    LocalEvaluation.atomic_write(ids_path, "#{@id}\n")
    LocalEvaluation.atomic_yaml(File.join(@evidence, "manifest.yaml"), {
      "schema_version" => 1,
      "record_count" => 1,
      "all_final_verdicts" => "accept",
      "original_source" => { "root" => @source, "commit" => @original_commit },
      "corrected_source" => { "root" => @source, "commit" => @corrected_commit },
      "compile_validation" => {
        "records" => 1, "compiled" => 1, "compile_successes" => 1, "compile_failures" => []
      },
      "artifacts" => {
        "corrections_jsonl_sha256" => LocalEvaluation.sha256_file(records_path),
        "correction_ids_sha256" => LocalEvaluation.sha256_file(ids_path)
      }
    })
  end

  def git(*args)
    LocalEvaluation.capture(["git", "-C", @source, *args]).tap do |output|
      raise output if output.start_with?("unavailable:")
    end
  end

  def make_writable(root)
    return unless File.exist?(root)
    Find.find(root) do |path|
      next if File.symlink?(path)
      File.chmod(File.stat(path).mode | 0o200, path)
    rescue Errno::ENOENT
      nil
    end
  end
end
