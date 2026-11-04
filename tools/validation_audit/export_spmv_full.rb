# frozen_string_literal: true
require 'pathname'
require_relative 'spmv_full_review'

module ValidationAudit
  module SpmvFullExport
    module_function

    METHOD_FILES = %w[
      tools/validation_audit/spmv_work_count.rb
      tools/validation_audit/spmv_full_review.rb
      tools/validation_audit/export_spmv_full.rb
      tools/validation_audit/inventory.rb
      test/test_spmv_work_count.rb
      test/test_spmv_full_review.rb
      test/test_export_spmv_full.rb
    ].freeze

    def check_completion!(completion, verification)
      unless completion.fetch('status') == 'complete' && completion.fetch('full_scope_accounted_for') == true &&
          completion.fetch('remaining').zero? && completion.fetch('evidence_verified') == true &&
          completion.fetch('new_failures').empty? && completion.fetch('program_changes') == 0
        raise 'Full static review is not complete'
      end
      %w[population reused_pilot_reviews new_reviews remaining review_sha256
         legacy_records_without_compilation_counter program_executions benchmark_runs].each do |key|
        raise "Completion differs from current verification: #{key}" unless completion.fetch(key) == verification.fetch(key)
      end
      raise 'Current evidence verification is incomplete' unless verification.fetch('evidence_verified') == true
      raise 'Unexpected execution activity' unless %w[program_executions benchmark_runs].all? { |key| completion.fetch(key) == 0 }
    end

    def checked_json(path)
      raise "Not a regular evidence file: #{path}" unless File.file?(path) && !File.symlink?(path)
      bytes = File.binread(path)
      JSON.parse(bytes)
      bytes
    end

    # Only explicitly selected JSON evidence is copied. In particular, local
    # source trees, binaries, caches and complete inspection dumps cannot enter
    # the bundle through a recursive directory copy.
    def write_bundle(destination:, sources:, summary:, method:)
      raise 'Refusing to overwrite full static review export' if File.exist?(destination) || File.symlink?(destination)
      reserved = %w[export.json method-files.json]
      contents = sources.to_h do |relative, path|
        unless relative.end_with?('.json') && !relative.start_with?('/') &&
            relative.split('/').none? { |part| ['', '.', '..'].include?(part) } && !reserved.include?(relative)
          raise "Unsafe export filename: #{relative}"
        end
        [relative, checked_json(path)]
      end
      contents['method-files.json'] = JSON.pretty_generate(method) + "\n"
      FileUtils.mkdir_p(destination)
      contents.each do |relative, bytes|
        path = File.join(destination, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(bytes) }
      end
      receipt = summary.merge('schema_version' => 1, 'exported_at' => Time.now.utc.iso8601,
        'files_sha256' => contents.sort.to_h { |relative, bytes| [relative, Digest::SHA256.hexdigest(bytes)] },
        'retained_bytes_excluding_receipt' => contents.values.sum(&:bytesize),
        'generated_source_copies' => 0, 'binaries' => 0, 'complete_disassembly_dumps' => 0)
      ValidationAudit.save(File.join(destination, 'export.json'), receipt)
      receipt
    end

    def run(workspace:, evidence:, destination:, pilot_directory:)
      reviewer = SpmvFullReview.new(workspace: workspace, evidence: evidence)
      completion_path = File.join(reviewer.root, 'completion.json')
      completion = ValidationAudit.read(completion_path)
      verification = reviewer.verify
      check_completion!(completion, verification)
      raise 'Delegation authorization is not pinned' unless completion.key?('delegation_authorization_sha256')
      pinned = {
        'completion.json' => completion_path,
        'authorization.json' => File.join(reviewer.root, 'authorization.json'),
        'delegation-authorization.json' => File.join(reviewer.root, 'delegation-authorization.json'),
        SpmvFullReview::INVENTORY => File.join(evidence, SpmvFullReview::INVENTORY),
        'spmv-release-transition.json' => File.join(evidence, 'spmv-release-transition.json')
      }
      {
        'authorization_sha256' => 'authorization.json',
        'delegation_authorization_sha256' => 'delegation-authorization.json',
        'inventory_sha256' => SpmvFullReview::INVENTORY
      }.each do |key, name|
        raise "Pinned export metadata differs: #{name}" unless ValidationAudit.sha(pinned.fetch(name)) == completion.fetch(key)
      end

      # The already-published pilot remains a shared dependency, not twelve
      # duplicated reviews. Check both the review and its source/inspection pack.
      pilot_directory = File.realpath(pilot_directory)
      pilot_files = %w[review.json preparation.json].to_h do |name|
        path = File.join(pilot_directory, name)
        digest = ValidationAudit.sha(path)
        raise 'Published pilot differs' unless digest == ValidationAudit.sha(File.join(evidence, 'spmv-work-count-pilot', name))
        [name, digest]
      end
      raise 'Pilot completion pin differs' unless pilot_files.fetch('review.json') == completion.fetch('pilot_review_sha256')

      rows, = reviewer.load_scope
      rows.each do |row|
        id = row.fetch('id')
        raise 'Unsafe run ID' unless id.match?(/\A[A-Za-z0-9_.-]+\z/)
        pinned["bindings/#{id}.json"] = File.join(evidence, 'bindings', id + '.json')
      end
      completion.fetch('review_sha256').each do |id, digest|
        path = File.join(reviewer.root, 'reviews', id + '.json')
        raise 'Retained review changed during export' unless ValidationAudit.sha(path) == digest
        retained = ValidationAudit.read(path)
        pinned["reviews/#{id}.json"] = path
        pinned["packs/#{id}.json"] = File.join(reviewer.root, 'packs', id + '.json')
        input = retained.fetch('review_input_sha256')
        pinned["review-inputs/#{input}.json"] = File.join(reviewer.root, 'review-inputs', input + '.json')
      end
      %w[delegation-pilot delegated-proposals].each do |directory|
        Dir.glob(File.join(reviewer.root, directory, '*.json')).sort.each do |path|
          pinned[File.join(directory, File.basename(path))] = path
        end
      end
      experiment = File.expand_path('../..', __dir__)
      method = { 'repository' => 'experiment',
        'files_sha256' => METHOD_FILES.to_h { |name| [name, ValidationAudit.sha(File.join(experiment, name))] },
        'note' => 'Exact method-file hashes; unrelated worktree changes are not part of this method.' }
      summary = completion.slice('status', 'population', 'reused_pilot_reviews', 'new_reviews', 'remaining',
        'new_failures', 'program_executions', 'benchmark_runs', 'program_changes',
        'legacy_records_without_compilation_counter', 'legacy_metadata_note', 'interpretation').merge(
          'reused_pilot' => { 'directory' => Pathname.new(pilot_directory).relative_path_from(Pathname.new(File.expand_path(destination))).to_s,
            'files_sha256' => pilot_files },
          'retention' => 'Exact accepted inputs, immutable per-ID reviews, pinned source/build/executable metadata, selected compiled excerpts, and raw delegated proposals. Original program files remain in their source repository; binaries and full dumps are excluded.')
      receipt = write_bundle(destination: destination, sources: pinned, summary: summary, method: method)
      puts JSON.pretty_generate(receipt.reject { |key, _| key == 'files_sha256' })
      receipt
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: export_spmv_full.rb WORKSPACE EVIDENCE NEW_DESTINATION PUBLISHED_PILOT_DIRECTORY' unless ARGV.size == 4
  ValidationAudit::SpmvFullExport.run(workspace: ARGV[0], evidence: ARGV[1], destination: ARGV[2], pilot_directory: ARGV[3])
end
