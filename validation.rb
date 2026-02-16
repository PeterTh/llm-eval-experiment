require_relative "general"
require_relative "validation_helper"

BENCH_SOURCE = "../benchmarks"

EXPERIMENT_PATH = ARGV.find { |arg| arg.start_with?("--exp=") }&.split("=")&.last

TIMESTAMP = Time.now.strftime("%Y%m%d-%H%M%S")
VALIDATION_DIR_DEFAULT = File.join(File.expand_path("~/llm_para_validation/"), "#{TIMESTAMP}")
VALIDATION_DIR = ARGV.find { |arg| arg.start_with?("--validation-dir=") }&.split("=")&.last || VALIDATION_DIR_DEFAULT

REUSE_REFERENCE_DIR = ARGV.find { |arg| arg.start_with?("--reuse-ref=") }&.split("=")&.last

FULL_STATS = ARGV.include?("--full-stats")

if EXPERIMENT_PATH.nil? || ARGV.include?("--help") || ARGV.include?("-h")
    puts "Usage: ruby validation_benchmark.rb [options]"
    puts "Options:"
    puts "  --exp=EXPERIMENT_PATH       Path to the experiment results to validate (required)"
    puts "  --validation-dir=DIR        Directory to use for validation builds and outputs (optional, incrementally continues)"
    puts "  --reuse-ref=REF_DIR         Reuse reference outputs from the given directory instead of regenerating them (optional)"
    puts "  --full-stats                Print detailed statistics about validation results (optional)"
    exit
end

VALIDATION_PARAMS = "-v -r"
VALIDATION_PARAMS_ROOMSIM = "-v -o"

def get_validation_params(benchmark)
    return benchmark == "roomsim" ? VALIDATION_PARAMS_ROOMSIM : VALIDATION_PARAMS
end

VALIDATION_SIZES = {
    "black-scholes" => "-n 10000",
    "cahn-hilliard" => "-x 64 -y 64 -z 64 -i 20",
    "cholesky" => "-n 512",
    "floydwarshall" => "-n 512",
    "matmul" => "-n 512",
    "nbody" => "-n 1024 -s 10",
    "qtclustering" => "-n 1000",
    "roomsim" => "-n 256 -t 100",
    "spmv" => "-n 1024 -s 10 -i 10",
    "stencil3d" => "-x 64 -y 64 -z 64 -i 20",
    "unstructured" => "-n 256 -i 20"
}

VALIDATION_TIMEOUT = 30 # seconds, to prevent hanging during validation runs

FileUtils.mkdir_p(VALIDATION_DIR)

VALIDATION_FN = "validation_out"

def perform_validation_run(benchmark, build_dir, par_type)
    mpirun = ""
    mpirun = "mpirun -n 4 " if par_type == PAR_MPI || par_type == PAR_HYBRID
    env = {}
    env = { "OMP_NUM_THREADS" => "8" } if par_type == PAR_OMP || par_type == PAR_HYBRID
    Dir.chdir(build_dir) do
        executable = benchmark_to_executable(benchmark)
        command = "#{mpirun}./#{executable} #{get_validation_params(benchmark)} #{VALIDATION_SIZES[benchmark]}"
        ret = run_with_outputs_to_files(command, VALIDATION_FN, VALIDATION_TIMEOUT, env)
        raise ("Validation run failed for #{benchmark} in #{Dir.pwd}. Check #{VALIDATION_FN}*.log for details.\n" +
               "Command: #{command}") unless ret
    end
end

def get_reference_output(benchmark)
    ref_dir = REUSE_REFERENCE_DIR || File.join(VALIDATION_DIR, "reference", benchmark)
    validation_fn = File.join(ref_dir, VALIDATION_FN + STDOUT_SUFFIX)
    if !File.directory?(ref_dir) || !File.exist?(validation_fn)
        puts " -> Generating reference outputs for benchmark #{benchmark} in #{ref_dir}"
        build(File.expand_path(File.join(BENCH_SOURCE, benchmark)), ref_dir)
        perform_validation_run(benchmark, ref_dir, nil)
    end
    return File.read(validation_fn)
