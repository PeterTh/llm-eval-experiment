require_relative "general"
require_relative "validation_helper"

BENCH_SOURCE = "../benchmarks"

EXPERIMENT_PATH = ARGV.find { |arg| arg.start_with?("--exp=") }&.split("=")&.last

VALIDATION_BUILD_ROOT_DEFAULT = File.expand_path("~/llm_para_validation/")
VALIDATION_BUILD_ROOT = ARGV.find { |arg| arg.start_with?("--validation-dir=") }&.split("=")&.last || VALIDATION_BUILD_ROOT_DEFAULT

REUSE_REFERENCE_DIR = ARGV.find { |arg| arg.start_with?("--reuse-ref=") }&.split("=")&.last

if EXPERIMENT_PATH.nil? || ARGV.include?("--help")
    puts "Usage: ruby validation_benchmark.rb"
    puts "Options:"
    puts "  --exp=EXPERIMENT_PATH       Path to the experiment results to validate (required)"
    puts "  --validation-dir=DIR        Directory to use for validation builds and outputs (optional)"
    puts "  --reuse-ref=REF_DIR         Reuse reference outputs from the given directory instead of regenerating them (optional)"
    exit
end

VALIDATION_PARAMS = "-v -r"

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

BENCHMARK_SIZES = {
    PAR_OMP => {
        "black-scholes" => "-n 10000000",
        "cahn-hilliard" => "-x 128 -y 128 -z 128 -i 100",
        "cholesky" => "-n 2048",
        "floydwarshall" => "-n 2048",
        "matmul" => "-n 2048",
        "nbody" => "-n 100000 -s 100",
        "qtclustering" => "-n 10000",
        "roomsim" => "-n 512 -t 500",
        "spmv" => "-n 32000 -s 100 -i 100",
        "stencil3d" => "-x 128 -y 128 -z 128 -i 100",
        "unstructured" => "-n 512 -i 100"
    },
}


def id_string_to_infos(id_string)
    # id string format: benchmark_model_par_type_rX
    parts = id_string.split("_")
    benchmark = parts[0]
    model = parts[1]
    par_type = parts[2]
    run = parts[3][1..-1].to_i # remove 'r' and convert to int
    return benchmark, model, par_type, run
end

TIMESTAMP = Time.now.strftime("%Y%m%d-%H%M%S")
VALIDATION_DIR = File.join(VALIDATION_BUILD_ROOT, "#{TIMESTAMP}")
FileUtils.mkdir_p(VALIDATION_DIR)

VALIDATION_FN = "validation_out"
VALIDATION_RESULT_FN = "validation_result.txt"

STDOUT_SUFFIX = "_stdout.log"
STDERR_SUFFIX = "_stderr.log"

BENCHMARK_COUNT = 5
BENCHMARK_OUT_PREFIX = "benchmark_"

BENCHMARK_PERF_DATA = {
    "black-scholes" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Options per second: (?<val>\d+(\.\d+)?)/]],
    "cahn-hilliard" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (?<val>\d+(\.\d+)?) MCellUpdates\/s/]],
    "cholesky" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (?<val>\d+(\.\d+)?) GFLOPS/]],
    "floydwarshall" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (?<val>\d+(\.\d+)?) GOPS/]],
    "matmul" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (?<val>\d+(\.\d+)?) GFLOPS/]],
    "nbody" => [["time", /Simulation time: (?<val>\d+(\.\d+)?) ms/]],
    "qtclustering" => [["time", /Clustering time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (\d+(\.\d+)?) clusters\/s, (?<val>\d+(\.\d+)?) points\/s/]],
    "roomsim" => [
        ["precomp_time", /Precomputation time: (?<val>\d+(\.\d+)?) ms/], 
        ["sim_time", /Simulation time: (?<val>\d+(\.\d+)?) ms/], 
        ["dist_time" , /Distance computation time: (?<val>\d+(\.\d+)?) ms/], 
        ["tot_time", /Total computation time: (?<val>\d+(\.\d+)?) ms/],
    ],
    "spmv" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (?<val>\d+(\.\d+)?) GFLOPS\/s/]],
    "stencil3d" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (?<val>\d+(\.\d+)?) MCellUpdates\/s/]],
    "unstructured" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Elements\/sec: (?<val>\d+(\.\d+)?) GigaElements\/s/]],
}

