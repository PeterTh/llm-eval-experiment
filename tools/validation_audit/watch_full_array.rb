# frozen_string_literal: true
require 'json'
require 'time'
require 'fiddle/import'

module ValidationAudit
  # A single, read-only local watcher. Kernel file notifications surface stops
  # and failures immediately; routine progress is emitted only at the requested
  # interval. It never starts or restarts a campaign or invokes a model.
  module FullArrayWatch
    module Native
      extend Fiddle::Importer
      dlload Fiddle.dlopen(nil)
      extern 'int inotify_init1(int)'
      extern 'int inotify_add_watch(int, const char*, unsigned int)'
    end
    module_function

    def reason(state, previous, last_report, now, interval)
      return 'terminal' if %w[complete stopped].include?(state.fetch('status'))
      return 'stale' if now - Time.iso8601(state.fetch('updated_at')) > 300
      return 'initial' unless previous
      return 'new_failure' unless (state.fetch('failed_ids') - previous.fetch('failed_ids')).empty?
      return 'progress' if now - last_report >= interval
      nil
    end

    def state_event?(bytes)
      offset, changed = 0, false
      while offset + 16 <= bytes.bytesize
        _wd, mask, _cookie, length = bytes.byteslice(offset, 16).unpack('iIII')
        raise 'Truncated inotify event' if offset + 16 + length > bytes.bytesize
        name = bytes.byteslice(offset + 16, length).split("\0", 2).first
        changed ||= name == 'state.json' || (mask & 0x4000) != 0 # IN_Q_OVERFLOW
        offset += 16 + length
      end
      raise 'Incomplete inotify payload' unless offset == bytes.bytesize
      changed
    end

    def run(evidence, interval: 3600)
      raise 'Reporting interval must be at least one minute' unless interval >= 60
      root = File.join(File.realpath(evidence), 'full-array-full')
      descriptor = Native.inotify_init1(0)
      raise 'Cannot initialize inotify' if descriptor.negative?
      io = IO.for_fd(descriptor, autoclose: true)
      io.close_on_exec = true
      # State updates use atomic rename; close-write also supports plain writers.
      raise 'Cannot watch sweep state' if Native.inotify_add_watch(descriptor, root, 0x8 | 0x80).negative?
      previous, last_report = nil, Time.at(0).utc
      check = true
      loop do
        if check
          state = JSON.parse(File.read(File.join(root, 'state.json')))
          now = Time.now.utc
          trigger = reason(state, previous, last_report, now, interval)
          if trigger
            puts JSON.generate('watch_event' => trigger, 'observed_at' => now.iso8601, 'state' => state)
            $stdout.flush
            previous, last_report = state, now
            return if %w[terminal stale].include?(trigger)
          end
        end
        ready = IO.select([io], nil, nil, 60)
        check = ready ? state_event?(io.readpartial(65_536)) : true
      end
    ensure
      io&.close
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: watch_full_array.rb HOME_EVIDENCE [PROGRESS_INTERVAL_SECONDS]' unless (1..2).cover?(ARGV.size)
  ValidationAudit::FullArrayWatch.run(ARGV[0], interval: ARGV[1] ? Integer(ARGV[1]) : 3600)
end