end

puts "Starting validation:"
puts "   - experiment results from #{EXPERIMENT_PATH}"
puts "   - validation builds and outputs in #{VALIDATION_DIR}"
puts

class ValidationResult
    attr_accessor :basic_para, :validation_build, :validation_run, :internal_validation, :output_comparison, :err_string
    def initialize(benchmark, model, par_type, run)
        @basic_para = false
        @validation_build = false
        @validation_run = false
        @internal_validation = false
        @output_comparison = false
        @err_string = ""
        @benchmark = benchmark
        @model = model
        @par_type = par_type
        @run = run
    end

    # provide a one-line console summary with emojis for quick overview of which validation steps passed or failed
    def summary
        summary_str = "%12s | %10s | %6s | %d : " % [@benchmark, @model, @par_type, @run]
        summary_str += @basic_para ? "✅ Para " : "❌ Para "
        summary_str += @validation_build ? "✅ Build " : "❌ Build " if @basic_para
        summary_str += @validation_run ? "✅ Run " : "❌ Run " if @validation_build
        summary_str += @internal_validation ? "✅ Validation " : "❌ Validation " if @validation_run
        summary_str += @output_comparison ? "✅ Comparison" : "❌ Comparison" if @internal_validation
        return summary_str
    end

    def is_for(benchmark, model, par_type, run)
        return @benchmark == benchmark && @model == model && @par_type == par_type && @run == run
    end
end

$all_validation_results = []

# reload existing validation results if we are continuing an existing validation run
ALL_VALIDATION_RESULTS_FN = File.join(VALIDATION_DIR, "all_validation_results.yaml")
if File.exist?(ALL_VALIDATION_RESULTS_FN)
    puts "Loading existing validation results from #{ALL_VALIDATION_RESULTS_FN} to continue."
    $all_validation_results = 
        YAML.safe_load(File.read(ALL_VALIDATION_RESULTS_FN), permitted_classes: [ValidationResult], aliases: true) || []
    puts " -> Loaded #{$all_validation_results.size} existing validation results."
end

# actual validation

