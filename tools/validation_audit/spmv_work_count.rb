# frozen_string_literal: true
require_relative 'inventory'
require 'time'

module ValidationAudit
  # A review pack, not an automatic verdict: identical final SpMV vectors do
  # not establish that all requested repetitions were executed. Inspect both
  # the source control flow and the already-bound executable where needed.
  module SpmvWorkCount
    module_function

    def select_pilot(rows, winner_ids)
      rows.group_by { |row| row.fetch('backend') }.sort.flat_map do |backend, group|
        ordered = group.sort_by do |row|
          [row.fetch('source_files').select { |path, _| path.match?(/\.(?:cpp|cu|hpp|h)\z/) }
            .values.sum { |file| file.fetch('bytes') }, row.fetch('id')]
        end
        winner = group.find { |row| winner_ids.include?(row.fetch('id')) }
        raise "Missing current SpMV winner for #{backend}" unless winner
        [winner, ordered[ordered.size / 2], ordered.last].uniq
      end
    end

    def capture(argv, path)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output, error, status = Open3.capture3(*argv)
      raise "Inspection failed: #{argv.first}: #{error}" unless status.success?
      raise 'Refusing to overwrite inspection output' if File.exist?(path)
      File.binwrite(path, output)
      { 'command' => argv, 'sha256' => Digest::SHA256.hexdigest(output), 'bytes' => output.bytesize,
        'seconds' => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
    end

    def review_estimate(started_at:, finished_at:, reviewed:, population:)
      elapsed = Time.iso8601(finished_at) - Time.iso8601(started_at)
      raise 'Invalid review interval or population' unless elapsed.positive? && reviewed.positive? && population >= reviewed
      remaining = elapsed * (population - reviewed) / reviewed
      { 'review_seconds' => elapsed, 'reviewed_implementations' => reviewed,
        'population' => population, 'remaining_implementations' => population - reviewed,
        'projected_full_review_hours' => elapsed * population / reviewed / 3600,
        'projected_remaining_review_hours' => remaining / 3600,
        'conservative_remaining_review_hours' => remaining * 1.5 / 3600,
        'method' => 'Linear extrapolation of complete source/compiled-code inspection, with a 1.5x conservative allowance. Not a statistical confidence interval; the pilot deliberately includes large implementations.',
        'approval_required' => remaining * 1.5 > 5 * 3600 }
    end

    def line_excerpts(path, ranges)
      lines = File.readlines(path)
      raise 'Missing evidence ranges' if ranges.empty?
      ranges.map do |range|
        first, last = range
        unless range.size == 2 && first.is_a?(Integer) && last.is_a?(Integer) &&
            first.positive? && last >= first && last <= lines.size && last - first < 500
          raise 'Invalid or excessive evidence range'
        end
        { 'first_line' => first, 'last_line' => last, 'text' => lines[(first - 1)..(last - 1)].join }
      end
    end

    def reviewed_pack(pack, review)
      raise 'Review ID differs' unless pack.dig('source', 'id') == review.fetch('id')
      unless review.fetch('finding') == 'no_work_count_omission_identified'
        raise 'Failures or ambiguous cases require individual adjudication, not pilot auto-acceptance'
      end
      directory = pack.fetch('local_directory')
      source_evidence = review.fetch('source_evidence').map do |entry|
        name = entry.fetch('file')
        pin = pack.fetch('source').fetch('source_files').fetch(name)
        path = File.join(directory, name)
        raise 'Source changed since preparation' unless ValidationAudit.sha(path) == pin.fetch('sha256')
        line_excerpts(path, entry.fetch('ranges')) # Validate references, but do not duplicate original code.
        entry.merge('sha256' => pin.fetch('sha256'), 'git_blob' => pin.fetch('git_blob'))
      end
      compiled_evidence = review.fetch('compiled_evidence').map do |entry|
        name = entry.fetch('file')
        pin = pack.fetch('inspections').fetch(name)
        path = File.join(directory, name)
        raise 'Inspection dump changed since preparation' unless ValidationAudit.sha(path) == pin.fetch('sha256')
        entry.reject { |key, _| key == 'ranges' }.merge('complete_dump_sha256' => pin.fetch('sha256'),
          'inspection_command' => pin.fetch('command'), 'excerpts' => line_excerpts(path, entry.fetch('ranges')))
      end
      raise 'Review must include source and compiled evidence' if source_evidence.empty? || compiled_evidence.empty?
      review.merge('source' => pack.fetch('source').slice('source_path', 'source_commit', 'staged_source_sha256'),
        'binary_sha256' => pack.fetch('binary_sha256'), 'binding_sha256' => pack.fetch('binding_sha256'),
        'source_evidence' => source_evidence, 'compiled_evidence' => compiled_evidence)
    end

    def finish(evidence:, review_path:)
      preparation_path = File.join(evidence, 'spmv-work-count-pilot/preparation.json')
      preparation = ValidationAudit.read(preparation_path)
      manual = ValidationAudit.read(review_path)
      packs = preparation.fetch('packs').to_h { |pack| [pack.dig('source', 'id'), pack] }
      reviews = manual.fetch('reviews')
      raise 'Pilot review coverage differs' unless reviews.map { |review| review.fetch('id') }.sort == packs.keys.sort
      estimate = review_estimate(started_at: manual.fetch('review_started_at'), finished_at: manual.fetch('review_finished_at'),
        reviewed: reviews.size, population: preparation.fetch('full_population'))
      report = manual.merge('schema_version' => 1, 'phase' => 'spmv-work-count-pilot',
        'saved_at' => Time.now.utc.iso8601, 'preparation_sha256' => ValidationAudit.sha(preparation_path),
        'review_input_sha256' => ValidationAudit.sha(review_path),
        'reviews' => reviews.map { |review| reviewed_pack(packs.fetch(review.fetch('id')), review) },
        'estimate' => estimate, 'status' => estimate.fetch('approval_required') ? 'pilot_complete_awaiting_full_review_approval' : 'pilot_complete',
        'new_failures' => [], 'program_executions' => 0, 'benchmark_runs' => 0, 'program_changes' => 0,
        'release_changes' => 0,
        'interpretation' => 'A bounded static review of the selected sources and bound validation executables, not an automatic validation verdict or proof for every possible input/compiler. Original measurement binaries were not assumed identical. The remainder of the population has not been reviewed for work count.')
      ValidationAudit.save(File.join(evidence, 'spmv-work-count-pilot/review.json'), report)
      puts JSON.pretty_generate(report.reject { |key, _| key == 'reviews' })
    end

    def prepare(workspace:, evidence:)
      workspace = File.realpath(workspace)
      raise 'Inspection workspace must be local /tmp' unless workspace.start_with?('/tmp/')
      destination = File.join(evidence, 'spmv-work-count-pilot')
      raise 'Pilot already prepared' if File.exist?(destination)
      started_at = Time.now.utc.iso8601
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      inventory_path = File.join(evidence, 'inventory-spmv.json')
      inventory = ValidationAudit.read(inventory_path)
      raise 'Release CSV changed' unless inventory.fetch('release_csv_sha256') == ValidationAudit.sha(File.join(RELEASE, 'release/scored_results.csv'))
      raise 'Release catalog changed' unless inventory.fetch('catalog_sha256') == ValidationAudit.sha(File.join(RELEASE, 'release/catalog.json'))
      completion_path = File.join(evidence, 'shape-topology-full-completion.json')
      completion = ValidationAudit.read(completion_path)
      raise 'Previous phase incomplete' unless completion.fetch('status') == 'complete' && completion.fetch('full_scope_accounted_for')
      rows = inventory.fetch('rows').reject { |row| completion.fetch('failed_ids').include?(row.fetch('id')) }
      audit_path = File.join(RELEASE, 'analysis/notes/2026-11-03-winner-validity/evidence.json')
      winners = ValidationAudit.read(audit_path).fetch('winners').select { |row| row.fetch('id').start_with?('spmv_') }.map { |row| row.fetch('id') }
      selected = select_pilot(rows, winners)
      local_root = File.join(workspace, 'spmv-work-count-pilot')
      raise 'Local pilot directory already exists' if File.exist?(local_root)
      FileUtils.mkdir_p(local_root)
      packs = selected.map do |row|
        id = row.fetch('id')
        directory = File.join(local_root, id)
        FileUtils.mkdir_p(directory)
        sources = row.fetch('source_files').to_h do |name, pin|
          bytes = ValidationAudit.git(SOURCE, 'cat-file', 'blob', pin.fetch('git_blob'))
          raise 'Source digest differs' unless Digest::SHA256.hexdigest(bytes) == pin.fetch('sha256')
          path = File.join(directory, name)
          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, bytes)
          [name, pin]
        end
        binding_path = File.join(evidence, 'bindings', id + '.json')
        binding = ValidationAudit.read(binding_path)
        executable = binding.fetch('executable')
        unless binding.fetch('source_files') == sources && executable.start_with?(workspace + '/') &&
            ValidationAudit.sha(executable) == binding.fetch('binary_sha256')
          raise 'Executable/source binding differs'
        end
        inspections = {
          'host-symbols.txt' => capture(['nm', '-C', executable], File.join(directory, 'host-symbols.txt')),
          'host-assembly.txt' => capture(['objdump', '-d', '-C', '--no-show-raw-insn', executable], File.join(directory, 'host-assembly.txt'))
        }
        if %w[cuda hybrid].include?(row.fetch('backend'))
          %w[ptx sass].each do |format|
            name = "device-#{format}.txt"
            inspections[name] = capture(['cuobjdump', "--dump-#{format}", executable], File.join(directory, name))
          end
        end
        { 'source' => row, 'binary_sha256' => binding.fetch('binary_sha256'),
          'binding_sha256' => ValidationAudit.sha(binding_path), 'local_directory' => directory,
          'inspections' => inspections }
      end
      report = { 'schema_version' => 1, 'phase' => 'spmv-work-count-pilot', 'started_at' => started_at,
        'prepared_at' => Time.now.utc.iso8601, 'preparation_seconds' => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
        'scope' => 'All still-valid SpMV implementations, including subsequent benchmark failures.',
        'full_population' => rows.size, 'full_ids' => rows.map { |row| row.fetch('id') }.sort,
        'selection' => 'Each backend: current winner, median source size, largest source size; deterministic ID tie-break.',
        'inventory_sha256' => ValidationAudit.sha(inventory_path), 'preceding_completion_sha256' => ValidationAudit.sha(completion_path),
        'winner_audit_sha256' => ValidationAudit.sha(audit_path), 'packs' => packs,
        'status' => 'prepared_for_manual_review_not_a_validation_verdict', 'program_executions' => 0,
        'benchmark_runs' => 0, 'program_changes' => 0,
        'full_phase_gate' => 'Estimate complete review cost after the pilot; under five hours may proceed, otherwise ask. Preparation time alone cannot justify the gate.' }
      ValidationAudit.save(File.join(destination, 'preparation.json'), report)
      puts JSON.pretty_generate(report.reject { |key, _| %w[packs full_ids].include?(key) }.merge('pilot_ids' => selected.map { |row| row.fetch('id') }))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV[2]
  when 'prepare'
    raise 'Expected WORKSPACE EVIDENCE prepare' unless ARGV.size == 3
    ValidationAudit::SpmvWorkCount.prepare(workspace: ARGV[0], evidence: ARGV[1])
  when 'finish'
    raise 'Expected WORKSPACE EVIDENCE finish REVIEW_JSON' unless ARGV.size == 4
    ValidationAudit::SpmvWorkCount.finish(evidence: ARGV[1], review_path: ARGV[3])
  else
    raise 'Usage: spmv_work_count.rb WORKSPACE EVIDENCE prepare|finish [REVIEW_JSON]'
  end
end
