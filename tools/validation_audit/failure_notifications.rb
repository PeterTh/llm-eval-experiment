# frozen_string_literal: true
require_relative 'inventory'

module ValidationAudit
  module FailureNotifications
    module_function
    def paths(evidence)
      [File.join(evidence, 'shape-full-failure-events'), File.join(evidence, 'shape-full-announcements.json')]
    end
    def pending(evidence)
      events, announcements = paths(evidence)
      sent = File.file?(announcements) ? ValidationAudit.read(announcements).fetch('announced') : {}
      Dir[File.join(events, '*.json')].sort.filter_map do |path|
        record = ValidationAudit.read(path)
        id = record.fetch('id')
        if sent.key?(id)
          raise 'Announced failure event changed' unless sent.fetch(id).fetch('event_sha256') == ValidationAudit.sha(path)
          next
        end
        record
      end
    end
    def mark(evidence, ids)
      raise 'Specify at least one ID actually reported in the conversation' if ids.empty?
      events, announcements = paths(evidence)
      saved = File.file?(announcements) ? ValidationAudit.read(announcements) : { 'announced' => {} }
      ids.each do |id|
        raise 'Unsafe failure ID' unless File.basename(id) == id && !id.include?('..')
        path = File.join(events, id + '.json')
        record = ValidationAudit.read(path)
        raise 'Failure event ID differs' unless record.fetch('id') == id
        raise 'Failure already announced' if saved.fetch('announced').key?(id)
        saved.fetch('announced')[id] = { 'announced_at' => Time.now.utc.iso8601, 'event_sha256' => ValidationAudit.sha(path) }
      end
      LocalEvaluation.atomic_write(announcements, JSON.pretty_generate(saved) + "\n")
      puts JSON.generate(announced: ids)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: failure_notifications.rb EVIDENCE pending|mark [IDS...]' unless ARGV.size >= 2
  evidence, command, *ids = ARGV
  case command
  when 'pending' then puts JSON.pretty_generate(ValidationAudit::FailureNotifications.pending(evidence))
  when 'mark' then ValidationAudit::FailureNotifications.mark(evidence, ids)
  else raise 'Use pending or mark'
  end
end
