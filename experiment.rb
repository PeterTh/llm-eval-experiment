require 'fileutils'

# General configuration / information

BENCHMARKS = [
    "black-scholes",
    "cahn-hilliard",
    "cholesky",
    "floydwarshall",
    "matmul",
    "nbody",
    "qtclustering",
    "roomsim",
    "spmv",
    "stencil3d",
    "unstructured"
]


MODELS = {"claude-sonnet-4.5":1,
          "claude-haiku-4.5":0.33,
          "claude-opus-4.6":3,
          "claude-opus-4.5":3,
          "claude-sonnet-4":1,
          "gemini-3-pro-preview":1,
          "gpt-5.2-codex":1,
          "gpt-5.2":1,
          "gpt-5.1-codex-max":1,
          "gpt-5.1-codex":1,
          "gpt-5.1":1,
          "gpt-5":1,
          "gpt-5.1-codex-mini":0.33,
          "gpt-5-mini":0,
          "gpt-4.1":0}

BASE_COST_PER_REQUEST = 0.04 # base cost in dollars for github copilot requests, to multiply with per-model cost factors

PARAMS = "--allow-all-paths --allow-all-tools --no-ask-user --no-color"

PAR_OMP = "omp"
PAR_CUDA = "cuda"
PAR_MPI = "mpi"
PAR_HYBRID = "hybrid"

PARALLELIZATION_TYPES = [PAR_OMP, PAR_CUDA, PAR_MPI, PAR_HYBRID]

INSTRUCTION_START = "Parallelize the %%1 benchmark code found in $$2 "

PAR_TYPE_INSTRUCTIONS = {
  PAR_OMP => "with OpenMP for multicore CPU shared memory parallelism.",
  PAR_CUDA => "with CUDA for GPU acceleration.",
  PAR_MPI => "with MPI for distributed cluster computing.",
  PAR_HYBRID => "with a hybrid approach combining MPI, OpenMP, and CUDA as appropriate for maximum performance on an accelerator cluster."
}

INSTRUCTION_END = 
"""
The program should be optimized for maximum performance and scalability, while maintaining correctness and equivalent semantics to the original code.
Change the code in the existing files only; do not create new files. Update CMakeLists as needed to ensure the code compiles and runs correctly.
Use no new external dependencies.
"""

EVAL_USER = "llmtest"
EVAL_ROOT = "/home/llmtest/evals"
BENCH_SOURCE = "../benchmarks"

COMMON_SOURCE = "common"

# Read command line arguments for testing mode, whether to continue an existing run, and whether to actually run ##############################################

TESTING = ARGV.include?("--production") ? false : true
DO_RUN = ARGV.include?("--run")
# syntax is --continue=timestamp, e.g. --continue=20240601-120000
CONTINUE_FROM = ARGV.find { |arg| arg.start_with?("--continue=") }&.split("=")&.last

if ARGV.include?("--help") || ARGV.include?("-h")
    puts "Usage: ruby experiment.rb [options]"
    puts "Options:"
    puts "  --production           Run the full experiment with all configurations (default is testing mode with limited configurations)"
    puts "  --continue=TIMESTAMP   Continue an existing experiment from the given timestamp (format: YYYYMMDD-HHMMSS)"
    puts "  --run                  Actually run the experiments (without this flag, the script will only print the planned experiments and estimated time/cost)"
    exit
end

puts "Running in #{TESTING ? "testing" : "production"} mode, with #{DO_RUN ? "actual runs" : "no runs (dry run)"} and #{CONTINUE_FROM ? "continuing from #{CONTINUE_FROM}" : "starting fresh"}."

# Evaluation configuration ####################################################################################################################################

if TESTING
    BENCHMARKS_TO_EVAL = ["black-scholes", "matmul", "nbody", "qtclustering"]
    MODELS_TO_EVAL = ["gpt-5-mini", "gpt-4.1"]
    PAR_TYPES_TO_EVAL = [PAR_OMP, PAR_CUDA]
    NUM_RUNS = 5
else
    BENCHMARKS_TO_EVAL = BENCHMARKS
    MODELS_TO_EVAL = ["claude-sonnet-4.5", "claude-haiku-4.5", "claude-opus-4.6", "gemini-3-pro-preview", "gpt-5.2-codex", "gpt-5.2", "gpt-5-mini"]
    PAR_TYPES_TO_EVAL = PARALLELIZATION_TYPES
    NUM_RUNS = 5
