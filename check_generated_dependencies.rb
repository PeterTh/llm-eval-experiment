# This script checks the generated code for dependencies that aren't whitelisted
# 
# Usage: ruby check_generated_dependencies.rb <path_to_experiment_output>
# 
# The script will print any dependencies that are found in the generated code but not in the whitelist, along with the files they were found in.

require_relative "general" 

if ARGV.size != 1 || ARGV.include?("--help") || ARGV.include?("-h")
    puts "Usage: ruby check_generated_dependencies.rb <path_to_experiment_output>"
    exit
end

EXP_PATH = ARGV[0]

WHITELIST = ["PRIVATE", "PUBLIC", "m", # general
  "OpenMP::OpenMP_CXX", "${OpenMP_CXX_LIBRARIES}", "$<$<BOOL:${OpenMP_CXX_FOUND}>:${OpenMP_CXX_LIBRARIES}>", # OMP 1
  "-lgomp", "gomp","-fopenmp", "omp", "$<$<CXX_COMPILER_ID:GNU>:gomp;m>", "$<$<CXX_COMPILER_ID:Clang>:omp;m>", # OMP 2
  "mpi", "MPI::MPI_CXX", "MPI::MPI_C", "${MPI_CXX_LIBRARIES}", "${MPI_LIBRARIES}", # MPI
  "CUDA::cudart", "${MPI_CXX_LINK_FLAGS}", "CUDA::cuda", "CUDAToolkit::cudart", "cuda", "cudart", "${CUDA_CUDART_LIBRARY}", # CUDA 1
  "-lcudart", "cudadevrt", "OpenMP::OpenMP_CUDA", "${CUDA_LIBRARIES}", "${CUDART_LIB}", "CUDAToolkit::CUDART", # CUDA 2
  "${CUDA_LIBS}", "${CUDA_LIB}", "/usr/local/cuda-12.6/lib64/libcudart.so", "/usr/local/cuda/lib64/libcudart.so" # CUDA 3
]

EQUIVALENCE_CLASSES = {
  "cublas" => ["CUDA::cublas","cublas", "CUDAToolkit::cublas", "${CUDA_CUBLAS_LIBRARY}", "${CUDA_CUBLAS_LIBRARIES}", "${CUDA_CUBLAS_LIB}", "-lcublas"],
  "cusolver" => ["CUDA::cusolver", "cusolver", "CUDAToolkit::cusolver", "${CUDA_cusolver_LIBRARY}", "${CUDA_CUSOLVER_LIBRARIES}", "${CUDA_CUSOLVER_LIB}", "-lcusolver"],
  "cusparse" => ["CUDA::cusparse", "cusparse", "CUDAToolkit::cusparse", "${CUDA_CUSPARSE_LIBRARY}", "${CUDA_CUSPARSE_LIBRARIES}", "${CUDA_CUSPARSE_LIB}", "-lcusparse"],
  "curand" => ["CUDA::curand", "curand", "CUDAToolkit::curand", "${CUDA_CURAND_LIBRARY}", "${CUDA_CURAND_LIBRARIES}", "${CUDA_CURAND_LIB}", "-lcurand"]
}

$non_whitelisted_deps = {};

$fallback_cmake_file_needed_for = []

def check_dependencies(id)
  file_path = File.join(EXP_PATH, id)
  if !File.directory?(file_path)
    raise "Expected #{file_path} to be a directory"
  end

  # extract benchmark name from id
  benchmark_name, _, _, _ = id_string_to_infos(id)

  # read CMakeLists.txt file and extract dependencies
  dependencies = []
  cmake_file_fn = File.join(file_path, benchmark_name, "CMakeLists.txt")
  if !File.exist?(cmake_file_fn)
    fallback_cmake_file_fn = File.join(file_path, "CMakeLists.txt")
    if File.exist?(fallback_cmake_file_fn)
      cmake_file_fn = fallback_cmake_file_fn
      $fallback_cmake_file_needed_for << id
    else
      raise "CMakeLists.txt not found for #{id} at expected locations #{cmake_file_fn} and #{fallback_cmake_file_fn}"
    end
  end
  File.readlines(cmake_file_fn).each do |line|
    if line =~ /target_link_libraries\((\w+)\s+([^\)]+)\)/
      deps = $2.split
      # apply equivalence classes
      deps = deps.map do |dep|
        found_class = EQUIVALENCE_CLASSES.find { |_, equivs| equivs.include?(dep) }
        found_class ? found_class[0] : dep
      end
      deps.uniq!
      dependencies.concat(deps)
    end
  end

  # check dependencies against whitelist
  dependencies.each do |dep|
    if !WHITELIST.include?(dep)
      $non_whitelisted_deps[dep] ||= []
      $non_whitelisted_deps[dep] << id
    end
  end
end

# actually perform the checks

Dir.entries(EXP_PATH).each do |entry|
  next unless is_id_string?(entry)
  check_dependencies(entry)
end

# print results
# sort dependencies by number of occurrences
sorted_deps = $non_whitelisted_deps.sort_by { |dep, ids| -ids.size }
puts "Non-whitelisted dependencies found in generated code:"
sorted_deps.each do |dep, ids|
  puts "- #{dep} (found in #{ids.size} files: #{ids.join(", ")})"
end

if $fallback_cmake_file_needed_for.any?
    puts "\nNote: For the following #{$fallback_cmake_file_needed_for.size} IDs, the CMakeLists.txt file was not found in the expected location and a fallback location was used. This may indicate an issue with the code generation for these cases:"
    $fallback_cmake_file_needed_for.each do |id|
        puts "- #{id}"
    end
    total_ids = Dir.entries(EXP_PATH).select { |entry| is_id_string?(entry) }.size
    percentage = ($fallback_cmake_file_needed_for.size.to_f / total_ids * 100).round(2)
    puts "This is #{percentage}% of the total #{total_ids} IDs checked.\n"
end

# store results as a map from ids to non-whitelisted depnendencies found in their CMakeLists.txt file, for later analysis
ids_to_non_whitelisted_deps = {}
$non_whitelisted_deps.each do |dep, ids|
  ids.each do |id|
    ids_to_non_whitelisted_deps[id] ||= []
    ids_to_non_whitelisted_deps[id] << dep
  end
end
results_fn = File.join(EXP_PATH, "non_whitelisted_dependencies.yaml")
File.write(results_fn, ids_to_non_whitelisted_deps.to_yaml)
puts "\nMapping of IDs to non-whitelisted dependencies saved to #{results_fn}.\n"