def validate_experiment(entry, id_string, benchmark, model, par_type, run)
    validation_result = ValidationResult.new(benchmark, model, par_type, run)

    this_validation_dir = File.join(VALIDATION_DIR, id_string)
    FileUtils.mkdir_p(this_validation_dir)
    puts "Validating #{id_string} (benchmark: #{benchmark}, model: #{model}, par_type: #{par_type}, run: #{run})"
    puts "   - Input from #{entry}"
    puts "   - Output to #{this_validation_dir}"
    
    # get reference outputs
    ref_output = get_reference_output(benchmark)

    validation_result_fn = File.join(this_validation_dir, VALIDATION_RESULT_FN)
    File.open(validation_result_fn, "w+") do |validation_result_file|

        # basic textual validation of parallelization approach
        begin
            detected_par_types = parallelization_detection(entry, benchmark)
            expected_par_types = [par_type]
            if par_type == PAR_HYBRID
                expected_par_types = [PAR_OMP, PAR_CUDA, PAR_MPI]
            end
            if detected_par_types.empty?
                validation_result.err_string = "Error during parallelization detection: No parallelization approach detected in source code."
                validation_result_file.puts(validation_result.err_string)
                return validation_result
            end
            if detected_par_types.any? { |detected| !expected_par_types.include?(detected) }
                validation_result.err_string = "Error during parallelization detection: Detected parallelization approaches " +
                    "#{detected_par_types} do not match expected approaches #{expected_par_types} for par_type #{par_type}."
                validation_result_file.puts(validation_result.err_string)
                return validation_result
            end
        rescue => e
            validation_result.err_string = "Error during parallelization detection:\n#{e.message}"
            validation_result_file.puts(validation_result.err_string)
            return validation_result
        end
        validation_result.basic_para = true
        validation_result_file.puts "Parallelization detection PASSED: Detected parallelization approaches #{detected_par_types}."

        # rename CMakeCache if it exists to prevent CMake from reusing cached build params from the original experiment run
        if File.exist?(File.join(entry, benchmark, "CMakeCache.txt"))
            FileUtils.mv(File.join(entry, benchmark, "CMakeCache.txt"), File.join(entry, benchmark, "CMakeCache_backup.txt"))
            validation_result_file.puts "Renamed CMakeCache.txt to CMakeCache_backup.txt prevent reuse of cached build params."
        end

        # perform validation build
        begin
            build_dir = File.join(entry, benchmark)
            build(build_dir, this_validation_dir)
        rescue => e
            validation_result.err_string = "Error during validation build:\n#{e.message}"
            validation_result_file.puts(validation_result.err_string)
            return validation_result
        end
        validation_result.validation_build = true
        validation_result_file.puts "Validation build PASSED."

        # perform validation run
        begin
            perform_validation_run(benchmark, this_validation_dir, par_type)
        rescue => e
            # some benchmarks return non-zero if their internal validation fails, but in that case we want to continue
            # check if the output exists and contains a validation failure to detect this case
            ran_but_failed_validation = lambda do
                validation_output_path = File.join(this_validation_dir, VALIDATION_FN + STDOUT_SUFFIX)
                if File.exist?(validation_output_path)
                    validation_output = File.read(validation_output_path)
                    if validation_output.include?("Validation: FAILED") || validation_output.include?("Validation fail")
                        return true
                    end
                end
                return false
            end
            if !ran_but_failed_validation.call()
                validation_result.err_string = "Error during validation run:\n#{e.message}"
                validation_result_file.puts(validation_result.err_string)
                return validation_result
            end
        end
        validation_result.validation_run = true
        validation_result_file.puts "Validation run PASSED."

        # check internal validation ("Validation: PASSED" in the output)
        validation_output = File.read(File.join(this_validation_dir, VALIDATION_FN + STDOUT_SUFFIX))
        if validation_output.include?("Validation: FAILED") || validation_output.include?("Validation fail") || !validation_output.include?("Validation: PASSED")
            validation_result.err_string = "Internal validation FAILED."
            validation_result_file.puts(validation_result.err_string)
            return validation_result
        end
        validation_result.internal_validation = true
        validation_result_file.puts "Internal validation PASSED."

        # compare output with reference output
        comparison_result = validate(ref_output, validation_output)
        if comparison_result[0] == false
            validation_result.err_string = "Output comparison FAILED:\n#{comparison_result[1]}"
            validation_result_file.puts(validation_result.err_string)
            return validation_result
        end
        validation_result.output_comparison = true
        validation_result_file.puts "Output comparison PASSED:\n#{comparison_result[1]}"
    end
    return validation_result
end

Dir[File.join(EXPERIMENT_PATH, "*")].each do |entry|
    if File.directory?(entry)
        id_string = File.basename(entry)
        next unless is_id_string?(id_string)

        # next unless id_string == "matmul_gpt-4.1_omp_r1" # for testing only a single configuration

        benchmark, model, par_type, run = id_string_to_infos(id_string)

        # skip if we already have a validation result for this configuration (for continuing existing runs)
        if $all_validation_results.any? { |result| result.is_for(benchmark, model, par_type, run) }
            puts "   - Skipping #{id_string} as validation result already exists."
            next
        end

        validation_result = validate_experiment(entry, id_string, benchmark, model, par_type, run)

        puts validation_result.summary
        puts

        $all_validation_results << validation_result
        
        # serialize the results accumulated so far to be able to resume an interrupted validation run
        File.open(ALL_VALIDATION_RESULTS_FN, "w") do |f|
            f.write(YAML.dump($all_validation_results))
        end
    end
end

# Statistics about the validation results

