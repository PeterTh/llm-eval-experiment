require "find"
require "minitest/autorun"
require "securerandom"
require "tmpdir"
require_relative "../lib/local_evaluation"

class ProcessResilienceTest < Minitest::Test
  MIBIBYTE = 1024 * 1024

  def setup
    @tmp = Dir.mktmpdir("local-evaluation-resilience-", "/tmp")
    @owned_processes = []
  end

  def teardown
    @owned_processes.each { |pid, token| kill_owned_process(pid, token) }
    make_tree_writable(@tmp)
    FileUtils.remove_entry(@tmp) if File.directory?(@tmp)
  end

  def test_output_flood_is_truncated_without_blocking_the_child
    limit = 32 * 1024
    prefix = File.join(@tmp, "output-flood")
    code = <<~'RUBY'
      chunk = "x" * (64 * 1024)
      16.times do
        STDOUT.write(chunk)
        STDERR.write(chunk)
      end
    RUBY

    result = with_optional_cgroup do
      LocalEvaluation::ProcessRunner.new.run(
        argv: [RbConfig.ruby, "-e", code],
        prefix: prefix,
        timeout: 5,
        limits: limits(output_limit_bytes: limit)
      )
    end

    assert result.success
    assert result.output_truncated
    %w[stdout stderr].each do |stream|
      path = "#{prefix}_#{stream}.log"
      assert_operator File.size(path), :<=, limit + 128
      assert_includes File.binread(path), "[local evaluation truncated"
    end
  end

  def test_timeout_kills_background_descendants
    prefix = File.join(@tmp, "timeout-tree")
    pid_path = File.join(@tmp, "timeout-child.pid")
    token = "local-evaluation-timeout-#{SecureRandom.hex(8)}"
    code = <<~'RUBY'
      child = spawn(RbConfig.ruby, "-e", "sleep 30", ARGV.fetch(0))
      File.write(ARGV.fetch(1), child.to_s)
      sleep 30
    RUBY

    result = LocalEvaluation::ProcessRunner.new.run(
      argv: [RbConfig.ruby, "-e", code, token, pid_path],
      prefix: prefix,
      timeout: 1
    )

    assert result.timed_out
    assert_equal 124, result.exit_code
    assert File.file?(pid_path), "leader did not record its background child"
    child_pid = Integer(File.read(pid_path), 10)
    @owned_processes << [child_pid, token]
    assert wait_until { !process_running?(child_pid) }, "background child #{child_pid} survived timeout cleanup"
  end

  def test_successful_leader_does_not_leave_a_background_descendant
    prefix = File.join(@tmp, "successful-tree")
    pid_path = File.join(@tmp, "successful-child.pid")
    ready_path = File.join(@tmp, "successful-child.ready")
    token = "local-evaluation-success-#{SecureRandom.hex(8)}"
    code = <<~'RUBY'
      child_code = <<~'CHILD'
        Signal.trap("HUP", "IGNORE")
        File.write(ARGV.fetch(0), "ready")
        sleep 30
      CHILD
      child = spawn(RbConfig.ruby, "-e", child_code, ARGV.fetch(2), ARGV.fetch(0))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.01 until File.file?(ARGV.fetch(2)) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      File.write(ARGV.fetch(1), child.to_s)
    RUBY

    result = LocalEvaluation::ProcessRunner.new.run(
      argv: [RbConfig.ruby, "-e", code, token, pid_path, ready_path],
      prefix: prefix,
      timeout: 5
    )

    assert result.success
    assert File.file?(ready_path), "background child was not live before its leader exited"
    child_pid = Integer(File.read(pid_path), 10)
    @owned_processes << [child_pid, token]
    assert wait_until { !process_running?(child_pid) }, "background child #{child_pid} survived successful leader cleanup"
  end

  def test_successful_leader_cleans_detached_child_that_closed_log_pipes
    skip "user-systemd cgroup containment unavailable" unless LocalEvaluation::SystemdContainment.available?

    prefix = File.join(@tmp, "successful-detached-tree")
    pid_path = File.join(@tmp, "successful-detached-child.pid")
    token = "local-evaluation-detached-success-#{SecureRandom.hex(8)}"
    code = <<~'RUBY'
      child = spawn(
        RbConfig.ruby, "-e", "sleep 30", ARGV.fetch(0),
        out: File::NULL, err: File::NULL, pgroup: true
      )
      File.write(ARGV.fetch(1), child.to_s)
    RUBY

    result = LocalEvaluation::ProcessRunner.new.run(
      argv: [RbConfig.ruby, "-e", code, token, pid_path],
      prefix: prefix,
      timeout: 5,
      limits: limits
    )

    assert result.success
    assert File.file?(pid_path), "leader did not record its detached child"
    child_pid = Integer(File.read(pid_path), 10)
    @owned_processes << [child_pid, token]
    assert wait_until { !process_running?(child_pid) },
           "detached child #{child_pid} survived successful leader cleanup"
  end

  def test_interrupt_kills_child_and_finalizes_attempt_logs
    prefix = File.join(@tmp, "interrupt")
    pid_path = File.join(@tmp, "interrupt-child.pid")
    token = "local-evaluation-interrupt-#{SecureRandom.hex(8)}"
    code = "File.write(ARGV.fetch(0), Process.pid.to_s); sleep 30"
    interrupted_thread = Thread.current
    interrupter = Thread.new do
      next unless wait_until(3) { File.file?(pid_path) }

      interrupted_thread.raise(Interrupt, "deterministic resilience-test interrupt")
    end

    error = assert_raises(Interrupt) do
      LocalEvaluation::ProcessRunner.new.run(
        argv: [RbConfig.ruby, "-e", code, pid_path, token],
        prefix: prefix,
        timeout: 10
      )
    end
    assert_match(/deterministic resilience-test interrupt/, error.message)
    interrupter.join

    assert File.file?(pid_path), "child did not start before the interrupt"
    child_pid = Integer(File.read(pid_path), 10)
    @owned_processes << [child_pid, token]
    assert wait_until { !process_running?(child_pid) }, "child #{child_pid} survived interrupt cleanup"
    assert_equal "130", File.read("#{prefix}_exitcode.log")
    assert File.file?("#{prefix}_wall_time.log")
    assert_includes File.read("#{prefix}_stderr.log"), "Infrastructure interruption: Interrupt"
  ensure
    interrupter&.kill if interrupter&.alive?
    interrupter&.join
  end

  def test_source_staging_excludes_generated_content_and_symlinks_and_is_read_only
    source_root = File.join(@tmp, "raw-source")
    benchmark_dir = File.join(source_root, "matmul")
    common_dir = File.join(source_root, "common")
    FileUtils.mkdir_p([benchmark_dir, common_dir])
    File.write(File.join(benchmark_dir, "CMakeLists.txt"), "add_executable(matmul main.cpp)\n")
    File.write(File.join(benchmark_dir, "main.cpp"), "int main() { return 0; }\n")
    File.write(File.join(common_dir, "results.hpp"), "#pragma once\n")
    File.write(File.join(benchmark_dir, "CMakeCache.txt"), "stale cache\n")
    File.write(File.join(benchmark_dir, "generated.o"), "object data\n")
    File.write(File.join(benchmark_dir, "prebuilt"), "binary\n")
    File.chmod(0o755, File.join(benchmark_dir, "prebuilt"))
    File.write(File.join(benchmark_dir, "configure"), "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, File.join(benchmark_dir, "configure"))
    FileUtils.mkdir_p(File.join(benchmark_dir, "build-debug"))
    File.write(File.join(benchmark_dir, "build-debug", "stale.cpp"), "stale\n")
    FileUtils.mkdir_p(File.join(benchmark_dir, "CMakeFiles"))
    File.write(File.join(benchmark_dir, "CMakeFiles", "state"), "stale\n")
    outside = File.join(source_root, "outside.cpp")
    File.write(outside, "outside\n")
    File.symlink(outside, File.join(benchmark_dir, "linked.cpp"))

    stage_root = File.join(@tmp, "staging", "source")
    staged_benchmark = LocalEvaluation::BuildSupport.stage_source(
      source_root: source_root,
      benchmark: "matmul",
      stage_root: stage_root
    )

    assert_equal File.join(stage_root, "matmul"), staged_benchmark
    assert File.file?(File.join(staged_benchmark, "CMakeLists.txt"))
    assert File.file?(File.join(staged_benchmark, "main.cpp"))
    assert File.file?(File.join(stage_root, "common", "results.hpp"))
    assert File.file?(File.join(staged_benchmark, "configure"))
    refute File.exist?(File.join(staged_benchmark, "CMakeCache.txt"))
    refute File.exist?(File.join(staged_benchmark, "generated.o"))
    refute File.exist?(File.join(staged_benchmark, "prebuilt"))
    refute File.exist?(File.join(staged_benchmark, "build-debug"))
    refute File.exist?(File.join(staged_benchmark, "CMakeFiles"))
    refute File.symlink?(File.join(staged_benchmark, "linked.cpp"))

    Find.find(stage_root) do |path|
      next if File.symlink?(path)

      assert_equal 0, File.stat(path).mode & 0o222, "#{path} retained write permission"
    end
    metadata = LocalEvaluation.load_yaml(File.join(@tmp, "staging", "source_staging.yaml"))
    assert_includes metadata.fetch("skipped_generated_entries"), "matmul/build-debug"
    assert_includes metadata.fetch("skipped_generated_entries"), "matmul/CMakeCache.txt"
    assert_includes metadata.fetch("skipped_generated_entries"), "matmul/linked.cpp"
  ensure
    FileUtils.chmod_R(0o700, stage_root) if stage_root && File.exist?(stage_root)
  end

  def test_disk_guard_accepts_available_space_and_rejects_an_impossible_reserve
    future_path = File.join(@tmp, "not-created", "run")
    available = LocalEvaluation.ensure_disk_space!(future_path, minimum_bytes: 1)
    assert_operator available, :>, 0

    error = assert_raises(LocalEvaluation::InfrastructureError) do
      LocalEvaluation.ensure_disk_space!(future_path, minimum_bytes: 1 << 62)
    end
    assert_match(/Only \d+ GiB remain/, error.message)
  end

  def test_cgroup_memory_limit_kills_an_over_allocating_process_when_available
    skip "user-systemd cgroup containment unavailable" unless LocalEvaluation::SystemdContainment.available?

    prefix = File.join(@tmp, "memory-cap")
    code = <<~'RUBY'
      chunks = []
      loop do
        chunks << ("m" * (8 * 1024 * 1024))
        sleep 0.01
      end
    RUBY
    result = LocalEvaluation::ProcessRunner.new.run(
      argv: [RbConfig.ruby, "-e", code],
      prefix: prefix,
      timeout: 8,
      limits: limits(memory_max_bytes: 64 * MIBIBYTE, output_limit_bytes: 64 * 1024)
    )

    refute result.success
    refute result.timed_out, "memory hog reached the outer timeout instead of the cgroup memory cap"
    refute_nil result.containment_unit
    assert_operator result.wall_seconds, :<, 8
    assert_includes File.read("#{prefix}_command.log"), "memory_max_bytes=#{64 * MIBIBYTE}"
  end

  private

  def limits(memory_max_bytes: 128 * MIBIBYTE, tasks_max: 32, output_limit_bytes: 64 * 1024)
    {
      memory_max_bytes: memory_max_bytes,
      tasks_max: tasks_max,
      output_limit_bytes: output_limit_bytes
    }
  end

  def with_optional_cgroup
    available = LocalEvaluation::SystemdContainment.available?
    previous = ENV["LOCAL_EVALUATION_ALLOW_UNCONTAINED"]
    ENV["LOCAL_EVALUATION_ALLOW_UNCONTAINED"] = "1" unless available
    yield
  ensure
    if previous.nil?
      ENV.delete("LOCAL_EVALUATION_ALLOW_UNCONTAINED")
    else
      ENV["LOCAL_EVALUATION_ALLOW_UNCONTAINED"] = previous
    end
  end

  def wait_until(seconds = 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      return true if yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.02
    end
  end

  def process_running?(pid)
    stat = File.read("/proc/#{pid}/stat")
    state = stat.match(/\A\d+ \(.+\) (?<state>.) /)&.[](:state)
    !%w[Z X].include?(state)
  rescue Errno::ENOENT
    false
  end

  def kill_owned_process(pid, token)
    return unless process_running?(pid)

    command_line = File.binread("/proc/#{pid}/cmdline")
    return unless command_line.include?(token)

    Process.kill("KILL", pid)
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  def make_tree_writable(root)
    return unless File.exist?(root)

    Find.find(root) do |path|
      next if File.symlink?(path)

      mode = File.stat(path).mode
      File.chmod(mode | (File.directory?(path) ? 0o700 : 0o600), path)
    rescue Errno::ENOENT
      nil
    end
  end
end
