# this script continues submitting validation runs with timeouts until all validations are done

require_relative "general"

if ARGV.include?("-h") || ARGV.include?("--help") || 
        !ARGV.any? { |arg| arg.start_with?("--exp=") } ||
        !ARGV.any? { |arg| arg.start_with?("--validation-dir=") } ||
        !ARGV.any? { |arg| arg.start_with?("--account=") }
    puts "Usage: ruby validation_orchestration.rb [options]"
    puts "Options:"
    puts "  --exp=EXPERIMENT_PATH       Path to the experiment results to validate (required)"
    puts "  --validation-dir=DIR        Directory to use for validation builds and outputs (required, incrementally continues)"
    puts "  --account=ACCOUNT  Slurm account to use for allocations (required)"
    exit
end

EXPERIMENT_PATH = ARGV.find { |arg| arg.start_with?("--exp=") }.split("=").last
VALIDATION_DIR = ARGV.find { |arg| arg.start_with?("--validation-dir=") }.split("=").last
ACCOUNT = ARGV.find { |arg| arg.start_with?("--account=") }.split("=").last

TIMEOUT = 26 # 26 minutes, to be safe with the 30 minute Slurm limit

VALIDATION_COMMAND = "ruby validation.rb --exp=#{EXPERIMENT_PATH} --full-stats --validation-dir=#{VALIDATION_DIR} --timeout=#{TIMEOUT}"
SRUN_COMMAND = "srun --account #{ACCOUNT} --partition boost_usr_prod --ntasks=1 --nodes=1 --ntasks-per-node=1 --cpus-per-task=32 --gres=gpu:4 #{VALIDATION_COMMAND}"

loop do
    system(SRUN_COMMAND)
    exit_code = $?.exitstatus
    if exit_code == 0
        puts "Validation completed successfully for experiment #{EXPERIMENT_PATH}"
        break
    elsif exit_code == OUT_OF_TIME_EXIT_CODE
        puts "Validation script ran out of time for experiment #{EXPERIMENT_PATH}, re-running to continue validation"
    else
        raise "Validation script failed with exit code #{exit_code} for experiment #{EXPERIMENT_PATH}"
    end
end
