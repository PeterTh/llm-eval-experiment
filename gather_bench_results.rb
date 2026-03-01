# gathers benchmark results (times, success/failure)

require_relative "general"

if !ARGV.any? { |arg| arg.start_with?("--bench=") } ||
    ARGV.include?("--help") || ARGV.include?("-h")
  puts "Usage: ruby gather_bench_results.rb [options]"
  puts "Options:"
  puts "  --bench=PATH       Path to benchmark results directory (required)"
  exit
end

BENCH_PATH = File.expand_path(ARGV.find { |arg| arg.start_with?("--bench=") }.split("=").last)

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

TIME_FALLBACKS = [/Computation time \(max.*?\): (?<val>\d+(\.\d+)?) ms/]
TIME_US_FALLBACKS = [/Computation time: (?<val>\d+(\.\d+)?) us/]
TIME_S_FALLBACKS = [/Computation time: (?<val>\d+(\.\d+)?) s/]

def gather_bench_results(id)
  file_path = File.join(BENCH_PATH, id)
  if !File.directory?(file_path)
    raise "Expected #{file_path} to be a directory"
  end
  benchmark, model, par_type, run = id_string_to_infos(id)

  metrics = []
  BENCHMARK_COUNT.times do |run|
    cur_metrics = {}
    out_fn = File.join(file_path, "#{BENCHMARK_OUT_PREFIX}#{run}_stdout.log")
    if !File.exist?(out_fn)
      raise "Expected output file #{out_fn} to exist for #{id}"
    end
    out_content = File.read(out_fn)
    perf_data = BENCHMARK_PERF_DATA[benchmark]
    if perf_data.nil?
      raise "No performance data regexes defined for benchmark #{benchmark}"
    end
    perf_data.each do |metric_name, regex|
      match = out_content.match(regex)
      if match.nil?
        # use time fallback if we were trying to get time
        if metric_name == "time"
          TIME_FALLBACKS.each do |fallback_regex|
            match = out_content.match(fallback_regex)
            if !match.nil?
              break
            end
          end
          # if we still don't have a match, try microsecond fallback
          TIME_US_FALLBACKS.each do |fallback_regex|
            match = out_content.match(fallback_regex)
            if !match.nil?              # convert microseconds to milliseconds
              match = {:val => (match[:val].to_f / 1000).to_s}
              break
            end
          end if match.nil?
          # if we still don't have a match, try second fallback
          TIME_S_FALLBACKS.each do |fallback_regex|
            match = out_content.match(fallback_regex)
            if !match.nil?              # convert seconds to milliseconds
              match = {:val => (match[:val].to_f * 1000).to_s}
              break
            end
          end if match.nil?
          if match.nil?
            raise "Could not find performance metric #{metric_name} in output for #{id} - file: #{out_fn}"
          end
        end
        # non-time metrics aren't critical, ignore if we can't find them
      end
      if !match.nil?
        val = match[:val].to_f
        cur_metrics[metric_name] = val
      end
    end
    metrics << cur_metrics
  end
  # sanity check: we should have at least a time metric for each run
  if metrics.empty?
    raise "No performance metrics found for #{id}"
  end
  
  return metrics
end

$success_results = {}
# load existing benchmark results if they exist (to avoid rerunning benchmarks that have already been run)
existing_results_fn = File.join(BENCH_PATH, BENCHMARK_RESULTS_FN)
if File.exist?(existing_results_fn)
    $success_results = YAML.safe_load(File.read(existing_results_fn)) || {}
    puts "Reusing existing benchmark results from #{existing_results_fn}, #{$success_results.size} entries"
else 
    puts "No existing benchmark results found at #{existing_results_fn}, starting fresh"
end

$bench_results = {}

Dir[File.join(BENCH_PATH, "*")].each do |entry|
  id = File.basename(entry)
  next unless File.directory?(entry) && is_id_string?(id)

  if !$success_results.key?(id)
    # this is an experiment with failed validation
    next
  end

  metrics = {}
  if $success_results[id]
    metrics = gather_bench_results(id)
  end

  $bench_results[id] = [$success_results[id], metrics]
end

# save results to yaml file
out_fn = File.join(BENCH_PATH, BENCHMARK_FULL_RESULTS_FN)
File.write(out_fn, YAML.dump($bench_results))
puts "Wrote benchmark results to #{out_fn}"
