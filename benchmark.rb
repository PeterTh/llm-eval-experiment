# runs benchmarks for all successfully validated experiments of a given parallelization type
# generally invoked from benchmark_orchestration.rb, which handles SLURM provisioning

require_relative "general"

TIMEOUT = 25 * 60 # 25 minutes, to be safe with the 30 minute Slurm limit
START_TIME = Time.now

VALIDATION_PATH = ARGV.find { |arg| arg.start_with?("--val=") }&.split("=")&.last
JOB_ID = ARGV.find { |arg| arg.start_with?("--job-id=") }&.split("=")&.last
PAR_TYPE = ARGV.find { |arg| arg.start_with?("--par-type=") }&.split("=")&.last

TIMESTAMP = Time.now.strftime("%Y%m%d-%H%M%S")
BENCHMARK_DIR_DEFAULT = File.join(File.expand_path("~/llm_para_benchmark/"), "#{TIMESTAMP}")
BENCHMARK_DIR = ARGV.find { |arg| arg.start_with?("--bench-dir=") }&.split("=")&.last || BENCHMARK_DIR_DEFAULT

BENCH_FILTER = ARGV.find { |arg| arg.start_with?("--filter=") }&.split("=")&.last

if VALIDATION_PATH.nil? || JOB_ID.nil? || PAR_TYPE.nil? || ARGV.include?("--help") || ARGV.include?("-h")
    puts "Usage: ruby benchmark.rb [options]"
    puts "Options:"
    puts "  --val=PATH         Validation path (required; validation must already have been run)"
    puts "  --job-id=ID        Slurm job ID to use for srun commands (required)"
    puts "  --par-type=TYPE    Parallelization type to benchmark (required, can be omp, cuda, mpi, hybrid)"
    puts "                     !! job-id must match a job ready for the given par-type"
    puts "  --bench-dir=PATH   Directory to store benchmark results (default: #{BENCHMARK_DIR_DEFAULT})"
    puts "  --filter=NAME      Filter benchmarks to run (default: all; substring match on benchmark name)"
    exit
end

# parameters and timeouts per-par-type and per-benchmark
BENCHMARK_PARAMS = {
    PAR_OMP => {
        "matmul" => [" -n 3072", 10],
        "black-scholes" => ["-n 100000000", 5],
        "unstructured" => [" -n 5000 -i 50", 10],
        "cahn-hilliard" => [" -x 512 -i 30", 10],
        "spmv" => [" -n 30000 -s 40 -i 200", 20],
        "stencil3d" => [" -x 768 -i 20", 10],
        "floydwarshall" => [" -n 4096", 10],
        "nbody" => [" -n 20000 -s 100", 10],
        "cholesky" => [" -n 3072", 50],
        "qtclustering" => [" -n 2200", 10],
        "roomsim" => [" -n 5120 -t 500", 30]
    },
    PAR_CUDA => {
        "matmul" => [" -n 8192", 5],
        "black-scholes" => ["-n 100000000", 15],
        "unstructured" => [" -n 6000 -i 50", 10],
        "cahn-hilliard" => [" -x 1024 -i 30", 15],
        "spmv" => [" -n 30000 -s 40 -i 10000", 20],
        "stencil3d" => [" -x 800 -i 100", 15],
        "floydwarshall" => [" -n 8192", 10],
        "nbody" => [" -n 40000 -s 200", 10],
        "cholesky" => [" -n 3072", 50],
        "qtclustering" => [" -n 4000", 30],
        "roomsim" => [" -n 5120 -t 1000", 30]
    },
    PAR_MPI => {
        "matmul" => [" -n 6144", 20],
        "black-scholes" => ["-n 100000000", 20],
        "unstructured" => [" -n 8000 -i 50", 20],
        "cahn-hilliard" => [" -x 1200 -i 30", 20],
        "spmv" => [" -n 40000 -s 40 -i 1000", 50],
        "stencil3d" => [" -x 800 -i 100", 20],
        "floydwarshall" => [" -n 8192", 20],
        "nbody" => [" -n 40000 -s 100", 20],
        "cholesky" => [" -n 3072", 50],
        "qtclustering" => [" -n 4000", 30],
        "roomsim" => [" -n 5120 -t 1000", 30]
    },
    PAR_HYBRID => {
        "matmul" => [" -n 16384", 10],
        "black-scholes" => ["-n 400000000", 10],
        "unstructured" => [" -n 10000 -i 200", 30],
        "cahn-hilliard" => [" -x 2000 -i 30", 20],
        "spmv" => [" -n 40000 -s 40 -i 5000", 50],
        "stencil3d" => [" -x 1400 -i 100", 20],
        "floydwarshall" => [" -n 10240", 20],
        "nbody" => [" -n 50000 -s 200", 20],
        "cholesky" => [" -n 4096", 50],
        "qtclustering" => [" -n 5000", 40],
        "roomsim" => [] # no valid configurations
    },
}

BENCHMARK_COUNT = 5
BENCHMARK_OUT_PREFIX = "benchmark_"

BENCHMARK_RESULTS_FN = "benchmark_results.yaml"

