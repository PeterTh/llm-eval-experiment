# this script is responsible for providing slurm allocations necessary for the main benchmark script

require_relative "general"

if ARGV.include?("-h") || ARGV.include?("--help") || 
        !ARGV.any? { |arg| arg.start_with?("--bench-dir=") } ||
        !ARGV.any? { |arg| arg.start_with?("--val=") } ||
        !ARGV.any? { |arg| arg.start_with?("--account=") }
    puts "Usage: ruby benchmark_orchestration.rb [options]"
    puts "Options:"
    puts "  --bench-dir=PATH   Directory to store benchmark results (required)"
    puts "  --val=DIR         Directory where validation builds are stored (required)"
    puts "  --account=ACCOUNT  Slurm account to use for allocations (required)"
    puts "  --par-type=TYPE   Parallelization type to benchmark (optional, default all, can be omp, cuda, mpi, hybrid)"
    exit
end

# required parameters
BENCHMARK_DIR = ARGV.find { |arg| arg.start_with?("--bench-dir=") }.split("=").last
VALIDATION_PATH = ARGV.find { |arg| arg.start_with?("--val=") }.split("=").last
ACCOUNT = ARGV.find { |arg| arg.start_with?("--account=") }.split("=").last

# optional parameters
PAR_TYPE = ARGV.find { |arg| arg.start_with?("--par-type=") }&.split("=")&.last

ALLOCATION_CALLS= {
    PAR_OMP => "salloc --no-shell --account #{ACCOUNT} --partition boost_usr_prod --ntasks=1 --nodes=1 --ntasks-per-node=1 --cpus-per-task=32 --gres=gpu:4",
    PAR_CUDA => "salloc --no-shell --account #{ACCOUNT} --partition boost_usr_prod --ntasks=1 --nodes=1 --ntasks-per-node=1 --cpus-per-task=32 --gres=gpu:4",
    PAR_MPI => "salloc --no-shell --account #{ACCOUNT} --partition boost_usr_prod --ntasks=128 --nodes=4 --ntasks-per-node=32 --cpus-per-task=1",
    PAR_HYBRID => "salloc --no-shell --account #{ACCOUNT} --partition boost_usr_prod --nodes=4 --ntasks-per-node=4 --cpus-per-task=8 --gpus-per-task=1 --gres=gpu:4"
}

def request_allocation(par_type)
    allocation_command = ALLOCATION_CALLS[par_type]
    puts "Requesting Slurm allocation with command: #{allocation_command}"
    stdout_str, stderr_str, status = Open3.capture3(allocation_command)
    if status.success?
        print "Allocation successful. "
        out_str = stdout_str + stderr_str
        # sanity check - the allocation should not be relinquished immediately, and we should get a job ID in the output
        if out_str.include?("Relinquishing")
            puts "However, the allocation was relinquished immediately, which indicates a problem. Output was:\n#{stdout_str}\n---- stderr was:\n#{stderr_str}\n----"
            raise "Slurm allocation was relinquished immediately, likely due to an issue with the allocation request"
        end
        # extract job ID
        job_id_match = out_str.match(/salloc: Granted job allocation (\d+)/)
        if job_id_match
            job_id = job_id_match[1]
            puts "Extracted Job ID: #{job_id}"
            return job_id
        else
            puts "Failed to extract Job ID from salloc output:\n#{stdout_str}\n---- stderr was:\n#{stderr_str}\n----"
            raise "Failed to extract Job ID from salloc output"
        end
    else
        puts "Allocation failed - output:\n#{stdout_str}\n---- stderr was:\n#{stderr_str}\n----"
        raise "Slurm allocation failed"
    end
end

def cancel_allocation(job_id)
    cancel_command = "scancel #{job_id}"
    Open3.capture3(cancel_command)
    if $?.success?
        puts "Cancelled Slurm allocation with Job ID: #{job_id}"
    else
        puts "Failed to cancel Slurm allocation with Job ID: #{job_id} (might already be cancelled or finished)"
    end
end

# main orchestration logic

PAR_TYPES_TO_RUN = PAR_TYPE ? [PAR_TYPE] : PARALLELIZATION_TYPES

PAR_TYPES_TO_RUN.each do |par_type|
    # loop current PAR_TYPE until return value is 0 (finished) and not OUT_OF_TIME_EXIT_CODE (ran out of time), then move to the next PAR_TYPE
    # show the output of the benchmark script in real time
    loop do
        job_id = request_allocation(par_type)
        # run the benchmark script with the given allocation and parameters
        benchmark_command = "ruby benchmark.rb --val=#{VALIDATION_PATH} --job-id=#{job_id} --par-type=#{par_type} --bench-dir=#{BENCHMARK_DIR}"
        puts "========================= Running benchmark command:\n ==== #{benchmark_command}"
        system(benchmark_command)
        exit_code = $?.exitstatus
        if exit_code == 0
            puts "Benchmark script finished successfully for PAR_TYPE=#{par_type}"
            cancel_allocation(job_id)
            break
        elsif exit_code == OUT_OF_TIME_EXIT_CODE
            puts "Benchmark script ran out of time for PAR_TYPE=#{par_type}, requesting new allocation and retrying..."
            cancel_allocation(job_id)
        else
            raise "Benchmark script failed with exit code #{exit_code} for PAR_TYPE=#{par_type}"
        end
    end
end

puts "All benchmarks completed for all requested parallelization types."