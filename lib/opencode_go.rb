# frozen_string_literal: true
require "json"
require "net/http"
require "time"
require_relative "opencode_harness"

# Read-only Go admission checks, always outside generation timing. Does not
# enable balance fallback, change workspace settings, or select another model.
module OpenCodeGo
  Invalid = OpenCodeHarness::Invalid
  MAX_WINDOW_PERCENT = 95
  module_function

  def check(auth_file:, model:, requester: nil, now: Time.now)
    profile = OpenCodeHarness::CAMPAIGN_PROFILES.values.find { |entry| entry["model"] == model && entry["access"] == "opencode-go" }
    raise Invalid, "Unapproved Go model" unless profile
    auth = OpenCodeHarness.credential(auth_file, model: model)
    requester ||= ->(path) { request(path, auth.fetch("opencode-go").fetch("key")) }
    data = requester.call("/zen/go/v1/usage")
    models = requester.call("/inference/go/v1/models").fetch("data")
    model_id = model.split("/", 2).last
    raise Invalid, "Requested Go model is no longer available: #{model_id}" unless models.any? { |entry| entry["id"] == model_id }
    windows = validate_usage(data.fetch("usage"))
    free = profile.fetch("free_only")
    raise Invalid, "Free-only route changed" if free && !model_id.end_with?("-free")
    blocked = free ? [] : windows.select { |_, value| value.fetch("status") != "ok" || value.fetch("percent") >= MAX_WINDOW_PERCENT }.keys
    resume = blocked.map { |name| Time.iso8601(windows.fetch(name).fetch("resetsAt")) }.max
    { "checked_at" => now.utc.iso8601, "model" => model, "free_only" => free,
      "available" => true, "usage" => windows, "maximum_window_percent" => MAX_WINDOW_PERCENT,
      "blocked_windows" => blocked, "allowed" => blocked.empty?, "resume_not_before" => resume && (resume + 60).utc.iso8601 }
  rescue KeyError, JSON::ParserError, ArgumentError, TypeError => e
    raise Invalid, "Invalid Go access response: #{e.message}"
  end

  def validate_usage(usage)
    %w[rolling weekly monthly].to_h do |name|
      window = usage.fetch(name)
      percent = window.fetch("percent")
      raise Invalid, "Invalid Go #{name} percentage" unless percent.is_a?(Numeric) && percent.finite? && percent >= 0
      raise Invalid, "Invalid Go #{name} status" unless %w[ok rate-limited].include?(window.fetch("status"))
      Time.iso8601(window.fetch("resetsAt"))
      [name, window.slice("status", "percent", "resetsAt")]
    end
  end

  def request(path, key)
    uri = URI("https://opencode.ai#{path}")
    message = Net::HTTP::Get.new(uri)
    message["Authorization"] = "Bearer #{key}"
    message["User-Agent"] = "llm-eval-opencode-go-admission/1.0"
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { |http| http.request(message) }
    # Never include request headers, credentials, or an unfiltered error body.
    raise Invalid, "Go access check #{path} returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  end
end
