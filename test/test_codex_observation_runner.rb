# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "../tools/codex_observation"

class CodexObservationRunnerTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("codex-runner-test-", "/tmp")
    @runner = CodexObservationRunner.allocate
    @state = File.join(@root, "private")
    @runner.instance_variable_set(:@state, @state)
    @source = File.join(@state, "home/.codex/sessions")
    @archive = File.join(@root, "archive")
    @relative = "2026/10/28/rollout-2026-10-28T20-00-00-01234567-89ab-cdef-0123-456789abcdef.jsonl"
    @workspace = "/home/llmtest/evals/20261028-200000/black-scholes_gpt-6.1-terra-medium_omp_r1"
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def make_session
    path = File.join(@source, @relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{\"fake_test_rollout\":true}\n")
    path
  end

  def test_linked_evidence_and_configuration_are_rejected
    path = File.join(@root, "original")
    link = File.join(@root, "link")
    File.write(path, "untouched")
    File.symlink(path, link)
    assert_raises(Errno::ELOOP) { @runner.write(link, { "ok" => true }) }
    assert_raises(RuntimeError) { @runner.read_regular(link) }
    assert_equal "untouched", File.read(path)
  end

  def test_subscription_only_credentials_without_echoing_values
    value = { "auth_mode" => "chatgpt", "OPENAI_API_KEY" => nil,
      "tokens" => %w[id_token access_token refresh_token account_id].to_h { |key| [key, "synthetic-secret"] } }
    assert_equal value, CodexObservationRunner.validate_credentials!(JSON.generate(value))
    [{ "auth_mode" => "apikey" }, { "OPENAI_API_KEY" => "synthetic-key" }].each do |mutation|
      error = assert_raises(RuntimeError) { CodexObservationRunner.validate_credentials!(JSON.generate(value.merge(mutation))) }
      refute_includes error.message, "synthetic"
    end
    value.fetch("tokens").keys.each do |key|
      modified = value.merge("tokens" => value.fetch("tokens").merge(key => ""))
      assert_raises(RuntimeError) { CodexObservationRunner.validate_credentials!(JSON.generate(modified)) }
    end
  end

  def config
    "model = \"gpt-5.6-luna\"\nmodel_reasoning_effort = \"medium\"\nweb_search = \"disabled\"\n" +
      "[projects.\"/home/llmtest/old-observation\"]\ntrust_level = \"trusted\"\n[tui]\nscreen_reader_detection_done = true\n"
  end

  def test_config_keeps_functional_settings_without_history
    isolated = CodexObservationRunner.isolated_config(config, workspace: @workspace)
    assert_includes isolated, 'web_search = "disabled"'
    assert_includes isolated, 'model_reasoning_effort = "medium"'
    assert_includes isolated, @workspace
    refute_includes isolated, "old-observation"
    refute_includes isolated, "screen_reader"
    assert_equal 1, isolated.scan(/^\[projects\./).size
  end

  def test_new_functional_configuration_requires_review
    [config.sub('"disabled"', '"live"'), "developer_instructions = \"changed\"\n" + config,
      config + "[mcp_servers.example]\ncommand = \"evil\"\n", config + "[features]\nplugins = true\n"].each do |raw|
      assert_raises(RuntimeError) { CodexObservationRunner.isolated_config(raw, workspace: @workspace) }
    end
    assert_raises(RuntimeError) { CodexObservationRunner.isolated_config(config, workspace: "/tmp/broad") }
  end

  def test_fresh_sessions_preserved_idempotently_without_old_session_scan
    source = make_session
    first = @runner.archive_sessions!(destination: @archive)
    assert_equal [{ "path" => @relative, "sha256" => Digest::SHA256.file(source).hexdigest, "bytes" => File.size(source) }], first
    target = File.join(@archive, @relative)
    assert_equal File.binread(source), File.binread(target)
    assert_equal 0600, File.stat(target).mode & 0777
    # A bogus unrelated host entry must not be opened or followed by collection.
    File.symlink("/does-not-exist", File.join(@archive, "old-unreadable"))
    assert_equal first, @runner.archive_sessions!(destination: @archive)
  end

  def test_archive_conflicts_do_not_overwrite_retained_sessions
    source = make_session
    @runner.archive_sessions!(destination: @archive)
    target = File.join(@archive, @relative)
    original = File.binread(target)
    File.write(source, "different")
    assert_raises(RuntimeError) { @runner.archive_sessions!(destination: @archive) }
    assert_equal original, File.binread(target)
  end

  def test_linked_or_unexpected_session_paths_cannot_escape_archive
    source = make_session
    File.symlink(source, File.join(File.dirname(source), "linked.jsonl"))
    assert_raises(RuntimeError) { @runner.archive_sessions!(destination: @archive) }
  end

  def test_linked_archive_parent_cannot_redirect_writes
    make_session
    FileUtils.mkdir_p(@archive)
    outside = File.join(@root, "outside")
    FileUtils.mkdir_p(outside)
    File.symlink(outside, File.join(@archive, "2026"))
    assert_raises(RuntimeError) { @runner.archive_sessions!(destination: @archive) }
    assert_empty Dir.children(outside)
  end

  def test_no_inference_lifecycle_can_have_no_session
    assert_empty @runner.archive_sessions!(destination: @archive)
  end
end
