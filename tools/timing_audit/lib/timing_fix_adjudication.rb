# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "securerandom"
require "tempfile"
require "tmpdir"
require "yaml"
require_relative "timing_fix_review"

module TimingFixAdjudication
  SCHEMA_VERSION = 1
  DEFAULT_MODEL = "gpt-5.6-sol"
  DEFAULT_EFFORT = "xhigh"
  DEFAULT_TIMEOUT_SECONDS = 20 * 60
  DEFAULT_RETRIES = 4
  DEFAULT_TRIAL_JOBS = 4
  DEFAULT_FULL_JOBS = 8
  TRIAL_IDS = %w[
    black-scholes_claude-opus-4.6_mpi_r1
    cahn-hilliard_claude-opus-4.6_hybrid_r4
    nbody_gpt-5.6-luna-low_hybrid_r4
    stencil3d_claude-sonnet-4.5_mpi_r1
  ].freeze
  REQUIRED_KEYS = %w[
    program_id final_verdict prior_rejection_upheld confidence issue_categories
    timing_contract_satisfied timing_only_scope_satisfied
    environment_evidence_assessment rationale evidence minimal_correction notes
  ].freeze
  VERDICTS = %w[accept reject ambiguous].freeze

  class InventoryBuilder
    MPI_HEADER = "/usr/lib/x86_64-linux-gnu/openmpi/include/mpi.h"

    def initialize(review_root:, output_dir:)
      @review_root = File.realpath(review_root)
      @output_dir = File.expand_path(output_dir)
    end

    def run
      raise "Output already exists: #{@output_dir}" if File.exist?(@output_dir)
      FileUtils.mkdir_p(@output_dir)
      review_manifest_path = File.join(@review_root, "manifest.yaml")
      review_manifest = YAML.safe_load(File.read(review_manifest_path), aliases: false)
      records = TimingAudit.load_jsonl(File.join(@review_root, "inventory.jsonl"))
      records_by_id = records.to_h { |record| [record.fetch("id"), record] }
      snapshots = TimingAudit.load_jsonl(File.join(@review_root, "proposal-snapshot.jsonl"))
      snapshots_by_id = snapshots.to_h { |snapshot| [snapshot.fetch("program_id"), snapshot] }
      results = Dir[File.join(@review_root, "results", "*.json")].sort.map { |path| JSON.parse(File.read(path)) }
      rejected = results.select { |result| result.fetch("verdict") == "reject" }
      raise "Expected disputed post-fix reviews" if rejected.empty?
      review_validator = TimingFixReview::ResultValidator.new(records)
      selected_records = rejected.map do |result|
        id = result.fetch("program_id")
        review_validator.validate!(result, expected_id: id)
        record = Marshal.load(Marshal.dump(records_by_id.fetch(id)))
        record["prior_review"] = result
        record
      end
      selected_snapshots = rejected.map { |result| snapshots_by_id.fetch(result.fetch("program_id")) }
      selected_ids = selected_records.map { |record| record.fetch("id") }
      trial_ids = TRIAL_IDS.select { |id| selected_ids.include?(id) }
      raise "Adjudication trial lost a representative class" unless trial_ids.size == TRIAL_IDS.size

      environment = environment_evidence(review_manifest)
      template_path = File.expand_path("../prompts/timing_fix_adjudication_prompt.txt", __dir__)
      schema_path = File.expand_path("../schemas/timing_fix_adjudication_schema.json", __dir__)
      runner_path = File.expand_path(__FILE__)
      copied_template = File.join(@output_dir, "prompt-template.txt")
      copied_schema = File.join(@output_dir, "result-schema.json")
      copied_runner = File.join(@output_dir, "runner-snapshot.rb")
      inventory_path = File.join(@output_dir, "inventory.jsonl")
      snapshot_path = File.join(@output_dir, "proposal-snapshot.jsonl")
      environment_path = File.join(@output_dir, "environment-evidence.yaml")
      TimingAudit.atomic_write(copied_template, File.binread(template_path))
      TimingAudit.atomic_write(copied_schema, File.binread(schema_path))
      TimingAudit.atomic_write(copied_runner, File.binread(runner_path))
      TimingAudit.atomic_write(inventory_path, TimingAudit.dump_jsonl(selected_records))
      TimingAudit.atomic_write(snapshot_path, TimingAudit.dump_jsonl(selected_snapshots))
      TimingAudit.atomic_write(environment_path, YAML.dump(environment))
      TimingAudit.atomic_write(File.join(@output_dir, "trial-ids.txt"), trial_ids.join("\n") + "\n")

      manifest = {
        "schema_version" => SCHEMA_VERSION,
        "created_at" => TimingAudit.utc_now,
        "review_root" => @review_root,
        "review_manifest_sha256" => TimingAudit.sha256_file(review_manifest_path),
        "review_summary_sha256" => TimingAudit.sha256_file(File.join(@review_root, "summary-full.jsonl")),
        "manual_review_overrides_sha256" => optional_sha(File.join(@review_root, "manual-result-overrides.yaml")),
        "selection" => { "records" => selected_records.size, "prior_verdict" => "reject" },
        "generated_source" => review_manifest.fetch("generated_source"),
        "contract" => "final static adjudication of disputed post-fix timing validity",
        "trial" => { "size" => trial_ids.size, "ids" => trial_ids },
        "artifacts" => {
          "prompt_template_sha256" => TimingAudit.sha256_file(copied_template),
          "result_schema_sha256" => TimingAudit.sha256_file(copied_schema),
          "runner_sha256" => TimingAudit.sha256_file(copied_runner),
          "inventory_sha256" => TimingAudit.sha256_file(inventory_path),
          "proposal_snapshot_sha256" => TimingAudit.sha256_file(snapshot_path),
          "environment_evidence_sha256" => TimingAudit.sha256_file(environment_path)
        }
      }
      TimingAudit.atomic_write(File.join(@output_dir, "manifest.yaml"), YAML.dump(manifest))
      puts "Prepared post-fix adjudication: #{selected_records.size} disputed records"
      puts "Trial IDs:"
      trial_ids.each { |id| puts "  #{id}" }
      manifest
    rescue Exception
      if File.directory?(@output_dir) && !File.exist?(File.join(@output_dir, "manifest.yaml"))
        FileUtils.remove_entry_secure(@output_dir)
      end
      raise
    end

    private

    def environment_evidence(review_manifest)
      lines = File.readlines(MPI_HEADER, chomp: true)
      alias_lines = [1211, 1212].to_h { |number| [number.to_s, lines.fetch(number - 1)] }
      unless alias_lines.values.all? { |line| line.include?("ompi_mpi_long_long_int") }
        raise "Pinned MPI_LONG_LONG alias evidence changed"
      end
      compile = review_manifest.fetch("compile_validation")
      raise "Adjudicated patch was not fully compiled" unless compile.fetch("compile_failures") == []
      {
        "compiled_patch" => {
          "records" => compile.fetch("records"),
          "compile_successes" => compile.fetch("compile_successes"),
          "compile_failures" => compile.fetch("compile_failures"),
          "patch_sha256" => compile.fetch("patch_sha256")
        },
        "pinned_openmpi_header" => {
          "path" => MPI_HEADER,
          "sha256" => TimingAudit.sha256_file(MPI_HEADER),
          "lines" => alias_lines,
          "finding" => "MPI_LONG_LONG and MPI_LONG_LONG_INT expand to the same ompi_mpi_long_long_int datatype object."
        },
        "cuda_event_semantics" => {
          "finding" => "An event records a timestamp when it reaches the front of its stream; elapsed time is between event timestamps. A finish event enqueued after host/MPI work can therefore include the intervening wall-clock gap.",
          "primary_sources" => [
            "https://docs.nvidia.com/cuda/cuda-programming-guide/02-basics/asynchronous-execution.html",
            "https://docs.nvidia.com/cuda/pdf/CUDA_Runtime_API.pdf"
          ]
        }
      }
    end

    def optional_sha(path)
      File.file?(path) ? TimingAudit.sha256_file(path) : nil
    end
  end

  class ResultValidator
    def initialize(records)
      @records = records.to_h { |record| [record.fetch("id"), record] }
    end

    def validate!(result, expected_id:)
      raise "Result is not an object" unless result.is_a?(Hash)
      missing = REQUIRED_KEYS - result.keys
      extra = result.keys - REQUIRED_KEYS
      raise "Missing keys: #{missing.join(', ')}" unless missing.empty?
      raise "Unexpected keys: #{extra.join(', ')}" unless extra.empty?
      raise "Program ID mismatch: #{result['program_id'].inspect}" unless result.fetch("program_id") == expected_id
      raise "Invalid final verdict" unless VERDICTS.include?(result.fetch("final_verdict"))
      raise "Invalid confidence" unless TimingFixReview::CONFIDENCES.include?(result.fetch("confidence"))
      %w[prior_rejection_upheld timing_contract_satisfied timing_only_scope_satisfied].each do |key|
        raise "#{key} must be boolean" unless [true, false].include?(result.fetch(key))
      end
      categories = result.fetch("issue_categories")
      unless categories.is_a?(Array) && !categories.empty? && categories.uniq == categories
        raise "issue_categories must be a non-empty unique array"
      end
      unknown = categories - TimingFixReview::ISSUE_CATEGORIES
      raise "Unknown categories: #{unknown.join(', ')}" unless unknown.empty?
      if result.fetch("final_verdict") == "accept"
        raise "Accepted adjudication must use none" unless categories == ["none"]
        raise "Accepted adjudication cannot uphold rejection" if result.fetch("prior_rejection_upheld")
        raise "Accepted adjudication fails contract" unless result.fetch("timing_contract_satisfied") && result.fetch("timing_only_scope_satisfied")
        raise "Accepted adjudication must have empty correction" unless result.fetch("minimal_correction") == ""
      else
        raise "Non-accept cannot use none" if categories.include?("none")
        unless result.fetch("minimal_correction").is_a?(String) && !result.fetch("minimal_correction").strip.empty?
          raise "Non-accept must give minimal correction"
        end
      end
      %w[environment_evidence_assessment rationale].each do |key|
        raise "#{key} must be non-empty text" unless result[key].is_a?(String) && !result[key].strip.empty?
      end
      raise "notes must be text" unless result.fetch("notes").is_a?(String)
      validate_evidence(result.fetch("evidence"), @records.fetch(expected_id))
      true
    end

    private

    def validate_evidence(evidence, record)
      raise "Evidence must be non-empty" unless evidence.is_a?(Array) && !evidence.empty?
      line_counts = record.fetch("corrected_source_files").to_h { |file| [file.fetch("path"), file.fetch("lines")] }
      evidence.each do |entry|
        raise "Invalid evidence keys" unless entry.is_a?(Hash) && entry.keys.sort == %w[finding lines path]
        maximum = line_counts.fetch(entry.fetch("path")) { raise "Unavailable evidence path" }
        match = /\A(\d+)(?:-(\d+))?\z/.match(entry.fetch("lines").to_s)
        raise "Invalid evidence line range" unless match
        first = match[1].to_i
        last = (match[2] || match[1]).to_i
        raise "Invalid evidence line order" unless first.positive? && last >= first && last <= maximum
        raise "Empty evidence finding" unless entry.fetch("finding").is_a?(String) && !entry.fetch("finding").strip.empty?
      end
    end
  end

  class Runner
    def initialize(output_dir:, scope:, jobs:, model: DEFAULT_MODEL, effort: DEFAULT_EFFORT,
                   timeout: DEFAULT_TIMEOUT_SECONDS, retries: DEFAULT_RETRIES, only_ids: [])
      @output_dir = File.realpath(output_dir)
      @scope = scope.to_s
      raise "Scope must be trial or full" unless %w[trial full].include?(@scope)
      @jobs = Integer(jobs)
      @timeout = Integer(timeout)
      @retries = Integer(retries)
      raise "Invalid jobs/timeout/retries" unless @jobs.positive? && @timeout.positive? && @retries.positive?
      @model = model
      @effort = effort
      @only_ids = Array(only_ids)
      @manifest = YAML.safe_load(File.read(File.join(@output_dir, "manifest.yaml")), aliases: false)
      @records = TimingAudit.load_jsonl(File.join(@output_dir, "inventory.jsonl"))
      @records_by_id = @records.to_h { |record| [record.fetch("id"), record] }
      snapshots = TimingAudit.load_jsonl(File.join(@output_dir, "proposal-snapshot.jsonl"))
      @proposals_by_id = snapshots.to_h { |snapshot| [snapshot.fetch("program_id"), snapshot.fetch("proposal")] }
      generated = @manifest.fetch("generated_source")
      TimingAudit::SourceRepository.new(root: generated.fetch("root"), commit: generated.fetch("commit"))
      @source_root = generated.fetch("root")
      @proposal_validator = TimingFix::ProposalValidator.new(@records, @source_root)
      @validator = ResultValidator.new(@records)
      @template = File.read(File.join(@output_dir, "prompt-template.txt"))
      @schema_path = File.join(@output_dir, "result-schema.json")
      @environment = YAML.safe_load(File.read(File.join(@output_dir, "environment-evidence.yaml")), aliases: false)
      verify_hashes!
      @command = TimingAudit::CodexCommand.new(model: @model, effort: @effort)
      @mutex = Mutex.new
      @completed = 0
      @failures = []
    end

    def run
      ids = selected_ids
      pending = ids.reject { |id| valid_existing?(id) }
      puts "Post-fix adjudication #{@scope}: #{ids.size} selected, #{ids.size - pending.size} complete, #{pending.size} pending, #{@jobs} workers"
      update_progress(ids)
      queue = Queue.new
      pending.each { |id| queue << id }
      @jobs.times { queue << nil }
      workers = @jobs.times.map do |index|
        Thread.new do
          while (id = queue.pop)
            begin
              run_with_retries(id, index + 1)
            rescue Exception => error
              @mutex.synchronize { @failures << [id, error]; warn "FAILED #{id}: #{error.message}" }
            ensure
              update_progress(ids)
            end
          end
        end
      end
      workers.each(&:join)
      unless @failures.empty?
        raise "#{@failures.size} adjudications failed:\n#{@failures.map { |id, e| "#{id}: #{e.message}" }.join("\n")}"
      end
      if ids.sort == scope_ids.sort
        Verifier.new(@output_dir, @scope).run
      else
        puts "Completed requested adjudication subset: #{ids.size}"
      end
    end

    private

    def scope_ids
      return @records.map { |record| record.fetch("id") } if @scope == "full"
      File.readlines(File.join(@output_dir, "trial-ids.txt"), chomp: true).reject(&:empty?)
    end

    def selected_ids
      ids = scope_ids
      return ids if @only_ids.empty?
      unknown = @only_ids - ids
      raise "IDs outside scope: #{unknown.join(', ')}" unless unknown.empty?
      @only_ids
    end

    def verify_hashes!
      artifacts = @manifest.fetch("artifacts")
      {
        "prompt_template_sha256" => "prompt-template.txt",
        "result_schema_sha256" => "result-schema.json",
        "runner_sha256" => "runner-snapshot.rb",
        "inventory_sha256" => "inventory.jsonl",
        "proposal_snapshot_sha256" => "proposal-snapshot.jsonl",
        "environment_evidence_sha256" => "environment-evidence.yaml"
      }.each do |key, name|
        raise "Artifact digest mismatch: #{name}" unless TimingAudit.sha256_file(File.join(@output_dir, name)) == artifacts.fetch(key)
      end
      raise "Current adjudication runner differs from snapshot" unless TimingAudit.sha256_file(__FILE__) == artifacts.fetch("runner_sha256")
    end

    def result_path(id)
      File.join(@output_dir, "results", "#{id}.json")
    end

    def valid_existing?(id)
      return false unless File.file?(result_path(id))
      @validator.validate!(JSON.parse(File.read(result_path(id))), expected_id: id)
    rescue StandardError => error
      warn "Ignoring invalid existing adjudication #{id}: #{error.message}"
      false
    end

    def build_prompt(record)
      id = record.fetch("id")
      proposal = @proposals_by_id.fetch(id)
      corrected = TimingFixReview::CorrectedSource.new(record: record, proposal: proposal,
        source_root: @source_root, validator: @proposal_validator)
      raise "Corrected source digest mismatch" unless corrected.digest == record.fetch("corrected_source_digest")
      @template % {
        program_id: id,
        benchmark: record.fetch("benchmark"),
        par_type: record.fetch("par_type"),
        metric_label: record.fetch("metric_label"),
        environment_evidence: JSON.pretty_generate(@environment),
        prior_review: JSON.pretty_generate(record.fetch("prior_review")),
        proposal: JSON.pretty_generate(proposal),
        dossier: corrected.dossier
      }
    end

    def run_with_retries(id, worker)
      record = @records_by_id.fetch(id)
      prompt = build_prompt(record)
      last_error = nil
      @retries.times do |offset|
        attempt = offset + 1
        begin
          run_attempt(record, prompt, attempt, worker)
          @mutex.synchronize { @completed += 1; puts "[#{worker}] complete #{id} (#{@completed} new)" }
          return
        rescue Exception => error
          last_error = error
          @mutex.synchronize { warn "[#{worker}] attempt #{attempt}/#{@retries} failed for #{id}: #{error.message}" }
          sleep([2**attempt, 20].min + rand) if attempt < @retries
        end
      end
      raise last_error
    end

    def run_attempt(record, prompt, attempt, worker)
      id = record.fetch("id")
      attempt_dir = File.join(@output_dir, "logs", id, format("attempt-%02d", attempt))
      FileUtils.mkdir_p(attempt_dir)
      stdout_path = File.join(attempt_dir, "events.jsonl")
      stderr_path = File.join(attempt_dir, "stderr.log")
      started = TimingAudit.monotonic_now
      started_at = TimingAudit.utc_now
      status = nil
      timed_out = false
      Dir.mktmpdir("llm-timing-adjudication-", "/tmp") do |temporary_dir|
        last_message = File.join(temporary_dir, "last-message.json")
        argv = @command.argv(schema_path: @schema_path, output_path: last_message)
        Tempfile.create(["timing-adjudication-prompt-", ".txt"], temporary_dir) do |input|
          input.binmode; input.write(prompt); input.flush; input.rewind
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
        metadata = {
          "program_id" => id, "worker" => worker, "attempt" => attempt,
          "started_at" => started_at, "finished_at" => TimingAudit.utc_now,
          "wall_seconds" => TimingAudit.monotonic_now - started,
          "timed_out" => timed_out, "exit_code" => status&.exitstatus,
          "term_signal" => status&.termsig, "model" => @model,
          "reasoning_effort" => @effort, "prompt_sha256" => TimingAudit.sha256_bytes(prompt),
          "prompt_bytes" => prompt.bytesize,
          "corrected_source_digest" => record.fetch("corrected_source_digest"),
          "source_or_program_executed" => false
        }
        TimingAudit.atomic_write(File.join(attempt_dir, "metadata.yaml"), YAML.dump(metadata))
        raise "Codex timed out" if timed_out
        raise "Codex exited #{status&.exitstatus || 'without status'}" unless status&.success?
        raise "Missing last message" unless File.file?(last_message)
        result = JSON.parse(File.read(last_message))
        @validator.validate!(result, expected_id: id)
        TimingAudit.atomic_write(result_path(id), JSON.pretty_generate(result) + "\n")
      end
    end

    def terminate_group(pid)
      Process.kill("TERM", -pid)
      sleep 1
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end

    def update_progress(ids)
      @mutex.synchronize do
        complete = ids.count { |id| File.file?(result_path(id)) }
        TimingAudit.atomic_write(File.join(@output_dir, "progress-#{@scope}.yaml"), YAML.dump({
          "updated_at" => TimingAudit.utc_now, "scope" => @scope,
          "selected" => ids.size, "complete" => complete,
          "pending" => ids.size - complete, "failures_this_run" => @failures.size
        }))
      end
    end
  end

  class Verifier
    def initialize(output_dir, scope)
      @output_dir = File.realpath(output_dir)
      @scope = scope
      @records = TimingAudit.load_jsonl(File.join(@output_dir, "inventory.jsonl"))
      @validator = ResultValidator.new(@records)
    end

    def run
      ids = @scope == "full" ? @records.map { |r| r.fetch("id") } : File.readlines(File.join(@output_dir, "trial-ids.txt"), chomp: true).reject(&:empty?)
      results = ids.map do |id|
        path = File.join(@output_dir, "results", "#{id}.json")
        raise "Missing adjudication #{id}" unless File.file?(path)
        result = JSON.parse(File.read(path)); @validator.validate!(result, expected_id: id); result
      end
      summary = results.map do |result|
        {
          "program_id" => result.fetch("program_id"),
          "final_verdict" => result.fetch("final_verdict"),
          "prior_rejection_upheld" => result.fetch("prior_rejection_upheld"),
          "confidence" => result.fetch("confidence"),
          "issue_categories" => result.fetch("issue_categories")
        }
      end
      TimingAudit.atomic_write(File.join(@output_dir, "summary-#{@scope}.jsonl"), TimingAudit.dump_jsonl(summary))
      counts = results.group_by { |r| r.fetch("final_verdict") }.transform_values(&:size)
      puts "Verified #{@scope} adjudications: #{results.size} (#{VERDICTS.map { |v| "#{v}=#{counts.fetch(v, 0)}" }.join(', ')})"
    end
  end
end
