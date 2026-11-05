# frozen_string_literal: true
require "shellwords"

module CodexHarness
  module_function

  # Ultra is an explicitly authorized native-delegation profile. Preserve all
  # other restrictions, and leave every existing single-agent profile unchanged.
  # Do not select a replacement child model or invent custom agent instructions.
  def flags(base, profile:)
    arguments = Shellwords.split(base)
    return arguments unless profile == "gpt-6.1-terra-ultra"

    %w[multi_agent multi_agent_v2].each do |feature|
      index = arguments.each_index.find { |i| arguments[i, 2] == ["--disable", feature] }
      raise "Missing expected delegation restriction: #{feature}" unless index
      arguments.slice!(index, 2)
    end
    arguments + ["--enable", "multi_agent"]
  end
end
