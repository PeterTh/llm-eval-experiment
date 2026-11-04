# frozen_string_literal: true
require_relative 'shape_topology'

module ValidationAudit
  module ShapePilotExport
    module_function

    def binding_with_logs(evidence, id)
      binding = ValidationAudit.read(File.join(evidence, 'bindings', "#{id}.json"))
      return binding if binding['reused_cache']
      directory = File.dirname(binding.fetch('executable'))
      binding['build_logs'] = %w[cmake build].product(%w[command stdout stderr exitcode wall_time]).to_h do |stage, suffix|
        name = "#{stage}_#{suffix}.log"
        bytes = File.read(File.join(directory, name))
        text = bytes.bytesize > 16000 ? bytes.byteslice(0, 8000) + "\n[bounded excerpt]\n" + bytes.byteslice(-8000, 8000) : bytes
        [name, { 'text' => text, 'bytes' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes), 'truncated' => bytes.bytesize > 16000 }]
      end
      binding
    end

    def run(evidence:, destination:)
      report = ValidationAudit.read(File.join(evidence, 'shape-topology-refined-pilot.json'))
      plan = ValidationAudit.read(File.join(evidence, 'shape-topology-refined-plan.json'))
      raise 'Refusing to overwrite an export' if File.exist?(destination)
      MethodSnapshot.save(evidence, 'shape-pilot-export')
      archive = []
      references = {}
      plan.fetch('groups').each do |group|
        definitions = [[group.fetch('definition'), false]]
        definitions << [group.fetch('superseded_pilot_definition'), true] if group['superseded_pilot_definition']
        definitions.each do |definition, superseded|
          label, benchmark = definition.values_at('id', 'benchmark')
          reference_directory = File.join(evidence, label, "reference_#{benchmark}")
          reference = File.read(File.join(reference_directory, 'validation_stdout.log'))
          references[label] ||= { 'definition' => definition, 'stdout' => reference,
            'stdout_sha256' => Digest::SHA256.hexdigest(reference),
            'result' => ValidationAudit.read(File.join(reference_directory, 'result.json')),
            'binding' => binding_with_logs(evidence, "reference_#{benchmark}") }
          group.fetch('pilot_ids').each do |id|
            source = group.fetch('rows').find { |row| row.fetch('id') == id }
            raise 'Missing pilot source binding' unless source
            directory = File.join(evidence, label, id)
            path = File.join(directory, 'result.json')
            result = ValidationAudit.read(path)
            raise 'Pilot source/case changed' unless result.fetch('source_commit') == source.fetch('source_commit') && result.fetch('definition') == definition
            logs = %w[command stdout stderr exitcode wall_time].to_h { |suffix| [suffix, File.read(File.join(directory, "validation_#{suffix}.log"))] }
            output = logs.fetch('stdout')
            raise 'Pilot stdout changed' unless Digest::SHA256.hexdigest(output) == result.fetch('output_sha256')
            raise 'Pilot reference changed' unless Digest::SHA256.hexdigest(reference) == result.fetch('reference_sha256')
            comparison = if !result.dig('execution', 'success')
              [false, "Supplemental correctness execution failed: exit #{result.dig('execution', 'exit_code')}, timeout #{result.dig('execution', 'timed_out')}."]
            elsif !result.fetch('internal_validation')
              [false, 'Supplemental internal check failed.']
            else
              numeric = validate(reference, output, benchmark)
              numeric.first && definition['comparison'] == 'integer_hash' ? LocalEvaluation::ComparisonPolicy.integer_hashes(reference, output) : numeric
            end
            raise 'Pilot verdict does not reproduce' unless comparison == result.fetch('comparison') && comparison.first == result.fetch('passed') && result.fetch('performance_measurement') == false
            archive << { 'id' => id, 'source' => source, 'result' => result, 'result_sha256' => ValidationAudit.sha(path),
              'logs' => logs, 'superseded_case' => superseded }
          end
        end
      end
      effective = archive.reject { |r| r.fetch('superseded_case') }
      failures = effective.reject { |r| r.dig('result', 'passed') }.map { |r| r.fetch('id') }.sort
      expected = report.fetch('groups').flat_map { |g| g.fetch('failed_ids') }.sort
      raise 'Pilot coverage or failures differ' unless effective.size == report.fetch('pilot_checks') && failures == expected
      FileUtils.mkdir_p(destination)
      LocalEvaluation.atomic_write(File.join(destination, 'records.jsonl'), archive.map { |r| JSON.generate(r) + "\n" }.join)
      ValidationAudit.save(File.join(destination, 'references.json'), references)
      ValidationAudit.save(File.join(destination, 'pilot.json'), report)
      ValidationAudit.save(File.join(destination, 'preliminary-pilot.json'), ValidationAudit.read(File.join(evidence, 'shape-topology-pilot.json')))
      compact = plan.merge('groups' => plan.fetch('groups').map do |group|
        group.merge('ids' => group.fetch('rows').map { |row| row.fetch('id') }).reject { |key, _| key == 'rows' }
      end)
      inventories = Dir[File.join(evidence, 'inventory-*.json')].to_h do |path|
        original = ValidationAudit.read(path)
        [original.fetch('benchmark'), original.reject { |key, _| key == 'rows' }.merge('sha256' => ValidationAudit.sha(path))]
      end
      compact['source_inventories'] = inventories
      ValidationAudit.save(File.join(destination, 'plan.json'), compact)
      bindings = archive.map { |r| r.fetch('id') }.uniq.to_h do |id|
        [id, binding_with_logs(evidence, id)]
      end
      ValidationAudit.save(File.join(destination, 'build-bindings.json'), bindings)
      FileUtils.cp(File.join(evidence, 'shape-static-findings.json'), File.join(destination, 'static-findings.json'))
      %w[shape-topology-pilot shape-topology-refined-pilot shape-pilot-export].each do |label|
        FileUtils.mkdir_p(File.join(destination, 'method'))
        FileUtils.cp_r(File.join(evidence, 'method', label), File.join(destination, 'method', label))
      end
      files = Dir[File.join(destination, '**/*')].select { |p| File.file?(p) }
      receipt = { 'schema_version' => 1, 'scope' => 'pilot_only_full_sweep_requires_user_approval',
        'effective_checks' => effective.size, 'superseded_case_checks' => archive.size - effective.size,
        'failed_ids' => failures, 'benchmark_runs' => 0,
        'estimated_full_seconds_conservative' => report.fetch('estimated_full_seconds_conservative'),
        'files_sha256' => files.sort.to_h { |p| [p.delete_prefix(destination + '/'), ValidationAudit.sha(p)] },
        'retained_bytes' => files.sum { |p| File.size(p) } }
      ValidationAudit.save(File.join(destination, 'export.json'), receipt)
      puts JSON.pretty_generate(receipt.reject { |k, _| k == 'files_sha256' })
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: export_shape_pilot.rb EVIDENCE NEW_DESTINATION' unless ARGV.size == 2
  ValidationAudit::ShapePilotExport.run(evidence: ARGV[0], destination: ARGV[1])
end
