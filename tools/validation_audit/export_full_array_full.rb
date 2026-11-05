# frozen_string_literal: true
require_relative 'export_full_array_pilot'
require_relative 'full_array_root_output_reviews'
require_relative 'full_array_eligibility'

module ValidationAudit
  module FullArrayFullExport
    SHARD_BYTES = 8 * 1024 * 1024
    module_function

    def json_digest(value)
      Digest::SHA256.hexdigest(JSON.pretty_generate(value) + "\n")
    end

    # The comparison already carries the exact source-file manifest. Keep its
    # position in the binding so the original receipt reconstructs byte-for-byte.
    def compact_binding(binding, source)
      raise 'Binding source manifest differs' unless binding.fetch('source_files') == source.fetch('source_files')
      raise 'Reserved compact-binding key' if binding.key?('source_files_from_comparison')
      binding.to_h { |key, value| key == 'source_files' ? ['source_files_from_comparison', true] : [key, value] }
    end

    def expand_binding(binding, source)
      raise 'Missing compact source binding' unless binding.fetch('source_files_from_comparison') == true && !binding.key?('source_files')
      binding.to_h do |key, value|
        key == 'source_files_from_comparison' ? ['source_files', source.fetch('source_files')] : [key, value]
      end
    end

    def check_completion!(plan, completion, plan_digest)
      ids = plan.fetch('groups').flat_map { |group| group.fetch('full_ids') }
      reused = plan.fetch('reused').keys
      failed = completion.fetch('failed_ids')
      unless completion.fetch('status') == 'complete' && completion.fetch('full_scope_accounted_for') == true &&
          completion.fetch('plan_sha256') == plan_digest && ids.size == ids.uniq.size &&
          ids.size == plan.fetch('population') && ids.size == completion.fetch('population') &&
          ids.size == completion.fetch('completed_checks') && reused.size == completion.fetch('reused_checks') &&
          (reused - ids).empty? && plan.fetch('new_checks') == ids.size - reused.size &&
          failed == failed.uniq.sort && (failed - ids).empty? &&
          completion.fetch('passed_checks') == ids.size - failed.size &&
          %w[benchmark_runs llm_invocations].all? { |key| plan.fetch(key).zero? && completion.fetch(key).zero? } &&
          plan.fetch('program_source_changes').zero?
        raise 'Full-array sweep is incomplete or its coverage differs'
      end
      ids
    end

    def checked_pilot(directory)
      receipt = ValidationAudit.read(File.join(directory, 'export.json'))
      receipt.fetch('files_sha256').each do |name, digest|
        raise 'Unsafe pilot member' if name.start_with?('/') || name.split('/').include?('..')
        path = File.join(directory, name)
        raise 'Published pilot evidence differs' unless File.file?(path) && !File.symlink?(path) && ValidationAudit.sha(path) == digest
      end
      records = {}
      File.foreach(File.join(directory, 'records.jsonl')).with_index(1) do |line, number|
        record = JSON.parse(line)
        key = [record.fetch('phase'), record.fetch('id')]
        raise 'Duplicate pilot record' if records.key?(key)
        records[key] = { 'record' => record, 'line' => number, 'line_sha256' => Digest::SHA256.hexdigest(line) }
      end
      [receipt, records]
    end

    def write_shards(destination, prefix, records, limit: SHARD_BYTES)
      raise 'Unsafe shard prefix' unless prefix.match?(%r{\Arecords/[a-z0-9-]+-(?:omp|cuda|mpi|hybrid)\z})
      chunks, current = [], +''
      records.each do |record|
        line = JSON.generate(record) + "\n"
        raise 'One evidence record exceeds the shard limit' if line.bytesize > limit
        if !current.empty? && current.bytesize + line.bytesize > limit
          chunks << current
          current = +''
        end
        current << line
      end
      chunks << current unless current.empty?
      chunks.each_with_index.map do |bytes, index|
        name = format('%s-%03d.jsonl', prefix, index + 1)
        path = File.join(destination, name)
        raise 'Refusing to overwrite evidence shard' if File.exist?(path)
        FileUtils.mkdir_p(File.dirname(path))
        LocalEvaluation.atomic_write(path, bytes)
        { 'path' => name, 'sha256' => ValidationAudit.sha(path), 'records' => bytes.count("\n"), 'bytes' => bytes.bytesize }
      end
    end

    def record(evidence:, directory:, row:, verifier:, destination:)
      comparison = verifier.verify_saved(directory, row)
      observation_path = File.join(directory, 'observation.json')
      observation = ValidationAudit.read(observation_path)
      binding = ValidationAudit.read(File.join(evidence, 'bindings', row.fetch('id') + '.json'))
      compact = compact_binding(binding, row)
      raise 'Compact build binding does not reconstruct' unless json_digest(expand_binding(compact, row)) == observation.fetch('binding_sha256')
      logs = %w[command stdout stderr exitcode wall_time].to_h do |part|
        [part, File.read(File.join(directory, "validation_#{part}.log"))]
      end
      value = { 'id' => row.fetch('id'), 'phase' => FullArrayFull::PHASE,
        'comparison' => comparison, 'comparison_sha256' => ValidationAudit.sha(File.join(directory, 'comparison.json')),
        'observation' => observation, 'binding' => compact, 'logs' => logs,
        'log_sha256' => logs.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) } }
      review_path = File.join(directory, 'capture-reconciliation.json')
      value['capture_reconciliation'] = ValidationAudit.read(review_path) if File.exist?(review_path)
      adapter_path = File.join(directory, 'observation-adapter.json')
      if File.exist?(adapter_path)
        value['observation_adapter'] = ValidationAudit.read(adapter_path)
        value['observation_adapter_sha256'] = ValidationAudit.sha(adapter_path)
      end
      primary_review_path = File.join(directory, 'primary-output-review.json')
      if File.exist?(primary_review_path)
        value['primary_output_review'] = ValidationAudit.read(primary_review_path)
        value['primary_output_review_sha256'] = ValidationAudit.sha(primary_review_path)
        value['reviewed_replica_arrays'] = observation.fetch('objects').to_h do |object|
          [object.fetch('sha256'), FullArrayPilotExport.witness(object, destination)]
        end
      end
      %w[suppressed-output-review root-output-review].each do |name|
        path = File.join(directory, name + '.json')
        next unless File.exist?(path)
        key = name.tr('-', '_')
        value[key] = ValidationAudit.read(path)
        value[key + '_sha256'] = ValidationAudit.sha(path)
        value['reviewed_replica_arrays'] = observation.fetch('objects').to_h do |object|
          [object.fetch('sha256'), FullArrayPilotExport.witness(object, destination)]
        end
        reference, = verifier.reference_for(row.fetch('benchmark'))
        value['review_reference_arrays'] = reference.fetch('objects').to_h do |object|
          [object.fetch('name'), FullArrayPilotExport.witness(object, destination)]
        end
      end
      unless comparison.fetch('passed')
        normalized, = verifier.normalized_observation(observation, logs.fetch('stdout'))
        reference, = verifier.reference_for(row.fetch('benchmark'))
        value['failure_arrays'] = [reference, normalized].to_h do |capture|
          [capture.fetch('id'), capture.fetch('objects').to_h do |object|
            [object.fetch('name'), FullArrayPilotExport.witness(object, destination)]
          end]
        end
      end
      value
    end

    def eligibility(destination, plan, pilot, pilot_records, reused, shards)
      failures = {}
      reused.each do |id, binding|
        next if binding.fetch('passed')
        entry = pilot_records.fetch([binding.fetch('phase'), id])
        location = FullArrayEligibility.location(pilot, File.join(pilot, 'records.jsonl'),
          entry.fetch('line'), entry.fetch('line_sha256'))
        failures[id] = [entry.fetch('record'), location]
      end
      shards.each do |shard|
        path = File.join(destination, shard.fetch('path'))
        File.foreach(path).with_index(1) do |line, number|
          value = JSON.parse(line)
          next if value.dig('comparison', 'passed')
          raise 'Duplicate eligibility failure' if failures.key?(value.fetch('id'))
          failures[value.fetch('id')] = [value,
            FullArrayEligibility.location(destination, path, number, Digest::SHA256.hexdigest(line))]
        end
      end
      references = ValidationAudit.read(File.join(pilot, 'references.json'))
      plan.fetch('groups').map { |group| group.fetch('benchmark') }.uniq.sort.to_h do |benchmark|
        definition = FullArrayEligibility.definition(benchmark, plan.fetch('groups'))
        pairs = failures.sort.filter_map do |_id, (value, location)|
          next unless value.dig('comparison', 'source', 'benchmark') == benchmark
          FullArrayEligibility.rows(value, location, definition)
        end
        directory = File.join(destination, 'eligibility', benchmark)
        registry = FullArrayEligibility.registry(definition, references.fetch(benchmark), pairs.map(&:first))
        ValidationAudit.save(File.join(directory, 'exclusions.json'), registry)
        LocalEvaluation.atomic_write(File.join(directory, 'records.jsonl'), pairs.map { |pair| JSON.generate(pair.last) + "\n" }.join)
        files = %w[exclusions.json records.jsonl].to_h { |name| [name, ValidationAudit.sha(File.join(directory, name))] }
        summary = { 'schema_version' => 1, 'case' => definition, 'records' => pairs.size,
          'registry_sha256' => files.fetch('exclusions.json'), 'files_sha256' => files }
        ValidationAudit.save(File.join(directory, 'export.json'), summary)
        [benchmark, summary]
      end
    end

    def run(workspace:, evidence:, destination:, pilot_directory:)
      raise 'Refusing to overwrite full-array export' if File.exist?(destination)
      pilot_directory = File.realpath(pilot_directory)
      unless File.realpath(File.dirname(destination)) == File.dirname(pilot_directory)
        raise 'Published pilot and full export must share their artifact parent'
      end
      root = File.join(evidence, FullArrayFull::PHASE)
      plan_path = File.join(root, 'plan.json')
      plan = ValidationAudit.read(plan_path)
      completion = ValidationAudit.read(File.join(root, 'completion.json'))
      ids = check_completion!(plan, completion, ValidationAudit.sha(plan_path))
      pilot_receipt, pilot_records = checked_pilot(pilot_directory)
      pilot_plan = ValidationAudit.read(File.join(pilot_directory, 'full-array-pilot-01', 'plan.json'))
      raise 'Shared pilot plan differs' unless json_digest(pilot_plan) == plan.fetch('pilot_plan_sha256')
      # This export references the already-published frozen method instead of
      # copying it again. A future method revision must be handled explicitly.
      plan.fetch('method_sha256').each do |name, digest|
        unless pilot_receipt.fetch('files_sha256').fetch(File.join('full-sweep-method', name)) == digest
          raise 'Full-sweep method differs from the published pilot snapshot'
        end
      end
      verifier = FullArrayFull.new(workspace: workspace, evidence: evidence)
      rows = pilot_plan.fetch('inventory_sha256').flat_map do |benchmark, digest|
        path = File.join(evidence, "inventory-#{benchmark}.json")
        raise 'Source inventory changed' unless ValidationAudit.sha(path) == digest
        ValidationAudit.read(path).fetch('rows')
      end.to_h { |row| [row.fetch('id'), row] }
      reused = plan.fetch('reused').sort.to_h do |id, binding|
        phase = File.dirname(binding.fetch('directory'))
        entry = pilot_records.fetch([phase, id])
        saved = verifier.verify_saved(File.join(evidence, binding.fetch('directory')), rows.fetch(id))
        published = entry.fetch('record')
        unless published.fetch('comparison') == saved && published.fetch('comparison_sha256') == binding.fetch('comparison_sha256') &&
            json_digest(published.fetch('observation')) == binding.fetch('observation_sha256')
          raise 'Published reused comparison differs'
        end
        [id, entry.slice('line', 'line_sha256').merge('phase' => phase,
          'comparison_sha256' => binding.fetch('comparison_sha256'), 'passed' => saved.fetch('passed'))]
      end
      FileUtils.mkdir_p(destination)
      shards, failed, new_count = [], reused.reject { |_id, value| value.fetch('passed') }.keys, 0
      plan.fetch('groups').each do |group|
        records = group.fetch('full_ids').reject { |id| reused.key?(id) }.sort.map do |id|
          value = record(evidence: evidence, directory: File.join(root, id), row: rows.fetch(id),
            verifier: verifier, destination: destination)
          failed << id unless value.dig('comparison', 'passed')
          value
        end
        new_count += records.size
        shards.concat(write_shards(destination, "records/#{group.fetch('benchmark')}-#{group.fetch('backend')}", records))
      end
      unless failed.sort == completion.fetch('failed_ids') && new_count == plan.fetch('new_checks') && new_count + reused.size == ids.size
        raise 'Export dispositions differ from completed sweep'
      end
      eligibility_cases = eligibility(destination, plan, pilot_directory, pilot_records, reused, shards)
      ValidationAudit.save(File.join(destination, 'reused.json'), reused)
      %w[plan.json completion.json].each { |name| FileUtils.cp(File.join(root, name), File.join(destination, name)) }
      FileUtils.cp(File.join(evidence, FullArrayFull::AUTHORIZATION), File.join(destination, 'authorization.json'))
      %w[attempts failure-events observer-adapters observer-extensions].each do |name|
        path = File.join(root, name)
        FileUtils.cp_r(path, File.join(destination, name)) if File.directory?(path)
      end
      Dir[File.join(root, 'launch-*.json')].sort.each do |path|
        receipt = ValidationAudit.read(path)
        source_name = receipt['launcher_name'] || (receipt.key?('extension_method_sha256') ? 'launch_full_array_reviewed.rb' : 'launch_full_array.rb')
        unless %w[launch_full_array.rb launch_full_array_reviewed.rb launch_full_array_suppressed.rb launch_full_array_root_outputs.rb].include?(source_name)
          raise 'Unknown historical sweep launcher'
        end
        source = File.join(__dir__, source_name)
        raise 'Historical launcher changed before export' unless ValidationAudit.sha(source) == receipt.fetch('launcher_sha256')
        target = File.join(destination, 'launch-methods', receipt.fetch('launcher_sha256') + '.rb')
        FileUtils.mkdir_p(File.dirname(target))
        if File.file?(target)
          raise 'Conflicting retained launcher' unless ValidationAudit.sha(target) == receipt.fetch('launcher_sha256')
        else
          FileUtils.cp(source, target)
        end
        FileUtils.mkdir_p(File.join(destination, 'launches'))
        FileUtils.cp(path, File.join(destination, 'launches', File.basename(path)))
      end
      FileUtils.mkdir_p(File.join(destination, 'export-method'))
      %w[export_full_array_full.rb].each do |name|
        FileUtils.cp(File.join(__dir__, name), File.join(destination, 'export-method', name))
      end
      # A standalone read-only verifier, independent of the execution stack and
      # its machine-local paths. Preserve relative requires in this small tree.
      method_root = File.expand_path('../..', __dir__)
      %w[tools/validation_audit/verify_full_array_full_export.rb
        tools/validation_audit/verify_full_array_pilot_export.rb
        tools/validation_audit/full_array_offline_support.rb
        tools/validation_audit/full_array_eligibility.rb
        validation_helper.rb lib/local_evaluation/comparison_policy.rb].each do |name|
        target = File.join(destination, 'verification-method', name)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(File.join(method_root, name), target)
      end
      files = Dir[File.join(destination, '**/*')].select { |path| File.file?(path) }.sort
      receipt = { 'schema_version' => 1, 'kind' => 'full-array-correctness-sweep', 'population' => ids.size,
        'new_checks' => new_count, 'reused_checks' => reused.size, 'failed_ids' => failed.sort,
        'benchmark_runs' => 0, 'llm_invocations' => 0, 'program_source_changes' => 0,
        'shared_pilot' => { 'directory' => File.basename(pilot_directory),
          'export_sha256' => ValidationAudit.sha(File.join(pilot_directory, 'export.json')) },
        'record_shards' => shards, 'eligibility' => eligibility_cases, 'retained_bytes' => files.sum { |path| File.size(path) },
        'files_sha256' => files.to_h { |path| [path.delete_prefix(destination + '/'), ValidationAudit.sha(path)] } }
      ValidationAudit.save(File.join(destination, 'export.json'), receipt)
      puts JSON.pretty_generate(receipt.reject { |key, _| %w[files_sha256 record_shards].include?(key) })
      receipt
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: export_full_array_full.rb WORKSPACE EVIDENCE NEW_DESTINATION PUBLISHED_PILOT_DIRECTORY' unless ARGV.size == 4
  ValidationAudit::FullArrayFullExport.run(workspace: ARGV[0], evidence: ARGV[1], destination: ARGV[2], pilot_directory: ARGV[3])
end