def run_with_outputs_to_files(command, output_fn_prefix, timeout = nil)
    # use Capture3 to capture stdout and stderr separately, and write them to files with the given prefix
    stdout_fn = "#{output_fn_prefix}#{STDOUT_SUFFIX}"
    stderr_fn = "#{output_fn_prefix}#{STDERR_SUFFIX}"
    begin
        command = "timeout #{timeout} #{command}" if timeout
        stdout_str, stderr_str, status = Open3.capture3(command)
        File.write(stdout_fn, stdout_str)
        File.write(stderr_fn, stderr_str)
        return status.success?
    rescue => e
        File.write(stderr_fn, e.message)
        return false
    end
end

def build(src_dir, build_dir)
    FileUtils.mkdir_p(build_dir)
    Dir.chdir(build_dir) do
        ret = run_with_outputs_to_files("cmake #{src_dir} -B #{build_dir} -DCMAKE_BUILD_TYPE=Release", "cmake")
        raise "Configure failed for #{src_dir}. See #{File.join(build_dir, "cmake_*.log")} for details." unless ret
        ret = run_with_outputs_to_files("cmake --build #{build_dir} --target all --", "build")
        raise "Build failed for #{src_dir}. See #{File.join(build_dir, "build_*.log")} for details." unless ret
    end
end

def benchmark_to_executable(benchmark)
    return benchmark.gsub("-", "_")
end

def perform_validation_run(benchmark, build_dir)
    Dir.chdir(build_dir) do
        executable = benchmark_to_executable(benchmark)
        command = "./#{executable} #{VALIDATION_PARAMS} #{VALIDATION_SIZES[benchmark]}"
        ret = run_with_outputs_to_files(command, VALIDATION_FN, 300)
        raise ("Validation run failed for #{benchmark} in #{Dir.pwd}. Check #{VALIDATION_FN}*.log for details.\n" +
               "Command: #{command}") unless ret
    end
end

def get_reference_output(benchmark)
    ref_dir = REUSE_REFERENCE_DIR || File.join(VALIDATION_DIR, "reference", benchmark)
    validation_fn = File.join(ref_dir, VALIDATION_FN + STDOUT_SUFFIX)
    if !File.directory?(ref_dir) || !File.exist?(validation_fn)
        puts "Generating reference outputs for benchmark #{benchmark} in #{ref_dir}"
        build(File.expand_path(File.join(BENCH_SOURCE, benchmark)), ref_dir)
        perform_validation_run(benchmark, ref_dir)
    end
    return File.read(validation_fn)
end


Dir[File.join(EXPERIMENT_PATH, "*")].each do |entry|
    if File.directory?(entry)
        id_string = File.basename(entry)
        benchmark, model, par_type, run = id_string_to_infos(id_string)
        next unless par_type == "omp"
        
        this_validation_dir = File.join(VALIDATION_DIR, id_string)
        FileUtils.mkdir_p(this_validation_dir)
        puts "Validating #{id_string} (benchmark: #{benchmark}, model: #{model}, par_type: #{par_type}, run: #{run})"
        puts "  - Output to #{this_validation_dir}"
        
        # get reference outputs
        ref_output = get_reference_output(benchmark)

        validation_result_fn = File.join(this_validation_dir, VALIDATION_RESULT_FN)
        File.open(validation_result_fn, "w+") do |validation_result_file|

            # perform validation build
            begin
                build(File.join(entry, benchmark), this_validation_dir)
            rescue => e
                validation_result_file.puts "Error during validation build:\n#{e.message}"
                next
            end

            # perform validation run
            begin
                perform_validation_run(benchmark, this_validation_dir)
            rescue => e
                validation_result_file.puts "Error during validation run:\n#{e.message}"
                next
            end

            # check internal validation ("Validation: PASSED" in the output)
            validation_output = File.read(File.join(this_validation_dir, VALIDATION_FN + STDOUT_SUFFIX))
            if validation_output.include?("Validation: PASSED")
                validation_result_file.puts "Internal validation PASSED"
            else
                validation_result_file.puts "Internal validation FAILED"
                next
            end

            # compare output with reference output
            validation_result = validate(ref_output, validation_output)
            if validation_result[0]
                validation_result_file.puts "Validation PASSED:\n#{validation_result[1]}"
            else
                validation_result_file.puts "Validation FAILED:\n#{validation_result[1]}"
            end
        end
    end
    exit
    puts
end
