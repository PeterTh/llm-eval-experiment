# frozen_string_literal: true
require_relative 'campaign'
require_relative 'method_snapshot'

module ValidationAudit
  class ShapeTopologyCampaign < Campaign
    ARGUMENTS = {
      'black-scholes' => %w[-n 10003], 'cahn-hilliard' => %w[-x 65 -y 61 -z 67 -i 21],
      'cholesky' => %w[-n 513], 'floydwarshall' => %w[-n 513], 'matmul' => %w[-n 513],
      'nbody' => %w[-n 1031 -s 11], 'qtclustering' => %w[-n 1001 -t 1.3],
      'roomsim' => %w[-n 320 -t 101 -s 7 -r 0.7], 'spmv' => %w[-n 1025 -s 40 -i 67],
      'stencil3d' => %w[-x 65 -y 61 -z 67 -i 21], 'unstructured' => %w[-n 33 -i 513]
    }.freeze

    def self.definition(benchmark, backend)
      flags = benchmark == 'roomsim' ? %w[-v -o] : %w[-v -r]
      args = ARGUMENTS.fetch(benchmark).dup
      # Keep every grid dimension above the rank count, regardless of which
      # axis an implementation partitions. Preserve nondivisible dimensions.
      if backend == 'mpi'
        args = %w[-x 129 -y 131 -z 257 -i 21] if %w[cahn-hilliard stencil3d].include?(benchmark)
        args = %w[-n 257 -i 513] if benchmark == 'unstructured'
      end
      revision = backend == 'mpi' && %w[cahn-hilliard stencil3d].include?(benchmark) ? 2 : 1
      definition = { 'id' => "#{benchmark}-shape-#{backend == 'mpi' ? 'mpi128' : 'topology'}-v#{revision}", 'benchmark' => benchmark,
        'args' => flags + args, 'topology' => 'measurement', 'timeout' => 30 }
      definition['comparison'] = 'integer_hash' if benchmark == 'floydwarshall'
      definition
    end

    FAST_PATHS = [
      ['cahn-hilliard', 'omp', 'large-fused', %w[-v -r -x 512 -i 3]],
      ['stencil3d', 'omp', 'large-streaming', %w[-v -r -x 512 -i 3]],
      ['cholesky', 'omp', 'large-tile', %w[-v -r -n 1537]]
    ].freeze

    def prepare_plan
      path = File.join(@evidence, 'shape-topology-plan.json')
      return ValidationAudit.read(path) if File.file?(path)
      excluded = Dir[File.join(@evidence, '*-completion.json')].flat_map { |p| ValidationAudit.read(p).fetch('failed_ids') }.uniq.sort
      groups = []
      costs = {}
      source_seconds = 0
      ARGUMENTS.each_key do |benchmark|
        current, saved = inventory(benchmark)
        source_seconds += saved.fetch('source_binding_seconds')
        current.records.each do |id, record|
          costs[id] = (record.dig('execution', 'wall_seconds') || record.dig('logs', 'validation_out_wall_time.log')).to_f
        end
        selected = saved.fetch('rows').reject { |row| excluded.include?(row.fetch('id')) }
        selected.group_by { |row| row.fetch('backend') }.each do |backend, rows|
          groups << { 'definition' => self.class.definition(benchmark, backend), 'backend' => backend, 'rows' => rows }
        end
        FAST_PATHS.select { |b, _p, _label, _args| b == benchmark }.each do |_b, backend, label, args|
          rows = selected.select { |row| row.fetch('backend') == backend }
          definition = { 'id' => "#{benchmark}-#{label}-v1", 'benchmark' => benchmark,
            'args' => args, 'topology' => 'measurement', 'timeout' => 30 }
          groups << { 'definition' => definition, 'backend' => backend, 'rows' => rows }
        end
      end
      groups.each do |group|
        ordered = group.fetch('rows').sort_by { |row| [costs.fetch(row.fetch('id')), row.fetch('id')] }
        group['pilot_ids'] = [ordered[ordered.size / 2], ordered[(ordered.size * 0.9).floor]].map { |row| row.fetch('id') }.uniq
      end
      plan = { 'scope' => 'All still-valid observations: nondefault shapes/iteration parity with measured resource topology, plus known large-size CPU paths. Correctness only, never performance samples.',
        'excluded_prior_failures' => excluded, 'source_binding_seconds' => source_seconds,
        'checks' => groups.sum { |g| g.fetch('rows').size }, 'unique_programs' => groups.flat_map { |g| g.fetch('rows').map { |r| r.fetch('id') } }.uniq.size,
        'pilot_checks' => groups.sum { |g| g.fetch('pilot_ids').size }, 'groups' => groups }
      ValidationAudit.save(path, plan)
      plan
    end

    def pilot
      MethodSnapshot.save(@evidence, 'shape-topology-pilot')
      plan = prepare_plan
      path = File.join(@evidence, 'shape-topology-pilot.json')
      raise 'Pilot already complete' if File.file?(path)
      unless Dir[File.join(@evidence, 'shape-pilot-groups', '*.json')].empty?
        raise 'Incomplete pilot needs elapsed-cost reconciliation before resuming; cached checks must not reduce the estimate'
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      summaries = []
      @runner.with_host do
        plan.fetch('groups').each do |group|
          definition = group.fetch('definition')
          benchmark = definition.fetch('benchmark')
          reference_row = ValidationAudit.bind_source({ 'id' => "reference_#{benchmark}", 'benchmark' => benchmark,
            'backend' => 'sequential', 'source_path' => '', 'source_commit' => INPUT_COMMIT }, repository: INPUT)
          reference_result = @runner.check(reference_row, definition)
          raise 'Sequential reference failed' unless reference_result.fetch('passed')
          reference = File.read(File.join(@evidence, definition.fetch('id'), reference_row.fetch('id'), 'validation_stdout.log'))
          rows = group.fetch('rows').select { |row| group.fetch('pilot_ids').include?(row.fetch('id')) }
          before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          results = rows.map { |row| @runner.check(row, definition, reference: reference) }
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - before
          summary = { 'case' => definition.fetch('id'), 'backend' => group.fetch('backend'), 'pilot_ids' => group.fetch('pilot_ids'),
            'full_checks' => group.fetch('rows').size, 'pilot_seconds' => elapsed,
            'projected_full_seconds' => elapsed / rows.size * group.fetch('rows').size,
            'passed' => results.count { |r| r.fetch('passed') }, 'failed_ids' => results.reject { |r| r.fetch('passed') }.map { |r| r.fetch('id') } }
          summaries << summary
          ValidationAudit.save(File.join(@evidence, 'shape-pilot-groups', "#{definition.fetch('id')}-#{group.fetch('backend')}.json"), summary)
          puts JSON.generate(summary)
          $stdout.flush
        end
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      setup = elapsed - summaries.sum { |r| r.fetch('pilot_seconds') }
      projected = summaries.sum { |r| r.fetch('projected_full_seconds') }
      estimate = projected * 1.5 + setup + plan.fetch('source_binding_seconds') + 600
      report = { 'checks' => plan.fetch('checks'), 'unique_programs' => plan.fetch('unique_programs'), 'pilot_checks' => plan.fetch('pilot_checks'),
        'pilot_seconds' => elapsed, 'projected_full_seconds' => projected,
        'estimated_full_seconds_conservative' => estimate, 'under_five_hours' => estimate < 18000,
        'estimate_basis' => 'Per benchmark/backend/path strata, median and 90th-percentile original validation cost observations; project observed preparation+correctness cost to each stratum, add 50% margin, one-time setup, source binding and ten minutes for verification.',
        'groups' => summaries, 'benchmark_runs' => 0 }
      ValidationAudit.save(path, report)
      puts JSON.pretty_generate(report.reject { |k, _| k == 'groups' })
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: shape_topology.rb WORKSPACE EVIDENCE prepare|pilot' unless ARGV.size == 3
  campaign = ValidationAudit::ShapeTopologyCampaign.new(workspace: ARGV[0], evidence: ARGV[1])
  case ARGV[2]
  when 'prepare'
    puts JSON.pretty_generate(campaign.prepare_plan.reject { |key, _| key == 'groups' })
  when 'pilot' then campaign.pilot
  else raise 'Use prepare or pilot'
  end
end
