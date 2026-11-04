# frozen_string_literal: true
require_relative 'shape_topology'

module ValidationAudit
  module ConcurrencyPolicy
    FILE = 'shape-concurrency-policy.json'
    APPROVAL = 'shape-concurrency-authorization.json'
    PILOT = 'shape-concurrency-pilot'
    module_function

    def key(group) = "#{group.dig('definition', 'id')}/#{group.fetch('backend')}"

    def eligible?(group)
      %w[mpi omp].include?(group.fetch('backend')) &&
        group.fetch('definition') == ShapeTopologyCampaign.definition(group.dig('definition', 'benchmark'), group.fetch('backend'))
    end

    def choose(reports, timeout: 30)
      baseline = reports.fetch(1).fetch('seconds_per_check')
      raise 'Invalid serial pilot cost' unless baseline.positive?
      choices = reports.select do |width, report|
        width == 1 || (report.fetch('all_passed') && report.fetch('resources_ok') &&
          report.fetch('records').all? { |record| record.dig('execution', 'wall_seconds') < timeout * 0.75 } &&
          baseline / report.fetch('seconds_per_check') >= 1.05)
      end
      best_rate = choices.values.map { |report| report.fetch('seconds_per_check') }.min
      width = choices.keys.sort.find { |candidate| choices.fetch(candidate).fetch('seconds_per_check') <= best_rate / 0.9 }
      rate = choices.fetch(width).fetch('seconds_per_check')
      { 'workers' => width, 'measured_speedup' => baseline / rate,
        'baseline_seconds_per_check' => baseline, 'pilot_seconds_per_check' => rate }
    end

    def build(evidence, plan)
      approval_path = File.join(evidence, APPROVAL)
      approval = ValidationAudit.read(approval_path)
      full_plan_digest = ValidationAudit.sha(File.join(evidence, 'shape-topology-refined-plan.json'))
      unless approval.fetch('source') == 'user' && approval.fetch('approved') && approval.fetch('max_workers') == 4 &&
          approval.fetch('plan_sha256') == full_plan_digest && approval.fetch('benchmark_runs') == 0
        raise 'Concurrency approval differs from frozen scope'
      end
      root = File.join(evidence, PILOT)
      completion_path = File.join(root, 'completion.json')
      completion = ValidationAudit.read(completion_path)
      pilot_path = File.join(root, 'plan.json')
      pilot = ValidationAudit.read(pilot_path)
      unless completion.fetch('plan_sha256') == ValidationAudit.sha(pilot_path) && pilot.fetch('plan_sha256') == full_plan_digest &&
          pilot.fetch('authorization_sha256') == ValidationAudit.sha(approval_path) && completion.fetch('benchmark_runs') == 0
        raise 'Concurrency pilot scope changed'
      end
      stages = completion.fetch('stages').to_h do |summary|
        width = summary.fetch('workers')
        raise 'Unexpected concurrency stage' unless [1, 2, 4].include?(width)
        path = File.join(root, "stage-w#{width}.json")
        stage = ValidationAudit.read(path)
        raise 'Pilot completion differs from stage' unless stage.reject { |k, _| k == 'groups' } == summary
        [width, stage]
      end
      raise 'No clean serial control and two-worker pilot' unless stages.fetch(1).fetch('clean') && stages.key?(2)
      clean = stages.select { |_width, stage| stage.fetch('clean') }
      expected = plan.fetch('groups').select { |group| eligible?(group) }.map { |group| key(group) }.sort
      clean.each do |width, stage|
        actual = stage.fetch('groups').map { |r| "#{r.fetch('case_id')}/#{r.fetch('backend')}" }
        raise 'Incomplete concurrency pilot coverage' unless actual.sort == expected
        stage.fetch('groups').each do |report|
          raise 'Pilot wave count or verdict differs' unless report.fetch('workers') == width && report.fetch('checks') == width &&
            report.fetch('records').size == width && report.fetch('all_passed') && report.fetch('resources_ok')
          definition = plan.fetch('groups').find { |g| key(g) == "#{report.fetch('case_id')}/#{report.fetch('backend')}" }.fetch('definition')
          original = pilot.fetch('groups').find { |g| key(g) == "#{report.fetch('case_id')}/#{report.fetch('backend')}" }.fetch('row')
          report.fetch('records').each do |record|
            relative = record.fetch('result_path')
            raise 'Unsafe pilot result path' unless relative.start_with?(PILOT + '/') && !relative.split('/').include?('..')
            path = File.join(evidence, relative)
            result = ValidationAudit.read(path)
            unless ValidationAudit.sha(path) == record.fetch('result_sha256') && result.fetch('passed') &&
                result.fetch('performance_measurement') == false && result.fetch('definition') == definition &&
                result.fetch('execution') == record.fetch('execution') &&
                %w[id source_commit source_path].all? { |field| result.fetch(field) == original.fetch(field) }
              raise 'Concurrency pilot execution changed'
            end
            stdout = File.read(File.join(File.dirname(path), 'validation_stdout.log'))
            reference = File.read(File.join(evidence, definition.fetch('id'), "reference_#{definition.fetch('benchmark')}", 'validation_stdout.log'))
            comparison = validate(reference, stdout, definition.fetch('benchmark'))
            comparison = LocalEvaluation::ComparisonPolicy.integer_hashes(reference, stdout) if comparison.first && definition['comparison'] == 'integer_hash'
            unless result.dig('execution', 'success') && result.fetch('internal_validation') &&
                comparison == result.fetch('comparison') && comparison.first &&
                result.fetch('output_sha256') == Digest::SHA256.hexdigest(stdout) &&
                result.fetch('reference_sha256') == Digest::SHA256.hexdigest(reference)
              raise 'Concurrency pilot comparison does not reproduce'
            end
          end
        end
      end
      backend_costs = clean.transform_values do |stage|
        stage.fetch('groups').group_by { |report| report.fetch('backend') }.transform_values do |reports|
          reports.sum do |report|
            group = plan.fetch('groups').find { |g| key(g) == "#{report.fetch('case_id')}/#{report.fetch('backend')}" }
            report.fetch('seconds_per_check') * group.fetch('rows').size
          end
        end
      end
      backend_speedups = backend_costs.to_h do |width, costs|
        [width.to_s, costs.to_h { |backend, cost| [backend, backend_costs.fetch(1).fetch(backend) / cost] }]
      end
      selections = plan.fetch('groups').to_h do |group|
        selection = if eligible?(group)
          supported = clean.select { |width, _stage| width == 1 || backend_speedups.fetch(width.to_s).fetch(group.fetch('backend')) >= 1.10 }
          reports = supported.transform_values do |stage|
            stage.fetch('groups').find { |r| "#{r.fetch('case_id')}/#{r.fetch('backend')}" == key(group) }
          end
          choose(reports, timeout: group.fetch('definition').fetch('timeout'))
        else
          { 'workers' => 1, 'measured_speedup' => 1.0, 'reason' => 'GPU/hybrid or large-memory case remains exclusive.' }
        end
        [key(group), selection]
      end
      { 'schema_version' => 1, 'plan_sha256' => full_plan_digest, 'authorization_sha256' => ValidationAudit.sha(approval_path),
        'pilot_completion_sha256' => ValidationAudit.sha(completion_path),
        'pilot_stage_sha256' => stages.keys.to_h { |width| ["stage-w#{width}.json", ValidationAudit.sha(File.join(root, "stage-w#{width}.json"))] },
        'backend_speedups' => backend_speedups,
        'selection_rule' => 'Clean complete pilot stages only; at least 10% projected throughput gain over the whole backend and 5% within the stratum; per-job wall time below 75% of unchanged timeout; prefer fewer workers within 10% of best measured throughput.',
        'groups' => selections, 'benchmark_runs' => 0 }
    end

    def load(evidence, plan)
      path = File.join(evidence, FILE)
      return nil unless File.file?(path)
      policy = ValidationAudit.read(path)
      raise 'Concurrency scheduling policy does not reproduce' unless policy == build(evidence, plan)
      policy
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: concurrency_policy.rb EVIDENCE' unless ARGV.size == 1
  evidence = ARGV.first
  policy = ValidationAudit::ConcurrencyPolicy.build(evidence, ValidationAudit.read(File.join(evidence, 'shape-topology-refined-plan.json')))
  ValidationAudit.save(File.join(evidence, ValidationAudit::ConcurrencyPolicy::FILE), policy)
  puts JSON.pretty_generate(policy)
end
