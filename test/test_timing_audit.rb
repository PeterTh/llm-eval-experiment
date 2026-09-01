# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../tools/timing_audit/lib/timing_audit"

class TimingAuditTest < Minitest::Test
  def test_inventory_uses_pinned_tracked_sources_and_filters_successful_parallel_records
    Dir.mktmpdir do |root|
      source_root = File.join(root, "generated")
      release_root = File.join(root, "release")
      output = File.join(root, "audit")
      FileUtils.mkdir_p(source_root)
      initialize_repository(source_root)

      id = "black-scholes_test_mpi_r1"
      prefix = File.join("batch", id)
      write(File.join(source_root, prefix, "instruction.txt"), "parallelize with MPI\n")
      write(File.join(source_root, prefix, "black-scholes", "CMakeLists.txt"), "add_executable(x main.cpp)\n")
      write(File.join(source_root, prefix, "black-scholes", "main.cpp"), <<~CPP)
        #include <mpi.h>
        int main() {
          double local = 1.0, maximum = 0.0;
          MPI_Reduce(&local, &maximum, 1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);
        }
      CPP
      write(File.join(source_root, prefix, "output.txt"), "must not enter dossier\n")
      commit_all(source_root)
      commit = git(source_root, "rev-parse", "HEAD").strip

      FileUtils.mkdir_p(File.join(release_root, "data", "provenance"))
      FileUtils.mkdir_p(File.join(release_root, "data", "scoring"))
      write(File.join(release_root, "data", "provenance", "repositories.yaml"), YAML.dump(
        "generated_programs" => {
          "repository" => "https://example.invalid/generated",
          "commit" => commit
        }
      ))
      headers = %w[
        benchmark model par_type run validation_status benchmark_success source_batch
        source_path benchmark_median_time overall_score benchmark_config_sha256
      ]
      csv = CSV.generate do |rows|
        rows << headers
        rows << ["black-scholes", "test", "mpi", 1, 5, true, "batch",
                 File.join(source_root, prefix), 2.5, 9, "a" * 64]
        rows << ["black-scholes", "test", "omp", 2, 5, true, "batch",
                 File.join(source_root, "batch", "ignored"), 2.5, 9, "a" * 64]
      end
      write(File.join(release_root, "data", "scoring", "scored_results.csv"), csv)

      TimingAudit::InventoryBuilder.new(
        release_root: release_root,
        source_root: source_root,
        output_dir: output,
        trial_size: 1
      ).run

      records = TimingAudit.load_jsonl(File.join(output, "inventory.jsonl"))
      assert_equal [id], records.map { |record| record.fetch("id") }
      record = records.first
      assert record.dig("static_features", "has_mpi_max")
      refute_includes record.fetch("source_files").map { |file| file.fetch("path") }, "output.txt"
      assert_equal commit, YAML.safe_load(File.read(File.join(output, "manifest.yaml"))).dig("generated_source", "commit")
    end
  end

  def test_result_validator_checks_semantics_and_evidence_ranges
    record = {
      "id" => "sample_mpi_r1",
      "source_files" => [{ "path" => "main.cpp", "lines" => 20 }]
    }
    validator = TimingAudit::ResultValidator.new([record])
    result = valid_result("sample_mpi_r1")
    assert validator.validate!(result, expected_id: "sample_mpi_r1")

    result["evidence"][0]["lines"] = "21"
    error = assert_raises(RuntimeError) { validator.validate!(result, expected_id: "sample_mpi_r1") }
    assert_match(/exceeds/, error.message)
  end

  def test_codex_command_is_read_only_ephemeral_and_not_unsandboxed
    argv = TimingAudit::CodexCommand.new(model: "gpt-5.6-luna", effort: "high").argv(
      schema_path: "/tmp/schema.json",
      output_path: "/tmp/result.json"
    )
    assert_equal %w[codex exec], argv.first(2)
    assert_includes argv, "gpt-5.6-luna"
    assert_includes argv, %(model_reasoning_effort="high")
    assert_includes argv, "read-only"
    assert_includes argv, "--ephemeral"
    refute_includes argv, "--dangerously-bypass-approvals-and-sandbox"
  end

  private

  def valid_result(id)
    {
      "program_id" => id,
      "verdict" => "valid",
      "issue_categories" => ["none"],
      "confidence" => "high",
      "timed_region" => "local computation",
      "start_synchronization" => "barrier",
      "stop_synchronization" => "completed work",
      "rank_aggregation" => "maximum reduction",
      "reported_value" => "reduced maximum",
      "semantic_equivalence_basis" => "MPI_MAX",
      "evidence" => [{ "path" => "main.cpp", "lines" => "1-10", "finding" => "maximum is reported" }],
      "timing_only_fix_possible" => false,
      "minimal_fix" => "",
      "notes" => ""
    }
  end

  def initialize_repository(path)
    git(path, "init", "-q")
    git(path, "config", "user.name", "Timing Audit Test")
    git(path, "config", "user.email", "timing-audit@example.invalid")
  end

  def commit_all(path)
    git(path, "add", ".")
    git(path, "commit", "-q", "-m", "fixture")
  end

  def git(path, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", path, *arguments)
    raise stderr unless status.success?
    stdout
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
