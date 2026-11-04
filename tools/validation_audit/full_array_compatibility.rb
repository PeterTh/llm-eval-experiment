# frozen_string_literal: true
require_relative 'full_array_capture'

module ValidationAudit
  module FullArrayCompatibility
    PHASE = 'full-array-compatibility-01'
    module_function

    def run(workspace, evidence)
      root = File.join(evidence, PHASE)
      old_root = File.join(evidence, 'full-array-pilot-01')
      old_plan = ValidationAudit.read(File.join(old_root, 'plan.json'))
      completion = ValidationAudit.read(File.join(old_root, 'completion.json'))
      raise 'Stratified pilot incomplete' unless completion.fetch('status') == 'pilot_complete'
      coverage_path = File.join(evidence, 'full-array-symbol-coverage-01.json')
      coverage = ValidationAudit.read(coverage_path)
      controls = old_plan.fetch('groups').select { |g| g.fetch('benchmark') == 'stencil3d' }
        .map { |g| g.fetch('pilot_rows').first.fetch('id') }
      ids = (coverage.fetch('unsupported_ids') + controls).uniq.sort
      rows = old_plan.fetch('groups').map { |g| g.fetch('benchmark') }.uniq.flat_map do |benchmark|
        ValidationAudit.read(File.join(evidence, "inventory-#{benchmark}.json")).fetch('rows')
      end.to_h { |r| [r.fetch('id'), r] }
      methods = FullArrayCapture.retain_method(evidence).merge(File.basename(__FILE__) => ValidationAudit.sha(__FILE__))
      plan = { 'ids' => ids, 'canonical_control_ids' => controls, 'pilot_plan_sha256' => ValidationAudit.sha(File.join(old_root, 'plan.json')),
        'coverage_sha256' => ValidationAudit.sha(coverage_path), 'method_sha256' => methods,
        'scope' => 'Thirteen output-layout compatibility cases, four canonical controls and one repeated reference. Validation only.' }
      plan_path = File.join(root, 'plan.json')
      if File.exist?(plan_path)
        raise 'Compatibility plan changed' unless ValidationAudit.read(plan_path) == plan
      else
        ValidationAudit.save(plan_path, plan)
        directory = File.join(evidence, 'full-array-methods', methods.fetch(File.basename(__FILE__)))
        FileUtils.mkdir_p(directory)
        File.open(File.join(directory, File.basename(__FILE__)), File::WRONLY | File::CREAT | File::EXCL) { |f| f.write(File.binread(__FILE__)) }
      end
      raise 'Compatibility pilot complete' if File.exist?(File.join(root, 'completion.json'))
      results = []
      runner = Runner.new(workspace: workspace, evidence: evidence)
      runner.with_host do
        (['reference_stencil3d'] + ids).each do |id|
          benchmark = id == 'reference_stencil3d' ? 'stencil3d' : rows.fetch(id).fetch('benchmark')
          backend = id.start_with?('reference_') ? 'sequential' : rows.fetch(id).fetch('backend')
          group = old_plan.fetch('groups').find { |g| g.fetch('benchmark') == benchmark && (backend == 'sequential' || g.fetch('backend') == backend) }
          args = group.fetch('args')
          if rows[id]
            binding = ValidationAudit.read(File.join(evidence, 'bindings', id + '.json'))
            raise 'Source binding changed' unless binding.fetch('source_files') == rows.fetch(id).fetch('source_files')
          end
          directory = File.join(root, id)
          comparison_path = File.join(directory, 'comparison.json')
          if File.exist?(comparison_path)
            results << ValidationAudit.read(comparison_path)
            next
          end
          reference_path = File.join(old_root, 'reference_' + benchmark, 'observation.json')
          reference = ValidationAudit.read(reference_path)
          observed_path = File.join(directory, 'observation.json')
          observed = if File.exist?(observed_path)
            ValidationAudit.read(observed_path)
          else
            FullArrayCapture.capture(workspace: workspace, evidence: evidence, id: id,
              benchmark: benchmark, backend: backend, args: args, phase: PHASE)
          end
          raise "Incomplete compatibility observation #{id}" unless observed.fetch('observation_complete')
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          comparison = FullArrayCapture.compare(reference, observed)
          sparse = validate(File.read(File.join(File.dirname(reference_path), 'validation_stdout.log')),
            File.read(File.join(directory, 'validation_stdout.log')), benchmark)
          comparison.merge!('source' => rows[id], 'reference_observation_sha256' => ValidationAudit.sha(reference_path),
            'observation_sha256' => ValidationAudit.sha(observed_path), 'sparse_comparison' => sparse,
            'total_check_seconds' => observed.fetch('total_seconds') + Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
          comparison['passed'] &&= sparse.first
          ValidationAudit.save(comparison_path, comparison)
          puts JSON.generate(comparison.slice('id', 'passed').merge('mismatches' => comparison.fetch('arrays').sum { |a| a.fetch('mismatches') }))
          $stdout.flush
          results << comparison
        end
      end
      report = { 'status' => 'complete', 'checks' => results.size, 'failed_ids' => results.reject { |r| r.fetch('passed') }.map { |r| r.fetch('id') },
        'seconds' => results.sum { |r| r.fetch('total_check_seconds') }, 'plan_sha256' => ValidationAudit.sha(plan_path),
        'completed_at' => Time.now.utc.iso8601, 'program_source_changes' => 0, 'executable_file_changes' => 0, 'benchmark_runs' => 0 }
      ValidationAudit.save(File.join(root, 'completion.json'), report)
      puts JSON.pretty_generate(report)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: full_array_compatibility.rb WORKSPACE EVIDENCE' unless ARGV.size == 2
  ValidationAudit::FullArrayCompatibility.run(*ARGV)
end
