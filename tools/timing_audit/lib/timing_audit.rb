# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "securerandom"
require "tempfile"
require "tmpdir"
require "yaml"

module TimingAudit
  SCHEMA_VERSION = 1
  INVENTORY_VERSION = 1
  TRIAL_SELECTION_VERSION = 1
  DEFAULT_RELEASE_ROOT = "/home/petert/llm-eval-local"
  DEFAULT_SOURCE_ROOT = "/home/petert/llm_para_experiments"
  DEFAULT_OUTPUT_ROOT = "/home/petert/llm_timing_audit"
  DEFAULT_MODEL = "gpt-5.6-luna"
  DEFAULT_EFFORT = "high"
  DEFAULT_TIMEOUT_SECONDS = 15 * 60
  DEFAULT_RETRIES = 3
  DEFAULT_TRIAL_SIZE = 16
  DEFAULT_TRIAL_JOBS = 4
  DEFAULT_FULL_JOBS = 16
  KNOWN_INVALID_PILOT = "black-scholes_qwen-3.6-27B-udq4_mpi_r5"

  METRIC_LABELS = {
    "black-scholes" => "Computation time",
    "cahn-hilliard" => "Computation time",
    "cholesky" => "Computation time",
    "floydwarshall" => "Computation time",
    "matmul" => "Computation time",
    "nbody" => "Simulation time",
    "qtclustering" => "Clustering time",
    "roomsim" => "Total computation time",
    "spmv" => "Computation time",
    "stencil3d" => "Computation time",
    "unstructured" => "Computation time"
  }.freeze

  SOURCE_EXTENSIONS = %w[
    .c .cc .cpp .cxx .cu .h .hh .hpp .hxx .cuh .inl .inc .cmake
  ].freeze
  SOURCE_BASENAMES = %w[CMakeLists.txt Makefile instruction.txt].freeze
  MAX_SOURCE_FILES = 64
  MAX_SOURCE_FILE_BYTES = 1024 * 1024
  MAX_SOURCE_TOTAL_BYTES = 2 * 1024 * 1024
  MAX_PROMPT_BYTES = 3 * 1024 * 1024

  REQUIRED_RESULT_KEYS = %w[
    program_id verdict issue_categories confidence timed_region
    start_synchronization stop_synchronization rank_aggregation reported_value
    semantic_equivalence_basis evidence timing_only_fix_possible minimal_fix notes
  ].freeze
  VERDICTS = %w[valid invalid ambiguous].freeze
  CONFIDENCES = %w[high medium low].freeze
  ISSUE_CATEGORIES = %w[
    none missing_start_synchronization missing_stop_synchronization
    missing_rank_aggregation rank_local_timing non_maximum_aggregation
    wrong_mpi_datatype asymmetric_timed_region incomplete_timed_region
    includes_unintended_work missing_device_synchronization timer_unit_error
    reported_value_mismatch unsynchronized_clocks other
  ].freeze

  DISABLED_FEATURES = %w[
    apps auth_elicitation browser_use browser_use_external
    browser_use_full_cdp_access computer_use in_app_browser in_app_updates
    image_generation memories mentions_v2 multi_agent multi_agent_v2
    plugin_sharing plugins remote_plugin skill_mcp_dependency_install
    tool_call_mcp_elicitation tool_suggest workspace_dependencies
  ].freeze

  module_function

  def sha256_bytes(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def sha256_file(path)
    Digest::SHA256.file(path).hexdigest
  end

  def utc_now
    Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def atomic_write(path, content)
    path = File.expand_path(path)
    FileUtils.mkdir_p(File.dirname(path))
    temporary = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}-#{SecureRandom.hex(4)}"
    File.open(temporary, "wb", 0o644) do |file|
      file.write(content)
      file.flush
      file.fsync
    end
    File.rename(temporary, path)
  ensure
    FileUtils.rm_f(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
  end

  def load_jsonl(path)
    File.foreach(path, chomp: true).filter_map do |line|
      next if line.empty?
      JSON.parse(line)
    end
  end

  def dump_jsonl(records)
    records.map { |record| JSON.generate(record) }.join("\n") + "\n"
  end

  def capture!(*argv)
    stdout, stderr, status = Open3.capture3(*argv)
    return stdout if status.success?

    raise "Command failed (#{argv.join(' ')}): #{stderr.strip}"
  end

  class SourceRepository
    attr_reader :root, :commit

    def initialize(root:, commit:)
      @root = File.realpath(root)
      @commit = commit.to_s
      raise "Invalid source commit #{@commit.inspect}" unless @commit.match?(/\A[0-9a-f]{40}\z/)

      head = TimingAudit.capture!("git", "-C", @root, "rev-parse", "HEAD").strip
      raise "Generated source HEAD #{head} does not match pinned commit #{@commit}" unless head == @commit

      _stdout, stderr, status = Open3.capture3("git", "-C", @root, "diff", "--quiet", @commit, "--")
      raise "Generated source repository has tracked modifications: #{stderr.strip}" unless status.success?

      raw_paths = TimingAudit.capture!("git", "-C", @root, "ls-tree", "-r", "-z", "--name-only", @commit)
      @paths_by_prefix = Hash.new { |hash, key| hash[key] = [] }
      raw_paths.split("\0").each do |path|
        components = path.split("/", 3)
        next unless components.size == 3
        @paths_by_prefix[components.first(2).join("/")] << path
      end
      @tree_oid_cache = {}
    end

    def source_record(prefix)
      validate_prefix!(prefix)
      paths = @paths_by_prefix.fetch(prefix) do
        raise "No tracked source directory #{prefix.inspect} at #{@commit}"
      end
      selected = paths.select { |path| source_file?(path.delete_prefix("#{prefix}/")) }.sort
      raise "No source files selected for #{prefix}" if selected.empty?
      raise "Too many source files for #{prefix}: #{selected.size}" if selected.size > MAX_SOURCE_FILES

      total = 0
      aggregate = Digest::SHA256.new
      static_source = +""
      files = selected.map do |git_path|
        relative = git_path.delete_prefix("#{prefix}/")
        bytes = read_tracked(git_path)
        raise "Source file too large: #{git_path}" if bytes.bytesize > MAX_SOURCE_FILE_BYTES
        total += bytes.bytesize
        raise "Source dossier too large for #{prefix}" if total > MAX_SOURCE_TOTAL_BYTES

        aggregate << relative << "\0" << bytes << "\0"
        static_source << bytes unless relative == "instruction.txt"
        {
          "path" => relative,
          "git_path" => git_path,
          "sha256" => TimingAudit.sha256_bytes(bytes),
          "bytes" => bytes.bytesize,
          "lines" => bytes.empty? ? 0 : bytes.lines.count
        }
      end

      {
        "source_tree_oid" => tree_oid(prefix),
        "source_digest" => aggregate.hexdigest,
        "source_total_bytes" => total,
        "source_files" => files,
        "static_features" => static_features(static_source)
      }
    end

    def dossier(record)
      aggregate = Digest::SHA256.new
      chunks = record.fetch("source_files").map do |file_record|
        relative = file_record.fetch("path")
        bytes = read_tracked(file_record.fetch("git_path"))
        actual = TimingAudit.sha256_bytes(bytes)
        unless actual == file_record.fetch("sha256")
          raise "Source hash changed for #{record.fetch('id')}/#{relative}"
        end
        aggregate << relative << "\0" << bytes << "\0"
        numbered = bytes.lines.each_with_index.map do |line, index|
          format("%6d | %s", index + 1, line)
        end.join
        numbered << format("%6d |\n", 1) if bytes.empty?
        "===== FILE #{relative} (sha256 #{actual}) =====\n#{numbered}"
      end
      unless aggregate.hexdigest == record.fetch("source_digest")
        raise "Aggregate source digest changed for #{record.fetch('id')}"
      end
      chunks.join("\n")
    end

    private

    def validate_prefix!(prefix)
      path = Pathname.new(prefix)
      raise "Unsafe source prefix #{prefix.inspect}" if path.absolute? || path.each_filename.any? { |part| part == ".." }
      raise "Unexpected source prefix #{prefix.inspect}" unless prefix.split("/").size == 2
    end

    def source_file?(relative)
      components = relative.split("/")
      return false if components.any? { |part| %w[build CMakeFiles .git].include?(part) }
      SOURCE_BASENAMES.include?(File.basename(relative)) || SOURCE_EXTENSIONS.include?(File.extname(relative).downcase)
    end

    def read_tracked(git_path)
      path = File.join(@root, git_path)
      real = File.realpath(path)
      unless real == @root || real.start_with?("#{@root}/")
        raise "Tracked source escapes repository: #{git_path}"
      end
      bytes = File.binread(real)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise "Source is not UTF-8: #{git_path}" unless text.valid_encoding?
      text
    end

    def tree_oid(prefix)
      @tree_oid_cache[prefix] ||= TimingAudit.capture!(
        "git", "-C", @root, "rev-parse", "#{@commit}:#{prefix}"
      ).strip
    end

    def static_features(source)
      timers = []
      timers << "MPI_Wtime" if source.include?("MPI_Wtime")
      timers << "chrono" if source.match?(/std::chrono|high_resolution_clock|steady_clock/)
      timers << "omp_get_wtime" if source.include?("omp_get_wtime")
      timers << "cudaEvent" if source.include?("cudaEvent")
      timers << "clock_gettime" if source.include?("clock_gettime")
      {
        "has_mpi_max" => source.include?("MPI_MAX"),
        "has_mpi_min" => source.include?("MPI_MIN"),
        "has_mpi_reduce" => source.match?(/MPI_(?:All)?Reduce\s*\(/),
        "has_mpi_gather" => source.match?(/MPI_(?:Gatherv|Gather)\s*\(/),
        "has_mpi_barrier" => source.include?("MPI_Barrier"),
        "has_cuda" => source.match?(/cuda[A-Z]|<<<|cublas|cusparse/i),
        "has_device_synchronization" => source.match?(/cudaDeviceSynchronize|cudaEventSynchronize|cudaStreamSynchronize/),
        "timer_apis" => timers
      }
    end
  end

  class InventoryBuilder
    attr_reader :release_root, :source_root, :output_dir, :trial_size

    def initialize(release_root:, source_root:, output_dir:, trial_size: DEFAULT_TRIAL_SIZE)
      @release_root = File.realpath(release_root)
      @source_root = File.realpath(source_root)
      @output_dir = File.expand_path(output_dir)
      @trial_size = Integer(trial_size)
      raise "Trial size must be positive" unless @trial_size.positive?
    end

    def run
      raise "Output already exists: #{@output_dir}" if File.exist?(@output_dir)
      FileUtils.mkdir_p(@output_dir)

      repositories_path = File.join(@release_root, "data/provenance/repositories.yaml")
      repositories = YAML.safe_load(File.read(repositories_path), aliases: false)
      generated = repositories.fetch("generated_programs")
      commit = generated.fetch("commit")
      repository = SourceRepository.new(root: @source_root, commit: commit)
      dataset_path = File.join(@release_root, "data/scoring/scored_results.csv")
      records = selected_rows(dataset_path)
      puts "Preparing immutable source metadata for #{records.size} successful MPI/hybrid records"

      records.each_with_index do |record, index|
        record.merge!(repository.source_record(record.fetch("source_prefix")))
        puts "  prepared #{index + 1}/#{records.size}" if ((index + 1) % 100).zero? || index + 1 == records.size
      end

      trial_ids = TrialSelector.new(records, @trial_size).select
      template_path = File.expand_path("../prompts/timing_audit_prompt.txt", __dir__)
      schema_path = File.expand_path("../schemas/timing_audit_schema.json", __dir__)
      runner_path = File.expand_path(__FILE__)
      copied_template = File.join(@output_dir, "prompt-template.txt")
      copied_schema = File.join(@output_dir, "result-schema.json")
      copied_runner = File.join(@output_dir, "runner-snapshot.rb")
      TimingAudit.atomic_write(copied_template, File.binread(template_path))
      TimingAudit.atomic_write(copied_schema, File.binread(schema_path))
      TimingAudit.atomic_write(copied_runner, File.binread(runner_path))
      TimingAudit.atomic_write(File.join(@output_dir, "inventory.jsonl"), TimingAudit.dump_jsonl(records))
      TimingAudit.atomic_write(File.join(@output_dir, "trial-ids.txt"), trial_ids.join("\n") + "\n")

      manifest = {
        "schema_version" => SCHEMA_VERSION,
        "inventory_version" => INVENTORY_VERSION,
        "trial_selection_version" => TRIAL_SELECTION_VERSION,
        "created_at" => TimingAudit.utc_now,
        "release_root" => @release_root,
        "dataset_path" => dataset_path,
        "dataset_sha256" => TimingAudit.sha256_file(dataset_path),
        "selection" => {
          "parallelization_types" => %w[mpi hybrid],
          "validation_status" => 5,
          "benchmark_success" => true,
          "records" => records.size
        },
        "generated_source" => {
          "root" => @source_root,
          "repository" => generated.fetch("repository"),
          "commit" => commit
        },
        "contract" => "maximum per-rank completed computation time or demonstrably equivalent global makespan",
        "trial" => { "size" => trial_ids.size, "ids" => trial_ids },
        "artifacts" => {
          "prompt_template_sha256" => TimingAudit.sha256_file(copied_template),
          "result_schema_sha256" => TimingAudit.sha256_file(copied_schema),
          "runner_sha256" => TimingAudit.sha256_file(copied_runner)
        }
      }
      TimingAudit.atomic_write(File.join(@output_dir, "manifest.yaml"), YAML.dump(manifest))
      puts "Prepared #{@output_dir}"
      puts "Trial IDs:"
      trial_ids.each { |id| puts "  #{id}" }
      manifest
    rescue Exception
      FileUtils.remove_entry_secure(@output_dir) if File.directory?(@output_dir) && !File.exist?(File.join(@output_dir, "manifest.yaml"))
      raise
    end

    private

    def selected_rows(dataset_path)
      source_prefixes = {}
      records = CSV.foreach(dataset_path, headers: true).filter_map do |row|
        next unless %w[mpi hybrid].include?(row.fetch("par_type"))
        next unless row.fetch("validation_status").to_i == 5
        next unless row.fetch("benchmark_success") == "true"

        source_path = File.expand_path(row.fetch("source_path"))
        relative = Pathname.new(source_path).relative_path_from(Pathname.new(@source_root)).to_s
        raise "Source escapes generated repository: #{source_path}" if relative.start_with?("../")
        id = File.basename(source_path)
        raise "Duplicate program ID #{id}" if source_prefixes.key?(id)
        source_prefixes[id] = relative
        benchmark = row.fetch("benchmark")
        {
          "id" => id,
          "benchmark" => benchmark,
          "model" => row.fetch("model"),
          "par_type" => row.fetch("par_type"),
          "run" => row.fetch("run").to_i,
          "source_batch" => row.fetch("source_batch"),
          "source_prefix" => relative,
          "metric_label" => METRIC_LABELS.fetch(benchmark),
          "benchmark_median_time_ms" => row.fetch("benchmark_median_time").to_f,
          "overall_score" => row.fetch("overall_score").to_i,
          "benchmark_config_sha256" => row.fetch("benchmark_config_sha256")
        }
      end
      raise "Expected selected audit records" if records.empty?
      records.sort_by { |record| record.fetch("id") }
    end
  end

  class TrialSelector
    def initialize(records, size)
      @records = records
      @size = [Integer(size), records.size].min
    end

    def select
      selected = []
      pilot = @records.find { |record| record.fetch("id") == KNOWN_INVALID_PILOT }
      selected << pilot if pilot

      while selected.size < @size
        remaining = @records - selected
        candidate = remaining.min_by { |record| selection_key(record, selected) }
        selected << candidate
      end
      selected.map { |record| record.fetch("id") }
    end

    private

    def selection_key(record, selected)
      features = record.fetch("static_features")
      max_group = features.fetch("has_mpi_max") ? "max" : "no-max"
      [
        selected.count { |entry| entry.fetch("benchmark") == record.fetch("benchmark") },
        selected.count { |entry| entry.fetch("par_type") == record.fetch("par_type") },
        selected.count do |entry|
          (entry.fetch("static_features").fetch("has_mpi_max") ? "max" : "no-max") == max_group
        end,
        selected.count { |entry| entry.fetch("model") == record.fetch("model") },
        record.fetch("overall_score") >= 9 ? 0 : 1,
        Digest::SHA256.hexdigest(record.fetch("id"))
      ]
    end
  end

  class ResultValidator
    def initialize(records)
      @records = records.to_h { |record| [record.fetch("id"), record] }
    end

    def validate!(result, expected_id:)
      raise "Result is not an object" unless result.is_a?(Hash)
      missing = REQUIRED_RESULT_KEYS - result.keys
      extra = result.keys - REQUIRED_RESULT_KEYS
      raise "Missing result keys: #{missing.join(', ')}" unless missing.empty?
      raise "Unexpected result keys: #{extra.join(', ')}" unless extra.empty?
      raise "Program ID mismatch: #{result['program_id'].inspect}" unless result.fetch("program_id") == expected_id
      raise "Invalid verdict" unless VERDICTS.include?(result.fetch("verdict"))
      raise "Invalid confidence" unless CONFIDENCES.include?(result.fetch("confidence"))

      categories = result.fetch("issue_categories")
      raise "issue_categories must be a non-empty unique array" unless categories.is_a?(Array) && !categories.empty? && categories.uniq == categories
      unknown = categories - ISSUE_CATEGORIES
      raise "Unknown issue categories: #{unknown.join(', ')}" unless unknown.empty?
      if result.fetch("verdict") == "valid"
        raise "Valid result must use only the none category" unless categories == ["none"]
        raise "Valid result cannot request a timing fix" unless result.fetch("timing_only_fix_possible") == false
        raise "Valid result must have an empty minimal_fix" unless result.fetch("minimal_fix") == ""
      elsif categories.include?("none")
        raise "Non-valid result cannot use the none category"
      end

      %w[timed_region start_synchronization stop_synchronization rank_aggregation reported_value].each do |key|
        raise "#{key} must be non-empty text" unless result[key].is_a?(String) && !result[key].strip.empty?
      end
      %w[semantic_equivalence_basis minimal_fix notes].each do |key|
        raise "#{key} must be text" unless result[key].is_a?(String)
      end
      unless [true, false].include?(result.fetch("timing_only_fix_possible"))
        raise "timing_only_fix_possible must be boolean"
      end

      record = @records.fetch(expected_id)
      line_counts = record.fetch("source_files").to_h { |file| [file.fetch("path"), file.fetch("lines")] }
      evidence = result.fetch("evidence")
      raise "Evidence must be a non-empty array" unless evidence.is_a?(Array) && !evidence.empty?
      evidence.each do |entry|
        raise "Evidence entry must be an object" unless entry.is_a?(Hash)
        raise "Evidence keys are invalid" unless entry.keys.sort == %w[finding lines path]
        path = entry.fetch("path")
        maximum = line_counts.fetch(path) { raise "Evidence cites unavailable path #{path.inspect}" }
        match = /\A(\d+)(?:-(\d+))?\z/.match(entry.fetch("lines").to_s)
        raise "Invalid evidence line range" unless match
        first = match[1].to_i
        last = (match[2] || match[1]).to_i
        raise "Invalid evidence line order" unless first.positive? && last >= first
        raise "Evidence line #{last} exceeds #{path} line count #{maximum}" if last > maximum
        raise "Evidence finding must be non-empty" unless entry.fetch("finding").is_a?(String) && !entry.fetch("finding").strip.empty?
      end
      true
    end
  end

  class CodexCommand
    attr_reader :model, :effort

    def initialize(model:, effort:)
      @model = model
      @effort = effort
    end

    def argv(schema_path:, output_path:)
      command = [
        "codex", "exec",
        "--model", @model,
        "--config", %(model_reasoning_effort="#{@effort}"),
        "--config", 'approval_policy="never"',
        "--sandbox", "read-only",
        "--ephemeral",
        "--ignore-user-config",
        "--strict-config",
        "--skip-git-repo-check",
        "--output-schema", schema_path,
        "--output-last-message", output_path,
        "--json",
        "--color", "never"
      ]
      DISABLED_FEATURES.each { |feature| command.concat(["--disable", feature]) }
      command << "-"
      command
    end
  end

  class AuditRunner
    def initialize(output_dir:, scope:, jobs:, model: DEFAULT_MODEL, effort: DEFAULT_EFFORT,
                   timeout: DEFAULT_TIMEOUT_SECONDS, retries: DEFAULT_RETRIES, only_ids: [])
      @output_dir = File.realpath(output_dir)
      @scope = scope.to_s
      raise "Scope must be trial or full" unless %w[trial full].include?(@scope)
      @jobs = Integer(jobs)
      raise "Jobs must be positive" unless @jobs.positive?
      @model = model
      @effort = effort
      @timeout = Integer(timeout)
      @retries = Integer(retries)
      @only_ids = Array(only_ids).map(&:to_s)
      raise "Timeout and retries must be positive" unless @timeout.positive? && @retries.positive?

      @manifest = YAML.safe_load(File.read(File.join(@output_dir, "manifest.yaml")), aliases: false)
      @records = TimingAudit.load_jsonl(File.join(@output_dir, "inventory.jsonl"))
      @records_by_id = @records.to_h { |record| [record.fetch("id"), record] }
      @validator = ResultValidator.new(@records)
      generated = @manifest.fetch("generated_source")
      @repository = SourceRepository.new(root: generated.fetch("root"), commit: generated.fetch("commit"))
      @template = File.read(File.join(@output_dir, "prompt-template.txt"))
      @schema_path = File.join(@output_dir, "result-schema.json")
      verify_artifact_hashes!
      @command = CodexCommand.new(model: @model, effort: @effort)
      @mutex = Mutex.new
      @completed_this_run = 0
      @failures = []
    end

    def run
      ids = selected_ids
      pending = ids.reject { |id| valid_existing_result?(id) }
      puts "Timing audit #{@scope}: #{ids.size} selected, #{ids.size - pending.size} complete, #{pending.size} pending, #{@jobs} workers"
      update_progress(ids)
      queue = Queue.new
      pending.each { |id| queue << id }
      @jobs.times { queue << nil }

      workers = @jobs.times.map do |worker_index|
        Thread.new do
          while (id = queue.pop)
            begin
              run_with_retries(id, worker_index + 1)
            rescue Exception => error
              @mutex.synchronize do
                @failures << [id, error]
                warn "FAILED #{id}: #{error.class}: #{error.message}"
              end
            ensure
              update_progress(ids)
            end
          end
        end
      end
      workers.each(&:join)
      unless @failures.empty?
        details = @failures.map { |id, error| "#{id}: #{error.class}: #{error.message}" }.join("\n")
        raise "#{@failures.size} audit jobs failed after retries:\n#{details}"
      end

      if ids.sort == scope_ids.sort
        AuditVerifier.new(@output_dir, @scope).run
      else
        puts "Completed and validated requested subset: #{ids.size} record(s)"
      end
    end

    private

    def selected_ids
      ids = scope_ids
      return ids if @only_ids.empty?

      unknown = @only_ids - ids
      raise "Requested IDs are outside #{@scope} scope: #{unknown.join(', ')}" unless unknown.empty?
      @only_ids
    end

    def scope_ids
      return @records.map { |record| record.fetch("id") } if @scope == "full"

      File.readlines(File.join(@output_dir, "trial-ids.txt"), chomp: true).reject(&:empty?)
    end

    def verify_artifact_hashes!
      artifacts = @manifest.fetch("artifacts")
      {
        "prompt_template_sha256" => File.join(@output_dir, "prompt-template.txt"),
        "result_schema_sha256" => @schema_path,
        "runner_sha256" => File.join(@output_dir, "runner-snapshot.rb")
      }.each do |key, path|
        actual = TimingAudit.sha256_file(path)
        raise "Audit artifact digest mismatch for #{path}" unless actual == artifacts.fetch(key)
      end
      current_runner = TimingAudit.sha256_file(__FILE__)
      unless current_runner == artifacts.fetch("runner_sha256")
        raise "Current timing-audit runner differs from the prepared immutable snapshot"
      end
    end

    def valid_existing_result?(id)
      path = result_path(id)
      return false unless File.file?(path)
      @validator.validate!(JSON.parse(File.read(path)), expected_id: id)
    rescue StandardError => error
      warn "Ignoring invalid existing result #{id}: #{error.message}"
      false
    end

    def run_with_retries(id, worker)
      record = @records_by_id.fetch(id)
      prompt = build_prompt(record)
      raise "Prompt exceeds #{MAX_PROMPT_BYTES} bytes for #{id}" if prompt.bytesize > MAX_PROMPT_BYTES
      last_error = nil
      @retries.times do |offset|
        attempt = offset + 1
        begin
          run_attempt(record, prompt, attempt, worker)
          @mutex.synchronize do
            @completed_this_run += 1
            puts format("[%d] complete %s (%d new)", worker, id, @completed_this_run)
          end
          return
        rescue Exception => error
          last_error = error
          @mutex.synchronize { warn "[#{worker}] attempt #{attempt}/#{@retries} failed for #{id}: #{error.message}" }
          sleep([2**attempt, 20].min + rand) if attempt < @retries
        end
      end
      raise last_error
    end

    def build_prompt(record)
      dossier = @repository.dossier(record)
      @template % {
        program_id: record.fetch("id"),
        benchmark: record.fetch("benchmark"),
        par_type: record.fetch("par_type"),
        metric_label: record.fetch("metric_label"),
        dossier: dossier
      }
    end

    def run_attempt(record, prompt, attempt, worker)
      id = record.fetch("id")
      attempt_dir = File.join(@output_dir, "logs", id, format("attempt-%02d", attempt))
      FileUtils.mkdir_p(attempt_dir)
      stdout_path = File.join(attempt_dir, "events.jsonl")
      stderr_path = File.join(attempt_dir, "stderr.log")
      metadata_path = File.join(attempt_dir, "metadata.yaml")
      started_at = TimingAudit.utc_now
      started = TimingAudit.monotonic_now
      status = nil
      timed_out = false

      Dir.mktmpdir("llm-timing-audit-") do |temporary_dir|
        last_message = File.join(temporary_dir, "last-message.json")
        argv = @command.argv(schema_path: @schema_path, output_path: last_message)
        Tempfile.create(["timing-audit-prompt-", ".txt"], temporary_dir) do |input|
          input.binmode
          input.write(prompt)
          input.flush
          input.rewind
          File.open(stdout_path, "wb") do |stdout|
            File.open(stderr_path, "wb") do |stderr|
              pid = Process.spawn(*argv, in: input, out: stdout, err: stderr,
                                  chdir: temporary_dir, pgroup: true, rlimit_core: [0, 0])
              loop do
                waited, status = Process.wait2(pid, Process::WNOHANG)
                break if waited
                if TimingAudit.monotonic_now - started >= @timeout
                  timed_out = true
                  terminate_group(pid)
                  _waited, status = Process.wait2(pid)
                  break
                end
                sleep 0.2
              end
            end
          end
        end

        wall = TimingAudit.monotonic_now - started
        metadata = {
          "program_id" => id,
          "worker" => worker,
          "attempt" => attempt,
          "started_at" => started_at,
          "finished_at" => TimingAudit.utc_now,
          "wall_seconds" => wall,
          "timed_out" => timed_out,
          "exit_code" => status&.exitstatus,
          "term_signal" => status&.termsig,
          "model" => @model,
          "reasoning_effort" => @effort,
          "prompt_sha256" => TimingAudit.sha256_bytes(prompt),
          "prompt_bytes" => prompt.bytesize,
          "source_digest" => record.fetch("source_digest"),
          "source_tree_oid" => record.fetch("source_tree_oid"),
          "runner_sha256" => @manifest.fetch("artifacts").fetch("runner_sha256")
        }
        TimingAudit.atomic_write(metadata_path, YAML.dump(metadata))
        raise "Codex invocation timed out after #{@timeout}s" if timed_out
        raise "Codex exited #{status&.exitstatus || 'without status'}" unless status&.success?
        raise "Codex did not write its last message" unless File.file?(last_message)

        raw = File.read(last_message)
        result = JSON.parse(raw)
        @validator.validate!(result, expected_id: id)
        TimingAudit.atomic_write(result_path(id), JSON.pretty_generate(result) + "\n")
      end
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

    def result_path(id)
      File.join(@output_dir, "results", "#{id}.json")
    end

    def update_progress(ids)
      @mutex.synchronize do
        complete = ids.count { |id| File.file?(result_path(id)) }
        progress = {
          "updated_at" => TimingAudit.utc_now,
          "scope" => @scope,
          "selected" => ids.size,
          "complete" => complete,
          "pending" => ids.size - complete,
          "failures_this_run" => @failures.size
        }
        TimingAudit.atomic_write(File.join(@output_dir, "progress-#{@scope}.yaml"), YAML.dump(progress))
      end
    end
  end

  class AuditVerifier
    def initialize(output_dir, scope)
      @output_dir = File.realpath(output_dir)
      @scope = scope.to_s
      raise "Scope must be trial or full" unless %w[trial full].include?(@scope)
      @records = TimingAudit.load_jsonl(File.join(@output_dir, "inventory.jsonl"))
      @records_by_id = @records.to_h { |record| [record.fetch("id"), record] }
      @validator = ResultValidator.new(@records)
    end

    def run
      ids = if @scope == "trial"
        File.readlines(File.join(@output_dir, "trial-ids.txt"), chomp: true).reject(&:empty?)
      else
        @records.map { |record| record.fetch("id") }
      end
      results = ids.map do |id|
        path = File.join(@output_dir, "results", "#{id}.json")
        raise "Missing result #{id}" unless File.file?(path)
        result = JSON.parse(File.read(path))
        @validator.validate!(result, expected_id: id)
        result
      end
      write_summary(results)
      counts = results.group_by { |result| result.fetch("verdict") }.transform_values(&:size)
      puts "Verified #{@scope} timing audit: #{results.size} records (#{VERDICTS.map { |v| "#{v}=#{counts.fetch(v, 0)}" }.join(', ')})"
      if @scope == "trial"
        pilot = results.find { |result| result.fetch("program_id") == KNOWN_INVALID_PILOT }
        raise "Known pilot was not selected" unless pilot
        raise "Known invalid pilot was classified #{pilot.fetch('verdict')}" unless pilot.fetch("verdict") == "invalid"
        raise "Trial produced no valid result; rubric/output usability needs review" unless results.any? { |result| result.fetch("verdict") == "valid" }
        raise "Trial produced no invalid result; rubric/output usability needs review" unless results.any? { |result| result.fetch("verdict") == "invalid" }
      end
      true
    end

    private

    def write_summary(results)
      enriched = results.map do |result|
        record = @records_by_id.fetch(result.fetch("program_id"))
        {
          "program_id" => result.fetch("program_id"),
          "benchmark" => record.fetch("benchmark"),
          "model" => record.fetch("model"),
          "par_type" => record.fetch("par_type"),
          "run" => record.fetch("run"),
          "overall_score" => record.fetch("overall_score"),
          "benchmark_median_time_ms" => record.fetch("benchmark_median_time_ms"),
          "source_tree_oid" => record.fetch("source_tree_oid"),
          "source_digest" => record.fetch("source_digest"),
          "verdict" => result.fetch("verdict"),
          "confidence" => result.fetch("confidence"),
          "issue_categories" => result.fetch("issue_categories"),
          "timing_only_fix_possible" => result.fetch("timing_only_fix_possible")
        }
      end
      TimingAudit.atomic_write(
        File.join(@output_dir, "summary-#{@scope}.jsonl"),
        TimingAudit.dump_jsonl(enriched)
      )
      headers = %w[
        program_id benchmark model par_type run overall_score benchmark_median_time_ms
        source_tree_oid source_digest verdict confidence issue_categories timing_only_fix_possible
      ]
      csv = CSV.generate do |output|
        output << headers
        enriched.each do |entry|
          output << headers.map do |header|
            value = entry.fetch(header)
            value.is_a?(Array) ? value.join(";") : value
          end
        end
      end
      TimingAudit.atomic_write(File.join(@output_dir, "summary-#{@scope}.csv"), csv)
    end
  end
end
