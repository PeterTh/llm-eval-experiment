module LocalEvaluation
  RESOLVED_BENCHMARK_STATUSES = %w[resolved wall_limited safe_cap_limited no_valid_programs reviewed].freeze

  class CalibrationSeed
    SNAPSHOT_FILENAME = "benchmark_seed.yaml"

    attr_reader :path, :data, :digest

    def self.snapshot_path(run_dir)
      File.join(File.expand_path(run_dir), SNAPSHOT_FILENAME)
    end

    def self.materialize!(run_dir:, source_path:)
      destination = snapshot_path(run_dir)
      sidecar = "#{destination}.sha256"

      if File.file?(destination)
        # A kill can land between the two atomic renames. Preserve the already-created
        # snapshot and finish its sidecar rather than replacing it from a possibly
        # edited or moved repository seed.
        seed = new(destination, require_sidecar: File.file?(sidecar))
        unless File.file?(sidecar)
          LocalEvaluation.atomic_write(sidecar, "#{seed.digest}\n")
        end
      elsif File.file?(sidecar)
        expected = read_digest(sidecar)
        source = File.expand_path(source_path)
        raise "Calibration seed snapshot is incomplete and source is unavailable: #{source}" unless File.file?(source)
        actual = LocalEvaluation.sha256_file(source)
        unless actual == expected
          raise "Calibration seed snapshot is incomplete and the source no longer matches its digest"
        end
        validate_data!(LocalEvaluation.load_yaml(source))
        LocalEvaluation.atomic_write(destination, File.binread(source))
        seed = new(destination)
      else
        source = File.expand_path(source_path)
        raise "Calibration seed not found: #{source}" unless File.file?(source)
        validate_data!(LocalEvaluation.load_yaml(source))
        LocalEvaluation.atomic_write(destination, File.binread(source))
        seed = new(destination, require_sidecar: false)
        LocalEvaluation.atomic_write(sidecar, "#{seed.digest}\n")
      end

      seed = new(destination)
      File.chmod(0o444, destination)
      File.chmod(0o444, sidecar)
      seed
    end

    def self.read_digest(sidecar)
      digest = File.read(sidecar).strip
      raise "Invalid calibration seed digest sidecar: #{sidecar}" unless digest.match?(/\A[0-9a-f]{64}\z/)
      digest
    end

    def self.validate_data!(data)
      raise "Unsupported calibration seed schema" unless data.is_a?(Hash) && data["schema_version"] == SCHEMA_VERSION
      data
    end

    def initialize(path, require_sidecar: true)
      @path = File.expand_path(path)
      raise "Calibration seed not found: #{@path}" unless File.file?(@path)
      @digest = LocalEvaluation.sha256_file(@path)
      sidecar = "#{@path}.sha256"
      if require_sidecar
        raise "Calibration seed digest sidecar not found: #{sidecar}" unless File.file?(sidecar)
        expected = self.class.read_digest(sidecar)
        raise "Calibration seed digest mismatch: #{@path}" unless expected == @digest
      end
      @data = self.class.validate_data!(LocalEvaluation.load_yaml(@path))
    end
  end

  class BenchmarkConfig
    attr_reader :path, :data, :digest

    def initialize(path)
      @path = File.expand_path(path)
      raise "Benchmark configuration not found: #{@path}" unless File.file?(@path)
      @digest = LocalEvaluation.sha256_file(@path)
      sidecar = "#{@path}.sha256"
      raise "Benchmark configuration digest sidecar not found: #{sidecar}" unless File.file?(sidecar)
      expected = CalibrationSeed.read_digest(sidecar)
      raise "Benchmark configuration digest mismatch: #{@path}" unless expected == @digest
      @data = LocalEvaluation.load_yaml(@path)
      raise "Unsupported benchmark configuration schema" unless @data["schema_version"] == SCHEMA_VERSION
    end

    def frozen?
      @data["state"] == "frozen"
    end

    def cell(par_type, benchmark)
      @data.fetch("cells").fetch(par_type).fetch(benchmark)
    end

    def verify_unchanged!
      sidecar = "#{@path}.sha256"
      actual = File.file?(@path) && LocalEvaluation.sha256_file(@path)
      recorded = File.file?(sidecar) && CalibrationSeed.read_digest(sidecar)
      unless actual == @digest && recorded == @digest
        raise InfrastructureError, "Frozen benchmark configuration or digest changed during execution: #{@path}"
      end
      true
    rescue StandardError => e
      raise if e.is_a?(InfrastructureError)
      raise InfrastructureError, "Could not verify frozen benchmark configuration integrity: #{e.message}"
    end


    def validate_cells!
      raise "Frozen configuration is not tied to complete validation" unless @data["validation_complete"]
      seed_path = @data.fetch("seed_path")
      seed = CalibrationSeed.new(seed_path)
      raise "Calibration seed has changed" unless @data["seed_sha256"] == seed.digest
      rules = SeedRules.new(seed.data)
      PAR_TYPES.each do |par_type|
        BENCHMARKS.each do |benchmark|
          entry = cell(par_type, benchmark)
          unless entry["resolved"] && RESOLVED_BENCHMARK_STATUSES.include?(entry["status"])
            raise "Unresolved benchmark configuration cell #{benchmark}/#{par_type}"
          end
          rules.validate_args!(par_type, benchmark, entry.fetch("args").map(&:to_s))
          timeout = Integer(entry.fetch("timeout_seconds").to_s, 10)
          raise "Timeout must be between 30 and 120 seconds for #{benchmark}/#{par_type}" unless timeout.between?(30, 120)
        end
      end
      true
    end
  end

  class SeedRules
    def initialize(data)
      @data = data
    end

    def benchmark(name)
      @data.fetch("benchmarks").fetch(name)
    end

    def validate_args!(par_type, benchmark, args)
      raise "Arguments for #{benchmark}/#{par_type} must be an array of strings" unless args.is_a?(Array) && args.all? { |arg| arg.is_a?(String) }
      definition = self.benchmark(benchmark)
      validate_argument_shape!(definition, par_type, benchmark, args)
      caps = definition.fetch("input_caps").fetch(par_type)
      caps.each do |argument, maximum|
        value = integer_argument(args, argument, benchmark, par_type)
        raise "Argument #{argument}=#{value} exceeds the safe cap #{maximum} for #{benchmark}/#{par_type}" if value > maximum.to_i
        raise "Argument #{argument}=#{value} must be positive for #{benchmark}/#{par_type}" unless value.positive?
      end
      minimums = (definition["input_minimums"] || {}).fetch(par_type, {})
      minimums.each do |argument, minimum|
        value = integer_argument(args, argument, benchmark, par_type)
        if value < minimum.to_i
          raise "Argument #{argument}=#{value} is below the safe minimum #{minimum} for #{benchmark}/#{par_type}"
        end
      end

      scale = definition.fetch("scale")
      value = integer_argument(args, scale.fetch("argument"), benchmark, par_type)
      minimum = scale.fetch("minimum").to_i
      maximum = scale_maximum(scale, par_type)
      alignment = scale.fetch("alignment").to_i
      raise "Scaled argument is outside #{minimum}..#{maximum} for #{benchmark}/#{par_type}" unless value.between?(minimum, maximum)
      raise "Scaled argument #{value} is not aligned to #{alignment} for #{benchmark}/#{par_type}" unless (value % alignment).zero?
      true
    end

    def scale_maximum(scale, par_type)
      by_backend = scale["maximum_by_backend"] || {}
      (by_backend[par_type] || scale.fetch("maximum")).to_i
    end

    private

    def validate_argument_shape!(definition, par_type, benchmark, args)
      expected = definition.fetch("args").fetch(par_type).map(&:to_s)
      unless expected.length.even? && expected.each_slice(2).all? { |flag, _value| flag.start_with?("-") }
        raise "Calibration seed has a malformed argument shape for #{benchmark}/#{par_type}"
      end
      expected_flags = expected.each_slice(2).map(&:first)
      if expected_flags.uniq.length != expected_flags.length
        raise "Calibration seed has duplicate argument flags for #{benchmark}/#{par_type}"
      end

      actual_flags = args.each_slice(2).map(&:first)
      unless args.length == expected.length && actual_flags == expected_flags &&
             args.each_slice(2).all? { |flag, value| flag.start_with?("-") && value && !value.start_with?("-") }
        raise "Arguments for #{benchmark}/#{par_type} must use exactly these flags in order: #{expected_flags.join(' ')}"
      end
    end

    def integer_argument(args, argument, benchmark, par_type)
      index = args.index(argument)
      raise "Required argument #{argument} is missing for #{benchmark}/#{par_type}" unless index && args[index + 1]
      Integer(args[index + 1], 10)
    rescue ArgumentError
      raise "Argument #{argument} must have an integer value for #{benchmark}/#{par_type}"
    end
  end

  class Calibrator
    def initialize(run_dir:, seed_path:, exact_id: nil, filter: nil, dry_run: false,
                   retry_failed: false, runner: ProcessRunner.new, resources: Resources.new)
      @run_dir = File.expand_path(run_dir)
      @manifest = Manifest.new(@run_dir)
      @requested_seed_path = File.expand_path(seed_path)
      @snapshot_seed_path = CalibrationSeed.snapshot_path(@run_dir)
      @dry_run = dry_run
      initial_seed_path = File.file?(@snapshot_seed_path) ? @snapshot_seed_path : @requested_seed_path
      initial_seed = CalibrationSeed.new(initial_seed_path,
                                         require_sidecar: initial_seed_path == @snapshot_seed_path &&
                                                          File.file?("#{@snapshot_seed_path}.sha256"))
      @seed_path = initial_seed.path
      @seed = initial_seed.data
      @rules = SeedRules.new(@seed)
      @exact_id = exact_id
      @filter = filter
      @selected_runs = @manifest.filtered_runs(exact_id: exact_id, filter: filter)
      @retry_failed = retry_failed
      @runner = runner
      @resources = resources
      @validation_path = File.join(@run_dir, "validation", "all_validation_results.yaml")
      @validation_results = load_validation_results
      @validation_digest = LocalEvaluation.sha256_file(@validation_path)
      @validation_complete = @validation_results.keys.sort == @manifest.runs.keys.sort
      @calibration_dir = File.join(@run_dir, "calibration")
      @proposal_path = File.join(@run_dir, "benchmark_config.proposed.yaml")
    end

    def run
      cells = selected_cells
      if @dry_run
        output = load_or_initialize_output
        pending_cells = cells.reject do |par_type, benchmark|
          calibration_completed?(output.dig("cells", par_type, benchmark))
        end
        puts "Calibration dry run: #{pending_cells.size} pending of #{cells.size} selected benchmark/backend cells"
        pending_cells.each do |par_type, benchmark|
          args = output.dig("cells", par_type, benchmark).fetch("args").map(&:to_s)
          pilots = pilot_ids(par_type, benchmark)
          executable = pilots.empty? ? "/validation/#{benchmark}_PROGRAM" : BuildSupport.find_executable(File.join(@run_dir, "validation", pilots.first), benchmark)
          env, command = @resources.command(par_type: par_type, executable: executable, args: args, mode: :benchmark)
          puts "#{benchmark}/#{par_type}: pilots=#{pilots.join(',')} timeout=#{probe_timeout}s env=#{env.inspect} command=#{Shellwords.join(command)}"
        end
        return
      end

      puts "Calibrating #{cells.size} benchmark/backend cells"
      activate_seed_snapshot!
      LocalEvaluation.ensure_disk_space!(@run_dir)
      output = load_or_initialize_output
      checkpoint(output)
      pending_cells = cells.reject do |par_type, benchmark|
        calibration_completed?(output.dig("cells", par_type, benchmark))
      end
      if pending_cells.empty?
        puts "All selected calibration cells are already completed"
        puts "Wrote resumable proposed benchmark configuration to #{@proposal_path}"
        return
      end
      @resources.verify_topology!
      phase_deadline = monotonic_now + target.fetch("phase_wall_budget_seconds")
      cells.each do |par_type, benchmark|
        cell = output.dig("cells", par_type, benchmark)
        if calibration_completed?(cell)
          puts "Skipping completed calibration #{benchmark}/#{par_type} (#{cell['status']})"
          next
        end
        if monotonic_now >= phase_deadline
          puts "Calibration phase wall budget reached; remaining cells stay pending"
          break
        end

        LocalEvaluation.ensure_disk_space!(@calibration_dir)
        cell_dir = File.join(@calibration_dir, "#{benchmark}_#{par_type}")
        BuildSupport.archive_existing(cell_dir, File.join(@calibration_dir, "attempts", "#{benchmark}_#{par_type}"))
        output["cells"][par_type][benchmark] = calibrate_cell(
          par_type, benchmark, phase_deadline, starting_args: cell["args"]
        )
        checkpoint(output)
      end
      puts "Wrote resumable proposed benchmark configuration to #{@proposal_path}"
    end

    private

    def target
      @seed.fetch("target_seconds")
    end

    def activate_seed_snapshot!
      snapshot = CalibrationSeed.materialize!(run_dir: @run_dir, source_path: @requested_seed_path)
      @seed_path = snapshot.path
      @seed = snapshot.data
      @rules = SeedRules.new(@seed)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def load_validation_results
      raise "Validation results not found: #{@validation_path}" unless File.file?(@validation_path)
      results = LocalEvaluation.load_yaml(@validation_path, permitted_classes: [ValidationResult]) || []
      results.to_h { |result| [result.id_string, result] }
    end

    def selected_cells
      @selected_runs.values.map { |info| [info["par_type"], info["benchmark"]] }.uniq.sort
    end

    def pilot_ids(par_type, benchmark)
      valid = @selected_runs.select do |id, info|
        info["par_type"] == par_type && info["benchmark"] == benchmark && @validation_results[id]&.output_comparison
      end
      priorities = @seed.fetch("pilot_model_priority")
      selected = priorities.filter_map do |model|
        valid.keys.sort.find { |id| @manifest.runs[id]["model"] == model }
      end
      (selected + valid.keys.sort).uniq.first(4)
    end

    def new_output
      cells = PAR_TYPES.to_h do |par_type|
        [par_type, BENCHMARKS.to_h do |benchmark|
          args = @rules.benchmark(benchmark).fetch("args").fetch(par_type).map(&:to_s)
          [benchmark, { "status" => "pending", "resolved" => false, "args" => args,
                        "timeout_seconds" => 30, "pilots" => [], "probes" => [] }]
        end]
      end
      {
        "schema_version" => SCHEMA_VERSION,
        "state" => "proposed",
        "generated_at" => Time.now.iso8601,
        "seed_path" => @seed_path,
        "seed_source_path" => @requested_seed_path,
        "seed_sha256" => LocalEvaluation.sha256_file(@seed_path),
        "manifest_sha256" => LocalEvaluation.sha256_file(@manifest.path),
        "validation_result_count" => @validation_results.size,
        "manifest_run_count" => @manifest.runs.size,
        "validation_complete" => @validation_complete,
        "validation_results_sha256" => @validation_digest,
        "target_seconds" => target,
        "cells" => cells
      }
    end

    def load_or_initialize_output
      return new_output unless File.file?(@proposal_path)
      output = LocalEvaluation.load_yaml(@proposal_path)
      raise "Existing proposal has an unsupported schema" unless output["schema_version"] == SCHEMA_VERSION
      raise "Existing proposal was produced from another seed" unless output["seed_sha256"] == LocalEvaluation.sha256_file(@seed_path)
      raise "Existing proposal was produced from another manifest" unless output["manifest_sha256"] == LocalEvaluation.sha256_file(@manifest.path)
      unless output["validation_results_sha256"] == @validation_digest
        raise "Validation results changed after calibration began; archive the proposal and recalibrate so workloads cannot mix validation revisions"
      end
      output["validation_result_count"] = @validation_results.size
      output["validation_complete"] = @validation_complete
      output["validation_results_sha256"] = @validation_digest
      # Seamlessly bind proposals written by an earlier local-pipeline revision to
      # the run-owned seed, provided the content digest is identical.
      output["seed_path"] = @seed_path
      output["seed_source_path"] ||= @requested_seed_path
      output
    end

    def checkpoint(output)
      output["updated_at"] = Time.now.iso8601
      LocalEvaluation.atomic_yaml(@proposal_path, output)
    end

    def calibration_completed?(cell)
      return false if cell.nil? || %w[pending validation_incomplete].include?(cell["status"])
      return false if @retry_failed && !cell["resolved"]
      true
    end

    def calibrate_cell(par_type, benchmark, phase_deadline, starting_args: nil)
      definition = @rules.benchmark(benchmark)
      args = (starting_args || definition.fetch("args").fetch(par_type)).map(&:to_s)
      @rules.validate_args!(par_type, benchmark, args)
      pilots = pilot_ids(par_type, benchmark)
      puts "  #{benchmark}/#{par_type}: #{pilots.size} pilots, seed #{args.join(' ')}"
      if pilots.empty?
        complete = @validation_complete
        return { "status" => complete ? "no_valid_programs" : "validation_incomplete",
                 "resolved" => complete, "args" => args, "timeout_seconds" => 30,
                 "pilots" => [], "probes" => [] }
      end

      probes = []
      status = "review_required"
      resolved = false
      quarantined = {}
      cell_deadline = [monotonic_now + target.fetch("cell_wall_budget_seconds"), phase_deadline].min
      target.fetch("max_probes").times do |probe_index|
        break if monotonic_now >= cell_deadline
        active_pilots = pilots.reject { |id| quarantined[id] }
        break if active_pilots.empty?
        probe = run_probe(par_type, benchmark, active_pilots, args, probe_index,
                          target.fetch("measurements"), cell_deadline)
        probes << probe
        probe.fetch("failed_pilots", {}).each { |id, reason| quarantined[id] = reason }

        measured = probe["fastest_median_seconds"]
        wall = probe["fastest_pilot_wall_median_seconds"]
        decision = calibration_decision(measured, wall)
        if decision
          status = decision
          resolved = true
          break
        end
        break unless measured && wall

        ratio = scaling_ratio(measured, wall)
        next_args = scaled_args(args, definition.fetch("scale"), ratio, par_type)
        @rules.validate_args!(par_type, benchmark, next_args)
        if next_args == args
          if ratio > 1.0 && measured < target.fetch("minimum") && at_upper_cap?(args, definition.fetch("scale"), par_type)
            status = "safe_cap_limited"
            resolved = true
          end
          break
        end
        break if probe_index + 1 >= target.fetch("max_probes")
        args = next_args
      end

      chosen_probe = probes.last || {}
      chosen_args = chosen_probe["args"] || args
      chosen_walls = chosen_probe.fetch("pilot_wall_median_seconds", {}).values
      representative_wall = chosen_walls.max
      timeout_seconds = representative_wall ? [[(representative_wall * 4).ceil, 30].max, 120].min : 30
      {
        "status" => status,
        "resolved" => resolved,
        # Always publish the last workload that actually ran, never a merely computed next scale.
        "args" => chosen_args,
        "timeout_seconds" => timeout_seconds,
        "pilots" => pilots,
        "quarantined_pilots" => quarantined,
        "cell_budget_exhausted" => monotonic_now >= cell_deadline,
        "probes" => probes
      }
    end

    def calibration_decision(measured, wall)
      return nil unless measured && wall
      return "resolved" if measured.between?(target.fetch("minimum"), target.fetch("maximum")) && wall <= target.fetch("wall_maximum")
      if measured < target.fetch("minimum") &&
         wall.between?(target.fetch("wall_minimum"), target.fetch("wall_maximum")) &&
         measured <= wall * target.fetch("short_compute_ratio")
        return "wall_limited"
      end
      nil
    end

    def scaling_ratio(measured, wall)
      ratios = []
      if measured > target.fetch("maximum")
        ratios << target.fetch("target") / measured
      elsif measured.positive? && measured < target.fetch("minimum")
        ratios << target.fetch("target") / measured
      end
      if wall > target.fetch("wall_maximum") || wall < target.fetch("wall_minimum")
        ratios << target.fetch("wall_target") / wall if wall.positive?
      end
      ratios.empty? ? 1.0 : ratios.min
    end

    def probe_timeout
      target.fetch("probe_timeout_seconds")
    end

    def run_probe(par_type, benchmark, pilots, args, probe_index, measurement_count, deadline)
      medians = {}
      wall_medians = {}
      walls = []
      failures = {}
      pilots.each do |id|
        break if monotonic_now >= deadline
        executable = BuildSupport.find_executable(File.join(@run_dir, "validation", id), benchmark)
        env, command = @resources.command(par_type: par_type, executable: executable, args: args, mode: :benchmark)
        directory = File.join(@calibration_dir, "#{benchmark}_#{par_type}", id)
        warm_prefix = File.join(directory, "probe_#{probe_index}_warmup")
        warmup = run_with_budget(command, env, warm_prefix, executable, deadline)
        unless warmup
          failures[id] = "cell_budget_exhausted"
          break
        end
        walls << warmup.wall_seconds
        unless warmup.success
          failures[id] = execution_failure(warmup)
          next
        end

        times = []
        pilot_walls = []
        measurement_count.times do |index|
          prefix = File.join(directory, "probe_#{probe_index}_#{index}")
          result = run_with_budget(command, env, prefix, executable, deadline)
          unless result
            failures[id] = "cell_budget_exhausted"
            break
          end
          walls << result.wall_seconds
          pilot_walls << result.wall_seconds
          unless result.success
            failures[id] = execution_failure(result)
            break
          end
          begin
            metrics = BenchmarkMetrics.parse(benchmark, File.read("#{prefix}_stdout.log"))
            times << metrics.fetch("time") / 1000.0
          rescue StandardError => e
            LocalEvaluation.atomic_write("#{prefix}_parse_error.log", "#{e.class}: #{e.message}\n")
            failures[id] = "parse_error"
            break
          end
        end
        if times.size == measurement_count
          medians[id] = BenchmarkMetrics.median(times)
          wall_medians[id] = BenchmarkMetrics.median(pilot_walls)
        end
      end
      fastest_id = medians.min_by { |_id, seconds| seconds }&.first
      {
        "probe" => probe_index,
        "args" => args,
        "pilot_median_seconds" => medians,
        "pilot_wall_median_seconds" => wall_medians,
        "fastest_pilot_id" => fastest_id,
        "fastest_median_seconds" => fastest_id && medians[fastest_id],
        "fastest_pilot_wall_median_seconds" => fastest_id && wall_medians[fastest_id],
        "wall_seconds" => walls,
        "failed_pilots" => failures,
        "budget_exhausted" => monotonic_now >= deadline
      }
    end

    def run_with_budget(command, env, prefix, executable, deadline)
      remaining = deadline - monotonic_now
      return nil unless remaining.positive?
      @runner.run(argv: command, env: env, prefix: prefix, timeout: [probe_timeout, remaining].min,
                  chdir: File.dirname(executable), limits: ExecutionLimits::PERFORMANCE)
    end

    def execution_failure(result)
      return "timeout" if result.timed_out
      return "signal_#{result.term_signal}" if result.term_signal
      "exit_#{result.exit_code}"
    end

    def at_upper_cap?(args, scale, par_type)
      index = args.index(scale.fetch("argument"))
      Integer(args.fetch(index + 1), 10) >= @rules.scale_maximum(scale, par_type)
    end

    def scaled_args(args, scale, workload_ratio, par_type = nil)
      argument = scale.fetch("argument")
      index = args.index(argument)
      raise "Scaling argument #{argument} not found in #{args.inspect}" unless index && args[index + 1]
      current = Integer(args[index + 1], 10)
      exponent = scale.fetch("exponent").to_f
      proposed = if workload_ratio.finite? && workload_ratio.positive?
        current * (workload_ratio**(1.0 / exponent))
      else
        current
      end
      alignment = scale.fetch("alignment").to_i
      proposed = (proposed / alignment).round * alignment
      maximum = par_type ? @rules.scale_maximum(scale, par_type) : scale.fetch("maximum").to_i
      proposed = [[proposed, scale.fetch("minimum").to_i].max, maximum].min
      updated = args.dup
      updated[index + 1] = proposed.to_i.to_s
      updated
    end
  end

  class BenchmarkPipeline
    def self.freeze_config(run_dir:, proposed_path: nil, dry_run: false)
      run_dir = File.expand_path(run_dir)
      proposed_path ||= File.join(run_dir, "benchmark_config.proposed.yaml")
      raise "Proposed configuration not found: #{proposed_path}" unless File.file?(proposed_path)
      config = LocalEvaluation.load_yaml(proposed_path)
      raise "Unsupported proposed configuration schema" unless config["schema_version"] == SCHEMA_VERSION
      raise "Expected a proposed configuration" unless config["state"] == "proposed"
      manifest = Manifest.new(run_dir)
      raise "Proposed configuration belongs to another manifest" unless config["manifest_sha256"] == LocalEvaluation.sha256_file(manifest.path)
      validation_path = File.join(run_dir, "validation", "all_validation_results.yaml")
      raise "Validation results not found: #{validation_path}" unless File.file?(validation_path)
      validation = LocalEvaluation.load_yaml(validation_path, permitted_classes: [ValidationResult]) || []
      validation_ids = validation.map(&:id_string).sort
      raise "Validation is incomplete; configuration cannot be frozen" unless config["validation_complete"] && validation_ids == manifest.runs.keys.sort
      unless config["validation_results_sha256"] == LocalEvaluation.sha256_file(validation_path)
        raise "Validation results changed after calibration; recalibrate before freezing"
      end
      seed_path = config.fetch("seed_path")
      expected_seed_path = CalibrationSeed.snapshot_path(run_dir)
      unless File.expand_path(seed_path) == expected_seed_path
        raise "Proposed configuration is not bound to the run-owned calibration seed snapshot"
      end
      seed = CalibrationSeed.new(seed_path)
      raise "Calibration seed has changed since calibration" unless config["seed_sha256"] == seed.digest
      rules = SeedRules.new(seed.data)

      missing = []
      unresolved = []
      expected_types = PAR_TYPES.sort
      actual_types = config.fetch("cells").keys.sort
      raise "Proposed configuration has unexpected backend keys: #{actual_types.inspect}" unless actual_types == expected_types
      PAR_TYPES.each do |par_type|
        actual_benchmarks = config.fetch("cells").fetch(par_type).keys.sort
        unless actual_benchmarks == BENCHMARKS.sort
          raise "Proposed configuration has unexpected benchmark keys for #{par_type}: #{actual_benchmarks.inspect}"
        end
        BENCHMARKS.each do |benchmark|
          cell = config.dig("cells", par_type, benchmark)
          missing << "#{benchmark}/#{par_type}" unless cell
          next unless cell
          unresolved << "#{benchmark}/#{par_type}" unless cell["resolved"] && RESOLVED_BENCHMARK_STATUSES.include?(cell["status"])
          rules.validate_args!(par_type, benchmark, cell.fetch("args").map(&:to_s))
          timeout = Integer(cell.fetch("timeout_seconds").to_s, 10)
          raise "Timeout must be between 30 and 120 seconds for #{benchmark}/#{par_type}" unless timeout.between?(30, 120)
        end
      end
      raise "Proposed configuration is incomplete: #{missing.join(', ')}" unless missing.empty?
      raise "Review-required calibration cells remain: #{unresolved.join(', ')}" unless unresolved.empty?

      output = File.join(run_dir, "benchmark_config.yaml")
      digest_path = "#{output}.sha256"
      if File.exist?(output)
        if File.file?(output) && !File.exist?(digest_path)
          existing = LocalEvaluation.load_yaml(output)
          proposed_digest = LocalEvaluation.sha256_file(proposed_path)
          expected = config.merge("state" => "frozen", "frozen_at" => existing["frozen_at"],
                                  "proposed_sha256" => proposed_digest)
          unless existing == expected && existing["frozen_at"].is_a?(String)
            raise "Frozen benchmark configuration is missing its digest and cannot be safely recovered: #{output}"
          end
          if dry_run
            puts "Freeze dry run: frozen configuration has a safely recoverable missing digest sidecar"
            return
          end
          digest = LocalEvaluation.sha256_file(output)
          LocalEvaluation.atomic_write(digest_path, "#{digest}\n")
          File.chmod(0o444, output)
          File.chmod(0o444, digest_path)
          puts "Recovered frozen benchmark configuration digest at #{digest_path}"
          return
        end
        # Require the existing pair to be internally consistent before reporting
        # immutability; a corrupt sidecar must not look like a benign re-freeze.
        BenchmarkConfig.new(output)
        raise "Frozen benchmark configuration already exists and is immutable: #{output}"
      end
      if File.file?(File.join(run_dir, "benchmark", BENCHMARK_FULL_RESULTS_FN))
        raise "Benchmark results already exist; refusing to replace their configuration"
      end
      if dry_run
        puts "Freeze dry run: configuration is complete, reviewed, bounded, and tied to this manifest"
        return
      end

      config["state"] = "frozen"
      config["frozen_at"] = Time.now.iso8601
      config["proposed_sha256"] = LocalEvaluation.sha256_file(proposed_path)
      serialized = YAML.dump(config)
      digest = Digest::SHA256.hexdigest(serialized)
      # The primary file is the commit record. If interrupted after the sidecar,
      # a retry can safely replace the orphan sidecar and commit the same proposal.
      LocalEvaluation.atomic_write(digest_path, "#{digest}\n")
      LocalEvaluation.atomic_write(output, serialized)
      File.chmod(0o444, output)
      File.chmod(0o444, digest_path)
      puts "Wrote frozen benchmark configuration to #{output} (SHA-256 #{digest})"
    end

    def initialize(run_dir:, config_path: nil, exact_id: nil, filter: nil, ids: nil, dry_run: false,
                   retry_failed: false, runner: ProcessRunner.new, resources: Resources.new)
      @run_dir = File.expand_path(run_dir)
      @manifest = Manifest.new(@run_dir)
      @config = BenchmarkConfig.new(config_path || File.join(@run_dir, "benchmark_config.yaml"))
      raise "Benchmark configuration must be reviewed and frozen" unless @config.frozen?
      @config.validate_cells!
      unless @config.data["manifest_sha256"] == LocalEvaluation.sha256_file(@manifest.path)
        raise "Benchmark configuration belongs to another manifest"
      end
      @selected = @manifest.filtered_runs(exact_id: exact_id, filter: filter, ids: ids)
      @dry_run = dry_run
      @retry_failed = retry_failed
      @runner = runner
      @resources = resources
      @benchmark_dir = File.join(@run_dir, "benchmark")
      @results_path = File.join(@benchmark_dir, BENCHMARK_RESULTS_FN)
      @full_results_path = File.join(@benchmark_dir, BENCHMARK_FULL_RESULTS_FN)
      @pipeline_amendment = PipelineAmendment.load_chain(@run_dir, manifest: @manifest).last
      @source_correction = SourceCorrectionAmendment.load(@run_dir, manifest: @manifest)
      @validation_results = load_validation_results
      validation_path = File.join(@run_dir, "validation", "all_validation_results.yaml")
      unless @config.data["validation_results_sha256"] == LocalEvaluation.sha256_file(validation_path)
        raise "Validation results differ from the revision used by the frozen benchmark configuration"
      end
    end

    def run
      full_results = load_full_results
      assert_config_consistency!(full_results)
      candidates = @selected.select { |id, _| @validation_results[id]&.output_comparison }
      pending = candidates.reject do |id, _|
        full_results.key?(id) && !(@retry_failed && full_results[id][0] == false)
      end
      if @dry_run
        puts "Benchmark dry run: #{pending.size} pending fully-valid programs"
        pending.each do |id, info|
          cell = @config.cell(info["par_type"], info["benchmark"])
          correction = @source_correction&.record_for(id)
          executable = if correction
            File.join("/tmp", "local-evaluation-timing-correction", id, LocalEvaluation.executable_name(info["benchmark"]))
          else
            BuildSupport.find_executable(File.join(@run_dir, "validation", id), info["benchmark"])
          end
          env, command = @resources.command(par_type: info["par_type"], executable: executable,
                                            args: cell.fetch("args").map(&:to_s), mode: :benchmark)
          source = correction ? "corrected-source local-/tmp-build" : "frozen-validation-build"
          puts "#{id}: source=#{source} timeout=#{cell['timeout_seconds']}s env=#{env.inspect} command=#{Shellwords.join(command)}"
        end
        return
      end

      FileUtils.mkdir_p(@benchmark_dir)
      LocalEvaluation.ensure_disk_space!(@benchmark_dir)
      @config.verify_unchanged!
      record_invocation(pending.size)
      write_compatibility_results(full_results)
      if pending.empty?
        puts "All selected fully-valid programs already have benchmark results"
        return
      end
      preflight = @resources.verify_topology!
      LocalEvaluation.atomic_yaml(File.join(@benchmark_dir, "preflight.yaml"),
                                  preflight.merge("checked_at" => Time.now.iso8601))
      pending.each do |id, info|
        @config.verify_unchanged!
        LocalEvaluation.ensure_disk_space!(@benchmark_dir)
        puts "Benchmarking #{id}"
        success, metrics = benchmark_one(id, info)
        full_results[id] = [success, metrics]
        # Full metrics are the commit record. The boolean compatibility map is derived from it.
        write_compatibility_results(full_results)
        puts "  #{success ? 'passed' : 'failed'}"
      end
    end

    private

    def load_validation_results
      path = File.join(@run_dir, "validation", "all_validation_results.yaml")
      raise "Validation results not found: #{path}" unless File.file?(path)
      array = LocalEvaluation.load_yaml(path, permitted_classes: [ValidationResult]) || []
      array.to_h { |result| [result.id_string, result] }
    end

    def load_full_results
      return {} unless File.file?(@full_results_path)
      results = LocalEvaluation.load_yaml(@full_results_path) || {}
      unless results.is_a?(Hash) && results.keys.all? { |id| id.is_a?(String) }
        raise "Benchmark full results must be a mapping from string run IDs to result records"
      end
      unknown_ids = results.keys - @manifest.runs.keys
      unless unknown_ids.empty?
        raise "Benchmark results contain IDs absent from the evaluation manifest: #{unknown_ids.sort.join(', ')}"
      end
      results.each_value do |record|
        # Early local-pipeline runs used an empty array for failures. Normalize
        # those records to gather_bench_results.rb's historical [false, {}].
        record[1] = {} if record.is_a?(Array) && record == [false, []]
      end
      results.delete_if do |id, record|
        next false unless @selected.key?(id)

        problem = benchmark_record_problem(id, record)
        warn "Requeueing inconsistent benchmark record #{id}: #{problem}" if problem
        !problem.nil?
      end
      results
    end

    def benchmark_record_problem(id, record)
      return "the frozen validation result is not fully valid" unless @validation_results[id]&.output_comparison

      valid_success = record.is_a?(Array) && record.size == 2 && record[0] == true &&
                      record[1].is_a?(Array) && record[1].size == BENCHMARK_COUNT &&
                      record[1].all? { |metrics| valid_metric_hash?(metrics) }
      valid_failure = record.is_a?(Array) && record == [false, {}]
      return "the canonical result has an invalid shape" unless valid_success || valid_failure

      metadata_path = File.join(@benchmark_dir, id, "benchmark_metadata.yaml")
      return "benchmark_metadata.yaml is missing" unless File.file?(metadata_path)
      metadata = LocalEvaluation.load_yaml(metadata_path)
      return "benchmark_metadata.yaml is not a mapping" unless metadata.is_a?(Hash)

      info = @manifest.runs.fetch(id)
      cell = @config.cell(info.fetch("par_type"), info.fetch("benchmark"))
      expected_args = cell.fetch("args").map(&:to_s)
      expected_timeout = Integer(cell.fetch("timeout_seconds").to_s, 10)
      return "metadata references another run" unless metadata["run"] == info
      return "metadata arguments differ from the frozen configuration" unless metadata["args"] == expected_args
      begin
        actual_timeout = Integer(metadata.fetch("timeout_seconds").to_s, 10)
      rescue KeyError, ArgumentError
        return "metadata timeout is missing or invalid"
      end
      return "metadata timeout differs from the frozen configuration" unless actual_timeout == expected_timeout
      return "metadata configuration digest differs from the frozen configuration" unless metadata["configuration_sha256"] == @config.digest
      if @pipeline_amendment&.data&.fetch("affected_run_ids")&.include?(id) &&
         metadata["pipeline_amendment_sha256"] != @pipeline_amendment.digest
        return "metadata does not bind the scoped pipeline amendment"
      end
      if (correction = @source_correction&.record_for(id))
        expected = {
          "timing_fixed" => true,
          "source_correction_amendment_sha256" => @source_correction.digest,
          "original_source_commit" => correction.dig("original_source", "commit"),
          "corrected_source_commit" => correction.dig("corrected_source", "commit"),
          "original_source_digest" => correction.dig("original_source", "digest"),
          "corrected_source_digest" => correction.dig("corrected_source", "digest"),
          "timing_fix_issue_categories" => correction.fetch("original_issue_categories"),
          "timing_fix_changed_paths" => correction.fetch("changed_paths")
        }
        mismatch = expected.find { |key, value| metadata[key] != value }
        return "metadata does not bind corrected timing source field #{mismatch[0]}" if mismatch
      end
      return "metadata success disagrees with the canonical result" unless metadata["success"] == record[0]
      if valid_success && metadata["metrics"] != record[1]
        return "metadata metrics differ from the canonical result"
      end

      execution_metadata_problem(id, metadata, success: valid_success)
    rescue StandardError => e
      "metadata reconciliation failed (#{e.class}: #{e.message})"
    end

    def execution_metadata_problem(id, metadata, success:)
      executions = metadata["executions"]
      if metadata["timing_fixed"] && metadata["build_success"] == false
        return "a failed corrected-source build is marked successful" if success
        return "a failed corrected-source build has executions" unless executions == []
        return nil
      end
      unless executions.is_a?(Array) && !executions.empty? && executions.all? { |entry| entry.is_a?(Hash) }
        return "execution metadata is missing or malformed"
      end
      if metadata["timing_fixed"] && metadata["build_success"] != true
        return "corrected-source execution lacks a successful local build"
      end
      executions.each do |entry|
        return "execution success is not boolean" unless [true, false].include?(entry["success"])
        wall = entry["wall_seconds"]
        return "execution wall time is invalid" unless wall.is_a?(Numeric) && wall.to_f.finite? && !wall.negative?
      end

      labels = executions.map { |entry| entry["repetition"] }
      expected_walls = executions.drop(1).map { |entry| entry["wall_seconds"] }
      return "measured wall times disagree with execution metadata" unless metadata["wall_seconds"] == expected_walls
      return "warmup wall time disagrees with execution metadata" unless metadata["warmup_wall_seconds"] == executions.first["wall_seconds"]
      unless metadata["all_execution_wall_seconds"] == executions.map { |entry| entry["wall_seconds"] }
        return "all-execution wall times disagree with execution metadata"
      end

      if success
        expected_labels = ["warmup", *(0...BENCHMARK_COUNT)]
        return "successful execution labels are not warmup followed by repetitions 0..4" unless labels == expected_labels
        return "a successful canonical result contains a failed execution" unless executions.all? { |entry| entry["success"] }
        return nil
      end

      partial_metrics = metadata["metrics"]
      unless partial_metrics.is_a?(Array) && partial_metrics.size < BENCHMARK_COUNT &&
             partial_metrics.all? { |metrics| valid_metric_hash?(metrics) }
        return "failed-attempt partial metrics are malformed"
      end
      warmup = executions.first
      return "failed execution metadata does not start with warmup" unless labels.first == "warmup"
      unless warmup["success"]
        return "a failed warmup has unexpected measured repetitions" unless executions.size == 1 && partial_metrics.empty?
        return nil
      end

      measured = executions.drop(1)
      return "a successful warmup failure has no measured repetition" if measured.empty?
      return "failed execution has too many repetitions" if measured.size > BENCHMARK_COUNT
      expected_labels = ["warmup", *(0...measured.size)]
      return "failed execution repetitions are not a contiguous prefix" unless labels == expected_labels
      return "a non-final measured repetition failed" unless measured[0...-1].all? { |entry| entry["success"] }
      unless partial_metrics.size == measured.size - 1
        return "partial metric count does not match completed repetitions"
      end
      if measured.last["success"]
        parse_error = File.join(@benchmark_dir, id, "#{BENCHMARK_OUT_PREFIX}#{measured.size - 1}_parse_error.log")
        return "failed attempt has no failed execution or parse-error artifact" unless File.file?(parse_error)
      end
      nil
    end

    def valid_metric_hash?(metrics)
      return false unless metrics.is_a?(Hash) && metrics.key?("time")
      value = metrics["time"]
      BenchmarkMetrics.valid_time?(value)
    end

    def assert_config_consistency!(full_results)
      metadata_path = File.join(@benchmark_dir, "benchmark_run_metadata.yaml")
      if File.file?(metadata_path)
        metadata = LocalEvaluation.load_yaml(metadata_path)
        if metadata["configuration_sha256"] != @config.digest
          raise "Existing benchmark results use configuration #{metadata['configuration_sha256']}, not #{@config.digest}"
        end
      elsif !full_results.empty?
        raise "Benchmark metrics exist without configuration metadata; refusing to mix results"
      end
      full_results.each_key do |id|
        per_id = File.join(@benchmark_dir, id, "benchmark_metadata.yaml")
        digest = LocalEvaluation.load_yaml(per_id)["configuration_sha256"]
        raise "Benchmark #{id} uses a different configuration digest" unless digest == @config.digest
      end
    end

    def record_invocation(pending_count)
      metadata_path = File.join(@benchmark_dir, "benchmark_run_metadata.yaml")
      metadata = File.file?(metadata_path) ? LocalEvaluation.load_yaml(metadata_path) : {
        "created_at" => Time.now.iso8601,
        "configuration" => @config.path,
        "configuration_sha256" => @config.digest,
        "manifest_sha256" => LocalEvaluation.sha256_file(@manifest.path),
        "warmups" => 1,
        "measurements" => BENCHMARK_COUNT,
        "invocations" => []
      }
      metadata["invocations"] ||= []
      metadata["invocations"] << { "started_at" => Time.now.iso8601, "selected" => @selected.size,
                                    "pending" => pending_count, "retry_failed" => @retry_failed,
                                    "pipeline_amendment_sha256" => @pipeline_amendment&.digest,
                                    "source_correction_amendment_sha256" => @source_correction&.digest }
      metadata["pipeline_amendment_sha256"] = @pipeline_amendment&.digest
      metadata["source_correction_amendment_sha256"] = @source_correction&.digest
      LocalEvaluation.atomic_yaml(metadata_path, metadata)
    end

    def write_compatibility_results(full_results)
      ordered = full_results.sort.to_h
      LocalEvaluation.atomic_yaml(@full_results_path, ordered)
      simple = ordered.to_h { |id, record| [id, record[0]] }
      LocalEvaluation.atomic_yaml(@results_path, simple)
    end

    def benchmark_one(id, info)
      benchmark = info.fetch("benchmark")
      par_type = info.fetch("par_type")
      cell = @config.cell(par_type, benchmark)
      args = cell.fetch("args").map(&:to_s)
      timeout = cell.fetch("timeout_seconds").to_i
      output_dir = File.join(@benchmark_dir, id)
      BuildSupport.archive_existing(output_dir, File.join(@benchmark_dir, "attempts", id))
      FileUtils.mkdir_p(output_dir)
      correction = @source_correction&.record_for(id)
      return benchmark_corrected(id, info, args, timeout, output_dir, correction) if correction

      executable = BuildSupport.find_executable(File.join(@run_dir, "validation", id), benchmark)
      execute_benchmark(info, args, timeout, output_dir, executable)
    end

    def benchmark_corrected(id, info, args, timeout, output_dir, correction)
      @source_correction.verify_record_source!(id)
      workspace = Dir.mktmpdir("local-evaluation-timing-correction-", "/tmp")
      begin
        unless File.realpath(workspace).start_with?("/tmp/")
          raise InfrastructureError, "Corrected-source build workspace is not on local /tmp"
        end
        stage_root = File.join(workspace, "source")
        source_dir = BuildSupport.stage_source(
          source_root: info.fetch("source_path"), benchmark: info.fetch("benchmark"), stage_root: stage_root
        )
        staging_metadata_path = File.join(workspace, "source_staging.yaml")
        staging_metadata = LocalEvaluation.load_yaml(staging_metadata_path)
        LocalEvaluation.atomic_yaml(File.join(output_dir, "source_staging.yaml"), staging_metadata)
        build_dir = File.join(workspace, "build")
        build_ok, build_error = BuildSupport.build(
          source_dir: source_dir, build_dir: build_dir, runner: @runner,
          par_type: info.fetch("par_type"), log_dir: File.join(output_dir, "build")
        )
        build_metadata = {
          "build_success" => build_ok,
          "build_error" => build_error,
          "temporary_workspace" => "local /tmp; removed after attempt",
          "staged_source_content_sha256" => staging_metadata.fetch("content_sha256")
        }
        unless build_ok
          return finish_metadata(output_dir, info, args, timeout, [], false, [],
                                 correction: correction, build_metadata: build_metadata)
        end
        executable = BuildSupport.find_executable(build_dir, info.fetch("benchmark"))
        return execute_benchmark(info, args, timeout, output_dir, executable,
                                 correction: correction, build_metadata: build_metadata)
      ensure
        if workspace && File.exist?(workspace)
          BuildSupport.remove_local_temporary_workspace!(
            workspace, required_prefix: "local-evaluation-timing-correction-"
          )
        end
      end
    end

    def execute_benchmark(info, args, timeout, output_dir, executable, correction: nil, build_metadata: nil)
      benchmark = info.fetch("benchmark")
      env, command = @resources.command(par_type: info.fetch("par_type"), executable: executable,
                                        args: args, mode: :benchmark)
      executions = []

      warmup = @runner.run(argv: command, env: env, prefix: File.join(output_dir, "benchmark_warmup"),
                           timeout: timeout, chdir: File.dirname(executable),
                           limits: ExecutionLimits::PERFORMANCE)
      executions << execution_metadata("warmup", warmup)
      unless warmup.success
        return finish_metadata(output_dir, info, args, timeout, executions, false, [],
                               correction: correction, build_metadata: build_metadata)
      end

      metrics = []
      BENCHMARK_COUNT.times do |index|
        prefix = File.join(output_dir, "#{BENCHMARK_OUT_PREFIX}#{index}")
        result = @runner.run(argv: command, env: env, prefix: prefix, timeout: timeout,
                             chdir: File.dirname(executable), limits: ExecutionLimits::PERFORMANCE)
        executions << execution_metadata(index, result)
        unless result.success
          return finish_metadata(output_dir, info, args, timeout, executions, false, metrics,
                                 correction: correction, build_metadata: build_metadata)
        end
        begin
          metrics << BenchmarkMetrics.parse(benchmark, File.read("#{prefix}_stdout.log"))
        rescue StandardError => e
          LocalEvaluation.atomic_write("#{prefix}_parse_error.log", "#{e.class}: #{e.message}\n")
          return finish_metadata(output_dir, info, args, timeout, executions, false, metrics,
                                 correction: correction, build_metadata: build_metadata)
        end
      end
      finish_metadata(output_dir, info, args, timeout, executions, true, metrics,
                      correction: correction, build_metadata: build_metadata)
    end

    def execution_metadata(label, result)
      { "repetition" => label, "success" => result.success, "exit_code" => result.exit_code,
        "term_signal" => result.term_signal, "timed_out" => result.timed_out,
        "wall_seconds" => result.wall_seconds, "output_truncated" => result.output_truncated }
    end

    def finish_metadata(output_dir, info, args, timeout, executions, success, metrics,
                        correction: nil, build_metadata: nil)
      warmup = executions.find { |entry| entry["repetition"] == "warmup" }
      measured_walls = executions.reject { |entry| entry["repetition"] == "warmup" }
                                 .map { |entry| entry["wall_seconds"] }
      all_walls = executions.map { |entry| entry["wall_seconds"] }
      metadata = {
        "run" => info,
        "args" => args,
        "timeout_seconds" => timeout,
        "configuration_sha256" => @config.digest,
        "pipeline_amendment_sha256" => @pipeline_amendment&.digest,
        # Compatibility aggregation reads wall_seconds; keep that field scoped to
        # the five recorded repetitions and expose setup cost separately.
        "wall_seconds" => measured_walls,
        "warmup_wall_seconds" => warmup && warmup["wall_seconds"],
        "all_execution_wall_seconds" => all_walls,
        "executions" => executions,
        "success" => success,
        "metrics" => metrics
      }
      if correction
        metadata.merge!(
          "timing_fixed" => true,
          "source_correction_amendment_sha256" => @source_correction.digest,
          "original_source_commit" => correction.dig("original_source", "commit"),
          "corrected_source_commit" => correction.dig("corrected_source", "commit"),
          "original_source_digest" => correction.dig("original_source", "digest"),
          "corrected_source_digest" => correction.dig("corrected_source", "digest"),
          "timing_fix_issue_categories" => correction.fetch("original_issue_categories"),
          "timing_fix_changed_paths" => correction.fetch("changed_paths")
        )
        metadata.merge!(build_metadata || {})
      end
      LocalEvaluation.atomic_yaml(File.join(output_dir, "benchmark_metadata.yaml"), metadata)
      [success, success ? metrics : {}]
    end
  end
end
