require_relative "general"

VALIDATION_PATH = ARGV.find { |arg| arg.start_with?("--val=") }&.split("=")&.last

TIMESTAMP = Time.now.strftime("%Y%m%d-%H%M%S")
BENCHMARK_DIR_DEFAULT = File.join(File.expand_path("~/llm_para_benchmark/"), "#{TIMESTAMP}")
BENCHMARK_DIR = ARGV.find { |arg| arg.start_with?("--bench-dir=") }&.split("=")&.last || BENCHMARK_DIR_DEFAULT

if VALIDATION_PATH.nil? || ARGV.include?("--help") || ARGV.include?("-h")
    puts "Usage: ruby benchmark.rb [options]"
    puts "Options:"
    puts "  --val=PATH         Validation path (required; validation must already have been run)"
    puts "  --bench-dir=PATH   Directory to store benchmark results (default: #{BENCHMARK_DIR_DEFAULT})"
    exit
end

BENCHMARK_SIZES = {
    PAR_OMP => {
        "black-scholes" => "-n 20000000",
        "cahn-hilliard" => "-x 128 -y 128 -z 128 -i 100",
        "cholesky" => "-n 2048",
        "floydwarshall" => "-n 2048",
        "matmul" => "-n 2048",
        "nbody" => "-n 20000 -s 100",
        "qtclustering" => "-n 10000",
        "roomsim" => "-n 512 -t 500",
        "spmv" => "-n 32000 -s 100 -i 100",
        "stencil3d" => "-x 128 -y 128 -z 128 -i 100",
        "unstructured" => "-n 512 -i 100"
    },
}

BENCHMARK_COUNT = 5
BENCHMARK_OUT_PREFIX = "benchmark_"

BENCHMARK_TIMEOUT = 60 # seconds

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

# helpers

def command_env(par_type)
    case par_type
    when PAR_OMP
        return { "OMP_NUM_THREADS" => "64" }
    when PAR_CUDA
        return { "CUDA_VISIBLE_DEVICES" => "0" }
    when PAR_MPI
        raise "TODO"
    when PAR_HYBRID
        raise "TODO"
    else
        raise "Unknown parallelization type: #{par_type}"
    end
end

def run_benchmark(executable_path, id, benchmark, par_type)
    # create working directory for the benchmark
    bench_path = File.join(BENCHMARK_DIR, id)
    FileUtils.mkdir_p(bench_path)
    # run the benchmark and capture output
    BENCHMARK_COUNT.times do |i|
        output_fn_prefix = File.join(bench_path, "#{BENCHMARK_OUT_PREFIX}#{i}")
        command = "#{executable_path} #{BENCHMARK_SIZES[par_type][benchmark]}"
        env = command_env(par_type)
        success = run_with_outputs_to_files(command, output_fn_prefix, BENCHMARK_TIMEOUT, env)
        if !success
            return false
        end
    end
    return true
end

# preparation

FileUtils.mkdir_p(BENCHMARK_DIR)

# benchmarking loop

Dir[File.join(VALIDATION_PATH, "*")].each do |entry|
    if File.directory?(entry)
        id_string = File.basename(entry)
        next unless is_id_string?(id_string)
        benchmark, model, par_type, run = id_string_to_infos(id_string)

        next if par_type != PAR_OMP # TEMPORARY for testing only benchmark OMP versions;
        next if benchmark != "nbody" # TEMPORARY for testing only benchmark nbody

        print "%-16s | %-12s | %-6s | r%d" % [benchmark, model, par_type, run]

        validation_summary = File.read(File.join(entry, VALIDATION_RESULT_FN))
        if !validation_summary.include?("Output comparison PASSED")
            puts " - ❌ Validation failed, skipping"
            next
        end

        executable_path = File.join(entry, benchmark_to_executable(benchmark))
        if !File.exist?(executable_path)
            puts " - ❌ Executable not found at #{executable_path}, skipping"
            next
        end

        success = run_benchmark(executable_path, id_string, benchmark, par_type)
        if success
            print " - ✅"
        else
            print " - ❌"
        end
        puts " -> #{File.join(BENCHMARK_DIR, id_string)}"
    end
end