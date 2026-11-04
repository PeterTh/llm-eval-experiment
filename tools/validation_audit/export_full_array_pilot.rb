# frozen_string_literal: true
require_relative 'full_array_full'

module ValidationAudit
  module FullArrayPilotExport
    module_function

    def witness(object, destination)
      bytes = File.binread(object.fetch('local_path'))
      raise 'Witness capture changed' unless Digest::SHA256.hexdigest(bytes) == object.fetch('sha256') && bytes.bytesize == object.fetch('bytes')
      raise 'Unexpectedly large pilot witness requires retention review' if bytes.bytesize > 4 * 1024 * 1024
      value = object.slice('dtype', 'elements', 'bytes', 'sha256', 'fnv1a64').merge(
        'encoding' => 'hexadecimal original little-endian scalar bytes', 'values_hex' => bytes.unpack1('H*'))
      path = File.join(destination, 'failure-arrays', object.fetch('sha256') + '.json')
      if File.exist?(path)
        raise 'Conflicting shared witness' unless ValidationAudit.read(path) == value
      else
        ValidationAudit.save(path, value)
      end
      'failure-arrays/' + File.basename(path)
    end

    def run(workspace:, evidence:, destination:)
      raise 'Refusing to overwrite export' if File.exist?(destination)
      pilot_root = File.join(evidence, 'full-array-pilot-01')
      compatibility_root = File.join(evidence, 'full-array-compatibility-01')
      completion = ValidationAudit.read(File.join(pilot_root, 'completion.json'))
      compatibility = ValidationAudit.read(File.join(compatibility_root, 'completion.json'))
      raise 'Incomplete pilots' unless completion.fetch('status') == 'pilot_complete' && compatibility.fetch('status') == 'complete'
      verifier = FullArrayFull.new(workspace: workspace, evidence: evidence)
      plan = ValidationAudit.read(File.join(pilot_root, 'plan.json'))
      rows = plan.fetch('inventory_sha256').flat_map do |benchmark, digest|
        path = File.join(evidence, "inventory-#{benchmark}.json")
        raise 'Source inventory changed' unless ValidationAudit.sha(path) == digest
        ValidationAudit.read(path).fetch('rows')
      end.to_h { |r| [r.fetch('id'), r] }
      records = []
      references = {}
      FileUtils.mkdir_p(destination)
      [pilot_root, compatibility_root].each do |root|
        Dir[File.join(root, '*', 'comparison.json')].sort.each do |path|
          directory = File.dirname(path)
          id = File.basename(directory)
          next if id.start_with?('reference_')
          comparison = verifier.verify_saved(directory, rows.fetch(id))
          observation_path = File.join(directory, 'observation.json')
          observation = ValidationAudit.read(observation_path)
          benchmark = rows.fetch(id).fetch('benchmark')
          reference_path = File.join(pilot_root, 'reference_' + benchmark, 'observation.json')
          reference = ValidationAudit.read(reference_path)
          references[benchmark] ||= { 'observation' => reference, 'observation_sha256' => ValidationAudit.sha(reference_path),
            'stdout' => File.read(File.join(File.dirname(reference_path), 'validation_stdout.log')) }
          stdout = File.read(File.join(directory, 'validation_stdout.log'))
          normalized, = verifier.normalized_observation(observation, stdout)
          evidence_record = { 'id' => id, 'phase' => File.basename(root), 'comparison' => comparison,
            'comparison_sha256' => ValidationAudit.sha(path), 'observation' => observation,
            'logs' => %w[command stdout stderr exitcode wall_time].to_h { |part| [part, File.read(File.join(directory, "validation_#{part}.log"))] } }
          reconciliation = File.join(directory, 'capture-reconciliation.json')
          evidence_record['capture_reconciliation'] = ValidationAudit.read(reconciliation) if File.exist?(reconciliation)
          unless comparison.fetch('passed')
            evidence_record['failure_arrays'] = [reference, normalized].to_h do |record|
              [record.fetch('id'), record.fetch('objects').to_h { |o| [o.fetch('name'), witness(o, destination)] }]
            end
          end
          records << evidence_record
        end
      end
      primary = records.select { |r| r.fetch('phase') == 'full-array-pilot-01' }
      raise 'Pilot export coverage differs' unless primary.size == completion.fetch('pilot_checks') &&
        primary.reject { |r| r.dig('comparison', 'passed') }.map { |r| r.fetch('id') }.sort == completion.fetch('failed_ids').sort
      LocalEvaluation.atomic_write(File.join(destination, 'records.jsonl'), records.map { |r| JSON.generate(r) + "\n" }.join)
      ValidationAudit.save(File.join(destination, 'references.json'), references)
      bindings = (records.map { |r| r.fetch('id') } + references.keys.map { |b| 'reference_' + b }).uniq.sort.to_h do |id|
        [id, ValidationAudit.read(File.join(evidence, 'bindings', id + '.json'))]
      end
      ValidationAudit.save(File.join(destination, 'build-bindings.json'), bindings)
      [pilot_root, compatibility_root].each do |root|
        %w[plan.json completion.json].each do |name|
          ValidationAudit.save(File.join(destination, File.basename(root), name), ValidationAudit.read(File.join(root, name)))
        end
      end
      ValidationAudit.save(File.join(destination, 'symbol-coverage.json'), ValidationAudit.read(File.join(evidence, 'full-array-symbol-coverage-01.json')))
      ValidationAudit.save(File.join(destination, 'authorization.json'), ValidationAudit.read(File.join(evidence, FullArrayFull::AUTHORIZATION)))
      # Keep all prototype attempts, including the before-start hardware-breakpoint
      # error, but never duplicate raw array payloads or executables.
      prototype = Dir[File.join(evidence, 'full-array-feasibility-*', '*', 'observation.json')].sort.map do |path|
        directory = File.dirname(path)
        { 'phase' => File.basename(File.dirname(directory)), 'observation' => ValidationAudit.read(path),
          'observation_sha256' => ValidationAudit.sha(path),
          'logs' => %w[stdout stderr command].to_h { |part| [part, File.read(File.join(directory, "validation_#{part}.log"))] } }
      end
      ValidationAudit.save(File.join(destination, 'prototype-attempts.json'), prototype)
      reference_check = File.join(compatibility_root, 'reference_stencil3d')
      ValidationAudit.save(File.join(destination, 'compatibility-reference.json'),
        %w[observation comparison].to_h { |name| [name, ValidationAudit.read(File.join(reference_check, name + '.json'))] })
      FileUtils.cp_r(File.join(evidence, 'full-array-methods'), File.join(destination, 'observer-methods'))
      FileUtils.cp_r(File.join(evidence, FullArrayFull::PHASE, 'method'), File.join(destination, 'full-sweep-method'))
      FileUtils.cp(__FILE__, File.join(destination, 'export_full_array_pilot.rb'))
      files = Dir[File.join(destination, '**/*')].select { |p| File.file?(p) }.sort
      receipt = { 'schema_version' => 1, 'scope' => 'Completed stratified and observer-compatibility pilots; full sweep separately authorized and running.',
        'pilot_checks' => primary.size, 'compatibility_checks' => compatibility.fetch('checks'),
        'unique_generated_ids' => records.map { |r| r.fetch('id') }.uniq.size,
        'failed_ids' => completion.fetch('failed_ids'), 'benchmark_runs' => 0, 'llm_invocations' => 0,
        'program_source_changes' => 0, 'projected_full_hours' => completion.fetch('projected_full_hours'),
        'conservative_full_hours' => completion.fetch('conservative_full_hours'),
        'retained_bytes' => files.sum { |p| File.size(p) },
        'files_sha256' => files.to_h { |p| [p.delete_prefix(destination + '/'), ValidationAudit.sha(p)] } }
      ValidationAudit.save(File.join(destination, 'export.json'), receipt)
      puts JSON.pretty_generate(receipt.reject { |k, _| k == 'files_sha256' })
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: export_full_array_pilot.rb WORKSPACE EVIDENCE NEW_DESTINATION' unless ARGV.size == 3
  ValidationAudit::FullArrayPilotExport.run(workspace: ARGV[0], evidence: ARGV[1], destination: ARGV[2])
end
