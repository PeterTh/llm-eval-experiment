# frozen_string_literal: true
require_relative 'campaign'

module ValidationAudit
  module Export
    module_function
    def archive_record(root, location, cache)
      path = location.fetch('path')
      raise 'Unsafe archival evidence path' if path.start_with?('/') || path.split('/').include?('..')
      lines = cache[path] ||= File.readlines(File.join(root, path))
      bytes = lines.fetch(location.fetch('line') - 1)
      raise 'Archival validation line changed' unless Digest::SHA256.hexdigest(bytes) == location.fetch('line_sha256')
      JSON.parse(bytes)
    end

    def run(evidence:, destination:, label:)
      definitions = { 'floyd' => Campaign::FLOYD, 'stencil' => Campaign::STENCIL }
      definition = definitions.fetch(label)
      case_id = definition.fetch('id')
      benchmark = definition.fetch('benchmark')
      completion_name = label == 'floyd' ? 'floyd-completion.json' : "#{case_id}-completion.json"
      pilot_name = label == 'floyd' ? 'floyd-pilot.json' : "#{case_id}-pilot.json"
      completion = ValidationAudit.read(File.join(evidence, completion_name))
      pilot = ValidationAudit.read(File.join(evidence, pilot_name))
      raise 'Pilot did not authorize full scope' unless pilot.fetch('under_five_hours')
      inventory = ValidationAudit.read(File.join(evidence, "inventory-#{benchmark}.json"))
      rows = inventory.fetch('rows')
      reference_path = if label == 'floyd'
        File.join(RELEASE, 'data/validation/references/floydwarshall/validation_out_stdout.log')
      else
        File.join(evidence, case_id, "reference_#{benchmark}", 'validation_stdout.log')
      end
      reference = File.read(reference_path)
      archived = {}
      records = rows.sort_by { |row| row.fetch('id') }.map do |row|
        directory = File.join(evidence, case_id, row.fetch('id'))
        result_path = File.join(directory, 'result.json')
        result = ValidationAudit.read(result_path)
        raise 'Result source/case changed' unless result.fetch('source_commit') == row.fetch('source_commit') && result.fetch('definition') == definition
        logs = if result['archived_validation']
          original = archive_record(RELEASE, result.fetch('archived_validation'), archived)
          raise 'Archived source binding changed' unless ValidationAudit.archived_source_digest(original) == row.fetch('staged_source_sha256')
          { 'stdout' => ValidationAudit.stdout(original) }
        else
          %w[command stdout stderr exitcode wall_time].to_h { |suffix| [suffix, File.read("#{directory}/validation_#{suffix}.log")] }
        end
        output = logs.fetch('stdout')
        raise 'Numerical output changed' unless Digest::SHA256.hexdigest(output) == result.fetch('output_sha256')
        comparison = if result['execution'] && !result.dig('execution', 'success')
          [false, "Supplemental correctness execution failed: exit #{result.dig('execution', 'exit_code')}, timeout #{result.dig('execution', 'timed_out')}."]
        elsif !result.fetch('internal_validation')
          [false, 'Supplemental internal check failed.']
        else
          numerical = validate(reference, output, benchmark)
          numerical.first && definition['comparison'] == 'integer_hash' ? LocalEvaluation::ComparisonPolicy.integer_hashes(reference, output) : numerical
        end
        raise "Verdict does not reproduce: #{row.fetch('id')}" unless comparison == result.fetch('comparison') && result.fetch('passed') == comparison.first
        raise 'Reference changed' unless result.fetch('reference_sha256') == Digest::SHA256.hexdigest(reference)
        kept_logs = result['archived_validation'] && result.fetch('passed') ? {} : logs
        source_binding = row.reject { |key, _| key == 'source_files' }
        { 'id' => row.fetch('id'), 'source' => source_binding, 'result' => result, 'result_sha256' => ValidationAudit.sha(result_path),
          'logs' => kept_logs, 'log_sha256' => logs.transform_values { |text| Digest::SHA256.hexdigest(text) } }
      end
      failed = records.reject { |row| row.dig('result', 'passed') }
      raise 'Completion count differs' unless records.size == rows.size && records.size == completion.fetch(label == 'floyd' ? 'total' : 'checked') &&
        failed.map { |row| row.fetch('id') } == completion.fetch('failed_ids').sort
      raise 'Refusing to overwrite an export' if File.exist?(destination)
      FileUtils.mkdir_p(destination)
      LocalEvaluation.atomic_write(File.join(destination, 'records.jsonl'), records.map { |r| JSON.generate(r) + "\n" }.join)
      ValidationAudit.save(File.join(destination, 'reference.json'), { 'source_commit' => INPUT_COMMIT, 'definition' => definition,
        'stdout' => reference, 'stdout_sha256' => Digest::SHA256.hexdigest(reference) })
      ValidationAudit.save(File.join(destination, 'pilot.json'), pilot)
      ValidationAudit.save(File.join(destination, 'completion.json'), completion)
      ValidationAudit.save(File.join(destination, 'inventory.json'), inventory)
      failures = failed.map do |row|
        source, result = row.values_at('source', 'result')
        source.slice('id', 'source_commit', 'source_path', 'validation_record').merge(
          'stages' => { 'basic_para' => true, 'validation_build' => true, 'validation_run' => true, 'internal_validation' => true, 'output_comparison' => false },
          'case_id' => case_id, 'result' => result, 'result_sha256' => row.fetch('result_sha256'), 'stdout' => row.fetch('logs').fetch('stdout'))
      end
      ValidationAudit.save(File.join(destination, 'exclusions.json'), { 'schema_version' => 2, 'case' => definition,
        'record_count' => failures.size, 'failed_stage' => 'output_comparison',
        'authorization' => { 'source' => 'user', 'statement' => 'Apply each validation improvement after a pilot when the full retrospective estimate is under five hours; failures use the existing failed external validation category. No performance benchmarks are rerun.' },
        'reference' => { 'stdout' => reference, 'stdout_sha256' => Digest::SHA256.hexdigest(reference) }, 'records' => failures })
      bindings = records.filter_map do |record|
        path = File.join(evidence, 'bindings', "#{record.fetch('id')}.json")
        next unless File.file?(path)
        binding = ValidationAudit.read(path)
        unless binding['reused_cache']
          directory = File.dirname(binding.fetch('executable'))
          binding['build_logs'] = %w[cmake build].product(%w[command stdout stderr exitcode wall_time]).to_h do |stage, suffix|
            name = "#{stage}_#{suffix}.log"
            bytes = File.read(File.join(directory, name))
            text = bytes.bytesize > 16000 ? bytes.byteslice(0, 8000) + "\n[bounded excerpt]\n" + bytes.byteslice(-8000, 8000) : bytes
            [name, { 'text' => text, 'bytes' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes), 'truncated' => bytes.bytesize > 16000 }]
          end
        end
        binding
      end
      ValidationAudit.save(File.join(destination, 'build-bindings.json'), bindings)
      method = File.join(evidence, 'method', "#{label}-pilot")
      FileUtils.cp_r(method, File.join(destination, 'method')) if File.directory?(method)
      findings = File.join(evidence, "#{label}-static-findings.json")
      FileUtils.cp(findings, File.join(destination, 'static-findings.json')) if File.file?(findings)
      files = Dir[File.join(destination, '**/*')].select { |path| File.file?(path) }
      receipt = { 'schema_version' => 1, 'case' => definition, 'records' => records.size, 'failed' => failed.size,
        'registry_sha256' => ValidationAudit.sha(File.join(destination, 'exclusions.json')),
        'files_sha256' => files.sort.to_h { |p| [p.delete_prefix(destination + '/'), ValidationAudit.sha(p)] },
        'retained_bytes' => files.sum { |p| File.size(p) }, 'benchmark_runs' => 0 }
      ValidationAudit.save(File.join(destination, 'export.json'), receipt)
      puts JSON.pretty_generate(receipt.slice('records', 'failed', 'retained_bytes', 'benchmark_runs'))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: export.rb EVIDENCE NEW_DESTINATION floyd|stencil' unless ARGV.size == 3
  ValidationAudit::Export.run(evidence: ARGV[0], destination: ARGV[1], label: ARGV[2])
end
