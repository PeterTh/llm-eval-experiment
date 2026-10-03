require "minitest/autorun"
require_relative "../lib/generation_cleanup"

class GenerationCleanupTest < Minitest::Test
  Status = Struct.new(:exitstatus)

  def setup
    @now = 0.0
    @listings = [""]
    @listing_status = nil
    @kill_status = 0
    @commands, @sleeps = [], []
    runner = lambda do |*args|
      @commands << args
      case args.first
      when "pgrep"
        output = @listings.size > 1 ? @listings.shift : @listings.first
        [output, Status.new(@listing_status || (output.empty? ? 1 : 0))]
      when "su"
        [@kill_status == 0 ? "" : "kill: No such process", Status.new(@kill_status)]
      when "ps"
        ["111 1 Z mpirun\n", Status.new(0)]
      else
        raise "Unexpected command: #{args.inspect}"
      end
    end
    @cleanup = GenerationCleanup.new(runner: runner, clock: -> { @now },
      sleeper: ->(seconds) { @sleeps << seconds; @now += seconds })
  end

  def test_empty_account_has_no_kill_or_sleep
    report = @cleanup.verify!
    assert report.fetch("verified_empty")
    assert_empty report.fetch("signal_attempts")
    assert_equal [["pgrep", "-u", "llmtest"]], @commands
    assert_empty @sleeps
  end

  def test_survivors_are_signalled_as_llmtest_and_disappearance_is_verified
    @listings = ["111\n222\n", "111\n", ""]
    report = @cleanup.verify!
    assert_equal ["su", "-", "llmtest", "--shell=/bin/bash", "-c", "kill -s KILL -- 111 222"], @commands.find { |c| c.first == "su" }
    assert_equal 1, report.fetch("signal_attempts").size
    assert_equal [0.1], @sleeps
    assert report.fetch("verified_empty")
  end

  def test_a_late_child_is_also_killed
    @listings = ["111\n", "222\n", ""]
    report = @cleanup.verify!
    assert_equal [[111], [222]], report.fetch("signal_attempts").map { |a| a.fetch("pids") }
    assert_empty @sleeps
  end

  def test_signal_success_does_not_hide_a_persistent_process_or_zombie
    @listings = ["111\n"]
    error = assert_raises(RuntimeError) { @cleanup.verify! }
    assert_in_delta 2.0, @now, 0.000001
    assert_match "111", error.message
    assert_match "Z mpirun", error.message
    assert_equal 1, @commands.count { |c| c.first == "su" }
  end

  def test_failed_signal_is_reported_when_process_remains
    @listings = ["111\n"]
    @kill_status = 1
    error = assert_raises(RuntimeError) { @cleanup.verify! }
    assert_match '"exit_status"=>1', error.message
    assert_match "No such process", error.message
    assert_in_delta 2.0, @now, 0.000001
  end

  def test_process_exit_racing_signal_is_safe_if_the_account_is_verified_empty
    @listings = ["111\n", ""]
    @kill_status = 1
    report = @cleanup.verify!
    assert report.fetch("verified_empty")
    assert_equal 1, report.fetch("signal_attempts").first.fetch("exit_status")
    assert_empty @sleeps
  end

  def test_listing_failure_never_causes_killing_or_a_false_empty_result
    @listing_status = 2
    assert_raises(RuntimeError) { @cleanup.verify! }
    refute @commands.any? { |c| c.first == "su" }
  end

  def test_invalid_or_inconsistent_pid_output_is_rejected
    ["1\n", "0\n", "-1\n", "111;echo x\n"].each do |value|
      @listings = [value]
      assert_raises(RuntimeError) { @cleanup.verify! }
    end
    @listings = ["111\n"]
    @listing_status = 1
    assert_raises(RuntimeError) { @cleanup.verify! }
    refute @commands.any? { |c| c.first == "su" }
  end
end
