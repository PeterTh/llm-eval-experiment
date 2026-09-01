module LocalEvaluation
  class ScoringPipeline
    AGGREGATE_HEADERS = %w[
      benchmark model par_type run input_tokens output_tokens cached_tokens api_time total_time
      code_additions code_deletions non_whitelisted_dependencies validation_status validation_err_string
      benchmark_success benchmark_times benchmark_median_time source_batch source_path total_tokens
      benchmark_wall_times benchmark_config_sha256 timing_fixed timing_fix_issue_categories
      original_source_commit corrected_source_commit original_source_digest corrected_source_digest
      original_source_url corrected_source_url source_correction_amendment_sha256
    ].freeze

    def self.prepare(run_dir:, exact_id: nil, filter: nil, dry_run: false)
      run_dir = File.expand_path(run_dir)
      all_results = load_aggregate(run_dir)
      manifest = validate_aggregate_freshness!(run_dir, all_results, exact_id: exact_id, filter: filter)
      validate_readiness!(manifest, all_results, filtered: exact_id || filter)
      results = all_results
      results = results.select { |id, _| id == exact_id } if exact_id
      results = results.select { |id, _| id.include?(filter) } if filter
      raise "No aggregate results match the requested selection" if results.empty?
      validate_selected_benchmarks!(results)
      groups = successful_groups(results)
      if dry_run
        puts "Scoring preparation dry run: #{groups.size} cells, #{groups.values.sum(&:size)} successful results"
        return
      end

      distribution = CSV.generate do |csv|
        csv << %w[benchmark par_type rank id median_time ratio_to_fastest ratio_to_previous gap_to_previous]
        groups.sort.each do |(benchmark, par_type), entries|
          fastest = entries.first[1].benchmark_median_time
          previous = nil
          entries.each_with_index do |(id, result), index|
            time = result.benchmark_median_time
            csv << [benchmark, par_type, index + 1, id, time, safe_ratio(time, fastest),
                    previous ? safe_ratio(time, previous) : nil,
                    previous ? time - previous : nil]
            previous = time
          end
        end
      end
      suffix = selection_suffix(exact_id, filter)
      distribution_path = File.join(run_dir, "local_scoring_distributions#{suffix}.csv")
      LocalEvaluation.atomic_write(distribution_path, distribution)

      template_path = File.join(run_dir, "local_scoring_thresholds#{suffix}.proposed.csv")
      template = CSV.generate do |csv|
        csv << %w[bench type top great good fastest successful_results reviewed]
        groups.sort.each do |(benchmark, par_type), entries|
          csv << [benchmark, par_type, nil, nil, nil, entries.first[1].benchmark_median_time, entries.size, false]
        end
      end
      LocalEvaluation.atomic_write(template_path, template)
      puts "Wrote #{distribution_path} and #{template_path}"
    end

    def self.score(run_dir:, thresholds_path:, exact_id: nil, filter: nil, dry_run: false)
      run_dir = File.expand_path(run_dir)
      all_results = load_aggregate(run_dir)
      manifest = validate_aggregate_freshness!(run_dir, all_results, exact_id: exact_id, filter: filter)
      validate_readiness!(manifest, all_results, filtered: exact_id || filter)
      results = all_results
      results = results.select { |id, _| id == exact_id } if exact_id
      results = results.select { |id, _| id.include?(filter) } if filter
      raise "No aggregate results match the requested selection" if results.empty?
      validate_selected_benchmarks!(results)
      groups = successful_groups(results)
      thresholds = load_thresholds(thresholds_path)
      validate_thresholds!(groups, thresholds)

      fastest = groups.transform_values { |entries| entries.first[1].benchmark_median_time }
      results.each_value do |result|
        score = result.validation_status || 0
        if result.benchmark_success
          cell = [result.benchmark, result.par_type]
          time = result.benchmark_median_time
          limits = thresholds.fetch(cell)
          score += if time == fastest.fetch(cell)
            5
          elsif time <= limits.fetch(:top)
            4
          elsif time <= limits.fetch(:great)
            3
          elsif time <= limits.fetch(:good)
            2
          else
            1
          end
        end
        result.overall_score = score
      end
      if dry_run
        puts "Scoring dry run: thresholds valid for #{groups.size} cells and #{results.size} results"
        return
      end

      csv = CSV.generate do |out|
        out << [*AGGREGATE_HEADERS, "overall_score"]
        results.each_value do |result|
          out << aggregate_row(result) + [result.overall_score]
        end
      end
      suffix = selection_suffix(exact_id, filter)
      csv_path = File.join(run_dir, "scored_results#{suffix}.csv")
      yaml_path = File.join(run_dir, "scored_results#{suffix}.yaml")
      LocalEvaluation.atomic_write(csv_path, csv)
      LocalEvaluation.atomic_yaml(yaml_path, results)
      puts "Wrote #{csv_path} and #{yaml_path}"
    end

    def self.load_aggregate(run_dir)
      path = File.join(run_dir, "aggregate_results.yaml")
      raise "Aggregate results not found: #{path}" unless File.file?(path)
      LocalEvaluation.load_yaml(path, permitted_classes: [AggregateEvaluation]) || {}
    end
    private_class_method :load_aggregate

    def self.successful_groups(results)
      invalid = results.find do |_id, result|
        result.benchmark_success && !BenchmarkMetrics.valid_time?(result.benchmark_median_time)
      end
      if invalid
        raise "Successful aggregate result has a nonpositive or invalid benchmark time: #{invalid.first}"
      end
      results.select { |_id, result| result.benchmark_success && result.benchmark_median_time }
             .group_by { |_id, result| [result.benchmark, result.par_type] }
             .transform_values { |entries| entries.sort_by { |_id, result| result.benchmark_median_time } }
    end
    private_class_method :successful_groups

    def self.safe_ratio(numerator, denominator)
      return nil unless denominator&.positive?
      numerator / denominator
    end
    private_class_method :safe_ratio

    def self.selection_suffix(exact_id, filter)
      return "" unless exact_id || filter
      value = exact_id ? "id=#{exact_id}" : "filter=#{filter}"
      ".selection-#{Digest::SHA256.hexdigest(value)[0, 12]}"
    end
    private_class_method :selection_suffix

    def self.validate_readiness!(manifest, results, filtered:)
      return if filtered
      missing = manifest.runs.keys - results.keys
      extra = results.keys - manifest.runs.keys
      raise "Aggregate is incomplete: #{missing.size} manifest runs are missing" unless missing.empty?
      raise "Aggregate contains #{extra.size} IDs outside the manifest" unless extra.empty?
      unresolved = results.count { |_id, result| result.validation_status.nil? }
      raise "Aggregate has #{unresolved} unresolved validation records" unless unresolved.zero?
      validate_selected_benchmarks!(results)
    end
    private_class_method :validate_readiness!

    def self.validate_aggregate_freshness!(run_dir, results, exact_id:, filter:)
      manifest = Manifest.new(run_dir)
      metadata_path = File.join(run_dir, "aggregate_metadata.yaml")
      raise "Aggregate freshness metadata not found: #{metadata_path}; rerun aggregate" unless File.file?(metadata_path)

      metadata = LocalEvaluation.load_yaml(metadata_path)
      raise "Aggregate freshness metadata is malformed; rerun aggregate" unless metadata.is_a?(Hash)

      digest_paths = {
        "manifest_sha256" => manifest.path,
        "pipeline_amendment_sha256" => PipelineAmendment.path_for(run_dir),
        "source_correction_amendment_sha256" => SourceCorrectionAmendment.path_for(run_dir),
        "validation_results_sha256" => File.join(run_dir, "validation", "all_validation_results.yaml"),
        "benchmark_full_results_sha256" => File.join(run_dir, "benchmark", BENCHMARK_FULL_RESULTS_FN),
        "benchmark_config_sha256" => File.join(run_dir, "benchmark_config.yaml"),
        "aggregate_results_sha256" => File.join(run_dir, "aggregate_results.yaml")
      }
      digest_paths.each do |field, path|
        raise "Aggregate freshness metadata is missing #{field}; rerun aggregate" unless metadata.key?(field)

        current = File.file?(path) ? LocalEvaluation.sha256_file(path) : nil
        recorded = metadata[field]
        next if recorded == current

        label = field.delete_suffix("_sha256").tr("_", " ")
        raise "Aggregate is stale or tampered: #{label} digest changed; rerun aggregate"
      end

      if metadata["record_count"] != results.size
        raise "Aggregate is stale or tampered: metadata record count does not match aggregate_results.yaml"
      end
      unless %w[full partial].include?(metadata["refresh_scope"])
        raise "Aggregate freshness metadata has an invalid refresh scope; rerun aggregate"
      end
      expected_full_rebuild = metadata["refresh_scope"] == "full"
      unless metadata["full_rebuild"] == expected_full_rebuild
        raise "Aggregate freshness metadata has inconsistent full/partial rebuild markers; rerun aggregate"
      end
      if metadata["manifest_run_count"] && metadata["manifest_run_count"] != manifest.runs.size
        raise "Aggregate freshness metadata manifest count does not match the current manifest; rerun aggregate"
      end
      refreshed_ids = metadata["refreshed_ids"]
      unless refreshed_ids.is_a?(Array) && refreshed_ids.uniq.size == refreshed_ids.size &&
             refreshed_ids.all? { |id| id.is_a?(String) && manifest.runs.key?(id) }
        raise "Aggregate freshness metadata has no valid refreshed-ID set; rerun aggregate"
      end
      if expected_full_rebuild && refreshed_ids.sort != manifest.runs.keys.sort
        raise "Full aggregate freshness metadata does not cover every manifest ID; rerun aggregate"
      end

      selected_ids = manifest.filtered_runs(exact_id: exact_id, filter: filter).keys
      if exact_id || filter
        missing = selected_ids - results.keys
        raise "Aggregate is missing #{missing.size} selected manifest records (first: #{missing.first}); rerun aggregate for this selection" unless missing.empty?

        if metadata["refresh_scope"] == "partial"
          stale = selected_ids - refreshed_ids
          unless stale.empty?
            raise "Aggregate selection is stale: #{stale.size} selected IDs were not refreshed by the latest partial aggregate (first: #{stale.first})"
          end
        end

        unresolved = selected_ids.select { |id| results.fetch(id).validation_status.nil? }
        unless unresolved.empty?
          raise "Aggregate selection has #{unresolved.size} unresolved validation records (first: #{unresolved.first})"
        end
      elsif metadata["refresh_scope"] != "full" || metadata["full_rebuild"] != true
        raise "Canonical scoring requires a current full-corpus aggregate rebuild; rerun aggregate without --id/--filter"
      end
      manifest
    rescue Psych::Exception => e
      raise "Aggregate freshness metadata is unreadable (#{e.class}: #{e.message}); rerun aggregate"
    end
    private_class_method :validate_aggregate_freshness!

    def self.validate_selected_benchmarks!(results)
      missing = results.filter_map do |id, result|
        id if result.validation_status == VS_FULLY_VALID && result.benchmark_success.nil?
      end
      raise "#{missing.size} fully valid programs have no benchmark attempt (first: #{missing.first})" unless missing.empty?
    end
    private_class_method :validate_selected_benchmarks!

    def self.load_thresholds(path)
      thresholds = {}
      table = CSV.read(path, headers: true, header_converters: ->(header) { header&.strip })
      required_headers = %w[bench type top great good reviewed]
      missing_headers = required_headers - table.headers
      raise "Threshold CSV is missing columns: #{missing_headers.join(', ')}" unless missing_headers.empty?
      table.each do |row|
        key = [row["bench"]&.strip, row["type"]&.strip]
        raise "Duplicate scoring threshold row for #{key.join("/")}" if thresholds.key?(key)
        reviewed = row["reviewed"].to_s.strip.downcase == "true"
        raise "Scoring threshold row is not reviewed for #{key.join("/")}" unless reviewed
        thresholds[key] = { top: Float(row["top"]), great: Float(row["great"]), good: Float(row["good"]) }
      rescue ArgumentError, TypeError
        raise "Missing or non-numeric scoring threshold for #{key.join("/")}"
      end
      thresholds
    end
    private_class_method :load_thresholds

    def self.validate_thresholds!(groups, thresholds)
      missing = groups.keys - thresholds.keys
      extra = thresholds.keys - groups.keys
      raise "Missing thresholds for: #{missing.map { |cell| cell.join("/") }.join(", ")}" unless missing.empty?
      raise "Thresholds contain cells without successful results: #{extra.map { |cell| cell.join("/") }.join(", ")}" unless extra.empty?
      thresholds.each do |cell, values|
        unless values.values.all? { |value| value.finite? && value >= 0.0 }
          raise "Thresholds must be finite and non-negative for #{cell.join('/')}"
        end
        next if values[:top] <= values[:great] && values[:great] <= values[:good]
        raise "Thresholds must satisfy top <= great <= good for #{cell.join("/")}"
      end
    end
    private_class_method :validate_thresholds!

    def self.aggregate_row(result)
      [result.benchmark, result.model, result.par_type, result.run, result.input_tokens,
       result.output_tokens, result.cached_tokens, result.api_time, result.total_time,
       result.code_additions, result.code_deletions, result.non_whitelisted_dependencies&.join(";"),
       result.validation_status, result.validation_err_string.to_s.gsub(/[\r\n]+/, " "),
       result.benchmark_success, result.benchmark_times&.join(";"), result.benchmark_median_time,
       result.source_batch, result.source_path, result.total_tokens,
       result.benchmark_wall_times&.join(";"), result.benchmark_config_sha256,
       result.timing_fixed, result.timing_fix_issue_categories&.join(";"),
       result.original_source_commit, result.corrected_source_commit,
       result.original_source_digest, result.corrected_source_digest,
       result.original_source_url, result.corrected_source_url,
       result.source_correction_amendment_sha256]
    end
    private_class_method :aggregate_row
  end

  class StatusReporter
    VALIDATION_STAGES = {
      "parallelization" => :basic_para,
      "build" => :validation_build,
      "run" => :validation_run,
      "internal" => :internal_validation,
      "comparison" => :output_comparison
    }.freeze

    def initialize(run_dir)
      @run_dir = File.expand_path(run_dir)
      @manifest = Manifest.new(@run_dir)
    end

    def run
      puts "Local evaluation: #{@run_dir}"
      puts "  manifest runs: #{@manifest.runs.size} across #{@manifest.data.fetch("batches").size} batches"
      report_preflight
      validation = report_validation
      config_digest = report_calibration_and_config
      report_benchmark(validation, config_digest)
      report_aggregate
      report_scoring
    end

    private

    def report_preflight
      report = yaml_file(File.join(@run_dir, "preflight.yaml"))
      report = nil unless report.is_a?(Hash)
      if report
        manifest_digest = report["manifest_sha256"]
        current_digest = LocalEvaluation.sha256_file(@manifest.path)
        binding = manifest_digest == current_digest ? "manifest-matched" : "MANIFEST-MISMATCH"
        disk = report["free_disk_bytes"] ? format("; recorded free disk %.1f GiB", report["free_disk_bytes"].to_f / GIBIBYTE) : ""
        containment = report.key?("cgroup_containment") ? "; cgroup containment=#{report['cgroup_containment'] ? 'enabled' : 'DISABLED'}" : ""
        puts "  preflight: passed at #{report['checked_at'] || 'unknown time'}; #{binding}#{containment}#{disk}"
      else
        puts "  preflight: not recorded"
      end

      phase_states = %w[validation benchmark].map do |phase|
        path = File.join(@run_dir, phase, "preflight.yaml")
        state = if !File.file?(path)
          "absent"
        else
          yaml_file(path).is_a?(Hash) ? "passed" : "unreadable"
        end
        "#{phase}=#{state}"
      end
      puts "  phase preflights: #{phase_states.join('; ')}"

      amendments = PipelineAmendment.load_chain(@run_dir, manifest: @manifest)
      unless amendments.empty?
        amendment = amendments.last
        puts "  pipeline amendment: sequence=#{amendments.size}; sha256=#{amendment.digest}; affected IDs=" \
             "#{amendment.data.fetch('affected_run_ids').join(',')}"
      end
    end

    def report_validation
      records = validation_results.to_h do |result|
        [result.id_string, result]
      end
      manifest_ids = @manifest.runs.keys
      completed_ids = manifest_ids & records.keys
      pending = manifest_ids.size - completed_ids.size
      valid = completed_ids.count { |id| records[id].output_comparison }
      extras = records.keys - manifest_ids
      puts "  validation: #{completed_ids.size}/#{manifest_ids.size} complete; #{pending} pending; #{valid} fully valid"
      stage_counts = VALIDATION_STAGES.map do |name, attribute|
        "#{name}=#{completed_ids.count { |id| records[id].public_send(attribute) }}/#{completed_ids.size}"
      end
      puts "  validation stages: #{stage_counts.join('; ')}"
      puts "  validation integrity: #{extras.empty? ? 'ok' : "#{extras.size} IDs outside manifest"}"
      records
    end

    def report_calibration_and_config
      frozen_path = File.join(@run_dir, "benchmark_config.yaml")
      proposed_path = File.join(@run_dir, "benchmark_config.proposed.yaml")
      config_path = File.file?(frozen_path) ? frozen_path : (File.file?(proposed_path) ? proposed_path : nil)
      unless config_path
        puts "  calibration: not generated; 0/#{expected_cell_count} cells present"
        puts "  benchmark configuration: not generated"
        return nil
      end

      config = yaml_file(config_path) || {}
      config = {} unless config.is_a?(Hash)
      cells = expected_cells.to_h do |par_type, benchmark|
        [[par_type, benchmark], config_cell(config, par_type, benchmark)]
      end
      statuses = cells.values.each_with_object(Hash.new(0)) do |cell, counts|
        counts[cell ? (cell["status"] || "unspecified") : "missing"] += 1
      end
      resolved = cells.values.count { |cell| cell && cell["resolved"] == true }
      present = cells.values.count { |cell| !cell.nil? }
      state = File.file?(frozen_path) ? "frozen" : "proposed"
      puts "  calibration: #{state}; #{present}/#{expected_cell_count} cells present; #{resolved}/#{expected_cell_count} resolved; validation_complete=#{!!config['validation_complete']}"
      puts "  calibration statuses: #{statuses.sort.map { |status, count| "#{status}=#{count}" }.join('; ')}"

      if File.file?(frozen_path)
        digest = LocalEvaluation.sha256_file(frozen_path)
        sidecar_path = "#{frozen_path}.sha256"
        sidecar_state = if !File.file?(sidecar_path)
          "missing"
        elsif File.read(sidecar_path).strip == digest
          "matches"
        else
          "MISMATCH"
        end
        read_only = (File.stat(frozen_path).mode & 0o222).zero?
        puts "  benchmark configuration: frozen; sha256=#{digest}; digest sidecar=#{sidecar_state}; read-only=#{read_only}"
        digest
      else
        puts "  benchmark configuration: proposed (review and freeze required)"
        nil
      end
    end

    def report_benchmark(validation, config_digest)
      full_path = File.join(@run_dir, "benchmark", BENCHMARK_FULL_RESULTS_FN)
      simple_path = File.join(@run_dir, "benchmark", BENCHMARK_RESULTS_FN)
      full = yaml_file(full_path) || {}
      simple = yaml_file(simple_path) || {}
      full = {} unless full.is_a?(Hash)
      simple = {} unless simple.is_a?(Hash)
      eligible_ids = @manifest.runs.keys.select { |id| validation[id]&.output_comparison }
      attempted_ids = eligible_ids & full.keys
      pending = eligible_ids.size - attempted_ids.size
      successful = attempted_ids.count { |id| full_record_success?(full[id]) }
      failed = attempted_ids.size - successful
      puts "  benchmark: #{attempted_ids.size}/#{eligible_ids.size} fully-valid programs attempted; #{pending} pending; #{successful} successful; #{failed} failed"

      malformed = full.count { |_id, record| !full_record_valid?(record) }
      derived = full.to_h { |id, record| [id, record.is_a?(Array) ? record[0] : nil] }
      compatibility = if !File.file?(full_path) && !File.file?(simple_path)
        "not started"
      elsif !File.file?(full_path)
        "full results missing"
      elsif !File.file?(simple_path)
        "compatibility results missing"
      elsif malformed.positive?
        "#{malformed} malformed full records"
      elsif simple == derived
        "consistent"
      else
        "MISMATCH"
      end

      metadata = yaml_file(File.join(@run_dir, "benchmark", "benchmark_run_metadata.yaml"))
      metadata = nil unless metadata.is_a?(Hash)
      recorded_digest = metadata && metadata["configuration_sha256"]
      digest_state = if full.empty? && metadata.nil?
        "not recorded"
      elsif config_digest && recorded_digest == config_digest
        "matches frozen config"
      elsif !config_digest && recorded_digest
        "recorded #{recorded_digest}; no frozen config available"
      elsif recorded_digest
        "MISMATCH (recorded #{recorded_digest})"
      else
        "missing"
      end
      per_id_issues = full.keys.count do |id|
        per_id = yaml_file(File.join(@run_dir, "benchmark", id, "benchmark_metadata.yaml"))
        !per_id.is_a?(Hash) || (config_digest && per_id["configuration_sha256"] != config_digest)
      end
      puts "  benchmark artifacts: canonical=#{compatibility}; config digest #{digest_state}; per-ID metadata issues=#{per_id_issues}"
    end

    def report_aggregate
      aggregate_path = File.join(@run_dir, "aggregate_results.yaml")
      unless File.file?(aggregate_path)
        puts "  aggregate: absent"
        return
      end

      results = yaml_file(aggregate_path, permitted_classes: [AggregateEvaluation]) || {}
      results = {} unless results.is_a?(Hash)
      manifest_ids = @manifest.runs.keys
      missing = manifest_ids - results.keys
      extra = results.keys - manifest_ids
      metadata = yaml_file(File.join(@run_dir, "aggregate_metadata.yaml")) || {}
      metadata = {} unless metadata.is_a?(Hash)
      complete = missing.empty? && extra.empty?
      warning_count = metadata["warning_records"]
      unless warning_count
        warnings = yaml_file(File.join(@run_dir, "aggregate_parse_warnings.yaml")) || {}
        warning_count = warnings.is_a?(Hash) ? warnings.size : 0
      end
      csv_state = File.file?(File.join(@run_dir, "aggregate_results.csv")) ? "present" : "absent"
      puts "  aggregate: #{results.size}/#{manifest_ids.size} records; complete=#{complete}; missing=#{missing.size}; extra=#{extra.size}; CSV=#{csv_state}; warning records=#{warning_count}"
      if metadata.key?("complete") && metadata["complete"] != complete
        puts "  aggregate integrity: metadata completeness MISMATCH"
      end
      report_aggregate_freshness(metadata, aggregate_path)
    end

    def report_scoring
      canonical = {
        "distributions" => "local_scoring_distributions.csv",
        "threshold template" => "local_scoring_thresholds.proposed.csv",
        "scored CSV" => "scored_results.csv",
        "scored YAML" => "scored_results.yaml"
      }.map do |label, file|
        "#{label}=#{File.file?(File.join(@run_dir, file)) ? 'present' : 'absent'}"
      end
      selections = Dir.glob(File.join(@run_dir, "*.selection-*.*")).count
      puts "  scoring: #{canonical.join('; ')}; selection-specific artifacts=#{selections}"
    end

    def validation_results
      path = File.join(@run_dir, "validation", "all_validation_results.yaml")
      return [] unless File.file?(path)
      results = yaml_file(path, permitted_classes: [ValidationResult]) || []
      return [] unless results.is_a?(Array)
      results.select { |result| result.respond_to?(:id_string) && result.respond_to?(:output_comparison) }
    end

    def expected_cells
      PAR_TYPES.product(BENCHMARKS)
    end

    def expected_cell_count
      PAR_TYPES.size * BENCHMARKS.size
    end

    def config_cell(config, par_type, benchmark)
      cells = config["cells"]
      return nil unless cells.is_a?(Hash)
      backend = cells[par_type]
      return nil unless backend.is_a?(Hash)
      cell = backend[benchmark]
      cell if cell.is_a?(Hash)
    end

    def full_record_success?(record)
      record.is_a?(Array) && record[0] == true
    end

    def full_record_valid?(record)
      return false unless record.is_a?(Array) && record.size == 2 && [true, false].include?(record[0])

      if record[0]
        metrics = record[1]
        metrics.is_a?(Array) && metrics.size == BENCHMARK_COUNT &&
          metrics.all? do |entry|
            entry.is_a?(Hash) && entry.key?("time") && BenchmarkMetrics.valid_time?(entry["time"])
          end
      else
        record[1] == {} || record[1] == []
      end
    end

    def report_aggregate_freshness(metadata, aggregate_path)
      paths = {
        "aggregate_results_sha256" => aggregate_path,
        "manifest_sha256" => @manifest.path,
        "pipeline_amendment_sha256" => PipelineAmendment.path_for(@run_dir),
        "source_correction_amendment_sha256" => SourceCorrectionAmendment.path_for(@run_dir),
        "validation_results_sha256" => File.join(@run_dir, "validation", "all_validation_results.yaml"),
        "benchmark_full_results_sha256" => File.join(@run_dir, "benchmark", BENCHMARK_FULL_RESULTS_FN),
        "benchmark_config_sha256" => File.join(@run_dir, "benchmark_config.yaml")
      }
      labels = {
        "aggregate_results_sha256" => "aggregate_results",
        "manifest_sha256" => "manifest",
        "pipeline_amendment_sha256" => "pipeline_amendment",
        "source_correction_amendment_sha256" => "source_correction_amendment",
        "validation_results_sha256" => "validation",
        "benchmark_full_results_sha256" => "benchmark_full",
        "benchmark_config_sha256" => "benchmark_config"
      }
      states = paths.map do |field, path|
        state = if !metadata.key?(field)
          "not-recorded"
        else
          current = File.file?(path) ? LocalEvaluation.sha256_file(path) : nil
          metadata[field] == current ? (current ? "matches" : "matches-absent") : "MISMATCH"
        end
        "#{labels.fetch(field)}=#{state}"
      rescue StandardError => e
        "#{labels.fetch(field)}=unreadable(#{e.class})"
      end
      puts "  aggregate freshness: scope=#{metadata['refresh_scope'] || 'not-recorded'}; #{states.join('; ')}"
    end

    def yaml_file(path, permitted_classes: [])
      return nil unless File.file?(path)
      LocalEvaluation.load_yaml(path, permitted_classes: permitted_classes)
    rescue StandardError => e
      puts "  artifact warning: #{path} is unreadable (#{e.class}: #{e.message})"
      nil
    end
  end
end
