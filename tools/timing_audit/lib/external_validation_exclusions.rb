# frozen_string_literal: true

require "json"
require "digest"
require_relative "../../../validation_helper"

# An additive, source-pinned external-validation disposition. Original native
# validation and performance evidence remain immutable. This format deliberately
# cannot relabel a compilation/run/internal failure as an external mismatch.
class ExternalValidationExclusions
  CASE_ID = "unstructured-boundary-v1"
  ARGS = %w[-v -r -n 32 -i 512].freeze
  STAGES = { "basic_para" => true, "validation_build" => true, "validation_run" => true,
             "internal_validation" => true, "output_comparison" => false }.freeze
  attr_reader :path, :digest, :data, :records

  def initialize(path)
    @path = File.realpath(path)
    @digest = Digest::SHA256.file(@path).hexdigest
    @data = JSON.parse(File.read(@path))
    raise "Unsupported external-validation exclusions" unless @data.fetch("schema_version") == 1
    definition = @data.fetch("case")
    unless definition.fetch("id") == CASE_ID && definition.fetch("benchmark") == "unstructured" &&
        definition.fetch("args") == ARGS && definition.fetch("mpi_ranks") == 4 &&
        @data.fetch("failed_stage") == "output_comparison"
      raise "External-validation case or failed stage differs"
    end
    authorization = @data.fetch("authorization")
    unless authorization.fetch("source") == "user" && !authorization.fetch("statement").strip.empty?
      raise "External-validation disposition lacks user authorization"
    end
    comparator = File.expand_path("../../../validation_helper.rb", __dir__)
    raise "External comparator changed" unless Digest::SHA256.file(comparator).hexdigest == @data.fetch("validation_helper_sha256")
    reference = @data.fetch("reference")
    @reference_output = reference.fetch("stdout")
    raise "Reference output digest differs" unless Digest::SHA256.hexdigest(@reference_output) == reference.fetch("stdout_sha256")
    unless @reference_output.include?("Validation: PASSED") && @reference_output.include?("=== RESULTS ===") && @reference_output.include?("=== END RESULTS ===")
      raise "Invalid external-validation reference"
    end
    list = @data.fetch("records")
    @records = list.to_h { |record| [record.fetch("id"), record] }
    unless !list.empty? && list.size == @data.fetch("record_count") && @records.size == list.size && @records.keys == @records.keys.sort
      raise "External-validation exclusion IDs are empty, duplicated or unordered"
    end
    @records.each { |id, record| verify_record!(id, record) }
  end

  def ids_for(source_commit:, ids:)
    selected = @records.keys & ids
    selected.each do |id|
      raise "External-validation source revision differs: #{id}" unless @records.fetch(id).fetch("source_commit") == source_commit
    end
    selected.sort
  end

  def reason(id)
    "Output comparison FAILED (#{CASE_ID}): #{@records.fetch(id).fetch('result').fetch('comparison').last}"
  end

  private

  def verify_record!(id, record)
    unless id.match?(/\Aunstructured_.+_(mpi|hybrid)_r[1-5]\z/) && record.fetch("source_commit").match?(/\A[0-9a-f]{40}\z/) &&
        record.fetch("source_path").match?(%r{\A\d{8}-\d{6}/#{Regexp.escape(id)}\z}) && record.fetch("stages") == STAGES
      raise "External-validation record identity or stages differ: #{id}"
    end
    result = record.fetch("result")
    %w[id source_commit source_path].each do |key|
      raise "External result identity differs: #{id}" unless result.fetch(key) == record.fetch(key)
    end
    unless result.fetch("arguments") == ARGS && result.fetch("passed") == false && result.fetch("internal_validation") == true &&
        result.dig("execution", "success") == true && result.dig("execution", "exit_code") == 0 && result.dig("execution", "timed_out") == false
      raise "Record is not a completed external-comparison failure: #{id}"
    end
    raise "Native result digest differs: #{id}" unless Digest::SHA256.hexdigest(JSON.pretty_generate(result) + "\n") == record.fetch("result_sha256")
    output = record.fetch("stdout")
    raise "External output digest differs: #{id}" unless Digest::SHA256.hexdigest(output) == result.fetch("output_sha256")
    unless output.include?("Validation: PASSED") && !output.include?("Validation: FAILED") && !output.include?("Validation fail")
      raise "External record actually failed internal validation: #{id}"
    end
    comparison = validate(@reference_output, output, "unstructured")
    unless comparison.first == false && comparison == result.fetch("comparison")
      raise "External comparison does not reproduce: #{id}"
    end
  end
end
