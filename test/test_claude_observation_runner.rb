require "minitest/autorun"
require "tmpdir"
require_relative "../tools/claude_observation"

class ClaudeObservationRunnerTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("claude-runner-test-", "/tmp")
    @runner = ClaudeObservationRunner.allocate
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_linked_metadata_cannot_overwrite_or_read_host_files
    real = File.join(@root, "original")
    link = File.join(@root, "linked")
    File.write(real, "untouched")
    File.symlink(real, link)
    assert_raises(Errno::ELOOP) { @runner.write(link, { "value" => 1 }) }
    assert_raises(RuntimeError) { @runner.read_regular(link) }
    assert_equal "untouched", File.read(real)
    FileUtils.mkdir_p(File.join(@root, "directory"))
    File.write(File.join(@root, "directory", "value"), "data")
    File.symlink(File.join(@root, "directory"), File.join(@root, "linked-parent"))
    assert_raises(RuntimeError) { @runner.read_regular(File.join(@root, "linked-parent", "value")) }
  end

  def test_credentials_are_validated_without_echoing_values
    oauth = { "accessToken" => "test-access", "refreshToken" => "test-refresh", "expiresAt" => 1234 }
    raw = JSON.generate("claudeAiOauth" => oauth)
    assert_equal oauth, ClaudeObservationRunner.validate_credentials!(raw).fetch("claudeAiOauth")
    %w[accessToken refreshToken expiresAt].each do |key|
      assert_raises(RuntimeError) { ClaudeObservationRunner.validate_credentials!(JSON.generate("claudeAiOauth" => oauth.merge(key => nil))) }
    end
  end

  def test_private_and_public_evidence_permissions
    path = File.join(@root, "private.json")
    @runner.write(path, { "ok" => true })
    assert_equal 0600, File.stat(path).mode & 0777
    path = File.join(@root, "public.json")
    @runner.write(path, { "ok" => true }, perm: 0644)
    assert_equal 0644, File.stat(path).mode & 0777
  end
end
