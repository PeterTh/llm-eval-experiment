# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../tools/validation_audit/failure_notifications'

class ValidationFailureNotificationsTest < Minitest::Test
  NOTIFICATIONS = ValidationAudit::FailureNotifications

  def fixture
    Dir.mktmpdir('validation-notifications-') do |directory|
      %w[shape full-array].each do |scope|
        events, = NOTIFICATIONS.paths(directory, scope: scope)
        ValidationAudit.save(File.join(events, scope + '.json'), { 'id' => scope, 'reason' => 'fixture' })
      end
      yield directory
    end
  end

  def test_scopes_are_separate_and_default_is_backwards_compatible
    fixture do |directory|
      assert_equal ['shape'], NOTIFICATIONS.pending(directory).map { |e| e.fetch('id') }
      assert_equal ['full-array'], NOTIFICATIONS.pending(directory, scope: 'full-array').map { |e| e.fetch('id') }
      assert_raises(RuntimeError) { NOTIFICATIONS.paths(directory, scope: 'other') }
    end
  end

  def test_marking_does_not_affect_the_other_scope
    fixture do |directory|
      capture_io { NOTIFICATIONS.mark(directory, ['full-array'], scope: 'full-array') }
      assert_empty NOTIFICATIONS.pending(directory, scope: 'full-array')
      assert_equal 1, NOTIFICATIONS.pending(directory).size
      assert_raises(RuntimeError) { NOTIFICATIONS.mark(directory, ['full-array'], scope: 'full-array') }
    end
  end

  def test_changed_previously_announced_event_is_detected
    fixture do |directory|
      capture_io { NOTIFICATIONS.mark(directory, ['full-array'], scope: 'full-array') }
      events, = NOTIFICATIONS.paths(directory, scope: 'full-array')
      LocalEvaluation.atomic_write(File.join(events, 'full-array.json'), JSON.generate('id' => 'full-array', 'reason' => 'changed'))
      assert_raises(RuntimeError) { NOTIFICATIONS.pending(directory, scope: 'full-array') }
    end
  end

  def test_missing_or_unsafe_ids_cannot_be_marked
    fixture do |directory|
      assert_raises(RuntimeError) { NOTIFICATIONS.mark(directory, [], scope: 'full-array') }
      assert_raises(RuntimeError) { NOTIFICATIONS.mark(directory, ['../outside'], scope: 'full-array') }
      assert_raises(Errno::ENOENT) { NOTIFICATIONS.mark(directory, ['missing'], scope: 'full-array') }
    end
  end
end
