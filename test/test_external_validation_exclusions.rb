# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../tools/timing_audit/lib/external_validation_exclusions"

class ExternalValidationExclusionsTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("validation-exclusions-test-", "/tmp")
    @path = File.join(@tmp, "exclusions.json")
    @id = "unstructured_example_mpi_r1"
    @commit = "a" * 40
    @reference = "Validation: PASSED\n=== RESULTS ===\nName: ElementEnergy\nElements: 1024\nMin: -4.0\nHash: same\n=== END RESULTS ===\n"
    @output = @reference.sub("Min: -4.0", "Min: -4.1")
    result = { "id" => @id, "source_commit" => @commit, "source_path" => "20260101-000000/#{@id}",
      "arguments" => ExternalValidationExclusions::ARGS, "passed" => false, "internal_validation" => true,
      "execution" => { "success" => true, "exit_code" => 0, "timed_out" => false },
      "comparison" => validate(@reference, @output, "unstructured"), "output_sha256" => Digest::SHA256.hexdigest(@output) }
    record = result.slice("id", "source_commit", "source_path").merge("result" => result,
      "result_sha256" => Digest::SHA256.hexdigest(JSON.pretty_generate(result) + "\n"), "stdout" => @output,
      "stages" => ExternalValidationExclusions::STAGES)
    @data = { "schema_version" => 1, "record_count" => 1, "failed_stage" => "output_comparison",
      "case" => { "id" => ExternalValidationExclusions::CASE_ID, "benchmark" => "unstructured", "args" => ExternalValidationExclusions::ARGS, "mpi_ranks" => 4 },
      "authorization" => { "source" => "user", "statement" => "Count numerical failures as external validation failures." },
      "validation_helper_sha256" => Digest::SHA256.file(File.expand_path("../validation_helper.rb", __dir__)).hexdigest,
      "reference" => { "stdout" => @reference, "stdout_sha256" => Digest::SHA256.hexdigest(@reference) }, "records" => [record] }
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def load_registry
    File.write(@path, JSON.pretty_generate(@data) + "\n")
    ExternalValidationExclusions.new(@path)
  end

  def test_verified_failure_has_exact_source_and_external_stage
    registry = load_registry
    assert_equal [@id], registry.ids_for(source_commit: @commit, ids: [@id, "other"])
    assert_empty registry.ids_for(source_commit: @commit, ids: ["other"])
    assert_raises(RuntimeError) { registry.ids_for(source_commit: "b" * 40, ids: [@id]) }
    assert_match(/Output comparison FAILED/, registry.reason(@id))
    assert_equal 4, registry.records.fetch(@id).fetch("stages").values.count(true)
  end

  def test_rejects_other_failed_stage
    @data["failed_stage"] = "validation_run"
    assert_raises(RuntimeError) { load_registry }
  end

  def test_rejects_mutated_output
    @data.fetch("records").first["stdout"] = @reference
    assert_raises(RuntimeError) { load_registry }
  end

  def test_rejects_duplicate_ids
    @data["record_count"] = 2
    @data.fetch("records") << @data.fetch("records").first.dup
    assert_raises(RuntimeError) { load_registry }
  end

  def test_rejects_hash_only_difference_even_with_rebound_hashes
    record = @data.fetch("records").first
    record["stdout"] = @reference.sub("Hash: same", "Hash: other")
    record.fetch("result")["output_sha256"] = Digest::SHA256.hexdigest(record["stdout"])
    record.fetch("result")["comparison"] = [false, "hash differs"]
    record["result_sha256"] = Digest::SHA256.hexdigest(JSON.pretty_generate(record.fetch("result")) + "\n")
    assert_raises(RuntimeError) { load_registry }
  end
end