end

# Pre-experiment ##############################################################################################################################################

experiments_per_model = BENCHMARKS_TO_EVAL.size * PAR_TYPES_TO_EVAL.size * NUM_RUNS
$total_experiments = experiments_per_model * MODELS_TO_EVAL.size

puts "Total number of experiments to run: #{$total_experiments}"
total_cost = MODELS_TO_EVAL.map { |model| MODELS[model.to_sym] }.sum * BASE_COST_PER_REQUEST * experiments_per_model
puts "Estimated total cost of the experiment: #{total_cost.round(2)} USD"

TIMESTAMP = CONTINUE_FROM || Time.now.strftime("%Y%m%d-%H%M%S")
EVAL_DIR = File.join(EVAL_ROOT, "#{TIMESTAMP}")

# check correct configuration of benchmark folder
if BENCHMARKS_TO_EVAL.any? { |b| !File.directory?(File.join(BENCH_SOURCE, b)) }
    raise "One or more benchmark folders not found in #{BENCH_SOURCE}. Check the BENCHMARKS list and the BENCH_SOURCE."
end

# Experiment helpers ##########################################################################################################################################

def run_id_string(benchmark, model, par_type, run)
    return "#{benchmark}_#{model}_#{par_type}_r#{run}"
end

def prepare_folder(benchmark, model, par_type, run)
    id = run_id_string(benchmark, model, par_type, run)
    # Create a folder for the run
    bench_path = File.join(EVAL_DIR, id)
    FileUtils.mkdir_p(bench_path)
    # Copy sequential code of the benchmark to the folder
    FileUtils.cp_r(File.join(BENCH_SOURCE, benchmark), bench_path)
    FileUtils.cp_r(File.join(BENCH_SOURCE, COMMON_SOURCE), bench_path)
    return bench_path
end

$times = []

def eval_config(benchmark, model, par_type, run)
    id = run_id_string(benchmark, model, par_type, run)
    print "Evaluating configuration: #{id}"

    # if we have a timing file for this run already, skip it (for continuing existing runs)
    bench_path = File.join(EVAL_DIR, id)
    if File.exist?(File.join(bench_path, "timing.txt"))
        puts " - Timing file already exists, skipping run"
        return
    end

    # do this check afterwards so we can test the continue functionality without actually running the experiments
    if !DO_RUN
        puts " - Skipping actual run (dry run mode)"
        return
    end

    start_time = Time.now

    bench_path = prepare_folder(benchmark, model, par_type, run)
    # Generate the instruction for the LLM based on the parallelization type
    instruction = INSTRUCTION_START.gsub("%%1", benchmark).gsub("$$2", "./" + benchmark + "/")
    instruction += PAR_TYPE_INSTRUCTIONS[par_type]
    instruction += INSTRUCTION_END
    instruction.gsub!("\n", " ") # replace newlines with spaces for better handling in the command line
    Dir.chdir(bench_path) do
        # give the eval user access to the folder and its contents
        FileUtils.chmod_R(0777, ".")
        # switch to the eval user and run the copilot command; write output to file for later analysis
        copilot_command = "cd #{bench_path}; copilot #{PARAMS} --model #{model} -p \"#{instruction}\" > output.txt 2>&1"
        output = system("su - #{EVAL_USER} --shell=/bin/bash -c '#{copilot_command}'")
        # write instructions to file for later analysis
        File.write(File.join(bench_path, "instruction.txt"), instruction)
    end

    end_time = Time.now
    duration = end_time - start_time
    # write start time, end time and duration to file for later analysis
    File.write(File.join(bench_path, "timing.txt"), "Start time: #{start_time}\nEnd time: #{end_time}\nDuration: #{duration.round(2)} seconds\n")

    puts " - Done in #{duration.round(2)} seconds."

    $times << duration
    avg_time = $times.sum / $times.size
    remaining_experiments = $total_experiments - $times.size
    est_remaining_time = avg_time * remaining_experiments
    puts "Estimated remaining time: #{(est_remaining_time / 3600).round(2)} hours (#{remaining_experiments} experiments left)"
end

# Experiment ##################################################################################################################################################

NUM_RUNS.times do |run|
    PAR_TYPES_TO_EVAL.each do |par_type|
        MODELS_TO_EVAL.each do |model|
            BENCHMARKS_TO_EVAL.each do |benchmark|
                eval_config(benchmark, model, par_type, run+1)
            end
        end
    end
end
