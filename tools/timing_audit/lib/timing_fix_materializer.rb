# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
require_relative "timing_fix"

module TimingFixMaterializer
  C_COMPILER = "/usr/bin/gcc-13"
  CXX_COMPILER = "/usr/bin/g++-13"
  CUDA_ROOT = "/usr/local/cuda"
  CUDA_COMPILER = File.join(CUDA_ROOT, "bin", "nvcc")
  CONFIGURE_TIMEOUT = 180
  BUILD_TIMEOUT = 600

  module_function

  def run(output_dir:, scope:, jobs: 4)
    output_dir = File.realpath(output_dir)
    scope = scope.to_s
    raise "Scope must be trial or full" unless %w[trial full].include?(scope)
    jobs = Integer(jobs)
    raise "Jobs must be positive" unless jobs.positive?
    manifest = YAML.safe_load(File.read(File.join(output_dir, "manifest.yaml")), aliases: false)
    records = TimingAudit.load_jsonl(File.join(output_dir, "inventory.jsonl"))
    records_by_id = records.to_h { |record| [record.fetch("id"), record] }
    ids = if scope == "trial"
      File.readlines(File.join(output_dir, "trial-ids.txt"), chomp: true).reject(&:empty?)
    else
      records.map { |record| record.fetch("id") }
    end
    generated = manifest.fetch("generated_source")
    source_root = File.realpath(generated.fetch("root"))
    TimingAudit::SourceRepository.new(root: source_root, commit: generated.fetch("commit"))
    validator = TimingFix::ProposalValidator.new(records, source_root)
    proposals = ids.to_h do |id|
      path = File.join(output_dir, "proposals", "#{id}.json")
      raise "Missing proposal #{id}" unless File.file?(path)
      proposal = JSON.parse(File.read(path))
      validator.validate!(proposal, expected_id: id)
      raise "Cannot materialize #{id}: proposal status is #{proposal.fetch('status')}" unless proposal.fetch("status") == "proposed"
      [id, proposal]
    end

    Dir.mktmpdir("llm-timing-fix-materialize-", "/tmp") do |staging|
      raise "Staging directory is not local /tmp" unless File.realpath(staging).start_with?("/tmp/")
      materialize_originals(staging, ids, records_by_id, source_root)
      initialize_baseline(staging)
      changed_paths = apply_proposals(staging, ids, records_by_id, proposals, validator)
      verify_changed_paths(staging, changed_paths)
      patch = git_capture(staging, "diff", "--binary", "--full-index", "--no-ext-diff", "--")
      raise "Materialized patch is empty" if patch.empty?
      stdout, stderr, status = Open3.capture3("git", "-C", staging, "diff", "--check", "--")
      diagnostics = [stdout, stderr].reject(&:empty?).join("\n")
      raise "Materialized patch fails git diff --check: #{diagnostics}" unless status.success?
      _stdout, stderr, status = Open3.capture3("git", "-C", source_root, "apply", "--check", "-", stdin_data: patch)
      raise "Materialized patch does not apply to pinned source: #{stderr}" unless status.success?
      patch_path = File.join(output_dir, "materialized", "timing-fixes-#{scope}.patch")
      TimingAudit.atomic_write(patch_path, patch)

      compile_results = compile_all(
        staging: staging,
        output_dir: output_dir,
        scope: scope,
        records: ids.map { |id| records_by_id.fetch(id) },
        jobs: jobs
      )
      failures = compile_results.reject { |result| result.fetch("success") }
      summary = {
        "created_at" => TimingAudit.utc_now,
        "scope" => scope,
        "records" => ids.size,
        "changed_paths" => changed_paths.size,
        "patch_sha256" => TimingAudit.sha256_file(patch_path),
        "compiled" => compile_results.size,
        "compile_successes" => compile_results.size - failures.size,
        "compile_failures" => failures.map { |result| result.fetch("program_id") },
        "source_commit" => generated.fetch("commit"),
        "materializer_sha256" => TimingAudit.sha256_file(File.expand_path(__FILE__))
      }
      TimingAudit.atomic_write(
        File.join(output_dir, "materialized", "summary-#{scope}.yaml"),
        YAML.dump(summary)
      )
      raise "#{failures.size} corrected programs failed compilation: #{failures.map { |result| result.fetch('program_id') }.join(', ')}" unless failures.empty?
      puts "Materialized and compiled #{ids.size} #{scope} timing fixes; changed #{changed_paths.size} files"
      summary
    end
  end

  def materialize_originals(staging, ids, records_by_id, source_root)
    ids.each do |id|
      record = records_by_id.fetch(id)
      record.fetch("source_files").each do |file|
        source = File.join(source_root, file.fetch("git_path"))
        bytes = File.binread(source)
        raise "Source hash changed for #{file.fetch('git_path')}" unless TimingAudit.sha256_bytes(bytes) == file.fetch("sha256")
        destination = File.join(staging, file.fetch("git_path"))
        FileUtils.mkdir_p(File.dirname(destination))
        File.binwrite(destination, bytes)
      end
    end
  end

  def initialize_baseline(staging)
    TimingAudit.capture!("git", "-C", staging, "init", "-q")
    TimingAudit.capture!("git", "-C", staging, "config", "user.email", "timing-fix@localhost")
    TimingAudit.capture!("git", "-C", staging, "config", "user.name", "Timing Fix Materializer")
    TimingAudit.capture!("git", "-C", staging, "add", "--all")
    TimingAudit.capture!("git", "-C", staging, "commit", "-q", "-m", "Pinned timing-fix baseline")
  end

  def apply_proposals(staging, ids, records_by_id, proposals, validator)
    changed = []
    ids.each do |id|
      record = records_by_id.fetch(id)
      validator.materialize(proposals.fetch(id), expected_id: id).each do |relative, content|
        path = File.join(staging, record.fetch("source_prefix"), relative)
        raise "Materialized edit path missing: #{path}" unless File.file?(path)
        File.binwrite(path, content)
        changed << File.join(record.fetch("source_prefix"), relative)
      end
    end
    changed.uniq.sort
  end

  def verify_changed_paths(staging, expected)
    actual = git_capture(staging, "diff", "--name-only", "--").lines(chomp: true).sort
    raise "Changed path set does not match proposal edits" unless actual == expected
  end

  def compile_all(staging:, output_dir:, scope:, records:, jobs:)
    queue = Queue.new
    records.each { |record| queue << record }
    jobs.times { queue << nil }
    mutex = Mutex.new
    results = []
    workers = jobs.times.map do |worker|
      Thread.new do
        while (record = queue.pop)
          result = compile_one(staging, output_dir, scope, record, worker + 1)
          mutex.synchronize do
            results << result
            state = result.fetch("success") ? "compiled" : "FAILED"
            puts "[#{worker + 1}] #{state} #{record.fetch('id')} (#{results.size}/#{records.size})"
          end
        end
      end
    end
    workers.each(&:join)
    results.sort_by { |result| result.fetch("program_id") }
  end

  def compile_one(staging, output_dir, scope, record, worker)
    id = record.fetch("id")
    source_dir = File.join(staging, record.fetch("source_prefix"), record.fetch("benchmark"))
    build_root = File.join(staging, ".builds")
    build_dir = File.join(build_root, id)
    FileUtils.mkdir_p(build_dir)
    log_dir = File.join(output_dir, "compile", scope, id)
    FileUtils.mkdir_p(log_dir)
    configure = [
      "cmake", "-S", source_dir, "-B", build_dir,
      "-DCMAKE_BUILD_TYPE=Release",
      "-DCMAKE_C_COMPILER=#{C_COMPILER}",
      "-DCMAKE_CXX_COMPILER=#{CXX_COMPILER}"
    ]
    if record.fetch("par_type") == "hybrid"
      configure.concat([
        "-DCMAKE_CUDA_ARCHITECTURES=86",
        "-DCMAKE_CUDA_COMPILER=#{CUDA_COMPILER}",
        "-DCUDAToolkit_ROOT=#{CUDA_ROOT}"
      ])
    end
    configured = run_command(configure, File.join(log_dir, "configure.log"), CONFIGURE_TIMEOUT, source_dir)
    built = if configured.fetch("success")
      run_command(
        ["cmake", "--build", build_dir, "--parallel", "2"],
        File.join(log_dir, "build.log"),
        BUILD_TIMEOUT,
        source_dir
      )
    else
      { "success" => false, "skipped" => true }
    end
    result = {
      "program_id" => id,
      "worker" => worker,
      "par_type" => record.fetch("par_type"),
      "source_digest" => record.fetch("source_digest"),
      "configure" => configured,
      "build" => built,
      "success" => configured.fetch("success") && built.fetch("success"),
      "program_executed" => false
    }
    TimingAudit.atomic_write(File.join(log_dir, "metadata.yaml"), YAML.dump(result))
    FileUtils.remove_entry_secure(build_dir) if File.directory?(build_dir)
    result
  rescue Exception => error
    result = {
      "program_id" => id,
      "worker" => worker,
      "success" => false,
      "program_executed" => false,
      "error" => "#{error.class}: #{error.message}"
    }
    TimingAudit.atomic_write(File.join(log_dir, "metadata.yaml"), YAML.dump(result)) if defined?(log_dir)
    result
  end

  def run_command(argv, log_path, timeout, chdir)
    started_at = TimingAudit.utc_now
    started = TimingAudit.monotonic_now
    status = nil
    timed_out = false
    File.open(log_path, "wb") do |log|
      pid = Process.spawn(*argv, out: log, err: log, chdir: chdir, pgroup: true, rlimit_core: [0, 0])
      loop do
        waited, status = Process.wait2(pid, Process::WNOHANG)
        break if waited
        if TimingAudit.monotonic_now - started >= timeout
          timed_out = true
          terminate_group(pid)
          _waited, status = Process.wait2(pid)
          break
        end
        sleep 0.2
      end
    end
    {
      "argv" => argv,
      "started_at" => started_at,
      "finished_at" => TimingAudit.utc_now,
      "wall_seconds" => TimingAudit.monotonic_now - started,
      "timed_out" => timed_out,
      "exit_code" => status&.exitstatus,
      "term_signal" => status&.termsig,
      "success" => !timed_out && status&.success?
    }
  end

  def terminate_group(pid)
    Process.kill("TERM", -pid)
    deadline = TimingAudit.monotonic_now + 5
    while TimingAudit.monotonic_now < deadline
      begin
        Process.kill(0, -pid)
      rescue Errno::ESRCH
        return
      end
      sleep 0.1
    end
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH
    nil
  end

  def git_capture(staging, *args)
    TimingAudit.capture!("git", "-C", staging, *args)
  end
end
