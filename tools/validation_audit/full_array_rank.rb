# frozen_string_literal: true
require 'json'
require 'fileutils'

raise 'Usage: full_array_rank.rb CONFIG_JSON EXECUTABLE [ARGS...]' if ARGV.size < 2
config_path = File.realpath(ARGV.shift)
config = JSON.parse(File.read(config_path))
rank = ENV.fetch('OMPI_COMM_WORLD_RANK', 'single')
raise 'Invalid MPI rank' unless rank == 'single' || rank.match?(/\A\d+\z/)
directory = File.join(config.fetch('capture_root'), 'rank-' + rank)
raise 'Captures must be local' unless File.realpath(File.dirname(directory)).start_with?('/tmp/')
observer = File.expand_path('full_array_observer.py', __dir__)
exec({ 'VALIDATION_ARRAY_DIR' => directory, 'VALIDATION_ARRAY_CONFIG' => config_path },
  'gdb', '-nx', '-q', '-batch', '--return-child-result',
  '-iex', 'set auto-load off', '-iex', 'set debuginfod enabled off',
  '-iex', 'set auto-solib-add off',
  '-x', observer, '--args', *ARGV)
