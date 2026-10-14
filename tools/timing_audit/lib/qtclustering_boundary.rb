# frozen_string_literal: true

require_relative "timing_audit"
require_relative "../../../lib/local_evaluation"

module QtclusteringBoundary
  STAGES = %w[basic_para validation_build validation_run internal_validation output_comparison].freeze
  BACKENDS = %w[omp cuda mpi hybrid].freeze
  PRIMARY_MODEL = "gpt-5.6-luna"
  ADJUDICATION_MODEL = "gpt-6.1-sol"
  REVIEW_POLICY = "luna_first_uncertainty_or_disagreement_v1"
  PILOT_CONTROLS = %w[
    qtclustering_gpt-6-luna-medium_hybrid_r2
    qtclustering_gpt-6-luna-medium_hybrid_r4
    qtclustering_claude-sonnet-5-cc-medium_hybrid_r2
    qtclustering_gpt-5.6-sol-xhigh_hybrid_r2
  ].freeze

  module_function

  def identity(benchmark, model, backend, run)
    "#{benchmark}_#{model}_#{backend}_r#{Integer(run)}"
  end

  def passed?(stages)
    values = STAGES.map { |key| stages.fetch(key) }
    raise "Invalid validation stage sequence" unless values.all? { |v| v == true || v == false } &&
      values.each_cons(2).none? { |a, b| !a && b }
    values.all?
  end

  # Keep the complete immutable inventory in the adjudication root so pilot
  # results can be reused. Only the explicitly selected subset is invoked.
  def prepare_review(main_root:, output_dir:)
    main = File.realpath(main_root)
    manifest = YAML.safe_load_file(File.join(main, "manifest.yaml"))
    records = TimingAudit.load_jsonl(File.join(main, "inventory.jsonl"))
    TimingAudit.derive_inventory(parent_root: main, output_dir: output_dir,
      ids: records.map { |r| r.fetch("id") }, provenance: {
        "boundary_adjudication" => { "parent_root" => main,
          "parent_manifest_sha256" => TimingAudit.sha256_file(File.join(main, "manifest.yaml")),
          "model" => ADJUDICATION_MODEL, "effort" => "xhigh", "blind" => true,
          "selection" => REVIEW_POLICY }
      })
    copied = YAML.safe_load_file(File.join(output_dir, "manifest.yaml"))
    trial = File.read(File.join(main, "trial-ids.txt"))
    TimingAudit.atomic_write(File.join(output_dir, "trial-ids.txt"), trial)
    copied["trial"] = manifest.fetch("trial")
    copied["artifacts"]["trial_ids_sha256"] = TimingAudit.sha256_bytes(trial)
    TimingAudit.atomic_write(File.join(output_dir, "review-policy-snapshot.rb"), File.binread(__FILE__))
    copied["boundary_adjudication"]["policy_sha256"] = TimingAudit.sha256_file(__FILE__)
    manifest.fetch("retained_artifacts").each_key do |name|
      next if %w[inventory.jsonl trial-ids.txt prompt-template.txt result-schema.json runner-snapshot.rb].include?(name)
      TimingAudit.atomic_write(File.join(output_dir, name), File.binread(File.join(main, name)))
    end
    TimingAudit.atomic_write(File.join(output_dir, "manifest.yaml"), YAML.dump(copied))
  end

  def review_selection(main_root, scope: "full", independent_root: nil)
    raise "Unknown review scope" unless %w[trial full].include?(scope)
    records = TimingAudit.load_jsonl(File.join(main_root, "inventory.jsonl"))
    if scope == "trial"
      trial = File.readlines(File.join(main_root, "trial-ids.txt"), chomp: true)
      records = records.select { |record| trial.include?(record.fetch("id")) }
    end
    primary = verify_results(main_root, records.map { |record| record.fetch("id") }, PRIMARY_MODEL)
    independent = {}
    if independent_root
      other_records = TimingAudit.load_jsonl(File.join(independent_root, "inventory.jsonl"))
      originals = TimingAudit.load_jsonl(File.join(main_root, "inventory.jsonl")).to_h { |r| [r.fetch("id"), r] }
      other_records.each do |record|
        raise "Independent review source mismatch" unless originals.fetch(record.fetch("id")).fetch("source_digest") == record.fetch("source_digest")
      end
      independent = verify_results(independent_root, other_records.map { |r| r.fetch("id") }, PRIMARY_MODEL)
    end
    records.filter_map do |record|
      id = record.fetch("id")
      result = primary.fetch(id)
      reasons = []
      reasons << "ambiguous" if result.fetch("verdict") == "ambiguous"
      reasons << "not_high_confidence" unless result.fetch("confidence") == "high"
      if independent[id] && TimingAudit.adjudication_required?(result, independent.fetch(id), include_uncertain: true)
        reasons << "independent_review_disagreement_or_uncertainty"
      end
      next if reasons.empty?
      { "program_id" => id, "reasons" => reasons }
    end
  end

  # MPI_MAXLOC does not aggregate elapsed durations. Do not let the older
  # inventory's substring feature suppress independent makespan controls.
  def explicit_mpi_max?(record, source_root)
    record.fetch("source_files").reject { |file| file.fetch("path") == "instruction.txt" }.any? do |file|
      bytes = File.binread(File.join(source_root, file.fetch("git_path")))
      raise "Source changed during control selection" unless TimingAudit.sha256_bytes(bytes) == file.fetch("sha256")
      bytes.match?(/\bMPI_MAX\b/)
    end
  end

  # Freeze previously completed reviews separately from new escalation requests.
  # This preserves legacy pilot evidence without requesting a new blanket pilot.
  def review_plan(main_root:, review_root:, scope:, independent_root: nil, create: false)
    selection = review_selection(main_root, scope: scope, independent_root: independent_root)
    filename = scope == "full" ? "adjudication-selection.jsonl" : "adjudication-selection-trial.jsonl"
    selection_path = File.join(review_root, filename)
    plan_path = File.join(review_root, "adjudication-plan-#{scope}.json")
    binding = {
      "policy" => REVIEW_POLICY, "scope" => scope,
      "primary_manifest_sha256" => TimingAudit.sha256_file(File.join(main_root, "manifest.yaml")),
      "selection_sha256" => TimingAudit.sha256_bytes(TimingAudit.dump_jsonl(selection)),
      "independent_root" => independent_root && File.realpath(independent_root),
      "independent_manifest_sha256" => independent_root && TimingAudit.sha256_file(File.join(independent_root, "manifest.yaml"))
    }
    binding["primary_results_sha256"] = Dir[File.join(main_root, "results", "*.json")].sort.to_h do |path|
      [File.basename(path, ".json"), TimingAudit.sha256_file(path)]
    end
    if independent_root
      binding["independent_results_sha256"] = Dir[File.join(independent_root, "results", "*.json")].sort.to_h do |path|
        [File.basename(path, ".json"), TimingAudit.sha256_file(path)]
      end
    end
    if File.exist?(plan_path)
      plan = JSON.parse(File.read(plan_path))
      raise "Adjudication plan changed" unless binding.all? { |key, value| plan.fetch(key) == value }
      raise "Selection changed" unless selection == TimingAudit.load_jsonl(selection_path)
    else
      raise "Missing adjudication plan" unless create
      raise "Unplanned selection already exists" if File.exist?(selection_path)
      retained = Dir[File.join(review_root, "results", "*.json")].sort.to_h do |path|
        [File.basename(path, ".json"), TimingAudit.sha256_file(path)]
      end
      verify_results(review_root, retained.keys, ADJUDICATION_MODEL)
      plan = binding.merge("created_at" => TimingAudit.utc_now, "retained_results" => retained,
        "policy_sha256" => TimingAudit.sha256_file(__FILE__))
      TimingAudit.atomic_write(selection_path, TimingAudit.dump_jsonl(selection))
      TimingAudit.atomic_write(File.join(review_root, "active-review-policy-#{scope}.rb"), File.binread(__FILE__))
      TimingAudit.atomic_write(plan_path, JSON.pretty_generate(plan) + "\n")
    end
    raise "Frozen review policy changed" unless plan.fetch("policy_sha256") ==
      TimingAudit.sha256_file(File.join(review_root, "active-review-policy-#{scope}.rb"))
    plan.fetch("retained_results").each do |id, digest|
      raise "Retained review changed: #{id}" unless TimingAudit.sha256_file(File.join(review_root, "results", "#{id}.json")) == digest
    end
    actual = Dir[File.join(review_root, "results", "*.json")].map { |path| File.basename(path, ".json") }
    allowed = selection.map { |row| row.fetch("program_id") } | plan.fetch("retained_results").keys
    raise "Unselected adjudication results" unless (actual - allowed).empty?
    [selection, plan]
  end

  def run_review(main_root:, output_dir:, scope:, jobs: nil, independent_root: nil)
    main = File.realpath(main_root)
    raise "Unknown review scope" unless %w[trial full].include?(scope)
    prepare_review(main_root: main, output_dir: output_dir) unless File.exist?(output_dir)
    manifest = YAML.safe_load_file(File.join(output_dir, "manifest.yaml"))
    raise "Adjudication parent changed" unless manifest.dig("boundary_adjudication", "parent_manifest_sha256") ==
      TimingAudit.sha256_file(File.join(main, "manifest.yaml"))
    selection, = review_plan(main_root: main, review_root: output_dir, scope: scope,
      independent_root: independent_root, create: true)
    ids = selection.map { |row| row.fetch("program_id") }
    # AuditRunner interprets an empty only_ids array as the entire inventory.
    return puts "No uncertain or disputed QT-clustering reviews require Sol" if ids.empty?
    TimingAudit::AuditRunner.new(output_dir: output_dir, scope: scope, jobs: jobs || (scope == "trial" ? 4 : 16),
      model: ADJUDICATION_MODEL, effort: "xhigh", only_ids: ids).run
  end

  def verify_results(root, ids, model)
    manifest = YAML.safe_load_file(File.join(root, "manifest.yaml"))
    manifest.fetch("retained_artifacts").each do |name, digest|
      raise "Retained audit artifact changed: #{name}" unless TimingAudit.sha256_file(File.join(root, name)) == digest
    end
    verifier = TimingAudit::AuditVerifier.new(root, "full")
    ids.to_h do |id|
      path = File.join(root, "results", "#{id}.json")
      result = JSON.parse(File.read(path))
      verifier.verify_result!(id, result)
      accepted = Dir[File.join(root, "logs", id, "attempt-*", "metadata.yaml")].any? do |metadata_path|
        metadata = YAML.safe_load_file(metadata_path)
        metadata["result_sha256"] == TimingAudit.sha256_file(path) && metadata["static_only_verified"] &&
          metadata["model"] == model && metadata["reasoning_effort"] == (model == PRIMARY_MODEL ? "high" : "xhigh")
      end
      raise "Reviewer identity mismatch for #{id}" unless accepted
      [id, result]
    end
  end

  def pilot_gate(main_root:, review_root:, independent_root: nil)
    ids = File.readlines(File.join(main_root, "trial-ids.txt"), chomp: true).reject(&:empty?)
    primary = verify_results(main_root, ids, PRIMARY_MODEL)
    selected = review_selection(main_root, scope: "trial", independent_root: independent_root)
      .map { |row| row.fetch("program_id") }
    retained = ids.select { |id| File.exist?(File.join(review_root, "results", "#{id}.json")) }
    stronger = verify_results(review_root, selected | retained, ADJUDICATION_MODEL)
    comparisons = stronger.keys.map do |id|
      a, b = primary.fetch(id), stronger.fetch(id)
      { "program_id" => id, "luna_verdict" => a.fetch("verdict"), "sol_verdict" => b.fetch("verdict"),
        "luna_categories" => a.fetch("issue_categories"), "sol_categories" => b.fetch("issue_categories"),
        "sol_confidence" => b.fetch("confidence"), "verdict_agreement" => a.fetch("verdict") == b.fetch("verdict") }
    end
    failures = []
    failures << "unresolved_sol_review" if stronger.values.any? { |r| r["verdict"] == "ambiguous" || r["confidence"] != "high" }
    failures << "too_many_verdict_disagreements" if comparisons.count { |r| !r["verdict_agreement"] } > 2
    PILOT_CONTROLS.first(3).each do |id|
      next unless ids.include?(id)
      [primary, stronger].each do |results|
        next unless results.key?(id)
        failures << "missing_known_precomputation_defect:#{id}" unless results.fetch(id).fetch("issue_categories").include?("incomplete_timed_region")
      end
    end
    report = { "created_at" => TimingAudit.utc_now, "passed" => failures.empty?, "failures" => failures.uniq,
      "records" => ids.size, "comparisons" => comparisons,
      "policy" => REVIEW_POLICY, "adjudications_required" => selected.size,
      "retained_sol_reviews" => retained.size,
      "primary_manifest_sha256" => TimingAudit.sha256_file(File.join(main_root, "manifest.yaml")),
      "review_manifest_sha256" => TimingAudit.sha256_file(File.join(review_root, "manifest.yaml")) }
    TimingAudit.atomic_write(File.join(main_root, "pilot-review.json"), JSON.pretty_generate(report) + "\n")
    puts JSON.pretty_generate(report)
    failures.empty?
  end

  def finalize(main_root:, review_root:, independent_root: nil)
    manifest = YAML.safe_load_file(File.join(main_root, "manifest.yaml"))
    review_manifest = YAML.safe_load_file(File.join(review_root, "manifest.yaml"))
    raise "Adjudication parent changed" unless review_manifest.dig("boundary_adjudication", "parent_manifest_sha256") ==
      TimingAudit.sha256_file(File.join(main_root, "manifest.yaml"))
    raise "Adjudication inventory differs" unless TimingAudit.sha256_file(File.join(main_root, "inventory.jsonl")) ==
      TimingAudit.sha256_file(File.join(review_root, "inventory.jsonl"))
    records = TimingAudit.load_jsonl(File.join(main_root, "inventory.jsonl"))
    primary = verify_results(main_root, records.map { |r| r.fetch("id") }, PRIMARY_MODEL)
    selection, plan = review_plan(main_root: main_root, review_root: review_root,
      scope: "full", independent_root: independent_root)
    review_ids = selection.map { |r| r.fetch("program_id") } | plan.fetch("retained_results").keys
    actual_review_ids = Dir[File.join(review_root, "results", "*.json")].map { |path| File.basename(path, ".json") }.sort
    raise "Adjudication result coverage mismatch" unless actual_review_ids == review_ids.sort
    stronger = verify_results(review_root, review_ids, ADJUDICATION_MODEL)
    decisions = records.map do |record|
      id = record.fetch("id")
      chosen = stronger[id] || primary.fetch(id)
      uncertain = chosen.fetch("verdict") == "ambiguous" || chosen.fetch("confidence") != "high"
      record.slice("benchmark", "model", "par_type", "run", "source_tree_oid", "source_digest",
        "overall_score", "benchmark_median_time_ms", "origin", "previously_timing_fixed", "previous_benchmark_success").merge(
          "program_id" => id, "primary_verdict" => primary.fetch(id).fetch("verdict"),
          "adjudication_verdict" => stronger[id]&.fetch("verdict"),
          "final_verdict" => uncertain ? "ambiguous" : chosen.fetch("verdict"),
          "final_issue_categories" => chosen.fetch("issue_categories"), "final_confidence" => chosen.fetch("confidence"),
          "decision_basis" => stronger.key?(id) ? "sol_6_1_blind_adjudication" : "luna_high_boundary_review",
          "timing_fix_required" => uncertain ? nil : chosen.fetch("verdict") == "invalid",
          "timing_review_required" => uncertain,
          "timing_only_fix_possible" => chosen.fetch("timing_only_fix_possible"),
          "minimal_fix" => chosen.fetch("minimal_fix"), "timed_region" => chosen.fetch("timed_region"),
          "semantic_equivalence_basis" => chosen.fetch("semantic_equivalence_basis"),
          "notes" => chosen.fetch("notes"), "evidence" => chosen.fetch("evidence"))
    end
    final_dir = File.join(main_root, "final")
    raise "Final decisions already exist" if File.exist?(final_dir)
    TimingAudit.atomic_write(File.join(final_dir, "decisions.jsonl"), TimingAudit.dump_jsonl(decisions))
    %w[correction review].each do |kind|
      key = kind == "correction" ? "timing_fix_required" : "timing_review_required"
      selected = decisions.select { |d| d.fetch(key) }.map { |d| d.fetch("program_id") }
      TimingAudit.atomic_write(File.join(final_dir, "#{kind}-ids.txt"), selected.join("\n") + (selected.empty? ? "" : "\n"))
    end
    metadata = { "created_at" => TimingAudit.utc_now, "records" => records.size,
      "final_verdict_counts" => decisions.group_by { |d| d.fetch("final_verdict") }.transform_values(&:size),
      "roots" => { "primary" => File.realpath(main_root), "priority_review" => independent_root && File.realpath(independent_root), "adjudication" => File.realpath(review_root) },
      "review_models" => manifest.fetch("review_models"), "adjudications" => stronger.size,
      "adjudications_selected" => selection.size, "retained_sol_reviews" => plan.fetch("retained_results").size,
      "review_policy" => REVIEW_POLICY,
      "review_plan_sha256" => TimingAudit.sha256_file(File.join(review_root, "adjudication-plan-full.json")),
      "primary_manifest_sha256" => TimingAudit.sha256_file(File.join(main_root, "manifest.yaml")),
      "review_manifest_sha256" => TimingAudit.sha256_file(File.join(review_root, "manifest.yaml")),
      "decisions_sha256" => TimingAudit.sha256_file(File.join(final_dir, "decisions.jsonl")),
      "finalizer_sha256" => TimingAudit.sha256_file(__FILE__),
      "policy" => "All validated QT-clustering implementations, all backends; include algorithmic preprocessing; old evidence unchanged; unresolved Sol findings require Astra/user review" }
    TimingAudit.atomic_write(File.join(final_dir, "metadata.yaml"), YAML.dump(metadata))
    TimingAudit.atomic_write(File.join(final_dir, "finalizer-snapshot.rb"), File.binread(__FILE__))
    puts JSON.pretty_generate(metadata)
  end

  class Builder
    def initialize(release_root:, validation_runs:, source_root:, source_commit:,
                   reference_root:, reference_commit:, benchmark_config:, context_path:, output_dir:, trial_size: 16,
                   include_release: true)
      @release = File.realpath(release_root)
      @validations = validation_runs.map { |path| File.realpath(path) }
      @include_release = include_release
      raise "Validation-only selection requires a validation run" if !@include_release && @validations.empty?
      @source = TimingAudit::SourceRepository.new(root: source_root, commit: source_commit)
      @reference_root = File.realpath(reference_root)
      @reference_commit = reference_commit
      @config_path = File.realpath(benchmark_config)
      @context_path = File.realpath(context_path)
      @output = File.expand_path(output_dir)
      @trial_size = Integer(trial_size)
      raise "Invalid trial size" unless @trial_size.positive?
      @inputs = []
      @excluded = []
    end

    def run
      raise "Output already exists: #{@output}" if File.exist?(@output)
      records = (@include_release ? release_records : []) + @validations.flat_map { |path| validation_records(path) }
      records.sort_by! { |row| row.fetch("id") }
      raise "Empty or duplicate inventory" if records.empty? || records.map { |r| r.fetch("id") }.uniq.size != records.size
      records.each do |record|
        record.merge!(@source.source_record(record.fetch("source_prefix")))
        expected_tree = TimingAudit.capture!("git", "-C", @source.root, "rev-parse",
          "#{record.fetch('evaluated_source_commit')}:#{record.fetch('source_prefix')}").strip
        raise "Evaluated source changed for #{record.fetch('id')}" unless expected_tree == record.fetch("source_tree_oid")
      end
      reference = TimingAudit.capture!("git", "-C", @reference_root, "show",
        "#{@reference_commit}:qtclustering/qtclustering.cpp")
      reference_metadata = { "commit" => @reference_commit, "path" => "qtclustering/qtclustering.cpp",
        "sha256" => TimingAudit.sha256_bytes(reference) }
      catalog_path = File.join(@release, "release/catalog.json")
      @inputs << file_evidence(catalog_path)
      config_paths = [@config_path] + JSON.parse(File.read(catalog_path)).fetch("campaigns").map do |campaign|
        File.join(@release, campaign.fetch("benchmark_config"))
      end
      configurations = config_paths.uniq.map do |path|
        config = YAML.safe_load_file(path, aliases: true)
        settings = config.fetch("cells").transform_values { |benchmarks| benchmarks.fetch("qtclustering").slice("args", "timeout_seconds") }
        @inputs << file_evidence(path)
        settings
      end
      raise "QT-clustering configurations differ between campaigns" unless configurations.uniq.size == 1
      context = File.read(@context_path)
      @inputs << file_evidence(@context_path)
      numbered = reference.lines.each_with_index.map { |line, i| format("%6d | %s", i + 1, line) }.join
      appendix = "Pinned sequential reference #{JSON.generate(reference_metadata)}\n#{numbered}\n" \
        "Inherited QT-clustering benchmark settings (all release campaigns agree):\n#{JSON.pretty_generate(configurations.first)}\n\n#{context}"
      prompt_path = File.expand_path("../prompts/qtclustering_boundary_prompt.txt", __dir__)
      prompt = File.read(prompt_path).sub("__REFERENCE_CONTEXT__") { appendix.gsub("%", "%%") }
      schema = JSON.parse(File.read(File.expand_path("../schemas/timing_audit_schema.json", __dir__)))
      schema.fetch("properties").fetch("evidence").fetch("items").fetch("properties").fetch("lines")["pattern"] = "^[1-9][0-9]*(-[1-9][0-9]*)?$"
      trial = pilot_ids(records)
      artifacts = {
        "prompt-template.txt" => prompt,
        "result-schema.json" => JSON.pretty_generate(schema) + "\n",
        "runner-snapshot.rb" => File.read(File.expand_path("timing_audit.rb", __dir__)),
        "preparer-snapshot.rb" => File.read(__FILE__),
        "reference-source.txt" => reference,
        "platform-context.txt" => context,
        "inputs.jsonl" => TimingAudit.dump_jsonl(@inputs.uniq),
        "excluded.jsonl" => TimingAudit.dump_jsonl(@excluded),
        "inventory.jsonl" => TimingAudit.dump_jsonl(records),
        "trial-ids.txt" => trial.join("\n") + "\n"
      }
      artifacts.each { |name, bytes| TimingAudit.atomic_write(File.join(@output, name), bytes) }
      manifest = {
        "schema_version" => 1, "inventory_version" => 1, "created_at" => TimingAudit.utc_now,
        "release_root" => @release, "dataset_path" => File.join(@release, "release/scored_results.csv"),
        "dataset_sha256" => TimingAudit.sha256_file(File.join(@release, "release/scored_results.csv")),
        "selection" => { "basis" => "qtclustering_validation_boundary_review", "benchmark" => "qtclustering",
          "parallelization_types" => BACKENDS, "validation_status" => 5, "benchmark_success" => nil,
          "include_release" => @include_release,
          "records" => records.size, "by_origin" => records.group_by { |r| r.fetch("origin") }.transform_values(&:size),
          "by_backend" => records.group_by { |r| r.fetch("par_type") }.transform_values(&:size) },
        "generated_source" => { "root" => @source.root, "commit" => @source.commit,
          "repository" => "https://github.com/PeterTh/llm-eval-generated" },
        "reference_source" => reference_metadata,
        "contract" => "include all input-dependent clustering computation; complete per-thread/device/rank timing",
        "review_models" => { "primary" => PRIMARY_MODEL, "primary_effort" => "high",
          "adjudication" => ADJUDICATION_MODEL, "adjudication_effort" => "xhigh" },
        "trial" => { "size" => trial.size, "ids" => trial },
        "artifacts" => { "prompt_template_sha256" => TimingAudit.sha256_bytes(prompt),
          "result_schema_sha256" => TimingAudit.sha256_bytes(artifacts.fetch("result-schema.json")),
          "runner_sha256" => TimingAudit.sha256_bytes(artifacts.fetch("runner-snapshot.rb")),
          "inventory_sha256" => TimingAudit.sha256_bytes(artifacts.fetch("inventory.jsonl")),
          "trial_ids_sha256" => TimingAudit.sha256_bytes(artifacts.fetch("trial-ids.txt")) },
        "retained_artifacts" => artifacts.transform_values { |bytes| TimingAudit.sha256_bytes(bytes) }
      }
      TimingAudit.atomic_write(File.join(@output, "manifest.yaml"), YAML.dump(manifest))
      puts JSON.pretty_generate(manifest.slice("selection", "trial", "review_models"))
      manifest
    end

    private

    def file_evidence(path)
      { "path" => File.realpath(path), "sha256" => TimingAudit.sha256_file(path) }
    end

    def base_record(id:, model:, backend:, run:, batch:, commit:, origin:)
      raise "Unknown backend #{backend}" unless BACKENDS.include?(backend)
      raise "Identity mismatch #{id}" unless id == QtclusteringBoundary.identity("qtclustering", model, backend, run)
      raise "Unpinned source" unless commit.match?(/\A[0-9a-f]{40}\z/)
      { "id" => id, "benchmark" => "qtclustering", "model" => model, "par_type" => backend,
        "run" => Integer(run), "source_batch" => batch, "source_prefix" => "#{batch}/#{id}",
        "evaluated_source_commit" => commit, "origin" => origin, "metric_label" => "Clustering time",
        "benchmark_median_time_ms" => nil, "overall_score" => nil, "benchmark_config_sha256" => nil }
    end

    def release_records
      catalog_path = File.join(@release, "release/catalog.json")
      csv_path = File.join(@release, "release/scored_results.csv")
      @inputs.concat([file_evidence(catalog_path), file_evidence(csv_path)])
      validation = {}
      JSON.parse(File.read(catalog_path)).fetch("campaigns").each do |campaign|
        paths = Dir[File.join(@release, campaign.fetch("validation_records"))].sort
        raise "No validation evidence for campaign" if paths.empty?
        paths.each do |path|
          @inputs << file_evidence(path)
          TimingAudit.load_jsonl(path).each do |record|
            next unless (record["benchmark"] || record.dig("metadata", "benchmark")) == "qtclustering"
            id = record.fetch("id")
            raise "Duplicate release validation #{id}" if validation.key?(id)
            validation[id] = [record, campaign]
          end
        end
      end
      selected = []
      seen = []
      CSV.foreach(csv_path, headers: true) do |row|
        next unless row.fetch("benchmark") == "qtclustering"
        id = QtclusteringBoundary.identity("qtclustering", row.fetch("model"), row.fetch("par_type"), row.fetch("run"))
        raise "Duplicate release row #{id}" if seen.include?(id)
        seen << id
        record, campaign = validation.fetch(id)
        passed = QtclusteringBoundary.passed?(record["stages"] || record.fetch("metadata").fetch("stages"))
        raise "CSV disagrees with validation #{id}" unless passed == (row.fetch("validation_status") == "5")
        unless passed
          @excluded << { "program_id" => id, "reason" => "validation_failed", "origin" => "release" }
          next
        end
        corrected = row.fetch("timing_fixed") == "true"
        commit = corrected ? row.fetch("corrected_source_commit") : campaign.fetch("source_commit")
        selected << base_record(id: id, model: row.fetch("model"), backend: row.fetch("par_type"),
          run: row.fetch("run"), batch: row.fetch("source_batch"), commit: commit, origin: "release").merge(
            "previously_timing_fixed" => corrected, "previous_benchmark_success" => row.fetch("benchmark_success") == "true")
      end
      raise "Release coverage mismatch" unless seen.sort == validation.keys.sort
      selected
    end

    def validation_records(root)
      manifest = LocalEvaluation::Manifest.new(root)
      source = manifest.data.fetch("experiment_repository")
      raise "Unpinned validation source" unless source["git"] && !source["dirty"]
      path = File.join(root, "validation/all_validation_results.yaml")
      results = LocalEvaluation.load_yaml(path, permitted_classes: [ValidationResult])
      @inputs.concat([file_evidence(manifest.path), file_evidence(path)])
      ids = results.map(&:id_string)
      raise "Incomplete or duplicate validation" unless ids.uniq == ids && ids.sort == manifest.runs.keys.sort
      results.filter_map do |result|
        info = manifest.runs.fetch(result.id_string)
        next unless info.fetch("benchmark") == "qtclustering"
        raise "Validation identity mismatch" unless result.is_for(info.fetch("benchmark"), info.fetch("model"), info.fetch("par_type"), info.fetch("run"))
        metadata_path = File.join(root, "validation", result.id_string, "validation_metadata.yaml")
        metadata = LocalEvaluation.load_yaml(metadata_path)
        @inputs << file_evidence(metadata_path)
        stages = STAGES.to_h { |key| [key, result.public_send(key)] }
        raise "Validation metadata mismatch" unless metadata.fetch("id") == result.id_string &&
          metadata.fetch("manifest_sha256") == TimingAudit.sha256_file(manifest.path) && metadata.fetch("stages") == stages
        unless QtclusteringBoundary.passed?(stages)
          @excluded << { "program_id" => result.id_string, "reason" => "validation_failed", "origin" => root }
          next
        end
        base_record(id: result.id_string, model: result.model, backend: result.par_type,
          run: result.run, batch: info.fetch("batch"), commit: source.fetch("commit"), origin: root).merge(
            "previously_timing_fixed" => false, "previous_benchmark_success" => nil)
      end
    end

    def pilot_ids(records)
      selected = PILOT_CONTROLS.filter_map { |id| records.find { |r| r.fetch("id") == id } }.first(@trial_size)
      while selected.size < [@trial_size, records.size].min
        selected << (records - selected).min_by do |record|
          [selected.count { |r| r.fetch("par_type") == record.fetch("par_type") },
           selected.count { |r| r.fetch("source_batch") == record.fetch("source_batch") },
           selected.count { |r| r.fetch("model") == record.fetch("model") },
           TimingAudit.sha256_bytes(record.fetch("id"))]
        end
      end
      selected.map { |r| r.fetch("id") }
    end
  end
end
