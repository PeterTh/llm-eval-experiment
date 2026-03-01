# aggregates information from the experiments, validation, benchmarking, and dependency analysis
# results in one aggregate dataset for analysis and plotting

require_relative "general"
require_relative "validation_class"

if !ARGV.any? { |arg| arg.start_with?("--exp=") } ||
   !ARGV.any? { |arg| arg.start_with?("--val=") } ||
   !ARGV.any? { |arg| arg.start_with?("--bench=") } ||
    ARGV.include?("--help") || ARGV.include?("-h")

    puts "Usage: ruby aggregate_evaluation.rb [options]"
    puts "Options:"
    puts "  --exp=PATH         Path to experiment output directory (required)"
    puts "  --val=PATH         Path to validation results directory (required)"
    puts "  --bench=PATH       Path to benchmark results directory (required)"
    exit
end

EXP_PATH = File.expand_path(ARGV.find { |arg| arg.start_with?("--exp=") }.split("=").last)
VAL_PATH = File.expand_path(ARGV.find { |arg| arg.start_with?("--val=") }.split("=").last)
BENCH_PATH = File.expand_path(ARGV.find { |arg| arg.start_with?("--bench=") }.split("=").last)

# validation status codes
VS_INVALID = 0
VS_PARALLELIZED = 1
VS_BUILDS = 2
VS_RUNS = 3
VS_INTERNALLY_VALID = 4
VS_FULLY_VALID = 5

class AggregateEvaluation
  attr_reader :benchmark, :model, :par_type, :run
  attr_accessor :input_tokens, :output_tokens, :cached_tokens
  attr_accessor :api_time, :total_time
  attr_accessor :code_additions, :code_deletions
  attr_accessor :non_whitelisted_dependencies
  attr_accessor :validation_status, :validation_err_string
  attr_accessor :benchmark_success, :benchmark_times, :benchmark_median_time

  def initialize(benchmark, model, par_type, run)
    @benchmark = benchmark
    @model = model
    @par_type = par_type
    @run = run
    @input_tokens = nil
    @output_tokens = nil
    @cached_tokens = nil
    @api_time = nil
    @total_time = nil
    @code_additions = nil
    @code_deletions = nil
    @non_whitelisted_dependencies = nil
    @validation_status = nil
    @validation_err_string = nil
    @benchmark_success = nil
    @benchmark_times = nil
    @benchmark_median_time = nil
  end
end

$results = {}

# output sample:
# API time spent:         2m 9.028s
# Total session time:     3m 3.195s
# Total code changes:     +77 -13
# Breakdown by AI model:
# claude-haiku-4.5        1.3m in, 11.3k out, 1.3m cached (Est. 0.33 Premium requests)

def read_output_file(id, result)
  output_fn = File.join(EXP_PATH, id, "output.txt")
  if !File.exist?(output_fn)
    raise "Expected output file not found for #{id} at #{output_fn}"
  end
  have_api_time, have_total_time = false, false
  have_code_changes = false
  have_token_breakdown = false
  File.readlines(output_fn).each do |line|
    if line =~ /API time spent:\s+(\d+(?:\.\d+)?h)?\s*(\d+(?:\.\d+)?m)?\s*(\d+(?:\.\d+)?s)/
      hours = $1 ? $1.to_i : 0
      minutes = $2 ? $2.to_i : 0
      seconds = $3.to_f
      result.api_time = hours * 3600 + minutes * 60 + seconds
      have_api_time = true
    elsif line =~ /Total session time:\s+(\d+(?:\.\d+)?h)?\s*(\d+(?:\.\d+)?m)?\s*(\d+(?:\.\d+)?s)/
      hours = $1 ? $1.to_i : 0
      minutes = $2 ? $2.to_i : 0
      seconds = $3.to_f
      result.total_time = hours * 3600 + minutes * 60 + seconds
      have_total_time = true
    elsif line =~ /Total code changes:\s+\+(\d+)\s+-(\d+)/
      result.code_additions = $1.to_i
      result.code_deletions = $2.to_i
      have_code_changes = true
    elsif line =~ /\s*[\w\-\.]+\s+(?:(\d+\.?\d*)m|(\d+\.?\d*)k|(\d+\.?\d*)) in,\s+(?:(\d+\.?\d*)m|(\d+\.?\d*)k|(\d+\.?\d*)) out,\s+(?:(\d+\.?\d*)m|(\d+\.?\d*|(\d+\.?\d*))k) cached/
      input_tokens = $1 ? ($1.to_f * 1_000_000) : ($2 ? ($2.to_f * 1_000) : $3.to_f)
      output_tokens = $4 ? ($4.to_f * 1_000_000) : ($5 ? ($5.to_f * 1_000) : $6.to_f)
      cached_tokens = $7 ? ($7.to_f * 1_000_000) : ($8 ? ($8.to_f * 1_000) : $9.to_f)
      result.input_tokens = input_tokens
      result.output_tokens = output_tokens
      result.cached_tokens = cached_tokens
      have_token_breakdown = true
    end
  end
  if !have_api_time || !have_total_time || !have_code_changes || !have_token_breakdown
    raise "Failed to parse all expected information from output file for #{id} at #{output_fn} - API time: #{have_api_time}, total time: #{have_total_time}, code changes: #{have_code_changes}, token breakdown: #{have_token_breakdown}"
  end
end

# gather basic information from experiment output directory

