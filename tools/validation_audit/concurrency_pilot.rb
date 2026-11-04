# frozen_string_literal: true
require_relative 'shape_full'
require_relative 'parallel_batch'

module ValidationAudit
  class ConcurrencyPilot
    APPROVAL = 'shape-concurrency-authorization.json'
    DIRECTORY = 'shape-concurrency-pilot'
    # Only the small primary CPU cases can overlap. GPU visibility, CPU affinity,
    # rank counts, limits and correctness comparators are not changed.
    def self.eligible?(group)
      %w[mpi omp].include?(group.fetch('backend')) &&
        group.fetch('definition') == ShapeTopologyCampaign.definition(group.dig('definition', 'benchmark'), group.fetch('backend'))
    end

    def self.resource_snapshot
      memory = File.readlines('/proc/meminfo').to_h { |line| [line.split(':').first, line.split[1].to_i * 1024] }
      pressure = File.readlines('/proc/pressure/memory').to_h do |line|
        [line.split.first, line.split.find { |part| part.start_with?('total=') }.split('=').last.to_i]
      end
      events_path = "/sys/fs/cgroup/user.slice/user-#{Process.uid}.slice/user@#{Process.uid}.service/memory.events"
      events = File.file?(events_path) ? File.readlines(events_path).to_h { |line| name, value = line.split; [name, value.to_i] } : {}
      { 'available_bytes' => memory.fetch('MemAvailable'), 'total_bytes' => memory.fetch('MemTotal'),
        'pressure_microseconds' => pressure, 'memory_events' => events }
    end

    def initialize(workspace:, evidence:)
      @workspace, @evidence = File.realpath(workspace), File.expand_path(evidence)
      @root = File.join(@evidence, DIRECTORY)
      @campaign = FullShapeCampaign.new(workspace: @workspace, evidence: @evidence)
      @runner = Runner.new(workspace: @workspace, evidence: @evidence)
    end

    def prepare
      @campaign.verify_inputs!
      plan = ValidationAudit.read(File.join(@evidence, FullShapeCampaign::PLAN_FILE))
      approval = ValidationAudit.read(File.join(@evidence, APPROVAL))
      unless approval.fetch('source') == 'user' && approval.fetch('approved') && approval.fetch('max_workers') == 4 &&
          approval.fetch('plan_sha256') == ValidationAudit.sha(File.join(@evidence, FullShapeCampaign::PLAN_FILE)) && approval.fetch('benchmark_runs') == 0
        raise 'Concurrency authorization differs'
      end
      state = ValidationAudit.read(File.join(@evidence, 'shape-topology-full-state.json'))
      raise 'Serial sweep must checkpoint before the pilot' unless state.fetch('status') == 'stopped'
      @groups = plan.fetch('groups').select { |group| self.class.eligible?(group) }.map do |group|
        candidates = group.fetch('rows').select { |row| group.fetch('pilot_ids').include?(row.fetch('id')) }.filter_map do |row|
          path = File.join(@evidence, group.dig('definition', 'id'), row.fetch('id'), 'result.json')
          result = ValidationAudit.read(path)
          next unless result.fetch('passed') && !state.fetch('failed_ids').include?(row.fetch('id'))
          [row, result, path]
        end
        row, result, path = candidates.max_by { |_r, verdict, _p| verdict.dig('execution', 'wall_seconds') }
        raise "No passing pilot candidate for #{group.dig('definition', 'id')}" unless row
        group.slice('definition', 'backend').merge('row' => row, 'baseline_result_sha256' => ValidationAudit.sha(path),
          'previous_wall_seconds' => result.dig('execution', 'wall_seconds'), 'full_checks' => group.fetch('rows').size)
      end
      raise 'Pilot must cover all 22 primary CPU strata' unless @groups.size == 22
      definition = { 'schema_version' => 1, 'plan_sha256' => approval.fetch('plan_sha256'),
        'authorization_sha256' => ValidationAudit.sha(File.join(@evidence, APPROVAL)),
        'groups' => @groups, 'worker_counts' => [1, 2, 4],
        'selection' => 'The slower passing original pilot observation per MPI/OpenMP primary stratum. One fresh serial control, then two/four identical independent replicas to stress each stratum at the intended concurrency. Failures are never retried or silently discarded.',
        'benchmark_runs' => 0 }
      ValidationAudit.save(File.join(@root, 'plan.json'), definition)
      MethodSnapshot.save(@evidence, 'shape-concurrency-pilot')
    end

    def wave(group, workers, runners)
      definition, row = group.values_at('definition', 'row')
      reference = @campaign.reference_for(definition)
      before = self.class.resource_snapshot
      samples = [before]
      running = true
      monitor = Thread.new do
        while running
          sleep 0.5
          samples << self.class.resource_snapshot
        end
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      results = ParallelBatch.run((0...workers).to_a) do |replica, _index|
        runner = runners.fetch(replica)
        runner.check(row, definition, reference: reference)
        path = File.join(runner.evidence, definition.fetch('id'), row.fetch('id'), 'result.json')
        result = ValidationAudit.read(path)
        { 'replica' => replica, 'result_path' => path.delete_prefix(@evidence + '/'),
          'result_sha256' => ValidationAudit.sha(path), 'passed' => result.fetch('passed'),
          'comparison' => result.fetch('comparison'), 'execution' => result.fetch('execution') }
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      running = false
      monitor.join
      after = self.class.resource_snapshot
      samples << after
      event_deltas = after.fetch('memory_events').to_h { |key, value| [key, value - before.fetch('memory_events').fetch(key)] }
      pressure_deltas = after.fetch('pressure_microseconds').to_h { |key, value| [key, value - before.fetch('pressure_microseconds').fetch(key)] }
      resources_ok = samples.map { |s| s.fetch('available_bytes') }.min >= before.fetch('total_bytes') * 0.25 &&
        %w[oom oom_kill max].all? { |key| event_deltas.fetch(key, 0).zero? } && pressure_deltas.fetch('full') < 500_000
      report = { 'case_id' => definition.fetch('id'), 'backend' => group.fetch('backend'), 'id' => row.fetch('id'),
        'workers' => workers, 'checks' => workers, 'wall_seconds' => elapsed, 'seconds_per_check' => elapsed / workers,
        'all_passed' => results.all? { |r| r.fetch('passed') }, 'resources_ok' => resources_ok,
        'minimum_available_bytes' => samples.map { |s| s.fetch('available_bytes') }.min,
        'memory_events_delta' => event_deltas, 'memory_pressure_microseconds_delta' => pressure_deltas,
        'records' => results, 'benchmark_runs' => 0 }
      path = File.join(@root, 'waves', "#{definition.fetch('id')}-#{group.fetch('backend')}-w#{workers}.json")
      ValidationAudit.save(path, report)
      puts JSON.generate(report.reject { |key, _| key == 'records' }.merge('event' => 'concurrency_pilot_wave'))
      $stdout.flush
      report
    ensure
      running = false
      monitor&.join
    end

    def run
      prepare
      stages = []
      @runner.with_host do
        @groups.each { |group| @runner.binary_for(group.fetch('row')) }
        [1, 2, 4].each do |workers|
          runners = Array.new(workers) do |replica|
            Runner.new(workspace: @workspace, evidence: File.join(@root, "w#{workers}", "replica-#{replica}"))
          end
          reports = []
          @groups.each do |group|
            report = wave(group, workers, runners)
            reports << report
            break unless report.fetch('all_passed') && report.fetch('resources_ok')
          end
          clean = reports.all? { |report| report.fetch('all_passed') && report.fetch('resources_ok') }
          summary = { 'workers' => workers, 'clean' => clean, 'checks' => reports.sum { |r| r.fetch('checks') },
            'wall_seconds' => reports.sum { |r| r.fetch('wall_seconds') }, 'groups' => reports, 'benchmark_runs' => 0 }
          ValidationAudit.save(File.join(@root, "stage-w#{workers}.json"), summary)
          stages << summary
          puts JSON.generate(summary.reject { |key, _| key == 'groups' }.merge('event' => 'concurrency_pilot_stage'))
          $stdout.flush
          break unless clean
        end
      end
      report = { 'schema_version' => 1, 'completed_at' => Time.now.utc.iso8601,
        'plan_sha256' => ValidationAudit.sha(File.join(@root, 'plan.json')),
        'stages' => stages.map { |stage| stage.reject { |key, _| key == 'groups' } }, 'benchmark_runs' => 0 }
      ValidationAudit.save(File.join(@root, 'completion.json'), report)
      puts JSON.pretty_generate(report)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: concurrency_pilot.rb WORKSPACE EVIDENCE' unless ARGV.size == 2
  ValidationAudit::ConcurrencyPilot.new(workspace: ARGV[0], evidence: ARGV[1]).run
end
