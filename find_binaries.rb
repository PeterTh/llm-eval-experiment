# helper to find valid binaries for a given benchmark / par type

require_relative "general"
require_relative "validation_class"

if ARGV.include?("-h") || ARGV.include?("--help") || 
    !ARGV.any? { |arg| arg.start_with?("--validation-dir=") }
    puts "Usage: ruby find_binaries.rb [options]"
    puts "Options:"
    puts "  --validation-dir=DIR    Directory where validation builds are stored (required)"
    puts "  --bench=BENCHMARK       Benchmark to find binaries for (optional, substring)"
    puts "  --par=PAR_TYPE          Parallelization type to find binaries for (optional, substring)"
    exit
end

VALIDATION_DIR = ARGV.find { |arg| arg.start_with?("--validation-dir=") }.split("=").last
BENCHMARK_FILTER = ARGV.find { |arg| arg.start_with?("--bench=") }&.split("=").last
PAR_TYPE_FILTER = ARGV.find { |arg| arg.start_with?("--par=") }&.split("=").last

# load validation results
ALL_VALIDATION_RESULTS_FN = File.join(VALIDATION_DIR, "all_validation_results.yaml")
$all_validation_results = 
    YAML.safe_load(File.read(ALL_VALIDATION_RESULTS_FN), permitted_classes: [ValidationResult], aliases: true) || []

$all_validation_results.each do |result|
    next if BENCHMARK_FILTER && !result.benchmark.include?(BENCHMARK_FILTER)
    next if PAR_TYPE_FILTER && !result.par_type.include?(PAR_TYPE_FILTER)

    if result.output_comparison
        # build the path to the binary
        binary_path = File.join(VALIDATION_DIR, result.id_string, benchmark_to_executable(result.benchmark))
        if File.exist?(binary_path)
            puts File.expand_path(binary_path)
        end
    end
end