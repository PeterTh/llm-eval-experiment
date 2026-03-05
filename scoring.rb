# this takes the output from aggregate_evaluation.rb, as well as the benchmark scoring matrix, and produces a final score for each experiment

require_relative "general"
require_relative "general_evaluation"

if !ARGV.any? { |arg| arg.start_with?("--scoring=") } ||
   !ARGV.any? { |arg| arg.start_with?("--bench-dir=") } ||
    ARGV.include?("--help") || ARGV.include?("-h")
  
  puts "Usage: ruby scoring.rb [options]"
  puts "Options:"
  puts "  --scoring=PATH     Path to benchmark scoring matrix csv file (required)"
  puts "  --bench-dir=PATH   Path to benchmark results directory (required)"
  exit
end

SCORING_FN = File.expand_path(ARGV.find { |arg| arg.start_with?("--scoring=") }.split("=").last)
BENCH_DIR = File.expand_path(ARGV.find { |arg| arg.start_with?("--bench-dir=") }.split("=").last)

# read scoring matrix
$scoring_matrix = {}
CSV.foreach(SCORING_FN, headers: true, header_converters: ->(f) { f&.strip }, converters: ->(f) { f&.strip }) do |row|
  bench = row["bench"]
  type = row["type"]
  top = row["top"].to_f
  great = row["great"].to_f
  good = row["good"].to_f
  $scoring_matrix[bench] ||= {} 
  $scoring_matrix[bench][type] = { top: top, great: great, good: good }
end

# read aggregate evaluation results

aggregate_results_fn = File.join(BENCH_DIR, "aggregate_results.yaml")
if !File.exist?(aggregate_results_fn)
  raise "Expected aggregate results file not found at #{aggregate_results_fn}"
end
$all_results = YAML.safe_load(File.read(aggregate_results_fn), permitted_classes: [AggregateEvaluation])

# find the fastest median time for each benchmark and par_type across all experiments, to be used for scoring
$fastest_times = {}
$all_results.each do |id, result|
  next unless result.benchmark_success
  bench = result.benchmark
  par_type = result.par_type
  time = result.benchmark_median_time
  $fastest_times[bench] ||= {}
  if !$fastest_times[bench][par_type] || time < $fastest_times[bench][par_type]
    $fastest_times[bench][par_type] = time
  end
end

# compute overall scores based on validation score, benchmark results, and the scoring matrix

$all_results.each do |id, result|
  benchmark = result.benchmark
  par_type = result.par_type

  score = result.validation_status # 0 to 5 based on validation
  if result.benchmark_success
    # fastest gets 5 extra points, top get 4, great get 3, good get 2, else 1 point, based on scoring matrix thresholds
    fastest_time = $fastest_times[benchmark][par_type]
    time = result.benchmark_median_time
    if time == fastest_time
      score += 5
      #puts "#{benchmark} / #{par_type} top result: #{id}"
    elsif time <= $scoring_matrix[benchmark][par_type][:top]
      score += 4
    elsif time <= $scoring_matrix[benchmark][par_type][:great]
      score += 3
    elsif time <= $scoring_matrix[benchmark][par_type][:good]
      score += 2
    else
      score += 1
    end
  end
  result.overall_score = score
end

# output final complete scored data to csv file for analysis and plotting
out_csv_fn = File.join(BENCH_DIR, "scored_results.csv")
CSV.open(out_csv_fn, "w") do |csv|
  csv << ["benchmark", "model", "par_type", "run", "input_tokens", "output_tokens", "cached_tokens", "api_time", "total_time", "code_additions", "code_deletions", "non_whitelisted_dependencies", "validation_status", "validation_err_string", "benchmark_success", "benchmark_times", "benchmark_median_time", "overall_score"]
  $all_results.each do |id, agg_eval|
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
      agg_eval.benchmark_median_time,
      agg_eval.overall_score
    ]
  end
end

puts "Stored final scored results in #{out_csv_fn}"