BENCHMARK_PERF_DATA = {
    "black-scholes" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Options per second: (?<val>\d+(\.\d+)?)/]],
    "cahn-hilliard" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (?<val>\d+(\.\d+)?) MCellUpdates\/s/]],
    "cholesky" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (?<val>\d+(\.\d+)?) GFLOPS/]],
    "floydwarshall" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (?<val>\d+(\.\d+)?) GOPS/]],
    "matmul" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (?<val>\d+(\.\d+)?) GFLOPS/]],
    "nbody" => [["time", /Simulation time: (?<val>\d+(\.\d+)?) ms/]],
    "qtclustering" => [["time", /Clustering time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (\d+(\.\d+)?) clusters\/s, (?<val>\d+(\.\d+)?) points\/s/]],
    "roomsim" => [
        ["time", /Total computation time: (?<val>\d+(\.\d+)?) ms/],
        ["precomp_time", /Precomputation time: (?<val>\d+(\.\d+)?) ms/],
        ["sim_time", /Simulation time: (?<val>\d+(\.\d+)?) ms/],
        ["dist_time" , /Distance computation time: (?<val>\d+(\.\d+)?) ms/],
    ],
    "spmv" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (?<val>\d+(\.\d+)?) GFLOPS\/s/]],
    "stencil3d" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Performance: (?<val>\d+(\.\d+)?) MCellUpdates\/s/]],
    "unstructured" => [["time", /Computation time: (?<val>\d+(\.\d+)?) ms/], ["throughput", /Elements\/sec: (?<val>\d+(\.\d+)?) GigaElements\/s/]],
}

# helpers

def command_env(par_type)
    case par_type
    when PAR_OMP
        return { "OMP_NUM_THREADS" => "32" }
    when PAR_CUDA
        return { }
    when PAR_MPI
        return { }
    when PAR_HYBRID
        return { "OMP_NUM_THREADS" => "8" }
    else
        raise "Unknown parallelization type: #{par_type}"
    end
end

def command_srun(par_type)
    case par_type
    when PAR_OMP
        return "srun --jobid=%JOBID% --ntasks=1 --nodes=1 --ntasks-per-node=1 --cpus-per-task=32"
    when PAR_CUDA
        return "srun --jobid=%JOBID% --ntasks=1 --nodes=1 --ntasks-per-node=1 --cpus-per-task=32 --gres=gpu:4"
    when PAR_MPI
        return "srun --jobid=%JOBID% --ntasks=128 --nodes=4 --ntasks-per-node=32 --cpus-per-task=1"
    when PAR_HYBRID
        return "srun --jobid=%JOBID% --nodes=4 --ntasks-per-node=4 --cpus-per-task=8 --gpus-per-task=1"
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
        bench_params, timeout = BENCHMARK_PARAMS[par_type][benchmark]
        output_fn_prefix = File.join(bench_path, "#{BENCHMARK_OUT_PREFIX}#{i}")
        slurm_command = command_srun(par_type).gsub("%JOBID%", JOB_ID)
        command = "#{slurm_command} #{executable_path} #{bench_params}"
        env = command_env(par_type)
        success = run_with_outputs_to_files(command, output_fn_prefix, timeout, env)
        if !success
            return false
        end
    end
    return true
end

# preparation

FileUtils.mkdir_p(BENCHMARK_DIR)

$benchmark_results = {}
# load existing benchmark results if they exist (to avoid rerunning benchmarks that have already been run)
existing_results_fn = File.join(BENCHMARK_DIR, BENCHMARK_RESULTS_FN)
if File.exist?(existing_results_fn)
    $benchmark_results = YAML.safe_load(File.read(existing_results_fn)) || {}
    puts "Reusing existing benchmark results from #{existing_results_fn}, #{$benchmark_results.size} entries"
else 
    puts "No existing benchmark results found at #{existing_results_fn}, starting fresh"
end

# benchmarking loop

Dir[File.join(VALIDATION_PATH, "*")].each do |entry|
    if File.directory?(entry)
        if Time.now > START_TIME + TIMEOUT 
            puts "Timeout - stopping this set of benchmarks"
            # signal that we ran out of time 
            exit OUT_OF_TIME_EXIT_CODE
        end

        id_string = File.basename(entry)
        next unless is_id_string?(id_string)
        next if $benchmark_results.key?(id_string) # skip if we already have results for this configuration

        benchmark, model, par_type, run = id_string_to_infos(id_string)
        next if par_type != PAR_TYPE # skip if this is not the parallelization type we want to benchmark

        next if BENCH_FILTER && !benchmark.include?(BENCH_FILTER) # skip if benchmark doesn't match filter

        print "%-16s | %-21s | %-6s | r%d" % [benchmark, model, par_type, run]

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

        # save new results after each benchmark to avoid losing progress
        $benchmark_results[id_string] = success
        File.write(existing_results_fn, YAML.dump($benchmark_results))
    end
end

# this signals that we are done with all benchmarks of the given par_type
# (as opposed to stopping due to timeout or other issues), which is useful for the orchestration script
exit 0