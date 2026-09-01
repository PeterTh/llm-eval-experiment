# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "securerandom"
require "tempfile"
require "tmpdir"
require "yaml"
require_relative "timing_audit"

module TimingFix
  SCHEMA_VERSION = 1
  DEFAULT_MODEL = "gpt-5.6-sol"
  DEFAULT_EFFORT = "high"
  DEFAULT_TIMEOUT_SECONDS = 15 * 60
  DEFAULT_RETRIES = 4
  DEFAULT_TRIAL_SIZE = 16
  DEFAULT_TRIAL_JOBS = 4
  DEFAULT_FULL_JOBS = 16
  MAX_EDITS = 8
  MAX_EDIT_TEXT_BYTES = 256 * 1024

  REQUIRED_KEYS = %w[
    program_id status summary expected_timing_semantics edits non_timing_changes notes
  ].freeze
  EDIT_KEYS = %w[new_text old_text path rationale].freeze
  STATUSES = %w[proposed cannot_fix].freeze
  SPECIAL_TRIAL_IDS = %w[
    black-scholes_qwen-3.6-27B-udq4_mpi_r5
    cholesky_gpt-5.6-terra-xhigh_hybrid_r3
    matmul_gpt-5.6-luna-low_mpi_r5
    nbody_gpt-5.6-luna-medium_hybrid_r1
    qtclustering_gpt-5.6-sol-xhigh_hybrid_r5
    spmv_gpt-5.6-terra-xhigh_hybrid_r3
    stencil3d_gpt-5.2_mpi_r4
    unstructured_gpt-5.6-luna-xhigh_hybrid_r4
  ].freeze

  class InventoryBuilder
    def initialize(audit_root:, output_dir:, trial_size: DEFAULT_TRIAL_SIZE)
      @audit_root = File.realpath(audit_root)
      @output_dir = File.expand_path(output_dir)
      @trial_size = Integer(trial_size)
      raise "Trial size must be positive" unless @trial_size.positive?
    end

    def run
      raise "Output already exists: #{@output_dir}" if File.exist?(@output_dir)
      FileUtils.mkdir_p(@output_dir)

      audit_manifest = YAML.safe_load(File.read(File.join(@audit_root, "manifest.yaml")), aliases: false)
      final_metadata = YAML.safe_load(File.read(File.join(@audit_root, "final", "metadata.yaml")), aliases: false)
      generated = audit_manifest.fetch("generated_source")
      repository = TimingAudit::SourceRepository.new(root: generated.fetch("root"), commit: generated.fetch("commit"))
      all_records = TimingAudit.load_jsonl(File.join(@audit_root, "inventory.jsonl"))
      records_by_id = all_records.to_h { |record| [record.fetch("id"), record] }
      decisions = TimingAudit.load_jsonl(File.join(@audit_root, "final", "decisions.jsonl"))
                              .to_h { |decision| [decision.fetch("program_id"), decision] }
      correction_ids = File.readlines(File.join(@audit_root, "final", "correction-ids.txt"), chomp: true)
                           .reject(&:empty?)
      roots = final_metadata.fetch("roots")

      records = correction_ids.map do |id|
        record = Marshal.load(Marshal.dump(records_by_id.fetch(id)))
        decision = decisions.fetch(id)
        raise "Correction ID #{id} is not invalid" unless decision.fetch("final_verdict") == "invalid"
        record["final_decision"] = decision
        record["review_findings"] = {
          "primary" => load_result(roots.fetch("primary"), id),
          "priority" => load_optional_result(roots.fetch("priority_review"), id),
          "adjudication" => load_optional_result(roots.fetch("adjudication"), id)
        }.compact
        record
      end
      trial_ids = TrialSelector.new(records, @trial_size).select

      template_path = File.expand_path("../prompts/timing_fix_prompt.txt", __dir__)
      schema_path = File.expand_path("../schemas/timing_fix_schema.json", __dir__)
      runner_path = File.expand_path(__FILE__)
      copied_template = File.join(@output_dir, "prompt-template.txt")
      copied_schema = File.join(@output_dir, "proposal-schema.json")
      copied_runner = File.join(@output_dir, "runner-snapshot.rb")
      TimingAudit.atomic_write(copied_template, File.binread(template_path))
      TimingAudit.atomic_write(copied_schema, File.binread(schema_path))
      TimingAudit.atomic_write(copied_runner, File.binread(runner_path))
      TimingAudit.atomic_write(File.join(@output_dir, "inventory.jsonl"), TimingAudit.dump_jsonl(records))
      TimingAudit.atomic_write(File.join(@output_dir, "trial-ids.txt"), trial_ids.join("\n") + "\n")

      manifest = {
        "schema_version" => SCHEMA_VERSION,
        "created_at" => TimingAudit.utc_now,
        "audit_root" => @audit_root,
        "audit_final_metadata_sha256" => TimingAudit.sha256_file(File.join(@audit_root, "final", "metadata.yaml")),
        "audit_decisions_sha256" => TimingAudit.sha256_file(File.join(@audit_root, "final", "decisions.jsonl")),
        "selection" => { "records" => records.size, "final_verdict" => "invalid" },
        "generated_source" => generated,
        "contract" => "fix only canonical timing measurement; preserve all non-timing behavior",
        "trial" => { "size" => trial_ids.size, "ids" => trial_ids },
        "artifacts" => {
          "prompt_template_sha256" => TimingAudit.sha256_file(copied_template),
          "proposal_schema_sha256" => TimingAudit.sha256_file(copied_schema),
          "runner_sha256" => TimingAudit.sha256_file(copied_runner)
        }
      }
      TimingAudit.atomic_write(File.join(@output_dir, "manifest.yaml"), YAML.dump(manifest))
      puts "Prepared timing-fix proposal inventory: #{records.size} records"
      puts "Trial IDs:"
      trial_ids.each { |id| puts "  #{id}" }
      manifest
    rescue Exception
      FileUtils.remove_entry_secure(@output_dir) if File.directory?(@output_dir) && !File.exist?(File.join(@output_dir, "manifest.yaml"))
      raise
    end

    private

    def load_result(root, id)
      JSON.parse(File.read(File.join(root, "results", "#{id}.json")))
    end

    def load_optional_result(root, id)
      path = File.join(root, "results", "#{id}.json")
      File.file?(path) ? JSON.parse(File.read(path)) : nil
    end
  end

  class TrialSelector
    def initialize(records, size)
      @records = records
      @size = [Integer(size), records.size].min
    end

    def select
      selected = SPECIAL_TRIAL_IDS.filter_map do |id|
        @records.find { |record| record.fetch("id") == id }
      end.first(@size)
      while selected.size < @size
        remaining = @records - selected
        selected << remaining.min_by { |record| selection_key(record, selected) }
      end
      selected.map { |record| record.fetch("id") }
    end

    private

    def selection_key(record, selected)
      categories = record.fetch("final_decision").fetch("final_issue_categories")
      [
        selected.count { |entry| entry.fetch("benchmark") == record.fetch("benchmark") },
        selected.count { |entry| entry.fetch("par_type") == record.fetch("par_type") },
        categories.sum do |category|
          selected.count do |entry|
            entry.fetch("final_decision").fetch("final_issue_categories").include?(category)
          end
        end,
        selected.count { |entry| entry.fetch("model") == record.fetch("model") },
        record.fetch("overall_score") >= 9 ? 0 : 1,
        Digest::SHA256.hexdigest(record.fetch("id"))
      ]
    end
  end

  class ProposalValidator
    def initialize(records, source_root)
      @records = records.to_h { |record| [record.fetch("id"), record] }
      @source_root = File.realpath(source_root)
    end

    def validate!(proposal, expected_id:)
      raise "Proposal is not an object" unless proposal.is_a?(Hash)
      raise "Invalid proposal keys" unless proposal.keys.sort == REQUIRED_KEYS.sort
      raise "Program ID mismatch: #{proposal['program_id'].inspect}" unless proposal.fetch("program_id") == expected_id
      raise "Invalid proposal status" unless STATUSES.include?(proposal.fetch("status"))
      %w[summary expected_timing_semantics].each do |key|
        raise "#{key} must be non-empty text" unless proposal[key].is_a?(String) && !proposal[key].strip.empty?
      end
      raise "notes must be text" unless proposal.fetch("notes").is_a?(String)
      non_timing = proposal.fetch("non_timing_changes")
      raise "non_timing_changes must be an empty array" unless non_timing == []
      edits = proposal.fetch("edits")
      raise "edits must be an array" unless edits.is_a?(Array)
      if proposal.fetch("status") == "cannot_fix"
        raise "cannot_fix proposal must not contain edits" unless edits.empty?
        return true
      end
      raise "proposed fix must contain 1..#{MAX_EDITS} edits" unless edits.size.between?(1, MAX_EDITS)
      materialize(proposal, expected_id: expected_id)
      true
    end

    def materialize(proposal, expected_id:)
      record = @records.fetch(expected_id)
      files = record.fetch("source_files").to_h { |file| [file.fetch("path"), file] }
      contents = {}
      proposal.fetch("edits").each do |edit|
        raise "Invalid edit keys" unless edit.is_a?(Hash) && edit.keys.sort == EDIT_KEYS
        path = edit.fetch("path")
        file = files.fetch(path) { raise "Edit cites unavailable path #{path.inspect}" }
        unless TimingAudit::SOURCE_EXTENSIONS.include?(File.extname(path).downcase)
          raise "Timing edit may only modify source/header files: #{path}"
        end
        old_text = edit.fetch("old_text")
        new_text = edit.fetch("new_text")
        rationale = edit.fetch("rationale")
        raise "old_text must be non-empty" unless old_text.is_a?(String) && !old_text.empty?
        raise "new_text must be text" unless new_text.is_a?(String)
        raise "Edit is a no-op" if old_text == new_text
        raise "Edit text is too large" if old_text.bytesize > MAX_EDIT_TEXT_BYTES || new_text.bytesize > MAX_EDIT_TEXT_BYTES
        raise "Edit rationale must be non-empty" unless rationale.is_a?(String) && !rationale.strip.empty?
        raise "Edit contains dossier line prefixes" if old_text.match?(/^\s*\d+ \|/) || new_text.match?(/^\s*\d+ \|/)

        contents[path] ||= read_verified(file)
        occurrences = contents[path].scan(Regexp.new(Regexp.escape(old_text))).size
        raise "old_text occurs #{occurrences} times in #{path}, expected exactly once" unless occurrences == 1
        contents[path] = contents[path].sub(old_text, new_text)
        raise "Modified source is not UTF-8" unless contents[path].valid_encoding?
      end
      combined = record.fetch("source_files").sum do |file|
        (contents[file.fetch("path")] || read_verified(file)).include?(record.fetch("metric_label")) ? 1 : 0
      end
      raise "Fix removed the canonical timing label" if combined.zero?
      contents
    end

    private

    def read_verified(file)
      path = File.join(@source_root, file.fetch("git_path"))
      real = File.realpath(path)
      raise "Source path escapes repository" unless real.start_with?("#{@source_root}/")
      bytes = File.binread(real).force_encoding(Encoding::UTF_8)
      raise "Source hash changed for #{file.fetch('git_path')}" unless TimingAudit.sha256_bytes(bytes) == file.fetch("sha256")
      bytes
    end
  end

  class ProposalRunner
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
      generated = @manifest.fetch("generated_source")
      @repository = TimingAudit::SourceRepository.new(root: generated.fetch("root"), commit: generated.fetch("commit"))
      @validator = ProposalValidator.new(@records, generated.fetch("root"))
      @template = File.read(File.join(@output_dir, "prompt-template.txt"))
      @schema_path = File.join(@output_dir, "proposal-schema.json")
      verify_artifact_hashes!
      @command = TimingAudit::CodexCommand.new(model: @model, effort: @effort)
      @mutex = Mutex.new
      @completed_this_run = 0
      @failures = []
    end

    def run
      ids = selected_ids
      pending = ids.reject { |id| valid_existing_proposal?(id) }
      puts "Timing fix #{@scope}: #{ids.size} selected, #{ids.size - pending.size} complete, #{pending.size} pending, #{@jobs} workers"
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
        raise "#{@failures.size} timing-fix proposals failed after retries:\n#{details}"
      end
      if ids.sort == scope_ids.sort
        ProposalVerifier.new(@output_dir, @scope).run
      else
        puts "Completed and validated requested subset: #{ids.size} proposal(s)"
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
        "proposal_schema_sha256" => @schema_path,
        "runner_sha256" => File.join(@output_dir, "runner-snapshot.rb")
      }.each do |key, path|
        raise "Timing-fix artifact digest mismatch for #{path}" unless TimingAudit.sha256_file(path) == artifacts.fetch(key)
      end
      unless TimingAudit.sha256_file(__FILE__) == artifacts.fetch("runner_sha256")
        raise "Current timing-fix runner differs from the prepared immutable snapshot"
      end
    end

    def proposal_path(id)
      File.join(@output_dir, "proposals", "#{id}.json")
    end

    def valid_existing_proposal?(id)
      path = proposal_path(id)
      return false unless File.file?(path)
      @validator.validate!(JSON.parse(File.read(path)), expected_id: id)
    rescue StandardError => error
      warn "Ignoring invalid existing proposal #{id}: #{error.message}"
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
      findings = {
        "final_decision" => record.fetch("final_decision"),
        "reviews" => record.fetch("review_findings")
      }
      @template % {
        program_id: record.fetch("id"),
        benchmark: record.fetch("benchmark"),
        par_type: record.fetch("par_type"),
        metric_label: record.fetch("metric_label"),
        issue_categories: record.fetch("final_decision").fetch("final_issue_categories").join(", "),
        audit_findings: JSON.pretty_generate(findings),
        dossier: @repository.dossier(record)
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

      Dir.mktmpdir("llm-timing-fix-") do |temporary_dir|
        last_message = File.join(temporary_dir, "last-message.json")
        argv = @command.argv(schema_path: @schema_path, output_path: last_message)
        Tempfile.create(["timing-fix-prompt-", ".txt"], temporary_dir) do |input|
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
          "source_digest" => record.fetch("source_digest"),
          "source_tree_oid" => record.fetch("source_tree_oid"),
          "runner_sha256" => @manifest.fetch("artifacts").fetch("runner_sha256")
        }
        TimingAudit.atomic_write(metadata_path, YAML.dump(metadata))
        raise "Codex invocation timed out after #{@timeout}s" if timed_out
        raise "Codex exited #{status&.exitstatus || 'without status'}" unless status&.success?
        raise "Codex did not write its last message" unless File.file?(last_message)
        proposal = JSON.parse(File.read(last_message))
        @validator.validate!(proposal, expected_id: id)
        TimingAudit.atomic_write(proposal_path(id), JSON.pretty_generate(proposal) + "\n")
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
        complete = ids.count { |id| File.file?(proposal_path(id)) }
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

  class ProposalVerifier
    def initialize(output_dir, scope)
      @output_dir = File.realpath(output_dir)
      @scope = scope.to_s
      raise "Scope must be trial or full" unless %w[trial full].include?(@scope)
      @records = TimingAudit.load_jsonl(File.join(@output_dir, "inventory.jsonl"))
      @records_by_id = @records.to_h { |record| [record.fetch("id"), record] }
      manifest = YAML.safe_load(File.read(File.join(@output_dir, "manifest.yaml")), aliases: false)
      @validator = ProposalValidator.new(@records, manifest.fetch("generated_source").fetch("root"))
    end

    def run
      ids = if @scope == "trial"
        File.readlines(File.join(@output_dir, "trial-ids.txt"), chomp: true).reject(&:empty?)
      else
        @records.map { |record| record.fetch("id") }
      end
      proposals = ids.map do |id|
        path = File.join(@output_dir, "proposals", "#{id}.json")
        raise "Missing proposal #{id}" unless File.file?(path)
        proposal = JSON.parse(File.read(path))
        @validator.validate!(proposal, expected_id: id)
        proposal
      end
      statuses = proposals.group_by { |proposal| proposal.fetch("status") }.transform_values(&:size)
      summary = proposals.map do |proposal|
        record = @records_by_id.fetch(proposal.fetch("program_id"))
        {
          "program_id" => proposal.fetch("program_id"),
          "benchmark" => record.fetch("benchmark"),
          "model" => record.fetch("model"),
          "par_type" => record.fetch("par_type"),
          "overall_score" => record.fetch("overall_score"),
          "source_digest" => record.fetch("source_digest"),
          "status" => proposal.fetch("status"),
          "edit_count" => proposal.fetch("edits").size
        }
      end
      TimingAudit.atomic_write(File.join(@output_dir, "summary-#{@scope}.jsonl"), TimingAudit.dump_jsonl(summary))
      puts "Verified #{@scope} timing-fix proposals: #{proposals.size} (#{STATUSES.map { |s| "#{s}=#{statuses.fetch(s, 0)}" }.join(', ')})"
      true
    end
  end
end
