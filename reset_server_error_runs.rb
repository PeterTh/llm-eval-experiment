# resets runs that failed due to server errors
# they will then automatically be re-run in the next experiment invocation

require_relative "general"

ERROR_STRING = "Response was interrupted due to a server error"
FAIL_STRING = "Execution failed: Error: Failed to get response from the AI model"

if !ARGV.any? { |arg| arg.start_with?("--timestamp=") } || ARGV.include?("-h") || ARGV.include?("--help")
  puts "Usage: ruby reset_server_error_runs.rb --timestamp=TIMESTAMP [--run]"
  puts "  --timestamp=TIMESTAMP: specify the timestamp for the run to process, e.g. 20240601-120000"
  puts "  --run: actually perform the reset (otherwise, dry run that only prints the runs that would be reset)"
  exit
end

TIMESTAMP = ARGV.find { |arg| arg.start_with?("--timestamp=") }.split("=").last
EVAL_TARGET_DIR = File.join(Dir.home, "llm_para_experiments", "#{TIMESTAMP}")

if !Dir.exist?(EVAL_TARGET_DIR)
  puts "Error: target directory #{EVAL_TARGET_DIR} does not exist."
  exit
end

recovered_runs = []
failed_runs = []

Dir[File.join(EVAL_TARGET_DIR, "*")].each do |dir|
    id_string = File.basename(dir)
    next unless is_id_string?(id_string)

    log_file = File.join(dir, "output.txt")
    raise "Log file not found for run #{id_string}" unless File.exist?(log_file)

    log_content = File.read(log_file)
    if log_content.include?(FAIL_STRING)
        failed_runs << id_string
    elsif log_content.include?(ERROR_STRING)
        recovered_runs << id_string
    end
end

puts "Runs which had an error but recovered: #{recovered_runs.size} - #{recovered_runs.join(", ")}"
puts "Failed runs: #{failed_runs.size} - #{failed_runs.join(", ")}"

FAIL_DIR = File.join(EVAL_TARGET_DIR, "failed")
FileUtils.mkdir_p(FAIL_DIR)

if ARGV.include?("--run")
    failed_runs.each do |id_string|
        dir = File.join(EVAL_TARGET_DIR, id_string)
        attempt_id = 0
        fail_dir = File.join(FAIL_DIR, id_string +"_f#{attempt_id}")
        while Dir.exist?(fail_dir)
            attempt_id += 1
            fail_dir = File.join(FAIL_DIR, id_string +"_f#{attempt_id}")
        end
        FileUtils.mv(dir, fail_dir)
        puts "Moved failed run #{id_string} to #{fail_dir}"
    end
end