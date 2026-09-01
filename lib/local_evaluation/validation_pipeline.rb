module LocalEvaluation
  class ValidationPipeline
    VALIDATION_TIMEOUT = 30
    VALIDATION_SIZES = {
      "black-scholes" => %w[-n 10000],
      "cahn-hilliard" => %w[-x 64 -y 64 -z 64 -i 20],
      "cholesky" => %w[-n 512],
      "floydwarshall" => %w[-n 512],
      "matmul" => %w[-n 512],
      "nbody" => %w[-n 1024 -s 10],
      "qtclustering" => %w[-n 1000],
      "roomsim" => %w[-n 256 -t 100],
      "spmv" => %w[-n 1024 -s 10 -i 10],
      "stencil3d" => %w[-x 64 -y 64 -z 64 -i 20],
      "unstructured" => %w[-n 256 -i 20]
    }.freeze

    def initialize(run_dir:, exact_id: nil, filter: nil, dry_run: false, retry_failed: false,
                   runner: ProcessRunner.new, resources: Resources.new)
      @run_dir = File.expand_path(run_dir)
      @manifest = Manifest.new(@run_dir)
      @selected = @manifest.filtered_runs(exact_id: exact_id, filter: filter)
      @dry_run = dry_run
      @retry_failed = retry_failed
      @runner = runner
      @resources = resources
      @validation_dir = File.join(@run_dir, "validation")
      @all_results_path = File.join(@validation_dir, "all_validation_results.yaml")
    end

    def run
      existing = load_results
      revision_report = @manifest.verify_input_revisions!
      if @dry_run
        pending = @selected.reject { |id, info| completed?(id, info, existing[id]) }
        puts "Validation dry run: #{pending.size} pending of #{@selected.size} selected IDs"
        pending.each do |id, info|
          executable = File.join(@validation_dir, id, LocalEvaluation.executable_name(info["benchmark"]))
          env, command = @resources.command(par_type: info["par_type"], executable: executable,
                                            args: validation_args(info["benchmark"]), mode: :validation)
          puts "#{id}: timeout=#{VALIDATION_TIMEOUT}s env=#{env.inspect} command=#{Shellwords.join(command)}"
        end
        return
      end

      FileUtils.mkdir_p(@validation_dir)
      LocalEvaluation.ensure_disk_space!(@validation_dir)
      preflight = @resources.verify_topology!
      LocalEvaluation.atomic_yaml(File.join(@validation_dir, "preflight.yaml"),
                                  preflight.merge("checked_at" => Time.now.iso8601,
                                                  "input_revisions" => revision_report))
      references = @selected.values.map { |info| info["benchmark"] }.uniq.sort.to_h do |benchmark|
        [benchmark, reference_output(benchmark)]
      end
      @selected.each do |id, info|
        if completed?(id, info, existing[id])
          puts "Skipping completed validation #{id}"
          next
        end

        LocalEvaluation.ensure_disk_space!(@validation_dir)
        puts "Validating #{id}"
        result = validate_one(id, info, references.fetch(info["benchmark"]))
        existing[id] = result
        save_results(existing)
        puts result.summary
      end
      print_summary(existing)
    end

    private

    def load_results
      return {} unless File.file?(@all_results_path)
      array = LocalEvaluation.load_yaml(@all_results_path, permitted_classes: [ValidationResult]) || []
      raise "Validation results must contain an array" unless array.is_a?(Array)

      results = {}
      array.each do |result|
        raise "Validation results contain an unexpected #{result.class}" unless result.is_a?(ValidationResult)
        id = result.id_string
        info = @manifest.runs[id]
        raise "Validation results contain unknown run ID #{id}" unless info
        unless result.is_for(info.fetch("benchmark"), info.fetch("model"), info.fetch("par_type"), info.fetch("run"))
          raise "Validation result identity does not match manifest for #{id}"
        end
        raise "Validation results contain duplicate run ID #{id}" if results.key?(id)
        results[id] = result
      end
      results
    end

    def completed?(id, info, result)
      return false unless result
      return false if @retry_failed && !result.output_comparison
      validation_artifacts_intact?(id, info, result)
    end

    def validation_artifacts_intact?(id, info, result)
      output_dir = File.join(@validation_dir, id)
      result_path = File.join(output_dir, VALIDATION_RESULT_FN)
      metadata_path = File.join(output_dir, "validation_metadata.yaml")
      return false unless File.file?(result_path) && File.size?(result_path) && File.file?(metadata_path)

      metadata = LocalEvaluation.load_yaml(metadata_path)
      expected_identity = {
        "id" => id,
        "benchmark" => info.fetch("benchmark"),
        "model" => info.fetch("model"),
        "par_type" => info.fetch("par_type"),
        "run" => info.fetch("run"),
        "manifest_sha256" => LocalEvaluation.sha256_file(@manifest.path)
      }
      return false unless expected_identity.all? { |key, value| metadata[key] == value }
      return false unless result.is_for(info.fetch("benchmark"), info.fetch("model"),
                                        info.fetch("par_type"), info.fetch("run"))

      stages = %w[basic_para validation_build validation_run internal_validation output_comparison]
      return false unless stages.all? { |stage| metadata.dig("stages", stage) == !!result.public_send(stage) }
      return false if result.validation_build && !result.basic_para
      return false if result.validation_run && !result.validation_build
      return false if result.internal_validation && !result.validation_run
      return false if result.output_comparison && !result.internal_validation

      if result.basic_para
        staged_benchmark = File.join(output_dir, "source", info.fetch("benchmark"))
        staging_metadata = File.join(output_dir, "source_staging.yaml")
        return false unless File.file?(staging_metadata) && File.file?(File.join(staged_benchmark, "CMakeLists.txt"))
      end
      if result.validation_build
        return false unless command_artifacts_intact?(output_dir, "cmake")
        return false unless command_artifacts_intact?(output_dir, "build")
        BuildSupport.find_executable(output_dir, info.fetch("benchmark"))
      end
      return false if result.validation_run && !command_artifacts_intact?(output_dir, "validation_out")

      true
    rescue StandardError
      false
    end

    def command_artifacts_intact?(directory, prefix)
      %w[command stdout stderr exitcode wall_time].all? do |suffix|
        File.file?(File.join(directory, "#{prefix}_#{suffix}.log"))
      end
    end

    def save_results(results)
      ordered = results.sort_by { |id, _| id }.map(&:last)
      LocalEvaluation.atomic_yaml(@all_results_path, ordered)
    end

    def validate_one(id, info, reference)
      benchmark = info.fetch("benchmark")
      model = info.fetch("model")
      par_type = info.fetch("par_type")
      run_number = info.fetch("run")
      source_root = info.fetch("source_path")
      output_dir = File.join(@validation_dir, id)
      BuildSupport.archive_existing(output_dir, File.join(@validation_dir, "attempts", id))
      FileUtils.mkdir_p(output_dir)
      result = ValidationResult.new(benchmark, model, par_type, run_number)
      result_path = File.join(output_dir, VALIDATION_RESULT_FN)
      messages = []

      if info["source_error"]
        result.err_string = "Error during source discovery: #{info['source_error']}"
        messages << result.err_string
        return finish_result(result_path, messages, result)
      end

      staged_source = BuildSupport.stage_source(source_root: source_root, benchmark: benchmark,
                                                stage_root: File.join(output_dir, "source"))
      detected = begin
        parallelization_detection(File.dirname(staged_source), benchmark)
      rescue Errno::ENOENT => e
        result.err_string = "Error during parallelization detection: #{e.message}"
        messages << result.err_string
        return finish_result(result_path, messages, result)
      end
      semantic_ok = par_type == PAR_HYBRID ? !detected.empty? : detected == [par_type]
      unless semantic_ok
        result.err_string = if detected.empty?
          "Error during parallelization detection: No parallelization approach detected in source code."
        else
          "Error during parallelization detection: Detected parallelization approaches #{detected} do not match target #{par_type}."
        end
        messages << result.err_string
        return finish_result(result_path, messages, result)
      end
      result.basic_para = true
      messages << "Parallelization detection PASSED: Detected parallelization approaches #{detected}."

      built, build_error = BuildSupport.build(source_dir: staged_source, build_dir: output_dir,
                                               runner: @runner, par_type: par_type)
      unless built
        result.err_string = "Error during validation build:\n#{build_error}. See #{output_dir}/cmake_*.log and build_*.log."
        messages << result.err_string
        return finish_result(result_path, messages, result)
      end
      result.validation_build = true
      messages << "Validation build PASSED."

      executable = BuildSupport.find_executable(output_dir, benchmark)
      args = validation_args(benchmark)
      env, command = @resources.command(par_type: par_type, executable: executable, args: args, mode: :validation)
      execution = @runner.run(argv: command, env: env, prefix: File.join(output_dir, "validation_out"),
                              timeout: VALIDATION_TIMEOUT, chdir: output_dir,
                              limits: ExecutionLimits::VALIDATION)
      output_path = File.join(output_dir, "validation_out_stdout.log")
      output = File.file?(output_path) ? File.read(output_path) : ""
      ran_with_internal_failure = internal_failure?(output)
      unless execution.success || ran_with_internal_failure
        result.err_string = "Error during validation run: exit code #{execution.exit_code}. See validation_out_*.log."
        messages << result.err_string
        return finish_result(result_path, messages, result)
      end
      result.validation_run = true
      messages << "Validation run PASSED."

      unless output.include?("Validation: PASSED") && !internal_failure?(output)
        result.err_string = "Internal validation FAILED."
        messages << result.err_string
        return finish_result(result_path, messages, result)
      end
      result.internal_validation = true
      messages << "Internal validation PASSED."

      comparison = validate(reference, output, benchmark)
      unless comparison[0]
        result.err_string = "Output comparison FAILED:\n#{comparison[1]}"
        messages << result.err_string
        return finish_result(result_path, messages, result)
      end
      result.output_comparison = true
      messages << "Output comparison PASSED:\n#{comparison[1]}"
      finish_result(result_path, messages, result)
    rescue InfrastructureError, SystemCallError, IOError => e
      # Infrastructure failures intentionally remain absent from the aggregate result list.
      LocalEvaluation.atomic_write(File.join(output_dir, "infrastructure_error.log"), "#{e.class}: #{e.message}\n") if output_dir
      raise
    rescue StandardError => e
      # Detection/build/output errors caused by generated source are reproducible program failures.
      result ||= ValidationResult.new(benchmark, model, par_type, run_number)
      result.err_string = "Validation pipeline error: #{e.class}: #{e.message}"
      messages ||= []
      messages << result.err_string
      finish_result(result_path, messages, result)
    end

    def finish_result(path, messages, result)
      LocalEvaluation.atomic_write(path, messages.join("\n") + "\n")
      LocalEvaluation.atomic_yaml(File.join(File.dirname(path), "validation_metadata.yaml"), {
        "id" => result.id_string,
        "benchmark" => result.benchmark,
        "model" => result.model,
        "par_type" => result.par_type,
        "run" => result.run,
        "manifest_sha256" => LocalEvaluation.sha256_file(@manifest.path),
        "stages" => {
          "basic_para" => !!result.basic_para,
          "validation_build" => !!result.validation_build,
          "validation_run" => !!result.validation_run,
          "internal_validation" => !!result.internal_validation,
          "output_comparison" => !!result.output_comparison
        },
        "completed_at" => Time.now.iso8601
      })
      result
    end

    def validation_args(benchmark)
      flags = benchmark == "roomsim" ? %w[-v -o] : %w[-v -r]
      flags + VALIDATION_SIZES.fetch(benchmark)
    end

    def internal_failure?(output)
      output.include?("Validation: FAILED") || output.include?("Validation fail")
    end

    def reference_output(benchmark)
      directory = File.join(@validation_dir, "reference", benchmark)
      output_path = File.join(directory, "validation_out_stdout.log")
      metadata_path = File.join(directory, "reference_metadata.yaml")
      revision_digest = Digest::SHA256.hexdigest(YAML.dump(@manifest.data.fetch("benchmark_repository")))
      if File.file?(output_path) && File.file?(metadata_path)
        metadata = LocalEvaluation.load_yaml(metadata_path)
        if metadata["validation_args"] == validation_args(benchmark) &&
           metadata["source_revision_sha256"] == revision_digest
          cached_output = File.read(output_path)
          if cached_output.include?("Validation: PASSED") &&
             cached_output.include?("=== RESULTS ===") && cached_output.include?("=== END RESULTS ===")
            return cached_output
          end
        end
      end

      BuildSupport.archive_existing(directory, File.join(@validation_dir, "reference_attempts", benchmark))
      FileUtils.mkdir_p(directory)
      LocalEvaluation.ensure_disk_space!(directory)
      source_dir = BuildSupport.stage_source(source_root: @manifest.benchmarks_root, benchmark: benchmark,
                                             stage_root: File.join(directory, "source"))
      built, error = BuildSupport.build(source_dir: source_dir, build_dir: directory, runner: @runner)
      raise InfrastructureError, "Reference build failed for #{benchmark}: #{error}" unless built
      executable = BuildSupport.find_executable(directory, benchmark)
      execution = @runner.run(argv: [executable, *validation_args(benchmark)],
                              prefix: File.join(directory, "validation_out"),
                              timeout: VALIDATION_TIMEOUT, chdir: directory,
                              limits: ExecutionLimits::VALIDATION)
      raise InfrastructureError, "Reference run failed for #{benchmark}" unless execution.success
      output = File.read(output_path)
      unless output.include?("Validation: PASSED") && output.include?("=== RESULTS ===") && output.include?("=== END RESULTS ===")
        raise InfrastructureError, "Reference output for #{benchmark} is incomplete or failed internal validation"
      end
      LocalEvaluation.atomic_yaml(metadata_path, {
        "benchmark" => benchmark,
        "source_repository" => @manifest.data.fetch("benchmark_repository"),
        "source_revision_sha256" => revision_digest,
        "validation_args" => validation_args(benchmark),
        "generated_at" => Time.now.iso8601
      })
      output
    end

    def print_summary(results)
      selected_results = @selected.keys.filter_map { |id| results[id] }
      stages = {
        "parallelization" => ->(result) { result.basic_para },
        "build" => ->(result) { result.validation_build },
        "run" => ->(result) { result.validation_run },
        "internal" => ->(result) { result.internal_validation },
        "comparison" => ->(result) { result.output_comparison }
      }
      puts "Validation results: #{selected_results.size}/#{@selected.size} completed"
      stages.each do |name, predicate|
        puts format("  %-16s %d/%d", name, selected_results.count(&predicate), selected_results.size)
      end
    end
  end
end
