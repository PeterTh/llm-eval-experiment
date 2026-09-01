# frozen_string_literal: true

require "minitest/autorun"
require_relative "../tools/timing_audit/lib/timing_fix_review"

class TimingFixReviewValidatorTest < Minitest::Test
  def setup
    @record = {
      "id" => "example_mpi_r1",
      "corrected_source_files" => [
        { "path" => "bench/main.cpp", "lines" => 20 }
      ]
    }
    @validator = TimingFixReview::ResultValidator.new([@record])
  end

  def test_accepts_valid_independent_review
    assert @validator.validate!(accepted_result, expected_id: "example_mpi_r1")
  end

  def test_rejects_accept_with_non_timing_issue
    result = accepted_result.merge("issue_categories" => ["non_timing_change"])
    assert_raises(RuntimeError) do
      @validator.validate!(result, expected_id: "example_mpi_r1")
    end
  end

  def test_rejects_corrected_source_citation_past_end
    result = accepted_result
    result["evidence"] = [{ "path" => "bench/main.cpp", "lines" => "19-21", "finding" => "bad range" }]
    assert_raises(RuntimeError) do
      @validator.validate!(result, expected_id: "example_mpi_r1")
    end
  end

  private

  def accepted_result
    {
      "program_id" => "example_mpi_r1",
      "verdict" => "accept",
      "issue_categories" => ["none"],
      "confidence" => "high",
      "timing_contract_satisfied" => true,
      "timing_only_scope_satisfied" => true,
      "device_completion" => "not_applicable",
      "timed_region" => "Complete local work is timed.",
      "rank_aggregation" => "Complete durations use MPI_MAX.",
      "collective_safety" => "All ranks call a type-compatible reduction.",
      "canonical_output" => "Rank zero reports the reduced maximum.",
      "scope_assessment" => "Only timing and derived performance output changed.",
      "evidence" => [
        { "path" => "bench/main.cpp", "lines" => "10-15", "finding" => "Timer and reduction." }
      ],
      "minimal_correction" => "",
      "notes" => ""
    }
  end
end