basic_para_count = 0
validation_build_count = 0
validation_run_count = 0
internal_validation_count = 0
output_comparison_count = 0
$all_validation_results.each do |result|
    basic_para_count += 1 if result.basic_para
    validation_build_count += 1 if result.validation_build
    validation_run_count += 1 if result.validation_run
    internal_validation_count += 1 if result.internal_validation
    output_comparison_count += 1 if result.output_comparison
end

puts "Validation complete. Results available in #{ALL_VALIDATION_RESULTS_FN}."
puts "Summary of validation results:"
puts "   - Total configurations validated: #{$all_validation_results.size}"
puts "   - Basic parallelization detection passed: #{basic_para_count} / #{$all_validation_results.size} (#{(basic_para_count.to_f / $all_validation_results.size * 100).round(2)}%)"
puts "   - Validation build passed: #{validation_build_count} / #{$all_validation_results.size} (#{(validation_build_count.to_f / $all_validation_results.size * 100).round(2)}%)"
puts "   - Validation run passed: #{validation_run_count} / #{$all_validation_results.size} (#{(validation_run_count.to_f / $all_validation_results.size * 100).round(2)}%)"
puts "   - Internal validation passed: #{internal_validation_count} / #{$all_validation_results.size} (#{(internal_validation_count.to_f / $all_validation_results.size * 100).round(2)}%)"
puts "   - Output comparison passed: #{output_comparison_count} / #{$all_validation_results.size} (#{(output_comparison_count.to_f / $all_validation_results.size * 100).round(2)}%)"

exit unless FULL_STATS

puts "\nPer-benchmark numbers:"
puts "Benchmark, invalid, para, built, ran, internal, valid"
$all_validation_results.group_by { |result| result.instance_variable_get(:@benchmark) }.each do |benchmark, results|
    invalid_count = results.size
    basic_para_count = results.count { |r| r.basic_para }
    validation_build_count = results.count { |r| r.validation_build }
    validation_run_count = results.count { |r| r.validation_run }
    internal_validation_count = results.count { |r| r.internal_validation }
    output_comparison_count = results.count { |r| r.output_comparison }
    puts "#{benchmark}, #{invalid_count - basic_para_count}, #{basic_para_count - validation_build_count}, #{validation_build_count - validation_run_count}, #{validation_run_count - internal_validation_count}, #{internal_validation_count - output_comparison_count}, #{output_comparison_count}"
end

puts "\nPer parallelization type numbers:"
puts "Partype, invalid, para, built, ran, internal, valid"
$all_validation_results.group_by { |result| result.instance_variable_get(:@par_type) }.each do |par_type, results|
    invalid_count = results.size
    basic_para_count = results.count { |r| r.basic_para }
    validation_build_count = results.count { |r| r.validation_build }
    validation_run_count = results.count { |r| r.validation_run }
    internal_validation_count = results.count { |r| r.internal_validation }
    output_comparison_count = results.count { |r| r.output_comparison }
    puts "#{par_type}, #{invalid_count - basic_para_count}, #{basic_para_count - validation_build_count}, #{validation_build_count - validation_run_count}, #{validation_run_count - internal_validation_count}, #{internal_validation_count - output_comparison_count}, #{output_comparison_count}"
end

puts "\nPer model numbers:"
puts "Model, invalid, para, built, ran, internal, valid"
$all_validation_results.group_by { |result| result.instance_variable_get(:@model) }.each do |model, results|
    invalid_count = results.size
    basic_para_count = results.count { |r| r.basic_para }
    validation_build_count = results.count { |r| r.validation_build }
    validation_run_count = results.count { |r| r.validation_run }
    internal_validation_count = results.count { |r| r.internal_validation }
    output_comparison_count = results.count { |r| r.output_comparison }
    puts "#{model}, #{invalid_count - basic_para_count}, #{basic_para_count - validation_build_count}, #{validation_build_count - validation_run_count}, #{validation_run_count - internal_validation_count}, #{internal_validation_count - output_comparison_count}, #{output_comparison_count}"
end
