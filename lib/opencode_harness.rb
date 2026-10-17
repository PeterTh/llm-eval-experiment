# frozen_string_literal: true
require "json"
require "digest"

# Policy for the unmodified, pinned OpenCode CLI. Keep its stock prompts and
# model adapters; match the local capabilities of the native harnesses.
module OpenCodeHarness
  VERSION = "1.19.3"
  BINARY_SHA256 = "179ca421d61eefeadfa0c50e084a6e79c1623734732f0f4593f81ccfd3ab7ee9"
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
  class Invalid < StandardError; end
  module_function

  def config(model:, effort:)
    # Anthropic is deliberately not enabled until there is a confirmed supported
    # subscription-only OpenCode route. No API-key or credit-spending fallback.
    raise Invalid, "Unapproved OpenCode model/access route" unless model == "openai/gpt-6.1-sol" && effort == "medium"
    provider, model_id = model.split("/", 2)
    { "$schema" => "https://opencode.ai/config.json", "model" => model, "small_model" => model,
      "default_agent" => "build", "autoupdate" => false, "share" => "disabled",
      "enabled_providers" => [provider], "plugin" => [], "mcp" => {}, "instructions" => [],
      "permission" => { "*" => "allow" }.merge(FORBIDDEN_TOOLS.to_h { |tool| [tool, "deny"] }),
      "provider" => { provider => { "whitelist" => [model_id], "models" => {
        model_id => { "options" => { "reasoningEffort" => effort } }
      } } },
      "agent" => { "build" => { "variant" => effort },
        "compaction" => { "model" => model, "variant" => effort } } }
  end

  def environment(state)
    # Do not inherit provider credentials, experimental flags, proxy settings,
    # remote servers, instruction overrides, or a user's OpenCode configuration.
    removed = ENV.keys.grep(/\A(?:OPENCODE_|XDG_|OPENAI_|ANTHROPIC_|CLAUDE_|CODEX_|GITHUB_TOKEN\z|GH_TOKEN\z|.*_API_KEY\z|.*_PROXY\z|.*_proxy\z)/).to_h { |key| [key, nil] }
    removed.merge(FLAGS).merge(
      "XDG_DATA_HOME" => File.join(state, "data"), "XDG_CONFIG_HOME" => File.join(state, "config"),
      "XDG_CACHE_HOME" => File.join(state, "cache"), "XDG_STATE_HOME" => File.join(state, "state"),
      "OPENCODE_TEST_HOME" => File.join(state, "home"),
      "OPENCODE_TEST_MANAGED_CONFIG_DIR" => File.join(state, "managed"),
      "TMPDIR" => File.join(state, "tmp"), "NO_COLOR" => "1"
    )
  end

  def credential(path)
    auth = JSON.parse(File.read(path))
    raise Invalid, "Only OpenAI subscription OAuth is permitted" unless auth.keys == ["openai"] && auth.dig("openai", "type") == "oauth"
    %w[access refresh].each { |key| raise Invalid, "Incomplete subscription credential" unless auth.dig("openai", key).is_a?(String) && !auth.dig("openai", key).empty? }
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

  def verify_agent!(agent)
    raise Invalid, "Not the stock build agent" unless agent["name"] == "build" && agent["native"] == true && !agent["prompt"]
    tools = agent.fetch("tools").select { |_, enabled| enabled }.keys.sort
    raise Invalid, "Unexpected enabled tools: #{tools - LOCAL_TOOLS}" unless (tools - LOCAL_TOOLS).empty?
    raise Invalid, "Local build/edit tools unavailable" unless (%w[bash read glob grep apply_patch] - tools).empty?
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
