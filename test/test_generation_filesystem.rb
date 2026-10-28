# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/generation_filesystem"

class GenerationFilesystemTest < Minitest::Test
  def setup
    @workspace = "/home/llmtest/evals/20261019-134042/test_model_omp_r1"
    @state = "/tmp/opencode-observation-test/private"
  end

  def test_mount_allowlist_does_not_expose_host_home_scratch_or_processes
    fs = GenerationFilesystem.allocate
    fs.instance_variable_set(:@workspace, @workspace)
    fs.instance_variable_set(:@state, @state)
    fs.instance_variable_set(:@binary, "/tmp/frozen-runtime/opencode")
    args = fs.command("run", "argument with spaces")
    assert_equal [GenerationFilesystem::BINARY, "run", "argument with spaces"], args.last(3)
    %w[--unshare-user --unshare-pid --unshare-ipc --disable-userns --assert-userns-disabled --new-session --die-with-parent].each { |option| assert_includes args, option }
    assert_includes args.each_cons(2).to_a, ["--proc", "/proc"]
    mounts = args.each_index.filter_map { |i| args[i, 3] if %w[--bind --ro-bind --dev-bind].include?(args[i]) }
    refute mounts.any? { |_, source, _| %w[/ /home /home/petert /home/llmtest /tmp /var/tmp /proc /run].include?(source) }
    assert_includes mounts, ["--bind", @workspace, @workspace]
    assert_includes mounts, ["--bind", "#{@state}/home", "/home/llmtest"]
    assert_includes mounts, ["--bind", "#{@state}/tmp", "/tmp"]
    assert_includes mounts, ["--ro-bind", "/tmp/frozen-runtime/opencode", GenerationFilesystem::BINARY]
    refute_includes args, "--unshare-net"
  end

  def test_broad_or_relative_workspace_and_state_are_rejected
    %w[/ /home /home/llmtest /home/llmtest/evals /tmp/foo relative].each do |workspace|
      assert_raises(RuntimeError) { GenerationFilesystem.new(workspace: workspace, state: @state, binary: "/usr/bin/true") }
    end
    %w[/ /tmp /tmp/private /home/llmtest relative].each do |state|
      assert_raises(RuntimeError) { GenerationFilesystem.new(workspace: @workspace, state: state, binary: "/usr/bin/true") }
    end
  end

  def test_claude_observation_uses_the_same_allowlist
    fs = GenerationFilesystem.allocate
    fs.instance_variable_set(:@workspace, @workspace)
    fs.instance_variable_set(:@state, "/tmp/claude-observation-test/private")
    fs.instance_variable_set(:@binary, "/opt/claude")
    assert_includes fs.prefix.each_cons(3).to_a,
      ["--bind", "/tmp/claude-observation-test/private/home", "/home/llmtest"]
  end

  def test_codex_observation_uses_the_same_allowlist
    fs = GenerationFilesystem.allocate
    fs.instance_variable_set(:@workspace, @workspace)
    fs.instance_variable_set(:@state, "/tmp/codex-observation-test/private")
    fs.instance_variable_set(:@binary, "/opt/codex")
    assert_includes fs.prefix.each_cons(3).to_a,
      ["--bind", "/tmp/codex-observation-test/private/home", "/home/llmtest"]
    refute fs.prefix.include?("/home/llmtest/.codex/sessions")
  end

  def test_evidence_requires_successful_probe_and_exact_policy
    evidence = GenerationFilesystem.policy_details(@workspace).merge(
      "implementation_sha256" => "a" * 64, "bubblewrap_sha256" => "b" * 64,
      "preflight" => { "passed" => true, "operator_home_visible" => false, "other_observations_visible" => false })
    assert_equal evidence, GenerationFilesystem.verify_evidence!(evidence, workspace: @workspace)
    ["private_home", "private_proc", "private_ipc"].each do |key|
      assert_raises(RuntimeError) { GenerationFilesystem.verify_evidence!(evidence.merge(key => false), workspace: @workspace) }
    end
    assert_raises(RuntimeError) { GenerationFilesystem.verify_evidence!(evidence.merge("preflight" => { "passed" => true }), workspace: @workspace) }
    assert_raises(RuntimeError) { GenerationFilesystem.verify_evidence!(evidence.merge("implementation_sha256" => ""), workspace: @workspace) }
    assert_raises(RuntimeError) { GenerationFilesystem.verify_evidence!(evidence, workspace: "another workspace") }
  end

  def test_pinned_companion_is_an_individual_read_only_mount
    Dir.mktmpdir("codex-companion-test-", "/tmp") do |directory|
      binary = File.join(directory, "codex")
      helper = File.join(directory, "codex-code-mode-host")
      File.write(helper, "synthetic fixture")
      File.chmod(0755, helper)
      companions = { "codex-code-mode-host" => helper }
      assert_equal companions, GenerationFilesystem.validate_companions!(binary, companions)
      fs = GenerationFilesystem.allocate
      fs.instance_variable_set(:@workspace, @workspace)
      fs.instance_variable_set(:@state, @state)
      fs.instance_variable_set(:@binary, binary)
      fs.instance_variable_set(:@companions, companions)
      assert_includes fs.prefix.each_cons(3).to_a, ["--ro-bind", helper, "/run/llm-eval/bin/codex-code-mode-host"]
      assert_raises(RuntimeError) { GenerationFilesystem.validate_companions!(binary, { "other" => helper }) }
      assert_raises(RuntimeError) { GenerationFilesystem.validate_companions!(binary, { "codex-code-mode-host" => "/usr/bin/true" }) }
      File.chmod(0644, helper)
      assert_raises(RuntimeError) { GenerationFilesystem.validate_companions!(binary, companions) }
    end
  end

  def test_companion_evidence_has_fixed_name_mount_and_digest
    value = GenerationFilesystem.policy_details(@workspace).merge(
      "implementation_sha256" => "a" * 64, "bubblewrap_sha256" => "b" * 64,
      "preflight" => { "passed" => true, "operator_home_visible" => false, "other_observations_visible" => false },
      "harness_companions" => { "codex-code-mode-host" => { "mount" => "/run/llm-eval/bin/codex-code-mode-host", "sha256" => "c" * 64 } })
    assert_equal value, GenerationFilesystem.verify_evidence!(value, workspace: @workspace)
    ["mount", "sha256"].each do |key|
      altered = Marshal.load(Marshal.dump(value))
      altered.fetch("harness_companions").fetch("codex-code-mode-host")[key] = "wrong"
      assert_raises(RuntimeError) { GenerationFilesystem.verify_evidence!(altered, workspace: @workspace) }
    end
  end
end
