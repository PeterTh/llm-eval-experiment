require "csv"
require "digest"
require "find"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "shellwords"
require "time"
require "tmpdir"
require "yaml"

module LocalEvaluation
  SCHEMA_VERSION = 1
  PAR_TYPES = %w[omp cuda mpi hybrid].freeze
  CUDA_ROOT = ENV.fetch("LOCAL_EVALUATION_CUDA_ROOT", "/usr/local/cuda")
  CUDA_COMPILER = ENV.fetch("LOCAL_EVALUATION_NVCC", File.join(CUDA_ROOT, "bin", "nvcc"))
  C_COMPILER = File.expand_path(ENV.fetch("LOCAL_EVALUATION_CC", "/usr/bin/gcc-13"))
  CXX_COMPILER = File.expand_path(ENV.fetch("LOCAL_EVALUATION_CXX", "/usr/bin/g++-13"))
  BENCHMARKS = %w[
    black-scholes cahn-hilliard cholesky floydwarshall matmul nbody
    qtclustering roomsim spmv stencil3d unstructured
  ].freeze
  RUN_ID_RE = /\A(?<base>.+)_(?<par_type>omp|cuda|mpi|hybrid)_r(?<run>\d+)\z/
  GIBIBYTE = 1024 * 1024 * 1024
  MINIMUM_FREE_DISK_BYTES = 10 * GIBIBYTE
  IO_WRITE_BANDWIDTH_BYTES_PER_SECOND = 16 * 1024 * 1024

  class InfrastructureError < StandardError; end

  module ExecutionLimits
    BUILD = { memory_max_bytes: 32 * GIBIBYTE, tasks_max: 256, output_limit_bytes: 8 * 1024 * 1024,
              file_size_max_bytes: GIBIBYTE, allowed_cpus: "0-15", cpu_quota_percent: 1600,
              io_write_bandwidth_bytes_per_second: IO_WRITE_BANDWIDTH_BYTES_PER_SECOND }.freeze
    VALIDATION = { memory_max_bytes: 64 * GIBIBYTE, tasks_max: 256, output_limit_bytes: 8 * 1024 * 1024,
                   file_size_max_bytes: 64 * 1024 * 1024,
                   io_write_bandwidth_bytes_per_second: IO_WRITE_BANDWIDTH_BYTES_PER_SECOND }.freeze
    PERFORMANCE = { memory_max_bytes: 256 * GIBIBYTE, tasks_max: 512, output_limit_bytes: 8 * 1024 * 1024,
                    file_size_max_bytes: 64 * 1024 * 1024,
                    io_write_bandwidth_bytes_per_second: IO_WRITE_BANDWIDTH_BYTES_PER_SECOND }.freeze
  end

  module_function

  def parse_run_id(id)
    match = RUN_ID_RE.match(id)
    raise ArgumentError, "Malformed run ID: #{id}" unless match

    benchmark = BENCHMARKS.find { |candidate| match[:base].start_with?("#{candidate}_") }
    raise ArgumentError, "Unknown benchmark in run ID: #{id}" unless benchmark

    model = match[:base].delete_prefix("#{benchmark}_")
    raise ArgumentError, "Missing model in run ID: #{id}" if model.empty?

    {
      "benchmark" => benchmark,
      "model" => model,
      "par_type" => match[:par_type],
      "run" => match[:run].to_i
    }
  end

  def executable_name(benchmark)
    benchmark.tr("-", "_")
  end

  def atomic_write(path, content, mode: nil)
    FileUtils.mkdir_p(File.dirname(path))
    temp = "#{path}.tmp-#{Process.pid}"
    File.open(temp, "wb") do |file|
      file.write(content)
      file.flush
      file.fsync
    end
    File.chmod(mode, temp) if mode
    File.rename(temp, path)
  ensure
    FileUtils.rm_f(temp) if defined?(temp) && File.exist?(temp)
  end

  def ensure_disk_space!(path, minimum_bytes: MINIMUM_FREE_DISK_BYTES)
    existing = File.expand_path(path)
    existing = File.dirname(existing) until File.exist?(existing)
    stdout, stderr, status = Open3.capture3("df", "-Pk", existing)
    raise InfrastructureError, "Could not inspect free disk space for #{existing}: #{stderr.strip}" unless status.success?

    fields = stdout.lines.last.to_s.split
    available = Integer(fields.fetch(3), 10) * 1024
    return available if available >= minimum_bytes

    raise InfrastructureError,
          "Only #{available / GIBIBYTE} GiB remain on the filesystem containing #{existing}; " \
          "at least #{minimum_bytes / GIBIBYTE} GiB are required"
  rescue ArgumentError, IndexError => e
    raise InfrastructureError, "Could not parse free disk space for #{existing}: #{e.message}"
  end

  def atomic_yaml(path, object)
    atomic_write(path, YAML.dump(object))
  end

  # Publish the digest first and the data file last. A crash can therefore leave
  # only an orphan sidecar (which a later init may safely replace), never a
  # visible manifest whose integrity cannot be checked.
  def atomic_yaml_with_digest(path, object, immutable: false)
    content = YAML.dump(object)
    mode = immutable ? 0o444 : nil
    sidecar = "#{path}.sha256"
    atomic_write(sidecar, "#{Digest::SHA256.hexdigest(content)}\n", mode: mode)
    fsync_directory(File.dirname(path))
    atomic_write(path, content, mode: mode)
    fsync_directory(File.dirname(path))
  end

  def fsync_directory(path)
    File.open(path, "r") { |directory| directory.fsync }
  rescue Errno::EINVAL, Errno::ENOTSUP
    nil
  end

  def load_yaml(path, permitted_classes: [])
    YAML.safe_load(File.read(path), permitted_classes: permitted_classes, aliases: true)
  end

  def sha256_file(path)
    Digest::SHA256.file(path).hexdigest
  end

  def capture(argv, chdir: nil)
    options = {}
    options[:chdir] = chdir if chdir
    stdout, stderr, status = Open3.capture3(*argv, **options)
    status.success? ? stdout.strip : "unavailable: #{stderr.strip}"
  rescue StandardError => e
    "unavailable: #{e.message}"
  end

  def git_snapshot(path)
    inside = capture(%w[git rev-parse --is-inside-work-tree], chdir: path)
    return { "path" => File.expand_path(path), "git" => false } unless inside == "true"

    status = capture(%w[git status --short], chdir: path)
    diff = capture(%w[git diff --binary], chdir: path)
    {
      "path" => File.expand_path(path),
      "git" => true,
      "commit" => capture(%w[git rev-parse HEAD], chdir: path),
      "dirty" => !status.empty?,
      "status" => status,
      "diff_sha256" => Digest::SHA256.hexdigest(diff)
    }
  end

  def pipeline_source_snapshot(root = File.expand_path("../..", __dir__))
    root = File.expand_path(root)
    fixed = %w[
      general.rb general_evaluation.rb local_benchmark_seed.yml local_evaluation.rb
      local_gpu_rank_wrapper.rb validation_class.rb validation_helper.rb
    ]
    files = (fixed + ["lib/local_evaluation.rb"] +
             Dir[File.join(root, "lib", "local_evaluation", "**", "*.rb")].map { |path| path.delete_prefix("#{root}/") })
            .uniq.sort
    missing = files.reject { |relative| File.file?(File.join(root, relative)) }
    raise InfrastructureError, "Pipeline source files are missing: #{missing.join(', ')}" unless missing.empty?

    file_digests = files.to_h do |relative|
      [relative, sha256_file(File.join(root, relative))]
    end
    aggregate = Digest::SHA256.new
    file_digests.each { |relative, digest| aggregate << relative << "\0" << digest << "\0" }
    {
      "root" => root,
      "sha256" => aggregate.hexdigest,
      "files" => file_digests
    }
  end

  class SourceCorrectionAmendment
    FILENAME = "source_correction_amendment.yaml"
    RECORDS_FILENAME = "source_correction_records.jsonl"
    IDS_FILENAME = "source_correction_ids.txt"
    EVIDENCE_FILENAME = "source_correction_evidence_manifest.yaml"
    AUTHORIZED_OPERATIONS = %w[benchmark aggregate prepare-scoring score].freeze
    DOWNSTREAM_OPERATIONS = %w[aggregate prepare-scoring score].freeze

    attr_reader :path, :data, :digest, :records

    def self.path_for(run_dir)
      File.join(File.expand_path(run_dir), FILENAME)
    end

    def self.digest_for(run_dir)
      path = path_for(run_dir)
      File.file?(path) ? LocalEvaluation.sha256_file(path) : nil
    end

    def self.load(run_dir, manifest:)
      path = path_for(run_dir)
      File.file?(path) ? new(path, manifest: manifest) : nil
    end

    def self.create!(manifest:, correction_dir:, reason:, dry_run: false)
      run_dir = File.dirname(manifest.path)
      paths = artifact_paths(run_dir)
      existing = paths.values.select { |path| File.exist?(path) || File.exist?("#{path}.sha256") }
      unless existing.empty?
        raise "Source correction amendment artifacts already exist and are immutable: #{existing.join(', ')}"
      end

      reason = reason.to_s.strip
      raise "Source correction amendment reason must not be empty" if reason.empty?
      correction_dir = File.realpath(correction_dir)
      source_manifest_path = File.join(correction_dir, "manifest.yaml")
      source_records_path = File.join(correction_dir, "corrections.jsonl")
      source_ids_path = File.join(correction_dir, "correction-ids.txt")
      [source_manifest_path, source_records_path, source_ids_path].each do |path|
        raise "Correction artifact not found: #{path}" unless File.file?(path)
      end
      evidence = LocalEvaluation.load_yaml(source_manifest_path)
      records = parse_jsonl(source_records_path)
      ids = File.readlines(source_ids_path, chomp: true).reject(&:empty?)
      validate_external_evidence!(evidence, records, ids, source_records_path, source_ids_path)

      recorded = manifest.data.fetch("experiment_repository")
      unless recorded["git"] && evidence.dig("original_source", "root") == recorded.fetch("path") &&
             evidence.dig("original_source", "commit") == recorded.fetch("commit")
        raise "Correction evidence does not start from the experiment revision pinned by the run manifest"
      end
      corrected = LocalEvaluation.git_snapshot(recorded.fetch("path"))
      unless corrected["git"] && !corrected["dirty"] &&
             corrected["commit"] == evidence.dig("corrected_source", "commit")
        raise "Experiment repository is not clean at the corrected evidence commit"
      end
      validate_records!(records, ids, manifest, recorded.fetch("commit"), corrected.fetch("commit"))
      changed_paths = git_changed_paths(recorded.fetch("path"), recorded.fetch("commit"), corrected.fetch("commit"))
      expected_paths = records.flat_map { |record| record.fetch("changed_paths") }.uniq.sort
      raise "Corrected Git commit path set differs from correction records" unless changed_paths == expected_paths

      data = {
        "schema_version" => SCHEMA_VERSION,
        "created_at" => Time.now.iso8601,
        "manifest_sha256" => LocalEvaluation.sha256_file(manifest.path),
        "reason" => reason,
        "authorized_operations" => AUTHORIZED_OPERATIONS,
        "affected_run_ids" => ids,
        "original_experiment_repository" => recorded,
        "corrected_experiment_repository" => corrected,
        "changed_paths_count" => changed_paths.size,
        "changed_paths_sha256" => Digest::SHA256.hexdigest(changed_paths.join("\n") + "\n"),
        "source_evidence_path" => correction_dir,
        "source_evidence_manifest_sha256" => LocalEvaluation.sha256_file(source_manifest_path),
        "records_file" => RECORDS_FILENAME,
        "records_sha256" => LocalEvaluation.sha256_file(source_records_path),
        "ids_file" => IDS_FILENAME,
        "ids_sha256" => LocalEvaluation.sha256_file(source_ids_path),
        "evidence_file" => EVIDENCE_FILENAME
      }
      return data if dry_run

      write_immutable(paths.fetch(:records), File.binread(source_records_path))
      write_immutable(paths.fetch(:ids), File.binread(source_ids_path))
      write_immutable(paths.fetch(:evidence), File.binread(source_manifest_path))
      LocalEvaluation.atomic_yaml_with_digest(paths.fetch(:amendment), data, immutable: true)
      new(paths.fetch(:amendment), manifest: manifest)
    end

    def self.artifact_paths(run_dir)
      run_dir = File.expand_path(run_dir)
      {
        amendment: File.join(run_dir, FILENAME),
        records: File.join(run_dir, RECORDS_FILENAME),
        ids: File.join(run_dir, IDS_FILENAME),
        evidence: File.join(run_dir, EVIDENCE_FILENAME)
      }
    end
    private_class_method :artifact_paths

    def self.write_immutable(path, content)
      digest = Digest::SHA256.hexdigest(content)
      LocalEvaluation.atomic_write("#{path}.sha256", "#{digest}\n", mode: 0o444)
      LocalEvaluation.fsync_directory(File.dirname(path))
      LocalEvaluation.atomic_write(path, content, mode: 0o444)
      LocalEvaluation.fsync_directory(File.dirname(path))
    end
    private_class_method :write_immutable

    def self.parse_jsonl(path)
      File.foreach(path, chomp: true).filter_map do |line|
        JSON.parse(line) unless line.empty?
      end
    rescue JSON::ParserError => e
      raise "Malformed correction JSONL #{path}: #{e.message}"
    end
    private_class_method :parse_jsonl

    def self.validate_external_evidence!(evidence, records, ids, records_path, ids_path)
      unless evidence.is_a?(Hash) && evidence["schema_version"] == SCHEMA_VERSION &&
             evidence["record_count"] == records.size && evidence["all_final_verdicts"] == "accept"
        raise "Correction evidence manifest is malformed or incomplete"
      end
      unless evidence.dig("artifacts", "corrections_jsonl_sha256") == LocalEvaluation.sha256_file(records_path) &&
             evidence.dig("artifacts", "correction_ids_sha256") == LocalEvaluation.sha256_file(ids_path)
        raise "Correction evidence artifact digest mismatch"
      end
      record_ids = records.map { |record| record.fetch("program_id") }
      unless ids == ids.uniq.sort && ids == record_ids.sort && ids.size == records.size
        raise "Correction ID list and records are inconsistent"
      end
      compile = evidence.fetch("compile_validation")
      unless compile["records"] == records.size && compile["compiled"] == records.size &&
             compile["compile_successes"] == records.size && compile["compile_failures"] == []
        raise "Correction evidence does not record a successful static compilation of every correction"
      end
    end
    private_class_method :validate_external_evidence!

    def self.validate_records!(records, ids, manifest, original_commit, corrected_commit)
      mapped = records.to_h { |record| [record.fetch("program_id"), record] }
      raise "Correction records contain duplicate program IDs" unless mapped.size == records.size
      ids.each do |id|
        record = mapped.fetch(id)
        info = manifest.runs[id]
        raise "Correction record is absent from the run manifest: #{id}" unless info
        expected_prefix = [info.fetch("batch"), id].join("/")
        identity = %w[benchmark model par_type run].all? { |key| record[key] == info[key] }
        unless identity && record["source_prefix"] == expected_prefix && record["source_batch"] == info["batch"]
          raise "Correction record identity differs from the run manifest for #{id}"
        end
        unless record["timing_fixed"] == true && record["final_verdict"] == "accept" &&
               record.dig("original_source", "commit") == original_commit &&
               record.dig("corrected_source", "commit") == corrected_commit
          raise "Correction record lacks accepted timing-only revision provenance for #{id}"
        end
        paths = record["changed_paths"]
        unless paths.is_a?(Array) && !paths.empty? && paths == paths.uniq.sort &&
               paths.all? { |path| path.start_with?("#{expected_prefix}/") }
          raise "Correction record has an invalid changed-path set for #{id}"
        end
      end
    end
    private_class_method :validate_records!

    def self.git_changed_paths(root, original, corrected)
      stdout, stderr, status = Open3.capture3("git", "-C", root, "diff", "--name-only", original, corrected, "--")
      raise "Could not inspect corrected Git path set: #{stderr.strip}" unless status.success?
      stdout.lines(chomp: true).sort
    end
    private_class_method :git_changed_paths

    def initialize(path, manifest:)
      @path = File.expand_path(path)
      verify_digest_pair!(@path, "Source correction amendment")
      @digest = LocalEvaluation.sha256_file(@path)
      @data = LocalEvaluation.load_yaml(@path)
      unless @data.is_a?(Hash) && @data["schema_version"] == SCHEMA_VERSION &&
             @data["manifest_sha256"] == LocalEvaluation.sha256_file(manifest.path)
        raise "Source correction amendment is malformed or belongs to another manifest"
      end
      unless @data["authorized_operations"] == AUTHORIZED_OPERATIONS
        raise "Source correction amendment has an invalid authorized-operation set"
      end
      paths = self.class.send(:artifact_paths, File.dirname(@path))
      [paths.fetch(:records), paths.fetch(:ids), paths.fetch(:evidence)].each do |artifact|
        verify_digest_pair!(artifact, "Source correction artifact")
      end
      unless @data["records_sha256"] == LocalEvaluation.sha256_file(paths.fetch(:records)) &&
             @data["ids_sha256"] == LocalEvaluation.sha256_file(paths.fetch(:ids)) &&
             @data["source_evidence_manifest_sha256"] == LocalEvaluation.sha256_file(paths.fetch(:evidence))
        raise "Source correction amendment artifact binding is inconsistent"
      end
      @records = self.class.send(:parse_jsonl, paths.fetch(:records)).to_h do |record|
        [record.fetch("program_id"), record]
      end
      ids = File.readlines(paths.fetch(:ids), chomp: true).reject(&:empty?)
      original = @data.fetch("original_experiment_repository").fetch("commit")
      corrected = @data.fetch("corrected_experiment_repository").fetch("commit")
      self.class.send(:validate_records!, @records.values, ids, manifest, original, corrected)
      unless ids == @data["affected_run_ids"] && ids == @records.keys.sort
        raise "Source correction amendment affected-run set is inconsistent"
      end
    end

    def affected_ids
      @data.fetch("affected_run_ids")
    end

    def record_for(id)
      @records[id]
    end

    def verify_record_source!(id)
      record = @records.fetch(id)
      repository = @data.fetch("corrected_experiment_repository")
      root = repository.fetch("path")
      commit = repository.fetch("commit")
      prefix = record.fetch("source_prefix")
      stdout, stderr, status = Open3.capture3("git", "-C", root, "rev-parse", "HEAD", "HEAD:#{prefix}")
      raise InfrastructureError, "Could not verify corrected source for #{id}: #{stderr.strip}" unless status.success?
      head, tree = stdout.lines(chomp: true)
      unless head == commit && tree == record.dig("corrected_source", "tree_oid")
        raise InfrastructureError, "Corrected source revision changed before benchmarking #{id}"
      end
      status_text, status_error, status = Open3.capture3(
        "git", "-C", root, "status", "--porcelain=v1", "--untracked-files=all", "--", prefix
      )
      unless status.success? && status_text.empty?
        detail = status.success? ? status_text.strip : status_error.strip
        raise InfrastructureError, "Corrected source is dirty for #{id}: #{detail}"
      end
      true
    end

    def verify!(manifest:, operation:, exact_id:, filter:, selected_ids: nil)
      recorded = @data.fetch("corrected_experiment_repository")
      current = LocalEvaluation.git_snapshot(recorded.fetch("path"))
      unless current["git"] && current["commit"] == recorded["commit"] && !current["dirty"]
        raise InfrastructureError,
              "Experiment repository differs from the immutable source correction amendment"
      end
      changed = self.class.send(
        :git_changed_paths, recorded.fetch("path"),
        @data.fetch("original_experiment_repository").fetch("commit"), recorded.fetch("commit")
      )
      expected_digest = Digest::SHA256.hexdigest(changed.join("\n") + "\n")
      unless changed.size == @data["changed_paths_count"] && expected_digest == @data["changed_paths_sha256"]
        raise InfrastructureError, "Corrected experiment commit path set differs from the immutable amendment"
      end

      return true if operation.nil?
      operation = operation.to_s
      unless AUTHORIZED_OPERATIONS.include?(operation)
        raise InfrastructureError, "Source correction amendment does not authorize #{operation}"
      end
      selection = Array(selected_ids).map(&:to_s)
      selection = [exact_id] if selection.empty? && exact_id
      if operation == "benchmark"
        unless filter.nil? && !selection.empty? && selection.uniq.size == selection.size &&
               (selection - affected_ids).empty?
          raise InfrastructureError,
                "Corrected sources may benchmark only an explicit subset of timing-correction IDs"
        end
      elsif exact_id || filter || !selection.empty?
        raise InfrastructureError,
              "Corrected-source downstream #{operation} must rebuild the full corpus without selection"
      end
      true
    end

    private

    def verify_digest_pair!(path, label)
      sidecar = "#{path}.sha256"
      raise "#{label} digest sidecar is missing: #{sidecar}" unless File.file?(sidecar)
      expected = File.read(sidecar).strip
      unless expected.match?(/\A[0-9a-f]{64}\z/) && expected == LocalEvaluation.sha256_file(path)
        raise "#{label} digest mismatch: #{path}"
      end
    end
  end

  class PipelineAmendment
    FILENAME = "pipeline_amendment.yaml"
    SEQUENCED_FILENAME_RE = /\Apipeline_amendment\.(?<sequence>\d+)\.yaml\z/
    AUTHORIZED_OPERATIONS = %w[benchmark aggregate prepare-scoring score].freeze
    DOWNSTREAM_OPERATIONS = %w[aggregate prepare-scoring score].freeze

    attr_reader :path, :data, :digest

    def self.base_path_for(run_dir)
      File.join(File.expand_path(run_dir), FILENAME)
    end

    def self.paths_for(run_dir)
      run_dir = File.expand_path(run_dir)
      base = base_path_for(run_dir)
      numbered = if File.directory?(run_dir)
        Dir.children(run_dir).filter_map do |entry|
          match = SEQUENCED_FILENAME_RE.match(entry)
          [Integer(match[:sequence], 10), File.join(run_dir, entry)] if match
        end.sort_by(&:first).map(&:last)
      else
        []
      end
      [*(File.file?(base) ? [base] : []), *numbered]
    end

    def self.path_for(run_dir)
      paths_for(run_dir).last || base_path_for(run_dir)
    end

    def self.digest_for(run_dir)
      path = path_for(run_dir)
      File.file?(path) ? LocalEvaluation.sha256_file(path) : nil
    end

    def self.load_chain(run_dir, manifest:)
      prior = nil
      paths_for(run_dir).map do |path|
        prior = new(path, manifest: manifest, prior: prior)
      end
    end

    def self.create!(manifest:, affected_ids:, reason:, dry_run: false)
      run_dir = File.dirname(manifest.path)
      chain = load_chain(run_dir, manifest: manifest)
      prior = chain.last
      sequence = chain.size + 1
      path = sequence == 1 ? base_path_for(run_dir) : File.join(run_dir, "pipeline_amendment.#{sequence}.yaml")
      raise "Pipeline amendment already exists and is immutable: #{path}" if File.exist?(path)

      reason = reason.to_s.strip
      raise "Pipeline amendment reason must not be empty" if reason.empty?

      affected_ids = [*Array(prior&.data&.fetch("affected_run_ids", nil)), *Array(affected_ids)]
                     .map(&:to_s).uniq.sort
      raise "Pipeline amendment must name at least one affected run ID" if affected_ids.empty?
      unknown = affected_ids - manifest.runs.keys
      unless unknown.empty?
        raise "Pipeline amendment contains IDs absent from the manifest: #{unknown.join(', ')}"
      end

      manifest.verify_non_pipeline_input_revisions!
      original = prior ? prior.data.fetch("amended_pipeline_source") : manifest.data.fetch("pipeline_source")
      current = LocalEvaluation.pipeline_source_snapshot(manifest.data.fetch("pipeline_source").fetch("root"))
      if current["sha256"] == original["sha256"]
        raise "Pipeline source has not changed; no amendment is needed"
      end

      changed_files = changed_file_map(original.fetch("files"), current.fetch("files"))
      data = {
        "schema_version" => SCHEMA_VERSION,
        "created_at" => Time.now.iso8601,
        "sequence" => sequence,
        "prior_amendment_sha256" => prior&.digest,
        "manifest_sha256" => LocalEvaluation.sha256_file(manifest.path),
        "reason" => reason,
        "affected_run_ids" => affected_ids,
        "authorized_operations" => AUTHORIZED_OPERATIONS,
        "original_pipeline_source_sha256" => original.fetch("sha256"),
        "amended_pipeline_source" => current,
        "changed_files" => changed_files
      }
      return data if dry_run

      LocalEvaluation.atomic_yaml_with_digest(path, data, immutable: true)
      new(path, manifest: manifest, prior: prior)
    end

    def self.changed_file_map(original_files, amended_files)
      (original_files.keys | amended_files.keys).sort.each_with_object({}) do |relative, changed|
        before = original_files[relative]
        after = amended_files[relative]
        next if before == after

        changed[relative] = { "before_sha256" => before, "after_sha256" => after }
      end
    end
    private_class_method :changed_file_map

    def initialize(path, manifest:, prior: nil)
      @path = File.expand_path(path)
      sidecar = "#{@path}.sha256"
      raise "Pipeline amendment digest sidecar is missing: #{sidecar}" unless File.file?(sidecar)
      expected = File.read(sidecar).strip
      unless expected.match?(/\A[0-9a-f]{64}\z/)
        raise "Pipeline amendment digest sidecar is malformed: #{sidecar}"
      end
      @digest = LocalEvaluation.sha256_file(@path)
      raise "Pipeline amendment digest mismatch: #{@path}" unless expected == @digest

      @data = LocalEvaluation.load_yaml(@path)
      unless @data.is_a?(Hash) && @data["schema_version"] == SCHEMA_VERSION
        raise "Unsupported pipeline amendment schema in #{@path}"
      end
      unless @data["manifest_sha256"] == LocalEvaluation.sha256_file(manifest.path)
        raise "Pipeline amendment belongs to another manifest"
      end
      expected_sequence = prior ? prior.data.fetch("sequence", 1) + 1 : 1
      unless @data.fetch("sequence", 1) == expected_sequence
        raise "Pipeline amendment sequence is not contiguous"
      end
      unless @data["prior_amendment_sha256"] == prior&.digest
        raise "Pipeline amendment does not bind its predecessor"
      end
      original = prior ? prior.data.fetch("amended_pipeline_source") : manifest.data.fetch("pipeline_source")
      unless @data["original_pipeline_source_sha256"] == original["sha256"]
        raise "Pipeline amendment does not start from its recorded predecessor source"
      end
      unless @data["authorized_operations"] == AUTHORIZED_OPERATIONS
        raise "Pipeline amendment has an invalid authorized-operation set"
      end
      reason = @data["reason"]
      raise "Pipeline amendment reason must not be empty" unless reason.is_a?(String) && !reason.strip.empty?

      affected = @data["affected_run_ids"]
      unless affected.is_a?(Array) && !affected.empty? && affected == affected.uniq.sort &&
             affected.all? { |id| id.is_a?(String) && manifest.runs.key?(id) }
        raise "Pipeline amendment has an invalid affected-run set"
      end
      if prior && (prior.data.fetch("affected_run_ids") - affected).any?
        raise "Pipeline amendment drops a previously affected run ID"
      end
      amended = @data["amended_pipeline_source"]
      unless amended.is_a?(Hash) && amended["files"].is_a?(Hash)
        raise "Pipeline amendment has no valid amended source snapshot"
      end
      unless amended["root"] == manifest.data.fetch("pipeline_source").fetch("root")
        raise "Pipeline amendment source root differs from the manifest"
      end
      aggregate = Digest::SHA256.new
      amended.fetch("files").sort.each { |relative, digest| aggregate << relative << "\0" << digest << "\0" }
      unless amended["sha256"] == aggregate.hexdigest
        raise "Pipeline amendment source snapshot digest is inconsistent"
      end
      expected_changes = self.class.send(:changed_file_map, original.fetch("files"), amended.fetch("files"))
      unless @data["changed_files"] == expected_changes && !expected_changes.empty?
        raise "Pipeline amendment changed-file map is inconsistent"
      end
    end

    def verify!(manifest:, current_pipeline:, operation:, exact_id:, filter:, selected_ids: nil)
      unless @data["amended_pipeline_source"] == current_pipeline
        raise InfrastructureError,
              "Local evaluation pipeline source differs from the immutable amendment " \
              "(expected #{@data.dig('amended_pipeline_source', 'sha256')}, got #{current_pipeline['sha256']})"
      end

      operation = operation.to_s
      unless AUTHORIZED_OPERATIONS.include?(operation)
        raise InfrastructureError,
              "Pipeline amendment does not authorize #{operation.empty? ? 'this operation' : operation}"
      end
      if operation == "benchmark"
        selection = Array(selected_ids).map(&:to_s)
        selection = [exact_id] if selection.empty? && exact_id
        unless filter.nil? && !selection.empty? && selection.uniq.size == selection.size &&
               (selection - @data.fetch("affected_run_ids")).empty?
          raise InfrastructureError,
                "Amended runs may benchmark only an explicit subset of affected IDs"
        end
      elsif exact_id || filter || !Array(selected_ids).empty?
        raise InfrastructureError,
              "Amended downstream #{operation} must rebuild the full corpus without --id/--filter"
      end
      true
    end
  end

  def environment_snapshot
    {
      "hostname" => capture(%w[hostname]),
      "ruby" => RUBY_DESCRIPTION,
      "cmake" => capture(%w[cmake --version]).lines.first&.strip,
      "cc_path" => C_COMPILER,
      "cc" => capture([C_COMPILER, "--version"]).lines.first&.strip,
      "cxx_path" => CXX_COMPILER,
      "cxx" => capture([CXX_COMPILER, "--version"]).lines.first&.strip,
      "nvcc_path" => File.expand_path(CUDA_COMPILER),
      "nvcc" => capture([CUDA_COMPILER, "--version"]).lines.last&.strip,
      "mpi" => capture(%w[mpirun --version]).lines.first&.strip,
      "lscpu" => capture(%w[lscpu]),
      "gpus" => capture(%w[nvidia-smi --query-gpu=index,name,memory.total,compute_cap,driver_version --format=csv,noheader])
    }
  end

  def resource_profile_description
    {
      "validation" => {
        "omp" => "8 physical cores on NUMA node 0",
        "cuda" => "GPU 0 and 8 host cores on NUMA node 0",
        "mpi" => "4 ranks, 2 per socket, 1 physical core per rank",
        "hybrid" => "4 ranks, 2 per socket, 8 cores and 1 topology-local GPU per rank"
      },
      "benchmark" => {
        "omp" => "128 physical cores across both sockets, interleaved memory",
        "cuda" => "GPU 0 and physical cores 0-63 on NUMA node 0",
        "mpi" => "128 ranks, 64 per socket, 1 physical core per rank",
        "hybrid" => "4 ranks, 2 per socket, 32 cores and 1 topology-local GPU per rank"
      }
    }
  end

  class Manifest
    attr_reader :path, :data

    def self.create(experiments_root:, run_dir:, benchmarks_root:)
      path = File.join(run_dir, "evaluation_manifest.yaml")
      raise "Run manifest already exists and is immutable: #{path}" if File.exist?(path)

      experiments_root = File.expand_path(experiments_root)
      benchmarks_root = File.expand_path(benchmarks_root)
      batches, runs = discover(experiments_root)
      experiment_repository = LocalEvaluation.git_snapshot(experiments_root)
      benchmark_repository = LocalEvaluation.git_snapshot(benchmarks_root)
      [["Experiment", experiment_repository], ["Benchmark", benchmark_repository]].each do |label, snapshot|
        next unless snapshot["git"] && snapshot["dirty"]

        raise "#{label} repository must be clean when initializing an immutable evaluation manifest: " \
              "#{snapshot['path']}"
      end

      data = {
        "schema_version" => SCHEMA_VERSION,
        "created_at" => Time.now.iso8601,
        "experiments_root" => experiments_root,
        "benchmarks_root" => benchmarks_root,
        "experiment_repository" => experiment_repository,
        "benchmark_repository" => benchmark_repository,
        "script_repository" => LocalEvaluation.git_snapshot(File.expand_path("../..", __dir__)),
        "pipeline_source" => LocalEvaluation.pipeline_source_snapshot,
        "environment" => LocalEvaluation.environment_snapshot,
        "resource_profiles" => LocalEvaluation.resource_profile_description,
        "batches" => batches,
        "run_count" => runs.size,
        "runs" => runs
      }
      FileUtils.mkdir_p(run_dir)
      LocalEvaluation.atomic_yaml_with_digest(path, data, immutable: true)
      new(path)
    end

    def self.discover(experiments_root)
      experiments_root = File.expand_path(experiments_root)
      batches = Dir.children(experiments_root).sort.select do |entry|
        File.directory?(File.join(experiments_root, entry)) && entry.match?(/\A\d{8}-\d{6}\z/)
      end
      raise "No timestamped experiment batches found in #{experiments_root}" if batches.empty?

      runs = {}
      batches.each do |batch|
        batch_path = File.join(experiments_root, batch)
        Dir.children(batch_path).sort.each do |id|
          source_path = File.join(batch_path, id)
          next unless File.directory?(source_path)
          next if id == "failed"

          info = LocalEvaluation.parse_run_id(id)
          raise "Duplicate run ID #{id} in #{runs[id]["source_path"]} and #{source_path}" if runs.key?(id)

          benchmark_path = File.join(source_path, info["benchmark"])
          source_error = if !File.directory?(benchmark_path)
            "Missing benchmark directory: #{benchmark_path}"
          elsif !File.file?(File.join(benchmark_path, "CMakeLists.txt"))
            "Missing CMakeLists.txt: #{File.join(benchmark_path, 'CMakeLists.txt')}"
          end

          runs[id] = info.merge("batch" => batch, "source_path" => File.expand_path(source_path),
                                "source_error" => source_error)
        end
      end
      [batches, runs]
    end

    def initialize(run_dir_or_path)
      @path = run_dir_or_path.end_with?(".yaml") ? run_dir_or_path : File.join(run_dir_or_path, "evaluation_manifest.yaml")
      raise "Manifest not found: #{@path}; run the init phase first" unless File.file?(@path)

      digest_path = "#{@path}.sha256"
      raise "Manifest digest sidecar is missing: #{digest_path}" unless File.file?(digest_path)
      expected = File.read(digest_path).strip
      unless expected.match?(/\A[0-9a-f]{64}\z/)
        raise "Manifest digest sidecar is malformed: #{digest_path}"
      end
      actual = LocalEvaluation.sha256_file(@path)
      raise "Manifest digest mismatch for #{@path}" unless expected == actual
      @data = LocalEvaluation.load_yaml(@path)
      raise "Unsupported manifest schema in #{@path}" unless @data["schema_version"] == SCHEMA_VERSION
    end

    def runs
      @data.fetch("runs")
    end

    def benchmarks_root
      @data.fetch("benchmarks_root")
    end

    def verify_input_revisions!(operation: nil, exact_id: nil, filter: nil, selected_ids: nil)
      report = verify_non_pipeline_input_revisions!(operation: operation, exact_id: exact_id,
                                                    filter: filter, selected_ids: selected_ids)
      if (recorded_pipeline = @data["pipeline_source"])
        current_pipeline = LocalEvaluation.pipeline_source_snapshot(recorded_pipeline.fetch("root"))
        if current_pipeline["sha256"] == recorded_pipeline["sha256"]
          report["pipeline_source_sha256"] = current_pipeline["sha256"]
        else
          amendments = PipelineAmendment.load_chain(File.dirname(@path), manifest: self)
          if amendments.empty?
            raise InfrastructureError,
                  "Local evaluation pipeline source changed since manifest creation (expected " \
                  "#{recorded_pipeline['sha256']}, got #{current_pipeline['sha256']})"
          end
          amendment = amendments.last
          amendment.verify!(manifest: self, current_pipeline: current_pipeline, operation: operation,
                            exact_id: exact_id, filter: filter, selected_ids: selected_ids)
          report["pipeline_source_sha256"] = current_pipeline["sha256"]
          report["pipeline_amendment_sha256"] = amendment.digest
          report["pipeline_amendment_chain_sha256"] = amendments.map(&:digest)
          report["pipeline_amendment_affected_run_ids"] = amendment.data.fetch("affected_run_ids")
        end
      else
        report["pipeline_source_sha256"] = nil
        report["warning"] = "Manifest predates pipeline-source snapshots"
      end
      report
    end

    def verify_non_pipeline_input_revisions!(operation: nil, exact_id: nil, filter: nil, selected_ids: nil)
      report = {}
      {
        "experiments" => @data["experiment_repository"],
        "benchmarks" => @data["benchmark_repository"]
      }.each do |name, recorded|
        next unless recorded && recorded["git"]

        current = LocalEvaluation.git_snapshot(recorded.fetch("path"))
        unless current["git"] && current["commit"] == recorded["commit"] && !current["dirty"]
          if name == "experiments" && (correction = SourceCorrectionAmendment.load(File.dirname(@path), manifest: self))
            correction.verify!(manifest: self, operation: operation, exact_id: exact_id,
                               filter: filter, selected_ids: selected_ids)
            report["source_correction_amendment_sha256"] = correction.digest
            report["source_correction_affected_run_ids"] = correction.affected_ids
            report[name] = {
              "path" => current.fetch("path"), "commit" => current.fetch("commit"), "clean" => true,
              "original_commit" => recorded.fetch("commit"), "timing_correction" => true
            }
            next
          end
          raise InfrastructureError,
                "#{name.capitalize} repository changed since manifest creation: #{recorded.fetch('path')}"
        end
        report[name] = { "path" => recorded.fetch("path"), "commit" => current["commit"], "clean" => true }
      end

      recorded_environment = @data["environment"] || {}
      {
        "cc_path" => C_COMPILER,
        "cxx_path" => CXX_COMPILER,
        "nvcc_path" => File.expand_path(CUDA_COMPILER)
      }.each do |key, current_path|
        next unless recorded_environment[key]
        raise InfrastructureError, "Pinned #{key} changed since manifest creation" unless recorded_environment[key] == current_path
        raise InfrastructureError, "Pinned tool is no longer executable: #{current_path}" unless File.executable?(current_path)
      end
      {
        "cc" => LocalEvaluation.capture([C_COMPILER, "--version"]).lines.first&.strip,
        "cxx" => LocalEvaluation.capture([CXX_COMPILER, "--version"]).lines.first&.strip,
        "nvcc" => LocalEvaluation.capture([CUDA_COMPILER, "--version"]).lines.last&.strip,
        "cmake" => LocalEvaluation.capture(%w[cmake --version]).lines.first&.strip,
        "mpi" => LocalEvaluation.capture(%w[mpirun --version]).lines.first&.strip,
        "gpus" => LocalEvaluation.capture(
          %w[nvidia-smi --query-gpu=index,name,memory.total,compute_cap,driver_version --format=csv,noheader]
        )
      }.each do |key, current_version|
        next unless recorded_environment[key]
        raise InfrastructureError, "Recorded #{key} environment changed since manifest creation" \
          unless recorded_environment[key] == current_version
      end
      report["toolchain_paths"] = {
        "cc" => C_COMPILER, "cxx" => CXX_COMPILER, "nvcc" => File.expand_path(CUDA_COMPILER)
      }
      report
    end

    def filtered_runs(exact_id: nil, filter: nil, ids: nil)
      ids = Array(ids).map(&:to_s)
      selectors = [!exact_id.nil?, !filter.nil?, !ids.empty?].count(true)
      raise "Use only one of exact ID, filter, or ID list" if selectors > 1
      selected = runs
      selected = selected.select { |id, _| id == exact_id } if exact_id
      selected = selected.select { |id, _| id.include?(filter) } if filter
      selected = selected.select { |id, _| ids.include?(id) } unless ids.empty?
      raise "Run ID not present in manifest: #{exact_id}" if exact_id && selected.empty?
      raise "No run IDs contain filter: #{filter}" if filter && selected.empty?
      unless ids.empty?
        missing = ids - selected.keys
        raise "Run IDs not present in manifest: #{missing.join(', ')}" unless missing.empty?
      end
      selected.sort.to_h
    end
  end

  class SystemdContainment
    class << self
      def available?
        return @available unless @available.nil?
        return @available = false if ENV["LOCAL_EVALUATION_DISABLE_CGROUP"] == "1"

        unit = "local-evaluation-probe-#{Process.pid}-#{SecureRandom.hex(4)}"
        @available = system(
          "systemd-run", "--user", "--scope", "--quiet", "--collect", "--unit=#{unit}",
          "--property=MemoryMax=64M", "--property=MemorySwapMax=0", "--property=TasksMax=16",
          "--property=RuntimeMaxSec=5s", "--property=IPAddressDeny=any",
          "--property=IPAddressAllow=localhost", "--", "/bin/true",
          out: File::NULL, err: File::NULL
        )
      rescue SystemCallError
        @available = false
      end

      def require_available!
        return true if available?
        return false if ENV["LOCAL_EVALUATION_ALLOW_UNCONTAINED"] == "1"

        raise InfrastructureError,
              "User-systemd cgroup containment is unavailable. Refusing to run generated code without " \
              "aggregate memory/PID limits; set LOCAL_EVALUATION_ALLOW_UNCONTAINED=1 only after review."
      end

      def wrap(argv, timeout:, limits:, io_target:)
        return [argv, nil, nil] unless require_available!

        unit = "local-evaluation-#{Process.pid}-#{SecureRandom.hex(6)}"
        properties = [
          "--property=MemoryMax=#{limits.fetch(:memory_max_bytes)}",
          "--property=MemorySwapMax=0",
          "--property=TasksMax=#{limits.fetch(:tasks_max)}",
          "--property=OOMPolicy=kill",
          "--property=IPAddressDeny=any",
          "--property=IPAddressAllow=localhost"
        ]
        properties << "--property=RuntimeMaxSec=#{timeout.ceil + 5}s" if timeout
        properties << "--property=AllowedCPUs=#{limits.fetch(:allowed_cpus)}" if limits[:allowed_cpus]
        properties << "--property=CPUQuota=#{limits.fetch(:cpu_quota_percent)}%" if limits[:cpu_quota_percent]
        io_device = nil
        if limits[:io_write_bandwidth_bytes_per_second]
          io_device = io_device_for(io_target)
          properties << "--property=IOWriteBandwidthMax=#{io_device} " \
                        "#{limits.fetch(:io_write_bandwidth_bytes_per_second)}"
        end
        command = ["systemd-run", "--user", "--scope", "--quiet", "--collect", "--unit=#{unit}",
                   *properties, "--", *argv]
        [command, unit, io_device]
      end

      def io_device_for(target)
        existing = File.expand_path(target)
        existing = File.dirname(existing) until File.exist?(existing)
        stdout, stderr, status = Open3.capture3("findmnt", "-n", "-o", "SOURCE", "--target", existing)
        unless status.success?
          raise InfrastructureError, "Could not resolve filesystem device for #{existing}: #{stderr.strip}"
        end
        source = stdout.lines.first.to_s.strip
        unless source.start_with?("/dev/")
          raise InfrastructureError,
                "Filesystem containing #{existing} is backed by #{source.inspect}, which cannot receive an I/O cap"
        end
        source
      end

      def signal(unit, signal)
        return unless unit
        system("systemctl", "--user", "kill", "--kill-whom=all", "--signal=#{signal}",
               "#{unit}.scope", out: File::NULL, err: File::NULL)
      rescue SystemCallError
        false
      end
    end
  end

  class RunLock
    def initialize(run_dir)
      @file = File.open(File.join(run_dir, ".local_evaluation.lock"), File::RDWR | File::CREAT, 0o644)
      raise "Another local evaluation process holds the run lock" unless @file.flock(File::LOCK_EX | File::LOCK_NB)
    end

    def close
      @file&.flock(File::LOCK_UN)
      @file&.close
    end
  end

  class HostPerformanceLock
    def initialize
      path = File.join(Dir.tmpdir, "local-evaluation-#{Process.uid}-performance.lock")
      @file = File.open(path, File::RDWR | File::CREAT, 0o644)
      raise "Another local evaluation phase is using this host" unless @file.flock(File::LOCK_EX | File::LOCK_NB)
    end

    def close
      @file&.flock(File::LOCK_UN)
      @file&.close
    end
  end

  class ProcessRunner
    Result = Struct.new(:success, :exit_code, :timed_out, :wall_seconds, :argv, :term_signal,
                        :output_truncated, :containment_unit, keyword_init: true)

    DEFAULT_OUTPUT_LIMIT_BYTES = 8 * 1024 * 1024
    INHERITED_ENVIRONMENT_KEYS = %w[
      PATH HOME USER LOGNAME TMPDIR XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
      LANG LC_ALL LC_CTYPE LD_LIBRARY_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH
      CPLUS_INCLUDE_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH
    ].freeze

    def run(argv:, prefix:, env: {}, timeout: nil, chdir: nil, limits: nil)
      argv = argv.map(&:to_s)
      env = env.to_h { |key, value| [key.to_s, value.to_s] }
      env = sanitized_environment(env)
      limits = limits&.transform_keys(&:to_sym)
      output_limit = limits&.fetch(:output_limit_bytes, DEFAULT_OUTPUT_LIMIT_BYTES) || DEFAULT_OUTPUT_LIMIT_BYTES
      FileUtils.mkdir_p(File.dirname(prefix))
      effective_argv, containment_unit, io_device = if limits
        SystemdContainment.wrap(argv, timeout: timeout, limits: limits, io_target: File.dirname(prefix))
      else
        [argv, nil, nil]
      end
      LocalEvaluation.atomic_write("#{prefix}_command.log",
                                   command_text(argv, effective_argv, env, chdir, limits, containment_unit, io_device))
      stdout_path = "#{prefix}_stdout.log"
      stderr_path = "#{prefix}_stderr.log"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = nil
      timed_out = false
      pid = nil
      error = nil
      stdout_reader, stdout_writer = IO.pipe
      stderr_reader, stderr_writer = IO.pipe
      pumps = [
        start_output_pump(stdout_reader, stdout_path, output_limit),
        start_output_pump(stderr_reader, stderr_path, output_limit)
      ]

      begin
        spawn_options = { out: stdout_writer, err: stderr_writer, pgroup: true, rlimit_core: [0, 0] }
        if limits&.key?(:file_size_max_bytes)
          maximum = limits.fetch(:file_size_max_bytes)
          spawn_options[:rlimit_fsize] = [maximum, maximum]
        end
        spawn_options[:chdir] = chdir if chdir
        pid = Process.spawn(env, *effective_argv, **spawn_options, unsetenv_others: true)
        stdout_writer.close
        stderr_writer.close
        loop do
          waited_pid, status = Process.wait2(pid, Process::WNOHANG)
          break if waited_pid
          if timeout && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= timeout
            timed_out = true
            terminate_tree(pid, containment_unit)
            _, status = Process.wait2(pid)
            break
          end
          sleep 0.05
        end

        pumps.all? { |thread| thread.join(0.5) }
        # A leader can daemonize a child into another process group and redirect its
        # logs before exiting.  Clean the complete transient scope even when the
        # leader looked successful and no pipe remains open.
        terminate_tree(pid, containment_unit)
      rescue Exception => e # cleanup must also run for Interrupt/TERM before the exception is re-raised
        error = e
        terminate_tree(pid, containment_unit) if pid
        begin
          _, status = Process.wait2(pid) if pid
        rescue Errno::ECHILD
          nil
        end
      ensure
        stdout_writer.close unless stdout_writer.closed?
        stderr_writer.close unless stderr_writer.closed?
        pumps.each do |thread|
          next if thread.join(2.0)
          stdout_reader.close unless stdout_reader.closed?
          stderr_reader.close unless stderr_reader.closed?
          thread.join(0.5)
        end
      end

      wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      pump_results = pumps.map(&:value)
      if error
        File.open(stderr_path, "ab") { |file| file.puts("Infrastructure interruption: #{error.class}: #{error.message}") }
        LocalEvaluation.atomic_write("#{prefix}_exitcode.log", error.is_a?(Interrupt) ? "130" : "127")
        LocalEvaluation.atomic_write("#{prefix}_wall_time.log", format("%.6f\n", wall))
        raise error
      end
      if timed_out
        File.open(stderr_path, "ab") { |file| file.puts("Command timed out after #{timeout} seconds.") }
      end
      exit_code = timed_out ? 124 : (status&.exitstatus || 128 + (status&.termsig || 0))
      LocalEvaluation.atomic_write("#{prefix}_exitcode.log", exit_code.to_s)
      LocalEvaluation.atomic_write("#{prefix}_wall_time.log", format("%.6f\n", wall))
      Result.new(success: !timed_out && status&.success? == true, exit_code: exit_code,
                 timed_out: timed_out, wall_seconds: wall, argv: argv,
                 term_signal: status&.termsig, output_truncated: pump_results.any? { |entry| entry[:truncated] },
                 containment_unit: containment_unit)
    end

    private

    def sanitized_environment(overrides)
      inherited = INHERITED_ENVIRONMENT_KEYS.filter_map do |key|
        [key, ENV[key]] if ENV.key?(key)
      end.to_h
      inherited["PATH"] ||= "/usr/local/bin:/usr/bin:/bin"
      inherited.merge("CC" => C_COMPILER, "CXX" => CXX_COMPILER).merge(overrides)
    end

    def command_text(argv, effective_argv, env, chdir, limits, containment_unit, io_device)
      lines = []
      lines << "chdir: #{chdir}" if chdir
      lines << "containment_unit: #{containment_unit}.scope" if containment_unit
      lines << "io_write_device: #{io_device}" if io_device
      lines << "network_policy: deny external; allow localhost" if containment_unit
      if limits
        lines << "limits:"
        limits.sort.each { |key, value| lines << "  #{key}=#{value}" }
      end
      lines << "environment:"
      env.sort.each { |key, value| lines << "  #{key}=#{value}" }
      lines << "command: #{Shellwords.join(argv)}"
      lines << "effective_command: #{Shellwords.join(effective_argv)}" if effective_argv != argv
      lines.join("\n") + "\n"
    end

    def start_output_pump(reader, path, limit)
      Thread.new do
        written = 0
        discarded = 0
        File.open(path, "wb") do |file|
          begin
            loop do
              chunk = reader.readpartial(64 * 1024)
              keep = [limit - written, chunk.bytesize].min
              if keep.positive?
                file.write(chunk.byteslice(0, keep))
                written += keep
              end
              discarded += chunk.bytesize - keep
            end
          rescue EOFError
            nil
          ensure
            file.puts("\n[local evaluation truncated #{discarded} output bytes]") if discarded.positive?
            file.flush
            file.fsync
            reader.close unless reader.closed?
          end
        end
        { truncated: discarded.positive?, discarded_bytes: discarded }
      end
    end

    def terminate_tree(pid, containment_unit)
      begin
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH
        nil
      end
      SystemdContainment.signal(containment_unit, "TERM")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        break unless group_alive?(pid)
        sleep 0.05
      end
      if group_alive?(pid)
        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH
          nil
        end
      end
      # MPI ranks may use PGIDs unrelated to the launcher, so always escalate the whole cgroup.
      SystemdContainment.signal(containment_unit, "KILL")
    end

    def group_alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    end
  end

  class Resources
    def initialize(wrapper_path: File.expand_path("../../local_gpu_rank_wrapper.rb", __dir__))
      @wrapper_path = wrapper_path
    end

    def command(par_type:, executable:, args:, mode:)
      raise ArgumentError, "Unknown parallelization type: #{par_type}" unless PAR_TYPES.include?(par_type)
      raise ArgumentError, "Unknown resource mode: #{mode}" unless %i[validation benchmark].include?(mode)

      mode == :validation ? validation_command(par_type, executable, args) : benchmark_command(par_type, executable, args)
    end

    def verify_topology!
      required = %w[cmake numactl mpirun nvidia-smi systemd-run systemctl findmnt]
      missing = required.reject { |command| executable_on_path?(command) }
      raise InfrastructureError, "Missing required executables: #{missing.join(', ')}" unless missing.empty?
      raise InfrastructureError, "C compiler not executable: #{C_COMPILER}" unless File.executable?(C_COMPILER)
      raise InfrastructureError, "C++ compiler not executable: #{CXX_COMPILER}" unless File.executable?(CXX_COMPILER)
      raise InfrastructureError, "CUDA compiler not executable: #{CUDA_COMPILER}" unless File.executable?(CUDA_COMPILER)
      raise InfrastructureError, "Hybrid GPU wrapper not found: #{@wrapper_path}" unless File.file?(@wrapper_path)

      topology = LocalEvaluation.capture(%w[lscpu -p=CPU,NODE,SOCKET,CORE])
      cpus = topology.lines.reject { |line| line.start_with?("#") || line.strip.empty? }.to_h do |line|
        cpu, node, socket, core = line.strip.split(",").map { |value| Integer(value, 10) }
        [cpu, { node: node, socket: socket, core: core }]
      end
      expected = (0..63).map { |cpu| [cpu, 0, 0] } + (64..127).map { |cpu| [cpu, 1, 1] }
      expected.each do |cpu, node, socket|
        actual = cpus[cpu]
        unless actual && actual[:node] == node && actual[:socket] == socket
          raise InfrastructureError, "CPU #{cpu} does not match the required node #{node}/socket #{socket} topology"
        end
      end
      physical = expected.map { |cpu, _node, _socket| [cpus.fetch(cpu)[:socket], cpus.fetch(cpu)[:core]] }
      raise InfrastructureError, "CPUs 0-127 are not 128 distinct physical cores" unless physical.uniq.size == 128

      gpu_output = LocalEvaluation.capture(
        %w[nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader,nounits]
      )
      gpu_devices = parse_gpu_inventory(gpu_output)
      gpu_indices = gpu_devices.map { |device| device.fetch("index") }
      raise InfrastructureError, "GPUs 0-3 are required; detected #{gpu_indices.inspect}" unless (0..3).all? { |index| gpu_indices.include?(index) }
      required_devices = gpu_devices.select { |device| (0..3).cover?(device.fetch("index")) }.sort_by { |device| device.fetch("index") }
      required_devices.each do |device|
        unless device.fetch("name").include?("RTX 3090")
          raise InfrastructureError, "GPU #{device.fetch('index')} is not an RTX 3090: #{device.fetch('name')}"
        end
        unless device.fetch("memory_mib") >= 24 * 1024
          raise InfrastructureError,
                "GPU #{device.fetch('index')} has only #{device.fetch('memory_mib')} MiB; at least 24576 MiB are required"
        end
      end
      gpu_topology_output = LocalEvaluation.capture(%w[nvidia-smi topo -m])
      gpu_topology = parse_gpu_topology(gpu_topology_output)
      expected_gpu_numa = { 0 => 0, 1 => 0, 2 => 1, 3 => 1 }
      expected_gpu_numa.each do |index, expected_node|
        actual = gpu_topology[index]
        unless actual && actual.fetch("numa_node") == expected_node
          raise InfrastructureError,
                "GPU #{index} does not match required NUMA node #{expected_node}: #{actual.inspect}"
        end
      end
      required_devices.each { |device| device.merge!(gpu_topology.fetch(device.fetch("index"))) }
      SystemdContainment.require_available!
      launcher_probes = probe_launcher_profiles!
      {
        "physical_cpu_ids" => (0..127).to_a,
        "physical_cores" => physical.uniq.size,
        "numa_nodes" => [0, 1],
        "gpu_indices" => gpu_indices,
        "gpu_devices" => required_devices,
        "gpu_topology" => gpu_topology.transform_keys(&:to_s),
        "cgroup_containment" => SystemdContainment.available?,
        "launcher_probes" => launcher_probes
      }
    rescue ArgumentError, KeyError => e
      raise InfrastructureError, "Could not parse hardware topology: #{e.message}"
    end

    private

    def executable_on_path?(command)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
        File.executable?(File.join(directory, command))
      end
    end

    def parse_gpu_inventory(output)
      devices = output.lines.reject { |line| line.strip.empty? }.map do |line|
        index, name, memory = line.strip.split(/\s*,\s*/, 3)
        raise InfrastructureError, "Malformed nvidia-smi inventory line: #{line.inspect}" unless index && name && memory
        { "index" => Integer(index, 10), "name" => name, "memory_mib" => Integer(Float(memory)) }
      end
      raise InfrastructureError, "nvidia-smi returned no GPU inventory" if devices.empty?
      raise InfrastructureError, "nvidia-smi returned duplicate GPU indices" unless devices.map { |entry| entry["index"] }.uniq.size == devices.size
      devices
    end

    def parse_gpu_topology(output)
      clean = output.gsub(/\e\[[0-9;]*m/, "")
      header = clean.lines.find { |line| line.include?("GPU0") && line.include?("NUMA Affinity") }
      raise InfrastructureError, "nvidia-smi topo output has no NUMA Affinity column" unless header
      columns = header.split("\t").map(&:strip)
      columns.shift while columns.first == ""
      topology = {}
      clean.lines.grep(/\AGPU\d+\s*\t/).each do |line|
        next if line == header
        values = line.split("\t").map(&:strip)
        label = values.shift
        next unless label&.match?(/\AGPU\d+\z/)
        fields = columns.zip(values).to_h
        index = Integer(label.delete_prefix("GPU"), 10)
        topology[index] = {
          "numa_node" => Integer(fields.fetch("NUMA Affinity"), 10),
          "cpu_affinity" => fields.fetch("CPU Affinity")
        }
      end
      raise InfrastructureError, "nvidia-smi topo output contains no GPU rows" if topology.empty?
      topology
    end

    def probe_launcher_profiles!
      runner = ProcessRunner.new
      results = {}
      Dir.mktmpdir("local-evaluation-preflight", "/tmp") do |directory|
        probe = File.join(directory, "observe.rb")
        LocalEvaluation.atomic_write(probe, <<~'RUBY')
          require "json"
          allowed = File.read("/proc/self/status").lines.find { |line| line.start_with?("Cpus_allowed_list:") }
          puts JSON.generate(
            "pid" => Process.pid,
            "rank" => ENV["OMPI_COMM_WORLD_RANK"],
            "local_rank" => ENV["OMPI_COMM_WORLD_LOCAL_RANK"],
            "omp_threads" => ENV["OMP_NUM_THREADS"],
            "cuda_visible_devices" => ENV["CUDA_VISIBLE_DEVICES"],
            "cpus_allowed_list" => allowed.to_s.split(":", 2).last.to_s.strip
          )
        RUBY
        File.chmod(0o555, probe)
        %i[validation benchmark].each do |mode|
          PAR_TYPES.each do |par_type|
            env, argv = command(par_type: par_type, executable: RbConfig.ruby, args: [probe], mode: mode)
            prefix = File.join(directory, "#{mode}_#{par_type}")
            limits = mode == :validation ? ExecutionLimits::VALIDATION : ExecutionLimits::PERFORMANCE
            result = runner.run(argv: argv, env: env, prefix: prefix, timeout: 15, limits: limits)
            unless result.success
              stderr = File.file?("#{prefix}_stderr.log") ? File.read("#{prefix}_stderr.log") : ""
              raise InfrastructureError,
                    "#{mode} #{par_type} launcher preflight failed (exit #{result.exit_code}): #{stderr.lines.last(8).join.strip}"
            end
            observations = File.readlines("#{prefix}_stdout.log", chomp: true).filter_map do |line|
              JSON.parse(line) if line.lstrip.start_with?("{")
            rescue JSON::ParserError
              nil
            end
            verify_launcher_observations!(mode, par_type, observations)
            results["#{mode}/#{par_type}"] = { "wall_seconds" => result.wall_seconds,
                                                "command" => argv, "environment" => env,
                                                "observations" => observations.sort_by { |entry| entry["rank"].to_i } }
          end
        end
      end
      results
    end

    def verify_launcher_observations!(mode, par_type, observations)
      distributed = %w[mpi hybrid].include?(par_type)
      expected_count = distributed ? (mode == :benchmark && par_type == "mpi" ? 128 : 4) : 1
      unless observations.size == expected_count
        raise InfrastructureError,
              "#{mode} #{par_type} preflight emitted #{observations.size} process records, expected #{expected_count}"
      end

      expected_threads = if par_type == "omp"
        mode == :benchmark ? 128 : 8
      elsif par_type == "hybrid"
        mode == :benchmark ? 32 : 8
      else
        1
      end
      observations.each do |record|
        unless record["omp_threads"] == expected_threads.to_s
          raise InfrastructureError,
                "#{mode} #{par_type} process has OMP_NUM_THREADS=#{record['omp_threads'].inspect}, expected #{expected_threads}"
        end
      end

      unless distributed
        expected_cpus = case [mode, par_type]
        when [:validation, "omp"], [:validation, "cuda"] then (0..7).to_a
        when [:benchmark, "omp"] then (0..127).to_a
        when [:benchmark, "cuda"] then (0..63).to_a
        end
        actual_cpus = parse_cpu_list(observations.first.fetch("cpus_allowed_list"))
        unless actual_cpus == expected_cpus
          raise InfrastructureError,
                "#{mode} #{par_type} CPU affinity is #{observations.first['cpus_allowed_list']}, expected #{cpu_list_text(expected_cpus)}"
        end
        expected_gpu = par_type == "cuda" ? "0" : ""
        unless observations.first["cuda_visible_devices"] == expected_gpu
          raise InfrastructureError,
                "#{mode} #{par_type} sees GPUs #{observations.first['cuda_visible_devices'].inspect}, expected #{expected_gpu.inspect}"
        end
        return
      end

      by_rank = observations.to_h { |record| [Integer(record.fetch("rank"), 10), record] }
      unless by_rank.keys.sort == (0...expected_count).to_a && by_rank.size == observations.size
        raise InfrastructureError, "#{mode} #{par_type} rank records are missing or duplicated"
      end
      expected_pe = par_type == "hybrid" ? (mode == :benchmark ? 32 : 8) : 1
      claimed_primary_cpus = []
      by_rank.sort.each do |rank, record|
        unless Integer(record.fetch("local_rank"), 10) == rank
          raise InfrastructureError, "#{mode} #{par_type} rank #{rank} has unexpected local rank #{record['local_rank'].inspect}"
        end
        allowed = parse_cpu_list(record.fetch("cpus_allowed_list"))
        primary = allowed.select { |cpu| (0..127).cover?(cpu) }
        unless primary.size == expected_pe
          raise InfrastructureError,
                "#{mode} #{par_type} rank #{rank} owns #{primary.size} physical CPUs, expected #{expected_pe}: #{record['cpus_allowed_list']}"
        end
        expected_node = rank < expected_count / 2 ? 0 : 1
        node_range = expected_node.zero? ? (0..63) : (64..127)
        unless primary.all? { |cpu| node_range.cover?(cpu) }
          raise InfrastructureError, "#{mode} #{par_type} rank #{rank} is not bound within NUMA node #{expected_node}"
        end
        if (claimed_primary_cpus & primary).any?
          raise InfrastructureError, "#{mode} #{par_type} ranks overlap physical CPU assignments"
        end
        claimed_primary_cpus.concat(primary)
        expected_gpu = par_type == "hybrid" ? rank.to_s : ""
        unless record["cuda_visible_devices"] == expected_gpu
          raise InfrastructureError,
                "#{mode} #{par_type} rank #{rank} sees GPUs #{record['cuda_visible_devices'].inspect}, expected #{expected_gpu.inspect}"
        end
      end
      if mode == :benchmark && claimed_primary_cpus.sort != (0..127).to_a
        raise InfrastructureError, "#{mode} #{par_type} ranks do not partition all 128 physical cores"
      end
    rescue ArgumentError, KeyError => e
      raise InfrastructureError, "Could not parse #{mode} #{par_type} launcher observation: #{e.message}"
    end

    def parse_cpu_list(text)
      text.split(",").flat_map do |part|
        first, last = part.split("-", 2).map { |value| Integer(value, 10) }
        last ? (first..last).to_a : [first]
      end.sort
    end

    def cpu_list_text(cpus)
      cpus.empty? ? "" : "#{cpus.first}-#{cpus.last}"
    end

    def common_omp(threads, bind)
      {
        "OMP_NUM_THREADS" => threads.to_s,
        "OMP_DYNAMIC" => "FALSE",
        "OMP_PLACES" => "cores",
        "OMP_PROC_BIND" => bind
      }
    end

    def validation_command(par_type, executable, args)
      case par_type
      when "omp"
        [common_omp(8, "close").merge("CUDA_VISIBLE_DEVICES" => ""),
         ["numactl", "--physcpubind=0-7", "--membind=0", executable, *args]]
      when "cuda"
        [{ "CUDA_VISIBLE_DEVICES" => "0", "OMP_NUM_THREADS" => "1" },
         ["numactl", "--physcpubind=0-7", "--membind=0", executable, *args]]
      when "mpi"
        [{ "CUDA_VISIBLE_DEVICES" => "", "OMP_NUM_THREADS" => "1" },
         ["mpirun", "--np", "4", "--map-by", "ppr:2:socket:PE=1", "--bind-to", "core", "--rank-by", "slot", executable, *args]]
      when "hybrid"
        [common_omp(8, "close").merge("CUDA_VISIBLE_DEVICES" => "0,1,2,3"),
         ["mpirun", "--np", "4", "--map-by", "ppr:2:socket:PE=8", "--bind-to", "core", "--rank-by", "slot",
          RbConfig.ruby, @wrapper_path, executable, *args]]
      end
    end

    def benchmark_command(par_type, executable, args)
      case par_type
      when "omp"
        [common_omp(128, "spread").merge("CUDA_VISIBLE_DEVICES" => ""),
         ["numactl", "--physcpubind=0-127", "--interleave=0,1", executable, *args]]
      when "cuda"
        [{ "CUDA_VISIBLE_DEVICES" => "0", "OMP_NUM_THREADS" => "1" },
         ["numactl", "--physcpubind=0-63", "--membind=0", executable, *args]]
      when "mpi"
        [{ "CUDA_VISIBLE_DEVICES" => "", "OMP_NUM_THREADS" => "1" },
         ["mpirun", "--np", "128", "--map-by", "ppr:64:socket:PE=1", "--bind-to", "core", "--rank-by", "slot", executable, *args]]
      when "hybrid"
        [common_omp(32, "close").merge("CUDA_VISIBLE_DEVICES" => "0,1,2,3"),
         ["mpirun", "--np", "4", "--map-by", "ppr:2:socket:PE=32", "--bind-to", "core", "--rank-by", "slot",
          RbConfig.ruby, @wrapper_path, executable, *args]]
      end
    end
  end

  module BuildSupport
    MAX_STAGED_SOURCE_BYTES = 512 * 1024 * 1024
    MAX_STAGED_SOURCE_FILE_BYTES = 64 * 1024 * 1024
    MAX_STAGED_SOURCE_ENTRIES = 20_000
    GENERATED_DIRECTORY_RE = /\A(?:build(?:[-_].*)?|CMakeFiles|Testing|\.git)\z/
    GENERATED_FILE_NAMES = %w[CMakeCache.txt cmake_install.cmake Makefile install_manifest.txt].freeze
    GENERATED_FILE_EXTENSIONS = %w[.o .obj .a .so .dylib .dll .exe].freeze
    module_function

    def build(source_dir:, build_dir:, runner:, par_type: nil, log_dir: nil)
      FileUtils.mkdir_p(build_dir)
      log_dir ||= build_dir
      FileUtils.mkdir_p(log_dir)
      configure = ["cmake", "-S", source_dir, "-B", build_dir, "-DCMAKE_BUILD_TYPE=Release",
                   "-DCMAKE_C_COMPILER=#{C_COMPILER}", "-DCMAKE_CXX_COMPILER=#{CXX_COMPILER}"]
      if %w[cuda hybrid].include?(par_type)
        raise InfrastructureError, "CUDA compiler not found: #{CUDA_COMPILER}" unless File.executable?(CUDA_COMPILER)
        configure.concat([
          "-DCMAKE_CUDA_ARCHITECTURES=86",
          "-DCMAKE_CUDA_COMPILER=#{CUDA_COMPILER}",
          "-DCUDAToolkit_ROOT=#{CUDA_ROOT}"
        ])
      end
      result = runner.run(argv: configure, prefix: File.join(log_dir, "cmake"), timeout: 120,
                          limits: ExecutionLimits::BUILD)
      return [false, "Configure failed for #{source_dir}"] unless result.success

      result = runner.run(argv: ["cmake", "--build", build_dir, "--parallel", "8"],
                          prefix: File.join(log_dir, "build"), timeout: 300,
                          limits: ExecutionLimits::BUILD)
      return [false, "Build failed for #{source_dir}"] unless result.success

      [true, nil]
    end

    def stage_source(source_root:, benchmark:, stage_root:)
      FileUtils.mkdir_p(stage_root)
      digest = Digest::SHA256.new
      copied_bytes = 0
      copied_files = 0
      seen_entries = 0
      skipped = []
      [benchmark, "common"].each do |entry|
        source = File.join(source_root, entry)
        next if entry == "common" && !File.directory?(source)
        raise "Required source directory not found: #{source}" unless File.directory?(source)
        destination = File.join(stage_root, entry)
        FileUtils.mkdir_p(destination)
        Find.find(source) do |path|
          next if path == source
          seen_entries += 1
          if seen_entries > MAX_STAGED_SOURCE_ENTRIES
            raise "Staged source exceeds #{MAX_STAGED_SOURCE_ENTRIES} entries for #{source_root}"
          end
          relative = path.delete_prefix("#{source}/")
          basename = File.basename(path)
          target = File.join(destination, relative)
          if File.directory?(path) && GENERATED_DIRECTORY_RE.match?(basename)
            skipped << File.join(entry, relative)
            Find.prune
          elsif File.symlink?(path)
            skipped << File.join(entry, relative)
          elsif File.directory?(path)
            FileUtils.mkdir_p(target)
          elsif generated_file?(path)
            skipped << File.join(entry, relative)
          elsif File.file?(path)
            size = File.size(path)
            if size > MAX_STAGED_SOURCE_FILE_BYTES
              raise "Source entry exceeds #{MAX_STAGED_SOURCE_FILE_BYTES} bytes: #{path}"
            end
            copied_bytes += size
            raise "Staged source exceeds #{MAX_STAGED_SOURCE_BYTES} bytes for #{source_root}" if copied_bytes > MAX_STAGED_SOURCE_BYTES
            FileUtils.mkdir_p(File.dirname(target))
            FileUtils.copy_file(path, target, true)
            digest << File.join(entry, relative) << "\0" << Digest::SHA256.file(path).hexdigest << "\0"
            copied_files += 1
          end
        end
      end
      make_read_only!(stage_root)
      LocalEvaluation.atomic_yaml(File.join(File.dirname(stage_root), "source_staging.yaml"), {
        "source_root" => File.expand_path(source_root),
        "benchmark" => benchmark,
        "copied_files" => copied_files,
        "seen_entries" => seen_entries,
        "copied_bytes" => copied_bytes,
        "content_sha256" => digest.hexdigest,
        "skipped_generated_entries" => skipped.sort
      })
      File.join(stage_root, benchmark)
    end

    def archive_existing(path, archive_root)
      return nil unless File.exist?(path)
      FileUtils.mkdir_p(archive_root)
      suffix = Time.now.strftime("%Y%m%d-%H%M%S")
      destination = File.join(archive_root, "#{suffix}-#{Process.pid}-#{SecureRandom.hex(3)}")
      File.rename(path, destination)
      destination
    end

    def remove_local_temporary_workspace!(root, required_prefix:)
      root = File.realpath(root)
      expected_parent = File.realpath("/tmp")
      unless File.dirname(root) == expected_parent && File.basename(root).start_with?(required_prefix)
        raise InfrastructureError, "Refusing to remove unrecognized temporary workspace: #{root}"
      end
      paths = []
      Find.find(root) { |path| paths << path }
      paths.each do |path|
        next if File.symlink?(path)
        mode = File.stat(path).mode & 0o7777
        mode |= File.directory?(path) ? 0o700 : 0o600
        File.chmod(mode, path)
      end
      FileUtils.remove_entry_secure(root)
      true
    end

    def find_executable(build_dir, benchmark)
      name = LocalEvaluation.executable_name(benchmark)
      direct = File.join(build_dir, name)
      return direct if File.file?(direct) && File.executable?(direct)

      # Preserve the paper pipeline's observable contract: generated projects
      # must place the expected executable directly in the build directory.
      # Treating a nested output path as usable would silently repair brittle
      # generated CMake rather than recording it as an experimental failure.
      raise "Executable #{name} not found at #{direct}"
    end

    def generated_file?(path)
      basename = File.basename(path)
      GENERATED_FILE_NAMES.include?(basename) || GENERATED_FILE_EXTENSIONS.include?(File.extname(path)) ||
        (File.executable?(path) && File.extname(path).empty? && !basename.match?(/\A(?:configure|.*\.sh)\z/))
    end
    private_class_method :generated_file?

    def make_read_only!(root)
      paths = []
      Find.find(root) { |path| paths << path }
      paths.reverse_each do |path|
        next if File.symlink?(path)
        mode = File.stat(path).mode & 0o7777
        File.chmod(mode & ~0o222, path)
      end
    end
    private_class_method :make_read_only!
  end

  module BenchmarkMetrics
    PATTERNS = {
      "black-scholes" => { "time" => /Computation time: (?<val>\d+(?:\.\d+)?) ms/, "throughput" => /Options per second: (?<val>\d+(?:\.\d+)?)/ },
      "cahn-hilliard" => { "time" => /Computation time: (?<val>\d+(?:\.\d+)?) ms/, "throughput" => /Performance: (?<val>\d+(?:\.\d+)?) MCellUpdates\/s/ },
      "cholesky" => { "time" => /Computation time: (?<val>\d+(?:\.\d+)?) ms/, "throughput" => /Performance: (?<val>\d+(?:\.\d+)?) GFLOPS/ },
      "floydwarshall" => { "time" => /Computation time: (?<val>\d+(?:\.\d+)?) ms/, "throughput" => /Performance: (?<val>\d+(?:\.\d+)?) GOPS/ },
      "matmul" => { "time" => /Computation time: (?<val>\d+(?:\.\d+)?) ms/, "throughput" => /Performance: (?<val>\d+(?:\.\d+)?) GFLOPS/ },
      "nbody" => { "time" => /Simulation time: (?<val>\d+(?:\.\d+)?) ms/ },
      "qtclustering" => { "time" => /Clustering time: (?<val>\d+(?:\.\d+)?) ms/, "throughput" => /Performance: \d+(?:\.\d+)? clusters\/s, (?<val>\d+(?:\.\d+)?) points\/s/ },
      "roomsim" => {
        "time" => /Total computation time: (?<val>\d+(?:\.\d+)?) ms/,
        "precomp_time" => /Precomputation time: (?<val>\d+(?:\.\d+)?) ms/,
        "sim_time" => /Simulation time: (?<val>\d+(?:\.\d+)?) ms/,
        "dist_time" => /Distance computation time: (?<val>\d+(?:\.\d+)?) ms/
      },
      "spmv" => { "time" => /Computation time: (?<val>\d+(?:\.\d+)?) ms/, "throughput" => /Performance: (?<val>\d+(?:\.\d+)?) GFLOPS\/s/ },
      "stencil3d" => { "time" => /Computation time: (?<val>\d+(?:\.\d+)?) ms/, "throughput" => /Performance: (?<val>\d+(?:\.\d+)?) MCellUpdates\/s/ },
      "unstructured" => { "time" => /Computation time: (?<val>\d+(?:\.\d+)?) ms/, "throughput" => /Elements\/sec: (?<val>\d+(?:\.\d+)?) GigaElements\/s/ }
    }.freeze
    MAX_ACROSS_RANKS_TIME_PATTERNS = [
      /Computation time \(max[^)]*\):\s*(?<val>\d+(?:\.\d+)?)\s*(?<unit>ms|us|s)\b/i,
      /Computation time:\s*(?<val>\d+(?:\.\d+)?)\s*(?<unit>ms|us|s)\s*\(max[^)]*\)/i
    ].freeze
    ALTERNATE_COMPUTATION_TIME_PATTERNS = [
      [/Computation time: (?<val>\d+(?:\.\d+)?) us/, 1.0 / 1000.0],
      [/Computation time: (?<val>\d+(?:\.\d+)?) s/, 1_000.0]
    ].freeze

    module_function

    def parse(benchmark, output)
      patterns = PATTERNS.fetch(benchmark)
      time = extract_time(benchmark, output, patterns.fetch("time"))
      unless valid_time?(time)
        raise "Invalid benchmark time for #{benchmark}: expected finite positive milliseconds, got #{time.inspect}"
      end
      metrics = { "time" => time }
      patterns.each do |name, regex|
        next if name == "time"
        match = output.match(regex)
        metrics[name] = match[:val].to_f if match
      end
      metrics
    end

    def valid_time?(value)
      value.is_a?(Numeric) && value.to_f.finite? && value.to_f.positive?
    end

    def extract_time(benchmark, output, primary_pattern)
      maximums = MAX_ACROSS_RANKS_TIME_PATTERNS.flat_map { |pattern| matches_for(output, pattern) }
      if maximums.size > 1
        raise "Ambiguous benchmark time for #{benchmark}: found #{maximums.size} max-across-ranks timings"
      end
      if maximums.one?
        match = maximums.first
        return milliseconds(match[:val], match[:unit])
      end

      primary = matches_for(output, primary_pattern)
      if primary.size > 1
        raise "Ambiguous benchmark time for #{benchmark}: found #{primary.size} primary timings"
      end

      alternates = ALTERNATE_COMPUTATION_TIME_PATTERNS.flat_map do |pattern, multiplier|
        matches_for(output, pattern).map { |match| match[:val].to_f * multiplier }
      end
      supported_timings = primary.size + alternates.size
      if supported_timings > 1
        raise "Ambiguous benchmark time for #{benchmark}: found #{supported_timings} primary/alternate-unit timings"
      end
      return primary.first[:val].to_f if primary.one?
      return alternates.first if alternates.one?

      raise "Could not parse benchmark time for #{benchmark}"
    end
    private_class_method :extract_time

    def matches_for(output, pattern)
      matches = []
      offset = 0
      while (match = pattern.match(output, offset))
        matches << match
        offset = match.end(0)
      end
      matches
    end
    private_class_method :matches_for

    def milliseconds(value, unit)
      multiplier = case unit.downcase
                   when "us" then 1.0 / 1000.0
                   when "ms" then 1.0
                   when "s" then 1_000.0
                   end
      value.to_f * multiplier
    end
    private_class_method :milliseconds

    def median(values)
      raise ArgumentError, "Cannot compute median of an empty array" if values.empty?
      sorted = values.sort
      middle = sorted.length / 2
      sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end
  end
end
