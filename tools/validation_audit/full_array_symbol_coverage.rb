# frozen_string_literal: true
require_relative 'full_array_capture'

module ValidationAudit
  module FullArraySymbolCoverage
    module_function
    def scan(evidence)
      plan_path = File.join(evidence, 'full-array-pilot-01/plan.json')
      plan = ValidationAudit.read(plan_path)
      destination = File.join(evidence, 'full-array-symbol-coverage-01.json')
      raise 'Coverage already retained' if File.exist?(destination)
      source_rows = plan.fetch('groups').map { |g| g.fetch('benchmark') }.uniq.flat_map do |benchmark|
        ValidationAudit.read(File.join(evidence, "inventory-#{benchmark}.json")).fetch('rows')
      end.to_h { |r| [r.fetch('id'), r] }
      ids = plan.fetch('groups').flat_map { |g| g.fetch('full_ids') }.sort
      queue = Queue.new
      ids.each { |id| queue << id }
      8.times { queue << nil }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rows = 8.times.map do
        Thread.new do
          result = []
          while (id = queue.pop)
            path = File.join(evidence, 'bindings', id + '.json')
            binding = ValidationAudit.read(path)
            raise "Changed binding #{id}" unless binding.fetch('source_files') == source_rows.fetch(id).fetch('source_files') &&
              ValidationAudit.sha(binding.fetch('executable')) == binding.fetch('binary_sha256')
            output, error, status = Open3.capture3('nm', '--defined-only', binding.fetch('executable'))
            raise error unless status.success?
            symbols = output.lines.filter_map do |line|
              address, type, name = line.split
              { 'address' => address, 'type' => type, 'name' => name } if name&.include?('print_results')
            end
            helper = binding.dig('source_files', 'common/results_output.hpp', 'sha256')
            supported = helper == FullArrayCapture::HELPER_SHA && symbols.any? { |s| FullArrayCapture::SYMBOLS.key?(s.fetch('name')) }
            result << { 'id' => id, 'binding_sha256' => ValidationAudit.sha(path),
              'binary_sha256' => binding.fetch('binary_sha256'), 'helper_sha256' => helper,
              'symbols' => symbols, 'canonical_observer_supported' => supported }
          end
          result
        end
      end.flat_map(&:value).sort_by { |r| r.fetch('id') }
      report = { 'plan_sha256' => ValidationAudit.sha(plan_path), 'population' => ids.size,
        'method_sha256' => ValidationAudit.sha(__FILE__), 'rows' => rows,
        'unsupported_ids' => rows.reject { |r| r.fetch('canonical_observer_supported') }.map { |r| r.fetch('id') },
        'seconds' => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
        'checked_at' => Time.now.utc.iso8601, 'program_runs' => 0, 'compilations' => 0,
        'scope' => 'Read-only ELF symbol and source-binding coverage, not numerical correctness.' }
      ValidationAudit.save(destination, report)
      puts JSON.pretty_generate(report.reject { |k, _| k == 'rows' })
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: full_array_symbol_coverage.rb EVIDENCE' unless ARGV.size == 1
  ValidationAudit::FullArraySymbolCoverage.scan(ARGV.first)
end