Dir[File.join(EXP_PATH, "*")].each do |exp_path|
  next unless File.directory?(exp_path)
  id = File.basename(exp_path)
  next unless is_id_string?(id)

  benchmark, model, par_type, run = id_string_to_infos(File.basename(exp_path))
  agg_eval = AggregateEvaluation.new(benchmark, model, par_type, run)
  $results[id] = agg_eval

  # read token and time information from experiment output
  output_fn = File.join(exp_path, "output.txt")
  if !File.exist?(output_fn)
    raise "Expected output file not found for #{id} at #{output_fn}"
  end

  read_output_file(id, agg_eval)
end

puts "Gathered basic information from output for #{$results.size} experiments"

# add dependency information form yaml file generated by check_generated_dependencies.rb

dependency_info_fn = File.join(EXP_PATH, "non_whitelisted_dependencies.yaml")
if !File.exist?(dependency_info_fn)
  raise "Expected dependency info file not found at #{dependency_info_fn}. Make sure to run check_generated_dependencies.rb and provide the correct --exp path."
end
dependency_info = YAML.safe_load(File.read(dependency_info_fn))
$results.each do |id, agg_eval|
  agg_eval.non_whitelisted_dependencies = dependency_info[id] || []
end

puts "Additional dependencies in #{$results.count { |_, agg_eval| agg_eval.non_whitelisted_dependencies.any? }} experiments"

# add validation information from validation results yaml file generated by validation.rb

validation_info_fn = File.join(VAL_PATH, "all_validation_results.yaml")
if !File.exist?(validation_info_fn)
  raise "Expected validation info file not found at #{validation_info_fn}. Make sure to run validation.rb and provide the correct --val path."
end
validation_info = YAML.safe_load(File.read(validation_info_fn), permitted_classes: [ValidationResult], aliases: true)
$results.each do |id, agg_eval|
  validation_result = validation_info.find { |vr| vr.is_for(agg_eval.benchmark, agg_eval.model, agg_eval.par_type, agg_eval.run) }
  if !validation_result
    raise "No validation result found for #{id} with benchmark #{agg_eval.benchmark}, model #{agg_eval.model}, par_type #{agg_eval.par_type}, run #{agg_eval.run} in validation info file #{validation_info_fn}"
  end
  agg_eval.validation_status = if validation_result.output_comparison
    VS_FULLY_VALID
  elsif validation_result.internal_validation
    VS_INTERNALLY_VALID
  elsif validation_result.validation_run
    VS_RUNS
  elsif validation_result.validation_build
    VS_BUILDS
  elsif validation_result.basic_para
    VS_PARALLELIZED
  else
    VS_INVALID
  end
  agg_eval.validation_err_string = validation_result.err_string
end

puts "Added validation results to #{$results.count { |_, agg_eval| agg_eval.validation_status }} experiments"

# add benchmark results from benchmark_full_results.yaml generated by gather_bench_results.rb

class Array
  def median
    raise "Cannot compute median of empty array" if self.empty?
    return self[0] if self.length == 1
    sorted = self.sort
    len = sorted.length
    return len.odd? ? sorted[len / 2] : (sorted[len / 2 - 1] + sorted[len / 2]) / 2.0
  end
end

benchmark_results_fn = File.join(BENCH_PATH, BENCHMARK_FULL_RESULTS_FN)
if !File.exist?(benchmark_results_fn)
  raise "Expected benchmark results file not found at #{benchmark_results_fn}. Make sure to run gather_bench_results.rb and provide the correct --bench path."
end
benchmark_results = YAML.safe_load(File.read(benchmark_results_fn))
$results.each do |id, agg_eval|
  if benchmark_results.key?(id)
    agg_eval.benchmark_success = benchmark_results[id][0]
    next if !agg_eval.benchmark_success
    agg_eval.benchmark_times = benchmark_results[id][1].map { |m| m["time"] }
    agg_eval.benchmark_median_time = agg_eval.benchmark_times.median
  end
end

puts "Added benchmark results to #{$results.count { |_, agg_eval| agg_eval.benchmark_success != nil }} experiments, #{$results.count { |_, agg_eval| agg_eval.benchmark_success == true }} of which were successful"

# output all the information to a csv file for analysis and plotting

require "csv"

out_csv_fn = File.join(EXP_PATH, "aggregate_results.csv")
CSV.open(out_csv_fn, "w") do |csv|
  csv << ["benchmark", "model", "par_type", "run", "input_tokens", "output_tokens", "cached_tokens", "api_time", "total_time", "code_additions", "code_deletions", "non_whitelisted_dependencies", "validation_status", "validation_err_string", "benchmark_success", "benchmark_times", "benchmark_median_time"]
  $results.each do |id, agg_eval|
    csv << [
      agg_eval.benchmark,
      agg_eval.model,
      agg_eval.par_type,
      agg_eval.run,
      agg_eval.input_tokens,
      agg_eval.output_tokens,
      agg_eval.cached_tokens,
      agg_eval.api_time,
      agg_eval.total_time,
      agg_eval.code_additions,
      agg_eval.code_deletions,
      agg_eval.non_whitelisted_dependencies.join(";"),
      agg_eval.validation_status,
      agg_eval.validation_err_string.gsub("\n", " ").gsub("\r", ""),
      agg_eval.benchmark_success,
      agg_eval.benchmark_times ? agg_eval.benchmark_times.join(";") : nil,
      agg_eval.benchmark_median_time
    ]
  end
end

puts "Wrote aggregate results to #{out_csv_fn}"
