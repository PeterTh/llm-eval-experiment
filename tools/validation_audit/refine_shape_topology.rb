# frozen_string_literal: true
require_relative 'shape_topology'

module ValidationAudit
  class RefinedShapePilot < ShapeTopologyCampaign
    def run
      original_path = File.join(@evidence, 'shape-topology-pilot.json')
      original = ValidationAudit.read(original_path)
      original_plan_path = File.join(@evidence, 'shape-topology-plan.json')
      plan = ValidationAudit.read(original_plan_path)
      destination = File.join(@evidence, 'shape-topology-refined-pilot.json')
      raise 'Refined pilot already complete' if File.exist?(destination)
      MethodSnapshot.save(@evidence, 'shape-topology-refined-pilot')
      changed = plan.fetch('groups').select do |group|
        group.fetch('backend') == 'mpi' && %w[cahn-hilliard stencil3d].include?(group.dig('definition', 'benchmark'))
      end
      raise 'Unexpected refinement scope' unless changed.size == 2
      changed.each do |group|
        expected = self.class.definition(group.dig('definition', 'benchmark'), 'mpi')
        raise 'Refinement needs a new case identity' if group.fetch('definition').fetch('id') == expected.fetch('id')
        group['superseded_pilot_definition'] = group.fetch('definition')
        group['definition'] = expected
      end
      summaries = Marshal.load(Marshal.dump(original.fetch('groups')))
      refinements = []
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @runner.with_host do
        changed.each do |group|
          definition = group.fetch('definition')
          benchmark = definition.fetch('benchmark')
          reference_row = ValidationAudit.bind_source({ 'id' => "reference_#{benchmark}", 'benchmark' => benchmark,
            'backend' => 'sequential', 'source_path' => '', 'source_commit' => INPUT_COMMIT }, repository: INPUT)
          reference_result = @runner.check(reference_row, definition)
          raise 'Refined sequential reference failed' unless reference_result.fetch('passed')
          reference = File.read(File.join(@evidence, definition.fetch('id'), reference_row.fetch('id'), 'validation_stdout.log'))
          rows = group.fetch('rows').select { |row| group.fetch('pilot_ids').include?(row.fetch('id')) }
          before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          results = rows.map { |row| @runner.check(row, definition, reference: reference) }
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - before
          old = summaries.find { |s| s.fetch('case') == group.dig('superseded_pilot_definition', 'id') && s.fetch('backend') == 'mpi' }
          raise 'Missing original pilot group' unless old
          projected_sample_cost = [elapsed, old.fetch('pilot_seconds')].max
          replacement = old.merge('case' => definition.fetch('id'), 'pilot_seconds' => projected_sample_cost,
            'refined_execution_seconds' => elapsed, 'superseded_pilot_case' => old.fetch('case'),
            'projected_full_seconds' => projected_sample_cost / rows.size * group.fetch('rows').size,
            'passed' => results.count { |r| r.fetch('passed') },
            'failed_ids' => results.reject { |r| r.fetch('passed') }.map { |r| r.fetch('id') })
          summaries[summaries.index(old)] = replacement
          refinements << replacement
          puts JSON.generate(replacement)
          $stdout.flush
        end
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      original_setup = original.fetch('pilot_seconds') - original.fetch('groups').sum { |g| g.fetch('pilot_seconds') }
      refined_setup = elapsed - refinements.sum { |g| g.fetch('refined_execution_seconds') }
      projected = summaries.sum { |g| g.fetch('projected_full_seconds') }
      estimate = projected * 1.5 + original_setup + refined_setup + plan.fetch('source_binding_seconds') + 600
      report = original.merge('groups' => summaries, 'projected_full_seconds' => projected,
        'estimated_full_seconds_conservative' => estimate, 'under_five_hours' => estimate < 18000,
        'original_pilot_sha256' => ValidationAudit.sha(original_path), 'original_plan_sha256' => ValidationAudit.sha(original_plan_path),
        'refinement_seconds' => elapsed, 'refined_checks' => 4,
        'refinement' => 'MPI Cahn and stencil use 129x131x257 so each axis exceeds 128 ranks. Only the four affected pilot observations are repeated; all other measured pilot costs/results are retained. Projection uses the larger original/refined sample cost to avoid dropping already incurred preparation cost.',
        'estimate_basis' => original.fetch('estimate_basis') + ' Refined MPI grids retain the larger original/refined per-stratum pilot cost, plus reference/setup cost.')
      plan['refinement'] = report.fetch('refinement')
      ValidationAudit.save(File.join(@evidence, 'shape-topology-refined-plan.json'), plan)
      ValidationAudit.save(destination, report)
      puts JSON.pretty_generate(report.reject { |k, _| k == 'groups' })
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: refine_shape_topology.rb WORKSPACE EVIDENCE' unless ARGV.size == 2
  ValidationAudit::RefinedShapePilot.new(workspace: ARGV[0], evidence: ARGV[1]).run
end
