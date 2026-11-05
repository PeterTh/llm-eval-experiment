# frozen_string_literal: true
require 'shellwords'
require_relative 'full_array_offline_support'

module ValidationAudit
  # A source-bound recovery of an observation whose post-execution parser threw
  # before writing observation.json. Original logs and rank reports are retained.
  module FullArrayRecoveredOutputPolicy
    ID = 'unstructured_gpt-5.6-luna-low_hybrid_r4'
    KIND = 'recovered-identical-replicas-with-intact-primary-output'
    ARGS = %w[-v -r -n 33 -i 513].freeze
    SOURCE_SHA = 'afd781415e7e9951d7705cf92632971f377353e58a5c77e42f0061dfe2204356'
    BINARY_SHA = '089fd8b87be320ae92ba2ba782605a2444644dd18aed012ffb69e5b39a8ea7b4'
    module_function

    def primary(stdout)
      block = stdout.match(/=== RESULTS ===(.*?)=== END RESULTS ===/m)&.to_s
      raise 'Missing or interleaved primary output' unless block && block.scan('=== RESULTS ===').size == 1
      objects = FullArrayOffline.output_objects(block)
      raise 'Unexpected primary result' unless objects.size == 1 && objects.first.values_at('name', 'elements') == ['ElementEnergy', 1089]
      objects
    end

    def execution(logs)
      command = logs.fetch('command')
      unless logs.fetch('exitcode').strip == '0' && logs.fetch('stderr').empty? &&
          %w[stdout stderr].all? { |name| logs.fetch(name).bytesize < 8 * 1024 * 1024 } &&
          command.include?("  output_limit_bytes=8388608\n")
        raise 'Saved execution logs do not establish clean completion'
      end
      argv = Shellwords.split(command.lines.find { |line| line.start_with?('command: ') }.delete_prefix('command: ').strip)
      unless argv.first(3) == %w[mpirun --np 4] && argv.last(ARGS.size) == ARGS && argv[-ARGS.size - 1].end_with?('/' + ID + '/unstructured')
        raise 'Recovered workload differs'
      end
      wall = Float(logs.fetch('wall_time'))
      raise 'Unexpected recovered execution duration' unless wall.positive? && wall < 30
      { 'success' => true, 'exit_code' => 0, 'timed_out' => false, 'wall_seconds' => wall,
        'argv' => argv, 'term_signal' => nil, 'output_truncated' => false,
        'containment_unit' => command.lines.find { |line| line.start_with?('containment_unit: ') }.split(': ', 2).last.strip }
    end

    def verify!(review, source, observation, logs)
      unless source.fetch('id') == ID && source.fetch('benchmark') == 'unstructured' && source.fetch('backend') == 'hybrid' &&
          source.fetch('source_files').fetch('unstructured/unstructured.cpp').fetch('sha256') == SOURCE_SHA &&
          observation.fetch('id') == ID && observation.fetch('args') == ARGS && observation.fetch('binary_sha256') == BINARY_SHA &&
          observation.fetch('execution') == execution(logs) && observation.fetch('total_seconds').nil? &&
          observation.fetch('metadata_origin') == KIND && !observation.fetch('observation_complete') &&
          observation.fetch('errors') == ['Post-execution all-block parser raised: Malformed result object'] &&
          review.fetch('kind') == KIND && review.fetch('id') == ID &&
          review.fetch('observation_sha256') == FullArrayOffline.json_digest(observation) &&
          review.fetch('source') == source.slice('id', 'benchmark', 'backend', 'source_commit', 'source_path', 'source_files') &&
          review.fetch('log_sha256') == logs.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) } &&
          %w[program_runs benchmark_runs llm_invocations program_source_changes executable_file_changes].all? { |key| review.fetch(key).zero? }
        raise 'Recovered observation provenance differs'
      end
      printed = primary(logs.fetch('stdout'))
      objects = observation.fetch('objects')
      raw = review.fetch('raw_capture_reports')
      raw_digests = raw.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
      raise 'Raw rank reports differ' unless observation.fetch('capture_reports').all? do |report|
        JSON.parse(raw.fetch(report.fetch('rank'))) == report.reject { |key, _| %w[rank local_directory].include?(key) }
      end
      unless observation.fetch('printed_objects') == printed && objects.size == 4 &&
          review.fetch('raw_capture_sha256') == raw_digests &&
          objects.map { |object| object.fetch('rank') }.sort == %w[rank-0 rank-1 rank-2 rank-3] &&
          objects.map { |object| object.slice('name', 'elements', 'dtype', 'bytes', 'sha256', 'fnv1a64') }.uniq.size == 1 &&
          objects.all? { |object| object.slice('name', 'elements', 'fnv1a64') == printed.first && object.fetch('dtype') == 'f64le' && object.fetch('bytes') == 8712 } &&
          review.fetch('selected_objects') == [objects.first]
        raise 'Recovered replicas do not uniquely bind the primary complete result'
      end
      begin
        FullArrayOffline.output_objects(logs.fetch('stdout'))
      rescue RuntimeError => error
        raise unless error.message == 'Malformed result object'
        return true
      end
      raise 'Original all-block parsing error does not reproduce'
    end
  end
end
