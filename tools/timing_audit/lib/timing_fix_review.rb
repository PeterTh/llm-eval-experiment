# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "tempfile"
require "tmpdir"
require "yaml"
require_relative "timing_audit"
require_relative "timing_fix"

module TimingFixReview
  SCHEMA_VERSION = 1
  DEFAULT_MODEL = "gpt-5.6-luna"
  DEFAULT_EFFORT = "high"
  DEFAULT_TIMEOUT_SECONDS = 15 * 60
  DEFAULT_RETRIES = 4
  DEFAULT_TRIAL_JOBS = 4
  DEFAULT_FULL_JOBS = 16

  REQUIRED_KEYS = %w[
    program_id verdict issue_categories confidence timing_contract_satisfied
    timing_only_scope_satisfied device_completion timed_region rank_aggregation
    collective_safety canonical_output scope_assessment evidence
    minimal_correction notes
  ].freeze
  VERDICTS = %w[accept reject ambiguous].freeze
  CONFIDENCES = %w[high medium low].freeze
  DEVICE_COMPLETION = %w[valid not_applicable invalid ambiguous].freeze
  ISSUE_CATEGORIES = %w[
    none missing_start_synchronization missing_stop_synchronization
    missing_rank_aggregation rank_local_timing non_maximum_aggregation
    wrong_mpi_datatype asymmetric_timed_region incomplete_timed_region
    timed_region_regression missing_device_synchronization timer_unit_error
    reported_value_mismatch collective_mismatch communicator_root_mismatch
    non_timing_change introduced_correctness_risk other
  ].freeze

  class CorrectedSource
    attr_reader :contents

    def initialize(record:, proposal:, source_root:, validator:)
      @record = record
      @source_root = File.realpath(source_root)
      replacements = validator.materialize(proposal, expected_id: record.fetch("id"))
      @contents = record.fetch("source_files").to_h do |file|
        path = file.fetch("path")
        [path, replacements.fetch(path) { read_verified(file) }]
      end
    end

    def digest
      aggregate = Digest::SHA256.new
      @record.fetch("source_files").each do |file|
        path = file.fetch("path")
        aggregate << path << "\0" << @contents.fetch(path) << "\0"
      end
      aggregate.hexdigest
    end

    def metadata
      @record.fetch("source_files").map do |file|
        path = file.fetch("path")
        bytes = @contents.fetch(path)
        {
          "path" => path,
          "sha256" => TimingAudit.sha256_bytes(bytes),
          "bytes" => bytes.bytesize,
          "lines" => bytes.empty? ? 0 : bytes.lines.count
        }
      end
    end

    def dossier
      @record.fetch("source_files").map do |file|
        path = file.fetch("path")
        bytes = @contents.fetch(path)
        sha256 = TimingAudit.sha256_bytes(bytes)
        numbered = bytes.lines.each_with_index.map do |line, index|
          format("%6d | %s", index + 1, line)
        end.join
        numbered << format("%6d |\n", 1) if bytes.empty?
        "===== FILE #{path} (corrected sha256 #{sha256}) =====\n#{numbered}"
      end.join("\n")
    end

    private

    def read_verified(file)
      path = File.join(@source_root, file.fetch("git_path"))
      real = File.realpath(path)
      raise "Source path escapes repository" unless real.start_with?("#{@source_root}/")
      bytes = File.binread(real).force_encoding(Encoding::UTF_8)
      raise "Source is not UTF-8: #{file.fetch('git_path')}" unless bytes.valid_encoding?
      unless TimingAudit.sha256_bytes(bytes) == file.fetch("sha256")
        raise "Source hash changed for #{file.fetch('git_path')}"
      end
      bytes
    end
  end

  class InventoryBuilder
    def initialize(proposal_root:, output_dir:)
      @proposal_root = File.realpath(proposal_root)
      @output_dir = File.expand_path(output_dir)
    end

    def run
      raise "Output already exists: #{@output_dir}" if File.exist?(@output_dir)
      FileUtils.mkdir_p(@output_dir)

      proposal_manifest_path = File.join(@proposal_root, "manifest.yaml")
      proposal_manifest = YAML.safe_load(File.read(proposal_manifest_path), aliases: false)
      generated = proposal_manifest.fetch("generated_source")
      TimingAudit::SourceRepository.new(root: generated.fetch("root"), commit: generated.fetch("commit"))
      records = TimingAudit.load_jsonl(File.join(@proposal_root, "inventory.jsonl"))
      validator = TimingFix::ProposalValidator.new(records, generated.fetch("root"))
      materialized_path = File.join(@proposal_root, "materialized", "summary-full.yaml")
      materialized = YAML.safe_load(File.read(materialized_path), aliases: false)
      validate_materialized!(materialized, records.size)

      snapshots = []
      review_records = records.map.with_index do |record, index|
        id = record.fetch("id")
        proposal_path = File.join(@proposal_root, "proposals", "#{id}.json")
        raise "Missing proposal #{id}" unless File.file?(proposal_path)
        proposal = JSON.parse(File.read(proposal_path))
        validator.validate!(proposal, expected_id: id)
        raise "Proposal #{id} is not materializable" unless proposal.fetch("status") == "proposed"
        corrected = CorrectedSource.new(
          record: record,
          proposal: proposal,
          source_root: generated.fetch("root"),
          validator: validator
        )
        snapshot = {
          "program_id" => id,
          "proposal_file_sha256" => TimingAudit.sha256_file(proposal_path),
          "proposal" => proposal
        }
        snapshots << snapshot
        enriched = Marshal.load(Marshal.dump(record))
        enriched["fix_proposal_file_sha256"] = snapshot.fetch("proposal_file_sha256")
        enriched["corrected_source_digest"] = corrected.digest
        enriched["corrected_source_files"] = corrected.metadata
        puts "  prepared corrected review source #{index + 1}/#{records.size}" if ((index + 1) % 100).zero? || index + 1 == records.size
        enriched
      end

      trial_ids = File.readlines(File.join(@proposal_root, "trial-ids.txt"), chomp: true).reject(&:empty?)
      unknown_trial_ids = trial_ids - review_records.map { |record| record.fetch("id") }
      raise "Unknown trial IDs: #{unknown_trial_ids.join(', ')}" unless unknown_trial_ids.empty?

      template_path = File.expand_path("../prompts/timing_fix_review_prompt.txt", __dir__)
      schema_path = File.expand_path("../schemas/timing_fix_review_schema.json", __dir__)
      runner_path = File.expand_path(__FILE__)
      copied_template = File.join(@output_dir, "prompt-template.txt")
      copied_schema = File.join(@output_dir, "result-schema.json")
      copied_runner = File.join(@output_dir, "runner-snapshot.rb")
      inventory_path = File.join(@output_dir, "inventory.jsonl")
      snapshots_path = File.join(@output_dir, "proposal-snapshot.jsonl")
      TimingAudit.atomic_write(copied_template, File.binread(template_path))
      TimingAudit.atomic_write(copied_schema, File.binread(schema_path))
      TimingAudit.atomic_write(copied_runner, File.binread(runner_path))
      TimingAudit.atomic_write(inventory_path, TimingAudit.dump_jsonl(review_records))
      TimingAudit.atomic_write(snapshots_path, TimingAudit.dump_jsonl(snapshots))
      TimingAudit.atomic_write(File.join(@output_dir, "trial-ids.txt"), trial_ids.join("\n") + "\n")

      patch_path = File.join(@proposal_root, "materialized", "timing-fixes-full.patch")
      raise "Missing materialized full patch" unless File.file?(patch_path)
      raise "Materialized patch digest mismatch" unless TimingAudit.sha256_file(patch_path) == materialized.fetch("patch_sha256")
      manual_overrides_path = File.join(@proposal_root, "manual-proposal-overrides.yaml")
      manifest = {
        "schema_version" => SCHEMA_VERSION,
        "created_at" => TimingAudit.utc_now,
        "proposal_root" => @proposal_root,
        "proposal_manifest_sha256" => TimingAudit.sha256_file(proposal_manifest_path),
        "proposal_summary_sha256" => TimingAudit.sha256_file(File.join(@proposal_root, "summary-full.jsonl")),
        "materialized_summary_sha256" => TimingAudit.sha256_file(materialized_path),
        "materialized_patch_sha256" => materialized.fetch("patch_sha256"),
        "manual_proposal_overrides_sha256" => File.file?(manual_overrides_path) ? TimingAudit.sha256_file(manual_overrides_path) : nil,
        "selection" => { "records" => review_records.size, "proposal_status" => "proposed" },
        "generated_source" => generated,
        "contract" => "independent static proof of corrected timing validity and timing-only edit scope",
        "trial" => { "size" => trial_ids.size, "ids" => trial_ids },
        "compile_validation" => materialized,
        "artifacts" => {
          "prompt_template_sha256" => TimingAudit.sha256_file(copied_template),
          "result_schema_sha256" => TimingAudit.sha256_file(copied_schema),
          "runner_sha256" => TimingAudit.sha256_file(copied_runner),
          "inventory_sha256" => TimingAudit.sha256_file(inventory_path),
          "proposal_snapshot_sha256" => TimingAudit.sha256_file(snapshots_path)
        }
      }
      TimingAudit.atomic_write(File.join(@output_dir, "manifest.yaml"), YAML.dump(manifest))
      puts "Prepared independent post-fix review: #{review_records.size} records"
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

    def validate_materialized!(summary, expected_records)
      raise "Full materialization summary required" unless summary.fetch("scope") == "full"
      raise "Materialization record count mismatch" unless summary.fetch("records") == expected_records
      raise "Materialization changed-path count mismatch" unless summary.fetch("changed_paths") == expected_records
      raise "Not all fixes compiled" unless summary.fetch("compiled") == expected_records &&
                                             summary.fetch("compile_successes") == expected_records &&
                                             summary.fetch("compile_failures") == []
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
      raise "Missing result keys: #{missing.join(', ')}" unless missing.empty?
      raise "Unexpected result keys: #{extra.join(', ')}" unless extra.empty?
      raise "Program ID mismatch: #{result['program_id'].inspect}" unless result.fetch("program_id") == expected_id
      raise "Invalid verdict" unless VERDICTS.include?(result.fetch("verdict"))
      raise "Invalid confidence" unless CONFIDENCES.include?(result.fetch("confidence"))
      raise "Invalid device_completion" unless DEVICE_COMPLETION.include?(result.fetch("device_completion"))
      %w[timing_contract_satisfied timing_only_scope_satisfied].each do |key|
        raise "#{key} must be boolean" unless [true, false].include?(result.fetch(key))
      end

      categories = result.fetch("issue_categories")
      unless categories.is_a?(Array) && !categories.empty? && categories.uniq == categories
        raise "issue_categories must be a non-empty unique array"
      end
      unknown = categories - ISSUE_CATEGORIES
      raise "Unknown issue categories: #{unknown.join(', ')}" unless unknown.empty?
      if result.fetch("verdict") == "accept"
        raise "Accepted result must use only none" unless categories == ["none"]
        raise "Accepted result does not satisfy timing contract" unless result.fetch("timing_contract_satisfied")
        raise "Accepted result is not timing-only" unless result.fetch("timing_only_scope_satisfied")
        unless %w[valid not_applicable].include?(result.fetch("device_completion"))
          raise "Accepted result has invalid or ambiguous device completion"
        end
        raise "Accepted result must have an empty minimal_correction" unless result.fetch("minimal_correction") == ""
      else
        raise "Non-accepted result cannot use none" if categories.include?("none")
        unless result.fetch("minimal_correction").is_a?(String) && !result.fetch("minimal_correction").strip.empty?
          raise "Non-accepted result must describe a minimal correction"
        end
      end

      %w[timed_region rank_aggregation collective_safety canonical_output scope_assessment].each do |key|
        raise "#{key} must be non-empty text" unless result[key].is_a?(String) && !result[key].strip.empty?
      end
      raise "notes must be text" unless result.fetch("notes").is_a?(String)
      validate_evidence!(result.fetch("evidence"), @records.fetch(expected_id))
      true
    end

    private

    def validate_evidence!(evidence, record)
      raise "Evidence must be a non-empty array" unless evidence.is_a?(Array) && !evidence.empty?
      line_counts = record.fetch("corrected_source_files").to_h do |file|
        [file.fetch("path"), file.fetch("lines")]
      end
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
        unless entry.fetch("finding").is_a?(String) && !entry.fetch("finding").strip.empty?
          raise "Evidence finding must be non-empty"
        end
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
      raise "Jobs, timeout, and retries must be positive" unless @jobs.positive? && @timeout.positive? && @retries.positive?
      @model = model
      @effort = effort
      @only_ids = Array(only_ids).map(&:to_s)
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
      verify_artifact_hashes!
      @command = TimingAudit::CodexCommand.new(model: @model, effort: @effort)
      @mutex = Mutex.new
      @completed_this_run = 0
      @failures = []
    end

    def run
      ids = selected_ids
      pending = ids.reject { |id| valid_existing_result?(id) }
      puts "Post-fix review #{@scope}: #{ids.size} selected, #{ids.size - pending.size} complete, #{pending.size} pending, #{@jobs} workers"
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
        raise "#{@failures.size} post-fix reviews failed after retries:\n#{details}"
      end
      if ids.sort == scope_ids.sort
        Verifier.new(@output_dir, @scope).run
      else
        puts "Completed and validated requested subset: #{ids.size} review(s)"
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
        "runner_sha256" => File.join(@output_dir, "runner-snapshot.rb"),
        "inventory_sha256" => File.join(@output_dir, "inventory.jsonl"),
        "proposal_snapshot_sha256" => File.join(@output_dir, "proposal-snapshot.jsonl")
      }.each do |key, path|
        raise "Post-fix review artifact digest mismatch for #{path}" unless TimingAudit.sha256_file(path) == artifacts.fetch(key)
      end
      unless TimingAudit.sha256_file(__FILE__) == artifacts.fetch("runner_sha256")
        raise "Current post-fix review runner differs from the prepared immutable snapshot"
      end
    end

    def result_path(id)
      File.join(@output_dir, "results", "#{id}.json")
    end

    def valid_existing_result?(id)
      path = result_path(id)
      return false unless File.file?(path)
      @validator.validate!(JSON.parse(File.read(path)), expected_id: id)
    rescue StandardError => error
      warn "Ignoring invalid existing review #{id}: #{error.message}"
      false
    end

    def run_with_retries(id, worker)
      record = @records_by_id.fetch(id)
      prompt = build_prompt(record)
      raise "Prompt exceeds #{TimingAudit::MAX_PROMPT_BYTES} bytes for #{id}" if prompt.bytesize > TimingAudit::MAX_PROMPT_BYTES
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
      id = record.fetch("id")
      proposal = @proposals_by_id.fetch(id)
      @proposal_validator.validate!(proposal, expected_id: id)
      corrected = CorrectedSource.new(
        record: record,
        proposal: proposal,
        source_root: @source_root,
        validator: @proposal_validator
      )
      raise "Corrected source digest mismatch for #{id}" unless corrected.digest == record.fetch("corrected_source_digest")
      raise "Corrected source metadata mismatch for #{id}" unless corrected.metadata == record.fetch("corrected_source_files")
      @template % {
        program_id: id,
        benchmark: record.fetch("benchmark"),
        par_type: record.fetch("par_type"),
        metric_label: record.fetch("metric_label"),
        proposal: JSON.pretty_generate(proposal),
        dossier: corrected.dossier
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

      Dir.mktmpdir("llm-timing-fix-review-", "/tmp") do |temporary_dir|
        last_message = File.join(temporary_dir, "last-message.json")
        argv = @command.argv(schema_path: @schema_path, output_path: last_message)
        Tempfile.create(["timing-fix-review-prompt-", ".txt"], temporary_dir) do |input|
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

        metadata = {
          "program_id" => id,
          "worker" => worker,
          "attempt" => attempt,
          "started_at" => started_at,
          "finished_at" => TimingAudit.utc_now,
          "wall_seconds" => TimingAudit.monotonic_now - started,
          "timed_out" => timed_out,
          "exit_code" => status&.exitstatus,
          "term_signal" => status&.termsig,
          "model" => @model,
          "reasoning_effort" => @effort,
          "prompt_sha256" => TimingAudit.sha256_bytes(prompt),
          "prompt_bytes" => prompt.bytesize,
          "original_source_digest" => record.fetch("source_digest"),
          "corrected_source_digest" => record.fetch("corrected_source_digest"),
          "proposal_file_sha256" => record.fetch("fix_proposal_file_sha256"),
          "runner_sha256" => @manifest.fetch("artifacts").fetch("runner_sha256"),
          "source_or_program_executed" => false
        }
        TimingAudit.atomic_write(metadata_path, YAML.dump(metadata))
        raise "Codex invocation timed out after #{@timeout}s" if timed_out
        raise "Codex exited #{status&.exitstatus || 'without status'}" unless status&.success?
        raise "Codex did not write its last message" unless File.file?(last_message)
        result = JSON.parse(File.read(last_message))
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

  class Verifier
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
        raise "Missing review result #{id}" unless File.file?(path)
        result = JSON.parse(File.read(path))
        @validator.validate!(result, expected_id: id)
        result
      end
      summary = results.map do |result|
        record = @records_by_id.fetch(result.fetch("program_id"))
        {
          "program_id" => result.fetch("program_id"),
          "benchmark" => record.fetch("benchmark"),
          "model" => record.fetch("model"),
          "par_type" => record.fetch("par_type"),
          "overall_score" => record.fetch("overall_score"),
          "verdict" => result.fetch("verdict"),
          "confidence" => result.fetch("confidence"),
          "timing_contract_satisfied" => result.fetch("timing_contract_satisfied"),
          "timing_only_scope_satisfied" => result.fetch("timing_only_scope_satisfied"),
          "device_completion" => result.fetch("device_completion"),
          "issue_categories" => result.fetch("issue_categories"),
          "corrected_source_digest" => record.fetch("corrected_source_digest")
        }
      end
      TimingAudit.atomic_write(File.join(@output_dir, "summary-#{@scope}.jsonl"), TimingAudit.dump_jsonl(summary))
      headers = summary.first.keys
      csv = CSV.generate do |output|
        output << headers
        summary.each do |entry|
          output << headers.map do |header|
            value = entry.fetch(header)
            value.is_a?(Array) ? value.join(";") : value
          end
        end
      end
      TimingAudit.atomic_write(File.join(@output_dir, "summary-#{@scope}.csv"), csv)
      verdicts = results.group_by { |result| result.fetch("verdict") }.transform_values(&:size)
      puts "Verified #{@scope} post-fix reviews: #{results.size} (#{VERDICTS.map { |v| "#{v}=#{verdicts.fetch(v, 0)}" }.join(', ')})"
      true
    end
  end
end
