# frozen_string_literal: true
require_relative 'spmv_work_count'

module ValidationAudit
  # Evidence bookkeeping only. Preparation and status never assign a verdict.
  # Each new review must be supplied by a source/control-flow inspection.
  class SpmvFullReview
    INVENTORY = 'post-publication-inventory-spmv.json'
    attr_reader :root, :evidence, :workspace

    def initialize(workspace:, evidence:)
      @workspace = File.realpath(workspace)
      raise 'Inspection workspace must be local /tmp' unless @workspace.start_with?('/tmp/')
      @evidence = File.realpath(evidence)
      @root = File.join(@evidence, 'spmv-work-count-full')
    end

    def load_scope
      authorization = ValidationAudit.read(File.join(root, 'authorization.json'))
      raise 'Full static review not authorized' unless authorization.fetch('full_review_authorized') == true
      inventory_path = File.join(evidence, INVENTORY)
      raise 'Authorized inventory differs' unless ValidationAudit.sha(inventory_path) == authorization.fetch('inventory_sha256')
      inventory = ValidationAudit.read(inventory_path)
      %w[release_csv_sha256 catalog_sha256].zip(%w[release/scored_results.csv release/catalog.json]).each do |key, file|
        raise 'Release data changed during static review' unless inventory.fetch(key) == ValidationAudit.sha(File.join(RELEASE, file))
      end
      rows = inventory.fetch('rows')
      raise 'Duplicate inventory IDs' unless rows.map { |r| r.fetch('id') }.uniq.size == rows.size
      transition = ValidationAudit.read(File.join(evidence, 'spmv-release-transition.json'))
      raise 'Missing verified pilot transition' unless transition.fetch('source_and_validation_bindings_identical') &&
        transition.fetch('new_inventory_sha256') == ValidationAudit.sha(inventory_path)
      pilot_path = File.join(evidence, 'spmv-work-count-pilot/review.json')
      raise 'Pilot evidence changed' unless ValidationAudit.sha(pilot_path) == authorization.fetch('pilot_review_sha256')
      pilot = ValidationAudit.read(pilot_path).fetch('reviews')
      indexed = rows.to_h { |row| [row.fetch('id'), row] }
      pilot.each do |review|
        row = indexed.fetch(review.fetch('id'))
        raise 'Pilot source differs' unless row.fetch('staged_source_sha256') == review.dig('source', 'staged_source_sha256')
        raise 'Pilot binding differs' unless ValidationAudit.sha(File.join(evidence, 'bindings', row.fetch('id') + '.json')) == review.fetch('binding_sha256')
      end
      [rows, pilot]
    end

    def checked_pack(path, row)
      pack = ValidationAudit.read(path)
      raise 'Prepared source binding differs' unless pack.fetch('source') == row
      binding_path = File.join(evidence, 'bindings', row.fetch('id') + '.json')
      raise 'Prepared executable binding differs' unless ValidationAudit.sha(binding_path) == pack.fetch('binding_sha256')
      binding = ValidationAudit.read(binding_path)
      raise 'Executable changed' unless ValidationAudit.sha(binding.fetch('executable')) == pack.fetch('binary_sha256')
      pack.fetch('source').fetch('source_files').each do |name, pin|
        raise 'Prepared source changed' unless ValidationAudit.sha(File.join(pack.fetch('local_directory'), name)) == pin.fetch('sha256')
      end
      pack.fetch('inspections').each do |name, pin|
        raise 'Prepared inspection changed' unless ValidationAudit.sha(File.join(pack.fetch('local_directory'), name)) == pin.fetch('sha256')
      end
      pack
    end

    def self.inspection_output(output, error, exit_code, optional_device: false)
      if exit_code == 0
        [output, { 'available' => true, 'exit_code' => exit_code }]
      elsif optional_device && error.include?('does not contain device code')
        [error, { 'available' => false, 'exit_code' => exit_code,
          'reason' => 'No embedded CUDA device code; inspect the actual host implementation.' }]
      else
        raise "Inspection failed (#{exit_code}): #{error}"
      end
    end

    def capture_inspection(command, path, optional_device: false)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output, error, result = Open3.capture3(*command)
      data, metadata = self.class.inspection_output(output, error, result.exitstatus, optional_device: optional_device)
      recovered = File.exist?(path)
      if recovered
        raise 'Unbound inspection differs on recovery' unless File.binread(path) == data
      else
        File.binwrite(path, data)
      end
      metadata.merge('command' => command, 'sha256' => Digest::SHA256.hexdigest(data), 'bytes' => data.bytesize,
        'seconds' => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
        'recovered_verified_existing_dump' => recovered)
    end

    def prepare
      rows, pilot = load_scope
      pilot_ids = pilot.map { |review| review.fetch('id') }
      rows.reject { |row| pilot_ids.include?(row.fetch('id')) }.each_with_index do |row, index|
        id = row.fetch('id')
        pack_path = File.join(root, 'packs', id + '.json')
        if File.exist?(pack_path)
          checked_pack(pack_path, row)
          next
        end
        directory = File.join(workspace, 'spmv-work-count-full', id)
        FileUtils.mkdir_p(directory)
        row.fetch('source_files').each do |name, pin|
          raise 'Unsafe source filename' if name.start_with?('/') || name.split('/').include?('..')
          path = File.join(directory, name)
          unless File.exist?(path)
            bytes = ValidationAudit.git(SOURCE, 'cat-file', 'blob', pin.fetch('git_blob'))
            raise 'Source blob digest differs' unless Digest::SHA256.hexdigest(bytes) == pin.fetch('sha256')
            FileUtils.mkdir_p(File.dirname(path))
            File.binwrite(path, bytes)
          end
          raise 'Existing source changed' unless ValidationAudit.sha(path) == pin.fetch('sha256')
        end
        binding_path = File.join(evidence, 'bindings', id + '.json')
        binding = ValidationAudit.read(binding_path)
        executable = binding.fetch('executable')
        raise 'Executable source binding differs' unless binding.fetch('source_files') == row.fetch('source_files') &&
          executable.start_with?(workspace + '/') && ValidationAudit.sha(executable) == binding.fetch('binary_sha256')
        commands = {
          'host-symbols.txt' => ['nm', '-C', executable],
          'host-assembly.txt' => ['objdump', '-d', '-C', '--no-show-raw-insn', executable]
        }
        if %w[cuda hybrid].include?(row.fetch('backend'))
          %w[ptx sass].each { |format| commands["device-#{format}.txt"] = ['cuobjdump', "--dump-#{format}", executable] }
        end
        inspections = commands.to_h do |name, command|
          path = File.join(directory, name)
          # An interrupted preparation may reuse an unbound dump only after
          # regenerating it from the same checked executable and comparing bytes.
          [name, capture_inspection(command, path, optional_device: name.start_with?('device-'))]
        end
        ValidationAudit.save(pack_path, { 'source' => row, 'binary_sha256' => binding.fetch('binary_sha256'),
          'binding_sha256' => ValidationAudit.sha(binding_path), 'local_directory' => directory,
          'inspections' => inspections, 'prepared_at' => Time.now.utc.iso8601 })
        puts "prepared #{index + 1}/#{rows.size - pilot.size}: #{id}" if index % 50 == 0
        $stdout.flush
      end
      status
    end

    # Validate a proposed batch without accepting its scientific judgments.
    # Uncertain findings remain uncertain; this command never records them.
    def check(input)
      rows, pilot = load_scope
      indexed = rows.to_h { |row| [row.fetch('id'), row] }
      manual = ValidationAudit.read(input)
      raise 'Review must identify its manual inspector' unless manual.fetch('reviewer').is_a?(String) && !manual.fetch('reviewer').empty?
      raise 'Invalid review interval' unless Time.iso8601(manual.fetch('review_finished_at')) >= Time.iso8601(manual.fetch('review_started_at'))
      %w[program_executions compilation program_changes benchmark_runs].each do |key|
        next unless manual.key?(key) || manual.key?('reviewer_model')
        raise 'Proposal violates static-only review constraints' unless manual.fetch(key, nil) == 0
      end
      ids = manual.fetch('reviews').map { |review| review.fetch('id') }
      raise 'Duplicate reviews in input' unless ids.uniq == ids
      raise 'Empty review batch' if ids.empty?
      manual.fetch('reviews').each do |review|
        id = review.fetch('id')
        pack = checked_pack(File.join(root, 'packs', id + '.json'), indexed.fetch(id))
        raise 'Unknown proposed finding' unless %w[no_work_count_omission_identified uncertain potential_failure].include?(review.fetch('finding'))
        raise 'Missing substantive summary' if review.fetch('summary').strip.empty?
        %w[source_evidence compiled_evidence].each do |kind|
          entries = review.fetch(kind)
          raise 'Missing proposed evidence' if entries.empty?
          pins = kind == 'source_evidence' ? pack.fetch('source').fetch('source_files') : pack.fetch('inspections')
          entries.each do |entry|
            pins.fetch(entry.fetch('file'))
            raise 'Missing proposed claim' if entry.fetch('claim').strip.empty?
            SpmvWorkCount.line_excerpts(File.join(pack.fetch('local_directory'), entry.fetch('file')), entry.fetch('ranges'))
          end
        end
      end
      { 'status' => 'proposal_bindings_verified_not_a_scientific_verdict', 'input_sha256' => ValidationAudit.sha(input),
        'reviews' => ids.size, 'findings' => manual.fetch('reviews').group_by { |review| review.fetch('finding') }.transform_values(&:size),
        'uncertain_ids' => manual.fetch('reviews').reject { |review| review.fetch('finding') == 'no_work_count_omission_identified' }.map { |review| review.fetch('id') } }
    end

    def record(input)
      check(input)
      rows, pilot = load_scope
      indexed = rows.to_h { |row| [row.fetch('id'), row] }
      pilot_ids = pilot.map { |review| review.fetch('id') }
      manual = ValidationAudit.read(input)
      self.class.verify_static_activity(manual)
      if manual.key?('reviewer_model')
        quality = manual.fetch('primary_quality_check', {})
        samples = quality.fetch('sampled_ids', [])
        ids = manual.fetch('reviews').map { |review| review.fetch('id') }
        raise 'Delegated review requires primary quality acceptance' unless
          quality.fetch('work_count_disagreement', nil) == false && !(samples & ids).empty? &&
          !quality.fetch('method', '').strip.empty? && !manual.fetch('proposal_sha256', '').empty?
      end
      records = manual.fetch('reviews').map do |review|
        id = review.fetch('id')
        raise 'Do not overwrite reusable pilot' if pilot_ids.include?(id)
        path = File.join(root, 'reviews', id + '.json')
        raise "Review already exists: #{id}" if File.exist?(path)
        pack = checked_pack(File.join(root, 'packs', id + '.json'), indexed.fetch(id))
        # This path records completed non-failure inspections. Any potential
        # failure must instead receive a separately retained adjudication.
        result = SpmvWorkCount.reviewed_pack(pack, review)
        raise 'Missing substantive summary' if result.fetch('summary').strip.empty?
        [path, result.merge(manual.slice('reviewer_model', 'proposal_sha256', 'primary_quality_check')).merge('schema_version' => 2, 'reviewer' => manual.fetch('reviewer'),
          'review_started_at' => manual.fetch('review_started_at'), 'review_finished_at' => manual.fetch('review_finished_at'),
          'review_input_sha256' => ValidationAudit.sha(input), 'pack_sha256' => ValidationAudit.sha(File.join(root, 'packs', id + '.json')),
          'program_executions' => 0, 'compilation' => 0, 'benchmark_runs' => 0, 'program_changes' => 0)]
      end
      retained_input = retain_review_input(input)
      raise 'Review input changed during acceptance' unless records.all? { |_, result| result.fetch('review_input_sha256') == retained_input }
      records.each { |path, result| ValidationAudit.save(path, result) }
      status
    end

    # Keep the exact accepted input bytes, once per digest. Per-ID evidence must
    # remain traceable after temporary review workspaces are removed.
    def retain_review_input(input)
      bytes = File.binread(input)
      digest = Digest::SHA256.hexdigest(bytes)
      path = File.join(root, 'review-inputs', digest + '.json')
      if File.exist?(path)
        raise 'Archived review input differs' unless File.binread(path) == bytes
      else
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(bytes) }
      end
      digest
    end

    def self.verify_static_activity(review, legacy_schema: false)
      %w[program_executions compilation benchmark_runs program_changes].each do |key|
        # Early immutable v1 records did not serialize this counter. Preserve
        # that absence explicitly; never reinterpret a nonzero value as zero.
        next if legacy_schema && key == 'compilation' && !review.key?(key)
        raise 'Static-only review constraint differs' unless review.fetch(key, nil) == 0
      end
      true
    end

    def status
      rows, pilot = load_scope
      reviews = Dir.glob(File.join(root, 'reviews', '*.json')).map { |path| ValidationAudit.read(path) }
      completed = (pilot + reviews).map { |review| review.fetch('id') }
      ids = rows.map { |row| row.fetch('id') }
      raise 'Review coverage mismatch' unless completed.uniq.size == completed.size && (completed - ids).empty?
      result = { 'status' => completed.size == ids.size ? 'all_inspections_recorded_pending_final_verification' : 'static_review_in_progress',
        'population' => ids.size, 'reused_pilot_reviews' => pilot.size, 'new_reviews' => reviews.size,
        'remaining' => ids.size - completed.size, 'prepared_packs' => Dir.glob(File.join(root, 'packs', '*.json')).size,
        'remaining_ids' => ids - completed, 'program_executions' => 0, 'benchmark_runs' => 0 }
      puts JSON.pretty_generate(result.reject { |key, _| key == 'remaining_ids' })
      result
    end

    # Check retained evidence against the complete pinned files, not merely
    # whether a review file exists. This validates provenance, not the judgment.
    def self.verify_retained_review(pack, review)
      raise 'Review ID differs' unless review.fetch('id') == pack.dig('source', 'id')
      raise 'Unresolved scientific finding' unless review.fetch('finding') == 'no_work_count_omission_identified'
      raise 'Missing substantive summary' if review.fetch('summary').strip.empty?
      expected_source = pack.fetch('source').slice('source_path', 'source_commit', 'staged_source_sha256')
      raise 'Retained source differs' unless review.fetch('source') == expected_source
      %w[binary_sha256 binding_sha256].each do |key|
        raise "Retained #{key} differs" unless review.fetch(key) == pack.fetch(key)
      end
      directory = pack.fetch('local_directory')
      source_entries = review.fetch('source_evidence')
      compiled_entries = review.fetch('compiled_evidence')
      raise 'Missing source or compiled evidence' if source_entries.empty? || compiled_entries.empty?
      source_entries.each do |entry|
        pin = pack.fetch('source').fetch('source_files').fetch(entry.fetch('file'))
        raise 'Missing source claim' if entry.fetch('claim').strip.empty?
        raise 'Retained source evidence differs' unless entry.fetch('sha256') == pin.fetch('sha256') &&
          entry.fetch('git_blob') == pin.fetch('git_blob')
        path = File.join(directory, entry.fetch('file'))
        raise 'Source evidence changed' unless ValidationAudit.sha(path) == pin.fetch('sha256')
        SpmvWorkCount.line_excerpts(path, entry.fetch('ranges'))
      end
      compiled_entries.each do |entry|
        pin = pack.fetch('inspections').fetch(entry.fetch('file'))
        raise 'Missing compiled claim' if entry.fetch('claim').strip.empty?
        raise 'Retained inspection provenance differs' unless entry.fetch('complete_dump_sha256') == pin.fetch('sha256') &&
          entry.fetch('inspection_command') == pin.fetch('command')
        path = File.join(directory, entry.fetch('file'))
        raise 'Compiled evidence changed' unless ValidationAudit.sha(path) == pin.fetch('sha256')
        excerpts = entry.fetch('excerpts')
        ranges = excerpts.map { |excerpt| [excerpt.fetch('first_line'), excerpt.fetch('last_line')] }
        raise 'Retained compiled excerpt differs' unless excerpts == SpmvWorkCount.line_excerpts(path, ranges)
      end
      true
    end

    def verify
      rows, pilot = load_scope
      coverage = status
      pilot_preparation = ValidationAudit.read(File.join(evidence, 'spmv-work-count-pilot/preparation.json'))
      pilot_packs = pilot_preparation.fetch('packs').to_h { |pack| [pack.dig('source', 'id'), pack] }
      pilot.each do |review|
        pack = pilot_packs.fetch(review.fetch('id'))
        binding = ValidationAudit.read(File.join(evidence, 'bindings', review.fetch('id') + '.json'))
        raise 'Pilot executable changed' unless ValidationAudit.sha(binding.fetch('executable')) == pack.fetch('binary_sha256')
        self.class.verify_retained_review(pack, review)
      end
      indexed = rows.to_h { |row| [row.fetch('id'), row] }
      missing_compilation_metadata = []
      hashes = Dir.glob(File.join(root, 'reviews', '*.json')).sort.to_h do |path|
        review = ValidationAudit.read(path)
        id = review.fetch('id')
        raise 'Review filename differs' unless File.basename(path) == id + '.json'
        pack_path = File.join(root, 'packs', id + '.json')
        pack = checked_pack(pack_path, indexed.fetch(id))
        raise 'Review pack changed' unless review.fetch('pack_sha256') == ValidationAudit.sha(pack_path)
        raise 'Missing reviewer identity' if review.fetch('reviewer').strip.empty?
        raise 'Invalid retained review interval' unless Time.iso8601(review.fetch('review_finished_at')) >= Time.iso8601(review.fetch('review_started_at'))
        legacy = review.fetch('schema_version') == 1
        raise 'Unknown retained review schema' unless [1, 2].include?(review.fetch('schema_version'))
        self.class.verify_static_activity(review, legacy_schema: legacy)
        missing_compilation_metadata << id if legacy && !review.key?('compilation')
        input_digest = review.fetch('review_input_sha256')
        raise 'Invalid review input digest' unless input_digest.match?(/\A[0-9a-f]{64}\z/)
        input_path = File.join(root, 'review-inputs', input_digest + '.json')
        raise 'Archived review input changed' unless ValidationAudit.sha(input_path) == input_digest
        self.class.verify_retained_review(pack, review)
        [id, ValidationAudit.sha(path)]
      end
      coverage.reject { |key, _| key == 'remaining_ids' }.merge('evidence_verified' => true,
        'review_sha256' => hashes, 'verified_at' => Time.now.utc.iso8601,
        'legacy_records_without_compilation_counter' => missing_compilation_metadata.size,
        'legacy_metadata_note' => 'Early immutable schema-v1 records omit the compilation counter; absence is retained as missing metadata, not evidence of compilation or an inferred zero. New records require explicit zero activity counters.')
    end

    def finish
      report = verify
      raise 'Review scope is incomplete' unless report.fetch('remaining').zero?
      report = report.merge('status' => 'complete', 'full_scope_accounted_for' => true,
        'new_failures' => [], 'program_changes' => 0,
        'inventory_sha256' => ValidationAudit.sha(File.join(evidence, INVENTORY)),
        'authorization_sha256' => ValidationAudit.sha(File.join(root, 'authorization.json')),
        'pilot_review_sha256' => ValidationAudit.sha(File.join(evidence, 'spmv-work-count-pilot/review.json')),
        'interpretation' => 'Static source/control-flow and bound validation-executable review. Not a formal proof for all inputs or compilers; historical performance binaries were not assumed identical. No performance reruns or source corrections.')
      delegation_path = File.join(root, 'delegation-authorization.json')
      report['delegation_authorization_sha256'] = ValidationAudit.sha(delegation_path) if File.exist?(delegation_path)
      ValidationAudit.save(File.join(root, 'completion.json'), report)
      puts JSON.pretty_generate(report.reject { |key, _| key == 'review_sha256' })
      report
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: spmv_full_review.rb WORKSPACE EVIDENCE prepare|status|check|verify|finish|record [REVIEW_JSON]' unless (3..4).cover?(ARGV.size)
  review = ValidationAudit::SpmvFullReview.new(workspace: ARGV[0], evidence: ARGV[1])
  case ARGV[2]
  when 'prepare' then review.prepare
  when 'status' then review.status
  when 'record' then review.record(ARGV.fetch(3))
  when 'check' then puts JSON.pretty_generate(review.check(ARGV.fetch(3)))
  when 'verify' then puts JSON.pretty_generate(review.verify.reject { |key, _| key == 'review_sha256' })
  when 'finish' then review.finish
  else raise 'Unknown action'
  end
end
