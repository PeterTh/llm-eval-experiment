# frozen_string_literal: true

module LocalEvaluation
  module ComparisonPolicy
    FLOYD_INTEGER_HASH = 'floyd-integer-hash-v1'
    module_function

    def identifier(benchmark)
      benchmark == 'floydwarshall' ? FLOYD_INTEGER_HASH : nil
    end

    # Distances are exact integers. This checks existing result bytes, not time,
    # path/predecessor state, or floating-point hashes. Reference hashes must be
    # produced by the unchanged reference with the same integer representation.
    def integer_hashes(reference, output)
      parse = lambda do |text|
        section = text.split('=== RESULTS ===', 2)[1]&.split('=== END RESULTS ===', 2)&.first
        next nil unless section
        objects = section.split('Name: ').drop(1)
        next nil if objects.empty?
        parsed = objects.map do |object|
          lines = object.lines.map(&:strip)
          hashes = lines.grep(/\AHash: /)
          next nil unless hashes.size == 1 && hashes.first.match?(/\AHash: [0-9a-f]{16}\z/)
          [lines.first, hashes.first.delete_prefix('Hash: ')]
        end
        parsed.any?(&:nil?) ? nil : parsed
      end
      expected = parse.call(reference)
      actual = parse.call(output)
      return [false, 'Exact integer comparison lacks a well-formed reference hash.'] unless expected
      return [false, 'Exact integer comparison lacks a well-formed result hash.'] unless actual
      return [false, 'Exact integer comparison object names/count differ.'] unless expected.map(&:first) == actual.map(&:first)
      expected.zip(actual).each do |ref, got|
        return [false, "Exact integer result mismatch for #{ref.first}: full-result hash #{got.last} differs from reference #{ref.last}."] unless ref.last == got.last
      end
      [true, 'Exact integer full-result hashes match.']
    end
  end
end
