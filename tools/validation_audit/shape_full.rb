# frozen_string_literal: true
require_relative 'shape_topology'
require_relative 'parallel_batch'
require_relative 'concurrency_policy'

module ValidationAudit
  class FullShapeCampaign < ShapeTopologyCampaign
    PLAN_FILE = 'shape-topology-refined-plan.json'
    PILOT_FILE = 'shape-topology-refined-pilot.json'
    APPROVAL_FILE = 'shape-topology-full-authorization.json'

    def self.check_authorization!(approval, plan_digest, pilot_digest, plan)
      unless approval.fetch('source') == 'user' && approval.fetch('approved') == true &&
          approval.fetch('scope') == 'full-shape-topology-sweep' &&
          approval.fetch('plan_sha256') == plan_digest && approval.fetch('pilot_sha256') == pilot_digest &&
          approval.fetch('planned_checks') == plan.fetch('checks') && approval.fetch('benchmark_runs') == 0 &&
          !approval.fetch('statement').strip.empty?
        raise 'Full-sweep approval does not match the frozen scope'
      end
    end

    def self.expected_definition(group)
      benchmark, backend = group.dig('definition', 'benchmark'), group.fetch('backend')
      path = FAST_PATHS.find { |b, p, label, _args| b == benchmark && p == backend && group.dig('definition', 'id') == "#{b}-#{label}-v1" }
      return definition(benchmark, backend) unless path
      { 'id' => "#{benchmark}-#{path[2]}-v1", 'benchmark' => benchmark,
        'args' => path[3], 'topology' => 'measurement', 'timeout' => 30 }
    end

    def verify_inputs!
      @plan = ValidationAudit.read(File.join(@evidence, PLAN_FILE))
      @pilot = ValidationAudit.read(File.join(@evidence, PILOT_FILE))
      @approval = ValidationAudit.read(File.join(@evidence, APPROVAL_FILE))
      @plan_digest = ValidationAudit.sha(File.join(@evidence, PLAN_FILE))
      @pilot_digest = ValidationAudit.sha(File.join(@evidence, PILOT_FILE))
      self.class.check_authorization!(@approval, @plan_digest, @pilot_digest, @plan)
      @groups = @plan.fetch('groups')
      @scheduling = ConcurrencyPolicy.load(@evidence, @plan)
      excluded = @plan.fetch('excluded_prior_failures')
      inventory = ARGUMENTS.keys.to_h { |benchmark| [benchmark, ValidationAudit.read(File.join(@evidence, "inventory-#{benchmark}.json"))] }
      current_csv = ValidationAudit.sha(File.join(RELEASE, 'release/scored_results.csv'))
      current_catalog = ValidationAudit.sha(File.join(RELEASE, 'release/catalog.json'))
      inventory.each_value do |value|
        raise 'Release changed since scope was frozen' unless value.fetch('release_csv_sha256') == current_csv && value.fetch('catalog_sha256') == current_catalog
      end
      expected_groups = ARGUMENTS.keys.product(%w[cuda hybrid mpi omp]).map { |b, p| [self.class.definition(b, p).fetch('id'), p] }
      expected_groups += FAST_PATHS.map { |b, p, label, _args| ["#{b}-#{label}-v1", p] }
      actual_groups = @groups.map { |g| [g.dig('definition', 'id'), g.fetch('backend')] }
      raise 'Full sweep has omitted, duplicated or unexpected groups' unless actual_groups.sort == expected_groups.sort
      @groups.each do |group|
        definition = group.fetch('definition')
        raise 'Full case differs from the piloted case' unless definition == self.class.expected_definition(group)
        benchmark = definition.fetch('benchmark')
        rows = inventory.fetch(benchmark).fetch('rows').reject { |r| excluded.include?(r.fetch('id')) }
          .select { |r| r.fetch('backend') == group.fetch('backend') }
        raise 'Full source scope differs from inventory' unless group.fetch('rows') == rows
        pilot = @pilot.fetch('groups').find { |p| p.fetch('case') == definition.fetch('id') && p.fetch('backend') == group.fetch('backend') }
        raise 'Missing pilot stratum' unless pilot && pilot.fetch('full_checks') == rows.size && pilot.fetch('pilot_ids') == group.fetch('pilot_ids')
        raise 'Pilot cost must be positive' unless pilot.fetch('pilot_seconds').positive? && pilot.fetch('projected_full_seconds').positive?
      end
      checks = @groups.sum { |g| g.fetch('rows').size }
      unique = @groups.flat_map { |g| g.fetch('rows').map { |r| r.fetch('id') } }.uniq.size
      raise 'Full scope count differs' unless checks == @plan.fetch('checks') && checks == @pilot.fetch('checks') && unique == @plan.fetch('unique_programs')
      @results, @skips, @references, @failures = {}, {}, {}, {}
      @costs = {}
      @current = nil
      @groups.each do |group|
        group.fetch('rows').each do |row|
          key = result_key(row, group.fetch('definition'))
          path = File.join(@evidence, key, 'result.json')
          next unless File.file?(path)
          result = ValidationAudit.read(path)
          verify_result!(row, group.fetch('definition'), result)
          @results[key] = result
          @failures[row.fetch('id')] ||= key unless result.fetch('passed')
        end
      end
      @groups.each do |group|
        group.fetch('rows').each do |row|
          key = result_key(row, group.fetch('definition'))
          path = File.join(@evidence, 'shape-full-skips', key + '.json')
          next unless File.file?(path)
          skip = ValidationAudit.read(path)
          basis = @results.fetch(skip.fetch('failed_result_key'))
          unless !@results.key?(key) && basis.fetch('passed') == false && basis.fetch('id') == row.fetch('id') &&
              skip.fetch('plan_sha256') == @plan_digest && skip.fetch('source_commit') == row.fetch('source_commit') &&
              skip.fetch('failed_result_sha256') == ValidationAudit.sha(File.join(@evidence, skip.fetch('failed_result_key'), 'result.json'))
            raise 'Skipped-check basis changed'
          end
          @skips[key] = skip
        end
      end
      true
    end

    def result_key(row, definition) = "#{definition.fetch('id')}/#{row.fetch('id')}"

    def reference_for(definition)
      @references[definition.fetch('id')] ||= begin
        directory = File.join(@evidence, definition.fetch('id'), "reference_#{definition.fetch('benchmark')}")
        result = ValidationAudit.read(File.join(directory, 'result.json'))
        output = File.read(File.join(directory, 'validation_stdout.log'))
        unless result.fetch('passed') && result.fetch('definition') == definition && result.fetch('source_commit') == INPUT_COMMIT &&
            result.fetch('output_sha256') == Digest::SHA256.hexdigest(output)
          raise 'Pilot reference changed or failed'
        end
        output
      end
    end

    def verify_result!(row, definition, result)
      %w[id source_commit source_path].each { |field| raise 'Result/source identity changed' unless result.fetch(field) == row.fetch(field) }
      raise 'Result case or purpose changed' unless result.fetch('definition') == definition && result.fetch('performance_measurement') == false
      reference = reference_for(definition)
      output = File.read(File.join(@evidence, result_key(row, definition), 'validation_stdout.log'))
      unless result.fetch('output_sha256') == Digest::SHA256.hexdigest(output) && result.fetch('reference_sha256') == Digest::SHA256.hexdigest(reference)
        raise 'Result or reference digest changed'
      end
      comparison = if !result.dig('execution', 'success')
        [false, "Supplemental correctness execution failed: exit #{result.dig('execution', 'exit_code')}, timeout #{result.dig('execution', 'timed_out')}."]
      elsif !result.fetch('internal_validation')
        [false, 'Supplemental internal check failed.']
      else
        numeric = validate(reference, output, row.fetch('benchmark'))
        numeric.first && definition['comparison'] == 'integer_hash' ? LocalEvaluation::ComparisonPolicy.integer_hashes(reference, output) : numeric
      end
      raise 'Result comparison does not reproduce' unless comparison == result.fetch('comparison') && comparison.first == result.fetch('passed')
      true
    end

    def remaining_seconds
      @groups.sum do |group|
        definition = group.fetch('definition')
        pending = group.fetch('rows').count do |row|
          key = result_key(row, definition)
          !@results.key?(key) && !@skips.key?(key) && !@failures.key?(row.fetch('id'))
        end
        key = [definition.fetch('id'), group.fetch('backend')]
        measured = @costs[key]
        pilot = @pilot.fetch('groups').find { |p| [p.fetch('case'), p.fetch('backend')] == key }
        speedup = @scheduling ? @scheduling.fetch('groups').fetch(ConcurrencyPolicy.key(group)).fetch('measured_speedup') : 1.0
        rate = measured && measured.fetch('checks') >= 10 ? measured.fetch('seconds') / measured.fetch('checks') : pilot.fetch('projected_full_seconds') / group.fetch('rows').size / speedup
        pending * rate
      end
    end

    def checkpoint(status, force: false, error: nil)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if !force && @last_checkpoint && now - @last_checkpoint < 60
      @last_checkpoint = now
      remaining = remaining_seconds
      value = { 'status' => status, 'updated_at' => Time.now.utc.iso8601, 'attempt' => @attempt,
        'plan_sha256' => @plan_digest, 'pilot_sha256' => @pilot_digest, 'planned_checks' => @plan.fetch('checks'),
        'completed_checks' => @results.size, 'passed_checks' => @results.values.count { |r| r.fetch('passed') },
        'skipped_checks' => @skips.size, 'accounted_checks' => @results.size + @skips.size,
        'failed_ids' => @failures.keys.sort, 'current' => @current,
        'new_checks_this_attempt' => @new_checks, 'elapsed_seconds_this_attempt' => now - @started,
        'remaining_seconds_projected' => remaining, 'estimated_finish_utc' => (Time.now.utc + remaining).iso8601,
        'benchmark_runs' => 0 }
      value['error'] = error if error
      if @scheduling
        value['scheduling_policy_sha256'] = ValidationAudit.sha(File.join(@evidence, ConcurrencyPolicy::FILE))
        value['max_workers'] = @scheduling.fetch('groups').values.map { |entry| entry.fetch('workers') }.max
      end
      # This is the replaceable operational status, not scientific evidence.
      LocalEvaluation.atomic_write(File.join(@evidence, 'shape-topology-full-state.json'), JSON.pretty_generate(value) + "\n")
      value
    end

    def skip_after_failure(row, definition)
      key = result_key(row, definition)
      basis = @failures.fetch(row.fetch('id'))
      value = { 'id' => row.fetch('id'), 'case_id' => definition.fetch('id'), 'source_commit' => row.fetch('source_commit'),
        'plan_sha256' => @plan_digest, 'reason' => 'This unchanged implementation already failed another check in the same sweep.',
        'failed_result_key' => basis, 'failed_result_sha256' => ValidationAudit.sha(File.join(@evidence, basis, 'result.json')),
        'checked_at' => Time.now.utc.iso8601, 'benchmark_runs' => 0 }
      ValidationAudit.save(File.join(@evidence, 'shape-full-skips', key + '.json'), value)
      @skips[key] = value
    end

    def record_result(row, definition)
      key = result_key(row, definition)
      result = ValidationAudit.read(File.join(@evidence, key, 'result.json'))
      verify_result!(row, definition, result)
      @results[key] = result
      @new_checks += 1
      unless result.fetch('passed')
        @failures[row.fetch('id')] = key
        event = { 'event' => 'new_failure', 'id' => row.fetch('id'), 'case_id' => definition.fetch('id'),
          'source_commit' => row.fetch('source_commit'), 'comparison' => result.fetch('comparison'),
          'result_key' => key, 'result_sha256' => ValidationAudit.sha(File.join(@evidence, key, 'result.json')),
          'checked_at' => result.fetch('checked_at'), 'benchmark_runs' => 0 }
        ValidationAudit.save(File.join(@evidence, 'shape-full-failure-events', row.fetch('id') + '.json'), event)
        puts JSON.generate(event)
        $stdout.flush
        checkpoint('running', force: true)
      end
      result
    end

    def run_group(group)
      definition = group.fetch('definition')
      group_key = [definition.fetch('id'), group.fetch('backend')]
      width = @scheduling ? @scheduling.fetch('groups').fetch(ConcurrencyPolicy.key(group)).fetch('workers') : 1
      pending = group.fetch('rows').reject do |row|
        key = result_key(row, definition)
        @results.key?(key) || @skips.key?(key)
      end
      pending.each_slice(width) do |candidates|
        raise 'STOP guard requested a checkpointed stop' if File.exist?(File.join(@evidence, 'STOP-shape-topology-full'))
        rows = candidates.reject do |row|
          next false unless @failures.key?(row.fetch('id'))
          skip_after_failure(row, definition)
          true
        end
        next if rows.empty?
        @current = { 'case_id' => definition.fetch('id'), 'backend' => group.fetch('backend'),
          'ids' => rows.map { |row| row.fetch('id') }, 'workers' => rows.size }
        @current['id'] = rows.first.fetch('id') if rows.size == 1
        checkpoint('running')
        @wave_sequence = (@wave_sequence || 0) + 1
        wave_name = format('%04d-%06d', @attempt, @wave_sequence)
        wave = { 'attempt' => @attempt, 'case_id' => definition.fetch('id'), 'backend' => group.fetch('backend'),
          'ids' => rows.map { |row| row.fetch('id') }, 'workers' => rows.size, 'started_at' => Time.now.utc.iso8601,
          'scheduling_policy_sha256' => @scheduling && ValidationAudit.sha(File.join(@evidence, ConcurrencyPolicy::FILE)),
          'benchmark_runs' => 0 }
        ValidationAudit.save(File.join(@evidence, 'shape-full-waves', wave_name + '-start.json'), wave)
        reference = reference_for(definition)
        before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        error = nil
        begin
          ParallelBatch.run(rows) { |row, _index| @runner.check(row, definition, reference: reference) }
        rescue Exception => caught
          # ParallelBatch drains every worker. Preserve and classify all complete
          # records even if another worker encountered an infrastructure error.
          error = caught
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - before
        records = rows.filter_map do |row|
          path = File.join(@evidence, result_key(row, definition), 'result.json')
          next unless File.file?(path)
          record_result(row, definition)
        end
        cost = @costs[group_key] ||= { 'checks' => 0, 'seconds' => 0.0 }
        cost['checks'] += records.size
        cost['seconds'] += elapsed
        finish = wave.merge('finished_at' => Time.now.utc.iso8601, 'wall_seconds' => elapsed,
          'result_sha256' => records.to_h { |result| [result.fetch('id'), ValidationAudit.sha(File.join(@evidence, definition.fetch('id'), result.fetch('id'), 'result.json'))] })
        finish['error'] = "#{error.class}: #{error.message}" if error
        ValidationAudit.save(File.join(@evidence, 'shape-full-waves', wave_name + '-finish.json'), finish)
        checkpoint('running')
        raise error if error
        raise 'Validation wave returned without all records' unless records.size == rows.size
        if rows.size > 1 && records.any? { |result| result['execution'] && !result.dig('execution', 'success') }
          ValidationAudit.save(File.join(@evidence, 'CONCURRENCY-REVIEW.json'), finish.merge(
            'reason' => 'A concurrent execution failed. Investigate program failure versus resource contention before resuming.'))
          raise 'Concurrent execution failure requires scheduling review before resuming'
        end
      end
      state = checkpoint('running', force: true)
      puts JSON.generate(event: 'group_complete', case_id: definition.fetch('id'), backend: group.fetch('backend'),
        workers: width, accounted_checks: state.fetch('accounted_checks'), planned_checks: @plan.fetch('checks'), failed: @failures.size,
        remaining_seconds_projected: state.fetch('remaining_seconds_projected'), estimated_finish_utc: state.fetch('estimated_finish_utc'))
      $stdout.flush
    end

    def run
      verify_inputs!
      completion = File.join(@evidence, 'shape-topology-full-completion.json')
      raise 'Full sweep already complete' if File.exist?(completion)
      LocalEvaluation.ensure_disk_space!(@workspace)
      @attempt = Dir[File.join(@evidence, 'shape-full-attempts', '*-start.json')].size + 1
      method_label = "shape-topology-full-attempt-#{@attempt}"
      MethodSnapshot.save(@evidence, method_label)
      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @new_checks = 0
      attempt_path = File.join(@evidence, 'shape-full-attempts', format('%04d-start.json', @attempt))
      attempt = { 'attempt' => @attempt, 'started_at' => Time.now.utc.iso8601, 'plan_sha256' => @plan_digest,
        'approval_sha256' => ValidationAudit.sha(File.join(@evidence, APPROVAL_FILE)),
        'method' => method_label, 'status' => 'running' }
      attempt['scheduling_policy_sha256'] = ValidationAudit.sha(File.join(@evidence, ConcurrencyPolicy::FILE)) if @scheduling
      ValidationAudit.save(attempt_path, attempt)
      checkpoint('starting', force: true)
      puts JSON.generate(event: 'starting', planned_checks: @plan.fetch('checks'), reused_checks: @results.size, known_failed_ids: @failures.keys.sort, benchmark_runs: 0)
      $stdout.flush
      @runner.with_host do
        @groups.each { |group| run_group(group) }
      end
      raise 'Full sweep coverage incomplete' unless @results.size + @skips.size == @plan.fetch('checks')
      @current = nil
      report = checkpoint('complete', force: true)
      report['completed_at'] = Time.now.utc.iso8601
      report['full_scope_accounted_for'] = true
      ValidationAudit.save(completion, report)
      attempt['status'] = 'complete'
      puts JSON.generate(report.merge('event' => 'complete'))
      $stdout.flush
    rescue Exception => error
      if @started && @attempt
        checkpoint('stopped', force: true, error: "#{error.class}: #{error.message}")
        attempt['status'] = 'stopped'
        attempt['error'] = "#{error.class}: #{error.message}"
      end
      raise
    ensure
      if attempt_path && attempt
        attempt['finished_at'] = Time.now.utc.iso8601
        attempt['elapsed_seconds'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started
        ValidationAudit.save(attempt_path.sub(/-start\.json\z/, '-finish.json'), attempt)
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: shape_full.rb WORKSPACE EVIDENCE check|run' unless ARGV.size == 3
  campaign = ValidationAudit::FullShapeCampaign.new(workspace: ARGV[0], evidence: ARGV[1])
  case ARGV[2]
  when 'check'
    campaign.verify_inputs!
    puts 'Frozen scope, approval, references and cached pilot results verified; no executions launched.'
  when 'run' then campaign.run
  else raise 'Use check or run'
  end
end
