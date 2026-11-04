# frozen_string_literal: true
require_relative 'full_array_capture'
require_relative 'full_array_reconcile'

module ValidationAudit
  class FullArrayFull
    PHASE = 'full-array-full'
    AUTHORIZATION = 'full-array-full-authorization.json'
    attr_reader :plan

    def initialize(workspace:, evidence:)
      @workspace, @evidence = File.realpath(workspace), File.realpath(evidence)
      @root = File.join(@evidence, PHASE)
      @pilot_root = File.join(@evidence, 'full-array-pilot-01')
      @runner = Runner.new(workspace: @workspace, evidence: @evidence)
      @pilot = ValidationAudit.read(File.join(@pilot_root, 'plan.json'))
      @pilot_completion = ValidationAudit.read(File.join(@pilot_root, 'completion.json'))
      @compatibility_root = File.join(@evidence, 'full-array-compatibility-01')
      @rows = @pilot.fetch('inventory_sha256').flat_map do |benchmark, digest|
        path = File.join(@evidence, "inventory-#{benchmark}.json")
        raise 'Frozen inventory changed' unless ValidationAudit.sha(path) == digest
        ValidationAudit.read(path).fetch('rows')
      end.to_h { |row| [row.fetch('id'), row] }
      @results, @references, @costs = {}, {}, {}
    end

    def self.check_authorization!(approval, pilot_digest, completion_digest, population)
      raise 'Full-array authorization differs from the approved scope' unless
        approval.fetch('source') == 'user' && approval.fetch('approved') == true &&
        approval.fetch('scope') == 'full-array-correctness-sweep' &&
        approval.fetch('pilot_plan_sha256') == pilot_digest &&
        approval.fetch('pilot_completion_sha256') == completion_digest &&
        approval.fetch('population') == population && approval.fetch('benchmark_runs') == 0 &&
        approval.fetch('llm_invocations') == 0 && !approval.fetch('statement').strip.empty?
    end

    def authorize
      approval = { 'source' => 'user', 'approved' => true, 'scope' => 'full-array-correctness-sweep',
        'statement' => 'Go ahead. Explicit approval after clarification that the projected 6.3 hours (9.6 conservatively) is local CPU/GPU correctness execution, not LLM invocations.',
        'approved_at' => Time.now.utc.iso8601, 'population' => @pilot.fetch('population'),
        'pilot_plan_sha256' => ValidationAudit.sha(File.join(@pilot_root, 'plan.json')),
        'pilot_completion_sha256' => ValidationAudit.sha(File.join(@pilot_root, 'completion.json')),
        'benchmark_runs' => 0, 'program_source_changes' => 0, 'llm_invocations' => 0 }
      ValidationAudit.save(File.join(@evidence, AUTHORIZATION), approval)
      puts JSON.pretty_generate(approval)
    end

    def method_files
      root = File.expand_path('../..', __dir__)
      names = %w[tools/validation_audit/full_array_full.rb tools/validation_audit/full_array_capture.rb
        tools/validation_audit/full_array_observer.py tools/validation_audit/full_array_rank.rb
        tools/validation_audit/full_array_adapters.rb tools/validation_audit/full_array_reconcile.rb
        tools/validation_audit/runner.rb tools/validation_audit/inventory.rb
        lib/local_evaluation.rb validation_helper.rb local_gpu_rank_wrapper.rb]
      names += Dir[File.join(root, 'lib/local_evaluation/**/*.rb')].map { |p| p.delete_prefix(root + '/') }
      names.uniq.sort.to_h { |name| [name, ValidationAudit.sha(File.join(root, name))] }
    end

    def prepare
      raise 'Pilot incomplete' unless @pilot_completion.fetch('status') == 'pilot_complete'
      compatibility = ValidationAudit.read(File.join(@compatibility_root, 'completion.json'))
      raise 'Compatibility preflight incomplete' unless compatibility.fetch('status') == 'complete' && compatibility.fetch('failed_ids').empty?
      approval_path = File.join(@evidence, AUTHORIZATION)
      self.class.check_authorization!(ValidationAudit.read(approval_path), ValidationAudit.sha(File.join(@pilot_root, 'plan.json')),
        ValidationAudit.sha(File.join(@pilot_root, 'completion.json')), @pilot.fetch('population'))
      raise 'Release changed before full sweep' unless @pilot.fetch('release_csv_sha256') == ValidationAudit.sha(File.join(RELEASE, 'release/scored_results.csv')) &&
        @pilot.fetch('catalog_sha256') == ValidationAudit.sha(File.join(RELEASE, 'release/catalog.json'))
      ids = @pilot.fetch('groups').flat_map { |g| g.fetch('full_ids') }
      raise 'Invalid population' unless ids.size == @pilot.fetch('population') && ids.uniq.size == ids.size
      reused = ids.filter_map do |id|
        directory = [@pilot_root, @compatibility_root].map { |r| File.join(r, id) }
          .find { |d| File.file?(File.join(d, 'comparison.json')) }
        next unless directory
        verify_saved(directory, @rows.fetch(id))
        [id, { 'directory' => directory.delete_prefix(@evidence + '/'),
          'comparison_sha256' => ValidationAudit.sha(File.join(directory, 'comparison.json')),
          'observation_sha256' => ValidationAudit.sha(File.join(directory, 'observation.json')) }]
      end.to_h
      expected = { 'schema_version' => 1, 'scope' => 'All 6747 eligible floating-result implementations at the frozen release, including later benchmark failures; Floyd integer output already covered.',
        'population' => ids.size, 'groups' => @pilot.fetch('groups').map { |g| g.reject { |k, _| k == 'pilot_rows' } },
        'reused' => reused, 'new_checks' => ids.size - reused.size,
        'pilot_plan_sha256' => ValidationAudit.sha(File.join(@pilot_root, 'plan.json')),
        'pilot_completion_sha256' => ValidationAudit.sha(File.join(@pilot_root, 'completion.json')),
        'compatibility_completion_sha256' => ValidationAudit.sha(File.join(@compatibility_root, 'completion.json')),
        'authorization_sha256' => ValidationAudit.sha(approval_path), 'method_sha256' => method_files,
        'scheduling' => 'One correctness execution at a time using the observer pilot allocation; no untested debugger concurrency.',
        'benchmark_runs' => 0, 'program_source_changes' => 0, 'llm_invocations' => 0 }
      path = File.join(@root, 'plan.json')
      if File.exist?(path)
        raise 'Frozen full-array plan/method changed' unless ValidationAudit.read(path) == expected
      else
        ValidationAudit.save(path, expected)
        method_root = File.expand_path('../..', __dir__)
        expected.fetch('method_sha256').each do |relative, digest|
          bytes = File.binread(File.join(method_root, relative))
          raise 'Method changed while retaining it' unless Digest::SHA256.hexdigest(bytes) == digest
          destination = File.join(@root, 'method', relative)
          FileUtils.mkdir_p(File.dirname(destination))
          File.open(destination, File::WRONLY | File::CREAT | File::EXCL) { |f| f.write(bytes) }
        end
      end
      @plan = expected
      reused.each_key do |id|
        @results[id] = ValidationAudit.read(File.join(@evidence, reused.fetch(id).fetch('directory'), 'comparison.json'))
      end
      ids.each do |id|
        directory = File.join(@root, id)
        next unless File.exist?(File.join(directory, 'comparison.json'))
        raise 'Duplicate new and reused result' if @results.key?(id)
        @results[id] = verify_saved(directory, @rows.fetch(id))
      end
      @plan
    end

    def reference_for(benchmark)
      @references[benchmark] ||= begin
        path = File.join(@pilot_root, 'reference_' + benchmark, 'observation.json')
        observation = ValidationAudit.read(path)
        raise 'Incomplete sequential reference' unless observation.fetch('observation_complete')
        stdout = File.read(File.join(File.dirname(path), 'validation_stdout.log'))
        binding_path = File.join(@evidence, 'bindings', 'reference_' + benchmark + '.json')
        raise 'Sequential reference binding changed' unless ValidationAudit.sha(binding_path) == observation.fetch('binding_sha256') &&
          Digest::SHA256.hexdigest(stdout) == observation.fetch('stdout_sha256')
        [observation, stdout, path]
      end
    end

    def normalized_observation(observation, stdout)
      duplicated = observation.fetch('objects').group_by { |o| o.fetch('name') }.values.any? { |v| v.size > 1 }
      return [observation, nil] if observation.fetch('observation_complete') && !duplicated
      selected = FullArrayReconcile.select_identical_replicas(observation, stdout)
      reconciliation = { 'reason' => 'All repeated/suppressed result replicas are byte-identical. Numerical comparison uses one representative per printed name; the benchmark output contract is unchanged.',
        'selected_objects' => selected, 'captured_objects' => observation.fetch('objects').size }
      [observation.merge('objects' => selected, 'errors' => [], 'observation_complete' => true), reconciliation]
    end

    def verify_saved(directory, row)
      observation_path = File.join(directory, 'observation.json')
      comparison = ValidationAudit.read(File.join(directory, 'comparison.json'))
      raise 'Saved source/observation changed' unless comparison.fetch('source') == row &&
        comparison.fetch('observation_sha256') == ValidationAudit.sha(observation_path)
      observation = ValidationAudit.read(observation_path)
      group = @pilot.fetch('groups').find { |g| g.fetch('full_ids').include?(row.fetch('id')) }
      raise 'Saved workload changed' unless observation.fetch('args') == group.fetch('args') &&
        observation.fetch('id') == row.fetch('id') && observation.fetch('backend') == row.fetch('backend')
      stdout = File.read(File.join(directory, 'validation_stdout.log'))
      raise 'Saved stdout changed' unless Digest::SHA256.hexdigest(stdout) == observation.fetch('stdout_sha256')
      binding_path = File.join(@evidence, 'bindings', row.fetch('id') + '.json')
      binding = ValidationAudit.read(binding_path)
      raise 'Saved binary/source binding differs' unless binding.fetch('source_files') == row.fetch('source_files') &&
        binding.fetch('binary_sha256') == observation.fetch('binary_sha256') &&
        ValidationAudit.sha(binding_path) == observation.fetch('binding_sha256')
      if comparison['observation_reconciliation_sha256']
        raise 'Reconciliation changed' unless comparison.fetch('observation_reconciliation_sha256') == ValidationAudit.sha(File.join(directory, 'capture-reconciliation.json'))
      end
      normalized, = normalized_observation(observation, stdout)
      reference, reference_stdout, = reference_for(row.fetch('benchmark'))
      replay = FullArrayCapture.compare(reference, normalized)
      sparse = validate(reference_stdout, stdout, row.fetch('benchmark'))
      raise 'Saved numerical verdict does not reproduce' unless replay.fetch('arrays') == comparison.fetch('arrays') &&
        sparse == comparison.fetch('sparse_comparison') && comparison.fetch('passed') == (replay.fetch('passed') && sparse.first)
      comparison
    end

    def check(row, group)
      id = row.fetch('id')
      binding = ValidationAudit.read(File.join(@evidence, 'bindings', id + '.json'))
      raise 'Executable source binding differs' unless binding.fetch('source_files') == row.fetch('source_files')
      directory = File.join(@root, id)
      path = File.join(directory, 'observation.json')
      observation = if File.exist?(path)
        ValidationAudit.read(path)
      else
        FullArrayCapture.capture(workspace: @workspace, evidence: @evidence, id: id, benchmark: row.fetch('benchmark'),
          backend: row.fetch('backend'), args: group.fetch('args'), phase: PHASE)
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout = File.read(File.join(directory, 'validation_stdout.log'))
      raise 'Observation binding or workload changed' unless observation.fetch('id') == id &&
        observation.fetch('backend') == row.fetch('backend') && observation.fetch('args') == group.fetch('args') &&
        observation.fetch('binary_sha256') == binding.fetch('binary_sha256') &&
        observation.fetch('binding_sha256') == ValidationAudit.sha(File.join(@evidence, 'bindings', id + '.json')) &&
        observation.fetch('stdout_sha256') == Digest::SHA256.hexdigest(stdout)
      normalized, reconciliation = normalized_observation(observation, stdout)
      reference, reference_stdout, reference_path = reference_for(row.fetch('benchmark'))
      comparison = FullArrayCapture.compare(reference, normalized)
      sparse = validate(reference_stdout, stdout, row.fetch('benchmark'))
      comparison.merge!('source' => row, 'observation_sha256' => ValidationAudit.sha(path),
        'reference_observation_sha256' => ValidationAudit.sha(reference_path), 'sparse_comparison' => sparse,
        'total_check_seconds' => observation.fetch('total_seconds') + Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      if reconciliation
        review_path = File.join(directory, 'capture-reconciliation.json')
        reconciliation.merge!('id' => id, 'original_observation_sha256' => ValidationAudit.sha(path),
          'method_sha256' => ValidationAudit.sha(__FILE__), 'program_runs' => 0, 'benchmark_runs' => 0)
        if File.exist?(review_path)
          raise 'Saved reconciliation differs' unless ValidationAudit.read(review_path) == reconciliation
        else
          ValidationAudit.save(review_path, reconciliation)
        end
        comparison['observation_reconciliation_sha256'] = ValidationAudit.sha(review_path)
      end
      comparison['passed'] &&= sparse.first
      ValidationAudit.save(File.join(directory, 'comparison.json'), comparison)
      comparison
    end

    def checkpoint(status, error: nil)
      pending_seconds = @pilot.fetch('groups').sum do |group|
        key = [group.fetch('benchmark'), group.fetch('backend')]
        measured = @costs[key]
        pilot = @pilot_completion.fetch('groups').find { |g| [g.fetch('benchmark'), g.fetch('backend')] == key }
        seconds = measured && measured.fetch('checks') >= 10 ? measured.fetch('seconds') / measured.fetch('checks') :
          pilot.fetch('projected_seconds') / pilot.fetch('full_count')
        group.fetch('full_ids').count { |id| !@results.key?(id) } * seconds
      end
      state = { 'status' => status, 'updated_at' => Time.now.utc.iso8601, 'attempt' => @attempt,
        'population' => @plan.fetch('population'), 'completed_checks' => @results.size,
        'passed_checks' => @results.values.count { |r| r.fetch('passed') },
        'failed_ids' => @results.values.reject { |r| r.fetch('passed') }.map { |r| r.fetch('id') }.sort,
        'current' => @current, 'reused_checks' => @plan.fetch('reused').size, 'new_checks_this_attempt' => @new_checks,
        'remaining_seconds_projected' => pending_seconds, 'estimated_finish_utc' => (Time.now.utc + pending_seconds).iso8601,
        'plan_sha256' => ValidationAudit.sha(File.join(@root, 'plan.json')), 'benchmark_runs' => 0, 'llm_invocations' => 0 }
      state['error'] = error if error
      LocalEvaluation.atomic_write(File.join(@root, 'state.json'), JSON.pretty_generate(state) + "\n")
      @last_checkpoint = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      state
    end

    def run
      prepare
      raise 'Sweep already complete' if File.exist?(File.join(@root, 'completion.json'))
      LocalEvaluation.ensure_disk_space!(@workspace)
      @attempt = Dir[File.join(@root, 'attempts', '*-start.json')].size + 1
      @new_checks = 0
      attempt = { 'attempt' => @attempt, 'started_at' => Time.now.utc.iso8601, 'status' => 'running',
        'plan_sha256' => ValidationAudit.sha(File.join(@root, 'plan.json')), 'authorization_sha256' => @plan.fetch('authorization_sha256') }
      attempt_path = File.join(@root, 'attempts', format('%04d-start.json', @attempt))
      ValidationAudit.save(attempt_path, attempt)
      puts JSON.generate(checkpoint('starting').merge('event' => 'starting'))
      @runner.with_host do
        @plan.fetch('groups').each do |group|
          group.fetch('full_ids').each do |id|
            next if @results.key?(id)
            raise 'STOP guard requested a checkpointed stop' if File.exist?(File.join(@evidence, 'STOP-full-array-full'))
            @current = id
            checkpoint('running') if Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_checkpoint >= 60
            before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result = check(@rows.fetch(id), group)
            @results[id] = result
            @new_checks += 1
            cost = (@costs[[group.fetch('benchmark'), group.fetch('backend')]] ||= { 'checks' => 0, 'seconds' => 0.0 })
            cost['checks'] += 1
            cost['seconds'] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - before
            unless result.fetch('passed')
              event = { 'id' => id, 'checked_at' => Time.now.utc.iso8601, 'comparison' => result.fetch('arrays'),
                'comparison_sha256' => ValidationAudit.sha(File.join(@root, id, 'comparison.json')), 'benchmark_runs' => 0 }
              ValidationAudit.save(File.join(@root, 'failure-events', id + '.json'), event)
              puts JSON.generate(event.merge('event' => 'new_failure'))
              checkpoint('running')
            end
            $stdout.flush
          end
          puts JSON.generate(checkpoint('running').merge('event' => 'group_complete'))
          $stdout.flush
        end
      end
      raise 'Full sweep coverage incomplete' unless @results.size == @plan.fetch('population')
      @current = nil
      report = checkpoint('complete').merge('completed_at' => Time.now.utc.iso8601, 'full_scope_accounted_for' => true)
      ValidationAudit.save(File.join(@root, 'completion.json'), report)
      attempt['status'] = 'complete'
      puts JSON.generate(report)
    rescue Exception => error
      if attempt
        attempt['status'] = 'stopped'
        attempt['error'] = "#{error.class}: #{error.message}"
        checkpoint('stopped', error: attempt.fetch('error'))
      end
      raise
    ensure
      if attempt
        attempt['finished_at'] = Time.now.utc.iso8601
        ValidationAudit.save(attempt_path.sub(/-start\.json\z/, '-finish.json'), attempt)
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: full_array_full.rb WORKSPACE EVIDENCE authorize|prepare|run' unless ARGV.size == 3
  campaign = ValidationAudit::FullArrayFull.new(workspace: ARGV[0], evidence: ARGV[1])
  case ARGV[2]
  when 'authorize' then campaign.authorize
  when 'prepare'
    plan = campaign.prepare
    puts JSON.pretty_generate(plan.slice('population', 'new_checks', 'scheduling', 'benchmark_runs', 'llm_invocations').merge('reused_checks' => plan.fetch('reused').size))
  when 'run' then campaign.run
  else raise 'Use authorize, prepare or run'
  end
end
