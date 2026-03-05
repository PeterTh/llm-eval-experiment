require 'fileutils'
require 'open3'
require 'yaml'
require 'csv'

PAR_OMP = "omp"
PAR_CUDA = "cuda"
PAR_MPI = "mpi"
PAR_HYBRID = "hybrid"

PARALLELIZATION_TYPES = [PAR_OMP, PAR_CUDA, PAR_MPI, PAR_HYBRID]

VALIDATION_RESULT_FN = "validation_result.txt"

STDOUT_SUFFIX = "_stdout.log"
STDERR_SUFFIX = "_stderr.log"

OUT_OF_TIME_EXIT_CODE = 7

BENCHMARK_COUNT = 5
BENCHMARK_OUT_PREFIX = "benchmark_"
BENCHMARK_RESULTS_FN = "benchmark_results.yaml"
BENCHMARK_FULL_RESULTS_FN = "benchmark_full_results.yaml"

# general helper functions ################################################################################################################

# id/string related

def run_id_string(benchmark, model, par_type, run)
    return "#{benchmark}_#{model}_#{par_type}_r#{run}"
end

def is_id_string?(str)
    # check if the string has the format benchmark_model_par_type_rX, where X is a number
    return !!(str =~ /^[a-zA-Z0-9\-\.]+_[a-zA-Z0-9\-\.]+_[a-z]+_r\d+$/)
end

def id_string_to_infos(id_string)
    # id string format: benchmark_model_par_type_rX
    parts = id_string.split("_")
    benchmark = parts[0]
    model = parts[1]
    par_type = parts[2]
    run = parts[3][1..-1].to_i # remove 'r' and convert to int
    return benchmark, model, par_type, run
end

def benchmark_to_executable(benchmark)
    return benchmark.gsub("-", "_") # benchmarks with dashes in their id have underscores in their source and executable names
end

# running/building related

def run_with_outputs_to_files(command, output_fn_prefix, timeout = nil, env = {})
    # use Capture3 to capture stdout and stderr separately, and write them to files with the given prefix
    stdout_fn = "#{output_fn_prefix}#{STDOUT_SUFFIX}"
    stderr_fn = "#{output_fn_prefix}#{STDERR_SUFFIX}"
    command_fn = "#{output_fn_prefix}_command.log"
    exitcode_fn = "#{output_fn_prefix}_exitcode.log"
    File.write(command_fn, command)
    begin
        command = "timeout #{timeout} #{command}" if timeout
        stdout_str, stderr_str, status = Open3.capture3(env, command)
        File.write(stdout_fn, stdout_str)
        File.write(stderr_fn, stderr_str)
        File.write(exitcode_fn, status.exitstatus.to_s)
        if timeout && status == 124 # timeout exit code
            File.write(stderr_fn, "Command timed out after #{timeout} seconds.")
        end
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
