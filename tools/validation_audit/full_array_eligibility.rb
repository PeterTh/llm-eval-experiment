# frozen_string_literal: true
require_relative 'full_array_offline_support'

module ValidationAudit
  # A small derived view for the existing external-validation presentation.
  # The complete observation, comparison and failure bytes remain in the sweep.
  module FullArrayEligibility
    STAGES = %w[basic_para validation_build validation_run internal_validation output_comparison]
      .to_h { |stage| [stage, stage != 'output_comparison'] }.freeze
    AUTHORIZATION = { 'source' => 'user',
      'statement' => 'Apply the approved validation-strengthening checks; subsume failures into the existing failed external validation category. Preserve original source and performance measurements.' }.freeze
    module_function

    def definition(benchmark, groups)
      own = groups.select { |group| group.fetch('benchmark') == benchmark }
      arguments = own.map { |group| group.fetch('args') }.uniq
      raise 'Missing or backend-dependent full-array case' unless arguments.size == 1 &&
        own.map { |group| group.fetch('backend') }.sort == %w[cuda hybrid mpi omp]
      { 'id' => "full-array-#{benchmark}-v1", 'benchmark' => benchmark,
        'args' => arguments.first, 'comparison' => 'complete-arrays-and-existing-summary', 'timeout' => 30 }
    end

    def reason(comparison)
      raise 'Passing comparison cannot exclude a program' unless comparison.fetch('passed') == false
      parts = comparison.fetch('arrays').filter_map do |array|
        next if array.fetch('mismatches').zero?
        "#{array.fetch('name')}: #{array.fetch('mismatches')}/#{array.fetch('elements')} values exceed absolute tolerance " \
          "#{array.fetch('absolute_tolerance')} (maximum absolute error #{array.fetch('maximum_absolute_error')})"
      end
      sparse = comparison.fetch('sparse_comparison')
      parts << "Existing summary check: #{sparse.last.strip}" unless sparse.first
      raise 'Failure has neither numerical nor summary mismatch' if parts.empty?
      parts.join('; ')
    end

    def rows(record, location, definition)
      comparison = record.fetch('comparison')
      source = comparison.fetch('source')
      id = record.fetch('id')
      raise 'Eligibility identity differs' unless id == source.fetch('id') && source.fetch('benchmark') == definition.fetch('benchmark')
      result = source.slice('id', 'source_commit', 'source_path').merge(
        'definition' => definition, 'passed' => false, 'performance_measurement' => false,
        'comparison' => [false, reason(comparison)], 'full_array_comparison_sha256' => record.fetch('comparison_sha256'),
        'raw_evidence' => location)
      digest = FullArrayOffline.json_digest(result)
      stdout = record.fetch('logs').fetch('stdout')
      exclusion = source.slice('id', 'source_commit', 'source_path', 'validation_record').merge(
        'case_id' => definition.fetch('id'), 'stages' => STAGES, 'result' => result, 'result_sha256' => digest, 'stdout' => stdout)
      evidence = { 'id' => id, 'result' => result, 'result_sha256' => digest, 'logs' => { 'stdout' => stdout } }
      [exclusion, evidence]
    end

    def registry(definition, reference, exclusions)
      ids = exclusions.map { |row| row.fetch('id') }
      raise 'Unordered or duplicate full-array exclusions' unless ids == ids.uniq.sort
      { 'schema_version' => 3, 'kind' => 'full-array-external-validation', 'case' => definition,
        'record_count' => ids.size, 'failed_stage' => 'output_comparison', 'authorization' => AUTHORIZATION,
        'reference' => { 'stdout' => reference.fetch('stdout'),
          'stdout_sha256' => Digest::SHA256.hexdigest(reference.fetch('stdout')) }, 'records' => exclusions }
    end

    def location(root, path, line, digest)
      relative = path.delete_prefix(root + '/')
      unless path.start_with?(root + '/') && relative.split('/').none? { |part| ['', '.', '..'].include?(part) } &&
          line.is_a?(Integer) && line.positive? && digest.match?(/\A[0-9a-f]{64}\z/)
        raise 'Unsafe full-array evidence location'
      end
      { 'directory' => File.basename(root), 'path' => relative, 'line' => line, 'line_sha256' => digest }
    end
  end
end
