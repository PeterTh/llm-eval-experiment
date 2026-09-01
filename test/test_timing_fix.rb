# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../tools/timing_audit/lib/timing_fix"

class TimingFixTest < Minitest::Test
  def with_validator
    Dir.mktmpdir do |root|
      path = "batch/example_mpi_r1/bench/main.cpp"
      absolute = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(absolute))
      source = "double local = stop - start;\nprintf(\"Computation time: %f ms\\n\", local);\n"
      File.write(absolute, source)
      record = {
        "id" => "example_mpi_r1",
        "metric_label" => "Computation time",
        "source_files" => [{
          "path" => "bench/main.cpp",
          "git_path" => path,
          "sha256" => TimingAudit.sha256_bytes(source),
          "lines" => 2
        }]
      }
      yield TimingFix::ProposalValidator.new([record], root)
    end
  end

  def valid_proposal
    {
      "program_id" => "example_mpi_r1",
      "status" => "proposed",
      "summary" => "Reduce the complete local duration with MPI_MAX.",
      "expected_timing_semantics" => "Rank zero reports the maximum local duration.",
      "edits" => [{
        "path" => "bench/main.cpp",
        "old_text" => "double local = stop - start;\n",
        "new_text" => "double local = stop - start;\ndouble maximum = local;\n",
        "rationale" => "Introduce the value used by the timing reduction."
      }],
      "non_timing_changes" => [],
      "notes" => ""
    }
  end

  def test_validator_accepts_and_materializes_exact_edit
    with_validator do |validator|
      assert validator.validate!(valid_proposal, expected_id: "example_mpi_r1")
      modified = validator.materialize(valid_proposal, expected_id: "example_mpi_r1")
      assert_includes modified.fetch("bench/main.cpp"), "double maximum = local;"
    end
  end

  def test_validator_rejects_non_timing_changes
    with_validator do |validator|
      proposal = valid_proposal
      proposal["non_timing_changes"] = ["Changed the algorithm"]
      error = assert_raises(RuntimeError) do
        validator.validate!(proposal, expected_id: "example_mpi_r1")
      end
      assert_match(/empty array/, error.message)
    end
  end

  def test_validator_rejects_non_unique_old_text
    with_validator do |validator|
      proposal = valid_proposal
      proposal.fetch("edits").first["old_text"] = "local"
      error = assert_raises(RuntimeError) do
        validator.validate!(proposal, expected_id: "example_mpi_r1")
      end
      assert_match(/occurs 2 times/, error.message)
    end
  end
end
