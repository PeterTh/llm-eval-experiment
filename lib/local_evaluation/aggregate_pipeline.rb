module LocalEvaluation
  class AggregatePipeline
    SOURCE_EXTENSIONS = %w[.c .cc .cpp .cu .h .hh .hpp].freeze
    DEPENDENCY_WHITELIST = %w[
      PRIVATE PUBLIC m OpenMP::OpenMP_CXX ${OpenMP_CXX_LIBRARIES}
      $<$<BOOL:${OpenMP_CXX_FOUND}>:${OpenMP_CXX_LIBRARIES}> -lgomp gomp -fopenmp omp
      $<$<CXX_COMPILER_ID:GNU>:gomp;m> $<$<CXX_COMPILER_ID:Clang>:omp;m>
      mpi MPI::MPI_CXX MPI::MPI_C ${MPI_CXX_LIBRARIES} ${MPI_LIBRARIES}
      CUDA::cudart ${MPI_CXX_LINK_FLAGS} CUDA::cuda CUDAToolkit::cudart cuda cudart
      ${CUDA_CUDART_LIBRARY} -lcudart cudadevrt OpenMP::OpenMP_CUDA ${CUDA_LIBRARIES}
      ${CUDART_LIB} CUDAToolkit::CUDART ${CUDA_LIBS} ${CUDA_LIB}
      /usr/local/cuda-12.6/lib64/libcudart.so /usr/local/cuda/lib64/libcudart.so
    ].freeze
    DEPENDENCY_EQUIVALENCE = {
      "cublas" => %w[CUDA::cublas cublas CUDAToolkit::cublas ${CUDA_CUBLAS_LIBRARY} ${CUDA_CUBLAS_LIBRARIES} ${CUDA_CUBLAS_LIB} -lcublas],
      "cusolver" => %w[CUDA::cusolver cusolver CUDAToolkit::cusolver ${CUDA_cusolver_LIBRARY} ${CUDA_CUSOLVER_LIBRARIES} ${CUDA_CUSOLVER_LIB} -lcusolver],
      "cusparse" => %w[CUDA::cusparse cusparse CUDAToolkit::cusparse ${CUDA_CUSPARSE_LIBRARY} ${CUDA_CUSPARSE_LIBRARIES} ${CUDA_CUSPARSE_LIB} -lcusparse],
      "curand" => %w[CUDA::curand curand CUDAToolkit::curand ${CUDA_CURAND_LIBRARY} ${CUDA_CURAND_LIBRARIES} ${CUDA_CURAND_LIB} -lcurand]
    }.freeze
    MAX_METADATA_BYTES = 64 * 1024 * 1024
    MAX_DIFF_TREE_ENTRIES = 10_000
    MAX_DIFF_FILES = 1_000
    MAX_DIFF_FILE_BYTES = 4 * 1024 * 1024
    MAX_DIFF_TOTAL_BYTES = 64 * 1024 * 1024
    MAX_DIFF_SCAN_SECONDS = 10.0
    MAX_DIFF_PROCESS_SECONDS = 2.0
    MAX_DIFF_CAPTURE_BYTES = 64 * 1024
    DIFF_SKIPPED_DIRECTORIES = %w[.git CMakeFiles Testing].freeze
    DIFF_SKIPPED_DIRECTORY_PATTERNS = [/\Abuild(?:[-_.].*)?\z/i, /\Acmake-build(?:[-_.].*)?\z/i].freeze

    class DiffScanLimit < StandardError; end

    def initialize(run_dir:, exact_id: nil, filter: nil, dry_run: false)
      @run_dir = File.expand_path(run_dir)
      @manifest = Manifest.new(@run_dir)
      @selected = @manifest.filtered_runs(exact_id: exact_id, filter: filter)
      @source_correction = SourceCorrectionAmendment.load(@run_dir, manifest: @manifest)
      @dry_run = dry_run
      warnings_path = File.join(@run_dir, "aggregate_parse_warnings.yaml")
      @warnings = File.file?(warnings_path) ? (LocalEvaluation.load_yaml(warnings_path) || {}) : {}
    end

    def run
      input_digests = current_input_digests
      validation = load_validation
      benchmarks = load_benchmarks
      aggregate_path = File.join(@run_dir, "aggregate_results.yaml")
      full_rebuild = @selected.size == @manifest.runs.size
      base_aggregate_sha256 = File.file?(aggregate_path) ? LocalEvaluation.sha256_file(aggregate_path) : nil
      results = if !full_rebuild && File.file?(aggregate_path)
        LocalEvaluation.load_yaml(aggregate_path, permitted_classes: [AggregateEvaluation]) || {}
      else
        {}
      end
      @warnings.clear if full_rebuild
      @selected.each do |id, info|
        @warnings.delete(id)
        results[id] = aggregate_one(id, info, validation[id], benchmarks[id])
      end
      if @dry_run
        puts "Aggregate dry run: would write #{results.size} records with #{@warnings.size} warnings"
        return
      end
      ensure_inputs_unchanged!(input_digests)
      write_outputs(results)
      ensure_inputs_unchanged!(input_digests)
      LocalEvaluation.atomic_yaml(File.join(@run_dir, "aggregate_parse_warnings.yaml"), @warnings)
      aggregate_sha256 = LocalEvaluation.sha256_file(aggregate_path)
      LocalEvaluation.atomic_yaml(File.join(@run_dir, "aggregate_metadata.yaml"), {
        "schema_version" => 1,
        "generated_at" => Time.now.iso8601,
        **input_digests,
        "aggregate_results_sha256" => aggregate_sha256,
        "refresh_scope" => full_rebuild ? "full" : "partial",
        "full_rebuild" => full_rebuild,
        "refreshed_ids" => @selected.keys.sort,
        "base_aggregate_sha256" => full_rebuild ? nil : base_aggregate_sha256,
        "record_count" => results.size,
        "manifest_run_count" => @manifest.runs.size,
        "complete" => results.keys.sort == @manifest.runs.keys.sort,
        "validation_records" => validation.size,
        "benchmark_records" => benchmarks.size,
        "warning_records" => @warnings.size
      })
      puts "Wrote #{results.size} aggregate records to #{@run_dir}"
    end

    private

    def current_input_digests
      validation_path = File.join(@run_dir, "validation", "all_validation_results.yaml")
      raise "Validation results not found: #{validation_path}" unless File.file?(validation_path)

      {
        "manifest_sha256" => LocalEvaluation.sha256_file(@manifest.path),
        "pipeline_amendment_sha256" => PipelineAmendment.digest_for(@run_dir),
        "source_correction_amendment_sha256" => SourceCorrectionAmendment.digest_for(@run_dir),
        "validation_results_sha256" => LocalEvaluation.sha256_file(validation_path),
        "benchmark_full_results_sha256" => optional_sha256(
          File.join(@run_dir, "benchmark", BENCHMARK_FULL_RESULTS_FN)
        ),
        "benchmark_config_sha256" => optional_sha256(File.join(@run_dir, "benchmark_config.yaml"))
      }
    end

    def optional_sha256(path)
      File.file?(path) ? LocalEvaluation.sha256_file(path) : nil
    end

    def ensure_inputs_unchanged!(expected)
      current = current_input_digests
      changed = expected.keys.select { |key| expected[key] != current[key] }
      return if changed.empty?

      raise "Aggregation inputs changed while the aggregate was being built: #{changed.join(', ')}; rerun aggregate"
    end

    def load_validation
      path = File.join(@run_dir, "validation", "all_validation_results.yaml")
      raise "Validation results not found: #{path}" unless File.file?(path)
      array = LocalEvaluation.load_yaml(path, permitted_classes: [ValidationResult]) || []
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

    def load_benchmarks
      path = File.join(@run_dir, "benchmark", BENCHMARK_FULL_RESULTS_FN)
      return {} unless File.file?(path)
      results = LocalEvaluation.load_yaml(path) || {}
      unless results.is_a?(Hash) && results.keys.all? { |id| id.is_a?(String) }
        raise "Benchmark full results must map string run IDs to result records"
      end
      unknown = results.keys - @manifest.runs.keys
      raise "Benchmark full results contain unknown IDs: #{unknown.sort.join(', ')}" unless unknown.empty?
      results.each do |id, record|
        valid_failure = record.is_a?(Array) && (record == [false, {}] || record == [false, []])
        valid_success = record.is_a?(Array) && record.size == 2 && record[0] == true &&
                        record[1].is_a?(Array) && record[1].size == BENCHMARK_COUNT &&
                        record[1].all? do |metrics|
                          value = metrics.is_a?(Hash) && metrics["time"]
                          BenchmarkMetrics.valid_time?(value)
                        end
        raise "Malformed benchmark result for #{id}" unless valid_failure || valid_success
      end
      results
    end

    def aggregate_one(id, info, validation_result, benchmark_result)
      result = AggregateEvaluation.new(info["benchmark"], info["model"], info["par_type"], info["run"])
      result.source_batch = info["batch"]
      result.source_path = info["source_path"]
      parse_agent_metadata(id, info, result)
      result.non_whitelisted_dependencies = dependencies_for(id, info)
      apply_validation(result, validation_result)
      apply_benchmark(result, id, benchmark_result)
      result
    end

    def parse_agent_metadata(id, info, result)
      timing_path = File.join(info["source_path"], "timing.txt")
      output_path = File.join(info["source_path"], "output.txt")
      if File.file?(timing_path) && (match = read_limited(timing_path).match(/Duration:\s+(?<seconds>\d+(?:\.\d+)?)\s+seconds/))
        result.total_time = match[:seconds].to_f
      else
        warn_for(id, "Missing or unparseable timing.txt")
      end
      unless File.file?(output_path)
        warn_for(id, "Missing output.txt")
        apply_diff_counts(id, info, result)
        return
      end

      output = read_limited(output_path)
      if (match = output.match(/API time spent:\s+(?:(?<hours>\d+(?:\.\d+)?)h)?\s*(?:(?<minutes>\d+(?:\.\d+)?)m)?\s*(?<seconds>\d+(?:\.\d+)?)s/))
        result.api_time = match[:hours].to_f * 3600 + match[:minutes].to_f * 60 + match[:seconds].to_f
      else
        warn_for(id, "API time is unavailable in this agent log format")
      end
      if (match = output.match(/Total code changes:\s+\+(?<adds>\d+)\s+-(?<deletes>\d+)/)) ||
         (match = output.match(/^Changes\s+\+(?<adds>\d+)\s+-(?<deletes>\d+)/m))
        result.code_additions = match[:adds].to_i
        result.code_deletions = match[:deletes].to_i
      else
        apply_diff_counts(id, info, result)
      end

      usage = output.scan(/^\s*[\w.\/-]+\s+(?<input>\d+(?:\.\d+)?[kKmM]?) in,\s+(?<output>\d+(?:\.\d+)?[kKmM]?) out,\s+(?<cached>\d+(?:\.\d+)?[kKmM]?) cached/m)
      if usage.any?
        result.input_tokens = usage.sum { |row| token_number(row[0]) }
        result.output_tokens = usage.sum { |row| token_number(row[1]) }
        result.cached_tokens = usage.sum { |row| token_number(row[2]) }
        result.total_tokens = result.input_tokens + result.output_tokens
        warn_for(id, "Aggregated #{usage.size} Copilot model token rows") if usage.size > 1
      elsif (match = output.match(/\[Usage\].*?input:\s*(?<input>\d+).*?output:\s*(?<output>\d+).*?cache_read:\s*(?<cached>\d+)/m))
        result.input_tokens = match[:input].to_f
        result.output_tokens = match[:output].to_f
        result.cached_tokens = match[:cached].to_f
        result.total_tokens = result.input_tokens + result.output_tokens
      elsif (match = output.match(/tokens used\s*\n\s*(?<total>[\d,]+)/i))
        result.total_tokens = match[:total].delete(",").to_f
        warn_for(id, "Codex reports only total tokens; input/output/cache fields are unavailable")
      elsif (match = output.match(/Tokens\s+↑\s*(?<input>\d+(?:\.\d+)?[kKmM]?)\s*•\s*↓\s*(?<output>\d+(?:\.\d+)?[kKmM]?)\s*•\s*(?<cached>\d+(?:\.\d+)?[kKmM]?)\s*\(cached\)/))
        result.input_tokens = token_number(match[:input])
        result.output_tokens = token_number(match[:output])
        result.cached_tokens = token_number(match[:cached])
        result.total_tokens = result.input_tokens + result.output_tokens
      else
        warn_for(id, "No supported token-usage format found")
      end
    rescue StandardError => e
      warn_for(id, "Agent metadata parse error: #{e.class}: #{e.message}")
      apply_diff_counts(id, info, result) if result.code_additions.nil?
    end

    def token_number(value)
      multiplier = case value[-1]
                   when "k", "K" then 1_000
                   when "m", "M" then 1_000_000
                   else 1
                   end
      value.sub(/[kKmM]\z/, "").to_f * multiplier
    end

    def apply_diff_counts(id, info, result)
      benchmark = info.fetch("benchmark")
      source_root = info.fetch("source_path")
      if File.lstat(source_root).symlink?
        raise DiffScanLimit, "generated source root is a symlink"
      end
      original_roots = [File.join(@manifest.benchmarks_root, benchmark), File.join(@manifest.benchmarks_root, "common")]
      generated_roots = [File.join(source_root, benchmark), File.join(source_root, "common")]
      additions = 0
      deletions = 0
      budget = {
        entries: 0,
        files: 0,
        bytes: 0,
        deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + MAX_DIFF_SCAN_SECONDS,
        skipped_symlinks: 0
      }
      original_roots.zip(generated_roots).each do |original_root, generated_root|
        relative_files(original_root, generated_root, budget: budget).each do |relative|
          check_diff_deadline!(budget)
          old_path = File.join(original_root, relative)
          new_path = File.join(generated_root, relative)
          old_file = bounded_regular_file?(old_path)
          new_file = bounded_regular_file?(new_path)
          if old_file && new_file
            add, delete = diff_numstat(old_path, new_path, budget)
            additions += add
            deletions += delete
          elsif new_file
            additions += bounded_line_count(new_path, budget)
          elsif old_file
            deletions += bounded_line_count(old_path, budget)
          end
        end
      end
      result.code_additions = additions
      result.code_deletions = deletions
      warn_for(id, "Skipped #{budget[:skipped_symlinks]} symlink entries while computing code changes") if budget[:skipped_symlinks].positive?
    rescue StandardError => e
      result.code_additions = nil
      result.code_deletions = nil
      warn_for(id, "Code-change diff scan was skipped: #{e.message}")
    end

    def relative_files(*roots, budget:)
      roots.flat_map do |root|
        next [] unless bounded_directory?(root)

        found = []
        stack = [[root, ""]]
        until stack.empty?
          directory, relative_directory = stack.pop
          check_diff_deadline!(budget)
          Dir.open(directory) do |entries|
            entries.each_child do |basename|
              check_diff_deadline!(budget)
              budget[:entries] += 1
              raise DiffScanLimit, "tree entry cap of #{MAX_DIFF_TREE_ENTRIES} was exceeded" if budget[:entries] > MAX_DIFF_TREE_ENTRIES

              path = File.join(directory, basename)
              relative = relative_directory.empty? ? basename : File.join(relative_directory, basename)
              stat = File.lstat(path)
              if stat.symlink?
                budget[:skipped_symlinks] += 1
                next
              end
              if stat.directory?
                stack << [path, relative] unless skipped_diff_directory?(basename)
                next
              end
              next unless stat.file?
              next unless basename == "CMakeLists.txt" || SOURCE_EXTENSIONS.include?(File.extname(basename))

              budget[:files] += 1
              raise DiffScanLimit, "file cap of #{MAX_DIFF_FILES} was exceeded" if budget[:files] > MAX_DIFF_FILES
              raise DiffScanLimit, "#{relative} exceeds the per-file cap of #{MAX_DIFF_FILE_BYTES} bytes" if stat.size > MAX_DIFF_FILE_BYTES
              budget[:bytes] += stat.size
              raise DiffScanLimit, "total source byte cap of #{MAX_DIFF_TOTAL_BYTES} was exceeded" if budget[:bytes] > MAX_DIFF_TOTAL_BYTES
              found << relative
            end
          end
        end
        found
      end.uniq
    end

    def bounded_directory?(path)
      File.lstat(path).directory?
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    end

    def bounded_regular_file?(path)
      File.lstat(path).file?
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    end

    def skipped_diff_directory?(basename)
      DIFF_SKIPPED_DIRECTORIES.include?(basename) ||
        DIFF_SKIPPED_DIRECTORY_PATTERNS.any? { |pattern| pattern.match?(basename) }
    end

    def check_diff_deadline!(budget)
      return if Process.clock_gettime(Process::CLOCK_MONOTONIC) < budget.fetch(:deadline)

      raise DiffScanLimit, "wall-time cap of #{MAX_DIFF_SCAN_SECONDS} seconds was exceeded"
    end

    def bounded_line_count(path, budget)
      count = 0
      bytes = 0
      last_byte = nil
      File.open(path, "rb") do |file|
        while (chunk = file.read(64 * 1024))
          bytes += chunk.bytesize
          raise DiffScanLimit, "#{File.basename(path)} grew beyond the per-file byte cap while scanning" if bytes > MAX_DIFF_FILE_BYTES
          count += chunk.count("\n")
          last_byte = chunk.getbyte(-1)
          check_diff_deadline!(budget)
        end
      end
      count += 1 if bytes.positive? && last_byte != 10
      count
    end

    def diff_numstat(old_path, new_path, budget)
      remaining = budget.fetch(:deadline) - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise DiffScanLimit, "wall-time cap of #{MAX_DIFF_SCAN_SECONDS} seconds was exceeded" unless remaining.positive?

      output, exit_code = bounded_capture(
        ["git", "--no-pager", "diff", "--no-index", "--numstat", "--no-renames",
         "--no-ext-diff", "--no-textconv", "--", old_path, new_path],
        timeout: [remaining, MAX_DIFF_PROCESS_SECONDS].min
      )
      unless [0, 1].include?(exit_code)
        raise DiffScanLimit, "git diff failed with exit #{exit_code} for #{File.basename(new_path)}"
      end

      line = output.each_line.find { |entry| entry.include?("\t") }
      return [0, 0] unless line
      add, delete = line.split("\t", 3)
      unless add&.match?(/\A\d+\z/) && delete&.match?(/\A\d+\z/)
        raise DiffScanLimit, "git diff returned non-text or unparseable counts for #{File.basename(new_path)}"
      end
      [add.to_i, delete.to_i]
    end

    def bounded_capture(argv, timeout:)
      reader, writer = IO.pipe
      pid = Process.spawn(*argv, out: writer, err: File::NULL, pgroup: true, rlimit_core: [0, 0])
      writer.close
      output = +""
      status = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        loop do
          chunk = reader.read_nonblock(16 * 1024, exception: false)
          break if chunk == :wait_readable || chunk.nil?
          output << chunk
          raise DiffScanLimit, "git diff output exceeded #{MAX_DIFF_CAPTURE_BYTES} bytes" if output.bytesize > MAX_DIFF_CAPTURE_BYTES
        end

        waited, status = Process.wait2(pid, Process::WNOHANG)
        break if waited

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise DiffScanLimit, "git diff exceeded its #{timeout.round(3)} second timeout" unless remaining.positive?
        IO.select([reader], nil, nil, [remaining, 0.01].min)
      end
      # Once wait2 succeeds the child has closed its writer. Drain the small tail.
      loop do
        chunk = reader.read_nonblock(16 * 1024, exception: false)
        break if chunk == :wait_readable || chunk.nil?
        output << chunk
        raise DiffScanLimit, "git diff output exceeded #{MAX_DIFF_CAPTURE_BYTES} bytes" if output.bytesize > MAX_DIFF_CAPTURE_BYTES
      end
      [output, status.exitstatus || 128 + status.termsig]
    ensure
      writer&.close unless writer&.closed?
      reader&.close unless reader&.closed?
      terminate_bounded_process(pid) if pid && !status
    end

    def terminate_bounded_process(pid)
      begin
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH
        nil
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.1
      loop do
        waited, = Process.wait2(pid, Process::WNOHANG)
        return if waited
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.005
      end
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
      Process.wait2(pid)
    rescue Errno::ECHILD
      nil
    end

    def dependencies_for(id, info)
      path = File.join(info["source_path"], info["benchmark"], "CMakeLists.txt")
      fallback = File.join(info["source_path"], "CMakeLists.txt")
      path = fallback if !bounded_regular_file?(path) && bounded_regular_file?(fallback)
      unless bounded_regular_file?(path)
        warn_for(id, "CMakeLists.txt is unavailable for dependency scanning")
        return []
      end
      dependencies = read_limited(path, 8 * 1024 * 1024)
                     .scan(/target_link_libraries\s*\([^\s\)]+\s+([^\)]+)\)/mi)
                     .flatten.flat_map(&:split)
      dependencies.map! do |dependency|
        found = DEPENDENCY_EQUIVALENCE.find { |_name, equivalents| equivalents.include?(dependency) }
        found ? found[0] : dependency
      end
      dependencies.reject { |dependency| DEPENDENCY_WHITELIST.include?(dependency) }.uniq.sort
    rescue StandardError => e
      warn_for(id, "Dependency scan failed: #{e.class}: #{e.message}")
      nil
    end

    def apply_validation(result, validation)
      unless validation
        result.validation_err_string = "Validation result missing"
        return
      end
      result.validation_status = if validation.output_comparison
        VS_FULLY_VALID
      elsif validation.internal_validation
        VS_INTERNALLY_VALID
      elsif validation.validation_run
        VS_RUNS
      elsif validation.validation_build
        VS_BUILDS
      elsif validation.basic_para
        VS_PARALLELIZED
      else
        VS_INVALID
      end
      result.validation_err_string = validation.err_string
    end

    def apply_benchmark(result, id, benchmark)
      return unless benchmark
      result.benchmark_success = benchmark[0]
      if result.benchmark_success
        result.benchmark_times = benchmark[1].map { |metrics| metrics.fetch("time") }
        result.benchmark_median_time = BenchmarkMetrics.median(result.benchmark_times)
      end
      metadata_path = File.join(@run_dir, "benchmark", id, "benchmark_metadata.yaml")
      return unless File.file?(metadata_path)
      metadata = LocalEvaluation.load_yaml(metadata_path)
      result.benchmark_wall_times = metadata["wall_seconds"]
      result.benchmark_config_sha256 = metadata["configuration_sha256"]
      result.timing_fixed = metadata["timing_fixed"] == true
      return unless result.timing_fixed

      result.timing_fix_issue_categories = metadata["timing_fix_issue_categories"]
      result.original_source_commit = metadata["original_source_commit"]
      result.corrected_source_commit = metadata["corrected_source_commit"]
      result.original_source_digest = metadata["original_source_digest"]
      result.corrected_source_digest = metadata["corrected_source_digest"]
      result.source_correction_amendment_sha256 = metadata["source_correction_amendment_sha256"]
      correction = @source_correction&.record_for(id)
      result.original_source_url = correction && correction["original_source_url"]
      result.corrected_source_url = correction && correction["corrected_source_url"]
    end

    def warn_for(id, warning)
      warnings = (@warnings[id] ||= [])
      warnings << warning unless warnings.include?(warning)
    end

    def read_limited(path, limit = MAX_METADATA_BYTES)
      size = File.size(path)
      data = if size <= limit
        File.binread(path)
      else
        half = limit / 2
        File.open(path, "rb") do |file|
          head = file.read(half)
          file.seek(-half, IO::SEEK_END)
          "#{head}\n[... #{size - limit} bytes omitted ...]\n#{file.read(half)}"
        end
      end

      data.force_encoding(Encoding::UTF_8).scrub
    end

    def write_outputs(results)
      LocalEvaluation.atomic_yaml(File.join(@run_dir, "aggregate_results.yaml"), results)
      path = File.join(@run_dir, "aggregate_results.csv")
      headers = %w[
        benchmark model par_type run input_tokens output_tokens cached_tokens api_time total_time
        code_additions code_deletions non_whitelisted_dependencies validation_status validation_err_string
        benchmark_success benchmark_times benchmark_median_time source_batch source_path total_tokens
        benchmark_wall_times benchmark_config_sha256 timing_fixed timing_fix_issue_categories
        original_source_commit corrected_source_commit original_source_digest corrected_source_digest
        original_source_url corrected_source_url source_correction_amendment_sha256
      ]
      rows = results.map do |_id, result|
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
      csv = CSV.generate { |out| out << headers; rows.each { |row| out << row } }
      LocalEvaluation.atomic_write(path, csv)
    end
  end
end
