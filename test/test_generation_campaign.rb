require "minitest/autorun"
require "tmpdir"
require_relative "../tools/generation_campaign"

class GenerationCampaignTest < Minitest::Test
  class SimulatedCampaign < GenerationCampaign
    attr_accessor :produce, :git_responses
    attr_reader :launched, :committed, :git_calls, :cleaned

    def initialize(root)
      super
      @launched, @git_calls, @git_responses, @cleaned = [], [], {}, []
    end

    def ensure_account_idle!; end

    def cleanup_after_run!(id)
      @cleaned << id
    end

    def launch(command)
      @launched << command
      @produce.call(File.read(command.last.delete_prefix("--run-ids=")).strip)
      true
    end

    def commit_outputs
      @committed = true
    end

    def real_commit_outputs
      GenerationCampaign.instance_method(:commit_outputs).bind(self).call
    end

    def git(*arguments)
      @git_calls << arguments
      @git_responses.fetch(arguments) { raise "Unexpected Git command: #{arguments.inspect}" }
    end
  end

  def setup
    @root = Dir.mktmpdir("generation-campaign-", "/tmp")
    @batch = "20261002-142720"
    @ids = %w[first second third].map { |name| "#{name}_claude-opus-5.5-cc-medium_omp_r1" }
    @results = File.join(@root, @batch)
    FileUtils.mkdir_p(@results)
    File.write(File.join(@root, "run-ids.txt"), @ids.join("\n") + "\n")
    File.write(File.join(@root, "campaign.json"), JSON.generate({ "campaign_id" => @batch,
      "expected_runs" => @ids.size, "persistent_results" => @results,
      "runtime_root" => File.join(@root, "runtime"), "preflight_id" => @ids.first,
      "invoked_model" => "claude-opus-5-5", "claude_version" => "2.1.287", "per_run_timeout_seconds" => 14400 }))
    @campaign = SimulatedCampaign.new(@root)
    @campaign.produce = method(:record)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def record(id, model: "claude-opus-5-5")
    directory = File.join(@results, id)
    FileUtils.mkdir_p(directory)
    init = { "type" => "system", "subtype" => "init", "session_id" => id, "model" => model,
      "claude_code_version" => "2.1.287", "permissionMode" => "bypassPermissions", "mcp_servers" => [], "tools" => ["Bash"], "plugins" => [] }
    result = { "type" => "result", "session_id" => id, "subtype" => "success", "is_error" => false, "duration_api_ms" => 1000,
      "modelUsage" => { model => { "inputTokens" => 10, "outputTokens" => 20, "cacheReadInputTokens" => 30, "cacheCreationInputTokens" => 40 } } }
    File.write(File.join(directory, "output.txt"), [init, result].map { |e| JSON.generate(e) }.join("\n") + "\n")
    File.write(File.join(directory, "timing.txt"), "Duration: 2.0 seconds\n")
    File.write(File.join(directory, "instruction.txt"), "unchanged production prompt")
    File.write(File.join(directory, "process-status.txt"), JSON.generate({ "exit_status" => 0, "term_signal" => nil, "timeout_seconds" => 14400 }))
    directory
  end

  def gate
    record(@ids.first)
    capture_io { @campaign.gate }
  end

  def progress
    JSON.parse(File.read(File.join(@root, "progress.json")))
  end

  def test_preflight_is_reused_and_only_pending_observations_are_launched
    gate
    directory = File.join(@results, @ids.first)
    original = Dir[File.join(directory, "*")].to_h { |p| [p, File.binread(p)] }
    capture_io { @campaign.run }
    assert_equal 2, @campaign.launched.size
    assert_equal @ids.drop(1), @campaign.cleaned
    assert @campaign.launched.all? { |args| args.include?("--production") && args.include?("--continue=#{@batch}") }
    original.each { |path, bytes| assert_equal bytes, File.binread(path) }
    assert @campaign.committed
    assert_equal "complete", progress.fetch("status")
    assert_equal 3, progress.fetch("completed")
  end

  def test_wrong_model_stops_without_launching_later_observations_or_committing
    gate
    @campaign.produce = ->(id) { record(id, model: "other-model") }
    capture_io { assert_raises(ClaudeGenerationObservation::Invalid) { @campaign.run } }
    assert_equal 1, @campaign.launched.size
    assert_equal [@ids[1]], @campaign.cleaned
    assert_nil @campaign.committed
    assert_equal "needs_review", progress.fetch("status")
    assert_equal 1, progress.fetch("completed")
    assert File.file?(File.join(@results, @ids[1], "output.txt"))
    refute Dir.exist?(File.join(@results, @ids[2]))
  end

  def test_existing_incomplete_or_modified_output_is_never_overwritten
    gate
    FileUtils.mkdir_p(File.join(@results, @ids[1]))
    capture_io { assert_raises(RuntimeError) { @campaign.run } }
    assert_empty @campaign.launched
    File.write(File.join(@results, @ids.first, "instruction.txt"), "unexpected mutation")
    capture_io { assert_raises(RuntimeError) { @campaign.run } }
    assert_match "Completed observation changed", progress.fetch("error")
    assert_empty @campaign.launched
  end

  def test_cleanup_failure_preserves_output_and_prevents_next_launch
    gate
    @campaign.define_singleton_method(:cleanup_after_run!) { |_id| raise "Post-run cleanup exceeded 2.0s" }
    capture_io { assert_raises(RuntimeError) { @campaign.run } }
    assert_equal 1, @campaign.launched.size
    assert_equal "needs_review", progress.fetch("status")
    assert File.file?(File.join(@results, @ids[1], "timing.txt"))
    refute Dir.exist?(File.join(@results, @ids[2]))
    assert_nil @campaign.committed
  end

  def test_cleanup_is_verified_even_when_the_harness_returns_failure
    gate
    @campaign.define_singleton_method(:launch) { |command| @launched << command; false }
    capture_io { assert_raises(RuntimeError) { @campaign.run } }
    assert_equal [@ids[1]], @campaign.cleaned
    assert_equal 1, @campaign.launched.size
    assert_equal "needs_review", progress.fetch("status")
    assert_nil @campaign.committed
  end

  def test_busy_account_before_launch_is_not_cleaned
    gate
    @campaign.define_singleton_method(:ensure_account_idle!) { raise "Account busy" }
    capture_io { assert_raises(RuntimeError) { @campaign.run } }
    assert_empty @campaign.launched
    assert_empty @campaign.cleaned
  end

  def test_another_controller_does_not_overwrite_progress
    gate
    File.write(File.join(@root, "progress.json"), '{"status":"running"}')
    File.open(File.join(@root, "controller.lock"), "a") do |lock|
      lock.flock(File::LOCK_EX)
      capture_io { assert_raises(RuntimeError) { @campaign.run } }
    end
    assert_equal({ "status" => "running" }, progress)
    assert_empty @campaign.launched
  end

  def test_operator_stop_keeps_observations_and_does_not_launch
    gate
    File.write(File.join(@root, "STOP"), "Pause between observations")
    capture_io { assert_raises(RuntimeError) { @campaign.run } }
    assert_empty @campaign.launched
    assert_equal "needs_review", progress.fetch("status")
    assert_match "Operator stop", progress.fetch("error")
  end

  def test_existing_staged_user_changes_are_not_modified
    @campaign.git_responses[["branch", "--show-current"]] = "claude\n"
    @campaign.git_responses[["diff", "--cached", "--name-only"]] = "unrelated.cpp\n"
    assert_raises(RuntimeError) { @campaign.real_commit_outputs }
    assert_equal 2, @campaign.git_calls.size
    refute @campaign.git_calls.any? { |args| args.first == "add" }
  end

  def test_nested_repository_is_not_staged_as_a_gitlink
    record(@ids.first)
    FileUtils.mkdir_p(File.join(@results, @ids.first, ".git"))
    @campaign.git_responses[["branch", "--show-current"]] = "claude\n"
    @campaign.git_responses[["diff", "--cached", "--name-only"]] = ""
    assert_raises(RuntimeError) { @campaign.real_commit_outputs }
    refute @campaign.git_calls.any? { |args| args.first == "add" }
  end

  def test_commit_retains_only_campaign_code_and_metadata_under_ignore_rules
    repository = @root
    git = ->(*args) do
      output, status = Open3.capture2e("git", "-C", repository, *args)
      raise output unless status.success?
      output
    end
    git.call("init", "--quiet", "--initial-branch=claude")
    git.call("config", "user.name", "Campaign Test")
    git.call("config", "user.email", "campaign-test@example.invalid")
    File.write(File.join(repository, ".gitignore"), "*\n!*/\n!*.txt\n!*.cpp\n!.gitignore\nbuild/\n")
    git.call("add", ".gitignore")
    git.call("commit", "--quiet", "-m", "Fixture")
    @ids.each do |id|
      directory = record(id)
      File.write(File.join(directory, "usage.txt"), "retained usage")
      File.write(File.join(directory, "main.cpp"), "int main() {}")
      FileUtils.mkdir_p(File.join(directory, "build"))
      File.write(File.join(directory, "build", "artifact.txt"), "reproducible build artifact")
      File.write(File.join(directory, "binary"), "reproducible binary")
    end
    File.write(File.join(repository, "unrelated.cpp"), "user work")
    GenerationCampaign.new(@root).commit_outputs
    committed = git.call("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").lines.map(&:strip)
    assert_equal 18, committed.size
    assert committed.all? { |p| p.start_with?("#{@batch}/") }
    refute committed.any? { |p| p.include?("/build/") || p.end_with?("/binary") }
    assert_equal "?? unrelated.cpp\n", git.call("status", "--porcelain", "--", "unrelated.cpp")
    completion = JSON.parse(File.read(File.join(@root, "completion.json")))
    assert_equal git.call("rev-parse", "HEAD").strip, completion.fetch("source_commit")
    assert_equal 3, completion.fetch("observations")
  end
end
