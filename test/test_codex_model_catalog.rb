# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/codex_model_catalog"

class CodexModelCatalogTest < Minitest::Test
  def model
    { "slug" => "gpt-6.1-terra", "context_window" => 500000,
      "supported_reasoning_levels" => [{ "effort" => "medium" }, { "effort" => "ultra" }],
      "model_messages" => ["synthetic test instructions"], "future_native_field" => { "retained" => true } }
  end

  def cache
    { "client_version" => "0.160.1", "fetched_at" => Time.now.utc.iso8601(6), "models" => [model],
      "identity" => "synthetic-private-account-identity", "etag" => "native-cache-plumbing" }
  end

  def export(value = cache)
    CodexModelCatalog.from_cache(JSON.generate(value), version: "0.160.1", model: "gpt-6.1-terra", effort: "ultra", not_before: Time.now - 1)
  end

  def test_preserves_all_definitions_but_not_identity_or_cache_state
    content, receipt = export
    assert_equal({ "models" => [model] }, JSON.parse(content))
    refute_includes content, "identity"
    refute_includes content, "etag"
    assert_equal false, receipt.fetch("definitions_modified")
    assert_equal 0, receipt.fetch("inferences_launched")
    assert_equal model, CodexModelCatalog.verify!(content, receipt, version: "0.160.1", model: "gpt-6.1-terra", effort: "ultra")
  end

  def test_wrong_version_stale_and_invalid_catalog_fail_closed
    [{ "client_version" => "0.160.2" }, { "fetched_at" => "2020-01-01T00:00:00Z" },
      { "fetched_at" => (Time.now + 60).utc.iso8601 }, { "models" => [] }, { "models" => [model, model] }].each do |change|
      assert_raises(CodexModelCatalog::Invalid) { export(cache.merge(change)) }
    end
  end

  def test_missing_requested_model_effort_context_and_instructions_fail
    [{ "slug" => "other" }, { "supported_reasoning_levels" => [] }, { "context_window" => 0 },
      { "model_messages" => [] }].each do |change|
      assert_raises(CodexModelCatalog::Invalid) { export(cache.merge("models" => [model.merge(change)])) }
    end
  end

  def test_snapshot_and_receipt_tampering_fail
    content, receipt = export
    [{ "catalog_sha256" => "f" * 64 }, { "catalog_bytes" => 1 }, { "source" => "invented" },
      { "selected_model_sha256" => "f" * 64 }, { "definitions_modified" => true }, { "inferences_launched" => 1 }].each do |change|
      assert_raises(CodexModelCatalog::Invalid) { CodexModelCatalog.verify!(content, receipt.merge(change), version: "0.160.1", model: "gpt-6.1-terra", effort: "ultra") }
    end
  end

  def test_publishing_is_atomic_read_only_and_never_overwrites
    Dir.mktmpdir("catalog-test-", "/tmp") do |root|
      path = File.join(root, "catalog.json")
      CodexModelCatalog.publish(path, "original")
      assert_equal "original", File.read(path)
      assert_equal 0444, File.stat(path).mode & 0777
      assert_raises(CodexModelCatalog::Invalid) { CodexModelCatalog.publish(path, "different") }
      assert_equal "original", File.read(path)
    end
  end

  def test_rpc_sends_only_metadata_requests
    script = <<~'RUBY'
      require "json"
      STDOUT.sync = true
      STDIN.each_line do |line|
        request = JSON.parse(line)
        method = request.fetch("method")
        abort "Inference not allowed" unless %w[initialize initialized model/list].include?(method)
        next if method == "initialized"
        result = method == "initialize" ? {} : { data: [{ model: "gpt-6.1-terra", supportedReasoningEfforts: [{ reasoningEffort: "ultra" }] }], nextCursor: nil }
        puts JSON.generate(id: request.fetch("id"), result: result)
      end
    RUBY
    result = CodexModelCatalog.list_models(["ruby", "-e", script])
    assert_equal "gpt-6.1-terra", CodexModelCatalog.require_advertised!(result, model: "gpt-6.1-terra", effort: "ultra").fetch("model")
    assert_raises(CodexModelCatalog::Invalid) { CodexModelCatalog.require_advertised!(result, model: "other", effort: "ultra") }
    assert_raises(CodexModelCatalog::Invalid) { CodexModelCatalog.require_advertised!(result, model: "gpt-6.1-terra", effort: "max") }
  end

  def test_dead_metadata_service_is_not_a_permissive_fallback
    assert_raises(CodexModelCatalog::Invalid) { CodexModelCatalog.list_models(["ruby", "-e", "exit 1"]) }
  end
end
