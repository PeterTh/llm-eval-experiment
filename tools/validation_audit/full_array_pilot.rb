# frozen_string_literal: true
require_relative 'full_array_capture'
require_relative 'shape_topology'

module ValidationAudit
  class FullArrayPilot
    PHASE = 'full-array-pilot-01'

    def initialize(workspace:, evidence:)
      @workspace, @evidence = File.realpath(workspace), File.realpath(evidence)
      @root = File.join(@evidence, PHASE)
      @runner = Runner.new(workspace: @workspace, evidence: @evidence)
    end

    def prepare
      prior_path = File.join(@evidence, 'spmv-work-count-full/completion.json')
      prior = ValidationAudit.read(prior_path)
      raise 'SpMV review is incomplete' unless prior.fetch('status') == 'complete' && prior.fetch('remaining').zero?
      path = File.join(@root, 'plan.json')
      hashes = FullArrayCapture.retain_method(@evidence).merge('full_array_pilot.rb' => ValidationAudit.sha(__FILE__))
      if File.exist?(path)
        plan = ValidationAudit.read(path)
        raise 'Observer method changed during pilot' unless plan.fetch('method_sha256') == hashes
        verify_plan(plan)
        return plan
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      benchmarks = LocalEvaluation::BENCHMARKS - ['floydwarshall']
      current = Inventory.new(benchmarks: benchmarks)
      winners = ValidationAudit.read(File.join(RELEASE, 'analysis/notes/2026-11-03-winner-validity/evidence.json'))
        .fetch('winners').map { |row| row.fetch('id') }
      inventories = benchmarks.to_h do |benchmark|
        saved = ValidationAudit.read(File.join(@evidence, "inventory-#{benchmark}.json"))
        [benchmark, saved.fetch('rows').to_h { |row| [row.fetch('id'), row] }]
      end
      rows = current.rows.map do |row|
        saved = inventories.fetch(row.fetch('benchmark')).fetch(row.fetch('id'))
        %w[id source_path source_commit validation_record validation_stdout_sha256].each do |key|
          raise "Source transition differs #{row.fetch('id')} #{key}" unless row.fetch(key) == saved.fetch(key)
        end
        saved
      end
      costs = current.records.transform_values do |record|
        Float(record.dig('execution', 'wall_seconds') || record.dig('logs', 'validation_out_wall_time.log'))
      end
      groups = rows.group_by { |row| [row.fetch('benchmark'), row.fetch('backend')] }.sort.map do |(benchmark, backend), group|
        ordered = group.sort_by { |row| [costs.fetch(row.fetch('id')), row.fetch('id')] }
        winner = group.find { |row| winners.include?(row.fetch('id')) }
        raise "Missing eligible winner #{benchmark}/#{backend}" unless winner
        selected = [winner, ordered[ordered.size / 2], ordered[(ordered.size * 0.9).floor]].uniq
        flags = benchmark == 'roomsim' ? %w[-v -o] : %w[-v -r]
        { 'benchmark' => benchmark, 'backend' => backend,
          'args' => flags + ShapeTopologyCampaign::ARGUMENTS.fetch(benchmark),
          'full_ids' => group.map { |r| r.fetch('id') }.sort, 'pilot_rows' => selected }
      end
      plan = { 'schema_version' => 1, 'phase' => PHASE, 'created_at' => Time.now.utc.iso8601,
        'scope' => 'All currently eligible floating-point-result implementations, including subsequent benchmark failures. Floyd integer full-result validation is already complete.',
        'population' => rows.size, 'pilot_checks' => groups.sum { |g| g.fetch('pilot_rows').size },
        'selection' => 'Current winner, median and 90th-percentile original validation runtime in each benchmark/backend stratum; deterministic ID tie-break.',
        'topology' => 'Established validation allocation: 8 OpenMP threads, 4 MPI ranks, or 4 ranks x 8 threads and one GPU each for hybrid. No performance samples.',
        'release_commit' => current.release_commit, 'release_csv_sha256' => current.release_digest,
        'catalog_sha256' => current.catalog_digest, 'preceding_completion_sha256' => ValidationAudit.sha(prior_path),
        'method_sha256' => hashes, 'inventory_sha256' => benchmarks.to_h { |b| [b, ValidationAudit.sha(File.join(@evidence, "inventory-#{b}.json"))] },
        'preparation_seconds' => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
        'groups' => groups, 'benchmark_runs' => 0, 'full_sweep_authorized' => false }
      ValidationAudit.save(path, plan)
      # Retain this authored driver, too; do not rely on an uncommitted worktree.
      digest = hashes.fetch('full_array_pilot.rb')
      directory = File.join(@evidence, 'full-array-methods', digest)
      FileUtils.mkdir_p(directory)
      File.open(File.join(directory, 'full_array_pilot.rb'), File::WRONLY | File::CREAT | File::EXCL) { |f| f.write(File.binread(__FILE__)) }
      verify_plan(plan)
      puts JSON.generate(plan.slice('population', 'pilot_checks', 'selection', 'preparation_seconds'))
      plan
    end

    def verify_plan(plan)
      raise 'Release changed during pilot' unless plan.fetch('release_csv_sha256') == ValidationAudit.sha(File.join(RELEASE, 'release/scored_results.csv')) &&
        plan.fetch('catalog_sha256') == ValidationAudit.sha(File.join(RELEASE, 'release/catalog.json'))
      plan.fetch('inventory_sha256').each do |benchmark, digest|
        raise 'Pinned source inventory changed' unless digest == ValidationAudit.sha(File.join(@evidence, "inventory-#{benchmark}.json"))
      end
      plan.fetch('groups').flat_map { |g| g.fetch('pilot_rows') }.each do |row|
        binding = ValidationAudit.read(File.join(@evidence, 'bindings', row.fetch('id') + '.json'))
        raise 'Pilot executable/source binding differs' unless binding.fetch('source_files') == row.fetch('source_files') &&
          ValidationAudit.sha(binding.fetch('executable')) == binding.fetch('binary_sha256')
      end
    end

    def observation(id, benchmark, backend, args)
      path = File.join(@root, id, 'observation.json')
      if File.exist?(path)
        saved = ValidationAudit.read(path)
        raise 'Incomplete/changed observation requires separate infrastructure review' unless saved.fetch('observation_complete') &&
          saved.fetch('id') == id && saved.fetch('args') == args && saved.fetch('backend') == backend
        return saved
      end
      FullArrayCapture.capture(workspace: @workspace, evidence: @evidence, id: id,
        benchmark: benchmark, backend: backend, args: args, phase: PHASE)
    end

    def run
      plan = prepare
      raise 'Pilot already complete' if File.exist?(File.join(@root, 'completion.json'))
      summaries = []
      @runner.with_host do
        plan.fetch('groups').each do |group|
          benchmark, backend, args = group.values_at('benchmark', 'backend', 'args')
          reference = observation("reference_#{benchmark}", benchmark, 'sequential', args)
          raise 'Incomplete reference observation' unless reference.fetch('observation_complete')
          reference_output = File.read(File.join(@root, "reference_#{benchmark}", 'validation_stdout.log'))
          results = group.fetch('pilot_rows').map do |row|
            id = row.fetch('id')
            result_path = File.join(@root, id, 'comparison.json')
            if File.exist?(result_path)
              saved = ValidationAudit.read(result_path)
              raise 'Pilot result source binding differs' unless saved.fetch('source') == row
              next saved
            end
            actual = observation(id, benchmark, backend, args)
            raise "Incomplete observation #{id}; no scientific verdict assigned" unless actual.fetch('observation_complete')
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            comparison = FullArrayCapture.compare(reference, actual)
            original = validate(reference_output, File.read(File.join(@root, id, 'validation_stdout.log')), benchmark)
            comparison['sparse_comparison'] = original
            comparison['source'] = row
            comparison['observation_sha256'] = ValidationAudit.sha(File.join(@root, id, 'observation.json'))
            comparison['total_check_seconds'] = actual.fetch('total_seconds') + Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            comparison['passed'] &&= original.first
            ValidationAudit.save(result_path, comparison)
            puts JSON.generate('id' => id, 'full_array_passed' => comparison.fetch('passed'),
              'sparse_passed' => original.first, 'mismatches' => comparison.fetch('arrays').sum { |r| r.fetch('mismatches') })
            $stdout.flush
            comparison
          end
          elapsed = results.sum { |r| r.fetch('total_check_seconds') }
          summaries << { 'benchmark' => benchmark, 'backend' => backend,
            'pilot_ids' => results.map { |r| r.fetch('id') }, 'full_count' => group.fetch('full_ids').size,
            'pilot_seconds' => elapsed, 'projected_seconds' => elapsed / results.size * group.fetch('full_ids').size,
            'failed_ids' => results.reject { |r| r.fetch('passed') }.map { |r| r.fetch('id') } }
        end
      end
      reference_seconds = Dir.glob(File.join(@root, 'reference_*', 'observation.json')).sum { |p| ValidationAudit.read(p).fetch('total_seconds') }
      projected = summaries.sum { |r| r.fetch('projected_seconds') }
      conservative = projected * 1.5 + reference_seconds + plan.fetch('preparation_seconds') + 600
      completion = { 'status' => 'pilot_complete', 'population' => plan.fetch('population'),
        'pilot_checks' => plan.fetch('pilot_checks'), 'groups' => summaries,
        'projected_full_hours' => projected / 3600, 'conservative_full_hours' => conservative / 3600,
        'under_five_hours' => conservative < 18000, 'full_sweep_launched' => false,
        'failed_ids' => summaries.flat_map { |g| g.fetch('failed_ids') },
        'estimate_basis' => 'Per-stratum complete observer execution, capture integrity checks and numerical comparison; 50% margin plus reference/setup cost and ten minutes. Saved actual costs are reused on resume, never cached replay time.',
        'plan_sha256' => ValidationAudit.sha(File.join(@root, 'plan.json')), 'completed_at' => Time.now.utc.iso8601,
        'benchmark_runs' => 0, 'program_source_changes' => 0, 'executable_file_changes' => 0 }
      ValidationAudit.save(File.join(@root, 'completion.json'), completion)
      puts JSON.pretty_generate(completion.reject { |key, _| key == 'groups' })
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: full_array_pilot.rb WORKSPACE EVIDENCE prepare|pilot' unless ARGV.size == 3
  pilot = ValidationAudit::FullArrayPilot.new(workspace: ARGV[0], evidence: ARGV[1])
  case ARGV[2]
  when 'prepare' then pilot.prepare
  when 'pilot' then pilot.run
  else raise 'Use prepare or pilot'
  end
end
