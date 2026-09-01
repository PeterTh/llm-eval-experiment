#!/usr/bin/env ruby

devices = ENV.fetch("CUDA_VISIBLE_DEVICES", "0,1,2,3").split(",").reject(&:empty?)
local_rank = Integer(ENV.fetch("OMPI_COMM_WORLD_LOCAL_RANK", "0"), 10)
abort "No GPUs were supplied to the hybrid rank wrapper" if devices.empty?
abort "Local rank #{local_rank} has no corresponding GPU in #{devices.inspect}" if local_rank >= devices.length
abort "Usage: local_gpu_rank_wrapper.rb EXECUTABLE [ARGS...]" if ARGV.empty?

ENV["CUDA_VISIBLE_DEVICES"] = devices.fetch(local_rank)
exec(*ARGV)
