# frozen_string_literal: true

require "set"

# Select observations without changing their prompts, budgets, or execution order.
module ExperimentSelection
  module_function

  def configurations(benchmarks:, models:, backends:, repetitions:)
    (1..repetitions).flat_map do |repetition|
      backends.flat_map do |backend|
        models.flat_map { |model| benchmarks.map { |benchmark| [benchmark, model, backend, repetition] } }
      end
    end
  end

  def id(configuration)
    benchmark, model, backend, repetition = configuration
    "#{benchmark}_#{model}_#{backend}_r#{repetition}"
  end

  def select(configurations, path: nil)
    return configurations unless path
    requested = File.readlines(path, chomp: true).map(&:strip)
    raise ArgumentError, "Run-ID file must contain nonempty IDs" if requested.empty? || requested.any?(&:empty?)
    raise ArgumentError, "Duplicate IDs in run-ID file" unless requested.uniq.size == requested.size
    unknown = requested - configurations.map { |configuration| id(configuration) }
    raise ArgumentError, "Run IDs outside the selected experiment: #{unknown.join(', ')}" unless unknown.empty?
    selected = requested.to_set
    configurations.select { |configuration| selected.include?(id(configuration)) }
  end

  def completed_duration(directory)
    path = File.join(directory, "timing.txt")
    return nil unless File.file?(path)
    line = File.readlines(path).find { |value| value.start_with?("Duration:") }
    match = line&.match(/\ADuration:\s+(\S+)\s+seconds\s*\z/)
    duration = Float(match[1]) if match
    unless duration && duration.finite? && duration >= 0
      raise ArgumentError, "Invalid completed timing record: #{path}"
    end
    duration
  end
end
