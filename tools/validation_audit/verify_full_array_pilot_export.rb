# frozen_string_literal: true
require_relative 'full_array_offline_support'

module ValidationAudit
  module FullArrayPilotVerification
    module_function
    def run(destination, quiet: false)
      destination = File.realpath(destination)
      receipt = FullArrayOffline.read(File.join(destination, 'export.json'))
      receipt.fetch('files_sha256').each do |relative, digest|
        raise 'Unsafe export member' if relative.start_with?('/') || relative.split('/').include?('..')
        raise "Export member changed #{relative}" unless FullArrayOffline.sha(File.join(destination, relative)) == digest
      end
      records = File.readlines(File.join(destination, 'records.jsonl')).map { |line| JSON.parse(line) }
      references = FullArrayOffline.read(File.join(destination, 'references.json'))
      primary = records.select { |record| record.fetch('phase') == 'full-array-pilot-01' }
      raise 'Primary coverage changed' unless primary.size == receipt.fetch('pilot_checks')
      failed = []
      records.each do |record|
        comparison = record.fetch('comparison')
        observation = record.fetch('observation')
        benchmark = comparison.dig('source', 'benchmark')
        reference = references.fetch(benchmark)
        raise 'Comparison digest changed' unless Digest::SHA256.hexdigest(JSON.pretty_generate(comparison) + "\n") == record.fetch('comparison_sha256')
        raise 'Observation digest changed' unless Digest::SHA256.hexdigest(JSON.pretty_generate(observation) + "\n") == comparison.fetch('observation_sha256')
        stdout = record.fetch('logs').fetch('stdout')
        raise 'Output digest changed' unless Digest::SHA256.hexdigest(stdout) == observation.fetch('stdout_sha256')
        sparse = validate(reference.fetch('stdout'), stdout, benchmark)
        raise 'Sparse comparison changed' unless sparse == comparison.fetch('sparse_comparison')
        raise 'Inconsistent combined verdict' unless comparison.fetch('passed') ==
          (sparse.first && comparison.fetch('arrays').all? { |a| a.fetch('mismatches').zero? })
        next if comparison.fetch('passed')
        failed << record.fetch('id')
        lookup = record.fetch('failure_arrays')
        comparison.fetch('arrays').each do |array|
          objects = [reference.fetch('observation').fetch('id'), record.fetch('id')].map do |id|
            relative = lookup.fetch(id).fetch(array.fetch('name'))
            raise 'Unsafe witness member' unless relative.match?(%r{\Afailure-arrays/[a-f0-9]{64}\.json\z})
            witness = FullArrayOffline.read(File.join(destination, relative))
            hex = witness.fetch('values_hex')
            raise 'Malformed byte witness' unless hex.match?(/\A(?:[a-f0-9]{2})*\z/)
            bytes = [hex].pack('H*')
            raise 'Witness bytes changed' unless bytes.bytesize == witness.fetch('bytes') &&
              Digest::SHA256.hexdigest(bytes) == witness.fetch('sha256') && FullArrayOffline.fnv(bytes) == witness.fetch('fnv1a64')
            format = FullArrayOffline::SYMBOLS.values.find { |entry| entry.first == witness.fetch('dtype') }.fetch(2)
            values = bytes.unpack(format)
            raise 'Witness element count changed' unless values.size == witness.fetch('elements')
            [witness, values]
          end
          left, right = objects
          raise 'Witness/comparison binding changed' unless left.first.fetch('sha256') == array.fetch('reference_array_sha256') &&
            right.first.fetch('sha256') == array.fetch('actual_array_sha256')
          [[reference.fetch('observation'), reference.fetch('stdout'), left], [observation, stdout, right]].each do |capture, text, data|
            object = capture.fetch('objects').find { |o| o.fetch('name') == array.fetch('name') && o.fetch('sha256') == data.first.fetch('sha256') }
            raise 'Witness not bound to captured/printed output' unless object && object.fetch('dtype') == data.first.fetch('dtype') &&
              FullArrayOffline.output_objects(text).include?('name' => array.fetch('name'),
                'elements' => data.first.fetch('elements'), 'fnv1a64' => data.first.fetch('fnv1a64'))
          end
          epsilon = benchmark == 'roomsim' && array.fetch('name').include?('Distance') ? 5.0 : 1e-5
          replay = FullArrayOffline.compare_values(left.last, right.last, epsilon: epsilon)
          raise 'Complete failure comparison does not reproduce' unless replay == array.slice(*replay.keys)
        end
      end
      raise 'Failure scope changed' unless failed.uniq.sort == receipt.fetch('failed_ids').sort
      result = { 'verified_files' => receipt.fetch('files_sha256').size,
        'verified_records' => records.size, 'unique_generated_ids' => records.map { |r| r.fetch('id') }.uniq.size,
        'full_failure_arrays_reproduced_for' => failed.uniq.sort,
        'scope' => 'All retained hashes, sparse comparisons and complete pilot-failure numerical arrays verified without program execution. Successful full-array verdicts remain retained reports; bulk successful arrays are intentionally not duplicated.' }
      puts JSON.pretty_generate(result) unless quiet
      result
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise 'Usage: verify_full_array_pilot_export.rb EXPORT' unless ARGV.size == 1
  ValidationAudit::FullArrayPilotVerification.run(ARGV.first)
end
