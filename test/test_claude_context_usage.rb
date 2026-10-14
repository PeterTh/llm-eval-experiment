# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/claude_context_usage"

class ClaudeContextUsageTest < Minitest::Test
  def test_deduplicates_streamed_messages_and_uses_final_output_total
    events, observation = fixture([request("a", input: 2, cache: 80_000, hour: 10_000, output: 1234)])
    events.insert(1, Marshal.load(Marshal.dump(events.first)))
    result = ClaudeContextUsage.parse(events, observation: observation)
    assert_equal 1, result.fetch("requests")
    assert_equal 1234, result.dig("bands", "short", "output_tokens")
    assert_equal 1, result.dig("bands", "short", "streamed_output_lower_bound")
    assert_equal "native_total_in_single_observed_band", result.fetch("output_band_evidence")
    assert_equal 1_000_000, result.fetch("cache_write_surcharge_nanodollars")
    refute result.fetch("per_request_output_available")
  end

  def test_threshold_counts_cache_reads_and_both_cache_write_lifetimes
    requests = [request("a", input: 2, cache: 89_998, five: 5000, hour: 5000, output: 100),
      request("b", input: 2, cache: 89_999, five: 5000, hour: 5000, output: 200)]
    events, observation = fixture(requests)
    result = ClaudeContextUsage.parse(events, observation: observation)
    assert_equal 100_000, result.dig("bands", "short", "max_request_input_tokens")
    assert_equal 100_001, result.dig("bands", "long", "max_request_input_tokens")
    assert_equal 100, result.dig("bands", "short", "output_tokens")
    assert_equal 200, result.dig("bands", "long", "output_tokens")
    assert_equal "derived_from_reported_list_cost_and_native_output_total", result.fetch("output_band_evidence")
    assert_equal 3_750_000, result.fetch("cache_write_surcharge_nanodollars")
    assert_equal result.fetch("native_list_cost_nanodollars") - 3_750_000, result.fetch("comparison_cost_nanodollars")
  end

  def test_all_long_requests_use_the_native_total_in_the_long_band
    events, observation = fixture([request("a", input: 3, cache: 100_000, output: 987)])
    result = ClaudeContextUsage.parse(events, observation: observation)
    assert_equal 987, result.dig("bands", "long", "output_tokens")
    assert_equal 0, result.dig("bands", "short", "output_tokens")
    assert_equal "native_total_in_single_observed_band", result.fetch("output_band_evidence")
  end

  def test_rejects_changed_input_or_cache_lifetime_counters
    events, observation = fixture([request("a", input: 2, hour: 1000, output: 200)])
    duplicate = Marshal.load(Marshal.dump(events.first))
    duplicate["message"]["usage"]["input_tokens"] = 3
    assert_raises(ClaudeContextUsage::Invalid) { ClaudeContextUsage.parse(events.insert(1, duplicate), observation: observation) }
    events.delete_at(1)
    events.first["message"]["usage"]["cache_creation"]["ephemeral_1h_input_tokens"] = 999
    assert_raises(ClaudeContextUsage::Invalid) { ClaudeContextUsage.parse(events, observation: observation) }
  end

  def test_rejects_incomplete_request_coverage
    events, observation = fixture([request("a", input: 2, output: 200), request("b", input: 3, output: 300)])
    events.delete_at(0)
    error = assert_raises(ClaudeContextUsage::Invalid) { ClaudeContextUsage.parse(events, observation: observation) }
    assert_match(/do not reconcile/, error.message)
  end

  def test_rejects_other_pricing_modes_or_models
    [[:provider, "partner"], [:costBasis, "negotiated"]].each do |key, value|
      events, observation = fixture([request("a", input: 2, output: 200)])
      events.last["modelUsage"][ClaudeContextUsage::MODEL][key.to_s] = value
      assert_raises(ClaudeContextUsage::Invalid) { ClaudeContextUsage.parse(events, observation: observation) }
    end
    %w[service_tier inference_geo].each do |key|
      events, observation = fixture([request("a", input: 2, output: 200)])
      events.first["message"]["usage"][key] = "different"
      assert_raises(ClaudeContextUsage::Invalid) { ClaudeContextUsage.parse(events, observation: observation) }
    end
    events, observation = fixture([request("a", input: 2, output: 200)])
    events.last["fast_mode_state"] = "on"
    assert_raises(ClaudeContextUsage::Invalid) { ClaudeContextUsage.parse(events, observation: observation) }
  end

  def test_rejects_impossible_or_fractional_price_implied_output_counts
    [1, -800_000, 4_000_000].each do |extra_nanos|
      events, observation = fixture([request("a", input: 2, output: 200), request("b", cache: 100_001, output: 300)])
      price = (ClaudeContextUsage.nanodollars(observation.fetch("reported_cost_usd")) + extra_nanos) / 1_000_000_000.0
      observation["reported_cost_usd"] = price
      events.last["total_cost_usd"] = price
      events.last["modelUsage"][ClaudeContextUsage::MODEL]["costUSD"] = price
      assert_raises(ClaudeContextUsage::Invalid) { ClaudeContextUsage.parse(events, observation: observation) }
    end
  end

  def test_single_band_prices_are_checked_independently_of_output_recovery
    events, observation = fixture([request("a", input: 2, output: 200)])
    price = observation.fetch("reported_cost_usd") + 0.000002
    observation["reported_cost_usd"] = price
    events.last["total_cost_usd"] = price
    events.last["modelUsage"][ClaudeContextUsage::MODEL]["costUSD"] = price
    error = assert_raises(ClaudeContextUsage::Invalid) { ClaudeContextUsage.parse(events, observation: observation) }
    assert_match(/unused band/, error.message)
  end

  def test_float_noise_does_not_change_integer_nanodollars
    assert_equal 8_495_900, ClaudeContextUsage.nanodollars(0.008495900000000001)
    assert_raises(ClaudeContextUsage::Invalid) { ClaudeContextUsage.nanodollars(-1) }
    assert_raises(ClaudeContextUsage::Invalid) { ClaudeContextUsage.nanodollars(Float::NAN) }
  end

  private

  def request(id, input: 0, cache: 0, five: 0, hour: 0, output:)
    { "id" => id, "input_tokens" => input, "cache_read_input_tokens" => cache,
      "cache_creation_5m_tokens" => five, "cache_creation_1h_tokens" => hour, "output_tokens" => output }
  end

  def fixture(requests)
    native = { "inputTokens" => 0, "cacheReadInputTokens" => 0, "cacheCreationInputTokens" => 0,
      "outputTokens" => 0, "provider" => "firstParty", "costBasis" => "list" }
    cost = 0
    events = requests.map do |request|
      native["inputTokens"] += request.fetch("input_tokens")
      native["cacheReadInputTokens"] += request.fetch("cache_read_input_tokens")
      native["cacheCreationInputTokens"] += request.values_at("cache_creation_5m_tokens", "cache_creation_1h_tokens").sum
      native["outputTokens"] += request.fetch("output_tokens")
      length = ClaudeContextUsage::INPUT_KEYS.sum { |key| request.fetch(key) }
      rates = length > 100_000 ? ClaudeContextUsage::LONG_RATES : ClaudeContextUsage::SHORT_RATES
      cost += rates.sum { |key, rate| request.fetch(key) * rate }
      { "type" => "assistant", "session_id" => "session", "message" => {
        "id" => request.fetch("id"), "model" => ClaudeContextUsage::MODEL, "usage" => {
          "input_tokens" => request.fetch("input_tokens"), "cache_read_input_tokens" => request.fetch("cache_read_input_tokens"),
          "cache_creation_input_tokens" => request.values_at("cache_creation_5m_tokens", "cache_creation_1h_tokens").sum,
          "cache_creation" => { "ephemeral_5m_input_tokens" => request.fetch("cache_creation_5m_tokens"),
            "ephemeral_1h_input_tokens" => request.fetch("cache_creation_1h_tokens") },
          "output_tokens" => 1, "service_tier" => "standard", "inference_geo" => "not_available"
        } } }
    end
    native["costUSD"] = cost / 1_000_000_000.0
    events << { "type" => "result", "session_id" => "session", "modelUsage" => { ClaudeContextUsage::MODEL => native },
      "fast_mode_state" => "off", "usage" => { "speed" => "standard" }, "total_cost_usd" => native.fetch("costUSD") }
    observation = { "id" => "fixture", "session_id" => "session", "version" => "2.1.296",
      "sha256" => { "output.txt" => "a" * 64 }, "reported_cost_usd" => native.fetch("costUSD"),
      "token_counts" => ClaudeGenerationObservation::COUNTERS.to_h { |key, native_key| [key, native.fetch(native_key)] } }
    [events, observation]
  end
end
