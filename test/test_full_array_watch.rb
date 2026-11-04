# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/watch_full_array'

class FullArrayWatchTest < Minitest::Test
  Watch = ValidationAudit::FullArrayWatch

  def test_only_exceptional_changes_or_due_progress_are_reported
    now = Time.utc(2026, 11, 4, 21)
    state = { 'status' => 'running', 'updated_at' => now.iso8601, 'failed_ids' => ['known'] }
    assert_equal 'initial', Watch.reason(state, nil, now, now, 3600)
    assert_nil Watch.reason(state, state, now, now + 10, 3600)
    assert_equal 'new_failure', Watch.reason(state.merge('failed_ids' => %w[known new]), state, now, now + 10, 3600)
    assert_equal 'terminal', Watch.reason(state.merge('status' => 'stopped'), state, now, now + 10, 3600)
    assert_equal 'terminal', Watch.reason(state.merge('status' => 'complete'), state, now, now + 10, 3600)
    assert_equal 'stale', Watch.reason(state, state, now, now + 301, 3600)
    fresh = state.merge('updated_at' => (now + 3600).iso8601)
    assert_equal 'progress', Watch.reason(fresh, state, now, now + 3600, 3600)
  end

  def event(name, mask = 0x80)
    bytes = name + "\0"
    bytes << "\0" until (bytes.bytesize % 4).zero?
    [1, mask, 0, bytes.bytesize].pack('iIII') + bytes
  end

  def test_state_renames_and_queue_overflow_are_recognized
    assert Watch.state_event?(event('state.json'))
    refute Watch.state_event?(event('unrelated.json'))
    assert Watch.state_event?(event('unrelated.json') + event('state.json'))
    assert Watch.state_event?([-1, 0x4000, 0, 0].pack('iIII'))
    assert_raises(RuntimeError) { Watch.state_event?(event('state.json')[0...-1]) }
  end

  def test_kernel_watch_observes_atomic_state_replacement
    Dir.mktmpdir('full-array-watch-test-', '/tmp') do |directory|
      descriptor = Watch::Native.inotify_init1(0)
      assert_operator descriptor, :>=, 0
      io = IO.for_fd(descriptor, autoclose: true)
      begin
        assert_operator Watch::Native.inotify_add_watch(descriptor, directory, 0x80), :>=, 0
        File.write(File.join(directory, 'pending'), '{}')
        File.rename(File.join(directory, 'pending'), File.join(directory, 'state.json'))
        refute_nil IO.select([io], nil, nil, 1)
        assert Watch.state_event?(io.readpartial(65_536))
      ensure
        io.close
      end
    end
  end
end
