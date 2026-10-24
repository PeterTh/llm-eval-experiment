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
end
