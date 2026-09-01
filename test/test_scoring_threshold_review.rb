# frozen_string_literal: true

require "minitest/autorun"
require_relative "../tools/timing_audit/bin/scoring_threshold_review"

class ScoringThresholdReviewTest < Minitest::Test
  def reviewer
    ScoringThresholdReview.new(run_dir: "/tmp", dry_run: true)
  end

  def entry(id, median)
    { "id" => id, "median_time" => median, "times" => Array.new(5, median) }
  end

  def test_natural_breaks_use_only_boundaries_above_noise_floor
    entries = [1.0, 1.01, 2.0, 2.02, 8.0, 8.01, 40.0].each_with_index.map do |time, index|
      entry(index.to_s, time)
    end

    cell = reviewer.send(:review_cell, entries)

    assert_equal 4, cell.fetch("cluster_count")
    assert_equal [2, 2, 2, 1], cell.fetch("cluster_sizes")
    assert_equal 1.01, cell.fetch("top")
    assert_equal 2.02, cell.fetch("great")
    assert_equal 8.01, cell.fetch("good")
  end

  def test_three_clusters_collapse_good_into_great
    entries = [1.0, 1.01, 3.0, 3.01, 20.0, 20.01].each_with_index.map do |time, index|
      entry(index.to_s, time)
    end

    cell = reviewer.send(:review_cell, entries)

    assert_equal 3, cell.fetch("cluster_count")
    assert_equal cell.fetch("great"), cell.fetch("good")
  end
end
