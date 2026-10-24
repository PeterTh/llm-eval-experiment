#!/usr/bin/env ruby
# frozen_string_literal: true
require "etc"
require "tmpdir"
require_relative "claude_observation"

abort "Run as llmtest" unless Process.uid == Etc.getpwnam("llmtest").uid
root = Dir.mktmpdir("claude-observation-preflight-", "/tmp")
workspace_root = File.join("/home/llmtest/evals", File.basename(root))
workspace = File.join(workspace_root, "probe")
FileUtils.mkdir_p(workspace)
spec = { "id" => "probe", "state" => File.join(root, "private"), "workspace" => workspace,
  "binary" => File.realpath(ARGV.fetch(0)), "model" => "claude-fable-5-1", "effort" => "medium",
  "instruction" => "unused: --version exits without inference", "flags" => ["--version"], "timeout_seconds" => 30,
  "environment" => %w[CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC DISABLE_AUTOUPDATER DISABLE_TELEMETRY DISABLE_ERROR_REPORTING DISABLE_BUG_COMMAND].to_h { |k| [k, "1"] }.merge("HISTFILE" => "/dev/null") }
path = File.join(root, "spec.json")
File.write(path, JSON.generate(spec))
runner = ClaudeObservationRunner.new(path)
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
  visibility = run.call("/bin/bash", "-c", 'test ! -e /home/petert && test ! -e /proc/1/root/home/petert && test ! -e /home/llmtest/.local && getent hosts api.anthropic.com >/dev/null && echo visibility-and-dns-ok')
  raise "CLI lifecycle check failed" unless runner.run == 0
  evidence = JSON.parse(File.read(File.join(workspace, ClaudeObservationRunner::EVIDENCE)))
  raise "Credential fingerprint leaked" if evidence.key?("auth_before_sha256")
  raise "Private state retained" if File.exist?(spec.fetch("state"))
  puts JSON.generate({ "checked_at" => Time.now.utc.iso8601, "inferences_launched" => 0,
    "filesystem_isolation" => evidence.fetch("filesystem_isolation"), "version" => evidence.fetch("version"),
    "binary_sha256" => evidence.fetch("binary_sha256"), "hybrid_probe" => hybrid, "cuda_probe" => cuda,
    "visibility_and_dns" => visibility, "private_state_removed" => true, "lifecycle_exit_status" => 0 })
ensure
  FileUtils.remove_entry_secure(root)
  FileUtils.remove_entry_secure(workspace)
  Dir.rmdir(workspace_root)
end
