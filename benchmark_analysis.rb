# helper to get TLOC for benchmarks

BENCH_PATH = File.expand_path("../benchmarks")

def linecount(file_path)
    return File.read(file_path).lines.count
end

$common_line_count = linecount(File.join(BENCH_PATH, "common", "hash.hpp")) + linecount(File.join(BENCH_PATH, "common", "results_output.hpp")) 

def bench_line_count(benchmark)
    benchmark_path = File.join(BENCH_PATH, benchmark)
    total_lines = $common_line_count
    # txt to include CMakeLists.txt since it must also be edited by the LLM and is part of the complexity of the task
    Dir.glob(File.join(benchmark_path, "**", "*.{c,cpp,h,txt}")).each do |file|
        total_lines += linecount(file)
    end
    return total_lines
end

benchmark_loc = {}

Dir[File.join(BENCH_PATH, "*")].each do |entry|
    if File.directory?(entry)
        next if entry.end_with?("common") || entry.end_with?("build")
        benchmark = File.basename(entry)
        benchmark_loc[benchmark] = bench_line_count(benchmark)
    end
end

benchmark_loc = benchmark_loc.sort_by { |benchmark, loc| loc }.to_h
benchmark_loc.each do |benchmark, loc|
    puts "#{benchmark} & #{loc} & \\todo{Description} \\\\"
end