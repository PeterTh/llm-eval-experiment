# frozen_string_literal: true

require "bigdecimal"
require_relative "claude_generation_observation"

# Recover context-band usage from retained Haiku 5.5 stream-json evidence.
# Input/TTL counters are reported per request. Streamed output counters are only
# lower bounds; the final modelUsage output total is authoritative. For a mixed
# session, the two output-band totals are uniquely recoverable from that total
# and the harness's list-price total after subtracting reported input charges.
# This is explicitly price-derived evidence, not reported per-request output.
module ClaudeContextUsage
  class Invalid < StandardError; end
  MODEL = "claude-haiku-5-5"
  THRESHOLD = 100_000
  RATE_DATE = "2026-10-14"
  PRICE_SOURCE = "https://platform.claude.com/docs/en/models/haiku-5-5/overview"
  POLICY_SOURCE = "https://platform.claude.com/docs/en/about-claude/pricing#long-context-pricing"
  # Integer nanodollars per token, equivalent to USD/MToken * 1000.
  SHORT_RATES = { "input_tokens" => 100, "cache_read_input_tokens" => 10,
    "cache_creation_5m_tokens" => 125, "cache_creation_1h_tokens" => 200, "output_tokens" => 500 }.freeze
  LONG_RATES = SHORT_RATES.transform_values { |value| value * 5 }.freeze
  INPUT_KEYS = SHORT_RATES.keys - ["output_tokens"]
  module_function

  def integer(value, label)
    raise Invalid, "Invalid nonnegative integer: #{label}" unless value.is_a?(Integer) && value >= 0
    value
  end

  def nanodollars(value)
    decimal = BigDecimal(value.to_s) * 1_000_000_000
    raise Invalid, "Invalid list-price total" unless decimal.finite? && decimal >= 0
    rounded = decimal.round
    raise Invalid, "List-price total is not on the documented nanodollar grid" unless (decimal - rounded).abs <= BigDecimal("0.001")
    rounded
  rescue ArgumentError
    raise Invalid, "Invalid list-price total"
  end

  def read(directory, version:)
    observation = ClaudeGenerationObservation.read(directory, model: MODEL, version: version)
    raise Invalid, "Usage unavailable" unless observation.fetch("usage_available")
    path = File.join(directory, "output.txt")
    events = File.foreach(path).lazy.filter_map { |line| JSON.parse(line) rescue nil }
    record = parse(events, observation: observation)
    raise Invalid, "Transcript changed while reading" unless Digest::SHA256.file(path).hexdigest == observation.fetch("sha256").fetch("output.txt")
    record
  end

  def parse(events, observation:)
    requests = {}
    terminal = nil
    events.each do |event|
      terminal = event if event["type"] == "result"
      next unless event["type"] == "assistant"
      message = event.fetch("message")
      next if message["model"] == "<synthetic>"
      raise Invalid, "Unexpected request model" unless message.fetch("model") == MODEL
      raise Invalid, "Request session changed" unless event.fetch("session_id") == observation.fetch("session_id")
      id = message.fetch("id")
      raise Invalid, "Missing request identity" unless id.is_a?(String) && !id.empty?
      usage = message.fetch("usage")
      raise Invalid, "Unexpected service tier" unless usage.fetch("service_tier") == "standard"
      raise Invalid, "Unsupported regional pricing" unless %w[global not_available].include?(usage.fetch("inference_geo"))
      cache = usage.fetch("cache_creation")
      inputs = {
        "input_tokens" => integer(usage.fetch("input_tokens"), "input_tokens"),
        "cache_read_input_tokens" => integer(usage.fetch("cache_read_input_tokens"), "cache_read_input_tokens"),
        "cache_creation_5m_tokens" => integer(cache.fetch("ephemeral_5m_input_tokens"), "5m cache"),
        "cache_creation_1h_tokens" => integer(cache.fetch("ephemeral_1h_input_tokens"), "1h cache")
      }
      raise Invalid, "Cache lifetime counters disagree" unless inputs.values_at("cache_creation_5m_tokens", "cache_creation_1h_tokens").sum ==
        integer(usage.fetch("cache_creation_input_tokens"), "cache_creation_input_tokens")
      lower = integer(usage.fetch("output_tokens"), "streamed output lower bound")
      if requests[id]
        raise Invalid, "Input counters changed for one request" unless requests.fetch(id).fetch("inputs") == inputs
        lower = [lower, requests.fetch(id).fetch("output_lower_bound")].max
      end
      requests[id] = { "inputs" => inputs, "output_lower_bound" => lower }
    end
    raise Invalid, "No request evidence" if requests.empty?
    raise Invalid, "Missing terminal usage" unless terminal
    raise Invalid, "Terminal session changed" unless terminal.fetch("session_id") == observation.fetch("session_id")
    raise Invalid, "Unexpected terminal models" unless terminal.fetch("modelUsage").keys == [MODEL]
    native = terminal.fetch("modelUsage").fetch(MODEL)
    raise Invalid, "Unsupported native cost basis" unless native.fetch("provider") == "firstParty" && native.fetch("costBasis") == "list"
    raise Invalid, "Unexpected fast mode" unless terminal.fetch("fast_mode_state") == "off" && terminal.fetch("usage").fetch("speed") == "standard"
    reported_nanos = nanodollars(terminal.fetch("total_cost_usd"))
    raise Invalid, "Native price totals disagree" unless reported_nanos == nanodollars(native.fetch("costUSD")) &&
      reported_nanos == nanodollars(observation.fetch("reported_cost_usd"))
    bands = %w[short long].to_h do |name|
      [name, INPUT_KEYS.to_h { |key| [key, 0] }.merge("requests" => 0, "max_request_input_tokens" => 0, "streamed_output_lower_bound" => 0)]
    end
    requests.each_value do |request|
      inputs = request.fetch("inputs")
      length = inputs.values.sum
      band = bands.fetch(length > THRESHOLD ? "long" : "short")
      inputs.each { |key, value| band[key] += value }
      band["requests"] += 1
      band["max_request_input_tokens"] = [band.fetch("max_request_input_tokens"), length].max
      band["streamed_output_lower_bound"] += request.fetch("output_lower_bound")
    end
    totals = observation.fetch("token_counts")
    ClaudeGenerationObservation::COUNTERS.each do |key, native_key|
      raise Invalid, "Native token totals changed: #{key}" unless integer(native.fetch(native_key), native_key) == totals.fetch(key)
    end
    checks = {
      "input_tokens" => bands.values.sum { |b| b.fetch("input_tokens") },
      "cache_read_input_tokens" => bands.values.sum { |b| b.fetch("cache_read_input_tokens") },
      "cache_creation_input_tokens" => bands.values.sum { |b| b.values_at("cache_creation_5m_tokens", "cache_creation_1h_tokens").sum }
    }
    checks.each { |key, value| raise Invalid, "Request inputs do not reconcile: #{key}" unless value == totals.fetch(key) }
    output = integer(totals.fetch("output_tokens"), "final output total")
    input_cost = bands.sum do |name, band|
      rates = name == "short" ? SHORT_RATES : LONG_RATES
      INPUT_KEYS.sum { |key| band.fetch(key) * rates.fetch(key) }
    end
    numerator = reported_nanos - input_cost - output * SHORT_RATES.fetch("output_tokens")
    delta = LONG_RATES.fetch("output_tokens") - SHORT_RATES.fetch("output_tokens")
    raise Invalid, "Price total does not imply an integer output-band split" unless numerator % delta == 0
    long_output = numerator / delta
    bands["long"]["output_tokens"] = long_output
    bands["short"]["output_tokens"] = output - long_output
    bands.each_value do |band|
      raise Invalid, "Impossible output-band total" unless band.fetch("output_tokens") >= band.fetch("streamed_output_lower_bound")
      raise Invalid, "Output assigned to an unused band" if band.fetch("requests").zero? && band.fetch("output_tokens") != 0
      band["inclusive_input_tokens"] = INPUT_KEYS.sum { |key| band.fetch(key) }
    end
    mixed = bands.values.all? { |band| band.fetch("requests").positive? }
    surcharge = bands.sum do |name, band|
      rates = name == "short" ? SHORT_RATES : LONG_RATES
      %w[cache_creation_5m_tokens cache_creation_1h_tokens].sum do |key|
        band.fetch(key) * (rates.fetch(key) - rates.fetch("input_tokens"))
      end
    end
    {
      "schema_version" => 1, "id" => observation.fetch("id"), "model" => MODEL,
      "session_id" => observation.fetch("session_id"), "claude_code_version" => observation.fetch("version"),
      "transcript_sha256" => observation.fetch("sha256").fetch("output.txt"),
      "pricing_as_of" => RATE_DATE, "pricing_source" => PRICE_SOURCE, "threshold_policy_source" => POLICY_SOURCE,
      "request_input_threshold_tokens" => THRESHOLD, "requests" => requests.size, "bands" => bands,
      "native_token_counts" => totals, "native_list_cost_nanodollars" => reported_nanos,
      "cache_write_surcharge_nanodollars" => surcharge,
      "comparison_cost_nanodollars" => reported_nanos - surcharge,
      "output_band_evidence" => mixed ? "derived_from_reported_list_cost_and_native_output_total" : "native_total_in_single_observed_band",
      "per_request_output_available" => false,
      "comparison_policy" => "Price cache creation as ordinary input, matching existing Claude comparisons; apply each request's documented context tier."
    }
  rescue KeyError => error
    raise Invalid, error.message
  end
end
