# frozen_string_literal: true
require "json"
require "digest"

# Policy for the unmodified, pinned OpenCode CLI. Keep its stock prompts and
# model adapters; match the local capabilities of the native harnesses.
module OpenCodeHarness
  VERSION = "1.19.3"
  BINARY_SHA256 = "179ca421d61eefeadfa0c50e084a6e79c1623734732f0f4593f81ccfd3ab7ee9"
  CAMPAIGN_PROFILES = {
    "gpt-6.1-sol-oc-medium" => {
      "model" => "openai/gpt-6.1-sol", "reasoning_effort" => "medium",
      "label" => "Sol 6.1 OpenCode medium", "slug" => "sol61-opencode-medium", "unit_slug" => "sol61-oc",
      "native_batch" => "20261006-204623", "native_profile" => "gpt-6.1-sol-medium"
    }.freeze,
    "gpt-6-luna-oc-medium" => {
      "model" => "openai/gpt-6-luna", "reasoning_effort" => "medium",
      "label" => "Luna 6 OpenCode medium", "slug" => "luna6-opencode-medium", "unit_slug" => "luna6-oc",
      "native_batch" => "20260929-135931", "native_profile" => "gpt-6-luna-medium"
    }.freeze,
    "deepseek-v4.1-flash-oc-high" => {
      "model" => "opencode-go/deepseek-v4.1-flash", "reasoning_effort" => "high",
      "label" => "DeepSeek V4.1 Flash OpenCode high", "slug" => "deepseek41-flash-opencode-high", "unit_slug" => "deepseek41-oc",
      "access" => "opencode-go", "free_only" => false
    }.freeze,
    "minimax-m3.1-flash-oc-medium" => {
      "model" => "opencode-go/minimax-m3.1-flash-free", "reasoning_effort" => "medium",
      "label" => "MiniMax M3.1 Flash OpenCode medium", "slug" => "minimax31-flash-opencode-medium", "unit_slug" => "minimax31-oc",
      "access" => "opencode-go", "free_only" => true,
      "definition" => "minimax-m3.1-flash-free.json"
    }.freeze,
    "claude-haiku-5.5-oc-medium" => {
      "model" => "opencode-go/claude-haiku-5-5", "reasoning_effort" => "medium",
      "label" => "Haiku 5.5 OpenCode medium", "slug" => "haiku55-opencode-medium", "unit_slug" => "haiku55-oc",
      "access" => "opencode-go", "free_only" => false,
      "native_batch" => "20261012-111947", "native_profile" => "claude-haiku-5.5-cc-medium"
    }.freeze,
    "beam-1.0-oc-medium" => {
      "model" => "opencode-go/beam-free", "reasoning_effort" => "medium",
      "label" => "Beam 1.0 OpenCode medium", "slug" => "beam10-opencode-medium", "unit_slug" => "beam10-oc",
      "access" => "opencode-go", "free_only" => true, "definition" => "beam-free.json"
    }.freeze
  }.freeze
  FORBIDDEN_TOOLS = %w[webfetch websearch task question plan_enter plan_exit].freeze
  LOCAL_TOOLS = %w[invalid bash read glob grep edit write todowrite skill apply_patch].freeze
  EVIDENCE_FILES = %w[opencode-config.txt opencode-session.txt opencode-events.txt opencode-process.txt].freeze
  FLAGS = {
    "OPENCODE_PURE" => "1", # bundled authentication stays; external plugins do not
    "OPENCODE_DISABLE_AUTOUPDATE" => "1", "OPENCODE_DISABLE_MODELS_FETCH" => "1",
    "OPENCODE_DISABLE_PROJECT_CONFIG" => "1", "OPENCODE_DISABLE_CLAUDE_CODE" => "1",
    "OPENCODE_DISABLE_EXTERNAL_SKILLS" => "1", "OPENCODE_DISABLE_LSP_DOWNLOAD" => "1",
    "DISABLE_TELEMETRY" => "1", "DO_NOT_TRACK" => "1", "HISTFILE" => "/dev/null"
  }.freeze
  OUTPUT_TOKEN_FLAG = "OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX"
  # Advertised limits in the pinned catalog / explicitly frozen model entry.
  # Verify them again against the stock server before allowing an inference.
  GO_OUTPUT_TOKEN_LIMITS = {
    "opencode-go/deepseek-v4.1-flash" => 384_000,
    "opencode-go/minimax-m3.1-flash-free" => 512_000,
    "opencode-go/claude-haiku-5-5" => 128_000,
    "opencode-go/beam-free" => 131_072
  }.freeze
  class Invalid < StandardError; end
  module_function

  def campaign_profile(name)
    CAMPAIGN_PROFILES.fetch(name) { raise Invalid, "Unapproved OpenCode campaign profile: #{name}" }
  end

  def config(model:, effort:)
    profile = CAMPAIGN_PROFILES.values.find { |entry| entry["model"] == model && entry["reasoning_effort"] == effort }
    raise Invalid, "Unapproved OpenCode model/access route" unless profile
    provider, model_id = model.split("/", 2)
    definition = profile["definition"] ? JSON.parse(File.read(File.join(__dir__, "opencode_models", profile.fetch("definition")))).fetch("config") : {}
    definition["options"] = reasoning_options(model, effort)
    { "$schema" => "https://opencode.ai/config.json", "model" => model, "small_model" => model,
      "default_agent" => "build", "autoupdate" => false, "share" => "disabled",
      "enabled_providers" => [provider], "plugin" => [], "mcp" => {}, "instructions" => [],
      "permission" => { "*" => "allow" }.merge(FORBIDDEN_TOOLS.to_h { |tool| [tool, "deny"] }),
      "provider" => { provider => { "whitelist" => [model_id], "models" => {
        model_id => definition
      } } },
      "agent" => { "build" => { "variant" => effort },
        "compaction" => { "model" => model, "variant" => effort } } }
  end

  def reasoning_options(model, effort)
    if model == "opencode-go/claude-haiku-5-5"
      # Stock 1.19.3 Anthropic adaptive-thinking variant, not an OAI option.
      { "thinking" => { "type" => "adaptive", "display" => "summarized" }, "effort" => effort }
    else
      { "reasoningEffort" => effort }
    end
  end

  def verify_reasoning!(resolved, model:, effort:)
    expected = reasoning_options(model, effort)
    raise Invalid, "Requested reasoning is unavailable" unless expected.all? { |key, value| resolved.dig("variants", effort, key) == value }
    raise Invalid, "Requested reasoning default differs" unless expected.all? { |key, value| resolved.dig("options", key) == value }
    if model == "opencode-go/claude-haiku-5-5"
      raise Invalid, "Haiku must use the stock Anthropic adapter" unless resolved.dig("api", "npm") == "@ai-sdk/anthropic"
      raise Invalid, "Unexpected Haiku reasoning override" if resolved.fetch("options").key?("reasoningEffort")
    end
  end

  def output_token_policy(model)
    limit = GO_OUTPUT_TOKEN_LIMITS[model]
    return nil unless limit
    { "mode" => "advertised_model_limit", "max_output_tokens" => limit,
      "environment_variable" => OUTPUT_TOKEN_FLAG }
  end

  def flags(model: nil)
    policy = output_token_policy(model)
    policy ? FLAGS.merge(OUTPUT_TOKEN_FLAG => policy.fetch("max_output_tokens").to_s) : FLAGS
  end

  def verify_output_token_policy!(evidence, model:)
    policy = evidence["output_token_policy"]
    if policy
      raise Invalid, "Unapproved output-token policy" unless policy == output_token_policy(model)
      raise Invalid, "Advertised output limit changed" unless evidence.dig("resolved_model", "limit", "output") == policy.fetch("max_output_tokens")
    end
    # Historical records retain their exact settings and report shape. An
    # override without a matching explicit policy is never silently accepted.
    expected = policy ? flags(model: model) : FLAGS
    raise Invalid, "OpenCode isolation flags differ" unless evidence["flags"] == expected
    policy
  end

  def environment(state, model: nil)
    # Do not inherit provider credentials, experimental flags, proxy settings,
    # remote servers, instruction overrides, or a user's OpenCode configuration.
    removed = ENV.keys.grep(/\A(?:OPENCODE_|XDG_|OPENAI_|ANTHROPIC_|CLAUDE_|CODEX_|GITHUB_TOKEN\z|GH_TOKEN\z|.*_API_KEY\z|.*_PROXY\z|.*_proxy\z)/).to_h { |key| [key, nil] }
    removed.merge(flags(model: model)).merge(
      "XDG_DATA_HOME" => File.join(state, "data"), "XDG_CONFIG_HOME" => File.join(state, "config"),
      "XDG_CACHE_HOME" => File.join(state, "cache"), "XDG_STATE_HOME" => File.join(state, "state"),
      "OPENCODE_TEST_HOME" => File.join(state, "home"),
      "OPENCODE_TEST_MANAGED_CONFIG_DIR" => File.join(state, "managed"),
      "TMPDIR" => File.join(state, "tmp"), "NO_COLOR" => "1"
    )
  end

  def auth_type(model)
    raise Invalid, "Unapproved OpenCode access route" unless CAMPAIGN_PROFILES.values.any? { |profile| profile["model"] == model }
    model.start_with?("opencode-go/") ? "opencode-go-subscription-api-key" : "openai-subscription-oauth"
  end

  def credential(path, model: "openai/gpt-6.1-sol")
    auth = JSON.parse(File.read(path))
    if auth_type(model) == "opencode-go-subscription-api-key"
      raise Invalid, "Only the isolated Go credential is permitted" unless auth.keys == ["opencode-go"] && auth.dig("opencode-go", "type") == "api"
      raise Invalid, "Incomplete Go credential" unless auth.dig("opencode-go", "key").is_a?(String) && !auth.dig("opencode-go", "key").empty?
      raise Invalid, "Go credential must be private" unless (File.stat(path).mode & 0077).zero?
    else
      raise Invalid, "Only OpenAI subscription OAuth is permitted" unless auth.keys == ["openai"] && auth.dig("openai", "type") == "oauth"
      %w[access refresh].each { |key| raise Invalid, "Incomplete subscription credential" unless auth.dig("openai", key).is_a?(String) && !auth.dig("openai", key).empty? }
    end
    auth
  end

  def verify_config!(actual, expected)
    expected.each do |key, value|
      next if key == "$schema"
      # OpenCode adds model defaults to the resolved provider, and normalizes
      # agent permissions. Check those independently against the native output.
      next if %w[agent provider].include?(key)
      raise Invalid, "OpenCode setting differs: #{key}" unless actual[key] == value
    end
    raise Invalid, "Unexpected custom commands" unless actual.fetch("command", {}).empty?
    raise Invalid, "Unexpected plugin origins" unless actual.fetch("plugin_origins", []).empty?
    raise Invalid, "Unexpected agent settings" unless actual.fetch("agent").keys.sort == expected.fetch("agent").keys.sort
    actual.fetch("agent").each_value do |agent|
      raise Invalid, "Custom agent prompt" if agent["prompt"]
    end
  end

  def verify_agent!(agent, model: nil)
    raise Invalid, "Not the stock build agent" unless agent["name"] == "build" && agent["native"] == true && !agent["prompt"]
    tools = agent.fetch("tools").select { |_, enabled| enabled }.keys.sort
    raise Invalid, "Unexpected enabled tools: #{tools - LOCAL_TOOLS}" unless (tools - LOCAL_TOOLS).empty?
    editing = model&.start_with?("opencode-go/") ? %w[edit write] : %w[apply_patch]
    raise Invalid, "Local build/edit tools unavailable" unless (%w[bash read glob grep] + editing - tools).empty?
    rules = agent.fetch("permission")
    (LOCAL_TOOLS + %w[external_directory doom_loop]).each do |tool|
      rule = rules.reverse.find { |item| [tool, "*"].include?(item["permission"]) && item["pattern"] == "*" }
      raise Invalid, "Local permission differs: #{tool}" unless rule && rule["action"] == "allow"
    end
    FORBIDDEN_TOOLS.each do |tool|
      rule = rules.reverse.find { |item| [tool, "*"].include?(item["permission"]) && item["pattern"] == "*" }
      raise Invalid, "Forbidden capability is not denied: #{tool}" unless rule && rule["action"] == "deny"
    end
    tools
  end

  def session_projection(info, messages)
    { "format" => "opencode-native-metadata-projection-v1", "info" => info,
      # Text, reasoning and tool inputs/outputs are already in output.txt. Keep
      # every native message header and all accounting/lifecycle parts once.
      "messages" => messages.map do |message|
        { "info" => message.fetch("info"), "parts" => message.fetch("parts").map do |part|
          if %w[step-start step-finish compaction retry].include?(part["type"])
            part
          else
            value = part.slice("id", "sessionID", "messageID", "type", "tool", "callID", "time")
            value["state"] = part.fetch("state").slice("status", "error", "time") if part["type"] == "tool"
            value
          end
        end }
      end }
  end
end
