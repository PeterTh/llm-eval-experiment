#!/usr/bin/env ruby
# frozen_string_literal: true
require "etc"
require "tmpdir"
require "fileutils"
require "json"
require "time"
require_relative "opencode_observation"

abort "Run as llmtest" unless Process.uid == Etc.getpwnam("llmtest").uid
profile = OpenCodeHarness.campaign_profile(ARGV.fetch(1, "deepseek-v4.1-flash-oc-high"))
root = Dir.mktmpdir("opencode-observation-filesystem-preflight-", "/tmp")
workspace_root = File.join("/home/llmtest/evals", File.basename(root))
workspace = File.join(workspace_root, "probe")
FileUtils.mkdir_p(workspace)
spec = { "id" => "filesystem-preflight", "state" => File.join(root, "private"),
  "workspace" => workspace, "model" => profile.fetch("model"), "effort" => profile.fetch("reasoning_effort"),
  "binary" => ARGV.fetch(0),
  "auth_file" => "/home/llmtest/.local/share/opencode-eval/go-access/data/opencode/auth.json" }
path = File.join(root, "spec.json")
File.write(path, JSON.generate(spec))
runner = OpenCodeObservationRunner.new(path)
begin
  runner.prepare
  evidence = JSON.parse(File.read(File.join(spec.fetch("state"), "prepared.json")))
  runner.start_server
  begin
    runner.verify_server!(evidence)
  rescue OpenCodeHarness::Invalid
    provider, model_id = spec.fetch("model").split("/", 2)
    native = runner.get("/config/providers").fetch("providers").find { |entry| entry["id"] == provider }
    warn JSON.generate({ "rejected_model_metadata" => native&.fetch("models", {})&.fetch(model_id, nil) })
    raise
  end
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
  checks = run.call("/bin/bash", "-c", 'test ! -e /home/petert/llm_para_experiments && test ! -e /tmp/deepseek-contamination-marker-audit-20261023.json && test ! -e /proc/1/root/home/petert && test ! -e /home/llmtest/.local/share/opencode-eval/go-access && getent hosts opencode.ai >/dev/null && echo visibility-and-dns-ok')
  puts JSON.generate({ "checked_at" => Time.now.utc.iso8601, "inferences_launched" => 0,
    "filesystem_isolation" => evidence.fetch("filesystem_isolation"),
    "model" => spec.fetch("model"), "effort" => spec.fetch("effort"), "policy" => evidence.fetch("output_token_policy"),
    "resolved_model" => evidence.fetch("resolved_model"),
    "version" => evidence.fetch("version"), "enabled_tools" => evidence.fetch("enabled_tools"),
    "hybrid_probe" => hybrid, "cuda_probe" => cuda, "visibility_and_dns" => checks })
ensure
  pid = runner.instance_variable_get(:@server_pid)
  if pid
    Process.kill("TERM", pid) rescue Errno::ESRCH
    begin
      Timeout.timeout(2) { Process.wait(pid) }
    rescue Timeout::Error
      Process.kill("KILL", pid) rescue Errno::ESRCH
      Process.wait(pid) rescue Errno::ECHILD
    rescue Errno::ECHILD
      nil
    end
  end
  runner.instance_variable_get(:@server_log)&.close
  # These exact newly-created directories contain only synthetic probes/state.
  FileUtils.remove_entry_secure(root)
  FileUtils.remove_entry_secure(workspace)
  Dir.rmdir(workspace_root)
end
