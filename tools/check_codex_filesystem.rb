#!/usr/bin/env ruby
# frozen_string_literal: true
require "etc"
require "tmpdir"
require_relative "codex_observation"

# Run only while the performance host is idle: tiny MPI/OMP and CUDA probes.
# No model request. The production-budget pilot separately tests real inference.
abort "Run as llmtest" unless Process.uid == Etc.getpwnam("llmtest").uid
root = Dir.mktmpdir("codex-observation-preflight-", "/tmp")
workspace_root = File.join("/home/llmtest/evals", File.basename(root))
workspace = File.join(workspace_root, "probe")
FileUtils.mkdir_p(workspace)
spec = { "id" => "probe", "state" => File.join(root, "private"), "workspace" => workspace,
  "binary" => File.realpath(ARGV.fetch(0)), "model" => "gpt-6.1-terra", "effort" => "medium",
  "instruction" => "unused: --version exits without inference", "flags" => ["--version"],
  "timeout_seconds" => 30, "environment" => {} }
path = File.join(root, "spec.json")
File.write(path, JSON.generate(spec))
runner = CodexObservationRunner.new(path)
begin
  runner.prepare
  isolation = runner.filesystem
  run = lambda do |*args|
    out, err, status = Open3.capture3(*isolation.prefix, *args)
    raise "Probe failed #{args.inspect}: #{err}\n#{out}" unless status.success?
    out.strip
  end
  File.write(File.join(workspace, "hybrid.cpp"), <<~'CPP')
    #include <mpi.h>
    #include <omp.h>
    #include <stdio.h>
    int main(int argc, char **argv) {
      MPI_Init(&argc, &argv);
      int rank, n, threads=0;
      MPI_Comm_rank(MPI_COMM_WORLD, &rank); MPI_Comm_size(MPI_COMM_WORLD, &n);
      #pragma omp parallel num_threads(2) reduction(+:threads)
      threads += 1;
      printf("rank=%d ranks=%d threads=%d\n",rank,n,threads);
      MPI_Finalize(); return (n==2 && threads==2) ? 0 : 1;
    }
  CPP
  File.write(File.join(workspace, "cuda.cu"), <<~'CU')
    #include <cuda_runtime.h>
    #include <stdio.h>
    __global__ void set(int *p) { *p = 7; }
    int main() {
      int *p, result=0;
      if(cudaMalloc(&p,sizeof(int))!=cudaSuccess) return 1;
      set<<<1,1>>>(p);
      if(cudaMemcpy(&result,p,sizeof(int),cudaMemcpyDeviceToHost)!=cudaSuccess) return 2;
      cudaFree(p); printf("cuda=%d\n",result); return result==7?0:3;
    }
  CU
  run.call("/usr/bin/mpicxx", "-O2", "-fopenmp", "hybrid.cpp", "-o", "hybrid")
  hybrid = run.call("/usr/bin/mpirun", "-n", "2", "./hybrid")
  run.call("/usr/local/cuda/bin/nvcc", "-O2", "cuda.cu", "-o", "cuda")
  cuda = run.call("./cuda")
  visibility = run.call("/bin/bash", "-c", 'test ! -e /home/petert && test ! -e /proc/1/root/home/petert && test ! -e /home/llmtest/.local && test ! -e /home/llmtest/.codex/sessions && getent hosts chatgpt.com >/dev/null && echo visibility-and-dns-ok')
  raise "CLI lifecycle check failed" unless runner.run == 0
  evidence = JSON.parse(File.read(File.join(workspace, CodexObservationRunner::EVIDENCE)))
  raise "Credential fingerprint leaked" if evidence.key?("auth_before_sha256")
  raise "Private state retained" if File.exist?(spec.fetch("state"))
  raise "Unexpected session created without inference" unless evidence.fetch("archived_sessions").empty?
  puts JSON.generate({ "checked_at" => Time.now.utc.iso8601, "inferences_launched" => 0,
    "filesystem_isolation" => evidence.fetch("filesystem_isolation"), "version" => evidence.fetch("version"),
    "binary_sha256" => evidence.fetch("binary_sha256"), "hybrid_probe" => hybrid, "cuda_probe" => cuda,
    "tool_host_startup" => "passed: pinned companion --help inside isolated namespace",
    "visibility_and_dns" => visibility, "private_state_removed" => true, "lifecycle_exit_status" => 0 })
ensure
  # Only the two fresh mktemp-derived probe directories, never an existing run.
  FileUtils.remove_entry_secure(root)
  FileUtils.remove_entry_secure(workspace)
  Dir.rmdir(workspace_root)
end
