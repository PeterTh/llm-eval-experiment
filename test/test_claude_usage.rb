require "minitest/autorun"
require "time"

class ClaudeUsageTest < Minitest::Test
  # Load only helper definitions: importing the script itself would start its
  # command-line workflow and query the real account even during a dry run.
  SOURCE_PATH = File.expand_path("../experiment.rb", __dir__)
  SOURCE = File.read(SOURCE_PATH)
  HELPERS = Class.new
  constants = SOURCE.lines.grep(/\ACLAUDE_(?:(?:WEEKLY_)?USAGE_(?:MAX_UTILIZATION|RECHECK_SECONDS)|SHARED_WINDOWS)\s*=/).join
  definitions = SOURCE[/^def claude_epoch_seconds\(value\).*?(?=^# Blocks until no usage window)/m]
  raise "Claude usage helper boundaries changed" unless definitions && constants.lines.size == 4
  HELPERS.class_eval(constants + definitions, SOURCE_PATH)

  def setup
    @policy = HELPERS.new
    @reset = "2026-10-16T17:00:00Z"
  end

  def window(percent, reset: @reset, locked: nil)
    { "utilization" => percent, "resets_at" => reset, "locked_reason" => locked }
  end

  def limit(percent, kind: "weekly_scoped", group: "weekly", model: "Fable", reset: @reset)
    { "kind" => kind, "group" => group, "percent" => percent, "resets_at" => reset,
      "scope" => model && { "model" => { "display_name" => model } } }
  end

  def blocked(snapshot, family = "fable")
    @policy.claude_usage_blocked_until(snapshot, family)
  end

  def test_weekly_threshold_is_95_for_shared_and_scoped_limits
    [90, 92, 94.999].each do |percent|
      assert_nil blocked("seven_day" => window(percent))
      assert_nil blocked("limits" => [limit(percent)])
    end
    [95, 100].each do |percent|
      assert_equal Time.iso8601(@reset), blocked("seven_day" => window(percent))
      assert_equal Time.iso8601(@reset), blocked("limits" => [limit(percent)])
    end
  end

  def test_session_threshold_is_still_90
    assert_nil blocked("five_hour" => window(89.999))
    assert_equal Time.iso8601(@reset), blocked("five_hour" => window(90))
    assert_equal Time.iso8601(@reset), blocked("limits" => [limit(90, kind: "session", group: "session", model: nil)])
  end

  def test_shared_limits_cannot_be_hidden_by_incomplete_normalized_limits
    assert_equal Time.iso8601(@reset), blocked("seven_day" => window(95), "limits" => [limit(0)])
    assert_equal Time.iso8601(@reset), blocked("five_hour" => window(90), "limits" => [limit(0)])
    assert_nil blocked("seven_day" => window(94), "limits" => [limit(99, model: "Sonnet")])
  end

  def test_unrelated_scoped_model_is_not_blocked
    assert_nil blocked("limits" => [limit(100, model: "Sonnet")])
    assert_equal Time.iso8601(@reset), blocked({ "limits" => [limit(100, model: "Sonnet")] }, "sonnet")
    assert_equal Time.iso8601(@reset), blocked("limits" => [limit(95, model: nil)])
  end

  def test_normalized_weekly_kinds_and_groups_are_recognized
    assert_nil blocked("limits" => [limit(92, kind: "weekly_all", group: nil, model: nil)])
    assert_nil blocked("limits" => [limit(92, group: nil)])
    assert_nil blocked("limits" => [limit(92, kind: "new_weekly_kind")])
    assert_equal Time.iso8601(@reset), blocked("limits" => [limit(95, kind: "new_weekly_kind")])
  end

  def test_top_level_fallback_uses_weekly_threshold_but_preserves_unknown_guards
    assert_nil blocked("seven_day_fable" => window(92))
    assert_equal Time.iso8601(@reset), blocked("seven_day_fable" => window(95))
    assert_equal Time.iso8601(@reset), blocked("new_window" => window(90))
    assert_equal Time.iso8601(@reset), blocked("seven_dayish" => window(90))
    assert_equal Time.iso8601(@reset), blocked("limits" => [limit(90, kind: "unknown", group: nil)])
  end

  def test_locks_still_block_even_at_zero_usage
    assert_equal Time.iso8601(@reset), blocked("seven_day" => window(0, locked: "locked"), "limits" => [limit(0)])
    assert_equal Time.iso8601(@reset), blocked("seven_day_fable" => window(0, locked: "locked"))
  end

  def test_latest_applicable_reset_still_wins
    later = "2026-10-17T00:00:00Z"
    assert_equal Time.iso8601(later), blocked("five_hour" => window(99), "limits" => [limit(95, reset: later)])
  end

  def test_missing_reset_rechecks_and_missing_snapshot_keeps_existing_behavior
    before = Time.now + 300
    result = blocked("limits" => [limit(95, reset: nil)])
    assert_operator result, :>=, before
    assert_operator result, :<=, Time.now + 300
    assert_nil blocked(nil)
    assert_nil blocked({})
  end
end
