# frozen_string_literal: true
require_relative 'shape_full'
require_relative 'export_shape_pilot'

module ValidationAudit
  module ShapeFullExport
    module_function

    def record(evidence, row, definition, verifier)
      key = verifier.result_key(row, definition)
      path = File.join(evidence, key, 'result.json')
      unless File.file?(path)
        skip_path = File.join(evidence, 'shape-full-skips', key + '.json')
        skip = ValidationAudit.read(skip_path)
        raise 'Skip source differs' unless skip.fetch('id') == row.fetch('id') && skip.fetch('source_commit') == row.fetch('source_commit')
        basis_path = File.join(evidence, skip.fetch('failed_result_key'), 'result.json')
        basis = ValidationAudit.read(basis_path)
        unless basis.fetch('id') == row.fetch('id') && basis.fetch('passed') == false &&
            ValidationAudit.sha(basis_path) == skip.fetch('failed_result_sha256')
          raise 'Skip failure basis differs'
        end
        return { 'id' => row.fetch('id'), 'source' => row, 'skipped' => skip,
          'skipped_sha256' => ValidationAudit.sha(skip_path) }
      end
      result = ValidationAudit.read(path)
      verifier.verify_result!(row, definition, result)
      directory = File.dirname(path)
      logs = %w[command stdout stderr exitcode wall_time].to_h { |suffix| [suffix, File.read(File.join(directory, "validation_#{suffix}.log"))] }
      { 'id' => row.fetch('id'), 'source' => row, 'result' => result, 'result_sha256' => ValidationAudit.sha(path),
        'logs' => logs, 'log_sha256' => logs.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) } }
    end

    def compact_binding(evidence, row, result)
      binding = ShapePilotExport.binding_with_logs(evidence, row.fetch('id'))
      unless binding.fetch('id') == row.fetch('id') && binding.fetch('source_files') == row.fetch('source_files') &&
          binding.fetch('binary_sha256') == result.fetch('binary_sha256')
        raise 'Build source or executable binding differs'
      end
      binding.reject { |key, _| key == 'source_files' }.merge(
        'source_files_sha256' => Digest::SHA256.hexdigest(JSON.generate(row.fetch('source_files'))))
    end

    # Preserve key order so the original approved plan can be reconstructed
    # byte-for-byte from its compact ID lists and the retained source records.
    def compact_plan(plan)
      plan.merge('groups' => plan.fetch('groups').map do |group|
        group.to_h { |key, value| key == 'rows' ? ['row_ids', value.map { |row| row.fetch('id') }] : [key, value] }
      end)
    end

    def expand_plan(plan, records)
      sources = {}
      records.each do |record|
        id, source = record.values_at('id', 'source')
        raise 'Source binding differs across cases' if sources.key?(id) && sources.fetch(id) != source
        sources[id] = source
      end
      plan.merge('groups' => plan.fetch('groups').map do |group|
        group.to_h { |key, value| key == 'row_ids' ? ['rows', value.map { |id| sources.fetch(id) }] : [key, value] }
      end)
    end

    def write_case(evidence:, destination:, definition:, records:, reference:, authorization:)
      raise 'Refusing to overwrite a case export' if File.exist?(destination)
      failed = records.select { |r| r['result'] && !r.dig('result', 'passed') }
      FileUtils.mkdir_p(destination)
      LocalEvaluation.atomic_write(File.join(destination, 'records.jsonl'), records.map { |r| JSON.generate(r) + "\n" }.join)
      ValidationAudit.save(File.join(destination, 'reference.json'), reference)
      bindings = records.select { |r| r['result'] }.map { |r| compact_binding(evidence, r.fetch('source'), r.fetch('result')) }
      ValidationAudit.save(File.join(destination, 'build-bindings.json'), bindings)
      exclusions = failed.map do |row|
        row.fetch('source').slice('id', 'source_commit', 'source_path', 'validation_record').merge(
          'stages' => { 'basic_para' => true, 'validation_build' => true, 'validation_run' => true, 'internal_validation' => true, 'output_comparison' => false },
          'case_id' => definition.fetch('id'), 'result' => row.fetch('result'), 'result_sha256' => row.fetch('result_sha256'),
          'stdout' => row.fetch('logs').fetch('stdout'))
      end
      ValidationAudit.save(File.join(destination, 'exclusions.json'), { 'schema_version' => 2, 'case' => definition,
        'record_count' => exclusions.size, 'failed_stage' => 'output_comparison',
        'authorization' => authorization.slice('source', 'statement'),
        'reference' => reference.slice('stdout', 'stdout_sha256'), 'records' => exclusions })
      files = Dir[File.join(destination, '*')].select { |p| File.file?(p) }
      receipt = { 'schema_version' => 1, 'case' => definition, 'records' => records.size,
        'executed' => records.count { |r| r['result'] }, 'skipped' => records.count { |r| r['skipped'] }, 'failed' => failed.size,
        'registry_sha256' => ValidationAudit.sha(File.join(destination, 'exclusions.json')),
        'files_sha256' => files.sort.to_h { |p| [File.basename(p), ValidationAudit.sha(p)] },
        'retained_bytes' => files.sum { |p| File.size(p) }, 'benchmark_runs' => 0 }
      ValidationAudit.save(File.join(destination, 'export.json'), receipt)
      receipt
    end

    def run(workspace:, evidence:, destination:)
      completion_path = File.join(evidence, 'shape-topology-full-completion.json')
      completion = ValidationAudit.read(completion_path)
      plan_path = File.join(evidence, FullShapeCampaign::PLAN_FILE)
      plan = ValidationAudit.read(plan_path)
      unless completion.fetch('status') == 'complete' && completion.fetch('accounted_checks') == plan.fetch('checks') &&
          completion.fetch('plan_sha256') == ValidationAudit.sha(plan_path) && completion.fetch('benchmark_runs') == 0
        raise 'Full validation sweep is not complete'
      end
      raise 'Refusing to overwrite full export' if File.exist?(destination)
      verifier = FullShapeCampaign.new(workspace: workspace, evidence: evidence)
      verifier.verify_inputs!
      authorization = ValidationAudit.read(File.join(evidence, FullShapeCampaign::APPROVAL_FILE))
      grouped = plan.fetch('groups').group_by { |g| g.dig('definition', 'id') }
      cases = grouped.sort.to_h do |label, groups|
        definition = groups.first.fetch('definition')
        raise 'Case definitions differ across backends' unless groups.all? { |g| g.fetch('definition') == definition }
        rows = groups.flat_map { |g| g.fetch('rows') }.sort_by { |r| r.fetch('id') }
        raise 'Duplicate run in one case' unless rows.map { |r| r.fetch('id') }.uniq.size == rows.size
        records = rows.map { |row| record(evidence, row, definition, verifier) }
        reference_directory = File.join(evidence, label, "reference_#{definition.fetch('benchmark')}")
        output = verifier.reference_for(definition)
        reference = { 'source_commit' => INPUT_COMMIT, 'definition' => definition, 'stdout' => output,
          'stdout_sha256' => Digest::SHA256.hexdigest(output),
          'result' => ValidationAudit.read(File.join(reference_directory, 'result.json')),
          'binding' => ShapePilotExport.binding_with_logs(evidence, "reference_#{definition.fetch('benchmark')}") }
        [label, { 'definition' => definition, 'records' => records, 'reference' => reference }]
      end
      all = cases.values.flat_map { |c| c.fetch('records') }
      failed = all.select { |r| r['result'] && !r.dig('result', 'passed') }
      ids = failed.map { |r| r.fetch('id') }
      unless all.size == plan.fetch('checks') && ids.sort == completion.fetch('failed_ids').sort && ids.uniq.size == ids.size &&
          all.count { |r| r['result'] } == completion.fetch('completed_checks') && all.count { |r| r['skipped'] } == completion.fetch('skipped_checks')
        raise 'Full result coverage or unique failure disposition differs'
      end
      MethodSnapshot.save(evidence, 'shape-full-export')
      FileUtils.mkdir_p(destination)
      summaries = cases.to_h do |label, content|
        receipt = write_case(evidence: evidence, destination: File.join(destination, label),
          definition: content.fetch('definition'), records: content.fetch('records'),
          reference: content.fetch('reference'), authorization: authorization)
        puts JSON.generate({ 'case_id' => label }.merge(receipt.slice('records', 'executed', 'skipped', 'failed', 'retained_bytes')))
        $stdout.flush
        [label, receipt]
      end
      [FullShapeCampaign::APPROVAL_FILE, FullShapeCampaign::PILOT_FILE, 'shape-topology-full-completion.json', 'shape-static-findings.json'].each do |name|
        FileUtils.cp(File.join(evidence, name), File.join(destination, name))
      end
      compact = compact_plan(plan)
      reconstructed = JSON.pretty_generate(expand_plan(compact, all)) + "\n"
      raise 'Compact plan does not reproduce approved plan' unless Digest::SHA256.hexdigest(reconstructed) == ValidationAudit.sha(plan_path)
      ValidationAudit.save(File.join(destination, 'plan.json'), compact)
      inventories = Dir[File.join(evidence, 'inventory-*.json')].sort.to_h do |path|
        inventory = ValidationAudit.read(path)
        [inventory.fetch('benchmark'), inventory.reject { |key, _| key == 'rows' }.merge('sha256' => ValidationAudit.sha(path))]
      end
      ValidationAudit.save(File.join(destination, 'source-inventories.json'), inventories)
      %w[shape-full-attempts shape-full-waves shape-full-failure-events shape-full-reviews shape-concurrency-pilot].each do |name|
        path = File.join(evidence, name)
        FileUtils.cp_r(path, File.join(destination, name)) if File.directory?(path)
      end
      %w[shape-concurrency-authorization.json shape-concurrency-policy.json].each do |name|
        path = File.join(evidence, name)
        FileUtils.cp(path, File.join(destination, name)) if File.file?(path)
      end
      FileUtils.mkdir_p(File.join(destination, 'method'))
      Dir[File.join(evidence, 'method', 'shape-topology-full-attempt-*')].sort.each do |path|
        FileUtils.cp_r(path, File.join(destination, 'method', File.basename(path)))
      end
      FileUtils.cp_r(File.join(evidence, 'method', 'shape-full-export'), File.join(destination, 'method', 'shape-full-export'))
      concurrency_method = File.join(evidence, 'method', 'shape-concurrency-pilot')
      FileUtils.cp_r(concurrency_method, File.join(destination, 'method', 'shape-concurrency-pilot')) if File.directory?(concurrency_method)
      files = Dir[File.join(destination, '**/*')].select { |p| File.file?(p) }
      receipt = { 'schema_version' => 1, 'cases' => summaries, 'planned_checks' => all.size,
        'executed_checks' => completion.fetch('completed_checks'), 'skipped_checks' => completion.fetch('skipped_checks'),
        'failed_ids' => ids.sort, 'benchmark_runs' => 0,
        'files_sha256' => files.sort.to_h { |p| [p.delete_prefix(destination + '/'), ValidationAudit.sha(p)] },
        'retained_bytes' => files.sum { |p| File.size(p) } }
      ValidationAudit.save(File.join(destination, 'export.json'), receipt)
      puts JSON.pretty_generate(receipt.reject { |k, _| %w[cases files_sha256].include?(k) })
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: export_shape_full.rb WORKSPACE EVIDENCE NEW_DESTINATION' unless ARGV.size == 3
  ValidationAudit::ShapeFullExport.run(workspace: ARGV[0], evidence: ARGV[1], destination: ARGV[2])
end
