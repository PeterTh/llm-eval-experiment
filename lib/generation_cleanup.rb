# frozen_string_literal: true
require "open3"

# Called only after an invocation on the exclusively reserved evaluation account.
# Never use this to clear an account before the first invocation: it might belong
# to an unrelated interactive session. The caller must check that it is idle.
class GenerationCleanup
  WAIT_SECONDS = 2.0
  POLL_SECONDS = 0.1

  def initialize(user: "llmtest", runner: Open3.method(:capture2e),
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: Kernel.method(:sleep))
    @user, @runner, @clock, @sleeper = user, runner, clock, sleeper
  end

  def pids
    output, result = @runner.call("pgrep", "-u", @user)
    raise "Cannot inspect #{@user} processes (exit #{result.exitstatus}): #{output.strip}" unless [0, 1].include?(result.exitstatus)
    return [] if result.exitstatus == 1 && output.strip.empty?
    values = output.split
    unless result.exitstatus == 0 && !values.empty? && values.all? { |value| value.match?(/\A[1-9][0-9]*\z/) && value.to_i > 1 }
      raise "Invalid process listing for #{@user}: #{output.inspect}"
    end
    values.map(&:to_i).uniq.sort
  end

  def verify!
    started = @clock.call
    deadline = started + WAIT_SECONDS
    signalled = []
    attempts = []
    remaining = pids
    until remaining.empty?
      if @clock.call >= deadline
        details, = @runner.call("ps", "-p", remaining.join(","), "-o", "pid=,ppid=,stat=,comm=")
        raise "Post-run cleanup exceeded #{WAIT_SECONDS}s; #{@user} PIDs #{remaining.join(', ')} remain. " \
          "Process states: #{details.strip}. Signal attempts: #{attempts.inspect}"
      end
      targets = remaining - signalled
      unless targets.empty?
        # Only these validated numeric PIDs are signalled. The short-lived su/shell
        # used to signal them was not in the snapshot, so it cannot kill itself.
        output, result = @runner.call("su", "-", @user, "--shell=/bin/bash", "-c", "kill -s KILL -- #{targets.join(' ')}")
        attempts << { "pids" => targets, "exit_status" => result.exitstatus, "output" => output.strip }
        signalled.concat(targets)
        # An ESRCH race is harmless if the postcondition is met; neither a zero
        # nor a nonzero signal-command status substitutes for checking it.
        remaining = pids
        next
      end
      @sleeper.call([POLL_SECONDS, deadline - @clock.call].min.clamp(0, POLL_SECONDS))
      remaining = pids
    end
    { "verified_empty" => true, "wait_limit_seconds" => WAIT_SECONDS,
      "elapsed_seconds" => (@clock.call - started).round(6), "signal_attempts" => attempts }
  end
end
