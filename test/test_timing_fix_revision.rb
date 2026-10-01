# frozen_string_literal: true

require "minitest/autorun"
require_relative "../tools/timing_audit/lib/timing_fix_revision"

class TimingFixRevisionTest < Minitest::Test
  def test_feedback_requires_nonempty_unique_hash_bound_requests
    request = { "program_id" => "example", "prior_proposal_sha256" => "a" * 64, "feedback" => "Remove added trailing whitespace." }
    Dir.mktmpdir do |root|
      path = File.join(root, "feedback.json")
      File.write(path, JSON.generate([request]))
      assert_equal({ "example" => request }, TimingFixRevision.load_feedback(path))
      [[], [request, request], [request.merge("feedback" => " ")],
        [request.merge("prior_proposal_sha256" => "bad")], [request.merge("extra" => true)]].each do |invalid|
        File.write(path, JSON.generate(invalid))
        assert_raises(RuntimeError) { TimingFixRevision.load_feedback(path) }
      end
    end
  end

  def test_revision_prompt_keeps_original_dossier_and_separates_feedback
    runner = TimingFixRevision::Runner.allocate
    record = { "id" => "example", "benchmark" => "bench", "par_type" => "mpi", "metric_label" => "Computation time",
      "final_decision" => { "final_issue_categories" => ["rank_local_timing"] }, "review_findings" => {} }
    runner.instance_variable_set(:@template, "Original: %{dossier}\n")
    repo = Object.new
    def repo.dossier(_record) = "PINNED ORIGINAL"
    runner.instance_variable_set(:@repository, repo)
    runner.instance_variable_set(:@feedback, { "example" => { "feedback" => "FIX FORMATTING" } })
    runner.instance_variable_set(:@prior_proposals, { "example" => { "program_id" => "example" } })
    prompt = runner.send(:build_prompt, record)
    assert_includes prompt, "Original: PINNED ORIGINAL"
    assert_includes prompt, "FIX FORMATTING"
    assert_includes prompt, "against the ORIGINAL source dossier"
    refute runner.send(:valid_existing_proposal?, "example")
  end
end
